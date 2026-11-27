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
  BUILD_PUBLICATION_FINGERPRINT_SCHEMA_VERSION = 2;
  BUILD_CACHE_FINGERPRINT_SCHEMA_VERSION = 3;
  BUILD_CACHE_OPERATION_BUILD_ENTRY = 'build-entry';
  BUILD_CACHE_OPERATION_TEST_PROGRAM = 'test-program';
  BUILD_SESSIONS_DIR = LWPT_DIR + '/sessions';
  BUILD_SESSION_DIR_ENV = PROJECT_NAME + '_SESSION_DIR';
  BUILD_SESSION_ROOT_LEDGER = LWPT_DIR + '/session-roots';
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
    CompilerArguments: TStringArray;
    ManifestContentHash: string;
    PublicOutput: string;
    Environment: TStringArray;
    CompilerImplicitInputs: TStringArray;
    WorkspacePaths: TStringArray;
    PrerequisiteOutputs: TStringArray;
    HookDefinition: TStringArray;
    HookInputs: TStringArray;
    ExcludedPaths: TStringArray;
  end;

  TLWPTBuildPublicationResult = (bprPublished, bprStale);

  { Raised by CaptureBuildCacheFingerprint when the compile's arguments may
    make the compiler read inputs that no fixed path holds, so a reusable
    result cannot be addressed. }
  ELWPTUnboundedCompilerInputs = class(ELWPTError);

  { Compiler-input content at one moment: each distinct path once, with the
    content the build cache fingerprint would hash for it. Contents[i]
    belongs to Paths[i]. }
  TLWPTInputSnapshot = record
    Paths: TStringArray;
    Contents: TStringArray;
  end;

  TLWPTBuildSession = class
  private
    FProjectRoot: string;
    FSessionsRoot: string;
    FDefaultSessionsRoot: Boolean;
    FSessionID: string;
    FSessionRoot: string;
    FSessionOwnerGuardPath: string;
    FSessionOwnerGuard: TObject;
    FFinished: Boolean;
    FProgramJobs: TStringList;
    FProjectIdentity: string;
    FCleanupWarnings: TStringList;
    function JobLogPath(const AName: string): string;
    procedure WriteState(const AState: string);
    procedure PruneSupersededJobs;
    procedure ReleaseOwnerGuard;
  public
    constructor Create(const AProjectRoot: string); overload;
    constructor Create(const AProjectRoot, ASessionsRoot: string); overload;
    destructor Destroy; override;
    { One build job's private staging. A later session that stages the same
      job supersedes the whole directory. }
    function JobRoot(const AName: string): string;
    { A job root holding one directory per program (test programs). A later
      session supersedes each program directory on its own, so a run of
      selected programs leaves the others' staging alone. Call it from the
      thread that owns the session, before workers start. }
    function ProgramJobsRoot(const AName: string): string;
    function JobLogReference(const AName: string): string;
    function SessionReference: string;
    procedure WriteJobLog(const AName, AOutput: string);
    procedure Finish(ASuccess: Boolean; const ADetail: string = '');
    { Superseded staging this session could not remove when it finished,
      one line each, for the command to report. Empty on a clean sweep. }
    property CleanupWarnings: TStringList read FCleanupWarnings;
    property SessionID: string read FSessionID;
    property SessionRoot: string read FSessionRoot;
    property SessionsRoot: string read FSessionsRoot;
  end;

function ResolveBuildSessionsRoot(const AProjectRoot,
  AManifestSessionsDir, AEnvironmentBase: string): string;
function BuildSessionsProjectRoot(const AProjectRoot,
  AConfiguredRoot: string): string;

function CaptureBuildPublicationFingerprint(
  const AProjectRoot, AManifestPath, ACfgPath, ALockPath,
  AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest): string;
function CaptureBuildCacheFingerprint(
  const AProjectRoot, AManifestPath, ACfgPath, ALockPath,
  AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest;
  const AOperation: string = BUILD_CACHE_OPERATION_BUILD_ENTRY): string;
function NeutralBuildCacheRequest(const ARequest: TLWPTBuildRequest;
  const APublicOutput: string): TLWPTBuildRequest;
{ Fingerprint each distinct path in APaths once, walking directories with the
  build cache's walk and AExcludedPaths. Relative paths resolve against
  AProjectRoot. A file that cannot be read is recorded by its size and time
  instead of failing the capture. }
function CaptureInputSnapshot(const AProjectRoot: string;
  const APaths, AExcludedPaths: TStringArray): TLWPTInputSnapshot;
{ Fingerprint ASnapshot's paths again and return the first one whose content
  differs, or '' when every path still matches. }
function FirstChangedInput(const AProjectRoot: string;
  const ASnapshot: TLWPTInputSnapshot;
  const AExcludedPaths: TStringArray): string;
{ Read the file at APath (relative paths resolve against AProjectRoot) once,
  without blocking, and return the state an input snapshot records for it,
  with the bytes that state describes in AContent: 'missing' and no content
  when nothing or a directory is there. Raises ELWPTError when the path is
  another kind of special file or cannot be read. }
function CaptureInputFile(const AProjectRoot, APath: string;
  out AContent: string): string;
{ The state ASnapshot recorded for APath, or '' when it has no such path. }
function InputSnapshotState(const AProjectRoot: string;
  const ASnapshot: TLWPTInputSnapshot; const APath: string): string;
function BuildSessionPathKey(const AValue: string): string;
procedure AppendUnitDirsFromOptions(const AOptions: TStrings;
  var ADirs: TStringArray);
procedure AppendUnitDirsFromCfg(const ACfgPath: string;
  var ADirs: TStringArray);
{ Appends the directories that the unit, include, object and library search
  options among AOptions (-Fu, -Fi, -Fo, -Fl, -I) can make the compiler
  read, resolved as FPC 3.2 resolves them. An option lists entries separated
  by ";", and outside Windows also by ":". An entry may be Pascal-quoted. A
  leading "=" names a path below the sysroot, which -XR sets for -Fl and
  which is empty for every other option. Macros are replaced first, as
  ExpandSearchMacros describes. A "*" wildcard, and an $FPC* macro whose
  value only the compiler knows, make an entry add its fixed leading
  directory, which holds every directory it can resolve to unless a ".."
  follows. An "=" entry of -Fl adds one
  directory per -XR value in AOptions and one without a sysroot, because the
  sysroot that applies depends on option order. An empty entry names the
  current directory, which this adds nothing for. }
procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray); overload;
{ The same, also naming in AUnbounded (when it is '') the first option with
  an entry whose fixed leading directory may not hold what it resolves to:
  a ".." after a wildcard or an $FPC* macro. }
procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray; var AUnbounded: string); overload;
{ Appends what AArguments make the compiler read through its options: each
  option file that an "@file" argument names and each file those include,
  and the directories that AppendCompilerSearchDirectories finds among the
  options, those of the files read included. Files are read as FPC 3.2's
  Interpret_file reads them: one option per line, spaces, tabs and commas
  around it removed; ";" lines are comments; "#INCLUDE <file>" reads another
  file and "#CFGDIR <dirs>" adds directories to look for such files in
  first, both after macro expansion; and the lines of every #IFDEF branch
  count, since any of them may apply. A file FPC looks for in #CFGDIR
  directories appends every place it may be found and reads each one that
  exists, since the branches decide which #CFGDIR lines applied. Relative
  paths resolve against AProjectRoot. A file is read without blocking,
  once, and one that is not a regular file or cannot be read names nothing
  more. }
procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string; var APaths: TStringArray); overload;
{ The same, also appending each option file it read to AReadFiles and the
  state CaptureInputFile gave it to AReadStates, '' where that read failed
  or met a file that is not regular. }
procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string;
  var APaths, AReadFiles, AReadStates: TStringArray); overload;
{ The same, also naming in AUnbounded (when it is '') the first argument,
  option or directive that may make the compiler read beyond APaths: a
  ".." after a wildcard or an $FPC* macro, an option file named through an
  $FPC* macro, a #CFGDIR entry with a wildcard or such a macro, a macro
  expansion that reached its bound, or option files nested past FPC's
  limit. }
procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string;
  var APaths, AReadFiles, AReadStates: TStringArray;
  var AUnbounded: string); overload;
{ True when ARecorded, the state an input snapshot or fingerprint recorded
  for a file, still describes ACaptured, the state CaptureInputFile gave it
  ('' when that read failed). }
function InputStateMatchesCapture(const ARecorded,
  ACaptured: string): Boolean;
function LongestCompiledBaseNameLength(const ADirectories: TStringArray;
  const AEntrySource: string): Integer;
procedure EnsureCompilerPathBudget(const AUnitDirectory,
  AExecutableDirectory: string; ALongestBaseNameLength: Integer);
function BuildPublicationLockPath(const ASessionsRoot, AOutput: string): string;
{ The identity of the file at AOutput that every spelling of it shares: its
  parent directory's filesystem identity and its name, folded to lower case
  where the filesystem usually ignores case. Creates the parent directory,
  so the identity stays the same once the file exists. }
function BuildOutputIdentity(const AOutput: string): string;
{ Take the project's build-coordination lock, the session-root ledger lock
  that every build's publication already shares across processes, threads
  and relocated session roots, for a short project-wide critical section.
  Free the result to release it. }
function AcquireBuildCoordinationLock(const AProjectRoot: string): TObject;
{ The primitives behind build sessions, for other per-project coordination
  state. AcquireOwnerGuard creates APath and holds it under a
  non-inherited operating-system lock (fcntl on Unix, LockFileEx on Windows)
  until the result is freed or the process exits; it raises when the guard
  cannot be taken. OwnerGuardHeld probes another process's guard: it opens
  and closes APath, so a process must never probe a guard it holds itself.
  AcquireShortLock takes the advisory lock at APath for a short critical
  section, waiting at most as long as a build publication does, and raises
  EConcurrencyError when that wait runs out or when APath is a link, which
  it never opens through. Free its result to release it. }
function AcquireOwnerGuard(const APath, ADescription: string): TObject;
function OwnerGuardHeld(const APath: string): Boolean;
function AcquireShortLock(const APath: string): TObject;
{$IFDEF OBJECTSTORE_TESTING}
type
  TLWPTSessionFinishTestHook = procedure(const ASessionRoot: string);
  TLWPTOptionFileReadTestHook = procedure(const APath: string);

var
  { Test-only: called by a failing Finish while it still holds the
    build-coordination lock, after its terminal state and owner guard are
    settled. Production code must leave it nil. }
  SessionFinishBeforeCoordinationReleaseTestHook: TLWPTSessionFinishTestHook;
  { Test-only: called by AppendCompilerArgumentInputs right after it reads
    an option file, with the path it read. Production code must leave it
    nil. }
  OptionFileReadTestHook: TLWPTOptionFileReadTestHook;

{$ENDIF}
function PublishBuildArtifact(const AProjectRoot, ACandidatePath,
  ADestinationPath, AExpectedFingerprint, AManifestPath, ACfgPath,
  ALockPath, AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest;
  const ASessionsRoot: string = ''):
  TLWPTBuildPublicationResult;
procedure RepairBuildSessions(const AProjectRoot: string;
  out ARemoved, ARetained: Integer); overload;
procedure RepairBuildSessions(const AProjectRoot, ATemporaryRoot: string;
  out ARemoved, ARetained: Integer;
  out ATemporaryRootCleaned: Boolean); overload;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  Unix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  contnrs,
  DateUtils;

