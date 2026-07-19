{ TransportSecurity.Test — deterministic TLS server-accept coverage.

  The production client deliberately verifies peers against the OS trust
  store, so it must not be weakened to connect to the throwaway self-signed
  fixture. The roundtrip client therefore uses raw calls through the same
  runtime-loaded OpenSSL interface after the server context has loaded it. }

program TransportSecurity.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  {$IFNDEF DARWIN}
  DynLibs,
  OpenSSL,
  {$ENDIF}
  TestingPascalLibrary,
  TransportSecurity;

const
  CERTIFICATE_PATH =
    'packages/httpclient/source/fixtures/localhost-test-cert.pem';
  PRIVATE_KEY_PATH =
    'packages/httpclient/source/fixtures/localhost-test-key.pem';
  SCRATCH_DIRECTORY = 'build/tests/tmp/transport-security';
  CLIENT_REQUEST = 'hello from raw OpenSSL client';
  SECOND_CLIENT_REQUEST = 'second connection through reused context';
  SERVER_RESPONSE = 'hello from TransportSecurity server';
  DARWIN_SKIP_REASON =
    'OpenSSL TLS server accept is intentionally unsupported on Darwin; ' +
    'duetto uses Network.framework there';

type
  TTransportSecurityServerTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDarwinReportsUnsupportedServerTLS;
    procedure TestMissingPEMFailsActionably;
    procedure TestGarbageCertificatePEMFailsActionably;
    procedure TestGarbagePrivateKeyPEMFailsActionably;
    procedure TestAcceptRoundtripAndReuse;
  end;

{$IFNDEF DARWIN}
type
  TSSLMethodGetter = function: Pointer; cdecl;

  TServerRoundtrip = record
    ClientResponse: AnsiString;
    ServerRequest: AnsiString;
    ServerError: string;
    ConnectionWasActive: Boolean;
    ConnectionWasClosed: Boolean;
  end;

  TTransportSecurityServerThread = class(TThread)
  private
    FContext: TTransportSecurityServerContext;
    FListenSocket: TSocket;
    FRequestLength: Integer;
    FReceived: AnsiString;
    FErrorMessage: string;
    FConnectionWasActive: Boolean;
    FConnectionWasClosed: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AListenSocket: TSocket;
      const AContext: TTransportSecurityServerContext;
      const ARequestLength: Integer);
    property Received: AnsiString read FReceived;
    property ErrorMessage: string read FErrorMessage;
    property ConnectionWasActive: Boolean read FConnectionWasActive;
    property ConnectionWasClosed: Boolean read FConnectionWasClosed;
  end;
{$ENDIF}

