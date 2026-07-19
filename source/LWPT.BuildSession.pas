{ LWPT.BuildSession — private compiler staging and atomic publication. }
unit LWPT.BuildSession;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Core;

const
  BUILD_SESSION_SCHEMA_VERSION = 1;
  BUILD_PUBLICATION_FINGERPRINT_SCHEMA_VERSION = 1;
  BUILD_SESSIONS_DIR = LWPT_DIR + '/sessions';
  ObservabilityHeartbeatIntervalEnvironment = PROJECT_NAME
    + '_HEARTBEAT_INTERVAL_MS';
  ObservabilityStartEvent = 'START ';
  ObservabilityHeartbeatEvent = 'HEARTBEAT ';
  ObservabilityPassEvent = 'PASS ';
  ObservabilityFailEvent = 'FAIL ';
  ObservabilitySkipEvent = 'SKIP ';
  ObservabilityBuildIdentityNamespace = 'build:';
  ObservabilityTestIdentityNamespace = 'test:';
  ObservabilityLogsDirectory = '/logs/';
  ObservabilityLogExtension = '.log';
  { FPC's RTL FileRec/TextRec name buffer holds this many characters. The
    compiler writes .s assembly files and link scripts through that API and
    silently truncates longer paths: the assembly lands under a truncated
    name while the assembler command line carries the full path, so clang
    fails with "no such file or directory: ....s". Session staging must
    keep every compiler-written path within this budget. }
  COMPILER_PATH_LIMIT = 255;

type
  TLWPTBuildPublicationRequest = record
    BuildRequest: TLWPTBuildRequest;
    CompilerExecutable: string;
    ManifestContentHash: string;
    PublicOutput: string;
    Environment: TStringArray;
    WorkspacePaths: TStringArray;
    HookDefinition: TStringArray;
    HookInputs: TStringArray;
    ExcludedPaths: TStringArray;
  end;

  TLWPTBuildPublicationResult = (bprPublished, bprStale);

  TLWPTBuildSession = class
  private
    FProjectRoot: string;
    FSessionID: string;
    FSessionRoot: string;
    FSessionOwnerGuardPath: string;
    FSessionOwnerGuard: TObject;
    FFinished: Boolean;
    function JobLogPath(const AName: string): string;
    procedure WriteState(const AState: string);
  public
    constructor Create(const AProjectRoot: string);
    destructor Destroy; override;
    function JobRoot(const AName: string): string;
    function JobLogReference(const AName: string): string;
    function HookRoot: string;
    function SessionReference: string;
    procedure WriteJobLog(const AName, AOutput: string);
    procedure Finish(ASuccess: Boolean; const ADetail: string = '');
    property SessionID: string read FSessionID;
    property SessionRoot: string read FSessionRoot;
  end;

function CaptureBuildPublicationFingerprint(
  const AProjectRoot, AManifestPath, ACfgPath, ALockPath,
  AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest): string;
function BuildSessionPathKey(const AValue: string): string;
function ObservabilityHeartbeatIntervalMilliseconds: QWord;
function FormatElapsedMilliseconds(const AElapsed: QWord): string;
procedure AppendUnitDirsFromOptions(const AOptions: TStrings;
  var ADirs: TStringArray);
procedure AppendUnitDirsFromCfg(const ACfgPath: string;
  var ADirs: TStringArray);
function LongestCompiledBaseNameLength(const ADirectories: TStringArray;
  const AEntrySource: string): Integer;
procedure EnsureCompilerPathBudget(const AUnitDirectory,
  AExecutableDirectory: string; ALongestBaseNameLength: Integer);
function BuildPublicationLockPath(const AProjectRoot, AOutput: string): string;
function PublishBuildArtifact(const AProjectRoot, ACandidatePath,
  ADestinationPath, AExpectedFingerprint, AManifestPath, ACfgPath,
  ALockPath, AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest):
  TLWPTBuildPublicationResult;
procedure RepairBuildSessions(const AProjectRoot: string;
  out ARemoved, ARetained: Integer);

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  Unix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  DateUtils;

const
  DefaultObservabilityHeartbeatIntervalMilliseconds = 30000;
  PUBLICATION_LOCK_WAIT_MILLISECONDS = 30000;
  SESSION_PARTIAL_GRACE_MILLISECONDS = 5000;
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  FD_CLOEXEC_LWPT = 1;
  F_WRLCK_LWPT = 1;
  F_UNLCK_LWPT = 2;
  {$ELSE}
  FD_CLOEXEC_LWPT = FD_CLOEXEC;
  F_WRLCK_LWPT = F_WRLCK;
  F_UNLCK_LWPT = F_UNLCK;
  {$ENDIF}
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  LOCKFILE_EXCLUSIVE_LOCK_LWPT = $00000002;
  LOCKFILE_FAIL_IMMEDIATELY_LWPT = $00000001;
  {$ENDIF}

var
  NextSessionCounter: QWord;
  PublicationCriticalSections:
    array[0..63] of TRTLCriticalSection;

type
  ELWPTParsedManifestChanged = class(ELWPTError);

  {$IFDEF UNIX}
  {$IFDEF LINUX}
  TLWPTFlock = BaseUnix.FLock;
  {$ELSE}
  TLWPTFlock = TFlock;
  {$ENDIF}
  {$ENDIF}

  TLWPTPublicationLock = class
  private
    FPath: string;
    FCriticalSectionIndex: Integer;
    FCriticalSectionEntered: Boolean;
    {$IFDEF UNIX}
    FDescriptor: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    {$ENDIF}
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
  end;

  TLWPTSessionOwnerGuard = class
  private
    FPath: string;
    FLocked: Boolean;
    {$IFDEF UNIX}
    FDescriptor: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    {$ENDIF}
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
  end;

