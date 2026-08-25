{ LWPT.Core — project identity, error hierarchy, and shared helpers. }
unit LWPT.Core;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  TOML;

const
  PROGRAM_NAME    = 'lwpt';
  PROJECT_NAME    = 'LWPT';
  {$I Version.inc}

  MANIFEST_FILE = PROGRAM_NAME + '.toml';
  LOCKFILE      = PROGRAM_NAME + '.lock';
  CFG_FILE      = PROGRAM_NAME + '.cfg';

  LWPT_DIR      = '.' + PROGRAM_NAME;
  MODULES_DIR   = LWPT_DIR + '/modules';
  ARCHIVES_DIR  = LWPT_DIR + '/archives';
  TMP_DIR       = LWPT_DIR + '/tmp';
  INSTALL_LOCK  = LWPT_DIR + '/install.lock';

  GITIGNORE_LINE = LWPT_DIR + '/tmp/';

  PROCESS_OUTPUT_BUFFER_SIZE = 4096;
  TREE_HASH_PATH_SEPARATOR = '/';
  TREE_HASH_BYTE_NUL = 0;
  TREE_HASH_BYTE_CR = 13;
  TREE_HASH_BYTE_LF = 10;

  PLACEHOLDER_USER       = '{user}';
  PLACEHOLDER_REPOSITORY = '{repository}';
  PLACEHOLDER_REF        = '{ref}';

type
  ELWPTError = class(Exception)
  public
    Operation: string;
    Recovery: string;
  end;
  EFetchError       = class(ELWPTError);
  EVerifyError      = class(ELWPTError);
  EExtractError     = class(ELWPTError);
  ELockfileError    = class(ELWPTError);
  EManifestError    = class(ELWPTError);
  EConcurrencyError = class(ELWPTError);

  TStringArray = array of string;
  TSHA256Progress = procedure of object;

function  FPCExecutable: string;
function  InstantFPCExecutable: string;
procedure AddEnvUnitPathParameters(AParameters: TStrings);
function  NativePath(const APath: string): string;
function  SanitisePathSegment(const AValue: string): string;
procedure AppendRawBytes(var ADestination: string; const ABuffer;
  const ACount: Integer);

function  TomlEscape(const S: string): string;
function  TomlGet(ANode: TTOMLNode; const AKey: string): TTOMLNode;
function  TomlIsString(ANode: TTOMLNode): Boolean;
function  TomlIsInt(ANode: TTOMLNode): Boolean;
function  TomlIsTable(ANode: TTOMLNode): Boolean;
function  TomlIsArray(ANode: TTOMLNode): Boolean;
function  TomlStr(ANode: TTOMLNode; const AKey, ADefault: string): string;
function  TomlInt(ANode: TTOMLNode; const AKey: string; ADefault: Int64): Int64;

function  MatchPathGlob(const APath, APattern: string): Boolean;
function  CanonicalPathGlob(const AGlob: string): string;
procedure CanonicalizePathGlobs(var AGlobs: TStringArray);
procedure ApplyIncludeExclude(const ARoot: string; const AIncludes, AExcludes: TStringArray);

function  CopyFileContent(const ASrc, ADst: string): Boolean;
function  PathContains(const AParent, AChild: string): Boolean;
function  IsDirSymlinkOrJunction(const APath: string): Boolean;
procedure CopyDirTree(const ASrc, ADst: string);
const
  TmpPathDelimiter = '.';
  TmpPathExtension = '.tmp';

function  MakeTmpPath(const ATmpRoot, AHint: string): string;
function  MakeSiblingTmpPath(const APath, ATag: string): string;
procedure WipeDir(const APath: string);
function  AtomicMoveFile(const ASrc, ADst: string): Boolean;
function  AtomicMoveDir(const ASrc, ADst: string): Boolean;
function  AtomicRetainPath(const APath, ATmpRoot, AHint: string;
  out ABackupPath: string): Boolean;
function  AtomicRestorePath(const ABackupPath, ADestination: string): Boolean;
function  AtomicRemovePath(const APath: string): Boolean;
function  AtomicRetainedDestination(const ABackupPath: string): string;
procedure AtomicDiscardRetainedPath(const ABackupPath: string);
function  AtomicReplaceFile(const ASrc, ADst: string): Boolean;
procedure AtomicWriteText(const ADst: string; const ATmpRoot: string; const AContent: TStringList);
procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);
function  SHA256BytesPrefixed(const ABytes: TBytes): string;
function  SHA256Hex(const AData: TBytes): string;
function  SHA256Stream(AStream: TStream;
  AProgress: TSHA256Progress = nil): string;
function  SHA256File(const APath: string): string;
function  CanonicalTreeHashPath(const APath: string;
  const ASourceDelimiter: Char): string;
function  NormalizeTreeHashContent(const ABytes: TBytes): TBytes;
function  HashTree(const APathOrArchive: string): string;

{ Appends every entry of the process environment to ATarget, safe to call
  from concurrent threads. The RTL's GetEnvironmentVariableCount lazily
  initialises a shared global without synchronisation (FPC_EnvCount in
  rtl/objpas/sysutils/osutil.inc, FPC 3.2.2) and counts upward in that
  global; a thread sweeping while another thread runs the first-ever count
  can read a partial value and silently truncate its copy. That truncation
  is how parallel build jobs handed their first compiler children an
  environment missing the trailing entries. The sweep therefore runs once,
  under a lock, into a process-lifetime snapshot that every caller copies.
  The RTL environment view is itself fixed at startup, so the snapshot
  drops nothing a per-call sweep would see. }
procedure AppendProcessEnvironment(const ATarget: TStrings);

implementation

uses
  {$IFDEF UNIX}
  BaseUnix
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows
  {$ENDIF};

{$IFDEF MSWINDOWS}
const
  MOVEFILE_WRITE_THROUGH_LWPT = $00000008;
  FSCTL_GET_REPARSE_POINT_LWPT = $000900A8;
  FSCTL_SET_REPARSE_POINT_LWPT = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
  FILE_FLAG_BACKUP_SEMANTICS_LWPT = $02000000;
  MAX_REPARSE_DATA_BUFFER_SIZE_LWPT = 16 * 1024;
{$ENDIF}

var
  TmpPathCounter: LongInt;
  TmpPathStartedAt: Int64;
  ProcessEnvironmentSnapshot: TStringList = nil;
  ProcessEnvironmentCriticalSection: TRTLCriticalSection;

procedure AppendProcessEnvironment(const ATarget: TStrings);
var
  EnvironmentIndex: Integer;
begin
  EnterCriticalSection(ProcessEnvironmentCriticalSection);
  try
    if not Assigned(ProcessEnvironmentSnapshot) then
    begin
      ProcessEnvironmentSnapshot := TStringList.Create;
      for EnvironmentIndex := 1 to GetEnvironmentVariableCount do
        ProcessEnvironmentSnapshot.Add(
          GetEnvironmentString(EnvironmentIndex));
    end;
    ATarget.AddStrings(ProcessEnvironmentSnapshot);
  finally
    LeaveCriticalSection(ProcessEnvironmentCriticalSection);
  end;
end;

