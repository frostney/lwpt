unit TransportSecurity;

// Cross-platform TLS transport. Blocking clients use SecureTransport on
// macOS, SChannel on Windows, and OpenSSL on Unix. Nonblocking server accept
// uses native SChannel (SSPI + crypt32) on Windows and memory-BIO OpenSSL on
// Unix-not-Darwin; macOS servers use Network.framework outside this unit.
// Windows therefore links no OpenSSL and loads no OpenSSL DLL at runtime.

{$I Shared.inc}

{$IFDEF MSWINDOWS}
{$DEFINE TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$DEFINE TRANSPORT_SECURITY_SERVER}
{$ENDIF}
{$IFDEF UNIX}
{$IFNDEF DARWIN}
{$DEFINE TRANSPORT_SECURITY_OPENSSL}
{$DEFINE TRANSPORT_SECURITY_SERVER}
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

const
  TLS_SERVER_DEFAULT_INPUT_CAPACITY = 64 * 1024;
  TLS_SERVER_MIN_INPUT_CAPACITY = 17 * 1024;
  TLS_SERVER_MAX_INPUT_CAPACITY = 256 * 1024;
  TLS_SERVER_DEFAULT_OUTPUT_CAPACITY = 64 * 1024;
  TLS_SERVER_MIN_OUTPUT_CAPACITY = 17 * 1024;
  TLS_SERVER_MAX_OUTPUT_CAPACITY = 256 * 1024;

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

  TTransportSecurityServerIdentityValidation = (
    tsivStrict,
    tsivPermissive
  );

  TTransportSecurityInputFlow = record
    AcceptedBytes: QWord;
    Backpressured: Boolean;
    BufferedBytes: Integer;
    ConsumedBytes: QWord;
    HighWatermark: Integer;
    LowWatermark: Integer;
  end;

  TTransportSecurityOutputFlow = record
    Capacity: Integer;
    PendingBytes: Integer;
    RemainingBytes: Integer;
  end;

  TTransportSecurityConnection = record
  public
    Active: Boolean;
  private
    Backend: Integer;
    Deadline: QWord;
    Socket: TSocket;
    BackendData: Pointer;
    TimeoutMilliseconds: QWord;
  end;

  TTransportSecurityServerContext = class
  private
    FBackendData: Pointer;
    FCriticalSection: TRTLCriticalSection;
    FCriticalSectionInitialized: Boolean;
    FInputHighWatermark: Integer;
    FInputLowWatermark: Integer;
    FOutputCapacity: Integer;
    function AcquireSnapshot: Pointer;
    procedure InitializeFlowControl(const AInputHighWatermark,
      AInputLowWatermark, AOutputCapacity: Integer);
    procedure ReplaceSnapshot(const ANewSnapshot: Pointer);
  public
    constructor Create(const APkcs12Identity: TBytes;
      const APkcs12Passphrase: UnicodeString;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    constructor Create(const APkcs12Identity: TBytes;
      const APkcs12Passphrase: UnicodeString; const AInputHighWatermark,
      AOutputCapacity: Integer;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    constructor Create(const APkcs12Identity: TBytes;
      const APkcs12Passphrase: UnicodeString; const AInputHighWatermark,
      AInputLowWatermark, AOutputCapacity: Integer;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    constructor Create(const APkcs12Path: string;
      const APkcs12Passphrase: UnicodeString;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    constructor Create(const APkcs12Path: string;
      const APkcs12Passphrase: UnicodeString;
      const AInputHighWatermark, AOutputCapacity: Integer;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    constructor Create(const APkcs12Path: string;
      const APkcs12Passphrase: UnicodeString; const AInputHighWatermark,
      AInputLowWatermark, AOutputCapacity: Integer;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    destructor Destroy; override;
    procedure Reload(const APkcs12Identity: TBytes;
      const APkcs12Passphrase: UnicodeString;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
    procedure Reload(const APkcs12Path: string;
      const APkcs12Passphrase: UnicodeString;
      const AValidation: TTransportSecurityServerIdentityValidation =
      tsivStrict); overload;
  end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string); overload;
procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string; const ADeadline,
  ATimeoutMilliseconds: QWord); overload;
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
function TransportSecurityServerInputFlow(
  var AConnection: TTransportSecurityConnection): TTransportSecurityInputFlow;
function TransportSecurityServerOutputFlow(
  const AConnection: TTransportSecurityConnection): TTransportSecurityOutputFlow;
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
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$IFNDEF PRODUCTION}
function TransportSecurityTestServerKeyContainer(
  const AContext: TTransportSecurityServerContext): UnicodeString;
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
  TSB_SCHANNEL_SERVER = 5;
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

function TransportSocketWouldBlock: Boolean; inline;
var
  ErrorCode: Integer;
begin
  {$IFDEF UNIX}
  ErrorCode := fpgeterrno;
  Result := (ErrorCode = ESysEAGAIN) or
    (ErrorCode = ESysEWOULDBLOCK) or
    (ErrorCode = ESysEINPROGRESS);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  ErrorCode := WSAGetLastError;
  Result := (ErrorCode = WSAEWOULDBLOCK) or
    (ErrorCode = WSAEINPROGRESS);
  {$ENDIF}
end;

procedure RaiseTransportDeadline(
  const AConnection: TTransportSecurityConnection);
begin
  raise ETransportSecurityError.CreateFmt(
    'HTTP request deadline exceeded after %d ms',
    [AConnection.TimeoutMilliseconds]);
end;

function RemainingTransportMilliseconds(
  const AConnection: TTransportSecurityConnection): Integer;
var
  NowTick, Remaining: QWord;
begin
  NowTick := GetTickCount64;
  if (AConnection.Deadline = 0) or
     (NowTick >= AConnection.Deadline) then
    RaiseTransportDeadline(AConnection);
  Remaining := AConnection.Deadline - NowTick;
  if Remaining > QWord(High(Integer)) then
    Result := High(Integer)
  else
    Result := Integer(Remaining);
  if Result < 1 then
    Result := 1;
end;

procedure WaitForTransportSocket(
  const AConnection: TTransportSecurityConnection;
  const ARead, AWrite: Boolean);
{$IFDEF UNIX}
var
  ReadSet, WriteSet: TFDSet;
  ReadSetPointer, WriteSetPointer: PFDSet;
  Ready: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ReadSet, WriteSet: TFDSet;
  ReadSetPointer, WriteSetPointer: PFDSet;
  Timeout: TTimeVal;
  Ready: Integer;
  Remaining: Integer;
{$ENDIF}
begin
  if not ARead and not AWrite then
    raise ETransportSecurityError.Create(
      'TLS socket readiness wait has no requested operation');
  {$IFDEF UNIX}
  fpFD_ZERO(ReadSet);
  fpFD_ZERO(WriteSet);
  ReadSetPointer := nil;
  WriteSetPointer := nil;
  if ARead then
  begin
    fpFD_SET(AConnection.Socket, ReadSet);
    ReadSetPointer := @ReadSet;
  end;
  if AWrite then
  begin
    fpFD_SET(AConnection.Socket, WriteSet);
    WriteSetPointer := @WriteSet;
  end;
  Ready := fpSelect(AConnection.Socket + 1, ReadSetPointer,
    WriteSetPointer, nil, RemainingTransportMilliseconds(AConnection));
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FillChar(ReadSet, SizeOf(ReadSet), 0);
  FillChar(WriteSet, SizeOf(WriteSet), 0);
  ReadSetPointer := nil;
  WriteSetPointer := nil;
  if ARead then
  begin
    ReadSet.fd_count := 1;
    ReadSet.fd_array[0] := AConnection.Socket;
    ReadSetPointer := @ReadSet;
  end;
  if AWrite then
  begin
    WriteSet.fd_count := 1;
    WriteSet.fd_array[0] := AConnection.Socket;
    WriteSetPointer := @WriteSet;
  end;
  Remaining := RemainingTransportMilliseconds(AConnection);
  Timeout.tv_sec := Remaining div 1000;
  Timeout.tv_usec := (Remaining mod 1000) * 1000;
  Ready := WinSock2.select(0, ReadSetPointer, WriteSetPointer, nil,
    @Timeout);
  {$ENDIF}
  if Ready = 0 then
    RaiseTransportDeadline(AConnection);
  if Ready < 0 then
    raise ETransportSecurityError.Create('TLS socket readiness wait failed');
  if GetTickCount64 >= AConnection.Deadline then
    RaiseTransportDeadline(AConnection);
end;

procedure SendSocketAll(
  const AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer; const ALength: Integer);
var
  Sent: Integer;
  Written: Integer;
begin
  Sent := 0;
  while Sent < ALength do
  begin
    Written := SocketSend(AConnection.Socket,
      Pointer(PtrUInt(ABuffer) + PtrUInt(Sent)), ALength - Sent);
    if (Written < 0) and TransportSocketWouldBlock and
       (AConnection.Deadline <> 0) then
    begin
      WaitForTransportSocket(AConnection, False, True);
      Continue;
    end;
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
    WantRead: Boolean;
    WantWrite: Boolean;
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
    begin
      Data.WantRead := True;
      Result := ERR_SSL_WOULD_BLOCK;
    end;
  end
  else if ReadCount = 0 then
  begin
    ADataLength := 0;
    Result := ERR_SSL_CLOSED_GRACEFUL;
  end
  else
  begin
    ADataLength := 0;
    if TransportSocketWouldBlock then
    begin
      Data.WantRead := True;
      Result := ERR_SSL_WOULD_BLOCK
    end
    else
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
    begin
      Data.WantWrite := True;
      Result := ERR_SSL_WOULD_BLOCK;
    end;
  end
  else
  begin
    ADataLength := 0;
    if TransportSocketWouldBlock then
    begin
      Data.WantWrite := True;
      Result := ERR_SSL_WOULD_BLOCK
    end
    else
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
  Data.WantRead := False;
  Data.WantWrite := False;
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
      Data.WantRead := False;
      Data.WantWrite := False;
      Status := SSLHandshake(Data.Context);
      if (Status = ERR_SSL_WOULD_BLOCK) and
         (AConnection.Deadline <> 0) then
        WaitForTransportSocket(AConnection, Data.WantRead,
          Data.WantWrite);
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
    Data.WantRead := False;
    Data.WantWrite := False;
    Status := SSLRead(Data.Context, @ABuffer[0], ALength, Processed);
    if (Status = ERR_SSL_WOULD_BLOCK) and (Processed = 0) and
       (AConnection.Deadline <> 0) then
      WaitForTransportSocket(AConnection, Data.WantRead,
        Data.WantWrite);
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
    Data.WantRead := False;
    Data.WantWrite := False;
    Status := SSLWrite(Data.Context, ABuffer, ALength, Processed);
    if (Status = ERR_SSL_WOULD_BLOCK) and (Processed = 0) and
       (AConnection.Deadline <> 0) then
      WaitForTransportSocket(AConnection, Data.WantRead,
        Data.WantWrite);
  until (Status <> ERR_SSL_WOULD_BLOCK) or (Processed > 0);
  if (Status <> ERR_SEC_SUCCESS) and (Status <> ERR_SSL_WOULD_BLOCK) then
    raise ETransportSecurityError.CreateFmt('%s: %d', [TLS_WRITE_ERROR, Status]);
  Result := Processed;
end;
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_SERVER}
{ Server-identity support shared by the OpenSSL and SChannel server
  backends: the PKCS#12 size ceiling, link-refusing identity-file
  loading, and the connection/secret bookkeeping both backends use. }

const
  MAX_PKCS12_IDENTITY_SIZE = 16 * 1024 * 1024;

procedure ResetTransportSecurityConnection(
  var AConnection: TTransportSecurityConnection); inline;
begin
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
end;

{$IFDEF UNIX}
function OpenAt(ADirectoryDescriptor: cint; APath: PChar;
  AFlags: cint): cint; cdecl; external 'c' name 'openat';
function FileStatusAt(ADirectoryDescriptor: cint; APath: PChar;
  var AFileStatus: BaseUnix.Stat; AFlags: cint): cint; cdecl;
  external 'c' name 'fstatat';

{$IFDEF LINUX}
type
  PCIntLWPT = ^cint;

function LinuxErrnoLocation: PCIntLWPT; cdecl;
  external 'c' name '__errno_location';
{$ENDIF}

const
  {$IFDEF LINUX}
  AT_SYMLINK_NOFOLLOW_LWPT = $00000100;
  O_NONBLOCK_LWPT = $00000800;
  { Linux AArch64 overrides the asm-generic directory and no-follow bits.
    FPC 3.2.2 exposes the asm-generic values on that target, so these values
    must follow the target UAPI rather than the RTL constants. }
  {$IFDEF CPUAARCH64}
  O_DIRECTORY_LWPT = $00004000;
  O_NOFOLLOW_LWPT = $00008000;
  {$ELSE}
  O_DIRECTORY_LWPT = $00010000;
  O_NOFOLLOW_LWPT = $00020000;
  {$ENDIF}
  {$ELSE}
  {$IFDEF DARWIN}
  AT_SYMLINK_NOFOLLOW_LWPT = $00000020;
  O_DIRECTORY_LWPT = $00100000;
  O_NOFOLLOW_LWPT = $00000100;
  O_NONBLOCK_LWPT = $00000004;
  {$ELSE}
  AT_SYMLINK_NOFOLLOW_LWPT = AT_SYMLINK_NOFOLLOW;
  O_DIRECTORY_LWPT = O_DIRECTORY;
  O_NOFOLLOW_LWPT = O_NOFOLLOW;
  O_NONBLOCK_LWPT = O_NONBLOCK;
  {$ENDIF}
  {$ENDIF}

function LastLibcError: cint; inline;
begin
  {$IFDEF LINUX}
  Result := LinuxErrnoLocation^;
  {$ELSE}
  Result := fpgeterrno;
  {$ENDIF}
end;

function OpenPKCS12Descriptor(const APath: string): cint;
var
  Component: string;
  CurrentDescriptor: cint;
  ErrorCode: cint;
  IsFinal: Boolean;
  LinkInfo: BaseUnix.Stat;
  NextDescriptor: cint;
  OpenFlags: cint;
  OpenInfo: BaseUnix.Stat;
  Position: Integer;
  Start: Integer;
begin
  if APath = '' then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity file does not exist');
  if APath[1] = '/' then
    CurrentDescriptor := fpOpen(PChar('/'), O_RDONLY)
  else
    CurrentDescriptor := fpOpen(PChar('.'), O_RDONLY);
  if CurrentDescriptor < 0 then
    raise ETransportSecurityError.Create(
      'Failed to open configured TLS PKCS#12 identity without following links');
  try
    Position := 1;
    while Position <= Length(APath) do
    begin
      while (Position <= Length(APath)) and (APath[Position] = '/') do
        Inc(Position);
      if Position > Length(APath) then
        Break;
      Start := Position;
      while (Position <= Length(APath)) and (APath[Position] <> '/') do
        Inc(Position);
      Component := Copy(APath, Start, Position - Start);
      while (Position <= Length(APath)) and (APath[Position] = '/') do
        Inc(Position);
      IsFinal := Position > Length(APath);
      if FileStatusAt(CurrentDescriptor, PChar(Component), LinkInfo,
        AT_SYMLINK_NOFOLLOW_LWPT) <> 0 then
      begin
        ErrorCode := LastLibcError;
        if ErrorCode = ESysENOENT then
          raise ETransportSecurityError.Create(
            'Configured TLS PKCS#12 identity file does not exist');
        raise ETransportSecurityError.Create(
          'Failed to open configured TLS PKCS#12 identity without following links');
      end;
      if (LinkInfo.st_mode and S_IFMT) = S_IFLNK then
        raise ETransportSecurityError.Create(
          'Failed to open configured TLS PKCS#12 identity without following links');
      if IsFinal then
      begin
        if (LinkInfo.st_mode and S_IFMT) <> S_IFREG then
          raise ETransportSecurityError.Create(
            'Configured TLS PKCS#12 identity must be a regular file');
        OpenFlags := O_RDONLY or O_NOFOLLOW_LWPT or O_NONBLOCK_LWPT;
      end
      else
      begin
        if (LinkInfo.st_mode and S_IFMT) <> S_IFDIR then
          raise ETransportSecurityError.Create(
            'Failed to open configured TLS PKCS#12 identity without following links');
        OpenFlags := O_RDONLY or O_NOFOLLOW_LWPT or O_NONBLOCK_LWPT or
          O_DIRECTORY_LWPT;
      end;
      NextDescriptor := OpenAt(CurrentDescriptor, PChar(Component),
        OpenFlags);
      if NextDescriptor < 0 then
      begin
        ErrorCode := LastLibcError;
        if ErrorCode = ESysENOENT then
          raise ETransportSecurityError.Create(
            'Configured TLS PKCS#12 identity file does not exist');
        raise ETransportSecurityError.Create(
          'Failed to open configured TLS PKCS#12 identity without following links');
      end;
      if (fpFStat(NextDescriptor, OpenInfo) <> 0) or
         (OpenInfo.st_dev <> LinkInfo.st_dev) or
         (OpenInfo.st_ino <> LinkInfo.st_ino) or
         ((OpenInfo.st_mode and S_IFMT) <> (LinkInfo.st_mode and S_IFMT)) then
      begin
        fpClose(NextDescriptor);
        raise ETransportSecurityError.Create(
          'Failed to open configured TLS PKCS#12 identity without following links');
      end;
      fpClose(CurrentDescriptor);
      CurrentDescriptor := NextDescriptor;
    end;
    Result := CurrentDescriptor;
    CurrentDescriptor := -1;
  finally
    if CurrentDescriptor >= 0 then
      fpClose(CurrentDescriptor);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
type
  PPWideCharLWPT = ^PWideChar;
  TWindowsHandleArray = array of THandle;

function WindowsGetFullPathName(APath: PWideChar; ALength: DWORD;
  ABuffer: PWideChar; AFilePart: PPWideCharLWPT): DWORD; stdcall;
  external 'kernel32.dll' name 'GetFullPathNameW';

function NormalizeWindowsPath(const APath: UnicodeString): UnicodeString;
begin
  Result := APath;
  if Copy(Result, 1, 8) = '\\?\UNC\' then
    Result := '\\' + Copy(Result, 9, MaxInt)
  else if Copy(Result, 1, 4) = '\\?\' then
    Delete(Result, 1, 4);
end;

function WindowsFullPath(const APath: string): UnicodeString;
var
  BufferLength: DWORD;
  FilePart: PWideChar;
begin
  Result := '';
  BufferLength := WindowsGetFullPathName(PWideChar(UnicodeString(APath)),
    0, nil, nil);
  if BufferLength = 0 then
    raise ETransportSecurityError.Create(
      'Failed to inspect configured TLS PKCS#12 identity');
  SetLength(Result, BufferLength);
  BufferLength := WindowsGetFullPathName(PWideChar(UnicodeString(APath)),
    Length(Result), PWideChar(Result), @FilePart);
  if (BufferLength = 0) or (BufferLength >= DWORD(Length(Result))) then
    raise ETransportSecurityError.Create(
      'Failed to inspect configured TLS PKCS#12 identity');
  SetLength(Result, BufferLength);
  Result := NormalizeWindowsPath(Result);
end;

function WindowsRootLength(const APath: UnicodeString): Integer;
var
  Position: Integer;
begin
  if (Length(APath) >= 3) and (APath[2] = ':') and (APath[3] = '\') then
    Exit(3);
  if (Length(APath) < 5) or (Copy(APath, 1, 2) <> '\\') then
    Exit(0);
  Position := 3;
  while (Position <= Length(APath)) and (APath[Position] <> '\') do
    Inc(Position);
  if Position > Length(APath) then
    Exit(0);
  Inc(Position);
  while (Position <= Length(APath)) and (APath[Position] <> '\') do
    Inc(Position);
  if Position > Length(APath) then
    Result := Length(APath)
  else
    Result := Position;
end;

procedure CloseWindowsHandles(var AHandles: TWindowsHandleArray);
var
  I: Integer;
begin
  for I := High(AHandles) downto 0 do
    if AHandles[I] <> THandle(Windows.INVALID_HANDLE_VALUE) then
      Windows.CloseHandle(AHandles[I]);
  SetLength(AHandles, 0);
end;

procedure OpenWindowsParentHandles(const APath: UnicodeString;
  out AHandles: TWindowsHandleArray);
const
  FILE_FLAG_BACKUP_SEMANTICS_LWPT = $02000000;
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
  FILE_READ_ATTRIBUTES_LWPT = $00000080;
var
  ComponentEnd: Integer;
  ComponentStart: Integer;
  FileInfo: TByHandleFileInformation;
  Handle: THandle;
  LastError: DWORD;
  ParentPath: UnicodeString;
  RootLength: Integer;
begin
  SetLength(AHandles, 0);
  RootLength := WindowsRootLength(APath);
  if RootLength = 0 then
    raise ETransportSecurityError.Create(
      'Failed to inspect configured TLS PKCS#12 identity');
  ComponentStart := RootLength + 1;
  while ComponentStart <= Length(APath) do
  begin
    ComponentEnd := ComponentStart;
    while (ComponentEnd <= Length(APath)) and
      (APath[ComponentEnd] <> '\') do
      Inc(ComponentEnd);
    if ComponentEnd > Length(APath) then
      Break;
    ParentPath := Copy(APath, 1, ComponentEnd - 1);
    Handle := Windows.CreateFileW(PWideChar(ParentPath),
      FILE_READ_ATTRIBUTES_LWPT, Windows.FILE_SHARE_READ, nil,
      Windows.OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS_LWPT or
      FILE_FLAG_OPEN_REPARSE_POINT_LWPT, 0);
    if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then
    begin
      LastError := Windows.GetLastError;
      CloseWindowsHandles(AHandles);
      { Mirror the Unix component walk, which reports ENOENT on any component
        as a missing identity rather than as a link refusal. Without this a
        configured path whose parent directory is absent is misreported as a
        reparse-point failure. Neither message discloses the path. }
      if (LastError = Windows.ERROR_FILE_NOT_FOUND) or
         (LastError = Windows.ERROR_PATH_NOT_FOUND) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 identity file does not exist');
      raise ETransportSecurityError.Create(
        'Failed to open configured TLS PKCS#12 identity without following reparse points');
    end;
    if not Windows.GetFileInformationByHandle(Handle, FileInfo) or
       ((FileInfo.dwFileAttributes and Windows.FILE_ATTRIBUTE_DIRECTORY) = 0) or
       ((FileInfo.dwFileAttributes and Windows.FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
    begin
      Windows.CloseHandle(Handle);
      CloseWindowsHandles(AHandles);
      raise ETransportSecurityError.Create(
        'Failed to open configured TLS PKCS#12 identity without following reparse points');
    end;
    SetLength(AHandles, Length(AHandles) + 1);
    AHandles[High(AHandles)] := Handle;
    ComponentStart := ComponentEnd + 1;
  end;
end;
{$ENDIF}

function LoadPKCS12Bytes(const APath: string): TBytes;
{$IFDEF UNIX}
var
  BytesRead: Integer;
  Descriptor: cint;
  FileInfo: BaseUnix.Stat;
  Offset: Integer;
begin
  Result := nil;
  Descriptor := OpenPKCS12Descriptor(APath);
  try
    if (fpFStat(Descriptor, FileInfo) <> 0) or
       ((FileInfo.st_mode and S_IFMT) <> S_IFREG) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must be a regular file');
    if FileInfo.st_size <= 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity file is empty');
    if FileInfo.st_size > MAX_PKCS12_IDENTITY_SIZE then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
    SetLength(Result, Integer(FileInfo.st_size));
    try
      Offset := 0;
      while Offset < Length(Result) do
      begin
        repeat
          BytesRead := fpRead(Descriptor, Result[Offset],
            Length(Result) - Offset);
        until (BytesRead >= 0) or (fpgeterrno <> ESysEINTR);
        if BytesRead <= 0 then
          raise ETransportSecurityError.Create(
            'Failed to read configured TLS PKCS#12 identity file');
        Inc(Offset, BytesRead);
      end;
    except
      FillChar(Result[0], Length(Result), 0);
      Result := nil;
      raise;
    end;
  finally
    fpClose(Descriptor);
  end;
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
const
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
var
  BytesRead: DWORD;
  ExpectedPath: UnicodeString;
  FileInfo: TByHandleFileInformation;
  FileSize: QWord;
  Handle: THandle;
  LastError: DWORD;
  Offset: Integer;
  ParentHandles: TWindowsHandleArray;
begin
  Result := nil;
  ExpectedPath := WindowsFullPath(APath);
  Handle := THandle(Windows.INVALID_HANDLE_VALUE);
  OpenWindowsParentHandles(ExpectedPath, ParentHandles);
  try
    Handle := Windows.CreateFileW(PWideChar(ExpectedPath),
      Windows.GENERIC_READ, Windows.FILE_SHARE_READ, nil,
      Windows.OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT_LWPT, 0);
    if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then
    begin
      LastError := Windows.GetLastError;
      if (LastError = Windows.ERROR_FILE_NOT_FOUND) or
         (LastError = Windows.ERROR_PATH_NOT_FOUND) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 identity file does not exist');
      raise ETransportSecurityError.Create(
        'Failed to open configured TLS PKCS#12 identity without following reparse points');
    end;
    if not Windows.GetFileInformationByHandle(Handle, FileInfo) or
       ((FileInfo.dwFileAttributes and Windows.FILE_ATTRIBUTE_REPARSE_POINT)
       <> 0) or
       ((FileInfo.dwFileAttributes and Windows.FILE_ATTRIBUTE_DIRECTORY)
       <> 0) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must be a regular non-reparse file');
    FileSize := (QWord(FileInfo.nFileSizeHigh) shl 32) or
      FileInfo.nFileSizeLow;
    if FileSize = 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity file is empty');
    if FileSize > MAX_PKCS12_IDENTITY_SIZE then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
    SetLength(Result, Integer(FileSize));
    try
      Offset := 0;
      while Offset < Length(Result) do
      begin
        if not Windows.ReadFile(Handle, Result[Offset],
          Length(Result) - Offset, BytesRead, nil) or (BytesRead = 0) then
          raise ETransportSecurityError.Create(
            'Failed to read configured TLS PKCS#12 identity file');
        Inc(Offset, BytesRead);
      end;
    except
      FillChar(Result[0], Length(Result), 0);
      Result := nil;
      raise;
    end;
  finally
    if Handle <> THandle(Windows.INVALID_HANDLE_VALUE) then
      Windows.CloseHandle(Handle);
    CloseWindowsHandles(ParentHandles);
  end;
end;
{$ENDIF}

procedure WipeBytes(var ABytes: TBytes);
begin
  if Length(ABytes) > 0 then
    FillChar(ABytes[0], Length(ABytes), 0);
  SetLength(ABytes, 0);
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
    References: LongInt;
    constructor Create(const AContext: PSSL_CTX);
    procedure Retain;
    procedure Release;
  end;

  TOpenSSLServerData = class
  public
    HandshakeDone: Boolean;
    InputAccepted: QWord;
    InputBackpressured: Boolean;
    InputBuffered: Integer;
    InputConsumed: QWord;
    InputHighWatermark: Integer;
    InputLowWatermark: Integer;
    Output: TBytes;
    OutputCapacity: Integer;
    OutputOffset: Integer;
    PendingPlaintext: TBytes;
    ReadBIO: Pointer;
    Snapshot: TOpenSSLServerContextData;
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
  TX509CheckPurpose = function(ACertificate: Pointer; APurpose,
    ACertificateAuthority: LongInt): LongInt; cdecl;
  TX509CompareCurrentTime = function(ATime: Pointer): LongInt; cdecl;
  TX509GetExtendedKeyUsage = function(ACertificate: Pointer): Cardinal; cdecl;
  TX509GetExtensionFlags = function(ACertificate: Pointer): Cardinal; cdecl;
  TX509GetKeyUsage = function(ACertificate: Pointer): Cardinal; cdecl;
  TX509GetName = function(ACertificate: Pointer): Pointer; cdecl;
  TX509GetPathLength = function(ACertificate: Pointer): LongInt; cdecl;
  TX509GetPublicKey = function(ACertificate: Pointer): Pointer; cdecl;
  TX509GetTime = function(ACertificate: Pointer): Pointer; cdecl;
  TX509NameCompare = function(AName, BName: Pointer): LongInt; cdecl;
  TX509Verify = function(ACertificate, APublicKey: Pointer): LongInt; cdecl;
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
  OPENSSL_OUTPUT_CHUNK_SIZE = 16 * 1024;
  EXFLAG_BCONS = $1;
  EXFLAG_KUSAGE = $2;
  EXFLAG_XKUSAGE = $4;
  EXFLAG_CA = $10;
  EXFLAG_INVALID = $80;
  EXFLAG_CRITICAL = $200;
  EXFLAG_INVALID_POLICY = $800;
  EXFLAG_NO_FINGERPRINT = $100000;
  X509_PURPOSE_SSL_SERVER = 2;
  KU_KEY_CERT_SIGN = $4;
  XKU_SSL_SERVER = $1;
  XKU_ANYEKU = $100;
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
  OpenSSLX509CheckPurpose: TX509CheckPurpose;
  OpenSSLX509CompareCurrentTime: TX509CompareCurrentTime;
  OpenSSLX509GetExtendedKeyUsage: TX509GetExtendedKeyUsage;
  OpenSSLX509GetExtensionFlags: TX509GetExtensionFlags;
  OpenSSLX509GetIssuerName: TX509GetName;
  OpenSSLX509GetKeyUsage: TX509GetKeyUsage;
  OpenSSLX509GetNotAfter: TX509GetTime;
  OpenSSLX509GetNotBefore: TX509GetTime;
  OpenSSLX509GetPathLength: TX509GetPathLength;
  OpenSSLX509GetPublicKey: TX509GetPublicKey;
  OpenSSLX509GetSubjectName: TX509GetName;
  OpenSSLX509NameCompare: TX509NameCompare;
  OpenSSLX509Verify: TX509Verify;

constructor TOpenSSLServerContextData.Create(const AContext: PSSL_CTX);
begin
  inherited Create;
  Context := AContext;
  References := 1;
end;

procedure TOpenSSLServerContextData.Retain;
begin
  InterlockedIncrement(References);
end;

procedure TOpenSSLServerContextData.Release;
begin
  if InterlockedDecrement(References) <> 0 then
    Exit;
  if Assigned(Context) then
    SslCtxFree(Context);
  Context := nil;
  Free;
end;

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
  X509CheckPurpose: TX509CheckPurpose;
  X509CompareCurrentTime: TX509CompareCurrentTime;
  X509GetExtendedKeyUsage: TX509GetExtendedKeyUsage;
  X509GetExtensionFlags: TX509GetExtensionFlags;
  X509GetIssuerName: TX509GetName;
  X509GetKeyUsage: TX509GetKeyUsage;
  X509GetNotAfter: TX509GetTime;
  X509GetNotBefore: TX509GetTime;
  X509GetPathLength: TX509GetPathLength;
  X509GetPublicKey: TX509GetPublicKey;
  X509GetSubjectName: TX509GetName;
  X509NameCompare: TX509NameCompare;
  X509VerifyCertificate: TX509Verify;
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
  X509CheckPurpose := TX509CheckPurpose(GetProcedureAddress(SSLUtilHandle,
    'X509_check_purpose'));
  X509CompareCurrentTime := TX509CompareCurrentTime(GetProcedureAddress(
    SSLUtilHandle, 'X509_cmp_current_time'));
  X509GetExtendedKeyUsage := TX509GetExtendedKeyUsage(GetProcedureAddress(
    SSLUtilHandle, 'X509_get_extended_key_usage'));
  X509GetExtensionFlags := TX509GetExtensionFlags(GetProcedureAddress(
    SSLUtilHandle, 'X509_get_extension_flags'));
  X509GetIssuerName := TX509GetName(GetProcedureAddress(SSLUtilHandle,
    'X509_get_issuer_name'));
  X509GetKeyUsage := TX509GetKeyUsage(GetProcedureAddress(SSLUtilHandle,
    'X509_get_key_usage'));
  X509GetNotAfter := TX509GetTime(GetProcedureAddress(SSLUtilHandle,
    'X509_get0_notAfter'));
  X509GetNotBefore := TX509GetTime(GetProcedureAddress(SSLUtilHandle,
    'X509_get0_notBefore'));
  X509GetPathLength := TX509GetPathLength(GetProcedureAddress(SSLUtilHandle,
    'X509_get_pathlen'));
  X509GetPublicKey := TX509GetPublicKey(GetProcedureAddress(SSLUtilHandle,
    'X509_get_pubkey'));
  X509GetSubjectName := TX509GetName(GetProcedureAddress(SSLUtilHandle,
    'X509_get_subject_name'));
  X509NameCompare := TX509NameCompare(GetProcedureAddress(SSLUtilHandle,
    'X509_NAME_cmp'));
  X509VerifyCertificate := TX509Verify(GetProcedureAddress(SSLUtilHandle,
    'X509_verify'));

  if not Assigned(BIOFree) or not Assigned(BIONew) or
     not Assigned(BIONewMemoryBuffer) or not Assigned(BIONewPair) or
     not Assigned(BIORead) or not Assigned(BIOSMemory) or
     not Assigned(BIOWrite) or not Assigned(StackFree) or
     not Assigned(StackNum) or not Assigned(StackValue) or
     not Assigned(PKCS12Parse) or
     not Assigned(SSLContextSetOptions) or
     not Assigned(VersionNumber) or not Assigned(SSLSetAcceptState) or
     not Assigned(SSLSetBIO) or not Assigned(X509CheckPurpose) or
     not Assigned(X509CompareCurrentTime) or
     not Assigned(X509GetExtendedKeyUsage) or
     not Assigned(X509GetExtensionFlags) or
     not Assigned(X509GetIssuerName) or not Assigned(X509GetKeyUsage) or
     not Assigned(X509GetNotAfter) or not Assigned(X509GetNotBefore) or
     not Assigned(X509GetPathLength) or not Assigned(X509GetPublicKey) or
     not Assigned(X509GetSubjectName) or not Assigned(X509NameCompare) or
     not Assigned(X509VerifyCertificate) then
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
  OpenSSLX509CheckPurpose := X509CheckPurpose;
  OpenSSLX509CompareCurrentTime := X509CompareCurrentTime;
  OpenSSLX509GetExtendedKeyUsage := X509GetExtendedKeyUsage;
  OpenSSLX509GetExtensionFlags := X509GetExtensionFlags;
  OpenSSLX509GetIssuerName := X509GetIssuerName;
  OpenSSLX509GetKeyUsage := X509GetKeyUsage;
  OpenSSLX509GetNotAfter := X509GetNotAfter;
  OpenSSLX509GetNotBefore := X509GetNotBefore;
  OpenSSLX509GetPathLength := X509GetPathLength;
  OpenSSLX509GetPublicKey := X509GetPublicKey;
  OpenSSLX509GetSubjectName := X509GetSubjectName;
  OpenSSLX509NameCompare := X509NameCompare;
  OpenSSLX509Verify := X509VerifyCertificate;
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
  ConnectResult, ErrorCode: Integer;
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
    repeat
      ErrClearError;
      ConnectResult := SslConnect(Data.SSL);
      if ConnectResult > 0 then
        Break;
      ErrorCode := SslGetError(Data.SSL, ConnectResult);
      case ErrorCode of
        SSL_ERROR_WANT_READ:
          if AConnection.Deadline <> 0 then
            WaitForTransportSocket(AConnection, True, False)
          else
            Continue;
        SSL_ERROR_WANT_WRITE:
          if AConnection.Deadline <> 0 then
            WaitForTransportSocket(AConnection, False, True)
          else
            Continue;
      else
        raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);
      end;
    until False;

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
  if Assigned(AData.Snapshot) then
    AData.Snapshot.Release;
  AData.SSL := nil;
  AData.ReadBIO := nil;
  AData.Snapshot := nil;
  AData.WriteBIO := nil;
  if Length(AData.PendingPlaintext) > 0 then
    FillChar(AData.PendingPlaintext[0], Length(AData.PendingPlaintext), 0);
  SetLength(AData.PendingPlaintext, 0);
  AData.Free;
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

function OpenSSLServerOutputFlow(
  const AData: TOpenSSLServerData): TTransportSecurityOutputFlow;
var
  BIOPending: Int64;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not Assigned(AData) then
    Exit;
  Result.Capacity := AData.OutputCapacity;
  BIOPending := 0;
  if Assigned(AData.WriteBIO) then
    BIOPending := BIO_ctrl(AData.WriteBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
  if BIOPending < 0 then
    BIOPending := 0;
  Result.PendingBytes := OpenSSLServerPendingCiphertext(AData) +
    Integer(BIOPending);
  Result.RemainingBytes := Result.Capacity - Result.PendingBytes;
  if Result.RemainingBytes < 0 then
    Result.RemainingBytes := 0;
end;

procedure RefreshOpenSSLServerInputFlow(const AData: TOpenSSLServerData);
var
  Pending: Int64;
begin
  if not Assigned(AData) or not Assigned(AData.ReadBIO) then
    Exit;
  Pending := BIO_ctrl(AData.ReadBIO, BIO_CTRL_PENDING_COMMAND, 0, nil);
  if Pending < 0 then
    Pending := 0;
  if Pending > AData.InputHighWatermark then
    Pending := AData.InputHighWatermark;
  AData.InputBuffered := Integer(Pending);
  AData.InputConsumed := AData.InputAccepted - QWord(AData.InputBuffered);
  if AData.InputBackpressured then
    AData.InputBackpressured := AData.InputBuffered >
      AData.InputLowWatermark
  else
    AData.InputBackpressured := AData.InputBuffered >=
      AData.InputHighWatermark;
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
  ContextData := TOpenSSLServerContextData(AContext.AcquireSnapshot);
  if not Assigned(ContextData) or not Assigned(ContextData.Context) then
  begin
    if Assigned(ContextData) then
      ContextData.Release;
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  end;

  try
    Data := TOpenSSLServerData.Create;
  except
    ContextData.Release;
    raise;
  end;
  BIOsOwnedBySSL := False;
  SSLWriteBIO := nil;
  try
    Data.Snapshot := ContextData;
    Data.InputHighWatermark := AContext.FInputHighWatermark;
    Data.InputLowWatermark := AContext.FInputLowWatermark;
    Data.OutputCapacity := AContext.FOutputCapacity;
    Data.SSL := SslNew(ContextData.Context);
    if not Assigned(Data.SSL) then
      raise ETransportSecurityError.Create(
        'Failed to create OpenSSL server session');

    Data.ReadBIO := OpenSSLBIONew(OpenSSLBIOSMemory());
    if (not Assigned(Data.ReadBIO)) or
       (OpenSSLBIONewPair(SSLWriteBIO, Data.OutputCapacity,
       Data.WriteBIO, Data.OutputCapacity) <> 1) then
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
  AcceptedLength: Integer;
  Available: Integer;
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

  RefreshOpenSSLServerInputFlow(Data);
  Available := Data.InputHighWatermark - Data.InputBuffered;
  AcceptedLength := ALength;
  if AcceptedLength > Available then
    AcceptedLength := Available;
  if AcceptedLength <= 0 then
  begin
    Data.InputBackpressured := True;
    Result := 0;
    Exit;
  end;

  Result := OpenSSLBIOWrite(Data.ReadBIO, ABuffer, AcceptedLength);
  if Result <= 0 then
  begin
    PoisonOpenSSLServerConnection(AConnection);
    Result := -1;
    Exit;
  end;
  Inc(Data.InputAccepted, QWord(Result));
  RefreshOpenSSLServerInputFlow(Data);
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
        begin
          if AConnection.Deadline <> 0 then
            WaitForTransportSocket(AConnection,
              ErrorCode = SSL_ERROR_WANT_READ,
              ErrorCode = SSL_ERROR_WANT_WRITE);
          Continue;
        end;
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
        begin
          if AConnection.Deadline <> 0 then
            WaitForTransportSocket(AConnection,
              ErrorCode = SSL_ERROR_WANT_READ,
              ErrorCode = SSL_ERROR_WANT_WRITE);
          Continue;
        end;
    else
      raise ETransportSecurityError.CreateFmt('%s: %d',
        [TLS_WRITE_ERROR, ErrorCode]);
    end;
  until False;
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

function CertificateIsSelfIssued(const ACertificate: Pointer): Boolean;
var
  IssuerName: Pointer;
  SubjectName: Pointer;
begin
  IssuerName := OpenSSLX509GetIssuerName(ACertificate);
  SubjectName := OpenSSLX509GetSubjectName(ACertificate);
  Result := Assigned(IssuerName) and Assigned(SubjectName) and
    (OpenSSLX509NameCompare(IssuerName, SubjectName) = 0);
end;

function CertificateWasSignedBy(const ACertificate,
  AIssuer: Pointer): Boolean;
var
  PublicKey: Pointer;
begin
  PublicKey := OpenSSLX509GetPublicKey(AIssuer);
  if not Assigned(PublicKey) then
    Exit(False);
  try
    Result := OpenSSLX509Verify(ACertificate, PublicKey) = 1;
  finally
    EVP_PKEY_free(PublicKey);
  end;
end;

procedure ValidateCertificateTime(const ACertificate: Pointer;
  const ADescription: string);
var
  NotAfter: Pointer;
  NotBefore: Pointer;
begin
  NotBefore := OpenSSLX509GetNotBefore(ACertificate);
  NotAfter := OpenSSLX509GetNotAfter(ACertificate);
  if not Assigned(NotBefore) or not Assigned(NotAfter) or
     (OpenSSLX509CompareCurrentTime(NotBefore) >= 0) or
     (OpenSSLX509CompareCurrentTime(NotAfter) <= 0) then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s is outside its validity window',
      [ADescription]);
end;

procedure ValidateCertificateConstraints(const ACertificate: Pointer;
  const ADescription: string; const ACertificateAuthority: Boolean);
const
  INVALID_EXTENSION_FLAGS = EXFLAG_INVALID or EXFLAG_CRITICAL or
    EXFLAG_INVALID_POLICY or EXFLAG_NO_FINGERPRINT;
var
  Flags: Cardinal;
  KeyUsage: Cardinal;
begin
  Flags := OpenSSLX509GetExtensionFlags(ACertificate);
  if (Flags and INVALID_EXTENSION_FLAGS) <> 0 then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s contains invalid certificate extensions',
      [ADescription]);
  if ACertificateAuthority and ((Flags and EXFLAG_BCONS) = 0) then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s must include basic constraints',
      [ADescription]);
  if ACertificateAuthority <> ((Flags and EXFLAG_CA) <> 0) then
    if ACertificateAuthority then
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS PKCS#12 %s must assert CA:TRUE basic constraints',
        [ADescription])
    else
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS PKCS#12 %s must assert CA:FALSE basic constraints',
        [ADescription]);
  if ACertificateAuthority and ((Flags and EXFLAG_KUSAGE) <> 0) then
  begin
    KeyUsage := OpenSSLX509GetKeyUsage(ACertificate);
    if (KeyUsage and KU_KEY_CERT_SIGN) = 0 then
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS PKCS#12 %s key usage must permit certificate signing',
        [ADescription]);
  end;
end;

procedure ValidateOpenSSLServerIdentity(const ACertificate,
  AChain: Pointer);
var
  Candidate: Pointer;
  CandidateIndex: Integer;
  CandidateSubjectName: Pointer;
  ChainCount: Integer;
  CurrentCertificate: Pointer;
  ExtendedKeyUsage: Cardinal;
  FoundIndex: Integer;
  I: Integer;
  IssuerName: Pointer;
  NonSelfIssuedCertificateAuthorities: Integer;
  PathLength: LongInt;
  Used: array of Boolean;
  UsedCount: Integer;
begin
  ValidateCertificateTime(ACertificate, 'leaf certificate');
  if CertificateIsSelfIssued(ACertificate) then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 self-signed identities require permissive validation');
  ValidateCertificateConstraints(ACertificate, 'leaf certificate', False);

  if (OpenSSLX509GetExtensionFlags(ACertificate) and EXFLAG_XKUSAGE) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 leaf certificate must include serverAuth extended key usage');
  ExtendedKeyUsage := OpenSSLX509GetExtendedKeyUsage(ACertificate);
  if (ExtendedKeyUsage and (XKU_SSL_SERVER or XKU_ANYEKU)) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 leaf certificate is not valid for server authentication');
  if OpenSSLX509CheckPurpose(ACertificate, X509_PURPOSE_SSL_SERVER, 0) <> 1 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 leaf certificate has an incompatible server purpose');

  if Assigned(AChain) then
    ChainCount := OpenSSLStackNum(AChain)
  else
    ChainCount := 0;
  SetLength(Used, ChainCount);
  for I := 0 to ChainCount - 1 do
  begin
    Candidate := OpenSSLStackValue(AChain, I);
    if not Assigned(Candidate) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 certificate chain contains an empty entry');
    ValidateCertificateTime(Candidate, Format('chain certificate %d',
      [I + 1]));
    ValidateCertificateConstraints(Candidate, Format('chain certificate %d',
      [I + 1]), True);
  end;

  CurrentCertificate := ACertificate;
  NonSelfIssuedCertificateAuthorities := 0;
  UsedCount := 0;
  while UsedCount < ChainCount do
  begin
    IssuerName := OpenSSLX509GetIssuerName(CurrentCertificate);
    FoundIndex := -1;
    for CandidateIndex := 0 to ChainCount - 1 do
      if not Used[CandidateIndex] then
      begin
        Candidate := OpenSSLStackValue(AChain, CandidateIndex);
        CandidateSubjectName := OpenSSLX509GetSubjectName(Candidate);
        if Assigned(IssuerName) and
           Assigned(CandidateSubjectName) and
           (OpenSSLX509NameCompare(IssuerName, CandidateSubjectName) = 0) and
           CertificateWasSignedBy(CurrentCertificate, Candidate) then
        begin
          if FoundIndex >= 0 then
            raise ETransportSecurityError.Create(
              'Configured TLS PKCS#12 certificate chain has ambiguous issuers');
          FoundIndex := CandidateIndex;
        end;
      end;
    if FoundIndex < 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 certificate chain is structurally or cryptographically incoherent');
    Candidate := OpenSSLStackValue(AChain, FoundIndex);
    PathLength := OpenSSLX509GetPathLength(Candidate);
    if (PathLength >= 0) and
       (NonSelfIssuedCertificateAuthorities > PathLength) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 certificate chain exceeds an issuer path-length constraint');
    Used[FoundIndex] := True;
    Inc(UsedCount);
    CurrentCertificate := Candidate;
    if not CertificateIsSelfIssued(CurrentCertificate) then
      Inc(NonSelfIssuedCertificateAuthorities);
  end;

  if CertificateIsSelfIssued(CurrentCertificate) then
  begin
    if not CertificateWasSignedBy(CurrentCertificate, CurrentCertificate) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 certificate chain has an invalid root signature');
  end
  else
  begin
    IssuerName := OpenSSLX509GetIssuerName(CurrentCertificate);
    CandidateSubjectName := OpenSSLX509GetSubjectName(ACertificate);
    if Assigned(IssuerName) and Assigned(CandidateSubjectName) and
       (OpenSSLX509NameCompare(IssuerName, CandidateSubjectName) = 0) and
       CertificateWasSignedBy(CurrentCertificate, ACertificate) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 certificate chain contains a certificate cycle');
    for I := 0 to ChainCount - 1 do
    begin
      Candidate := OpenSSLStackValue(AChain, I);
      if Candidate = CurrentCertificate then
        Continue;
      CandidateSubjectName := OpenSSLX509GetSubjectName(Candidate);
      if Assigned(IssuerName) and Assigned(CandidateSubjectName) and
         (OpenSSLX509NameCompare(IssuerName, CandidateSubjectName) = 0) and
         CertificateWasSignedBy(CurrentCertificate, Candidate) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 certificate chain contains a certificate cycle');
    end;
  end;
end;

procedure ConfigureOpenSSLServerIdentity(const AContext: PSSL_CTX;
  var AIdentity: TBytes; const APassphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation);
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

    if AValidation = tsivStrict then
      ValidateOpenSSLServerIdentity(Certificate, Chain);

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

function CreateOpenSSLServerSnapshot(const APkcs12Identity: TBytes;
  const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation):
  TOpenSSLServerContextData;
var
  Context: PSSL_CTX;
  Identity: TBytes;
begin
  Result := nil;
  if Length(APkcs12Identity) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity is empty');
  if Length(APkcs12Identity) > MAX_PKCS12_IDENTITY_SIZE then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
  SetLength(Identity, Length(APkcs12Identity));
  Move(APkcs12Identity[0], Identity[0], Length(Identity));
  Context := nil;
  try
    Context := CreateOpenSSLServerContext;
    ConfigureOpenSSLServerIdentity(Context, Identity,
      APkcs12Passphrase, AValidation);
    Result := TOpenSSLServerContextData.Create(Context);
    Context := nil;
  finally
    if Assigned(Context) then
      SslCtxFree(Context);
    WipeBytes(Identity);
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

  TSecPkgContextConnectionInfo = record
    dwProtocol: LongWord;
    aiCipher: LongWord;
    dwCipherStrength: LongWord;
    aiHash: LongWord;
    dwHashStrength: LongWord;
    aiExch: LongWord;
    dwExchStrength: LongWord;
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

  PTlsParameters = ^TTlsParameters;
  TTlsParameters = record
    cAlpnIds: LongWord;
    rgstrAlpnIds: Pointer;
    grbitDisabledProtocols: LongWord;
    cDisabledCrypto: LongWord;
    pDisabledCrypto: Pointer;
    dwFlags: LongWord;
  end;

  PSchCredentials = ^TSchCredentials;
  TSchCredentials = record
    dwVersion: LongWord;
    dwCredFormat: LongWord;
    cCreds: LongWord;
    paCred: Pointer;
    hRootStore: Pointer;
    cMappers: LongWord;
    aphMappers: Pointer;
    dwSessionLifespan: LongWord;
    dwFlags: LongWord;
    cTlsParameters: LongWord;
    pTlsParameters: PTlsParameters;
  end;

  TRtlOsVersionInfoW = record
    dwOSVersionInfoSize: LongWord;
    dwMajorVersion: LongWord;
    dwMinorVersion: LongWord;
    dwBuildNumber: LongWord;
    dwPlatformId: LongWord;
    szCSDVersion: array[0..127] of WideChar;
  end;

{$IFDEF CPU64}
  {$IF SizeOf(TSchCredentials) <> 72}
    {$FATAL SCH_CREDENTIALS v5 layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TTlsParameters) <> 40}
    {$FATAL TLS_PARAMETERS layout mismatch on 64-bit Windows}
  {$ENDIF}
{$ELSE}
  {$IF SizeOf(TSchCredentials) <> 44}
    {$FATAL SCH_CREDENTIALS v5 layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TTlsParameters) <> 24}
    {$FATAL TLS_PARAMETERS layout mismatch on 32-bit Windows}
  {$ENDIF}
{$ENDIF}
  {$IF SizeOf(TRtlOsVersionInfoW) <> 276}
    {$FATAL RTL_OSVERSIONINFOW layout mismatch on Windows}
  {$ENDIF}

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
  SECPKG_ATTR_CONNECTION_INFO = $5A;
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
  SCH_CREDENTIALS_VERSION = 5;
  SCH_USE_STRONG_CRYPTO = $00400000;
  SCHANNEL_SHUTDOWN = 1;
  SECURITY_NATIVE_DREP = $00000010;
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';
  SECBUFFER_ATTRMASK = $F0000000;
  WINDOWS_10_1809_BUILD = 17763;

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
function RtlGetVersion(var AVersion: TRtlOsVersionInfoW): LongInt; stdcall;
  external 'ntdll.dll' name 'RtlGetVersion';

function SChannelSupportsTlsParameters: Boolean;
var
  Version: TRtlOsVersionInfoW;
begin
  FillChar(Version, SizeOf(Version), 0);
  Version.dwOSVersionInfoSize := SizeOf(Version);
  Result := (RtlGetVersion(Version) = 0) and
    ((Version.dwMajorVersion > 10) or
     ((Version.dwMajorVersion = 10) and
      (Version.dwBuildNumber >= WINDOWS_10_1809_BUILD)));
end;

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

function ReceiveIntoBuffer(
  const AConnection: TTransportSecurityConnection;
  var ABuffer: TBytes): Integer;
var
  Temporary: array[0..8191] of Byte;
begin
  repeat
    Result := SocketReceive(AConnection.Socket, @Temporary[0],
      Length(Temporary));
    if (Result < 0) and TransportSocketWouldBlock and
       (AConnection.Deadline <> 0) then
      WaitForTransportSocket(AConnection, True, False)
    else
      Break;
  until False;
  if Result > 0 then
    AppendBytes(ABuffer, @Temporary[0], Result);
end;

procedure SendSChannelToken(
  const AConnection: TTransportSecurityConnection;
  const ABuffer: TSecBuffer);
begin
  if (ABuffer.cbBuffer > 0) and Assigned(ABuffer.pvBuffer) then
    SendSocketAll(AConnection, ABuffer.pvBuffer, ABuffer.cbBuffer);
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

      try
        SendSChannelToken(AConnection, OutputBuffer);
      finally
        if Assigned(OutputBuffer.pvBuffer) then
          FreeContextBuffer(OutputBuffer.pvBuffer);
      end;

      if Status = SEC_E_INCOMPLETE_MESSAGE then
      begin
        ReceiveCount := ReceiveIntoBuffer(AConnection,
          Data.EncryptedInput);
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
          ReceiveCount := ReceiveIntoBuffer(AConnection,
            Data.EncryptedInput);
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

        try
          if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) or
             (Status = SEC_I_CONTEXT_EXPIRED) then
            try
              SendSChannelToken(AConnection, OutputBuffer);
            except
              on E: ETransportSecurityError do
                ; // Best-effort close must not mask the request result.
            end;
        finally
          if Assigned(OutputBuffer.pvBuffer) then
            FreeContextBuffer(OutputBuffer.pvBuffer);
        end;
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
      ReceiveCount := ReceiveIntoBuffer(AConnection, Data.EncryptedInput);
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
      ReceiveCount := ReceiveIntoBuffer(AConnection, Data.EncryptedInput);
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
    { Harvest from index 1. DecryptMessage relabels the descriptor in place
      on success — [0] becomes SECBUFFER_STREAM_HEADER, [1] the plaintext —
      but on SEC_I_CONTEXT_EXPIRED it returns without touching the buffers,
      so [0] still carries the caller-supplied SECBUFFER_DATA label over the
      whole ciphertext. Scanning from 0 therefore turns a peer close_notify
      into a payload of raw ciphertext. }
    if not ContextExpired then
      for I := 1 to High(Buffers) do
        if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_DATA then
          AppendBytes(Data.DecryptedInput, Buffers[I].pvBuffer,
            Buffers[I].cbBuffer);

    { SECBUFFER_EXTRA belongs to Data.EncryptedInput. Some SChannel
      builds report only cbBuffer, so fall back to preserving the input
      tail before replacing the array that owns those bytes. }
    SetLength(ExtraInput, 0);
    for I := 1 to High(Buffers) do
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
    SendSocketAll(AConnection, @Message[0], TotalLength);
    Inc(PlainOffset, ChunkLength);
    Inc(Result, ChunkLength);
  end;
