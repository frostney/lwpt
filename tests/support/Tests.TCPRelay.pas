{ Tests.TCPRelay -- a loopback TCP relay that counts connections.

  Each accepted connection is joined to a new connection to the backend and
  bytes are copied both ways unchanged, so TLS passes through end to end.
  Tests use the accept count to prove how many connections a client made.

  Every wait is bounded and cancellable: the listener is nonblocking and
  polled in short slices, so an accept whose readiness disappeared (a
  connection reset or taken before accept) returns at once instead of
  blocking; accepted sockets are made blocking for the copies; a backend
  connection must be established within
  ConnectTimeoutMilliseconds (the client is closed otherwise), and teardown
  first shuts every socket down, which ends every copy, and only then joins
  the threads. No wake-up connection is needed, so teardown cannot depend on
  allocating one. }
unit Tests.TCPRelay;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  Classes,
  SysUtils;

type
  TTCPRelay = class(TThread)
  private
    FListen: TSocket;
    FPort, FBackend: Word;
    FBackendHost: string;
    FAccepted, FFailedConnects: LongInt;
    FLock: TRTLCriticalSection;
    FSockets: array of TSocket;
    FPumps: TList;
    {$IFDEF MSWINDOWS}
    FWinSockStarted: Boolean;
    {$ENDIF}
    procedure Track(const ASocket: TSocket);
    function ConnectBackend(out ASocket: TSocket): Boolean;
  public
    { Test-only: runs on the relay thread after the listener reported
      readiness and before accept, so a test can take the pending
      connection away. }
    BeforeAccept: TNotifyEvent;
  protected
    procedure Execute; override;
  public
    { Bound on establishing one backend connection. }
    ConnectTimeoutMilliseconds: Cardinal;
    constructor Create(const ABackend: Word; const ABackendHost: string = '127.0.0.1');
    destructor Destroy; override;
    property Port: Word read FPort;
    { The listening socket, for BeforeAccept only. }
    property ListenSocket: TSocket read FListen;
    property Backend: Word read FBackend write FBackend;
    function Accepted: Integer;
    { Backend connections that failed or timed out. }
    function FailedConnects: Integer;
  end;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

const
  POLL_MILLISECONDS = 50;
  {$IFDEF LINUX}
  RELAY_SEND_FLAGS = $4000; { MSG_NOSIGNAL }
  {$ELSE}
  RELAY_SEND_FLAGS = 0;
  {$ENDIF}
  {$IFDEF DARWIN}
  RELAY_SO_NOSIGPIPE = $1022;
  {$ENDIF}

type
  TRelayPump = class(TThread)
  private
    FFrom, FTo: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFrom, ATo: TSocket);
  end;

function RelaySocketValid(const ASocket: TSocket): Boolean;
begin
  {$IFDEF UNIX}
  Result := ASocket >= 0;
  {$ELSE}
  Result := ASocket <> INVALID_SOCKET;
  {$ENDIF}
end;

function NewRelaySocket: TSocket;
{$IFDEF DARWIN}
var
  Enabled: LongInt;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  {$IFDEF DARWIN}
  if RelaySocketValid(Result) then
  begin
    Enabled := 1;
    fpSetSockOpt(Result, SOL_SOCKET, RELAY_SO_NOSIGPIPE, @Enabled, SizeOf(Enabled));
  end;
  {$ENDIF}
end;

function SetRelayBlocking(const ASocket: TSocket; const ABlocking: Boolean): Boolean;
var
  {$IFDEF UNIX}
  Flags: LongInt;
  {$ELSE}
  Mode: u_long;
  {$ENDIF}
begin
  {$IFDEF UNIX}
  Flags := fpFcntl(ASocket, F_GETFL, 0);
  if Flags < 0 then Exit(False);
  if ABlocking then Flags := Flags and not O_NONBLOCK
  else Flags := Flags or O_NONBLOCK;
  Result := fpFcntl(ASocket, F_SETFL, Flags) = 0;
  {$ELSE}
  if ABlocking then Mode := 0 else Mode := 1;
  Result := WinSock2.ioctlsocket(ASocket, LongInt(FIONBIO), Mode) = 0;
  {$ENDIF}
end;

{ Waits up to AMilliseconds for ASocket to become readable (AWrite False)
  or writable (AWrite True). }
function WaitRelaySocket(const ASocket: TSocket; const AWrite: Boolean;
  const AMilliseconds: Cardinal): Boolean;
var
  {$IFDEF UNIX}
  Sets: TFDSet;
  Timeout: TTimeVal;
  {$ELSE}
  Sets: TFDSet;
  Timeout: TTimeVal;
  {$ENDIF}