const
  PUBLICATION_LOCK_WAIT_MILLISECONDS = 30000;
  SESSION_PARTIAL_GRACE_MILLISECONDS = 5000;
  SESSION_ROOT_LEDGER_SCHEMA_VERSION = 1;
  SESSION_ROOT_IDENTITY_SCHEMA_VERSION = 2;
  SESSION_ROOT_IDENTITY_FILE = 'project.identity';
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  F_WRLCK_LWPT = 1;
  F_UNLCK_LWPT = 2;
  {$ELSE}
  F_WRLCK_LWPT = F_WRLCK;
  F_UNLCK_LWPT = F_UNLCK;
  {$ENDIF}
  {$ENDIF}
  {$IFDEF UNIX}
  { FPC's BaseUnix has no O_NOFOLLOW on Darwin; values as in
    LWPT.Registry.Filesystem. }
  {$IFDEF LINUX}
  {$IFDEF CPUAARCH64}
  O_NOFOLLOW_LWPT = $00008000;
  {$ELSE}
  O_NOFOLLOW_LWPT = $00020000;
  {$ENDIF}
  {$ELSE}
  {$IFDEF DARWIN}
  O_NOFOLLOW_LWPT = $00000100;
  {$ELSE}
  O_NOFOLLOW_LWPT = O_NOFOLLOW;
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  LOCKFILE_EXCLUSIVE_LOCK_LWPT = $00000002;
  LOCKFILE_FAIL_IMMEDIATELY_LWPT = $00000001;
  FILE_FLAG_OPEN_REPARSE_POINT_SESSION_LWPT = $00200000;
  {$ENDIF}

var
  NextSessionCounter: QWord;
  PublicationCriticalSections:
    array[0..63] of TRTLCriticalSection;
  { Sessions whose owner guard this process holds. Unix record locks belong
    to the process, so probing such a guard from the same process succeeds
    and closing the probe descriptor drops the owner's lock. The
    inactivity predicate consults this list instead of probing. }
  LiveSessionIDs: TStringList;
  LiveSessionCriticalSection: TRTLCriticalSection;

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
    FRefuseLinks: Boolean;
    FCriticalSectionIndex: Integer;
    FCriticalSectionEntered: Boolean;
    {$IFDEF UNIX}
    FDescriptor: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FHandle: THandle;
    {$ENDIF}
  public
    constructor Create(const APath: string;
      const ARefuseLinks: Boolean = False);
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
    constructor Create(const APath: string;
      const ADescription: string = 'build session owner guard');
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

function ResolveBuildSessionsRoot(const AProjectRoot,
  AManifestSessionsDir, AEnvironmentBase: string): string;
var
  EnvironmentValue: string;
begin
  EnvironmentValue := SysUtils.GetEnvironmentVariable(
    BUILD_SESSION_DIR_ENV);
  if EnvironmentValue <> '' then
    Exit(RootedPath(AEnvironmentBase, EnvironmentValue));
  if AManifestSessionsDir <> '' then
    Exit(RootedPath(AProjectRoot, AManifestSessionsDir));
  Result := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR);
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
    LoadProtectedStrings(Lines, ACfgPath);
    AppendUnitDirsFromOptions(Lines, ADirs);
  finally
    Lines.Free;
  end;
end;

const
  { Stands for a path segment that only the compiler can name: the value of
    an FPC macro such as $FPCTARGET. DEL is above the control characters
    that trimming an entry removes. }
  UNKNOWN_SEARCH_SEGMENT = #127;

{$IFDEF MSWINDOWS}
function SHGetFolderPathW(AWindow: HWND; AFolder: LongInt; AToken: THandle;
  AFlags: DWORD; APath: PWideChar): HRESULT; stdcall;
  external 'shell32.dll' name 'SHGetFolderPathW';
{$ENDIF}

{ FPC's Replace: every ANeedle in AText, compared without case, becomes
  AValue; text that AValue brings in is not searched again. }
procedure ReplaceSearchMacro(var AText: string; const ANeedle,
  AValue: string);
var
  Offset, Position: Integer;
begin
  Offset := 1;
  repeat
    Position := Pos(UpperCase(ANeedle), UpperCase(Copy(AText, Offset,
      MaxInt)));
    if Position = 0 then Exit;
    Position := Offset + Position - 1;
    Delete(AText, Position, Length(ANeedle));
    Insert(AValue, AText, Position);
    Offset := Position + Length(AValue);
  until False;
end;

{ FPC 3.2's DefaultReplacements (compiler/globals.pas), which the compiler
  applies to search options, -XR, #INCLUDE and #CFGDIR. Its $FPC* macros
  name a version, date, CPU, OS, target, subarchitecture, ABI or memory
  model: each becomes UNKNOWN_SEARCH_SEGMENT, a relative part of the path.
  On Windows its special-folder macros become those folders, and on OpenBSD
  its base macros become their directories. Then each "$NAME$" whose
  environment variable is set, even to nothing, becomes its value, from the
  left, until a name is not set; the compiler inherits this environment.
  AExhausted becomes True when the expansion stopped at its bound with a
  variable still to replace, so what the compiler reads is not known. }
function ExpandSearchMacros(const AValue: string;
  var AExhausted: Boolean): string;