end;

{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
{ Native SChannel server accept.

  This backend is the Windows twin of the memory-BIO OpenSSL server backend
  and reproduces its observable state machine exactly (ADR-0024): the same
  tssDone/tssWantRead/tssWantWrite/tssError/tssPeerClosed transitions, the
  same accepted-prefix input admission with high/low-watermark hysteresis,
  the same exact pending/remaining output accounting against
  OutputCapacity, the same retained-plaintext write retry, and the same
  poison-on-fatal-error behaviour. Consumers (duetto's IOCP TLS transport)
  drive one API across both platforms, so drift here is a defect.

  Two mechanical differences are deliberate and invisible to callers:

  - OpenSSL buffers unconsumed ciphertext inside its read BIO; SChannel has
    no such buffer, so EncryptedInput plays that role. SECBUFFER_EXTRA
    leftovers from AcceptSecurityContext and DecryptMessage are written back
    into it, which is what keeps ConsumedBytes = AcceptedBytes - Buffered
    identical to the BIO-pending accounting.
  - OpenSSL writes records straight into a capacity-sized BIO and can leave a
    record split across the capacity boundary. EncryptMessage produces whole
    records and AcceptSecurityContext whole tokens, so whichever does not fit
    is queued as a prefix and its tail is retained in RecordBuffer until
    capacity frees up. Pending output is therefore still exactly
    OutputCapacity when saturated, and a certificate flight larger than the
    configured capacity drains incrementally instead of failing. }

type
  HCERTSTORE = Pointer;

  PCryptDataBlob = ^TCryptDataBlob;
  TCryptDataBlob = record
    cbData: LongWord;
    pbData: PByte;
  end;

  TCryptBitBlob = record
    cbData: LongWord;
    pbData: PByte;
    cUnusedBits: LongWord;
  end;

  TCryptAlgorithmIdentifier = record
    pszObjId: PAnsiChar;
    Parameters: TCryptDataBlob;
  end;

  TCertPublicKeyInfo = record
    Algorithm: TCryptAlgorithmIdentifier;
    PublicKey: TCryptBitBlob;
  end;

  PCertExtension = ^TCertExtension;
  TCertExtension = record
    pszObjId: PAnsiChar;
    fCritical: LongBool;
    Value: TCryptDataBlob;
  end;

  PCertInfo = ^TCertInfo;
  TCertInfo = record
    dwVersion: LongWord;
    SerialNumber: TCryptDataBlob;
    SignatureAlgorithm: TCryptAlgorithmIdentifier;
    Issuer: TCryptDataBlob;
    NotBefore: TFileTime;
    NotAfter: TFileTime;
    Subject: TCryptDataBlob;
    SubjectPublicKeyInfo: TCertPublicKeyInfo;
    IssuerUniqueId: TCryptBitBlob;
    SubjectUniqueId: TCryptBitBlob;
    cExtension: LongWord;
    rgExtension: PCertExtension;
  end;

  PCertContext = ^TCertContext;
  TCertContext = record
    dwCertEncodingType: LongWord;
    pbCertEncoded: PByte;
    cbCertEncoded: LongWord;
    pCertInfo: PCertInfo;
    hCertStore: HCERTSTORE;
  end;

  PPAnsiCharLWPT = ^PAnsiChar;

  PCertEnhancedKeyUsage = ^TCertEnhancedKeyUsage;
  TCertEnhancedKeyUsage = record
    cUsageIdentifier: LongWord;
    rgpszUsageIdentifier: PPAnsiCharLWPT;
  end;

  TCertBasicConstraints2Info = record
    fCA: LongBool;
    fPathLenConstraint: LongBool;
    dwPathLenConstraint: LongWord;
  end;

  PCryptKeyProviderInfo = ^TCryptKeyProviderInfo;
  TCryptKeyProviderInfo = record
    pwszContainerName: PWideChar;
    pwszProvName: PWideChar;
    dwProvType: LongWord;
    dwFlags: LongWord;
    cProvParam: LongWord;
    rgProvParam: Pointer;
    dwKeySpec: LongWord;
  end;

  PPCertContext = ^PCertContext;
  TCertContextArray = array of PCertContext;

  TSChannelServerCredentialData = class
  public
    Certificate: PCertContext;
    Credential: TSecHandle;
    HasCredential: Boolean;
    HasPrivateKey: Boolean;
    IssuerStore: HCERTSTORE;
    KeyContainerName: UnicodeString;
    PrivateKey: PtrUInt;
    PublishedIssuers: TCertContextArray;
    References: LongInt;
    Store: HCERTSTORE;
    constructor Create;
    procedure Retain;
    procedure Release;
  end;

  TSChannelServerData = class
  public
    Context: TSecHandle;
    EncryptedInput: TBytes;
    HandshakeDone: Boolean;
    HasContext: Boolean;
    InputAccepted: QWord;
    InputBackpressured: Boolean;
    InputBuffered: Integer;
    InputConsumed: QWord;
    InputHighWatermark: Integer;
    InputLowWatermark: Integer;
    Output: TBytes;
    OutputCapacity: Integer;
    OutputOffset: Integer;
    PeerClosed: Boolean;
    PostHandshakeInProgress: Boolean;
    PendingPlaintext: TBytes;
    PendingPlaintextOffset: Integer;
    Plaintext: TBytes;
    PlaintextOffset: Integer;
    RecordBuffer: TBytes;
    RecordOffset: Integer;
    Protocol: LongWord;
    ShutdownStarted: Boolean;
    Snapshot: TSChannelServerCredentialData;
    StreamSizes: TSecPkgContextStreamSizes;
  end;

const
  SECPKG_CRED_INBOUND = 1;
  ASC_REQ_REPLAY_DETECT = $00000004;
  ASC_REQ_SEQUENCE_DETECT = $00000008;
  ASC_REQ_CONFIDENTIALITY = $00000010;
  ASC_REQ_ALLOCATE_MEMORY = $00000100;
  ASC_REQ_EXTENDED_ERROR = $00008000;
  ASC_REQ_STREAM = $00010000;
  SP_PROT_SSL2_SERVER = $00000004;
  SP_PROT_SSL3_SERVER = $00000010;
  SP_PROT_TLS1_0_SERVER = $00000040;
  SP_PROT_TLS1_1_SERVER = $00000100;
  SP_PROT_TLS1_2_SERVER = $00000400;
  SP_PROT_TLS1_3_SERVER = $00001000;
  SCH_CRED_NO_SYSTEM_MAPPER = $00000002;
  X509_ASN_ENCODING = $00000001;
  PKCS_7_ASN_ENCODING = $00010000;
  CERT_ENCODING_TYPES = X509_ASN_ENCODING or PKCS_7_ASN_ENCODING;
  CERT_FIND_HAS_PRIVATE_KEY = $00150000;
  CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG = $00000002;
  X509_BASIC_CONSTRAINTS2 = 15;
  PKCS12_ALWAYS_CNG_KSP = $00000200;
  CRYPT_USER_KEYSET = $00001000;
  CRYPT_ACQUIRE_SILENT_FLAG = $00000040;
  CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG = $00040000;
  CERT_NCRYPT_KEY_SPEC = LongWord($FFFFFFFF);
  CERT_KEY_PROV_INFO_PROP_ID = 2;
  NCRYPT_SILENT_FLAG = $00000040;
  CERT_STORE_ADD_ALWAYS = 4;
  INTERMEDIATE_AUTHORITY_STORE = 'CA';
  CERT_KEY_CERT_SIGN_KEY_USAGE = $04;
  { X509_PURPOSE_SSL_SERVER rejects a leaf whose key usage asserts none of
    digitalSignature, keyEncipherment, or keyAgreement. }
  SERVER_PURPOSE_KEY_USAGE = $80 or $20 or $08;
  OID_BASIC_CONSTRAINTS2 = '2.5.29.19';
  OID_SERVER_AUTHENTICATION = '1.3.6.1.5.5.7.3.1';
  OID_ANY_ENHANCED_KEY_USAGE = '2.5.29.37.0';
  SCHANNEL_SERVER_IDENTITY_PARSE_ERROR =
    'Failed to parse configured TLS PKCS#12 identity; verify the bundle and passphrase';

function AcceptSecurityContext(ACredential: PCredHandle;
  AContext: PCtxtHandle; AInput: PSecBufferDesc;
  AContextRequirements: LongWord; ATargetDataRepresentation: LongWord;
  ANewContext: PCtxtHandle; AOutput: PSecBufferDesc;
  AContextAttributes: PLongWord;
  AExpiry: PSecurityInteger): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'AcceptSecurityContext';
function PFXImportCertStore(APkcs12: PCryptDataBlob; APassword: PWideChar;
  AFlags: LongWord): HCERTSTORE; stdcall;
  external 'crypt32.dll' name 'PFXImportCertStore';
function CertCloseStore(AStore: HCERTSTORE;
  AFlags: LongWord): LongBool; stdcall;
  external 'crypt32.dll' name 'CertCloseStore';
function CertFindCertificateInStore(AStore: HCERTSTORE;
  AEncodingType, AFindFlags, AFindType: LongWord; AFindParameter: Pointer;
  APreviousContext: PCertContext): PCertContext; stdcall;
  external 'crypt32.dll' name 'CertFindCertificateInStore';
function CertEnumCertificatesInStore(AStore: HCERTSTORE;
  APreviousContext: PCertContext): PCertContext; stdcall;
  external 'crypt32.dll' name 'CertEnumCertificatesInStore';
function CertDuplicateCertificateContext(
  ACertificate: PCertContext): PCertContext; stdcall;
  external 'crypt32.dll' name 'CertDuplicateCertificateContext';
function CertFreeCertificateContext(
  ACertificate: PCertContext): LongBool; stdcall;
  external 'crypt32.dll' name 'CertFreeCertificateContext';
function CertCompareCertificateName(AEncodingType: LongWord;
  AFirstName, ASecondName: PCryptDataBlob): LongBool; stdcall;
  external 'crypt32.dll' name 'CertCompareCertificateName';
function CertFindExtension(AObjectIdentifier: PAnsiChar;
  AExtensionCount: LongWord;
  AExtensions: PCertExtension): PCertExtension; stdcall;
  external 'crypt32.dll' name 'CertFindExtension';
function CertGetIntendedKeyUsage(AEncodingType: LongWord;
  ACertificateInfo: PCertInfo; AKeyUsage: Pointer;
  AKeyUsageLength: LongWord): LongBool; stdcall;
  external 'crypt32.dll' name 'CertGetIntendedKeyUsage';
function CertGetEnhancedKeyUsage(ACertificate: PCertContext;
  AFlags: LongWord; AUsage: Pointer;
  var AUsageLength: LongWord): LongBool; stdcall;
  external 'crypt32.dll' name 'CertGetEnhancedKeyUsage';
function CertVerifyTimeValidity(ATime: Pointer;
  ACertificateInfo: PCertInfo): LongInt; stdcall;
  external 'crypt32.dll' name 'CertVerifyTimeValidity';
function CryptDecodeObjectEx(AEncodingType: LongWord;
  AStructureType: PAnsiChar; AEncoded: PByte; AEncodedLength: LongWord;
  AFlags: LongWord; ADecodeParameters: Pointer; AStructureInfo: Pointer;
  var AStructureInfoLength: LongWord): LongBool; stdcall;
  external 'crypt32.dll' name 'CryptDecodeObjectEx';
function CryptVerifyCertificateSignatureEx(ACryptProvider: PtrUInt;
  AEncodingType, ASubjectType: LongWord; ASubject: Pointer;
  AIssuerType: LongWord; AIssuer: Pointer; AFlags: LongWord;
  AExtra: Pointer): LongBool; stdcall;
  external 'crypt32.dll' name 'CryptVerifyCertificateSignatureEx';
function CryptAcquireCertificatePrivateKey(ACertificate: PCertContext;
  AFlags: LongWord; AParameters: Pointer; out AKey: PtrUInt;
  out AKeySpec: LongWord; out ACallerFree: LongBool): LongBool; stdcall;
  external 'crypt32.dll' name 'CryptAcquireCertificatePrivateKey';
function CertGetCertificateContextProperty(ACertificate: PCertContext;
  APropertyIdentifier: LongWord; AData: Pointer;
  var ADataLength: LongWord): LongBool; stdcall;
  external 'crypt32.dll' name 'CertGetCertificateContextProperty';
function NCryptDeleteKey(AKey: PtrUInt; AFlags: LongWord): LongInt; stdcall;
  external 'ncrypt.dll' name 'NCryptDeleteKey';
function NCryptFreeObject(AObject: PtrUInt): LongInt; stdcall;
  external 'ncrypt.dll' name 'NCryptFreeObject';
function CertOpenSystemStoreW(ACryptProvider: PtrUInt;
  ASubsystemProtocol: PWideChar): HCERTSTORE; stdcall;
  external 'crypt32.dll' name 'CertOpenSystemStoreW';
function CertAddCertificateContextToStore(AStore: HCERTSTORE;
  ACertificate: PCertContext; ADisposition: LongWord;
  AStoreContext: PPCertContext): LongBool; stdcall;
  external 'crypt32.dll' name 'CertAddCertificateContextToStore';
function CertDeleteCertificateFromStore(
  ACertificate: PCertContext): LongBool; stdcall;
  external 'crypt32.dll' name 'CertDeleteCertificateFromStore';

constructor TSChannelServerCredentialData.Create;
begin
  inherited Create;
  FillChar(Credential, SizeOf(Credential), 0);
  Certificate := nil;
  HasCredential := False;
  HasPrivateKey := False;
  IssuerStore := nil;
  KeyContainerName := '';
  PrivateKey := 0;
  SetLength(PublishedIssuers, 0);
  References := 1;
  Store := nil;
end;

procedure TSChannelServerCredentialData.Retain;
begin
  InterlockedIncrement(References);
end;

procedure TSChannelServerCredentialData.Release;
var
  I: Integer;
begin
  if InterlockedDecrement(References) <> 0 then
    Exit;
  if HasCredential then
  begin
    FreeCredentialsHandle(@Credential);
    HasCredential := False;
  end;
  { The imported private key is persisted, so the snapshot owns a container
    that must not outlive it. Deletion happens only here, at the last
    reference, which is what lets a reloaded-away snapshot keep serving live
    connections until they finish. NCryptDeleteKey both removes the container
    and frees the handle; NCryptFreeObject is the fallback so a failed delete
    still releases the handle. }
  if HasPrivateKey then
  begin
    if NCryptDeleteKey(PrivateKey, NCRYPT_SILENT_FLAG) <> 0 then
      NCryptFreeObject(PrivateKey);
    PrivateKey := 0;
    HasPrivateKey := False;
  end;
  KeyContainerName := '';
  { Withdraw the issuers this snapshot published. CertDeleteCertificateFromStore
    frees the context as well, on success and on failure alike. }
  for I := High(PublishedIssuers) downto 0 do
    if Assigned(PublishedIssuers[I]) then
      CertDeleteCertificateFromStore(PublishedIssuers[I]);
  SetLength(PublishedIssuers, 0);
  if Assigned(IssuerStore) then
  begin
    CertCloseStore(IssuerStore, 0);
    IssuerStore := nil;
  end;
  if Assigned(Certificate) then
  begin
    CertFreeCertificateContext(Certificate);
    Certificate := nil;
  end;
  { Closed without CERT_CLOSE_STORE_FORCE_FLAG: SChannel holds its own
    reference to the leaf context, and the store is what supplies the
    bundled intermediates it sends during the handshake. }
  if Assigned(Store) then
  begin
    CertCloseStore(Store, 0);
    Store := nil;
  end;
  Free;
end;

function SChannelObjectIdentifierMatches(const AIdentifier: PAnsiChar;
  const AExpected: AnsiString): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not Assigned(AIdentifier) then
    Exit;
  for I := 1 to Length(AExpected) do
    if AIdentifier[I - 1] <> AExpected[I] then
      Exit;
  Result := AIdentifier[Length(AExpected)] = #0;
end;

function SChannelSameCertificate(const AFirst,
  ASecond: PCertContext): Boolean;
begin
  Result := Assigned(AFirst) and Assigned(ASecond) and
    (AFirst^.cbCertEncoded = ASecond^.cbCertEncoded) and
    ((AFirst^.cbCertEncoded = 0) or
    (CompareByte(AFirst^.pbCertEncoded^, ASecond^.pbCertEncoded^,
    AFirst^.cbCertEncoded) = 0));
end;

function SChannelCertificateIsSelfIssued(
  const ACertificate: PCertContext): Boolean;
begin
  Result := CertCompareCertificateName(X509_ASN_ENCODING,
    @ACertificate^.pCertInfo^.Issuer, @ACertificate^.pCertInfo^.Subject);
end;

function SChannelCertificateWasSignedBy(const ACertificate,
  AIssuer: PCertContext): Boolean;
const
  CRYPT_VERIFY_CERT_SIGN_SUBJECT_CERT = 2;
  CRYPT_VERIFY_CERT_SIGN_ISSUER_CERT = 2;
begin
  Result := CryptVerifyCertificateSignatureEx(0, X509_ASN_ENCODING,
    CRYPT_VERIFY_CERT_SIGN_SUBJECT_CERT, ACertificate,
    CRYPT_VERIFY_CERT_SIGN_ISSUER_CERT, AIssuer, 0, nil);
end;

function SChannelCertificateIssuedBySubjectOf(const ACertificate,
  ACandidateIssuer: PCertContext): Boolean;
begin
  Result := CertCompareCertificateName(X509_ASN_ENCODING,
    @ACertificate^.pCertInfo^.Issuer,
    @ACandidateIssuer^.pCertInfo^.Subject);
end;

procedure ValidateSChannelCertificateTime(const ACertificate: PCertContext;
  const ADescription: string);
begin
  if CertVerifyTimeValidity(nil, ACertificate^.pCertInfo) <> 0 then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s is outside its validity window',
      [ADescription]);
end;

function SChannelBasicConstraints(const ACertificate: PCertContext;
  out ACertificateAuthority: Boolean; out APathLength: LongInt): Boolean;
var
  Constraints: TCertBasicConstraints2Info;
  ConstraintsLength: LongWord;
  Extension: PCertExtension;
begin
  ACertificateAuthority := False;
  APathLength := -1;
  Extension := CertFindExtension(PAnsiChar(OID_BASIC_CONSTRAINTS2),
    ACertificate^.pCertInfo^.cExtension, ACertificate^.pCertInfo^.rgExtension);
  Result := Assigned(Extension);
  if not Result then
    Exit;
  FillChar(Constraints, SizeOf(Constraints), 0);
  ConstraintsLength := SizeOf(Constraints);
  if not CryptDecodeObjectEx(X509_ASN_ENCODING,
    PAnsiChar(PtrUInt(X509_BASIC_CONSTRAINTS2)), Extension^.Value.pbData,
    Extension^.Value.cbData, 0, nil, @Constraints, ConstraintsLength) then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity has unreadable basic constraints');
  ACertificateAuthority := Constraints.fCA;
  if ACertificateAuthority and Constraints.fPathLenConstraint then
    APathLength := LongInt(Constraints.dwPathLenConstraint);
end;

function SChannelIntendedKeyUsage(const ACertificate: PCertContext;
  out AKeyUsage: Byte): Boolean;
var
  Bits: array[0..1] of Byte;
begin
  Bits[0] := 0;
  Bits[1] := 0;
  Result := CertGetIntendedKeyUsage(X509_ASN_ENCODING,
    ACertificate^.pCertInfo, @Bits[0], SizeOf(Bits));
  AKeyUsage := Bits[0];
end;

function SChannelHasServerAuthentication(const ACertificate: PCertContext;
  out AExtensionPresent: Boolean): Boolean;
var
  Buffer: TBytes;
  Identifier: PAnsiChar;
  I: Integer;
  Usage: PCertEnhancedKeyUsage;
  UsageLength: LongWord;
begin
  Result := False;
  AExtensionPresent := False;
  UsageLength := 0;
  if not CertGetEnhancedKeyUsage(ACertificate,
    CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG, nil, UsageLength) then
    Exit;
  if UsageLength < LongWord(SizeOf(TCertEnhancedKeyUsage)) then
    Exit;
  SetLength(Buffer, UsageLength);
  if not CertGetEnhancedKeyUsage(ACertificate,
    CERT_FIND_EXT_ONLY_ENHKEY_USAGE_FLAG, @Buffer[0], UsageLength) then
    Exit;
  AExtensionPresent := True;
  Usage := PCertEnhancedKeyUsage(@Buffer[0]);
  if not Assigned(Usage^.rgpszUsageIdentifier) then
    Exit;
  for I := 0 to Integer(Usage^.cUsageIdentifier) - 1 do
  begin
    Identifier := PPAnsiCharLWPT(PtrUInt(Usage^.rgpszUsageIdentifier) +
      PtrUInt(I) * PtrUInt(SizeOf(PAnsiChar)))^;
    if SChannelObjectIdentifierMatches(Identifier,
       OID_SERVER_AUTHENTICATION) or
       SChannelObjectIdentifierMatches(Identifier,
       OID_ANY_ENHANCED_KEY_USAGE) then
      Exit(True);
  end;
end;

procedure ValidateSChannelCertificateConstraints(
  const ACertificate: PCertContext; const ADescription: string;
  const ACertificateAuthority: Boolean);
var
  IsCertificateAuthority: Boolean;
  KeyUsage: Byte;
  PathLength: LongInt;
  Present: Boolean;
begin
  Present := SChannelBasicConstraints(ACertificate, IsCertificateAuthority,
    PathLength);
  if ACertificateAuthority and not Present then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s must include basic constraints',
      [ADescription]);
  if ACertificateAuthority <> (Present and IsCertificateAuthority) then
    if ACertificateAuthority then
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS PKCS#12 %s must assert CA:TRUE basic constraints',
        [ADescription])
    else
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS PKCS#12 %s must assert CA:FALSE basic constraints',
        [ADescription]);
  if ACertificateAuthority and
     SChannelIntendedKeyUsage(ACertificate, KeyUsage) and
     ((KeyUsage and CERT_KEY_CERT_SIGN_KEY_USAGE) = 0) then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS PKCS#12 %s key usage must permit certificate signing',
      [ADescription]);