begin
  Timeout.tv_sec := AMilliseconds div 1000;
  Timeout.tv_usec := (AMilliseconds mod 1000) * 1000;
  {$IFDEF UNIX}
  fpFD_ZERO(Sets);
  fpFD_SET(ASocket, Sets);
  if AWrite then Result := fpSelect(ASocket + 1, nil, @Sets, nil, @Timeout) > 0
  else Result := fpSelect(ASocket + 1, @Sets, nil, nil, @Timeout) > 0;
  {$ELSE}
  FD_ZERO(Sets);
  FD_SET(ASocket, Sets);
  if AWrite then Result := WinSock2.select(0, nil, @Sets, nil, @Timeout) > 0
  else Result := WinSock2.select(0, @Sets, nil, nil, @Timeout) > 0;
  {$ENDIF}
end;

procedure ShutdownRelaySocket(const ASocket: TSocket);
begin
  {$IFDEF UNIX}
  fpShutdown(ASocket, 2);
  {$ELSE}
  WinSock2.shutdown(ASocket, SD_BOTH);
  {$ENDIF}
end;

procedure CloseRelaySocket(const ASocket: TSocket);
begin
  {$IFDEF UNIX}
  CloseSocket(ASocket);
  {$ELSE}
  WinSock2.closesocket(ASocket);
  {$ENDIF}
end;

