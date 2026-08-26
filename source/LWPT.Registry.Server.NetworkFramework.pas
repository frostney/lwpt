{ LWPT.Registry.Server.NetworkFramework — native macOS TLS listener.

  FPC 3.2.2 does not expose the Objective-C blocks syntax used by Network.
  The small block literal below follows Apple's stable blocks ABI and captures
  only owner pointers whose lifetime is drained before listener destruction. }
unit LWPT.Registry.Server.NetworkFramework;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.Registry.Store;

procedure RunNetworkFrameworkRegistryServer(AStore: TLWPTRegistryStore;
  const APKCS12Path: string; var APassphrase: string; AStopFlag: PBoolean);
{$IFDEF REGISTRY_TESTING}
function NetworkFrameworkTeardownOrderingIsSafeForTesting: Boolean;
function NetworkFrameworkBlockABIIsCompleteForTesting: Boolean;
{$ENDIF}

implementation

{$IFDEF DARWIN}

uses
  BaseUnix,
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Filesystem,
  LWPT.Registry.Server;

{$linkframework Network}
{$linkframework Security}
{$linkframework CoreFoundation}

const
  MAX_PKCS12_BYTES = 16 * 1024 * 1024;
  MAX_REQUEST_BYTES = 32 * 1024;
  LISTENER_READY_TIMEOUT_SECONDS = 10;
  DRAIN_POLL_MILLISECONDS = 100;
  CONNECTION_DEADLINE_MILLISECONDS = 10000;
  MAX_ACTIVE_CONNECTIONS = 32;
  NANOSECONDS_PER_MILLISECOND = Int64(1000000);
  NANOSECONDS_PER_SECOND = Int64(1000000000);
  CF_STRING_ENCODING_UTF8 = $08000100;
  NW_LISTENER_STATE_READY = 2;
  NW_LISTENER_STATE_FAILED = 3;
  NW_LISTENER_STATE_CANCELLED = 4;
  NW_CONNECTION_STATE_READY = 3;
  NW_CONNECTION_STATE_FAILED = 4;
  NW_CONNECTION_STATE_CANCELLED = 5;
  { Network.framework consumes Objective-C blocks. Clang emits the signature
    flag plus the descriptor's signature/layout tail for every callback below;
    retaining that complete ABI is required even though the captured context
    itself is only an unretained owner pointer. }
  BLOCK_FLAG_HAS_SIGNATURE = Int32($40000000);
  BLOCK_SIGNATURE_CONFIGURE = 'v16@?0^{nw_protocol_options=}8';
  BLOCK_SIGNATURE_STATE = 'v20@?0i8^{nw_error=}12';
  BLOCK_SIGNATURE_RECEIVE =
    'v36@?0^{dispatch_data_s=}8^{nw_content_context=}16B24^{nw_error=}28';
  BLOCK_SIGNATURE_SEND = 'v16@?0^{nw_error=}8';
  BLOCK_SIGNATURE_NEW_CONNECTION = 'v16@?0^{nw_connection=}8';
  MAX_TEMPORARY_KEYCHAIN_RECOVERY_FILES = 128;
  TEMPORARY_KEYCHAIN_RANDOM_BYTES = 32;

type
  PBlockDescriptor = ^TBlockDescriptor;
  TBlockDescriptor = record
    Reserved: NativeUInt;
    Size: NativeUInt;
    Signature: PAnsiChar;
    Layout: PAnsiChar;
  end;

  PRegistryBlock = ^TRegistryBlock;
  TRegistryBlock = record
    Isa: Pointer;
    Flags: Int32;
    Reserved: Int32;
    Invoke: CodePointer;
    Descriptor: PBlockDescriptor;
    Context: Pointer;
  end;

  PNativeUInt = ^NativeUInt;
  TTemporaryKeychainRandom =
    array[0..TEMPORARY_KEYCHAIN_RANDOM_BYTES - 1] of Byte;
  TNetworkFrameworkRegistryServer = class;

  TNetworkFrameworkRegistryConnection = class
  private
    FServer: TNetworkFrameworkRegistryServer;
    FConnection: Pointer;
    FQueue: Pointer;
    FRequest: AnsiString;
    FClosing: Boolean;
    FResponding: Boolean;
    FDeadline: QWord;
    FResponseStream: TStream;
    FSendBuffer: TBytes;
    FSendData: Pointer;
    FStateBlock: TRegistryBlock;
    FReceiveBlock: TRegistryBlock;
    FSendBlock: TRegistryBlock;
    procedure ArmReceive;
    procedure Cancel;
    procedure CheckDeadline;
    procedure Consume(const ABuffer: Pointer; const ALength: NativeUInt);
    procedure SendCompleted(AError: Pointer);
    procedure SendCurrentBuffer;
    procedure SendNextResourceChunk;
    procedure SendResponse;
  public
    destructor Destroy; override;
  end;

  TNetworkFrameworkRegistryServer = class
  private
    FStore: TLWPTRegistryStore;
    FListener: Pointer;
    FParameters: Pointer;
    FListenerQueue: Pointer;
    FReadySemaphore: Pointer;
    FStopSemaphore: Pointer;
    FDrainSemaphore: Pointer;
    FListenerDoneSemaphore: Pointer;
    FTLSIdentity: Pointer;
    FTemporaryKeychain: Pointer;
    FTemporaryKeychainPath: string;
    FListenerState: Integer;
    FActiveConnections: LongInt;
    FConnections: TList;
    FConnectionLock: TRTLCriticalSection;
    FStopFlag: PBoolean;
    FStopping: Boolean;
    FListenerStateBlock: TRegistryBlock;
    FNewConnectionBlock: TRegistryBlock;
    FTLSBlock: TRegistryBlock;
    FTCPBlock: TRegistryBlock;
    procedure ConnectionFinished(
      AConnection: TNetworkFrameworkRegistryConnection);
    procedure DeleteTemporaryKeychainStorage;
    procedure LoadIdentity(const APath, APassphrase: string);
  public
    constructor Create(AStore: TLWPTRegistryStore;
      const APKCS12Path, APassphrase: string; AStopFlag: PBoolean);
    destructor Destroy; override;
    procedure Run;
  end;

function Dispatch_queue_create(ALabel: PAnsiChar; AAttributes: Pointer): Pointer;
  cdecl; external name 'dispatch_queue_create';
procedure Dispatch_release(AObject: Pointer); cdecl;
  external name 'dispatch_release';
function Dispatch_semaphore_create(AValue: NativeInt): Pointer; cdecl;
  external name 'dispatch_semaphore_create';
function Dispatch_semaphore_wait(ASemaphore: Pointer;
  ATimeout: UInt64): NativeInt; cdecl; external name 'dispatch_semaphore_wait';
function Dispatch_semaphore_signal(ASemaphore: Pointer): NativeInt; cdecl;
  external name 'dispatch_semaphore_signal';
function Dispatch_time(AWhen: UInt64; ADeltaNanoseconds: Int64): UInt64;
  cdecl; external name 'dispatch_time';
function Dispatch_data_create(ABuffer: Pointer; ASize: NativeUInt;
  AQueue, ADestructor: Pointer): Pointer; cdecl;
  external name 'dispatch_data_create';
