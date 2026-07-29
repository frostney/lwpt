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
  {$ENDIF}
  Classes,
  SysUtils,
  TestingPascalLibrary,
  HTTPClient,
  Tests.HTTPMockServer;

type
  THTTPClientByteFetch = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSimpleResponseBodyStartsWithNul;
    procedure TestSimpleResponseBodyInterspersedNul;
    procedure TestChunkedResponseChunkStartsWithNul;
    procedure TestChunkedResponseMultipleChunksWithNul;
    procedure TestLargeBodyForcesMultiRecv;
  end;

  { Bounded-failure contract. Both cases are shapes a well-behaved peer
    never produces and a broken or hostile one does: a fixed-length body
    cut short mid-transfer, and a peer that accepts the connection then
    says nothing. Before these, the first returned a zero-padded buffer
    that looked like a complete body, and the second blocked forever. }
  THTTPClientBoundedFailures = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestFixedLengthEarlyCloseRaises;
    procedure TestFixedLengthEarlyCloseNamesTheShortfall;
    procedure TestCompleteFixedLengthBodyStillSucceeds;
    procedure TestStalledPeerFailsWithinTheArmedBudget;
    procedure TestTimeoutIsDisabledByDefault;
  end;

{ ── helpers ───────────────────────────────────────────────────────── }

function MockURL(APort: Word): string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(APort) + '/x';
end;

function ServeAndFetch(const ARawResponse: TBytes): TBytes;
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

{ ── THTTPClientBoundedFailures ────────────────────────────────────── }

{ Built by hand rather than through BuildSimpleResponse, which always
  declares a truthful Content-Length. The declared length deliberately
  exceeds what is written to the wire, and the mock closes the socket
  once its bytes are gone. That is the fixed-length early-close shape. }
function BuildShortFixedLengthResponse(const ASentBody: TBytes;
  const ADeclaredLength: Integer): TBytes;
const
  CRLF = #13#10;
var
  Head: TBytes;
begin
  Head := BytesOf('HTTP/1.1 200 OK' + CRLF
    + 'Content-Type: application/octet-stream' + CRLF
    + 'Content-Length: ' + IntToStr(ADeclaredLength) + CRLF
    + 'Connection: close' + CRLF
    + CRLF);
  SetLength(Result, Length(Head) + Length(ASentBody));
  if Length(Head) > 0 then Move(Head[0], Result[0], Length(Head));
  if Length(ASentBody) > 0 then
    Move(ASentBody[0], Result[Length(Head)], Length(ASentBody));
end;

{ Serve ARawResponse and return the error text, or '' when the fetch
  succeeded. }
function ServeAndCaptureError(const ARawResponse: TBytes): string;
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
      HTTPGet(MockURL(Mock.Port), NoHeaders);
    except
      on E: EHTTPError do Result := E.Message;
    end;
    Mock.WaitDone;
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientBoundedFailures.TestFixedLengthEarlyCloseRaises;
var
  Message: string;
begin
  { Declares 4096 bytes, sends 16, then closes. }
  Message := ServeAndCaptureError(BuildShortFixedLengthResponse(
    MakeBytes([$1F, $8B, $08, $00, $00, $00, $00, $00,
               $00, $03, $AA, $BB, $CC, $DD, $EE, $FF]), 4096));
  Expect<Boolean>(Message <> '').ToBe(True);
end;

procedure THTTPClientBoundedFailures.TestFixedLengthEarlyCloseNamesTheShortfall;
var
  Message: string;
begin
  { The message has to carry both numbers: "the body was short" is not
    actionable, "16 of 4096" says how short and rules out an off-by-one
    read as the explanation. }
  Message := ServeAndCaptureError(BuildShortFixedLengthResponse(
    MakeBytes([$1F, $8B, $08, $00, $00, $00, $00, $00,
               $00, $03, $AA, $BB, $CC, $DD, $EE, $FF]), 4096));
  Expect<Boolean>(Pos('truncated fixed-length body', Message) > 0).ToBe(True);
  Expect<Boolean>(Pos('16', Message) > 0).ToBe(True);
  Expect<Boolean>(Pos('4096', Message) > 0).ToBe(True);
end;

procedure THTTPClientBoundedFailures.TestCompleteFixedLengthBodyStillSucceeds;
var
  Body: TBytes;
begin
  { The guard must fire on a short transfer only. A truthful
    Content-Length is the overwhelmingly common case and must be
    completely unaffected. }
  Body := MakeBytes([$00, $01, $02, $03, $04, $05, $06, $07]);
  Expect<string>(BytesToHex(ServeAndFetch(BuildSimpleResponse(Body))))
    .ToBe(BytesToHex(Body));
end;

procedure THTTPClientBoundedFailures.TestStalledPeerFailsWithinTheArmedBudget;
var
  Mock: TMockHTTPServer;
  NoHeaders: THTTPHeaders;
  Message: string;
  Elapsed: QWord;
const
  BUDGET_MS = 250;
  { Generous ceiling: the assertion is "bounded", not "precisely 250 ms".
    Scheduler noise on a loaded CI runner must not turn this red. }
  CEILING_MS = 15000;
begin
  { Create binds and listens but does not accept until Start, which is
    never called here. The connect completes into the kernel's backlog,
    the request goes out, and no byte ever comes back. That is the
    stall this budget exists to bound. }
  Mock := TMockHTTPServer.Create(nil);
  try
    Message := '';
    NoHeaders := nil;
    SetPlainTransportTimeout(BUDGET_MS);
    try
      Elapsed := GetTickCount64;
      try
        HTTPGet(MockURL(Mock.Port), NoHeaders);
      except
        on E: EHTTPError do Message := E.Message;
      end;
      Elapsed := GetTickCount64 - Elapsed;
    finally
      SetPlainTransportTimeout(PLAIN_TRANSPORT_TIMEOUT_DISABLED);
    end;
    Expect<Boolean>(Pos('timed out', Message) > 0).ToBe(True);
    Expect<Boolean>(Elapsed < CEILING_MS).ToBe(True);
  finally
    Mock.Free;
  end;
end;

procedure THTTPClientBoundedFailures.TestTimeoutIsDisabledByDefault;
begin
  { Every existing caller gets the historical blocking behaviour until
    it opts in, and the case above must leave nothing armed behind it. }
  Expect<Integer>(PlainTransportTimeout)
    .ToBe(PLAIN_TRANSPORT_TIMEOUT_DISABLED);
end;

procedure THTTPClientBoundedFailures.SetupTests;
begin
  Test('fixed-length early close is reported instead of zero-padded',
    TestFixedLengthEarlyCloseRaises);
  Test('fixed-length early close names received and declared lengths',
    TestFixedLengthEarlyCloseNamesTheShortfall);
  Test('a truthful Content-Length body still round-trips',
    TestCompleteFixedLengthBodyStillSucceeds);
  Test('a stalled peer fails inside the armed read budget',
    TestStalledPeerFailsWithinTheArmedBudget);
  Test('the read budget is disabled unless a caller arms it',
    TestTimeoutIsDisabledByDefault);
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
end;

begin
  {$IFNDEF UNIX}
  WriteLn(
    'HTTPClient.Test skipped on this platform (mock server is Unix-only ' +
    'in v1; Windows path lands in a later cycle). Exiting 0 to keep the test gate green.');
  Halt(0);
  {$ENDIF}

  TestRunnerProgram.AddSuite(THTTPClientByteFetch.Create(
    'HTTPClient: binary-fetch regression'));
  TestRunnerProgram.AddSuite(THTTPClientBoundedFailures.Create(
    'HTTPClient: bounded failure modes'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