const
  SEGMENT_MACROS: array[0..8] of string = ('$FPCVERSION', '$FPCFULLVERSION',
    '$FPCDATE', '$FPCCPU', '$FPCOS', '$FPCTARGET', '$FPCSUBARCH', '$FPCABI',
    '$FPCMEMORYMODEL');
  { A value that names itself cannot expand for good. }
  MAXIMUM_ENVIRONMENT_EXPANSIONS = 64;
  {$IFDEF MSWINDOWS}
  CSIDL_FLAG_DONT_VERIFY = $4000;
  SPECIAL_FOLDER_NAMES: array[0..6] of string = ('$LOCAL_APPDATA',
    '$APPDATA', '$COMMON_APPDATA', '$PERSONAL', '$PROGRAM_FILES',
    '$PROGRAM_FILES_COMMON', '$PROFILE');
  SPECIAL_FOLDER_IDS: array[0..6] of LongInt = ($1C, $1A, $23, $05, $26,
    $2B, $28);

  { The folder FPC's GetWindowsSpecialDir names, without creating it. }
  function SpecialFolder(const AID: LongInt): string;
  var
    Buffer: array[0..Windows.MAX_PATH] of WideChar;
  begin
    Result := '';
    FillChar(Buffer, SizeOf(Buffer), 0);
    if SHGetFolderPathW(0, AID or CSIDL_FLAG_DONT_VERIFY, 0, 0,
         @Buffer[0]) = 0 then
      Result := IncludeTrailingPathDelimiter(
        UTF8Encode(UnicodeString(PWideChar(@Buffer[0]))));
  end;
  {$ENDIF}
  {$IFDEF OPENBSD}

  function EnvironmentOr(const AName, ADefault: string): string;
  begin
    Result := GetEnvironmentVariable(AName);
    if Result = '' then Result := ADefault;
  end;
  {$ENDIF}

  { FPC's GetEnvPChar: a variable that is set, empty or not, has a value;
    on Windows its name is compared without case. }
  function EnvironmentValue(const AName: string; out AFound: string): Boolean;
  var
    Entry: string;
    Index: Integer;
  begin
    AFound := '';
    Result := False;
    if AName = '' then Exit;
    for Index := 1 to GetEnvironmentVariableCount do
    begin
      Entry := GetEnvironmentString(Index);
      {$IFDEF MSWINDOWS}
      if SameText(Copy(Entry, 1, Length(AName) + 1), AName + '=') then
      {$ELSE}
      if Copy(Entry, 1, Length(AName) + 1) = AName + '=' then
      {$ENDIF}
      begin
        AFound := Copy(Entry, Length(AName) + 2, MaxInt);
        Exit(True);
      end;
    end;
  end;

var
  Expansions, i, Position: Integer;
  Name, Value: string;
begin
  Result := AValue;
  for i := 0 to High(SEGMENT_MACROS) do
    ReplaceSearchMacro(Result, SEGMENT_MACROS[i], UNKNOWN_SEARCH_SEGMENT);
  {$IFDEF MSWINDOWS}
  for i := 0 to High(SPECIAL_FOLDER_NAMES) do
    if Pos(SPECIAL_FOLDER_NAMES[i], Result) > 0 then
      ReplaceSearchMacro(Result, SPECIAL_FOLDER_NAMES[i],
        SpecialFolder(SPECIAL_FOLDER_IDS[i]));
  {$ENDIF}
  {$IFDEF OPENBSD}
  ReplaceSearchMacro(Result, '$OPENBSD_LOCALBASE',
    EnvironmentOr('LOCALBASE', '/usr/local'));
  ReplaceSearchMacro(Result, '$OPENBSD_X11BASE',
    EnvironmentOr('X11BASE', '/usr/X11R6'));
  {$ENDIF}
  Expansions := 0;
  Position := Pos('$', Result);
  while (Position > 0) and (Expansions < MAXIMUM_ENVIRONMENT_EXPANSIONS) do
  begin
    Name := Copy(Result, Position + 1, MaxInt);
    if Pos('$', Name) = 0 then Break;
    Name := Copy(Name, 1, Pos('$', Name) - 1);
    if not EnvironmentValue(Name, Value) then Break;
    ReplaceSearchMacro(Result, '$' + Name + '$', Value);
    Inc(Expansions);
    Position := Pos('$', Result);
  end;
  if Expansions >= MAXIMUM_ENVIRONMENT_EXPANSIONS then AExhausted := True;
end;

{ Appends the directories that one search option's value AEntries names,
  its macros already expanded. An entry with a wildcard or an unknown
  segment adds its fixed leading directory, which holds what it resolves
  to unless a ".." follows; then, or for any such entry when AExactOnly,
  AUnbounded becomes True instead, and with AExactOnly nothing is added. }
procedure AppendSearchEntries(const AEntries: string;
  const ALibrary, AExactOnly: Boolean; const ASysroots: TStringArray;
  var ADirectories: TStringArray; var AUnbounded: Boolean);

  procedure AddDirectory(APath: string);
  var
    Count, Position: Integer;
    Rest: string;
  begin
    for Position := 1 to Length(APath) do
      if APath[Position] in ['*', '?', '$', UNKNOWN_SEARCH_SEGMENT] then
      begin
        { FPC reads "\" as a separator on every platform. }
        Rest := '/' + StringReplace(Copy(APath, Position, MaxInt), '\', '/',
          [rfReplaceAll]) + '/';
        if AExactOnly or (Pos('/../', Rest) > 0) then
        begin
          AUnbounded := True;
          if AExactOnly then Exit;
        end;
        APath := Copy(APath, 1, Position - 1);
        while (APath <> '') and not (APath[Length(APath)] in ['/', '\']) do
          Delete(APath, Length(APath), 1);
        if APath = '' then APath := '.';
        Break;
      end;
    if APath = '' then Exit;
    Count := Length(ADirectories);
    SetLength(ADirectories, Count + 1);
    ADirectories[Count] := APath;
  end;

  { FPC's DePascalQuote: a leading ' starts a quoted entry in which ''
    stands for one quote; without its closing quote the entry stays as
    written. }
  function PascalUnquoted(const AEntry: string): string;
  var
    Position: Integer;
  begin
    Result := '';
    Position := 2;
    while Position <= Length(AEntry) do
    begin
      if AEntry[Position] = '''' then
      begin
        if (Position < Length(AEntry)) and (AEntry[Position + 1] = '''') then
          Inc(Position)
        else
          Exit;
      end;
      Result := Result + AEntry[Position];
      Inc(Position);
    end;
    Result := AEntry;
  end;

  procedure AddEntry(AEntry: string);
  var
    Bare: string;
    i: Integer;
  begin
    AEntry := Trim(AEntry);
    { A double-quoted entry reaches FPC as written, since no shell or
      response-file reader removes the quotes: watch both spellings. }
    if (Length(AEntry) >= 2) and (AEntry[1] = '"')
       and (AEntry[Length(AEntry)] = '"') then
      AddEntry(Copy(AEntry, 2, Length(AEntry) - 2))
    else if (AEntry <> '') and (AEntry[1] = '''') then
      AEntry := PascalUnquoted(AEntry);
    if (AEntry = '') or (AEntry[1] <> '=') then
    begin
      AddDirectory(AEntry);
      Exit;
    end;
    Bare := Copy(AEntry, 2, MaxInt);
    if ALibrary then
      for i := 0 to High(ASysroots) do AddDirectory(ASysroots[i] + Bare);
    AddDirectory(Bare);
  end;

var
  Position, StartAt: Integer;
begin
  StartAt := 1;
  for Position := 1 to Length(AEntries) + 1 do
    if (Position > Length(AEntries)) or (AEntries[Position] = ';')
       {$IFNDEF MSWINDOWS}or (AEntries[Position] = ':'){$ENDIF} then
    begin
      AddEntry(Copy(AEntries, StartAt, Position - StartAt));
      StartAt := Position + 1;
    end;
end;

procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray; var AUnbounded: string);
const
  SEARCH_OPTIONS: array[0..4] of string = ('-Fu', '-Fi', '-Fo', '-Fl', '-I');
  SYSROOT_OPTION = '-XR';
var
  Sysroots: TStringArray;
  Count, i, j: Integer;
  Option: string;
  Unbounded: Boolean;
begin
  SetLength(Sysroots, 0);
  for i := 0 to High(AOptions) do
  begin
    Option := Trim(AOptions[i]);
    if (Length(Option) > Length(SYSROOT_OPTION))
       and (Copy(Option, 1, Length(SYSROOT_OPTION)) = SYSROOT_OPTION) then
    begin
      Count := Length(Sysroots);
      SetLength(Sysroots, Count + 1);
      Unbounded := False;
      Sysroots[Count] := ExpandSearchMacros(
        Copy(Option, Length(SYSROOT_OPTION) + 1, MaxInt), Unbounded);
      if Unbounded and (AUnbounded = '') then
        AUnbounded := 'option "' + Option + '"';
    end;
  end;
  for i := 0 to High(AOptions) do
  begin
    Option := Trim(AOptions[i]);
    for j := 0 to High(SEARCH_OPTIONS) do
      if (Length(Option) > Length(SEARCH_OPTIONS[j]))
         and (Copy(Option, 1, Length(SEARCH_OPTIONS[j]))
           = SEARCH_OPTIONS[j]) then
      begin
        Unbounded := False;
        AppendSearchEntries(ExpandSearchMacros(Copy(Option,
          Length(SEARCH_OPTIONS[j]) + 1, MaxInt), Unbounded),
          SEARCH_OPTIONS[j] = '-Fl', False, Sysroots, ADirectories,
          Unbounded);
        if Unbounded and (AUnbounded = '') then
          AUnbounded := 'option "' + Option + '"';
        Break;
      end;
  end;
end;

procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray);
var
  Unbounded: string;
begin
  Unbounded := '';
  AppendCompilerSearchDirectories(AOptions, ADirectories, Unbounded);
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
  Handle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)), 0,
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

{ A file's content hash. The build cache lets an unreadable file fail its
  fingerprint (the cache then steps aside); a run-level input snapshot must
  not fail, so ASnapshot records such a file by its metadata. The compiler
  cannot read that file either, and a change to it still shows. Both open
  without blocking and hash only a regular file through the descriptor they
  classified, so a FIFO (even one swapped in after a check) never blocks
  them: another kind of file is recorded by its type and mode. ADigests
  reuses a file already hashed in this scan through an overlapping path. }
function InputFileContent(const APath: string; const ASnapshot: Boolean;
  const ADigests: TFPStringHashTable): string;

  function Metadata: string;
  var
    Info: TSearchRec;
  begin
    Result := 'unreadable';
    if SysUtils.FindFirst(APath, faAnyFile or faSymLink, Info) = 0 then
    try
      Result := Result + ':' + IntToStr(Info.Size) + ':'
        + IntToStr(Info.Time) + ':' + IntToStr(Info.Attr);
    finally
      SysUtils.FindClose(Info);
    end;
  end;

var
  Known: THTStringNode;
  {$IFDEF UNIX}
  Descriptor, ErrorNumber: LongInt;
  Status: BaseUnix.Stat;
  Stream: TLWPTProtectedFileStream;
  {$ENDIF}
begin
  if ADigests <> nil then
  begin
    Known := THTStringNode(ADigests.Find(APath));
    if Known <> nil then Exit(Known.Data);
  end;
  {$IFDEF UNIX}
  Descriptor := OpenProtectedDescriptor(APath, O_RDONLY or O_NONBLOCK, 0);
  if Descriptor < 0 then
  begin
    ErrorNumber := FpGetErrNo;
    { The cache records a file removed since it was listed as SHA256File
      does, and fails on any other file it cannot open. }
    if ASnapshot then Result := Metadata
    else if ErrorNumber = ESysENOENT then Result := ''
    else
      raise ELWPTError.Create('cannot read ' + APath + ': '
        + SysErrorMessage(ErrorNumber));
  end
  else if (FpFStat(Descriptor, Status) = 0)
     and not fpS_ISREG(Status.st_mode) then
  begin
    FpClose(Descriptor);
    Result := 'special:' + IntToStr(Status.st_mode);
  end
  else
  begin
    Stream := TLWPTProtectedFileStream.Create(THandle(Descriptor));
    try
      if not ASnapshot then
        Result := SHA256Stream(Stream)
      else
        try
          Result := SHA256Stream(Stream);
        except
          on E: Exception do Result := Metadata;
        end;
    finally
      Stream.Free;
    end;
  end;
  {$ELSE}
  if not ASnapshot then
    Result := SHA256File(APath)
  else
    try
      Result := SHA256File(APath);
    except
      on E: Exception do Result := Metadata;
    end;
  {$ENDIF}
  if ADigests <> nil then ADigests.Add(APath, Result);
end;

{ The sorted "<length>:<relative path>=<content>" entries of every file below
  ARoot, joined by LF. The cache hashes this text; an input snapshot keeps it
  so a change can be named by file. }
function InputDirectoryListing(const AProjectRoot, ARoot: string;
  const AExcludedPaths: TStringArray; const ASnapshot: Boolean;
  const ADigests: TFPStringHashTable): string;
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
              + InputFileContent(Full, ASnapshot, ADigests));
        end
        else if (Attr and faDirectory) <> 0 then
        begin
          if not PathContains(SessionsRoot, Full) then
            Collect(Full, Relative + '/');
        end
        else
          Files.Add(IntToStr(Length(Relative)) + ':' + Relative + '='
            + InputFileContent(Full, ASnapshot, ADigests));
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
    { Hash inputs never inherit the platform line ending: TStrings.Text joins
      with CRLF on Windows and LF elsewhere. LF keeps LF-platform digests
      byte-identical. }
    Files.LineBreak := #10;
    Result := Files.Text;
  finally
    VisitedDirectories.Free;
    Files.Free;
  end;
end;

{ A path's content as the cache sees it. ASnapshot keeps a directory's full
  listing instead of its hash and records unreadable files by metadata. }
function PathState(const AProjectRoot, APath: string;
  const AExcludedPaths: TStringArray; const ASnapshot: Boolean;
  const ADigests: TFPStringHashTable): string;
var
  Full, Listing: string;
begin
  Full := RootedPath(AProjectRoot, APath);
  if Full = '' then Exit('<none>');
  { Explicit files remain inputs even when they are also declared outputs.
    Exclusions apply to broad tree walks so unrelated published artifacts do
    not invalidate another target. }
  if FileExists(Full) then
    Exit('file:' + InputFileContent(Full, ASnapshot, ADigests));
  if PathIsExcluded(AProjectRoot, Full, AExcludedPaths) then Exit('<excluded>');
  if DirectoryExists(Full) then
  begin
    Listing := InputDirectoryListing(AProjectRoot, Full, AExcludedPaths,
      ASnapshot, ADigests);
    if ASnapshot then Exit('tree:' + Listing);
    Exit('tree:' + TextHash(Listing));
  end;
  Result := 'missing';
end;

{ A path's content as the cache hashes it. ADigests reuses a file already
  hashed in the same fingerprint through another path. }
function PathFingerprint(const AProjectRoot, APath: string;
  const AExcludedPaths: TStringArray;
  const ADigests: TFPStringHashTable): string;
begin
  Result := PathState(AProjectRoot, APath, AExcludedPaths, False, ADigests);
end;

{ The first file whose entry differs between two directory listings, as a
  path relative to the listed directory; '' when none can be named. }
function FirstChangedListingEntry(const ABefore, AAfter: string): string;
var
  Before, After: TStringList;

  function EntryPath(const AEntry: string): string;
  var
    Colon: Integer;
  begin
    Colon := Pos(':', AEntry);
    Result := Copy(AEntry, Colon + 1,
      StrToIntDef(Copy(AEntry, 1, Colon - 1), 0));
  end;

  function FirstMissing(const AFrom, AIn: TStringList): string;
  var
    i, Index: Integer;
  begin
    for i := 0 to AFrom.Count - 1 do
      if not AIn.Find(AFrom[i], Index) then Exit(EntryPath(AFrom[i]));
    Result := '';
  end;

begin
  Before := TStringList.Create;
  After := TStringList.Create;
  try
    Before.CaseSensitive := True;
    After.CaseSensitive := True;
    Before.LineBreak := #10;
    After.LineBreak := #10;
    Before.Text := ABefore;
    After.Text := AAfter;
    Before.Sorted := True;
    After.Sorted := True;
    Result := FirstMissing(After, Before);
    if Result = '' then Result := FirstMissing(Before, After);
  finally
    After.Free;
    Before.Free;
  end;
end;

function CaptureInputSnapshot(const AProjectRoot: string;
  const APaths, AExcludedPaths: TStringArray): TLWPTInputSnapshot;
var
  Digests: TFPStringHashTable;
  Unique: TStringList;
  Full: string;
  i: Integer;
begin
  Digests := TFPStringHashTable.Create;
  Unique := TStringList.Create;
  try
    {$IFDEF MSWINDOWS}
    Unique.CaseSensitive := False;
    {$ELSE}
    Unique.CaseSensitive := True;
    {$ENDIF}
    Unique.Sorted := True;
    Unique.Duplicates := dupIgnore;
    for i := 0 to High(APaths) do
    begin
      Full := RootedPath(AProjectRoot, APaths[i]);
      if Full <> '' then Unique.Add(ExcludeTrailingPathDelimiter(Full));
    end;
    SetLength(Result.Paths, Unique.Count);
    SetLength(Result.Contents, Unique.Count);
    for i := 0 to Unique.Count - 1 do
    begin
      Result.Paths[i] := Unique[i];
      Result.Contents[i] := PathState(AProjectRoot, Unique[i],
        AExcludedPaths, True, Digests);
    end;
  finally
    Unique.Free;
    Digests.Free;
  end;
end;

function FirstChangedInput(const AProjectRoot: string;
  const ASnapshot: TLWPTInputSnapshot;
  const AExcludedPaths: TStringArray): string;
var
  Current, Entry: string;
  Digests: TFPStringHashTable;
  i: Integer;
begin
  Result := '';
  { One digest table per scan: a file reached through two overlapping
    paths is hashed once, and a later scan reads it again. }
  Digests := TFPStringHashTable.Create;
  try
    for i := 0 to High(ASnapshot.Paths) do
    begin
      Current := PathState(AProjectRoot, ASnapshot.Paths[i], AExcludedPaths,
        True, Digests);
      if Current = ASnapshot.Contents[i] then Continue;
      Result := ASnapshot.Paths[i];
      if (Copy(Current, 1, 5) = 'tree:')
         and (Copy(ASnapshot.Contents[i], 1, 5) = 'tree:') then
      begin
        Entry := FirstChangedListingEntry(
          Copy(ASnapshot.Contents[i], 6, MaxInt), Copy(Current, 6, MaxInt));
        if Entry <> '' then
          Result := IncludeTrailingPathDelimiter(Result) + Entry;
      end;
      Exit;
    end;
  finally
    Digests.Free;
  end;
end;

function CaptureInputFile(const AProjectRoot, APath: string;
  out AContent: string): string;
var
  Bytes: TMemoryStream;
  Full: string;
  Stream: TStream;
  {$IFDEF UNIX}
  Descriptor: LongInt;
  Status: BaseUnix.Stat;
  {$ENDIF}
begin
  AContent := '';
  Full := RootedPath(AProjectRoot, APath);
  if (Full = '') or not FileExists(Full) then Exit('missing');
  {$IFDEF UNIX}
  { Opening a FIFO for reading blocks until a writer appears, so open
    without blocking and read only the regular file that descriptor names. }
  Descriptor := OpenProtectedDescriptor(Full, O_RDONLY or O_NONBLOCK, 0);
  if Descriptor < 0 then
    raise ELWPTError.Create('cannot read ' + APath + ': '
      + SysErrorMessage(FpGetErrNo));
  if (FpFStat(Descriptor, Status) <> 0)
     or not fpS_ISREG(Status.st_mode) then
  begin
    FpClose(Descriptor);
    raise ELWPTError.Create(APath + ' is not a regular file');
  end;
  Stream := TLWPTProtectedFileStream.Create(THandle(Descriptor));
  {$ELSE}
  try
    Stream := OpenProtectedFileStream(Full, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
      raise ELWPTError.Create('cannot read ' + APath + ': ' + E.Message);
  end;
  {$ENDIF}
  Bytes := TMemoryStream.Create;
  try
    try
      Bytes.CopyFrom(Stream, 0);
    finally
      Stream.Free;
    end;
    SetString(AContent, PAnsiChar(Bytes.Memory), Bytes.Size);
    { The digest InputFileContent takes of the same bytes. }
    Bytes.Position := 0;
    Result := 'file:' + SHA256Stream(Bytes);
  finally
    Bytes.Free;
  end;
end;

function InputSnapshotState(const AProjectRoot: string;
  const ASnapshot: TLWPTInputSnapshot; const APath: string): string;
var
  Full: string;
  i: Integer;
begin
  Result := '';
  Full := RootedPath(AProjectRoot, APath);
  if Full = '' then Exit;
  Full := ExcludeTrailingPathDelimiter(Full);
  for i := 0 to High(ASnapshot.Paths) do
    {$IFDEF MSWINDOWS}
    if SameText(ASnapshot.Paths[i], Full) then
    {$ELSE}
    if ASnapshot.Paths[i] = Full then
    {$ENDIF}
      Exit(ASnapshot.Contents[i]);
end;

procedure AddField(AFields: TStrings; const AName, AValue: string);
begin
  AFields.Add(AName + '=' + IntToStr(Length(AValue)) + ':' + AValue);
end;

procedure AddPathArray(AFields: TStrings; const AProjectRoot, AName: string;
  const APaths, AExcludedPaths: TStringArray;
  const ADigests: TFPStringHashTable);
var
  i: Integer;
begin
  AddField(AFields, AName + '.count', IntToStr(Length(APaths)));
  for i := 0 to High(APaths) do
  begin
    AddField(AFields, AName + '.' + IntToStr(i) + '.path', APaths[i]);
    AddField(AFields, AName + '.' + IntToStr(i) + '.content',
      PathFingerprint(AProjectRoot, APaths[i], AExcludedPaths, ADigests));
  end;
end;

function InputStateMatchesCapture(const ARecorded,
  ACaptured: string): Boolean;
begin
  { A read that failed or met a special file named nothing; it holds while
    the file is still no regular file that could be read. }
  if ACaptured = '' then
    Exit((Copy(ARecorded, 1, 5) <> 'file:')
      or (Copy(ARecorded, 1, 13) = 'file:special:')
      or (Copy(ARecorded, 1, 15) = 'file:unreadable'));
  if ACaptured = 'missing' then Exit(Copy(ARecorded, 1, 5) <> 'file:');
  Result := ARecorded = ACaptured;
end;

procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string;
  var APaths, AReadFiles, AReadStates: TStringArray;
  var AUnbounded: string);
const
  { FPC's Interpret_file stops past 15 nested files. }
  MAXIMUM_OPTION_FILE_DEPTH = 16;
var
  ConfigurationDirectories, Options, ReadPaths, ReadContents: TStringArray;
  Parsed: TStringList;
  Depth: Integer;

  procedure Append(var AList: TStringArray; const AValue: string);
  begin
    SetLength(AList, Length(AList) + 1);
    AList[High(AList)] := AValue;
  end;

  procedure MarkUnbounded(const AReason: string);
  begin
    if AUnbounded = '' then AUnbounded := AReason;
  end;

  function IsAbsolute(const APath: string): Boolean;
  begin
    Result := (APath <> '') and ((APath[1] in ['/', '\'])
      or ((Length(APath) >= 2) and (APath[1] in ['a'..'z', 'A'..'Z'])
        and (APath[2] = ':')));
  end;

  { FPC's RemoveSep: spaces, tabs and commas around a line are not part of
    it. }
  function WithoutSeparators(const ALine: string): string;
  var
    First, Last: Integer;
  begin
    First := 1;
    while (First <= Length(ALine)) and (ALine[First] in [',', ' ', #9]) do
      Inc(First);
    Last := Length(ALine);
    while (Last >= First) and (ALine[Last] in [',', ' ', #9]) do Dec(Last);
    Result := Copy(ALine, First, Last - First + 1);
  end;

  function ReadIndex(const APath: string): Integer;
  var
    i: Integer;
  begin
    for i := 0 to High(ReadPaths) do
      if SamePath(RootedPath(AProjectRoot, ReadPaths[i]),
           RootedPath(AProjectRoot, APath)) then Exit(i);
    Result := -1;
  end;

  { The #CFGDIR directories in effect, as one key. }
  function LookupContext: string;
  var
    i: Integer;
  begin
    Result := '';
    for i := 0 to High(ConfigurationDirectories) do
      Result := Result + #0 + ConfigurationDirectories[i];
  end;

  { FPC's #CFGDIR: AddPath appends each directory not already listed. }
  procedure AddConfigurationDirectories(const AOperand, ADescription: string);
  var
    Added: TStringArray;
    Known: Boolean;
    Unbounded: Boolean;
    i, j: Integer;
  begin
    SetLength(Added, 0);
    { FPC expands a wildcard here into the directories that exist, which
      this does not follow. }
    Unbounded := False;
    AppendSearchEntries(AOperand, False, True, nil, Added, Unbounded);
    if Unbounded then MarkUnbounded(ADescription);
    for i := 0 to High(Added) do
    begin
      Known := False;
      for j := 0 to High(ConfigurationDirectories) do
        if SamePath(RootedPath(AProjectRoot, ConfigurationDirectories[j]),
             RootedPath(AProjectRoot, Added[i])) then Known := True;
      if not Known then Append(ConfigurationDirectories, Added[i]);
    end;
  end;

  procedure ReadCandidate(const APath, ADescription: string); forward;

  { FPC's Interpret_file for AName. A relative name opens from the first
    #CFGDIR directory that has it, trying it as written, in lower case and
    in upper case (FileExistsNonCase on a case-sensitive system), and
    otherwise as named. Which #CFGDIR lines applied depends on #IFDEF
    branches this does not evaluate, and what is there may change, so every
    candidate is an input and every one that exists is read: that names
    every directory any of them could. }
  procedure ReadFile(const AName, ADescription: string);
  var
    Directory: string;
    i: Integer;
  begin
    if AName = '' then Exit;
    if Pos(UNKNOWN_SEARCH_SEGMENT, AName) > 0 then
    begin
      { Only the compiler knows which file an $FPC* macro names. }
      MarkUnbounded(ADescription);
      Exit;
    end;
    if not IsAbsolute(AName) then
      for i := 0 to High(ConfigurationDirectories) do
      begin
        Directory := IncludeTrailingPathDelimiter(ConfigurationDirectories[i]);
        ReadCandidate(Directory + AName, ADescription);
        {$IFNDEF MSWINDOWS}
        if LowerCase(AName) <> AName then
          ReadCandidate(Directory + LowerCase(AName), ADescription);
        if UpperCase(AName) <> AName then
          ReadCandidate(Directory + UpperCase(AName), ADescription);
        {$ENDIF}
      end;
    ReadCandidate(AName, ADescription);
  end;

  { Reads APath once and parses it once for each #CFGDIR context it is
    reached in, since FPC parses an included file again each time and a
    later #CFGDIR changes what its own #INCLUDE lines find. }
  procedure ReadCandidate(const APath, ADescription: string);
  var
    Content, Directive, Key, Line, Operand, State: string;
    Lines: TStringList;
    Exhausted: Boolean;
    i, Index, Position: Integer;
  begin
    Append(APaths, APath);
    Index := ReadIndex(APath);
    if Index >= 0 then Content := ReadContents[Index]
    else
    begin
      { A file that cannot be read, or is not a regular file, names nothing
        more. Its state, 'missing' included, is held to the snapshot or
        fingerprint, so a file that appears or changes since is seen. }
      try
        State := CaptureInputFile(AProjectRoot, APath, Content);
      except
        on E: ELWPTError do
        begin
          State := '';
          Content := '';
        end;
      end;
      Append(AReadFiles, APath);
      Append(AReadStates, State);
      Append(ReadPaths, APath);
      Append(ReadContents, Content);
      {$IFDEF OBJECTSTORE_TESTING}
      if Assigned(OptionFileReadTestHook) then OptionFileReadTestHook(APath);
      {$ENDIF}
    end;
    if Content = '' then Exit;
    Key := ExcludeTrailingPathDelimiter(RootedPath(AProjectRoot, APath))
      + LookupContext;
    if Parsed.IndexOf(Key) >= 0 then Exit;
    if Depth >= MAXIMUM_OPTION_FILE_DEPTH then
    begin
      MarkUnbounded(ADescription);
      Exit;
    end;
    Parsed.Add(Key);
    Inc(Depth);
    Lines := TStringList.Create;
    try
      Lines.Text := Content;
      for i := 0 to Lines.Count - 1 do
      begin
        Line := WithoutSeparators(Lines[i]);
        if Line = '' then Continue;
        if Line[1] = '-' then Append(Options, Line)
        else if Line[1] = '#' then
        begin
          Position := 2;
          while (Position <= Length(Line))
                and (Line[Position] in ['a'..'z', 'A'..'Z', '0'..'9', '_',
                  '-']) do
            Inc(Position);
          Directive := UpperCase(Copy(Line, 2, Position - 2));
          Exhausted := False;
          Operand := ExpandSearchMacros(Trim(Copy(Line, Position + 1,
            MaxInt)), Exhausted);
          if Exhausted then
            MarkUnbounded('directive "' + Line + '" in ' + APath);
          if Directive = 'INCLUDE' then
            ReadFile(Operand, 'directive "' + Line + '" in ' + APath)
          else if Directive = 'CFGDIR' then
            AddConfigurationDirectories(Operand,
              'directive "' + Line + '" in ' + APath);
        end;
        { ";" starts a comment, and FPC refuses a nested "@file". }
      end;
    finally
      Lines.Free;
      Dec(Depth);
    end;
  end;

var
  i: Integer;
begin
  SetLength(ConfigurationDirectories, 0);
  SetLength(Options, 0);
  SetLength(ReadPaths, 0);
  SetLength(ReadContents, 0);
  Depth := 0;
  Parsed := TStringList.Create;
  try
    {$IFDEF MSWINDOWS}
    Parsed.CaseSensitive := False;
    {$ELSE}
    Parsed.CaseSensitive := True;
    {$ENDIF}
    Parsed.Sorted := True;
    for i := 0 to High(AArguments) do
      if (Length(AArguments[i]) > 1) and (AArguments[i][1] = '@') then
        ReadFile(Copy(AArguments[i], 2, MaxInt),
          'argument "' + AArguments[i] + '"')
      else
        Append(Options, AArguments[i]);
  finally
    Parsed.Free;
  end;
  AppendCompilerSearchDirectories(Options, APaths, AUnbounded);
end;

procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string;
  var APaths, AReadFiles, AReadStates: TStringArray);
var
  Unbounded: string;
begin
  Unbounded := '';
  AppendCompilerArgumentInputs(AProjectRoot, AArguments, APaths, AReadFiles,
    AReadStates, Unbounded);
end;

procedure AppendCompilerArgumentInputs(const AProjectRoot: string;
  const AArguments: array of string; var APaths: TStringArray);
var
  ReadFiles, ReadStates: TStringArray;
begin
  SetLength(ReadFiles, 0);
  SetLength(ReadStates, 0);
  AppendCompilerArgumentInputs(AProjectRoot, AArguments, APaths, ReadFiles,
    ReadStates);
end;

{ What the compile's arguments make the compiler read beyond the request's
  unit and include paths, which the fingerprints hash already: the inputs
  AppendCompilerArgumentInputs finds in the compiler arguments, which carry
  the cfg (expanded or as "@file") and the compiler profile's arguments, and
  in the request's extra arguments ([build] or [test] flags), which a driver
  may pass outside its argument list. Each path appears once, in the order
  the arguments name it. AReadFiles and AReadStates are the option files
  read and the states they were read in, and AUnbounded names what may make
  the compiler read beyond these paths ('' when nothing does). }
function CompilerArgumentInputs(const AProjectRoot: string;
  const ARequest: TLWPTBuildPublicationRequest;
  out AReadFiles, AReadStates: TStringArray;
  out AUnbounded: string): TStringArray;
var
  Arguments, Found: TStringArray;
  Known: TStringList;
  i: Integer;

  function Remember(const APath: string): Boolean;
  var
    Key: string;
  begin
    Key := ExcludeTrailingPathDelimiter(RootedPath(AProjectRoot, APath));
    Result := (Key <> '') and (Known.IndexOf(Key) < 0);
    if Result then Known.Add(Key);
  end;

begin
  SetLength(Result, 0);
  SetLength(Arguments, 0);
  for i := 0 to High(ARequest.CompilerArguments) do
  begin
    SetLength(Arguments, Length(Arguments) + 1);
    Arguments[High(Arguments)] := ARequest.CompilerArguments[i];
  end;
  for i := 0 to High(ARequest.BuildRequest.Inputs.ExtraArguments) do
  begin
    SetLength(Arguments, Length(Arguments) + 1);
    Arguments[High(Arguments)] :=
      ARequest.BuildRequest.Inputs.ExtraArguments[i];
  end;
  SetLength(Found, 0);
  SetLength(AReadFiles, 0);
  SetLength(AReadStates, 0);
  AUnbounded := '';
  AppendCompilerArgumentInputs(AProjectRoot, Arguments, Found, AReadFiles,
    AReadStates, AUnbounded);
  Known := TStringList.Create;
  try
    {$IFDEF MSWINDOWS}
    Known.CaseSensitive := False;
    {$ELSE}
    Known.CaseSensitive := True;
    {$ENDIF}
    Known.Sorted := True;
    for i := 0 to High(ARequest.BuildRequest.Inputs.UnitPaths) do
      Remember(ARequest.BuildRequest.Inputs.UnitPaths[i]);
    for i := 0 to High(ARequest.BuildRequest.Inputs.IncludePaths) do
      Remember(ARequest.BuildRequest.Inputs.IncludePaths[i]);
    for i := 0 to High(Found) do
      if Remember(Found[i]) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Found[i];
      end;
  finally
    Known.Free;
  end;
end;

{ The option files that CompilerArgumentInputs derived search inputs from
  must still hold the bytes it read, which the fingerprint has just hashed:
  otherwise those inputs and the hash describe different versions, and the
  cache steps aside. }
procedure RequireOptionFilesUnchanged(const AProjectRoot: string;
  const AReadFiles, AReadStates: TStringArray;
  const ADigests: TFPStringHashTable);
var
  i: Integer;
begin
  for i := 0 to High(AReadFiles) do
    if not InputStateMatchesCapture(PathFingerprint(AProjectRoot,
         AReadFiles[i], nil, ADigests), AReadStates[i]) then
      raise ELWPTError.Create('compiler option file ' + AReadFiles[i]
        + ' changed while it was fingerprinted');
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
  Digests: TFPStringHashTable;
  Fields: TStringList;
  EmptyPaths, ReadFiles, ReadStates: TStringArray;
  ManifestFingerprint, SourceDirectory, Unbounded: string;
begin
  SetLength(EmptyPaths, 0);
  Digests := TFPStringHashTable.Create;
  Fields := TStringList.Create;
  try
    AddField(Fields, 'schema',
      IntToStr(BUILD_PUBLICATION_FINGERPRINT_SCHEMA_VERSION));
    ValidateBuildRequest(ARequest.BuildRequest);
    AddField(Fields, 'build-request',
      SerializeBuildRequest(ARequest.BuildRequest));
    AddField(Fields, 'compiler.executable', ARequest.CompilerExecutable);
    AddStringArray(Fields, 'compiler.arguments', ARequest.CompilerArguments);
    AddField(Fields, 'manifest.parsed-hash', ARequest.ManifestContentHash);
    AddPathArray(Fields, AProjectRoot, 'sources',
      ARequest.BuildRequest.Inputs.Sources, EmptyPaths, Digests);
    SourceDirectory := ExtractFileDir(
      RootedPath(AProjectRoot, ARequest.BuildRequest.Inputs.EntryPoint));
    AddField(Fields, 'source-directory', SourceDirectory);
    AddField(Fields, 'source-directory.content',
      PathFingerprint(AProjectRoot, SourceDirectory,
        ARequest.ExcludedPaths, Digests));
    AddField(Fields, 'output', ARequest.PublicOutput);
    AddField(Fields, 'output.previous',
      PathFingerprint(AProjectRoot, ARequest.PublicOutput, EmptyPaths,
        Digests));
    AddStringArray(Fields, 'environment', ARequest.Environment);
    AddStringArray(Fields, 'excluded-paths', ARequest.ExcludedPaths);
    AddPathArray(Fields, AProjectRoot, 'unit-paths',
      ARequest.BuildRequest.Inputs.UnitPaths, ARequest.ExcludedPaths,
      Digests);
    AddPathArray(Fields, AProjectRoot, 'include-paths',
      ARequest.BuildRequest.Inputs.IncludePaths, ARequest.ExcludedPaths,
      Digests);
    { Publication hashes what it can bound; only a reusable result needs
      every input. }
    AddPathArray(Fields, AProjectRoot, 'compiler-search-inputs',
      CompilerArgumentInputs(AProjectRoot, ARequest, ReadFiles, ReadStates,
        Unbounded), ARequest.ExcludedPaths, Digests);
    RequireOptionFilesUnchanged(AProjectRoot, ReadFiles, ReadStates,
      Digests);
    AddPathArray(Fields, AProjectRoot, 'workspace-paths',
      ARequest.WorkspacePaths, ARequest.ExcludedPaths, Digests);
    AddPathArray(Fields, AProjectRoot, 'prerequisite-outputs',
      ARequest.PrerequisiteOutputs, EmptyPaths, Digests);
    AddPathArray(Fields, AProjectRoot, 'resources',
      ARequest.BuildRequest.Inputs.Resources, ARequest.ExcludedPaths,
      Digests);
    AddStringArray(Fields, 'hook-definition', ARequest.HookDefinition);
    AddPathArray(Fields, AProjectRoot, 'hook-inputs',
      ARequest.HookInputs, ARequest.ExcludedPaths, Digests);
    ManifestFingerprint := PathFingerprint(
      AProjectRoot, AManifestPath, EmptyPaths, Digests);
    if ManifestFingerprint <> 'file:' + ARequest.ManifestContentHash then
      raise ELWPTParsedManifestChanged.Create(
        'manifest changed after it was parsed');
    AddField(Fields, 'manifest', ManifestFingerprint);
    AddField(Fields, 'cfg',
      PathFingerprint(AProjectRoot, ACfgPath, EmptyPaths, Digests));
    AddField(Fields, 'lock',
      PathFingerprint(AProjectRoot, ALockPath, EmptyPaths, Digests));
    AddField(Fields, 'modules', PathFingerprint(AProjectRoot, AModulesPath,
      ARequest.ExcludedPaths, Digests));
    { Same invariant as InputDirectoryListing: the fold separator is
      pinned, never inherited from the platform. }
    Fields.LineBreak := #10;
    Result := TextHash(Fields.Text);
  finally
    Fields.Free;
    Digests.Free;
  end;
end;

function NeutralBuildCacheRequest(const ARequest: TLWPTBuildRequest;
  const APublicOutput: string): TLWPTBuildRequest;
const
  NEUTRAL_SESSION_ROOT = '<build-session>';
begin
  Result := ARequest;
  Result.Outputs.Artifact := APublicOutput;
  Result.Outputs.ExecutableDirectory := NEUTRAL_SESSION_ROOT + '/bin';
  Result.Outputs.UnitDirectory := NEUTRAL_SESSION_ROOT + '/units';
  Result.Outputs.ObjectDirectory := NEUTRAL_SESSION_ROOT + '/units';
  Result.Outputs.ResourceDirectory := NEUTRAL_SESSION_ROOT + '/resources';
end;

function CaptureBuildCacheFingerprint(
  const AProjectRoot, AManifestPath, ACfgPath, ALockPath,
  AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest;
  const AOperation: string): string;
var
  EmptyPaths, ReadFiles, ReadStates, SearchInputs: TStringArray;
  Fields: TStringList;
  ManifestFingerprint, SourceDirectory, Unbounded: string;
  NeutralRequest: TLWPTBuildRequest;
  Digests: TFPStringHashTable;
begin
  SetLength(EmptyPaths, 0);
  Digests := TFPStringHashTable.Create;
  Fields := TStringList.Create;
  try
    if AOperation = '' then
      raise ELWPTError.Create('cache operation identity must not be empty');
    AddField(Fields, 'schema',
      IntToStr(BUILD_CACHE_FINGERPRINT_SCHEMA_VERSION));
    AddField(Fields, 'operation', AOperation);
    ValidateBuildRequest(ARequest.BuildRequest);
    NeutralRequest := NeutralBuildCacheRequest(ARequest.BuildRequest,
      ARequest.PublicOutput);
    AddField(Fields, 'build-request', SerializeBuildRequest(NeutralRequest));
    AddField(Fields, 'compiler.executable', ARequest.CompilerExecutable);
    AddStringArray(Fields, 'compiler.arguments', ARequest.CompilerArguments);
    AddField(Fields, 'manifest.parsed-hash', ARequest.ManifestContentHash);
    AddPathArray(Fields, AProjectRoot, 'sources',
      ARequest.BuildRequest.Inputs.Sources, EmptyPaths, Digests);
    AddPathArray(Fields, AProjectRoot, 'compiler-implicit-inputs',
      ARequest.CompilerImplicitInputs, ARequest.ExcludedPaths, Digests);
    { Cache identity must survive an equivalent checkout at another absolute
      path. Content is still read relative to the concrete project root. }
    SourceDirectory := ExtractFileDir(
      ARequest.BuildRequest.Inputs.EntryPoint);
    AddField(Fields, 'source-directory', SourceDirectory);
    AddField(Fields, 'source-directory.content',
      PathFingerprint(AProjectRoot, SourceDirectory,
        ARequest.ExcludedPaths, Digests));
    AddField(Fields, 'output', ARequest.PublicOutput);
    AddStringArray(Fields, 'environment', ARequest.Environment);
    AddPathArray(Fields, AProjectRoot, 'unit-paths',
      ARequest.BuildRequest.Inputs.UnitPaths, ARequest.ExcludedPaths,
      Digests);
    AddPathArray(Fields, AProjectRoot, 'include-paths',
      ARequest.BuildRequest.Inputs.IncludePaths, ARequest.ExcludedPaths,
      Digests);
    SearchInputs := CompilerArgumentInputs(AProjectRoot, ARequest,
      ReadFiles, ReadStates, Unbounded);
    if Unbounded <> '' then
      raise ELWPTUnboundedCompilerInputs.Create('the compiler may read '
        + 'inputs that ' + Unbounded + ' names and that no fixed directory '
        + 'holds, so its result is not reused');
    AddPathArray(Fields, AProjectRoot, 'compiler-search-inputs',
      SearchInputs, ARequest.ExcludedPaths, Digests);
    RequireOptionFilesUnchanged(AProjectRoot, ReadFiles, ReadStates,
      Digests);
    AddPathArray(Fields, AProjectRoot, 'workspace-paths',
      ARequest.WorkspacePaths, ARequest.ExcludedPaths, Digests);
    AddPathArray(Fields, AProjectRoot, 'prerequisite-outputs',
      ARequest.PrerequisiteOutputs, EmptyPaths, Digests);
    AddPathArray(Fields, AProjectRoot, 'resources',
      ARequest.BuildRequest.Inputs.Resources, ARequest.ExcludedPaths,
      Digests);
    AddStringArray(Fields, 'hook-definition', ARequest.HookDefinition);
    AddPathArray(Fields, AProjectRoot, 'hook-inputs',
      ARequest.HookInputs, ARequest.ExcludedPaths, Digests);
    ManifestFingerprint := PathFingerprint(
      AProjectRoot, AManifestPath, EmptyPaths, Digests);
    if ManifestFingerprint <> 'file:' + ARequest.ManifestContentHash then
      raise ELWPTParsedManifestChanged.Create(
        'manifest changed after it was parsed');
    AddField(Fields, 'manifest', ManifestFingerprint);
    AddField(Fields, 'cfg',
      PathFingerprint(AProjectRoot, ACfgPath, EmptyPaths, Digests));
    AddField(Fields, 'lock',
      PathFingerprint(AProjectRoot, ALockPath, EmptyPaths, Digests));
    AddField(Fields, 'modules', PathFingerprint(AProjectRoot, AModulesPath,
      ARequest.ExcludedPaths, Digests));
    Fields.LineBreak := #10;
    Result := TextHash(Fields.Text);
  finally
    Fields.Free;
    Digests.Free;
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
  if not LongPathFileExists(APath) then Exit;
  Lines := TStringList.Create;
  try
    LoadProtectedStrings(Lines, APath);
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
  Age := LongPathFileAge(APath);
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
    if LongPathDirectoryExists(APath) or LongPathForceDirectories(APath) then
      Exit(True);
    Sleep(10);
  end;
  Result := LongPathDirectoryExists(APath);
end;

function ReadSessionState(const APath: string): string;
var
  Lines: TStringList;
begin
  Result := '';
  if not LongPathFileExists(APath) then Exit;
  Lines := TStringList.Create;
  try
    LoadProtectedStrings(Lines, APath);
    if Lines.Count > 1 then Result := Trim(Lines[1]);
  finally
    Lines.Free;
  end;
end;

constructor TLWPTSessionOwnerGuard.Create(const APath: string;
  const ADescription: string);
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
    raise ELWPTError.CreateFmt('could not create %s directory %s',
      [ADescription, ExtractFileDir(FPath)]);
  {$IFDEF UNIX}
  FDescriptor := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
  {$ENDIF}
  {$IFDEF UNIX}
  FDescriptor := OpenProtectedDescriptor(FPath, O_RDWR or O_CREAT);
  if FDescriptor < 0 then
    raise ELWPTError.CreateFmt('could not open %s %s',
      [ADescription, FPath]);
  FillChar(LockSpec, SizeOf(LockSpec), 0);
  LockSpec.l_type := F_WRLCK_LWPT;
  LockSpec.l_whence := SEEK_SET;
  LockSpec.l_start := 0;
  LockSpec.l_len := 1;
  if FpFcntl(FDescriptor, F_SetLk, LockSpec) <> 0 then
  begin
    FpClose(FDescriptor);
    FDescriptor := -1;
    raise ELWPTError.CreateFmt('%s is already held %s',
      [ADescription, FPath]);
  end;
  FLocked := True;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FHandle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(FPath)),
    Windows.GENERIC_READ or Windows.GENERIC_WRITE,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE,
    nil, Windows.OPEN_ALWAYS, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
    raise ELWPTError.CreateFmt('could not open %s %s',
      [ADescription, FPath]);
  FillChar(Overlapped, SizeOf(Overlapped), 0);
  if not Windows.LockFileEx(FHandle,
    LOCKFILE_EXCLUSIVE_LOCK_LWPT or LOCKFILE_FAIL_IMMEDIATELY_LWPT,
    0, 1, 0, Overlapped) then
  begin
    Windows.CloseHandle(FHandle);
    FHandle := THandle(Windows.INVALID_HANDLE_VALUE);
    raise ELWPTError.CreateFmt('%s is already held %s',
      [ADescription, FPath]);
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
  Descriptor := OpenProtectedDescriptor(APath, O_RDWR);
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
  Handle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(APath)),
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

constructor TLWPTPublicationLock.Create(const APath: string;
  const ARefuseLinks: Boolean);
var
  Started: TDateTime;
  PIDLine: AnsiString;
  Acquired: Boolean;
  i: Integer;
  {$IFDEF UNIX}
  LockSpec: TLWPTFlock;
  OpenFlags: LongInt;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Written: DWORD;
  Overlapped: TOverlapped;
  OpenAttributes: DWORD;
  Information: TByHandleFileInformation;
  {$ENDIF}
begin
  inherited Create;
  FPath := APath;
  FRefuseLinks := ARefuseLinks;
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
    LongPathForceDirectories(ExtractFileDir(FPath));
    Started := Now;
    Acquired := False;
    {$IFDEF UNIX}
    OpenFlags := O_RDWR or O_CREAT;
    { A refused link fails the open (ELOOP) before anything is written. }
    if FRefuseLinks then OpenFlags := OpenFlags or O_NOFOLLOW_LWPT;
    FDescriptor := OpenProtectedDescriptor(FPath, OpenFlags, &644);
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
    OpenAttributes := Windows.FILE_ATTRIBUTE_NORMAL;
    { Opening the reparse point itself, rather than what it names, lets a
      refused link be recognised before anything is written. }
    if FRefuseLinks then
      OpenAttributes := OpenAttributes
        or FILE_FLAG_OPEN_REPARSE_POINT_SESSION_LWPT;
    FHandle := Windows.CreateFileW(PWideChar(WindowsExtendedPath(FPath)),
      Windows.GENERIC_READ or Windows.GENERIC_WRITE,
      Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE, nil,
      Windows.OPEN_ALWAYS, OpenAttributes, 0);
    if FHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
      raise EConcurrencyError.CreateFmt(
        'could not open build publication lock %s', [FPath]);
    if FRefuseLinks and (not Windows.GetFileInformationByHandle(FHandle,
      Information) or ((Information.dwFileAttributes
        and Windows.FILE_ATTRIBUTE_REPARSE_POINT) <> 0)) then
      raise EConcurrencyError.CreateFmt(
        'build publication lock must not be a link: %s', [FPath]);
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

function BuildSessionProjectIdentity(const AProjectRoot: string): string;
var
  IdentityPath, PhysicalIdentity: string;
begin
  IdentityPath := ExcludeTrailingPathDelimiter(ExpandFileName(AProjectRoot));
  PhysicalIdentity := DirectoryIdentity(IdentityPath);
  if PhysicalIdentity <> '' then
    Exit(TextHash('build-session-project-physical-v1'#10
      + PhysicalIdentity));
  {$IFDEF MSWINDOWS}
  IdentityPath := LowerCase(IdentityPath);
  {$ENDIF}
  Result := TextHash('build-session-project-path-v1'#10 + IdentityPath);
end;

function BuildSessionLedgerPath(const AProjectRoot: string): string;
begin
  Result := RootedPath(AProjectRoot, BUILD_SESSION_ROOT_LEDGER);
end;

function BuildSessionLedgerLockPath(const AProjectRoot: string): string;
begin
  Result := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR)
    + '/locks/session-roots.lock';
end;

function AcquireBuildCoordinationLock(const AProjectRoot: string): TObject;
begin
  Result := TLWPTPublicationLock.Create(
    BuildSessionLedgerLockPath(AProjectRoot));
end;

function AcquireOwnerGuard(const APath, ADescription: string): TObject;
begin
  Result := TLWPTSessionOwnerGuard.Create(APath, ADescription);
end;

function OwnerGuardHeld(const APath: string): Boolean;
begin
  Result := SessionOwnerGuardHeld(APath);
end;

function AcquireShortLock(const APath: string): TObject;
begin
  Result := TLWPTPublicationLock.Create(APath, True);
end;

function BuildSessionsProjectRoot(const AProjectRoot,
  AConfiguredRoot: string): string;
var
  Identity: string;
begin
  if SamePath(AConfiguredRoot,
    RootedPath(AProjectRoot, BUILD_SESSIONS_DIR)) then
    Exit(ExpandFileName(AConfiguredRoot));
  Identity := BuildSessionProjectIdentity(AProjectRoot);
  Result := IncludeTrailingPathDelimiter(ExpandFileName(AConfiguredRoot))
    + 'p-' + Copy(Identity, 8, 16);
end;

function SessionRootIdentityMatches(const ARoot,
  AProjectIdentity: string): Boolean;
var
  IdentityPath, RootIdentity: string;
  Lines: TStringList;
begin
  Result := False;
  if ExtractFileName(ExcludeTrailingPathDelimiter(ARoot))
    <> 'p-' + Copy(AProjectIdentity, 8, 16) then Exit;
  if IsDirSymlinkOrJunction(ARoot) then Exit;
  RootIdentity := DirectoryIdentity(ARoot);
  if RootIdentity = '' then Exit;
  IdentityPath := IncludeTrailingPathDelimiter(ARoot)
    + SESSION_ROOT_IDENTITY_FILE;
  if not LongPathFileExists(IdentityPath) then Exit;
  if IsDirSymlinkOrJunction(IdentityPath) then Exit;
  Lines := TStringList.Create;
  try
    LoadProtectedStrings(Lines, IdentityPath);
    Result := (Lines.Count = 3)
      and (Lines[0] = 'schema='
        + IntToStr(SESSION_ROOT_IDENTITY_SCHEMA_VERSION))
      and (Lines[1] = 'project=' + AProjectIdentity)
      and (Lines[2] = 'root=' + RootIdentity);
  finally
    Lines.Free;
  end;
end;

procedure EnsureSessionRootIdentity(const ARoot,
  AProjectIdentity: string);
var
  IdentityPath, RootIdentity: string;
  Lines: TStringList;
begin
  if (Pos(#10, ARoot) > 0) or (Pos(#13, ARoot) > 0) then
    raise ELWPTError.Create('build session root contains a line break');
  if IsDirSymlinkOrJunction(ARoot) then
    raise ELWPTError.CreateFmt(
      'build session root must not be a link: %s', [ARoot]);
  if not EnsureDirectory(ARoot) then
    raise ELWPTError.CreateFmt(
      'could not create build sessions directory %s', [ARoot]);
  IdentityPath := IncludeTrailingPathDelimiter(ARoot)
    + SESSION_ROOT_IDENTITY_FILE;
  if IsDirSymlinkOrJunction(IdentityPath) then
    raise ELWPTError.CreateFmt(
      'build session root identity must not be a link: %s',
      [IdentityPath]);
  RootIdentity := DirectoryIdentity(ARoot);
  if RootIdentity = '' then
    raise ELWPTError.CreateFmt(
      'could not identify build sessions directory %s', [ARoot]);
  if not LongPathFileExists(IdentityPath) then
  begin
    Lines := TStringList.Create;
    try
      Lines.Add('schema=' + IntToStr(SESSION_ROOT_IDENTITY_SCHEMA_VERSION));
      Lines.Add('project=' + AProjectIdentity);
      Lines.Add('root=' + RootIdentity);
      AtomicWriteText(IdentityPath, ARoot, Lines);
    finally
      Lines.Free;
    end;
  end;
  if not SessionRootIdentityMatches(ARoot, AProjectIdentity) then
    raise ELWPTError.CreateFmt(
      'build session root ownership does not match this project: %s',
      [ARoot]);
end;

procedure LoadSessionRootLedger(const AProjectRoot,
  AProjectIdentity: string; ARoots: TStrings);
var
  LedgerPath, Prefix: string;
  Lines: TStringList;
  i: Integer;
begin
  ARoots.Clear;
  LedgerPath := BuildSessionLedgerPath(AProjectRoot);
  if not LongPathFileExists(LedgerPath) then Exit;
  Lines := TStringList.Create;
  try
    LoadProtectedStrings(Lines, LedgerPath);
    if (Lines.Count < 2)
      or (Lines[0] <> 'schema='
        + IntToStr(SESSION_ROOT_LEDGER_SCHEMA_VERSION))
      or (Lines[1] <> 'project=' + AProjectIdentity) then
      raise ELWPTError.CreateFmt(
        'build session root ledger is invalid: %s', [LedgerPath]);
    Prefix := 'root=';
    for i := 2 to Lines.Count - 1 do
    begin
      if Copy(Lines[i], 1, Length(Prefix)) <> Prefix then
        raise ELWPTError.CreateFmt(
          'build session root ledger is invalid: %s', [LedgerPath]);
      if Copy(Lines[i], Length(Prefix) + 1, MaxInt) = '' then
        raise ELWPTError.CreateFmt(
          'build session root ledger is invalid: %s', [LedgerPath]);
      ARoots.Add(Copy(Lines[i], Length(Prefix) + 1, MaxInt));
    end;
  finally
    Lines.Free;
  end;
end;

procedure SaveSessionRootLedger(const AProjectRoot,
  AProjectIdentity: string; ARoots: TStrings);
var
  Lines: TStringList;
  i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('schema=' + IntToStr(SESSION_ROOT_LEDGER_SCHEMA_VERSION));
    Lines.Add('project=' + AProjectIdentity);
    for i := 0 to ARoots.Count - 1 do
      Lines.Add('root=' + ARoots[i]);
    AtomicWriteText(BuildSessionLedgerPath(AProjectRoot),
      RootedPath(AProjectRoot, TMP_DIR), Lines);
  finally
    Lines.Free;
  end;
end;

procedure RegisterSessionRoot(const AProjectRoot,
  ASessionsRoot: string);
var
  LedgerLock: TLWPTPublicationLock;
  Roots: TStringList;
  ProjectIdentity: string;
begin
  ProjectIdentity := BuildSessionProjectIdentity(AProjectRoot);
  LedgerLock := TLWPTPublicationLock.Create(
    BuildSessionLedgerLockPath(AProjectRoot));
  Roots := TStringList.Create;
  try
    EnsureSessionRootIdentity(ASessionsRoot, ProjectIdentity);
    LoadSessionRootLedger(AProjectRoot, ProjectIdentity, Roots);
    Roots.CaseSensitive := {$IFDEF MSWINDOWS}False{$ELSE}True{$ENDIF};
    if Roots.IndexOf(ASessionsRoot) < 0 then
    begin
      Roots.Add(ASessionsRoot);
      Roots.Sort;
      SaveSessionRootLedger(AProjectRoot, ProjectIdentity, Roots);
    end;
  finally
    Roots.Free;
    LedgerLock.Free;
  end;
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

procedure RegisterLiveSession(const ASessionID: string);
begin
  EnterCriticalSection(LiveSessionCriticalSection);
  try
    LiveSessionIDs.Add(ASessionID);
  finally
    LeaveCriticalSection(LiveSessionCriticalSection);
  end;
end;

procedure UnregisterLiveSession(const ASessionID: string);
var
  Index: Integer;
begin
  EnterCriticalSection(LiveSessionCriticalSection);
  try
    Index := LiveSessionIDs.IndexOf(ASessionID);
    if Index >= 0 then LiveSessionIDs.Delete(Index);
  finally
    LeaveCriticalSection(LiveSessionCriticalSection);
  end;
end;

{ The one inactivity predicate for a session directory under ARoot: its owner
  guard is not held, and its state is failed, or its owner is gone, or it has
  outlived the partial-state grace. lwpt repair reclaims exactly these
  sessions, and a finishing session prunes superseded job staging only from
  these sessions. ASessionName may be a hidden '.creating-' directory. }
function SessionIsInactive(const ARoot, ASessionName: string): Boolean;
var
  SessionPath, SessionID, StatePath, AgePath, State: string;
  PID: LongInt;
  GuardHeld: Boolean;
begin
  SessionPath := IncludeTrailingPathDelimiter(ARoot) + ASessionName;
  SessionID := ASessionName;
  if Copy(SessionID, 1, Length('.creating-')) = '.creating-' then
    Delete(SessionID, 1, Length('.creating-'));
  { A session registers before it takes its guard, and the lookup and probe
    share the registry's critical section, so a probe from this process
    never runs against a guard this process holds or is taking. }
  EnterCriticalSection(LiveSessionCriticalSection);
  try
    GuardHeld := (LiveSessionIDs.IndexOf(SessionID) >= 0)
      or SessionOwnerGuardHeld(SessionOwnerGuardPath(ARoot, SessionID));
  finally
    LeaveCriticalSection(LiveSessionCriticalSection);
  end;
  if GuardHeld then Exit(False);
  StatePath := SessionPath + '/session.state';
  PID := ReadPID(StatePath);
  State := ReadSessionState(StatePath);
  if LongPathFileExists(StatePath) then AgePath := StatePath
  else AgePath := SessionPath;
  Result := not ((State <> 'failed')
    and (not IncompleteStateIsAbandoned(AgePath))
    and ((State = '') or ProcessIsAlive(PID)));
end;

{ The project identity a session recorded in its state, or '' for a session
  written before sessions recorded one. }
function ReadSessionProjectIdentity(const ASessionRoot: string): string;
var
  Lines: TStringList;
  StatePath: string;
begin
  Result := '';
  StatePath := ASessionRoot + '/session.state';
  if not LongPathFileExists(StatePath) then Exit;
  Lines := TStringList.Create;
  try
    LoadProtectedStrings(Lines, StatePath);
    if Lines.Count > 3 then Result := Trim(Lines[3]);
  finally
    Lines.Free;
  end;
end;

constructor TLWPTBuildSession.Create(const AProjectRoot: string);
begin
  Create(AProjectRoot, RootedPath(AProjectRoot, BUILD_SESSIONS_DIR));
end;

constructor TLWPTBuildSession.Create(const AProjectRoot,
  ASessionsRoot: string);
var
  BaseRoot, PendingRoot: string;
  CollisionCounter: Integer;
  InvocationCounter: QWord;
begin
  inherited Create;
  FProjectRoot := ExpandFileName(AProjectRoot);
  FSessionOwnerGuardPath := '';
  FSessionOwnerGuard := nil;
  FProgramJobs := TStringList.Create;
  FCleanupWarnings := TStringList.Create;
  FProjectIdentity := BuildSessionProjectIdentity(FProjectRoot);
  BaseRoot := ExpandFileName(ASessionsRoot);
  FDefaultSessionsRoot := SamePath(BaseRoot,
    RootedPath(FProjectRoot, BUILD_SESSIONS_DIR));
  if not FDefaultSessionsRoot then
  begin
    BaseRoot := BuildSessionsProjectRoot(FProjectRoot, BaseRoot);
    RegisterSessionRoot(FProjectRoot, BaseRoot);
  end;
  FSessionsRoot := BaseRoot;
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
  until (not LongPathDirectoryExists(FSessionRoot))
    and (not LongPathDirectoryExists(PendingRoot));
  if not EnsureDirectory(PendingRoot) then
    raise ELWPTError.CreateFmt(
      'could not create build session directory %s', [PendingRoot]);
  FFinished := False;
  FSessionRoot := PendingRoot;
  FSessionOwnerGuardPath := SessionOwnerGuardPath(BaseRoot, FSessionID);
  try
    RegisterLiveSession(FSessionID);
    FSessionOwnerGuard := TLWPTSessionOwnerGuard.Create(
      FSessionOwnerGuardPath);
    WriteState('active');
    if not LongPathRenameFile(PendingRoot,
      IncludeTrailingPathDelimiter(BaseRoot) + FSessionID) then
      raise ELWPTError.CreateFmt(
        'could not publish build session directory %s', [FSessionID]);
    FSessionRoot := IncludeTrailingPathDelimiter(BaseRoot) + FSessionID;
  except
    ReleaseOwnerGuard;
    if LongPathFileExists(FSessionOwnerGuardPath) then
      LongPathDeleteFile(FSessionOwnerGuardPath);
    if LongPathDirectoryExists(PendingRoot) then WipeDir(PendingRoot);
    if LongPathDirectoryExists(IncludeTrailingPathDelimiter(BaseRoot)
      + FSessionID) then
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
  ReleaseOwnerGuard;
  FProgramJobs.Free;
  FCleanupWarnings.Free;
  inherited Destroy;
end;

procedure TLWPTBuildSession.ReleaseOwnerGuard;
begin
  FreeAndNil(FSessionOwnerGuard);
  UnregisterLiveSession(FSessionID);
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
    { Readers before this line existed read only the first three lines. }
    Lines.Add(FProjectIdentity);
    AtomicWriteText(FSessionRoot + '/session.state', FSessionRoot, Lines);
  finally
    Lines.Free;
  end;
end;

function TLWPTBuildSession.JobRoot(const AName: string): string;
begin
  Result := FSessionRoot + '/jobs/' + BuildSessionPathKey(AName);
  LongPathForceDirectories(Result);
end;

function TLWPTBuildSession.ProgramJobsRoot(const AName: string): string;
begin
  Result := JobRoot(AName);
  if FProgramJobs.IndexOf(BuildSessionPathKey(AName)) < 0 then
    FProgramJobs.Add(BuildSessionPathKey(AName));
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

function TLWPTBuildSession.SessionReference: string;
begin
  if FDefaultSessionsRoot then
    Result := BUILD_SESSIONS_DIR + '/' + FSessionID
  else
    Result := FSessionRoot;
end;

procedure TLWPTBuildSession.WriteJobLog(const AName, AOutput: string);
var
  LogPath: string;
  Bytes: TBytes;
begin
  LogPath := JobLogPath(AName);
  if not LongPathForceDirectories(ExtractFileDir(LogPath)) then
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

{ A job unit is what a later session supersedes: one build job's directory
  (jobs/<entry>-<mode>-<key>/, with its bin/, units/ and cache staging) or
  one program's directory below a ProgramJobsRoot
  (jobs/tests-<key>/<program-key>/). Job and program keys are stable for the
  same project, so the same unit in an inactive session of this sessions root
  holds an older build of the same entry or program. A failed session keeps
  its staging for diagnosis, and someone running that copy by hand would get
  the superseded binary without a warning. Remove it, keeping the older
  session's logs, failure detail and state. Live sessions (owner guard held,
  or not yet inactive by repair's own predicate) are never touched. The
  caller holds the project's build-coordination lock. Pruning is best
  effort: a unit that cannot be removed is left for the next finishing
  session or lwpt repair, and never changes the result of the run that
  finished. }
procedure TLWPTBuildSession.PruneSupersededJobs;
const
  SESSION_PATTERNS: array[0..1] of string = ('s-*', 'session-*');
var
  JobsRoot, OtherRoot, OtherJobs, ProgramJob, OtherIdentity: string;
  Jobs, Programs, Sessions: TLWPTDirectoryEntries;
  Units: TStringList;
  JobIndex, ProgramIndex, SessionIndex, UnitIndex, PatternIndex: Integer;

  function IsDirectoryEntry(const AEntry: TLWPTDirectoryEntry): Boolean;
  begin
    Result := ((AEntry.Attr and faDirectory) <> 0)
      and (AEntry.Name <> '.') and (AEntry.Name <> '..');
  end;

  { Report a session whose ownership could not be verified when it holds
    staging this session supersedes, because that staging stays runnable. }
  procedure ReportUnverified(const AReason: string);
  var
    Index: Integer;
    Target: string;
  begin
    for Index := 0 to Units.Count - 1 do
    begin
      Target := OtherJobs + '/' + Units[Index];
      try
        if not (LongPathDirectoryExists(Target)
          or IsDirSymlinkOrJunction(Target)) then Continue;
      except
        on Exception do;
      end;
      FCleanupWarnings.Add(Format('superseded staging %s was not removed '
        + 'because its session could not be verified as this project''s '
        + '(%s); run %s repair', [Target, AReason, PROGRAM_NAME]));
    end;
  end;

  procedure RemoveUnit(const AUnit: string);
  var
    Target, Reason: string;
  begin
    Target := OtherJobs + '/' + AUnit;
    Reason := '';
    try
      if Pos('/', AUnit) > 0 then
      begin
        ProgramJob := OtherJobs + '/' + ExtractFileDir(AUnit);
        if (not LongPathDirectoryExists(ProgramJob))
          or IsDirSymlinkOrJunction(ProgramJob) then Exit;
      end;
      if not (LongPathDirectoryExists(Target)
        or IsDirSymlinkOrJunction(Target)) then Exit;
      { WipeDir removes a linked unit as a link. }
      WipeDir(Target);
      { RemoveDir refuses a job root that still holds programs this session
        did not stage. }
      if Pos('/', AUnit) > 0 then LongPathRemoveDir(ProgramJob);
    except
      on E: Exception do Reason := E.Message;
    end;
    if LongPathDirectoryExists(Target) or IsDirSymlinkOrJunction(Target) then
    begin
      if Reason = '' then Reason := 'it could not be removed';
      FCleanupWarnings.Add(Format('superseded staging %s was not removed '
        + '(%s); run %s repair', [Target, Reason, PROGRAM_NAME]));
    end;
  end;

begin
  JobsRoot := FSessionRoot + '/jobs';
  if not LongPathDirectoryExists(JobsRoot) then Exit;
  if (not FDefaultSessionsRoot) and (not SessionRootIdentityMatches(
    FSessionsRoot, FProjectIdentity)) then
    Exit;
  Units := TStringList.Create;
  try
    Jobs := ListDirectoryEntries(JobsRoot, '*', faDirectory);
    for JobIndex := 0 to High(Jobs) do
    begin
      if not IsDirectoryEntry(Jobs[JobIndex]) then Continue;
      if FProgramJobs.IndexOf(Jobs[JobIndex].Name) < 0 then
      begin
        Units.Add(Jobs[JobIndex].Name);
        Continue;
      end;
      Programs := ListDirectoryEntries(JobsRoot + '/' + Jobs[JobIndex].Name,
        '*', faDirectory);
      for ProgramIndex := 0 to High(Programs) do
        if IsDirectoryEntry(Programs[ProgramIndex]) then
          Units.Add(Jobs[JobIndex].Name + '/' + Programs[ProgramIndex].Name);
    end;
    if Units.Count = 0 then Exit;
    for PatternIndex := Low(SESSION_PATTERNS) to High(SESSION_PATTERNS) do
    begin
      Sessions := ListDirectoryEntries(FSessionsRoot,
        SESSION_PATTERNS[PatternIndex], faDirectory);
      for SessionIndex := 0 to High(Sessions) do
      begin
        if not IsDirectoryEntry(Sessions[SessionIndex]) then Continue;
        if Sessions[SessionIndex].Name = FSessionID then Continue;
        OtherRoot := FSessionsRoot + '/' + Sessions[SessionIndex].Name;
        OtherJobs := OtherRoot + '/jobs';
        try
          if IsDirSymlinkOrJunction(OtherRoot)
            or IsDirSymlinkOrJunction(OtherJobs)
            or (not LongPathDirectoryExists(OtherJobs)) then Continue;
          { A sessions root can be shared through a link with another
            project, whose build-entry keys can match ours: only this
            project's own sessions are superseded. A record without an
            identity (an older LWPT wrote it) cannot be attributed, so it
            is retained and reported when it holds matching staging. }
          OtherIdentity := ReadSessionProjectIdentity(OtherRoot);
          if OtherIdentity = '' then
          begin
            ReportUnverified('it records no project identity');
            Continue;
          end;
          if OtherIdentity <> FProjectIdentity then Continue;
          if not SessionIsInactive(FSessionsRoot,
            Sessions[SessionIndex].Name) then Continue;
          for UnitIndex := 0 to Units.Count - 1 do
            RemoveUnit(Units[UnitIndex]);
          LongPathRemoveDir(OtherJobs);
        except
          { An unreadable session record retains that session; the sweep
            continues with the others and reports the retained staging. }
          on E: Exception do
          begin
            ReportUnverified(E.Message);
            Continue;
          end;
        end;
      end;
    end;
  finally
    Units.Free;
  end;
end;

procedure TLWPTBuildSession.Finish(ASuccess: Boolean; const ADetail: string);
var
  HasLogs: Boolean;
  Lines: TStringList;
  CoordinationLock: TLWPTPublicationLock;
begin
  if FFinished then Exit;
  { Pruning and a failed session's terminal state and guard release share
    one critical section under the lock repair also holds. Otherwise a
    failing session could finish its sweep, a passing session could skip it
    as live, and the failing session's executable, now superseded, would
    survive both. Retention therefore follows completion order. }
  CoordinationLock := nil;
  try
    try
      CoordinationLock := TLWPTPublicationLock.Create(
        BuildSessionLedgerLockPath(FProjectRoot));
    except
      on E: Exception do
      begin
        CoordinationLock := nil;
        if LongPathDirectoryExists(FSessionRoot + '/jobs') then
          FCleanupWarnings.Add(Format('superseded staging in older sessions '
            + 'was not checked (%s); run %s repair',
            [E.Message, PROGRAM_NAME]));
      end;
    end;
    if CoordinationLock <> nil then
      try
        PruneSupersededJobs;
      except
        on E: Exception do
          FCleanupWarnings.Add(Format('superseded staging in older sessions '
            + 'was not fully checked (%s); run %s repair',
            [E.Message, PROGRAM_NAME]));
      end;
    if ASuccess then
    begin
      { A passing session keeps no executable, so its own cleanup does not
        need the coordination lock. }
      FreeAndNil(CoordinationLock);
      { The guard lives beside session directories, so it remains observable
        while private compiler staging is removed on every platform.
        Stable job logs remain until lwpt repair reclaims the completed
        session. }
      HasLogs := LongPathDirectoryExists(FSessionRoot
        + ObservabilityLogsDirectory);
      WriteState('completing');
      if HasLogs then
      begin
        if LongPathDirectoryExists(FSessionRoot + '/jobs') then
          WipeDir(FSessionRoot + '/jobs');
        WriteState('completed');
      end
      else
        WipeDir(FSessionRoot);
      ReleaseOwnerGuard;
      if LongPathFileExists(FSessionOwnerGuardPath)
        and (not LongPathDeleteFile(FSessionOwnerGuardPath)) then
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
    ReleaseOwnerGuard;
    FFinished := True;
    {$IFDEF OBJECTSTORE_TESTING}
    if (CoordinationLock <> nil)
      and Assigned(SessionFinishBeforeCoordinationReleaseTestHook) then
      SessionFinishBeforeCoordinationReleaseTestHook(FSessionRoot);
    {$ENDIF}
  finally
    CoordinationLock.Free;
  end;
end;

function BuildOutputIdentity(const AOutput: string): string;
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
  Result := ParentIdentity + '/' + OutputName;
end;

function BuildPublicationLockPath(const ASessionsRoot, AOutput: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ASessionsRoot)
    + '/locks/' + Copy(TextHash(BuildOutputIdentity(AOutput)), 8, 64)
    + '.lock';
end;

function PublishBuildArtifact(const AProjectRoot, ACandidatePath,
  ADestinationPath, AExpectedFingerprint, AManifestPath, ACfgPath,
  ALockPath, AModulesPath: string;
  const ARequest: TLWPTBuildPublicationRequest;
  const ASessionsRoot: string):
  TLWPTBuildPublicationResult;
var
  CoordinatorLock, Lock: TLWPTPublicationLock;
  CurrentFingerprint, PublicationSessionsRoot: string;
  Destination: string;
begin
  Destination := RootedPath(AProjectRoot, ADestinationPath);
  PublicationSessionsRoot := ASessionsRoot;
  if PublicationSessionsRoot = '' then
    PublicationSessionsRoot := RootedPath(AProjectRoot, BUILD_SESSIONS_DIR);
  { Session-root selection can change while builds overlap. The project-local
    ledger lock gives every root generation one publication rendezvous; the
    output-specific lock remains in the resolved namespace for stable
    same-root coordination. }
  CoordinatorLock := TLWPTPublicationLock.Create(
    BuildSessionLedgerLockPath(AProjectRoot));
  try
    Lock := TLWPTPublicationLock.Create(
      BuildPublicationLockPath(PublicationSessionsRoot, Destination));
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
      { The destination may be the running LWPT (self-hosted rebuild) or
        another live executable; see AtomicReplaceExecutable. Retired
        images are swept only below the project root, never through a
        redirected output directory. }
      if not AtomicReplaceExecutable(ACandidatePath, Destination,
        AProjectRoot) then
        raise ELWPTError.CreateFmt(
          'could not atomically publish "%s" to "%s"; the completed '
          + 'candidate remains private', [ACandidatePath, Destination]);
      Result := bprPublished;
    finally
      Lock.Free;
    end;
  finally
    CoordinatorLock.Free;
  end;
end;

procedure RepairBuildSessions(const AProjectRoot, ATemporaryRoot: string;
  out ARemoved, ARetained: Integer;
  out ATemporaryRootCleaned: Boolean);
var
  Root, SessionPath, SessionID, OwnerPath: string;
  LedgerLock: TLWPTPublicationLock;
  Roots: TStringList;
  ProjectIdentity: string;
  RootRequiresIdentity: Boolean;
  i: Integer;

  procedure ReclaimSessionPattern(const APattern: string);
  var
    Entries: TLWPTDirectoryEntries;
    EntryIndex: Integer;
  begin
    if RootRequiresIdentity
      and not SessionRootIdentityMatches(Root, ProjectIdentity) then Exit;
    Entries := ListDirectoryEntries(Root, APattern, faAnyFile);
    for EntryIndex := 0 to High(Entries) do
    begin
      if (Entries[EntryIndex].Attr and faDirectory) = 0 then Continue;
      SessionPath := Root + '/' + Entries[EntryIndex].Name;
      SessionID := Entries[EntryIndex].Name;
      if Copy(SessionID, 1, Length('.creating-')) = '.creating-' then
        Delete(SessionID, 1, Length('.creating-'));
      OwnerPath := SessionOwnerGuardPath(Root, SessionID);
      if not SessionIsInactive(Root, Entries[EntryIndex].Name) then
        Inc(ARetained)
      else
      begin
        if RootRequiresIdentity
          and not SessionRootIdentityMatches(Root, ProjectIdentity) then
          Exit;
        WipeDir(SessionPath);
        if LongPathFileExists(OwnerPath) then LongPathDeleteFile(OwnerPath);
        Inc(ARemoved);
      end;
    end;
  end;

  procedure ReclaimRoot(const ARoot: string;
    ARequireIdentity: Boolean);
  begin
    Root := ARoot;
    RootRequiresIdentity := ARequireIdentity;
    if not LongPathDirectoryExists(Root) then Exit;
    if RootRequiresIdentity
      and not SessionRootIdentityMatches(Root, ProjectIdentity) then Exit;
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
begin
  ARemoved := 0;
  ARetained := 0;
  ATemporaryRootCleaned := False;
  ProjectIdentity := BuildSessionProjectIdentity(AProjectRoot);
  LedgerLock := TLWPTPublicationLock.Create(
    BuildSessionLedgerLockPath(AProjectRoot));
  Roots := TStringList.Create;
  try
    { Ledger publication stages through the project temporary root while
      holding this same lock. Serialize repair's residue sweep with that
      writer so a live atomic ledger update cannot lose its staged file. }
    if (ATemporaryRoot <> '') and LongPathDirectoryExists(ATemporaryRoot) then
    begin
      WipeDir(ATemporaryRoot);
      ATemporaryRootCleaned := True;
    end;
    ReclaimRoot(RootedPath(AProjectRoot, BUILD_SESSIONS_DIR), False);
    LoadSessionRootLedger(AProjectRoot, ProjectIdentity, Roots);
    for i := 0 to Roots.Count - 1 do
      if SessionRootIdentityMatches(Roots[i], ProjectIdentity) then
        ReclaimRoot(Roots[i], True);
  finally
    Roots.Free;
    LedgerLock.Free;
  end;
end;

procedure RepairBuildSessions(const AProjectRoot: string;
  out ARemoved, ARetained: Integer);
var
  TemporaryRootCleaned: Boolean;
begin
  RepairBuildSessions(AProjectRoot, '', ARemoved, ARetained,
    TemporaryRootCleaned);
end;

var
  CriticalSectionIndex: Integer;

initialization
  for CriticalSectionIndex := Low(PublicationCriticalSections)
    to High(PublicationCriticalSections) do
    InitCriticalSection(PublicationCriticalSections[CriticalSectionIndex]);
  InitCriticalSection(LiveSessionCriticalSection);
  LiveSessionIDs := TStringList.Create;

finalization
  for CriticalSectionIndex := Low(PublicationCriticalSections)
    to High(PublicationCriticalSections) do
    DoneCriticalSection(PublicationCriticalSections[CriticalSectionIndex]);
  FreeAndNil(LiveSessionIDs);
  DoneCriticalSection(LiveSessionCriticalSection);

end.