function RelayAddress(const AHost: string;
  const APort: Word): {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.sin_family := AF_INET;
  {$IFDEF UNIX}
  Result.sin_port := htons(APort);
  Result.sin_addr := StrToNetAddr(AHost);
  {$ELSE}
  Result.sin_port := WinSock2.htons(APort);
  Result.sin_addr.S_addr := WinSock2.inet_addr(PAnsiChar(AnsiString(AHost)));
  {$ENDIF}
end;

constructor TRelayPump.Create(const AFrom, ATo: TSocket);
begin
  FFrom := AFrom;
  FTo := ATo;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TRelayPump.Execute;
var
  Buffer: array[0..16383] of Byte;
  Received, Sent, Offset: Integer;
begin
  repeat
    { Polled, so teardown ends a copy through Terminate on every platform:
      Windows does not wake a receive blocked on a socket that another
      thread shuts down. }
    if Terminated then Exit;
    if not WaitRelaySocket(FFrom, False, POLL_MILLISECONDS) then Continue;
    {$IFDEF UNIX}
    Received := fpRecv(FFrom, @Buffer[0], SizeOf(Buffer), 0);
    {$ELSE}
    Received := WinSock2.recv(FFrom, Buffer[0], SizeOf(Buffer), 0);
    {$ENDIF}
    if Received <= 0 then Break;
    Offset := 0;
    while Offset < Received do
    begin
      {$IFDEF UNIX}
      Sent := fpSend(FTo, @Buffer[Offset], Received - Offset, RELAY_SEND_FLAGS);
      {$ELSE}
      Sent := WinSock2.send(FTo, Buffer[Offset], Received - Offset, 0);
      {$ENDIF}
      if Sent <= 0 then Exit;
      Inc(Offset, Sent);
    end;
  until False;
  { The source ended: pass the end on, so the peer sees the close. }
  {$IFDEF UNIX}
  fpShutdown(FTo, 1);
  {$ELSE}
  WinSock2.shutdown(FTo, SD_SEND);
  {$ENDIF}
end;

constructor TTCPRelay.Create(const ABackend: Word; const ABackendHost: string);
var
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Length_: {$IFDEF UNIX}TSockLen{$ELSE}LongInt{$ENDIF};
  {$IFDEF MSWINDOWS}
  Data: TWSAData;
  {$ENDIF}
begin
  FBackend := ABackend;
  FBackendHost := ABackendHost;
  ConnectTimeoutMilliseconds := 5000;
  FreeOnTerminate := False;
  InitCriticalSection(FLock);
  FPumps := TList.Create;
  {$IFDEF MSWINDOWS}
  if WSAStartup($0202, Data) <> 0 then
    raise Exception.Create('relay WSAStartup failed');
  FWinSockStarted := True;
  {$ENDIF}
  FListen := NewRelaySocket;
  if not RelaySocketValid(FListen) then
    raise Exception.Create('relay socket failed');
  Address := RelayAddress('127.0.0.1', 0);
  Length_ := SizeOf(Address);
  {$IFDEF UNIX}
  if (fpBind(FListen, @Address, SizeOf(Address)) <> 0)
    or (fpListen(FListen, 16) <> 0)
    or (fpGetSockName(FListen, @Address, @Length_) <> 0) then
    raise Exception.Create('relay listen failed');
  FPort := ntohs(Address.sin_port);
  {$ELSE}
  if (WinSock2.bind(FListen, PSockAddr(@Address), SizeOf(Address)) <> 0)
    or (WinSock2.listen(FListen, 16) <> 0)
    or (WinSock2.getsockname(FListen, Address, Length_) <> 0) then
    raise Exception.Create('relay listen failed');
  FPort := WinSock2.ntohs(Address.sin_port);
  {$ENDIF}
  if not SetRelayBlocking(FListen, False) then
    raise Exception.Create('relay listener cannot be made nonblocking');
  inherited Create(False);
end;

procedure TTCPRelay.Track(const ASocket: TSocket);
begin
  EnterCriticalSection(FLock);
  try
    SetLength(FSockets, Length(FSockets) + 1);
    FSockets[High(FSockets)] := ASocket;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TTCPRelay.Accepted: Integer;
begin
  Result := InterlockedCompareExchange(FAccepted, 0, 0);
end;

function TTCPRelay.FailedConnects: Integer;
begin
  Result := InterlockedCompareExchange(FFailedConnects, 0, 0);
end;

{ A nonblocking connection, polled in short slices until it is
  established, fails, times out, or the relay is terminated. }
function TTCPRelay.ConnectBackend(out ASocket: TSocket): Boolean;
var
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Started: QWord;
  SocketError: LongInt;
  ErrorLength: {$IFDEF UNIX}TSockLen{$ELSE}LongInt{$ENDIF};
begin
  Result := False;
  ASocket := NewRelaySocket;
  if not RelaySocketValid(ASocket) then Exit;
  Track(ASocket);
  if not SetRelayBlocking(ASocket, False) then Exit;
  Address := RelayAddress(FBackendHost, FBackend);
  {$IFDEF UNIX}
  fpConnect(ASocket, @Address, SizeOf(Address));
  {$ELSE}
  WinSock2.connect(ASocket, PSockAddr(@Address), SizeOf(Address));
  {$ENDIF}
  Started := GetTickCount64;
  repeat
    if Terminated then Exit;
    if WaitRelaySocket(ASocket, True, POLL_MILLISECONDS) then
    begin
      SocketError := 0;
      ErrorLength := SizeOf(SocketError);
      {$IFDEF UNIX}
      if fpGetSockOpt(ASocket, SOL_SOCKET, SO_ERROR, @SocketError, @ErrorLength) <> 0 then
        Exit;
      {$ELSE}
      if WinSock2.getsockopt(ASocket, SOL_SOCKET, SO_ERROR, PChar(@SocketError),
        ErrorLength) <> 0 then Exit;
      {$ENDIF}
      if SocketError <> 0 then Exit;
      Exit(SetRelayBlocking(ASocket, True));
    end;
  until GetTickCount64 - Started >= ConnectTimeoutMilliseconds;
end;

procedure TTCPRelay.Execute;
var
  Client, Upstream: TSocket;
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Length_: {$IFDEF UNIX}TSockLen{$ELSE}LongInt{$ENDIF};
begin
  while not Terminated do
  begin
    if not WaitRelaySocket(FListen, False, POLL_MILLISECONDS) then Continue;
    if Terminated then Break;
    if Assigned(BeforeAccept) then BeforeAccept(Self);
    Length_ := SizeOf(Address);
    { Nonblocking: a readiness that disappeared gives EAGAIN, not a wait. }
    {$IFDEF UNIX}
    Client := fpAccept(FListen, @Address, @Length_);
    {$ELSE}
    Client := WinSock2.accept(FListen, PSockAddr(@Address), @Length_);
    {$ENDIF}
    if not RelaySocketValid(Client) then Continue;
    InterlockedIncrement(FAccepted);
    Track(Client);
    { Some platforms (BSD, Windows) hand the listener's nonblocking mode to
      accepted sockets; the copies block. }
    if not SetRelayBlocking(Client, True) then
    begin
      ShutdownRelaySocket(Client);
      Continue;
    end;
    if not ConnectBackend(Upstream) then
    begin
      InterlockedIncrement(FFailedConnects);
      ShutdownRelaySocket(Client);
      Continue;
    end;
    FPumps.Add(TRelayPump.Create(Client, Upstream));
    FPumps.Add(TRelayPump.Create(Upstream, Client));
  end;
end;

destructor TTCPRelay.Destroy;
var
  Index: Integer;
begin
  { Cancel first, then join: the listener is shut down, the accept loop
    and a pending backend connection notice Terminated within one poll
    slice, and shut-down sockets end every copy. The listener is closed
    only after the join, so no thread uses a closed handle. }
  Terminate;
  ShutdownRelaySocket(FListen);
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(FSockets) do ShutdownRelaySocket(FSockets[Index]);
  finally
    LeaveCriticalSection(FLock);
  end;
  WaitFor;
  { Sockets added after the first sweep; the copies, now that the relay
    thread no longer adds any, end within one poll slice. }
  for Index := 0 to High(FSockets) do ShutdownRelaySocket(FSockets[Index]);
  for Index := 0 to FPumps.Count - 1 do
  begin
    TRelayPump(FPumps[Index]).Terminate;
    TRelayPump(FPumps[Index]).WaitFor;
    TRelayPump(FPumps[Index]).Free;
  end;
  FPumps.Free;
  for Index := 0 to High(FSockets) do CloseRelaySocket(FSockets[Index]);
  CloseRelaySocket(FListen);
  DoneCriticalSection(FLock);
  {$IFDEF MSWINDOWS}
  if FWinSockStarted then WSACleanup;
  {$ENDIF}
  inherited Destroy;
end;

end.