end;

function SChannelCertificatePathLength(
  const ACertificate: PCertContext): LongInt;
var
  IsCertificateAuthority: Boolean;
begin
  if not SChannelBasicConstraints(ACertificate, IsCertificateAuthority,
    Result) then
    Result := -1;
end;

{ Strict identity policy, ported rule for rule from the OpenSSL backend's
  ValidateOpenSSLServerIdentity so both platforms reject the same bundles
  with the same messages. One documented gap: OpenSSL additionally refuses a
  certificate carrying an unhandled critical extension (EXFLAG_CRITICAL) or
  an invalid policy encoding (EXFLAG_INVALID_POLICY); crypt32 exposes no
  equivalent aggregate flag, so those two sub-cases are not reproduced.
  Everything the tests and ADR-0024 pin — validity windows, self-signed
  refusal, basic constraints, issuer key usage, serverAuth purpose,
  chain coherence, path length, and cycles — is enforced identically. }
procedure ValidateSChannelServerIdentity(const AStore: HCERTSTORE;
  const ACertificate: PCertContext);
var
  Candidate: PCertContext;
  CandidateIndex: Integer;
  Chain: array of PCertContext;
  ChainCount: Integer;
  CurrentCertificate: PCertContext;
  Enumerated: PCertContext;
  ExtendedKeyUsagePresent: Boolean;
  FoundIndex: Integer;
  I: Integer;
  KeyUsage: Byte;
  NonSelfIssuedCertificateAuthorities: Integer;
  PathLength: LongInt;
  Used: array of Boolean;
  UsedCount: Integer;
