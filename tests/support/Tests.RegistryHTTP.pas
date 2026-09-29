{ Tests.RegistryHTTP -- raw loopback HTTP/1.1 requests for registry tests.

  Publication has no client yet, so tests speak the wire directly: arbitrary
  methods, headers, and bodies, including partial bodies held open. }
unit Tests.RegistryHTTP;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  SysUtils,

  TransportSecurity;

type
  TRawHTTPResponse = record
    Status: Integer;
    Head: string;
    Body: TBytes;
  end;

  { One open connection whose request can be sent in pieces. }
  TRawHTTPConnection = class
  private
    FSocket: {$IFDEF UNIX}TSocket{$ELSE}TSocket{$ENDIF};
    FOpen: Boolean;
    FTLS: TTransportSecurityConnection;
    FSecure: Boolean;
  public
    { Wraps the connection in TLS without verifying the test identity. }
    procedure StartTLS(const AHost: string);
    constructor Create(const APort: Word);
    destructor Destroy; override;
    procedure Send(const ABytes: TBytes);
    procedure SendText(const AText: string);
    { Reads until the peer closes or ATimeoutMilliseconds passes. }
    function ReadResponse(const ATimeoutMilliseconds: Cardinal = 30000): TRawHTTPResponse;
    procedure Close;
  end;

function RawHTTPRequest(const APort: Word; const AMethod, ATarget: string;
  const AHeaders: array of string; const ABody: TBytes;
  const AIncludeLength: Boolean = True;
  const ATimeoutMilliseconds: Cardinal = 30000): TRawHTTPResponse;
{ Value of the first response header named AName, or ''. }
function RawHTTPHeader(const AResponse: TRawHTTPResponse;
  const AName: string): string;
function RawHTTPBodyText(const AResponse: TRawHTTPResponse): string;
function RawHTTPBytes(const AText: string): TBytes;

implementation

{$IFDEF UNIX}
uses
  BaseUnix;
{$ENDIF}

{$IFDEF MSWINDOWS}
var
  WinSockReady: Boolean;

procedure EnsureWinSock;
var
  Data: TWSAData;
begin
  if WinSockReady then Exit;
  if WSAStartup($0202, Data) <> 0 then
    raise Exception.Create('raw HTTP WSAStartup failed');
  WinSockReady := True;
end;
{$ENDIF}

function RawHTTPBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Result[0], Length(AText));
end;

function RawHTTPBodyText(const AResponse: TRawHTTPResponse): string;
begin
  if Length(AResponse.Body) = 0 then Exit('');
  SetString(Result, PAnsiChar(@AResponse.Body[0]), Length(AResponse.Body));
end;

constructor TRawHTTPConnection.Create(const APort: Word);
var
  Address: {$IFDEF UNIX}TInetSockAddr{$ELSE}TSockAddrIn{$ENDIF};
begin
  inherited Create;
  {$IFDEF MSWINDOWS}
  EnsureWinSock;
  FSocket := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  if FSocket = INVALID_SOCKET then
    raise Exception.Create('raw HTTP socket failed');
  {$ELSE}
  FSocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FSocket < 0 then raise Exception.Create('raw HTTP socket failed');
  {$ENDIF}
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  {$IFDEF UNIX}
  Address.sin_port := htons(APort);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  if fpConnect(FSocket, @Address, SizeOf(Address)) <> 0 then
  begin
    CloseSocket(FSocket);
    raise Exception.Create('raw HTTP connect failed');
  end;
  {$ELSE}
  Address.sin_port := WinSock2.htons(APort);
  Address.sin_addr.S_addr := WinSock2.inet_addr('127.0.0.1');
  if WinSock2.connect(FSocket, PSockAddr(@Address), SizeOf(Address)) <> 0 then
  begin
    WinSock2.closesocket(FSocket);
    raise Exception.Create('raw HTTP connect failed');
  end;
  {$ENDIF}
  FOpen := True;
end;

destructor TRawHTTPConnection.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TRawHTTPConnection.StartTLS(const AHost: string);
var
  Options: TTransportSecurityClientOptions;
begin
  Options := DefaultTransportSecurityClientOptions;
  Options.InsecureSkipVerify := True;
  FillChar(FTLS, SizeOf(FTLS), 0);
  StartTransportSecurity(FTLS, FSocket, AHost, Options);
  FSecure := True;
end;

procedure TRawHTTPConnection.Close;
begin
  if not FOpen then Exit;
  FOpen := False;
  if FSecure then
  begin
    FSecure := False;
    try
      CloseTransportSecurity(FTLS);
    except
    end;
  end;
  {$IFDEF UNIX}
  CloseSocket(FSocket);
  {$ELSE}
  WinSock2.closesocket(FSocket);
  {$ENDIF}
end;

procedure TRawHTTPConnection.Send(const ABytes: TBytes);
var
  Offset, Sent: Integer;