function Block_has_signature(ABlock: Pointer): ByteBool; cdecl;
  external name '_Block_has_signature';

{$IFDEF REGISTRY_TESTING}
var
  RegistryCallbackTestReady: Pointer;
  RegistryCallbackTestRelease: Pointer;

procedure PauseRegistryCallbackForTesting;
begin
  if RegistryCallbackTestReady = nil then Exit;
  Dispatch_semaphore_signal(RegistryCallbackTestReady);
  Dispatch_semaphore_wait(RegistryCallbackTestRelease, High(UInt64));
end;
{$ENDIF}

procedure PublishListenerCancellation(ASemaphore: Pointer;
  var AState: LongInt);
begin
  Dispatch_semaphore_signal(ASemaphore);
  {$IFDEF REGISTRY_TESTING}
  PauseRegistryCallbackForTesting;
  {$ENDIF}
  InterLockedExchange(AState, NW_LISTENER_STATE_CANCELLED);
end;

procedure PublishConnectionCompletion(ASemaphore: Pointer;
  var AActiveConnections: LongInt);
begin
  Dispatch_semaphore_signal(ASemaphore);
  {$IFDEF REGISTRY_TESTING}
  PauseRegistryCallbackForTesting;
  {$ENDIF}
  InterLockedDecrement(AActiveConnections);
end;

{$IFDEF REGISTRY_TESTING}
type
  TRegistryCallbackKind = (rckListener, rckConnection);

  TRegistryCallbackTestThread = class(TThread)
  private
    FCallbackKind: TRegistryCallbackKind;
    FCallbackSemaphore: Pointer;
    FPublishedValue: PLongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACallbackKind: TRegistryCallbackKind;
      ACallbackSemaphore: Pointer; APublishedValue: PLongInt);
  end;

constructor TRegistryCallbackTestThread.Create(
  const ACallbackKind: TRegistryCallbackKind; ACallbackSemaphore: Pointer;
  APublishedValue: PLongInt);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCallbackKind := ACallbackKind;
  FCallbackSemaphore := ACallbackSemaphore;
  FPublishedValue := APublishedValue;
end;

procedure TRegistryCallbackTestThread.Execute;
begin
  if FCallbackKind = rckListener then
    PublishListenerCancellation(FCallbackSemaphore, FPublishedValue^)
  else PublishConnectionCompletion(FCallbackSemaphore, FPublishedValue^);
end;

function TestRegistryCallbackOrdering(
  const ACallbackKind: TRegistryCallbackKind): Boolean;
var
  CallbackSemaphore: Pointer;
  PublishedValue: LongInt;
  ReadySemaphore, ReleaseSemaphore: Pointer;
  Thread: TRegistryCallbackTestThread;
begin
  Result := False;
  ReadySemaphore := Dispatch_semaphore_create(0);
  ReleaseSemaphore := Dispatch_semaphore_create(0);
  RegistryCallbackTestReady := ReadySemaphore;
  RegistryCallbackTestRelease := ReleaseSemaphore;
  CallbackSemaphore := Dispatch_semaphore_create(0);
  if ACallbackKind = rckListener then PublishedValue := 0
  else PublishedValue := 1;
  Thread := TRegistryCallbackTestThread.Create(ACallbackKind,
    CallbackSemaphore, @PublishedValue);
  try
    Thread.Start;
    if Dispatch_semaphore_wait(RegistryCallbackTestReady,
      Dispatch_time(0, NANOSECONDS_PER_SECOND)) <> 0 then Exit;
    if ACallbackKind = rckListener then
      Result := InterLockedExchangeAdd(PublishedValue, 0)
        <> NW_LISTENER_STATE_CANCELLED
    else Result := InterLockedExchangeAdd(PublishedValue, 0) <> 0;
    Dispatch_semaphore_signal(RegistryCallbackTestRelease);
    Thread.WaitFor;
    if ACallbackKind = rckListener then
      Result := Result and (InterLockedExchangeAdd(PublishedValue, 0)
        = NW_LISTENER_STATE_CANCELLED)
    else Result := Result and (InterLockedExchangeAdd(PublishedValue, 0) = 0);
  finally
    Dispatch_semaphore_signal(RegistryCallbackTestRelease);
    Thread.WaitFor;
    Thread.Free;
    RegistryCallbackTestReady := nil;
    RegistryCallbackTestRelease := nil;
    Dispatch_release(CallbackSemaphore);
    Dispatch_release(ReleaseSemaphore);
    Dispatch_release(ReadySemaphore);
  end;
end;

function NetworkFrameworkTeardownOrderingIsSafeForTesting: Boolean;
begin
  Result := TestRegistryCallbackOrdering(rckListener)
    and TestRegistryCallbackOrdering(rckConnection);
end;
{$ENDIF}
function Dispatch_data_create_map(AData: Pointer; ABuffer: PPointer;
  ASize: PNativeUInt): Pointer; cdecl; external name 'dispatch_data_create_map';

procedure Nw_retain(AObject: Pointer); cdecl; external name 'nw_retain';
procedure Nw_release(AObject: Pointer); cdecl; external name 'nw_release';
function Nw_parameters_create_secure_tcp(ATLS, ATCP: Pointer): Pointer; cdecl;
  external name 'nw_parameters_create_secure_tcp';
procedure Nw_parameters_set_reuse_local_address(AParameters: Pointer;
  AReuse: ByteBool); cdecl; external name 'nw_parameters_set_reuse_local_address';
procedure Nw_parameters_set_local_endpoint(AParameters,
  AEndpoint: Pointer); cdecl;
  external name 'nw_parameters_set_local_endpoint';
function Nw_endpoint_create_host(AHost, APort: PAnsiChar): Pointer; cdecl;
  external name 'nw_endpoint_create_host';
function Nw_tls_copy_sec_protocol_options(AOptions: Pointer): Pointer; cdecl;
  external name 'nw_tls_copy_sec_protocol_options';
procedure Sec_protocol_options_set_local_identity(AOptions,
  AIdentity: Pointer); cdecl;
  external name 'sec_protocol_options_set_local_identity';
procedure Nw_tcp_options_set_no_delay(AOptions: Pointer;
  ANoDelay: ByteBool); cdecl; external name 'nw_tcp_options_set_no_delay';
function Nw_listener_create_with_port(APort: PAnsiChar;
  AParameters: Pointer): Pointer; cdecl;
  external name 'nw_listener_create_with_port';
function Nw_listener_create(AParameters: Pointer): Pointer; cdecl;
  external name 'nw_listener_create';
procedure Nw_listener_set_queue(AListener, AQueue: Pointer); cdecl;
  external name 'nw_listener_set_queue';
procedure Nw_listener_set_state_changed_handler(AListener,
  ABlock: Pointer); cdecl; external name 'nw_listener_set_state_changed_handler';
procedure Nw_listener_set_new_connection_handler(AListener,
  ABlock: Pointer); cdecl;
  external name 'nw_listener_set_new_connection_handler';
procedure Nw_listener_start(AListener: Pointer); cdecl;
  external name 'nw_listener_start';
procedure Nw_listener_cancel(AListener: Pointer); cdecl;
  external name 'nw_listener_cancel';