begin
  ValidateSChannelCertificateTime(ACertificate, 'leaf certificate');
  if SChannelCertificateIsSelfIssued(ACertificate) then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 self-signed identities require permissive validation');
  ValidateSChannelCertificateConstraints(ACertificate, 'leaf certificate',
    False);

  if not SChannelHasServerAuthentication(ACertificate,
    ExtendedKeyUsagePresent) then
  begin
    if not ExtendedKeyUsagePresent then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 leaf certificate must include serverAuth extended key usage');
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 leaf certificate is not valid for server authentication');
  end;
  if SChannelIntendedKeyUsage(ACertificate, KeyUsage) and
     ((KeyUsage and SERVER_PURPOSE_KEY_USAGE) = 0) then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 leaf certificate has an incompatible server purpose');

  SetLength(Chain, 0);
  Enumerated := nil;
  try
    Enumerated := CertEnumCertificatesInStore(AStore, nil);
    while Assigned(Enumerated) do
    begin
      if not SChannelSameCertificate(Enumerated, ACertificate) then
      begin
        { Grow first so the duplicate always has an owner: a failure between
          duplicating and storing would otherwise leak the context. }
        SetLength(Chain, Length(Chain) + 1);
        Chain[High(Chain)] := nil;
        Candidate := CertDuplicateCertificateContext(Enumerated);
        if not Assigned(Candidate) then
          raise ETransportSecurityError.Create(
            'Configured TLS PKCS#12 certificate chain contains an empty entry');
        Chain[High(Chain)] := Candidate;
      end;
      Enumerated := CertEnumCertificatesInStore(AStore, Enumerated);
    end;

    ChainCount := Length(Chain);
    SetLength(Used, ChainCount);
    for I := 0 to ChainCount - 1 do
    begin
      ValidateSChannelCertificateTime(Chain[I],
        Format('chain certificate %d', [I + 1]));
      ValidateSChannelCertificateConstraints(Chain[I],
        Format('chain certificate %d', [I + 1]), True);
    end;

    CurrentCertificate := ACertificate;
    NonSelfIssuedCertificateAuthorities := 0;
    UsedCount := 0;
    while UsedCount < ChainCount do
    begin
      FoundIndex := -1;
      for CandidateIndex := 0 to ChainCount - 1 do
        if not Used[CandidateIndex] then
        begin
          Candidate := Chain[CandidateIndex];
          if SChannelCertificateIssuedBySubjectOf(CurrentCertificate,
             Candidate) and
             SChannelCertificateWasSignedBy(CurrentCertificate, Candidate) then
          begin
            if FoundIndex >= 0 then
              raise ETransportSecurityError.Create(
                'Configured TLS PKCS#12 certificate chain has ambiguous issuers');
            FoundIndex := CandidateIndex;
          end;
        end;
      if FoundIndex < 0 then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 certificate chain is structurally or cryptographically incoherent');
      Candidate := Chain[FoundIndex];
      PathLength := SChannelCertificatePathLength(Candidate);
      if (PathLength >= 0) and
         (NonSelfIssuedCertificateAuthorities > PathLength) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 certificate chain exceeds an issuer path-length constraint');
      Used[FoundIndex] := True;
      Inc(UsedCount);
      CurrentCertificate := Candidate;
      if not SChannelCertificateIsSelfIssued(CurrentCertificate) then
        Inc(NonSelfIssuedCertificateAuthorities);
    end;

    if SChannelCertificateIsSelfIssued(CurrentCertificate) then
    begin
      if not SChannelCertificateWasSignedBy(CurrentCertificate,
        CurrentCertificate) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 certificate chain has an invalid root signature');
    end
    else
    begin
      if SChannelCertificateIssuedBySubjectOf(CurrentCertificate,
         ACertificate) and
         SChannelCertificateWasSignedBy(CurrentCertificate, ACertificate) then
        raise ETransportSecurityError.Create(
          'Configured TLS PKCS#12 certificate chain contains a certificate cycle');
      for I := 0 to ChainCount - 1 do
      begin
        Candidate := Chain[I];
        if Candidate = CurrentCertificate then
          Continue;
        if SChannelCertificateIssuedBySubjectOf(CurrentCertificate,
           Candidate) and
           SChannelCertificateWasSignedBy(CurrentCertificate, Candidate) then
          raise ETransportSecurityError.Create(
            'Configured TLS PKCS#12 certificate chain contains a certificate cycle');
      end;
    end;
  finally
    if Assigned(Enumerated) then
      CertFreeCertificateContext(Enumerated);
    for I := 0 to High(Chain) do
      if Assigned(Chain[I]) then
        CertFreeCertificateContext(Chain[I]);
    SetLength(Chain, 0);
  end;
