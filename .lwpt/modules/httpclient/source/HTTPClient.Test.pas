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
    procedure TestCloseDelimitedBodyOverLimit;
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

procedure THTTPMockServerLifecycle.SetupTests;
begin
  Test('started server without a client tears down inside the watchdog',
    TestStartedUnconnectedTeardownIsBounded);
  Test('connected silent client tears down inside the watchdog',
    TestConnectedSilentTeardownIsBounded);
  Test('success, failure, and unstarted cycles balance fixture resources',
    TestRepeatedCyclesBalanceResources);
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
  Test('close-delimited body over limit fails',
    TestCloseDelimitedBodyOverLimit);
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
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
