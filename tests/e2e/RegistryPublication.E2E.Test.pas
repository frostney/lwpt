program RegistryPublication.E2E.Test;

{ Black-box publication against a running `registry serve`: tokens issued
  and revoked while the origin serves, uploads and records over localhost
  HTTP, a publication killed at its activation barrier, an upload killed
  mid-body, and credentials that never leave the one issue-token line. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  DateUtils,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryHTTP,
  Tests.RegistryOrigin,
  Tests.RegistryProcess,
  Tests.Scratch;

type
  TRequestThread = class(TThread)
  private
    FPort: Word;
    FTarget, FToken: string;
    FBody: TBytes;
  protected
    procedure Execute; override;
  public
    Response: TRawHTTPResponse;
    constructor Create(const APort: Word; const ATarget, AToken: string;
      const ABody: TBytes);
  end;

  TRegistryPublicationE2E = class(TTestSuite)
  private
    FScratch, FData, FBase: string;
    FPort: Word;
    FServe: TProcess;
    FOutputs: string;
    { A `registry serve` child in FScratch that, on Linux, cannot outlive
      this test program even when the program is killed. }
    function NewServeProcess(const ABinary: string;
      const AEnvironment: array of string): TProcess;
    { Removes a scratch root, retrying while exited children finish
      releasing their handles; a failure is reported, never raised. }
    procedure ReleaseScratch;
    procedure InitOrigin;
    procedure StartServe(const ABinary: string; const AEnvironment: array of string);
    procedure KillServe;
    procedure StopServe;
    function Run(const AArgs: array of string): TLwptResult;
    function IssueToken(const AExtra: array of string): string;
    function Upload(const AArchive: TBytes; const AToken: string): TRawHTTPResponse;
    function RecordText(const AName, AVersion: string; const AArchive: TBytes): string;
    function PublishRecord(const AName, AVersion: string; const AArchive: TBytes;
      const AToken: string): TRawHTTPResponse;
    function LatestSequence: Integer;
    function PartFiles: Integer;
    function IncompleteAudits: Integer;
    procedure ExpectCurl(const AExpected: string;
      const AArguments: array of string);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestPublishToARunningOrigin;
    procedure TestTokenOptionsAndExpiryBounds;
    procedure TestKilledPublicationKeepsTheOldHead;
    procedure TestKilledUploadIsReclaimedOnlyAfterItsLeaseIsFree;
    procedure TestTLSListenerReadsRequestBodies;
    procedure TestExpiredUploadsAreReclaimedWhileServingAndAtRestart;
  end;

constructor TRequestThread.Create(const APort: Word; const ATarget,
  AToken: string; const ABody: TBytes);
begin
  FPort := APort;
  FTarget := ATarget;
  FToken := AToken;
  FBody := ABody;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRequestThread.Execute;
begin
  try
    Response := RawHTTPRequest(FPort, 'PUT', FTarget,
      ['Authorization: Bearer ' + FToken], FBody, True, 20000);
  except
  end;
end;

function CurrentUTC: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

procedure TRegistryPublicationE2E.InitOrigin;
var
  Result: TLwptResult;
begin
  FPort := FindAvailableRegistryTestPort;
  FBase := 'http://localhost:' + IntToStr(FPort);
  FData := FScratch + '/origin';
  Result := Run(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
    '--port', IntToStr(FPort)]);
  Expect<Integer>(Result.ExitCode).ToBe(0);
end;

procedure TRegistryPublicationE2E.StartServe(const ABinary: string;
  const AEnvironment: array of string);
var
  Started: QWord;
  Ready: Boolean;
begin
  FServe := NewServeProcess(ABinary, AEnvironment);
  Started := GetTickCount64;
  Ready := False;
  repeat
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
    try
      Ready := RawHTTPRequest(FPort, 'GET', '/.well-known/' + RegistryProgramName
        + '-registry', [], nil, False, 2000).Status = 200;
    except
      Ready := False;
    end;
    if Ready or not FServe.Running then Break;
    Sleep(20);
  until GetTickCount64 - Started > 10000;
  if not Ready then
    raise Exception.Create('registry serve did not become ready: ' + FOutputs);
end;

function TRegistryPublicationE2E.NewServeProcess(const ABinary: string;
  const AEnvironment: array of string): TProcess;