end;

{ The container name the key-storage provider assigned to this import. Read
  back rather than chosen: PFXImportCertStore names the CNG key itself, and
  the name is the identity of the persisted container this snapshot owns and
  will delete. Empty when the property is unreadable. }
function SChannelServerKeyContainerName(
  const ACertificate: PCertContext): UnicodeString;
var
  Buffer: TBytes;
  BufferLength: LongWord;
  ProviderInfo: PCryptKeyProviderInfo;
begin
  Result := '';
  BufferLength := 0;
  if not CertGetCertificateContextProperty(ACertificate,
    CERT_KEY_PROV_INFO_PROP_ID, nil, BufferLength) then
    Exit;
  if BufferLength < LongWord(SizeOf(TCryptKeyProviderInfo)) then
    Exit;
  SetLength(Buffer, BufferLength);
  if not CertGetCertificateContextProperty(ACertificate,
    CERT_KEY_PROV_INFO_PROP_ID, @Buffer[0], BufferLength) then
    Exit;
  ProviderInfo := PCryptKeyProviderInfo(@Buffer[0]);
  if Assigned(ProviderInfo^.pwszContainerName) then
    Result := UnicodeString(WideString(ProviderInfo^.pwszContainerName));
end;

{ Make the bundled issuers discoverable to the operating system's chain
  builder.

  SChannel assembles the outgoing Certificate flight itself, and it builds that
  chain from the Windows certificate stores rather than from the caller's
  in-memory store — the handshake runs outside the calling process, so a store
  that only exists in this process is invisible to it. A PKCS#12 bundle
  carrying an intermediate therefore yields a leaf-only flight unless the
  intermediate is published where the OS looks. .NET hits the same wall and
  solves it the same way: SslStreamCertificateContext adds the caller's
  intermediates to the Intermediate Certification Authorities store.

  Two deliberate differences from .NET: the current user's store is used rather
  than the machine's, so no administrative rights are needed and nothing is
  published machine-wide; and every context added here is recorded and removed
  again when the snapshot is released, where .NET leaves them behind. Only
  certificates this snapshot actually added are recorded, so an issuer the user
  had already installed is never withdrawn. Publication is best effort: a store
  that cannot be opened or written degrades to a leaf-only flight, which is
  exactly the behaviour before this existed, rather than failing the identity. }
