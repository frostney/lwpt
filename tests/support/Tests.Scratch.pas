{ Tests.Scratch — scratch-directory file helpers shared by the
  integration and E2E test programs.

  Every per-test scratch project needs the same primitives: allocate
  an invocation-private root, write a small text file (creating parent
  dirs), and wipe a directory tree. These used to be copy-pasted into
  each test program; this unit is their single home, next to
  Tests.LwptSubprocess (the support dir is already on every test's
  compile path via LWPT.Command.Testing).

  CreateScratchRoot uses a compact base-36 PID + timestamp owner slug.
  Before allocating it, stale siblings are atomically claimed and
  removed. A dead owner's root is reaped only after a short grace
  period (orphaned descendants of a crashed run can briefly outlive
  it); a live-looking owner's root still falls to the age ceiling,
  which bounds PID recycling. PID checks fail closed when liveness is
  indeterminate; the age ceiling alone is used only on platforms
  without a liveness API. This lets concurrent test invocations
  coexist while recovering debris from interrupted runs.

  RecursiveDelete is link-aware: a symlink is unlinked and a Windows
  directory symlink/junction is removed as a node (RemoveDir detaches
  a junction without touching its target), never followed — so a link
  planted inside a scratch tree (by the build --clean symlink
  regression test, or by the installer's monorepo link path, which
  puts junctions under a scratch project's .lwpt/modules/) cannot
  make the wipe escape the tree, delete live package sources, or
  recurse forever.

  A wipe that cannot complete raises, naming the path: a test that
  silently proceeds on a half-wiped scratch dir turns into stale-state
  flakiness that is far harder to diagnose than a loud setup error. }

unit Tests.Scratch;

{$mode delphi}{$H+}

interface

function CreateScratchRoot(const ASuite: string): string;
procedure WriteTextFile(const APath, AContent: string);
procedure RecursiveDelete(const APath: string);
function ReadBinaryFile(const APath: string): string;
function TestCompilerExecutable: string;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  DateUtils,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils;

const
  ScratchBase = 'build/tests/tmp';
  ReapPrefix = '.reap-';
  StaleAgeDays = 7;
  DeadOwnerGraceMSec = 10 * 60 * 1000;
  Base36Radix = 36;
  OwnerSeparator = '-';

type
  TProcessLiveness = (plAlive, plDead, plUnknown, plUnavailable);

var
  LastScratchTimestamp: QWord = 0;
  ReapCounter: QWord = 0;

function EncodeBase36(AValue: QWord): string;
const
  Digits = '0123456789abcdefghijklmnopqrstuvwxyz';
begin
  if AValue = 0 then Exit('0');
  Result := '';
  while AValue > 0 do
  begin
    Result := Digits[(AValue mod Base36Radix) + 1] + Result;
    AValue := AValue div Base36Radix;
  end;
end;

function TryDecodeBase36(const AValue: string; out ADecoded: QWord): Boolean;
var
  Index: Integer;
  Digit: QWord;
begin
  Result := False;
  ADecoded := 0;
  if AValue = '' then Exit;
  for Index := 1 to Length(AValue) do
  begin
    case AValue[Index] of
      '0'..'9': Digit := Ord(AValue[Index]) - Ord('0');
      'a'..'z': Digit := Ord(AValue[Index]) - Ord('a') + 10;
    else
      Exit;
    end;
    if ADecoded > (High(QWord) - Digit) div Base36Radix then Exit;
    ADecoded := ADecoded * Base36Radix + Digit;
  end;
  Result := True;
end;

function CurrentScratchTimestamp: QWord; inline;
begin
  Result := QWord(Round(Now * MSecsPerDay));
end;

function NextScratchTimestamp: QWord;
begin
  Result := CurrentScratchTimestamp;
  if Result <= LastScratchTimestamp then Result := LastScratchTimestamp + 1;
  LastScratchTimestamp := Result;
end;

function PathExists(const APath: string): Boolean;
var
  Search: TSearchRec;
begin
  if APath = '' then Exit(False);
  Result := SysUtils.FindFirst(ExcludeTrailingPathDelimiter(APath),
    faAnyFile or faSymLink, Search) = 0;
  if Result then SysUtils.FindClose(Search);
end;

procedure ValidateSuiteName(const ASuite: string);
var
  Index: Integer;
begin
  if ASuite = '' then
    raise Exception.Create('CreateScratchRoot: suite name cannot be empty');
  for Index := 1 to Length(ASuite) do
    if not (ASuite[Index] in ['a'..'z', '0'..'9', '-']) then
      raise Exception.CreateFmt(
        'CreateScratchRoot: invalid suite name "%s"', [ASuite]);
end;

function ProcessLiveness(const APID: QWord): TProcessLiveness;
{$IFDEF UNIX}
var
  ErrorCode: cint;
begin
  if APID = 0 then Exit(plDead);
  if APID > QWord(High(LongInt)) then Exit(plUnknown);
  if FpKill(LongInt(APID), 0) = 0 then Exit(plAlive);
  ErrorCode := fpgeterrno;
  if ErrorCode = ESysESRCH then Exit(plDead);
  if ErrorCode = ESysEPERM then Exit(plAlive);
  Result := plUnknown;
end;
{$ELSE}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  WaitResult, ErrorCode: DWORD;
begin
  if APID = 0 then Exit(plDead);
  if APID > QWord(High(DWORD)) then Exit(plDead);
  Handle := Windows.OpenProcess(Windows.SYNCHRONIZE, False, DWORD(APID));
  if Handle = 0 then
  begin
    ErrorCode := Windows.GetLastError;
    if ErrorCode = Windows.ERROR_INVALID_PARAMETER then Exit(plDead);
    { Like EPERM on Unix: the process exists but is not ours. }
    if ErrorCode = Windows.ERROR_ACCESS_DENIED then Exit(plAlive);
    Exit(plUnknown);
  end;
  try
    { GetExitCodeProcess cannot tell a running process from one that
      exited with code 259 (STILL_ACTIVE); a zero-timeout wait on the
      process handle has no such ambiguity. }
    WaitResult := Windows.WaitForSingleObject(Handle, 0);
    if WaitResult = Windows.WAIT_TIMEOUT then Result := plAlive
    else if WaitResult = Windows.WAIT_OBJECT_0 then Result := plDead
    else Result := plUnknown;
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ELSE}
begin
  if APID = 0 then Exit(plDead);
  Result := plUnavailable;
