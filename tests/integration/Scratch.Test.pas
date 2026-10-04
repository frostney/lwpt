{ Scratch.Test — focused coverage for invocation-private test roots. }

program Scratch.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.Scratch;

const
  DeadLinkPIDSlug = 'zik0zi';
  DeadPIDSlug = 'zik0zj';

type
  TScratch = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRootsAreUniqueAcrossCalls;
    procedure TestReapingDeletesDeadAndLeavesLiveOwner;
    procedure TestRecursiveDeleteRemovesTreesPastMaxPath;
    procedure TestReadsShareAHandleHoldingDeleteAccess;
    procedure TestReadsRetryABrieflyExclusiveHandle;
    procedure TestReadsReachFilesPastMaxPath;
    {$IFDEF MSWINDOWS}
    procedure TestRecursiveDeleteRemovesRootLinkPastMaxPath;
    {$ENDIF}
  end;

const
  { Win32 MAX_PATH, including the terminating NUL. }
  LEGACY_WINDOWS_MAX_PATH = 260;

{ A path below ARoot longer than MAX_PATH, from components inside NAME_MAX. }
function DeepBelow(const ARoot: string): string;
begin
  Result := ARoot;
  while Length(Result) <= LEGACY_WINDOWS_MAX_PATH + 20 do
    Result := Result + '/' + StringOfChar('d', 48);
end;

{$IFDEF MSWINDOWS}
const
  IO_REPARSE_TAG_MOUNT_POINT_TEST = $A0000003;
  FSCTL_SET_REPARSE_POINT_TEST = $000900A4;
  FILE_FLAG_OPEN_REPARSE_POINT_TEST = $00200000;
  FILE_FLAG_BACKUP_SEMANTICS_TEST = $02000000;

{ Creates a directory junction at ALink (which may pass MAX_PATH) pointing
  at ATarget, through the extended spelling and FSCTL_SET_REPARSE_POINT:
  `mklink /J` goes through cmd.exe, which cannot address such a link. True
  only when the link really exists afterwards. }
function TryCreateLongJunction(const ALink, ATarget: string): Boolean;
var
  LinkPath, Substitute, Print: UnicodeString;
  Buffer: TBytes;
  Handle: THandle;
  PathBytes, DataLength: Integer;
  Returned: DWORD;

  procedure PutWord(const AOffset: Integer; const AValue: Word);
  begin
    Move(AValue, Buffer[AOffset], SizeOf(AValue));
  end;

begin
  Result := False;
  LinkPath := WindowsExtendedPath(ALink);
  Print := UnicodeString(StringReplace(ExpandFileName(ATarget), '/', '\',
    [rfReplaceAll]));
  Substitute := '\??\' + Print;
  PathBytes := (Length(Substitute) + 1 + Length(Print) + 1) * SizeOf(WideChar);
  DataLength := 8 + PathBytes;
  SetLength(Buffer, 8 + DataLength);
  FillChar(Buffer[0], Length(Buffer), 0);
  PLongWord(@Buffer[0])^ := IO_REPARSE_TAG_MOUNT_POINT_TEST;
  PutWord(4, Word(DataLength));
  PutWord(8, 0);
  PutWord(10, Word(Length(Substitute) * SizeOf(WideChar)));
  PutWord(12, Word((Length(Substitute) + 1) * SizeOf(WideChar)));
  PutWord(14, Word(Length(Print) * SizeOf(WideChar)));
  Move(Substitute[1], Buffer[16], Length(Substitute) * SizeOf(WideChar));
  Move(Print[1], Buffer[16 + (Length(Substitute) + 1) * SizeOf(WideChar)],
    Length(Print) * SizeOf(WideChar));
  if not Windows.CreateDirectoryW(PWideChar(LinkPath), nil) then Exit;
  Handle := Windows.CreateFileW(PWideChar(LinkPath), GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT_TEST
      or FILE_FLAG_BACKUP_SEMANTICS_TEST, 0);
  if Handle <> INVALID_HANDLE_VALUE then
    try
      Result := Windows.DeviceIoControl(Handle, FSCTL_SET_REPARSE_POINT_TEST,
        @Buffer[0], Length(Buffer), nil, 0, Returned, nil);
    finally
      Windows.CloseHandle(Handle);
    end;
  Result := Result and IsDirSymlinkOrJunction(ALink)
    and LongPathDirectoryExists(ALink);
  if not Result then Windows.RemoveDirectoryW(PWideChar(LinkPath));