begin
  Offset := 0;
  if FSecure then
  begin
    while Offset < Length(ABytes) do
    begin
      Sent := TransportSecurityWrite(FTLS, @ABytes[Offset],
        Length(ABytes) - Offset);
      if Sent <= 0 then raise Exception.Create('raw HTTPS send failed');
      Inc(Offset, Sent);
    end;
    Exit;
  end;
  while Offset < Length(ABytes) do
  begin
    {$IFDEF UNIX}
    Sent := fpSend(FSocket, @ABytes[Offset], Length(ABytes) - Offset,
      {$IFDEF LINUX}$4000{$ELSE}0{$ENDIF});
    {$ELSE}
    Sent := WinSock2.send(FSocket, ABytes[Offset], Length(ABytes) - Offset, 0);
    {$ENDIF}
    if Sent <= 0 then raise Exception.Create('raw HTTP send failed');
    Inc(Offset, Sent);
  end;
end;

procedure TRawHTTPConnection.SendText(const AText: string);
begin
  Send(RawHTTPBytes(AText));
end;

function TRawHTTPConnection.ReadResponse(
  const ATimeoutMilliseconds: Cardinal): TRawHTTPResponse;
var
  Buffer: array[0..65535] of Byte;
  Raw: string;
  Chunk: AnsiString;
  Received, HeaderEnd, Space: Integer;
  {$IFDEF UNIX}
  Timeout: TTimeVal;
  {$ELSE}
  Timeout: LongInt;
  {$ENDIF}
  Deadline: QWord;
begin
  Result := Default(TRawHTTPResponse);
  {$IFDEF UNIX}
  Timeout.tv_sec := 1;
  Timeout.tv_usec := 0;
  fpSetSockOpt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
  {$ELSE}
  Timeout := 1000;
  WinSock2.setsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, PChar(@Timeout),
    SizeOf(Timeout));
  {$ENDIF}
  Raw := '';
  Deadline := GetTickCount64 + ATimeoutMilliseconds;
  repeat
    {$IFDEF UNIX}
    Received := fpRecv(FSocket, @Buffer[0], SizeOf(Buffer), 0);
    {$ELSE}
    Received := WinSock2.recv(FSocket, Buffer[0], SizeOf(Buffer), 0);
    {$ENDIF}
    if Received > 0 then
    begin
      SetString(Chunk, PAnsiChar(@Buffer[0]), Received);
      Raw := Raw + Chunk;
      Continue;
    end;
    if Received = 0 then Break;
    {$IFDEF UNIX}
    if (fpGetErrNo <> ESysEAGAIN) and (fpGetErrNo <> ESysEINTR) then Break;
    {$ELSE}
    if WSAGetLastError <> WSAETIMEDOUT then Break;
    {$ENDIF}
  until GetTickCount64 >= Deadline;
  { Skip interim 1xx responses. }
  while (Copy(Raw, 1, 10) = 'HTTP/1.1 1') and (Pos(#13#10#13#10, Raw) > 0) do
    Delete(Raw, 1, Pos(#13#10#13#10, Raw) + 3);
  HeaderEnd := Pos(#13#10#13#10, Raw);
  if HeaderEnd = 0 then Exit;
  Result.Head := Copy(Raw, 1, HeaderEnd - 1);
  Space := Pos(' ', Result.Head);
  Result.Status := StrToIntDef(Copy(Result.Head, Space + 1, 3), 0);
  Result.Body := RawHTTPBytes(Copy(Raw, HeaderEnd + 4, MaxInt));
end;

function RawHTTPRequest(const APort: Word; const AMethod, ATarget: string;
  const AHeaders: array of string; const ABody: TBytes;
  const AIncludeLength: Boolean;
  const ATimeoutMilliseconds: Cardinal): TRawHTTPResponse;
var
  Connection: TRawHTTPConnection;
  Request: string;
  Header: string;
begin
  Connection := TRawHTTPConnection.Create(APort);
  try
    Request := AMethod + ' ' + ATarget + ' HTTP/1.1' + #13#10
      + 'Host: localhost:' + IntToStr(APort) + #13#10;
    for Header in AHeaders do Request := Request + Header + #13#10;
    if AIncludeLength then
      Request := Request + 'Content-Length: ' + IntToStr(Length(ABody)) + #13#10;
    Request := Request + 'Connection: close' + #13#10#13#10;
    Connection.SendText(Request);
    if Length(ABody) > 0 then Connection.Send(ABody);
    Result := Connection.ReadResponse(ATimeoutMilliseconds);
  finally
    Connection.Free;
  end;
end;

function RawHTTPHeader(const AResponse: TRawHTTPResponse;
  const AName: string): string;
var
  Lines: TStringArray;
  Line: string;
begin
  Result := '';
  Lines := AResponse.Head.Split([#13#10]);
  for Line in Lines do
    if SameText(Copy(Line, 1, Length(AName) + 1), AName + ':') then
      Exit(Trim(Copy(Line, Length(AName) + 2, MaxInt)));
end;

{$IFDEF MSWINDOWS}
finalization
  if WinSockReady then WSACleanup;
{$ENDIF}
end.