function RootedPath(const AProjectRoot, APath: string): string;
begin
  if APath = '' then Exit('');
  if (APath[1] = '/') or (APath[1] = '\')
    or ((Length(APath) >= 2) and (APath[1] in ['a'..'z', 'A'..'Z'])
      and (APath[2] = ':')) then
    Exit(ExpandFileName(APath));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot) + APath);
end;

function TextHash(const AText: string): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Bytes[0], Length(AText));
  Result := SHA256BytesPrefixed(Bytes);
end;

function BuildSessionPathKey(const AValue: string): string;
var
  BaseName, Digest: string;
begin
  { Keys sit inside compiler staging paths that must stay within
    COMPILER_PATH_LIMIT, so the readable prefix and the digest are both
    kept short. 12 hex digits (48 bits) still make accidental collisions
    between the handful of keys inside one session implausible. }
  BaseName := SanitisePathSegment(ChangeFileExt(ExtractFileName(AValue), ''));
  if BaseName = '' then BaseName := 'job';
  if Length(BaseName) > 16 then SetLength(BaseName, 16);
  Digest := TextHash(AValue);
  Result := BaseName + '-' + Copy(Digest, 8, 12);
end;

function ObservabilityHeartbeatIntervalMilliseconds: QWord;
var
  Raw: string;
  Parsed: Int64;
begin
  Raw := SysUtils.GetEnvironmentVariable(ObservabilityHeartbeatIntervalEnvironment);
  if (Raw <> '') and TryStrToInt64(Raw, Parsed) and (Parsed > 0) then
  begin
    Result := QWord(Parsed);
    if Result > DefaultObservabilityHeartbeatIntervalMilliseconds then
      Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
    Exit;
  end;
  Result := DefaultObservabilityHeartbeatIntervalMilliseconds;
end;

function FormatElapsedMilliseconds(const AElapsed: QWord): string;
begin
  Result := UIntToStr(AElapsed) + ' ms';
end;

{ Single home for "which directories does this compile search for unit
  sources". Both the target-build flow (cfg passed to FPC unexpanded via
  @file) and the test/script flow (cfg already expanded onto the parameter
  list) feed the path-budget check through these two helpers, so the two
  flows cannot silently diverge in how they extract -Fu directories. }
procedure AppendUnitDirsFromOptions(const AOptions: TStrings;
  var ADirs: TStringArray);
var
  i, Count: Integer;
  Line: string;
begin
  for i := 0 to AOptions.Count - 1 do
  begin
    Line := Trim(AOptions[i]);
    if Copy(Line, 1, 3) <> '-Fu' then Continue;
    Count := Length(ADirs);
    SetLength(ADirs, Count + 1);
    ADirs[Count] := Copy(Line, 4, MaxInt);
  end;
end;

procedure AppendUnitDirsFromCfg(const ACfgPath: string;
  var ADirs: TStringArray);
var
  Lines: TStringList;
begin
  if not FileExists(ACfgPath) then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ACfgPath);
    AppendUnitDirsFromOptions(Lines, ADirs);
  finally
    Lines.Free;
  end;
end;

function LongestCompiledBaseNameLength(const ADirectories: TStringArray;
  const AEntrySource: string): Integer;
var
  i, Len: Integer;
  Search: TSearchRec;
  Dir, Ext: string;
begin
  { The compiler writes '<unit>.s' into the staging unit directory for the
    entry program and for every unit it recompiles from the search paths.
    Scanning the search paths for the longest Pascal base name makes the
    path budget below exact instead of guessing an allowance. A long-named
    unit that the entry never uses still counts — refusing such a compile
    is deliberate: any unit on a search path is one uses-clause edit away
    from compiling, and a deterministic setup error beats the truncation
    failure appearing only once that edit lands. }
  Result := Length(ChangeFileExt(ExtractFileName(AEntrySource), ''));
  for i := 0 to High(ADirectories) do
  begin
    if ADirectories[i] = '' then Continue;
    Dir := IncludeTrailingPathDelimiter(ExpandFileName(ADirectories[i]));
    if SysUtils.FindFirst(Dir + '*', faAnyFile, Search) <> 0 then Continue;
    try
      repeat
        if (Search.Attr and faDirectory) <> 0 then Continue;
        Ext := LowerCase(ExtractFileExt(Search.Name));
        if (Ext <> '.pas') and (Ext <> '.pp') then Continue;
        Len := Length(ChangeFileExt(Search.Name, ''));
        if Len > Result then Result := Len;
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
  end;
end;

procedure EnsureCompilerPathBudget(const AUnitDirectory,
  AExecutableDirectory: string; ALongestBaseNameLength: Integer);
const
  { Longest fixed-name artefact FPC writes beside the executable
    ('symbol_order.fpc'; 'ppaslink.sh' and 'link.res' are shorter). }
  LINK_ARTEFACT_LENGTH = 16;
var
  UnitDirectory, ExecutableDirectory: string;
  WorstLength, LinkLength: Integer;
begin
  UnitDirectory := ExpandFileName(AUnitDirectory);
  ExecutableDirectory := ExpandFileName(AExecutableDirectory);
  WorstLength := Length(UnitDirectory) + 1 + ALongestBaseNameLength
    + Length('.s');
  LinkLength := Length(ExecutableDirectory) + 1 + LINK_ARTEFACT_LENGTH;
  if LinkLength > WorstLength then WorstLength := LinkLength;
  if WorstLength <= COMPILER_PATH_LIMIT then Exit;
  raise ELWPTError.CreateFmt(
    'compiler staging path is too long: files below "%s" would reach %d '
    + 'characters, but FPC''s file API silently truncates paths over %d '
    + 'characters and the compile then fails with a missing .s file; '
    + 'shorten the project path by at least %d characters',
    [UnitDirectory, WorstLength, COMPILER_PATH_LIMIT,
     WorstLength - COMPILER_PATH_LIMIT]);
