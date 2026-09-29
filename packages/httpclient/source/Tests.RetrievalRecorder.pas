{ Tests.RetrievalRecorder — loopback HTTP endpoint that counts certificate
  URL fetches.

  The client-options tests use a fixture leaf whose AIA issuer, OCSP, and
  CRL URLs all point at http://127.0.0.1:47931/. The recorder binds exactly
  that port, answers every request with an uncacheable 404, and counts the
  connections it accepted, so a test can prove that a chain evaluation made
  no retrieval (zero requests) and that the same endpoint is observable when
  retrieval is allowed (at least one request). The port is fixed because it
  is baked into the certificate; Create raises when it is taken.

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
  RETRIEVAL_RECORDER_PORT = 47931;

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

constructor TRetrievalRecorder.Create;
{$IFDEF MSWINDOWS}
var
  Address: TSockAddrIn;
  WSAData: TWSAData;
{$ELSE}
var
  Address: TInetSockAddr;
  ReuseAddress: LongInt;
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
  FListenSocket := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  FListenSocket := FpSocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
  if not RecorderSocketValid(FListenSocket) then
    raise ERetrievalRecorderError.Create('retrieval recorder socket() failed');
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  {$IFDEF MSWINDOWS}
  Address.sin_port := WinSock2.htons(RETRIEVAL_RECORDER_PORT);
  Address.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
  if (WinSock2.bind(FListenSocket, PSockAddr(@Address), SizeOf(Address)) <> 0)
     or (WinSock2.listen(FListenSocket, 16) <> 0) then
  {$ELSE}
  { Reruns must not trip over the previous run's TIME_WAIT connections. }
  ReuseAddress := 1;
  FpSetSockOpt(FListenSocket, SOL_SOCKET, SO_REUSEADDR, @ReuseAddress,
    SizeOf(ReuseAddress));
  Address.sin_port := HToNs(RETRIEVAL_RECORDER_PORT);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if (FpBind(FListenSocket, @Address, SizeOf(Address)) <> 0) or
     (FpListen(FListenSocket, 16) <> 0) then
  {$ENDIF}
    raise ERetrievalRecorderError.CreateFmt(
      'retrieval recorder could not listen on 127.0.0.1:%d; the port is ' +
      'baked into the fixture certificate', [RETRIEVAL_RECORDER_PORT]);
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
