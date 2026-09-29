{ Tests.TCPRelay -- a loopback TCP relay that counts connections.

  Each accepted connection is joined to a new connection to the backend
  port and bytes are copied both ways unchanged, so TLS passes through end
  to end. Tests use the accept count to prove how many connections a client
  made. Teardown shuts every socket down, so no copy thread outlives the
  relay. }
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
    FAccepted: LongInt;
    FLock: TRTLCriticalSection;
    FSockets: array of TSocket;
    FPumps: TList;
    {$IFDEF MSWINDOWS}
    FWinSockStarted: Boolean;
    {$ENDIF}
    procedure Track(const ASocket: TSocket);
  protected
    procedure Execute; override;
  public
    constructor Create(const ABackend: Word);
    destructor Destroy; override;
    property Port: Word read FPort;
    property Backend: Word read FBackend write FBackend;
    function Accepted: Integer;
  end;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

const
  {$IFDEF LINUX}
  RELAY_SEND_FLAGS = $4000; { MSG_NOSIGNAL }
  {$ELSE}
  RELAY_SEND_FLAGS = 0;
  {$ENDIF}
  {$IFDEF DARWIN}
  RELAY_SO_NOSIGPIPE = $1022;
  {$ENDIF}
  {$IFDEF UNIX}
  RELAY_SHUT_RDWR = 2;
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

procedure PrepareRelaySocket(const ASocket: TSocket);
{$IFDEF DARWIN}
var
  Enabled: LongInt;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  Enabled := 1;
  fpSetSockOpt(ASocket, SOL_SOCKET, RELAY_SO_NOSIGPIPE, @Enabled, SizeOf(Enabled));
  {$ENDIF}
end;

procedure ShutdownRelaySocket(const ASocket: TSocket);
begin
  {$IFDEF UNIX}
  fpShutdown(ASocket, RELAY_SHUT_RDWR);
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

function LoopbackAddress(const APort: Word): {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.sin_family := AF_INET;
  {$IFDEF UNIX}
  Result.sin_port := htons(APort);
  Result.sin_addr := StrToNetAddr('127.0.0.1');
  {$ELSE}
  Result.sin_port := WinSock2.htons(APort);
  Result.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
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

constructor TTCPRelay.Create(const ABackend: Word);
var
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Length_: {$IFDEF UNIX}TSockLen{$ELSE}LongInt{$ENDIF};
  {$IFDEF MSWINDOWS}
  Data: TWSAData;
  {$ENDIF}
begin
  FBackend := ABackend;
  FreeOnTerminate := False;
  InitCriticalSection(FLock);
  FPumps := TList.Create;
  {$IFDEF MSWINDOWS}
  if WSAStartup($0202, Data) <> 0 then
    raise Exception.Create('relay WSAStartup failed');
  FWinSockStarted := True;
  FListen := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if not RelaySocketValid(FListen) then
    raise Exception.Create('relay socket failed');
  Address := LoopbackAddress(0);
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

procedure TTCPRelay.Execute;
var
  Client, Upstream: TSocket;
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Length_: {$IFDEF UNIX}TSockLen{$ELSE}LongInt{$ENDIF};
begin
  while not Terminated do
  begin
    Length_ := SizeOf(Address);
    {$IFDEF UNIX}
    Client := fpAccept(FListen, @Address, @Length_);
    {$ELSE}
    Client := WinSock2.accept(FListen, PSockAddr(@Address), @Length_);
    {$ENDIF}
    if not RelaySocketValid(Client) then
    begin
      if Terminated then Break;
      Sleep(1);
      Continue;
    end;
    if Terminated then
    begin
      CloseRelaySocket(Client);
      Break;
    end;
    InterlockedIncrement(FAccepted);
    Track(Client);
    PrepareRelaySocket(Client);
    {$IFDEF UNIX}
    Upstream := fpSocket(AF_INET, SOCK_STREAM, 0);
    {$ELSE}
    Upstream := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    if not RelaySocketValid(Upstream) then
    begin
      ShutdownRelaySocket(Client);
      Continue;
    end;
    Track(Upstream);
    PrepareRelaySocket(Upstream);
    Address := LoopbackAddress(FBackend);
    {$IFDEF UNIX}
    if fpConnect(Upstream, @Address, SizeOf(Address)) <> 0 then
    {$ELSE}
    if WinSock2.connect(Upstream, PSockAddr(@Address), SizeOf(Address)) <> 0 then
    {$ENDIF}
    begin
      ShutdownRelaySocket(Client);
      Continue;
    end;
    FPumps.Add(TRelayPump.Create(Client, Upstream));
    FPumps.Add(TRelayPump.Create(Upstream, Client));
  end;
end;

destructor TTCPRelay.Destroy;
var
  Wake: TSocket;
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  Index: Integer;
begin
  Terminate;
  { Wake the blocking accept with one last connection. }
  {$IFDEF UNIX}
  Wake := fpSocket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  Wake := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if RelaySocketValid(Wake) then
  begin
    Address := LoopbackAddress(FPort);
    {$IFDEF UNIX}
    fpConnect(Wake, @Address, SizeOf(Address));
    {$ELSE}
    WinSock2.connect(Wake, PSockAddr(@Address), SizeOf(Address));
    {$ENDIF}
    CloseRelaySocket(Wake);
  end;
  WaitFor;
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(FSockets) do ShutdownRelaySocket(FSockets[Index]);
  finally
    LeaveCriticalSection(FLock);
  end;
  for Index := 0 to FPumps.Count - 1 do
  begin
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