function FPCExecutable: string;
begin
  Result := SysUtils.GetEnvironmentVariable('LWPT_FPC');
  if Result = '' then
    Result := SysUtils.GetEnvironmentVariable('FPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'fpc.exe';
  {$ELSE}
  Result := 'fpc';
  {$ENDIF}
end;

function InstantFPCExecutable: string;
begin
  Result := SysUtils.GetEnvironmentVariable('LWPT_INSTANTFPC');
  if Result = '' then
    Result := SysUtils.GetEnvironmentVariable('INSTANTFPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'instantfpc.exe';
  {$ELSE}
  Result := 'instantfpc';
  {$ENDIF}
end;

procedure AppendRawBytes(var ADestination: string; const ABuffer;
  const ACount: Integer);
var
  PreviousLength: Integer;
begin
  if ACount <= 0 then Exit;
  PreviousLength := Length(ADestination);
  SetLength(ADestination, PreviousLength + ACount);
  Move(ABuffer, ADestination[PreviousLength + 1], ACount);
end;

procedure AddEnvUnitPathParameters(AParameters: TStrings);
var
  Raw, Part : string;
  StartAt, i : Integer;
begin
  Raw := SysUtils.GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  if Raw = '' then
    Exit;

  StartAt := 1;
  for i := 1 to Length(Raw) + 1 do
    if (i > Length(Raw)) or (Raw[i] = PathSeparator) then
    begin
      Part := Copy(Raw, StartAt, i - StartAt);
      if Part <> '' then
      begin
        AParameters.Add('-Fu' + Part);
        AParameters.Add('-Fi' + Part);
      end;
      StartAt := i + 1;
    end;
end;

function NativePath(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  Result := StringReplace(Result, '/', DirectorySeparator, [rfReplaceAll]);
  {$ENDIF}
end;

{ Flatten an arbitrary string into a single path segment: separators
  and drive colons become '_'. Distinct inputs can collide ("a:b" and
  "a_b" both yield "a_b") — callers that key directories off the
  result must detect collisions themselves. }
function SanitisePathSegment(const AValue: string): string;
begin
  Result := StringReplace(AValue, ':', '_', [rfReplaceAll]);
  Result := StringReplace(Result, '/', '_', [rfReplaceAll]);
  Result := StringReplace(Result, '\', '_', [rfReplaceAll]);
end;

{ ===========================================================================
  TOML helpers — manifest + lockfile readers used to drive their
  own partial reader (TTomlReader / TTomlNode record); after the
  TOML.pas conversion (port of GocciaScript's full TOML 1.1 parser)
  the readers go through TTOMLParser + the TTOMLNode class hierarchy.

  Helpers below provide the same conveniences as the old TomlGet /
  TomlStr but operate on TTOMLNode (class) instead of PTomlNode
  (record pointer). Lookup uses TOrderedStringMap.TryGetValue which
  is O(1) average and preserves insertion order for iteration.
  =========================================================================== }
{ TOML basic-string escaping for every LWPT writer (lockfile, manifest
  edits). One implementation so escaping rules can't drift between the
  machine-written and user-edited files. }
function TomlEscape(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '"' : Result := Result + '\"';
      '\' : Result := Result + '\\';
      #9  : Result := Result + '\t';
      #10 : Result := Result + '\n';
      #13 : Result := Result + '\r';
    else
      Result := Result + S[i];
    end;
end;

function TomlGet(ANode: TTOMLNode; const AKey: string): TTOMLNode;
begin
  Result := nil;
  if (ANode = nil) or (ANode.Kind <> tnkTable) then Exit;
  if not ANode.Children.TryGetValue(AKey, Result) then Result := nil;
end;

function TomlIsString(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskString);
end;

function TomlIsInt(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskInteger);
end;

function TomlIsTable(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil) and (ANode.Kind = tnkTable);
end;

function TomlIsArray(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and ((ANode.Kind = tnkArray) or (ANode.Kind = tnkArrayOfTables));
end;

function TomlStr(ANode: TTOMLNode;
  const AKey, ADefault: string): string;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsString(N) then Result := N.ScalarText
  else Result := ADefault;
end;

function TomlInt(ANode: TTOMLNode; const AKey: string;
  ADefault: Int64): Int64;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsInt(N) then Result := StrToInt64Def(N.ScalarText, ADefault)
  else Result := ADefault;
end;

function MatchSegment(const APattern, AName: string): Boolean;
var
  P, N, StarP, StarN: Integer;
begin
  P := 1; N := 1;
  StarP := 0; StarN := 0;
  while N <= Length(AName) do
  begin
    if (P <= Length(APattern)) and (APattern[P] = '?') then
    begin Inc(P); Inc(N); end
    else if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin StarP := P; Inc(P); StarN := N; end
    else if (P <= Length(APattern)) and (APattern[P] = AName[N]) then
    begin Inc(P); Inc(N); end
    else if StarP <> 0 then
    begin P := StarP + 1; Inc(StarN); N := StarN; end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do Inc(P);
  Result := P > Length(APattern);
end;

function SplitPathSegments(const APath: string): TStringArray;
var i, Start, n: Integer;
begin
  SetLength(Result, 0);
  Start := 1;
  for i := 1 to Length(APath) do
    if APath[i] = '/' then
    begin
      if i > Start then
      begin
        n := Length(Result); SetLength(Result, n + 1);
        Result[n] := Copy(APath, Start, i - Start);
      end;
      Start := i + 1;
    end;
  if Start <= Length(APath) then
  begin
    n := Length(Result); SetLength(Result, n + 1);
    Result[n] := Copy(APath, Start, MaxInt);
  end;
end;

function MatchPathGlob(const APath, APattern: string): Boolean;
var
  PathSegs, PatSegs: TStringArray;

  function DoMatch(APathIdx, APatIdx: Integer): Boolean;
  var i: Integer;
  begin
    while (APatIdx < Length(PatSegs))
          and (PathSegs <> nil) and (APathIdx <= High(PathSegs)) do
    begin
      if PatSegs[APatIdx] = '**' then
      begin
        { ** at the end of the pattern matches every remaining path
          segment unconditionally. Otherwise try matching it against
          0..N path segments and recurse on the rest. }
        if APatIdx = High(PatSegs) then Exit(True);
        for i := APathIdx to Length(PathSegs) do
          if DoMatch(i, APatIdx + 1) then Exit(True);
        Exit(False);
      end;
      if not MatchSegment(PatSegs[APatIdx], PathSegs[APathIdx]) then
        Exit(False);
      Inc(APathIdx); Inc(APatIdx);
    end;
    { Trailing ** in the pattern matches a zero-segment tail. }
    while (APatIdx < Length(PatSegs)) and (PatSegs[APatIdx] = '**') do
      Inc(APatIdx);
    Result := (APathIdx >= Length(PathSegs))
          and (APatIdx >= Length(PatSegs));
  end;

begin
  PathSegs := SplitPathSegments(APath);
  PatSegs  := SplitPathSegments(APattern);
  Result := DoMatch(0, 0);
end;

function CanonicalPathGlob(const AGlob: string): string;
begin
  { Manifest paths use '/' on every platform. Treat a backslash authored in
    a glob as the same separator before either identity or matching sees it;
    character case remains significant. }
  Result := StringReplace(AGlob, '\', '/', [rfReplaceAll]);
end;

procedure CanonicalizePathGlobs(var AGlobs: TStringArray);
var Canonical: TStringList; i: Integer;
begin
  Canonical := TStringList.Create;
  try
    Canonical.Sorted := True;
    Canonical.CaseSensitive := True;
    Canonical.Duplicates := dupIgnore;
    for i := 0 to High(AGlobs) do
      Canonical.Add(CanonicalPathGlob(AGlobs[i]));
    SetLength(AGlobs, Canonical.Count);
    for i := 0 to Canonical.Count - 1 do AGlobs[i] := Canonical[i];
  finally
    Canonical.Free;
  end;
end;

{ Apply [dependencies].<name>.include / .exclude globs against the
  freshly-extracted modules tree under ARoot. Files outside the
  include set OR inside the exclude set are deleted; empty dirs are
  reaped after the file pass. ARoot itself is never deleted. }
function PathMatchesAny(const ARelPath: string;
  const AGlobs: TStringArray): Boolean;
var i: Integer;
begin
  for i := 0 to High(AGlobs) do
    if MatchPathGlob(ARelPath, AGlobs[i]) then Exit(True);
  Result := False;
end;

procedure ApplyIncludeExclude(const ARoot: string;
  const AIncludes, AExcludes: TStringArray);

  function ShouldKeep(const ARelPath: string): Boolean;
  begin
    Result := True;
    if (Length(AIncludes) > 0) and not PathMatchesAny(ARelPath, AIncludes) then
      Exit(False);
    if PathMatchesAny(ARelPath, AExcludes) then
      Exit(False);
  end;

  function WalkAndPrune(const ADir, ARelDir: string): Integer;
  var SR: TSearchRec; Base, RelPath, Full: string;
  begin
    Result := 0;
    Base := IncludeTrailingPathDelimiter(ADir);
    if SysUtils.FindFirst(Base + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if ARelDir = '' then RelPath := SR.Name
          else RelPath := ARelDir + '/' + SR.Name;
          Full := Base + SR.Name;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if WalkAndPrune(Full, RelPath) = 0 then
              SysUtils.RemoveDir(Full)
            else
              Inc(Result);
          end
          else if ShouldKeep(RelPath) then
            Inc(Result)
          else
            SysUtils.DeleteFile(Full);
        until SysUtils.FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
  end;

begin
  if (Length(AIncludes) = 0) and (Length(AExcludes) = 0) then Exit;
  WalkAndPrune(ARoot, '');
end;

function CopyFileContent(const ASrc, ADst: string): Boolean;
var SrcS, DstS: TFileStream;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  try
    SrcS := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
    try
      DstS := TFileStream.Create(ADst, fmCreate);
      try
        if SrcS.Size > 0 then DstS.CopyFrom(SrcS, SrcS.Size);
      finally
        DstS.Free;
      end;
    finally
      SrcS.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

{ True when AChild sits inside (or is) the directory AParent. Both
  sides are normalized via ExpandFileName (idempotent on already-
  absolute paths) and compared with a trailing delimiter appended, so
  'a/bc' is not inside 'a/b' and equality counts as contained.
  Case-insensitive on Windows. Purely lexical — symlinks are not
  resolved. This is the one home for the containment compare; the
  copy-cycle guards below and in the extractor's deferred-link pass
  must not grow their own variants. }
function PathContains(const AParent, AChild: string): Boolean;
var P, C: string;
begin
  P := IncludeTrailingPathDelimiter(ExpandFileName(AParent));
  C := IncludeTrailingPathDelimiter(ExpandFileName(AChild));
  {$IFDEF MSWINDOWS}
  Result := SameText(Copy(C, 1, Length(P)), P);
  {$ELSE}
  Result := Copy(C, 1, Length(P)) = P;
  {$ENDIF}
end;

{ True when A and B name the same physical directory, with symlinks
  and junctions followed: dev+inode on Unix, volume serial + file
  index on Windows. False when either path does not resolve. This is
  the stat-level complement to the lexical PathContains. }
{$IFDEF UNIX}
function IsSameDirectory(const A, B: string): Boolean;
var SA, SB: BaseUnix.Stat;
begin
  if FpStat(A, SA) <> 0 then Exit(False);
  if FpStat(B, SB) <> 0 then Exit(False);
  Result := (SA.st_dev = SB.st_dev) and (SA.st_ino = SB.st_ino);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
function IsSameDirectory(const A, B: string): Boolean;

  function OpenDir(const APath: string): THandle;
  begin
    { zero access: metadata only. FILE_FLAG_BACKUP_SEMANTICS is
      required to open a directory handle; reparse points are
      followed so the identity is the final target's. }
    Result := Windows.CreateFileW(PWideChar(UnicodeString(APath)), 0,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
  end;

var
  HA, HB: THandle;
  IA, IB: TByHandleFileInformation;
begin
  Result := False;
  HA := OpenDir(A);
  if HA = INVALID_HANDLE_VALUE then Exit;
  try
    HB := OpenDir(B);
    if HB = INVALID_HANDLE_VALUE then Exit;
    try
      if Windows.GetFileInformationByHandle(HA, IA)
         and Windows.GetFileInformationByHandle(HB, IB) then
        Result := (IA.dwVolumeSerialNumber = IB.dwVolumeSerialNumber)
              and (IA.nFileIndexHigh = IB.nFileIndexHigh)
              and (IA.nFileIndexLow = IB.nFileIndexLow);
    finally
      Windows.CloseHandle(HB);
    end;
  finally
    Windows.CloseHandle(HA);
  end;
end;
{$ENDIF}

{ Recursive directory copy. Used for the local source and for resolving
  directory symlinks during extraction.

  Directory symlinks are never followed: a link cycle in the source
  tree would otherwise recurse until the OS path-length limit,
  duplicating the tree once per nesting level into the destination.
  Skipping them (the link is not reproduced either) matches
  CollectFiles/HashTree, so a staged copy hashes identically to the
  tree it was copied from. File symlinks are copied through (target
  bytes) when the target resolves and skipped when dangling — again
  mirroring CollectFiles. faSymLink must be in the FindFirst mask or
  the attribute is not reported and links look like plain
  directories (or, dangling, vanish entirely).

  A destination inside (or equal to) the source is the other
  unbounded-recursion shape — each level re-enumerates what the
  previous one wrote. That is always a caller bug, so it raises
  rather than being silently skipped. The lexical PathContains check
  catches the plain case before any filesystem work; it cannot see
  ALIASED containment (the source reached through a symlink or
  junction while the destination names the real tree, or a
  case-folding filesystem spelling the same directory two ways), so
  the destination's existing ancestors are additionally compared
  against the source by physical directory identity. Copying FROM an
  aliased root into a disjoint destination stays legal. }
procedure CopyDirTree(const ASrc, ADst: string);

  procedure CopyRec(const ASrcDir, ADstDir: string);
  var SR: TSearchRec; S, D: string;
  begin
    S := IncludeTrailingPathDelimiter(ASrcDir);
    D := IncludeTrailingPathDelimiter(ADstDir);
    ForceDirectories(ADstDir);
    if SysUtils.FindFirst(S + '*', faAnyFile or faSymLink, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faSymLink) <> 0 then
          begin
            if ((SR.Attr and faDirectory) = 0)
               and FileExists(S + SR.Name)
               and not CopyFileContent(S + SR.Name, D + SR.Name) then
              raise EExtractError.CreateFmt(
                'failed to copy "%s" to "%s"', [S + SR.Name, D + SR.Name]);
          end
          else if (SR.Attr and faDirectory) <> 0 then
            CopyRec(S + SR.Name, D + SR.Name)
          else if not CopyFileContent(S + SR.Name, D + SR.Name) then
            raise EExtractError.CreateFmt(
              'failed to copy "%s" to "%s"', [S + SR.Name, D + SR.Name]);
        until SysUtils.FindNext(SR) <> 0;
      finally
        SysUtils.FindClose(SR);
      end;
  end;

var
  Anc, Parent: string;
begin
  if PathContains(ASrc, ADst) then
    raise EExtractError.CreateFmt(
      'refusing to copy "%s" into itself ("%s")', [ASrc, ADst]);
  { Physical containment walk: if any existing ancestor of the
    destination IS the source directory (same dev+inode / volume+file
    index), the destination resolves into the source even though the
    spellings differ. Checked once up front — before ForceDirectories
    pollutes the source — and not re-checked per recursion level:
    children of a disjoint pair stay disjoint because directory
    symlinks are never followed. }
  Anc := ExcludeTrailingPathDelimiter(ExpandFileName(ADst));
  while Anc <> '' do
  begin
    if IsSameDirectory(ASrc, Anc) then
      raise EExtractError.CreateFmt(
        'refusing to copy "%s" into itself ("%s" resolves into it)',
        [ASrc, ADst]);
    Parent := ExtractFileDir(Anc);
    if Parent = Anc then Break;
    Anc := Parent;
  end;
  CopyRec(ASrc, ADst);
end;

function ProcessIdStr: string;
begin
  Result := IntToStr(GetProcessID);
end;

{ Base36 keeps the once-per-process stamp inside the pre-hardening
  temp-name length budget; atomic-write callers can sit close to
  filesystem path limits. }
function EncodeBase36(AValue: Int64): string;
const
  Digits = '0123456789abcdefghijklmnopqrstuvwxyz';
begin
  if AValue <= 0 then Exit('0');
  Result := '';
  while AValue > 0 do
  begin
    Result := Digits[(AValue mod 36) + 1] + Result;
    AValue := AValue div 36;
  end;
end;

function MakeUniqueTmpPath(const ARoot, APrefix: string): string;
var
  Sequence: Cardinal;
begin
  repeat
    Sequence := Cardinal(InterlockedIncrement(TmpPathCounter));
    Result := IncludeTrailingPathDelimiter(ARoot)
            + APrefix + TmpPathDelimiter + ProcessIdStr + TmpPathDelimiter
            + EncodeBase36(TmpPathStartedAt) + TmpPathDelimiter
            + IntToStr(Int64(Sequence)) + TmpPathExtension;
  until (not FileExists(Result)) and (not DirectoryExists(Result));
end;

function MakeSiblingTmpPath(const APath, ATag: string): string;
var
  Dir: string;
begin
  { A bare filename has no directory component; ExtractFileDir yields ''
    and IncludeTrailingPathDelimiter('') would root the sibling at the
    filesystem root. The sibling of a bare relative path lives in the
    current directory. }
  Dir := ExtractFileDir(APath);
  if Dir = '' then Dir := '.';
  Result := MakeUniqueTmpPath(Dir,
    ExtractFileName(APath) + TmpPathDelimiter + ATag);
end;

function MakeTmpPath(const ATmpRoot, AHint: string): string;
const
  DirectoryCreateAttempts = 32;
var
  Attempt: Integer;
begin
  { ForceDirectories is process-local race-prone: when two processes recurse
    through the same missing hierarchy, one can lose an intermediate mkdir to
    EEXIST and return before the winner creates the final directory. Validate
    the postcondition and retry briefly while that competing creation lands. }
  for Attempt := 1 to DirectoryCreateAttempts do
  begin
    if DirectoryExists(ATmpRoot) then Break;
    ForceDirectories(ATmpRoot);
    if DirectoryExists(ATmpRoot) then Break;
    Sleep(1);
  end;
  Result := MakeUniqueTmpPath(ATmpRoot, AHint);
end;

function IsDirSymlinkOrJunction(const APath: string): Boolean;
{$IFDEF UNIX}
var Info: BaseUnix.Stat;
begin
  if FpLstat(APath, Info) <> 0 then Exit(False);
  Result := FpS_ISLNK(Info.st_mode);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var Attrs: Cardinal;
begin
  Attrs := Windows.GetFileAttributesW(PWideChar(UnicodeString(APath)));
  if Attrs = $FFFFFFFF then Exit(False);
  Result := (Attrs and $400) <> 0;  { FILE_ATTRIBUTE_REPARSE_POINT }
end;
{$ENDIF}

function RemoveDirLink(const APath: string): Boolean;
{$IFDEF UNIX}
begin
  Result := FpUnlink(APath) = 0;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var Attrs: Cardinal;
begin
  Attrs := Windows.GetFileAttributesW(PWideChar(UnicodeString(APath)));
  if Attrs = $FFFFFFFF then Exit(False);
  if (Attrs and Windows.FILE_ATTRIBUTE_DIRECTORY) <> 0 then
    Result := Windows.RemoveDirectoryW(PWideChar(UnicodeString(APath)))
  else
    Result := Windows.DeleteFileW(PWideChar(UnicodeString(APath)));
end;
{$ENDIF}

function ReadLinkSnapshot(const APath: string; out AData: TBytes;
  out AIsDirectory: Boolean): Boolean;
{$IFDEF UNIX}
var
  Buffer: array[0..4095] of Char;
  Count: ssize_t;
begin
  AData := nil;
  AIsDirectory := False;
  Count := FpReadLink(PChar(APath), @Buffer[0], SizeOf(Buffer));
  if (Count < 0) or (Count = SizeOf(Buffer)) then Exit(False);
  SetLength(AData, Count);
  if Count > 0 then Move(Buffer[0], AData[0], Count);
  Result := True;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Attrs, Flags, Returned: Cardinal;
  Handle: THandle;
begin
  AData := nil;
  AIsDirectory := False;
  Attrs := Windows.GetFileAttributesW(PWideChar(UnicodeString(APath)));
  if (Attrs = $FFFFFFFF)
     or ((Attrs and Windows.FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
    Exit(False);
  AIsDirectory := (Attrs and Windows.FILE_ATTRIBUTE_DIRECTORY) <> 0;
  Flags := FILE_FLAG_OPEN_REPARSE_POINT_LWPT;
  if AIsDirectory then Flags := Flags or FILE_FLAG_BACKUP_SEMANTICS_LWPT;
  Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)), 0,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE, nil, Windows.OPEN_EXISTING, Flags, 0);
  if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then Exit(False);
  try
    SetLength(AData, MAX_REPARSE_DATA_BUFFER_SIZE_LWPT);
    Result := Windows.DeviceIoControl(Handle,
      FSCTL_GET_REPARSE_POINT_LWPT, nil, 0, @AData[0], Length(AData),
      Returned, nil);
    if Result then SetLength(AData, Returned)
    else AData := nil;
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

function WriteLinkSnapshot(const APath: string; const AData: TBytes;
  const AIsDirectory: Boolean): Boolean;
{$IFDEF UNIX}
var Target: string;
begin
  if Length(AData) = 0 then Target := ''
  else SetString(Target, PAnsiChar(@AData[0]), Length(AData));
  Result := FpSymlink(PChar(Target), PChar(APath)) = 0;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Flags, Returned: Cardinal;
  Handle: THandle;
begin
  Result := False;
  if Length(AData) = 0 then Exit;
  if AIsDirectory then
  begin
    if not Windows.CreateDirectoryW(PWideChar(UnicodeString(APath)), nil) then
      Exit;
  end
  else
  begin
    Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
      Windows.GENERIC_WRITE, 0, nil, Windows.CREATE_NEW,
      Windows.FILE_ATTRIBUTE_NORMAL, 0);
    if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then Exit;
    Windows.CloseHandle(Handle);
  end;
  Flags := FILE_FLAG_OPEN_REPARSE_POINT_LWPT;
  if AIsDirectory then Flags := Flags or FILE_FLAG_BACKUP_SEMANTICS_LWPT;
  Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
    Windows.GENERIC_WRITE, 0, nil, Windows.OPEN_EXISTING, Flags, 0);
  if Handle <> THandle(Windows.INVALID_HANDLE_VALUE) then
    try
      Result := Windows.DeviceIoControl(Handle,
        FSCTL_SET_REPARSE_POINT_LWPT, @AData[0], Length(AData), nil, 0,
        Returned, nil);
    finally
      Windows.CloseHandle(Handle);
    end;
  if not Result then
    if AIsDirectory then
      Windows.RemoveDirectoryW(PWideChar(UnicodeString(APath)))
    else
      Windows.DeleteFileW(PWideChar(UnicodeString(APath)));
end;
{$ENDIF}

function CopyLinkObject(const ASrc, ADst: string): Boolean;
var Data: TBytes; IsDirectory: Boolean;
begin
  Result := ReadLinkSnapshot(ASrc, Data, IsDirectory)
    and WriteLinkSnapshot(ADst, Data, IsDirectory);
end;

function PathExists(const APath: string): Boolean; inline;
begin
  Result := FileExists(APath) or DirectoryExists(APath)
        or IsDirSymlinkOrJunction(APath);
end;

procedure RemovePath(const APath: string);
begin
  if IsDirSymlinkOrJunction(APath) then
  begin
    if not RemoveDirLink(APath) then
      raise EExtractError.CreateFmt('failed to remove link "%s"', [APath]);
    Exit;
  end;
  if DirectoryExists(APath) then
    WipeDir(APath)
  else if FileExists(APath) and not SysUtils.DeleteFile(APath) then
    raise EExtractError.CreateFmt('failed to delete "%s"', [APath]);
end;

{ faSymLink must be in the FindFirst mask: without it the enumeration
  stats THROUGH each link, so a dangling link (target already deleted —
  which the wipe itself produces when a link's target dir is wiped
  before the link's own entry comes up) is not returned at all,
  survives the wipe, and the final RemoveDir fails on the non-empty
  dir. Links are unlinked, never followed — wiping through one would
  destroy content outside APath. }
procedure WipeDir(const APath: string);
var SR: TSearchRec; Base, Full: string;
begin
  if IsDirSymlinkOrJunction(APath) then
  begin
    if not RemoveDirLink(APath) then
      raise EExtractError.CreateFmt('failed to remove link "%s"', [APath]);
    Exit;
  end;
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := Base + SR.Name;
        if (SR.Attr and faSymLink) <> 0 then
        begin
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if not RemoveDirLink(Full) then
              raise EExtractError.CreateFmt(
                'failed to remove link "%s"', [Full]);
          end
          else if not SysUtils.DeleteFile(Full) then
            raise EExtractError.CreateFmt('failed to delete "%s"', [Full]);
        end
        else if (SR.Attr and faDirectory) <> 0 then
          WipeDir(Full)
        else if not SysUtils.DeleteFile(Full) then
          raise EExtractError.CreateFmt('failed to delete "%s"', [Full]);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  if not SysUtils.RemoveDir(APath) then
    raise EExtractError.CreateFmt('failed to remove directory "%s"', [APath]);
end;

function AtomicMoveFile(const ASrc, ADst: string): Boolean;
var
  DstDir, StagedCopy: string;
begin
  if not FileExists(ASrc) then Exit(False);
  DstDir := ExtractFileDir(ADst);
  if DstDir <> '' then ForceDirectories(DstDir);
  { One same-filesystem replacement is the common path. Unlike renaming the
    old destination aside first, this never creates a reader-visible gap. }
  if AtomicReplaceFile(ASrc, ADst) then Exit(True);

  { EXDEV (or its Windows equivalent): copy to a unique sibling on the
    destination filesystem, then perform the same one-operation replacement.
    A crash can leave only the unaddressed sibling; readers keep seeing either
    the complete old destination or the complete new one. }
  StagedCopy := MakeSiblingTmpPath(ADst, 'copy');
  Result := False;
  try
    if not CopyFileContent(ASrc, StagedCopy) then Exit;
    if not AtomicReplaceFile(StagedCopy, ADst) then Exit;
    { Publication is already complete. A failed source cleanup is recoverable
      residue, not a failed move that should trigger rollback of the new path. }
    SysUtils.DeleteFile(ASrc);
    Result := True;
  finally
    if FileExists(StagedCopy) then SysUtils.DeleteFile(StagedCopy);
  end;
end;

function AtomicMoveDir(const ASrc, ADst: string): Boolean;
var
  DstDir, Backup: string;
  SourceIsLink: Boolean;

  procedure RestoreBackup;
  begin
    if Backup = '' then Exit;
    if PathExists(ADst) then RemovePath(ADst);
    if PathExists(Backup) then SysUtils.RenameFile(Backup, ADst);
  end;

begin
  SourceIsLink := IsDirSymlinkOrJunction(ASrc);
  if (not DirectoryExists(ASrc)) and (not SourceIsLink) then Exit(False);
  DstDir := ExtractFileDir(ExcludeTrailingPathDelimiter(ADst));
  if DstDir <> '' then ForceDirectories(DstDir);
  Backup := '';
  Result := False;

  if PathExists(ADst) then
  begin
    Backup := MakeSiblingTmpPath(ExcludeTrailingPathDelimiter(ADst), 'old');
    if not SysUtils.RenameFile(ADst, Backup) then Exit(False);
  end;

  try
    Result := SysUtils.RenameFile(ASrc, ADst);
    if (not Result) and (not SourceIsLink) then
    begin
      { EXDEV path: recursive copy + wipe-source. The old destination
        remains recoverable until the copy finishes. }
      ForceDirectories(ADst);
      CopyDirTree(ASrc, ADst);
      WipeDir(ASrc);
      Result := DirectoryExists(ADst);
    end;

    if Result then
    begin
      if Backup <> '' then RemovePath(Backup);
      Exit;
    end;

    RestoreBackup;
  except
    RestoreBackup;
    raise;
  end;
end;

function SnapshotPathHash(const APath: string): string;
var LinkData: TBytes; LinkIsDirectory: Boolean;
begin
  { A link is a committed filesystem object in its own right. Hash its raw
    target/reparse data, not the tree currently reached through it, so rollback
    preserves both the original type and target even when it is dangling. }
  if IsDirSymlinkOrJunction(APath) then
  begin
    if not ReadLinkSnapshot(APath, LinkData, LinkIsDirectory) then
      raise EExtractError.CreateFmt(
        'failed to read retained link metadata for "%s"', [APath]);
    if LinkIsDirectory then Result := 'link-dir:' + SHA256Hex(LinkData)
    else Result := 'link-file:' + SHA256Hex(LinkData);
  end
  else if DirectoryExists(APath) then
    Result := 'tree:' + HashTree(APath)
  else if FileExists(APath) then
    Result := 'file:' + SHA256File(APath)
  else
    Result := 'absent';
end;

{ Copy the current transaction target below the caller-owned rollback root.
  The live destination remains readable until publication's final swap. A
  sidecar records both the destination and validated content identity, so an
  interrupted transaction can be recovered before tmp cleanup. }
function AtomicRetainPath(const APath, ATmpRoot, AHint: string;
  out ABackupPath: string): Boolean;
var Meta: TStringList; Expected, Actual: string;
begin
  ABackupPath := MakeTmpPath(ATmpRoot, 'rollback-' + AHint);
  Expected := SnapshotPathHash(APath);
  Result := False;
  try
    if Expected = 'absent' then
      Actual := 'absent'
    else if IsDirSymlinkOrJunction(APath) then
    begin
      if not CopyLinkObject(APath, ABackupPath) then Exit;
      Actual := SnapshotPathHash(ABackupPath);
    end
    else if FileExists(APath) and not IsDirSymlinkOrJunction(APath) then
    begin
      if not CopyFileContent(APath, ABackupPath) then Exit;
      Actual := SnapshotPathHash(ABackupPath);
    end
    else
    begin
      ForceDirectories(ABackupPath);
      CopyDirTree(APath, ABackupPath);
      Actual := SnapshotPathHash(ABackupPath);
    end;
    if Actual <> Expected then Exit;
    Meta := TStringList.Create;
    try
      Meta.Add(APath);
      Meta.Add(Expected);
      AtomicWriteText(ABackupPath + '.rollback', ATmpRoot, Meta);
    finally
      Meta.Free;
    end;
    Result := True;
  except
    AtomicRemovePath(ABackupPath);
    AtomicRemovePath(ABackupPath + '.rollback');
    raise;
  end;
end;

function AtomicRemovePath(const APath: string): Boolean;
begin
  Result := True;
  if not PathExists(APath) then Exit;
  try
    RemovePath(APath);
  except
    Result := False;
  end;
end;

{ Restore a retained path after validating its sidecar and saved bytes. An
  `absent` sidecar means the destination did not exist before the transaction,
  so rollback consists only of removing the replacement. }
function AtomicRestorePath(const ABackupPath, ADestination: string): Boolean;
var Meta: TStringList; Expected: string;
begin
  if SameText(SysUtils.GetEnvironmentVariable(
       PROJECT_NAME + '_TEST_THROW_RESTORE_FOR'),
       ExtractFileName(ExcludeTrailingPathDelimiter(ADestination))) then
    raise EExtractError.CreateFmt(
      'injected restore exception for "%s"', [ADestination]);
  Result := False;
  if not FileExists(ABackupPath + '.rollback') then Exit;
  Meta := TStringList.Create;
  try
    Meta.LoadFromFile(ABackupPath + '.rollback');
    if Meta.Count < 2 then Exit;
    if Meta[0] <> ADestination then Exit;
    Expected := Meta[1];
  finally
    Meta.Free;
  end;
  if Expected = 'absent' then
  begin
    Result := AtomicRemovePath(ADestination);
    if Result then AtomicRemovePath(ABackupPath + '.rollback');
    Exit;
  end;
  { Validate before touching the published destination. A corrupt or missing
    backup remains available for diagnosis and never destroys the current
    readable tree while rollback is already degraded. }
  if SnapshotPathHash(ABackupPath) <> Expected then Exit;
  if not AtomicRemovePath(ADestination) then Exit(False);
  if FileExists(ABackupPath) and not IsDirSymlinkOrJunction(ABackupPath) then
    Result := AtomicMoveFile(ABackupPath, ADestination)
  else
    Result := AtomicMoveDir(ABackupPath, ADestination);
  if Result then AtomicRemovePath(ABackupPath + '.rollback');
end;

function AtomicRetainedDestination(const ABackupPath: string): string;
var Meta: TStringList;
begin
  Result := '';
  if ABackupPath = '' then Exit;
  if not FileExists(ABackupPath + '.rollback') then Exit;
  Meta := TStringList.Create;
  try
    Meta.LoadFromFile(ABackupPath + '.rollback');
    if Meta.Count > 0 then Result := Meta[0];
  finally
    Meta.Free;
  end;
end;

procedure AtomicDiscardRetainedPath(const ABackupPath: string);
begin
  if ABackupPath = '' then Exit;
  AtomicRemovePath(ABackupPath);
  AtomicRemovePath(ABackupPath + '.rollback');
end;

{ Replace a file in one filesystem operation. Unlike AtomicMoveFile this
  helper never renames the old destination aside, because doing so creates
  an observable missing-path window. It is intentionally strict: callers
  must stage the source on the same filesystem as the destination. }
function AtomicReplaceFile(const ASrc, ADst: string): Boolean;
var
  DstDir: string;
begin
  if not FileExists(ASrc) then Exit(False);
  DstDir := ExtractFileDir(ADst);
  if DstDir <> '' then ForceDirectories(DstDir);
  {$IFDEF UNIX}
  Result := FpRename(PChar(ASrc), PChar(ADst)) = 0;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := Windows.MoveFileExW(
    PWideChar(UnicodeString(ASrc)),
    PWideChar(UnicodeString(ADst)),
    Windows.MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH_LWPT);
  {$ENDIF}
end;

procedure EnsureDstDir(const ADst: string);
var D: string;
begin
  D := ExtractFileDir(ADst);
  if D <> '' then ForceDirectories(D);
end;

procedure AtomicWriteText(const ADst: string;
  const ATmpRoot: string; const AContent: TStringList);
var Tmp: string;
begin
  { The destination name adds no uniqueness and can push a project-local
    staging path past Windows' directory-path ceiling in a deep checkout. }
  Tmp := MakeTmpPath(ATmpRoot, 'write');
  EnsureDstDir(ADst);
  AContent.SaveToFile(Tmp);
  { The common same-filesystem path is one replacement operation and avoids
    AtomicMoveFile's recoverable sibling backup, whose longer name can exceed
    the Windows path ceiling in a deep project. Keep its EXDEV fallback. }
  if AtomicReplaceFile(Tmp, ADst) then Exit;
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    SysUtils.DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);
var Tmp: string; Stream: TFileStream;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write');
  EnsureDstDir(ADst);
  Stream := TFileStream.Create(Tmp, fmCreate);
  try
    if Length(ABytes) > 0 then Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
  if AtomicReplaceFile(Tmp, ADst) then Exit;
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    SysUtils.DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

{ Sha256 of a TBytes for the [resolved].archiveHash field. The same hex
  shape as HashTree ('sha256:<hex>') so callers can compare directly. }
function SHA256BytesPrefixed(const ABytes: TBytes): string;
begin
  Result := 'sha256:' + SHA256Hex(ABytes);
end;

type
  TSHA256Digest = array[0..31] of Byte;
  TSHA256Context = record
    State: array[0..7] of Cardinal;
    Buffer: array[0..63] of Byte;
    BufferLength: Integer;
    TotalLength: QWord;
  end;

{ SHA-256 performs intentional modular arithmetic on 32-bit values
  (Cardinals): the compression loop's `temp1 := h + s1 + ch + K[t] + W[t]`
  and `W[t] := W[t-16] + s0 + W[t-7] + s1` deliberately wrap on
  overflow — that's how the algorithm produces correct hashes. FPC's
  range check ({$R+}) detects the intermediate Int64-promoted sums
  exceeding Cardinal's range and raises EangeError. Disable range
  checking inside this function so the modular arithmetic runs as
  written. The unit tests (NIST vectors) don't catch this because
  the test compiler doesn't pass -Cr; lwpt's dev build does, and the
  network-source archive-hash path was the first call site to hit
  it after the matching ADR. }
{$PUSH}{$R-}{$Q-}
procedure SHA256Transform(var AContext: TSHA256Context;
  const ABlock: array of Byte);
const
  K: array[0..63] of Cardinal = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);
var
  W: array[0..63] of Cardinal;
  t: Integer;
  a,b,c,d,e,f,g,h, s0,s1, ch, maj, temp1, temp2: Cardinal;

  function RotR(x: Cardinal; n: Byte): Cardinal; inline;
  begin
    Result := (x shr n) or (x shl (32 - n));
  end;

begin
    for t := 0 to 15 do
      W[t] := (Cardinal(ABlock[t*4    ]) shl 24) or
              (Cardinal(ABlock[t*4 + 1]) shl 16) or
              (Cardinal(ABlock[t*4 + 2]) shl 8) or
              (Cardinal(ABlock[t*4 + 3]));
    for t := 16 to 63 do
    begin
      s0 := RotR(W[t-15],7) xor RotR(W[t-15],18) xor (W[t-15] shr 3);
      s1 := RotR(W[t-2],17) xor RotR(W[t-2],19) xor (W[t-2] shr 10);
      W[t] := W[t-16] + s0 + W[t-7] + s1;
    end;

    a:=AContext.State[0]; b:=AContext.State[1];
    c:=AContext.State[2]; d:=AContext.State[3];
    e:=AContext.State[4]; f:=AContext.State[5];
    g:=AContext.State[6]; h:=AContext.State[7];

    for t := 0 to 63 do
    begin
      s1   := RotR(e,6) xor RotR(e,11) xor RotR(e,25);
      ch   := (e and f) xor ((not e) and g);
      temp1:= h + s1 + ch + K[t] + W[t];
      s0   := RotR(a,2) xor RotR(a,13) xor RotR(a,22);
      maj  := (a and b) xor (a and c) xor (b and c);
      temp2:= s0 + maj;
      h:=g; g:=f; f:=e; e:=d + temp1;
      d:=c; c:=b; b:=a; a:=temp1 + temp2;
    end;

    Inc(AContext.State[0],a); Inc(AContext.State[1],b);
    Inc(AContext.State[2],c); Inc(AContext.State[3],d);
    Inc(AContext.State[4],e); Inc(AContext.State[5],f);
    Inc(AContext.State[6],g); Inc(AContext.State[7],h);
end;

procedure SHA256Init(var AContext: TSHA256Context);
begin
  FillChar(AContext, SizeOf(AContext), 0);
  AContext.State[0]:=$6a09e667; AContext.State[1]:=$bb67ae85;
  AContext.State[2]:=$3c6ef372; AContext.State[3]:=$a54ff53a;
  AContext.State[4]:=$510e527f; AContext.State[5]:=$9b05688c;
  AContext.State[6]:=$1f83d9ab; AContext.State[7]:=$5be0cd19;
end;

procedure SHA256Update(var AContext: TSHA256Context; const AData;
  const ACount: Integer);
var
  Count, Take: Integer;
  Cursor: PByte;
begin
  if ACount <= 0 then Exit;
  Cursor := @AData;
  Count := ACount;
  Inc(AContext.TotalLength, Count);
  while Count > 0 do
  begin
    Take := SizeOf(AContext.Buffer) - AContext.BufferLength;
    if Take > Count then Take := Count;
    Move(Cursor^, AContext.Buffer[AContext.BufferLength], Take);
    Inc(Cursor, Take);
    Inc(AContext.BufferLength, Take);
    Dec(Count, Take);
    if AContext.BufferLength = SizeOf(AContext.Buffer) then
    begin
      SHA256Transform(AContext, AContext.Buffer);
      AContext.BufferLength := 0;
    end;
  end;
end;

procedure SHA256Final(var AContext: TSHA256Context;
  out ADigest: TSHA256Digest);
var
  BitLength: QWord;
  Index: Integer;
begin
  BitLength := AContext.TotalLength * 8;
  AContext.Buffer[AContext.BufferLength] := $80;
  Inc(AContext.BufferLength);
  if AContext.BufferLength > 56 then
  begin
    FillChar(AContext.Buffer[AContext.BufferLength],
      SizeOf(AContext.Buffer) - AContext.BufferLength, 0);
    SHA256Transform(AContext, AContext.Buffer);
    AContext.BufferLength := 0;
  end;
  FillChar(AContext.Buffer[AContext.BufferLength],
    56 - AContext.BufferLength, 0);
  for Index := 0 to 7 do
    AContext.Buffer[63 - Index] := Byte((BitLength shr (8 * Index)) and $FF);
  SHA256Transform(AContext, AContext.Buffer);

  for Index := 0 to 7 do
  begin
    ADigest[Index*4    ] := Byte((AContext.State[Index] shr 24) and $FF);
    ADigest[Index*4 + 1] := Byte((AContext.State[Index] shr 16) and $FF);
    ADigest[Index*4 + 2] := Byte((AContext.State[Index] shr 8) and $FF);
    ADigest[Index*4 + 3] := Byte( AContext.State[Index]         and $FF);
  end;
  FillChar(AContext, SizeOf(AContext), 0);
end;

function SHA256Bytes(const AData: TBytes): TSHA256Digest;
var
  Context: TSHA256Context;
begin
  SHA256Init(Context);
  if Length(AData) > 0 then SHA256Update(Context, AData[0], Length(AData));
  SHA256Final(Context, Result);
end;
{$POP}

function SHA256DigestHex(const ADigest: TSHA256Digest): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(ADigest) do
    Result := Result + LowerCase(IntToHex(ADigest[Index], 2));
end;

function SHA256Hex(const AData: TBytes): string;
begin
  Result := SHA256DigestHex(SHA256Bytes(AData));
end;

function SHA256Stream(AStream: TStream;
  AProgress: TSHA256Progress): string;
var
  Buffer: array[0..65535] of Byte;
  Context: TSHA256Context;
  Digest: TSHA256Digest;
  ReadCount: Integer;
begin
  AStream.Position := 0;
  try
    SHA256Init(Context);
    repeat
      if Assigned(AProgress) then AProgress;
      ReadCount := AStream.Read(Buffer[0], SizeOf(Buffer));
      if ReadCount > 0 then SHA256Update(Context, Buffer[0], ReadCount);
    until ReadCount = 0;
    if Assigned(AProgress) then AProgress;
    SHA256Final(Context, Digest);
    Result := SHA256DigestHex(Digest);
  finally
    AStream.Position := 0;
  end;
end;

function SHA256File(const APath: string): string;
var
  Stream: TFileStream;
begin
  if not FileExists(APath) then Exit('');
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := SHA256Stream(Stream);
  finally
    Stream.Free;
  end;
end;

function CanonicalTreeHashPath(const APath: string;
  const ASourceDelimiter: Char): string;
begin
  { Replace only the caller's native delimiter: backslashes are valid
    filename characters on POSIX and must remain hash input there. }
  Result := StringReplace(APath, ASourceDelimiter,
    TREE_HASH_PATH_SEPARATOR, [rfReplaceAll]);
end;

{ Normalize a hashed file's bytes so the tree digest is independent of
  checkout line endings: a CRLF Windows working tree must hash the same
  as the LF tree the lockfile was written from. The content analogue of
  CanonicalTreeHashPath / #116. Text files: every CRLF (#13#10) becomes
  LF (#10); a lone CR is left as-is (git's convention). Binary files —
  any that contain a NUL byte, the standard git heuristic — are hashed
  VERBATIM, so their exact bytes are never altered. LF-committed content
  is unchanged by this, so every existing lockfile keeps verifying.

  The collapse is intentional and does not weaken artifact integrity:
  CRLF and LF forms of the same NUL-free text hash alike ON PURPOSE, so
  a CRLF checkout of the extracted modules verifies against an LF-written
  lockfile. computedHash's job is "was the installed tree modified",
  where a checkout-introduced line-ending flip is a false positive to be
  tolerated, not detected. Byte-exact integrity of the fetched package is
  a separate anchor: archiveHash is the raw SHA-256 of the .tar.gz (never
  normalized), and `install --frozen` checks it alongside this tree hash.
  So the only computedHash pre-images that collide are line-ending
  variants of identical text; any real byte change to the source-of-truth
  archive is still caught. }
function NormalizeTreeHashContent(const ABytes: TBytes): TBytes;
var
  Read, Write, Len : Integer;
begin
  Len := Length(ABytes);
  { Binary guard: a single NUL byte means hash verbatim — bail before
    allocating a normalized copy. }
  for Read := 0 to Len - 1 do
    if ABytes[Read] = TREE_HASH_BYTE_NUL then Exit(ABytes);
  { Single pass: size the output once at the input length, drop the CR of
    every CRLF pair in place, then trim to the bytes actually written. }
  SetLength(Result, Len);
  Write := 0;
  Read := 0;
  while Read < Len do
  begin
    if (ABytes[Read] = TREE_HASH_BYTE_CR) and (Read + 1 < Len)
       and (ABytes[Read + 1] = TREE_HASH_BYTE_LF) then
      Inc(Read)
    else
    begin
      Result[Write] := ABytes[Read];
      Inc(Write);
      Inc(Read);
    end;
  end;
  SetLength(Result, Write);
end;

{ Hash of an installed package: SHA-256 over every extracted file's bytes,
  visited in sorted relative-path order so the digest is stable regardless
  of filesystem enumeration order or which mirror served the archive.
  This is the value that goes in lwpt.lock's computedHash.

  Directory symlinks are never descended into: a link cycle would recurse
  forever, and the linked bytes are hashed where they really live. File
  symlinks still contribute (their target's bytes are read through the
  link, as before) — but only when the target resolves: a dangling link
  was invisible to the old faAnyFile-only enumeration, so it must stay
  excluded or HashTree fails opening it. faSymLink must be in the
  FindFirst mask or the attribute is not reported and links look like
  plain directories (or, dangling, vanish entirely). }
procedure CollectFiles(const ARoot, ARel: string; AList: TStringList);
var SR: TSearchRec; Path, RelPath: string;
begin
  Path := IncludeTrailingPathDelimiter(ARoot + ARel);
  if SysUtils.FindFirst(Path + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        RelPath := ARel + SR.Name;
        if (SR.Attr and faSymLink) <> 0 then
        begin
          if ((SR.Attr and faDirectory) = 0)
             and FileExists(Path + SR.Name) then
            AList.Add(CanonicalTreeHashPath(RelPath, PathDelim));
        end
        else if (SR.Attr and faDirectory) <> 0 then
          CollectFiles(ARoot, RelPath + PathDelim, AList)
        else
          AList.Add(CanonicalTreeHashPath(RelPath, PathDelim));
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

{ Fold-order comparator for HashTree: ASCII case-insensitive, byte-wise,
  ordinal tiebreak — a platform-independent pin of the order every
  existing lockfile was written with. TStringList.Sort compares with
  AnsiCompareText, which is ASCII-uppercase byte compare on POSIX but
  CompareStringW WORD-SORT on Windows, where '-' is primary-ignorable:
  the same tree of hyphenated filenames folds in a different order and
  the digest diverges with byte-identical content ("tree hash mismatch"
  on a Windows checkout — the third guise of the #78 family, after path
  separators (#116) and the fingerprint join). Verified byte-for-byte
  against a real divergence: ASCII-CI order reproduces the POSIX-written
  lockfile digest exactly; the hyphen-ignoring order reproduces the
  Windows disk digest exactly. Do not "simplify" this to a plain ordinal
  compare — that is a THIRD order and would invalidate every lockfile. }
function TreeHashPathCompare(AList: TStringList;
  AIndex1, AIndex2: Integer): Integer;
var
  A, B : string;
  i, LA, LB : Integer;
  CA, CB : Char;
begin
  A := AList[AIndex1];
  B := AList[AIndex2];
  LA := Length(A);
  LB := Length(B);
  i := 1;
  while (i <= LA) and (i <= LB) do
  begin
    CA := A[i];
    CB := B[i];
    if CA in ['a'..'z'] then Dec(CA, 32);
    if CB in ['a'..'z'] then Dec(CB, 32);
    if CA <> CB then Exit(Ord(CA) - Ord(CB));
    Inc(i);
  end;
  Result := LA - LB;
  { Case-insensitively equal but distinct paths (a case collision the
    default Windows/macOS filesystems cannot even host): break the tie
    ordinally so the order is still deterministic everywhere. This does
    NOT change any existing digest — the prior TStringList.Sort
    (AnsiCompareText) already ordered such a pair uppercase-first and
    input-order-stably ('A.pas' before 'a.pas'), which CompareStr
    reproduces byte-for-byte (verified against FPC's Sort). Where the
    old order could still differ was ACROSS platforms — the exact
    non-portability this comparator exists to remove — so no lockfile
    that was portable is invalidated. }
  if Result = 0 then Result := CompareStr(A, B);
end;

function HashTree(const APathOrArchive: string): string;
var
  Files : TStringList;
  Acc   : TBytes;
  i, n  : Integer;
  Chunk : TBytes;
  FileBytes : TBytes;
  FS    : TFileStream;
  FullPath : string;
begin
  { directory: hash the sorted file tree }
  if DirectoryExists(APathOrArchive) then
  begin
    Files := TStringList.Create;
    try
      CollectFiles(IncludeTrailingPathDelimiter(APathOrArchive), '', Files);
      Files.CustomSort(@TreeHashPathCompare);
      SetLength(Acc, 0);
      for i := 0 to Files.Count - 1 do
      begin
        { fold the relative path in too, so renames change the hash }
        Chunk := BytesOf(Files[i] + #10);
        n := Length(Acc);
        SetLength(Acc, n + Length(Chunk));
        if Length(Chunk) > 0 then Move(Chunk[0], Acc[n], Length(Chunk));

        FullPath := NativePath(IncludeTrailingPathDelimiter(APathOrArchive)
          + Files[i]);
        FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
        try
          SetLength(FileBytes, FS.Size);
          if FS.Size > 0 then FS.ReadBuffer(FileBytes[0], FS.Size);
        finally
          FS.Free;
        end;
        { Fold NORMALIZED content: a CRLF checkout hashes as its LF tree
          (NormalizeTreeHashContent), so a Windows working tree verifies
          against a POSIX-written lockfile. Binary files pass through
          verbatim via that helper's NUL guard. }
        FileBytes := NormalizeTreeHashContent(FileBytes);
        n := Length(Acc);
        SetLength(Acc, n + Length(FileBytes));
        if Length(FileBytes) > 0 then
          Move(FileBytes[0], Acc[n], Length(FileBytes));
      end;
      Result := 'sha256:' + SHA256Hex(Acc);
    finally
      Files.Free;
    end;
  end
  { file (e.g. the archive itself): hash its bytes }
  else if FileExists(APathOrArchive) then
    Result := 'sha256:' + SHA256File(APathOrArchive)
  else
    Result := 'sha256:' + SHA256Hex(BytesOf(APathOrArchive));
end;

initialization
  { Record a millisecond-resolution TDateTime stamp once per process.
    PID + atomic sequence provide uniqueness; the existence retry
    defends against a stale path from PID/stamp reuse. }
  TmpPathStartedAt := Round(Now * MSecsPerDay);
  InitCriticalSection(ProcessEnvironmentCriticalSection);

end.
