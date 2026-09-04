{ Tests.RegistryServer -- deterministic multi-request loopback registry. }
unit Tests.RegistryServer;

{$mode delphi}{$H+}

interface

uses
  Classes,
  SysUtils
  {$IFDEF UNIX}, Sockets {$ENDIF}
  {$IFDEF MSWINDOWS}, Windows, WinSock2 {$ENDIF};

type
  {$IF DEFINED(UNIX) OR DEFINED(MSWINDOWS)}
  TRegistryTestSocket = TSocket;
  {$ELSE}
  TRegistryTestSocket = PtrUInt;
  {$ENDIF}

  TRegistryHTTPRoute = record
    Path: string;
    MediaType: string;
    Status: Integer;
    Body: TBytes;
  end;
  TRegistryHTTPRouteArray = array of TRegistryHTTPRoute;

  TRegistryTestServer = class
  private
    FListenSocket: TRegistryTestSocket;
    FPort: Word;
    FRequestCount: Integer;
    FRoutes: TRegistryHTTPRouteArray;
    FStopping: Boolean;
    FStarted: Boolean;
    FThread: TThread;
    FError: string;
    {$IFDEF MSWINDOWS}
    FWinSockStarted: Boolean;
    {$ENDIF}
    procedure Serve;
  public
    constructor Create(const ARoutes: TRegistryHTTPRouteArray);
    destructor Destroy; override;
    procedure SetRoutes(const ARoutes: TRegistryHTTPRouteArray);
    procedure Start;
    function WaitForRequests(const ACount: Integer;
      const ATimeoutMilliseconds: Cardinal = 5000): Boolean;
    property Port: Word read FPort;
    property RequestCount: Integer read FRequestCount;
  end;

function RegistryRoute(const APath, AMediaType: string;
  const ABody: TBytes; const AStatus: Integer = 200): TRegistryHTTPRoute;

implementation

const
  CRLF = #13#10;

type
  TRegistryServerThread = class(TThread)
  private
    FOwner: TRegistryTestServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TRegistryTestServer);
  end;

function RegistryRoute(const APath, AMediaType: string;
  const ABody: TBytes; const AStatus: Integer): TRegistryHTTPRoute;
begin
  Result.Path := APath;
  Result.MediaType := AMediaType;
  Result.Status := AStatus;
  Result.Body := Copy(ABody, 0, Length(ABody));
end;

function InvalidSocketValue: TRegistryTestSocket;
begin
  {$IFDEF UNIX}
  Result := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := INVALID_SOCKET;
  {$ENDIF}
end;

function SocketIsValid(const ASocket: TRegistryTestSocket): Boolean;
begin
  {$IFDEF UNIX}
  Result := ASocket >= 0;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := ASocket <> INVALID_SOCKET;
  {$ENDIF}
end;

procedure CloseTestSocket(var ASocket: TRegistryTestSocket);
var
  SocketToClose: TRegistryTestSocket;
begin
  if not SocketIsValid(ASocket) then Exit;
  SocketToClose := ASocket;
  ASocket := InvalidSocketValue;
  {$IFDEF UNIX}
  CloseSocket(SocketToClose);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(SocketToClose);
  {$ENDIF}
end;

function SendBytes(const ASocket: TRegistryTestSocket;
  const ABytes: TBytes): Boolean;
var
  Sent, Offset: Integer;
