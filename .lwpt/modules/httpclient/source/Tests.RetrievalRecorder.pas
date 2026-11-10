{ Tests.RetrievalRecorder — HTTP endpoint that counts certificate URL
  fetches from this host.

  The client-options tests use fixture leaves whose AIA issuer, OCSP, and
  CRL URLs all point at the recorder. The recorder answers every request
  with an uncacheable 404 and counts the loopback connections it accepted,
  so a test can prove that a chain evaluation made no retrieval (zero
  requests) and that the same endpoint is observable when retrieval is
  allowed (at least one request). It listens where one of two leaves
  points:

  - rreLoopbackPort, http://127.0.0.1:6741/ (localhost-loopback-aia), bound
    on 127.0.0.1 only.
  - rreLocalhostDefaultPort, http://localhost/ (localhost-default-port-aia),
    macOS only. On macOS 26.7.2 trustd refused to fetch the CA-issuer URL
    of a leaf when the URL named a local endpoint by IP literal or on a
    non-default port, logging "skipping SSRF-denied destination"; of the
    local shapes tried, only a host name on port 80 was still fetched. macOS
    lets an unprivileged process bind port 80 on the wildcard address but
    refuses a loopback address with EACCES (observed on 26.5.2), so this
    endpoint binds [::]:80 dual-stack (localhost may resolve to ::1 or
    127.0.0.1) and counts only connections from a loopback peer; any other
    peer is closed uncounted.
    Port 80 must therefore be free while the test runs, and a host firewall
    may ask once to let the test program accept connections.

  Port 6741 is fixed because it is baked into the certificate, so it sits
  below every supported platform's default ephemeral range: Linux
  32768-60999, Windows and macOS 49152-65535, and FreeBSD 10000-65535.
  Inside such a range, any outbound loopback connection a concurrent test
  program opens can be auto-bound to the port and refuse the listener with
  EADDRINUSE, and SO_REUSEADDR cannot override a socket that lacks it. 6741
  is also unassigned by IANA and clear of common unregistered services. A
  host can still make it unavailable: an existing listener, an explicit
  Windows port exclusion or persistent reservation, or an ephemeral range
  reconfigured below it (Windows, Linux, and macOS all allow that). Create
  retries a bind refused with EADDRINUSE for a bounded time, then raises
  with the operating-system error.

  BSD sockets on Unix and WinSock2 on Windows. }

unit Tests.RetrievalRecorder;

{$mode delphi}{$H+}

interface

uses
  Classes,
  SysUtils
  {$IFDEF UNIX}, BaseUnix, Sockets {$ENDIF}
  {$IFDEF MSWINDOWS}, WinSock2 {$ENDIF};

const
  RETRIEVAL_RECORDER_PORT = 6741;
  { The port of the localhost-default-port-aia URLs, which name no port. }
  RETRIEVAL_RECORDER_DEFAULT_HTTP_PORT = 80;
  { How long Create retries a bind refused because the port is in use. }
  RETRIEVAL_RECORDER_BIND_MILLISECONDS = 5000;