end;

{ '' when a junction past MAX_PATH can be created here, else the reason. }
function LongJunctionSkipReason: string;
var Probe, Link: string;
begin
  Probe := ExpandFileName('build/tests/tmp/scratch-junction-probe-'
    + IntToStr(GetProcessID));
  Link := DeepBelow(Probe) + '/link';
  LongPathForceDirectories(Probe + '/target');
  LongPathForceDirectories(ExtractFileDir(Link));
  try
    if TryCreateLongJunction(Link, Probe + '/target') then Result := ''
    else Result := 'a directory junction past MAX_PATH cannot be created '
      + 'on this host';
  finally
    Windows.RemoveDirectoryW(PWideChar(WindowsExtendedPath(Link)));
    WipeDir(Probe);
  end;
end;
{$ENDIF}

procedure TScratch.TestRootsAreUniqueAcrossCalls;
var
  FirstRoot, SecondRoot: string;
begin
  FirstRoot := CreateScratchRoot('scratch-unique');
  SecondRoot := CreateScratchRoot('scratch-unique');
  try
    Expect<Boolean>(FirstRoot <> SecondRoot).ToBe(True);
    Expect<Boolean>(DirectoryExists(FirstRoot)).ToBe(True);
    Expect<Boolean>(DirectoryExists(SecondRoot)).ToBe(True);
  finally
    RecursiveDelete(FirstRoot);
    RecursiveDelete(SecondRoot);
  end;
end;

procedure TScratch.TestReapingDeletesDeadAndLeavesLiveOwner;
var
  Base, DeadLink, DeadRoot, LiveRoot, NextRoot: string;
begin
  LiveRoot := CreateScratchRoot('scratch-reaping');
  Base := IncludeTrailingPathDelimiter(ExtractFileDir(LiveRoot));
  DeadRoot := Base + 'scratch-reaping-' + DeadPIDSlug + '-0';
  ForceDirectories(DeadRoot);
  WriteTextFile(DeadRoot + '/dead', 'dead');
  DeadLink := '';
  {$IFDEF UNIX}
  DeadLink := Base + 'scratch-reaping-' + DeadLinkPIDSlug + '-0';
  if FpSymlink(PAnsiChar(LiveRoot), PAnsiChar(DeadLink)) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for stale root');
  {$ENDIF}
  WriteTextFile(LiveRoot + '/alive', 'alive');
  NextRoot := '';
  try
    NextRoot := CreateScratchRoot('scratch-reaping');
    Expect<Boolean>(not DirectoryExists(DeadRoot)).ToBe(True);
    {$IFDEF UNIX}
    Expect<Boolean>(not DirectoryExists(DeadLink)).ToBe(True);
    {$ENDIF}
    Expect<Boolean>(DirectoryExists(LiveRoot)).ToBe(True);
    Expect<Boolean>(FileExists(LiveRoot + '/alive')).ToBe(True);
  finally
    RecursiveDelete(LiveRoot);
    RecursiveDelete(NextRoot);
    RecursiveDelete(DeadRoot);
    RecursiveDelete(DeadLink);
  end;
end;

{ #347: toolkit code legitimately nests state past the Windows MAX_PATH, so
  scratch cleanup must remove such trees. The fixture is written with the
  Core long-path helpers; the wipe uses only Tests.Scratch. }
procedure TScratch.TestRecursiveDeleteRemovesTreesPastMaxPath;
var
  Root, Deep, FilePath: string;
  Stream: TLWPTProtectedFileStream;
begin
  Root := CreateScratchRoot('scratch-deep');
  Deep := DeepBelow(Root);
  FilePath := Deep + '/' + StringOfChar('f', 40) + '.txt';
  Expect<Boolean>(Length(FilePath) > LEGACY_WINDOWS_MAX_PATH).ToBe(True);
  Expect<Boolean>(LongPathForceDirectories(Deep + '/empty')).ToBe(True);
  Stream := OpenProtectedFileStream(FilePath, fmCreate);
  Stream.Free;
  Expect<Boolean>(LongPathFileExists(FilePath)).ToBe(True);

  RecursiveDelete(Root);

  Expect<Boolean>(LongPathFileExists(FilePath)).ToBe(False);
  Expect<Boolean>(LongPathDirectoryExists(Root)).ToBe(False);
