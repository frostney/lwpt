unit TransportSecurity;

// Cross-platform TLS transport. Blocking clients use SecureTransport on
// macOS, SChannel on Windows, and OpenSSL on Unix. Nonblocking server accept
// uses memory-BIO OpenSSL on Windows and Unix-not-Darwin; macOS servers use
// Network.framework outside this unit.

{$I Shared.inc}

{$IFDEF MSWINDOWS}
{$DEFINE TRANSPORT_SECURITY_OPENSSL}
{$ENDIF}
{$IFDEF UNIX}
{$IFNDEF DARWIN}
{$DEFINE TRANSPORT_SECURITY_OPENSSL}
{$ENDIF}
{$ENDIF}

interface

uses
  SysUtils,
  {$IFDEF UNIX}
  Sockets
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2
  {$ENDIF}
  ;

type
  ETransportSecurityError = class(Exception);

  TTransportSecurityState = (
    tssDone,
    tssWantRead,
    tssWantWrite,
    tssError,
    tssPeerClosed
  );

  TTransportSecurityIOResult = record
    State: TTransportSecurityState;
    BytesProcessed: Integer;
  end;

  TTransportSecurityConnection = record
  public
    Active: Boolean;
  private
    Backend: Integer;
    Socket: TSocket;
    BackendData: Pointer;
  end;

  TTransportSecurityServerContext = class
  private
    FBackendData: Pointer;
  public
    constructor Create(const APkcs12Path: string;
      const APkcs12Passphrase: UnicodeString);
    destructor Destroy; override;
  end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string);
procedure CloseTransportSecurityServerContext(
  var AContext: TTransportSecurityServerContext);