procedure Nw_connection_set_queue(AConnection, AQueue: Pointer); cdecl;
  external name 'nw_connection_set_queue';
procedure Nw_connection_set_state_changed_handler(AConnection,
  ABlock: Pointer); cdecl;
  external name 'nw_connection_set_state_changed_handler';
procedure Nw_connection_start(AConnection: Pointer); cdecl;
  external name 'nw_connection_start';
procedure Nw_connection_cancel(AConnection: Pointer); cdecl;
  external name 'nw_connection_cancel';
procedure Nw_connection_receive(AConnection: Pointer; AMinimum,
  AMaximum: UInt32; ABlock: Pointer); cdecl;
  external name 'nw_connection_receive';
procedure Nw_connection_send(AConnection, AData, AContext: Pointer;
  AComplete: ByteBool; ABlock: Pointer); cdecl;
  external name 'nw_connection_send';

function Dlsym(AHandle: Pointer; AName: PAnsiChar): Pointer; cdecl;
  external name 'dlsym';
function CFDataCreate(AAllocator, ABytes: Pointer;
  ALength: NativeInt): Pointer; cdecl; external name 'CFDataCreate';
function CFStringCreateWithCString(AAllocator: Pointer; AString: PAnsiChar;
  AEncoding: UInt32): Pointer; cdecl;
  external name 'CFStringCreateWithCString';
function CFStringGetCString(AString: Pointer; ABuffer: PAnsiChar;
  ABufferSize: NativeInt; AEncoding: UInt32): ByteBool; cdecl;
  external name 'CFStringGetCString';
function CFErrorCopyDescription(AError: Pointer): Pointer; cdecl;
  external name 'CFErrorCopyDescription';
function CFDictionaryCreate(AAllocator: Pointer; AKeys, AValues: PPointer;
  ACount: NativeInt; AKeyCallbacks, AValueCallbacks: Pointer): Pointer; cdecl;
  external name 'CFDictionaryCreate';
function CFArrayGetCount(AArray: Pointer): NativeInt; cdecl;
  external name 'CFArrayGetCount';
function CFArrayGetValueAtIndex(AArray: Pointer;
  AIndex: NativeInt): Pointer; cdecl; external name 'CFArrayGetValueAtIndex';
function CFDictionaryGetValue(ADictionary, AKey: Pointer): Pointer; cdecl;
  external name 'CFDictionaryGetValue';
function CFArrayCreate(AAllocator, AValues: Pointer; ACount: NativeInt;
  ACallbacks: Pointer): Pointer; cdecl; external name 'CFArrayCreate';
function CFRetain(AObject: Pointer): Pointer; cdecl; external name 'CFRetain';
procedure CFRelease(AObject: Pointer); cdecl; external name 'CFRelease';
function SecPKCS12Import(AData, AOptions: Pointer;
  AItems: PPointer): Int32; cdecl; external name 'SecPKCS12Import';
function Sec_identity_create(AIdentity: Pointer): Pointer; cdecl;
  external name 'sec_identity_create';
function SecPolicyCreateSSL(AServer: ByteBool; AHostname: Pointer): Pointer;
  cdecl; external name 'SecPolicyCreateSSL';
function SecTrustCreateWithCertificates(ACertificates, APolicies: Pointer;
  out ATrust: Pointer): Int32; cdecl;
  external name 'SecTrustCreateWithCertificates';
function SecTrustSetAnchorCertificates(ATrust, AAnchors: Pointer): Int32;
  cdecl; external name 'SecTrustSetAnchorCertificates';
function SecTrustSetAnchorCertificatesOnly(ATrust: Pointer;
  AAnchorCertificatesOnly: ByteBool): Int32; cdecl;
  external name 'SecTrustSetAnchorCertificatesOnly';
function SecTrustEvaluateWithError(ATrust: Pointer;
  out AError: Pointer): ByteBool; cdecl;
  external name 'SecTrustEvaluateWithError';
function SecKeychainCreate(APath: PAnsiChar; APassphraseLength: UInt32;
  APassphrase: Pointer; APromptUser: ByteBool; AInitialAccess: Pointer;
  out AKeychain: Pointer): Int32; cdecl; external name 'SecKeychainCreate';
function SecKeychainDelete(AKeychain: Pointer): Int32; cdecl;
  external name 'SecKeychainDelete';
function SecRandomCopyBytes(ARandom: Pointer; ACount: NativeUInt;
  ABytes: Pointer): Int32; cdecl; external name 'SecRandomCopyBytes';

const
  RTLD_DEFAULT = Pointer(-2);

var
  BlockIsaStack: Pointer;
  ConfigureBlockDescriptor, NewConnectionBlockDescriptor,
    ReceiveBlockDescriptor, SendBlockDescriptor,
    StateBlockDescriptor: TBlockDescriptor;
  ConfigureBlockSignature, NewConnectionBlockSignature,
    ReceiveBlockSignature, SendBlockSignature,
    StateBlockSignature: AnsiString;
  ContentContextDefaultStream: Pointer;
  KeyImportPassphrase: Pointer;
  KeyImportItemIdentity: Pointer;
  KeyImportItemCertChain: Pointer;
  KeyImportKeychain: Pointer;
  ArrayCallbacks: Pointer;
  DictionaryKeyCallbacks: Pointer;
  DictionaryValueCallbacks: Pointer;

threadvar
  FrameworkThreadInitialized: Boolean;

procedure EnsureFrameworkThread;
begin
  if FrameworkThreadInitialized then Exit;
  FrameworkThreadInitialized := True;
  Assign(Output, '');
  Rewrite(Output);
  Assign(ErrOutput, '');
  Rewrite(ErrOutput);
end;

function MakeBlock(var ABlock: TRegistryBlock; AInvoke: CodePointer;
  AContext: Pointer; ADescriptor: PBlockDescriptor): Pointer;
begin
  ABlock.Isa := BlockIsaStack;
  ABlock.Flags := BLOCK_FLAG_HAS_SIGNATURE;
  ABlock.Reserved := 0;
  ABlock.Invoke := AInvoke;
  ABlock.Descriptor := ADescriptor;
  ABlock.Context := AContext;
  Result := @ABlock;
end;

{$IFDEF REGISTRY_TESTING}
function BlockMatchesABI(var ABlock: TRegistryBlock;
  ADescriptor: PBlockDescriptor; const AExpectedSignature: AnsiString): Boolean;
begin
  MakeBlock(ABlock, nil, nil, ADescriptor);
  Result := (ABlock.Isa = BlockIsaStack)
    and (ABlock.Flags and BLOCK_FLAG_HAS_SIGNATURE <> 0)
    and (ABlock.Reserved = 0)
    and (ABlock.Descriptor = ADescriptor)
    and (ABlock.Descriptor^.Reserved = 0)
    and (ABlock.Descriptor^.Size = SizeOf(TRegistryBlock))
    and (AnsiString(ABlock.Descriptor^.Signature) = AExpectedSignature)
    and (ABlock.Descriptor^.Layout = nil)
    and Block_has_signature(@ABlock);
end;

function NetworkFrameworkBlockABIIsCompleteForTesting: Boolean;
var
  Block: TRegistryBlock;
