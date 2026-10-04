{ Tests.RetrievalRecorder — loopback HTTP endpoint that counts certificate
  URL fetches.

  The client-options tests use a fixture leaf whose AIA issuer, OCSP, and
  CRL URLs all point at http://127.0.0.1:6741/. The recorder binds exactly
  that port, answers every request with an uncacheable 404, and counts the
  connections it accepted, so a test can prove that a chain evaluation made
  no retrieval (zero requests) and that the same endpoint is observable when
  retrieval is allowed (at least one request).

  The port is fixed because it is baked into the certificate, so it sits
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
  { How long Create retries a bind refused because the port is in use. }
  RETRIEVAL_RECORDER_BIND_MILLISECONDS = 5000;

type
  ERetrievalRecorderError = class(Exception);

  TRetrievalRecorder = class(TThread)
  private
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
    constructor Create;
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

constructor TRetrievalRecorder.Create;
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
  InitCriticalSection(FLock);
  FRequestLines := TStringList.Create;
  FListenSocket := INVALID_RECORDER_SOCKET;
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
    if OpenRecorderListener(FListenSocket, Stage, ErrorCode) then
      Break;
    if (Stage <> 'bind()') or not RecorderAddressInUse(ErrorCode) or
       (GetTickCount64 - StartedAt >= RETRIEVAL_RECORDER_BIND_MILLISECONDS) then
      raise ERetrievalRecorderError.CreateFmt(
        'retrieval recorder could not listen on 127.0.0.1:%d (the port is ' +
        'baked into the fixture certificate): %s failed with error %d (%s) ' +
        'after %d attempt(s) in %d ms',
        [RETRIEVAL_RECORDER_PORT, Stage, ErrorCode,
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
begin
  while not Terminated do
  begin
    if not RecorderReadable(FListenSocket, 50) then
      Continue;
    {$IFDEF MSWINDOWS}
    Accepted := WinSock2.accept(FListenSocket, nil, nil);
    {$ELSE}
    Accepted := FpAccept(FListenSocket, nil, nil);
    {$ENDIF}
    if not RecorderSocketValid(Accepted) then
      Continue;
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