end;
{$ENDIF}
{$ENDIF}

function OwnerIsStale(const APID: QWord; const ATimestamp: QWord): Boolean;
var
  Current, Age: QWord;
begin
  Current := CurrentScratchTimestamp;
  if Current > ATimestamp then Age := Current - ATimestamp
  else Age := 0;
  case ProcessLiveness(APID) of
    { A crashed owner's orphaned descendants can briefly outlive it
      and still write into the root; the grace period outlasts them. }
    plDead: Exit(Age >= DeadOwnerGraceMSec);
    { PID recycling can make an abandoned root look owned forever;
      the age ceiling bounds that. }
    plAlive, plUnknown: Exit(Age >= QWord(StaleAgeDays) * MSecsPerDay);
  end;
  Result := Age >= QWord(StaleAgeDays) * MSecsPerDay;
end;

function TryParseOwner(const AName, APrefix: string;
  out APID: QWord; out ATimestamp: QWord): Boolean;
var
  Tail, PIDPart, TimestampPart: string;
  Separator: Integer;
begin
  Result := False;
  APID := 0;
  ATimestamp := 0;
  if Copy(AName, 1, Length(APrefix)) <> APrefix then Exit;
  Tail := Copy(AName, Length(APrefix) + 1, MaxInt);
  Separator := Pos(OwnerSeparator, Tail);
  if Separator = 0 then Exit;
  PIDPart := Copy(Tail, 1, Separator - 1);
  TimestampPart := Copy(Tail, Separator + 1, MaxInt);
  if Pos(OwnerSeparator, TimestampPart) > 0 then Exit;
  if not TryDecodeBase36(PIDPart, APID) then Exit;
  if not TryDecodeBase36(TimestampPart, ATimestamp) then Exit;
  Result := True;