begin
  Offset := 0;
  while Offset < Length(ABytes) do
  begin
    {$IFDEF UNIX}
    Sent := fpSend(ASocket, @ABytes[Offset], Length(ABytes) - Offset, 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Sent := WinSock2.send(ASocket, PAnsiChar(@ABytes[Offset]),
      Length(ABytes) - Offset, 0);
    {$ENDIF}
    if Sent <= 0 then Exit(False);
    Inc(Offset, Sent);
  end;
  Result := True;
end;

function ReceiveRequest(const ASocket: TRegistryTestSocket): string;
var
  Buffer: array[0..4095] of Byte;
  Received: Integer;
  Chunk: AnsiString;
begin
  Result := '';
  repeat
    {$IFDEF UNIX}
    Received := fpRecv(ASocket, @Buffer[0], SizeOf(Buffer), 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Received := WinSock2.recv(ASocket, PAnsiChar(@Buffer[0]),
      SizeOf(Buffer), 0);
    {$ENDIF}
    if Received <= 0 then Exit;
    SetString(Chunk, PAnsiChar(@Buffer[0]), Received);
    Result := Result + string(Chunk);
    if Pos(CRLF + CRLF, Result) > 0 then Exit;
    if Length(Result) > 65536 then Exit('');
  until False;
end;

function RequestPath(const ARequest: string): string;
var
  FirstSpace, SecondSpace: Integer;
begin
  FirstSpace := Pos(' ', ARequest);
  if FirstSpace = 0 then Exit('');
  SecondSpace := Pos(' ', Copy(ARequest, FirstSpace + 1, MaxInt));
  if SecondSpace = 0 then Exit('');
  Result := Copy(ARequest, FirstSpace + 1, SecondSpace - 1);
end;

function ResponseBytes(const AStatus: Integer; const AMediaType: string;
  const ABody: TBytes): TBytes;
var
  Head, Reason: string;
begin
  case AStatus of
    200: Reason := 'OK';
    404: Reason := 'Not Found';
    500: Reason := 'Internal Server Error';
  else
    Reason := 'Test Response';
  end;
  Head := 'HTTP/1.1 ' + IntToStr(AStatus) + ' ' + Reason + CRLF
    + 'Content-Type: ' + AMediaType + CRLF
    + 'Content-Length: ' + IntToStr(Length(ABody)) + CRLF
    + 'Connection: close' + CRLF + CRLF;
  SetLength(Result, Length(Head) + Length(ABody));
  if Head <> '' then Move(Head[1], Result[0], Length(Head));
  if Length(ABody) > 0 then
    Move(ABody[0], Result[Length(Head)], Length(ABody));
end;

constructor TRegistryServerThread.Create(AOwner: TRegistryTestServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TRegistryServerThread.Execute;
begin
  FOwner.Serve;
end;

constructor TRegistryTestServer.Create(
  const ARoutes: TRegistryHTTPRouteArray);
var
  Addr: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  AddrLength: LongInt;
  {$IFDEF MSWINDOWS}
  WinSockData: TWSAData;
  {$ENDIF}
begin
  inherited Create;
  FListenSocket := InvalidSocketValue;
  SetRoutes(ARoutes);
  {$IFDEF MSWINDOWS}
  if WSAStartup($0202, WinSockData) <> 0 then
    raise Exception.Create('registry test server WSAStartup failed');
  FWinSockStarted := True;
  {$ENDIF}
  {$IFDEF UNIX}
  FListenSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FListenSocket := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if not SocketIsValid(FListenSocket) then
    raise Exception.Create('registry test server socket failed');
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  {$IFDEF UNIX}
  Addr.sin_addr := StrToNetAddr('127.0.0.1');
  Addr.sin_port := htons(0);
  if fpBind(FListenSocket, @Addr, SizeOf(Addr)) <> 0 then
    raise Exception.Create('registry test server bind failed');
  if fpListen(FListenSocket, 16) <> 0 then
    raise Exception.Create('registry test server listen failed');
  AddrLength := SizeOf(Addr);
  if fpGetSockName(FListenSocket, @Addr, @AddrLength) <> 0 then
    raise Exception.Create('registry test server getsockname failed');
  FPort := ntohs(Addr.sin_port);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Addr.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
  Addr.sin_port := WinSock2.htons(0);
  if WinSock2.bind(FListenSocket, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
    raise Exception.Create('registry test server bind failed');
  if WinSock2.listen(FListenSocket, 16) <> 0 then
    raise Exception.Create('registry test server listen failed');
  AddrLength := SizeOf(Addr);
  if WinSock2.getsockname(FListenSocket, PSockAddr(@Addr), AddrLength) <> 0 then
    raise Exception.Create('registry test server getsockname failed');
  FPort := WinSock2.ntohs(Addr.sin_port);
  {$ENDIF}
  FThread := TRegistryServerThread.Create(Self);
end;

procedure TRegistryTestServer.SetRoutes(
  const ARoutes: TRegistryHTTPRouteArray);
var
  I: Integer;
begin
  if FStarted then
    raise Exception.Create('cannot replace routes after server start');
  SetLength(FRoutes, Length(ARoutes));
  for I := 0 to High(ARoutes) do FRoutes[I] := ARoutes[I];
end;

destructor TRegistryTestServer.Destroy;
var
  WakeSocket: TRegistryTestSocket;
  Addr: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
begin
  FStopping := True;
  { A caller may release a reserved listener or fail while preparing routes
    before Start. Let its suspended worker observe FStopping before joining. }
  if Assigned(FThread) and not FStarted then FThread.Start;
  if Assigned(FThread) and (not FThread.Finished) then
  begin
    {$IFDEF UNIX}
    WakeSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    WakeSocket := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
    {$ENDIF}
    if SocketIsValid(WakeSocket) then
    begin
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := {$IFDEF UNIX}htons{$ELSE}WinSock2.htons{$ENDIF}(FPort);
      {$IFDEF UNIX}
      Addr.sin_addr := StrToNetAddr('127.0.0.1');
      fpConnect(WakeSocket, @Addr, SizeOf(Addr));
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      Addr.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
      WinSock2.connect(WakeSocket, PSockAddr(@Addr), SizeOf(Addr));
      {$ENDIF}
      CloseTestSocket(WakeSocket);
    end;
    FThread.WaitFor;
  end;
  FThread.Free;
  CloseTestSocket(FListenSocket);
  {$IFDEF MSWINDOWS}
  if FWinSockStarted then WinSock2.WSACleanup;
  {$ENDIF}
  inherited Destroy;
end;

procedure TRegistryTestServer.Start;
begin
  FStarted := True;
  FThread.Start;
end;

procedure TRegistryTestServer.Serve;
var
  Client: TRegistryTestSocket;
  Addr: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
  AddrLength: LongInt;
  I: Integer;
  Request, Path: string;
  Response: TBytes;
  Found: Boolean;
begin
  try
    while not FStopping do
    begin
      AddrLength := SizeOf(Addr);
      {$IFDEF UNIX}
      Client := fpAccept(FListenSocket, @Addr, @AddrLength);
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      Client := WinSock2.accept(FListenSocket, PSockAddr(@Addr), @AddrLength);
      {$ENDIF}
      if not SocketIsValid(Client) then Continue;
      try
        if FStopping then Continue;
        Request := ReceiveRequest(Client);
        Path := RequestPath(Request);
        InterlockedIncrement(FRequestCount);
        Found := False;
        for I := 0 to High(FRoutes) do
          if FRoutes[I].Path = Path then
          begin
            Response := ResponseBytes(FRoutes[I].Status,
              FRoutes[I].MediaType, FRoutes[I].Body);
            SendBytes(Client, Response);
            Found := True;
            Break;
          end;
        if not Found then
        begin
          Response := ResponseBytes(404, 'text/plain',
            BytesOf('missing route: ' + Path));
          SendBytes(Client, Response);
        end;
      finally
        CloseTestSocket(Client);
      end;
    end;
  except
    on E: Exception do FError := E.Message;
  end;
end;

function TRegistryTestServer.WaitForRequests(const ACount: Integer;
  const ATimeoutMilliseconds: Cardinal): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  while (FRequestCount < ACount)
    and (GetTickCount64 - Started < ATimeoutMilliseconds) do Sleep(1);
  if FError <> '' then
    raise Exception.Create('registry test server failed: ' + FError);
  Result := FRequestCount >= ACount;
end;

end.
