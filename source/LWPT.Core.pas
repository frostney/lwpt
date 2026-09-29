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

{$IFDEF INSTALL_TESTING}
{ Value of the <PROJECT_NAME>_TEST_<AName> environment variable. Exists only
  in a test build (ADR-0044): every fault-injection branch that reads it is
  compiled only under INSTALL_TESTING, so a release binary contains neither
  the branch nor the variable name. }
function  TestSeamValue(const AName: string): string;
{$ENDIF}
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
  { Prefix of old executable images retired by AtomicReplaceExecutable. }
  RetiredExecutablePrefix = '.' + PROGRAM_NAME + '-retired-';

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
{ AtomicReplaceFile for a published executable image that a running process
  may still map (the self-hosted `lwpt build` replaces the binary running it).
  Windows refuses to delete a mapped image, so after a committed replacement
  an undeletable old image is renamed to a retired-image sibling and the
  replacement still succeeds; each later executable replacement in that
  directory, and `lwpt repair`, removes retired images no longer in use.
  The sweep runs only where RetiredExecutableSweepAllowed(AOwnerRoot, ...)
  holds for the destination directory. Identical to AtomicReplaceFile on
  Unix. }
function  AtomicReplaceExecutable(const ASrc, ADst,
  AOwnerRoot: string): Boolean;
{ True for names only AtomicReplaceExecutable produces for retired images. }
function  IsRetiredExecutableName(const AName: string): Boolean;
{ A retired-image sweep deletes by name alone, so it is allowed only in an
  existing directory that lies lexically inside AOwnerRoot and that LWPT
  reaches without following a link: no component from AOwnerRoot down to
  ADirectory, inclusive, may be a symlink or junction. The owner root itself
  is the caller's trust anchor. }
function  RetiredExecutableSweepAllowed(const AOwnerRoot,
  ADirectory: string): Boolean;
{ Delete every retired executable image in ADirectory that is no longer in
  use; returns the removed count and reports those still in use. Links are
  never followed or removed, and a directory refused by
  RetiredExecutableSweepAllowed is left untouched. }
function  RemoveRetiredExecutables(const AOwnerRoot, ADirectory: string;
  out ARetained: Integer): Integer;
procedure AtomicWriteText(const ADst: string; const ATmpRoot: string; const AContent: TStringList);
procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);

{ Process-handle inheritance protection. FPC cannot restrict a spawn to an
  explicit descriptor or handle list, and on Unix its TFileStream opens take
  a flock() (shared for reads, exclusive for creates) on descriptors without
  close-on-exec. A child forked while such a descriptor is open shares its
  lock: for its whole life without close-on-exec, and until its exec even
  with it. Later non-blocking share-mode opens of that file then fail with
  EAGAIN. Toolkit state therefore opens through the helpers below: they take
  no flock (LWPT coordinates with explicit fcntl locks and atomic renames),
  and they open and mark each descriptor close-on-exec under the same guard
  every managed and unmanaged spawn holds. The guard covers only that step;
  all I/O happens after it is released. Begin/End calls must be paired. }
procedure BeginProcessHandleSetup;
procedure EndProcessHandleSetup;