end;

function SamePath(const AFirst, ASecond: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ExpandFileName(AFirst), ExpandFileName(ASecond));
  {$ELSE}
  Result := ExpandFileName(AFirst) = ExpandFileName(ASecond);
  {$ENDIF}
end;

function PathIsExcluded(const AProjectRoot, APath: string;
  const AExcludedPaths: TStringArray): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AExcludedPaths) do
    if (AExcludedPaths[i] <> '')
       and SamePath(APath, RootedPath(AProjectRoot, AExcludedPaths[i])) then
      Exit(True);
  Result := False;
end;

function DirectoryIdentity(const APath: string): string;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  if FpStat(APath, Info) <> 0 then Exit('');
  Result := IntToStr(Info.st_dev) + ':' + IntToStr(Info.st_ino);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  Info: TByHandleFileInformation;
begin
  Result := '';
  Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)), 0,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE,
    nil, Windows.OPEN_EXISTING, Windows.FILE_FLAG_BACKUP_SEMANTICS, 0);
  if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then Exit;
  try
    if Windows.GetFileInformationByHandle(Handle, Info) then
      Result := IntToStr(Info.dwVolumeSerialNumber) + ':'
        + IntToStr(Info.nFileIndexHigh) + ':'
        + IntToStr(Info.nFileIndexLow);
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

function InputDirectoryFingerprint(const AProjectRoot, ARoot: string;
  const AExcludedPaths: TStringArray): string;
var
  Files, VisitedDirectories: TStringList;
  SessionsRoot: string;
  SessionsIdentity: string;

  procedure Collect(const ADir, ARelative: string);
  var
    Entries: TStringList;
    Search: TSearchRec;
    Base, Full, Relative, Identity: string;
    Attr, i: Integer;
  begin
    if PathContains(SessionsRoot, ADir) then Exit;
    if PathIsExcluded(AProjectRoot, ADir, AExcludedPaths) then Exit;
    Identity := DirectoryIdentity(ADir);
    if (Identity <> '') and (Identity = SessionsIdentity) then Exit;
    if (Identity <> '') and (VisitedDirectories.IndexOf(Identity) >= 0) then
      Exit;
    if Identity <> '' then VisitedDirectories.Add(Identity);
    Base := IncludeTrailingPathDelimiter(ADir);
    Entries := TStringList.Create;
    Entries.CaseSensitive := True;
    if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, Search) <> 0 then
    begin
      Entries.Free;
      Exit;
    end;
    try
      repeat
        if (Search.Name <> '.') and (Search.Name <> '..') then
          Entries.Add(Search.Name);
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
    Entries.Sort;
    try
      for i := 0 to Entries.Count - 1 do
      begin
        Full := Base + Entries[i];
        if SysUtils.FindFirst(Full, faAnyFile or faSymLink, Search) <> 0 then
          Continue;
        try
          Attr := Search.Attr;
        finally
          SysUtils.FindClose(Search);
        end;
        Relative := ARelative + Entries[i];
        if PathIsExcluded(AProjectRoot, Full, AExcludedPaths) then Continue;
        if (Attr and faSymLink) <> 0 then
        begin
          if DirectoryExists(Full) then
            Collect(Full, Relative + '/')
          else if FileExists(Full) then
            Files.Add(IntToStr(Length(Relative)) + ':' + Relative + '='
              + SHA256File(Full));
        end
        else if (Attr and faDirectory) <> 0 then
        begin
          if not PathContains(SessionsRoot, Full) then
            Collect(Full, Relative + '/');
        end
        else
          Files.Add(IntToStr(Length(Relative)) + ':' + Relative + '='
            + SHA256File(Full));
      end;
    finally
      Entries.Free;
    end;
  end;

begin
  Files := TStringList.Create;
  VisitedDirectories := TStringList.Create;
  try
    SessionsRoot := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR);
    SessionsIdentity := DirectoryIdentity(SessionsRoot);
    Collect(ARoot, '');
    Files.Sort;
    Result := TextHash(Files.Text);
  finally
    VisitedDirectories.Free;
    Files.Free;
  end;
end;

function PathFingerprint(const AProjectRoot, APath: string;
  const AExcludedPaths: TStringArray): string;
var
  Full: string;
begin
  Full := RootedPath(AProjectRoot, APath);
  if Full = '' then Exit('<none>');
  { Explicit files remain inputs even when they are also declared outputs.
    Exclusions apply to broad tree walks so unrelated published artifacts do
    not invalidate another target. }
  if FileExists(Full) then Exit('file:' + SHA256File(Full));
  if PathIsExcluded(AProjectRoot, Full, AExcludedPaths) then Exit('<excluded>');
  if DirectoryExists(Full) then
    Exit('tree:' + InputDirectoryFingerprint(AProjectRoot, Full,
      AExcludedPaths));
  Result := 'missing';
end;

procedure AddField(AFields: TStrings; const AName, AValue: string);
begin
  AFields.Add(AName + '=' + IntToStr(Length(AValue)) + ':' + AValue);
end;

procedure AddPathArray(AFields: TStrings; const AProjectRoot, AName: string;
  const APaths, AExcludedPaths: TStringArray);
var
  i: Integer;
begin
  AddField(AFields, AName + '.count', IntToStr(Length(APaths)));
  for i := 0 to High(APaths) do
  begin
    AddField(AFields, AName + '.' + IntToStr(i) + '.path', APaths[i]);
    AddField(AFields, AName + '.' + IntToStr(i) + '.content',
      PathFingerprint(AProjectRoot, APaths[i], AExcludedPaths));
  end;