function TransportSecurityServerBackendAvailable: Boolean;
procedure BeginTransportSecurityServer(
  var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
function TransportSecurityServerHandshake(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
function TransportSecurityFeedCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
function TransportSecurityPendingCiphertext(
  const AConnection: TTransportSecurityConnection): Integer;
function TransportSecurityGetCiphertext(
  var AConnection: TTransportSecurityConnection;
  out ABuffer: Pointer): Integer;
procedure TransportSecurityConsumeCiphertext(
  var AConnection: TTransportSecurityConnection; const ALength: Integer);
function TransportSecurityServerRead(
  var AConnection: TTransportSecurityConnection; var ABuffer: array of Byte;
  const ALength: Integer): TTransportSecurityIOResult;
function TransportSecurityServerWrite(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
function CloseTransportSecurityServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
procedure AbortTransportSecurityServer(
  var AConnection: TTransportSecurityConnection);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
{$IFNDEF PRODUCTION}
function TransportSecurityTestInjectSyscallError(
  var AConnection: TTransportSecurityConnection;
  out AObservedError: Integer): TTransportSecurityState;
{$ENDIF}
{$ENDIF}
procedure CloseTransportSecurity(var AConnection: TTransportSecurityConnection);
function TransportSecurityRead(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte; const ALength: Integer): Integer;
function TransportSecurityWrite(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer): Integer;

implementation

uses
  Classes,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  DynLibs,
  OpenSSL,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Math;

const
  TSB_NONE = 0;
  TSB_OPENSSL = 1;
  TSB_SECURE_TRANSPORT = 2;
  TSB_SCHANNEL = 3;
  TSB_OPENSSL_SERVER = 4;
  OPENSSL_LOAD_ERROR = 'HTTPS requires OpenSSL but it could not be loaded';
  OPENSSL_SERVER_LOAD_ERROR =
    'TLS server accept requires OpenSSL but it could not be loaded';
  TLS_SERVER_UNSUPPORTED_ERROR =
    'TLS server accept is not supported on macOS; use Network.framework for server TLS';
  TLS_HANDSHAKE_ERROR = 'TLS handshake failed';
  TLS_READ_ERROR = 'TLS read failed';
  TLS_WRITE_ERROR = 'TLS write failed';

function SocketSend(const ASock: TSocket; const ABuffer: Pointer;
  const ALength: Integer): Integer; inline;
begin
  {$IFDEF UNIX}
  Result := fpSend(ASock, ABuffer, ALength, 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.send(ASock, ABuffer^, ALength, 0);
  {$ENDIF}
end;

function SocketReceive(const ASock: TSocket; const ABuffer: Pointer;
  const ALength: Integer): Integer; inline;
begin
  {$IFDEF UNIX}
  Result := fpRecv(ASock, ABuffer, ALength, 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.recv(ASock, ABuffer^, ALength, 0);
  {$ENDIF}
end;

procedure SendSocketAll(const ASocket: TSocket; const ABuffer: Pointer;
  const ALength: Integer);
var
  Sent: Integer;
  Written: Integer;
begin
  Sent := 0;
  while Sent < ALength do
  begin
    Written := SocketSend(ASocket, Pointer(PtrUInt(ABuffer) + PtrUInt(Sent)),
      ALength - Sent);
    if Written <= 0 then
      raise ETransportSecurityError.Create(TLS_WRITE_ERROR);
    Inc(Sent, Written);
  end;
end;

{$IFDEF DARWIN}
{$linkframework Security}
{$linkframework CoreFoundation}

type
  OSStatus = LongInt;
  CFAllocatorRef = Pointer;
  SSLContextRef = Pointer;
  SSLConnectionRef = Pointer;
  SSLProtocolSide = Integer;
  SSLConnectionType = Integer;
  SSLProtocol = Integer;

const
  ERR_SEC_SUCCESS = 0;
  ERR_SSL_WOULD_BLOCK = -9803;
  ERR_SSL_CLOSED_GRACEFUL = -9805;
  ERR_SSL_CLOSED_ABORT = -9806;
  K_SSL_CLIENT_SIDE = 1;
  K_SSL_STREAM_TYPE = 0;
  K_TLS_PROTOCOL_12 = 8;

type
  TSecureTransportData = class
  public
    Socket: TSocket;
    Context: SSLContextRef;
  end;

  TSecureTransportReadFunc = function(AConnection: SSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
  TSecureTransportWriteFunc = function(AConnection: SSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;

function SSLCreateContext(AAllocator: CFAllocatorRef;
  AProtocolSide: SSLProtocolSide;
  AConnectionType: SSLConnectionType): SSLContextRef; cdecl;
  external name 'SSLCreateContext';
function SSLSetIOFuncs(AContext: SSLContextRef;
  AReadFunc: TSecureTransportReadFunc;
  AWriteFunc: TSecureTransportWriteFunc): OSStatus; cdecl;
  external name 'SSLSetIOFuncs';
function SSLSetConnection(AContext: SSLContextRef;
  AConnection: SSLConnectionRef): OSStatus; cdecl;
  external name 'SSLSetConnection';
function SSLSetPeerDomainName(AContext: SSLContextRef; APeerName: PAnsiChar;
  APeerNameLength: PtrUInt): OSStatus; cdecl;
  external name 'SSLSetPeerDomainName';
function SSLSetProtocolVersionMin(AContext: SSLContextRef;
  AVersion: SSLProtocol): OSStatus; cdecl;
  external name 'SSLSetProtocolVersionMin';
function SSLHandshake(AContext: SSLContextRef): OSStatus; cdecl;
  external name 'SSLHandshake';
function SSLRead(AContext: SSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): OSStatus; cdecl;
  external name 'SSLRead';
function SSLWrite(AContext: SSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): OSStatus; cdecl;
  external name 'SSLWrite';
function SSLClose(AContext: SSLContextRef): OSStatus; cdecl;
  external name 'SSLClose';
procedure CFRelease(ARef: Pointer); cdecl; external name 'CFRelease';

function SecureTransportSocketRead(AConnection: SSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
var
  Data: TSecureTransportData;
  RequestedLength: PtrUInt;
  ReadCount: Integer;
begin
  Data := TSecureTransportData(AConnection);
  RequestedLength := ADataLength;
  ReadCount := SocketReceive(Data.Socket, AData, ADataLength);
  if ReadCount > 0 then
  begin
    ADataLength := ReadCount;
    if PtrUInt(ReadCount) = RequestedLength then
      Result := ERR_SEC_SUCCESS
    else
      Result := ERR_SSL_WOULD_BLOCK;
  end
  else if ReadCount = 0 then
  begin
    ADataLength := 0;
    Result := ERR_SSL_CLOSED_GRACEFUL;
  end
  else
  begin
    ADataLength := 0;
    Result := ERR_SSL_CLOSED_ABORT;
  end;
end;

function SecureTransportSocketWrite(AConnection: SSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
var
  Data: TSecureTransportData;
  RequestedLength: PtrUInt;
  Written: Integer;
begin
  Data := TSecureTransportData(AConnection);
  RequestedLength := ADataLength;
  Written := SocketSend(Data.Socket, AData, ADataLength);
  if Written > 0 then
  begin
    ADataLength := Written;
    if PtrUInt(Written) = RequestedLength then
      Result := ERR_SEC_SUCCESS
    else
      Result := ERR_SSL_WOULD_BLOCK;
  end
  else
  begin
    ADataLength := 0;
    Result := ERR_SSL_CLOSED_ABORT;
  end;
end;

procedure StartSecureTransport(var AConnection: TTransportSecurityConnection;
  const AHost: string);
var
  Data: TSecureTransportData;
  HostName: AnsiString;
  Status: OSStatus;
begin
  Data := TSecureTransportData.Create;
  Data.Socket := AConnection.Socket;
  Data.Context := SSLCreateContext(nil, K_SSL_CLIENT_SIDE, K_SSL_STREAM_TYPE);
  if Data.Context = nil then
  begin
    Data.Free;
    raise ETransportSecurityError.Create('Failed to create SecureTransport context');
  end;

  try
    Status := SSLSetIOFuncs(Data.Context, SecureTransportSocketRead,
      SecureTransportSocketWrite);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.Create('Failed to set SecureTransport I/O callbacks');

    Status := SSLSetConnection(Data.Context, SSLConnectionRef(Data));
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.Create('Failed to bind SecureTransport socket');

    HostName := AnsiString(AHost);
    Status := SSLSetPeerDomainName(Data.Context, PAnsiChar(HostName),
      Length(HostName));
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.Create('Failed to set TLS server name');

    Status := SSLSetProtocolVersionMin(Data.Context, K_TLS_PROTOCOL_12);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.Create('Failed to set minimum TLS version');

    repeat
      Status := SSLHandshake(Data.Context);
    until Status <> ERR_SSL_WOULD_BLOCK;

    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt('%s: %d',
        [TLS_HANDSHAKE_ERROR, Status]);

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_SECURE_TRANSPORT;
    AConnection.Active := True;
  except
    CFRelease(Data.Context);
    Data.Free;
    raise;
  end;
end;

procedure CloseSecureTransport(var AConnection: TTransportSecurityConnection);
var
  Data: TSecureTransportData;
begin
  Data := TSecureTransportData(AConnection.BackendData);
  if Assigned(Data) then
  begin
    if Data.Context <> nil then
    begin
      SSLClose(Data.Context);
      CFRelease(Data.Context);
    end;
    Data.Free;
  end;
end;

function ReadSecureTransport(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte; const ALength: Integer): Integer;
var
  Data: TSecureTransportData;
  Processed: PtrUInt;
  Status: OSStatus;
begin
  Data := TSecureTransportData(AConnection.BackendData);
  Processed := 0;
  repeat
    Status := SSLRead(Data.Context, @ABuffer[0], ALength, Processed);
  until (Status <> ERR_SSL_WOULD_BLOCK) or (Processed > 0);
  if (Status <> ERR_SEC_SUCCESS) and (Status <> ERR_SSL_CLOSED_GRACEFUL) and
     (Status <> ERR_SSL_WOULD_BLOCK) then
    raise ETransportSecurityError.CreateFmt('%s: %d', [TLS_READ_ERROR, Status]);
  Result := Processed;
end;

function WriteSecureTransport(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer): Integer;
var
  Data: TSecureTransportData;
  Processed: PtrUInt;
  Status: OSStatus;
begin
  Data := TSecureTransportData(AConnection.BackendData);
  Processed := 0;
  repeat
    Status := SSLWrite(Data.Context, ABuffer, ALength, Processed);
  until (Status <> ERR_SSL_WOULD_BLOCK) or (Processed > 0);
  if (Status <> ERR_SEC_SUCCESS) and (Status <> ERR_SSL_WOULD_BLOCK) then
    raise ETransportSecurityError.CreateFmt('%s: %d', [TLS_WRITE_ERROR, Status]);
  Result := Processed;
end;
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_OPENSSL}
type
  TOpenSSLData = class
  public
    Context: PSSL_CTX;
    SSL: PSSL;
  end;

  TOpenSSLServerContextData = class
  public
    Context: PSSL_CTX;
  end;

  TOpenSSLServerData = class
  public
    HandshakeDone: Boolean;
    Output: TBytes;
    OutputOffset: Integer;
    PendingPlaintext: TBytes;
    ReadBIO: Pointer;
    SSL: PSSL;
    WriteBIO: Pointer;
  end;

  TSSLSetDefaultVerifyPaths = function(AContext: PSSL_CTX): LongInt; cdecl;
  TSSLSetHostName = function(ASSL: PSSL; AHost: PAnsiChar): LongInt; cdecl;
  TSSLMethodGetter = function: Pointer; cdecl;
  TBIOFree = function(ABIO: Pointer): LongInt; cdecl;
  TBIONew = function(AMethod: Pointer): Pointer; cdecl;
  TBIONewMemoryBuffer = function(ABuffer: Pointer;
    ALength: LongInt): Pointer; cdecl;
  TBIONewPair = function(out ABIOOne: Pointer; const AWriteBufferOne: PtrUInt;
    out ABIOTwo: Pointer; const AWriteBufferTwo: PtrUInt): LongInt; cdecl;
  TBIORead = function(ABIO, ABuffer: Pointer;
    ALength: LongInt): LongInt; cdecl;
  TBIOSMemory = function: Pointer; cdecl;
  TBIOWrite = function(ABIO, ABuffer: Pointer;
    ALength: LongInt): LongInt; cdecl;
  TBIOClearFlags = procedure(ABIO: Pointer; const AFlags: LongInt); cdecl;
  TOpenSSLStackFree = procedure(AStack: Pointer); cdecl;
  TOpenSSLStackNum = function(AStack: Pointer): LongInt; cdecl;
  TOpenSSLStackValue = function(AStack: Pointer;
    AIndex: LongInt): Pointer; cdecl;
  TOpenSSLVersionNumber = function: PtrUInt; cdecl;
  TPKCS12Parse = function(APKCS12: Pointer; APassphrase: PAnsiChar;
    out APrivateKey, ACertificate, AChain: Pointer): LongInt; cdecl;
  TSSLContextSetOptions = function(AContext: PSSL_CTX;
    const AOptions: QWord): QWord; cdecl;
  TSSLSetAcceptState = procedure(ASSL: PSSL); cdecl;
  TSSLSetBIO = procedure(ASSL: PSSL; AReadBIO, AWriteBIO: Pointer); cdecl;

const
  SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
  SSL_CTRL_CHAIN_CERT = 89;
  SSL_OP_NO_RENEGOTIATION = LongInt(1) shl 30;
  TLS1_2_VERSION = $0303;
  BIO_C_SET_BUF_MEM_EOF_RETURN = 130;
  BIO_CTRL_PENDING_COMMAND = 10;
  BIO_FLAGS_RETRY_MASK = $0F;
  MAX_PKCS12_IDENTITY_SIZE = 16 * 1024 * 1024;
  OPENSSL_BIO_PAIR_CAPACITY = 16 * 1024;
  OPENSSL_OUTPUT_CHUNK_SIZE = 16 * 1024;
  {$IFDEF MSWINDOWS}
  {$IFDEF WIN64}
  OPENSSL_VERSION_THREE_SSL_LIBRARY = 'libssl-3-x64.dll';
  OPENSSL_VERSION_THREE_CRYPTO_LIBRARY = 'libcrypto-3-x64.dll';
  {$ELSE}
  OPENSSL_VERSION_THREE_SSL_LIBRARY = 'libssl-3.dll';
  OPENSSL_VERSION_THREE_CRYPTO_LIBRARY = 'libcrypto-3.dll';
  {$ENDIF}
  {$ELSE}
  OPENSSL_VERSION_THREE = '.3';
  {$ENDIF}

var
  OpenSSLBIOFree: TBIOFree;
  OpenSSLBIONew: TBIONew;
  OpenSSLBIONewMemoryBuffer: TBIONewMemoryBuffer;
  OpenSSLBIONewPair: TBIONewPair;
  OpenSSLBIORead: TBIORead;
  OpenSSLBIOSMemory: TBIOSMemory;
  OpenSSLBIOWrite: TBIOWrite;
  OpenSSLStackFree: TOpenSSLStackFree;
  OpenSSLStackNum: TOpenSSLStackNum;
  OpenSSLStackValue: TOpenSSLStackValue;
  OpenSSLPKCS12Parse: TPKCS12Parse;
  OpenSSLSSLContextSetOptions: TSSLContextSetOptions;
  OpenSSLServerProceduresLoaded: Boolean;
  {$IFDEF MSWINDOWS}
  OpenSSLServerRuntimeLoadedSecurely: Boolean;
  {$ENDIF}
  OpenSSLSSLSetAcceptState: TSSLSetAcceptState;
  OpenSSLSSLSetBIO: TSSLSetBIO;

{$IFDEF UNIX}
procedure PreferOpenSSLVersionThree;
var
  I: Integer;
begin
  for I := High(DLLVersions) downto Low(DLLVersions) + 1 do
    DLLVersions[I] := DLLVersions[I - 1];
  DLLVersions[Low(DLLVersions)] := OPENSSL_VERSION_THREE;
end;

function TryUseOpenSSLPair(const ADirectory, AVersion: string): Boolean;
var
  SSLBase: string;
  CryptoBase: string;
begin
  SSLBase := IncludeTrailingPathDelimiter(ADirectory) + 'libssl';
  CryptoBase := IncludeTrailingPathDelimiter(ADirectory) + 'libcrypto';
  Result := FileExists(SSLBase + '.so' + AVersion) and
    FileExists(CryptoBase + '.so' + AVersion);
  if Result then
  begin
    DLLSSLName := SSLBase;
    DLLUtilName := CryptoBase;
    DLLVersions[Low(DLLVersions)] := AVersion;
  end;
end;
{$ENDIF}

procedure ConfigureOpenSSLLoading;
{$IFDEF UNIX}
const
  DIRECTORIES: array[0..7] of string = (
    '/lib/x86_64-linux-gnu',
    '/usr/lib/x86_64-linux-gnu',
    '/lib/aarch64-linux-gnu',
    '/usr/lib/aarch64-linux-gnu',
    '/lib64',
    '/usr/lib64',
    '/lib',
    '/usr/lib'
  );
  VERSIONS: array[0..2] of string = (
    '.3',
    '',
    '.1.1'
  );
var
  DirectoryIndex: Integer;
  VersionIndex: Integer;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  DLLSSLName := OPENSSL_VERSION_THREE_SSL_LIBRARY;
  DLLUtilName := OPENSSL_VERSION_THREE_CRYPTO_LIBRARY;
  {$ELSE}
  PreferOpenSSLVersionThree;
  for DirectoryIndex := Low(DIRECTORIES) to High(DIRECTORIES) do
    for VersionIndex := Low(VERSIONS) to High(VERSIONS) do
      if TryUseOpenSSLPair(DIRECTORIES[DirectoryIndex],
        VERSIONS[VersionIndex]) then
        Exit;
  {$ENDIF}
end;

function TryLoadOpenSSLServer: Boolean; forward;

function TryLoadOpenSSL: Boolean;
begin
  if IsSSLloaded then
  begin
    Result := True;
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  Result := TryLoadOpenSSLServer;
  {$ELSE}
  ConfigureOpenSSLLoading;
  Result := InitSSLInterface;
  {$ENDIF}
end;

function TryLoadOpenSSLServer: Boolean;
{$IFDEF MSWINDOWS}
const
  LOAD_LIBRARY_SEARCH_DEFAULT_DIRS_FLAG = $00001000;
  LOAD_LIBRARY_SEARCH_SYSTEM32_FLAG = $00000800;
var
  CryptoHandle: HMODULE;
  SearchFlags: LongWord;
  SSLHandle: HMODULE;
{$ENDIF}
{$IFDEF UNIX}
var
  I: Integer;
  SavedVersions: array[Low(DLLVersions)..High(DLLVersions)] of string;
{$ENDIF}
begin
  if IsSSLloaded then
  begin
    {$IFDEF MSWINDOWS}
    Result := OpenSSLServerRuntimeLoadedSecurely;
    {$ELSE}
    Result := True;
    {$ENDIF}
    Exit;
  end;

  {$IFDEF MSWINDOWS}
  ConfigureOpenSSLLoading;
  SearchFlags := LOAD_LIBRARY_SEARCH_DEFAULT_DIRS_FLAG or
    LOAD_LIBRARY_SEARCH_SYSTEM32_FLAG;
  CryptoHandle := Windows.LoadLibraryExW(PWideChar(WideString(
    OPENSSL_VERSION_THREE_CRYPTO_LIBRARY)), 0, SearchFlags);
  if CryptoHandle = 0 then
  begin
    Result := False;
    Exit;
  end;
  SSLHandle := Windows.LoadLibraryExW(PWideChar(WideString(
    OPENSSL_VERSION_THREE_SSL_LIBRARY)), 0, SearchFlags);
  if SSLHandle = 0 then
  begin
    Windows.FreeLibrary(CryptoHandle);
    Result := False;
    Exit;
  end;
  try
    Result := InitSSLInterface;
    OpenSSLServerRuntimeLoadedSecurely := Result;
  finally
    Windows.FreeLibrary(SSLHandle);
    Windows.FreeLibrary(CryptoHandle);
  end;
  {$ELSE}
  { Run the same directory scan the client load path uses, so the server
    resolves the same libraries instead of depending on the default loader
    search path. }
  ConfigureOpenSSLLoading;
  for I := Low(DLLVersions) to High(DLLVersions) do
  begin
    SavedVersions[I] := DLLVersions[I];
    DLLVersions[I] := OPENSSL_VERSION_THREE;
  end;
  try
    Result := InitSSLInterface;
    if not Result then
    begin
      for I := Low(DLLVersions) to High(DLLVersions) do
        DLLVersions[I] := '';
      Result := InitSSLInterface;
    end;
  finally
    for I := Low(DLLVersions) to High(DLLVersions) do
      DLLVersions[I] := SavedVersions[I];
  end;
  {$ENDIF}
end;

procedure LoadOpenSSLServerProcedures;
var
  BIONew: TBIONew;
  BIONewMemoryBuffer: TBIONewMemoryBuffer;
  BIONewPair: TBIONewPair;
  BIOFree: TBIOFree;
  BIORead: TBIORead;
  BIOSMemory: TBIOSMemory;
  BIOWrite: TBIOWrite;
  SSLSetAcceptState: TSSLSetAcceptState;
  SSLSetBIO: TSSLSetBIO;
  StackFree: TOpenSSLStackFree;
  StackNum: TOpenSSLStackNum;
  StackValue: TOpenSSLStackValue;
  PKCS12Parse: TPKCS12Parse;
  SSLContextSetOptions: TSSLContextSetOptions;
  VersionNumber: TOpenSSLVersionNumber;
begin
  if OpenSSLServerProceduresLoaded then
    Exit;

  BIOFree := TBIOFree(GetProcedureAddress(SSLUtilHandle,
    'BIO_free'));
  BIONew := TBIONew(GetProcedureAddress(SSLUtilHandle,
    'BIO_new'));
  BIONewMemoryBuffer := TBIONewMemoryBuffer(GetProcedureAddress(
    SSLUtilHandle, 'BIO_new_mem_buf'));
  BIONewPair := TBIONewPair(GetProcedureAddress(SSLUtilHandle,
    'BIO_new_bio_pair'));
  BIORead := TBIORead(GetProcedureAddress(SSLUtilHandle,
    'BIO_read'));
  BIOSMemory := TBIOSMemory(GetProcedureAddress(SSLUtilHandle,
    'BIO_s_mem'));
  BIOWrite := TBIOWrite(GetProcedureAddress(SSLUtilHandle,
    'BIO_write'));
  StackFree := TOpenSSLStackFree(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_free'));
  StackNum := TOpenSSLStackNum(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_num'));
  StackValue := TOpenSSLStackValue(GetProcedureAddress(
    SSLUtilHandle, 'OPENSSL_sk_value'));
  PKCS12Parse := TPKCS12Parse(GetProcedureAddress(SSLUtilHandle,
    'PKCS12_parse'));
  SSLContextSetOptions := TSSLContextSetOptions(GetProcedureAddress(
    SSLLibHandle, 'SSL_CTX_set_options'));
  VersionNumber := TOpenSSLVersionNumber(GetProcedureAddress(SSLUtilHandle,
    'OpenSSL_version_num'));
  SSLSetAcceptState := TSSLSetAcceptState(GetProcedureAddress(
    SSLLibHandle, 'SSL_set_accept_state'));
  SSLSetBIO := TSSLSetBIO(GetProcedureAddress(SSLLibHandle,
    'SSL_set_bio'));

  if not Assigned(BIOFree) or not Assigned(BIONew) or
     not Assigned(BIONewMemoryBuffer) or not Assigned(BIONewPair) or
     not Assigned(BIORead) or not Assigned(BIOSMemory) or
     not Assigned(BIOWrite) or not Assigned(StackFree) or
     not Assigned(StackNum) or not Assigned(StackValue) or
     not Assigned(PKCS12Parse) or
     not Assigned(SSLContextSetOptions) or
     not Assigned(VersionNumber) or not Assigned(SSLSetAcceptState) or
     not Assigned(SSLSetBIO) then
    raise ETransportSecurityError.Create(
      'OpenSSL runtime does not provide the required TLS server memory-BIO interface');

  if (VersionNumber() shr 28) < 3 then
    raise ETransportSecurityError.Create(
      'TLS server accept requires OpenSSL 3.0 or newer; install a supported OpenSSL 3 runtime');

  OpenSSLBIOFree := BIOFree;
  OpenSSLBIONew := BIONew;
  OpenSSLBIONewMemoryBuffer := BIONewMemoryBuffer;
  OpenSSLBIONewPair := BIONewPair;
  OpenSSLBIORead := BIORead;
  OpenSSLBIOSMemory := BIOSMemory;
  OpenSSLBIOWrite := BIOWrite;
  OpenSSLStackFree := StackFree;
  OpenSSLStackNum := StackNum;
  OpenSSLStackValue := StackValue;
  OpenSSLPKCS12Parse := PKCS12Parse;
  OpenSSLSSLContextSetOptions := SSLContextSetOptions;
  OpenSSLSSLSetAcceptState := SSLSetAcceptState;
  OpenSSLSSLSetBIO := SSLSetBIO;
  OpenSSLServerProceduresLoaded := True;
end;

procedure ConfigureOpenSSLVerification(const AContext: PSSL_CTX;
  const ASSL: PSSL; const AHost: string);
var
  SetDefaultVerifyPaths: TSSLSetDefaultVerifyPaths;
  SetHostName: TSSLSetHostName;
  HostName: AnsiString;
begin
  SetDefaultVerifyPaths := TSSLSetDefaultVerifyPaths(GetProcedureAddress(
    SSLLibHandle, 'SSL_CTX_set_default_verify_paths'));
  if Assigned(SetDefaultVerifyPaths) and (SetDefaultVerifyPaths(AContext) <> 1) then
    raise ETransportSecurityError.Create('Failed to load OpenSSL default certificate paths');

  SslCtxSetVerify(AContext, SSL_VERIFY_PEER, TSSLCTXVerifyCallback(nil));

  HostName := AnsiString(AHost);
  SetHostName := TSSLSetHostName(GetProcedureAddress(SSLLibHandle,
    'SSL_set1_host'));
  if not Assigned(SetHostName) then
    raise ETransportSecurityError.Create('OpenSSL library does not provide SSL_set1_host; hostname verification unavailable');
  if SetHostName(ASSL, PAnsiChar(HostName)) <> 1 then
    raise ETransportSecurityError.Create('Failed to configure OpenSSL host verification');
end;

function CreateOpenSSLContext: PSSL_CTX;
var
  GetMethod: TSSLMethodGetter;
begin
  GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
    'TLS_client_method'));
  if not Assigned(GetMethod) then
    GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
      'TLS_method'));
  if not Assigned(GetMethod) then
    raise ETransportSecurityError.Create('OpenSSL library does not provide a version-flexible TLS client method');

  Result := SslCtxNew(GetMethod());
  if not Assigned(Result) then
    raise ETransportSecurityError.Create('Failed to create OpenSSL context');

  if SslCTXCtrl(Result, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil) <= 0 then
  begin
    SslCtxFree(Result);
    raise ETransportSecurityError.Create('Failed to set minimum OpenSSL TLS version');
  end;
end;

function CreateOpenSSLServerContext: PSSL_CTX;
var
  GetMethod: TSSLMethodGetter;
begin
  GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
    'TLS_server_method'));
  if not Assigned(GetMethod) then
    GetMethod := TSSLMethodGetter(GetProcedureAddress(SSLLibHandle,
      'TLS_method'));
  if not Assigned(GetMethod) then
    raise ETransportSecurityError.Create(
      'OpenSSL library does not provide a version-flexible TLS server method');

  Result := SslCtxNew(GetMethod());
  if not Assigned(Result) then
    raise ETransportSecurityError.Create('Failed to create OpenSSL server context');

  if SslCTXCtrl(Result, SSL_CTRL_SET_MIN_PROTO_VERSION,
    TLS1_2_VERSION, nil) <= 0 then
  begin
    SslCtxFree(Result);
    raise ETransportSecurityError.Create(
      'Failed to set minimum OpenSSL server TLS version');
  end;

  if (OpenSSLSSLContextSetOptions(Result, SSL_OP_NO_RENEGOTIATION) and
    QWord(SSL_OP_NO_RENEGOTIATION)) = 0 then
  begin
    SslCtxFree(Result);
    raise ETransportSecurityError.Create(
      'Failed to disable OpenSSL server renegotiation');
  end;
end;

procedure StartOpenSSL(var AConnection: TTransportSecurityConnection;
  const AHost: string);
var
  Data: TOpenSSLData;
begin
  if not TryLoadOpenSSL then
    raise ETransportSecurityError.Create(OPENSSL_LOAD_ERROR);

  Data := TOpenSSLData.Create;
  Data.Context := nil;
  Data.SSL := nil;
  try
    Data.Context := CreateOpenSSLContext;

    Data.SSL := SslNew(Data.Context);
    if not Assigned(Data.SSL) then
      raise ETransportSecurityError.Create('Failed to create OpenSSL session');

    ConfigureOpenSSLVerification(Data.Context, Data.SSL, AHost);

    SslCtrl(Data.SSL, SSL_CTRL_SET_TLSEXT_HOSTNAME,
      TLSEXT_NAMETYPE_host_name, PAnsiChar(AnsiString(AHost)));

    SslSetFd(Data.SSL, AConnection.Socket);
    if SslConnect(Data.SSL) <= 0 then
      raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);

    if SSLGetVerifyResult(Data.SSL) <> X509_V_OK then
      raise ETransportSecurityError.Create('OpenSSL certificate verification failed');

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_OPENSSL;
    AConnection.Active := True;
  except
    if Assigned(Data.SSL) then
      SslFree(Data.SSL);
    if Assigned(Data.Context) then
      SslCtxFree(Data.Context);
    Data.Free;
    raise;
  end;
end;

procedure FreeOpenSSLServerData(const AData: TOpenSSLServerData);
begin
  if not Assigned(AData) then
    Exit;
  if Assigned(AData.SSL) then
    SslFree(AData.SSL);
  if Assigned(AData.WriteBIO) then
    OpenSSLBIOFree(AData.WriteBIO);
  AData.SSL := nil;
  AData.ReadBIO := nil;
  AData.WriteBIO := nil;
  if Length(AData.PendingPlaintext) > 0 then
    FillChar(AData.PendingPlaintext[0], Length(AData.PendingPlaintext), 0);
  SetLength(AData.PendingPlaintext, 0);
  AData.Free;
end;

procedure ResetTransportSecurityConnection(
  var AConnection: TTransportSecurityConnection); inline;
begin
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
end;

procedure PoisonOpenSSLServerConnection(
  var AConnection: TTransportSecurityConnection);
var
  Data: TOpenSSLServerData;
begin
  Data := TOpenSSLServerData(AConnection.BackendData);
  ResetTransportSecurityConnection(AConnection);
  FreeOpenSSLServerData(Data);
end;

function OpenSSLServerData(
  const AConnection: TTransportSecurityConnection): TOpenSSLServerData;
  inline;
begin
  if (AConnection.Backend = TSB_OPENSSL_SERVER) and
     Assigned(AConnection.BackendData) then
    Result := TOpenSSLServerData(AConnection.BackendData)
  else
    Result := nil;
end;

function CollectOpenSSLServerCiphertext(
  const AData: TOpenSSLServerData): Boolean;
var
  ChunkLength: Integer;
  ExistingLength: Integer;
  Pending: Int64;
  PendingLength: Integer;
  ReadCount: Integer;
begin
  Result := False;
  if not Assigned(AData) or not Assigned(AData.WriteBIO) then
    Exit;

  PendingLength := Length(AData.Output) - AData.OutputOffset;
  if (AData.OutputOffset > 0) and (PendingLength > 0) then
    Move(AData.Output[AData.OutputOffset], AData.Output[0], PendingLength);
  if AData.OutputOffset > 0 then
  begin
    SetLength(AData.Output, PendingLength);
    AData.OutputOffset := 0;
  end;

  repeat
    Pending := BIO_ctrl(AData.WriteBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
    if Pending <= 0 then
      Break;
    if Pending > OPENSSL_OUTPUT_CHUNK_SIZE then
      ChunkLength := OPENSSL_OUTPUT_CHUNK_SIZE
    else
      ChunkLength := Integer(Pending);
    ExistingLength := Length(AData.Output);
    SetLength(AData.Output, ExistingLength + ChunkLength);
    ReadCount := OpenSSLBIORead(AData.WriteBIO,
      @AData.Output[ExistingLength], ChunkLength);
    if ReadCount <= 0 then
    begin
      SetLength(AData.Output, ExistingLength);
      Exit;
    end;
    if ReadCount < ChunkLength then
      SetLength(AData.Output, ExistingLength + ReadCount);
  until False;
  Result := True;
end;

function OpenSSLServerPendingCiphertext(
  const AData: TOpenSSLServerData): Integer; inline;
begin
  if Assigned(AData) then
    Result := Length(AData.Output) - AData.OutputOffset
  else
    Result := 0;
end;

type
  TOpenSSLServerOperation = (
    osoHandshake,
    osoRead,
    osoWrite,
    osoClose
  );

function OpenSSLServerErrorState(var AConnection: TTransportSecurityConnection;
  const AData: TOpenSSLServerData; const AErrorCode: Integer;
  const AOperation: TOpenSSLServerOperation): TTransportSecurityState;
begin
  if (AErrorCode <> SSL_ERROR_WANT_READ) and
     (AErrorCode <> SSL_ERROR_WANT_WRITE) and
     (AErrorCode <> SSL_ERROR_ZERO_RETURN) then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;

  if AErrorCode = SSL_ERROR_ZERO_RETURN then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    if AOperation = osoRead then
      Result := tssPeerClosed
    else if AOperation = osoClose then
      Result := tssDone
    else
      Result := tssError;
    Exit;
  end;

  if not CollectOpenSSLServerCiphertext(AData) then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;

  if OpenSSLServerPendingCiphertext(AData) > 0 then
  begin
    Result := tssWantWrite;
    Exit;
  end;

  case AErrorCode of
    SSL_ERROR_WANT_READ:
      Result := tssWantRead;
    SSL_ERROR_WANT_WRITE:
      Result := tssWantWrite;
  end;
end;

procedure BeginOpenSSLServer(var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
var
  BIOsOwnedBySSL: Boolean;
  ContextData: TOpenSSLServerContextData;
  Data: TOpenSSLServerData;
  SSLWriteBIO: Pointer;
begin
  ContextData := TOpenSSLServerContextData(AContext.FBackendData);
  if not Assigned(ContextData) or not Assigned(ContextData.Context) then
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');

  Data := TOpenSSLServerData.Create;
  BIOsOwnedBySSL := False;
  SSLWriteBIO := nil;
  try
    Data.SSL := SslNew(ContextData.Context);
    if not Assigned(Data.SSL) then
      raise ETransportSecurityError.Create(
        'Failed to create OpenSSL server session');

    Data.ReadBIO := OpenSSLBIONew(OpenSSLBIOSMemory());
    if (not Assigned(Data.ReadBIO)) or
       (OpenSSLBIONewPair(SSLWriteBIO, OPENSSL_BIO_PAIR_CAPACITY,
       Data.WriteBIO, OPENSSL_BIO_PAIR_CAPACITY) <> 1) then
      raise ETransportSecurityError.Create(
        'Failed to create OpenSSL server memory BIOs');
    if BIO_ctrl(Data.ReadBIO, BIO_C_SET_BUF_MEM_EOF_RETURN, -1, nil) <= 0 then
      raise ETransportSecurityError.Create(
        'Failed to configure OpenSSL server read BIO');

    OpenSSLSSLSetBIO(Data.SSL, Data.ReadBIO, SSLWriteBIO);
    BIOsOwnedBySSL := True;
    SSLWriteBIO := nil;
    OpenSSLSSLSetAcceptState(Data.SSL);

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_OPENSSL_SERVER;
  except
    if not BIOsOwnedBySSL then
    begin
      if Assigned(Data.ReadBIO) then
        OpenSSLBIOFree(Data.ReadBIO);
      if Assigned(SSLWriteBIO) then
        OpenSSLBIOFree(SSLWriteBIO);
      if Assigned(Data.WriteBIO) then
        OpenSSLBIOFree(Data.WriteBIO);
      Data.ReadBIO := nil;
      SSLWriteBIO := nil;
      Data.WriteBIO := nil;
    end;
    FreeOpenSSLServerData(Data);
    raise;
  end;
end;

function HandshakeOpenSSLServer(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  AcceptResult: Integer;
  Data: TOpenSSLServerData;
  ErrorCode: Integer;
begin
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) then
  begin
    Result := tssError;
    Exit;
  end;
  if Data.HandshakeDone then
  begin
    if OpenSSLServerPendingCiphertext(Data) > 0 then
      Result := tssWantWrite
    else
      Result := tssDone;
    Exit;
  end;
  if OpenSSLServerPendingCiphertext(Data) > 0 then
  begin
    Result := tssWantWrite;
    Exit;
  end;

  ErrClearError;
  AcceptResult := SslAccept(Data.SSL);
  if AcceptResult <= 0 then
    ErrorCode := SslGetError(Data.SSL, AcceptResult)
  else
    ErrorCode := SSL_ERROR_NONE;

  if AcceptResult = 1 then
  begin
    Data.HandshakeDone := True;
    AConnection.Active := True;
    if not CollectOpenSSLServerCiphertext(Data) then
    begin
      PoisonOpenSSLServerConnection(AConnection);
      Result := tssError;
    end
    else if OpenSSLServerPendingCiphertext(Data) > 0 then
      Result := tssWantWrite
    else
      Result := tssDone;
    Exit;
  end;

  Result := OpenSSLServerErrorState(AConnection, Data, ErrorCode,
    osoHandshake);
end;

function FeedOpenSSLServerCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
var
  Data: TOpenSSLServerData;
begin
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) then
  begin
    Result := -1;
    Exit;
  end;
  if ALength <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  if not Assigned(ABuffer) then
    raise ETransportSecurityError.Create(
      'TLS ciphertext input buffer is nil');

  Result := OpenSSLBIOWrite(Data.ReadBIO, ABuffer, ALength);
  if Result <= 0 then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := -1;
  end;
end;

function ReadOpenSSLServer(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte;
  const ALength: Integer): TTransportSecurityIOResult;
var
  Data: TOpenSSLServerData;
  ErrorCode: Integer;
  ReadLength: Integer;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit;
  if Length(Data.PendingPlaintext) > 0 then
    raise ETransportSecurityError.Create(
      'TLS write retry is pending; resume it before reading');
  if OpenSSLServerPendingCiphertext(Data) > 0 then
  begin
    Result.State := tssWantWrite;
    Exit;
  end;

  ReadLength := ALength;
  if ReadLength > Length(ABuffer) then
    ReadLength := Length(ABuffer);
  if ReadLength <= 0 then
  begin
    Result.State := tssDone;
    Exit;
  end;

  ErrClearError;
  Result.BytesProcessed := SslRead(Data.SSL, @ABuffer[0], ReadLength);
  if Result.BytesProcessed <= 0 then
    ErrorCode := SslGetError(Data.SSL, Result.BytesProcessed)
  else
    ErrorCode := SSL_ERROR_NONE;

  if Result.BytesProcessed > 0 then
  begin
    if not CollectOpenSSLServerCiphertext(Data) then
    begin
      Result.BytesProcessed := 0;
      PoisonOpenSSLServerConnection(AConnection);
      Exit;
    end;
    if OpenSSLServerPendingCiphertext(Data) > 0 then
      Result.State := tssWantWrite
    else
      Result.State := tssDone;
    Exit;
  end;

  Result.BytesProcessed := 0;
  Result.State := OpenSSLServerErrorState(AConnection, Data, ErrorCode,
    osoRead);
end;

function WriteOpenSSLServer(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
var
  Data: TOpenSSLServerData;
  ErrorCode: Integer;
  PendingLength: Integer;
  Retrying: Boolean;
  WriteResult: Integer;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit;
  if OpenSSLServerPendingCiphertext(Data) > 0 then
  begin
    Result.State := tssWantWrite;
    Exit;
  end;

  Retrying := Length(Data.PendingPlaintext) > 0;
  if Retrying and ((ALength <> 0) or Assigned(ABuffer)) then
    raise ETransportSecurityError.Create(
      'TLS write retry is pending; resume it with a nil, zero-length buffer');
  if not Retrying then
  begin
    if ALength <= 0 then
    begin
      Result.State := tssDone;
      Exit;
    end;
    if not Assigned(ABuffer) then
      raise ETransportSecurityError.Create(
        'TLS plaintext output buffer is nil');
    SetLength(Data.PendingPlaintext, ALength);
    Move(ABuffer^, Data.PendingPlaintext[0], ALength);
  end;

  PendingLength := Length(Data.PendingPlaintext);
  ErrClearError;
  WriteResult := SslWrite(Data.SSL, @Data.PendingPlaintext[0], PendingLength);
  if WriteResult <= 0 then
    ErrorCode := SslGetError(Data.SSL, WriteResult)
  else
    ErrorCode := SSL_ERROR_NONE;

  if WriteResult > 0 then
  begin
    Result.BytesProcessed := WriteResult;
    if WriteResult < PendingLength then
    begin
      Move(Data.PendingPlaintext[WriteResult], Data.PendingPlaintext[0],
        PendingLength - WriteResult);
      FillChar(Data.PendingPlaintext[PendingLength - WriteResult],
        WriteResult, 0);
      SetLength(Data.PendingPlaintext, PendingLength - WriteResult);
    end
    else
    begin
      FillChar(Data.PendingPlaintext[0], PendingLength, 0);
      SetLength(Data.PendingPlaintext, 0);
    end;
    if not CollectOpenSSLServerCiphertext(Data) then
    begin
      Result.BytesProcessed := 0;
      PoisonOpenSSLServerConnection(AConnection);
      Exit;
    end;
    if OpenSSLServerPendingCiphertext(Data) > 0 then
      Result.State := tssWantWrite
    else if Length(Data.PendingPlaintext) > 0 then
      Result.State := tssWantWrite
    else
      Result.State := tssDone;
    Exit;
  end;

  Result.BytesProcessed := 0;
  Result.State := OpenSSLServerErrorState(AConnection, Data, ErrorCode,
    osoWrite);
end;

function CloseOpenSSLServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  Data: TOpenSSLServerData;
  ErrorCode: Integer;
  ShutdownResult: Integer;
begin
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) then
  begin
    Result := tssError;
    Exit;
  end;
  if OpenSSLServerPendingCiphertext(Data) > 0 then
  begin
    Result := tssWantWrite;
    Exit;
  end;
  if Length(Data.PendingPlaintext) > 0 then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;
  if not Data.HandshakeDone then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;

  ErrClearError;
  ShutdownResult := SslShutdown(Data.SSL);
  if ShutdownResult < 0 then
    ErrorCode := SslGetError(Data.SSL, ShutdownResult)
  else
    ErrorCode := SSL_ERROR_NONE;
  if ShutdownResult < 0 then
  begin
    Result := OpenSSLServerErrorState(AConnection, Data, ErrorCode,
      osoClose);
    Exit;
  end;
  if not CollectOpenSSLServerCiphertext(Data) then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;
  if OpenSSLServerPendingCiphertext(Data) > 0 then
  begin
    Result := tssWantWrite;
    Exit;
  end;
  if ShutdownResult = 1 then
    Result := tssDone
  else
    Result := tssWantRead;
end;

procedure CloseOpenSSL(var AConnection: TTransportSecurityConnection);
var
  Data: TOpenSSLData;
begin
  Data := TOpenSSLData(AConnection.BackendData);
  if Assigned(Data) then
  begin
    if Assigned(Data.SSL) then
    begin
      SslShutdown(Data.SSL);
      SslFree(Data.SSL);
    end;
    if Assigned(Data.Context) then
      SslCtxFree(Data.Context);
    Data.Free;
  end;
end;

function ReadOpenSSL(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte; const ALength: Integer): Integer;
var
  Data: TOpenSSLData;
  ErrorCode: Integer;
begin
  Data := TOpenSSLData(AConnection.BackendData);
  repeat
    ErrClearError;
    Result := SslRead(Data.SSL, @ABuffer[0], ALength);
    if Result > 0 then
      Exit;

    ErrorCode := SslGetError(Data.SSL, Result);
    case ErrorCode of
      SSL_ERROR_ZERO_RETURN:
        begin
          Result := 0;
          Exit;
        end;
      SSL_ERROR_WANT_READ,
      SSL_ERROR_WANT_WRITE:
        Continue;
    else
      raise ETransportSecurityError.CreateFmt('%s: %d',
        [TLS_READ_ERROR, ErrorCode]);
    end;
  until False;
end;

function WriteOpenSSL(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer): Integer;
var
  Data: TOpenSSLData;
  ErrorCode: Integer;
begin
  Data := TOpenSSLData(AConnection.BackendData);
  repeat
    ErrClearError;
    Result := SslWrite(Data.SSL, ABuffer, ALength);
    if Result > 0 then
      Exit;

    ErrorCode := SslGetError(Data.SSL, Result);
    case ErrorCode of
      SSL_ERROR_ZERO_RETURN:
        begin
          Result := 0;
          Exit;
        end;
      SSL_ERROR_WANT_READ,
      SSL_ERROR_WANT_WRITE:
        Continue;
    else
      raise ETransportSecurityError.CreateFmt('%s: %d',
        [TLS_WRITE_ERROR, ErrorCode]);
    end;
  until False;
end;

function LoadPKCS12Bytes(const APath: string): TBytes;
var
  Input: TFileStream;
begin
  Result := nil;
  if not FileExists(APath) then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity file does not exist');
  try
    Input := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      if Input.Size <= 0 then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 identity file is empty');
      if Input.Size > MAX_PKCS12_IDENTITY_SIZE then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
      SetLength(Result, Integer(Input.Size));
      Input.ReadBuffer(Result[0], Length(Result));
    finally
      Input.Free;
    end;
  except
    on E: ETransportSecurityError do
      raise;
    on E: Exception do
      raise ETransportSecurityError.Create(
        'Failed to read configured TLS PKCS#12 identity file');
  end;
end;

procedure WipeBytes(var ABytes: TBytes);
begin
  if Length(ABytes) > 0 then
    FillChar(ABytes[0], Length(ABytes), 0);
  SetLength(ABytes, 0);
end;

procedure WipeUTF8String(var AValue: UTF8String);
begin
  if Length(AValue) > 0 then
    FillChar(PAnsiChar(AValue)^, Length(AValue), 0);
  AValue := '';
end;

procedure FreePKCS12Chain(const AChain: Pointer);
var
  Certificate: Pointer;
  I: Integer;
begin
  if not Assigned(AChain) then
    Exit;
  for I := 0 to OpenSSLStackNum(AChain) - 1 do
  begin
    Certificate := OpenSSLStackValue(AChain, I);
    if Assigned(Certificate) then
      X509Free(Certificate);
  end;
  OpenSSLStackFree(AChain);
end;

procedure ConfigureOpenSSLServerIdentity(const AContext: PSSL_CTX;
  var AIdentity: TBytes; const APassphrase: UnicodeString);
var
  Certificate: Pointer;
  Chain: Pointer;
  ChainCertificate: Pointer;
  EmptyPassphrase: AnsiChar;
  I: Integer;
  IdentityBIO: Pointer;
  Passphrase: UTF8String;
  PassphrasePointer: PAnsiChar;
  PKCS12: Pointer;
  PrivateKey: Pointer;
begin
  Certificate := nil;
  Chain := nil;
  EmptyPassphrase := #0;
  IdentityBIO := nil;
  Passphrase := '';
  PassphrasePointer := @EmptyPassphrase;
  PKCS12 := nil;
  PrivateKey := nil;
  try
    if Pos(#0, APassphrase) > 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 passphrase contains an embedded NUL');
    Passphrase := UTF8Encode(APassphrase);
    if Length(Passphrase) > 0 then
      PassphrasePointer := PAnsiChar(Passphrase);
    IdentityBIO := OpenSSLBIONewMemoryBuffer(@AIdentity[0],
      Length(AIdentity));
    if not Assigned(IdentityBIO) then
      raise ETransportSecurityError.Create(
        'Failed to read configured TLS PKCS#12 identity');
    PKCS12 := d2iPKCS12bio(IdentityBIO, nil);
    if not Assigned(PKCS12) then
      raise ETransportSecurityError.Create(
        'Failed to parse configured TLS PKCS#12 identity; verify the bundle and passphrase');

    if OpenSSLPKCS12Parse(PKCS12, PassphrasePointer, PrivateKey,
      Certificate, Chain) <> 1 then
      raise ETransportSecurityError.Create(
        'Failed to parse configured TLS PKCS#12 identity; verify the bundle and passphrase');
    if not Assigned(Certificate) or not Assigned(PrivateKey) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain a certificate and private key');

    if SslCtxUseCertificate(AContext, Certificate) <> 1 then
      raise ETransportSecurityError.Create(
        'Failed to configure the certificate from the TLS PKCS#12 identity');
    if SslCtxUsePrivateKey(AContext, PrivateKey) <> 1 then
      raise ETransportSecurityError.Create(
        'Failed to configure the private key from the TLS PKCS#12 identity');
    if Assigned(Chain) then
      for I := 0 to OpenSSLStackNum(Chain) - 1 do
      begin
        ChainCertificate := OpenSSLStackValue(Chain, I);
        if Assigned(ChainCertificate) and
           (SslCTXCtrl(AContext, SSL_CTRL_CHAIN_CERT, 1,
           ChainCertificate) <= 0) then
          raise ETransportSecurityError.Create(
            'Failed to configure the certificate chain from the TLS PKCS#12 identity');
      end;
    if SslCtxCheckPrivateKeyFile(AContext) <> 1 then
      raise ETransportSecurityError.Create(
        'The certificate and private key in the TLS PKCS#12 identity do not match');
  finally
    FreePKCS12Chain(Chain);
    if Assigned(Certificate) then
      X509Free(Certificate);
    if Assigned(PrivateKey) then
      EVP_PKEY_free(PrivateKey);
    if Assigned(PKCS12) then
      PKCS12free(PKCS12);
    if Assigned(IdentityBIO) then
      OpenSSLBIOFree(IdentityBIO);
    WipeUTF8String(Passphrase);
    WipeBytes(AIdentity);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
type
  SECURITY_STATUS = LongInt;
  SECURITY_INTEGER = Int64;
  PSecurityInteger = ^SECURITY_INTEGER;
  ULONG_PTR = PtrUInt;

  PSecHandle = ^TSecHandle;
  TSecHandle = record
    Lower: ULONG_PTR;
    Upper: ULONG_PTR;
  end;

  PCredHandle = PSecHandle;
  PCtxtHandle = PSecHandle;

  PSecBuffer = ^TSecBuffer;
  TSecBuffer = record
    cbBuffer: LongWord;
    BufferType: LongWord;
    pvBuffer: Pointer;
  end;

  PSecBufferDesc = ^TSecBufferDesc;
  TSecBufferDesc = record
    ulVersion: LongWord;
    cBuffers: LongWord;
    pBuffers: PSecBuffer;
  end;

  PSecPkgContextStreamSizes = ^TSecPkgContextStreamSizes;
  TSecPkgContextStreamSizes = record
    cbHeader: LongWord;
    cbTrailer: LongWord;
    cbMaximumMessage: LongWord;
    cBuffers: LongWord;
    cbBlockSize: LongWord;
  end;

  PSchannelCred = ^TSchannelCred;
  TSchannelCred = record
    dwVersion: LongWord;
    cCreds: LongWord;
    paCred: Pointer;
    hRootStore: Pointer;
    cMappers: LongWord;
    aphMappers: Pointer;
    cSupportedAlgs: LongWord;
    palgSupportedAlgs: Pointer;
    grbitEnabledProtocols: LongWord;
    dwMinimumCipherStrength: LongWord;
    dwMaximumCipherStrength: LongWord;
    dwSessionLifespan: LongWord;
    dwFlags: LongWord;
    dwCredFormat: LongWord;
  end;

  TSChannelData = class
  public
    Socket: TSocket;
    Credential: TSecHandle;
    Context: TSecHandle;
    HasContext: Boolean;
    StreamSizes: TSecPkgContextStreamSizes;
    EncryptedInput: TBytes;
    DecryptedInput: TBytes;
    DecryptedOffset: Integer;
  end;

const
  SECPKG_CRED_OUTBOUND = 2;
  SECBUFFER_VERSION = 0;
  SECBUFFER_EMPTY = 0;
  SECBUFFER_DATA = 1;
  SECBUFFER_TOKEN = 2;
  SECBUFFER_EXTRA = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER = 7;
  SECPKG_ATTR_STREAM_SIZES = 4;
  SEC_E_OK = SECURITY_STATUS($00000000);
  SEC_I_CONTINUE_NEEDED = SECURITY_STATUS($00090312);
  SEC_I_CONTEXT_EXPIRED = SECURITY_STATUS($00090317);
  SEC_E_INCOMPLETE_MESSAGE = SECURITY_STATUS($80090318);
  SEC_I_INCOMPLETE_CREDENTIALS = SECURITY_STATUS($00090320);
  SEC_I_RENEGOTIATE = SECURITY_STATUS($00090321);
  ISC_REQ_SEQUENCE_DETECT = $00000008;
  ISC_REQ_REPLAY_DETECT = $00000004;
  ISC_REQ_CONFIDENTIALITY = $00000010;
  ISC_REQ_EXTENDED_ERROR = $00004000;
  ISC_REQ_ALLOCATE_MEMORY = $00000100;
  ISC_REQ_STREAM = $00008000;
  SCHANNEL_CRED_VERSION = 4;
  SCH_USE_STRONG_CRYPTO = $00400000;
  SCHANNEL_SHUTDOWN = 1;
  SECURITY_NATIVE_DREP = $00000010;
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';
  SECBUFFER_ATTRMASK = $F0000000;

function AcquireCredentialsHandleW(APrincipal: PWideChar; APackage: PWideChar;
  ACredentialUse: LongWord; ALogonId: Pointer; AAuthData: Pointer;
  AGetKeyFn: Pointer; AGetKeyArgument: Pointer; ACredential: PCredHandle;
  AExpiry: PSecurityInteger): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'AcquireCredentialsHandleW';
function InitializeSecurityContextW(ACredential: PCredHandle;
  AContext: PCtxtHandle; ATargetName: PWideChar; AContextRequirements: LongWord;
  AReserved: LongWord; ATargetDataRepresentation: LongWord;
  AInput: PSecBufferDesc; AReservedTwo: LongWord; ANewContext: PCtxtHandle;
  AOutput: PSecBufferDesc; AContextAttributes: PLongWord;
  AExpiry: PSecurityInteger): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'InitializeSecurityContextW';
function QueryContextAttributesW(AContext: PCtxtHandle; AAttribute: LongWord;
  ABuffer: Pointer): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'QueryContextAttributesW';
function EncryptMessage(AContext: PCtxtHandle; AFQualityOfProtection: LongWord;
  AMessage: PSecBufferDesc; AMessageSequenceNumber: LongWord): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'EncryptMessage';
function DecryptMessage(AContext: PCtxtHandle; AMessage: PSecBufferDesc;
  AMessageSequenceNumber: LongWord; AQualityOfProtection: PLongWord): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'DecryptMessage';
function ApplyControlToken(AContext: PCtxtHandle; AInput: PSecBufferDesc): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'ApplyControlToken';
function FreeContextBuffer(ABuffer: Pointer): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'FreeContextBuffer';
function DeleteSecurityContext(AContext: PCtxtHandle): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'DeleteSecurityContext';
function FreeCredentialsHandle(ACredential: PCredHandle): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'FreeCredentialsHandle';

function SecBufferKind(const ABufferType: LongWord): LongWord; inline;
begin
  Result := ABufferType and not SECBUFFER_ATTRMASK;
end;

procedure AppendBytes(var ATarget: TBytes; const ASource: Pointer;
  const ALength: Integer);
var
  PreviousLength: Integer;
begin
  if ALength <= 0 then
    Exit;
  if not Assigned(ASource) then
    raise ETransportSecurityError.Create('SChannel returned a byte buffer without a pointer');
  PreviousLength := Length(ATarget);
  SetLength(ATarget, PreviousLength + ALength);
  Move(ASource^, ATarget[PreviousLength], ALength);
end;

procedure AppendExtraBytes(var ATarget: TBytes; const AInput: TBytes;
  const ASource: Pointer; const ALength: Integer);
var
  PreviousLength: Integer;
  SourceOffset: Integer;
begin
  if ALength <= 0 then
    Exit;

  PreviousLength := Length(ATarget);
  SetLength(ATarget, PreviousLength + ALength);
  if Assigned(ASource) then
    Move(ASource^, ATarget[PreviousLength], ALength)
  else
  begin
    if ALength > Length(AInput) then
      raise ETransportSecurityError.Create('SChannel reported extra bytes outside the input buffer');
    SourceOffset := Length(AInput) - ALength;
    Move(AInput[SourceOffset], ATarget[PreviousLength], ALength);
  end;
end;

procedure PreserveExtraBytes(var ATarget: TBytes; const ASource: Pointer;
  const ALength: Integer);
var
  Temporary: TBytes;
begin
  if ALength <= 0 then
  begin
    SetLength(ATarget, 0);
    Exit;
  end;

  SetLength(Temporary, 0);
  AppendExtraBytes(Temporary, ATarget, ASource, ALength);
  ATarget := Temporary;
end;

function ReceiveIntoBuffer(const ASocket: TSocket; var ABuffer: TBytes): Integer;
var
  Temporary: array[0..8191] of Byte;
begin
  Result := SocketReceive(ASocket, @Temporary[0], Length(Temporary));
  if Result > 0 then
    AppendBytes(ABuffer, @Temporary[0], Result);
end;

procedure SendSChannelToken(const ASocket: TSocket; const ABuffer: TSecBuffer);
begin
  if (ABuffer.cbBuffer > 0) and Assigned(ABuffer.pvBuffer) then
    SendSocketAll(ASocket, ABuffer.pvBuffer, ABuffer.cbBuffer);
end;

function SChannelRequestFlags: LongWord;
begin
  Result := ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_STREAM;
end;

procedure StartSChannel(var AConnection: TTransportSecurityConnection;
  const AHost: string);
var
  Data: TSChannelData;
  Credential: TSchannelCred;
  Status: SECURITY_STATUS;
  Expiry: SECURITY_INTEGER;
  ContextAttributes: LongWord;
  OutputBuffer: TSecBuffer;
  OutputDesc: TSecBufferDesc;
  InputBuffers: array[0..1] of TSecBuffer;
  InputDesc: TSecBufferDesc;
  TargetName: WideString;
  InputDescPointer: PSecBufferDesc;
  ExistingContext: PCtxtHandle;
  ReceiveCount: Integer;
begin
  Data := TSChannelData.Create;
  FillChar(Data.Credential, SizeOf(Data.Credential), 0);
  FillChar(Data.Context, SizeOf(Data.Context), 0);
  FillChar(Data.StreamSizes, SizeOf(Data.StreamSizes), 0);
  Data.Socket := AConnection.Socket;
  Data.HasContext := False;

  FillChar(Credential, SizeOf(Credential), 0);
  Credential.dwVersion := SCHANNEL_CRED_VERSION;
  Credential.dwFlags := SCH_USE_STRONG_CRYPTO;

  Status := AcquireCredentialsHandleW(nil, PWideChar(WideString(UNISP_NAME)),
    SECPKG_CRED_OUTBOUND, nil, @Credential, nil, nil, @Data.Credential,
    @Expiry);
  if Status <> SEC_E_OK then
  begin
    Data.Free;
    raise ETransportSecurityError.CreateFmt('Failed to acquire SChannel credentials: 0x%x',
      [LongWord(Status)]);
  end;

  TargetName := WideString(AHost);
  try
    repeat
      FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
      OutputBuffer.BufferType := SECBUFFER_TOKEN;
      FillChar(OutputDesc, SizeOf(OutputDesc), 0);
      OutputDesc.ulVersion := SECBUFFER_VERSION;
      OutputDesc.cBuffers := 1;
      OutputDesc.pBuffers := @OutputBuffer;

      InputDescPointer := nil;
      if Length(Data.EncryptedInput) > 0 then
      begin
        FillChar(InputBuffers, SizeOf(InputBuffers), 0);
        InputBuffers[0].BufferType := SECBUFFER_TOKEN;
        InputBuffers[0].cbBuffer := Length(Data.EncryptedInput);
        InputBuffers[0].pvBuffer := @Data.EncryptedInput[0];
        InputBuffers[1].BufferType := SECBUFFER_EMPTY;
        InputDesc.ulVersion := SECBUFFER_VERSION;
        InputDesc.cBuffers := 2;
        InputDesc.pBuffers := @InputBuffers[0];
        InputDescPointer := @InputDesc;
      end;

      if Data.HasContext then
        ExistingContext := @Data.Context
      else
        ExistingContext := nil;

      Status := InitializeSecurityContextW(@Data.Credential, ExistingContext,
        PWideChar(TargetName), SChannelRequestFlags, 0,
        SECURITY_NATIVE_DREP, InputDescPointer, 0, @Data.Context, @OutputDesc,
        @ContextAttributes, @Expiry);
      Data.HasContext := True;

      SendSChannelToken(Data.Socket, OutputBuffer);
      if Assigned(OutputBuffer.pvBuffer) then
        FreeContextBuffer(OutputBuffer.pvBuffer);

      if Status = SEC_E_INCOMPLETE_MESSAGE then
      begin
        ReceiveCount := ReceiveIntoBuffer(Data.Socket, Data.EncryptedInput);
        if ReceiveCount < 0 then
          raise ETransportSecurityError.Create(TLS_READ_ERROR);
        if ReceiveCount = 0 then
          raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);
        Continue;
      end;

      if (InputDescPointer <> nil) and
         (SecBufferKind(InputBuffers[1].BufferType) = SECBUFFER_EXTRA) then
        PreserveExtraBytes(Data.EncryptedInput, InputBuffers[1].pvBuffer,
          InputBuffers[1].cbBuffer)
      else
        SetLength(Data.EncryptedInput, 0);

      if Status = SEC_I_INCOMPLETE_CREDENTIALS then
        raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);

      if Status = SEC_I_CONTINUE_NEEDED then
      begin
        if Length(Data.EncryptedInput) = 0 then
        begin
          ReceiveCount := ReceiveIntoBuffer(Data.Socket, Data.EncryptedInput);
          if ReceiveCount < 0 then
            raise ETransportSecurityError.Create(TLS_READ_ERROR);
          if ReceiveCount = 0 then
            raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);
        end;
        Continue;
      end;

      if Status <> SEC_E_OK then
        raise ETransportSecurityError.CreateFmt('%s: 0x%x',
          [TLS_HANDSHAKE_ERROR, LongWord(Status)]);
    until Status = SEC_E_OK;

    Status := QueryContextAttributesW(@Data.Context, SECPKG_ATTR_STREAM_SIZES,
      @Data.StreamSizes);
    if Status <> SEC_E_OK then
      raise ETransportSecurityError.CreateFmt('Failed to query SChannel stream sizes: 0x%x',
        [LongWord(Status)]);

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_SCHANNEL;
    AConnection.Active := True;
  except
    if Data.HasContext then
      DeleteSecurityContext(@Data.Context);
    FreeCredentialsHandle(@Data.Credential);
    Data.Free;
    raise;
  end;
end;

procedure CloseSChannel(var AConnection: TTransportSecurityConnection);
var
  Data: TSChannelData;
  ShutdownToken: LongWord;
  ShutdownBuffer: TSecBuffer;
  ShutdownDesc: TSecBufferDesc;
  OutputBuffer: TSecBuffer;
  OutputDesc: TSecBufferDesc;
  Status: SECURITY_STATUS;
  ContextAttributes: LongWord;
  Expiry: SECURITY_INTEGER;
begin
  Data := TSChannelData(AConnection.BackendData);
  if Assigned(Data) then
  begin
    if Data.HasContext then
    begin
      ShutdownToken := SCHANNEL_SHUTDOWN;
      ShutdownBuffer.cbBuffer := SizeOf(ShutdownToken);
      ShutdownBuffer.BufferType := SECBUFFER_TOKEN;
      ShutdownBuffer.pvBuffer := @ShutdownToken;
      ShutdownDesc.ulVersion := SECBUFFER_VERSION;
      ShutdownDesc.cBuffers := 1;
      ShutdownDesc.pBuffers := @ShutdownBuffer;
      Status := ApplyControlToken(@Data.Context, @ShutdownDesc);
      if Status = SEC_E_OK then
      begin
        FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
        OutputBuffer.BufferType := SECBUFFER_TOKEN;
        FillChar(OutputDesc, SizeOf(OutputDesc), 0);
        OutputDesc.ulVersion := SECBUFFER_VERSION;
        OutputDesc.cBuffers := 1;
        OutputDesc.pBuffers := @OutputBuffer;

        Status := InitializeSecurityContextW(@Data.Credential, @Data.Context,
          nil, SChannelRequestFlags, 0, SECURITY_NATIVE_DREP, nil, 0,
          @Data.Context, @OutputDesc, @ContextAttributes, @Expiry);

        if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) or
           (Status = SEC_I_CONTEXT_EXPIRED) then
          SendSChannelToken(Data.Socket, OutputBuffer);
        if Assigned(OutputBuffer.pvBuffer) then
          FreeContextBuffer(OutputBuffer.pvBuffer);
      end;

      DeleteSecurityContext(@Data.Context);
    end;
    FreeCredentialsHandle(@Data.Credential);
    Data.Free;
  end;
end;

function ReadSChannel(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte; const ALength: Integer): Integer;
var
  Data: TSChannelData;
  Available: Integer;
  Buffers: array[0..3] of TSecBuffer;
  BufferDesc: TSecBufferDesc;
  Status: SECURITY_STATUS;
  QualityOfProtection: LongWord;
  I: Integer;
  ReceiveCount: Integer;
  ExtraInput: TBytes;
  ContextExpired: Boolean;
begin
  Data := TSChannelData(AConnection.BackendData);

  Available := Length(Data.DecryptedInput) - Data.DecryptedOffset;
  if Available > 0 then
  begin
    Result := Min(Available, ALength);
    Move(Data.DecryptedInput[Data.DecryptedOffset], ABuffer[0], Result);
    Inc(Data.DecryptedOffset, Result);
    if Data.DecryptedOffset >= Length(Data.DecryptedInput) then
    begin
      SetLength(Data.DecryptedInput, 0);
      Data.DecryptedOffset := 0;
    end;
    Exit;
  end;

  while True do
  begin
    if Length(Data.EncryptedInput) = 0 then
    begin
      ReceiveCount := ReceiveIntoBuffer(Data.Socket, Data.EncryptedInput);
      if ReceiveCount < 0 then
        raise ETransportSecurityError.Create(TLS_READ_ERROR);
      if ReceiveCount = 0 then
      begin
        Result := 0;
        Exit;
      end;
    end;

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_DATA;
    Buffers[0].cbBuffer := Length(Data.EncryptedInput);
    Buffers[0].pvBuffer := @Data.EncryptedInput[0];
    Buffers[1].BufferType := SECBUFFER_EMPTY;
    Buffers[2].BufferType := SECBUFFER_EMPTY;
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    BufferDesc.ulVersion := SECBUFFER_VERSION;
    BufferDesc.cBuffers := 4;
    BufferDesc.pBuffers := @Buffers[0];
    QualityOfProtection := 0;

    Status := DecryptMessage(@Data.Context, @BufferDesc, 0,
      @QualityOfProtection);
    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      ReceiveCount := ReceiveIntoBuffer(Data.Socket, Data.EncryptedInput);
      if ReceiveCount < 0 then
        raise ETransportSecurityError.Create(TLS_READ_ERROR);
      if ReceiveCount = 0 then
      begin
        Result := 0;
        Exit;
      end;
      Continue;
    end;
    if Status = SEC_I_RENEGOTIATE then
      raise ETransportSecurityError.Create('SChannel renegotiation is not supported');
    ContextExpired := Status = SEC_I_CONTEXT_EXPIRED;
    if (Status <> SEC_E_OK) and not ContextExpired then
      raise ETransportSecurityError.CreateFmt('%s: 0x%x',
        [TLS_READ_ERROR, LongWord(Status)]);

    SetLength(Data.DecryptedInput, 0);
    Data.DecryptedOffset := 0;
    for I := 0 to High(Buffers) do
      if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_DATA then
        AppendBytes(Data.DecryptedInput, Buffers[I].pvBuffer,
          Buffers[I].cbBuffer);

    { SECBUFFER_EXTRA belongs to Data.EncryptedInput. Some SChannel
      builds report only cbBuffer, so fall back to preserving the input
      tail before replacing the array that owns those bytes. }
    SetLength(ExtraInput, 0);
    for I := 0 to High(Buffers) do
      if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
        AppendExtraBytes(ExtraInput, Data.EncryptedInput,
          Buffers[I].pvBuffer, Buffers[I].cbBuffer);
    Data.EncryptedInput := ExtraInput;

    Available := Length(Data.DecryptedInput);
    if Available > 0 then
    begin
      Result := Min(Available, ALength);
      Move(Data.DecryptedInput[0], ABuffer[0], Result);
      Data.DecryptedOffset := Result;
      Exit;
    end;

    if ContextExpired then
    begin
      Result := 0;
      Exit;
    end;
  end;
end;

function WriteSChannel(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer): Integer;
var
  Data: TSChannelData;
  ChunkLength: Integer;
  PlainOffset: Integer;
  Message: TBytes;
  Buffers: array[0..3] of TSecBuffer;
  BufferDesc: TSecBufferDesc;
  Status: SECURITY_STATUS;
  TotalLength: Integer;
begin
  Data := TSChannelData(AConnection.BackendData);
  Result := 0;
  PlainOffset := 0;
  while PlainOffset < ALength do
  begin
    ChunkLength := Min(ALength - PlainOffset,
      Integer(Data.StreamSizes.cbMaximumMessage));
    TotalLength := Data.StreamSizes.cbHeader + ChunkLength +
      Data.StreamSizes.cbTrailer;
    SetLength(Message, TotalLength);
    Move(Pointer(PtrUInt(ABuffer) + PtrUInt(PlainOffset))^,
      Message[Data.StreamSizes.cbHeader], ChunkLength);

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_STREAM_HEADER;
    Buffers[0].cbBuffer := Data.StreamSizes.cbHeader;
    Buffers[0].pvBuffer := @Message[0];
    Buffers[1].BufferType := SECBUFFER_DATA;
    Buffers[1].cbBuffer := ChunkLength;
    Buffers[1].pvBuffer := @Message[Data.StreamSizes.cbHeader];
    Buffers[2].BufferType := SECBUFFER_STREAM_TRAILER;
    Buffers[2].cbBuffer := Data.StreamSizes.cbTrailer;
    Buffers[2].pvBuffer := @Message[Data.StreamSizes.cbHeader + ChunkLength];
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    BufferDesc.ulVersion := SECBUFFER_VERSION;
    BufferDesc.cBuffers := 4;
    BufferDesc.pBuffers := @Buffers[0];

    Status := EncryptMessage(@Data.Context, 0, @BufferDesc, 0);
    if Status <> SEC_E_OK then
      raise ETransportSecurityError.CreateFmt('%s: 0x%x',
        [TLS_WRITE_ERROR, LongWord(Status)]);

    TotalLength := Buffers[0].cbBuffer + Buffers[1].cbBuffer +
      Buffers[2].cbBuffer;
    SendSocketAll(Data.Socket, @Message[0], TotalLength);
    Inc(PlainOffset, ChunkLength);
    Inc(Result, ChunkLength);
  end;
end;
{$ENDIF}

function TransportSecurityServerBackendAvailable: Boolean;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := TryLoadOpenSSLServer;
  if not Result then
    Exit;
  try
    LoadOpenSSLServerProcedures;
  except
    on E: ETransportSecurityError do
      Result := False;
  end;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Path: string; const APkcs12Passphrase: UnicodeString);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerContextData;
  Identity: TBytes;
{$ENDIF}
begin
  inherited Create;
  FBackendData := nil;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  if not TryLoadOpenSSLServer then
    raise ETransportSecurityError.Create(OPENSSL_SERVER_LOAD_ERROR);
  LoadOpenSSLServerProcedures;
  Identity := nil;
  try
    Identity := LoadPKCS12Bytes(APkcs12Path);
    Data := TOpenSSLServerContextData.Create;
    Data.Context := nil;
    FBackendData := Data;
    Data.Context := CreateOpenSSLServerContext;
    ConfigureOpenSSLServerIdentity(Data.Context, Identity,
      APkcs12Passphrase);
  finally
    WipeBytes(Identity);
  end;
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