begin
  Result := TProcess.Create(nil);
  try
    Result.Executable := ABinary;
    Result.CurrentDirectory := FScratch;
    Result.Options := [poUsePipes];
    Result.Parameters.Add('registry');
    Result.Parameters.Add('serve');
    Result.Parameters.Add('--data-dir');
    Result.Parameters.Add(FData);
    if Length(AEnvironment) > 0 then
      ConfigureProcessEnvironment(Result, AEnvironment);
    BindRegistryChildToParent(Result);
    Result.Execute;
  except
    Result.Free;
    raise;
  end;
end;

procedure TRegistryPublicationE2E.ReleaseScratch;
var
  Started: QWord;
  Failure: string;
begin
  if FScratch = '' then Exit;
  Started := GetTickCount64;
  repeat
    try
      RecursiveDelete(FScratch);
      FScratch := '';
      Exit;
    except
      on E: Exception do Failure := E.Message;
    end;
    Sleep(50);
  until GetTickCount64 - Started >= 10000;
  WriteLn(StdErr, 'registry publication e2e cleanup: ', Failure);
  FScratch := '';
end;

procedure TRegistryPublicationE2E.KillServe;
begin
  if FServe = nil then Exit;
  {$IFDEF UNIX}
  FpKill(FServe.ProcessID, SIGKILL);
  {$ELSE}
  TerminateProcess(FServe.Handle, 1);
  {$ENDIF}
  StopServe;
end;

procedure TRegistryPublicationE2E.StopServe;
var
  Stopped: TRegistryStopResult;
begin
  if FServe = nil then Exit;
  try
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
  except
  end;
  { Bounded: SIGTERM or TerminateProcess, a grace period, then a forced
    kill, and a wait for the signalled handle so the child no longer pins
    its working directory. }
  Stopped := StopRegistryProcess(FServe);
  if not Stopped.Stopped then
    WriteLn(StdErr, 'registry publication e2e cleanup: registry serve did not stop');
end;

function TRegistryPublicationE2E.Run(const AArgs: array of string): TLwptResult;
begin
  Result := RunLwpt(AArgs, FScratch);
  FOutputs := FOutputs + Result.Stdout + Result.Stderr;
end;

function TRegistryPublicationE2E.IssueToken(const AExtra: array of string): string;
var
  Arguments: array of string;
  Index: Integer;
  Result_: TLwptResult;