end;

function TryParseReapOwner(const AName: string;
  out APID: QWord; out ATimestamp: QWord): Boolean;
var
  Tail, OwnerPart, CounterPart: string;
  Separator: Integer;
  DecodedReapCounter: QWord;
begin
  Result := False;
  if Copy(AName, 1, Length(ReapPrefix)) <> ReapPrefix then Exit;
  Tail := Copy(AName, Length(ReapPrefix) + 1, MaxInt);
  Separator := LastDelimiter(OwnerSeparator, Tail);
  if Separator = 0 then Exit;
  OwnerPart := Copy(Tail, 1, Separator - 1);
  CounterPart := Copy(Tail, Separator + 1, MaxInt);
  if not TryDecodeBase36(CounterPart, DecodedReapCounter) then Exit;
  Result := TryParseOwner(OwnerPart, '', APID, ATimestamp);
end;

procedure RemoveLink(const APath: string; const AAttributes: LongInt);
begin
  {$IFDEF MSWINDOWS}
  if (AAttributes and faDirectory) <> 0 then
  begin
    if not RemoveDir(APath) then
      raise Exception.CreateFmt(
        'RecursiveDelete: failed to remove dir link "%s": %s',
        [APath, SysErrorMessage(GetLastOSError)]);
  end
  else
  {$ENDIF}
  if not SysUtils.DeleteFile(APath) then
    raise Exception.CreateFmt(
      'RecursiveDelete: failed to unlink "%s": %s',
      [APath, SysErrorMessage(GetLastOSError)]);
end;

procedure ClaimAndDelete(const APath, ABase: string);
var
  ClaimedPath: string;
begin
  repeat
    Inc(ReapCounter);
    ClaimedPath := ABase + ReapPrefix
      + EncodeBase36(QWord(GetProcessID)) + OwnerSeparator
      + EncodeBase36(NextScratchTimestamp) + OwnerSeparator
      + EncodeBase36(ReapCounter);
  until not PathExists(ClaimedPath);
  if not RenameFile(APath, ClaimedPath) then
  begin
    { Another invocation may have claimed the same stale root after
      enumeration. Only report an error when the source still exists. }
    if PathExists(APath) then
      raise Exception.CreateFmt(
        'CreateScratchRoot: failed to claim stale root "%s": %s',
        [APath, SysErrorMessage(GetLastOSError)]);
    Exit;
  end;
  RecursiveDelete(ClaimedPath);
end;

procedure ReapStaleRoots(const ABase, ASuite: string);
var
  Search: TSearchRec;
  Candidates: TStringList;
  Base, Candidate: string;
  PID: QWord;
  Timestamp: QWord;
  Index: Integer;
begin
  Base := IncludeTrailingPathDelimiter(ABase);
  Candidates := TStringList.Create;
  try
    if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, Search) = 0 then
      try
        repeat
          if (Search.Name = '.') or (Search.Name = '..') then Continue;
          if (Search.Attr and (faDirectory or faSymLink)) = 0 then Continue;
          if TryParseOwner(Search.Name, ASuite + OwnerSeparator,
              PID, Timestamp)
            and OwnerIsStale(PID, Timestamp) then
            Candidates.Add(Base + Search.Name)
          else if TryParseReapOwner(Search.Name, PID, Timestamp)
            and OwnerIsStale(PID, Timestamp) then
            Candidates.Add(Base + Search.Name);
        until SysUtils.FindNext(Search) <> 0;
      finally
        SysUtils.FindClose(Search);
      end;
    for Index := 0 to Candidates.Count - 1 do
    begin
      Candidate := Candidates[Index];
      if PathExists(Candidate) then ClaimAndDelete(Candidate, Base);
    end;
  finally
    Candidates.Free;
  end;