destructor TTransportSecurityServerContext.Destroy;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerContextData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := TOpenSSLServerContextData(FBackendData);
  if Assigned(Data) then
  begin
    if Assigned(Data.Context) then
      SslCtxFree(Data.Context);
    Data.Free;
  end;
  {$ENDIF}
  FBackendData := nil;
  inherited Destroy;
end;

procedure CloseTransportSecurityServerContext(
  var AContext: TTransportSecurityServerContext);
begin
  FreeAndNil(AContext);
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string);
begin
  FillChar(AConnection, SizeOf(AConnection), 0);
  AConnection.Socket := ASocket;
  AConnection.Backend := TSB_NONE;

  {$IFDEF DARWIN}
  StartSecureTransport(AConnection, AHost);
  {$ELSE}
  {$IFDEF MSWINDOWS}
  StartSChannel(AConnection, AHost);
  {$ELSE}
  StartOpenSSL(AConnection, AHost);
  {$ENDIF}
  {$ENDIF}
end;

procedure BeginTransportSecurityServer(
  var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
begin
  FillChar(AConnection, SizeOf(AConnection), 0);
  AConnection.Backend := TSB_NONE;

  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  if not Assigned(AContext) then
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  BeginOpenSSLServer(AConnection, AContext);
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

function TransportSecurityServerHandshake(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := HandshakeOpenSSLServer(AConnection);
  {$ELSE}
  Result := tssError;
  {$ENDIF}
end;

function TransportSecurityFeedCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := FeedOpenSSLServerCiphertext(AConnection, ABuffer, ALength);
  {$ELSE}
  Result := -1;
  {$ENDIF}
end;

function TransportSecurityPendingCiphertext(
  const AConnection: TTransportSecurityConnection): Integer;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Result := OpenSSLServerPendingCiphertext(Data);
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

function TransportSecurityGetCiphertext(
  var AConnection: TTransportSecurityConnection;
  out ABuffer: Pointer): Integer;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
begin
  ABuffer := nil;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Result := OpenSSLServerPendingCiphertext(Data);
  if Result > 0 then
    ABuffer := @Data.Output[Data.OutputOffset];
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

procedure TransportSecurityConsumeCiphertext(
  var AConnection: TTransportSecurityConnection; const ALength: Integer);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
  Pending: Integer;
{$ENDIF}
begin
  if ALength <= 0 then
    Exit;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Pending := OpenSSLServerPendingCiphertext(Data);
  if not Assigned(Data) or (ALength > Pending) then
    raise ETransportSecurityError.Create(
      'TLS ciphertext consumption exceeds the pending output');
  Inc(Data.OutputOffset, ALength);
  if Data.OutputOffset = Length(Data.Output) then
  begin
    SetLength(Data.Output, 0);
    Data.OutputOffset := 0;
  end;
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

function TransportSecurityServerRead(
  var AConnection: TTransportSecurityConnection; var ABuffer: array of Byte;
  const ALength: Integer): TTransportSecurityIOResult;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := ReadOpenSSLServer(AConnection, ABuffer, ALength);
  {$ELSE}
  Result.State := tssError;
  Result.BytesProcessed := 0;
  {$ENDIF}
end;

function TransportSecurityServerWrite(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := WriteOpenSSLServer(AConnection, ABuffer, ALength);
  {$ELSE}
  Result.State := tssError;
  Result.BytesProcessed := 0;
  {$ENDIF}
end;

function CloseTransportSecurityServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := CloseOpenSSLServerGracefully(AConnection);
  {$ELSE}
  Result := tssError;
  {$ENDIF}
end;

procedure AbortTransportSecurityServer(
  var AConnection: TTransportSecurityConnection);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  ResetTransportSecurityConnection(AConnection);
  FreeOpenSSLServerData(Data);
  {$ELSE}
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
  {$ENDIF}
end;

{$IFDEF TRANSPORT_SECURITY_OPENSSL}
{$IFNDEF PRODUCTION}
function TransportSecurityTestInjectSyscallError(
  var AConnection: TTransportSecurityConnection;
  out AObservedError: Integer): TTransportSecurityState;
var
  Buffer: Byte;
  ClearFlags: TBIOClearFlags;
  Data: TOpenSSLServerData;
  ReadResult: Integer;
begin
  AObservedError := SSL_ERROR_NONE;
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone or
     (OpenSSLServerPendingCiphertext(Data) > 0) then
  begin
    Result := tssError;
    Exit;
  end;
  ClearFlags := TBIOClearFlags(GetProcedureAddress(SSLUtilHandle,
    'BIO_clear_flags'));
  if not Assigned(ClearFlags) then
    raise ETransportSecurityError.Create(
      'OpenSSL runtime does not provide the TLS test error seam');

  ErrClearError;
  ReadResult := SslRead(Data.SSL, @Buffer, 1);
  if ReadResult > 0 then
    raise ETransportSecurityError.Create(
      'TLS test error seam unexpectedly read plaintext');
  ClearFlags(Data.ReadBIO, BIO_FLAGS_RETRY_MASK);
  AObservedError := SslGetError(Data.SSL, ReadResult);
  Result := OpenSSLServerErrorState(AConnection, Data, AObservedError,
    osoRead);
end;
{$ENDIF}
{$ENDIF}

procedure CloseTransportSecurity(var AConnection: TTransportSecurityConnection);
begin
  if (AConnection.Backend = TSB_NONE) or
     not Assigned(AConnection.BackendData) then
    Exit;

  case AConnection.Backend of
    {$IFDEF DARWIN}
    TSB_SECURE_TRANSPORT:
      CloseSecureTransport(AConnection);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TSB_SCHANNEL:
      CloseSChannel(AConnection);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    TSB_OPENSSL:
      CloseOpenSSL(AConnection);
    TSB_OPENSSL_SERVER:
      FreeOpenSSLServerData(TOpenSSLServerData(AConnection.BackendData));
    {$ENDIF}
  end;

  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
end;

function TransportSecurityRead(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte; const ALength: Integer): Integer;
var
  ReadLength: Integer;
begin
  ReadLength := ALength;
  if ReadLength > Length(ABuffer) then
    ReadLength := Length(ABuffer);
  if ReadLength <= 0 then
  begin
    Result := 0;
    Exit;
  end;

  case AConnection.Backend of
    {$IFDEF DARWIN}
    TSB_SECURE_TRANSPORT:
      Result := ReadSecureTransport(AConnection, ABuffer, ReadLength);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TSB_SCHANNEL:
      Result := ReadSChannel(AConnection, ABuffer, ReadLength);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    TSB_OPENSSL:
      Result := ReadOpenSSL(AConnection, ABuffer, ReadLength);
    {$ENDIF}
  else
    Result := 0;
  end;
end;

function TransportSecurityWrite(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer): Integer;
begin
  if ALength <= 0 then
  begin
    Result := 0;
    Exit;
  end;

  case AConnection.Backend of
    {$IFDEF DARWIN}
    TSB_SECURE_TRANSPORT:
      Result := WriteSecureTransport(AConnection, ABuffer, ALength);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TSB_SCHANNEL:
      Result := WriteSChannel(AConnection, ABuffer, ALength);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    TSB_OPENSSL:
      Result := WriteOpenSSL(AConnection, ABuffer, ALength);
    {$ENDIF}
  else
    Result := 0;
  end;
end;

end.