begin
  SetLength(Arguments, 4 + Length(AExtra));
  Arguments[0] := 'registry';
  Arguments[1] := 'issue-token';
  Arguments[2] := '--data-dir';
  Arguments[3] := FData;
  for Index := 0 to High(AExtra) do Arguments[4 + Index] := AExtra[Index];
  { The token line is the one intended output that may hold the secret. }
  Result_ := RunLwpt(Arguments, FScratch);
  FOutputs := FOutputs + Result_.Stderr;
  Expect<Integer>(Result_.ExitCode).ToBe(0);
  Result := Trim(Result_.Stdout);
  Expect<Boolean>(Pos(#10, Result) = 0).ToBe(True);
  Expect<Boolean>(Pos(RegistryProgramName + '_rt1_', Result) = 1).ToBe(True);
end;

function TRegistryPublicationE2E.Upload(const AArchive: TBytes;
  const AToken: string): TRawHTTPResponse;
begin
  Result := RawHTTPRequest(FPort, 'PUT', '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(AArchive), 8, 64),
    ['Authorization: Bearer ' + AToken], AArchive);
end;

function TRegistryPublicationE2E.RecordText(const AName, AVersion: string;
  const AArchive: TBytes): string;
begin
  Result := 'schema = "' + RegistryProgramName + '-registry-package-v1"' + #10
    + 'origin = "' + FBase + '"' + #10
    + 'name = "' + AName + '"' + #10
    + 'version = "' + AVersion + '"' + #10
    + 'archive = "' + RegistryArtifactHash(AArchive) + '"' + #10
    + 'archive_size = ' + IntToStr(Length(AArchive)) + #10
    + 'published_at = "' + CurrentUTC + '"' + #10
    + 'yanked = false' + #10
    + 'dependencies = []' + #10;
end;

function TRegistryPublicationE2E.PublishRecord(const AName, AVersion: string;
  const AArchive: TBytes; const AToken: string): TRawHTTPResponse;
begin
  Result := RawHTTPRequest(FPort, 'PUT', '/v1/packages/' + AName + '/' + AVersion,
    ['Authorization: Bearer ' + AToken],
    RawHTTPBytes(RecordText(AName, AVersion, AArchive)));
end;

function TRegistryPublicationE2E.LatestSequence: Integer;
var
  Body: string;
  Start: Integer;
begin
  Body := RawHTTPBodyText(RawHTTPRequest(FPort, 'GET',
    '/v1/checkpoints/latest.toml', [], nil, False));
  Start := Pos('sequence = ', Body);
  Result := StrToIntDef(Trim(Copy(Body, Start + 11,
    Pos(#10, Copy(Body, Start, MaxInt)) - 12)), -1);
end;

function TRegistryPublicationE2E.PartFiles: Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(FData + '/incoming/*.part', faAnyFile, Search) = 0 then
  try
    repeat
      Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TRegistryPublicationE2E.BeforeEach;
begin
  { A failed assertion skips AfterEach; stop a server the previous case
    left running before its scratch is removed. }
  StopServe;
  ReleaseScratch;
  FScratch := CreateScratchRoot('registry-publication-e2e');
  FOutputs := '';
  FServe := nil;
end;

procedure TRegistryPublicationE2E.AfterEach;
begin
  StopServe;
end;

procedure TRegistryPublicationE2E.AfterAll;
begin
  StopServe;
  ReleaseScratch;
end;

procedure CollectFiles(const ADirectory: string; AList: TStringList);
var
  Search: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*', faAnyFile,
    Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        CollectFiles(IncludeTrailingPathDelimiter(ADirectory) + Search.Name, AList)
      else AList.Add(IncludeTrailingPathDelimiter(ADirectory) + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure TRegistryPublicationE2E.TestPublishToARunningOrigin;
var
  Token, Secret, TokenID, Path, Verify: string;
  Archive: TBytes;
  Response: TRawHTTPResponse;
  PID: Integer;
  Files: TStringList;
  Revoke: TLwptResult;
begin
  InitOrigin;
  StartServe(LwptBinaryPath, []);
  PID := FServe.ProcessID;
  { A read-only origin refuses mutation until a token exists. }
  Archive := RawHTTPBytes('e2e archive bytes');
  Expect<Integer>(Upload(Archive, 'none').Status).ToBe(405);
  Token := IssueToken(['--packages', 'e2e-*', '--actions', 'publish,yank',
    '--label', 'ci']);
  Secret := Copy(Token, Length(RegistryProgramName + '_rt1_') + 32 + 2, MaxInt);
  TokenID := Copy(Token, Length(RegistryProgramName + '_rt1_') + 1, 32);
  Expect<Boolean>(Pos('"publication-v1"', RawHTTPBodyText(RawHTTPRequest(FPort,
    'GET', '/v1/capabilities', [], nil, False))) > 0).ToBe(True);
  Expect<Integer>(Upload(Archive, Token).Status).ToBe(201);
  Response := PublishRecord('e2e-lib', '1.0.0', Archive, Token);
  Expect<Integer>(Response.Status).ToBe(201);
  Expect<Integer>(PublishRecord('e2e-lib', '1.0.0', Archive, Token).Status)
    .ToBe(204);
  Expect<Integer>(PublishRecord('other-lib', '1.0.0', Archive, Token).Status)
    .ToBe(403);
  Expect<Integer>(LatestSequence).ToBe(2);
  Expect<Boolean>(Pos('name = "e2e-lib"', RawHTTPBodyText(RawHTTPRequest(FPort,
    'GET', '/v1/packages', [], nil, False))) > 0).ToBe(True);
  Expect<Integer>(RawHTTPRequest(FPort, 'GET', '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(Archive), 8, 64), [], nil, False).Status).ToBe(200);
  { Revocation takes effect on the next request without a restart. A second
    token keeps the origin publication-enabled, so the revoked credential
    gets the authentication challenge rather than 405. }
  IssueToken(['--packages', 'unrelated']);
  Revoke := Run(['registry', 'revoke-token', '--data-dir', FData, '--token-id',
    TokenID]);
  Expect<Integer>(Revoke.ExitCode).ToBe(0);
  Response := Upload(Archive, Token);
  Expect<Integer>(Response.Status).ToBe(401);
  Expect<string>(RawHTTPHeader(Response, 'WWW-Authenticate')).ToBe('Bearer');
  Expect<Boolean>(FServe.Running).ToBe(True);
  Expect<Integer>(FServe.ProcessID).ToBe(PID);
  Verify := Run(['registry', 'verify', '--data-dir', FData]).Stdout;
  Expect<Boolean>(Pos('id = "' + TokenID + '"', Verify) > 0).ToBe(True);
  Expect<Boolean>(Pos('label = "ci"', Verify) > 0).ToBe(True);
  Path := Copy(Verify, Pos('id = "' + TokenID + '"', Verify), MaxInt);
  Path := Copy(Path, 1, Pos(' }', Path));
  Expect<Boolean>(Pos('revoked_at = "2', Path) > 0).ToBe(True);
  Expect<Boolean>(Pos('secret', Verify) = 0).ToBe(True);
  StopServe;
  { The secret appears nowhere but the one issue-token line. }
  Expect<Boolean>(Pos(Secret, FOutputs) = 0).ToBe(True);
  Files := TStringList.Create;
  try
    CollectFiles(FScratch, Files);
    for Path in Files do
      Expect<Boolean>(Pos(Secret, ReadBinaryFile(Path)) = 0).ToBe(True);
  finally
    Files.Free;
  end;
  Expect<Boolean>(FileExists(FScratch + '/' + RegistryProgramName + '.lock'))
    .ToBe(False);
  Expect<Boolean>(DirectoryExists(FScratch + '/.' + RegistryProgramName))
    .ToBe(False);
end;

procedure TRegistryPublicationE2E.TestTokenOptionsAndExpiryBounds;
const
  INVALID: array[0..4] of string = ('0', '366', 'abc', '+5', '05');
var
  Result_: TLwptResult;
  Verify, Value: string;
  Created, Expires: TDateTime;
begin
  InitOrigin;
  IssueToken(['--packages', 'lib']);
  Verify := Run(['registry', 'verify', '--data-dir', FData]).Stdout;
  Value := Copy(Verify, Pos('created_at = "', Verify) + 14, 20);
  Created := ISO8601ToDate(Value, True);
  Value := Copy(Verify, Pos('expires_at = "', Verify) + 14, 20);
  Expires := ISO8601ToDate(Value, True);
  Expect<Int64>(DaysBetween(Created, Expires)).ToBe(90);
  Expect<Boolean>(Pos('actions = ["publish"]', Verify) > 0).ToBe(True);
  IssueToken(['--packages', 'lib', '--expires-days', '1']);
  IssueToken(['--packages', 'lib', '--expires-days', '365']);
  for Value in INVALID do
  begin
    Result_ := Run(['registry', 'issue-token', '--data-dir', FData, '--packages',
      'lib', '--expires-days', Value]);
    Expect<Integer>(Result_.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
    Expect<string>(Trim(Result_.Stdout)).ToBe('');
  end;
  Result_ := Run(['registry', 'issue-token', '--data-dir', FData]);
  Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
  Result_ := Run(['registry', 'issue-token', '--data-dir', FData, '--packages',
    'lib', '--port', '1']);
  Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
  Result_ := Run(['registry', 'issue-token', '--data-dir', FData, '--packages',
    'Bad Name']);
  Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
  Result_ := Run(['registry', 'revoke-token', '--data-dir', FData]);
  Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
  Result_ := Run(['registry', 'serve', '--data-dir', FData, '--packages', 'lib']);
  Expect<Integer>(Result_.ExitCode).ToBe(1);
  Expect<Boolean>(Pos('invalid_configuration', Result_.Stderr) > 0).ToBe(True);
end;

procedure TRegistryPublicationE2E.TestKilledPublicationKeepsTheOldHead;
var
  Token, Ready, Release: string;
  Archive: TBytes;
  Publisher: TRequestThread;
  Started: QWord;
begin
  InitOrigin;
  Token := IssueToken(['--packages', '*']);
  Ready := FScratch + '/barrier-ready';
  Release := FScratch + '/barrier-release';
  StartServe(LwptTestingBinaryPath, [UpperCase(RegistryProgramName)
    + '_TEST_REGISTRY_PUBLICATION_BARRIER=' + Ready + '|' + Release]);
  Archive := RawHTTPBytes('killed publication archive');
  Expect<Integer>(Upload(Archive, Token).Status).ToBe(201);
  Publisher := TRequestThread.Create(FPort, '/v1/packages/killed-lib/1.0.0',
    Token, RawHTTPBytes(RecordText('killed-lib', '1.0.0', Archive)));
  try
    Started := GetTickCount64;
    while not FileExists(Ready) and (GetTickCount64 - Started < 10000) do
      Sleep(10);
    Expect<Boolean>(FileExists(Ready)).ToBe(True);
    { Readers still see the old, complete head while the new checkpoint is
      durable but not yet activated. }
    Expect<Integer>(LatestSequence).ToBe(1);
    KillServe;
    Publisher.WaitFor;
  finally
    Publisher.Free;
  end;
  StartServe(LwptBinaryPath, []);
  Expect<Integer>(LatestSequence).ToBe(1);
  Expect<Integer>(PublishRecord('killed-lib', '1.0.0', Archive, Token).Status)
    .ToBe(201);
  Expect<Integer>(LatestSequence).ToBe(2);
end;

procedure TRegistryPublicationE2E.TestKilledUploadIsReclaimedOnlyAfterItsLeaseIsFree;
var
  Token: string;
  Live: TRawHTTPConnection;
  Archive, Other: TBytes;
  Started: QWord;
begin
  InitOrigin;
  Token := IssueToken(['--packages', '*']);
  StartServe(LwptBinaryPath, []);
  Archive := RawHTTPBytes(StringOfChar('p', 4096));
  Live := TRawHTTPConnection.Create(FPort);
  try
    Live.SendText('PUT /v1/objects/sha256/' + Copy(RegistryArtifactHash(Archive),
      8, 64) + ' HTTP/1.1' + #13#10 + 'Authorization: Bearer ' + Token + #13#10
      + 'Content-Length: 4096' + #13#10#13#10 + StringOfChar('p', 1000));
    Started := GetTickCount64;
    while (PartFiles = 0) and (GetTickCount64 - Started < 5000) do Sleep(10);
    Expect<Integer>(PartFiles).ToBe(1);
    { A live upload survives a concurrent admission and commit. }
    Other := RawHTTPBytes('concurrent archive');
    Expect<Integer>(Upload(Other, Token).Status).ToBe(201);
    Expect<Integer>(PublishRecord('concurrent-lib', '1.0.0', Other, Token).Status)
      .ToBe(201);
    Expect<Integer>(PartFiles).ToBe(1);
    KillServe;
  finally
    Live.Free;
  end;
  { The killed owner's reservation stays until a publication-lease holder
    finds its upload lease free: startup recovery reclaims it. }
  Expect<Integer>(PartFiles).ToBe(1);
  StartServe(LwptBinaryPath, []);
  Expect<Integer>(PartFiles).ToBe(0);
  Expect<Integer>(Upload(RawHTTPBytes('after restart'), Token).Status).ToBe(201);
end;

{ Status code of one curl request against the TLS listener; curl trusts the
  self-signed test identity only through --insecure. }
{ One curl request against the TLS listener; curl trusts the self-signed
  test identity only through --insecure. Returns the status code and keeps
  the response body and curl's diagnostics for failure reports. }
function CurlRequest(const AArguments: array of string; const ABodyPath: string;
  out AStandardError: string): string;
const
  CURL_BOUND_MILLISECONDS = 40000;
var
  ProcessInstance: TProcess;
  Argument: string;
  Started: QWord;
begin
  AStandardError := '';
  ProcessInstance := TProcess.Create(nil);
  try
    {$IFDEF MSWINDOWS}
    ProcessInstance.Executable := 'curl.exe';
    {$ELSE}
    ProcessInstance.Executable := 'curl';
    {$ENDIF}
    ProcessInstance.Parameters.Add('--silent');
    ProcessInstance.Parameters.Add('--show-error');
    ProcessInstance.Parameters.Add('--insecure');
    ProcessInstance.Parameters.Add('--max-time');
    ProcessInstance.Parameters.Add('20');
    ProcessInstance.Parameters.Add('--output');
    ProcessInstance.Parameters.Add(ABodyPath);
    ProcessInstance.Parameters.Add('--write-out');
    ProcessInstance.Parameters.Add('%{http_code}');
    for Argument in AArguments do ProcessInstance.Parameters.Add(Argument);
    ProcessInstance.Options := [poUsePipes];
    ProcessInstance.Execute;
    Result := '';
    Started := GetTickCount64;
    while ProcessInstance.Running do
    begin
      Result := Result + DrainAvailableStream(ProcessInstance.Output, 4096);
      AStandardError := AStandardError
        + DrainAvailableStream(ProcessInstance.Stderr, 4096);
      if GetTickCount64 - Started > CURL_BOUND_MILLISECONDS then
      begin
        { curl's own --max-time normally ends it far sooner. }
        AStandardError := AStandardError + ' [curl exceeded its bound]';
        ProcessInstance.Terminate(1);
        Break;
      end;
      Sleep(10);
    end;
    Result := Trim(Result + DrainAvailableStream(ProcessInstance.Output, 4096));
    AStandardError := AStandardError
      + DrainAvailableStream(ProcessInstance.Stderr, 4096);
    { Windows reports the exit status before it releases the child's
      handles; wait, bounded, for the signalled handle before the scratch
      file curl read can be removed. }
    if not WaitForRegistryHandleRelease(ProcessInstance, 5000) then
      WriteLn(StdErr, 'registry publication e2e: curl did not release its '
        + 'handles within 5000 ms');
  finally
    ProcessInstance.Free;
  end;
end;

function CurlStatus(const AArguments: array of string): string;
var
  StandardError: string;
begin
  {$IFDEF MSWINDOWS}
  Result := CurlRequest(AArguments, 'NUL', StandardError);
  {$ELSE}
  Result := CurlRequest(AArguments, '/dev/null', StandardError);
  {$ENDIF}
end;

procedure TRegistryPublicationE2E.ExpectCurl(const AExpected: string;
  const AArguments: array of string);
var
  BodyPath, Status, StandardError, Body: string;
begin
  BodyPath := FScratch + '/curl-response.bin';
  if FileExists(BodyPath) then DeleteFile(BodyPath);
  Status := CurlRequest(AArguments, BodyPath, StandardError);
  if Status <> AExpected then
  begin
    Body := '';
    if FileExists(BodyPath) then Body := ReadBinaryFile(BodyPath);
    WriteLn(StdErr, 'curl expected ', AExpected, ' but got ', Status,
      '; response body: ', Body, '; curl stderr: ', StandardError);
  end;
  Expect<string>(Status).ToBe(AExpected);
end;

procedure WriteBinaryText(const APath, AText: string);
var
  Stream: TFileStream;
begin
  { Protocol bytes: exactly these characters, LF line endings included, on
    every platform. }
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then Stream.WriteBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
end;

procedure TRegistryPublicationE2E.TestTLSListenerReadsRequestBodies;
const
  TLS_PASSWORD_ENV = 'LWPT_REGISTRY_PUBLICATION_E2E_PASSWORD';
  TLS_PASSWORD = 'test-only';
var
  Init: TLwptResult;
  Token, ArchivePath, RecordPath, Hex, Base: string;
  Archive: TBytes;
  Stream: TFileStream;
  Started: QWord;
  Ready: Boolean;
  Truncated: TRawHTTPConnection;
begin
  FPort := FindAvailableRegistryTestPort;
  Base := 'https://localhost:' + IntToStr(FPort);
  FBase := Base;
  FData := FScratch + '/tls-origin';
  Init := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', Base,
    '--port', IntToStr(FPort), '--tls-pkcs12',
    ExpandFileName('tests/fixtures/registry/localhost-native-identity.p12'),
    '--tls-password-env', TLS_PASSWORD_ENV], FScratch,
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Expect<Integer>(Init.ExitCode).ToBe(0);
  Token := IssueToken(['--packages', 'tls-*']);
  FServe := NewServeProcess(LwptBinaryPath,
    [TLS_PASSWORD_ENV + '=' + TLS_PASSWORD]);
  Started := GetTickCount64;
  repeat
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
    Ready := CurlStatus([Base + '/.well-known/' + RegistryProgramName
      + '-registry']) = '200';
    if Ready or not FServe.Running then Break;
    Sleep(50);
  until GetTickCount64 - Started > 15000;
  Expect<Boolean>(Ready).ToBe(True);
  { A body spanning many TLS records, large enough that curl asks for
    100-continue. }
  SetLength(Archive, 2 * 1024 * 1024 + 11);
  FillChar(Archive[0], Length(Archive), $6b);
  ArchivePath := FScratch + '/tls-archive.bin';
  Stream := TFileStream.Create(ArchivePath, fmCreate);
  try
    Stream.WriteBuffer(Archive[0], Length(Archive));
  finally
    Stream.Free;
  end;
  Hex := Copy(RegistryArtifactHash(Archive), 8, 64);
  ExpectCurl('201', ['-X', 'PUT', '--data-binary', '@' + ArchivePath,
    '-H', 'Authorization: Bearer ' + Token, Base + '/v1/objects/sha256/' + Hex]);
  ExpectCurl('204', ['-X', 'PUT', '--data-binary', '@' + ArchivePath,
    '-H', 'Authorization: Bearer ' + Token, Base + '/v1/objects/sha256/' + Hex]);
  { A text-mode write would turn LF into CRLF on Windows and make the record
    non-canonical. }
  RecordPath := FScratch + '/tls-record.toml';
  WriteBinaryText(RecordPath, RecordText('tls-lib', '1.0.0', Archive));
  ExpectCurl('201', ['-X', 'PUT', '--data-binary', '@' + RecordPath,
    '-H', 'Authorization: Bearer ' + Token, Base + '/v1/packages/tls-lib/1.0.0']);
  ExpectCurl('204', ['-X', 'PUT', '--data-binary', '@' + RecordPath,
    '-H', 'Authorization: Bearer ' + Token, Base + '/v1/packages/tls-lib/1.0.0']);
  ExpectCurl('200', [Base + '/v1/objects/sha256/' + Hex]);
  { A mutating head cut off by the peer over TLS is audited exactly once. }
  Truncated := TRawHTTPConnection.Create(FPort);
  try
    Truncated.StartTLS('localhost');
    Truncated.SendText('PUT /v1/objects/sha256/' + Hex + ' HTTP/1.1' + #13#10
      + 'Authorization: Bearer ' + Token + #13#10);
  finally
    Truncated.Free;
  end;
  Started := GetTickCount64;
  while (IncompleteAudits = 0) and (GetTickCount64 - Started < 8000) do Sleep(20);
  Sleep(200);
  Expect<Integer>(IncompleteAudits).ToBe(1);
end;

function TRegistryPublicationE2E.IncompleteAudits: Integer;
var
  Files: TStringList;
  Path, Text: string;
begin
  Result := 0;
  Files := TStringList.Create;
  try
    CollectFiles(FData + '/audit', Files);
    for Path in Files do
    begin
      if Pos('.staging', Path) > 0 then Continue;
      Text := ReadBinaryFile(Path);
      if (Pos('status = 400' + #10, Text) > 0)
        and (Pos('method = "PUT"', Text) > 0)
        and (Pos('route = "invalid"', Text) > 0) then Inc(Result);
    end;
  finally
    Files.Free;
  end;
end;

procedure TRegistryPublicationE2E.TestExpiredUploadsAreReclaimedWhileServingAndAtRestart;
const
  BUDGET = Int64(1024) * 1024 * 1024;
var
  Token, Filler: string;
begin
  InitOrigin;
  Token := IssueToken(['--packages', '*']);
  StartServe(LwptBinaryPath, []);
  Filler := FData + '/incoming/sha256/' + StringOfChar('c', 64);
  CreateSparseFile(Filler, BUDGET - 10);
  Expect<Integer>(Upload(RawHTTPBytes('over the budget'), Token).Status).ToBe(507);
  { An abandoned completed upload older than one hour stops counting at the
    next admission, with no publication in between. }
  FileSetDate(Filler, DateTimeToFileDate(Now - 2 / 24));
  Expect<Integer>(Upload(RawHTTPBytes('over the budget'), Token).Status).ToBe(201);
  Expect<Boolean>(FileExists(Filler)).ToBe(False);
  StopServe;
  CreateSparseFile(Filler, BUDGET - 10);
  FileSetDate(Filler, DateTimeToFileDate(Now - 2 / 24));
  StartServe(LwptBinaryPath, []);
  Expect<Boolean>(FileExists(Filler)).ToBe(False);
end;

procedure TRegistryPublicationE2E.SetupTests;
begin
  Test('a CI token publishes to a running origin, then revocation applies',
    TestPublishToARunningOrigin);
  Test('token options and expiry bounds are validated by the CLI',
    TestTokenOptionsAndExpiryBounds);
  Test('a publication killed before activation keeps the old head',
    TestKilledPublicationKeepsTheOldHead);
  Test('a killed upload is reclaimed only after its lease is free',
    TestKilledUploadIsReclaimedOnlyAfterItsLeaseIsFree);
  Test('the TLS listener reads request bodies', TestTLSListenerReadsRequestBodies);
  Test('expired uploads are reclaimed while serving and at restart',
    TestExpiredUploadsAreReclaimedWhileServingAndAtRestart);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryPublicationE2E.Create(
    'registry publication e2e'));
  TestRunnerProgram.Run;
end.