end;

function CreateScratchRoot(const ASuite: string): string;
var
  Base, ProcessIDSlug: string;
begin
  ValidateSuiteName(ASuite);
  Base := ExpandFileName(ScratchBase);
  if not ForceDirectories(Base) and not DirectoryExists(Base) then
    raise Exception.CreateFmt(
      'CreateScratchRoot: failed to create base directory "%s": %s',
      [Base, SysErrorMessage(GetLastOSError)]);
  ReapStaleRoots(Base, ASuite);
  ProcessIDSlug := EncodeBase36(QWord(GetProcessID));
  repeat
    Result := IncludeTrailingPathDelimiter(Base) + ASuite
      + OwnerSeparator + ProcessIDSlug + OwnerSeparator
      + EncodeBase36(NextScratchTimestamp);
  until not PathExists(Result);
  if not ForceDirectories(Result) and not DirectoryExists(Result) then
    raise Exception.CreateFmt(
      'CreateScratchRoot: failed to create root "%s": %s',
      [Result, SysErrorMessage(GetLastOSError)]);
end;

procedure WriteTextFile(const APath, AContent: string);
var
  SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

function ReadBinaryFile(const APath: string): string;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function TestCompilerExecutable: string;
begin
  Result := GetEnvironmentVariable('LWPT_FPC');
  if Result = '' then Result := GetEnvironmentVariable('FPC');
  if Result <> '' then Exit;
  {$IFDEF MSWINDOWS}
  Result := 'fpc.exe';
  {$ELSE}
  Result := 'fpc';
  {$ENDIF}
end;

procedure RecursiveDelete(const APath: string);
var
  SR, RootSearch: TSearchRec;
  Base: string;
begin
  if APath = '' then Exit;
  if SysUtils.FindFirst(ExcludeTrailingPathDelimiter(APath),
    faAnyFile or faSymLink, RootSearch) <> 0 then Exit;
  try
    if (RootSearch.Attr and faSymLink) <> 0 then
    begin
      RemoveLink(APath, RootSearch.Attr);
      Exit;
    end;
    if (RootSearch.Attr and faDirectory) = 0 then Exit;
  finally
    SysUtils.FindClose(RootSearch);
  end;
  Base := IncludeTrailingPathDelimiter(APath);
  { faSymLink in the mask makes FindFirst report links as links (the
    same $400 bit is FILE_ATTRIBUTE_REPARSE_POINT on Windows, so
    junctions carry it too); a link is removed as a node instead of
    recursed into. The node-removal call is platform-split: a Unix
    symlink (even one whose Attr also carries faDirectory from the
    target) unlinks via DeleteFile — RemoveDir on a symlink is
    ENOTDIR — while a Windows junction / directory reparse point is
    the opposite: DeleteFile cannot remove it, RemoveDir detaches it
    without touching the target. }
  if SysUtils.FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faSymLink) <> 0 then
          RemoveLink(Base + SR.Name, SR.Attr)
        else if (SR.Attr and faDirectory) <> 0 then
          RecursiveDelete(Base + SR.Name)
        else if not SysUtils.DeleteFile(Base + SR.Name) then
          raise Exception.CreateFmt(
            'RecursiveDelete: failed to delete "%s": %s',
            [Base + SR.Name, SysErrorMessage(GetLastOSError)]);
      until SysUtils.FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  if not RemoveDir(APath) then
    raise Exception.CreateFmt(
      'RecursiveDelete: failed to remove directory "%s": %s',
      [APath, SysErrorMessage(GetLastOSError)]);
end;

end.