end;

{$IFDEF MSWINDOWS}
{ A root that is itself a junction past MAX_PATH is detached as a node; its
  target and the target's contents survive. }
procedure TScratch.TestRecursiveDeleteRemovesRootLinkPastMaxPath;
var Root, Target, Link: string;
begin
  Root := CreateScratchRoot('scratch-root-link');
  try
    Target := Root + '/target';
    LongPathForceDirectories(Target);
    OpenProtectedFileStream(Target + '/keep.txt', fmCreate).Free;
    Link := DeepBelow(Root) + '/link';
    Expect<Boolean>(Length(Link) > LEGACY_WINDOWS_MAX_PATH).ToBe(True);
    LongPathForceDirectories(ExtractFileDir(Link));
    Expect<Boolean>(TryCreateLongJunction(Link, Target)).ToBe(True);
    Expect<Boolean>(LongPathFileExists(Link + '/keep.txt')).ToBe(True);

    RecursiveDelete(Link);

    Expect<Boolean>(IsDirSymlinkOrJunction(Link)).ToBe(False);
    Expect<Boolean>(LongPathDirectoryExists(Link)).ToBe(False);
    Expect<Boolean>(LongPathFileExists(Target + '/keep.txt')).ToBe(True);
  finally
    RecursiveDelete(Root);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
type
  { Reads one file on its own thread, so the test can hold the file while
    the read retries and release it only after observing a retry. }
  TFileReader = class(TThread)
  private
    FPath: string;
  protected
    procedure Execute; override;
  public
    Content, Failure: string;
    constructor Create(const APath: string);
  end;

constructor TFileReader.Create(const APath: string);
begin
  FPath := APath;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TFileReader.Execute;
begin
  try
    Content := ReadBinaryFile(FPath);
  except
    on E: Exception do Failure := E.Message;
  end;
end;

function OpenTestHandle(const APath: string; const AAccess,
  AShare: DWORD): THandle;
begin
  Result := Windows.CreateFileW(PWideChar(UnicodeString(APath)), AAccess,
    AShare, nil, Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if Result = Windows.INVALID_HANDLE_VALUE then RaiseLastOSError;
end;
{$ENDIF}

{ A write-through rename keeps its handle, with delete access, open while
  the renamed file is already visible; a reader that does not share delete
  access fails against it with a sharing violation. }
procedure TScratch.TestReadsShareAHandleHoldingDeleteAccess;
{$IFDEF MSWINDOWS}
const
  DELETE_ACCESS = $00010000;
var
  Root, Path: string;
  Handle: THandle;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  Root := CreateScratchRoot('scratch-shared-read');
  try
    Path := Root + '\published.toml';
    WriteTextFile(Path, 'complete = true' + #10);
    Handle := OpenTestHandle(Path, DELETE_ACCESS or Windows.GENERIC_READ,
      Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
        or Windows.FILE_SHARE_DELETE);
    try
      { WriteTextFile uses the platform line ending. }
      Expect<string>(Trim(ReadBinaryFile(Path))).ToBe('complete = true');
    finally
      Windows.CloseHandle(Handle);
    end;
  finally
    RecursiveDelete(Root);
  end;
  {$ENDIF}
end;

{ A handle that shares nothing makes every open fail with a sharing
  violation. A read retries that, and only that, until the handle closes;
  the test releases the handle only after observing a retried open, so no
  timing window decides the outcome. Held past the retry bound, the read
  fails. }
procedure TScratch.TestReadsRetryABrieflyExclusiveHandle;
{$IFDEF MSWINDOWS}
var
  Root, Path, Failure: string;
  Handle: THandle;
  Reader: TFileReader;
  Baseline: LongInt;
  StartedAt: QWord;
  Retried: Boolean;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  Root := CreateScratchRoot('scratch-shared-read');
  try
    Path := Root + '\held.toml';
    WriteTextFile(Path, 'held = true' + #10);
    Handle := OpenTestHandle(Path, Windows.GENERIC_READ, 0);
    Baseline := InterLockedExchangeAdd(ScratchReadSharingRetries, 0);
    Reader := TFileReader.Create(Path);
    try
      { Bounded only as a hang guard; a retry normally shows at once. }
      StartedAt := GetTickCount64;
      repeat
        Retried := InterLockedExchangeAdd(ScratchReadSharingRetries, 0)
          > Baseline;
        if Retried or Reader.Finished then Break;
        SysUtils.Sleep(1);
      until GetTickCount64 - StartedAt >= READ_SHARING_RETRY_MILLISECONDS;
      Windows.CloseHandle(Handle);
      Handle := Windows.INVALID_HANDLE_VALUE;
      Reader.WaitFor;
      Expect<Boolean>(Retried).ToBe(True);
      Expect<string>(Reader.Failure).ToBe('');
      { WriteTextFile uses the platform line ending. }
      Expect<string>(Trim(Reader.Content)).ToBe('held = true');
    finally
      if Handle <> Windows.INVALID_HANDLE_VALUE then
        Windows.CloseHandle(Handle);
      Reader.Free;
    end;
    Handle := OpenTestHandle(Path, Windows.GENERIC_READ, 0);
    try
      Baseline := InterLockedExchangeAdd(ScratchReadSharingRetries, 0);
      Failure := '';
      try
        ReadBinaryFile(Path);
      except
        on E: EFOpenError do Failure := E.Message;
      end;
      Expect<Boolean>(Failure <> '').ToBe(True);
      Expect<Boolean>(InterLockedExchangeAdd(ScratchReadSharingRetries, 0)
        > Baseline).ToBe(True);
    finally
      Windows.CloseHandle(Handle);
    end;
  finally
    RecursiveDelete(Root);
  end;
  {$ENDIF}
end;

{ A file nested past the 260-character Win32 MAX_PATH reads through its
  extended-length spelling. }
procedure TScratch.TestReadsReachFilesPastMaxPath;
var
  Root, FilePath: string;
  Stream: TLWPTProtectedFileStream;
  Content: string;
begin
  Root := CreateScratchRoot('scratch-deep-read');
  try
    FilePath := DeepBelow(Root) + '/' + StringOfChar('r', 40) + '.toml';
    Expect<Boolean>(Length(FilePath) > LEGACY_WINDOWS_MAX_PATH).ToBe(True);
    Expect<Boolean>(LongPathForceDirectories(ExtractFileDir(FilePath)))
      .ToBe(True);
    Content := 'deep = true' + #10;
    Stream := OpenProtectedFileStream(FilePath, fmCreate);
    try
      Stream.WriteBuffer(Content[1], Length(Content));
    finally
      Stream.Free;
    end;
    Expect<string>(ReadBinaryFile(FilePath)).ToBe(Content);
  finally
    RecursiveDelete(Root);
  end;
end;

procedure TScratch.SetupTests;
{$IFDEF MSWINDOWS}
var SkipReason: string;
{$ENDIF}
begin
  Test('roots are unique across calls', TestRootsAreUniqueAcrossCalls);
  Test('recursive delete removes a tree past MAX_PATH',
    TestRecursiveDeleteRemovesTreesPastMaxPath);
  Test('a read reaches a file past MAX_PATH', TestReadsReachFilesPastMaxPath);
  {$IFDEF MSWINDOWS}
  Test('a read shares the file with a handle holding delete access',
    TestReadsShareAHandleHoldingDeleteAccess);
  Test('a read retries a briefly exclusive handle within its bound',
    TestReadsRetryABrieflyExclusiveHandle);
  {$ELSE}
  Skip('a read shares the file with a handle holding delete access',
    TestReadsShareAHandleHoldingDeleteAccess, 'Windows share modes');
  Skip('a read retries a briefly exclusive handle within its bound',
    TestReadsRetryABrieflyExclusiveHandle, 'Windows share modes');
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  SkipReason := LongJunctionSkipReason;
  if SkipReason = '' then
    Test('recursive delete detaches a root junction past MAX_PATH',
      TestRecursiveDeleteRemovesRootLinkPastMaxPath)
  else
    Skip('recursive delete detaches a root junction past MAX_PATH',
      TestRecursiveDeleteRemovesRootLinkPastMaxPath, SkipReason);
  {$ENDIF}
  Test('reaping deletes dead owner and leaves live owner',
    TestReapingDeletesDeadAndLeavesLiveOwner);
end;

begin
  TestRunnerProgram.AddSuite(TScratch.Create('Scratch'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