begin
  Result := BlockMatchesABI(Block, @ConfigureBlockDescriptor,
    'v16@?0^{nw_protocol_options=}8')
    and BlockMatchesABI(Block, @StateBlockDescriptor,
      'v20@?0i8^{nw_error=}12')
    and BlockMatchesABI(Block, @ReceiveBlockDescriptor,
      'v36@?0^{dispatch_data_s=}8^{nw_content_context=}16B24^{nw_error=}28')
    and BlockMatchesABI(Block, @SendBlockDescriptor,
      'v16@?0^{nw_error=}8')
    and BlockMatchesABI(Block, @NewConnectionBlockDescriptor,
      'v16@?0^{nw_connection=}8');
end;
{$ENDIF}

procedure TLSConfigureInvoke(ABlock: PRegistryBlock;
  AOptions: Pointer); cdecl;
var
  Options: Pointer;
  Server: TNetworkFrameworkRegistryServer;
begin
  EnsureFrameworkThread;
  Server := TNetworkFrameworkRegistryServer(ABlock^.Context);
  Options := Nw_tls_copy_sec_protocol_options(AOptions);
  Sec_protocol_options_set_local_identity(Options, Server.FTLSIdentity);
  Nw_release(Options);
end;

procedure TCPConfigureInvoke(ABlock: PRegistryBlock;
  AOptions: Pointer); cdecl;
begin
  Nw_tcp_options_set_no_delay(AOptions, True);
end;

procedure ListenerStateInvoke(ABlock: PRegistryBlock; AState: Int32;
  AError: Pointer); cdecl;
var
  Server: TNetworkFrameworkRegistryServer;
begin
  EnsureFrameworkThread;
  Server := TNetworkFrameworkRegistryServer(ABlock^.Context);
  case AState of
    NW_LISTENER_STATE_READY, NW_LISTENER_STATE_FAILED:
      begin
        InterLockedExchange(Server.FListenerState, AState);
        Dispatch_semaphore_signal(Server.FReadySemaphore);
      end;
    NW_LISTENER_STATE_CANCELLED:
      PublishListenerCancellation(Server.FListenerDoneSemaphore,
        Server.FListenerState);
    else InterLockedExchange(Server.FListenerState, AState);
  end;
end;

procedure ConnectionStateInvoke(ABlock: PRegistryBlock; AState: Int32;
  AError: Pointer); cdecl;
var
  Connection: TNetworkFrameworkRegistryConnection;
begin
  EnsureFrameworkThread;
  Connection := TNetworkFrameworkRegistryConnection(ABlock^.Context);
  case AState of
    NW_CONNECTION_STATE_READY: Connection.ArmReceive;
    NW_CONNECTION_STATE_FAILED: Connection.Cancel;
    NW_CONNECTION_STATE_CANCELLED:
      Connection.FServer.ConnectionFinished(Connection);
  end;
end;

procedure ReceiveInvoke(ABlock: PRegistryBlock; AContent,
  AContext: Pointer; AComplete: ByteBool; AError: Pointer); cdecl;
var
  Buffer, Mapped: Pointer;
  Connection: TNetworkFrameworkRegistryConnection;
  Size: NativeUInt;
begin
  EnsureFrameworkThread;
  Connection := TNetworkFrameworkRegistryConnection(ABlock^.Context);
  if Connection.FClosing or Connection.FResponding then Exit;
  if AContent <> nil then
  begin
    Mapped := Dispatch_data_create_map(AContent, @Buffer, @Size);
    try
      if Size > 0 then Connection.Consume(Buffer, Size);
    finally
      Dispatch_release(Mapped);
    end;
  end;
  if Connection.FClosing or Connection.FResponding then Exit;
  if (AError <> nil) or AComplete then Connection.Cancel
  else Connection.ArmReceive;
end;

procedure SendInvoke(ABlock: PRegistryBlock; AError: Pointer); cdecl;
var
  Connection: TNetworkFrameworkRegistryConnection;
begin
  EnsureFrameworkThread;
  Connection := TNetworkFrameworkRegistryConnection(ABlock^.Context);
  try
    Connection.SendCompleted(AError);
  except
    Connection.Cancel;
  end;
end;

procedure NewConnectionInvoke(ABlock: PRegistryBlock;
  ANetworkConnection: Pointer); cdecl;
var
  Connection: TNetworkFrameworkRegistryConnection;
  Server: TNetworkFrameworkRegistryServer;
begin
  EnsureFrameworkThread;
  Server := TNetworkFrameworkRegistryServer(ABlock^.Context);
  EnterCriticalSection(Server.FConnectionLock);
  try
    if Server.FStopping
      or (Server.FConnections.Count >= MAX_ACTIVE_CONNECTIONS) then
    begin
      Nw_connection_cancel(ANetworkConnection);
      Exit;
    end;
    Connection := TNetworkFrameworkRegistryConnection.Create;
    Connection.FServer := Server;
    Connection.FDeadline := GetTickCount64
      + CONNECTION_DEADLINE_MILLISECONDS;
    Nw_retain(ANetworkConnection);
    Connection.FConnection := ANetworkConnection;
    Connection.FQueue := Dispatch_queue_create(
      PAnsiChar(AnsiString('org.' + PROGRAM_NAME + '.registry.connection')),
      nil);
    Nw_connection_set_queue(ANetworkConnection, Connection.FQueue);
    Nw_connection_set_state_changed_handler(ANetworkConnection,
      MakeBlock(Connection.FStateBlock, @ConnectionStateInvoke, Connection,
        @StateBlockDescriptor));
    Server.FConnections.Add(Connection);
    InterLockedIncrement(Server.FActiveConnections);
    { Starting under the admission lock prevents the run loop from observing a
      published connection before every field and callback is initialized. }
    Nw_connection_start(ANetworkConnection);
  finally
    LeaveCriticalSection(Server.FConnectionLock);
  end;
end;

procedure TNetworkFrameworkRegistryConnection.ArmReceive;
begin
  if GetTickCount64 >= FDeadline then
  begin
    Cancel;
    Exit;
  end;
  if not FClosing then
    Nw_connection_receive(FConnection, 1, MAX_REQUEST_BYTES,
      MakeBlock(FReceiveBlock, @ReceiveInvoke, Self,
        @ReceiveBlockDescriptor));
end;

procedure TNetworkFrameworkRegistryConnection.Cancel;
begin
  if FClosing then Exit;
  FClosing := True;
  { The cancelled state callback releases the retained connection and queue. }
  Nw_connection_cancel(FConnection);
end;

procedure TNetworkFrameworkRegistryConnection.CheckDeadline;
begin
  if FClosing or (GetTickCount64 >= FDeadline) then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'registry connection exceeded its total deadline');
end;

destructor TNetworkFrameworkRegistryConnection.Destroy;
begin
  FResponseStream.Free;
  if FSendData <> nil then Dispatch_release(FSendData);
  inherited Destroy;
end;

procedure TNetworkFrameworkRegistryConnection.Consume(const ABuffer: Pointer;
  const ALength: NativeUInt);
var
  Chunk: AnsiString;
