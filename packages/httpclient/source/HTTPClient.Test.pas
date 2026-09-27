{ HTTPClient.Test — the binary-fetch regression.

  HTTPClient.pas's byte-safe AppendRawBytes accumulator (used at four
  sites — three on the header-recv path, one on the chunked-body seed)
  exists to fix a real byte-truncation bug. The naive alternative
  `Copy(PAnsiChar(...))` treats the recv buffer as a C string and
  truncates at the first #0 byte; that corrupts every binary download
  whose body bytes contain #0 — i.e. essentially every tarball, zip,
  or compressed artefact lwpt install touches.

  Three sites needed fixing:
    1. Header-accumulation path (the worst — recv may return both
       headers AND body-prefix bytes in one read, and truncating the
       buffer at #0 in the body prefix poisons the body assembly).
    2. Chunked-read path, content length unknown.
    3. Chunked-read path, content length known.

  This test exercises all three deterministically via a mock HTTP
  server (tests/support/Tests.HTTPMockServer.pas) that serves caller-
  crafted raw bytes — the only way to embed #0 in known positions and
  prove the fix sticks.

  See ADR-0017 for why the LWPT-canonical HTTPClient is the source
  of truth (and ADR-0003, superseded, for the prior framing). Phase 2
  graduates this package into a standalone repo when warranted; until
  then this test is the regression net pinning the byte-safety
  contract that every consumer depends on. }