type
  { Owns its handle. On Unix the descriptor is close-on-exec and carries no
    flock share-mode lock; on Windows the handle is non-inheritable and keeps
    TFileStream's share modes. }
  TLWPTProtectedFileStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

{ TFileStream.Create equivalent for toolkit state. AMode takes the same
  fmCreate / fmOpenRead / fmOpenWrite / fmOpenReadWrite values; Unix ignores
  share flags. Raises EFCreateError or EFOpenError. }
function  OpenProtectedFileStream(const APath: string;
  const AMode: Word): TLWPTProtectedFileStream;
{ Replaces AStrings with the file's lines through OpenProtectedFileStream. }
procedure LoadProtectedStrings(const AStrings: TStrings; const APath: string);
{$IFDEF UNIX}
{ FpOpen equivalent for lock and marker files. Returns -1, leaving errno set,
  when the open or the close-on-exec protection fails. }
function  OpenProtectedDescriptor(const APath: string; const AFlags: LongInt;
  const APermissions: LongInt = &600): LongInt;
{$ENDIF}

{$IFDEF OBJECTSTORE_TESTING}
type
  TLWPTProtectedOpenTestHook = procedure(const APath: string);
  TLWPTProtectedDescriptorTestHook = procedure(const APath: string;
    const ADescriptor: LongInt);

var
  { Test-only: runs inside the inheritance guard after the open and before
    close-on-exec protection. Production code must leave it nil. }
  ProtectedOpenBeforeProtectionTestHook: TLWPTProtectedOpenTestHook;
  { Test-only: runs inside the guard once a Unix descriptor is protected, so
    a test can inspect its close-on-exec flag. Production must leave it nil. }
  ProtectedOpenAfterProtectionTestHook: TLWPTProtectedDescriptorTestHook;

type
  { phfContended: the thread's non-blocking attempt failed because another
    thread held the guard, and the thread is now blocked waiting for it.
    phfHeld: the thread holds the guard now. phfEntered: the thread has held
    it at least once since the last reset. }
  TLWPTProcessHandleSetupFlag = (phfContended, phfHeld, phfEntered);
  TLWPTProcessHandleSetupFlags = set of TLWPTProcessHandleSetupFlag;

{ Test-only observation of the inheritance guard per thread. }
procedure ResetProcessHandleSetupObservation;
function  ObserveProcessHandleSetup(
  const AThreadID: TThreadID): TLWPTProcessHandleSetupFlags;
{$ENDIF}

type
  TSHA256Digest = array[0..31] of Byte;
  { Incremental SHA-256 state for callers that hash bytes as they arrive. }
  TSHA256Context = record
    State: array[0..7] of Cardinal;
    Buffer: array[0..63] of Byte;
    BufferLength: Integer;
    TotalLength: QWord;
  end;

procedure SHA256Init(var AContext: TSHA256Context);
procedure SHA256Update(var AContext: TSHA256Context; const AData;
  const ACount: Integer);
procedure SHA256Final(var AContext: TSHA256Context;
  out ADigest: TSHA256Digest);
function  SHA256DigestHex(const ADigest: TSHA256Digest): string;
function  SHA256BytesPrefixed(const ABytes: TBytes): string;
function  SHA256Hex(const AData: TBytes): string;
function  SHA256Stream(AStream: TStream;
  AProgress: TSHA256Progress = nil): string;
function  SHA256File(const APath: string): string;
function  CanonicalTreeHashPath(const APath: string;
  const ASourceDelimiter: Char): string;
function  NormalizeTreeHashContent(const ABytes: TBytes): TBytes;

const
  { The framed tree digest (ADR-0052). The algorithm name is both the lock
    value's prefix and, with one trailing NUL, the stream's magic. It is a
    wire constant, not a program-name literal (ADR-0001). }
  TREE_DIGEST_ALGORITHM = 'sha256-tree2';
  TREE_DIGEST_PREFIX = TREE_DIGEST_ALGORITHM + ':';
  { The flawed v3 digest, kept only to recover rollback files that a
    pre-v4 binary wrote and to pin its own tests. }
  LEGACY_TREE_DIGEST_PREFIX = 'sha256:';
  { Files are read in chunks of this size. The digest does not depend on
    it. }
  TREE_DIGEST_CHUNK_BYTES = 64 * 1024;
  TREE_DIGEST_FILE_RECORD = $01;

type
  { What a tree walk found below a module root. Directories are walked, not
    listed. }
  TTreeEntryKind = (tekFile, tekFileLink, tekDirectoryLink, tekDanglingLink);

{ Fold-order comparator shared by both tree digests: ASCII case-insensitive,
  byte-wise, shorter first, ordinal tiebreak. }
function  TreeHashPathCompare(AList: TStringList;
  AIndex1, AIndex2: Integer): Integer;
{ SHA-256 of NormalizeTreeHashContent(the stream's remaining bytes), computed
  in one pass of TREE_DIGEST_CHUNK_BYTES reads with a raw and a normalized
  context; ASize is the normalized length. Nothing is buffered beyond one
  chunk. }
function  TreeContentDigest(AStream: TStream; out ASize: Int64): TSHA256Digest;
{ `sha256-tree2:<hex>` of the directory ADirectory (ADR-0052). Raises
  EVerifyError for a missing directory, and for a path that is not
  well-formed UTF-8 (or, on Windows, well-formed UTF-16). }
function  HashTree(const ADirectory: string): string;
{ The v3 `sha256:` digest. Used only to validate rollback files written by a
  pre-v4 binary, never for lock verification. }
function  LegacyHashTree(const APathOrArchive: string): string;
{ True for `sha256-tree2:` followed by 64 lowercase hex digits. }
function  IsTreeDigest(const AValue: string): Boolean;
{ Strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF, no
  NUL. }
function  IsWellFormedTreePath(const APath: RawByteString): Boolean;
{ Printable ASCII kept, every other byte as \xHH. }
function  EscapeTreePath(const APath: RawByteString): string;
{ Strict UTF-16 to UTF-8: an unpaired surrogate fails, it is never replaced
  with U+FFFD. Pure Pascal, so it is tested on every platform. }
function  StrictUTF16ToUTF8(const AName: UnicodeString;
  out AUTF8: RawByteString): Boolean;
{ Code units outside printable ASCII as \uXXXX. }
function  EscapeUTF16Name(const AName: UnicodeString): string;
{ Every entry below ADirectory as its canonical UTF-8 relative path, with
  Ord(TTreeEntryKind) in Objects. Directory links are listed, never
  followed. Raises like HashTree for a malformed name. }
procedure CollectTreeEntries(const ADirectory: string; AEntries: TStringList);
{ The escaped relative path of the first link (file link, directory link,
  junction, or dangling link) below ADirectory in digest order, '.' when
  ADirectory itself is one, or ''. }
function  FindTreeLink(const ADirectory: string): string;

const
  { Lockfile schema (ADR-0052). v3 is read only by `lwpt repair` to upgrade
    it. }
  LOCKFILE_SCHEMA_VERSION = 4;
  LOCKFILE_SCHEMA_V3 = 3;

{ The one message every lock reader raises for a schema-v3 lock. }
function  LockfileSchemaV3Message: string;
{ The shared lock version gate. Returns the schema version; raises
  ELockfileError for anything but v4, except v3 when AAcceptSchemaV3. }
function  CheckLockfileSchema(ARoot: TTOMLNode; const APath: string;
  const AAcceptSchemaV3: Boolean): Integer;
{ The gate for a lock on disk, run before a command changes anything. A
  missing lock passes. }
procedure RequireCurrentLockfileSchema(const APath: string);
{ The schema version of the lock at APath: 0 when it is missing, -1 when it
  cannot be parsed or has no integer version. Never raises for content. }
function  ReadLockfileSchemaVersion(const APath: string): Integer;

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
  MOVEFILE_DELAY_UNTIL_REBOOT_LWPT = $00000004;
  ERROR_UNABLE_TO_MOVE_REPLACEMENT_2_LWPT = 1177;
  FSCTL_GET_REPARSE_POINT_LWPT = $000900A8;
  FSCTL_SET_REPARSE_POINT_LWPT = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
  FILE_FLAG_BACKUP_SEMANTICS_LWPT = $02000000;
  MAX_REPARSE_DATA_BUFFER_SIZE_LWPT = 16 * 1024;

function LWPTReplaceFileW(AReplacedFileName, AReplacementFileName,
  ABackupFileName: PWideChar; AReplaceFlags: LongWord;
  AExclude, AReserved: Pointer): LongBool; stdcall;
  external 'kernel32.dll' name 'ReplaceFileW';
{$ENDIF}

var
  TmpPathCounter: LongInt;
  TmpPathStartedAt: Int64;
  ProcessEnvironmentSnapshot: TStringList = nil;
  ProcessEnvironmentCriticalSection: TRTLCriticalSection;
  ProcessHandleSetupCriticalSection: TRTLCriticalSection;

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

{$IFDEF INSTALL_TESTING}
function TestSeamValue(const AName: string): string;
begin
  Result := SysUtils.GetEnvironmentVariable(PROJECT_NAME + '_TEST_' + AName);
end;
{$ENDIF}

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

{ ===========================================================================
  Lockfile schema gate (ADR-0052). Every reader of lwpt.lock goes through
  CheckLockfileSchema, so v3 is refused with one message everywhere and only
  `lwpt repair` accepts it, to upgrade it.
  =========================================================================== }
function LockfileSchemaV3Message: string;
begin
  Result := '`' + LOCKFILE + '` is schema v3, whose tree hash cannot detect '
    + 'a rearranged module tree (ADR-0052). Run `' + PROGRAM_NAME
    + ' repair` to upgrade it to v4 without network access and without '
    + 'changing dependency versions, then commit `' + LOCKFILE + '`. '
    + 'Deleting `' + LOCKFILE + '` and running `' + PROGRAM_NAME
    + ' install` also works, but needs network access and moves range '
    + 'dependencies to their newest matching versions.';
end;

function CheckLockfileSchema(ARoot: TTOMLNode; const APath: string;
  const AAcceptSchemaV3: Boolean): Integer;
var VersionNode: TTOMLNode;
begin
  VersionNode := TomlGet(ARoot, 'version');
  if not TomlIsInt(VersionNode) then
    raise ELockfileError.CreateFmt(
      'lockfile %s has no schema version. Delete and re-run `%s install`.',
      [APath, PROGRAM_NAME]);
  Result := StrToIntDef(VersionNode.ScalarText, -1);
  if Result = LOCKFILE_SCHEMA_VERSION then Exit;
  if Result = LOCKFILE_SCHEMA_V3 then
  begin
    if AAcceptSchemaV3 then Exit;
    raise ELockfileError.Create(LockfileSchemaV3Message);
  end;
  if Result > LOCKFILE_SCHEMA_VERSION then
    raise ELockfileError.CreateFmt(
      'lockfile %s is schema v%d; this %s reads up to v%d. Use a %s release '
      + 'that reads schema v%d.', [APath, Result, PROGRAM_NAME,
      LOCKFILE_SCHEMA_VERSION, PROGRAM_NAME, Result]);
  raise ELockfileError.CreateFmt(
    'lockfile %s is schema v%d; this %s expects v%d. '
    + 'Delete %s and run `%s install` to regenerate.',
    [APath, Result, PROGRAM_NAME, LOCKFILE_SCHEMA_VERSION, APath,
     PROGRAM_NAME]);
end;

function ParseLockfileDocument(const APath: string): TTOMLNode;
var Lines: TStringList; Parser: TTOMLParser;
begin
  Lines := TStringList.Create;
  Parser := TTOMLParser.Create;
  try
    Lines.LoadFromFile(APath);
    try
      Result := Parser.ParseDocument(Lines.Text);
    except
      on E: ETOMLParseError do
        raise ELockfileError.CreateFmt(
          'lockfile %s is corrupt: %s. Delete it and run `%s install` '
          + 'to regenerate from the manifest.', [APath, E.Message,
          PROGRAM_NAME]);
    end;
  finally
    Parser.Free;
    Lines.Free;
  end;
end;

procedure RequireCurrentLockfileSchema(const APath: string);
var Root: TTOMLNode;
begin
  if not FileExists(APath) then Exit;
  Root := ParseLockfileDocument(APath);
  try
    CheckLockfileSchema(Root, APath, False);
  finally
    Root.Free;
  end;
end;

function ReadLockfileSchemaVersion(const APath: string): Integer;
var Root, VersionNode: TTOMLNode;
begin
  if not FileExists(APath) then Exit(0);
  try
    Root := ParseLockfileDocument(APath);
  except
    on E: ELockfileError do Exit(-1);
  end;
  try
    VersionNode := TomlGet(Root, 'version');
    if TomlIsInt(VersionNode) then
      Result := StrToIntDef(VersionNode.ScalarText, -1)
    else
      Result := -1;
  finally
    Root.Free;
  end;
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
var SrcS, DstS: TLWPTProtectedFileStream;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  try
    SrcS := OpenProtectedFileStream(ASrc, fmOpenRead or fmShareDenyNone);
    try
      DstS := OpenProtectedFileStream(ADst, fmCreate);
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

{$IFDEF MSWINDOWS}
function WindowsExtendedPath(const APath: string): UnicodeString;
var
  FullPath: UnicodeString;
begin
  FullPath := UnicodeString(StringReplace(ExpandFileName(APath), '/', '\',
    [rfReplaceAll]));
  if Copy(FullPath, 1, 4) = '\\?\' then Exit(FullPath);
  if Copy(FullPath, 1, 2) = '\\' then
    Result := '\\?\UNC\' + Copy(FullPath, 3, MaxInt)
  else
    Result := '\\?\' + FullPath;
end;

function WindowsPathExists(const APath: string): Boolean;
var
  ExtendedPath: UnicodeString;
begin
  ExtendedPath := WindowsExtendedPath(APath);
  Result := Windows.GetFileAttributesW(PWideChar(ExtendedPath)) <> $FFFFFFFF;
end;

function WindowsFileExists(const APath: string): Boolean;
var
  Attributes: Cardinal;
  ExtendedPath: UnicodeString;
begin
  ExtendedPath := WindowsExtendedPath(APath);
  Attributes := Windows.GetFileAttributesW(PWideChar(ExtendedPath));
  Result := (Attributes <> $FFFFFFFF)
    and ((Attributes and Windows.FILE_ATTRIBUTE_DIRECTORY) = 0);
end;

function MakeWindowsReplaceBackupPath(const ADst: string): string;
var
  Dir: string;
  Sequence: Cardinal;
begin
  Dir := ExtractFileDir(ADst);
  if Dir = '' then Dir := '.';
  repeat
    Sequence := Cardinal(InterlockedIncrement(TmpPathCounter));
    { Keep the ordinary spelling compact and independent of the destination
      filename. The Win32 calls use its extended-length spelling below, so a
      deep but valid destination does not acquire a longer-path precondition. }
    Result := IncludeTrailingPathDelimiter(Dir) + '.r-'
      + ProcessIdStr + '-' + EncodeBase36(TmpPathStartedAt) + '-'
      + IntToStr(Int64(Sequence)) + TmpPathExtension;
  until not WindowsPathExists(Result);
end;

{ A retired image is the old destination after a committed replacement.
  Its compact, destination-independent name mirrors the in-flight backup's
  length budget, while the distinct prefix marks it as committed residue that
  is safe to delete whenever the operating system allows it. }
function MakeRetiredExecutablePath(const ADirectory: string): string;
var
  Dir: string;
  Sequence: Cardinal;
begin
  Dir := ADirectory;
  if Dir = '' then Dir := '.';
  repeat
    Sequence := Cardinal(InterlockedIncrement(TmpPathCounter));
    Result := IncludeTrailingPathDelimiter(Dir) + RetiredExecutablePrefix
      + ProcessIdStr + '-' + EncodeBase36(TmpPathStartedAt) + '-'
      + IntToStr(Int64(Sequence)) + TmpPathExtension;
  until not WindowsPathExists(Result);
end;
{$ENDIF}

function IsRetiredExecutableName(const AName: string): Boolean;
var
  Body: string;
  Field, i: Integer;
  FieldLength: array[0..2] of Integer;
begin
  Result := False;
  if Length(AName) <= Length(RetiredExecutablePrefix)
    + Length(TmpPathExtension) then Exit;
  if Copy(AName, 1, Length(RetiredExecutablePrefix))
    <> RetiredExecutablePrefix then Exit;
  if Copy(AName, Length(AName) - Length(TmpPathExtension) + 1,
    Length(TmpPathExtension)) <> TmpPathExtension then Exit;
  { <pid>-<base36 start>-<sequence> }
  Body := Copy(AName, Length(RetiredExecutablePrefix) + 1,
    Length(AName) - Length(RetiredExecutablePrefix)
    - Length(TmpPathExtension));
  Field := 0;
  FieldLength[0] := 0; FieldLength[1] := 0; FieldLength[2] := 0;
  for i := 1 to Length(Body) do
    if Body[i] = '-' then
    begin
      if (Field = 2) or (FieldLength[Field] = 0) then Exit;
      Inc(Field);
    end
    else if (Body[i] in ['0'..'9'])
      or ((Field = 1) and (Body[i] in ['a'..'z'])) then
      Inc(FieldLength[Field])
    else
      Exit;
  Result := (Field = 2) and (FieldLength[2] > 0);
end;

function RetiredExecutableSweepAllowed(const AOwnerRoot,
  ADirectory: string): Boolean;
var
  Root, Dir, Current, Component: string;
  i: Integer;
begin
  Result := False;
  if (AOwnerRoot = '') or (ADirectory = '') then Exit;
  Root := ExcludeTrailingPathDelimiter(ExpandFileName(AOwnerRoot));
  Dir := ExcludeTrailingPathDelimiter(ExpandFileName(ADirectory));
  if not PathContains(Root, Dir) then Exit;
  { Walk every component below the root: a link anywhere on the way
    redirects the sweep into a directory LWPT does not own. }
  Current := Root;
  Component := '';
  for i := Length(IncludeTrailingPathDelimiter(Root)) + 1 to Length(Dir) + 1 do
    if (i > Length(Dir)) or (Dir[i] = '/') or (Dir[i] = '\') then
    begin
      if Component <> '' then
      begin
        Current := IncludeTrailingPathDelimiter(Current) + Component;
        if IsDirSymlinkOrJunction(Current) then Exit;
      end;
      Component := '';
    end
    else
      Component := Component + Dir[i];
  Result := DirectoryExists(Dir) and not IsDirSymlinkOrJunction(Dir);
end;

function RemoveRetiredExecutables(const AOwnerRoot, ADirectory: string;
  out ARetained: Integer): Integer;
var
  Dir, Full: string;
  Search: TSearchRec;
begin
  Result := 0;
  ARetained := 0;
  Dir := ADirectory;
  if Dir = '' then Dir := '.';
  if not RetiredExecutableSweepAllowed(AOwnerRoot, Dir) then Exit;
  { faSymLink makes Unix FindFirst lstat entries, so a link reports itself
    instead of its target and is skipped below. }
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(Dir)
    + RetiredExecutablePrefix + '*' + TmpPathExtension,
    faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if not IsRetiredExecutableName(Search.Name) then Continue;
      if (Search.Attr and (faDirectory or faSymLink)) <> 0 then Continue;
      Full := IncludeTrailingPathDelimiter(Dir) + Search.Name;
      if IsDirSymlinkOrJunction(Full) then Continue;
      { Revalidate the directory before each deletion so a link swapped in
        during the scan stops the sweep. }
      if not RetiredExecutableSweepAllowed(AOwnerRoot, Dir) then Break;
      {$IFDEF MSWINDOWS}
      if Windows.DeleteFileW(PWideChar(WindowsExtendedPath(Full))) then
      {$ELSE}
      if SysUtils.DeleteFile(Full) then
      {$ENDIF}
        Inc(Result)
      else
        Inc(ARetained);
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
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

{ True when APath still holds the snapshot AExpected describes. A sidecar
  that a pre-v4 binary wrote records `tree:sha256:<hex>`; it is validated
  with the legacy digest, so a transaction interrupted before an upgrade can
  still be recovered after it (ADR-0052). This is the legacy digest's only
  use outside its pinned tests. }
function SnapshotMatches(const APath, AExpected: string): Boolean;
const LEGACY_TREE_SNAPSHOT = 'tree:' + LEGACY_TREE_DIGEST_PREFIX;
begin
  if Copy(AExpected, 1, Length(LEGACY_TREE_SNAPSHOT)) = LEGACY_TREE_SNAPSHOT then
    Result := (not IsDirSymlinkOrJunction(APath)) and DirectoryExists(APath)
      and ('tree:' + LegacyHashTree(APath) = AExpected)
  else
    Result := SnapshotPathHash(APath) = AExpected;
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
  {$IFDEF INSTALL_TESTING}
  if SameText(TestSeamValue('THROW_RESTORE_FOR'),
       ExtractFileName(ExcludeTrailingPathDelimiter(ADestination))) then
    raise EExtractError.CreateFmt(
      'injected restore exception for "%s"', [ADestination]);
  {$ENDIF}
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
  if not SnapshotMatches(ABackupPath, Expected) then Exit;
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

{$IFDEF MSWINDOWS}
{ A committed ReplaceFileW leaves the old destination at its backup name.
  Windows refuses to delete that file while a process maps it as an image
  (the running `lwpt.exe` during a self-hosted rebuild) and reports access
  denied or a sharing violation. Only those in-use failures are tolerated:
  the destination already holds the complete replacement, and renaming a
  mapped image is permitted, so the backup moves to a retired-image name
  that later executable replacements and `lwpt repair` delete once no
  process uses it. Scheduling deletion at reboot is the last resort when the
  rename is refused; any other outcome keeps the strict failure. }
function RetireInUseReplaceBackup(const ABackupPath: string;
  ADeleteError: LongWord): Boolean;
var
  BackupPathW, RetiredPathW: UnicodeString;
begin
  Result := False;
  if (ADeleteError <> Windows.ERROR_ACCESS_DENIED)
    and (ADeleteError <> Windows.ERROR_SHARING_VIOLATION) then Exit;
  BackupPathW := WindowsExtendedPath(ABackupPath);
  RetiredPathW := WindowsExtendedPath(
    MakeRetiredExecutablePath(ExtractFileDir(ABackupPath)));
  if Windows.MoveFileExW(PWideChar(BackupPathW), PWideChar(RetiredPathW),
    MOVEFILE_WRITE_THROUGH_LWPT) then Exit(True);
  Result := Windows.MoveFileExW(PWideChar(BackupPathW), nil,
    MOVEFILE_DELAY_UNTIL_REBOOT_LWPT);
end;
{$ENDIF}

{ Replace a file in one filesystem operation. Unlike AtomicMoveFile this
  helper never renames the old destination aside, because doing so creates
  an observable missing-path window. It is intentionally strict: callers
  must stage the source on the same filesystem as the destination.
  ARetireInUseBackup is set only by AtomicReplaceExecutable. }
function ReplaceFileInOneOperation(const ASrc, ADst: string;
  ARetireInUseBackup: Boolean): Boolean;
var
  DstDir: string;
  {$IFDEF MSWINDOWS}
  BackupPath: string;
  BackupPathW, DstPathW, SrcPathW: UnicodeString;
  DeleteError, ReplaceError: LongWord;
  {$ENDIF}
begin
  {$IFDEF UNIX}
  if not FileExists(ASrc) then Exit(False);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not WindowsFileExists(ASrc) then Exit(False);
  {$ENDIF}
  DstDir := ExtractFileDir(ADst);
  if DstDir <> '' then ForceDirectories(DstDir);
  {$IFDEF UNIX}
  Result := FpRename(PChar(ASrc), PChar(ADst)) = 0;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { ReplaceFileW requests delete sharing for the replaced file, so a retained
    read handle opened with FILE_SHARE_DELETE keeps serving the old bytes while
    the path changes atomically. A named sibling backup makes ReplaceFileW's
    partial-failure states recoverable: error 1177 moves the old destination to
    that backup, so restore it before reporting failure. MoveFileEx cannot
    provide the open-reader contract. If the destination merely disappeared
    before ReplaceFileW opened it, use the ordinary no-destination move only
    while the staged source is still present. }
  SrcPathW := WindowsExtendedPath(ASrc);
  DstPathW := WindowsExtendedPath(ADst);
  if WindowsPathExists(ADst) then
  begin
    BackupPath := MakeWindowsReplaceBackupPath(ADst);
    BackupPathW := WindowsExtendedPath(BackupPath);
    Result := LWPTReplaceFileW(PWideChar(DstPathW), PWideChar(SrcPathW),
      PWideChar(BackupPathW), 0, nil, nil);
    if Result then
    begin
      if WindowsPathExists(BackupPath) then
        if not Windows.DeleteFileW(PWideChar(BackupPathW)) then
        begin
          DeleteError := Windows.GetLastError;
          if not (ARetireInUseBackup
            and RetireInUseReplaceBackup(BackupPath, DeleteError)) then
            raise EExtractError.CreateFmt(
              'atomic replacement of "%s" left its retained backup', [ADst]);
        end;
      Exit;
    end;
    ReplaceError := Windows.GetLastError;
    if ReplaceError = ERROR_UNABLE_TO_MOVE_REPLACEMENT_2_LWPT then
    begin
      if (not WindowsPathExists(BackupPath))
        or not Windows.MoveFileExW(PWideChar(BackupPathW),
          PWideChar(DstPathW), MOVEFILE_WRITE_THROUGH_LWPT) then
        raise EExtractError.CreateFmt(
          'atomic replacement of "%s" could not restore its retained backup',
          [ADst]);
      Exit(False);
    end;
    if WindowsPathExists(BackupPath)
      and not Windows.DeleteFileW(PWideChar(BackupPathW)) then
      raise EExtractError.CreateFmt(
        'atomic replacement of "%s" could not remove its unused backup',
        [ADst]);
    if WindowsPathExists(ADst) or not WindowsPathExists(ASrc) then Exit(False);
  end;
  Result := Windows.MoveFileExW(PWideChar(SrcPathW), PWideChar(DstPathW),
    MOVEFILE_WRITE_THROUGH_LWPT);
  {$ENDIF}
end;

function AtomicReplaceFile(const ASrc, ADst: string): Boolean;
begin
  Result := ReplaceFileInOneOperation(ASrc, ADst, False);
end;

function AtomicReplaceExecutable(const ASrc, ADst,
  AOwnerRoot: string): Boolean;
{$IFDEF MSWINDOWS}
var
  Retained: Integer;
{$ENDIF}
begin
  Result := ReplaceFileInOneOperation(ASrc, ADst, True);
  {$IFDEF MSWINDOWS}
  { Earlier self-hosted rebuilds retire the image they ran from; once that
    process exits its retired image becomes deletable. }
  if Result then
    RemoveRetiredExecutables(AOwnerRoot, ExtractFileDir(ADst), Retained);
  {$ENDIF}
end;

procedure EnsureDstDir(const ADst: string);
var D: string;
begin
  D := ExtractFileDir(ADst);
  if D <> '' then ForceDirectories(D);
end;

const
  { TFileStream.Create's default rights; the process umask still applies. }
  PROTECTED_CREATE_PERMISSIONS = &666;
{$IFDEF UNIX}
  { Darwin's BaseUnix declares FD_CLOEXEC; Linux FPC 3.2.2 does not. POSIX
    fixes the value at 1. }
  {$IFDEF LINUX}
  FD_CLOEXEC_LWPT = 1;
  {$ELSE}
  FD_CLOEXEC_LWPT = FD_CLOEXEC;
  {$ENDIF}
{$ENDIF}

{$IFDEF OBJECTSTORE_TESTING}
type
  TLWPTProcessHandleSetupObservation = record
    ThreadID: TThreadID;
    Contended: Boolean;
    Depth: Integer;
    Entered: Boolean;
  end;

var
  ProcessHandleSetupObservationCriticalSection: TRTLCriticalSection;
  ProcessHandleSetupObservations: array of TLWPTProcessHandleSetupObservation;

function ProcessHandleSetupObservationIndex(
  const AThreadID: TThreadID): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(ProcessHandleSetupObservations) do
    if ProcessHandleSetupObservations[Index].ThreadID = AThreadID then
      Exit(Index);
  Result := Length(ProcessHandleSetupObservations);
  SetLength(ProcessHandleSetupObservations, Result + 1);
  ProcessHandleSetupObservations[Result] :=
    Default(TLWPTProcessHandleSetupObservation);
  ProcessHandleSetupObservations[Result].ThreadID := AThreadID;
end;

procedure RecordProcessHandleSetupContention;
var
  Index: Integer;
begin
  EnterCriticalSection(ProcessHandleSetupObservationCriticalSection);
  try
    { Resolve the index first: it may grow and move the array. }
    Index := ProcessHandleSetupObservationIndex(GetCurrentThreadId);
    ProcessHandleSetupObservations[Index].Contended := True;
  finally
    LeaveCriticalSection(ProcessHandleSetupObservationCriticalSection);
  end;
end;

procedure RecordProcessHandleSetupDepth(const ADelta: Integer);
var
  Index: Integer;
begin
  EnterCriticalSection(ProcessHandleSetupObservationCriticalSection);
  try
    Index := ProcessHandleSetupObservationIndex(GetCurrentThreadId);
    Inc(ProcessHandleSetupObservations[Index].Depth, ADelta);
    if ADelta > 0 then
    begin
      ProcessHandleSetupObservations[Index].Entered := True;
      ProcessHandleSetupObservations[Index].Contended := False;
    end;
  finally
    LeaveCriticalSection(ProcessHandleSetupObservationCriticalSection);
  end;
end;

procedure ResetProcessHandleSetupObservation;
var
  Index, Kept: Integer;
begin
  EnterCriticalSection(ProcessHandleSetupObservationCriticalSection);
  try
    { A thread that holds the guard right now keeps its depth. }
    Kept := 0;
    for Index := 0 to High(ProcessHandleSetupObservations) do
      if ProcessHandleSetupObservations[Index].Depth > 0 then
      begin
        ProcessHandleSetupObservations[Kept] :=
          ProcessHandleSetupObservations[Index];
        ProcessHandleSetupObservations[Kept].Contended := False;
        ProcessHandleSetupObservations[Kept].Entered := False;
        Inc(Kept);
      end;
    SetLength(ProcessHandleSetupObservations, Kept);
  finally
    LeaveCriticalSection(ProcessHandleSetupObservationCriticalSection);
  end;
end;

function ObserveProcessHandleSetup(
  const AThreadID: TThreadID): TLWPTProcessHandleSetupFlags;
var
  Index: Integer;
begin
  Result := [];
  EnterCriticalSection(ProcessHandleSetupObservationCriticalSection);
  try
    for Index := 0 to High(ProcessHandleSetupObservations) do
      if ProcessHandleSetupObservations[Index].ThreadID = AThreadID then
      begin
        if ProcessHandleSetupObservations[Index].Contended then
          Include(Result, phfContended);
        if ProcessHandleSetupObservations[Index].Depth > 0 then
          Include(Result, phfHeld);
        if ProcessHandleSetupObservations[Index].Entered then
          Include(Result, phfEntered);
        Exit;
      end;
  finally
    LeaveCriticalSection(ProcessHandleSetupObservationCriticalSection);
  end;
end;
{$ENDIF}

procedure BeginProcessHandleSetup;
begin
  {$IFDEF OBJECTSTORE_TESTING}
  { Record contention only after a real failed attempt on the guard itself,
    so an observer never mistakes an uncontended thread for a blocked one. }
  if System.TryEnterCriticalSection(ProcessHandleSetupCriticalSection) = 0 then
  begin
    RecordProcessHandleSetupContention;
    EnterCriticalSection(ProcessHandleSetupCriticalSection);
  end;
  RecordProcessHandleSetupDepth(1);
  {$ELSE}
  EnterCriticalSection(ProcessHandleSetupCriticalSection);
  {$ENDIF}
end;

procedure EndProcessHandleSetup;
begin
  {$IFDEF OBJECTSTORE_TESTING}
  RecordProcessHandleSetupDepth(-1);
  {$ENDIF}
  LeaveCriticalSection(ProcessHandleSetupCriticalSection);
end;

destructor TLWPTProtectedFileStream.Destroy;
begin
  if Handle <> THandle(-1) then FileClose(Handle);
  inherited Destroy;
end;

{$IFDEF UNIX}
function ProtectedOpenFlags(const AMode: Word): LongInt;
begin
  if (AMode and fmCreate) = fmCreate then
    Exit(O_RDWR or O_CREAT or O_TRUNC);
  case AMode and (fmOpenRead or fmOpenWrite or fmOpenReadWrite) of
    fmOpenWrite: Result := O_WRONLY;
    fmOpenReadWrite: Result := O_RDWR;
  else
    Result := O_RDONLY;
  end;
end;
{$ENDIF}

function OpenProtectedFileStream(const APath: string;
  const AMode: Word): TLWPTProtectedFileStream;
var
  Handle: THandle;
  {$IFDEF UNIX}
  Descriptor, ErrorCode: LongInt;
  Info: BaseUnix.Stat;
  {$ENDIF}
begin
  {$IFDEF UNIX}
  Descriptor := OpenProtectedDescriptor(APath, ProtectedOpenFlags(AMode),
    PROTECTED_CREATE_PERMISSIONS);
  if Descriptor < 0 then
  begin
    ErrorCode := FpGetErrNo;
    if (AMode and fmCreate) = fmCreate then
      raise EFCreateError.CreateFmt('Unable to create file "%s": %s',
        [APath, SysErrorMessage(ErrorCode)]);
    raise EFOpenError.CreateFmt('Unable to open file "%s": %s',
      [APath, SysErrorMessage(ErrorCode)]);
  end;
  { TFileStream refuses directories; keep that contract. }
  if FpFStat(Descriptor, Info) <> 0 then
  begin
    ErrorCode := FpGetErrNo;
    FpClose(Descriptor);
    raise EFOpenError.CreateFmt('Unable to open file "%s": %s',
      [APath, SysErrorMessage(ErrorCode)]);
  end;
  if FpS_ISDIR(Info.st_mode) then
  begin
    FpClose(Descriptor);
    raise EFOpenError.CreateFmt('Unable to open file "%s": is a directory',
      [APath]);
  end;
  Handle := THandle(Descriptor);
  {$ELSE}
  { Windows file handles are created non-inheritable. }
  if (AMode and fmCreate) = fmCreate then
  begin
    Handle := FileCreate(APath, AMode and not fmCreate,
      PROTECTED_CREATE_PERMISSIONS);
    if Handle = THandle(-1) then
      raise EFCreateError.CreateFmt('Unable to create file "%s": %s',
        [APath, SysErrorMessage(GetLastOSError)]);
  end
  else
  begin
    Handle := FileOpen(APath, AMode);
    if Handle = THandle(-1) then
      raise EFOpenError.CreateFmt('Unable to open file "%s": %s',
        [APath, SysErrorMessage(GetLastOSError)]);
  end;
  {$ENDIF}
  Result := TLWPTProtectedFileStream.Create(Handle);
end;

{$IFDEF UNIX}
function OpenProtectedDescriptor(const APath: string; const AFlags: LongInt;
  const APermissions: LongInt): LongInt;
var
  ErrorCode: LongInt;
begin
  BeginProcessHandleSetup;
  try
    repeat
      Result := FpOpen(PChar(APath), AFlags, APermissions);
    until (Result >= 0) or (FpGetErrNo <> ESysEINTR);
    if Result < 0 then Exit;
    {$IFDEF OBJECTSTORE_TESTING}
    if Assigned(ProtectedOpenBeforeProtectionTestHook) then
      ProtectedOpenBeforeProtectionTestHook(APath);
    {$ENDIF}
    if FpFcntl(Result, F_SETFD, FD_CLOEXEC_LWPT) <> 0 then
    begin
      ErrorCode := FpGetErrNo;
      FpClose(Result);
      FpSetErrNo(ErrorCode);
      Result := -1;
      Exit;
    end;
    {$IFDEF OBJECTSTORE_TESTING}
    if Assigned(ProtectedOpenAfterProtectionTestHook) then
      ProtectedOpenAfterProtectionTestHook(APath, Result);
    {$ENDIF}
  finally
    EndProcessHandleSetup;
  end;
end;
{$ENDIF}

procedure LoadProtectedStrings(const AStrings: TStrings; const APath: string);
var
  Stream: TLWPTProtectedFileStream;
begin
  Stream := OpenProtectedFileStream(APath, fmOpenRead or fmShareDenyNone);
  try
    AStrings.LoadFromStream(Stream);
  finally
    Stream.Free;
  end;
end;

procedure AtomicWriteText(const ADst: string;
  const ATmpRoot: string; const AContent: TStringList);
var Tmp: string; Stream: TLWPTProtectedFileStream;
begin
  { The destination name adds no uniqueness and can push a project-local
    staging path past Windows' directory-path ceiling in a deep checkout. }
  Tmp := MakeTmpPath(ATmpRoot, 'write');
  EnsureDstDir(ADst);
  Stream := OpenProtectedFileStream(Tmp, fmCreate);
  try
    AContent.SaveToStream(Stream);
  finally
    Stream.Free;
  end;
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
var Tmp: string; Stream: TLWPTProtectedFileStream;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write');
  EnsureDstDir(ADst);
  Stream := OpenProtectedFileStream(Tmp, fmCreate);
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
  Stream: TLWPTProtectedFileStream;
begin
  if not FileExists(APath) then Exit('');
  Stream := OpenProtectedFileStream(APath, fmOpenRead or fmShareDenyNone);
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

{ ===========================================================================
  Tree digests.

  HashTree is the framed `sha256-tree2` digest of ADR-0052, the value of
  every schema-v4 computedHash. LegacyHashTree is the v3 digest, whose
  unframed "path LF contents" stream lets a rearranged tree hash like the
  original (#352); it survives only to validate rollback files that a
  pre-v4 binary wrote.

  Both cover the same files: regular files, and file links whose target
  resolves, read through the link. Directory links are never descended into
  (a link cycle would recurse forever, and the linked bytes are hashed where
  they really live) and dangling links are skipped, so a CopyDirTree copy
  hashes like its source. faSymLink must be in the FindFirst mask or the
  attribute is not reported and links look like plain directories (or,
  dangling, vanish entirely).
  =========================================================================== }

{ The v3 inventory, unchanged: native-name relative paths. }
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

{ Fold-order comparator for both tree digests: ASCII case-insensitive,
  byte-wise, ordinal tiebreak — a platform-independent pin of the order every
  lockfile was written with. TStringList.Sort compares with AnsiCompareText,
  which is ASCII-uppercase byte compare on POSIX but CompareStringW
  WORD-SORT on Windows, where '-' is primary-ignorable: the same tree of
  hyphenated filenames folds in a different order and the digest diverges
  with byte-identical content ("tree hash mismatch" on a Windows checkout —
  the third guise of the #78 family, after path separators (#116) and the
  fingerprint join). Verified byte-for-byte against a real divergence:
  ASCII-CI order reproduces the POSIX-written lockfile digest exactly; the
  hyphen-ignoring order reproduces the Windows disk digest exactly. Framing
  (ADR-0052) would make any deterministic order sound, but a third order
  adds risk for nothing, so `sha256-tree2` keeps this one. }
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
    ordinally so the order is still deterministic everywhere ('A.pas'
    before 'a.pas'). }
  if Result = 0 then Result := CompareStr(A, B);
end;

function LegacyHashTree(const APathOrArchive: string): string;
var
  Files : TStringList;
  Acc   : TBytes;
  i, n  : Integer;
  Chunk : TBytes;
  FileBytes : TBytes;
  FS    : TLWPTProtectedFileStream;
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
        Chunk := BytesOf(Files[i] + #10);
        n := Length(Acc);
        SetLength(Acc, n + Length(Chunk));
        if Length(Chunk) > 0 then Move(Chunk[0], Acc[n], Length(Chunk));

        FullPath := NativePath(IncludeTrailingPathDelimiter(APathOrArchive)
          + Files[i]);
        FS := OpenProtectedFileStream(FullPath, fmOpenRead or fmShareDenyNone);
        try
          SetLength(FileBytes, FS.Size);
          if FS.Size > 0 then FS.ReadBuffer(FileBytes[0], FS.Size);
        finally
          FS.Free;
        end;
        FileBytes := NormalizeTreeHashContent(FileBytes);
        n := Length(Acc);
        SetLength(Acc, n + Length(FileBytes));
        if Length(FileBytes) > 0 then
          Move(FileBytes[0], Acc[n], Length(FileBytes));
      end;
      Result := LEGACY_TREE_DIGEST_PREFIX + SHA256Hex(Acc);
    finally
      Files.Free;
    end;
  end
  { file (e.g. the archive itself): hash its bytes }
  else if FileExists(APathOrArchive) then
    Result := LEGACY_TREE_DIGEST_PREFIX + SHA256File(APathOrArchive)
  else
    Result := LEGACY_TREE_DIGEST_PREFIX + SHA256Hex(BytesOf(APathOrArchive));
end;

function IsTreeDigest(const AValue: string): Boolean;
var i: Integer;
begin
  Result := (Length(AValue) = Length(TREE_DIGEST_PREFIX) + 64)
    and (Copy(AValue, 1, Length(TREE_DIGEST_PREFIX)) = TREE_DIGEST_PREFIX);
  if not Result then Exit;
  for i := Length(TREE_DIGEST_PREFIX) + 1 to Length(AValue) do
    if not (AValue[i] in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function IsWellFormedTreePath(const APath: RawByteString): Boolean;
var
  i, Len, Extra: Integer;
  B, Second: Byte;
  CodePoint: LongWord;
  k: Integer;
begin
  Len := Length(APath);
  if Len = 0 then Exit(False);
  i := 1;
  while i <= Len do
  begin
    B := Ord(APath[i]);
    if B = 0 then Exit(False);
    if B < $80 then
    begin
      Inc(i);
      Continue;
    end;
    if (B and $E0) = $C0 then
    begin
      Extra := 1;
      CodePoint := B and $1F;
    end
    else if (B and $F0) = $E0 then
    begin
      Extra := 2;
      CodePoint := B and $0F;
    end
    else if (B and $F8) = $F0 then
    begin
      Extra := 3;
      CodePoint := B and $07;
    end
    else
      Exit(False);
    if i + Extra > Len then Exit(False);
    for k := 1 to Extra do
    begin
      Second := Ord(APath[i + k]);
      if (Second and $C0) <> $80 then Exit(False);
      CodePoint := (CodePoint shl 6) or (Second and $3F);
    end;
    { Shortest form only, no surrogate code points, nothing above
      U+10FFFF. }
    case Extra of
      1: if CodePoint < $80 then Exit(False);
      2: if (CodePoint < $800)
            or ((CodePoint >= $D800) and (CodePoint <= $DFFF)) then
           Exit(False);
      3: if (CodePoint < $10000) or (CodePoint > $10FFFF) then Exit(False);
    end;
    Inc(i, Extra + 1);
  end;
  Result := True;
end;

function EscapeTreePath(const APath: RawByteString): string;
var i: Integer; B: Byte;
begin
  Result := '';
  for i := 1 to Length(APath) do
  begin
    B := Ord(APath[i]);
    if (B >= $20) and (B < $7F) and (B <> Ord('\')) then
      Result := Result + Chr(B)
    else
      Result := Result + '\x' + LowerCase(IntToHex(B, 2));
  end;
end;

function StrictUTF16ToUTF8(const AName: UnicodeString;
  out AUTF8: RawByteString): Boolean;
var
  i, Len, Written: Integer;
  Unit1, Unit2: Word;
  CodePoint: LongWord;
  Buffer: string;

  procedure Emit(AByte: LongWord);
  begin
    Inc(Written);
    Buffer[Written] := Chr(Byte(AByte));
  end;

begin
  AUTF8 := '';
  Len := Length(AName);
  { Four UTF-8 bytes at most per code unit pair; three per single unit. }
  SetLength(Buffer, 3 * Len);
  Written := 0;
  i := 1;
  while i <= Len do
  begin
    Unit1 := Ord(AName[i]);
    if (Unit1 >= $D800) and (Unit1 <= $DBFF) then
    begin
      if i = Len then Exit(False);
      Unit2 := Ord(AName[i + 1]);
      if (Unit2 < $DC00) or (Unit2 > $DFFF) then Exit(False);
      CodePoint := $10000 + ((LongWord(Unit1) - $D800) shl 10)
        + (LongWord(Unit2) - $DC00);
      Inc(i, 2);
    end
    else if (Unit1 >= $DC00) and (Unit1 <= $DFFF) then
      Exit(False)
    else
    begin
      CodePoint := Unit1;
      Inc(i);
    end;
    if CodePoint < $80 then
      Emit(CodePoint)
    else if CodePoint < $800 then
    begin
      Emit($C0 or (CodePoint shr 6));
      Emit($80 or (CodePoint and $3F));
    end
    else if CodePoint < $10000 then
    begin
      Emit($E0 or (CodePoint shr 12));
      Emit($80 or ((CodePoint shr 6) and $3F));
      Emit($80 or (CodePoint and $3F));
    end
    else
    begin
      Emit($F0 or (CodePoint shr 18));
      Emit($80 or ((CodePoint shr 12) and $3F));
      Emit($80 or ((CodePoint shr 6) and $3F));
      Emit($80 or (CodePoint and $3F));
    end;
  end;
  SetLength(Buffer, Written);
  AUTF8 := Buffer;
  Result := True;
end;

function EscapeUTF16Name(const AName: UnicodeString): string;
var i: Integer; CodeUnit: Word;
begin
  Result := '';
  for i := 1 to Length(AName) do
  begin
    CodeUnit := Ord(AName[i]);
    if (CodeUnit >= $20) and (CodeUnit < $7F) and (CodeUnit <> Ord('\')) then
      Result := Result + Chr(CodeUnit)
    else
      Result := Result + '\u' + LowerCase(IntToHex(CodeUnit, 4));
  end;
end;

procedure RaiseMalformedTreePath(const ARoot, AEscaped, AEncoding: string);
begin
  raise EVerifyError.CreateFmt(
    'cannot hash the tree at %s: the name "%s" is not well-formed %s. A '
    + 'tree digest (ADR-0052) covers only paths that hash the same on every '
    + 'platform; rename the file.', [ARoot, AEscaped, AEncoding]);
end;

{$IFDEF MSWINDOWS}
const
  WC_ERR_INVALID_CHARS_LWPT = $00000080;

{ UTF-16 names from the filesystem, converted strictly: pairing is checked
  here, and WideCharToMultiByte with WC_ERR_INVALID_CHARS must agree. It
  never goes through the ANSI code page and never substitutes U+FFFD. }
function WindowsNameToUTF8(const AName: UnicodeString;
  out AUTF8: string): Boolean;
var
  Checked: RawByteString;
  Size: LongInt;
  Converted: string;
begin
  AUTF8 := '';
  if not StrictUTF16ToUTF8(AName, Checked) then Exit(False);
  if AName = '' then Exit(False);
  Size := WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS_LWPT,
    PWideChar(AName), Length(AName), nil, 0, nil, nil);
  if Size <= 0 then Exit(False);
  SetLength(Converted, Size);
  if WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS_LWPT, PWideChar(AName),
       Length(AName), PAnsiChar(Converted), Size, nil, nil) <> Size then
    Exit(False);
  { Byte comparison of the two independent conversions. }
  if (Length(Converted) <> Length(Checked))
     or ((Length(Checked) > 0)
       and not CompareMem(@Converted[1], @Checked[1], Length(Checked))) then
    Exit(False);
  AUTF8 := Converted;
  Result := True;
end;

{ The exact inverse for a validated UTF-8 path; '/' becomes '\'. }
function TreePathToWide(const APath: string): UnicodeString;
var
  i, Len, Written: Integer;
  B: Byte;
  CodePoint: LongWord;
begin
  Len := Length(APath);
  SetLength(Result, Len);
  Written := 0;
  i := 1;
  while i <= Len do
  begin
    B := Ord(APath[i]);
    if B < $80 then
    begin
      CodePoint := B;
      Inc(i);
    end
    else if (B and $E0) = $C0 then
    begin
      CodePoint := ((B and $1F) shl 6) or (Ord(APath[i + 1]) and $3F);
      Inc(i, 2);
    end
    else if (B and $F0) = $E0 then
    begin
      CodePoint := ((B and $0F) shl 12) or ((Ord(APath[i + 1]) and $3F) shl 6)
        or (Ord(APath[i + 2]) and $3F);
      Inc(i, 3);
    end
    else
    begin
      CodePoint := ((B and $07) shl 18) or ((Ord(APath[i + 1]) and $3F) shl 12)
        or ((Ord(APath[i + 2]) and $3F) shl 6) or (Ord(APath[i + 3]) and $3F);
      Inc(i, 4);
    end;
    if CodePoint = Ord('/') then CodePoint := Ord('\');
    if CodePoint >= $10000 then
    begin
      Dec(CodePoint, $10000);
      Inc(Written);
      Result[Written] := WideChar($D800 + (CodePoint shr 10));
      Inc(Written);
      Result[Written] := WideChar($DC00 + (CodePoint and $3FF));
    end
    else
    begin
      Inc(Written);
      Result[Written] := WideChar(CodePoint);
    end;
  end;
  SetLength(Result, Written);
end;

function WideTargetIsFile(const APath: UnicodeString): Boolean;
var Handle: THandle; Info: TByHandleFileInformation;
begin
  { Opening follows the link; without backup semantics a directory target
    fails, which is exactly "not a file". }
  Handle := CreateFileW(PWideChar(APath), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then Exit(False);
  try
    Result := GetFileInformationByHandle(Handle, Info)
      and ((Info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) = 0);
  finally
    CloseHandle(Handle);
  end;
end;

procedure CollectTreeEntriesRec(const ARootLabel: string;
  const AWideDir: UnicodeString; const ARel: string; AEntries: TStringList);
var
  Find: THandle;
  Data: TWin32FindDataW;
  Name: UnicodeString;
  NameUTF8, RelPath: string;
  Kind: TTreeEntryKind;
begin
  Find := FindFirstFileW(PWideChar(AWideDir + '\*'), Data);
  if Find = INVALID_HANDLE_VALUE then Exit;
  try
    repeat
      Name := PWideChar(@Data.cFileName[0]);
      if (Name = '.') or (Name = '..') then Continue;
      if not WindowsNameToUTF8(Name, NameUTF8) then
        RaiseMalformedTreePath(ARootLabel,
          EscapeTreePath(ARel) + EscapeUTF16Name(Name), 'UTF-16');
      RelPath := ARel + NameUTF8;
      if (Data.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then
      begin
        if (Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          Kind := tekDirectoryLink
        else if WideTargetIsFile(AWideDir + '\' + Name) then
          Kind := tekFileLink
        else
          Kind := tekDanglingLink;
        AEntries.AddObject(RelPath, TObject(PtrInt(Ord(Kind))));
      end
      else if (Data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
        CollectTreeEntriesRec(ARootLabel, AWideDir + '\' + Name,
          RelPath + TREE_HASH_PATH_SEPARATOR, AEntries)
      else
        AEntries.AddObject(RelPath, TObject(PtrInt(Ord(tekFile))));
    until not FindNextFileW(Find, Data);
  finally
    Windows.FindClose(Find);
  end;
end;

function OpenTreeFile(const ADirectory, ARelPath: string): TStream;
var Handle: THandle; WidePath: UnicodeString;
begin
  WidePath := UnicodeString(ExcludeTrailingPathDelimiter(ADirectory)) + '\'
    + TreePathToWide(ARelPath);
  { Non-inheritable (no security attributes), as every toolkit handle. }
  Handle := CreateFileW(PWideChar(WidePath), GENERIC_READ,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then
    raise EFOpenError.CreateFmt('Unable to open file "%s": %s',
      [EscapeTreePath(ARelPath), SysErrorMessage(GetLastOSError)]);
  Result := TLWPTProtectedFileStream.Create(Handle);
end;
{$ELSE}
procedure CollectTreeEntriesRec(const ARootLabel, ARoot, ARel: string;
  AEntries: TStringList);
var SR: TSearchRec; Path, RelPath: string; Kind: TTreeEntryKind;
begin
  Path := IncludeTrailingPathDelimiter(ARoot + ARel);
  if SysUtils.FindFirst(Path + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        RelPath := ARel + SR.Name;
        { POSIX names are hashed as the bytes the filesystem reports. }
        if not IsWellFormedTreePath(RelPath) then
          RaiseMalformedTreePath(ARootLabel, EscapeTreePath(RelPath),
            'UTF-8');
        if (SR.Attr and faSymLink) <> 0 then
        begin
          if (SR.Attr and faDirectory) <> 0 then
            Kind := tekDirectoryLink
          else if FileExists(Path + SR.Name) then
            Kind := tekFileLink
          else if DirectoryExists(Path + SR.Name) then
            Kind := tekDirectoryLink
          else
            Kind := tekDanglingLink;
          AEntries.AddObject(RelPath, TObject(PtrInt(Ord(Kind))));
        end
        else if (SR.Attr and faDirectory) <> 0 then
          CollectTreeEntriesRec(ARootLabel, ARoot, RelPath + PathDelim,
            AEntries)
        else
          AEntries.AddObject(RelPath, TObject(PtrInt(Ord(tekFile))));
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
end;

function OpenTreeFile(const ADirectory, ARelPath: string): TStream;
begin
  Result := OpenProtectedFileStream(IncludeTrailingPathDelimiter(ADirectory)
    + ARelPath, fmOpenRead or fmShareDenyNone);
end;
{$ENDIF}

procedure CollectTreeEntries(const ADirectory: string; AEntries: TStringList);
begin
  if not DirectoryExists(ADirectory) then
    raise EVerifyError.CreateFmt(
      'cannot hash the tree at %s: it is not a directory', [ADirectory]);
  {$IFDEF MSWINDOWS}
  CollectTreeEntriesRec(ADirectory,
    UnicodeString(ExcludeTrailingPathDelimiter(ADirectory)), '', AEntries);
  {$ELSE}
  CollectTreeEntriesRec(ADirectory, IncludeTrailingPathDelimiter(ADirectory),
    '', AEntries);
  {$ENDIF}
end;

function TreeContentDigestWith(AStream: TStream; var ARaw, ANormalized: TBytes;
  out ASize: Int64): TSHA256Digest;
var
  RawContext, NormalizedContext: TSHA256Context;
  RawSize, NormalizedSize: Int64;
  Binary, HeldCR: Boolean;
  Count, i, Written: Integer;
  Value: Byte;
  NormalizedDigest: TSHA256Digest;
begin
  SHA256Init(RawContext);
  SHA256Init(NormalizedContext);
  RawSize := 0;
  NormalizedSize := 0;
  Binary := False;
  HeldCR := False;
  repeat
    Count := AStream.Read(ARaw[0], TREE_DIGEST_CHUNK_BYTES);
    if Count <= 0 then Break;
    { FS.Size is never trusted: the length is what was read. }
    SHA256Update(RawContext, ARaw[0], Count);
    Inc(RawSize, Count);
    if Binary then Continue;
    Written := 0;
    for i := 0 to Count - 1 do
    begin
      Value := ARaw[i];
      if Value = TREE_HASH_BYTE_NUL then
      begin
        { Binary: hashed verbatim; the normalized context is abandoned. }
        Binary := True;
        Break;
      end;
      if HeldCR then
      begin
        HeldCR := False;
        { CRLF drops the CR; a lone CR is kept. }
        if Value <> TREE_HASH_BYTE_LF then
        begin
          ANormalized[Written] := TREE_HASH_BYTE_CR;
          Inc(Written);
        end;
      end;
      if Value = TREE_HASH_BYTE_CR then
        { Held until the next byte, possibly in the next chunk. }
        HeldCR := True
      else
      begin
        ANormalized[Written] := Value;
        Inc(Written);
      end;
    end;
    if (not Binary) and (Written > 0) then
    begin
      SHA256Update(NormalizedContext, ANormalized[0], Written);
      Inc(NormalizedSize, Written);
    end;
  until False;
  if Binary then
  begin
    SHA256Final(RawContext, Result);
    SHA256Final(NormalizedContext, NormalizedDigest);
    ASize := RawSize;
    Exit;
  end;
  if HeldCR then
  begin
    ANormalized[0] := TREE_HASH_BYTE_CR;
    SHA256Update(NormalizedContext, ANormalized[0], 1);
    Inc(NormalizedSize);
  end;
  SHA256Final(NormalizedContext, Result);
  SHA256Final(RawContext, NormalizedDigest);
  ASize := NormalizedSize;
end;

function TreeContentDigest(AStream: TStream; out ASize: Int64): TSHA256Digest;
var Raw, Normalized: TBytes;
begin
  SetLength(Raw, TREE_DIGEST_CHUNK_BYTES);
  { A held CR from the previous chunk can precede a whole chunk. }
  SetLength(Normalized, TREE_DIGEST_CHUNK_BYTES + 1);
  Result := TreeContentDigestWith(AStream, Raw, Normalized, ASize);
end;

procedure SHA256UpdateBigEndian(var AContext: TSHA256Context;
  const AValue: QWord; const ABytes: Integer);
var Encoded: array[0..7] of Byte; i: Integer;
begin
  for i := 0 to ABytes - 1 do
    Encoded[i] := Byte((AValue shr (8 * (ABytes - 1 - i))) and $FF);
  SHA256Update(AContext, Encoded[0], ABytes);
end;

{ `sha256-tree2` (ADR-0052): SHA-256 over magic || record*, records in
  TreeHashPathCompare order. magic is the algorithm name and one NUL; a
  record is type (1 byte, 0x01), path length (4 bytes), the UTF-8 path, the
  normalized content length (8 bytes), and the normalized content's SHA-256
  (32 bytes); integers are unsigned big-endian. Every record is
  self-delimiting, so no arrangement of contents can be read as a path or a
  file boundary. Only the sorted path list is held in memory; each file is
  read once in fixed chunks. }
function HashTree(const ADirectory: string): string;
var
  Entries, Files: TStringList;
  Outer: TSHA256Context;
  Raw, Normalized: TBytes;
  Magic: string;
  Kind: TTreeEntryKind;
  i: Integer;
  Size: Int64;
  Digest, TreeDigest: TSHA256Digest;
  RecordType: Byte;
  Stream: TStream;
begin
  Entries := TStringList.Create;
  Files := TStringList.Create;
  try
    CollectTreeEntries(ADirectory, Entries);
    for i := 0 to Entries.Count - 1 do
    begin
      Kind := TTreeEntryKind(PtrInt(Entries.Objects[i]));
      if Kind in [tekFile, tekFileLink] then Files.Add(Entries[i]);
    end;
    Files.CustomSort(@TreeHashPathCompare);
    SetLength(Raw, TREE_DIGEST_CHUNK_BYTES);
    SetLength(Normalized, TREE_DIGEST_CHUNK_BYTES + 1);
    SHA256Init(Outer);
    Magic := TREE_DIGEST_ALGORITHM + #0;
    SHA256Update(Outer, Magic[1], Length(Magic));
    RecordType := TREE_DIGEST_FILE_RECORD;
    for i := 0 to Files.Count - 1 do
    begin
      Stream := OpenTreeFile(ADirectory, Files[i]);
      try
        Digest := TreeContentDigestWith(Stream, Raw, Normalized, Size);
      finally
        Stream.Free;
      end;
      SHA256Update(Outer, RecordType, 1);
      SHA256UpdateBigEndian(Outer, QWord(Length(Files[i])), 4);
      SHA256Update(Outer, Files[i][1], Length(Files[i]));
      SHA256UpdateBigEndian(Outer, QWord(Size), 8);
      SHA256Update(Outer, Digest[0], SizeOf(Digest));
    end;
    SHA256Final(Outer, TreeDigest);
    Result := TREE_DIGEST_PREFIX + SHA256DigestHex(TreeDigest);
  finally
    Files.Free;
    Entries.Free;
  end;
end;

function FindTreeLink(const ADirectory: string): string;
var Entries, Links: TStringList; i: Integer;
begin
  Result := '';
  if IsDirSymlinkOrJunction(ExcludeTrailingPathDelimiter(ADirectory)) then
    Exit('.');
  Entries := TStringList.Create;
  Links := TStringList.Create;
  try
    CollectTreeEntries(ADirectory, Entries);
    for i := 0 to Entries.Count - 1 do
      if TTreeEntryKind(PtrInt(Entries.Objects[i])) <> tekFile then
        Links.Add(Entries[i]);
    if Links.Count = 0 then Exit;
    Links.CustomSort(@TreeHashPathCompare);
    Result := EscapeTreePath(Links[0]);
  finally
    Links.Free;
    Entries.Free;
  end;
end;

initialization
  { Record a millisecond-resolution TDateTime stamp once per process.
    PID + atomic sequence provide uniqueness; the existence retry
    defends against a stale path from PID/stamp reuse. }
  TmpPathStartedAt := Round(Now * MSecsPerDay);
  InitCriticalSection(ProcessEnvironmentCriticalSection);
  InitCriticalSection(ProcessHandleSetupCriticalSection);
  {$IFDEF OBJECTSTORE_TESTING}
  InitCriticalSection(ProcessHandleSetupObservationCriticalSection);
  {$ENDIF}

end.
