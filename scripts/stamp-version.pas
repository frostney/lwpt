#!/usr/bin/env instantfpc
program StampVersion;

{ Write source/Version.inc with a Pascal `PROGRAM_VERSION = '<value>';`
  constant. LWPT.Core.pas {$I}'s the result; lwpt --version reports it.

  The value is, in priority order:
    1. $LWPT_VERSION_OVERRIDE if set + non-empty — used by release.yml
       to stamp the GIT TAG into release binaries, so a downloaded
       release reports the version it was tagged as (e.g. `0.1.0-rc.3`).
    2. otherwise [package].version from lwpt.toml — the dev/unreleased
       version reported by locally-built binaries.

  This split is deliberate: dev builds report the manifest version
  (and Version.Test.pas's drift guard checks binary == manifest for
  those); release builds report the tag (release.yml asserts binary ==
  tag on the native target). See docs/ci.md "Release version stamping".

  Deliberately self-contained — does not depend on packages/toml so the
  bootstrap chicken-and-egg (lwpt cannot resolve its own deps before the
  binary exists) is preserved. The parser is a naive line scan for the
  first `version = "..."` line inside the [package] section; anything
  fancier (multi-section TOML state machine) would pull in packages/toml.

  Concurrent runs are safe (issue #361). Two self-builds that start
  together can both run this hook while a third compiles against
  Version.inc, so the file is never rewritten in place:
    - when it already holds exactly the expected text it is left
      untouched (mtime included), which is the common concurrent case;
    - otherwise the text goes to a uniquely named, exclusively created
      temporary file in the project's own .lwpt/tmp directory (beside
      lwpt.toml, created when missing), which then replaces the
      destination atomically: rename(2) on Unix, MoveFileExW with
      MOVEFILE_REPLACE_EXISTING on Windows. Staging there keeps the
      transient file out of source/, which builds fingerprint. Windows
      sharing violations (a reader holding the destination) are retried a
      bounded number of times;
    - an `[lwpt] tmp-dir` override is deliberately not read: this naive
      line scan cannot parse TOML faithfully, and a misread path could
      point outside the project. .lwpt/tmp sits inside the project, so it
      shares the destination's file system;
    - there is no other staging place. When .lwpt/tmp cannot be created
      or written, or the rename crosses file systems (EXDEV,
      ERROR_NOT_SAME_DEVICE), the run fails with a message naming the
      path and Version.inc is left as it was;
    - a failed replacement whose destination already holds the expected
      text (a concurrent writer won) counts as success, and a temporary
      file removed under the script (lwpt install wipes .lwpt/tmp) is
      written again, a bounded number of times;
    - every temporary file that is not published is deleted; one that
      cannot be deleted is reported on stderr.
  The bytes are those TStringList.SaveToFile wrote before: every line,
  including the last, ends with the platform LineEnding. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils;

const
  MANIFEST_PATH = 'lwpt.toml';
  OUTPUT_PATH   = 'source/Version.inc';
  { Relative to the directory holding the manifest. }
  STAGING_DIR = '.lwpt/tmp';
  TEMP_PREFIX = 'stamp-version-';
  { A temporary file deleted under the script is written again at most this
    many times in total. }
  MAX_PUBLISH_ATTEMPTS = 3;
  { A destination larger than this cannot hold the expected text. }
  MAX_COMPARE_BYTES = 64 * 1024;
  { Exclusive creation fails only on a leftover name; a handful of fresh
    names is plenty. }
  MAX_TEMP_NAME_ATTEMPTS = 16;
  {$IFDEF UNIX}
  TEMP_FILE_PERMISSIONS = &666; { TFileStream's default; umask applies }
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  MOVEFILE_REPLACE_EXISTING_STAMP = $00000001;
  MOVEFILE_WRITE_THROUGH_STAMP = $00000008;
  { At most about 3.5 seconds of waiting in total: long enough to outlast a
    compiler or a sibling run holding the destination open, never
    unbounded. }
  MAX_REPLACE_ATTEMPTS = 40;
  REPLACE_RETRY_FIRST_DELAY_MS = 5;
  REPLACE_RETRY_MAX_DELAY_MS = 100;
  {$ENDIF}

type
  TReplaceFailure = (rfOther, rfCrossDevice, rfTempVanished);

var
  TempNameCounter: Integer = 0;

function ExtractVersion(const ALines: TStringList): string;
var
  i, EqPos : Integer;
  Line, Trimmed, Value : string;
  InPackage : Boolean;
begin
  Result := '';
  InPackage := False;
  for i := 0 to ALines.Count - 1 do
  begin
    Trimmed := Trim(ALines[i]);
    if Trimmed = '' then Continue;
    if (Length(Trimmed) > 0) and (Trimmed[1] = '#') then Continue;

    if (Length(Trimmed) >= 2) and (Trimmed[1] = '[') then
    begin
      InPackage := SameText(Trimmed, '[package]');
      Continue;
    end;

    if not InPackage then Continue;

    Line := Trimmed;
    if not SameText(Copy(Line, 1, 7), 'version') then Continue;

    EqPos := Pos('=', Line);
    if EqPos = 0 then Continue;

    Value := Trim(Copy(Line, EqPos + 1, MaxInt));
    Value := StringReplace(Value, '"', '', [rfReplaceAll]);
    Value := StringReplace(Value, '''', '', [rfReplaceAll]);
    Result := Trim(Value);
    Exit;
  end;
end;

{ Reads APath whole. False when it is absent, unreadable, or too large to
  hold the expected text. On Windows the handle grants every sharing mode,
  so this comparison never makes a sibling run's create or write fail; a
  replacement that lands while it is open is retried. }
function ReadSmallFile(const APath: string; out AContent: string): Boolean;
var
  {$IFDEF UNIX}
  Fd: cint;
  Info: Stat;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Handle: THandle;
  SizeHigh, SizeLow: DWORD;
  {$ENDIF}
  Total, Got: Integer;
  Probe: Byte;
begin
  Result := False;
  AContent := '';
  {$IFDEF UNIX}
  Fd := FpOpen(PChar(APath), O_RDONLY);
  if Fd < 0 then Exit;
  try
    if FpFStat(Fd, Info) <> 0 then Exit;
    if not FpS_ISREG(Info.st_mode) then Exit;
    if Info.st_size > MAX_COMPARE_BYTES then Exit;
    SetLength(AContent, Info.st_size);
    Total := 0;
    while Total < Length(AContent) do
    begin
      Got := FpRead(Fd, AContent[Total + 1], Length(AContent) - Total);
      if Got <= 0 then Exit;
      Inc(Total, Got);
    end;
    { A file still growing under a concurrent writer is not a match. }
    if FpRead(Fd, Probe, 1) <> 0 then Exit;
    Result := True;
  finally
    FpClose(Fd);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Handle := Windows.CreateFileW(PWideChar(UnicodeString(APath)),
    Windows.GENERIC_READ,
    Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
      or Windows.FILE_SHARE_DELETE,
    nil, Windows.OPEN_EXISTING, Windows.FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = Windows.INVALID_HANDLE_VALUE then Exit;
  try
    SizeLow := Windows.GetFileSize(Handle, @SizeHigh);
    if (SizeLow = $FFFFFFFF) and (Windows.GetLastError <> Windows.NO_ERROR) then
      Exit;
    if (SizeHigh <> 0) or (SizeLow > MAX_COMPARE_BYTES) then Exit;
    SetLength(AContent, SizeLow);
    Total := 0;
    while Total < Length(AContent) do
    begin
      if not Windows.ReadFile(Handle, AContent[Total + 1],
        DWORD(Length(AContent) - Total), DWORD(Got), nil) then Exit;
      if Got <= 0 then Exit;
      Inc(Total, Got);
    end;
    if not Windows.ReadFile(Handle, Probe, 1, DWORD(Got), nil)
      or (Got <> 0) then Exit;
    Result := True;
  finally
    Windows.CloseHandle(Handle);
  end;
  {$ENDIF}
end;

function HoldsText(const APath, AText: string): Boolean;
var
  Existing: string;
begin
  Result := ReadSmallFile(APath, Existing) and (Existing = AText);
end;

function NextTempPath(const ADir, APrefix: string): string;
begin
  Inc(TempNameCounter);
  Result := ConcatPaths([ADir, APrefix + IntToStr(GetProcessID) + '-'
    + IntToStr(GetTickCount64) + '-' + IntToStr(TempNameCounter) + '.tmp']);
end;

procedure RemoveTemp(const APath: string);
begin
  if FileExists(APath) and not SysUtils.DeleteFile(APath) then
    WriteLn(ErrOutput, 'stamp-version: could not remove temporary file ',
      APath);
end;

{ Creates a fresh file in ADir exclusively and writes AText to it. Returns
  its path; on failure it removes what it created and raises. }
function WriteTempFile(const ADir, APrefix, AText: string): string;
var
  Attempt, Written, Put: Integer;
  {$IFDEF UNIX}
  Fd: cint;
  Err: cint;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Handle: THandle;
  Err: DWORD;
  {$ENDIF}
  Ok: Boolean;
begin
  for Attempt := 1 to MAX_TEMP_NAME_ATTEMPTS do
  begin
    Result := NextTempPath(ADir, APrefix);
    {$IFDEF UNIX}
    Fd := FpOpen(PChar(Result), O_WRONLY or O_CREAT or O_EXCL,
      TEMP_FILE_PERMISSIONS);
    if Fd < 0 then
    begin
      Err := FpGetErrNo;
      if Err = ESysEEXIST then Continue;
      raise Exception.CreateFmt('cannot create %s (errno %d)', [Result, Err]);
    end;
    Ok := False;
    try
      Written := 0;
      while Written < Length(AText) do
      begin
        Put := FpWrite(Fd, AText[Written + 1], Length(AText) - Written);
        if Put <= 0 then
          raise Exception.CreateFmt('cannot write %s (errno %d)',
            [Result, FpGetErrNo]);
        Inc(Written, Put);
      end;
      Ok := True;
    finally
      if FpClose(Fd) <> 0 then Ok := False;
      if not Ok then RemoveTemp(Result);
    end;
    if not Ok then
      raise Exception.CreateFmt('cannot close %s', [Result]);
    Exit;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Handle := Windows.CreateFileW(PWideChar(UnicodeString(Result)),
      Windows.GENERIC_WRITE, 0, nil, Windows.CREATE_NEW,
      Windows.FILE_ATTRIBUTE_NORMAL, 0);
    if Handle = Windows.INVALID_HANDLE_VALUE then
    begin
      Err := Windows.GetLastError;
      if (Err = Windows.ERROR_FILE_EXISTS)
        or (Err = Windows.ERROR_ALREADY_EXISTS) then Continue;
      raise Exception.CreateFmt('cannot create %s (error %d)', [Result, Err]);
    end;
    Ok := False;
    try
      Written := 0;
      while Written < Length(AText) do
      begin
        if not Windows.WriteFile(Handle, AText[Written + 1],
          DWORD(Length(AText) - Written), DWORD(Put), nil) or (Put <= 0) then
          raise Exception.CreateFmt('cannot write %s (error %d)',
            [Result, Windows.GetLastError]);
        Inc(Written, Put);
      end;
      Ok := True;
    finally
      if not Windows.CloseHandle(Handle) then Ok := False;
      if not Ok then RemoveTemp(Result);
    end;
    if not Ok then
      raise Exception.CreateFmt('cannot close %s', [Result]);
    Exit;
    {$ENDIF}
  end;
  raise Exception.CreateFmt('no free temporary name in %s', [ADir]);
end;

{ Moves ATemp over ADest in one operation. False when it did not move. }
function ReplaceDestination(const ATemp, ADest, AText: string;
  out AError: string; out AFailure: TReplaceFailure): Boolean;
{$IFDEF UNIX}
var
  Err: cint;
begin
  AFailure := rfOther;
  Result := FpRename(PChar(ATemp), PChar(ADest)) = 0;
  if Result then Exit;
  Err := FpGetErrNo;
  AError := Format('cannot rename %s to %s (errno %d)', [ATemp, ADest, Err]);
  if Err = ESysEXDEV then
  begin
    AFailure := rfCrossDevice;
    AError := Format('cannot rename %s to %s: they are on different file '
      + 'systems', [ATemp, ADest]);
  end
  else if (Err = ESysENOENT) and not FileExists(ATemp) then
    AFailure := rfTempVanished;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Attempt: Integer;
  Delay: DWORD;
  Err: DWORD;
begin
  AFailure := rfOther;
  Delay := REPLACE_RETRY_FIRST_DELAY_MS;
  for Attempt := 1 to MAX_REPLACE_ATTEMPTS do
  begin
    if Windows.MoveFileExW(PWideChar(UnicodeString(ATemp)),
      PWideChar(UnicodeString(ADest)),
      MOVEFILE_REPLACE_EXISTING_STAMP or MOVEFILE_WRITE_THROUGH_STAMP) then
      Exit(True);
    Err := Windows.GetLastError;
    AError := Format('cannot move %s to %s (error %d)', [ATemp, ADest, Err]);
    if Err = Windows.ERROR_NOT_SAME_DEVICE then
    begin
      AFailure := rfCrossDevice;
      AError := Format('cannot move %s to %s: they are on different '
        + 'volumes', [ATemp, ADest]);
      Exit(False);
    end;
    if ((Err = Windows.ERROR_FILE_NOT_FOUND)
      or (Err = Windows.ERROR_PATH_NOT_FOUND)) and not FileExists(ATemp) then
    begin
      AFailure := rfTempVanished;
      Exit(False);
    end;
    { Only a destination someone holds open is worth waiting for. }
    if (Err <> Windows.ERROR_ACCESS_DENIED)
      and (Err <> Windows.ERROR_SHARING_VIOLATION)
      and (Err <> Windows.ERROR_LOCK_VIOLATION) then Exit(False);
    { A sibling run already published the same text. }
    if HoldsText(ADest, AText) then Exit(False);
    if Attempt < MAX_REPLACE_ATTEMPTS then
    begin
      Windows.Sleep(Delay);
      Delay := Delay * 2;
      if Delay > REPLACE_RETRY_MAX_DELAY_MS then
        Delay := REPLACE_RETRY_MAX_DELAY_MS;
    end;
  end;
  Result := False;
end;
{$ENDIF}

{ Creates ADir and its parents. Unlike SysUtils.ForceDirectories it
  tolerates a concurrent run creating the same directory between the
  existence check and the mkdir. }
function EnsureDirectory(const ADir: string): Boolean;
var
  Dir, Parent: string;
begin
  Dir := ExcludeTrailingPathDelimiter(ADir);
  if Dir = '' then Exit(False);
  if DirectoryExists(Dir) then Exit(True);
  Parent := ExtractFileDir(Dir);
  if (Parent <> '') and (Parent <> Dir) and not EnsureDirectory(Parent) then
    Exit(False);
  Result := CreateDir(Dir) or DirectoryExists(Dir);
end;

{ The project's own staging directory, created when missing. }
function StagingDirectory: string;
begin
  Result := ConcatPaths([ExtractFileDir(ExpandFileName(MANIFEST_PATH)),
    STAGING_DIR]);
  if EnsureDirectory(Result) then Exit;
  raise Exception.CreateFmt('cannot create staging directory %s; %s is '
    + 'unchanged', [Result, OUTPUT_PATH]);
end;

{ Publishes AText at ADest. False when ADest already held it. }
function PublishText(const ADest, AText: string): Boolean;
var
  Temp, Error, Dir: string;
  Attempt: Integer;
  Published: Boolean;
  Failure: TReplaceFailure;
begin
  Error := 'cannot publish ' + ADest;
  for Attempt := 1 to MAX_PUBLISH_ATTEMPTS do
  begin
    if HoldsText(ADest, AText) then Exit(False);
    Dir := StagingDirectory;
    try
      Temp := WriteTempFile(Dir, TEMP_PREFIX + ExtractFileName(ADest) + '.',
        AText);
    except
      on E: Exception do
        raise Exception.CreateFmt('%s; %s is unchanged', [E.Message, ADest]);
    end;
    Published := False;
    try
      Published := ReplaceDestination(Temp, ADest, AText, Error, Failure);
    finally
      if not Published then RemoveTemp(Temp);
    end;
    if Published then Exit(True);
    { A concurrent writer won the replacement with the same text. }
    if HoldsText(ADest, AText) then Exit(False);
    { Only a temporary file wiped under the script (lwpt install empties
      .lwpt/tmp) is worth writing again. }
    if Failure <> rfTempVanished then Break;
  end;
  raise Exception.CreateFmt('%s; %s is unchanged', [Error, ADest]);
end;

var
  Lines  : TStringList;
  Version, Override_, SourceNote: string;
  Out    : TStringList;
  Wrote  : Boolean;
begin
  try
    Override_ := Trim(GetEnvironmentVariable('LWPT_VERSION_OVERRIDE'));
    if Override_ <> '' then
    begin
      Version := Override_;
      SourceNote := '$LWPT_VERSION_OVERRIDE (release tag)';
    end
    else
    begin
      if not FileExists(MANIFEST_PATH) then
      begin
        WriteLn(ErrOutput, 'stamp-version: ', MANIFEST_PATH,
          ' not found (run from repo root)');
        Halt(1);
      end;

      Lines := TStringList.Create;
      try
        Lines.LoadFromFile(MANIFEST_PATH);
        Version := ExtractVersion(Lines);
      finally
        Lines.Free;
      end;

      if Version = '' then
      begin
        WriteLn(ErrOutput, 'stamp-version: no `version` field in [package] of ',
          MANIFEST_PATH);
        Halt(1);
      end;
      SourceNote := '[package].version in ' + MANIFEST_PATH;
    end;

    Out := TStringList.Create;
    try
      Out.Add('{ Auto-generated by scripts/stamp-version.pas. Do not hand-edit. }');
      Out.Add('{ Source: ' + SourceNote + '. }');
      Out.Add('');
      Out.Add('  PROGRAM_VERSION = ' + QuotedStr(Version) + ';');
      { Text is exactly what SaveToFile wrote: each line + LineEnding. }
      Wrote := PublishText(OUTPUT_PATH, Out.Text);
    finally
      Out.Free;
    end;

    if Wrote then
      WriteLn('stamp-version: wrote ', OUTPUT_PATH, ' = ', Version,
        ' (from ', SourceNote, ')')
    else
      WriteLn('stamp-version: ', OUTPUT_PATH, ' already current = ', Version,
        ' (from ', SourceNote, ')');
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'stamp-version: ', E.Message);
      Halt(1);
    end;
  end;
end.