begin
  if GetTickCount64 >= FDeadline then
  begin
    Cancel;
    Exit;
  end;
  if Length(FRequest) + ALength > MAX_REQUEST_BYTES then
  begin
    Cancel;
    Exit;
  end;
  SetString(Chunk, PAnsiChar(ABuffer), ALength);
  FRequest := FRequest + Chunk;
  if Pos(#13#10#13#10, FRequest) > 0 then
  begin
    FResponding := True;
    try
      SendResponse;
    except
      Cancel;
    end;
  end;
end;

procedure TNetworkFrameworkRegistryConnection.SendResponse;
var
  IncludeBody: Boolean;
  Method, RequestLine, Target: string;
  Response: TLWPTRegistryHTTPResponse;
  Space: Integer;
begin
  RequestLine := Copy(string(FRequest), 1, Pos(#13#10, string(FRequest)) - 1);
  Space := Pos(' ', RequestLine);
  if Space = 0 then
  begin
    Cancel;
    Exit;
  end;
  Method := Copy(RequestLine, 1, Space - 1);
  Delete(RequestLine, 1, Space);
  Space := Pos(' ', RequestLine);
  if Space = 0 then
  begin
    Cancel;
    Exit;
  end;
  Target := Copy(RequestLine, 1, Space - 1);
  Response := RegistryHTTPResponse(FServer.FStore, Method, Target,
    CheckDeadline);
  IncludeBody := not SameText(Method, 'HEAD');
  if GetTickCount64 >= FDeadline then
  begin
    Cancel;
    Exit;
  end;
  if Response.ResourcePath <> '' then
  begin
    try
      FResponseStream := OpenRegistryHTTPResource(Response, CheckDeadline);
    except
      on E: Exception do
        Response := RegistryResourceFailureResponse(E.Message);
    end;
    if not IncludeBody then FreeAndNil(FResponseStream);
  end;
  FSendBuffer := RegistryHTTPWireResponse(Response,
    IncludeBody and (Response.ResourcePath = ''));
  SendCurrentBuffer;
end;

procedure TNetworkFrameworkRegistryConnection.SendCurrentBuffer;
begin
  if FClosing or (Length(FSendBuffer) = 0)
    or (GetTickCount64 >= FDeadline) then
  begin
    Cancel;
    Exit;
  end;
  FSendData := Dispatch_data_create(@FSendBuffer[0], Length(FSendBuffer),
    nil, nil);
  Nw_connection_send(FConnection, FSendData, ContentContextDefaultStream,
    False, MakeBlock(FSendBlock, @SendInvoke, Self, @SendBlockDescriptor));
end;

procedure TNetworkFrameworkRegistryConnection.SendNextResourceChunk;
var
  ReadCount: Integer;
begin
  if not Assigned(FResponseStream) then
  begin
    Cancel;
    Exit;
  end;
  CheckDeadline;
  SetLength(FSendBuffer, 64 * 1024);
  ReadCount := FResponseStream.Read(FSendBuffer[0], Length(FSendBuffer));
  SetLength(FSendBuffer, ReadCount);
  if ReadCount = 0 then
  begin
    FreeAndNil(FResponseStream);
    Cancel;
    Exit;
  end;
  SendCurrentBuffer;
end;

procedure TNetworkFrameworkRegistryConnection.SendCompleted(AError: Pointer);
begin
  if FSendData <> nil then
  begin
    Dispatch_release(FSendData);
    FSendData := nil;
  end;
  SetLength(FSendBuffer, 0);
  if (AError <> nil) or FClosing or (GetTickCount64 >= FDeadline) then
  begin
    Cancel;
    Exit;
  end;
  if Assigned(FResponseStream) then
  begin
    if FResponseStream.Position < FResponseStream.Size then
      SendNextResourceChunk
    else
    begin
      FreeAndNil(FResponseStream);
      Cancel;
    end;
  end
  else Cancel;
end;

procedure TNetworkFrameworkRegistryServer.ConnectionFinished(
  AConnection: TNetworkFrameworkRegistryConnection);
begin
  EnterCriticalSection(FConnectionLock);
  try
    FConnections.Remove(AConnection);
  finally
    LeaveCriticalSection(FConnectionLock);
  end;
  Nw_release(AConnection.FConnection);
  Dispatch_release(AConnection.FQueue);
  AConnection.Free;
  { Active-count zero is the callback-complete publication. The decrement must
    be the callback's final access to server-owned storage. }
  PublishConnectionCompletion(FDrainSemaphore, FActiveConnections);
end;

function ReadPKCS12WithoutFollowingLinks(const APath: string): TBytes;
var
  Stream: TStream;
begin
  Result := nil;
  Stream := nil;
  try
    try
      try
        Stream := OpenRegistryFileWithoutFollowingLinks(APath);
      except
        on E: Exception do
          raise ELWPTRegistryError.CreateStable('tls_configuration',
            'could not open PKCS#12 identity without following links');
      end;
      if (Stream.Size < 1) or (Stream.Size > MAX_PKCS12_BYTES) then
        raise ELWPTRegistryError.CreateStable('tls_configuration',
          'PKCS#12 identity must be a regular file from 1 byte through 16 MiB');
      SetLength(Result, Stream.Size);
      try
        Stream.ReadBuffer(Result[0], Length(Result));
      except
        on E: Exception do
          raise ELWPTRegistryError.CreateStable('tls_configuration',
            'could not read the complete PKCS#12 identity');
      end;
    except
      if Length(Result) > 0 then FillChar(Result[0], Length(Result), 0);
      Result := nil;
      raise;
    end;
  finally
    Stream.Free;
  end;
end;

procedure ValidateBundledIdentity(const AImportedItem: Pointer);
var
  Anchor, Anchors, Chain, ErrorReference, Policy, Trust: Pointer;
  ErrorDescription: Pointer;
  ErrorBuffer: array[0..511] of AnsiChar;
  Detail: string;
  Status: Int32;
begin
  Chain := CFDictionaryGetValue(AImportedItem, KeyImportItemCertChain);
  if (Chain = nil) or (CFArrayGetCount(Chain) < 2) then
    raise ELWPTRegistryError.CreateStable('tls_certificate_policy',
      'TLS identity must contain a non-self-signed certificate chain');
  Anchor := CFArrayGetValueAtIndex(Chain, CFArrayGetCount(Chain) - 1);
  Anchors := CFArrayCreate(nil, @Anchor, 1, ArrayCallbacks);
  Policy := SecPolicyCreateSSL(True, nil);
  Trust := nil;
  ErrorReference := nil;
  try
    Status := SecTrustCreateWithCertificates(Chain, Policy, Trust);
    if (Status <> 0) or (Trust = nil) then
      raise ELWPTRegistryError.CreateStable('tls_certificate_policy',
        'could not create bundled-chain certificate validation');
    if (SecTrustSetAnchorCertificates(Trust, Anchors) <> 0)
      or (SecTrustSetAnchorCertificatesOnly(Trust, True) <> 0) then
      raise ELWPTRegistryError.CreateStable('tls_certificate_policy',
        'TLS identity does not form a valid bundled server chain');
    if not SecTrustEvaluateWithError(Trust, ErrorReference) then
    begin
      Detail := '';
      if ErrorReference <> nil then
      begin
        ErrorDescription := CFErrorCopyDescription(ErrorReference);
        try
          FillChar(ErrorBuffer, SizeOf(ErrorBuffer), 0);
          if CFStringGetCString(ErrorDescription, @ErrorBuffer[0],
            SizeOf(ErrorBuffer), CF_STRING_ENCODING_UTF8) then
            Detail := ': ' + string(PAnsiChar(@ErrorBuffer[0]));
        finally
          CFRelease(ErrorDescription);
        end;
      end;
      raise ELWPTRegistryError.CreateStable('tls_certificate_policy',
        'TLS identity does not form a valid bundled server chain' + Detail);
    end;
  finally
    if ErrorReference <> nil then CFRelease(ErrorReference);
    if Trust <> nil then CFRelease(Trust);
    if Policy <> nil then CFRelease(Policy);
    if Anchors <> nil then CFRelease(Anchors);
  end;
end;

function TemporaryKeychainRandomHex(
  out ARandom: TTemporaryKeychainRandom): AnsiString;
const
  HEX = '0123456789abcdef';
var
  Index: Integer;
begin
  if SecRandomCopyBytes(nil, SizeOf(ARandom), @ARandom[0]) <> 0 then
    raise ELWPTRegistryError.CreateStable('tls_configuration',
      'could not obtain secure temporary keychain material');
  SetLength(Result, SizeOf(ARandom) * 2);
  for Index := 0 to High(ARandom) do
  begin
    Result[Index * 2 + 1] := HEX[(ARandom[Index] shr 4) + 1];
    Result[Index * 2 + 2] := HEX[(ARandom[Index] and $0f) + 1];
  end;
end;

function TryTemporaryKeychainOwnerPID(const AName: string;
  out APID: LongInt): Boolean;
const
  SUFFIX = '.keychain';
var
  Character: Char;
  Index: Integer;
  Nonce, Owner, Prefix, Tail: string;
begin
  Result := False;
  APID := 0;
  Prefix := PROGRAM_NAME + '-registry-tls-';
  if Length(AName) <= Length(Prefix) + Length(SUFFIX) then Exit;
  if Copy(AName, 1, Length(Prefix)) <> Prefix then Exit;
  if Copy(AName, Length(AName) - Length(SUFFIX) + 1,
    Length(SUFFIX)) <> SUFFIX then Exit;
  Tail := Copy(AName, Length(Prefix) + 1,
    Length(AName) - Length(Prefix) - Length(SUFFIX));
  Index := Pos('-', Tail);
  if Index <= 1 then Exit;
  Owner := Copy(Tail, 1, Index - 1);
  Nonce := Copy(Tail, Index + 1, MaxInt);
  if Length(Nonce) <> TEMPORARY_KEYCHAIN_RANDOM_BYTES * 2 then Exit;
  for Character in Owner do
    if not (Character in ['0'..'9']) then Exit;
  for Character in Nonce do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit;
  if not TryStrToInt(Owner, APID) or (APID <= 0) then Exit;
  Result := True;
end;

function ProcessIsDefinitelyDead(const APID: LongInt): Boolean;
var
  ErrorCode: cint;
begin
  if FpKill(APID, 0) = 0 then Exit(False);
  ErrorCode := FpGetErrNo;
  Result := ErrorCode = ESysESRCH;
end;

procedure ReconcileAbandonedTemporaryKeychains;
var
  Inspected: Integer;
  OwnerPID: LongInt;
  Path, Pattern: string;
  Search: TSearchRec;
  Status: Stat;
begin
  Inspected := 0;
  Pattern := IncludeTrailingPathDelimiter(GetTempDir)
    + PROGRAM_NAME + '-registry-tls-*.keychain';
  if FindFirst(Pattern, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      Inc(Inspected);
      if Inspected > MAX_TEMPORARY_KEYCHAIN_RECOVERY_FILES then
        raise ELWPTRegistryError.CreateStable('tls_configuration',
          'temporary keychain recovery limit exceeded');
      if not TryTemporaryKeychainOwnerPID(Search.Name, OwnerPID) then Continue;
      Path := IncludeTrailingPathDelimiter(GetTempDir) + Search.Name;
      if (FpLStat(PChar(Path), Status) <> 0)
        or ((Status.st_mode and S_IFMT) <> S_IFREG)
        or (Status.st_uid <> FpGetUID) then Continue;
      if not ProcessIsDefinitelyDead(OwnerPID) then Continue;
      if not SysUtils.DeleteFile(Path) then
        raise ELWPTRegistryError.CreateStable('tls_configuration',
          'could not recover abandoned temporary keychain storage');
      if (FpLStat(PChar(Path), Status) = 0)
        or (FpGetErrNo <> ESysENOENT) then
        raise ELWPTRegistryError.CreateStable('tls_configuration',
          'temporary keychain storage survived recovery');
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure WipeAnsiString(var AValue: AnsiString);
begin
  if Length(AValue) > 0 then
    FillChar(AValue[1], Length(AValue) * SizeOf(AnsiChar), 0);
  AValue := '';
end;

procedure TNetworkFrameworkRegistryServer.DeleteTemporaryKeychainStorage;
var
  Path: string;
  Status: Stat;
begin
  Path := FTemporaryKeychainPath;
  if Path = '' then Exit;
  if FpLStat(PChar(Path), Status) <> 0 then
  begin
    if FpGetErrNo = ESysENOENT then
    begin
      FTemporaryKeychainPath := '';
      Exit;
    end;
    raise ELWPTRegistryError.CreateStable('tls_configuration',
      'could not verify temporary keychain storage before removal');
  end;
  if ((Status.st_mode and S_IFMT) <> S_IFREG)
    or (Status.st_uid <> FpGetUID) then
    raise ELWPTRegistryError.CreateStable('tls_configuration',
      'temporary keychain storage ownership changed before removal');
  if not SysUtils.DeleteFile(Path) then
    raise ELWPTRegistryError.CreateStable('tls_configuration',
      'could not remove temporary keychain storage');
  if (FpLStat(PChar(Path), Status) = 0) or (FpGetErrNo <> ESysENOENT) then
    raise ELWPTRegistryError.CreateStable('tls_configuration',
      'temporary keychain storage survived removal');
  FTemporaryKeychainPath := '';
end;

procedure TNetworkFrameworkRegistryServer.LoadIdentity(const APath,
  APassphrase: string);
var
  Bytes: TBytes;
  CFData, CFOptions, CFPassphrase, IdentityReference, Item,
    Items: Pointer;
  EncodedPassphrase, KeychainPassphrase, KeychainPath,
    KeychainPathNonce: AnsiString;
  KeychainPasswordRandom, KeychainPathRandom: TTemporaryKeychainRandom;
  Keys, Values: array[0..1] of Pointer;
  PathStatus: Stat;
  Status: Int32;
begin
  Bytes := nil;
  CFData := nil;
  CFOptions := nil;
  CFPassphrase := nil;
  IdentityReference := nil;
  Items := nil;
  EncodedPassphrase := '';
  KeychainPassphrase := '';
  KeychainPathNonce := '';
  FillChar(KeychainPasswordRandom, SizeOf(KeychainPasswordRandom), 0);
  FillChar(KeychainPathRandom, SizeOf(KeychainPathRandom), 0);
  try
    Bytes := ReadPKCS12WithoutFollowingLinks(APath);
    ReconcileAbandonedTemporaryKeychains;
    KeychainPathNonce := TemporaryKeychainRandomHex(KeychainPathRandom);
    FTemporaryKeychainPath := IncludeTrailingPathDelimiter(GetTempDir)
      + PROGRAM_NAME + '-registry-tls-' + IntToStr(GetProcessID) + '-'
      + string(KeychainPathNonce) + '.keychain';
    KeychainPath := AnsiString(FTemporaryKeychainPath);
    if FpLStat(PChar(FTemporaryKeychainPath), PathStatus) = 0 then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'temporary keychain path already exists');
    if FpGetErrNo <> ESysENOENT then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not verify the temporary keychain path');
    KeychainPassphrase := TemporaryKeychainRandomHex(KeychainPasswordRandom);
    Status := SecKeychainCreate(PAnsiChar(KeychainPath),
      Length(KeychainPassphrase), PAnsiChar(KeychainPassphrase), False, nil,
      FTemporaryKeychain);
    if Status <> 0 then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'temporary keychain creation failed with status ' + IntToStr(Status));
    if FpChmod(FTemporaryKeychainPath, S_IRUSR or S_IWUSR) <> 0 then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not restrict temporary keychain storage');
    CFData := CFDataCreate(nil, @Bytes[0], Length(Bytes));
    if CFData = nil then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not retain PKCS#12 identity bytes for import');
    FillChar(Bytes[0], Length(Bytes), 0);
    Bytes := nil;
    EncodedPassphrase := AnsiString(APassphrase);
    CFPassphrase := CFStringCreateWithCString(nil,
      PAnsiChar(EncodedPassphrase), CF_STRING_ENCODING_UTF8);
    if CFPassphrase = nil then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not encode the PKCS#12 passphrase');
    Keys[0] := KeyImportPassphrase;
    Values[0] := CFPassphrase;
    Keys[1] := KeyImportKeychain;
    Values[1] := FTemporaryKeychain;
    CFOptions := CFDictionaryCreate(nil, @Keys[0], @Values[0], 2,
      DictionaryKeyCallbacks, DictionaryValueCallbacks);
    if CFOptions = nil then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not prepare PKCS#12 import options');
    Status := SecPKCS12Import(CFData, CFOptions, @Items);
    if (Status <> 0) or (Items = nil) or (CFArrayGetCount(Items) = 0) then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'PKCS#12 import failed with status ' + IntToStr(Status));
    Item := CFArrayGetValueAtIndex(Items, 0);
    ValidateBundledIdentity(Item);
    IdentityReference := CFDictionaryGetValue(Item, KeyImportItemIdentity);
    if IdentityReference = nil then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'PKCS#12 contains no identity');
    CFRetain(IdentityReference);
    FTLSIdentity := Sec_identity_create(IdentityReference);
    if FTLSIdentity = nil then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'could not create the Network.framework TLS identity');
  finally
    if Length(Bytes) > 0 then FillChar(Bytes[0], Length(Bytes), 0);
    Bytes := nil;
    if Length(EncodedPassphrase) > 0 then
      FillChar(EncodedPassphrase[1], Length(EncodedPassphrase)
        * SizeOf(AnsiChar), 0);
    EncodedPassphrase := '';
    WipeAnsiString(KeychainPassphrase);
    WipeAnsiString(KeychainPathNonce);
    FillChar(KeychainPasswordRandom, SizeOf(KeychainPasswordRandom), 0);
    FillChar(KeychainPathRandom, SizeOf(KeychainPathRandom), 0);
    if IdentityReference <> nil then CFRelease(IdentityReference);
    if Items <> nil then CFRelease(Items);
    if CFOptions <> nil then CFRelease(CFOptions);
    if CFPassphrase <> nil then CFRelease(CFPassphrase);
    if CFData <> nil then CFRelease(CFData);
  end;