procedure PublishSChannelServerIssuers(
  const ASnapshot: TSChannelServerCredentialData);
var
  Enumerated: PCertContext;
  PublishedCount: Integer;
begin
  ASnapshot.IssuerStore := CertOpenSystemStoreW(0,
    PWideChar(UnicodeString(INTERMEDIATE_AUTHORITY_STORE)));
  if not Assigned(ASnapshot.IssuerStore) then
    Exit;
  Enumerated := CertEnumCertificatesInStore(ASnapshot.Store, nil);
  try
    while Assigned(Enumerated) do
    begin
      if not SChannelSameCertificate(Enumerated, ASnapshot.Certificate) then
      begin
        { Grow before mutating the persistent store so every successfully
          added entry immediately has an owner, even if a later allocation
          fails. ADD_ALWAYS gives each concurrently live snapshot its own
          exact entry; deleting an older snapshot's returned context can then
          never withdraw the issuer from a newer one or from the user. }
        PublishedCount := Length(ASnapshot.PublishedIssuers);
        SetLength(ASnapshot.PublishedIssuers,
          PublishedCount + 1);
        ASnapshot.PublishedIssuers[PublishedCount] := nil;
        if not CertAddCertificateContextToStore(ASnapshot.IssuerStore,
          Enumerated, CERT_STORE_ADD_ALWAYS,
          @ASnapshot.PublishedIssuers[PublishedCount]) or
          not Assigned(ASnapshot.PublishedIssuers[PublishedCount]) then
          SetLength(ASnapshot.PublishedIssuers, PublishedCount);
      end;
      Enumerated := CertEnumCertificatesInStore(ASnapshot.Store, Enumerated);
    end;
  finally
    if Assigned(Enumerated) then
      CertFreeCertificateContext(Enumerated);
  end;
end;

function CreateSChannelServerSnapshot(const APkcs12Identity: TBytes;
  const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation):
  TSChannelServerCredentialData;
var
  AuthenticationData: Pointer;
  CallerOwnsKey: LongBool;
  Expiry: SECURITY_INTEGER;
  Identity: TBytes;
  IdentityBlob: TCryptDataBlob;
  KeyHandle: PtrUInt;
  KeySpecification: LongWord;
  LegacyCredentials: TSchannelCred;
  ModernCredentials: TSchCredentials;
  Passphrase: array of WideChar;
  Snapshot: TSChannelServerCredentialData;
  Status: SECURITY_STATUS;
  TlsParameters: TTlsParameters;