program HTTPClient.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,   { must come first so TThread has a driver before
                Tests.HTTPMockServer's background server starts }
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,
  TestingPascalLibrary,
  HTTPClient,
  Tests.HTTPMockServer;

type
  THTTPMockServerLifecycle = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestConnectedSilentTeardownIsBounded;
    procedure TestRepeatedCyclesBalanceResources;
    procedure TestStartedUnconnectedTeardownIsBounded;
    {$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
    procedure TestConnectWaitFailureClosesClientSocket;
    procedure TestSelectRetriesAfterInterruption;
    {$ENDIF}
  end;

  THTTPClientByteFetch = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSimpleResponseBodyStartsWithNul;
    procedure TestSimpleResponseBodyInterspersedNul;
    procedure TestChunkedResponseChunkStartsWithNul;
    procedure TestChunkedResponseMultipleChunksWithNul;
    procedure TestLargeBodyForcesMultiRecv;
    procedure TestSegmentedWritesPreserveNul;
  end;

  THTTPClientResourceBounds = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestChunkedBodyAtLimit;
    procedure TestChunkedBodyOverLimit;
    procedure TestChunkSizeFailures;
    procedure TestChunkSizeNearIntegerMaxIsBounded;
    procedure TestCloseDelimitedBodyOverLimit;
    procedure TestBodyLimitRaisesResponseTooLarge;
    procedure TestConflictingContentLengths;
    procedure TestDuplicateContentLengths;
    procedure TestFixedBodyAtLimit;
    procedure TestFixedBodyOverLimit;
    procedure TestHeaderAtLimit;
    procedure TestHeaderOverLimit;
    procedure TestInvalidContentLengths;
    procedure TestRequestDeadlineRejectsIdlePeer;
    procedure TestRequestDeadlineRejectsSlowDrip;
    procedure TestRedirectBudgetDefaultsAndRejectsNegativeValues;
    procedure TestZeroRedirectBudgetReturnsTheRedirectResponse;
    procedure TestTLSHandshakeDeadlineRejectsIdlePeer;
    procedure TestTruncatedFixedBody;
  end;

  THTTPClientRequestBodies = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestGetAndHeadWireBehaviorIsUnchanged;
    procedure TestPostRedirect301And302BecomesGet;
    procedure TestPostRedirect303BecomesGet;
    procedure TestPostRedirect307And308PreservesBody;
    procedure TestPostRejectsContentTypeLineBreaksBeforeConnect;
    procedure TestPostSendsBinaryBodyAndOwnsEntityHeaders;
  end;

  THTTPClientDestinationPolicy = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDefaultOptionsAllowEveryDestination;
    procedure TestHTTPURLHostMatchesRequestParsing;
    procedure TestRequireHTTPSRefusesPlaintextBeforeConnect;
    procedure TestDisallowedInitialHostIsRefusedBeforeConnect;
    procedure TestRedirectToDisallowedHostIsRefused;
    procedure TestRedirectWithinAllowedHostsSucceeds;
    procedure TestDenyRefusesResolvedLoopbackBeforeConnect;
    procedure TestDenyRefusesNonGlobalLiteralsBeforeConnect;
    {$IFDEF HTTPCLIENT_TESTING}
    procedure TestIPv4RegistryBlockBoundaries;
    procedure TestIPv4GlobalExceptionsAndNeighbours;
    procedure TestIPv6RegistryBlockBoundaries;
    procedure TestIPv4EmbeddingSpellingsAreCanonical;
    procedure TestNonLiteralTextIsNotGlobal;
    procedure TestHostAllowlistMatching;
    procedure TestPublicDestinationDialsTheCheckedAddress;
    procedure TestDenyRefusesRedirectIntoPrivateAddress;
    procedure TestExpandedMappedIPv6RedirectCannotReachLoopback;
    {$ENDIF}
  end;

const
  MOCK_LIFECYCLE_CHILD = '--mock-lifecycle-child';
  {$IFDEF MSWINDOWS}
  { This outer watchdog includes cold child-process startup. Native Windows
    runners can spend more than two seconds loading the test executable before
    the fixture exists, so keep the deadlock bound without timing startup as
    mock-server teardown. }
  MOCK_LIFECYCLE_TIMEOUT_MILLISECONDS = 5000;
  {$ELSE}
  MOCK_LIFECYCLE_TIMEOUT_MILLISECONDS = 2000;
  {$ENDIF}
  MOCK_LIFECYCLE_CLEANUP_TIMEOUT_MILLISECONDS = 1000;

{$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
var
  CapturedClientSocket: PtrInt;
  SelectTestCallCount: Integer;

function FailConnectWaitSelect(const ASocket: PtrInt;
  const ARead, AWrite: Boolean;
  const AAttempt: Integer): THTTPClientSelectTestAction;
begin
  Inc(SelectTestCallCount);
  if AWrite then
  begin
    CapturedClientSocket := ASocket;
    Exit(selectFailed);
  end;
  Result := selectUseSystem;
end;

function InterruptFirstSelect(const ASocket: PtrInt;
  const ARead, AWrite: Boolean;
  const AAttempt: Integer): THTTPClientSelectTestAction;
begin
  Inc(SelectTestCallCount);
  if SelectTestCallCount = 1 then
    Exit(selectInterrupted);
  Result := selectUseSystem;
end;
{$ENDIF}

{ ── helpers ───────────────────────────────────────────────────────── }

function MockURL(APort: Word): string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(APort) + '/x';
end;

function ConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function StringBytes(const S: string): TBytes;
begin
  Result := BytesOf(S);
end;

function TestOptions(const AMaxBodyBytes, AMaxHeaderBytes,
  ATimeoutMilliseconds: Integer): THTTPRequestOptions;
begin
  Result := DefaultHTTPRequestOptions;
  Result.MaxResponseBodyBytes := AMaxBodyBytes;
  Result.MaxResponseHeaderBytes := AMaxHeaderBytes;
  Result.RequestTimeoutMilliseconds := ATimeoutMilliseconds;
end;

function ServeAndFetch(const ARawResponse: TBytes): TBytes; overload;
var
  Mock: TMockHTTPServer;
  Resp: THTTPResponse;
  NoHeaders: THTTPHeaders;
begin
  Mock := TMockHTTPServer.Create(ARawResponse);
  try
    Mock.Start;
    NoHeaders := nil;
    Resp := HTTPGet(MockURL(Mock.Port), NoHeaders);
    Mock.WaitDone;
    Result := Resp.Body;
  finally
    Mock.Free;
  end;
end;

function ServeAndFetch(const ARawResponse: TBytes;
  const AOptions: THTTPRequestOptions): TBytes; overload;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
  Resp: THTTPResponse;
begin
  Mock := TMockHTTPServer.Create(ARawResponse);
  try
    Mock.Start;
    NoHeaders := nil;
    Resp := HTTPGet(MockURL(Mock.Port), NoHeaders, AOptions);
    Mock.WaitDone;
    Result := Resp.Body;
  finally
    Mock.Free;
  end;
end;

function ServeAndFetch(const ARawResponse: TBytes;
  const ABytesPerWrite: Integer): TBytes; overload;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
  Resp: THTTPResponse;
begin
  Mock := TMockHTTPServer.Create(ARawResponse, ABytesPerWrite, 0, 0);
  try
    Mock.Start;
    NoHeaders := nil;
    Resp := HTTPGet(MockURL(Mock.Port), NoHeaders);
    Mock.WaitDone;
    Result := Resp.Body;
  finally
    Mock.Free;
  end;
end;

function ServeAndCaptureError(const ARawResponse: TBytes;
  const AOptions: THTTPRequestOptions;
  const ABytesPerWrite, AWriteDelayMilliseconds,
  AInitialDelayMilliseconds: Integer;
  const AScheme: string = 'http'): string;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
begin
  Result := '';
  Mock := TMockHTTPServer.Create(ARawResponse, ABytesPerWrite,
    AWriteDelayMilliseconds, AInitialDelayMilliseconds);
  try
    Mock.Start;
    NoHeaders := nil;
    try
      HTTPGet(AScheme + '://127.0.0.1:' + IntToStr(Mock.Port) + '/x',
        NoHeaders, AOptions);
    except
      on E: EHTTPError do
        Result := E.Message;
    end;
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
end;

function FixedResponse(const AContentLength: string;
  const ABody: TBytes): TBytes;
const
  CRLF = #13#10;
var
  Header: string;
begin
  Header := 'HTTP/1.1 200 OK' + CRLF +
    'Content-Length: ' + AContentLength + CRLF +
    'Connection: close' + CRLF + CRLF;
  Result := ConcatBytes(StringBytes(Header), ABody);
end;

function BytesToHex(const ABytes: TBytes): string;
const Hex = '0123456789abcdef';
var i: Integer;
begin
  SetLength(Result, Length(ABytes) * 2);
  for i := 0 to High(ABytes) do
  begin
    Result[i * 2 + 1] := Hex[(ABytes[i] shr 4) + 1];
    Result[i * 2 + 2] := Hex[(ABytes[i] and $F) + 1];
  end;
end;

function MakeBytes(const AValues: array of Byte): TBytes;
var i: Integer;
begin
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do Result[i] := AValues[i];
end;

function RequestHeaderEnd(const ARequest: TBytes): Integer;
var
  I: Integer;
begin
  for I := 0 to Length(ARequest) - 4 do
    if (ARequest[I] = 13) and (ARequest[I + 1] = 10) and
       (ARequest[I + 2] = 13) and (ARequest[I + 3] = 10) then
      Exit(I + 4);
  Result := -1;
end;

function RequestHeaderText(const ARequest: TBytes): string;
var
  HeaderEnd: Integer;
  Header: AnsiString;
begin
  HeaderEnd := RequestHeaderEnd(ARequest);
  if HeaderEnd < 0 then Exit('');
  SetString(Header, PAnsiChar(@ARequest[0]), HeaderEnd);
  Result := string(Header);
end;

function RequestBody(const ARequest: TBytes): TBytes;
var
  HeaderEnd: Integer;
begin
  HeaderEnd := RequestHeaderEnd(ARequest);
  if HeaderEnd < 0 then Exit(nil);
  Result := Copy(ARequest, HeaderEnd, Length(ARequest) - HeaderEnd);
end;

function RedirectResponse(const AStatusCode: Integer;
  const ALocation: string): TBytes;
const
  CRLF = #13#10;
begin
  Result := StringBytes('HTTP/1.1 ' + IntToStr(AStatusCode) +
    ' Redirect' + CRLF + 'Location: ' + ALocation + CRLF +
    'Content-Length: 0' + CRLF + 'Connection: close' + CRLF + CRLF);
end;

function ServePostRedirectAndCapture(const AStatusCode: Integer;
  const ABody: TBytes; const AContentType: string): TBytes;
var
  NoHeaders: THTTPHeaders;
  Options: THTTPRequestOptions;
  Origin, Target: TMockHTTPServer;
  Response: THTTPResponse;
  TargetURL: string;
begin
  Target := TMockHTTPServer.Create(BuildSimpleResponse(nil));
  try
    Target.Start;
    TargetURL := 'http://127.0.0.1:' + IntToStr(Target.Port) + '/target';
    Origin := TMockHTTPServer.Create(RedirectResponse(AStatusCode, TargetURL));
    try
      Origin.Start;
      NoHeaders := nil;
      Options := DefaultHTTPRequestOptions;
      Options.RequestTimeoutMilliseconds := 2000;
      Response := HTTPPost(MockURL(Origin.Port), ABody, AContentType,
        NoHeaders, Options);
      Origin.WaitDone;
      Target.WaitDone;
      Expect<Integer>(Response.StatusCode).ToBe(200);
      Expect<Boolean>(Response.Redirected).ToBe(True);
      Expect<string>(Response.FinalURL).ToBe(TargetURL);
      Result := Target.ReceivedRequest;
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure RunMockLifecycleChild(const AScenario: string);
var
  Mock: TMockHTTPServer;
begin
  Mock := TMockHTTPServer.Create(nil);
  try
    Mock.Start;
    if AScenario = 'connected-silent' then
    begin
      Mock.ConnectWithoutRequest;
      Mock.WaitForAccepted;
    end
    else if AScenario <> 'started-unconnected' then
      Halt(2);
  finally
    Mock.Free;
  end;
end;

procedure ForceKillMockLifecycleChild(const AChild: TProcess);
begin
  {$IFDEF UNIX}
  if (FpKill(AChild.ProcessID, SIGKILL) <> 0) and
    (FpGetErrNo <> ESysESRCH) then
    RaiseLastOSError;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if not Windows.TerminateProcess(AChild.ProcessHandle, 1) and
    (Windows.WaitForSingleObject(AChild.ProcessHandle, 0) <>
      Windows.WAIT_OBJECT_0) then
    RaiseLastOSError;
  {$ENDIF}
end;

procedure StopMockLifecycleChild(const AChild: TProcess);
begin
  if AChild.ProcessID <= 0 then Exit;
  if not AChild.Running then
  begin
    AChild.WaitOnExit;
    Exit;
  end;
  AChild.Terminate(1);
  if AChild.WaitOnExit(MOCK_LIFECYCLE_CLEANUP_TIMEOUT_MILLISECONDS)
     or not AChild.Running then
  begin
    AChild.WaitOnExit;
    Exit;
  end;
  ForceKillMockLifecycleChild(AChild);
  if not AChild.WaitOnExit(MOCK_LIFECYCLE_CLEANUP_TIMEOUT_MILLISECONDS)
     and AChild.Running then
    raise Exception.Create('mock lifecycle child did not stop after force kill');
  AChild.WaitOnExit;
end;

procedure RunBoundedMockLifecycleChild(const AScenario: string);
var
  Child: TProcess;
  StartedAt: QWord;
  TimedOut: Boolean;
begin
  Child := TProcess.Create(nil);
  try
    Child.Executable := ExpandFileName(ParamStr(0));
    Child.Parameters.Add(MOCK_LIFECYCLE_CHILD);
    Child.Parameters.Add(AScenario);
    Child.Execute;
    StartedAt := GetTickCount64;
    while Child.Running and
      (GetTickCount64 - StartedAt <
        MOCK_LIFECYCLE_TIMEOUT_MILLISECONDS) do
      Sleep(10);
    TimedOut := Child.Running;
    if TimedOut then StopMockLifecycleChild(Child)
    else
      Child.WaitOnExit;
    Expect<Boolean>(TimedOut).ToBe(False);
    if not TimedOut then Expect<Integer>(Child.ExitStatus).ToBe(0);
  finally
    StopMockLifecycleChild(Child);
    Child.Free;
  end;
end;

{ ── THTTPMockServerLifecycle ──────────────────────────────────────── }

procedure THTTPMockServerLifecycle.TestStartedUnconnectedTeardownIsBounded;
begin
  RunBoundedMockLifecycleChild('started-unconnected');
end;

procedure THTTPMockServerLifecycle.TestConnectedSilentTeardownIsBounded;
begin
  RunBoundedMockLifecycleChild('connected-silent');
end;

procedure RunMockResourceBalanceCycle(const AExpectedBody: TBytes);
var
  GotBody: TBytes;
  ErrorMessage: string;
  Mock: TMockHTTPServer;
begin
  GotBody := ServeAndFetch(BuildSimpleResponse(AExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(AExpectedBody));
  ErrorMessage := ServeAndCaptureError(
    StringBytes('not an HTTP response'), TestOptions(16, 1024, 1000),
    0, 0, 0);
  Expect<Boolean>(ErrorMessage <> '').ToBe(True);
  Mock := TMockHTTPServer.Create(nil);
  try
    Mock.Start;
    Mock.ConnectWithoutRequest;
    Mock.WaitForAccepted;
  finally
    Mock.Free;
  end;
  Mock := TMockHTTPServer.Create(nil);
  Mock.Free;
end;

procedure THTTPMockServerLifecycle.TestRepeatedCyclesBalanceResources;
const
  ITERATIONS = 16;
var
  BeforeResources, AfterResources: TMockServerResourceSnapshot;
  ExpectedBody: TBytes;
  i: Integer;
begin
  ExpectedBody := MakeBytes([$00, $7f, $ff]);
  { Initialize platform networking and thread runtime state before measuring
    fixture-owned lifecycle deltas. Windows retains some one-time process
    handles on first use which are not mock-server leaks. }
  RunMockResourceBalanceCycle(ExpectedBody);
  BeforeResources := GetMockServerResourceSnapshot;
  for i := 1 to ITERATIONS do
    RunMockResourceBalanceCycle(ExpectedBody);
  AfterResources := GetMockServerResourceSnapshot;
  Expect<Integer>(AfterResources.OpenSockets).ToBe(
    BeforeResources.OpenSockets);
  Expect<Integer>(AfterResources.LiveThreads).ToBe(
    BeforeResources.LiveThreads);
  Expect<Integer>(AfterResources.WinSockReferences).ToBe(
    BeforeResources.WinSockReferences);
  Expect<Integer>(AfterResources.ProcessHandles).ToBe(
    BeforeResources.ProcessHandles);
end;

{$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
procedure THTTPMockServerLifecycle.TestConnectWaitFailureClosesClientSocket;
var
  Endpoint: TMockRefusedEndpoint;
  ErrorMessage: string;
  NoHeaders: THTTPHeaders;
begin
  CapturedClientSocket := -1;
  SelectTestCallCount := 0;
  ErrorMessage := '';
  NoHeaders := nil;
  Endpoint := TMockRefusedEndpoint.Create;
  try
    HTTPClientSelectTestHook := @FailConnectWaitSelect;
    try
      try
        HTTPGet('http://' + Endpoint.Host + ':' + IntToStr(Endpoint.Port) +
          '/x', NoHeaders, TestOptions(4, 1024, 1000));
      except
        on E: EHTTPError do
          ErrorMessage := E.Message;
      end;
    finally
      HTTPClientSelectTestHook := nil;
    end;
  finally
    Endpoint.Free;
  end;
  Expect<string>(ErrorMessage).ToBe('HTTP socket readiness wait failed');
  Expect<Boolean>(SelectTestCallCount > 0).ToBe(True);
  Expect<Boolean>(CapturedClientSocket >= 0).ToBe(True);
  Expect<Integer>(fpFcntl(CapturedClientSocket, F_GETFD, 0)).ToBe(-1);
end;

procedure THTTPMockServerLifecycle.TestSelectRetriesAfterInterruption;
var
  ExpectedBody, GotBody: TBytes;
begin
  SelectTestCallCount := 0;
  ExpectedBody := MakeBytes([$00, $7f, $ff]);
  HTTPClientSelectTestHook := @InterruptFirstSelect;
  try
    GotBody := ServeAndFetch(BuildSimpleResponse(ExpectedBody));
  finally
    HTTPClientSelectTestHook := nil;
  end;
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
  Expect<Boolean>(SelectTestCallCount > 1).ToBe(True);
end;
{$ENDIF}

procedure THTTPMockServerLifecycle.SetupTests;
begin
  Test('started server without a client tears down inside the watchdog',
    TestStartedUnconnectedTeardownIsBounded);
  Test('connected silent client tears down inside the watchdog',
    TestConnectedSilentTeardownIsBounded);
  Test('success, failure, and unstarted cycles balance fixture resources',
    TestRepeatedCyclesBalanceResources);
  {$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
  Test('connect-wait failure closes its client socket',
    TestConnectWaitFailureClosesClientSocket);
  Test('select retries after an interrupted system call',
    TestSelectRetriesAfterInterruption);
  {$ENDIF}
end;

{ ── THTTPClientRequestBodies ─────────────────────────────────────── }

procedure THTTPClientRequestBodies.TestPostSendsBinaryBodyAndOwnsEntityHeaders;
const
  CRLF = #13#10;
var
  Body, CapturedBody: TBytes;
  CapturedHeader, ExpectedHeader: string;
  Headers: THTTPHeaders;
  I: Integer;
  Mock: TMockHTTPServer;
  Response: THTTPResponse;
begin
  SetLength(Body, 8 * 1024 + 17);
  for I := 0 to High(Body) do
    if I mod 19 = 0 then Body[I] := 0
    else Body[I] := Byte(I and $ff);
  SetLength(Headers, 5);
  Headers[0].Name := 'Host';
  Headers[0].Value := 'example.invalid';
  Headers[1].Name := 'Content-Length';
  Headers[1].Value := '1';
  Headers[2].Name := 'Content-Type';
  Headers[2].Value := 'text/plain';
  Headers[3].Name := 'X-Trace';
  Headers[3].Value := 'retained';
  Headers[4].Name := 'Transfer-Encoding';
  Headers[4].Value := 'chunked';
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(nil));
  try
    Mock.Start;
    Response := HTTPPost(MockURL(Mock.Port), Body,
      'application/octet-stream', Headers);
    Mock.WaitDone;
    Expect<Integer>(Response.StatusCode).ToBe(200);
    CapturedHeader := RequestHeaderText(Mock.ReceivedRequest);
    ExpectedHeader := 'POST /x HTTP/1.1' + CRLF +
      'Host: 127.0.0.1:' + IntToStr(Mock.Port) + CRLF +
      'Connection: close' + CRLF +
      'User-Agent: GocciaScript/1.0' + CRLF +
      'Content-Length: ' + IntToStr(Length(Body)) + CRLF +
      'Content-Type: application/octet-stream' + CRLF +
      'X-Trace: retained' + CRLF + CRLF;
    Expect<string>(CapturedHeader).ToBe(ExpectedHeader);
    CapturedBody := RequestBody(Mock.ReceivedRequest);
    Expect<Integer>(Length(CapturedBody)).ToBe(Length(Body));
    Expect<string>(BytesToHex(CapturedBody)).ToBe(BytesToHex(Body));
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientRequestBodies.
  TestPostRejectsContentTypeLineBreaksBeforeConnect;
var
  Body: TBytes;
  ContentTypes: array[0..1] of string;
  Endpoint: TMockRefusedEndpoint;
  ErrorMessage, URL: string;
  I: Integer;
  NoHeaders: THTTPHeaders;
begin
  Body := MakeBytes([$00, $01]);
  ContentTypes[0] := 'text/plain' + #13 + 'X-Injected: yes';
  ContentTypes[1] := 'text/plain' + #10 + 'X-Injected: yes';
  Endpoint := TMockRefusedEndpoint.Create;
  try
    URL := 'http://' + Endpoint.Host + ':' + IntToStr(Endpoint.Port) + '/x';
    NoHeaders := nil;
    for I := 0 to High(ContentTypes) do
    begin
      ErrorMessage := '';
      try
        HTTPPost(URL, Body, ContentTypes[I], NoHeaders);
      except
        on E: EHTTPError do ErrorMessage := E.Message;
      end;
      Expect<string>(ErrorMessage).ToBe(
        'HTTP content type must not contain carriage return or line feed');
    end;
  finally
    Endpoint.Free;
  end;
end;

procedure THTTPClientRequestBodies.TestPostRedirect301And302BecomesGet;
const
  CRLF = #13#10;
var
  Body, Captured: TBytes;
  Header: string;
  StatusCode: Integer;
begin
  Body := MakeBytes([$00, $01, $fe, $ff]);
  for StatusCode := 301 to 302 do
  begin
    Captured := ServePostRedirectAndCapture(StatusCode, Body,
      'application/octet-stream');
    Header := RequestHeaderText(Captured);
    Expect<Boolean>(Pos('GET /target HTTP/1.1' + CRLF, Header) = 1).ToBe(True);
    Expect<Boolean>(Pos('Content-Length:', Header) = 0).ToBe(True);
    Expect<Boolean>(Pos('Content-Type:', Header) = 0).ToBe(True);
    Expect<Integer>(Length(RequestBody(Captured))).ToBe(0);
  end;
end;

procedure THTTPClientRequestBodies.TestPostRedirect303BecomesGet;
const
  CRLF = #13#10;
var
  Captured: TBytes;
  Header: string;
begin
  Captured := ServePostRedirectAndCapture(303,
    MakeBytes([$00, $01, $02]), 'application/octet-stream');
  Header := RequestHeaderText(Captured);
  Expect<Boolean>(Pos('GET /target HTTP/1.1' + CRLF, Header) = 1).ToBe(True);
  Expect<Boolean>(Pos('Content-Length:', Header) = 0).ToBe(True);
  Expect<Boolean>(Pos('Content-Type:', Header) = 0).ToBe(True);
  Expect<Integer>(Length(RequestBody(Captured))).ToBe(0);
end;

procedure THTTPClientRequestBodies.TestPostRedirect307And308PreservesBody;
const
  CRLF = #13#10;
var
  Body, Captured, CapturedBody: TBytes;
  Header: string;
  StatusCode: Integer;
begin
  Body := MakeBytes([$00, $01, $fe, $ff]);
  for StatusCode := 307 to 308 do
  begin
    Captured := ServePostRedirectAndCapture(StatusCode, Body,
      'application/octet-stream');
    Header := RequestHeaderText(Captured);
    Expect<Boolean>(Pos('POST /target HTTP/1.1' + CRLF, Header) = 1).ToBe(True);
    Expect<Boolean>(Pos('Content-Length: 4' + CRLF, Header) > 0).ToBe(True);
    Expect<Boolean>(Pos('Content-Type: application/octet-stream' + CRLF,
      Header) > 0).ToBe(True);
    CapturedBody := RequestBody(Captured);
    Expect<string>(BytesToHex(CapturedBody)).ToBe(BytesToHex(Body));
  end;
end;

procedure THTTPClientRequestBodies.TestGetAndHeadWireBehaviorIsUnchanged;
const
  CRLF = #13#10;
var
  CapturedHeader, ExpectedHeader, Method: string;
  Headers: THTTPHeaders;
  I: Integer;
  Mock: TMockHTTPServer;
  Response: THTTPResponse;
begin
  SetLength(Headers, 1);
  Headers[0].Name := 'X-Preserve';
  Headers[0].Value := 'yes';
  for I := 0 to 1 do
  begin
    if I = 0 then Method := 'GET'
    else Method := 'HEAD';
    Mock := TMockHTTPServer.Create(BuildSimpleResponse(nil));
    try
      Mock.Start;
      if Method = 'GET' then
        Response := HTTPGet(MockURL(Mock.Port), Headers)
      else
        Response := HTTPHead(MockURL(Mock.Port), Headers);
      Mock.WaitDone;
      Expect<Integer>(Response.StatusCode).ToBe(200);
      CapturedHeader := RequestHeaderText(Mock.ReceivedRequest);
      ExpectedHeader := Method + ' /x HTTP/1.1' + CRLF +
        'Host: 127.0.0.1:' + IntToStr(Mock.Port) + CRLF +
        'Connection: close' + CRLF +
        'User-Agent: GocciaScript/1.0' + CRLF +
        'X-Preserve: yes' + CRLF + CRLF;
      Expect<string>(CapturedHeader).ToBe(ExpectedHeader);
      Expect<Integer>(Length(RequestBody(Mock.ReceivedRequest))).ToBe(0);
    finally
      Mock.Free;
    end;
  end;
end;

procedure THTTPClientRequestBodies.SetupTests;
begin
  Test('POST sends complete binary content and owns entity headers',
    TestPostSendsBinaryBodyAndOwnsEntityHeaders);
  Test('POST rejects Content-Type line breaks before connecting',
    TestPostRejectsContentTypeLineBreaksBeforeConnect);
  Test('POST redirects through 301 and 302 as bodyless GET',
    TestPostRedirect301And302BecomesGet);
  Test('POST redirects through 303 as bodyless GET',
    TestPostRedirect303BecomesGet);
  Test('POST redirects through 307 and 308 with method and body preserved',
    TestPostRedirect307And308PreservesBody);
  Test('GET and HEAD request bytes remain unchanged',
    TestGetAndHeadWireBehaviorIsUnchanged);
end;

{ ── THTTPClientByteFetch ──────────────────────────────────────────── }

procedure THTTPClientByteFetch.TestSimpleResponseBodyStartsWithNul;
var
  ExpectedBody, GotBody: TBytes;
begin
  { Body = #0 #1 #2 #3 'ABCD'. The body's first byte is #0; the old
    code would truncate the entire body. Length must be exactly 8. }
  ExpectedBody := MakeBytes([$00, $01, $02, $03, $41, $42, $43, $44]);
  GotBody := ServeAndFetch(BuildSimpleResponse(ExpectedBody));
  Expect<Integer>(Length(GotBody)).ToBe(Length(ExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

procedure THTTPClientByteFetch.TestSimpleResponseBodyInterspersedNul;
var
  ExpectedBody, GotBody: TBytes;
begin
  { Body has #0 bytes between non-null bytes. Old code would truncate
    at the first #0 encountered while string-converting the recv buffer. }
  ExpectedBody := MakeBytes(
    [$01, $02, $00, $03, $04, $00, $00, $05, $06, $00, $07, $08]);
  GotBody := ServeAndFetch(BuildSimpleResponse(ExpectedBody));
  Expect<Integer>(Length(GotBody)).ToBe(Length(ExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

procedure THTTPClientByteFetch.TestChunkedResponseChunkStartsWithNul;
var
  ExpectedBody, GotBody: TBytes;
  Chunks: TByteArrays;
begin
  { Single chunk starting with #0. Exercises the chunked-read path
    where Copy(PAnsiChar(...)) used to truncate. }
  ExpectedBody := MakeBytes([$00, $00, $FF, $FE, $FD]);
  SetLength(Chunks, 1);
  Chunks[0] := ExpectedBody;
  GotBody := ServeAndFetch(BuildChunkedResponse(Chunks));
  Expect<Integer>(Length(GotBody)).ToBe(Length(ExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

procedure THTTPClientByteFetch.TestChunkedResponseMultipleChunksWithNul;
var
  ExpectedBody, GotBody, ChunkA, ChunkB, ChunkC: TBytes;
  Chunks: TByteArrays;
begin
  { Three chunks; each contains #0 in a different position. The chunked
    reader assembles the body by appending bytes; with the old code
    each chunk's bytes were truncated at its first #0. }
  ChunkA := MakeBytes([$00, $01, $02, $03]);              { starts with #0 }
  ChunkB := MakeBytes([$10, $00, $11, $00, $12]);         { mid #0 x2 }
  ChunkC := MakeBytes([$20, $21, $22, $00]);              { ends with #0 }
  SetLength(Chunks, 3);
  Chunks[0] := ChunkA;
  Chunks[1] := ChunkB;
  Chunks[2] := ChunkC;
  ExpectedBody := MakeBytes(
    [$00, $01, $02, $03,
     $10, $00, $11, $00, $12,
     $20, $21, $22, $00]);
  GotBody := ServeAndFetch(BuildChunkedResponse(Chunks));
  Expect<Integer>(Length(GotBody)).ToBe(Length(ExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

procedure THTTPClientByteFetch.TestLargeBodyForcesMultiRecv;
var
  ExpectedBody, GotBody: TBytes;
  i: Integer;
begin
  { Body larger than HTTPClient's RECV_BUF_SIZE (8 KB), with #0 bytes
    scattered throughout. Forces multiple recv() calls and exercises
    the path where header-accumulation already wrote some body-prefix
    bytes to the buffer that DON'T get re-read on the next recv. }
  SetLength(ExpectedBody, 32 * 1024);
  for i := 0 to High(ExpectedBody) do
  begin
    if (i mod 17) = 0 then ExpectedBody[i] := 0     { sprinkle #0 }
    else if (i mod 13) = 0 then ExpectedBody[i] := 255
    else ExpectedBody[i] := Byte(i and $FF);
  end;
  GotBody := ServeAndFetch(BuildSimpleResponse(ExpectedBody));
  Expect<Integer>(Length(GotBody)).ToBe(Length(ExpectedBody));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

procedure THTTPClientByteFetch.TestSegmentedWritesPreserveNul;
var
  ExpectedBody, GotBody: TBytes;
begin
  ExpectedBody := MakeBytes(
    [$00, $01, $02, $03, $00, $fd, $fe, $ff, $00]);
  GotBody := ServeAndFetch(BuildSimpleResponse(ExpectedBody), 1);
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(ExpectedBody));
end;

{ ── THTTPClientResourceBounds ──────────────────────────────────────── }

procedure THTTPClientResourceBounds.TestFixedBodyAtLimit;
var
  Body, GotBody: TBytes;
begin
  Body := MakeBytes([$00, $01, $02, $03]);
  GotBody := ServeAndFetch(FixedResponse('4', Body),
    TestOptions(4, 1024, 1000));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(Body));
end;

procedure THTTPClientResourceBounds.TestFixedBodyOverLimit;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(
    FixedResponse('5', nil), TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP response body exceeds configured limit of 4 bytes');
end;

procedure THTTPClientResourceBounds.TestChunkedBodyAtLimit;
var
  Body, GotBody: TBytes;
  Chunks: TByteArrays;
begin
  Body := MakeBytes([$00, $01, $02, $03]);
  SetLength(Chunks, 2);
  Chunks[0] := Copy(Body, 0, 2);
  Chunks[1] := Copy(Body, 2, 2);
  GotBody := ServeAndFetch(BuildChunkedResponse(Chunks),
    TestOptions(4, 1024, 1000));
  Expect<string>(BytesToHex(GotBody)).ToBe(BytesToHex(Body));
end;

procedure THTTPClientResourceBounds.TestChunkedBodyOverLimit;
var
  Body: TBytes;
  Chunks: TByteArrays;
  ErrorMessage: string;
begin
  Body := MakeBytes([$00, $01, $02, $03, $04]);
  SetLength(Chunks, 1);
  Chunks[0] := Body;
  ErrorMessage := ServeAndCaptureError(BuildChunkedResponse(Chunks),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP response body exceeds configured limit of 4 bytes');
end;

procedure THTTPClientResourceBounds.TestChunkSizeFailures;
const
  CRLF = #13#10;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(
    StringBytes('HTTP/1.1 200 OK' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF +
      'nope' + CRLF),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe('Invalid HTTP chunk size: nope');

  ErrorMessage := ServeAndCaptureError(
    StringBytes('HTTP/1.1 200 OK' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF +
      StringOfChar('a', 65) + CRLF),
    TestOptions(4, 64, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP chunk-size line exceeds configured limit of 64 bytes');
end;

procedure THTTPClientResourceBounds.TestChunkSizeNearIntegerMaxIsBounded;
const
  CRLF = #13#10;
var
  ErrorMessage: string;
begin
  { A chunk-size line of 7fffffff (= High(Integer)) with the body limit set to
    High(Integer): the body guard admits the size, but the Integer-indexed
    accumulator cannot hold both that payload and its trailing CRLF. Reject it
    before `ChunkSize + 2` can overflow or any body bytes are read. }
  ErrorMessage := ServeAndCaptureError(
    StringBytes('HTTP/1.1 200 OK' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF +
      '7fffffff' + CRLF),
    TestOptions(High(Integer), 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP chunk size exceeds supported frame limit of 2147483645 bytes');
end;

function BodyLimitErrorClass(const ARawResponse: TBytes): string;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
begin
  Result := '';
  Mock := TMockHTTPServer.Create(ARawResponse);
  try
    Mock.Start;
    NoHeaders := nil;
    try
      HTTPGet('http://127.0.0.1:' + IntToStr(Mock.Port) + '/x', NoHeaders,
        TestOptions(4, 1024, 1000));
    except
      on E: EHTTPError do
        Result := E.ClassName;
    end;
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientResourceBounds.TestBodyLimitRaisesResponseTooLarge;
const
  CRLF = #13#10;
var
  Chunks: TByteArrays;
begin
  { Every way a body can exceed the limit raises the same subclass, so
    callers can refuse an oversized response without matching text. }
  Expect<string>(BodyLimitErrorClass(FixedResponse('5', nil)))
    .ToBe('EHTTPResponseTooLarge');
  Expect<string>(BodyLimitErrorClass(ConcatBytes(
    StringBytes('HTTP/1.1 200 OK' + CRLF + 'Connection: close' + CRLF
      + CRLF), MakeBytes([$00, $01, $02, $03, $04]))))
    .ToBe('EHTTPResponseTooLarge');
  SetLength(Chunks, 1);
  Chunks[0] := MakeBytes([$00, $01, $02, $03, $04]);
  Expect<string>(BodyLimitErrorClass(BuildChunkedResponse(Chunks)))
    .ToBe('EHTTPResponseTooLarge');
  { Other response failures keep the base class. }
  Expect<string>(BodyLimitErrorClass(StringBytes('HTTP/1.1 200 OK' + CRLF
    + 'Transfer-Encoding: chunked' + CRLF + CRLF + 'nope' + CRLF)))
    .ToBe('EHTTPError');
end;

procedure THTTPClientResourceBounds.TestCloseDelimitedBodyOverLimit;
const
  CRLF = #13#10;
var
  Raw: TBytes;
  ErrorMessage: string;
begin
  Raw := ConcatBytes(
    StringBytes('HTTP/1.1 200 OK' + CRLF + 'Connection: close' +
      CRLF + CRLF),
    MakeBytes([$00, $01, $02, $03, $04]));
  ErrorMessage := ServeAndCaptureError(Raw,
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP response body exceeds configured limit of 4 bytes');
end;

procedure THTTPClientResourceBounds.TestInvalidContentLengths;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(FixedResponse('-1', nil),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe('Invalid HTTP Content-Length: -1');

  ErrorMessage := ServeAndCaptureError(FixedResponse('2147483648', nil),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP response body exceeds configured limit of 4 bytes');

  ErrorMessage := ServeAndCaptureError(FixedResponse('nope', nil),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe('Invalid HTTP Content-Length: nope');

  ErrorMessage := ServeAndCaptureError(
    FixedResponse('9223372036854775808', nil),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'Invalid HTTP Content-Length: 9223372036854775808');
end;

procedure THTTPClientResourceBounds.TestConflictingContentLengths;
const
  CRLF = #13#10;
var
  Raw: TBytes;
  ErrorMessage: string;
begin
  Raw := StringBytes('HTTP/1.1 200 OK' + CRLF +
    'Content-Length: 1' + CRLF + 'Content-Length: 2' + CRLF +
    'Connection: close' + CRLF + CRLF);
  ErrorMessage := ServeAndCaptureError(Raw,
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'Invalid HTTP response: conflicting Content-Length headers');
end;

procedure THTTPClientResourceBounds.TestDuplicateContentLengths;
const
  CRLF = #13#10;
var
  Raw, GotBody: TBytes;
begin
  Raw := ConcatBytes(StringBytes('HTTP/1.1 200 OK' + CRLF +
    'Content-Length: 1' + CRLF + 'Content-Length: 1' + CRLF +
    'Connection: close' + CRLF + CRLF), MakeBytes([$7f]));
  GotBody := ServeAndFetch(Raw, TestOptions(1, 1024, 1000));
  Expect<string>(BytesToHex(GotBody)).ToBe('7f');
end;

procedure THTTPClientResourceBounds.TestTruncatedFixedBody;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(
    FixedResponse('4', MakeBytes([$00, $01])),
    TestOptions(4, 1024, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'Invalid HTTP response: truncated fixed-length body');
end;

procedure THTTPClientResourceBounds.TestHeaderAtLimit;
const
  CRLF = #13#10;
  HEADER_LIMIT = 64;
var
  Header, Prefix, Suffix: string;
  GotBody: TBytes;
begin
  Prefix := 'HTTP/1.1 204 No Content' + CRLF + 'X-Pad: ';
  Suffix := CRLF + CRLF;
  Header := Prefix + StringOfChar('a',
    HEADER_LIMIT - Length(Prefix) - Length(Suffix)) + Suffix;
  GotBody := ServeAndFetch(StringBytes(Header),
    TestOptions(4, HEADER_LIMIT, 1000));
  Expect<Integer>(Length(GotBody)).ToBe(0);
end;

procedure THTTPClientResourceBounds.TestHeaderOverLimit;
const
  CRLF = #13#10;
  HEADER_LIMIT = 64;
var
  Header, Prefix, Suffix: string;
  ErrorMessage: string;
begin
  Prefix := 'HTTP/1.1 204 No Content' + CRLF + 'X-Pad: ';
  Suffix := CRLF + CRLF;
  Header := Prefix + StringOfChar('a',
    HEADER_LIMIT - Length(Prefix) - Length(Suffix) + 1) + Suffix;
  ErrorMessage := ServeAndCaptureError(StringBytes(Header),
    TestOptions(4, HEADER_LIMIT, 1000), 0, 0, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP response headers exceed configured limit of 64 bytes');
end;

procedure THTTPClientResourceBounds.TestRequestDeadlineRejectsIdlePeer;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(nil,
    TestOptions(4, 1024, 100), 0, 0, 300);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP request deadline exceeded after 100 ms');
end;

procedure THTTPClientResourceBounds.TestRequestDeadlineRejectsSlowDrip;
const
  CRLF = #13#10;
var
  SlowHeader: TBytes;
  ErrorMessage: string;
begin
  SlowHeader := StringBytes('HTTP/1.1 200 OK' + CRLF +
    'X-Slow: ' + StringOfChar('a', 64));
  ErrorMessage := ServeAndCaptureError(SlowHeader,
    TestOptions(4, 1024, 100), 1, 25, 0);
  Expect<string>(ErrorMessage).ToBe(
    'HTTP request deadline exceeded after 100 ms');
end;

procedure THTTPClientResourceBounds.
  TestRedirectBudgetDefaultsAndRejectsNegativeValues;
var
  ErrorMessage: string;
  NoHeaders: THTTPHeaders;
  Options: THTTPRequestOptions;
begin
  Options := DefaultHTTPRequestOptions;
  Expect<Integer>(Options.MaximumRedirects).ToBe(
    DEFAULT_MAXIMUM_REDIRECTS);
  Options.MaximumRedirects := -1;
  ErrorMessage := '';
  NoHeaders := nil;
  try
    HTTPGet('http://127.0.0.1:1/', NoHeaders, Options);
  except
    on E: EHTTPError do ErrorMessage := E.Message;
  end;
  Expect<string>(ErrorMessage).ToBe(
    'HTTP maximum redirects must not be negative');
end;

procedure THTTPClientResourceBounds.
  TestZeroRedirectBudgetReturnsTheRedirectResponse;
const
  CRLF = #13#10;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
  Options: THTTPRequestOptions;
  Response: THTTPResponse;
begin
  Mock := TMockHTTPServer.Create(StringBytes(
    'HTTP/1.1 302 Found' + CRLF +
    'Location: http://127.0.0.1:1/escape' + CRLF +
    'Content-Length: 0' + CRLF + 'Connection: close' + CRLF + CRLF));
  try
    Mock.Start;
    NoHeaders := nil;
    Options := TestOptions(4, 1024, 1000);
    Options.MaximumRedirects := 0;
    Response := HTTPGet(MockURL(Mock.Port), NoHeaders, Options);
    Mock.WaitDone;
    Expect<Integer>(Response.StatusCode).ToBe(302);
    Expect<Boolean>(Response.Redirected).ToBe(False);
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientResourceBounds.TestTLSHandshakeDeadlineRejectsIdlePeer;
var
  ErrorMessage: string;
begin
  ErrorMessage := ServeAndCaptureError(nil,
    TestOptions(4, 1024, 100), 0, 0, 300, 'https');
  Expect<string>(ErrorMessage).ToBe(
    'HTTP request deadline exceeded after 100 ms');
end;

procedure THTTPClientResourceBounds.SetupTests;
begin
  Test('fixed-length body exactly at limit succeeds', TestFixedBodyAtLimit);
  Test('fixed-length body over limit fails before allocation',
    TestFixedBodyOverLimit);
  Test('chunked body exactly at limit succeeds', TestChunkedBodyAtLimit);
  Test('chunked body over limit fails', TestChunkedBodyOverLimit);
  Test('invalid and oversized chunk-size lines fail stably',
    TestChunkSizeFailures);
  Test('a chunk size near High(Integer) fails without overflow or over-read',
    TestChunkSizeNearIntegerMaxIsBounded);
  Test('close-delimited body over limit fails',
    TestCloseDelimitedBodyOverLimit);
  Test('every body-limit failure raises EHTTPResponseTooLarge',
    TestBodyLimitRaisesResponseTooLarge);
  Test('invalid Content-Length values fail stably',
    TestInvalidContentLengths);
  Test('conflicting Content-Length headers fail stably',
    TestConflictingContentLengths);
  Test('identical duplicate Content-Length headers succeed',
    TestDuplicateContentLengths);
  Test('truncated fixed-length body fails', TestTruncatedFixedBody);
  Test('header terminator exactly at limit succeeds', TestHeaderAtLimit);
  Test('header terminator over limit fails', TestHeaderOverLimit);
  Test('whole-request deadline rejects fully idle peer',
    TestRequestDeadlineRejectsIdlePeer);
  Test('whole-request deadline rejects slow-drip peer',
    TestRequestDeadlineRejectsSlowDrip);
  Test('redirect budget defaults and rejects negative values',
    TestRedirectBudgetDefaultsAndRejectsNegativeValues);
  Test('a zero redirect budget returns the redirect response',
    TestZeroRedirectBudgetReturnsTheRedirectResponse);
  Test('whole-request deadline covers an idle TLS handshake',
    TestTLSHandshakeDeadlineRejectsIdlePeer);
end;

procedure THTTPClientByteFetch.SetupTests;
begin
  Test('simple response: body starts with #0 (header-accumulation path)',
    TestSimpleResponseBodyStartsWithNul);
  Test('simple response: #0 interspersed in body',
    TestSimpleResponseBodyInterspersedNul);
  Test('chunked: single chunk starting with #0',
    TestChunkedResponseChunkStartsWithNul);
  Test('chunked: multiple chunks each carrying #0',
    TestChunkedResponseMultipleChunksWithNul);
  Test('large body forces multi-recv with #0 scattered through',
    TestLargeBodyForcesMultiRecv);
  Test('one-byte server writes preserve embedded #0 bytes',
    TestSegmentedWritesPreserveNul);
end;

{ ── destination policy ─────────────────────────────────────────────── }

const
  PolicyPublicTestHost = 'forge.test';

function PolicyOptions(const AAllowedHosts: array of string;
  const APrivateAddressPolicy: THTTPPrivateAddressPolicy): THTTPRequestOptions;
var
  HostIndex: Integer;
begin
  Result := TestOptions(1024, 4096, 2000);
  SetLength(Result.Destination.AllowedHosts, Length(AAllowedHosts));
  for HostIndex := 0 to High(AAllowedHosts) do
    Result.Destination.AllowedHosts[HostIndex] := AAllowedHosts[HostIndex];
  Result.Destination.PrivateAddressPolicy := APrivateAddressPolicy;
end;

function GetErrorMessage(const AURL: string;
  const AOptions: THTTPRequestOptions): string;
var
  NoHeaders: THTTPHeaders;
begin
  Result := '';
  NoHeaders := nil;
  try
    HTTPGet(AURL, NoHeaders, AOptions);
  except
    on E: EHTTPError do Result := E.Message;
  end;
end;

{ Serves a redirect from an origin mock to ATargetHost on a target mock and
  returns the error the policy raised, or '' after a successful fetch.
  ATargetServed reports whether the redirect target was contacted at all. }
function FollowRedirectUnderPolicy(const AOriginHost, ATargetHost: string;
  const AOptions: THTTPRequestOptions; out ATargetServed: Boolean): string;
var
  NoHeaders: THTTPHeaders;
  Origin, Target: TMockHTTPServer;
  Response: THTTPResponse;
begin
  Result := '';
  Target := TMockHTTPServer.Create(BuildSimpleResponse(StringBytes('ok')));
  try
    Target.Start;
    Origin := TMockHTTPServer.Create(RedirectResponse(302,
      'http://' + ATargetHost + ':' + IntToStr(Target.Port) + '/target'));
    try
      Origin.Start;
      NoHeaders := nil;
      try
        Response := HTTPGet('http://' + AOriginHost + ':'
          + IntToStr(Origin.Port) + '/x', NoHeaders, AOptions);
        Expect<Integer>(Response.StatusCode).ToBe(200);
        Expect<string>(StringOf(Response.Body)).ToBe('ok');
      except
        on E: EHTTPError do Result := E.Message;
      end;
      Expect<Boolean>(Origin.WaitDone(2000)).ToBe(True);
      { A refused hop never connects, so the target is still waiting for
        its first client when the request has already returned. }
      ATargetServed := Target.WaitDone(200);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

{ Asserts the request is refused with AExpected before any connection. }
procedure ExpectRefusedBeforeConnect(const AScheme, AHost: string;
  const AOptions: THTTPRequestOptions; const AExpected: string);
var
  Mock: TMockHTTPServer;
begin
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(StringBytes('ok')));
  try
    Mock.Start;
    Expect<string>(GetErrorMessage(AScheme + '://' + AHost + ':'
      + IntToStr(Mock.Port) + '/x', AOptions)).ToBe(AExpected);
    Expect<Boolean>(Mock.WaitDone(200)).ToBe(False);
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientDestinationPolicy.TestDefaultOptionsAllowEveryDestination;
var
  Options: THTTPRequestOptions;
  Served: Boolean;
begin
  Options := DefaultHTTPRequestOptions;
  Expect<Integer>(Length(Options.Destination.AllowedHosts)).ToBe(0);
  Expect<Boolean>(Options.Destination.PrivateAddressPolicy = papAllow)
    .ToBe(True);
  Expect<Boolean>(Options.Destination.RequireHTTPS).ToBe(False);
  Options.RequestTimeoutMilliseconds := 2000;
  Expect<string>(FollowRedirectUnderPolicy('127.0.0.1', '127.0.0.1',
    Options, Served)).ToBe('');
  Expect<Boolean>(Served).ToBe(True);
end;

procedure THTTPClientDestinationPolicy.TestHTTPURLHostMatchesRequestParsing;
var
  Message: string;
begin
  Expect<string>(HTTPURLHost('https://GitHub.com/owner/repo.git'))
    .ToBe('github.com');
  Expect<string>(HTTPURLHost('https://user@Host.Example:8443/x')).ToBe(
    'host.example');
  Expect<string>(HTTPURLHost('https://[::1]:443/x')).ToBe('::1');
  Expect<string>(HTTPURLHost('http://127.0.0.1')).ToBe('127.0.0.1');
  Message := '';
  try
    HTTPURLHost('ftp://host.example/x');
  except
    on E: EHTTPError do Message := E.Message;
  end;
  Expect<string>(Message).ToBe('Unsupported scheme: ftp');
end;

procedure THTTPClientDestinationPolicy.
  TestRequireHTTPSRefusesPlaintextBeforeConnect;
var
  Options: THTTPRequestOptions;
begin
  Options := PolicyOptions([], papAllow);
  Options.Destination.RequireHTTPS := True;
  ExpectRefusedBeforeConnect('http', '127.0.0.1', Options,
    'fetch scheme not allowed: http://127.0.0.1 (https is required)');
end;

procedure THTTPClientDestinationPolicy.
  TestDisallowedInitialHostIsRefusedBeforeConnect;
begin
  ExpectRefusedBeforeConnect('http', '127.0.0.1',
    PolicyOptions(['github.com'], papAllow),
    'fetch host not allowed: 127.0.0.1');
end;

procedure THTTPClientDestinationPolicy.TestRedirectToDisallowedHostIsRefused;
var
  Served: Boolean;
begin
  Expect<string>(FollowRedirectUnderPolicy('127.0.0.1', 'localhost',
    PolicyOptions(['127.0.0.1'], papAllow), Served))
    .ToBe('fetch host not allowed: localhost');
  Expect<Boolean>(Served).ToBe(False);
end;

procedure THTTPClientDestinationPolicy.TestRedirectWithinAllowedHostsSucceeds;
var
  Served: Boolean;
begin
  Expect<string>(FollowRedirectUnderPolicy('127.0.0.1', '127.0.0.1',
    PolicyOptions(['127.0.0.1'], papAllow), Served)).ToBe('');
  Expect<Boolean>(Served).ToBe(True);
end;

procedure THTTPClientDestinationPolicy.
  TestDenyRefusesResolvedLoopbackBeforeConnect;
begin
  { The name is resolved once; the binary answer is classified and named in
    the refusal, which also pins the resolver's byte order. }
  ExpectRefusedBeforeConnect('http', 'localhost', PolicyOptions([], papDeny),
    'fetch destination not allowed: localhost resolves to loopback address '
    + '127.0.0.1');
end;

procedure THTTPClientDestinationPolicy.
  TestDenyRefusesNonGlobalLiteralsBeforeConnect;
begin
  ExpectRefusedBeforeConnect('http', '127.0.0.1', PolicyOptions([], papDeny),
    'fetch destination not allowed: 127.0.0.1 resolves to loopback address '
    + '127.0.0.1');
  ExpectRefusedBeforeConnect('http', '[0:0:0:0:0:ffff:127.0.0.1]',
    PolicyOptions([], papDeny),
    'fetch destination not allowed: 0:0:0:0:0:ffff:127.0.0.1 resolves to '
    + 'loopback address 127.0.0.1');
  ExpectRefusedBeforeConnect('http', '[fe90::1]', PolicyOptions([], papDeny),
    'fetch destination not allowed: fe90::1 resolves to link-local address '
    + 'fe90:0:0:0:0:0:0:1');
end;

{$IFDEF HTTPCLIENT_TESTING}
{ Asserts the first and last address of a non-global block, and the
  addresses just outside it, classify as expected. AOutsideBelow and
  AOutsideAbove are '' when that neighbour belongs to another block. }
procedure ExpectBlock(const AFirst, ALast, AName, AOutsideBelow,
  AOutsideAbove: string);
begin
  Expect<string>(NonGlobalAddressReason(AFirst)).ToBe(AName);
  Expect<string>(NonGlobalAddressReason(ALast)).ToBe(AName);
  if AOutsideBelow <> '' then
    Expect<string>(NonGlobalAddressReason(AOutsideBelow)).ToBe('');
  if AOutsideAbove <> '' then
    Expect<string>(NonGlobalAddressReason(AOutsideAbove)).ToBe('');
end;

procedure THTTPClientDestinationPolicy.TestIPv4RegistryBlockBoundaries;
begin
  ExpectBlock('0.0.0.0', '0.255.255.255', 'this network', '', '1.0.0.0');
  ExpectBlock('10.0.0.0', '10.255.255.255', 'private-use', '9.255.255.255',
    '11.0.0.0');
  ExpectBlock('100.64.0.0', '100.127.255.255', 'shared address space',
    '100.63.255.255', '100.128.0.0');
  ExpectBlock('127.0.0.0', '127.255.255.255', 'loopback', '126.255.255.255',
    '128.0.0.0');
  ExpectBlock('169.254.0.0', '169.254.255.255', 'link-local',
    '169.253.255.255', '169.255.0.0');
  ExpectBlock('172.16.0.0', '172.31.255.255', 'private-use',
    '172.15.255.255', '172.32.0.0');
  ExpectBlock('192.0.0.0', '192.0.0.255', 'IETF protocol assignments',
    '191.255.255.255', '192.0.1.0');
  ExpectBlock('192.0.2.0', '192.0.2.255', 'documentation', '192.0.1.255',
    '192.0.3.0');
  ExpectBlock('192.88.99.0', '192.88.99.255', 'deprecated 6to4 relay anycast',
    '192.88.98.255', '192.88.100.0');
  ExpectBlock('192.168.0.0', '192.168.255.255', 'private-use',
    '192.167.255.255', '192.169.0.0');
  ExpectBlock('198.18.0.0', '198.19.255.255', 'benchmarking',
    '198.17.255.255', '198.20.0.0');
  ExpectBlock('198.51.100.0', '198.51.100.255', 'documentation',
    '198.51.99.255', '198.51.101.0');
  ExpectBlock('203.0.113.0', '203.0.113.255', 'documentation',
    '203.0.112.255', '203.0.114.0');
  ExpectBlock('224.0.0.0', '239.255.255.255', 'multicast', '223.255.255.255',
    '');
  ExpectBlock('240.0.0.0', '255.255.255.255',
    'reserved (including limited broadcast)', '', '');
  { The cloud instance-metadata endpoint is link-local. }
  Expect<string>(NonGlobalAddressReason('169.254.169.254')).ToBe(
    'link-local');
end;

procedure THTTPClientDestinationPolicy.TestIPv4GlobalExceptionsAndNeighbours;
begin
  Expect<string>(NonGlobalAddressReason('192.0.0.9')).ToBe('');
  Expect<string>(NonGlobalAddressReason('192.0.0.10')).ToBe('');
  Expect<string>(NonGlobalAddressReason('192.0.0.8')).ToBe(
    'IETF protocol assignments');
  Expect<string>(NonGlobalAddressReason('192.0.0.11')).ToBe(
    'IETF protocol assignments');
  Expect<string>(NonGlobalAddressReason('192.0.0.170')).ToBe(
    'IETF protocol assignments');
  Expect<string>(NonGlobalAddressReason('8.8.8.8')).ToBe('');
  Expect<string>(NonGlobalAddressReason('140.82.112.3')).ToBe('');
end;

procedure THTTPClientDestinationPolicy.TestIPv6RegistryBlockBoundaries;
begin
  Expect<string>(NonGlobalAddressReason('::')).ToBe('unspecified');
  Expect<string>(NonGlobalAddressReason('::1')).ToBe('loopback');
  Expect<string>(NonGlobalAddressReason('[::1]')).ToBe('loopback');
  ExpectBlock('64:ff9b:1::', '64:ff9b:1:ffff:ffff:ffff:ffff:ffff',
    'local-use IPv4/IPv6 translation', '', '');
  ExpectBlock('100::', '100::ffff:ffff:ffff:ffff', 'discard-only', '', '');
  ExpectBlock('100:0:0:1::', '100::1:ffff:ffff:ffff:ffff', 'dummy prefix',
    '', '');
  ExpectBlock('2001::', '2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff',
    'IETF protocol assignments', '2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    '2001:200::');
  ExpectBlock('2001:db8::', '2001:db8:ffff:ffff:ffff:ffff:ffff:ffff',
    'documentation', '2001:db7:ffff:ffff:ffff:ffff:ffff:ffff', '2001:db9::');
  ExpectBlock('2002::', '2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '6to4',
    '2001:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '2003::');
  ExpectBlock('3fff::', '3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff',
    'documentation', '3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff', '3fff:1000::');
  ExpectBlock('5f00::', '5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    'segment routing', '', '');
  ExpectBlock('fc00::', 'fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    'unique-local', '', '');
  { fe80::/10 is masked, not matched by its first group. }
  ExpectBlock('fe80::', 'febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    'link-local', '', '');
  Expect<string>(NonGlobalAddressReason('fe90::1')).ToBe('link-local');
  Expect<string>(NonGlobalAddressReason('fea0::1')).ToBe('link-local');
  Expect<string>(NonGlobalAddressReason('fec0::1')).ToBe(
    'deprecated site-local');
  Expect<string>(NonGlobalAddressReason('fe7f::1')).ToBe(
    'outside global unicast');
  ExpectBlock('ff00::', 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
    'multicast', '', '');
  Expect<string>(NonGlobalAddressReason('1fff:ffff::1')).ToBe(
    'outside global unicast');
  Expect<string>(NonGlobalAddressReason('4000::1')).ToBe(
    'outside global unicast');
  { Globally reachable exceptions inside 2001::/23. }
  Expect<string>(NonGlobalAddressReason('2001:1::1')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:1::2')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:1::3')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:1::4')).ToBe(
    'IETF protocol assignments');
  Expect<string>(NonGlobalAddressReason('2001:3::1')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:4:112::1')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:20::1')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:3f::1')).ToBe('');
  Expect<string>(NonGlobalAddressReason('2001:40::1')).ToBe(
    'IETF protocol assignments');
  Expect<string>(NonGlobalAddressReason('2606:4700::1111')).ToBe('');
end;

procedure THTTPClientDestinationPolicy.TestIPv4EmbeddingSpellingsAreCanonical;
begin
  Expect<string>(NonGlobalAddressReason('::ffff:127.0.0.1')).ToBe(
    'loopback');
  Expect<string>(NonGlobalAddressReason('0:0:0:0:0:ffff:127.0.0.1')).ToBe(
    'loopback');
  Expect<string>(NonGlobalAddressReason('[0:0:0:0:0:ffff:127.0.0.1]'))
    .ToBe('loopback');
  Expect<string>(NonGlobalAddressReason('::ffff:7f00:1')).ToBe('loopback');
  Expect<string>(NonGlobalAddressReason('0:0:0:0:0:FFFF:0A00:0001')).ToBe(
    'private-use');
  Expect<string>(NonGlobalAddressReason('::127.0.0.1')).ToBe('loopback');
  Expect<string>(NonGlobalAddressReason('::a9fe:a9fe')).ToBe('link-local');
  Expect<string>(NonGlobalAddressReason('64:ff9b::7f00:1')).ToBe(
    'loopback');
  Expect<string>(NonGlobalAddressReason('64:ff9b::c612:1')).ToBe(
    'benchmarking');
  Expect<string>(NonGlobalAddressReason('::ffff:8.8.8.8')).ToBe('');
  Expect<string>(NonGlobalAddressReason('64:ff9b::808:808')).ToBe('');
end;

procedure THTTPClientDestinationPolicy.TestNonLiteralTextIsNotGlobal;
begin
  Expect<string>(NonGlobalAddressReason('127.1')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('0x7f.0.0.1')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('2130706433')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('localhost')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('')).ToBe('not an address literal');
  Expect<string>(NonGlobalAddressReason('999.1.1.1')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('1.2.3.4.5')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('fe80::1%eth0')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('1::2::3')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('1:2:3:4:5:6:7:8:9')).ToBe(
    'not an address literal');
  Expect<string>(NonGlobalAddressReason('12345::1')).ToBe(
    'not an address literal');
end;

procedure THTTPClientDestinationPolicy.TestHostAllowlistMatching;
var
  Options: THTTPRequestOptions;
begin
  Options := PolicyOptions([], papAllow);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination, 'anything.example'))
    .ToBe(True);
  Options := PolicyOptions(['github.com', 'codeload.github.com'], papAllow);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination, 'github.com'))
    .ToBe(True);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination,
    'CodeLoad.GitHub.com')).ToBe(True);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination,
    'evil.github.com')).ToBe(False);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination,
    'github.com.evil.example')).ToBe(False);
  Expect<Boolean>(IsHTTPHostAllowed(Options.Destination, '')).ToBe(False);
end;

{ Stands in for DNS: the named test host dials the loopback mock server but
  is classified as a public destination. Every other host resolves for real. }
function ResolvePublicTestHost(const AHost: string; out AAddress: string;
  out APrivate: Boolean): Boolean;
begin
  Result := SameText(AHost, PolicyPublicTestHost);
  AAddress := '';
  APrivate := False;
  if Result then AAddress := '127.0.0.1';
end;

procedure THTTPClientDestinationPolicy.
  TestPublicDestinationDialsTheCheckedAddress;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
  Response: THTTPResponse;
begin
  HTTPClientResolveTestHook := @ResolvePublicTestHost;
  try
    Mock := TMockHTTPServer.Create(BuildSimpleResponse(StringBytes('ok')));
    try
      Mock.Start;
      NoHeaders := nil;
      Response := HTTPGet('http://' + PolicyPublicTestHost + ':'
        + IntToStr(Mock.Port) + '/x', NoHeaders,
        PolicyOptions([PolicyPublicTestHost], papDeny));
      Expect<Boolean>(Mock.WaitDone(2000)).ToBe(True);
      Expect<Integer>(Response.StatusCode).ToBe(200);
      { The resolved address is dialled; the request still names the host. }
      Expect<Boolean>(Pos('Host: ' + PolicyPublicTestHost + ':'
        + IntToStr(Mock.Port) + #13#10,
        StringOf(Mock.ReceivedRequest)) > 0).ToBe(True);
    finally
      Mock.Free;
    end;
  finally
    HTTPClientResolveTestHook := nil;
  end;
end;

procedure THTTPClientDestinationPolicy.
  TestDenyRefusesRedirectIntoPrivateAddress;
var
  Served: Boolean;
begin
  HTTPClientResolveTestHook := @ResolvePublicTestHost;
  try
    Expect<string>(FollowRedirectUnderPolicy(PolicyPublicTestHost,
      '127.0.0.1', PolicyOptions([], papDeny), Served)).ToBe(
      'fetch destination not allowed: 127.0.0.1 resolves to loopback '
      + 'address 127.0.0.1');
    Expect<Boolean>(Served).ToBe(False);
  finally
    HTTPClientResolveTestHook := nil;
  end;
end;

{ Regression for the review finding: an expanded IPv4-mapped IPv6 literal
  was classified public and then re-resolved to loopback. }
procedure THTTPClientDestinationPolicy.
  TestExpandedMappedIPv6RedirectCannotReachLoopback;
var
  Served: Boolean;
begin
  HTTPClientResolveTestHook := @ResolvePublicTestHost;
  try
    Expect<string>(FollowRedirectUnderPolicy(PolicyPublicTestHost,
      '[0:0:0:0:0:ffff:127.0.0.1]', PolicyOptions([], papDeny),
      Served)).ToBe(
      'fetch destination not allowed: 0:0:0:0:0:ffff:127.0.0.1 resolves to '
      + 'loopback address 127.0.0.1');
    Expect<Boolean>(Served).ToBe(False);
  finally
    HTTPClientResolveTestHook := nil;
  end;
end;
{$ENDIF}

procedure THTTPClientDestinationPolicy.SetupTests;
begin
  Test('default options keep every destination reachable',
    TestDefaultOptionsAllowEveryDestination);
  Test('HTTPURLHost parses hosts exactly as a request does',
    TestHTTPURLHostMatchesRequestParsing);
  Test('RequireHTTPS refuses a plaintext hop before connecting',
    TestRequireHTTPSRefusesPlaintextBeforeConnect);
  Test('a host outside the allowlist is refused before connecting',
    TestDisallowedInitialHostIsRefusedBeforeConnect);
  Test('a redirect to a host outside the allowlist is refused',
    TestRedirectToDisallowedHostIsRefused);
  Test('a redirect within the allowlist is followed',
    TestRedirectWithinAllowedHostsSucceeds);
  Test('deny refuses a name that resolves to loopback before connecting',
    TestDenyRefusesResolvedLoopbackBeforeConnect);
  Test('deny refuses non-global IPv4, mapped IPv6 and link-local literals',
    TestDenyRefusesNonGlobalLiteralsBeforeConnect);
  {$IFDEF HTTPCLIENT_TESTING}
  Test('every IPv4 registry block classifies at and beyond its boundaries',
    TestIPv4RegistryBlockBoundaries);
  Test('globally reachable IPv4 exceptions and neighbours classify correctly',
    TestIPv4GlobalExceptionsAndNeighbours);
  Test('every IPv6 registry block classifies at and beyond its boundaries',
    TestIPv6RegistryBlockBoundaries);
  Test('IPv4-mapped, compatible and NAT64 spellings classify as their IPv4',
    TestIPv4EmbeddingSpellingsAreCanonical);
  Test('non-literal and malformed text is never global',
    TestNonLiteralTextIsNotGlobal);
  Test('the host allowlist matches exact names case-insensitively',
    TestHostAllowlistMatching);
  Test('a public destination dials the checked address under its host name',
    TestPublicDestinationDialsTheCheckedAddress);
  Test('deny refuses a redirect from a public host into private space',
    TestDenyRefusesRedirectIntoPrivateAddress);
  Test('an expanded IPv4-mapped IPv6 redirect cannot reach loopback',
    TestExpandedMappedIPv6RedirectCannotReachLoopback);
  {$ENDIF}
end;

begin
  {$IFDEF UNIX}
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}
  if (ParamCount = 2) and (ParamStr(1) = MOCK_LIFECYCLE_CHILD) then
  begin
    RunMockLifecycleChild(ParamStr(2));
    Halt(0);
  end;
  {$IFNDEF UNIX}
  {$IFNDEF MSWINDOWS}
  WriteLn('HTTPClient.Test skipped: no supported mock-server socket backend');
  Halt(0);
  {$ENDIF}
  {$ENDIF}
  TestRunnerProgram.AddSuite(THTTPMockServerLifecycle.Create(
    'HTTP mock server: lifecycle'));
  TestRunnerProgram.AddSuite(THTTPClientByteFetch.Create(
    'HTTPClient: binary-fetch regression'));
  TestRunnerProgram.AddSuite(THTTPClientResourceBounds.Create(
    'HTTPClient: resource bounds'));
  TestRunnerProgram.AddSuite(THTTPClientRequestBodies.Create(
    'HTTPClient: request bodies'));
  TestRunnerProgram.AddSuite(THTTPClientDestinationPolicy.Create(
    'HTTPClient: destination policy'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