end;

constructor TNetworkFrameworkRegistryServer.Create(AStore: TLWPTRegistryStore;
  const APKCS12Path, APassphrase: string; AStopFlag: PBoolean);
var
  Endpoint: Pointer;
  Host, Port: AnsiString;
begin
  inherited Create;
  IsMultiThread := True;
  FStore := AStore;
  FStopFlag := AStopFlag;
  FConnections := TList.Create;
  InitCriticalSection(FConnectionLock);
  FReadySemaphore := Dispatch_semaphore_create(0);
  FStopSemaphore := Dispatch_semaphore_create(0);
  FDrainSemaphore := Dispatch_semaphore_create(0);
  FListenerDoneSemaphore := Dispatch_semaphore_create(0);
  FListenerQueue := Dispatch_queue_create(
    PAnsiChar(AnsiString('org.' + PROGRAM_NAME + '.registry.listener')), nil);
  LoadIdentity(APKCS12Path, APassphrase);
  FParameters := Nw_parameters_create_secure_tcp(
    MakeBlock(FTLSBlock, @TLSConfigureInvoke, Self,
      @ConfigureBlockDescriptor),
    MakeBlock(FTCPBlock, @TCPConfigureInvoke, Self,
      @ConfigureBlockDescriptor));
  Nw_parameters_set_reuse_local_address(FParameters, True);
  Host := AnsiString(FStore.Config.ListenAddress);
  if SameText(string(Host), 'localhost') then Host := '127.0.0.1';
  Port := AnsiString(IntToStr(FStore.Config.Port));
  Endpoint := Nw_endpoint_create_host(PAnsiChar(Host), PAnsiChar(Port));
  if Endpoint = nil then
    raise ELWPTRegistryError.CreateStable('invalid_listen_address',
      'could not create the configured Network.framework endpoint');
  Nw_parameters_set_local_endpoint(FParameters, Endpoint);
  Nw_release(Endpoint);
  FListener := Nw_listener_create(FParameters);
  if FListener = nil then
    raise ELWPTRegistryError.CreateStable('listen_failed',
      'Network.framework could not create the registry listener');
  Nw_listener_set_queue(FListener, FListenerQueue);
  Nw_listener_set_state_changed_handler(FListener,
    MakeBlock(FListenerStateBlock, @ListenerStateInvoke, Self,
      @StateBlockDescriptor));
  Nw_listener_set_new_connection_handler(FListener,
    MakeBlock(FNewConnectionBlock, @NewConnectionInvoke, Self,
      @NewConnectionBlockDescriptor));
  Nw_listener_start(FListener);
  Dispatch_semaphore_wait(FReadySemaphore,
    Dispatch_time(0, LISTENER_READY_TIMEOUT_SECONDS * NANOSECONDS_PER_SECOND));
  if InterLockedExchangeAdd(FListenerState, 0)
    <> NW_LISTENER_STATE_READY then
    raise ELWPTRegistryError.CreateStable('listen_failed',
      'Network.framework could not bind the configured endpoint');