begin
  Result := nil;
  if Length(APkcs12Identity) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity is empty');
  if Length(APkcs12Identity) > MAX_PKCS12_IDENTITY_SIZE then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
  if Pos(#0, APkcs12Passphrase) > 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 passphrase contains an embedded NUL');

  SetLength(Identity, Length(APkcs12Identity));
  Move(APkcs12Identity[0], Identity[0], Length(Identity));
  SetLength(Passphrase, Length(APkcs12Passphrase) + 1);
  Snapshot := nil;
  try
    if Length(APkcs12Passphrase) > 0 then
      Move(APkcs12Passphrase[1], Passphrase[0],
        Length(APkcs12Passphrase) * SizeOf(WideChar));
    Passphrase[High(Passphrase)] := WideChar(0);

    Snapshot := TSChannelServerCredentialData.Create;
    IdentityBlob.cbData := Length(Identity);
    IdentityBlob.pbData := @Identity[0];
    { The key must be persisted in a key-storage provider. SChannel performs
      server key operations in lsass, which cannot reach an in-process
      ephemeral key: importing with PKCS12_NO_PERSIST_KEY makes
      AcquireCredentialsHandle fail with SEC_E_NO_CREDENTIALS. The snapshot
      therefore owns a persisted CNG container and deletes it in Release.

      PKCS12_ALLOW_OVERWRITE_KEY is deliberately NOT passed. PFXImportCertStore
      names CNG keys itself, so ordinary bundles get a fresh container per
      import and concurrent snapshots of the same identity stay independent
      (pinned by the isolated-key-container test). Should a bundle ever carry a
      container name that already exists, omitting the flag makes the import
      fail loudly instead of silently overwriting a key another live snapshot
      is still serving with. }
    Snapshot.Store := PFXImportCertStore(@IdentityBlob, @Passphrase[0],
      PKCS12_ALWAYS_CNG_KSP or CRYPT_USER_KEYSET);
    if not Assigned(Snapshot.Store) then
      raise ETransportSecurityError.Create(
        SCHANNEL_SERVER_IDENTITY_PARSE_ERROR);
    Snapshot.Certificate := CertFindCertificateInStore(Snapshot.Store,
      CERT_ENCODING_TYPES, 0, CERT_FIND_HAS_PRIVATE_KEY, nil, nil);
    if not Assigned(Snapshot.Certificate) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain a certificate and private key');

    { Claim the key handle before anything can fail: from here on every exit —
      including strict-validation rejection and credential-acquisition failure
      — runs Release, which deletes the container. }
    KeyHandle := 0;
    KeySpecification := 0;
    CallerOwnsKey := False;
    if not CryptAcquireCertificatePrivateKey(Snapshot.Certificate,
      CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG or CRYPT_ACQUIRE_SILENT_FLAG, nil,
      KeyHandle, KeySpecification, CallerOwnsKey) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain a certificate and private key');
    { Record before rejecting: an owned handle must reach Release even on the
      rejection path, or its container would outlive the failed snapshot. A
      handle we do not own is not ours to free, so there is nothing to record. }
    if CallerOwnsKey then
    begin
      Snapshot.PrivateKey := KeyHandle;
      Snapshot.HasPrivateKey := True;
    end;
    if not Snapshot.HasPrivateKey or
       (KeySpecification <> CERT_NCRYPT_KEY_SPEC) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity did not import into an owned CNG key');
    Snapshot.KeyContainerName :=
      SChannelServerKeyContainerName(Snapshot.Certificate);

    if AValidation = tsivStrict then
      ValidateSChannelServerIdentity(Snapshot.Store, Snapshot.Certificate);

    PublishSChannelServerIssuers(Snapshot);

    AuthenticationData := nil;
    FillChar(LegacyCredentials, SizeOf(LegacyCredentials), 0);
    FillChar(ModernCredentials, SizeOf(ModernCredentials), 0);
    FillChar(TlsParameters, SizeOf(TlsParameters), 0);
    if SChannelSupportsTlsParameters then
    begin
      { SCH_CREDENTIALS v5 leaves the protocol ceiling to the operating
        system. Disable every protocol below TLS 1.2 explicitly so Windows 11
        and Server 2022 can negotiate TLS 1.3 without weakening the public
        floor. TLS_PARAMETERS first shipped in Windows 10 version 1809; the
        manifest-independent RtlGetVersion gate above prevents passing this
        structure to older supported hosts. }
      TlsParameters.grbitDisabledProtocols := SP_PROT_SSL2_SERVER or
        SP_PROT_SSL3_SERVER or SP_PROT_TLS1_0_SERVER or
        SP_PROT_TLS1_1_SERVER;
      ModernCredentials.dwVersion := SCH_CREDENTIALS_VERSION;
      ModernCredentials.cCreds := 1;
      ModernCredentials.paCred := @Snapshot.Certificate;
      ModernCredentials.dwFlags := SCH_USE_STRONG_CRYPTO or
        SCH_CRED_NO_SYSTEM_MAPPER;
      ModernCredentials.cTlsParameters := 1;
      ModernCredentials.pTlsParameters := @TlsParameters;
      AuthenticationData := @ModernCredentials;
    end
    else
    begin
      { SCHANNEL_CRED v4 is the Windows 8-compatible fallback. It cannot
        enable TLS 1.3, which those hosts do not provide, so pin TLS 1.2. }
      LegacyCredentials.dwVersion := SCHANNEL_CRED_VERSION;
      LegacyCredentials.cCreds := 1;
      LegacyCredentials.paCred := @Snapshot.Certificate;
      LegacyCredentials.grbitEnabledProtocols := SP_PROT_TLS1_2_SERVER;
      LegacyCredentials.dwFlags := SCH_USE_STRONG_CRYPTO or
        SCH_CRED_NO_SYSTEM_MAPPER;
      AuthenticationData := @LegacyCredentials;
    end;
    Status := AcquireCredentialsHandleW(nil,
      PWideChar(WideString(UNISP_NAME)), SECPKG_CRED_INBOUND, nil,
      AuthenticationData, nil, nil, @Snapshot.Credential, @Expiry);
    if Status <> SEC_E_OK then
      raise ETransportSecurityError.CreateFmt(
        'Failed to acquire SChannel server credentials: 0x%x',
        [LongWord(Status)]);
    Snapshot.HasCredential := True;
    Result := Snapshot;
    Snapshot := nil;
  finally
    if Assigned(Snapshot) then
      Snapshot.Release;
    if Length(Passphrase) > 0 then
      FillChar(Passphrase[0], Length(Passphrase) * SizeOf(WideChar), 0);
    SetLength(Passphrase, 0);
    WipeBytes(Identity);
  end;
end;

procedure FreeSChannelServerData(const AData: TSChannelServerData);
begin
  if not Assigned(AData) then
    Exit;
  if AData.HasContext then
  begin
    DeleteSecurityContext(@AData.Context);
    AData.HasContext := False;
  end;
  if Assigned(AData.Snapshot) then
    AData.Snapshot.Release;
  AData.Snapshot := nil;
  if Length(AData.PendingPlaintext) > 0 then
    FillChar(AData.PendingPlaintext[0], Length(AData.PendingPlaintext), 0);
  SetLength(AData.PendingPlaintext, 0);
  if Length(AData.Plaintext) > 0 then
    FillChar(AData.Plaintext[0], Length(AData.Plaintext), 0);
  SetLength(AData.Plaintext, 0);
  if Length(AData.RecordBuffer) > 0 then
    FillChar(AData.RecordBuffer[0], Length(AData.RecordBuffer), 0);
  SetLength(AData.RecordBuffer, 0);
  AData.Free;
end;

function SChannelServerData(
  const AConnection: TTransportSecurityConnection): TSChannelServerData;
  inline;
begin
  if (AConnection.Backend = TSB_SCHANNEL_SERVER) and
     Assigned(AConnection.BackendData) then
    Result := TSChannelServerData(AConnection.BackendData)
  else
    Result := nil;
end;

procedure PoisonSChannelServerConnection(
  var AConnection: TTransportSecurityConnection);
var
  Data: TSChannelServerData;
begin
  Data := TSChannelServerData(AConnection.BackendData);
  ResetTransportSecurityConnection(AConnection);
  FreeSChannelServerData(Data);
end;

function SChannelServerPendingCiphertext(
  const AData: TSChannelServerData): Integer; inline;
begin
  if Assigned(AData) then
    Result := Length(AData.Output) - AData.OutputOffset
  else
    Result := 0;
end;

function SChannelServerOutputFlow(
  const AData: TSChannelServerData): TTransportSecurityOutputFlow;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not Assigned(AData) then
    Exit;
  Result.Capacity := AData.OutputCapacity;
  Result.PendingBytes := SChannelServerPendingCiphertext(AData);
  Result.RemainingBytes := Result.Capacity - Result.PendingBytes;
  if Result.RemainingBytes < 0 then
    Result.RemainingBytes := 0;
end;

{ Only ever reached with the queue fully drained, because every entry point
  returns tssWantWrite while output is pending. Compacting here therefore
  cannot move bytes a caller still holds a GetCiphertext pointer to. }
procedure CompactSChannelServerOutput(const AData: TSChannelServerData);
var
  PendingLength: Integer;
begin
  if AData.OutputOffset <= 0 then
    Exit;
  PendingLength := Length(AData.Output) - AData.OutputOffset;
  if PendingLength > 0 then
    Move(AData.Output[AData.OutputOffset], AData.Output[0], PendingLength);
  SetLength(AData.Output, PendingLength);
  AData.OutputOffset := 0;
end;

function AppendSChannelServerOutput(const AData: TSChannelServerData;
  const ABuffer: Pointer; const ALength: Integer): Boolean;
var
  ExistingLength: Integer;
begin
  Result := True;
  if ALength <= 0 then
    Exit;
  CompactSChannelServerOutput(AData);
  ExistingLength := Length(AData.Output);
  if ExistingLength + ALength > AData.OutputCapacity then
  begin
    Result := False;
    Exit;
  end;
  SetLength(AData.Output, ExistingLength + ALength);
  Move(ABuffer^, AData.Output[ExistingLength], ALength);
end;

function FlushSChannelServerRecord(const AData: TSChannelServerData): Boolean;
var
  Remaining: Integer;
  Take: Integer;
begin
  Result := True;
  while AData.RecordOffset < Length(AData.RecordBuffer) do
  begin
    Remaining := AData.OutputCapacity -
      SChannelServerPendingCiphertext(AData);
    if Remaining <= 0 then
    begin
      Result := False;
      Exit;
    end;
    Take := Length(AData.RecordBuffer) - AData.RecordOffset;
    if Take > Remaining then
      Take := Remaining;
    if not AppendSChannelServerOutput(AData,
      @AData.RecordBuffer[AData.RecordOffset], Take) then
    begin
      Result := False;
      Exit;
    end;
    Inc(AData.RecordOffset, Take);
  end;
  SetLength(AData.RecordBuffer, 0);
  AData.RecordOffset := 0;
end;

function SChannelServerStagedBytes(
  const AData: TSChannelServerData): Integer; inline;
begin
  Result := Length(AData.RecordBuffer) - AData.RecordOffset;
end;

{ Queue a freshly produced SSPI token through the same prefix-staging path
  application records use. A handshake flight larger than OutputCapacity
  therefore drains incrementally instead of failing the connection, which is
  what OpenSSL's bounded write BIO does. }
function StageSChannelServerToken(const AData: TSChannelServerData;
  const ABuffer: Pointer; const ALength: Integer): Boolean;
begin
  Result := True;
  if ALength <= 0 then
    Exit;
  if SChannelServerStagedBytes(AData) > 0 then
  begin
    { A staged record must drain before another can be staged; reaching this
      would mean an entry-point guard let a caller past pending output. }
    Result := False;
    Exit;
  end;
  if not Assigned(ABuffer) then
  begin
    Result := False;
    Exit;
  end;
  SetLength(AData.RecordBuffer, ALength);
  AData.RecordOffset := 0;
  Move(ABuffer^, AData.RecordBuffer[0], ALength);
  FlushSChannelServerRecord(AData);
end;

{ True when the caller must drain retained ciphertext before anything else can
  make progress. Also advances a partially queued staged record, so a token
  that did not fit in one go keeps moving. }
function SChannelServerOutputBusy(
  const AData: TSChannelServerData): Boolean;
begin
  Result := SChannelServerPendingCiphertext(AData) > 0;
  if Result then
    Exit;
  if SChannelServerStagedBytes(AData) <= 0 then
    Exit;
  FlushSChannelServerRecord(AData);
  Result := SChannelServerPendingCiphertext(AData) > 0;
end;

procedure RefreshSChannelServerInputFlow(const AData: TSChannelServerData);
var
  Buffered: Integer;
begin
  if not Assigned(AData) then
    Exit;
  Buffered := Length(AData.EncryptedInput);
  if Buffered > AData.InputHighWatermark then
    Buffered := AData.InputHighWatermark;
  AData.InputBuffered := Buffered;
  AData.InputConsumed := AData.InputAccepted - QWord(AData.InputBuffered);
  if AData.InputBackpressured then
    AData.InputBackpressured := AData.InputBuffered > AData.InputLowWatermark
  else
    AData.InputBackpressured := AData.InputBuffered >=
      AData.InputHighWatermark;
end;

function SChannelServerRequestFlags: LongWord;
begin
  Result := ASC_REQ_SEQUENCE_DETECT or ASC_REQ_REPLAY_DETECT or
    ASC_REQ_CONFIDENTIALITY or ASC_REQ_EXTENDED_ERROR or
    ASC_REQ_ALLOCATE_MEMORY or ASC_REQ_STREAM;
end;

procedure BeginSChannelServer(var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
var
  Data: TSChannelServerData;
  Snapshot: TSChannelServerCredentialData;
begin
  Snapshot := TSChannelServerCredentialData(AContext.AcquireSnapshot);
  if not Assigned(Snapshot) or not Snapshot.HasCredential then
  begin
    if Assigned(Snapshot) then
      Snapshot.Release;
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  end;
  try
    Data := TSChannelServerData.Create;
  except
    Snapshot.Release;
    raise;
  end;
  Data.Snapshot := Snapshot;
  Data.InputHighWatermark := AContext.FInputHighWatermark;
  Data.InputLowWatermark := AContext.FInputLowWatermark;
  Data.OutputCapacity := AContext.FOutputCapacity;
  AConnection.BackendData := Data;
  AConnection.Backend := TSB_SCHANNEL_SERVER;
end;

function FeedSChannelServerCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
var
  AcceptedLength: Integer;
  Available: Integer;
  Data: TSChannelServerData;
  ExistingLength: Integer;
begin
  Data := SChannelServerData(AConnection);
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

  RefreshSChannelServerInputFlow(Data);
  Available := Data.InputHighWatermark - Data.InputBuffered;
  AcceptedLength := ALength;
  if AcceptedLength > Available then
    AcceptedLength := Available;
  if AcceptedLength <= 0 then
  begin
    Data.InputBackpressured := True;
    Result := 0;
    Exit;
  end;

  ExistingLength := Length(Data.EncryptedInput);
  SetLength(Data.EncryptedInput, ExistingLength + AcceptedLength);
  Move(ABuffer^, Data.EncryptedInput[ExistingLength], AcceptedLength);
  Inc(Data.InputAccepted, QWord(AcceptedLength));
  Result := AcceptedLength;
  RefreshSChannelServerInputFlow(Data);
end;

function HandshakeSChannelServer(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  ConnectionInfo: TSecPkgContextConnectionInfo;
  ContextAttributes: LongWord;
  Data: TSChannelServerData;
  ExistingContext: PCtxtHandle;
  Expiry: SECURITY_INTEGER;
  InputBuffers: array[0..1] of TSecBuffer;
  InputDescriptor: TSecBufferDesc;
  OutputBuffer: TSecBuffer;
  OutputDescriptor: TSecBufferDesc;
  Status: SECURITY_STATUS;
  TokenQueued: Boolean;
begin
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) then
  begin
    Result := tssError;
    Exit;
  end;
  { Checked before HandshakeDone: the final flight may still be staged, and
    reporting tssDone with undelivered bytes would lose them. }
  if SChannelServerOutputBusy(Data) then
  begin
    Result := tssWantWrite;
    Exit;
  end;
  if Data.HandshakeDone then
  begin
    Data.PostHandshakeInProgress := False;
    Result := tssDone;
    Exit;
  end;

  repeat
    if Length(Data.EncryptedInput) = 0 then
    begin
      Result := tssWantRead;
      Exit;
    end;

    FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
    OutputBuffer.BufferType := SECBUFFER_TOKEN;
    FillChar(OutputDescriptor, SizeOf(OutputDescriptor), 0);
    OutputDescriptor.ulVersion := SECBUFFER_VERSION;
    OutputDescriptor.cBuffers := 1;
    OutputDescriptor.pBuffers := @OutputBuffer;

    FillChar(InputBuffers, SizeOf(InputBuffers), 0);
    InputBuffers[0].BufferType := SECBUFFER_TOKEN;
    InputBuffers[0].cbBuffer := Length(Data.EncryptedInput);
    InputBuffers[0].pvBuffer := @Data.EncryptedInput[0];
    InputBuffers[1].BufferType := SECBUFFER_EMPTY;
    FillChar(InputDescriptor, SizeOf(InputDescriptor), 0);
    InputDescriptor.ulVersion := SECBUFFER_VERSION;
    InputDescriptor.cBuffers := 2;
    InputDescriptor.pBuffers := @InputBuffers[0];

    if Data.HasContext then
      ExistingContext := @Data.Context
    else
      ExistingContext := nil;

    Status := AcceptSecurityContext(@Data.Snapshot.Credential,
      ExistingContext, @InputDescriptor, SChannelServerRequestFlags,
      SECURITY_NATIVE_DREP, @Data.Context, @OutputDescriptor,
      @ContextAttributes, @Expiry);
    if Status >= 0 then
      Data.HasContext := True;

    TokenQueued := True;
    try
      if Status = SEC_E_INCOMPLETE_MESSAGE then
      begin
        Result := tssWantRead;
        Exit;
      end;

      if SecBufferKind(InputBuffers[1].BufferType) = SECBUFFER_EXTRA then
        PreserveExtraBytes(Data.EncryptedInput, InputBuffers[1].pvBuffer,
          InputBuffers[1].cbBuffer)
      else
        SetLength(Data.EncryptedInput, 0);

      if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) then
        TokenQueued := StageSChannelServerToken(Data, OutputBuffer.pvBuffer,
          OutputBuffer.cbBuffer);
    finally
      if Assigned(OutputBuffer.pvBuffer) then
        FreeContextBuffer(OutputBuffer.pvBuffer);
    end;
    if not TokenQueued then
    begin
      PoisonSChannelServerConnection(AConnection);
      Result := tssError;
      Exit;
    end;

    if Status = SEC_E_OK then
    begin
      Status := QueryContextAttributesW(@Data.Context,
        SECPKG_ATTR_STREAM_SIZES, @Data.StreamSizes);
      if Status <> SEC_E_OK then
      begin
        PoisonSChannelServerConnection(AConnection);
        Result := tssError;
        Exit;
      end;
      FillChar(ConnectionInfo, SizeOf(ConnectionInfo), 0);
      Status := QueryContextAttributesW(@Data.Context,
        SECPKG_ATTR_CONNECTION_INFO, @ConnectionInfo);
      if Status <> SEC_E_OK then
      begin
        PoisonSChannelServerConnection(AConnection);
        Result := tssError;
        Exit;
      end;
      Data.Protocol := ConnectionInfo.dwProtocol;
      Data.HandshakeDone := True;
      AConnection.Active := True;
      if (SChannelServerPendingCiphertext(Data) > 0) or
         (SChannelServerStagedBytes(Data) > 0) then
        Result := tssWantWrite
      else
        Result := tssDone;
      Exit;
    end;

    if Status <> SEC_I_CONTINUE_NEEDED then
    begin
      PoisonSChannelServerConnection(AConnection);
      Result := tssError;
      Exit;
    end;

    if (SChannelServerPendingCiphertext(Data) > 0) or
       (SChannelServerStagedBytes(Data) > 0) then
    begin
      Result := tssWantWrite;
      Exit;
    end;
  until False;
end;

function ReadSChannelServer(var AConnection: TTransportSecurityConnection;
  var ABuffer: array of Byte;
  const ALength: Integer): TTransportSecurityIOResult;
var
  Available: Integer;
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  Data: TSChannelServerData;
  ExtraInput: TBytes;
  HandshakeState: TTransportSecurityState;
  I: Integer;
  QualityOfProtection: LongWord;
  ReadLength: Integer;
  Status: SECURITY_STATUS;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) then
    Exit;
  if Data.PostHandshakeInProgress then
  begin
    HandshakeState := HandshakeSChannelServer(AConnection);
    if HandshakeState <> tssDone then
    begin
      Result.State := HandshakeState;
      Exit;
    end;
  end;
  if not Data.HandshakeDone then
    Exit;
  if Length(Data.PendingPlaintext) > 0 then
    raise ETransportSecurityError.Create(
      'TLS write retry is pending; resume it before reading');
  if SChannelServerOutputBusy(Data) then
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

  repeat
    Available := Length(Data.Plaintext) - Data.PlaintextOffset;
    if Available > 0 then
    begin
      Result.BytesProcessed := Available;
      if Result.BytesProcessed > ReadLength then
        Result.BytesProcessed := ReadLength;
      Move(Data.Plaintext[Data.PlaintextOffset], ABuffer[0],
        Result.BytesProcessed);
      Inc(Data.PlaintextOffset, Result.BytesProcessed);
      if Data.PlaintextOffset >= Length(Data.Plaintext) then
      begin
        SetLength(Data.Plaintext, 0);
        Data.PlaintextOffset := 0;
      end;
      Result.State := tssDone;
      Exit;
    end;

    if Data.PeerClosed then
    begin
      PoisonSChannelServerConnection(AConnection);
      Result.State := tssPeerClosed;
      Exit;
    end;
    if Length(Data.EncryptedInput) = 0 then
    begin
      Result.State := tssWantRead;
      Exit;
    end;

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_DATA;
    Buffers[0].cbBuffer := Length(Data.EncryptedInput);
    Buffers[0].pvBuffer := @Data.EncryptedInput[0];
    Buffers[1].BufferType := SECBUFFER_EMPTY;
    Buffers[2].BufferType := SECBUFFER_EMPTY;
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    FillChar(BufferDescriptor, SizeOf(BufferDescriptor), 0);
    BufferDescriptor.ulVersion := SECBUFFER_VERSION;
    BufferDescriptor.cBuffers := 4;
    BufferDescriptor.pBuffers := @Buffers[0];
    QualityOfProtection := 0;

    Status := DecryptMessage(@Data.Context, @BufferDescriptor, 0,
      @QualityOfProtection);
    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      Result.State := tssWantRead;
      Exit;
    end;
    { SECBUFFER_EXTRA points into EncryptedInput; some SChannel builds report
      only cbBuffer, so preserve the input tail before replacing the array
      that owns those bytes. }
    SetLength(ExtraInput, 0);
    for I := 1 to High(Buffers) do
      if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
        AppendExtraBytes(ExtraInput, Data.EncryptedInput,
          Buffers[I].pvBuffer, Buffers[I].cbBuffer);
    Data.EncryptedInput := ExtraInput;

    if Status = SEC_I_RENEGOTIATE then
    begin
      { TLS 1.3 uses this status for post-handshake KeyUpdate and session
        tickets; its extra bytes must re-enter AcceptSecurityContext. TLS 1.2
        renegotiation remains fatal, preserving the no-renegotiation contract
        shared with the OpenSSL backend. }
      if Data.Protocol <> SP_PROT_TLS1_3_SERVER then
      begin
        PoisonSChannelServerConnection(AConnection);
        Result.State := tssError;
        Exit;
      end;
      Data.HandshakeDone := False;
      Data.PostHandshakeInProgress := True;
      HandshakeState := HandshakeSChannelServer(AConnection);
      if HandshakeState <> tssDone then
      begin
        Result.State := HandshakeState;
        Exit;
      end;
      Continue;
    end;
    if (Status <> SEC_E_OK) and (Status <> SEC_I_CONTEXT_EXPIRED) then
    begin
      PoisonSChannelServerConnection(AConnection);
      Result.State := tssError;
      Exit;
    end;

    SetLength(Data.Plaintext, 0);
    Data.PlaintextOffset := 0;
    { Harvest from index 1. DecryptMessage relabels the descriptor in place
      on success — [0] becomes SECBUFFER_STREAM_HEADER, [1] the plaintext —
      but on SEC_I_CONTEXT_EXPIRED it returns without touching the buffers,
      so [0] still carries the caller-supplied SECBUFFER_DATA label over the
      whole ciphertext. Scanning from 0 therefore turns a peer close_notify
      into a payload of raw ciphertext. }
    if Status = SEC_E_OK then
      for I := 1 to High(Buffers) do
        if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_DATA then
          AppendBytes(Data.Plaintext, Buffers[I].pvBuffer,
            Buffers[I].cbBuffer);

    if Status = SEC_I_CONTEXT_EXPIRED then
      Data.PeerClosed := True;
  until False;
end;

function WriteSChannelServer(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
var
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  ChunkLength: Integer;
  Data: TSChannelServerData;
  EncryptedOffset: Integer;
  EncryptedRecord: TBytes;
  I: Integer;
  MessageLength: Integer;
  PendingLength: Integer;
  Retrying: Boolean;
  Status: SECURITY_STATUS;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit;
  if SChannelServerPendingCiphertext(Data) > 0 then
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
    Data.PendingPlaintextOffset := 0;
  end;

  PendingLength := Length(Data.PendingPlaintext);
  while FlushSChannelServerRecord(Data) and
    (Data.PendingPlaintextOffset < PendingLength) do
  begin
    ChunkLength := PendingLength - Data.PendingPlaintextOffset;
    if ChunkLength > Integer(Data.StreamSizes.cbMaximumMessage) then
      ChunkLength := Integer(Data.StreamSizes.cbMaximumMessage);
    MessageLength := Integer(Data.StreamSizes.cbHeader) + ChunkLength +
      Integer(Data.StreamSizes.cbTrailer);
    SetLength(Data.RecordBuffer, MessageLength);
    Data.RecordOffset := 0;
    Move(Data.PendingPlaintext[Data.PendingPlaintextOffset],
      Data.RecordBuffer[Data.StreamSizes.cbHeader], ChunkLength);

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_STREAM_HEADER;
    Buffers[0].cbBuffer := Data.StreamSizes.cbHeader;
    Buffers[0].pvBuffer := @Data.RecordBuffer[0];
    Buffers[1].BufferType := SECBUFFER_DATA;
    Buffers[1].cbBuffer := ChunkLength;
    Buffers[1].pvBuffer := @Data.RecordBuffer[Data.StreamSizes.cbHeader];
    Buffers[2].BufferType := SECBUFFER_STREAM_TRAILER;
    Buffers[2].cbBuffer := Data.StreamSizes.cbTrailer;
    Buffers[2].pvBuffer :=
      @Data.RecordBuffer[Integer(Data.StreamSizes.cbHeader) + ChunkLength];
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    FillChar(BufferDescriptor, SizeOf(BufferDescriptor), 0);
    BufferDescriptor.ulVersion := SECBUFFER_VERSION;
    BufferDescriptor.cBuffers := 4;
    BufferDescriptor.pBuffers := @Buffers[0];

    Status := EncryptMessage(@Data.Context, 0, @BufferDescriptor, 0);
    if Status <> SEC_E_OK then
    begin
      SetLength(Data.RecordBuffer, 0);
      Data.RecordOffset := 0;
      PoisonSChannelServerConnection(AConnection);
      Result.State := tssError;
      Exit;
    end;
    MessageLength := Integer(Buffers[0].cbBuffer) +
      Integer(Buffers[1].cbBuffer) + Integer(Buffers[2].cbBuffer);
    SetLength(EncryptedRecord, MessageLength);
    EncryptedOffset := 0;
    for I := 0 to 2 do
      if Buffers[I].cbBuffer > 0 then
      begin
        Move(Buffers[I].pvBuffer^, EncryptedRecord[EncryptedOffset],
          Buffers[I].cbBuffer);
        Inc(EncryptedOffset, Buffers[I].cbBuffer);
      end;
    Data.RecordBuffer := EncryptedRecord;
    Inc(Data.PendingPlaintextOffset, ChunkLength);
  end;

  if (Data.PendingPlaintextOffset >= PendingLength) and
     (Data.RecordOffset >= Length(Data.RecordBuffer)) then
  begin
    SetLength(Data.RecordBuffer, 0);
    Data.RecordOffset := 0;
    Result.BytesProcessed := PendingLength;
    FillChar(Data.PendingPlaintext[0], PendingLength, 0);
    SetLength(Data.PendingPlaintext, 0);
    Data.PendingPlaintextOffset := 0;
    if SChannelServerPendingCiphertext(Data) > 0 then
      Result.State := tssWantWrite
    else
      Result.State := tssDone;
    Exit;
  end;

  if SChannelServerPendingCiphertext(Data) <= 0 then
  begin
    { No progress and nothing to drain would wedge the caller's pump. }
    PoisonSChannelServerConnection(AConnection);
    Result.State := tssError;
    Exit;
  end;
  Result.BytesProcessed := 0;
  Result.State := tssWantWrite;
end;

function StartSChannelServerShutdown(
  var AConnection: TTransportSecurityConnection;
  const AData: TSChannelServerData): Boolean;
var
  ContextAttributes: LongWord;
  Expiry: SECURITY_INTEGER;
  OutputBuffer: TSecBuffer;
  OutputDescriptor: TSecBufferDesc;
  ShutdownBuffer: TSecBuffer;
  ShutdownDescriptor: TSecBufferDesc;
  ShutdownToken: LongWord;
  Status: SECURITY_STATUS;
  TokenQueued: Boolean;
begin
  Result := False;
  ShutdownToken := SCHANNEL_SHUTDOWN;
  FillChar(ShutdownBuffer, SizeOf(ShutdownBuffer), 0);
  ShutdownBuffer.cbBuffer := SizeOf(ShutdownToken);
  ShutdownBuffer.BufferType := SECBUFFER_TOKEN;
  ShutdownBuffer.pvBuffer := @ShutdownToken;
  FillChar(ShutdownDescriptor, SizeOf(ShutdownDescriptor), 0);
  ShutdownDescriptor.ulVersion := SECBUFFER_VERSION;
  ShutdownDescriptor.cBuffers := 1;
  ShutdownDescriptor.pBuffers := @ShutdownBuffer;
  if ApplyControlToken(@AData.Context, @ShutdownDescriptor) <> SEC_E_OK then
  begin
    PoisonSChannelServerConnection(AConnection);
    Exit;
  end;

  FillChar(OutputBuffer, SizeOf(OutputBuffer), 0);
  OutputBuffer.BufferType := SECBUFFER_TOKEN;
  FillChar(OutputDescriptor, SizeOf(OutputDescriptor), 0);
  OutputDescriptor.ulVersion := SECBUFFER_VERSION;
  OutputDescriptor.cBuffers := 1;
  OutputDescriptor.pBuffers := @OutputBuffer;

  Status := AcceptSecurityContext(@AData.Snapshot.Credential,
    @AData.Context, nil, SChannelServerRequestFlags, SECURITY_NATIVE_DREP,
    @AData.Context, @OutputDescriptor, @ContextAttributes, @Expiry);
  TokenQueued := True;
  try
    if (Status = SEC_E_OK) or (Status = SEC_I_CONTINUE_NEEDED) or
       (Status = SEC_I_CONTEXT_EXPIRED) then
      TokenQueued := StageSChannelServerToken(AData, OutputBuffer.pvBuffer,
        OutputBuffer.cbBuffer)
    else
      TokenQueued := False;
  finally
    if Assigned(OutputBuffer.pvBuffer) then
      FreeContextBuffer(OutputBuffer.pvBuffer);
  end;
  if not TokenQueued then
  begin
    PoisonSChannelServerConnection(AConnection);
    Exit;
  end;
  AData.ShutdownStarted := True;
  Result := True;
end;

function CloseSChannelServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  Data: TSChannelServerData;
  ExtraInput: TBytes;
  I: Integer;
  QualityOfProtection: LongWord;
  Status: SECURITY_STATUS;
begin
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) then
  begin
    Result := tssError;
    Exit;
  end;
  if SChannelServerOutputBusy(Data) then
  begin
    Result := tssWantWrite;
    Exit;
  end;
  if Length(Data.PendingPlaintext) > 0 then
  begin
    PoisonSChannelServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;
  if not Data.HandshakeDone then
  begin
    PoisonSChannelServerConnection(AConnection);
    Result := tssError;
    Exit;
  end;

  if not Data.ShutdownStarted then
  begin
    if not StartSChannelServerShutdown(AConnection, Data) then
    begin
      Result := tssError;
      Exit;
    end;
    if (SChannelServerPendingCiphertext(Data) > 0) or
       (SChannelServerStagedBytes(Data) > 0) then
    begin
      Result := tssWantWrite;
      Exit;
    end;
  end;

  repeat
    if Data.PeerClosed then
    begin
      Result := tssDone;
      Exit;
    end;
    if Length(Data.EncryptedInput) = 0 then
    begin
      Result := tssWantRead;
      Exit;
    end;

    FillChar(Buffers, SizeOf(Buffers), 0);
    Buffers[0].BufferType := SECBUFFER_DATA;
    Buffers[0].cbBuffer := Length(Data.EncryptedInput);
    Buffers[0].pvBuffer := @Data.EncryptedInput[0];
    Buffers[1].BufferType := SECBUFFER_EMPTY;
    Buffers[2].BufferType := SECBUFFER_EMPTY;
    Buffers[3].BufferType := SECBUFFER_EMPTY;
    FillChar(BufferDescriptor, SizeOf(BufferDescriptor), 0);
    BufferDescriptor.ulVersion := SECBUFFER_VERSION;
    BufferDescriptor.cBuffers := 4;
    BufferDescriptor.pBuffers := @Buffers[0];
    QualityOfProtection := 0;

    Status := DecryptMessage(@Data.Context, @BufferDescriptor, 0,
      @QualityOfProtection);
    if Status = SEC_E_INCOMPLETE_MESSAGE then
    begin
      Result := tssWantRead;
      Exit;
    end;
    if (Status <> SEC_E_OK) and (Status <> SEC_I_CONTEXT_EXPIRED) then
    begin
      { A fatal alert observed while draining must not surface more output;
        the legitimate close_notify was already emitted and drained. }
      PoisonSChannelServerConnection(AConnection);
      Result := tssError;
      Exit;
    end;

    { Index 1 upward for the same reason the read path does: on
      SEC_I_CONTEXT_EXPIRED buffer 0 still carries the caller's label. }
    SetLength(ExtraInput, 0);
    for I := 1 to High(Buffers) do
      if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
        AppendExtraBytes(ExtraInput, Data.EncryptedInput,
          Buffers[I].pvBuffer, Buffers[I].cbBuffer);
    Data.EncryptedInput := ExtraInput;

    if Status = SEC_I_CONTEXT_EXPIRED then
      Data.PeerClosed := True;
  until False;
end;
{$ENDIF}
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
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  { SChannel ships with the operating system: there is no runtime library to
    probe and no OpenSSL DLL to find. }
  Result := True;
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  Result := False;
  {$ENDIF}
end;

function TTransportSecurityServerContext.AcquireSnapshot: Pointer;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Snapshot: TOpenSSLServerContextData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Snapshot: TSChannelServerCredentialData;
{$ENDIF}
begin
  Result := nil;
  if not FCriticalSectionInitialized then
    Exit;
  EnterCriticalSection(FCriticalSection);
  try
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    Snapshot := TOpenSSLServerContextData(FBackendData);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
    Snapshot := TSChannelServerCredentialData(FBackendData);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_SERVER}
    if Assigned(Snapshot) then
    begin
      Snapshot.Retain;
      Result := Snapshot;
    end;
    {$ENDIF}
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TTransportSecurityServerContext.InitializeFlowControl(
  const AInputHighWatermark, AInputLowWatermark,
  AOutputCapacity: Integer);
begin
  if (AInputHighWatermark < TLS_SERVER_MIN_INPUT_CAPACITY) or
     (AInputHighWatermark > TLS_SERVER_MAX_INPUT_CAPACITY) then
    raise ETransportSecurityError.CreateFmt(
      'TLS server input capacity must be between %d and %d bytes',
      [TLS_SERVER_MIN_INPUT_CAPACITY, TLS_SERVER_MAX_INPUT_CAPACITY]);
  if (AInputLowWatermark < 0) or
     (AInputLowWatermark >= AInputHighWatermark) then
    raise ETransportSecurityError.Create(
      'TLS server input low watermark must be nonnegative and below capacity');
  if (AOutputCapacity < TLS_SERVER_MIN_OUTPUT_CAPACITY) or
     (AOutputCapacity > TLS_SERVER_MAX_OUTPUT_CAPACITY) then
    raise ETransportSecurityError.CreateFmt(
      'TLS server output capacity must be between %d and %d bytes',
      [TLS_SERVER_MIN_OUTPUT_CAPACITY, TLS_SERVER_MAX_OUTPUT_CAPACITY]);
  FInputHighWatermark := AInputHighWatermark;
  FInputLowWatermark := AInputLowWatermark;
  FOutputCapacity := AOutputCapacity;
end;

procedure TTransportSecurityServerContext.ReplaceSnapshot(
  const ANewSnapshot: Pointer);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  OldSnapshot: TOpenSSLServerContextData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  OldSnapshot: TSChannelServerCredentialData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  OldSnapshot := nil;
  if not FCriticalSectionInitialized then
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  EnterCriticalSection(FCriticalSection);
  try
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    OldSnapshot := TOpenSSLServerContextData(FBackendData);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
    OldSnapshot := TSChannelServerCredentialData(FBackendData);
    {$ENDIF}
    FBackendData := ANewSnapshot;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
  if Assigned(OldSnapshot) then
    OldSnapshot.Release;
  {$ELSE}
  FBackendData := ANewSnapshot;
  {$ENDIF}
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Identity: TBytes; const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_DEFAULT_INPUT_CAPACITY div 2,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Identity, APkcs12Passphrase, AValidation);
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Identity: TBytes; const APkcs12Passphrase: UnicodeString;
  const AInputHighWatermark, AOutputCapacity: Integer;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(AInputHighWatermark,
    AInputHighWatermark div 2, AOutputCapacity);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Identity, APkcs12Passphrase, AValidation);
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Identity: TBytes; const APkcs12Passphrase: UnicodeString;
  const AInputHighWatermark, AInputLowWatermark,
  AOutputCapacity: Integer;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(AInputHighWatermark, AInputLowWatermark,
    AOutputCapacity);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Identity, APkcs12Passphrase, AValidation);
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Path: string; const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(TLS_SERVER_DEFAULT_INPUT_CAPACITY,
    TLS_SERVER_DEFAULT_INPUT_CAPACITY div 2,
    TLS_SERVER_DEFAULT_OUTPUT_CAPACITY);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Path, APkcs12Passphrase, AValidation);
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Path: string; const APkcs12Passphrase: UnicodeString;
  const AInputHighWatermark, AOutputCapacity: Integer;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(AInputHighWatermark,
    AInputHighWatermark div 2, AOutputCapacity);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Path, APkcs12Passphrase, AValidation);