procedure WriteTextFile(const APath, AText: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

function CaptureContextError(const ACertificatePath,
  APrivateKeyPath: string): string;
var
  Context: TTransportSecurityServerContext;
begin
  Result := '';
  Context := nil;
  try
    try
      Context := TTransportSecurityServerContext.Create(
        ACertificatePath, APrivateKeyPath);
    except
      on E: ETransportSecurityError do
        Result := E.Message;
    end;
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  if Result = '' then
    raise Exception.Create('Expected TLS server context creation to fail');
end;

{$IFNDEF DARWIN}
function SocketIsInvalid(const ASocket: TSocket): Boolean; inline;
begin
  {$IFDEF UNIX}
  Result := ASocket < 0;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := ASocket = INVALID_SOCKET;
  {$ENDIF}
end;

procedure CloseTestSocket(const ASocket: TSocket); inline;
begin
  if SocketIsInvalid(ASocket) then
    Exit;
  {$IFDEF UNIX}
  CloseSocket(ASocket);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(ASocket);
  {$ENDIF}
end;

function CreateLoopbackListener(out APort: Word): TSocket;
{$IFDEF UNIX}
var
  Address: TInetSockAddr;
  AddressLength: TSockLen;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if SocketIsInvalid(Result) then
    raise Exception.Create('socket() failed for TLS server test listener');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := 0;
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if fpBind(Result, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('bind() failed for TLS server test listener');
    if fpListen(Result, 1) <> 0 then
      raise Exception.Create('listen() failed for TLS server test listener');
    AddressLength := SizeOf(Address);
    if fpGetSockName(Result, @Address, @AddressLength) <> 0 then
      raise Exception.Create(
        'getsockname() failed for TLS server test listener');
    APort := ntohs(Address.sin_port);
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Address: TSockAddrIn;
  AddressLength: LongInt;
begin
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if SocketIsInvalid(Result) then
    raise Exception.Create('socket() failed for TLS server test listener');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := 0;
    Address.sin_addr.s_addr := WinSock2.inet_addr('127.0.0.1');
    if WinSock2.bind(Result, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('bind() failed for TLS server test listener');
    if WinSock2.listen(Result, 1) <> 0 then
      raise Exception.Create('listen() failed for TLS server test listener');
    AddressLength := SizeOf(Address);
    if WinSock2.getsockname(Result, PSockAddr(@Address)^,
      AddressLength) <> 0 then
      raise Exception.Create(
        'getsockname() failed for TLS server test listener');
    APort := WinSock2.ntohs(Address.sin_port);
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ENDIF}

function ConnectLoopback(const APort: Word): TSocket;
{$IFDEF UNIX}
var
  Address: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if SocketIsInvalid(Result) then
    raise Exception.Create('socket() failed for TLS server test client');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := htons(APort);
    Address.sin_addr := StrToNetAddr('127.0.0.1');
    if fpConnect(Result, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('connect() failed for TLS server test client');
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Address: TSockAddrIn;
begin
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if SocketIsInvalid(Result) then
    raise Exception.Create('socket() failed for TLS server test client');
  try
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := WinSock2.htons(APort);
    Address.sin_addr.s_addr := WinSock2.inet_addr('127.0.0.1');
    if WinSock2.connect(Result, @Address, SizeOf(Address)) <> 0 then
      raise Exception.Create('connect() failed for TLS server test client');
  except
    CloseTestSocket(Result);
    raise;
  end;
end;
{$ENDIF}

function AcceptTestSocket(const AListenSocket: TSocket): TSocket; inline;
begin
  {$IFDEF UNIX}
  Result := fpAccept(AListenSocket, nil, nil);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.accept(AListenSocket, nil, nil);
  {$ENDIF}
end;

function TransportReadExact(var AConnection: TTransportSecurityConnection;
  const ALength: Integer): AnsiString;
var
  Buffer: array[0..255] of Byte;
  Offset: Integer;
  ReadCount: Integer;
  Requested: Integer;
begin
  SetLength(Result, ALength);
  Offset := 0;
  while Offset < ALength do
  begin
    Requested := ALength - Offset;
    if Requested > Length(Buffer) then
      Requested := Length(Buffer);
    ReadCount := TransportSecurityRead(AConnection, Buffer, Requested);
    if ReadCount <= 0 then
      raise Exception.Create('TLS server read ended before request was complete');
    Move(Buffer[0], Result[Offset + 1], ReadCount);
    Inc(Offset, ReadCount);
  end;
end;

procedure TransportWriteAll(var AConnection: TTransportSecurityConnection;
  const AData: AnsiString);
var
  Offset: Integer;
  Written: Integer;
begin
  Offset := 0;
  while Offset < Length(AData) do
  begin
    Written := TransportSecurityWrite(AConnection, @AData[Offset + 1],
      Length(AData) - Offset);
    if Written <= 0 then
      raise Exception.Create('TLS server write ended before response was complete');
    Inc(Offset, Written);
  end;
end;

constructor TTransportSecurityServerThread.Create(
  const AListenSocket: TSocket;
  const AContext: TTransportSecurityServerContext;
  const ARequestLength: Integer);
begin
  FListenSocket := AListenSocket;
  FContext := AContext;
  FRequestLength := ARequestLength;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TTransportSecurityServerThread.Execute;
var
  AcceptedSocket: TSocket;
  Connection: TTransportSecurityConnection;
begin
  AcceptedSocket := AcceptTestSocket(FListenSocket);
  FillChar(Connection, SizeOf(Connection), 0);
  try
    if SocketIsInvalid(AcceptedSocket) then
      raise Exception.Create('accept() failed for TLS server test');
    StartTransportSecurityServer(Connection, FContext, AcceptedSocket);
    FConnectionWasActive := Connection.Active;
    FReceived := TransportReadExact(Connection, FRequestLength);
    TransportWriteAll(Connection, SERVER_RESPONSE);
    CloseTransportSecurity(Connection);
    FConnectionWasClosed := not Connection.Active;
  except
    on E: Exception do
      FErrorMessage := E.ClassName + ': ' + E.Message;
  end;
  CloseTransportSecurity(Connection);
  CloseTestSocket(AcceptedSocket);
end;

procedure RawOpenSSLWriteAll(const ASSL: PSSL; const AData: AnsiString);
var
  Offset: Integer;
  Written: Integer;
  ErrorCode: Integer;
begin
  Offset := 0;
  while Offset < Length(AData) do
  begin
    Written := SslWrite(ASSL, @AData[Offset + 1], Length(AData) - Offset);
    if Written > 0 then
    begin
      Inc(Offset, Written);
      Continue;
    end;
    ErrorCode := SslGetError(ASSL, Written);
    if (ErrorCode <> SSL_ERROR_WANT_READ) and
       (ErrorCode <> SSL_ERROR_WANT_WRITE) then
      raise Exception.CreateFmt('Raw OpenSSL client write failed: %d',
        [ErrorCode]);
  end;
end;

function RawOpenSSLReadExact(const ASSL: PSSL;
  const ALength: Integer): AnsiString;
var
  Offset: Integer;
  ReadCount: Integer;
  ErrorCode: Integer;
begin
  SetLength(Result, ALength);
  Offset := 0;
  while Offset < ALength do
  begin
    ReadCount := SslRead(ASSL, @Result[Offset + 1], ALength - Offset);
    if ReadCount > 0 then
    begin
      Inc(Offset, ReadCount);
      Continue;
    end;
    ErrorCode := SslGetError(ASSL, ReadCount);
    if (ErrorCode <> SSL_ERROR_WANT_READ) and
       (ErrorCode <> SSL_ERROR_WANT_WRITE) then
      raise Exception.CreateFmt('Raw OpenSSL client read failed: %d',
        [ErrorCode]);
  end;
end;

function RunRawOpenSSLClient(const APort: Word;
  const ARequest: AnsiString): AnsiString;
var
  GetMethod: TSSLMethodGetter;
  Context: PSSL_CTX;
  SSL: PSSL;
  ClientSocket: TSocket;
  ConnectResult: Integer;
begin
  if not IsSSLloaded then
    raise Exception.Create(
      'TLS server context did not initialize the raw OpenSSL test client');
  GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
    'TLS_client_method'));
  if not Assigned(GetMethod) then
    GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
      'TLS_method'));
  if not Assigned(GetMethod) then
    raise Exception.Create('Raw OpenSSL test client has no TLS method');

  Context := SslCtxNew(GetMethod());
  if not Assigned(Context) then
    raise Exception.Create('Raw OpenSSL test client context creation failed');
  SSL := nil;
  ClientSocket := TSocket(-1);
  try
    SSL := SslNew(Context);
    if not Assigned(SSL) then
      raise Exception.Create('Raw OpenSSL test client session creation failed');
    ClientSocket := ConnectLoopback(APort);
    if SslSetFd(SSL, ClientSocket) <> 1 then
      raise Exception.Create('Raw OpenSSL test client socket binding failed');
    ConnectResult := SslConnect(SSL);
    if ConnectResult <= 0 then
      raise Exception.CreateFmt('Raw OpenSSL client handshake failed: %d',
        [SslGetError(SSL, ConnectResult)]);
    RawOpenSSLWriteAll(SSL, ARequest);
    Result := RawOpenSSLReadExact(SSL, Length(SERVER_RESPONSE));
  finally
    if Assigned(SSL) then
    begin
      SslShutdown(SSL);
      SslFree(SSL);
    end;
    CloseTestSocket(ClientSocket);
    SslCtxFree(Context);
  end;