type
  ERetrievalRecorderError = class(Exception);

  { Where the recorder listens; each matches one fixture leaf's URLs. }
  TRetrievalRecorderEndpoint = (rreLoopbackPort, rreLocalhostDefaultPort);

  TRetrievalRecorder = class(TThread)
  private
    FEndpoint: TRetrievalRecorderEndpoint;
    FListenSocket: TSocket;
    FRequests: LongInt;
    FRequestLines: TStringList;
    FLock: TRTLCriticalSection;
    {$IFDEF MSWINDOWS}
    FWinSockStarted: Boolean;
    {$ENDIF}
    procedure Serve(const ASocket: TSocket);
  protected
    procedure Execute; override;
  public
    constructor Create(
      const AEndpoint: TRetrievalRecorderEndpoint = rreLoopbackPort);
    destructor Destroy; override;
    { Connections accepted so far. }
    function Requests: Integer;
    { Request lines received so far, joined by '; '. }
    function Describe: string;
  end;

implementation

const
  RESPONSE = 'HTTP/1.1 404 Not Found'#13#10 +
    'Cache-Control: no-store'#13#10 +
    'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;
  REQUEST_READ_MILLISECONDS = 2000;

{$IFDEF MSWINDOWS}
const
  INVALID_RECORDER_SOCKET = TSocket(INVALID_SOCKET);
{$ELSE}
const
  INVALID_RECORDER_SOCKET = TSocket(-1);
{$ENDIF}

function RecorderSocketValid(const ASocket: TSocket): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := ASocket <> TSocket(INVALID_SOCKET);
  {$ELSE}
  Result := ASocket >= 0;
  {$ENDIF}
end;

procedure CloseRecorderSocket(var ASocket: TSocket);
begin
  if not RecorderSocketValid(ASocket) then
    Exit;
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(ASocket);
  {$ELSE}
  CloseSocket(ASocket);
  {$ENDIF}
  ASocket := INVALID_RECORDER_SOCKET;
end;

{ Waits up to ATimeoutMilliseconds for ASocket to become readable. }
function RecorderReadable(const ASocket: TSocket;
  const ATimeoutMilliseconds: Integer): Boolean;
var
  ReadSet: TFDSet;
  {$IFDEF MSWINDOWS}
  Timeout: TTimeVal;
  {$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  FillChar(ReadSet, SizeOf(ReadSet), 0);
  ReadSet.fd_count := 1;
  ReadSet.fd_array[0] := ASocket;
  Timeout.tv_sec := ATimeoutMilliseconds div 1000;
  Timeout.tv_usec := (ATimeoutMilliseconds mod 1000) * 1000;
  Result := WinSock2.select(0, @ReadSet, nil, nil, @Timeout) > 0;
  {$ELSE}
  FpFD_ZERO(ReadSet);
  FpFD_SET(ASocket, ReadSet);
  Result := FpSelect(ASocket + 1, @ReadSet, nil, nil,
    ATimeoutMilliseconds) > 0;
  {$ENDIF}
end;

function LastRecorderSocketError: Integer;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.WSAGetLastError;
  {$ELSE}
  Result := SocketError;
  {$ENDIF}
end;

function RecorderAddressInUse(const AError: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := AError = WSAEADDRINUSE;
  {$ELSE}
  Result := AError = ESysEADDRINUSE;
  {$ENDIF}
end;

function RecorderEndpointText(
  const AEndpoint: TRetrievalRecorderEndpoint): string;
begin
  if AEndpoint = rreLocalhostDefaultPort then
    Result := Format('[::]:%d', [RETRIEVAL_RECORDER_DEFAULT_HTTP_PORT])
  else
    Result := Format('127.0.0.1:%d', [RETRIEVAL_RECORDER_PORT]);
end;

{$IFDEF DARWIN}
{ Opens a dual-stack listener on [::]:RETRIEVAL_RECORDER_DEFAULT_HTTP_PORT.
  On failure it returns False with the socket closed, the failing call in
  AStage and its operating-system error in AError. }
function OpenDefaultPortListener(out ASocket: TSocket; out AStage: string;
  out AError: Integer): Boolean;
var
  Address: TInetSockAddr6;
  Flag: LongInt;
begin
  Result := False;
  AError := 0;
  AStage := 'socket()';
  ASocket := FpSocket(AF_INET6, SOCK_STREAM, 0);
  if not RecorderSocketValid(ASocket) then
  begin
    AError := LastRecorderSocketError;
    ASocket := INVALID_RECORDER_SOCKET;
    Exit;
  end;
  Flag := 1;
  FpSetSockOpt(ASocket, SOL_SOCKET, SO_REUSEADDR, @Flag, SizeOf(Flag));
  { localhost resolves to ::1 or 127.0.0.1, so accept both families. }
  Flag := 0;
  AStage := 'setsockopt(IPV6_V6ONLY)';
  if FpSetSockOpt(ASocket, IPPROTO_IPV6, IPV6_V6ONLY, @Flag,
     SizeOf(Flag)) = 0 then
  begin
    FillChar(Address, SizeOf(Address), 0);
    Address.sin6_family := AF_INET6;
    Address.sin6_port := HToNs(RETRIEVAL_RECORDER_DEFAULT_HTTP_PORT);
    AStage := 'bind()';
    if FpBind(ASocket, @Address, SizeOf(Address)) = 0 then
    begin
      AStage := 'listen()';
      Result := FpListen(ASocket, 16) = 0;
    end;
  end;
  if not Result then
  begin
    AError := LastRecorderSocketError;
    CloseRecorderSocket(ASocket);
  end;
end;

{ Whether APeer, as accepted on the dual-stack listener, is ::1 or an
  IPv4-mapped 127.0.0.0/8 address. }
function RecorderPeerIsLoopback(const APeer: TInetSockAddr6): Boolean;
begin
  if APeer.sin6_family <> AF_INET6 then
    Exit(False);
  if (APeer.sin6_addr.u6_addr32[0] <> 0) or
     (APeer.sin6_addr.u6_addr32[1] <> 0) then
    Exit(False);
  if APeer.sin6_addr.u6_addr32[2] = 0 then
    Result := APeer.sin6_addr.u6_addr32[3] = HToNl(1)
  else
    Result := (APeer.sin6_addr.u6_addr32[2] = HToNl($FFFF)) and
      (APeer.sin6_addr.u6_addr8[12] = 127);
end;
{$ENDIF}

{ Opens a listener on 127.0.0.1:RETRIEVAL_RECORDER_PORT. On failure it
  returns False with the socket closed, the failing call in AStage and its
  operating-system error in AError. }
function OpenRecorderListener(out ASocket: TSocket; out AStage: string;
  out AError: Integer): Boolean;
var
  {$IFDEF MSWINDOWS}
  Address: TSockAddrIn;
  {$ELSE}
  Address: TInetSockAddr;
  ReuseAddress: LongInt;
  {$ENDIF}
begin
  Result := False;
  AError := 0;
  AStage := 'socket()';
  {$IFDEF MSWINDOWS}
  ASocket := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  ASocket := FpSocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if not RecorderSocketValid(ASocket) then
  begin
    AError := LastRecorderSocketError;
    ASocket := INVALID_RECORDER_SOCKET;
    Exit;
  end;
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  AStage := 'bind()';
  {$IFDEF MSWINDOWS}
  Address.sin_port := WinSock2.htons(RETRIEVAL_RECORDER_PORT);
  Address.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
  if WinSock2.bind(ASocket, PSockAddr(@Address), SizeOf(Address)) = 0 then
  begin
    AStage := 'listen()';
    Result := WinSock2.listen(ASocket, 16) = 0;
  end;
  {$ELSE}
  { Reruns must not trip over the previous run's TIME_WAIT connections. }
  ReuseAddress := 1;
  FpSetSockOpt(ASocket, SOL_SOCKET, SO_REUSEADDR, @ReuseAddress,
    SizeOf(ReuseAddress));
  Address.sin_port := HToNs(RETRIEVAL_RECORDER_PORT);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if FpBind(ASocket, @Address, SizeOf(Address)) = 0 then
  begin
    AStage := 'listen()';
    Result := FpListen(ASocket, 16) = 0;
  end;
  {$ENDIF}
  if not Result then
  begin
    AError := LastRecorderSocketError;
    CloseRecorderSocket(ASocket);
  end;
end;

{ Opens the listener for AEndpoint, reporting failure as
  OpenRecorderListener does. }
function OpenEndpointListener(const AEndpoint: TRetrievalRecorderEndpoint;
  out ASocket: TSocket; out AStage: string; out AError: Integer): Boolean;
begin
  {$IFDEF DARWIN}
  if AEndpoint = rreLocalhostDefaultPort then
    Exit(OpenDefaultPortListener(ASocket, AStage, AError));
  {$ENDIF}
  Result := OpenRecorderListener(ASocket, AStage, AError);
end;

constructor TRetrievalRecorder.Create(
  const AEndpoint: TRetrievalRecorderEndpoint);
var
  Attempts, ErrorCode: Integer;
  Stage: string;
  StartedAt: QWord;
  {$IFDEF MSWINDOWS}
  WSAData: TWSAData;
  {$ENDIF}
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FEndpoint := AEndpoint;
  InitCriticalSection(FLock);
  FRequestLines := TStringList.Create;
  FListenSocket := INVALID_RECORDER_SOCKET;
  {$IFNDEF DARWIN}
  if AEndpoint = rreLocalhostDefaultPort then
    raise ERetrievalRecorderError.Create(
      'the default-port retrieval recorder is available on macOS only');
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if WinSock2.WSAStartup($0202, WSAData) <> 0 then
    raise ERetrievalRecorderError.Create('WSAStartup failed');
  FWinSockStarted := True;
  {$ENDIF}
  { Another process can hold the port briefly, for example a loopback
    connection that is closing; only that error is worth waiting out. }
  Attempts := 0;
  StartedAt := GetTickCount64;
  repeat
    Inc(Attempts);
    if OpenEndpointListener(AEndpoint, FListenSocket, Stage, ErrorCode) then
      Break;
    if (Stage <> 'bind()') or not RecorderAddressInUse(ErrorCode) or
       (GetTickCount64 - StartedAt >= RETRIEVAL_RECORDER_BIND_MILLISECONDS) then
      raise ERetrievalRecorderError.CreateFmt(
        'retrieval recorder could not listen on %s (the port the fixture ' +
        'certificate''s URLs imply): %s failed with error %d (%s) ' +
        'after %d attempt(s) in %d ms',
        [RecorderEndpointText(AEndpoint), Stage, ErrorCode,
         SysErrorMessage(ErrorCode), Attempts,
         GetTickCount64 - StartedAt]);
    Sleep(100);
  until False;
  Start;
end;

destructor TRetrievalRecorder.Destroy;
begin
  Terminate;
  if not Suspended then
    WaitFor;
  CloseRecorderSocket(FListenSocket);
  FRequestLines.Free;
  DoneCriticalSection(FLock);
  {$IFDEF MSWINDOWS}
  if FWinSockStarted then
    WinSock2.WSACleanup;
  {$ENDIF}
  inherited Destroy;
end;

function TRetrievalRecorder.Requests: Integer;
begin
  Result := InterlockedCompareExchange(FRequests, 0, 0);
end;

function TRetrievalRecorder.Describe: string;
begin
  EnterCriticalSection(FLock);
  try
    Result := StringReplace(Trim(FRequestLines.Text), LineEnding, '; ',
      [rfReplaceAll]);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TRetrievalRecorder.Serve(const ASocket: TSocket);
var
  Buffer: array[0..1023] of Byte;
  Chunk, Request: AnsiString;
  Received: Integer;
  StartedAt: QWord;
begin
  Request := '';
  StartedAt := GetTickCount64;
  while (Pos(#13#10#13#10, Request) = 0) and
        (GetTickCount64 - StartedAt < REQUEST_READ_MILLISECONDS) do
  begin
    if not RecorderReadable(ASocket, 50) then
      Continue;
    {$IFDEF MSWINDOWS}
    Received := WinSock2.recv(ASocket, Buffer, SizeOf(Buffer), 0);
    {$ELSE}
    Received := FpRecv(ASocket, @Buffer[0], SizeOf(Buffer), 0);
    {$ENDIF}
    if Received <= 0 then
      Break;
    SetString(Chunk, PAnsiChar(@Buffer[0]), Received);
    Request := Request + Chunk;
  end;
  EnterCriticalSection(FLock);
  try
    if Pos(#13#10, Request) > 0 then
      FRequestLines.Add(string(Copy(Request, 1, Pos(#13#10, Request) - 1)))
    else
      FRequestLines.Add('(incomplete request)');
  finally
    LeaveCriticalSection(FLock);
  end;
  {$IFDEF MSWINDOWS}
  WinSock2.send(ASocket, RESPONSE[1], Length(RESPONSE), 0);
  {$ELSE}
  FpSend(ASocket, @RESPONSE[1], Length(RESPONSE), 0);
  {$ENDIF}
end;

procedure TRetrievalRecorder.Execute;
var
  Accepted: TSocket;
  {$IFDEF DARWIN}
  Peer: TInetSockAddr6;
  PeerLength: TSockLen;
  {$ENDIF}
begin
  while not Terminated do
  begin
    if not RecorderReadable(FListenSocket, 50) then
      Continue;
    {$IF DEFINED(MSWINDOWS)}
    Accepted := WinSock2.accept(FListenSocket, nil, nil);
    {$ELSEIF DEFINED(DARWIN)}
    FillChar(Peer, SizeOf(Peer), 0);
    PeerLength := SizeOf(Peer);
    Accepted := FpAccept(FListenSocket, @Peer, @PeerLength);
    {$ELSE}
    Accepted := FpAccept(FListenSocket, nil, nil);
    {$ENDIF}
    if not RecorderSocketValid(Accepted) then
      Continue;
    {$IFDEF DARWIN}
    { The default-port listener is bound on every address; a connection
      from off the host is not a certificate fetch by this machine. }
    if (FEndpoint = rreLocalhostDefaultPort) and
       not RecorderPeerIsLoopback(Peer) then
    begin
      CloseRecorderSocket(Accepted);
      Continue;
    end;
    {$ENDIF}
    { Counted on accept: a fetch attempt is what matters, and the count is
      final before the fetching evaluation can see the response. }
    InterlockedIncrement(FRequests);
    try
      Serve(Accepted);
    finally
      CloseRecorderSocket(Accepted);
    end;
  end;
end;

end.