end;

constructor TTransportSecurityServerContext.Create(
  const APkcs12Path: string; const APkcs12Passphrase: UnicodeString;
  const AInputHighWatermark, AInputLowWatermark,
  AOutputCapacity: Integer;
  const AValidation: TTransportSecurityServerIdentityValidation);
begin
  inherited Create;
  FBackendData := nil;
  FCriticalSectionInitialized := False;
  InitializeFlowControl(AInputHighWatermark, AInputLowWatermark,
    AOutputCapacity);
  InitCriticalSection(FCriticalSection);
  FCriticalSectionInitialized := True;
  Reload(APkcs12Path, APkcs12Passphrase, AValidation);
end;

destructor TTransportSecurityServerContext.Destroy;
begin
  if FCriticalSectionInitialized then
  begin
    ReplaceSnapshot(nil);
    DoneCriticalSection(FCriticalSection);
    FCriticalSectionInitialized := False;
  end;
  FBackendData := nil;
  inherited Destroy;
end;

procedure TTransportSecurityServerContext.Reload(
  const APkcs12Identity: TBytes; const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Snapshot: TOpenSSLServerContextData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Snapshot: TSChannelServerCredentialData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  if not TryLoadOpenSSLServer then
    raise ETransportSecurityError.Create(OPENSSL_SERVER_LOAD_ERROR);
  LoadOpenSSLServerProcedures;
  Snapshot := CreateOpenSSLServerSnapshot(APkcs12Identity,
    APkcs12Passphrase, AValidation);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Snapshot := CreateSChannelServerSnapshot(APkcs12Identity,
    APkcs12Passphrase, AValidation);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  try
    ReplaceSnapshot(Snapshot);
    Snapshot := nil;
  finally
    if Assigned(Snapshot) then
      Snapshot.Release;
  end;
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

procedure TTransportSecurityServerContext.Reload(
  const APkcs12Path: string; const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation);
{$IFDEF TRANSPORT_SECURITY_SERVER}
var
  Identity: TBytes;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  Identity := LoadPKCS12Bytes(APkcs12Path);
  try
    Reload(Identity, APkcs12Passphrase, AValidation);
  finally
    WipeBytes(Identity);
  end;
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

procedure CloseTransportSecurityServerContext(
  var AContext: TTransportSecurityServerContext);
begin
  FreeAndNil(AContext);
end;

procedure StartTransportSecurityInternal(
  var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  FillChar(AConnection, SizeOf(AConnection), 0);
  AConnection.Socket := ASocket;
  AConnection.Backend := TSB_NONE;
  AConnection.Deadline := ADeadline;
  AConnection.TimeoutMilliseconds := ATimeoutMilliseconds;

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

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost, 0, 0);
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost, ADeadline,
    ATimeoutMilliseconds);
end;

procedure BeginTransportSecurityServer(
  var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
begin
  FillChar(AConnection, SizeOf(AConnection), 0);
  AConnection.Backend := TSB_NONE;

  {$IFDEF TRANSPORT_SECURITY_SERVER}
  if not Assigned(AContext) then
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  BeginOpenSSLServer(AConnection, AContext);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  BeginSChannelServer(AConnection, AContext);
  {$ENDIF}
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

function TransportSecurityServerHandshake(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := HandshakeOpenSSLServer(AConnection);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := HandshakeSChannelServer(AConnection);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  Result := tssError;
  {$ENDIF}
end;

function TransportSecurityFeedCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := FeedOpenSSLServerCiphertext(AConnection, ABuffer, ALength);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := FeedSChannelServerCiphertext(AConnection, ABuffer, ALength);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  Result := -1;
  {$ENDIF}
end;

function TransportSecurityServerInputFlow(
  var AConnection: TTransportSecurityConnection): TTransportSecurityInputFlow;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
begin
  FillChar(Result, SizeOf(Result), 0);
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) then
    Exit;
  RefreshOpenSSLServerInputFlow(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) then
    Exit;
  RefreshSChannelServerInputFlow(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SERVER}
  Result.AcceptedBytes := Data.InputAccepted;
  Result.Backpressured := Data.InputBackpressured;
  Result.BufferedBytes := Data.InputBuffered;
  Result.ConsumedBytes := Data.InputConsumed;
  Result.HighWatermark := Data.InputHighWatermark;
  Result.LowWatermark := Data.InputLowWatermark;
  {$ENDIF}
end;

function TransportSecurityServerOutputFlow(
  const AConnection: TTransportSecurityConnection): TTransportSecurityOutputFlow;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
begin
  FillChar(Result, SizeOf(Result), 0);
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Result := OpenSSLServerOutputFlow(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  Result := SChannelServerOutputFlow(Data);
  {$ENDIF}
end;

function TransportSecurityPendingCiphertext(
  const AConnection: TTransportSecurityConnection): Integer;
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Result := OpenSSLServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  Result := SChannelServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
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
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
begin
  ABuffer := nil;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Result := OpenSSLServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  Result := SChannelServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SERVER}
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
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
  Pending: Integer;
{$ENDIF}
begin
  if ALength <= 0 then
    Exit;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  Pending := OpenSSLServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  Pending := SChannelServerPendingCiphertext(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SERVER}
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
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := ReadSChannelServer(AConnection, ABuffer, ALength);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
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
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := WriteSChannelServer(AConnection, ABuffer, ALength);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  Result.State := tssError;
  Result.BytesProcessed := 0;
  {$ENDIF}
end;

function CloseTransportSecurityServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := CloseOpenSSLServerGracefully(AConnection);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := CloseSChannelServerGracefully(AConnection);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  Result := tssError;
  {$ENDIF}
end;

procedure AbortTransportSecurityServer(
  var AConnection: TTransportSecurityConnection);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
var
  Data: TOpenSSLServerData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
begin
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  ResetTransportSecurityConnection(AConnection);
  FreeOpenSSLServerData(Data);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  ResetTransportSecurityConnection(AConnection);
  FreeSChannelServerData(Data);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
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

{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$IFNDEF PRODUCTION}
{ Names the persisted CNG container backing the context's current snapshot.
  Exists so the suite can assert what this backend depends on and cannot
  otherwise observe: that concurrent imports of one identity own separate
  containers, so releasing a snapshot never deletes a key another snapshot is
  still serving with. }
function TransportSecurityTestServerKeyContainer(
  const AContext: TTransportSecurityServerContext): UnicodeString;
var
  Snapshot: TSChannelServerCredentialData;
begin
  Result := '';
  if not Assigned(AContext) then
    Exit;
  Snapshot := TSChannelServerCredentialData(AContext.AcquireSnapshot);
  if not Assigned(Snapshot) then
    Exit;
  try
    Result := Snapshot.KeyContainerName;
  finally
    Snapshot.Release;
  end;
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
    {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
    TSB_SCHANNEL_SERVER:
      FreeSChannelServerData(TSChannelServerData(AConnection.BackendData));
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
