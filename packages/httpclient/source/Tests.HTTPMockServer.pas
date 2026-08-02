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

  The socket backend is native to each supported platform: BSD sockets on
  Unix and WinSock2 on Windows. }

unit Tests.HTTPMockServer;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils
  {$IFDEF UNIX}, Sockets {$ENDIF}
  {$IFDEF MSWINDOWS}, Windows, WinSock2 {$ENDIF};

type
  TByteArrays = array of TBytes;

  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  TMockSocket = TSocket;
  {$ELSE}
  TMockSocket = PtrUInt;
  {$ENDIF}

  EMockServerError = class(Exception);

  TMockServerResourceSnapshot = record
    OpenSockets: Integer;
    LiveThreads: Integer;
    WinSockReferences: Integer;
    ProcessHandles: Integer;
  end;

  TMockHTTPServer = class
  private
    FListenSock: TMockSocket;
    FSilentClientSock: TMockSocket;
    FBytesPerWrite: Integer;
    FInitialDelayMilliseconds: Integer;
    FThread: TThread;
    FWriteDelayMilliseconds: Integer;
    FResponse: TBytes;
    FPort: Word;
    {$IFDEF MSWINDOWS}
    FWinSockStarted: Boolean;
    {$ENDIF}
  public
    constructor Create(const ARawResponse: TBytes); overload;
    constructor Create(const ARawResponse: TBytes;
      const ABytesPerWrite, AWriteDelayMilliseconds,
      AInitialDelayMilliseconds: Integer); overload;
    destructor Destroy; override;
    procedure ConnectWithoutRequest;
    procedure Start;      { launches the background accept-and-serve thread }
    procedure WaitForAccepted;
    procedure WaitDone; overload;   { bounded wait; raises on timeout }
    function WaitDone(const ATimeoutMilliseconds: Cardinal): Boolean; overload;
    property Port: Word read FPort;
  end;

  { Prepares an ephemeral loopback endpoint that refuses a later connection
    without releasing its port for reuse. Unix retains the endpoint in
    TIME_WAIT; Windows reserves the port on 127.0.0.1 and targets 127.0.0.2. }
  TMockRefusedEndpoint = class
  private
    FHost: string;
    FPort: Word;
    {$IFDEF MSWINDOWS}
    FReservationSock: TMockSocket;
    FWinSockStarted: Boolean;
    {$ENDIF}
  public
    constructor Create;
    destructor Destroy; override;
    property Host: string read FHost;
    property Port: Word read FPort;
  end;

{ Helpers for constructing wire-format HTTP responses. Both produce
  bytes that go straight onto the wire — no auto-headers, no implicit
  Content-Length. Tests that want pathological shapes (Content-Length
  lies, missing trailing CRLF, etc.) should construct the bytes by hand. }

function BuildSimpleResponse(const ABody: TBytes): TBytes;
function BuildChunkedResponse(const AChunks: TByteArrays): TBytes;
function GetMockServerResourceSnapshot: TMockServerResourceSnapshot;

implementation

uses
  StrUtils;

const
  CRLF = #13#10;

var
  GMockOpenSockets: Integer = 0;
  GMockLiveThreads: Integer = 0;
  GMockWinSockReferences: Integer = 0;