end;

destructor TNetworkFrameworkRegistryServer.Destroy;
var
  CleanupFailure: string;
  DeleteStatus: Int32;
  Index: Integer;
begin
  CleanupFailure := '';
  FStopping := True;
  if FListener <> nil then
  begin
    Nw_listener_cancel(FListener);
    while InterLockedExchangeAdd(FListenerState, 0)
      <> NW_LISTENER_STATE_CANCELLED do
      Dispatch_semaphore_wait(FListenerDoneSemaphore,
        Dispatch_time(0, DRAIN_POLL_MILLISECONDS
          * NANOSECONDS_PER_MILLISECOND));
  end;
  EnterCriticalSection(FConnectionLock);
  try
    for Index := 0 to FConnections.Count - 1 do
      TNetworkFrameworkRegistryConnection(FConnections[Index]).Cancel;
  finally
    LeaveCriticalSection(FConnectionLock);
  end;
  while InterLockedExchangeAdd(FActiveConnections, 0) > 0 do
    Dispatch_semaphore_wait(FDrainSemaphore,
      Dispatch_time(0, DRAIN_POLL_MILLISECONDS
        * NANOSECONDS_PER_MILLISECOND));
  if FListener <> nil then Nw_release(FListener);
  if FParameters <> nil then Nw_release(FParameters);
  if FTLSIdentity <> nil then Nw_release(FTLSIdentity);
  if FTemporaryKeychain <> nil then
  begin
    DeleteStatus := SecKeychainDelete(FTemporaryKeychain);
    CFRelease(FTemporaryKeychain);
    FTemporaryKeychain := nil;
    if DeleteStatus <> 0 then
      CleanupFailure := 'Security.framework could not delete temporary '
        + 'keychain storage';
  end;
  try
    DeleteTemporaryKeychainStorage;
  except
    on E: Exception do
      if CleanupFailure = '' then CleanupFailure := E.Message;
  end;
  if FListenerQueue <> nil then Dispatch_release(FListenerQueue);
  if FReadySemaphore <> nil then Dispatch_release(FReadySemaphore);
  if FStopSemaphore <> nil then Dispatch_release(FStopSemaphore);
  if FDrainSemaphore <> nil then Dispatch_release(FDrainSemaphore);
  if FListenerDoneSemaphore <> nil then
    Dispatch_release(FListenerDoneSemaphore);
  DoneCriticalSection(FConnectionLock);
  FConnections.Free;
  try
    if CleanupFailure <> '' then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        CleanupFailure);
  finally
    inherited Destroy;
  end;