end;

procedure AddStringArray(AFields: TStrings; const AName: string;
  const AValues: TStringArray);
var
  i: Integer;
begin
  AddField(AFields, AName + '.count', IntToStr(Length(AValues)));
  for i := 0 to High(AValues) do
    AddField(AFields, AName + '.' + IntToStr(i), AValues[i]);
end;

function CaptureBuildPublicationFingerprint(
  const AProjectRoot, AManifestPath, ACfgPath, ALockPath,
  AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest): string;
var
  Fields: TStringList;
  EmptyPaths: TStringArray;
  ManifestFingerprint, SourceDirectory: string;
begin
  SetLength(EmptyPaths, 0);
  Fields := TStringList.Create;
  try
    AddField(Fields, 'schema',
      IntToStr(BUILD_PUBLICATION_FINGERPRINT_SCHEMA_VERSION));
    ValidateBuildRequest(ARequest.BuildRequest);
    AddField(Fields, 'build-request',
      SerializeBuildRequest(ARequest.BuildRequest));
    AddField(Fields, 'compiler.executable', ARequest.CompilerExecutable);
    AddField(Fields, 'manifest.parsed-hash', ARequest.ManifestContentHash);
    AddPathArray(Fields, AProjectRoot, 'sources',
      ARequest.BuildRequest.Inputs.Sources, EmptyPaths);
    SourceDirectory := ExtractFileDir(
      RootedPath(AProjectRoot, ARequest.BuildRequest.Inputs.EntryPoint));
    AddField(Fields, 'source-directory', SourceDirectory);
    AddField(Fields, 'source-directory.content',
      PathFingerprint(AProjectRoot, SourceDirectory,
        ARequest.ExcludedPaths));
    AddField(Fields, 'output', ARequest.PublicOutput);
    AddField(Fields, 'output.previous',
      PathFingerprint(AProjectRoot, ARequest.PublicOutput, EmptyPaths));
    AddStringArray(Fields, 'environment', ARequest.Environment);
    AddStringArray(Fields, 'excluded-paths', ARequest.ExcludedPaths);
    AddPathArray(Fields, AProjectRoot, 'unit-paths',
      ARequest.BuildRequest.Inputs.UnitPaths, ARequest.ExcludedPaths);
    AddPathArray(Fields, AProjectRoot, 'include-paths',
      ARequest.BuildRequest.Inputs.IncludePaths, ARequest.ExcludedPaths);
    AddPathArray(Fields, AProjectRoot, 'workspace-paths',
      ARequest.WorkspacePaths, ARequest.ExcludedPaths);
    AddPathArray(Fields, AProjectRoot, 'resources',
      ARequest.BuildRequest.Inputs.Resources, ARequest.ExcludedPaths);
    AddStringArray(Fields, 'hook-definition', ARequest.HookDefinition);
    AddPathArray(Fields, AProjectRoot, 'hook-inputs',
      ARequest.HookInputs, ARequest.ExcludedPaths);
    ManifestFingerprint := PathFingerprint(
      AProjectRoot, AManifestPath, EmptyPaths);
    if ManifestFingerprint <> 'file:' + ARequest.ManifestContentHash then
      raise ELWPTParsedManifestChanged.Create(
        'manifest changed after it was parsed');
    AddField(Fields, 'manifest', ManifestFingerprint);
    AddField(Fields, 'cfg',
      PathFingerprint(AProjectRoot, ACfgPath, EmptyPaths));
    AddField(Fields, 'lock',
      PathFingerprint(AProjectRoot, ALockPath, EmptyPaths));
    AddField(Fields, 'modules', PathFingerprint(AProjectRoot, AModulesPath,
      ARequest.ExcludedPaths));
    Result := TextHash(Fields.Text);
  finally
    Fields.Free;
  end;
end;

function ProcessIsAlive(APID: LongInt): Boolean;
{$IFDEF UNIX}
begin
  if APID <= 0 then Exit(False);
  Result := (FpKill(APID, 0) = 0) or (fpgeterrno = ESysEPERM);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  ExitCode: DWORD;
begin
  if APID <= 0 then Exit(False);
  Handle := Windows.OpenProcess(
    Windows.PROCESS_QUERY_INFORMATION, False, DWORD(APID));
  if Handle = 0 then Exit(False);
  try
    Result := Windows.GetExitCodeProcess(Handle, ExitCode)
      and (ExitCode = Windows.STILL_ACTIVE);
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

function ReadPID(const APath: string): LongInt;
var
  Lines: TStringList;
begin
  Result := -1;
  if not FileExists(APath) then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    if Lines.Count > 0 then
      Result := StrToIntDef(Trim(Lines[0]), -1);
  finally
    Lines.Free;
  end;
end;

function IncompleteStateIsAbandoned(const APath: string): Boolean;
var
  Age: LongInt;
begin
  Age := FileAge(APath);
  if Age < 0 then Exit(False);
  Result := MilliSecondsBetween(Now, FileDateToDateTime(Age))
    >= SESSION_PARTIAL_GRACE_MILLISECONDS;
end;

function EnsureDirectory(const APath: string): Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to 100 do
  begin
    if DirectoryExists(APath) or ForceDirectories(APath) then Exit(True);
    Sleep(10);
  end;
  Result := DirectoryExists(APath);
end;

function ReadSessionState(const APath: string): string;
var
  Lines: TStringList;
begin
  Result := '';
  if not FileExists(APath) then Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(APath);
    if Lines.Count > 1 then Result := Trim(Lines[1]);
  finally
    Lines.Free;
  end;
end;