{$IFDEF MSWINDOWS}
function KernelGetProcessHandleCount(AProcess: THandle;
  var AHandleCount: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetProcessHandleCount';
{$ENDIF}

function GetMockServerResourceSnapshot: TMockServerResourceSnapshot;
{$IFDEF MSWINDOWS}
var
  ProcessHandleCount: DWORD;
{$ENDIF}
begin
  Result.OpenSockets := GMockOpenSockets;
  Result.LiveThreads := GMockLiveThreads;
  Result.WinSockReferences := GMockWinSockReferences;
  {$IFDEF MSWINDOWS}
  if not KernelGetProcessHandleCount(Windows.GetCurrentProcess,
    ProcessHandleCount) then
    RaiseLastOSError;
  Result.ProcessHandles := ProcessHandleCount;
  {$ELSE}
  Result.ProcessHandles := 0;
  {$ENDIF}
end;

{$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
const
  MOCK_SHUTDOWN_BOTH = 2;

function InvalidMockSocket: TSocket;
begin
  {$IFDEF UNIX}
  Result := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := INVALID_SOCKET;
  {$ENDIF}
end;

function IsValidMockSocket(const ASocket: TSocket): Boolean;
begin
  {$IFDEF UNIX}
  Result := ASocket >= 0;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := ASocket <> INVALID_SOCKET;
  {$ENDIF}
end;

procedure TrackMockSocketOpened;
begin
  InterlockedIncrement(GMockOpenSockets);
end;

procedure CloseTrackedMockSocket(var ASocket: TSocket);
var
  SocketToClose: TSocket;
begin
  if not IsValidMockSocket(ASocket) then Exit;
  SocketToClose := ASocket;
  ASocket := InvalidMockSocket;
  {$IFDEF UNIX}
  CloseSocket(SocketToClose);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(SocketToClose);
  {$ENDIF}
  InterlockedDecrement(GMockOpenSockets);
end;

procedure ShutdownMockSocket(const ASocket: TSocket);
begin
  if not IsValidMockSocket(ASocket) then Exit;
  {$IFDEF UNIX}
  fpShutdown(ASocket, MOCK_SHUTDOWN_BOTH);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2.shutdown(ASocket, MOCK_SHUTDOWN_BOTH);
  {$ENDIF}
end;

function ConnectLoopback(const APort: Word;
  const AHost: string = '127.0.0.1'): TSocket;
{$IFDEF UNIX}
var
  Addr: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if not IsValidMockSocket(Result) then Exit;
  TrackMockSocketOpened;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr := StrToNetAddr(AHost);
  if fpConnect(Result, @Addr, SizeOf(Addr)) <> 0 then
    CloseTrackedMockSocket(Result);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Addr: TSockAddrIn;
begin
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  if not IsValidMockSocket(Result) then Exit;
  TrackMockSocketOpened;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := WinSock2.htons(APort);
  Addr.sin_addr.S_addr := WinSock2.inet_addr(PAnsiChar(AnsiString(AHost)));
  if WinSock2.connect(Result, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
    CloseTrackedMockSocket(Result);
end;
{$ENDIF}
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure CleanupTrackedWinSock(var AStarted: Boolean);
begin
  if not AStarted then Exit;
  WinSock2.WSACleanup;
  AStarted := False;
  InterlockedDecrement(GMockWinSockReferences);
end;
{$ENDIF}

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

{$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
type
  TMockServerThread = class(TThread)
  private
    FCriticalSection: TRTLCriticalSection;
    FListenSock: TSocket;
    FClientSock: TSocket;
    FAccepted: LongInt;
    FBytesPerWrite: Integer;
    FInitialDelayMilliseconds: Integer;
    FPort: Word;
    FResponse: TBytes;
    FWriteDelayMilliseconds: Integer;
    procedure CloseOwnedSockets;
  protected
    procedure Execute; override;
  public
    constructor Create(AListenSock: TSocket; const APort: Word;
      const AResponse: TBytes;
      const ABytesPerWrite, AWriteDelayMilliseconds,
      AInitialDelayMilliseconds: Integer);
    destructor Destroy; override;
    procedure Stop;
    function WaitForAccepted(const ATimeoutMilliseconds: Cardinal): Boolean;
  end;

constructor TMockServerThread.Create(AListenSock: TSocket;
  const APort: Word; const AResponse: TBytes;
  const ABytesPerWrite, AWriteDelayMilliseconds,
  AInitialDelayMilliseconds: Integer);
begin
  InitCriticalSection(FCriticalSection);
  try
    inherited Create(True);   { suspended; caller invokes Start }
  except
    DoneCriticalSection(FCriticalSection);
    raise;
  end;
  FListenSock := AListenSock;
  FClientSock := InvalidMockSocket;
  FAccepted := 0;
  FPort := APort;
  FResponse := AResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;
  FreeOnTerminate := False;
  InterlockedIncrement(GMockLiveThreads);
end;

destructor TMockServerThread.Destroy;
begin
  CloseOwnedSockets;
  DoneCriticalSection(FCriticalSection);
  InterlockedDecrement(GMockLiveThreads);
  inherited Destroy;
end;

procedure TMockServerThread.CloseOwnedSockets;
var
  ClientSock, ListenSock: TSocket;
begin
  EnterCriticalSection(FCriticalSection);
  try
    ClientSock := FClientSock;
    FClientSock := InvalidMockSocket;
    ListenSock := FListenSock;
    FListenSock := InvalidMockSocket;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  CloseTrackedMockSocket(ClientSock);
  CloseTrackedMockSocket(ListenSock);
end;

procedure TMockServerThread.Stop;
var
  ClientSock, ListenSock, WakeSock: TSocket;
begin
  Terminate;
  EnterCriticalSection(FCriticalSection);
  try
    ClientSock := FClientSock;
    ListenSock := FListenSock;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;

  if IsValidMockSocket(ClientSock) then
  begin
    { Cancel the blocking receive without closing a descriptor that Execute
      may still be using. Execute retains ownership and closes the accepted
      socket from its finally block after the I/O call returns. }
    ShutdownMockSocket(ClientSock);
  end
  else if
    IsValidMockSocket(ListenSock) then
  begin
    WakeSock := ConnectLoopback(FPort);
    CloseTrackedMockSocket(WakeSock);
  end;
end;

function TMockServerThread.WaitForAccepted(
  const ATimeoutMilliseconds: Cardinal): Boolean;
var
  StartedAt: QWord;
begin
  StartedAt := GetTickCount64;
  while InterlockedCompareExchange(FAccepted, 0, 0) = 0 do
  begin
    if GetTickCount64 - StartedAt >= ATimeoutMilliseconds then Exit(False);
    Sleep(1);
  end;
  Result := True;
end;

procedure TMockServerThread.Execute;
var
  ClientSock: TSocket;
  {$IFDEF UNIX}
  ClientAddr: TInetSockAddr;
  ClientAddrLen: TSocklen;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ClientAddr: TSockAddrIn;
  ClientAddrLen: Longint;
  {$ENDIF}
  Buf: array[0..4095] of Byte;
  Total, Sent, SendLength, N: Integer;
  P: PByte;
begin
  try
    ClientAddrLen := SizeOf(ClientAddr);
    {$IFDEF UNIX}
    ClientSock := fpAccept(FListenSock, @ClientAddr, @ClientAddrLen);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    ClientSock := WinSock2.accept(FListenSock, PSockAddr(@ClientAddr),
      @ClientAddrLen);
    {$ENDIF}
    if not IsValidMockSocket(ClientSock) then Exit;
    TrackMockSocketOpened;
    EnterCriticalSection(FCriticalSection);
    try
      FClientSock := ClientSock;
      InterlockedExchange(FAccepted, 1);
    finally
      LeaveCriticalSection(FCriticalSection);
    end;
    if Terminated then Exit;

    { Drain whatever the client wrote (the HTTP request line + headers).
      We don't care about the contents — the test pre-configured the
      response. One recv up to the buffer size is enough for our use:
      lwpt's HTTPClient sends short GET requests well under 4 KB. }
    {$IFDEF UNIX}
    N := fpRecv(ClientSock, @Buf, SizeOf(Buf), 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    N := WinSock2.recv(ClientSock, @Buf, SizeOf(Buf), 0);
    {$ENDIF}
    if N < 0 then N := 0;
    if Terminated then Exit;

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
      {$IFDEF UNIX}
      N := fpSend(ClientSock, P + Sent, SendLength, 0);
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      N := WinSock2.send(ClientSock, P + Sent, SendLength, 0);
      {$ENDIF}
      if N <= 0 then Break;
      Inc(Sent, N);
      if (Sent < Total) and (FWriteDelayMilliseconds > 0) then
        Sleep(FWriteDelayMilliseconds);
    end;
  finally
    CloseOwnedSockets;
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
  FListenSock := InvalidMockSocket;
  FSilentClientSock := InvalidMockSocket;

  FListenSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenSock < 0 then
    raise EMockServerError.Create('socket() failed');
  TrackMockSocketOpened;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;   { kernel picks an ephemeral port }
  Loopback := StrToNetAddr('127.0.0.1');
  Addr.sin_addr := Loopback;

  if fpBind(FListenSock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    raise EMockServerError.Create('bind() failed');
  end;

  if fpListen(FListenSock, 1) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    raise EMockServerError.Create('listen() failed');
  end;

  AddrLen := SizeOf(Addr);
  if fpGetsockname(FListenSock, @Addr, @AddrLen) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    raise EMockServerError.Create('getsockname() failed');
  end;

  FPort := ntohs(Addr.sin_port);
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Addr: TSockAddrIn;
  AddrLen: Longint;
  WSAData: TWSAData;
begin
  FResponse := ARawResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;

  FListenSock := INVALID_SOCKET;
  FSilentClientSock := INVALID_SOCKET;
  if WinSock2.WSAStartup($0202, WSAData) <> 0 then
    raise EMockServerError.Create('WSAStartup failed');
  FWinSockStarted := True;
  InterlockedIncrement(GMockWinSockReferences);

  FListenSock := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  if FListenSock = INVALID_SOCKET then
  begin
    CleanupTrackedWinSock(FWinSockStarted);
    raise EMockServerError.Create('socket() failed');
  end;
  TrackMockSocketOpened;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;   { kernel picks an ephemeral port }
  Addr.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');

  if WinSock2.bind(FListenSock, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    CleanupTrackedWinSock(FWinSockStarted);
    raise EMockServerError.Create('bind() failed');
  end;

  if WinSock2.listen(FListenSock, 1) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    CleanupTrackedWinSock(FWinSockStarted);
    raise EMockServerError.Create('listen() failed');
  end;

  AddrLen := SizeOf(Addr);
  if WinSock2.getsockname(FListenSock, PSockAddr(@Addr)^, AddrLen) <> 0 then
  begin
    CloseTrackedMockSocket(FListenSock);
    CleanupTrackedWinSock(FWinSockStarted);
    raise EMockServerError.Create('getsockname() failed');
  end;

  FPort := WinSock2.ntohs(Addr.sin_port);
end;
{$ENDIF}
{$IFNDEF UNIX}
{$IFNDEF MSWINDOWS}
begin
  FResponse := ARawResponse;
  FBytesPerWrite := ABytesPerWrite;
  FWriteDelayMilliseconds := AWriteDelayMilliseconds;
  FInitialDelayMilliseconds := AInitialDelayMilliseconds;
  raise EMockServerError.Create(
    'Tests.HTTPMockServer requires Unix sockets or WinSock2');
end;
{$ENDIF}
{$ENDIF}

destructor TMockHTTPServer.Destroy;
begin
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  { A fixture-created silent client is the most reliable cancellation point:
    close the peer first so a blocking server-side recv observes EOF on every
    platform. Stop still owns external clients and the accept-registration
    race. }
  ShutdownMockSocket(FSilentClientSock);
  CloseTrackedMockSocket(FSilentClientSock);
  {$ENDIF}
  if Assigned(FThread) then
  begin
    TMockServerThread(FThread).Stop;
    FThread.WaitFor;
    FThread.Free;
  end;
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  CloseTrackedMockSocket(FListenSock);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  CleanupTrackedWinSock(FWinSockStarted);
  {$ENDIF}
  inherited Destroy;
end;

procedure TMockHTTPServer.ConnectWithoutRequest;
begin
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  if not Assigned(FThread) then
    raise EMockServerError.Create('mock server is not started');
  if IsValidMockSocket(FSilentClientSock) then
    raise EMockServerError.Create('silent mock client is already connected');
  FSilentClientSock := ConnectLoopback(FPort);
  if not IsValidMockSocket(FSilentClientSock) then
    raise EMockServerError.Create('silent mock client failed to connect');
  {$ENDIF}
end;

procedure TMockHTTPServer.Start;
begin
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  if Assigned(FThread) then
    raise EMockServerError.Create('mock server is already started');
  FThread := TMockServerThread.Create(FListenSock, FPort, FResponse,
    FBytesPerWrite, FWriteDelayMilliseconds, FInitialDelayMilliseconds);
  FListenSock := InvalidMockSocket;
  FThread.Start;
  {$ENDIF}
end;

procedure TMockHTTPServer.WaitForAccepted;
begin
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  if not Assigned(FThread) then
    raise EMockServerError.Create('mock server is not started');
  if not TMockServerThread(FThread).WaitForAccepted(2000) then
    raise EMockServerError.Create('mock server did not accept the client');
  {$ENDIF}
end;

procedure TMockHTTPServer.WaitDone;
begin
  if not WaitDone(2000) then
    raise EMockServerError.Create('mock server did not finish within 2000 ms');
end;

function TMockHTTPServer.WaitDone(
  const ATimeoutMilliseconds: Cardinal): Boolean;
var
  StartedAt: QWord;
begin
  if not Assigned(FThread) then Exit(True);
  StartedAt := GetTickCount64;
  while not FThread.Finished do
  begin
    if GetTickCount64 - StartedAt >= ATimeoutMilliseconds then
    begin
      TMockServerThread(FThread).Stop;
      Exit(False);
    end;
    Sleep(1);
  end;
  FThread.WaitFor;
  Result := True;
end;

constructor TMockRefusedEndpoint.Create;
var
  ListenSock, ClientSock, AcceptedSock, ProbeSock: TMockSocket;
  Received: Integer;
  OneByte: Byte;
  {$IFDEF UNIX}
  Addr: TInetSockAddr;
  AddrLen: TSocklen;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Addr: TSockAddrIn;
  AddrLen: Longint;
  WSAData: TWSAData;
  {$ENDIF}
begin
  FHost := '127.0.0.1';
  ListenSock := InvalidMockSocket;
  ClientSock := InvalidMockSocket;
  AcceptedSock := InvalidMockSocket;
  ProbeSock := InvalidMockSocket;
  {$IFDEF MSWINDOWS}
  FReservationSock := InvalidMockSocket;
  if WinSock2.WSAStartup($0202, WSAData) <> 0 then
    raise EMockServerError.Create('WSAStartup failed');
  FWinSockStarted := True;
  InterlockedIncrement(GMockWinSockReferences);
  {$ENDIF}
  try
    {$IFDEF UNIX}
    ListenSock := fpSocket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    ListenSock := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    if not IsValidMockSocket(ListenSock) then
      raise EMockServerError.Create('socket() failed');
    TrackMockSocketOpened;

    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := 0;
    {$IFDEF UNIX}
    Addr.sin_addr := StrToNetAddr('127.0.0.1');
    if fpBind(ListenSock, @Addr, SizeOf(Addr)) <> 0 then
      raise EMockServerError.Create('bind() failed');
    if fpListen(ListenSock, 1) <> 0 then
      raise EMockServerError.Create('listen() failed');
    AddrLen := SizeOf(Addr);
    if fpGetsockname(ListenSock, @Addr, @AddrLen) <> 0 then
      raise EMockServerError.Create('getsockname() failed');
    FPort := ntohs(Addr.sin_port);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Addr.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
    if WinSock2.bind(ListenSock, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
      raise EMockServerError.Create('bind() failed');
    if WinSock2.listen(ListenSock, 1) <> 0 then
      raise EMockServerError.Create('listen() failed');
    AddrLen := SizeOf(Addr);
    if WinSock2.getsockname(ListenSock, PSockAddr(@Addr)^, AddrLen) <> 0 then
      raise EMockServerError.Create('getsockname() failed');
    FPort := WinSock2.ntohs(Addr.sin_port);
    {$ENDIF}

    {$IFDEF UNIX}
    ClientSock := ConnectLoopback(FPort);
    if not IsValidMockSocket(ClientSock) then
      raise EMockServerError.Create('setup client failed to connect');
    {$IFDEF UNIX}
    AcceptedSock := fpAccept(ListenSock, @Addr, @AddrLen);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    AcceptedSock := WinSock2.accept(ListenSock, PSockAddr(@Addr), @AddrLen);
    {$ENDIF}
    if not IsValidMockSocket(AcceptedSock) then
      raise EMockServerError.Create('setup accept failed');
    TrackMockSocketOpened;

    { The server endpoint closes first. Reading its FIN on the setup client
      and then closing that client leaves the server port in TIME_WAIT. }
    CloseTrackedMockSocket(AcceptedSock);
    {$IFDEF UNIX}
    Received := fpRecv(ClientSock, @OneByte, 1, 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Received := WinSock2.recv(ClientSock, @OneByte, 1, 0);
    {$ENDIF}
    if Received <> 0 then
      raise EMockServerError.Create('setup client did not receive EOF');
    CloseTrackedMockSocket(ClientSock);
    CloseTrackedMockSocket(ListenSock);

    { Fail fast if this platform did not retain the TIME_WAIT refusal state. }
    ProbeSock := ConnectLoopback(FPort);
    if IsValidMockSocket(ProbeSock) then
      raise EMockServerError.Create(
        'loopback port was unexpectedly reusable after active close');
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    { Windows can retain a recently closed loopback connection in a state
      that blackholes the next SYN until the request deadline. Keep the
      OS-assigned port reserved on one numeric loopback address instead and
      target another address in 127.0.0.0/8. The reservation prevents a
      wildcard listener from racing into the port, while the distinct address
      has no listener and therefore rejects the connect immediately. }
    FHost := '127.0.0.2';
    ProbeSock := ConnectLoopback(FPort, FHost);
    if IsValidMockSocket(ProbeSock) then
      raise EMockServerError.Create(
        'secondary loopback address unexpectedly accepted a connection');
    FReservationSock := ListenSock;
    ListenSock := InvalidMockSocket;
    {$ENDIF}
  except
    CloseTrackedMockSocket(ProbeSock);
    CloseTrackedMockSocket(AcceptedSock);
    CloseTrackedMockSocket(ClientSock);
    CloseTrackedMockSocket(ListenSock);
    {$IFDEF MSWINDOWS}
    CleanupTrackedWinSock(FWinSockStarted);
    {$ENDIF}
    raise;
  end;
end;

destructor TMockRefusedEndpoint.Destroy;
begin
  {$IFDEF MSWINDOWS}
  CloseTrackedMockSocket(FReservationSock);
  CleanupTrackedWinSock(FWinSockStarted);
  {$ENDIF}
  inherited Destroy;
end;

end.
