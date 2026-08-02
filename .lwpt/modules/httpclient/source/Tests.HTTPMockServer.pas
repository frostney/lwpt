{ Tests.HTTPMockServer — ephemeral-port HTTP server for the HTTPClient
  regression test.

  The mock binds to 127.0.0.1 on an OS-assigned port, accepts ONE
  connection in a background thread, sends a caller-supplied raw
  response, closes the socket, and dies. The whole thing exists so the
  HTTPClient byte-truncation regression test can craft pathological
  responses (embedded #0 bytes in body, chunked encoding with #0 in
  chunk data) deterministically — what makes HTTPClient.pas's
  byte-safe AppendRawBytes accumulator a verified fix rather than a
  guess.

  Caller pattern:

    Response := BuildSimpleResponse(BytesOf(#0#1#2#3'ABCD'));
    Mock := TMockHTTPServer.Create(Response);
    try
      Mock.Start;
      HttpResp := HTTPGet('http://127.0.0.1:' + IntToStr(Mock.Port) + '/x', nil);
      Mock.WaitDone;
      { assert on HttpResp.Body }
    finally
      Mock.Free;
    end;

  Status: Unix-only for v1. A later cycle will add the WinSock path when CI
  starts running this against Windows. }

unit Tests.HTTPMockServer;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils
  {$IFDEF UNIX}, Sockets {$ENDIF};

type
  TByteArrays = array of TBytes;

  EMockServerError = class(Exception);

  TMockHTTPServer = class
  private
    {$IFDEF UNIX}
    FListenSock: TSocket;
    {$ENDIF}
    FBytesPerWrite: Integer;
    FInitialDelayMilliseconds: Integer;
    FThread: TThread;
    FWriteDelayMilliseconds: Integer;
    FResponse: TBytes;
    FPort: Word;
  public
    constructor Create(const ARawResponse: TBytes); overload;
    constructor Create(const ARawResponse: TBytes;
      const ABytesPerWrite, AWriteDelayMilliseconds,
      AInitialDelayMilliseconds: Integer); overload;
    destructor Destroy; override;
    procedure Start;      { launches the background accept-and-serve thread }
    procedure WaitDone;   { blocks until the thread finishes }
    property Port: Word read FPort;
  end;

{ Helpers for constructing wire-format HTTP responses. Both produce
  bytes that go straight onto the wire — no auto-headers, no implicit
  Content-Length. Tests that want pathological shapes (Content-Length
  lies, missing trailing CRLF, etc.) should construct the bytes by hand. }

function BuildSimpleResponse(const ABody: TBytes): TBytes;
function BuildChunkedResponse(const AChunks: TByteArrays): TBytes;

implementation

uses
  StrUtils;

const
  CRLF = #13#10;

{ ── byte-buffer helpers ───────────────────────────────────────────── }

function ConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function StringBytes(const S: string): TBytes;
begin
  Result := BytesOf(S);
end;

function HexLower(const N: Integer): string;
const Hex = '0123456789abcdef';
var V: Integer;
begin
  if N = 0 then Exit('0');
  Result := '';
  V := N;
  while V > 0 do
  begin
    Result := Hex[(V and $F) + 1] + Result;
    V := V shr 4;
  end;
end;

{ ── response builders ─────────────────────────────────────────────── }

function BuildSimpleResponse(const ABody: TBytes): TBytes;
var Head: string;
begin
  Head := 'HTTP/1.1 200 OK' + CRLF
        + 'Content-Type: application/octet-stream' + CRLF
        + 'Content-Length: ' + IntToStr(Length(ABody)) + CRLF
        + 'Connection: close' + CRLF
        + CRLF;
  Result := ConcatBytes(StringBytes(Head), ABody);
end;

function BuildChunkedResponse(const AChunks: TByteArrays): TBytes;
var
  Head: string;
  i: Integer;
begin
  Head := 'HTTP/1.1 200 OK' + CRLF
        + 'Content-Type: application/octet-stream' + CRLF
        + 'Transfer-Encoding: chunked' + CRLF
        + 'Connection: close' + CRLF
        + CRLF;
  Result := StringBytes(Head);
  for i := 0 to High(AChunks) do
  begin
    Result := ConcatBytes(Result,
      StringBytes(HexLower(Length(AChunks[i])) + CRLF));
    Result := ConcatBytes(Result, AChunks[i]);
    Result := ConcatBytes(Result, StringBytes(CRLF));
  end;
  Result := ConcatBytes(Result, StringBytes('0' + CRLF + CRLF));
end;

{ ── thread that serves one request ────────────────────────────────── }

{$IFDEF UNIX}
type
  TMockServerThread = class(TThread)
  private
    FListenSock: TSocket;
    FBytesPerWrite: Integer;
    FInitialDelayMilliseconds: Integer;
    FResponse: TBytes;
    FWriteDelayMilliseconds: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AListenSock: TSocket; const AResponse: TBytes;
      const ABytesPerWrite, AWriteDelayMilliseconds,
      AInitialDelayMilliseconds: Integer);
  end;

constructor TMockServerThread.Create(AListenSock: TSocket;
  const AResponse: TBytes; const ABytesPerWrite, AWriteDelayMilliseconds,
  AInitialDelayMilliseconds: Integer);
begin
  FListenSock := AListenSock;
  FResponse := AResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;
  FreeOnTerminate := False;
  inherited Create(True);   { suspended; caller invokes Start }
end;

procedure TMockServerThread.Execute;
var
  ClientSock: TSocket;
  ClientAddr: TInetSockAddr;
  ClientAddrLen: TSocklen;
  Buf: array[0..4095] of Byte;
  Total, Sent, SendLength, N: Integer;
  P: PByte;
begin
  ClientAddrLen := SizeOf(ClientAddr);
  ClientSock := fpAccept(FListenSock, @ClientAddr, @ClientAddrLen);
  if ClientSock < 0 then Exit;

  try
    { Drain whatever the client wrote (the HTTP request line + headers).
      We don't care about the contents — the test pre-configured the
      response. One recv up to the buffer size is enough for our use:
      lwpt's HTTPClient sends short GET requests well under 4 KB. }
    N := fpRecv(ClientSock, @Buf, SizeOf(Buf), 0);
    if N < 0 then N := 0;

    if FInitialDelayMilliseconds > 0 then
      Sleep(FInitialDelayMilliseconds);

    { Send the configured response bytes. Loop until all are out, since
      send() on a TCP socket may return short writes for large buffers. }
    Total := Length(FResponse);
    Sent := 0;
    if Total > 0 then
      P := PByte(@FResponse[0])
    else
      P := nil;
    while Sent < Total do
    begin
      SendLength := Total - Sent;
      if (FBytesPerWrite > 0) and (SendLength > FBytesPerWrite) then
        SendLength := FBytesPerWrite;
      N := fpSend(ClientSock, P + Sent, SendLength, 0);
      if N <= 0 then Break;
      Inc(Sent, N);
      if (Sent < Total) and (FWriteDelayMilliseconds > 0) then
        Sleep(FWriteDelayMilliseconds);
    end;
  finally
    CloseSocket(ClientSock);
  end;
end;
{$ENDIF}

{ ── TMockHTTPServer ───────────────────────────────────────────────── }

constructor TMockHTTPServer.Create(const ARawResponse: TBytes);
begin
  Create(ARawResponse, 0, 0, 0);
end;

constructor TMockHTTPServer.Create(const ARawResponse: TBytes;
  const ABytesPerWrite, AWriteDelayMilliseconds,
  AInitialDelayMilliseconds: Integer);
{$IFDEF UNIX}
var
  Addr: TInetSockAddr;
  AddrLen: TSocklen;
  Loopback: in_addr;
begin
  FResponse := ARawResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;

  FListenSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenSock < 0 then
    raise EMockServerError.Create('socket() failed');

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;   { kernel picks an ephemeral port }
  Loopback := StrToNetAddr('127.0.0.1');
  Addr.sin_addr := Loopback;

  if fpBind(FListenSock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(FListenSock);
    raise EMockServerError.Create('bind() failed');
  end;

  if fpListen(FListenSock, 1) <> 0 then
  begin
    CloseSocket(FListenSock);
    raise EMockServerError.Create('listen() failed');
  end;

  AddrLen := SizeOf(Addr);
  if fpGetsockname(FListenSock, @Addr, @AddrLen) <> 0 then
  begin
    CloseSocket(FListenSock);
    raise EMockServerError.Create('getsockname() failed');
  end;

  FPort := ntohs(Addr.sin_port);
end;
{$ELSE}
begin
  FResponse := ARawResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;
  raise EMockServerError.Create(
    'Tests.HTTPMockServer is Unix-only in v1; Windows path lands in a later cycle');
end;
{$ENDIF}

destructor TMockHTTPServer.Destroy;
begin
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FThread.Free;
  end;
  {$IFDEF UNIX}
  if FListenSock <> 0 then
    CloseSocket(FListenSock);
  {$ENDIF}
  inherited Destroy;
end;

procedure TMockHTTPServer.Start;
begin
  {$IFDEF UNIX}
  FThread := TMockServerThread.Create(FListenSock, FResponse,
    FBytesPerWrite, FWriteDelayMilliseconds, FInitialDelayMilliseconds);
  FThread.Start;
  {$ENDIF}
end;

procedure TMockHTTPServer.WaitDone;
begin
  if Assigned(FThread) then
    FThread.WaitFor;
end;

end.