end;

function RunRoundtrip(const AContext: TTransportSecurityServerContext;
  const ARequest: AnsiString): TServerRoundtrip;
var
  ListenSocket: TSocket;
  Port: Word;
  Server: TTransportSecurityServerThread;
begin
  FillChar(Result, SizeOf(Result), 0);
  ListenSocket := CreateLoopbackListener(Port);
  Server := TTransportSecurityServerThread.Create(ListenSocket, AContext,
    Length(ARequest));
  try
    Server.Start;
    Result.ClientResponse := RunRawOpenSSLClient(Port, ARequest);
    Server.WaitFor;
    Result.ServerRequest := Server.Received;
    Result.ServerError := Server.ErrorMessage;
    Result.ConnectionWasActive := Server.ConnectionWasActive;
    Result.ConnectionWasClosed := Server.ConnectionWasClosed;
  finally
    Server.Free;
    CloseTestSocket(ListenSocket);
  end;
end;
{$ENDIF}

procedure TTransportSecurityServerTests.TestDarwinReportsUnsupportedServerTLS;
var
  ErrorMessage: string;
begin
  ErrorMessage := CaptureContextError(CERTIFICATE_PATH, PRIVATE_KEY_PATH);
  Expect<Boolean>(Pos('not supported on macOS', ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos('Network.framework', ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestMissingPEMFailsActionably;
var
  MissingPath: string;
  ErrorMessage: string;
begin
  MissingPath := SCRATCH_DIRECTORY + '/missing-cert.pem';
  ErrorMessage := CaptureContextError(MissingPath, PRIVATE_KEY_PATH);
  Expect<Boolean>(Pos('certificate PEM file does not exist',
    ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(MissingPath, ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestGarbageCertificatePEMFailsActionably;
var
  GarbagePath: string;
  ErrorMessage: string;
begin
  ForceDirectories(SCRATCH_DIRECTORY);
  GarbagePath := SCRATCH_DIRECTORY + '/garbage-cert.pem';
  WriteTextFile(GarbagePath, 'not a certificate');
  ErrorMessage := CaptureContextError(GarbagePath, PRIVATE_KEY_PATH);
  Expect<Boolean>(Pos('Failed to load TLS certificate chain',
    ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(GarbagePath, ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestGarbagePrivateKeyPEMFailsActionably;
var
  GarbagePath: string;
  ErrorMessage: string;
begin
  ForceDirectories(SCRATCH_DIRECTORY);
  GarbagePath := SCRATCH_DIRECTORY + '/garbage-key.pem';
  WriteTextFile(GarbagePath, 'not a private key');
  ErrorMessage := CaptureContextError(CERTIFICATE_PATH, GarbagePath);
  Expect<Boolean>(Pos('Failed to load TLS private key',
    ErrorMessage) > 0).ToBe(True);
  Expect<Boolean>(Pos(GarbagePath, ErrorMessage) > 0).ToBe(True);
end;

procedure TTransportSecurityServerTests.TestAcceptRoundtripAndReuse;
{$IFNDEF DARWIN}
var
  Context: TTransportSecurityServerContext;
  FirstRoundtrip: TServerRoundtrip;
  SecondRoundtrip: TServerRoundtrip;
{$ENDIF}
begin
  {$IFNDEF DARWIN}
  Context := TTransportSecurityServerContext.Create(
    CERTIFICATE_PATH, PRIVATE_KEY_PATH);
  try
    FirstRoundtrip := RunRoundtrip(Context, CLIENT_REQUEST);
    SecondRoundtrip := RunRoundtrip(Context, SECOND_CLIENT_REQUEST);
    Expect<string>(string(FirstRoundtrip.ClientResponse)).ToBe(
      SERVER_RESPONSE);
    Expect<string>(string(FirstRoundtrip.ServerRequest)).ToBe(CLIENT_REQUEST);
    Expect<string>(FirstRoundtrip.ServerError).ToBe('');
    Expect<Boolean>(FirstRoundtrip.ConnectionWasActive).ToBe(True);
    Expect<Boolean>(FirstRoundtrip.ConnectionWasClosed).ToBe(True);
    Expect<string>(string(SecondRoundtrip.ClientResponse)).ToBe(
      SERVER_RESPONSE);
    Expect<string>(string(SecondRoundtrip.ServerRequest)).ToBe(
      SECOND_CLIENT_REQUEST);
    Expect<string>(SecondRoundtrip.ServerError).ToBe('');
    Expect<Boolean>(SecondRoundtrip.ConnectionWasActive).ToBe(True);
    Expect<Boolean>(SecondRoundtrip.ConnectionWasClosed).ToBe(True);
  finally
    CloseTransportSecurityServerContext(Context);
  end;
  Expect<Boolean>(not Assigned(Context)).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TTransportSecurityServerTests.SetupTests;
begin
  {$IFDEF DARWIN}
  Test('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS);
  Skip('missing PEM paths fail actionably', TestMissingPEMFailsActionably,
    DARWIN_SKIP_REASON);
  Skip('garbage certificate PEM fails actionably',
    TestGarbageCertificatePEMFailsActionably, DARWIN_SKIP_REASON);
  Skip('garbage private-key PEM fails actionably',
    TestGarbagePrivateKeyPEMFailsActionably, DARWIN_SKIP_REASON);
  Skip('TLS accept roundtrip reuses one server context',
    TestAcceptRoundtripAndReuse, DARWIN_SKIP_REASON);
  {$ELSE}
  Skip('Darwin server API reports Network.framework alternative',
    TestDarwinReportsUnsupportedServerTLS, 'Darwin-only behavior');
  Test('missing PEM paths fail actionably', TestMissingPEMFailsActionably);
  Test('garbage certificate PEM fails actionably',
    TestGarbageCertificatePEMFailsActionably);
  Test('garbage private-key PEM fails actionably',
    TestGarbagePrivateKeyPEMFailsActionably);
  Test('TLS accept roundtrip reuses one server context',
    TestAcceptRoundtripAndReuse);
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
var
  WSAData: TWSAData;
{$ENDIF}

begin
  {$IFDEF MSWINDOWS}
  if WSAStartup($0202, WSAData) <> 0 then
  begin
    WriteLn(ErrOutput, 'WSAStartup failed for TransportSecurity.Test');
    Halt(2);
  end;
  {$ENDIF}
  try
    TestRunnerProgram.AddSuite(TTransportSecurityServerTests.Create(
      'TransportSecurity: TLS server accept'));
    TestRunnerProgram.Run;
    ExitCode := TestResultToExitCode;
  finally
    {$IFDEF MSWINDOWS}
    WSACleanup;
    {$ENDIF}
  end;
end.