end;

procedure TNetworkFrameworkRegistryServer.Run;
var
  Index: Integer;
begin
  WriteLn('registry origin ', FStore.Config.Identity, ' listening at ',
    FStore.Config.BaseURL);
  while not FStopping do
  begin
    if Assigned(FStopFlag) and FStopFlag^ then Break;
    EnterCriticalSection(FConnectionLock);
    try
      for Index := 0 to FConnections.Count - 1 do
        if GetTickCount64 >= TNetworkFrameworkRegistryConnection(
          FConnections[Index]).FDeadline then
          TNetworkFrameworkRegistryConnection(FConnections[Index]).Cancel;
    finally
      LeaveCriticalSection(FConnectionLock);
    end;
    Dispatch_semaphore_wait(FStopSemaphore,
      Dispatch_time(0, DRAIN_POLL_MILLISECONDS
        * NANOSECONDS_PER_MILLISECOND));
  end;
end;

procedure ResolveSymbols;
  procedure InitializeBlockDescriptor(var ADescriptor: TBlockDescriptor;
    var ASignatureStorage: AnsiString; const ASignature: AnsiString);
  begin
    ASignatureStorage := ASignature;
    ADescriptor.Reserved := 0;
    ADescriptor.Size := SizeOf(TRegistryBlock);
    ADescriptor.Signature := PAnsiChar(ASignatureStorage);
    ADescriptor.Layout := nil;
  end;
begin
  InitializeBlockDescriptor(ConfigureBlockDescriptor,
    ConfigureBlockSignature, BLOCK_SIGNATURE_CONFIGURE);
  InitializeBlockDescriptor(StateBlockDescriptor, StateBlockSignature,
    BLOCK_SIGNATURE_STATE);
  InitializeBlockDescriptor(ReceiveBlockDescriptor, ReceiveBlockSignature,
    BLOCK_SIGNATURE_RECEIVE);
  InitializeBlockDescriptor(SendBlockDescriptor, SendBlockSignature,
    BLOCK_SIGNATURE_SEND);
  InitializeBlockDescriptor(NewConnectionBlockDescriptor,
    NewConnectionBlockSignature, BLOCK_SIGNATURE_NEW_CONNECTION);
  BlockIsaStack := Dlsym(RTLD_DEFAULT, '_NSConcreteStackBlock');
  ContentContextDefaultStream := PPointer(Dlsym(RTLD_DEFAULT,
    '_nw_content_context_default_stream'))^;
  KeyImportPassphrase := PPointer(Dlsym(RTLD_DEFAULT,
    'kSecImportExportPassphrase'))^;
  KeyImportItemIdentity := PPointer(Dlsym(RTLD_DEFAULT,
    'kSecImportItemIdentity'))^;
  KeyImportItemCertChain := PPointer(Dlsym(RTLD_DEFAULT,
    'kSecImportItemCertChain'))^;
  KeyImportKeychain := PPointer(Dlsym(RTLD_DEFAULT,
    'kSecImportExportKeychain'))^;
  ArrayCallbacks := Dlsym(RTLD_DEFAULT, 'kCFTypeArrayCallBacks');
  DictionaryKeyCallbacks := Dlsym(RTLD_DEFAULT,
    'kCFTypeDictionaryKeyCallBacks');
  DictionaryValueCallbacks := Dlsym(RTLD_DEFAULT,
    'kCFTypeDictionaryValueCallBacks');
end;

procedure RunNetworkFrameworkRegistryServer(AStore: TLWPTRegistryStore;
  const APKCS12Path: string; var APassphrase: string; AStopFlag: PBoolean);
var
  Server: TNetworkFrameworkRegistryServer;
begin
  Server := nil;
  try
    Server := TNetworkFrameworkRegistryServer.Create(AStore, APKCS12Path,
      APassphrase, AStopFlag);
  finally
    if Length(APassphrase) > 0 then
      FillChar(APassphrase[1], Length(APassphrase) * SizeOf(Char), 0);
    APassphrase := '';
  end;
  try
    Server.Run;
  finally
    Server.Free;
  end;
end;

initialization
  ResolveSymbols;

{$ELSE}

procedure RunNetworkFrameworkRegistryServer(AStore: TLWPTRegistryStore;
  const APKCS12Path: string; var APassphrase: string; AStopFlag: PBoolean);
begin
  if Length(APassphrase) > 0 then
    FillChar(APassphrase[1], Length(APassphrase) * SizeOf(Char), 0);
  APassphrase := '';
  raise ELWPTRegistryError.CreateStable('tls_unavailable',
    'Network.framework registry transport is available only on macOS');
end;

{$IFDEF REGISTRY_TESTING}
function NetworkFrameworkTeardownOrderingIsSafeForTesting: Boolean;
begin
  Result := True;
end;

function NetworkFrameworkBlockABIIsCompleteForTesting: Boolean;
begin
  Result := True;
end;
{$ENDIF}

{$ENDIF}

end.