constructor TLWPTSessionOwnerGuard.Create(const APath: string);
{$IFDEF UNIX}
var
  LockSpec: TLWPTFlock;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Overlapped: TOverlapped;
{$ENDIF}
begin
  inherited Create;
  FPath := APath;
  FLocked := False;
  if not EnsureDirectory(ExtractFileDir(FPath)) then
    raise ELWPTError.CreateFmt(
      'could not create build session owner guard directory %s',
      [ExtractFileDir(FPath)]);
  {$IFDEF UNIX}
  FDescriptor := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  {$ENDIF}
  {$IFDEF UNIX}
  FDescriptor := FpOpen(PChar(FPath), O_RDWR or O_CREAT, &600);
  if FDescriptor < 0 then
    raise ELWPTError.CreateFmt(
      'could not open build session owner guard %s', [FPath]);
  if FpFcntl(FDescriptor, F_SETFD, FD_CLOEXEC_LWPT) <> 0 then
  begin
    FpClose(FDescriptor);
    FDescriptor := -1;
    raise ELWPTError.CreateFmt(
      'could not protect build session owner guard from inheritance %s',
      [FPath]);
  end;
  FillChar(LockSpec, SizeOf(LockSpec), 0);
  LockSpec.l_type := F_WRLCK_LWPT;
  LockSpec.l_whence := SEEK_SET;
  LockSpec.l_start := 0;
  LockSpec.l_len := 1;
  if FpFcntl(FDescriptor, F_SetLk, LockSpec) <> 0 then
  begin
    FpClose(FDescriptor);
    FDescriptor := -1;
    raise ELWPTError.CreateFmt(
      'build session owner guard is already held %s', [FPath]);
  end;
  FLocked := True;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := Windows.CreateFileW(PWideChar(UnicodeString(FPath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE,
    nil, Windows.OPEN_ALWAYS, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
    raise ELWPTError.CreateFmt(
      'could not open build session owner guard %s', [FPath]);
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  if not Windows.LockFileEx(FHandle,
    LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
    0, 1, 0, Overlapped) then
  begin
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
    raise ELWPTError.CreateFmt(
      'build session owner guard is already held %s', [FPath]);
  end;
  FLocked := True;
  {$ENDIF}
end;

destructor TLWPTSessionOwnerGuard.Destroy;
{$IFDEF UNIX}
var
  LockSpec: TLWPTFlock;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Overlapped: TOverlapped;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if FDescriptor >= 0 then
  begin
    if FLocked then
    begin
      FillChar(LockSpec, SizeOf(LockSpec), 0);
      LockSpec.l_type := F_UNLCK_LWPT;
      LockSpec.l_whence := SEEK_SET;
      LockSpec.l_start := 0;
      LockSpec.l_len := 1;
      FpFcntl(FDescriptor, F_SetLk, LockSpec);
    end;
    FpClose(FDescriptor);
    FDescriptor := -1;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FHandle <> THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    if FLocked then
    begin
      FillChar(Overlapped, SizeOf(Overlapped), 0);
      Windows.UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
    end;
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  end;
  {$ENDIF}
  FLocked := False;
  inherited Destroy;
end;

function SessionOwnerGuardHeld(const APath: string): Boolean;
{$IFDEF UNIX}
var
  Descriptor: LongInt;
  ErrorCode: Integer;
  LockSpec: TLWPTFlock;
begin
  Descriptor := FpOpen(PChar(APath), O_RDWR);
  if Descriptor < 0 then
  begin
    ErrorCode := FpGetErrNo;
    Exit(ErrorCode <> ESysENOENT);
  end;
  try
    FillChar(LockSpec, SizeOf(LockSpec), 0);
    LockSpec.l_type := F_WRLCK_LWPT;
    LockSpec.l_whence := SEEK_SET;
    LockSpec.l_start := 0;
    LockSpec.l_len := 1;
    if FpFcntl(Descriptor, F_SetLk, LockSpec) = 0 then
    begin
      LockSpec.l_type := F_UNLCK_LWPT;
      FpFcntl(Descriptor, F_SetLk, LockSpec);
      Exit(False);
    end;
    Result := True;
  finally
    FpClose(Descriptor);
  end;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  Overlapped: TOverlapped;
  ErrorCode: DWORD;
begin
  Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE,
    nil, Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    ErrorCode := Windows.GetLastError;
    Exit(not (ErrorCode in
      [Windows.ERROR_FILE_NOT_FOUND, Windows.ERROR_PATH_NOT_FOUND]));
  end;
  try
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    if Windows.LockFileEx(Handle,
      LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
      0, 1, 0, Overlapped) then
    begin
      Windows.UnlockFileEx(Handle, 0, 1, 0, Overlapped);
      Exit(False);
    end;
    Result := True;
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

constructor TLWPTPublicationLock.Create(const APath: string);
var
  Started: TDateTime;
  PIDLine: AnsiString;
  Acquired: Boolean;
  i: Integer;
  {$IFDEF UNIX}
  LockSpec: TLWPTFlock;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Written: DWORD;
  Overlapped: TOverlapped;
  {$ENDIF}
begin
  inherited Create;
  FPath := APath;
  FCriticalSectionIndex := 0;
  for i := 1 to Length(FPath) do
    FCriticalSectionIndex :=
      (FCriticalSectionIndex * 33 + Ord(FPath[i]))
      mod Length(PublicationCriticalSections);
  FCriticalSectionEntered := False;
  {$IFDEF UNIX}
  FDescriptor := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  {$ENDIF}
  EnterCriticalSection(
    PublicationCriticalSections[FCriticalSectionIndex]);
  FCriticalSectionEntered := True;
  try
    ForceDirectories(ExtractFileDir(FPath));
    Started := Now;
    Acquired := False;
    {$IFDEF UNIX}
    FDescriptor := FpOpen(PChar(FPath), O_RDWR or O_CREAT, &644);
    if FDescriptor < 0 then
      raise EConcurrencyError.CreateFmt(
        'could not open build publication lock %s', [FPath]);
    FillChar(LockSpec, SizeOf(LockSpec), 0);
    LockSpec.l_type := F_WRLCK_LWPT;
    LockSpec.l_whence := SEEK_SET;
    LockSpec.l_start := 0;
    LockSpec.l_len := 1;
    repeat
      Acquired := FpFcntl(FDescriptor, F_SetLk, LockSpec) = 0;
      if Acquired then Break;
      Sleep(10);
    until MilliSecondsBetween(Now, Started) >=
      PUBLICATION_LOCK_WAIT_MILLISECONDS;
    if not Acquired then
      raise EConcurrencyError.CreateFmt(
        'timed out waiting for build publication lock %s', [FPath]);
    FpLseek(FDescriptor, 0, SEEK_SET);
    PIDLine := AnsiString(IntToStr(GetProcessID)) + AnsiChar(#10);
    if Length(PIDLine) > 0 then
      FpWrite(FDescriptor, PIDLine[1], Length(PIDLine));
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle := Windows.CreateFileW(PWideChar(UnicodeString(FPath)),
      Windows.GENERIC_READ or Windows.GENERIC_WRITE,
      Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE, nil,
      Windows.OPEN_ALWAYS, Windows.FILE_ATTRIBUTE_NORMAL, 0);
    if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
      raise EConcurrencyError.CreateFmt(
        'could not open build publication lock %s', [FPath]);
    repeat
      FillChar(Overlapped, SizeOf(Overlapped), 0);
      Acquired := Windows.LockFileEx(FHandle,
        LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
        0, 1, 0, Overlapped);
      if Acquired then Break;
      Sleep(10);
    until MilliSecondsBetween(Now, Started) >=
      PUBLICATION_LOCK_WAIT_MILLISECONDS;
    if not Acquired then
      raise EConcurrencyError.CreateFmt(
        'timed out waiting for build publication lock %s', [FPath]);
    Windows.SetFilePointer(FHandle, 0, nil, Windows.FILE_BEGIN);
    PIDLine := AnsiString(IntToStr(GetProcessID)) + AnsiChar(#10);
    if Length(PIDLine) > 0 then
      Windows.WriteFile(FHandle, PIDLine[1], Length(PIDLine), Written, nil);
    Windows.SetEndOfFile(FHandle);
    {$ENDIF}
  except
    {$IFDEF UNIX}
    if FDescriptor >= 0 then
    begin
      FpClose(FDescriptor);
      FDescriptor := -1;
    end;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    if FHandle <> THandle(Windows.INVALID_HANDLE_VALUE) then
    begin
      Windows.CloseHandle(FHandle);
      FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
    end;
    {$ENDIF}
    LeaveCriticalSection(
      PublicationCriticalSections[FCriticalSectionIndex]);
    FCriticalSectionEntered := False;
    raise;
  end;
end;

destructor TLWPTPublicationLock.Destroy;
{$IFDEF UNIX}
var
  LockSpec: TLWPTFlock;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Overlapped: TOverlapped;
{$ENDIF}
begin
  {$IFDEF UNIX}
  if FDescriptor >= 0 then
  begin
    FillChar(LockSpec, SizeOf(LockSpec), 0);
    LockSpec.l_type := F_UNLCK_LWPT;
    LockSpec.l_whence := SEEK_SET;
    LockSpec.l_start := 0;
    LockSpec.l_len := 1;
    FpFcntl(FDescriptor, F_SetLk, LockSpec);
    FpClose(FDescriptor);
    FDescriptor := -1;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if FHandle <> THandle(Windows.INVALID_HANDLE_VALUE) then
  begin
    FillChar(Overlapped, SizeOf(Overlapped), 0);
    Windows.UnlockFileEx(FHandle, 0, 1, 0, Overlapped);
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  end;
  {$ENDIF}
  if FCriticalSectionEntered then
  begin
    LeaveCriticalSection(
      PublicationCriticalSections[FCriticalSectionIndex]);
    FCriticalSectionEntered := False;
  end;
  inherited Destroy;
end;

{ Publication lock files are stable names for advisory byte-range locks.
  The operating system releases ownership when the handle closes or the
  process exits; the files themselves remain and are safe to reuse. }

function EncodeBase36(AValue: QWord): string;
const
  DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz';
begin
  if AValue = 0 then Exit('0');
  Result := '';
  while AValue > 0 do
  begin
    Result := DIGITS[(AValue mod 36) + 1] + Result;
    AValue := AValue div 36;
  end;
end;

function SessionTimestamp: string;
begin
  { Base36 milliseconds keep the slug short: session directory names are a
    fixed prefix of every compiler-written staging path, and each saved
    character is headroom under COMPILER_PATH_LIMIT. }
  Result := EncodeBase36(QWord(Round(Now * MSecsPerDay)));
end;

function SessionOwnerGuardPath(const ASessionsRoot,
  ASessionID: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ASessionsRoot)
    + 'locks/owners/' + ASessionID + '.lock';
end;

constructor TLWPTBuildSession.Create(const AProjectRoot: string);
var
  BaseRoot, PendingRoot: string;
  CollisionCounter: Integer;
  InvocationCounter: QWord;
begin
  inherited Create;
  FProjectRoot := ExpandFileName(AProjectRoot);
  FSessionOwnerGuardPath := '';
  FSessionOwnerGuard := nil;
  BaseRoot := RootedPath(FProjectRoot, BUILD_SESSIONS_DIR);
  if not EnsureDirectory(BaseRoot) then
    raise ELWPTError.CreateFmt(
      'could not create build sessions directory %s', [BaseRoot]);
  Inc(NextSessionCounter);
  InvocationCounter := NextSessionCounter;
  CollisionCounter := 0;
  repeat
    { Compact form: the session slug prefixes every compiler staging path,
      so base36 PID + timestamp keep it well inside COMPILER_PATH_LIMIT
      even for deeply nested project roots. }
    FSessionID := 's-' + EncodeBase36(QWord(GetProcessID)) + '-'
      + SessionTimestamp + '-' + UIntToStr(InvocationCounter) + '-'
      + IntToStr(CollisionCounter);
    FSessionRoot := IncludeTrailingPathDelimiter(BaseRoot) + FSessionID;
    PendingRoot := IncludeTrailingPathDelimiter(BaseRoot) + '.creating-'
      + FSessionID;
    Inc(CollisionCounter);
  until (not DirectoryExists(FSessionRoot))
    and (not DirectoryExists(PendingRoot));
  if not EnsureDirectory(PendingRoot) then
    raise ELWPTError.CreateFmt(
      'could not create build session directory %s', [PendingRoot]);
  FFinished := False;
  FSessionRoot := PendingRoot;
  FSessionOwnerGuardPath := SessionOwnerGuardPath(BaseRoot, FSessionID);
  try
    FSessionOwnerGuard := TLWPTSessionOwnerGuard.Create(
      FSessionOwnerGuardPath);
    WriteState('active');
    if not SysUtils.RenameFile(PendingRoot,
      IncludeTrailingPathDelimiter(BaseRoot) + FSessionID) then
      raise ELWPTError.CreateFmt(
        'could not publish build session directory %s', [FSessionID]);
    FSessionRoot := IncludeTrailingPathDelimiter(BaseRoot) + FSessionID;
  except
    FreeAndNil(FSessionOwnerGuard);
    if FileExists(FSessionOwnerGuardPath) then
      SysUtils.DeleteFile(FSessionOwnerGuardPath);
    if DirectoryExists(PendingRoot) then WipeDir(PendingRoot);
    if DirectoryExists(IncludeTrailingPathDelimiter(BaseRoot) + FSessionID) then
      WipeDir(IncludeTrailingPathDelimiter(BaseRoot) + FSessionID);
    raise;
  end;
end;

destructor TLWPTBuildSession.Destroy;
begin
  if not FFinished then
    try
      Finish(False, 'process exited without completing the session');
    except
      { Destruction must not hide the command error that caused the
        session to be retained. Repair can still reclaim the directory. }
    end;
  FSessionOwnerGuard.Free;
  inherited Destroy;
end;

procedure TLWPTBuildSession.WriteState(const AState: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add(IntToStr(GetProcessID));
    Lines.Add(AState);
    Lines.Add(IntToStr(BUILD_SESSION_SCHEMA_VERSION));
    AtomicWriteText(FSessionRoot + '/session.state', FSessionRoot, Lines);
  finally
    Lines.Free;
  end;
end;

function TLWPTBuildSession.JobRoot(const AName: string): string;
begin
  Result := FSessionRoot + '/jobs/' + BuildSessionPathKey(AName);
  ForceDirectories(Result);
end;

function TLWPTBuildSession.JobLogPath(const AName: string): string;
begin
  Result := FSessionRoot + ObservabilityLogsDirectory
    + BuildSessionPathKey(AName) + ObservabilityLogExtension;
end;

function TLWPTBuildSession.JobLogReference(const AName: string): string;
begin
  Result := SessionReference + ObservabilityLogsDirectory
    + BuildSessionPathKey(AName) + ObservabilityLogExtension;
end;

function TLWPTBuildSession.HookRoot: string;
begin
  Result := FSessionRoot + '/hooks';
  ForceDirectories(Result);
end;

function TLWPTBuildSession.SessionReference: string;
begin
  Result := BUILD_SESSIONS_DIR + '/' + FSessionID;
end;

procedure TLWPTBuildSession.WriteJobLog(const AName, AOutput: string);
var
  LogPath: string;
  Bytes: TBytes;
begin
  LogPath := JobLogPath(AName);
  if not ForceDirectories(ExtractFileDir(LogPath)) then
    raise ELWPTError.CreateFmt('could not create session log directory %s',
      [ExtractFileDir(LogPath)]);
  { Committed-path write goes through the atomic helper (staged under the
    session root, atomic rename) — never a raw TFileStream — so an
    interrupted write cannot leave a truncated log behind JobLogReference.
    Byte-exact copy: the captured output must not be re-encoded. }
  SetLength(Bytes, Length(AOutput));
  if Length(AOutput) > 0 then
    Move(AOutput[1], Bytes[0], Length(AOutput));
  AtomicWriteBytes(LogPath, FSessionRoot, Bytes);
end;

procedure TLWPTBuildSession.Finish(ASuccess: Boolean; const ADetail: string);
var
  HasLogs: Boolean;
  Lines: TStringList;
begin
  if FFinished then Exit;
  if ASuccess then
  begin
    { The guard lives beside session directories, so it remains observable
      while private compiler and hook staging is removed on every platform.
      Stable job logs remain until lwpt repair reclaims the completed session. }
    HasLogs := DirectoryExists(FSessionRoot + ObservabilityLogsDirectory);
    WriteState('completing');
    if HasLogs then
    begin
      if DirectoryExists(FSessionRoot + '/jobs') then
        WipeDir(FSessionRoot + '/jobs');
      if DirectoryExists(FSessionRoot + '/hooks') then
        WipeDir(FSessionRoot + '/hooks');
      WriteState('completed');
    end
    else
      WipeDir(FSessionRoot);
    FreeAndNil(FSessionOwnerGuard);
    if FileExists(FSessionOwnerGuardPath)
      and (not SysUtils.DeleteFile(FSessionOwnerGuardPath)) then
      raise ELWPTError.CreateFmt(
        'could not remove build session owner guard %s',
        [FSessionOwnerGuardPath]);
    FFinished := True;
    Exit;
  end;
  if ADetail <> '' then
  begin
    Lines := TStringList.Create;
    try
      Lines.Add(ADetail);
      AtomicWriteText(FSessionRoot + '/failure.txt', FSessionRoot, Lines);
    finally
      Lines.Free;
    end;
  end;
  WriteState('failed');
  FreeAndNil(FSessionOwnerGuard);
  FFinished := True;
end;

function BuildPublicationLockPath(const AProjectRoot, AOutput: string): string;
var
  OutputIdentity, ParentPath, ParentIdentity, OutputName: string;
begin
  OutputIdentity := ExpandFileName(AOutput);
  ParentPath := ExtractFileDir(OutputIdentity);
  if (ParentPath <> '') and (not EnsureDirectory(ParentPath)) then
    raise ELWPTError.CreateFmt(
      'could not create build output directory %s', [ParentPath]);
  ParentIdentity := DirectoryIdentity(ParentPath);
  if ParentIdentity = '' then ParentIdentity := ExpandFileName(ParentPath);
  OutputName := ExtractFileName(OutputIdentity);
  {$IFDEF MSWINDOWS}
  OutputName := LowerCase(OutputName);
  {$ENDIF}
  {$IFDEF DARWIN}
  OutputName := LowerCase(OutputName);
  {$ENDIF}
  Result := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR)
    + '/locks/' + Copy(TextHash(ParentIdentity + '/' + OutputName),
      8, 64) + '.lock';
end;

function PublishBuildArtifact(const AProjectRoot, ACandidatePath,
  ADestinationPath, AExpectedFingerprint, AManifestPath, ACfgPath,
  ALockPath, AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest):
  TLWPTBuildPublicationResult;
var
  Lock: TLWPTPublicationLock;
  CurrentFingerprint: string;
  Destination: string;
begin
  Destination := RootedPath(AProjectRoot, ADestinationPath);
  Lock := TLWPTPublicationLock.Create(
    BuildPublicationLockPath(AProjectRoot, Destination));
  try
    try
      CurrentFingerprint := CaptureBuildPublicationFingerprint(
        AProjectRoot, AManifestPath, ACfgPath, ALockPath, AModulesPath,
        ARequest);
    except
      on ELWPTParsedManifestChanged do Exit(bprStale);
    end;
    if CurrentFingerprint <> AExpectedFingerprint then
      Exit(bprStale);
    if not AtomicReplaceFile(ACandidatePath, Destination) then
      raise ELWPTError.CreateFmt(
        'could not atomically publish "%s" to "%s"; the completed '
        + 'candidate remains private', [ACandidatePath, Destination]);
    Result := bprPublished;
  finally
    Lock.Free;
  end;
end;

procedure RepairBuildSessions(const AProjectRoot: string;
  out ARemoved, ARetained: Integer);
var
  Root, SessionPath, SessionID, StatePath, AgePath, OwnerPath: string;
  Search: TSearchRec;
  PID: LongInt;
  State: string;
  OwnerHeld: Boolean;

  procedure ReclaimSessionPattern(const APattern: string);
  begin
    if SysUtils.FindFirst(Root + '/' + APattern, faAnyFile, Search) <> 0 then
      Exit;
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        if (Search.Attr and faDirectory) = 0 then Continue;
        SessionPath := Root + '/' + Search.Name;
        SessionID := Search.Name;
        if Copy(SessionID, 1, Length('.creating-')) = '.creating-' then
          Delete(SessionID, 1, Length('.creating-'));
        OwnerPath := SessionOwnerGuardPath(Root, SessionID);
        StatePath := SessionPath + '/session.state';
        PID := ReadPID(StatePath);
        State := ReadSessionState(StatePath);
        OwnerHeld := SessionOwnerGuardHeld(OwnerPath);
        if FileExists(StatePath) then AgePath := StatePath
        else AgePath := SessionPath;
        if OwnerHeld then
          Inc(ARetained)
        else if (State <> 'failed')
          and (not IncompleteStateIsAbandoned(AgePath))
          and ((State = '') or ProcessIsAlive(PID)) then
          Inc(ARetained)
        else
        begin
          WipeDir(SessionPath);
          if FileExists(OwnerPath) then SysUtils.DeleteFile(OwnerPath);
          Inc(ARemoved);
        end;
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
  end;
begin
  ARemoved := 0;
  ARetained := 0;
  Root := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR);
  if not DirectoryExists(Root) then Exit;
  ReclaimSessionPattern('s-*');
  { A process can crash between creating and publishing its visible
    session directory. The hidden creating form has the same state
    record, so repair can retain its live owner or reclaim the orphan. }
  ReclaimSessionPattern('.creating-s-*');
  { Sessions left behind by binaries that used the long pre-compaction
    slug ('session-<pid>-<datetime>-...') remain reclaimable. }
  ReclaimSessionPattern('session-*');
  ReclaimSessionPattern('.creating-session-*');
end;

var
  CriticalSectionIndex: Integer;

initialization
  for CriticalSectionIndex := Low(PublicationCriticalSections)
    to High(PublicationCriticalSections) do
    InitCriticalSection(PublicationCriticalSections[CriticalSectionIndex]);

finalization
  for CriticalSectionIndex := Low(PublicationCriticalSections)
    to High(PublicationCriticalSections) do
    DoneCriticalSection(PublicationCriticalSections[CriticalSectionIndex]);

end.
