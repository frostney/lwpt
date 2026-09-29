unit TransportSecurity;

// Cross-platform TLS transport. Blocking clients use SecureTransport on
// macOS, SChannel on Windows, and OpenSSL on Unix. Nonblocking server accept
// uses native SChannel (SSPI + crypt32) on Windows, Secure Transport on
// macOS, and memory-BIO OpenSSL on Unix-not-Darwin.
// Windows therefore links no OpenSSL and loads no OpenSSL DLL at runtime.

{$I Shared.inc}

{$IFDEF MSWINDOWS}
{$DEFINE TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$DEFINE TRANSPORT_SECURITY_SERVER}
{$ENDIF}
{$IFDEF DARWIN}
{$DEFINE TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
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
  { The client refused the peer: its certificate chain, validity, purpose,
    or host name failed verification. Raised by every client backend, with
    or without options, so a caller can tell a trust refusal, which a retry
    cannot fix, from a transient transport failure. }
  ETransportSecurityVerificationError = class(ETransportSecurityError);

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

  { How an outbound client combines configured trust anchors with the
    platform trust store. The zero value keeps today's system-store-only
    behaviour when no anchors are configured. See ADR-0050 for the
    per-backend semantics. }
  TTransportSecurityTrustMode = (
    { The platform trust store plus every configured anchor. }
    tstmSystemAndAnchors,
    { Only the configured anchors; the platform trust store is ignored. }
    tstmAnchorsOnly
  );

  { Outbound client TLS options. Every field's zero value means today's
    behaviour: system trust, full chain and host-name verification, and no
    client certificate. A zero-valued record takes exactly the same code path
    as the option-less StartTransportSecurity overloads. }
  TTransportSecurityClientOptions = record
    { Trust anchors as PEM text (one or more CERTIFICATE blocks) or a single
      DER-encoded certificate. Anchors are root CA certificates. }
    TrustAnchors: TBytes;
    TrustMode: TTransportSecurityTrustMode;
    { Client identity (mTLS) as PKCS#12 bytes, the format the server context
      accepts. Presented when the server requests a certificate. }
    ClientPkcs12: TBytes;
    ClientPkcs12Passphrase: UnicodeString;
    { Skip chain and host-name verification entirely. For development and
      test servers only; never the default, and it cannot be combined with
      trust anchors. The connection is still encrypted, but the peer is not
      authenticated. }
    InsecureSkipVerify: Boolean;
  end;

  TUnicodeStringArray = array of UnicodeString;

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
procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string;
  const AOptions: TTransportSecurityClientOptions); overload;
procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string;
  const AOptions: TTransportSecurityClientOptions; const ADeadline,
  ATimeoutMilliseconds: QWord); overload;
{ The zero-valued options record: system trust, full verification, no client
  certificate. }
function DefaultTransportSecurityClientOptions: TTransportSecurityClientOptions;
{ True when AOptions selects exactly the option-less client behaviour. }
function TransportSecurityClientOptionsAreDefault(
  const AOptions: TTransportSecurityClientOptions): Boolean;
{ Raises ETransportSecurityError when AOptions is inconsistent or malformed:
  anchors-only trust without anchors, insecure mode combined with anchors, a
  passphrase without an identity, or oversized inputs; then parses every
  anchor and opens the PKCS#12 identity with its passphrase through the
  platform's own APIs. Opens no socket and persists nothing, so callers
  (HTTPClient among them) reject bad material before connecting. On macOS
  the identity check creates and removes a temporary keychain; on Windows
  it imports without persisting keys and requires exactly one identity. }
procedure ValidateTransportSecurityClientOptions(
  const AOptions: TTransportSecurityClientOptions);
{ Describes why the calling thread's most recent
  TransportSecurityServerHandshake call failed (backend, stage, and native
  status where the backend exposes one), or '' when that call made progress
  or succeeded. Every handshake call and BeginTransportSecurityServer reset
  it, so interleaved connections on one thread never see each other's
  reason. Diagnostic text only, truncated to 480 characters and held in
  fixed thread-local storage: it never contains key material, passphrases,
  or plaintext. }
function TransportSecurityServerFailureReason: string;
{ DER encoding of the peer's leaf certificate on an active client
  connection; empty when the connection is not an active client or the peer
  presented no certificate. }
function TransportSecurityPeerCertificate(
  const AConnection: TTransportSecurityConnection): TBytes;
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
{$IFDEF TRANSPORT_SECURITY_SERVER}
{$IFNDEF PRODUCTION}
{ Test-only seam: make a server connection returned by
  BeginTransportSecurityServer, before its first handshake step, require a
  client certificate that chains to one of AClientAnchors (PEM or DER) for
  client authentication. Intermediates must come from the client's own
  certificate message: no system store, AIA fetch, or keychain supplies
  them. The handshake fails when the client presents no certificate or an
  unanchored one. Exists so the client-identity (mTLS) options can be
  exercised against the package's own server backends; the production
  server never requests client certificates. }
procedure TransportSecurityTestRequireClientCertificate(
  var AConnection: TTransportSecurityConnection;
  const AClientAnchors: TBytes);
{$ENDIF}
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
{$IFNDEF PRODUCTION}
procedure TransportSecurityTestForceSecureTransportCleanupFileFailure(
  const AEnabled: Boolean);
procedure TransportSecurityTestForceSecureTransportRecoveryUnlinkRace(
  const AEnabled: Boolean);
procedure TransportSecurityTestForceSecureTransportRecoveryDeadOwnerPID(
  const APID: LongInt);
procedure TransportSecurityTestForceSecureTransportReplacementRace(
  const AOrdinaryCleanup, ARecovery: Boolean);
procedure TransportSecurityTestForceSecureTransportImportReplacementRace(
  const ABeforeValidation, ABeforeOpen, AAfterMarkerLookup: Boolean);
procedure TransportSecurityTestForceSecureTransportBindABARace(
  const AEnabled: Boolean; const ACallsToSkip: LongInt);
procedure TransportSecurityTestForceSecureTransportFinalUnlinkReplacementRace(
  const AEnabled: Boolean);
procedure TransportSecurityTestSecureTransportReplacementRacePaths(
  out AOriginalPath, APreservedPath: string);
procedure TransportSecurityTestForceSecureTransportNetworkFetchStatus(
  const AStatus: LongInt);
procedure TransportSecurityTestForceSecureTransportTrustEvaluationFailure(
  const AEnabled: Boolean);
function TransportSecurityTestSecureTransportNetworkFetchWasDisabled: Boolean;
function TransportSecurityTestInjectSecureTransportFatalStatus(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
function TransportSecurityTestInjectSecureTransportPeerClose(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
{$ENDIF}
{$ENDIF}
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
{ Container names persisted by the most recent PKCS#12 import on this
  process, including imports that were then rejected. }
function TransportSecurityTestLastImportedKeyContainers: TUnicodeStringArray;
{ Whether a user-scope CNG key container with this name still exists. }
function TransportSecurityTestKeyContainerExists(
  const AContainerName: UnicodeString): Boolean;
{ Runs the SChannel client's trust-anchor verification on ALeaf (DER) as
  if a server had sent it together with AIntermediates (PEM or DER, may be
  empty), without a handshake. Returns '' when the peer is accepted,
  otherwise the verification error. Compiled only without PRODUCTION (test
  and development builds). Exists so the offline retrieval policy
  can be pinned without an SChannel server building its own chain. }
function TransportSecurityTestVerifyServerChain(const ALeaf,
  AIntermediates: TBytes; const AHost: string;
  const AOptions: TTransportSecurityClientOptions): string; overload;
{ As above; ARefused is True only for ETransportSecurityVerificationError. }
function TransportSecurityTestVerifyServerChain(const ALeaf,
  AIntermediates: TBytes; const AHost: string;
  const AOptions: TTransportSecurityClientOptions;
  out ARefused: Boolean): string; overload;
{ Makes the next chain evaluations fail to execute: 1 in
  CertGetCertificateChain, 2 in CertVerifyCertificateChainPolicy, 0 for
  none. }
procedure TransportSecurityTestForceSChannelChainExecutionFailure(
  const AStage: Integer);
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
  TSB_SECURE_TRANSPORT_SERVER = 6;
  OPENSSL_LOAD_ERROR = 'HTTPS requires OpenSSL but it could not be loaded';
  OPENSSL_SERVER_LOAD_ERROR =
    'TLS server accept requires OpenSSL but it could not be loaded';
  TLS_SERVER_UNSUPPORTED_ERROR = 'TLS server accept is not supported';
  TLS_HANDSHAKE_ERROR = 'TLS handshake failed';
  TLS_READ_ERROR = 'TLS read failed';
  TLS_WRITE_ERROR = 'TLS write failed';
  TLS_VERIFICATION_ERROR = 'TLS certificate verification failed';
  MAX_TRUST_ANCHOR_BYTES = 4 * 1024 * 1024;
  MAX_TRUST_ANCHORS = 1024;
  MAX_CLIENT_PKCS12_SIZE = 16 * 1024 * 1024;

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

const
  SERVER_FAILURE_REASON_CAPACITY = 480;

{ Unmanaged on purpose: FPC does not finalize managed threadvars when a
  thread exits, so a string here would leak once per connection thread that
  recorded a failure. Reasons are truncated to the fixed capacity. }
threadvar
  ServerFailureReasonText: array[0..SERVER_FAILURE_REASON_CAPACITY - 1] of
    AnsiChar;
  ServerFailureReasonLength: Integer;

procedure RecordServerFailure(const AReason: string);
var
  Encoded: AnsiString;
  Count: Integer;
begin
  Encoded := AnsiString(AReason);
  Count := Length(Encoded);
  if Count > SERVER_FAILURE_REASON_CAPACITY then
    Count := SERVER_FAILURE_REASON_CAPACITY;
  if Count > 0 then
    Move(Encoded[1], ServerFailureReasonText[0], Count);
  ServerFailureReasonLength := Count;
end;

procedure ClearServerFailure; inline;
begin
  ServerFailureReasonLength := 0;
end;

function TransportSecurityServerFailureReason: string;
var
  Text: AnsiString;
begin
  Text := '';
  if ServerFailureReasonLength > 0 then
    SetString(Text, PAnsiChar(@ServerFailureReasonText[0]),
      ServerFailureReasonLength);
  Result := string(Text);
end;

{ Client options: backend-neutral validation and trust-anchor decoding.

  Anchors arrive as PEM text or one DER certificate. PEM armour is removed
  and the base64 body decoded here; each backend then parses the DER with its
  own certificate API (d2i_X509, SecCertificateCreateWithData,
  CertAddEncodedCertificateToStore), so no certificate semantics are
  implemented in this unit. The structural DER check below only confirms one
  complete outer SEQUENCE so malformed input fails before any platform work. }

type
  TTransportSecurityCertificateList = array of TBytes;

function DefaultTransportSecurityClientOptions: TTransportSecurityClientOptions;
begin
  Result.TrustAnchors := nil;
  Result.TrustMode := tstmSystemAndAnchors;
  Result.ClientPkcs12 := nil;
  Result.ClientPkcs12Passphrase := '';
  Result.InsecureSkipVerify := False;
end;

function TransportSecurityClientOptionsAreDefault(
  const AOptions: TTransportSecurityClientOptions): Boolean;
begin
  Result := (Length(AOptions.TrustAnchors) = 0) and
    (AOptions.TrustMode = tstmSystemAndAnchors) and
    (Length(AOptions.ClientPkcs12) = 0) and
    (AOptions.ClientPkcs12Passphrase = '') and
    not AOptions.InsecureSkipVerify;
end;

function DERCertificateIsWellFormed(const ABytes: TBytes): Boolean;
var
  ContentLength: Int64;
  HeaderLength: Integer;
  I: Integer;
  LengthOctets: Integer;
begin
  Result := False;
  if (Length(ABytes) < 2) or (ABytes[0] <> $30) then
    Exit;
  if ABytes[1] < $80 then
  begin
    ContentLength := ABytes[1];
    HeaderLength := 2;
  end
  else
  begin
    LengthOctets := ABytes[1] and $7F;
    if (LengthOctets < 1) or (LengthOctets > 4) or
       (Length(ABytes) < 2 + LengthOctets) then
      Exit;
    ContentLength := 0;
    for I := 0 to LengthOctets - 1 do
      ContentLength := (ContentLength shl 8) or ABytes[2 + I];
    HeaderLength := 2 + LengthOctets;
  end;
  Result := Int64(HeaderLength) + ContentLength = Int64(Length(ABytes));
end;

function DecodeTransportSecurityBase64(const AText: AnsiString;
  out ABytes: TBytes): Boolean;
var
  Character: AnsiChar;
  I: Integer;
  OutputLength: Integer;
  Padding: Integer;
  Quad: array[0..3] of Integer;
  QuadCount: Integer;
  Value: Integer;
begin
  Result := False;
  ABytes := nil;
  SetLength(ABytes, (Length(AText) div 4) * 3 + 3);
  OutputLength := 0;
  QuadCount := 0;
  Padding := 0;
  for I := 1 to Length(AText) do
  begin
    Character := AText[I];
    case Character of
      'A'..'Z': Value := Ord(Character) - Ord('A');
      'a'..'z': Value := Ord(Character) - Ord('a') + 26;
      '0'..'9': Value := Ord(Character) - Ord('0') + 52;
      '+': Value := 62;
      '/': Value := 63;
      '=': Value := -1;
      #9, #10, #13, ' ': Continue;
    else
      Exit;
    end;
    if Value < 0 then
    begin
      { Padding may only complete the third or fourth position. }
      if QuadCount < 2 then
        Exit;
      Inc(Padding);
      Value := 0;
    end
    else if Padding > 0 then
      Exit;
    Quad[QuadCount] := Value;
    Inc(QuadCount);
    if QuadCount = 4 then
    begin
      ABytes[OutputLength] := Byte((Quad[0] shl 2) or (Quad[1] shr 4));
      Inc(OutputLength);
      if Padding < 2 then
      begin
        ABytes[OutputLength] := Byte(((Quad[1] and $0F) shl 4) or
          (Quad[2] shr 2));
        Inc(OutputLength);
      end;
      if Padding < 1 then
      begin
        ABytes[OutputLength] := Byte(((Quad[2] and $03) shl 6) or Quad[3]);
        Inc(OutputLength);
      end;
      QuadCount := 0;
    end;
  end;
  if QuadCount <> 0 then
    Exit;
  SetLength(ABytes, OutputLength);
  Result := OutputLength > 0;
end;

function FindAnsiText(const ANeedle, AHaystack: AnsiString;
  const AStart: Integer): Integer;
var
  Found: Integer;
begin
  Result := 0;
  if AStart > Length(AHaystack) then
    Exit;
  Found := Pos(ANeedle, Copy(AHaystack, AStart, MaxInt));
  if Found > 0 then
    Result := AStart + Found - 1;
end;

procedure AddUniqueCertificate(var AList: TTransportSecurityCertificateList;
  const ACertificate: TBytes);
var
  I: Integer;
begin
  for I := 0 to High(AList) do
    if (Length(AList[I]) = Length(ACertificate)) and
       (CompareByte(AList[I][0], ACertificate[0], Length(ACertificate)) = 0) then
      Exit;
  if Length(AList) >= MAX_TRUST_ANCHORS then
    raise ETransportSecurityError.CreateFmt(
      'Configured TLS trust anchors exceed the %d-certificate limit',
      [MAX_TRUST_ANCHORS]);
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := ACertificate;
end;

function ParseTransportSecurityTrustAnchors(
  const AInput: TBytes): TTransportSecurityCertificateList;
const
  PEM_BEGIN = '-----BEGIN CERTIFICATE-----';
  PEM_END = '-----END CERTIFICATE-----';
  PEM_ANY_BEGIN = '-----BEGIN ';
var
  BodyStart: Integer;
  Certificate: TBytes;
  EndMarker: Integer;
  Position: Integer;
  Text: AnsiString;
begin
  Result := nil;
  if Length(AInput) = 0 then
    Exit;
  if Length(AInput) > MAX_TRUST_ANCHOR_BYTES then
    raise ETransportSecurityError.Create(
      'Configured TLS trust anchors exceed the 4 MiB limit');
  SetString(Text, PAnsiChar(@AInput[0]), Length(AInput));
  if Pos(PEM_ANY_BEGIN, Text) = 0 then
  begin
    if not DERCertificateIsWellFormed(AInput) then
      raise ETransportSecurityError.Create(
        'Configured TLS trust anchors are neither PEM CERTIFICATE blocks nor one DER certificate');
    SetLength(Certificate, Length(AInput));
    Move(AInput[0], Certificate[0], Length(AInput));
    AddUniqueCertificate(Result, Certificate);
    Exit;
  end;
  Position := 1;
  repeat
    Position := FindAnsiText(PEM_BEGIN, Text, Position);
    if Position = 0 then
      Break;
    BodyStart := Position + Length(PEM_BEGIN);
    EndMarker := FindAnsiText(PEM_END, Text, BodyStart);
    if EndMarker = 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS trust anchors contain an unterminated PEM CERTIFICATE block');
    if not DecodeTransportSecurityBase64(
       Copy(Text, BodyStart, EndMarker - BodyStart), Certificate) or
       not DERCertificateIsWellFormed(Certificate) then
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS trust anchor %d is not a valid PEM certificate',
        [Length(Result) + 1]);
    AddUniqueCertificate(Result, Certificate);
    Position := EndMarker + Length(PEM_END);
  until False;
  if Length(Result) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS trust anchors contain no PEM CERTIFICATE block');
end;

{ Structural checks only; ValidateTransportSecurityClientOptions adds the
  platform parse of the anchors and the PKCS#12 identity. }
procedure ValidateClientOptionsStructure(
  const AOptions: TTransportSecurityClientOptions);
begin
  if (Ord(AOptions.TrustMode) < Ord(Low(TTransportSecurityTrustMode))) or
     (Ord(AOptions.TrustMode) > Ord(High(TTransportSecurityTrustMode))) then
    raise ETransportSecurityError.Create('Unknown TLS trust mode');
  if AOptions.InsecureSkipVerify and
     ((Length(AOptions.TrustAnchors) > 0) or
      (AOptions.TrustMode <> tstmSystemAndAnchors)) then
    raise ETransportSecurityError.Create(
      'TLS InsecureSkipVerify cannot be combined with trust anchors or an anchors-only trust mode');
  if (AOptions.TrustMode = tstmAnchorsOnly) and
     (Length(AOptions.TrustAnchors) = 0) then
    raise ETransportSecurityError.Create(
      'TLS anchors-only trust mode requires at least one trust anchor');
  ParseTransportSecurityTrustAnchors(AOptions.TrustAnchors);
  if (Length(AOptions.ClientPkcs12) = 0) and
     (AOptions.ClientPkcs12Passphrase <> '') then
    raise ETransportSecurityError.Create(
      'TLS client PKCS#12 passphrase requires a client identity');
  if Length(AOptions.ClientPkcs12) > MAX_CLIENT_PKCS12_SIZE then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
  if Pos(#0, AOptions.ClientPkcs12Passphrase) > 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 passphrase contains an embedded NUL');
end;

{$IFDEF DARWIN}
{$linkframework Security}
{$linkframework CoreFoundation}
{$linkframework CoreServices}

type
  OSStatus = LongInt;
  CFAllocatorRef = Pointer;
  SSLContextRef = Pointer;
  SSLConnectionRef = Pointer;
  SSLProtocolSide = Integer;
  SSLConnectionType = Integer;
  SSLProtocol = Integer;
  TSecureTransportFSRef = packed record
    Hidden: array[0..79] of Byte;
  end;

const
  ERR_SEC_SUCCESS = 0;
  ERR_SSL_WOULD_BLOCK = -9803;
  ERR_SSL_CLOSED_GRACEFUL = -9805;
  ERR_SSL_CLOSED_ABORT = -9806;
  { errSSLPeerAuthCompleted: SSLHandshake paused after the peer's certificate
    arrived because a kSSLSessionOptionBreakOn*Auth option is set. }
  ERR_SSL_PEER_AUTH_COMPLETED = -9841;
  K_SSL_SERVER_SIDE = 0;
  K_SSL_CLIENT_SIDE = 1;
  K_SSL_STREAM_TYPE = 0;
  K_TLS_PROTOCOL_12 = 8;
  K_SSL_SESSION_OPTION_BREAK_ON_SERVER_AUTH = 0;
  K_SSL_SESSION_OPTION_BREAK_ON_CLIENT_AUTH = 2;
  K_ALWAYS_AUTHENTICATE = 1;

type
  TSecureTransportServerSnapshot = class
  public
    CertificateArray: Pointer;
    Keychain: Pointer;
    KeychainFileReference: TSecureTransportFSRef;
    KeychainFileReferenceKnown: Boolean;
    KeychainPath: string;
    References: LongInt;
    constructor Create;
    procedure Retain;
    procedure Release;
  end;

  TSecureTransportData = class
  public
    Socket: TSocket;
    Context: SSLContextRef;
    WantRead: Boolean;
    WantWrite: Boolean;
    { Imported client identity (temporary keychain plus certificate array);
      nil without ClientPkcs12. }
    ClientIdentity: TSecureTransportServerSnapshot;
    { Parsed trust anchors, built before the handshake; nil without
      anchors. }
    AnchorArray: Pointer;
  end;

  TSecureTransportServerData = class
  public
    Context: SSLContextRef;
    HandshakeDone: Boolean;
    Input: TBytes;
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
    PendingPlaintextOffset: Integer;
    WriteNeedsResume: Boolean;
    Snapshot: TSecureTransportServerSnapshot;
    { Set only by the test-only client-certificate seam, together with the
      anchors the client's chain must reach. }
    RequireClientCertificate: Boolean;
    ClientAnchorArray: Pointer;
  end;

  TSecureTransportReadFunc = function(AConnection: SSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
  TSecureTransportWriteFunc = function(AConnection: SSLConnectionRef;
    AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;

  TSecureTransportServerSymbols = record
    ArrayCallbacks: Pointer;
    DictionaryKeyCallbacks: Pointer;
    DictionaryValueCallbacks: Pointer;
    ImportCertChainKey: Pointer;
    ImportIdentityKey: Pointer;
    ImportKeychainKey: Pointer;
    ImportPassphraseKey: Pointer;
  end;

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
function SSLSetCertificate(AContext: SSLContextRef;
  ACertificateArray: Pointer): OSStatus; cdecl;
  external name 'SSLSetCertificate';
function SSLHandshake(AContext: SSLContextRef): OSStatus; cdecl;
  external name 'SSLHandshake';

{ Certificate statuses Secure Transport's own evaluation ends a client
  handshake with (errSSLXCertChainInvalid, errSSLBadCert,
  errSSLUnknownRootCert, errSSLNoRootCert, errSSLCertExpired,
  errSSLCertNotYetValid, errSSLHostNameMismatch). }
function SecureTransportStatusIsVerificationFailure(const AStatus: OSStatus): Boolean;
begin
  case AStatus of
    -9807, -9808, -9812, -9813, -9814, -9815, -9843:
      Result := True;
  else
    Result := False;
  end;
end;

function SSLRead(AContext: SSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): OSStatus; cdecl;
  external name 'SSLRead';
function SSLWrite(AContext: SSLContextRef; AData: Pointer;
  ADataLength: PtrUInt; var AProcessed: PtrUInt): OSStatus; cdecl;
  external name 'SSLWrite';
function SSLClose(AContext: SSLContextRef): OSStatus; cdecl;
  external name 'SSLClose';
function SSLSetSessionOption(AContext: SSLContextRef; AOption: Integer;
  AValue: ByteBool): OSStatus; cdecl; external name 'SSLSetSessionOption';
function SSLSetClientSideAuthenticate(AContext: SSLContextRef;
  AAuthenticate: Integer): OSStatus; cdecl;
  external name 'SSLSetClientSideAuthenticate';
function SSLCopyPeerTrust(AContext: SSLContextRef;
  out ATrust: Pointer): OSStatus; cdecl; external name 'SSLCopyPeerTrust';
function SecTrustSetPolicies(ATrust, APolicies: Pointer): OSStatus; cdecl;
  external name 'SecTrustSetPolicies';
function SecTrustGetCertificateCount(ATrust: Pointer): NativeInt; cdecl;
  external name 'SecTrustGetCertificateCount';
function SecTrustGetCertificateAtIndex(ATrust: Pointer;
  AIndex: NativeInt): Pointer; cdecl;
  external name 'SecTrustGetCertificateAtIndex';
function SecCertificateCreateWithData(AAllocator, AData: Pointer): Pointer;
  cdecl; external name 'SecCertificateCreateWithData';
function SecCertificateCopyData(ACertificate: Pointer): Pointer; cdecl;
  external name 'SecCertificateCopyData';
function CFDataGetBytePtr(AData: Pointer): PByte; cdecl;
  external name 'CFDataGetBytePtr';
function CFDataGetLength(AData: Pointer): NativeInt; cdecl;
  external name 'CFDataGetLength';
function CFErrorGetCode(AError: Pointer): NativeInt; cdecl;
  external name 'CFErrorGetCode';
procedure CFRelease(ARef: Pointer); cdecl; external name 'CFRelease';
function CFArrayCreate(AAllocator, AValues: Pointer; ACount: NativeInt;
  ACallbacks: Pointer): Pointer; cdecl; external name 'CFArrayCreate';
function CFArrayGetCount(AArray: Pointer): NativeInt; cdecl;
  external name 'CFArrayGetCount';
function CFArrayGetValueAtIndex(AArray: Pointer;
  AIndex: NativeInt): Pointer; cdecl; external name 'CFArrayGetValueAtIndex';
function CFDataCreate(AAllocator, ABytes: Pointer;
  ALength: NativeInt): Pointer; cdecl; external name 'CFDataCreate';
function CFDictionaryCreate(AAllocator: Pointer; AKeys, AValues: PPointer;
  ACount: NativeInt; AKeyCallbacks, AValueCallbacks: Pointer): Pointer; cdecl;
  external name 'CFDictionaryCreate';
function CFDictionaryGetValue(ADictionary, AKey: Pointer): Pointer; cdecl;
  external name 'CFDictionaryGetValue';
function CFStringCreateWithCString(AAllocator: Pointer; AString: PAnsiChar;
  AEncoding: UInt32): Pointer; cdecl;
  external name 'CFStringCreateWithCString';
function SecKeychainCreate(APath: PAnsiChar; APassphraseLength: UInt32;
  APassphrase: Pointer; APromptUser: ByteBool; AInitialAccess: Pointer;
  out AKeychain: Pointer): OSStatus; cdecl; external name 'SecKeychainCreate';
function SecKeychainOpen(APath: PAnsiChar; out AKeychain: Pointer): OSStatus;
  cdecl; external name 'SecKeychainOpen';
function SecKeychainAddGenericPassword(AKeychain: Pointer;
  AServiceNameLength: UInt32; AServiceName: PAnsiChar;
  AAccountNameLength: UInt32; AAccountName: PAnsiChar;
  APasswordLength: UInt32; APasswordData: Pointer;
  AItem: PPointer): OSStatus; cdecl;
  external name 'SecKeychainAddGenericPassword';
function SecKeychainFindGenericPassword(AKeychainOrArray: Pointer;
  AServiceNameLength: UInt32; AServiceName: PAnsiChar;
  AAccountNameLength: UInt32; AAccountName: PAnsiChar;
  APasswordLength: PUInt32; APasswordData: PPointer;
  out AItem: Pointer): OSStatus; cdecl;
  external name 'SecKeychainFindGenericPassword';
function SecPKCS12Import(AData, AOptions: Pointer;
  AItems: PPointer): OSStatus; cdecl; external name 'SecPKCS12Import';
function SecPolicyCreateSSL(AServer: ByteBool; AHostname: Pointer): Pointer;
  cdecl; external name 'SecPolicyCreateSSL';
function SecRandomCopyBytes(ARandom: Pointer; ACount: NativeUInt;
  ABytes: Pointer): OSStatus; cdecl; external name 'SecRandomCopyBytes';
function SecTrustCreateWithCertificates(ACertificates, APolicies: Pointer;
  out ATrust: Pointer): OSStatus; cdecl;
  external name 'SecTrustCreateWithCertificates';
function SecTrustEvaluateWithError(ATrust: Pointer;
  out AError: Pointer): ByteBool; cdecl;
  external name 'SecTrustEvaluateWithError';
function SecTrustSetAnchorCertificates(ATrust, AAnchors: Pointer): OSStatus;
  cdecl; external name 'SecTrustSetAnchorCertificates';
function SecTrustSetAnchorCertificatesOnly(ATrust: Pointer;
  AAnchorCertificatesOnly: ByteBool): OSStatus; cdecl;
  external name 'SecTrustSetAnchorCertificatesOnly';
function SecTrustSetNetworkFetchAllowed(ATrust: Pointer;
  AAllowFetch: ByteBool): OSStatus; cdecl;
  external name 'SecTrustSetNetworkFetchAllowed';
function Dlsym(AHandle: Pointer; AName: PAnsiChar): Pointer; cdecl;
  external name 'dlsym';
function RenameAtXNP(AFromFD: LongInt; AFromPath: PAnsiChar;
  AToFD: LongInt; AToPath: PAnsiChar; AFlags: UInt32): LongInt; cdecl;
  external name 'renameatx_np';
function FSPathMakeRefWithOptions(APath: PByte; AOptions: UInt32;
  ARef: Pointer; AIsDirectory: PByte): OSStatus; cdecl;
  external name 'FSPathMakeRefWithOptions';
function FSRefMakePath(const ARef: Pointer; APath: PByte;
  APathBufferSize: UInt32): OSStatus; cdecl; external name 'FSRefMakePath';
function FSCompareFSRefs(const AFirst, ASecond: Pointer): SmallInt; cdecl;
  external name 'FSCompareFSRefs';
function FSUnlinkObject(const ARef: Pointer): SmallInt; cdecl;
  external name 'FSUnlinkObject';

const
  CF_STRING_ENCODING_UTF8 = $08000100;
  MAX_SECURE_TRANSPORT_KEYCHAIN_RECOVERY_FILES = 128;
  SECURE_TRANSPORT_KEYCHAIN_RANDOM_BYTES = 16;
  SECURE_TRANSPORT_KEYCHAIN_PREFIX = 'secure-transport-server-';
  SECURE_TRANSPORT_O_NOFOLLOW = $00000100;
  SECURE_TRANSPORT_RENAME_EXCLUSIVE = $00000004;
  SECURE_TRANSPORT_CURRENT_WORKING_DIRECTORY_FD = -2;
  SECURE_TRANSPORT_FSREF_NOFOLLOW = $00000001;
  SECURE_TRANSPORT_FSREF_PATH_CAPACITY = 4096;
  RTLD_DEFAULT = Pointer(-2);

var
  SecureTransportServerSymbolLock: TRTLCriticalSection;
  SecureTransportServerSymbols: TSecureTransportServerSymbols;
  SecureTransportServerSymbolsReady: Boolean;
  {$IFNDEF PRODUCTION}
  SecureTransportTestCleanupFileFailure: Boolean;
  SecureTransportTestTrustEvaluationFailure: Boolean;
  SecureTransportTestRecoveryUnlinkRace: Boolean;
  SecureTransportTestRecoveryDeadOwnerPID: LongInt;
  SecureTransportTestOrdinaryReplacementRace: Boolean;
  SecureTransportTestRecoveryReplacementRace: Boolean;
  SecureTransportTestImportReplacementRaceBeforeValidation: Boolean;
  SecureTransportTestImportReplacementRaceBeforeOpen: Boolean;
  SecureTransportTestImportReplacementRaceAfterMarkerLookup: Boolean;
  SecureTransportTestBindABARace: Boolean;
  SecureTransportTestBindABACallsToSkip: LongInt;
  SecureTransportTestFinalUnlinkReplacementRace: Boolean;
  SecureTransportTestReplacementOriginalPath: string;
  SecureTransportTestReplacementPreservedPath: string;
  SecureTransportTestNetworkFetchStatus: OSStatus;
  SecureTransportTestNetworkFetchCalled: Boolean;
  {$ENDIF}

procedure ResolveSecureTransportServerSymbols;
var
  Resolved: TSecureTransportServerSymbols;

  function ResolveConstant(const AName: PAnsiChar): Pointer;
  var
    Symbol: Pointer;
  begin
    Symbol := Dlsym(RTLD_DEFAULT, AName);
    if Symbol = nil then
      raise ETransportSecurityError.Create(
        'Security.framework is missing a required public TLS symbol');
    Result := PPointer(Symbol)^;
  end;
begin
  EnterCriticalSection(SecureTransportServerSymbolLock);
  try
    if SecureTransportServerSymbolsReady then Exit;
    FillChar(Resolved, SizeOf(Resolved), 0);
    Resolved.ImportPassphraseKey := ResolveConstant(
      'kSecImportExportPassphrase');
    Resolved.ImportKeychainKey := ResolveConstant(
      'kSecImportExportKeychain');
    Resolved.ImportIdentityKey := ResolveConstant(
      'kSecImportItemIdentity');
    Resolved.ImportCertChainKey := ResolveConstant(
      'kSecImportItemCertChain');
    Resolved.ArrayCallbacks := Dlsym(RTLD_DEFAULT,
      'kCFTypeArrayCallBacks');
    Resolved.DictionaryKeyCallbacks := Dlsym(RTLD_DEFAULT,
      'kCFTypeDictionaryKeyCallBacks');
    Resolved.DictionaryValueCallbacks := Dlsym(RTLD_DEFAULT,
      'kCFTypeDictionaryValueCallBacks');
    if (Resolved.ArrayCallbacks = nil)
      or (Resolved.DictionaryKeyCallbacks = nil)
      or (Resolved.DictionaryValueCallbacks = nil) then
      raise ETransportSecurityError.Create(
        'CoreFoundation is missing required public collection callbacks');
    SecureTransportServerSymbols := Resolved;
    SecureTransportServerSymbolsReady := True;
  finally
    LeaveCriticalSection(SecureTransportServerSymbolLock);
  end;
end;

constructor TSecureTransportServerSnapshot.Create;
begin
  inherited Create;
  References := 1;
end;

procedure TSecureTransportServerSnapshot.Retain;
begin
  InterlockedIncrement(References);
end;

procedure HandleSecureTransportKeychainCleanupFailure(
  const AMessage: string; const APrimaryExceptionActive: Boolean);
begin
  if AMessage = '' then Exit;
  if APrimaryExceptionActive then
  begin
    try
      WriteLn(StdErr,
        'TLS cleanup: temporary Secure Transport keychain cleanup failed');
    except
      { Reporting is best-effort and must not replace the primary failure. }
    end;
    Exit;
  end;
  raise ETransportSecurityError.Create(AMessage);
end;

function UnlinkSecureTransportKeychainFile(
  const AFileReference: TSecureTransportFSRef): Boolean;
begin
  {$IFNDEF PRODUCTION}
  if SecureTransportTestCleanupFileFailure then Exit(False);
  {$ENDIF}
  Result := FSUnlinkObject(@AFileReference) = ERR_SEC_SUCCESS;
end;

function SecureTransportRandomHex: AnsiString; forward;
function TrySecureTransportKeychainOwnerPID(const AName: string;
  out APID: LongInt): Boolean; forward;

function SecureTransportFileIdentityMatches(const AStatus: BaseUnix.Stat;
  const AExpectedDevice, AExpectedInode: QWord): Boolean; inline;
begin
  Result := ((AStatus.st_mode and S_IFMT) = S_IFREG)
    and (AStatus.st_uid = FpGetUID)
    and (QWord(AStatus.st_dev) = AExpectedDevice)
    and (QWord(AStatus.st_ino) = AExpectedInode);
end;

function RenameSecureTransportFileExclusive(const AFromPath,
  AToPath: string): Boolean;
var
  EncodedFromPath, EncodedToPath: AnsiString;
begin
  EncodedFromPath := AnsiString(AFromPath);
  EncodedToPath := AnsiString(AToPath);
  Result := RenameAtXNP(SECURE_TRANSPORT_CURRENT_WORKING_DIRECTORY_FD,
    PAnsiChar(EncodedFromPath), SECURE_TRANSPORT_CURRENT_WORKING_DIRECTORY_FD,
    PAnsiChar(EncodedToPath), SECURE_TRANSPORT_RENAME_EXCLUSIVE) = 0;
end;

function SecureTransportQuarantinePath(const APath: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFileDir(APath))
    + SECURE_TRANSPORT_KEYCHAIN_PREFIX + IntToStr(GetProcessID) + '-'
    + string(SecureTransportRandomHex) + '.keychain';
end;

function RestoreOrPreserveSecureTransportQuarantine(const AQuarantinePath,
  AOriginalPath: string): Boolean;
var
  PreservedPath: string;
begin
  if RenameSecureTransportFileExclusive(AQuarantinePath, AOriginalPath) then
    Exit(True);
  PreservedPath := AQuarantinePath + '.preserved-'
    + string(SecureTransportRandomHex);
  Result := RenameSecureTransportFileExclusive(AQuarantinePath,
    PreservedPath);
end;

{$IFNDEF PRODUCTION}
procedure InjectSecureTransportReplacementRace(const APath: string);
var
  ByteValue: Byte;
  Descriptor: LongInt;
  PreservedPath: string;
begin
  PreservedPath := APath + '.preserved-' + string(SecureTransportRandomHex);
  if not RenameSecureTransportFileExclusive(APath, PreservedPath) then
    raise ETransportSecurityError.Create(
      'Could not prepare temporary TLS keychain replacement-race fixture');
  Descriptor := FpOpen(PChar(APath), O_WRONLY or O_CREAT or O_EXCL or
    SECURE_TRANSPORT_O_NOFOLLOW, S_IRUSR or S_IWUSR);
  if Descriptor < 0 then
  begin
    RenameSecureTransportFileExclusive(PreservedPath, APath);
    raise ETransportSecurityError.Create(
      'Could not create temporary TLS keychain replacement-race fixture');
  end;
  try
    ByteValue := $a5;
    if FpWrite(Descriptor, ByteValue, SizeOf(ByteValue)) <> SizeOf(ByteValue)
      then
      raise ETransportSecurityError.Create(
        'Could not write temporary TLS keychain replacement-race fixture');
  finally
    FpClose(Descriptor);
  end;
  SecureTransportTestReplacementOriginalPath := APath;
  SecureTransportTestReplacementPreservedPath := PreservedPath;
end;

procedure InjectSecureTransportBindABARaceBeforeCapture(const APath: string);
begin
  InjectSecureTransportReplacementRace(APath);
end;

procedure RestoreSecureTransportBindABARaceAfterCapture(const APath: string);
var
  PreservedPath: string;
begin
  PreservedPath := SecureTransportTestReplacementPreservedPath;
  if (PreservedPath = '') or not SysUtils.DeleteFile(APath)
    or not RenameSecureTransportFileExclusive(PreservedPath, APath) then
    raise ETransportSecurityError.Create(
      'Could not restore temporary TLS keychain bind-ABA fixture');
end;
{$ENDIF}

function SecureTransportFileReferenceIdentityMatches(
  const AFileReference: TSecureTransportFSRef;
  const AExpectedDevice, AExpectedInode: QWord): Boolean;
var
  EncodedResolvedPath: AnsiString;
  FirstStatus, SecondStatus: BaseUnix.Stat;
  PathBuffer: array[0..SECURE_TRANSPORT_FSREF_PATH_CAPACITY - 1] of Byte;
  VerificationReference: TSecureTransportFSRef;
begin
  Result := False;
  FillChar(PathBuffer, SizeOf(PathBuffer), 0);
  if FSRefMakePath(@AFileReference, @PathBuffer[0], SizeOf(PathBuffer))
    <> ERR_SEC_SUCCESS then Exit;
  EncodedResolvedPath := AnsiString(PAnsiChar(@PathBuffer[0]));
  if (EncodedResolvedPath = '')
    or (FpLStat(PChar(EncodedResolvedPath), FirstStatus) <> 0)
    or not SecureTransportFileIdentityMatches(FirstStatus,
      AExpectedDevice, AExpectedInode) then Exit;
  FillChar(VerificationReference, SizeOf(VerificationReference), 0);
  if FSPathMakeRefWithOptions(PByte(PAnsiChar(EncodedResolvedPath)),
    SECURE_TRANSPORT_FSREF_NOFOLLOW, @VerificationReference, nil)
    <> ERR_SEC_SUCCESS then Exit;
  if FSCompareFSRefs(@AFileReference, @VerificationReference)
    <> ERR_SEC_SUCCESS then Exit;
  Result := (FpLStat(PChar(EncodedResolvedPath), SecondStatus) = 0)
    and SecureTransportFileIdentityMatches(SecondStatus,
      AExpectedDevice, AExpectedInode);
end;

function BindSecureTransportFileReference(const APath: string;
  const AExpectedDevice, AExpectedInode: QWord;
  out AFileReference: TSecureTransportFSRef): Boolean;
var
  EncodedPath: AnsiString;
  InjectABARace: Boolean;
begin
  FillChar(AFileReference, SizeOf(AFileReference), 0);
  EncodedPath := AnsiString(APath);
  InjectABARace := False;
  {$IFNDEF PRODUCTION}
  if SecureTransportTestBindABARace then
  begin
    if SecureTransportTestBindABACallsToSkip > 0 then
      Dec(SecureTransportTestBindABACallsToSkip)
    else
    begin
      SecureTransportTestBindABARace := False;
      InjectABARace := True;
      InjectSecureTransportBindABARaceBeforeCapture(APath);
    end;
  end;
  {$ENDIF}
  Result := FSPathMakeRefWithOptions(PByte(PAnsiChar(EncodedPath)),
    SECURE_TRANSPORT_FSREF_NOFOLLOW, @AFileReference, nil)
    = ERR_SEC_SUCCESS;
  {$IFNDEF PRODUCTION}
  if InjectABARace then
    RestoreSecureTransportBindABARaceAfterCapture(APath);
  {$ENDIF}
  if Result then
    Result := SecureTransportFileReferenceIdentityMatches(AFileReference,
      AExpectedDevice, AExpectedInode);
end;

function ValidateImportedSecureTransportKeychainIdentity(
  const AMarkerService, AMarkerAccount: AnsiString; var APath: string;
  out ADevice, AInode: QWord;
  var AFileReference: TSecureTransportFSRef;
  var AFileReferenceKnown: Boolean): Boolean;
var
  EncodedPath: AnsiString;
  FirstStatus, SecondStatus: BaseUnix.Stat;
  ImportedFileReference: TSecureTransportFSRef;
  MarkerItem: Pointer;
  QuarantinePath: string;
  QuarantineOwned: Boolean;
  ReopenedKeychain: Pointer;
begin
  Result := False;
  QuarantineOwned := False;
  ADevice := 0;
  AInode := 0;
  {$IFNDEF PRODUCTION}
  if SecureTransportTestImportReplacementRaceBeforeValidation then
    InjectSecureTransportReplacementRace(APath);
  {$ENDIF}
  if (FpLStat(PChar(APath), FirstStatus) <> 0)
    or ((FirstStatus.st_mode and S_IFMT) <> S_IFREG)
    or (FirstStatus.st_uid <> FpGetUID) then Exit;
  QuarantinePath := SecureTransportQuarantinePath(APath);
  if not RenameSecureTransportFileExclusive(APath, QuarantinePath) then Exit;
  QuarantineOwned := True;
  try
    if (FpLStat(PChar(QuarantinePath), FirstStatus) <> 0)
      or ((FirstStatus.st_mode and S_IFMT) <> S_IFREG)
      or (FirstStatus.st_uid <> FpGetUID) then Exit;
    if not BindSecureTransportFileReference(QuarantinePath,
      QWord(FirstStatus.st_dev), QWord(FirstStatus.st_ino),
      ImportedFileReference) then Exit;
    {$IFNDEF PRODUCTION}
    if SecureTransportTestImportReplacementRaceBeforeOpen then
      InjectSecureTransportReplacementRace(QuarantinePath);
    {$ENDIF}
    EncodedPath := AnsiString(QuarantinePath);
    MarkerItem := nil;
    ReopenedKeychain := nil;
    if (SecKeychainOpen(PAnsiChar(EncodedPath), ReopenedKeychain)
      <> ERR_SEC_SUCCESS) or (ReopenedKeychain = nil) then Exit;
    try
      if (SecKeychainFindGenericPassword(ReopenedKeychain,
        Length(AMarkerService), PAnsiChar(AMarkerService),
        Length(AMarkerAccount), PAnsiChar(AMarkerAccount), nil, nil,
        MarkerItem) <> ERR_SEC_SUCCESS) or (MarkerItem = nil) then Exit;
      {$IFNDEF PRODUCTION}
      if SecureTransportTestImportReplacementRaceAfterMarkerLookup then
        InjectSecureTransportReplacementRace(QuarantinePath);
      {$ENDIF}
      if (FpLStat(PChar(QuarantinePath), SecondStatus) <> 0)
        or not SecureTransportFileIdentityMatches(SecondStatus,
          QWord(FirstStatus.st_dev), QWord(FirstStatus.st_ino)) then Exit;
      ADevice := QWord(FirstStatus.st_dev);
      AInode := QWord(FirstStatus.st_ino);
      AFileReference := ImportedFileReference;
      AFileReferenceKnown := True;
      APath := QuarantinePath;
      QuarantineOwned := False;
      Result := True;
    finally
      if MarkerItem <> nil then CFRelease(MarkerItem);
      CFRelease(ReopenedKeychain);
    end;
  finally
    if QuarantineOwned then
    begin
      if RestoreOrPreserveSecureTransportQuarantine(QuarantinePath, APath)
        then
      begin
        {$IFNDEF PRODUCTION}
        if SecureTransportTestReplacementOriginalPath = QuarantinePath then
          SecureTransportTestReplacementOriginalPath := APath;
        {$ENDIF}
      end;
    end;
  end;
end;

function QuarantineAndRemoveSecureTransportFile(const APath: string;
  const AExpectedDevice, AExpectedInode: QWord;
  const AInjectReplacementRace: Boolean; out AFailure: string): Boolean;
var
  FileReference: TSecureTransportFSRef;
  QuarantinePath: string;
  Status: BaseUnix.Stat;
begin
  Result := False;
  AFailure := '';
  if FpLStat(PChar(APath), Status) <> 0 then
  begin
    if FpGetErrNo = ESysENOENT then Exit(True);
    AFailure := 'Failed to inspect temporary TLS keychain storage';
    Exit;
  end;
  if not SecureTransportFileIdentityMatches(Status, AExpectedDevice,
    AExpectedInode) then
  begin
    AFailure := 'Temporary TLS keychain storage changed identity, ownership, or type';
    Exit;
  end;
  {$IFNDEF PRODUCTION}
  if AInjectReplacementRace then InjectSecureTransportReplacementRace(APath);
  {$ENDIF}
  QuarantinePath := SecureTransportQuarantinePath(APath);
  if not RenameSecureTransportFileExclusive(APath, QuarantinePath) then
  begin
    if FpGetErrNo = ESysENOENT then Exit(True);
    AFailure := 'Failed to quarantine temporary TLS keychain storage';
    Exit;
  end;
  if (FpLStat(PChar(QuarantinePath), Status) <> 0)
    or not SecureTransportFileIdentityMatches(Status, AExpectedDevice,
      AExpectedInode) then
  begin
    if not RestoreOrPreserveSecureTransportQuarantine(QuarantinePath,
      APath) then
      AFailure := 'Temporary TLS keychain replacement could not be restored'
    else
      AFailure := 'Temporary TLS keychain storage changed identity during cleanup';
    Exit;
  end;
  FillChar(FileReference, SizeOf(FileReference), 0);
  if not BindSecureTransportFileReference(QuarantinePath,
    AExpectedDevice, AExpectedInode, FileReference) then
  begin
    RestoreOrPreserveSecureTransportQuarantine(QuarantinePath, APath);
    AFailure := 'Failed to bind temporary TLS keychain cleanup identity';
    Exit;
  end;
  {$IFNDEF PRODUCTION}
  if SecureTransportTestFinalUnlinkReplacementRace then
    InjectSecureTransportReplacementRace(QuarantinePath);
  {$ENDIF}
  if not UnlinkSecureTransportKeychainFile(FileReference) then
  begin
    RestoreOrPreserveSecureTransportQuarantine(QuarantinePath, APath);
    AFailure := 'Failed to remove quarantined temporary TLS keychain storage';
    Exit;
  end;
  if (FpLStat(PChar(QuarantinePath), Status) = 0)
    or (FpGetErrNo <> ESysENOENT) then
  begin
    RestoreOrPreserveSecureTransportQuarantine(QuarantinePath, APath);
    {$IFNDEF PRODUCTION}
    if SecureTransportTestFinalUnlinkReplacementRace then
      SecureTransportTestReplacementOriginalPath := APath;
    {$ENDIF}
    AFailure := 'Temporary TLS keychain storage survived quarantine cleanup';
    Exit;
  end;
  if FpLStat(PChar(APath), Status) = 0 then
  begin
    AFailure := 'Temporary TLS keychain pathname was replaced during cleanup';
    Exit;
  end;
  if FpGetErrNo <> ESysENOENT then
  begin
    AFailure := 'Failed to verify temporary TLS keychain pathname cleanup';
    Exit;
  end;
  Result := True;
end;

procedure CleanupSecureTransportKeychain(var AKeychain: Pointer;
  var APath: string; const AFileReference: TSecureTransportFSRef;
  const AFileReferenceKnown, APrimaryExceptionActive: Boolean);
var
  CleanupFailure: string;
  Status: BaseUnix.Stat;
begin
  CleanupFailure := '';
  if APath <> '' then
  begin
    if not AFileReferenceKnown then
      CleanupFailure :=
        'Temporary TLS keychain storage identity is unavailable'
    else
    begin
      {$IFNDEF PRODUCTION}
      if SecureTransportTestOrdinaryReplacementRace then
        InjectSecureTransportReplacementRace(APath);
      {$ENDIF}
      if not UnlinkSecureTransportKeychainFile(AFileReference) then
        CleanupFailure :=
          'Failed to remove identity-bound temporary TLS keychain storage';
    end;
  end;
  if AKeychain <> nil then
  begin
    CFRelease(AKeychain);
    AKeychain := nil;
  end;
  if (APath <> '') and (CleanupFailure = '') then
  begin
    if FpLStat(PChar(APath), Status) = 0 then
      CleanupFailure :=
        'Temporary TLS keychain pathname was replaced during cleanup'
    else if FpGetErrNo = ESysENOENT then
      APath := ''
    else
      CleanupFailure :=
        'Failed to verify temporary TLS keychain pathname cleanup';
  end;
  HandleSecureTransportKeychainCleanupFailure(CleanupFailure,
    APrimaryExceptionActive);
end;

procedure TSecureTransportServerSnapshot.Release;
begin
  if InterlockedDecrement(References) <> 0 then
    Exit;
  if CertificateArray <> nil then
    CFRelease(CertificateArray);
  CertificateArray := nil;
  try
    CleanupSecureTransportKeychain(Keychain, KeychainPath,
      KeychainFileReference, KeychainFileReferenceKnown,
      ExceptObject <> nil);
  finally
    Free;
  end;
end;

function SecureTransportRandomHex: AnsiString;
const
  HEX = '0123456789abcdef';
var
  Bytes: array[0..SECURE_TRANSPORT_KEYCHAIN_RANDOM_BYTES - 1] of Byte;
  Index: Integer;
begin
  FillChar(Bytes, SizeOf(Bytes), 0);
  if SecRandomCopyBytes(nil, SizeOf(Bytes), @Bytes[0]) <> ERR_SEC_SUCCESS then
    raise ETransportSecurityError.Create(
      'Failed to obtain secure temporary keychain material');
  SetLength(Result, SizeOf(Bytes) * 2);
  for Index := Low(Bytes) to High(Bytes) do
  begin
    Result[Index * 2 + 1] := HEX[(Bytes[Index] shr 4) + 1];
    Result[Index * 2 + 2] := HEX[(Bytes[Index] and $0f) + 1];
  end;
  FillChar(Bytes, SizeOf(Bytes), 0);
end;

function TrySecureTransportKeychainOwnerPID(const AName: string;
  out APID: LongInt): Boolean;
const
  SUFFIX = '.keychain';
var
  Character: Char;
  Index: Integer;
  Nonce, Owner, Tail: string;
begin
  Result := False;
  APID := 0;
  if Length(AName) <= Length(SECURE_TRANSPORT_KEYCHAIN_PREFIX)
    + Length(SUFFIX) then
    Exit;
  if Copy(AName, 1, Length(SECURE_TRANSPORT_KEYCHAIN_PREFIX))
    <> SECURE_TRANSPORT_KEYCHAIN_PREFIX then
    Exit;
  if Copy(AName, Length(AName) - Length(SUFFIX) + 1,
    Length(SUFFIX)) <> SUFFIX then
    Exit;
  Tail := Copy(AName, Length(SECURE_TRANSPORT_KEYCHAIN_PREFIX) + 1,
    Length(AName) - Length(SECURE_TRANSPORT_KEYCHAIN_PREFIX)
    - Length(SUFFIX));
  Index := Pos('-', Tail);
  if Index <= 1 then Exit;
  Owner := Copy(Tail, 1, Index - 1);
  Nonce := Copy(Tail, Index + 1, MaxInt);
  if Length(Nonce) <> SECURE_TRANSPORT_KEYCHAIN_RANDOM_BYTES * 2 then Exit;
  for Character in Owner do
    if not (Character in ['0'..'9']) then Exit;
  for Character in Nonce do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit;
  if not TryStrToInt(Owner, APID) or (APID <= 0) then Exit;
  Result := True;
end;

function SecureTransportOwnerIsDefinitelyDead(const APID: LongInt): Boolean;
begin
  {$IFNDEF PRODUCTION}
  if (SecureTransportTestRecoveryDeadOwnerPID > 0)
    and (APID = SecureTransportTestRecoveryDeadOwnerPID) then
    Exit(True);
  {$ENDIF}
  if FpKill(APID, 0) = 0 then Exit(False);
  Result := FpGetErrNo = ESysESRCH;
end;

procedure ReconcileAbandonedSecureTransportKeychains;
var
  Failure: string;
  Inspected: Integer;
  OwnerPID: LongInt;
  Path, Pattern: string;
  Search: TSearchRec;
  Status: BaseUnix.Stat;
begin
  Inspected := 0;
  Pattern := IncludeTrailingPathDelimiter(GetTempDir)
    + SECURE_TRANSPORT_KEYCHAIN_PREFIX + '*.keychain';
  if FindFirst(Pattern, faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      Inc(Inspected);
      if Inspected > MAX_SECURE_TRANSPORT_KEYCHAIN_RECOVERY_FILES then
        raise ETransportSecurityError.Create(
          'Temporary TLS keychain recovery limit exceeded');
      if not TrySecureTransportKeychainOwnerPID(Search.Name, OwnerPID) then
        Continue;
      Path := IncludeTrailingPathDelimiter(GetTempDir) + Search.Name;
      if (FpLStat(PChar(Path), Status) <> 0)
        or ((Status.st_mode and S_IFMT) <> S_IFREG)
        or (Status.st_uid <> FpGetUID) then
        Continue;
      if not SecureTransportOwnerIsDefinitelyDead(OwnerPID) then Continue;
      {$IFNDEF PRODUCTION}
      if SecureTransportTestRecoveryUnlinkRace then
      begin
        SecureTransportTestRecoveryUnlinkRace := False;
        SysUtils.DeleteFile(Path);
      end;
      {$ENDIF}
      if not QuarantineAndRemoveSecureTransportFile(Path,
        QWord(Status.st_dev), QWord(Status.st_ino),
        {$IFNDEF PRODUCTION}SecureTransportTestRecoveryReplacementRace{$ELSE}False{$ENDIF},
        Failure) then
        raise ETransportSecurityError.Create(
          'Failed to recover abandoned temporary TLS keychain storage: '
          + Failure);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure ValidateSecureTransportServerIdentity(const AChain: Pointer);
var
  Anchor, Anchors, ErrorReference, Policy, Trust: Pointer;
  Status: OSStatus;
begin
  if (AChain = nil) or (CFArrayGetCount(AChain) < 2) then
    raise ETransportSecurityError.Create(
      'Configured TLS identity must contain a non-self-signed certificate chain');
  Anchor := CFArrayGetValueAtIndex(AChain, CFArrayGetCount(AChain) - 1);
  Anchors := CFArrayCreate(nil, @Anchor, 1,
    SecureTransportServerSymbols.ArrayCallbacks);
  Policy := SecPolicyCreateSSL(True, nil);
  Trust := nil;
  ErrorReference := nil;
  try
    Status := SecTrustCreateWithCertificates(AChain, Policy, Trust);
    if (Status <> ERR_SEC_SUCCESS) or (Trust = nil) then
      raise ETransportSecurityError.Create(
        'Configured TLS identity does not form a valid bundled server chain');
    Status := SecTrustSetNetworkFetchAllowed(Trust, False);
    {$IFNDEF PRODUCTION}
    SecureTransportTestNetworkFetchCalled := True;
    if SecureTransportTestNetworkFetchStatus <> ERR_SEC_SUCCESS then
      Status := SecureTransportTestNetworkFetchStatus;
    {$ENDIF}
    if (Status <> ERR_SEC_SUCCESS)
      or (SecTrustSetAnchorCertificates(Trust, Anchors) <> ERR_SEC_SUCCESS)
      or (SecTrustSetAnchorCertificatesOnly(Trust, True)
        <> ERR_SEC_SUCCESS)
      or not SecTrustEvaluateWithError(Trust, ErrorReference)
      {$IFNDEF PRODUCTION}
      or SecureTransportTestTrustEvaluationFailure
      {$ENDIF}
      then
      raise ETransportSecurityError.Create(
        'Configured TLS identity does not form a valid bundled server chain');
  finally
    if ErrorReference <> nil then
      CFRelease(ErrorReference);
    if Trust <> nil then
      CFRelease(Trust);
    if Policy <> nil then
      CFRelease(Policy);
    if Anchors <> nil then
      CFRelease(Anchors);
  end;
end;

function CreateSecureTransportServerSnapshot(
  const APkcs12Identity: TBytes;
  const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation):
  TSecureTransportServerSnapshot;
var
  CertificateChain, CFData, CFOptions, CFPassphrase, Identity, Item,
    Items, Keychain: Pointer;
  CertificateCount, Index: NativeInt;
  CertificateValues: array of Pointer;
  EncodedKeychainPath, EncodedPassphrase, KeychainPassphrase: AnsiString;
  MarkerAccount, MarkerService: AnsiString;
  KeychainPath: string;
  KeychainDevice, KeychainInode: QWord;
  KeychainFileReference: TSecureTransportFSRef;
  KeychainFileReferenceKnown: Boolean;
  KeychainStatus: BaseUnix.Stat;
  IdentityBytes: TBytes;
  Keys, Values: array[0..1] of Pointer;
  Status: OSStatus;
begin
  Result := nil;
  if Length(APkcs12Identity) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity is empty');
  if Length(APkcs12Identity) > 16 * 1024 * 1024 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity exceeds the 16 MiB limit');
  if Pos(#0, APkcs12Passphrase) > 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 passphrase contains an embedded NUL');
  ResolveSecureTransportServerSymbols;
  CertificateChain := nil;
  CFData := nil;
  CFOptions := nil;
  CFPassphrase := nil;
  Identity := nil;
  Items := nil;
  Keychain := nil;
  KeychainDevice := 0;
  FillChar(KeychainFileReference, SizeOf(KeychainFileReference), 0);
  KeychainFileReferenceKnown := False;
  KeychainInode := 0;
  EncodedKeychainPath := '';
  EncodedPassphrase := '';
  KeychainPassphrase := '';
  MarkerAccount := '';
  MarkerService := '';
  KeychainPath := '';
  SetLength(IdentityBytes, Length(APkcs12Identity));
  Move(APkcs12Identity[0], IdentityBytes[0], Length(IdentityBytes));
  try
    ReconcileAbandonedSecureTransportKeychains;
    KeychainPath := IncludeTrailingPathDelimiter(GetTempDir)
      + SECURE_TRANSPORT_KEYCHAIN_PREFIX + IntToStr(GetProcessID) + '-'
      + string(SecureTransportRandomHex) + '.keychain';
    if FileExists(KeychainPath) then
      raise ETransportSecurityError.Create(
        'Temporary TLS keychain path already exists');
    EncodedKeychainPath := AnsiString(KeychainPath);
    KeychainPassphrase := SecureTransportRandomHex;
    Status := SecKeychainCreate(PAnsiChar(EncodedKeychainPath),
      Length(KeychainPassphrase), PAnsiChar(KeychainPassphrase), False, nil,
      Keychain);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt(
        'Failed to create temporary TLS keychain: %d', [Status]);
    if (FpLStat(PChar(KeychainPath), KeychainStatus) <> 0)
      or ((KeychainStatus.st_mode and S_IFMT) <> S_IFREG)
      or (KeychainStatus.st_uid <> FpGetUID) then
      raise ETransportSecurityError.Create(
        'Temporary TLS keychain storage has an unsafe identity');
    KeychainDevice := QWord(KeychainStatus.st_dev);
    KeychainInode := QWord(KeychainStatus.st_ino);
    if not BindSecureTransportFileReference(KeychainPath, KeychainDevice,
      KeychainInode, KeychainFileReference) then
      raise ETransportSecurityError.Create(
        'Failed to bind temporary TLS keychain storage identity');
    KeychainFileReferenceKnown := True;
    if FpChmod(PChar(KeychainPath), S_IRUSR or S_IWUSR) <> 0 then
      raise ETransportSecurityError.Create(
        'Failed to restrict temporary TLS keychain storage');
    CFData := CFDataCreate(nil, @IdentityBytes[0], Length(IdentityBytes));
    if CFData = nil then
      raise ETransportSecurityError.Create(
        'Failed to retain configured TLS PKCS#12 identity');
    EncodedPassphrase := UTF8Encode(APkcs12Passphrase);
    CFPassphrase := CFStringCreateWithCString(nil,
      PAnsiChar(EncodedPassphrase), CF_STRING_ENCODING_UTF8);
    if CFPassphrase = nil then
      raise ETransportSecurityError.Create(
        'Failed to encode configured TLS PKCS#12 passphrase');
    Keys[0] := SecureTransportServerSymbols.ImportPassphraseKey;
    Values[0] := CFPassphrase;
    Keys[1] := SecureTransportServerSymbols.ImportKeychainKey;
    Values[1] := Keychain;
    CFOptions := CFDictionaryCreate(nil, @Keys[0], @Values[0], 2,
      SecureTransportServerSymbols.DictionaryKeyCallbacks,
      SecureTransportServerSymbols.DictionaryValueCallbacks);
    if CFOptions = nil then
      raise ETransportSecurityError.Create(
        'Failed to prepare configured TLS PKCS#12 import');
    Status := SecPKCS12Import(CFData, CFOptions, @Items);
    if (Status <> ERR_SEC_SUCCESS) or (Items = nil)
      or (CFArrayGetCount(Items) = 0) then
      raise ETransportSecurityError.Create(
        'Failed to parse configured TLS PKCS#12 identity; verify the bundle and passphrase');
    Item := CFArrayGetValueAtIndex(Items, 0);
    CertificateChain := CFDictionaryGetValue(Item,
      SecureTransportServerSymbols.ImportCertChainKey);
    Identity := CFDictionaryGetValue(Item,
      SecureTransportServerSymbols.ImportIdentityKey);
    if (Identity = nil) or (CertificateChain = nil)
      or (CFArrayGetCount(CertificateChain) = 0) then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain a certificate and private key');
    MarkerService := 'temporary-tls-keychain-' + SecureTransportRandomHex;
    MarkerAccount := SecureTransportRandomHex;
    if SecKeychainAddGenericPassword(Keychain, Length(MarkerService),
      PAnsiChar(MarkerService), Length(MarkerAccount), PAnsiChar(MarkerAccount),
      0, nil, nil) <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.Create(
        'Failed to mark temporary TLS keychain storage');
    if not ValidateImportedSecureTransportKeychainIdentity(MarkerService,
      MarkerAccount, KeychainPath, KeychainDevice, KeychainInode,
      KeychainFileReference, KeychainFileReferenceKnown) then
      raise ETransportSecurityError.Create(
        'Temporary TLS keychain storage changed identity during import');
    if AValidation = tsivStrict then
      ValidateSecureTransportServerIdentity(CertificateChain);
    CertificateCount := CFArrayGetCount(CertificateChain);
    SetLength(CertificateValues, CertificateCount);
    CertificateValues[0] := Identity;
    for Index := 1 to CertificateCount - 1 do
      CertificateValues[Index] := CFArrayGetValueAtIndex(CertificateChain,
        Index);
    Result := TSecureTransportServerSnapshot.Create;
    Result.CertificateArray := CFArrayCreate(nil, @CertificateValues[0],
      Length(CertificateValues), SecureTransportServerSymbols.ArrayCallbacks);
    if Result.CertificateArray = nil then
    begin
      Result.Free;
      Result := nil;
      raise ETransportSecurityError.Create(
        'Failed to retain configured TLS certificate chain');
    end;
    Result.Keychain := Keychain;
    Keychain := nil;
    Result.KeychainFileReference := KeychainFileReference;
    Result.KeychainFileReferenceKnown := KeychainFileReferenceKnown;
    Result.KeychainPath := KeychainPath;
    KeychainPath := '';
  finally
    if Length(IdentityBytes) > 0 then
      FillChar(IdentityBytes[0], Length(IdentityBytes), 0);
    IdentityBytes := nil;
    if Length(EncodedPassphrase) > 0 then
      FillChar(EncodedPassphrase[1], Length(EncodedPassphrase), 0);
    EncodedPassphrase := '';
    if Length(KeychainPassphrase) > 0 then
      FillChar(KeychainPassphrase[1], Length(KeychainPassphrase), 0);
    KeychainPassphrase := '';
    if Length(MarkerAccount) > 0 then
      FillChar(MarkerAccount[1], Length(MarkerAccount), 0);
    MarkerAccount := '';
    if Length(MarkerService) > 0 then
      FillChar(MarkerService[1], Length(MarkerService), 0);
    MarkerService := '';
    EncodedKeychainPath := '';
    if Items <> nil then
      CFRelease(Items);
    if CFOptions <> nil then
      CFRelease(CFOptions);
    if CFPassphrase <> nil then
      CFRelease(CFPassphrase);
    if CFData <> nil then
      CFRelease(CFData);
    CleanupSecureTransportKeychain(Keychain, KeychainPath,
      KeychainFileReference, KeychainFileReferenceKnown,
      ExceptObject <> nil);
  end;
end;

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

{ Client options on Secure Transport (ADR-0050). Trust anchors and insecure
  mode set kSSLSessionOptionBreakOnServerAuth, which disables Secure
  Transport's own server evaluation and pauses the handshake with
  errSSLPeerAuthCompleted. EvaluateSecureTransportServerTrust then evaluates
  the peer's SecTrust with an SSL policy for the host name and the configured
  anchors; SecTrustSetAnchorCertificatesOnly expresses both trust modes
  natively. Insecure mode resumes without evaluating. }
function CreateSecureTransportAnchorArray(
  const AAnchors: TTransportSecurityCertificateList): Pointer;
var
  Certificates: array of Pointer;
  CertificateData: Pointer;
  Created: Integer;
  I: Integer;
begin
  Result := nil;
  if Length(AAnchors) = 0 then
    raise ETransportSecurityError.Create(
      'TLS server evaluation requires at least one trust anchor');
  ResolveSecureTransportServerSymbols;
  SetLength(Certificates, Length(AAnchors));
  Created := 0;
  try
    for I := 0 to High(AAnchors) do
    begin
      CertificateData := CFDataCreate(nil, @AAnchors[I][0],
        Length(AAnchors[I]));
      if CertificateData = nil then
        raise ETransportSecurityError.Create(
          'Failed to retain a configured TLS trust anchor');
      try
        Certificates[I] := SecCertificateCreateWithData(nil, CertificateData);
      finally
        CFRelease(CertificateData);
      end;
      if Certificates[I] = nil then
        raise ETransportSecurityError.CreateFmt(
          'Configured TLS trust anchor %d is not a valid X.509 certificate',
          [I + 1]);
      Created := I + 1;
    end;
    Result := CFArrayCreate(nil, @Certificates[0], Length(Certificates),
      SecureTransportServerSymbols.ArrayCallbacks);
    if Result = nil then
      raise ETransportSecurityError.Create(
        'Failed to retain the configured TLS trust anchors');
  finally
    for I := 0 to Created - 1 do
      CFRelease(Certificates[I]);
  end;
end;

procedure EvaluateSecureTransportServerTrust(const AContext: SSLContextRef;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AAnchors: Pointer);
var
  ErrorReference, HostName, Policy, Trust: Pointer;
  EncodedHost: UTF8String;
  Status: OSStatus;
begin
  if AOptions.InsecureSkipVerify then
    Exit;
  if AAnchors = nil then
    raise ETransportSecurityError.Create(
      'TLS server evaluation requires at least one trust anchor');
  ErrorReference := nil;
  HostName := nil;
  Policy := nil;
  Trust := nil;
  try
    Status := SSLCopyPeerTrust(AContext, Trust);
    if (Status <> ERR_SEC_SUCCESS) or (Trust = nil) then
      raise ETransportSecurityVerificationError.CreateFmt(
        '%s: the server presented no certificate', [TLS_VERIFICATION_ERROR]);
    EncodedHost := UTF8Encode(UnicodeString(AHost));
    HostName := CFStringCreateWithCString(nil, PAnsiChar(EncodedHost),
      CF_STRING_ENCODING_UTF8);
    if HostName = nil then
      raise ETransportSecurityError.Create(
        'Failed to encode the TLS server name');
    Policy := SecPolicyCreateSSL(True, HostName);
    if (Policy = nil) or
       (SecTrustSetPolicies(Trust, Policy) <> ERR_SEC_SUCCESS) then
      raise ETransportSecurityError.Create(
        'Failed to configure the TLS server trust policy');
    { The configured anchors are evaluated first, alone and offline: a
      private anchor set needs no issuer or revocation fetch, and a URL in
      a certificate must never stall the handshake (ADR-0050). System plus
      anchors then re-evaluates with the system anchors and Secure
      Transport's default network behaviour, as the option-less client
      does. }
    if (SecTrustSetAnchorCertificates(Trust, AAnchors) <> ERR_SEC_SUCCESS) or
       (SecTrustSetAnchorCertificatesOnly(Trust, True) <> ERR_SEC_SUCCESS) or
       (SecTrustSetNetworkFetchAllowed(Trust, False) <> ERR_SEC_SUCCESS) then
      raise ETransportSecurityError.Create(
        'Failed to configure the TLS trust anchors');
    if SecTrustEvaluateWithError(Trust, ErrorReference) then
      Exit;
    if AOptions.TrustMode = tstmSystemAndAnchors then
    begin
      if ErrorReference <> nil then
        CFRelease(ErrorReference);
      ErrorReference := nil;
      if (SecTrustSetAnchorCertificatesOnly(Trust, False)
         <> ERR_SEC_SUCCESS) or
         (SecTrustSetNetworkFetchAllowed(Trust, True) <> ERR_SEC_SUCCESS) then
        raise ETransportSecurityError.Create(
          'Failed to configure the TLS system trust');
      if SecTrustEvaluateWithError(Trust, ErrorReference) then
        Exit;
    end;
    if ErrorReference <> nil then
      raise ETransportSecurityVerificationError.CreateFmt('%s: %d',
        [TLS_VERIFICATION_ERROR, Int64(CFErrorGetCode(ErrorReference))]);
    raise ETransportSecurityVerificationError.Create(TLS_VERIFICATION_ERROR);
  finally
    if ErrorReference <> nil then
      CFRelease(ErrorReference);
    if Policy <> nil then
      CFRelease(Policy);
    if HostName <> nil then
      CFRelease(HostName);
    if Trust <> nil then
      CFRelease(Trust);
  end;
end;

{ Test-only seam helper: whether the client's certificate chain, as sent in
  its own Certificate message, reaches AAnchors for client authentication,
  with network fetching disabled. }
function SecureTransportClientTrustAccepted(const AContext: SSLContextRef;
  const AAnchors: Pointer): Boolean;
var
  ErrorReference, Policy, Trust: Pointer;
begin
  Result := False;
  if AAnchors = nil then
    Exit;
  ErrorReference := nil;
  Policy := nil;
  Trust := nil;
  try
    if (SSLCopyPeerTrust(AContext, Trust) <> ERR_SEC_SUCCESS) or
       (Trust = nil) or (SecTrustGetCertificateCount(Trust) < 1) then
      Exit;
    Policy := SecPolicyCreateSSL(False, nil);
    if (Policy = nil) or
       (SecTrustSetPolicies(Trust, Policy) <> ERR_SEC_SUCCESS) or
       (SecTrustSetNetworkFetchAllowed(Trust, False) <> ERR_SEC_SUCCESS) or
       (SecTrustSetAnchorCertificates(Trust, AAnchors) <> ERR_SEC_SUCCESS) or
       (SecTrustSetAnchorCertificatesOnly(Trust, True) <> ERR_SEC_SUCCESS) then
      Exit;
    Result := SecTrustEvaluateWithError(Trust, ErrorReference);
  finally
    if ErrorReference <> nil then
      CFRelease(ErrorReference);
    if Policy <> nil then
      CFRelease(Policy);
    if Trust <> nil then
      CFRelease(Trust);
  end;
end;

function SecureTransportTrustLeafCertificate(const ATrust: Pointer): TBytes;
var
  Certificate, CertificateData: Pointer;
  DataLength: NativeInt;
begin
  Result := nil;
  if (ATrust = nil) or (SecTrustGetCertificateCount(ATrust) < 1) then
    Exit;
  Certificate := SecTrustGetCertificateAtIndex(ATrust, 0);
  if Certificate = nil then
    Exit;
  CertificateData := SecCertificateCopyData(Certificate);
  if CertificateData = nil then
    Exit;
  try
    DataLength := CFDataGetLength(CertificateData);
    if DataLength > 0 then
    begin
      SetLength(Result, DataLength);
      Move(CFDataGetBytePtr(CertificateData)^, Result[0], DataLength);
    end;
  finally
    CFRelease(CertificateData);
  end;
end;

function SecureTransportContextPeerCertificate(
  const AContext: SSLContextRef): TBytes;
var
  Trust: Pointer;
begin
  Result := nil;
  Trust := nil;
  if (SSLCopyPeerTrust(AContext, Trust) <> ERR_SEC_SUCCESS) or
     (Trust = nil) then
    Exit;
  try
    Result := SecureTransportTrustLeafCertificate(Trust);
  finally
    CFRelease(Trust);
  end;
end;

procedure StartSecureTransport(var AConnection: TTransportSecurityConnection;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AUseOptions: Boolean);
var
  Data: TSecureTransportData;
  HostName: AnsiString;
  Status: OSStatus;
begin
  Data := TSecureTransportData.Create;
  Data.Socket := AConnection.Socket;
  Data.WantRead := False;
  Data.WantWrite := False;
  Data.ClientIdentity := nil;
  Data.AnchorArray := nil;
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

    if AUseOptions then
    begin
      { Anchors are parsed before the first handshake byte, so a malformed
        anchor never reaches the network. }
      if Length(AOptions.TrustAnchors) > 0 then
        Data.AnchorArray := CreateSecureTransportAnchorArray(
          ParseTransportSecurityTrustAnchors(AOptions.TrustAnchors));
      if Length(AOptions.ClientPkcs12) > 0 then
      begin
        { The server-identity importer is reused with permissive validation:
          it owns the temporary keychain lifecycle, and judging the client
          certificate is the server's job. }
        Data.ClientIdentity := CreateSecureTransportServerSnapshot(
          AOptions.ClientPkcs12, AOptions.ClientPkcs12Passphrase,
          tsivPermissive);
        Status := SSLSetCertificate(Data.Context,
          Data.ClientIdentity.CertificateArray);
        if Status <> ERR_SEC_SUCCESS then
          raise ETransportSecurityError.CreateFmt(
            'Failed to configure the TLS client identity: %d', [Status]);
      end;
      if AOptions.InsecureSkipVerify or
         (Length(AOptions.TrustAnchors) > 0) then
      begin
        Status := SSLSetSessionOption(Data.Context,
          K_SSL_SESSION_OPTION_BREAK_ON_SERVER_AUTH, True);
        if Status <> ERR_SEC_SUCCESS then
          raise ETransportSecurityError.CreateFmt(
            'Failed to configure TLS server evaluation: %d', [Status]);
      end;
    end;

    repeat
      Data.WantRead := False;
      Data.WantWrite := False;
      Status := SSLHandshake(Data.Context);
      if AUseOptions and (Status = ERR_SSL_PEER_AUTH_COMPLETED) then
      begin
        EvaluateSecureTransportServerTrust(Data.Context, AHost, AOptions,
          Data.AnchorArray);
        { Resume the paused handshake without waiting for the socket. }
        Status := ERR_SSL_WOULD_BLOCK;
        Continue;
      end;
      if (Status = ERR_SSL_WOULD_BLOCK) and
         (AConnection.Deadline <> 0) then
        WaitForTransportSocket(AConnection, Data.WantRead,
          Data.WantWrite);
    until Status <> ERR_SSL_WOULD_BLOCK;

    { Without options Secure Transport evaluates the chain itself and
      ends the handshake with one of its certificate statuses. }
    if SecureTransportStatusIsVerificationFailure(Status) then
      raise ETransportSecurityVerificationError.CreateFmt('%s: %d',
        [TLS_HANDSHAKE_ERROR, Status]);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt('%s: %d',
        [TLS_HANDSHAKE_ERROR, Status]);

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_SECURE_TRANSPORT;
    AConnection.Active := True;
  except
    CFRelease(Data.Context);
    if Data.AnchorArray <> nil then
      CFRelease(Data.AnchorArray);
    if Assigned(Data.ClientIdentity) then
      Data.ClientIdentity.Release;
    Data.Free;
    raise;
  end;
end;

{ Native parse of the anchors and the identity (with its passphrase) through
  the same importers the connection uses, so a caller can reject bad
  material before dialing. The identity check creates and removes a
  temporary keychain. }
procedure ValidateSecureTransportClientMaterial(
  const AOptions: TTransportSecurityClientOptions);
var
  Anchors: Pointer;
  Identity: TSecureTransportServerSnapshot;
begin
  if Length(AOptions.TrustAnchors) > 0 then
  begin
    Anchors := CreateSecureTransportAnchorArray(
      ParseTransportSecurityTrustAnchors(AOptions.TrustAnchors));
    CFRelease(Anchors);
  end;
  if Length(AOptions.ClientPkcs12) > 0 then
  begin
    Identity := CreateSecureTransportServerSnapshot(AOptions.ClientPkcs12,
      AOptions.ClientPkcs12Passphrase, tsivPermissive);
    Identity.Release;
  end;
end;

procedure CloseSecureTransport(var AConnection: TTransportSecurityConnection);
var
  Data: TSecureTransportData;
begin
  Data := TSecureTransportData(AConnection.BackendData);
  if Assigned(Data) then
  begin
    try
      if Data.Context <> nil then
      begin
        SSLClose(Data.Context);
        CFRelease(Data.Context);
      end;
      if Data.AnchorArray <> nil then
        CFRelease(Data.AnchorArray);
      if Assigned(Data.ClientIdentity) then
        Data.ClientIdentity.Release;
    finally
      Data.Free;
    end;
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

procedure CompactSecureTransportServerOutput(
  const AData: TSecureTransportServerData);
var
  Pending: Integer;
begin
  if not Assigned(AData) or (AData.OutputOffset <= 0) then
    Exit;
  Pending := Length(AData.Output) - AData.OutputOffset;
  if Pending > 0 then
    Move(AData.Output[AData.OutputOffset], AData.Output[0], Pending);
  SetLength(AData.Output, Pending);
  AData.OutputOffset := 0;
end;

function SecureTransportServerPendingCiphertext(
  const AData: TSecureTransportServerData): Integer; inline;
begin
  if Assigned(AData) then
    Result := Length(AData.Output) - AData.OutputOffset
  else
    Result := 0;
end;

function SecureTransportServerReadCallback(AConnection: SSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
var
  Available, Requested, Taken: Integer;
  Data: TSecureTransportServerData;
begin
  Data := TSecureTransportServerData(AConnection);
  Requested := Integer(ADataLength);
  Available := Length(Data.Input);
  Taken := Requested;
  if Taken > Available then
    Taken := Available;
  if Taken > 0 then
  begin
    Move(Data.Input[0], AData^, Taken);
    Inc(Data.InputConsumed, QWord(Taken));
    if Taken < Available then
      Move(Data.Input[Taken], Data.Input[0], Available - Taken);
    SetLength(Data.Input, Available - Taken);
  end;
  ADataLength := Taken;
  Data.InputBuffered := Length(Data.Input);
  if Taken = Requested then
    Result := ERR_SEC_SUCCESS
  else
    Result := ERR_SSL_WOULD_BLOCK;
  if Data.InputBackpressured then
    Data.InputBackpressured := Length(Data.Input) > Data.InputLowWatermark;
end;

function SecureTransportServerWriteCallback(AConnection: SSLConnectionRef;
  AData: Pointer; var ADataLength: PtrUInt): OSStatus; cdecl;
var
  Available, Existing, Requested, Taken: Integer;
  Data: TSecureTransportServerData;
begin
  Data := TSecureTransportServerData(AConnection);
  CompactSecureTransportServerOutput(Data);
  Requested := Integer(ADataLength);
  Existing := Length(Data.Output);
  Available := Data.OutputCapacity - Existing;
  Taken := Requested;
  if Taken > Available then
    Taken := Available;
  if Taken > 0 then
  begin
    SetLength(Data.Output, Existing + Taken);
    Move(AData^, Data.Output[Existing], Taken);
  end;
  ADataLength := Taken;
  if Taken = Requested then
    Result := ERR_SEC_SUCCESS
  else
    Result := ERR_SSL_WOULD_BLOCK;
end;

procedure FreeSecureTransportServerData(
  const AData: TSecureTransportServerData);
begin
  if not Assigned(AData) then
    Exit;
  if AData.Context <> nil then
    CFRelease(AData.Context);
  if AData.ClientAnchorArray <> nil then
    CFRelease(AData.ClientAnchorArray);
  AData.ClientAnchorArray := nil;
  if Assigned(AData.Snapshot) then
    AData.Snapshot.Release;
  AData.Context := nil;
  AData.Snapshot := nil;
  SetLength(AData.Input, 0);
  SetLength(AData.Output, 0);
  if Length(AData.PendingPlaintext) > 0 then
    FillChar(AData.PendingPlaintext[0], Length(AData.PendingPlaintext), 0);
  SetLength(AData.PendingPlaintext, 0);
  AData.Free;
end;

function SecureTransportServerData(
  const AConnection: TTransportSecurityConnection):
  TSecureTransportServerData; inline;
begin
  if (AConnection.Backend = TSB_SECURE_TRANSPORT_SERVER)
    and Assigned(AConnection.BackendData) then
    Result := TSecureTransportServerData(AConnection.BackendData)
  else
    Result := nil;
end;

procedure PoisonSecureTransportServerConnection(
  var AConnection: TTransportSecurityConnection);
var
  Data: TSecureTransportServerData;
begin
  Data := TSecureTransportServerData(AConnection.BackendData);
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
  FreeSecureTransportServerData(Data);
end;

procedure BeginSecureTransportServer(
  var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
var
  Data: TSecureTransportServerData;
  Snapshot: TSecureTransportServerSnapshot;
  Status: OSStatus;
begin
  Snapshot := TSecureTransportServerSnapshot(AContext.AcquireSnapshot);
  if not Assigned(Snapshot) or (Snapshot.CertificateArray = nil) then
  begin
    if Assigned(Snapshot) then
      Snapshot.Release;
    raise ETransportSecurityError.Create(
      'TLS server context is not initialized');
  end;
  try
    Data := TSecureTransportServerData.Create;
  except
    Snapshot.Release;
    raise;
  end;
  try
    Data.Snapshot := Snapshot;
    Data.InputHighWatermark := AContext.FInputHighWatermark;
    Data.InputLowWatermark := AContext.FInputLowWatermark;
    Data.OutputCapacity := AContext.FOutputCapacity;
    Data.Context := SSLCreateContext(nil, K_SSL_SERVER_SIDE,
      K_SSL_STREAM_TYPE);
    if Data.Context = nil then
      raise ETransportSecurityError.Create(
        'Failed to create Secure Transport server context');
    Status := SSLSetIOFuncs(Data.Context,
      SecureTransportServerReadCallback,
      SecureTransportServerWriteCallback);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt(
        'Failed to configure Secure Transport server I/O: %d', [Status]);
    Status := SSLSetConnection(Data.Context, SSLConnectionRef(Data));
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt(
        'Failed to bind Secure Transport server I/O: %d', [Status]);
    Status := SSLSetCertificate(Data.Context, Snapshot.CertificateArray);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt(
        'Failed to configure Secure Transport server identity: %d', [Status]);
    Status := SSLSetProtocolVersionMin(Data.Context, K_TLS_PROTOCOL_12);
    if Status <> ERR_SEC_SUCCESS then
      raise ETransportSecurityError.CreateFmt(
        'Failed to configure Secure Transport server TLS floor: %d', [Status]);
    AConnection.BackendData := Data;
    AConnection.Backend := TSB_SECURE_TRANSPORT_SERVER;
  except
    FreeSecureTransportServerData(Data);
    raise;
  end;
end;

function FeedSecureTransportServerCiphertext(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): Integer;
var
  Accepted, Available, Existing: Integer;
  Data: TSecureTransportServerData;
begin
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) then
    Exit(-1);
  if ALength <= 0 then
    Exit(0);
  if not Assigned(ABuffer) then
    raise ETransportSecurityError.Create(
      'TLS ciphertext input buffer is nil');
  Available := Data.InputHighWatermark - Length(Data.Input);
  Accepted := ALength;
  if Accepted > Available then
    Accepted := Available;
  if Accepted <= 0 then
  begin
    Data.InputBackpressured := True;
    Exit(0);
  end;
  Existing := Length(Data.Input);
  SetLength(Data.Input, Existing + Accepted);
  Move(ABuffer^, Data.Input[Existing], Accepted);
  Inc(Data.InputAccepted, QWord(Accepted));
  Data.InputBackpressured := Length(Data.Input) >= Data.InputHighWatermark;
  Data.InputBuffered := Length(Data.Input);
  Result := Accepted;
end;

function SecureTransportServerState(
  var AConnection: TTransportSecurityConnection;
  const AStatus: OSStatus; const APeerCloseIsSuccess: Boolean):
  TTransportSecurityState;
var
  Data: TSecureTransportServerData;
begin
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) then
    Exit(tssError);
  if AStatus = ERR_SSL_CLOSED_GRACEFUL then
  begin
    PoisonSecureTransportServerConnection(AConnection);
    if APeerCloseIsSuccess then
      Result := tssPeerClosed
    else
      Result := tssError;
    Exit;
  end;
  if (AStatus <> ERR_SEC_SUCCESS) and (AStatus <> ERR_SSL_WOULD_BLOCK) then
  begin
    PoisonSecureTransportServerConnection(AConnection);
    Exit(tssError);
  end;
  if SecureTransportServerPendingCiphertext(Data) > 0 then
    Exit(tssWantWrite);
  case AStatus of
    ERR_SEC_SUCCESS: Result := tssDone;
    ERR_SSL_WOULD_BLOCK: Result := tssWantRead;
  else
    Result := tssError;
  end;
end;

function HandshakeSecureTransportServer(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  Data: TSecureTransportServerData;
  SeamRejection: string;
  Status: OSStatus;
begin
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) then
    Exit(tssError);
  if SecureTransportServerPendingCiphertext(Data) > 0 then
    Exit(tssWantWrite);
  if Data.HandshakeDone then
    Exit(tssDone);
  SeamRejection := '';
  Status := SSLHandshake(Data.Context);
  if Data.RequireClientCertificate and
     (Status = ERR_SSL_PEER_AUTH_COMPLETED) then
  begin
    { Test-only seam: accept only a client chain that reaches the seam's
      anchors, then resume the paused handshake. }
    if not SecureTransportClientTrustAccepted(Data.Context,
       Data.ClientAnchorArray) then
    begin
      SeamRejection := 'Secure Transport server test seam refused the ' +
        'client certificate chain';
      Status := ERR_SSL_CLOSED_ABORT;
    end
    else
      Status := SSLHandshake(Data.Context);
  end;
  if Status = ERR_SEC_SUCCESS then
  begin
    Data.HandshakeDone := True;
    AConnection.Active := True;
  end
  else if Status <> ERR_SSL_WOULD_BLOCK then
  begin
    if SeamRejection <> '' then
      RecordServerFailure(SeamRejection)
    else
      RecordServerFailure(Format('Secure Transport server handshake ' +
        'failed: OSStatus %d', [Status]));
  end;
  Result := SecureTransportServerState(AConnection, Status, False);
end;

function SecureTransportServerInputFlow(
  const AData: TSecureTransportServerData): TTransportSecurityInputFlow;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not Assigned(AData) then
    Exit;
  Result.AcceptedBytes := AData.InputAccepted;
  Result.Backpressured := AData.InputBackpressured;
  Result.BufferedBytes := Length(AData.Input);
  Result.ConsumedBytes := AData.InputConsumed;
  Result.HighWatermark := AData.InputHighWatermark;
  Result.LowWatermark := AData.InputLowWatermark;
end;

function SecureTransportServerOutputFlow(
  const AData: TSecureTransportServerData): TTransportSecurityOutputFlow;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not Assigned(AData) then
    Exit;
  Result.Capacity := AData.OutputCapacity;
  Result.PendingBytes := SecureTransportServerPendingCiphertext(AData);
  Result.RemainingBytes := Result.Capacity - Result.PendingBytes;
end;

function ReadSecureTransportServer(
  var AConnection: TTransportSecurityConnection; var ABuffer: array of Byte;
  const ALength: Integer): TTransportSecurityIOResult;
var
  Data: TSecureTransportServerData;
  Processed: PtrUInt;
  ReadLength: Integer;
  Status: OSStatus;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit;
  if SecureTransportServerPendingCiphertext(Data) > 0 then
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
  Processed := 0;
  Status := SSLRead(Data.Context, @ABuffer[0], ReadLength, Processed);
  Result.BytesProcessed := Integer(Processed);
  Result.State := SecureTransportServerState(AConnection, Status, True);
end;

function WriteSecureTransportServer(
  var AConnection: TTransportSecurityConnection; const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
var
  Data: TSecureTransportServerData;
  PendingLength: Integer;
  Processed: PtrUInt;
  ResumeCall: Boolean;
  Retrying: Boolean;
  Status: OSStatus;
begin
  Result.State := tssError;
  Result.BytesProcessed := 0;
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit;
  if SecureTransportServerPendingCiphertext(Data) > 0 then
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
    Data.WriteNeedsResume := False;
  end;

  { Secure Transport can report errSSLWouldBlock after accepting part or all
    of the plaintext. Keep the caller's bytes until repeated SSLWrite calls,
    including a zero-length resume after output drain, complete
    the operation. This preserves the package-wide nil/zero retry contract. }
  PendingLength := Length(Data.PendingPlaintext);
  repeat
    ResumeCall := Data.WriteNeedsResume;
    Processed := 0;
    if ResumeCall then
      Status := SSLWrite(Data.Context, nil, 0, Processed)
    else
      Status := SSLWrite(Data.Context,
        @Data.PendingPlaintext[Data.PendingPlaintextOffset],
        PendingLength - Data.PendingPlaintextOffset, Processed);
    if not ResumeCall then
      Inc(Data.PendingPlaintextOffset, Integer(Processed));
    Data.WriteNeedsResume := Status = ERR_SSL_WOULD_BLOCK;
    Result.State := SecureTransportServerState(AConnection, Status, False);
    if Result.State = tssError then Exit;
    if (Status = ERR_SEC_SUCCESS)
      and (Data.PendingPlaintextOffset >= PendingLength) then
    begin
      Result.BytesProcessed := PendingLength;
      FillChar(Data.PendingPlaintext[0], PendingLength, 0);
      SetLength(Data.PendingPlaintext, 0);
      Data.PendingPlaintextOffset := 0;
      Data.WriteNeedsResume := False;
      if SecureTransportServerPendingCiphertext(Data) > 0 then
        Result.State := tssWantWrite
      else
        Result.State := tssDone;
      Exit;
    end;
    if SecureTransportServerPendingCiphertext(Data) > 0 then Exit;
    if Status = ERR_SSL_WOULD_BLOCK then Exit;
  until Data.PendingPlaintextOffset >= PendingLength;
end;

function CloseSecureTransportServerGracefully(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
var
  Data: TSecureTransportServerData;
  Status: OSStatus;
begin
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) or not Data.HandshakeDone then
    Exit(tssError);
  if SecureTransportServerPendingCiphertext(Data) > 0 then
    Exit(tssWantWrite);
  if Length(Data.PendingPlaintext) > 0 then
  begin
    PoisonSecureTransportServerConnection(AConnection);
    Exit(tssError);
  end;
  Status := SSLClose(Data.Context);
  Result := SecureTransportServerState(AConnection, Status, True);
end;
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_SERVER}
{ Server-identity support shared by the platform server backends: the
  PKCS#12 size ceiling, link-refusing identity-file loading, and the
  connection/secret bookkeeping they use. }

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

{ Client options on OpenSSL (ADR-0050). The symbols are resolved on first
  use, separately from the server set, so client options work with every
  runtime the plain client accepts and never demand the server's OpenSSL 3
  floor. }
type
  TOpenSSLClientBIONewMemoryBuffer = function(ABuffer: Pointer;
    ALength: LongInt): Pointer; cdecl;
  TOpenSSLClientBIOFree = function(ABIO: Pointer): LongInt; cdecl;
  TOpenSSLD2IX509 = function(ACertificate: Pointer; var AInput: PByte;
    ALength: PtrInt): Pointer; cdecl;
  TOpenSSLI2DX509 = function(ACertificate: Pointer;
    AOutput: Pointer): LongInt; cdecl;
  TOpenSSLGetPeerCertificate = function(ASSL: PSSL): Pointer; cdecl;
  TOpenSSLGetCertificateStore = function(AContext: PSSL_CTX): Pointer; cdecl;
  TOpenSSLStoreAddCertificate = function(AStore,
    ACertificate: Pointer): LongInt; cdecl;
  TOpenSSLVerifyErrorString = function(AError: PtrInt): PAnsiChar; cdecl;

var
  OpenSSLClientProceduresLoaded: Boolean;
  OpenSSLClientBIONewMemoryBuffer: TOpenSSLClientBIONewMemoryBuffer;
  OpenSSLClientBIOFree: TOpenSSLClientBIOFree;
  OpenSSLClientD2IX509: TOpenSSLD2IX509;
  OpenSSLClientI2DX509: TOpenSSLI2DX509;
  OpenSSLClientGetPeerCertificate: TOpenSSLGetPeerCertificate;
  OpenSSLClientGetCertificateStore: TOpenSSLGetCertificateStore;
  OpenSSLClientStoreAddCertificate: TOpenSSLStoreAddCertificate;
  OpenSSLClientVerifyErrorString: TOpenSSLVerifyErrorString;
  OpenSSLClientPKCS12Parse: TPKCS12Parse;
  OpenSSLClientStackFree: TOpenSSLStackFree;
  OpenSSLClientStackNum: TOpenSSLStackNum;
  OpenSSLClientStackValue: TOpenSSLStackValue;

procedure LoadOpenSSLClientProcedures;
var
  BIOFree: TOpenSSLClientBIOFree;
  BIONewMemoryBuffer: TOpenSSLClientBIONewMemoryBuffer;
  D2IX509: TOpenSSLD2IX509;
  GetCertificateStore: TOpenSSLGetCertificateStore;
  GetPeerCertificate: TOpenSSLGetPeerCertificate;
  I2DX509: TOpenSSLI2DX509;
  PKCS12Parse: TPKCS12Parse;
  StackFree: TOpenSSLStackFree;
  StackNum: TOpenSSLStackNum;
  StackValue: TOpenSSLStackValue;
  StoreAddCertificate: TOpenSSLStoreAddCertificate;
  VerifyErrorString: TOpenSSLVerifyErrorString;
begin
  if OpenSSLClientProceduresLoaded then
    Exit;
  BIOFree := TOpenSSLClientBIOFree(GetProcedureAddress(SSLUtilHandle,
    'BIO_free'));
  BIONewMemoryBuffer := TOpenSSLClientBIONewMemoryBuffer(
    GetProcedureAddress(SSLUtilHandle, 'BIO_new_mem_buf'));
  D2IX509 := TOpenSSLD2IX509(GetProcedureAddress(SSLUtilHandle, 'd2i_X509'));
  I2DX509 := TOpenSSLI2DX509(GetProcedureAddress(SSLUtilHandle, 'i2d_X509'));
  { OpenSSL 3 exports only SSL_get1_peer_certificate; 1.1 exports only
    SSL_get_peer_certificate. Both return a new reference. }
  GetPeerCertificate := TOpenSSLGetPeerCertificate(GetProcedureAddress(
    SSLLibHandle, 'SSL_get1_peer_certificate'));
  if not Assigned(GetPeerCertificate) then
    GetPeerCertificate := TOpenSSLGetPeerCertificate(GetProcedureAddress(
      SSLLibHandle, 'SSL_get_peer_certificate'));
  GetCertificateStore := TOpenSSLGetCertificateStore(GetProcedureAddress(
    SSLLibHandle, 'SSL_CTX_get_cert_store'));
  StoreAddCertificate := TOpenSSLStoreAddCertificate(GetProcedureAddress(
    SSLUtilHandle, 'X509_STORE_add_cert'));
  VerifyErrorString := TOpenSSLVerifyErrorString(GetProcedureAddress(
    SSLUtilHandle, 'X509_verify_cert_error_string'));
  PKCS12Parse := TPKCS12Parse(GetProcedureAddress(SSLUtilHandle,
    'PKCS12_parse'));
  StackFree := TOpenSSLStackFree(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_free'));
  StackNum := TOpenSSLStackNum(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_num'));
  StackValue := TOpenSSLStackValue(GetProcedureAddress(SSLUtilHandle,
    'OPENSSL_sk_value'));
  if not Assigned(BIOFree) or not Assigned(BIONewMemoryBuffer) or
     not Assigned(D2IX509) or not Assigned(I2DX509) or
     not Assigned(GetPeerCertificate) or not Assigned(GetCertificateStore) or
     not Assigned(StoreAddCertificate) or not Assigned(VerifyErrorString) or
     not Assigned(PKCS12Parse) or not Assigned(StackFree) or
     not Assigned(StackNum) or not Assigned(StackValue) then
    raise ETransportSecurityError.Create(
      'OpenSSL runtime does not provide the TLS client options interface');
  OpenSSLClientBIOFree := BIOFree;
  OpenSSLClientBIONewMemoryBuffer := BIONewMemoryBuffer;
  OpenSSLClientD2IX509 := D2IX509;
  OpenSSLClientI2DX509 := I2DX509;
  OpenSSLClientGetPeerCertificate := GetPeerCertificate;
  OpenSSLClientGetCertificateStore := GetCertificateStore;
  OpenSSLClientStoreAddCertificate := StoreAddCertificate;
  OpenSSLClientVerifyErrorString := VerifyErrorString;
  OpenSSLClientPKCS12Parse := PKCS12Parse;
  OpenSSLClientStackFree := StackFree;
  OpenSSLClientStackNum := StackNum;
  OpenSSLClientStackValue := StackValue;
  OpenSSLClientProceduresLoaded := True;
end;

procedure AddOpenSSLTrustAnchorsToStore(const AStore: Pointer;
  const AAnchors: TTransportSecurityCertificateList);
var
  Certificate: Pointer;
  Input: PByte;
  I: Integer;
begin
  for I := 0 to High(AAnchors) do
  begin
    Input := @AAnchors[I][0];
    Certificate := OpenSSLClientD2IX509(nil, Input, Length(AAnchors[I]));
    if not Assigned(Certificate) or
       (PtrUInt(Input) - PtrUInt(@AAnchors[I][0]) <>
        PtrUInt(Length(AAnchors[I]))) then
    begin
      if Assigned(Certificate) then
        X509Free(Certificate);
      ErrClearError;
      raise ETransportSecurityError.CreateFmt(
        'Configured TLS trust anchor %d is not a valid X.509 certificate',
        [I + 1]);
    end;
    try
      { Anchors are de-duplicated before this point, so a failure here is a
        real store error rather than an already-present certificate. }
      if OpenSSLClientStoreAddCertificate(AStore, Certificate) <> 1 then
      begin
        ErrClearError;
        raise ETransportSecurityError.CreateFmt(
          'Failed to add TLS trust anchor %d to the OpenSSL store', [I + 1]);
      end;
    finally
      X509Free(Certificate);
    end;
  end;
end;

procedure AddOpenSSLTrustAnchors(const AContext: PSSL_CTX;
  const AAnchors: TTransportSecurityCertificateList);
var
  Store: Pointer;
begin
  Store := OpenSSLClientGetCertificateStore(AContext);
  if not Assigned(Store) then
    raise ETransportSecurityError.Create(
      'OpenSSL context has no certificate store for TLS trust anchors');
  AddOpenSSLTrustAnchorsToStore(Store, AAnchors);
end;

procedure FreeOpenSSLClientChain(const AChain: Pointer);
var
  Certificate: Pointer;
  I: Integer;
begin
  if not Assigned(AChain) then
    Exit;
  for I := 0 to OpenSSLClientStackNum(AChain) - 1 do
  begin
    Certificate := OpenSSLClientStackValue(AChain, I);
    if Assigned(Certificate) then
      X509Free(Certificate);
  end;
  OpenSSLClientStackFree(AChain);
end;

procedure ConfigureOpenSSLClientIdentity(const AContext: PSSL_CTX;
  const APkcs12Identity: TBytes; const APassphrase: UnicodeString);
var
  Certificate: Pointer;
  Chain: Pointer;
  ChainCertificate: Pointer;
  EmptyPassphrase: AnsiChar;
  I: Integer;
  Identity: TBytes;
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
  SetLength(Identity, Length(APkcs12Identity));
  Move(APkcs12Identity[0], Identity[0], Length(Identity));
  try
    Passphrase := UTF8Encode(APassphrase);
    if Length(Passphrase) > 0 then
      PassphrasePointer := PAnsiChar(Passphrase);
    IdentityBIO := OpenSSLClientBIONewMemoryBuffer(@Identity[0],
      Length(Identity));
    if not Assigned(IdentityBIO) then
      raise ETransportSecurityError.Create(
        'Failed to read configured TLS client PKCS#12 identity');
    PKCS12 := d2iPKCS12bio(IdentityBIO, nil);
    if not Assigned(PKCS12) or
       (OpenSSLClientPKCS12Parse(PKCS12, PassphrasePointer, PrivateKey,
       Certificate, Chain) <> 1) then
      raise ETransportSecurityError.Create(
        'Failed to parse configured TLS client PKCS#12 identity; verify the bundle and passphrase');
    if not Assigned(Certificate) or not Assigned(PrivateKey) then
      raise ETransportSecurityError.Create(
        'Configured TLS client PKCS#12 identity must contain a certificate and private key');
    if SslCtxUseCertificate(AContext, Certificate) <> 1 then
      raise ETransportSecurityError.Create(
        'Failed to configure the TLS client certificate');
    if SslCtxUsePrivateKey(AContext, PrivateKey) <> 1 then
      raise ETransportSecurityError.Create(
        'Failed to configure the TLS client private key');
    if Assigned(Chain) then
      for I := 0 to OpenSSLClientStackNum(Chain) - 1 do
      begin
        ChainCertificate := OpenSSLClientStackValue(Chain, I);
        if Assigned(ChainCertificate) and
           (SslCTXCtrl(AContext, SSL_CTRL_CHAIN_CERT, 1,
           ChainCertificate) <= 0) then
          raise ETransportSecurityError.Create(
            'Failed to configure the TLS client certificate chain');
      end;
    if SslCtxCheckPrivateKeyFile(AContext) <> 1 then
      raise ETransportSecurityError.Create(
        'The TLS client certificate and private key do not match');
  finally
    FreeOpenSSLClientChain(Chain);
    if Assigned(Certificate) then
      X509Free(Certificate);
    if Assigned(PrivateKey) then
      EVP_PKEY_free(PrivateKey);
    if Assigned(PKCS12) then
      PKCS12free(PKCS12);
    if Assigned(IdentityBIO) then
      OpenSSLClientBIOFree(IdentityBIO);
    if Length(Passphrase) > 0 then
      FillChar(PAnsiChar(Passphrase)^, Length(Passphrase), 0);
    Passphrase := '';
    if Length(Identity) > 0 then
      FillChar(Identity[0], Length(Identity), 0);
    Identity := nil;
    ErrClearError;
  end;
end;

{ Configures everything that lives on the context, before SSL_new copies the
  verification mode into the session: a verification failure then aborts the
  handshake before a client certificate or application data is sent. }
procedure ConfigureOpenSSLClientOptions(const AContext: PSSL_CTX;
  const AOptions: TTransportSecurityClientOptions);
var
  SetDefaultVerifyPaths: TSSLSetDefaultVerifyPaths;
begin
  LoadOpenSSLClientProcedures;
  if AOptions.InsecureSkipVerify then
    SslCtxSetVerify(AContext, SSL_VERIFY_NONE, TSSLCTXVerifyCallback(nil))
  else
  begin
    if AOptions.TrustMode = tstmSystemAndAnchors then
    begin
      SetDefaultVerifyPaths := TSSLSetDefaultVerifyPaths(GetProcedureAddress(
        SSLLibHandle, 'SSL_CTX_set_default_verify_paths'));
      if Assigned(SetDefaultVerifyPaths) and
         (SetDefaultVerifyPaths(AContext) <> 1) then
        raise ETransportSecurityError.Create(
          'Failed to load OpenSSL default certificate paths');
    end;
    AddOpenSSLTrustAnchors(AContext,
      ParseTransportSecurityTrustAnchors(AOptions.TrustAnchors));
    SslCtxSetVerify(AContext, SSL_VERIFY_PEER, TSSLCTXVerifyCallback(nil));
  end;
  if Length(AOptions.ClientPkcs12) > 0 then
    ConfigureOpenSSLClientIdentity(AContext, AOptions.ClientPkcs12,
      AOptions.ClientPkcs12Passphrase);
end;

{ Native parse of the anchors and the identity (with its passphrase) on a
  throwaway context, so a caller can reject bad material before dialing. }
procedure ValidateOpenSSLClientMaterial(
  const AOptions: TTransportSecurityClientOptions);
var
  Context: PSSL_CTX;
begin
  if (Length(AOptions.TrustAnchors) = 0) and
     (Length(AOptions.ClientPkcs12) = 0) then
    Exit;
  if not TryLoadOpenSSL then
    raise ETransportSecurityError.Create(OPENSSL_LOAD_ERROR);
  Context := CreateOpenSSLContext;
  try
    ConfigureOpenSSLClientOptions(Context, AOptions);
  finally
    SslCtxFree(Context);
  end;
end;

procedure ConfigureOpenSSLClientHostVerification(const ASSL: PSSL;
  const AHost: string);
var
  HostName: AnsiString;
  SetHostName: TSSLSetHostName;
begin
  HostName := AnsiString(AHost);
  SetHostName := TSSLSetHostName(GetProcedureAddress(SSLLibHandle,
    'SSL_set1_host'));
  if not Assigned(SetHostName) then
    raise ETransportSecurityError.Create('OpenSSL library does not provide SSL_set1_host; hostname verification unavailable');
  if SetHostName(ASSL, PAnsiChar(HostName)) <> 1 then
    raise ETransportSecurityError.Create('Failed to configure OpenSSL host verification');
end;

procedure RaiseOpenSSLClientVerificationFailure(const AVerifyResult: PtrInt);
var
  Reason: PAnsiChar;
begin
  Reason := OpenSSLClientVerifyErrorString(AVerifyResult);
  if Assigned(Reason) then
    raise ETransportSecurityVerificationError.CreateFmt('%s: %s',
      [TLS_VERIFICATION_ERROR, string(AnsiString(Reason))]);
  raise ETransportSecurityVerificationError.CreateFmt('%s: %d',
    [TLS_VERIFICATION_ERROR, AVerifyResult]);
end;

function OpenSSLPeerCertificate(
  const AConnection: TTransportSecurityConnection): TBytes;
var
  Certificate: Pointer;
  Data: TOpenSSLData;
  EncodedLength: LongInt;
  Output: PByte;
begin
  Result := nil;
  Data := TOpenSSLData(AConnection.BackendData);
  if not Assigned(Data) or not Assigned(Data.SSL) then
    Exit;
  LoadOpenSSLClientProcedures;
  Certificate := OpenSSLClientGetPeerCertificate(Data.SSL);
  if not Assigned(Certificate) then
    Exit;
  try
    EncodedLength := OpenSSLClientI2DX509(Certificate, nil);
    if EncodedLength <= 0 then
      Exit;
    SetLength(Result, EncodedLength);
    Output := @Result[0];
    if OpenSSLClientI2DX509(Certificate, @Output) <> EncodedLength then
      raise ETransportSecurityError.Create(
        'Failed to encode the TLS peer certificate');
  finally
    X509Free(Certificate);
  end;
end;

procedure StartOpenSSL(var AConnection: TTransportSecurityConnection;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AUseOptions: Boolean);
var
  Data: TOpenSSLData;
  ConnectResult, ErrorCode: Integer;
  VerifyResult: PtrInt;
begin
  if not TryLoadOpenSSL then
    raise ETransportSecurityError.Create(OPENSSL_LOAD_ERROR);

  Data := TOpenSSLData.Create;
  Data.Context := nil;
  Data.SSL := nil;
  try
    Data.Context := CreateOpenSSLContext;
    if AUseOptions then
      ConfigureOpenSSLClientOptions(Data.Context, AOptions);

    Data.SSL := SslNew(Data.Context);
    if not Assigned(Data.SSL) then
      raise ETransportSecurityError.Create('Failed to create OpenSSL session');

    if not AUseOptions then
      ConfigureOpenSSLVerification(Data.Context, Data.SSL, AHost)
    else if not AOptions.InsecureSkipVerify then
      ConfigureOpenSSLClientHostVerification(Data.SSL, AHost);

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
        begin
          if AUseOptions and not AOptions.InsecureSkipVerify then
          begin
            VerifyResult := SSLGetVerifyResult(Data.SSL);
            if VerifyResult <> X509_V_OK then
              RaiseOpenSSLClientVerificationFailure(VerifyResult);
          end;
          raise ETransportSecurityError.Create(TLS_HANDSHAKE_ERROR);
        end;
      end;
    until False;

    if not AUseOptions then
    begin
      if SSLGetVerifyResult(Data.SSL) <> X509_V_OK then
        raise ETransportSecurityVerificationError.Create('OpenSSL certificate verification failed');
    end
    else if not AOptions.InsecureSkipVerify then
    begin
      VerifyResult := SSLGetVerifyResult(Data.SSL);
      if VerifyResult <> X509_V_OK then
        RaiseOpenSSLClientVerificationFailure(VerifyResult);
    end;

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

type
  TOpenSSLPeekError = function: PtrUInt; cdecl;
  TOpenSSLReasonString = function(AError: PtrUInt): PAnsiChar; cdecl;

{ The reason text of the oldest queued OpenSSL error, or 'no reason'. Reads
  the queue without consuming it. }
function OpenSSLFirstErrorReason: string;
var
  PeekError: TOpenSSLPeekError;
  Reason: PAnsiChar;
  ReasonString: TOpenSSLReasonString;
  Code: PtrUInt;
begin
  Result := 'no reason';
  PeekError := TOpenSSLPeekError(GetProcedureAddress(SSLUtilHandle,
    'ERR_peek_error'));
  ReasonString := TOpenSSLReasonString(GetProcedureAddress(SSLUtilHandle,
    'ERR_reason_error_string'));
  if not Assigned(PeekError) or not Assigned(ReasonString) then
    Exit;
  Code := PeekError();
  if Code = 0 then
    Exit;
  Reason := ReasonString(Code);
  if Assigned(Reason) then
    Result := string(AnsiString(Reason));
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

  if (ErrorCode <> SSL_ERROR_WANT_READ) and
     (ErrorCode <> SSL_ERROR_WANT_WRITE) then
    RecordServerFailure(Format('OpenSSL server handshake failed: SSL error ' +
      '%d (%s), peer verification result %d', [ErrorCode,
      OpenSSLFirstErrorReason, SSLGetVerifyResult(Data.SSL)]));
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
    { Owned client identity (a TSChannelServerCredentialData whose persisted
      CNG key is deleted and published issuers withdrawn on release); nil
      without ClientPkcs12. }
    ClientIdentity: TObject;
    { In-memory store of the parsed trust anchors, built before the
      handshake; nil without anchors. }
    ClientAnchorStore: Pointer;
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
  ISC_REQ_USE_SUPPLIED_CREDS = $00000080;
  ISC_REQ_STREAM = $00008000;
  SCHANNEL_CRED_VERSION = 4;
  SCH_CREDENTIALS_VERSION = 5;
  SCH_CRED_MANUAL_CRED_VALIDATION = $00000008;
  SCH_CRED_NO_DEFAULT_CREDS = $00000010;
  SCH_USE_STRONG_CRYPTO = $00400000;
  SECPKG_ATTR_REMOTE_CERT_CONTEXT = $53;
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

{ '0x80090325 SEC_E_UNTRUSTED_ROOT' style text for SSPI statuses and the
  certificate-policy HRESULTs SChannel and crypt32 report. }
function SChannelStatusText(const AStatus: LongWord): string;
var
  Name: string;
begin
  case AStatus of
    $00000000: Name := 'SEC_E_OK';
    $00090312: Name := 'SEC_I_CONTINUE_NEEDED';
    $00090317: Name := 'SEC_I_CONTEXT_EXPIRED';
    $00090320: Name := 'SEC_I_INCOMPLETE_CREDENTIALS';
    $00090321: Name := 'SEC_I_RENEGOTIATE';
    $80090300: Name := 'SEC_E_INSUFFICIENT_MEMORY';
    $80090301: Name := 'SEC_E_INVALID_HANDLE';
    $80090302: Name := 'SEC_E_UNSUPPORTED_FUNCTION';
    $80090303: Name := 'SEC_E_TARGET_UNKNOWN';
    $80090304: Name := 'SEC_E_INTERNAL_ERROR';
    $80090308: Name := 'SEC_E_INVALID_TOKEN';
    $8009030C: Name := 'SEC_E_LOGON_DENIED';
    $8009030D: Name := 'SEC_E_UNKNOWN_CREDENTIALS';
    $8009030E: Name := 'SEC_E_NO_CREDENTIALS';
    $8009030F: Name := 'SEC_E_MESSAGE_ALTERED';
    $80090311: Name := 'SEC_E_NO_AUTHENTICATING_AUTHORITY';
    $80090318: Name := 'SEC_E_INCOMPLETE_MESSAGE';
    $80090322: Name := 'SEC_E_WRONG_PRINCIPAL';
    $80090325: Name := 'SEC_E_UNTRUSTED_ROOT';
    $80090326: Name := 'SEC_E_ILLEGAL_MESSAGE';
    $80090327: Name := 'SEC_E_CERT_UNKNOWN';
    $80090328: Name := 'SEC_E_CERT_EXPIRED';
    $80090330: Name := 'SEC_E_DECRYPT_FAILURE';
    $80090331: Name := 'SEC_E_ALGORITHM_MISMATCH';
    $80090349: Name := 'SEC_E_CERT_WRONG_USAGE';
    $8009035D: Name := 'SEC_E_INVALID_PARAMETER';
    $80090363: Name := 'SEC_E_MUTUAL_AUTH_FAILED';
    $80090367: Name := 'SEC_E_APPLICATION_PROTOCOL_MISMATCH';
    $800B0101: Name := 'CERT_E_EXPIRED';
    $800B0109: Name := 'CERT_E_UNTRUSTEDROOT';
    $800B010A: Name := 'CERT_E_CHAINING';
    $800B010F: Name := 'CERT_E_CN_NO_MATCH';
    $800B0110: Name := 'CERT_E_WRONG_USAGE';
    $80092012: Name := 'CRYPT_E_NO_REVOCATION_CHECK';
    $80092013: Name := 'CRYPT_E_REVOCATION_OFFLINE';
  else
    Name := '';
  end;
  Result := Format('0x%.8x', [AStatus]);
  if Name <> '' then
    Result := Result + ' ' + Name;
end;

{ Certificate statuses SChannel's own server validation ends a client
  handshake with: an untrusted, unknown, expired, misused, or misnamed
  server certificate, and every CERT_E_ trust-policy status. }
function SChannelStatusIsVerificationFailure(const AStatus: LongWord): Boolean;
begin
  case AStatus of
    $80090322, { SEC_E_WRONG_PRINCIPAL }
    $80090325, { SEC_E_UNTRUSTED_ROOT }
    $80090327, { SEC_E_CERT_UNKNOWN }
    $80090328, { SEC_E_CERT_EXPIRED }
    $80090349, { SEC_E_CERT_WRONG_USAGE }
    $80090352: { SEC_E_ISSUING_CA_UNTRUSTED }
      Result := True;
  else
    Result := (AStatus and $FFFFFF00) = $800B0100;
  end;
end;

{ A handshake that ends because the server closed the connection names the
  last status the client saw and whether it answered a certificate request
  anonymously, which is where a refused client identity shows up. }
procedure RaiseSChannelClientHandshakeClosed(const ALastStatus: LongWord;
  const AReceiveCount: Integer; const ARetriedWithSuppliedCredentials: Boolean);
var
  Detail: string;
begin
  if AReceiveCount < 0 then
    Detail := Format('client socket receive failed (WSA %d)',
      [WSAGetLastError])
  else
    Detail := 'the server closed the connection';
  Detail := Detail + ' after ' + SChannelStatusText(ALastStatus);
  if ARetriedWithSuppliedCredentials then
    Detail := Detail +
      '; SChannel had reported SEC_I_INCOMPLETE_CREDENTIALS for the server''s certificate request';
  if AReceiveCount < 0 then
    raise ETransportSecurityError.CreateFmt('%s: %s (client handshake)',
      [TLS_READ_ERROR, Detail]);
  raise ETransportSecurityError.CreateFmt('%s: %s (client handshake)',
    [TLS_HANDSHAKE_ERROR, Detail]);
end;

function SChannelRequestFlags: LongWord;
begin
  Result := ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or
    ISC_REQ_ALLOCATE_MEMORY or ISC_REQ_STREAM;
end;

{ Client options on SChannel (ADR-0050). The crypt32 declarations these need
  live with the SChannel server backend further down, so the option-specific
  steps are forward-declared here and defined there. }
procedure PrepareSChannelClientCredential(
  const AOptions: TTransportSecurityClientOptions;
  var ACredential: TSchannelCred; var AIdentity: TObject;
  var AAnchorStore: Pointer); forward;
procedure ReleaseSChannelClientState(var AIdentity: TObject;
  var AAnchorStore: Pointer); forward;
procedure VerifySChannelClientPeer(const AContext: TSecHandle;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AAnchorStore: Pointer); forward;

procedure StartSChannel(var AConnection: TTransportSecurityConnection;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AUseOptions: Boolean);
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
  RequestFlags: LongWord;
begin
  Data := TSChannelData.Create;
  FillChar(Data.Credential, SizeOf(Data.Credential), 0);
  FillChar(Data.Context, SizeOf(Data.Context), 0);
  FillChar(Data.StreamSizes, SizeOf(Data.StreamSizes), 0);
  Data.Socket := AConnection.Socket;
  Data.HasContext := False;
  Data.ClientIdentity := nil;
  Data.ClientAnchorStore := nil;

  FillChar(Credential, SizeOf(Credential), 0);
  Credential.dwVersion := SCHANNEL_CRED_VERSION;
  Credential.dwFlags := SCH_USE_STRONG_CRYPTO;
  RequestFlags := SChannelRequestFlags;

  if AUseOptions then
  try
    PrepareSChannelClientCredential(AOptions, Credential,
      Data.ClientIdentity, Data.ClientAnchorStore);
  except
    ReleaseSChannelClientState(Data.ClientIdentity, Data.ClientAnchorStore);
    Data.Free;
    raise;
  end;

  Status := AcquireCredentialsHandleW(nil, PWideChar(WideString(UNISP_NAME)),
    SECPKG_CRED_OUTBOUND, nil, @Credential, nil, nil, @Data.Credential,
    @Expiry);
  if Status <> SEC_E_OK then
  begin
    ReleaseSChannelClientState(Data.ClientIdentity, Data.ClientAnchorStore);
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
        PWideChar(TargetName), RequestFlags, 0,
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
        if ReceiveCount <= 0 then
          RaiseSChannelClientHandshakeClosed(LongWord(Status), ReceiveCount,
            (RequestFlags and ISC_REQ_USE_SUPPLIED_CREDS) <> 0);
        Continue;
      end;

      { With options, a server certificate request is answered with exactly
        the supplied credential, which may be none: retry once with the same
        input and ISC_REQ_USE_SUPPLIED_CREDS, as the SSPI contract allows.
        The server then decides whether to accept an anonymous client. }
      if AUseOptions and (Status = SEC_I_INCOMPLETE_CREDENTIALS) and
         ((RequestFlags and ISC_REQ_USE_SUPPLIED_CREDS) = 0) then
      begin
        RequestFlags := RequestFlags or ISC_REQ_USE_SUPPLIED_CREDS;
        Continue;
      end;

      if (InputDescPointer <> nil) and
         (SecBufferKind(InputBuffers[1].BufferType) = SECBUFFER_EXTRA) then
        PreserveExtraBytes(Data.EncryptedInput, InputBuffers[1].pvBuffer,
          InputBuffers[1].cbBuffer)
      else
        SetLength(Data.EncryptedInput, 0);

      if Status = SEC_I_INCOMPLETE_CREDENTIALS then
      begin
        if Assigned(Data.ClientIdentity) then
          raise ETransportSecurityError.CreateFmt(
            '%s: SChannel did not accept the configured client identity for the server''s certificate request (%s, client handshake)',
            [TLS_HANDSHAKE_ERROR, SChannelStatusText(LongWord(Status))]);
        raise ETransportSecurityError.CreateFmt(
          '%s: the server requested a client certificate (%s, client handshake)',
          [TLS_HANDSHAKE_ERROR, SChannelStatusText(LongWord(Status))]);
      end;

      if Status = SEC_I_CONTINUE_NEEDED then
      begin
        if Length(Data.EncryptedInput) = 0 then
        begin
          ReceiveCount := ReceiveIntoBuffer(AConnection,
            Data.EncryptedInput);
          if ReceiveCount <= 0 then
            RaiseSChannelClientHandshakeClosed(LongWord(Status),
              ReceiveCount,
              (RequestFlags and ISC_REQ_USE_SUPPLIED_CREDS) <> 0);
        end;
        Continue;
      end;

      { Without options SChannel validates the server itself and fails
        the handshake with a certificate status. }
      if SChannelStatusIsVerificationFailure(LongWord(Status)) then
        raise ETransportSecurityVerificationError.CreateFmt(
          '%s: %s (client handshake)',
          [TLS_HANDSHAKE_ERROR, SChannelStatusText(LongWord(Status))]);
      if Status <> SEC_E_OK then
        raise ETransportSecurityError.CreateFmt('%s: %s (client handshake)',
          [TLS_HANDSHAKE_ERROR, SChannelStatusText(LongWord(Status))]);
    until Status = SEC_E_OK;

    Status := QueryContextAttributesW(@Data.Context, SECPKG_ATTR_STREAM_SIZES,
      @Data.StreamSizes);
    if Status <> SEC_E_OK then
      raise ETransportSecurityError.CreateFmt('Failed to query SChannel stream sizes: 0x%x',
        [LongWord(Status)]);

    if AUseOptions then
      VerifySChannelClientPeer(Data.Context, AHost, AOptions,
        Data.ClientAnchorStore);

    AConnection.BackendData := Data;
    AConnection.Backend := TSB_SCHANNEL;
    AConnection.Active := True;
  except
    if Data.HasContext then
      DeleteSecurityContext(@Data.Context);
    FreeCredentialsHandle(@Data.Credential);
    ReleaseSChannelClientState(Data.ClientIdentity, Data.ClientAnchorStore);
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
    ReleaseSChannelClientState(Data.ClientIdentity, Data.ClientAnchorStore);
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

  { A CNG key container persisted by PFXImportCertStore and owned by one
    credential holder. Handle is 0 when the key could not be opened through
    its certificate; the container is then deleted by name. }
  TSChannelImportedKey = record
    ContainerName: UnicodeString;
    Handle: PtrUInt;
    ProviderName: UnicodeString;
  end;

  TSChannelImportedKeyArray = array of TSChannelImportedKey;

  TSChannelServerCredentialData = class
  public
    Certificate: PCertContext;
    Credential: TSecHandle;
    HasCredential: Boolean;
    { Every key container the import persisted, not only the selected
      identity's: PFXImportCertStore persists one per keyed certificate. }
    ImportedKeys: TSChannelImportedKeyArray;
    IssuerStore: HCERTSTORE;
    KeyContainerName: UnicodeString;
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
    { Set only by the test-only client-certificate seam, together with the
      anchors the client's chain must reach. }
    RequireClientCertificate: Boolean;
    ClientAnchorStore: HCERTSTORE;
  end;

  { Chain-engine and chain-policy structures for the client trust-anchor
    check (ADR-0050). Only the leading fields each API reads are declared;
    cbSize tells crypt32 which revision the caller supplies. }
  TCertChainEngineConfig = record
    cbSize: LongWord;
    hRestrictedRoot: HCERTSTORE;
    hRestrictedTrust: HCERTSTORE;
    hRestrictedOther: HCERTSTORE;
    cAdditionalStore: LongWord;
    rghAdditionalStore: Pointer;
    dwFlags: LongWord;
    dwUrlRetrievalTimeout: LongWord;
    MaximumCachedCertificates: LongWord;
    CycleDetectionModulus: LongWord;
    hExclusiveRoot: HCERTSTORE;
    hExclusiveTrustedPeople: HCERTSTORE;
    dwExclusiveFlags: LongWord;
  end;

  TCertEnhancedKeyUsageRequest = record
    cUsageIdentifier: LongWord;
    rgpszUsageIdentifier: PPAnsiCharLWPT;
  end;

  TCertUsageMatch = record
    dwType: LongWord;
    Usage: TCertEnhancedKeyUsageRequest;
  end;

  TCertChainPara = record
    cbSize: LongWord;
    RequestedUsage: TCertUsageMatch;
  end;

  TSSLExtraCertChainPolicyPara = record
    cbSize: LongWord;
    dwAuthType: LongWord;
    fdwChecks: LongWord;
    pwszServerName: PWideChar;
  end;

  TCertChainPolicyPara = record
    cbSize: LongWord;
    dwFlags: LongWord;
    pvExtraPolicyPara: Pointer;
  end;

  TCertChainPolicyStatus = record
    cbSize: LongWord;
    dwError: LongWord;
    lChainIndex: LongInt;
    lElementIndex: LongInt;
    pvExtraPolicyStatus: Pointer;
  end;

  { Leading fields of CERT_CHAIN_CONTEXT, CERT_SIMPLE_CHAIN, and
    CERT_CHAIN_ELEMENT; the structures are only read through the pointers
    CertGetCertificateChain returns. }
  TCertTrustStatus = record
    dwErrorStatus: LongWord;
    dwInfoStatus: LongWord;
  end;

  PCertChainElementLWPT = ^TCertChainElementLWPT;
  TCertChainElementLWPT = record
    cbSize: LongWord;
    pCertContext: PCertContext;
    TrustStatus: TCertTrustStatus;
  end;

  PCertSimpleChainLWPT = ^TCertSimpleChainLWPT;
  TCertSimpleChainLWPT = record
    cbSize: LongWord;
    TrustStatus: TCertTrustStatus;
    cElement: LongWord;
    rgpElement: ^PCertChainElementLWPT;
  end;

  PCertChainContextLWPT = ^TCertChainContextLWPT;
  TCertChainContextLWPT = record
    cbSize: LongWord;
    TrustStatus: TCertTrustStatus;
    cChain: LongWord;
    rgpChain: ^PCertSimpleChainLWPT;
  end;

  { What one chain evaluation found, for diagnostics and the test seam. }
  TSChannelChainReport = record
    ChainErrorStatus: LongWord;
    ElementCount: Integer;
    IntermediatesFromPeer: Boolean;
    PeerStoreCount: Integer;
    PolicyError: LongWord;
    { Empty when both chain calls ran; otherwise which call failed to
      execute and its GetLastError. PolicyError then reports no verdict. }
    ExecutionFailure: string;
  end;

{$IFDEF CPU64}
  {$IF SizeOf(TCertChainEngineConfig) <> 88}
    {$FATAL CERT_CHAIN_ENGINE_CONFIG layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPara) <> 32}
    {$FATAL CERT_CHAIN_PARA layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TSSLExtraCertChainPolicyPara) <> 24}
    {$FATAL SSL_EXTRA_CERT_CHAIN_POLICY_PARA layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPolicyPara) <> 16}
    {$FATAL CERT_CHAIN_POLICY_PARA layout mismatch on 64-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPolicyStatus) <> 24}
    {$FATAL CERT_CHAIN_POLICY_STATUS layout mismatch on 64-bit Windows}
  {$ENDIF}
{$ELSE}
  {$IF SizeOf(TCertChainEngineConfig) <> 52}
    {$FATAL CERT_CHAIN_ENGINE_CONFIG layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPara) <> 16}
    {$FATAL CERT_CHAIN_PARA layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TSSLExtraCertChainPolicyPara) <> 16}
    {$FATAL SSL_EXTRA_CERT_CHAIN_POLICY_PARA layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPolicyPara) <> 12}
    {$FATAL CERT_CHAIN_POLICY_PARA layout mismatch on 32-bit Windows}
  {$ENDIF}
  {$IF SizeOf(TCertChainPolicyStatus) <> 20}
    {$FATAL CERT_CHAIN_POLICY_STATUS layout mismatch on 32-bit Windows}
  {$ENDIF}
{$ENDIF}

const
  SECPKG_CRED_INBOUND = 1;
  ASC_REQ_MUTUAL_AUTH = $00000002;
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
function CertOpenStore(AStoreProvider: PAnsiChar; AEncodingType: LongWord;
  ACryptProvider: PtrUInt; AFlags: LongWord;
  AParameter: Pointer): HCERTSTORE; stdcall;
  external 'crypt32.dll' name 'CertOpenStore';
function CertAddEncodedCertificateToStore(AStore: HCERTSTORE;
  AEncodingType: LongWord; AEncoded: PByte; AEncodedLength: LongWord;
  ADisposition: LongWord; AStoreContext: PPCertContext): LongBool; stdcall;
  external 'crypt32.dll' name 'CertAddEncodedCertificateToStore';
function CertCreateCertificateChainEngine(
  var AConfig: TCertChainEngineConfig; out AEngine: Pointer): LongBool;
  stdcall; external 'crypt32.dll' name 'CertCreateCertificateChainEngine';
procedure CertFreeCertificateChainEngine(AEngine: Pointer); stdcall;
  external 'crypt32.dll' name 'CertFreeCertificateChainEngine';
function CertGetCertificateChain(AEngine: Pointer;
  ACertificate: PCertContext; ATime: Pointer; AAdditionalStore: HCERTSTORE;
  var AChainPara: TCertChainPara; AFlags: LongWord; AReserved: Pointer;
  out AChain: Pointer): LongBool; stdcall;
  external 'crypt32.dll' name 'CertGetCertificateChain';
procedure CertFreeCertificateChain(AChain: Pointer); stdcall;
  external 'crypt32.dll' name 'CertFreeCertificateChain';
function CertVerifyCertificateChainPolicy(APolicy: PAnsiChar;
  AChain: Pointer; var APolicyPara: TCertChainPolicyPara;
  var APolicyStatus: TCertChainPolicyStatus): LongBool; stdcall;
  external 'crypt32.dll' name 'CertVerifyCertificateChainPolicy';

const
  NTE_BAD_KEYSET_LWPT = LongInt($80090016);

{$IFNDEF PRODUCTION}
var
  SChannelTestImportedKeyContainers: TUnicodeStringArray;
  { 0, or the chain call the test seam makes fail to execute. }
  SChannelTestChainExecutionFailure: Integer;
{$ENDIF}

function NCryptOpenStorageProvider(out AProvider: PtrUInt;
  AProviderName: PWideChar; AFlags: LongWord): LongInt; stdcall;
  external 'ncrypt.dll' name 'NCryptOpenStorageProvider';
function NCryptOpenKey(AProvider: PtrUInt; out AKey: PtrUInt;
  AKeyName: PWideChar; ALegacyKeySpec, AFlags: LongWord): LongInt; stdcall;
  external 'ncrypt.dll' name 'NCryptOpenKey';

{ Opens a user-scope CNG key by container name. Returns the NCrypt status;
  NTE_BAD_KEYSET means the container does not exist. }
function OpenSChannelKeyContainer(const AProviderName,
  AContainerName: UnicodeString; out AKey: PtrUInt): LongInt;
var
  Provider: PtrUInt;
  ProviderName: PWideChar;
begin
  AKey := 0;
  Provider := 0;
  ProviderName := nil;
  if AProviderName <> '' then
    ProviderName := PWideChar(AProviderName);
  Result := NCryptOpenStorageProvider(Provider, ProviderName, 0);
  if Result <> 0 then
    Exit;
  try
    Result := NCryptOpenKey(Provider, AKey, PWideChar(AContainerName), 0,
      NCRYPT_SILENT_FLAG);
  finally
    NCryptFreeObject(Provider);
  end;
end;

{ Deletes every recorded container. NCryptDeleteKey both removes the
  container and frees the handle; NCryptFreeObject is the fallback so a
  failed delete still releases the handle. A key recorded without a handle
  is reopened by name so no container is left behind on any path. }
procedure DeleteSChannelImportedKeys(var AKeys: TSChannelImportedKeyArray);
var
  I: Integer;
  Key: PtrUInt;
begin
  for I := High(AKeys) downto 0 do
  begin
    Key := AKeys[I].Handle;
    if (Key = 0) and (AKeys[I].ContainerName <> '') and
       (OpenSChannelKeyContainer(AKeys[I].ProviderName,
       AKeys[I].ContainerName, Key) <> 0) then
      Key := 0;
    if Key <> 0 then
      if NCryptDeleteKey(Key, NCRYPT_SILENT_FLAG) <> 0 then
        NCryptFreeObject(Key);
    AKeys[I].Handle := 0;
  end;
  SetLength(AKeys, 0);
end;

constructor TSChannelServerCredentialData.Create;
begin
  inherited Create;
  FillChar(Credential, SizeOf(Credential), 0);
  Certificate := nil;
  HasCredential := False;
  SetLength(ImportedKeys, 0);
  IssuerStore := nil;
  KeyContainerName := '';
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
  { The imported private keys are persisted, so the holder owns containers
    that must not outlive it. Deletion happens only here, at the last
    reference, which is what lets a reloaded-away snapshot keep serving live
    connections until they finish. }
  DeleteSChannelImportedKeys(ImportedKeys);
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
function SChannelKeyProviderNames(const ACertificate: PCertContext;
  out AContainerName, AProviderName: UnicodeString): Boolean;
var
  Buffer: TBytes;
  BufferLength: LongWord;
  ProviderInfo: PCryptKeyProviderInfo;
begin
  Result := False;
  AContainerName := '';
  AProviderName := '';
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
    AContainerName := UnicodeString(WideString(
      ProviderInfo^.pwszContainerName));
  if Assigned(ProviderInfo^.pwszProvName) then
    AProviderName := UnicodeString(WideString(ProviderInfo^.pwszProvName));
  Result := AContainerName <> '';
end;

function SChannelServerKeyContainerName(
  const ACertificate: PCertContext): UnicodeString;
var
  ProviderName: UnicodeString;
begin
  SChannelKeyProviderNames(ACertificate, Result, ProviderName);
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

{ Imports a PKCS#12 identity into a credential holder that owns the store,
  the leaf context, and the persisted CNG key container, which Release
  deletes. Shared by server snapshots and outbound client identities. }
{ Claims every key the import persisted, then selects the single identity.
  PFXImportCertStore persists one container per keyed certificate, so each
  is recorded before anything can fail: from here on every exit, including
  a multi-identity rejection, strict-validation rejection, and
  credential-acquisition failure, runs Release, which deletes them all. }
procedure RecordSChannelImportedKeys(
  const ASnapshot: TSChannelServerCredentialData);
var
  CallerOwnsKey: LongBool;
  ContainerName: UnicodeString;
  Found: PCertContext;
  Index: Integer;
  KeyHandle: PtrUInt;
  KeySpecification: LongWord;
  OwnedKeys: Integer;
  ProviderName: UnicodeString;
begin
  OwnedKeys := 0;
  Found := CertFindCertificateInStore(ASnapshot.Store, CERT_ENCODING_TYPES, 0,
    CERT_FIND_HAS_PRIVATE_KEY, nil, nil);
  try
    while Assigned(Found) do
    begin
      SChannelKeyProviderNames(Found, ContainerName, ProviderName);
      Index := Length(ASnapshot.ImportedKeys);
      SetLength(ASnapshot.ImportedKeys, Index + 1);
      ASnapshot.ImportedKeys[Index].ContainerName := ContainerName;
      ASnapshot.ImportedKeys[Index].ProviderName := ProviderName;
      ASnapshot.ImportedKeys[Index].Handle := 0;
      {$IFNDEF PRODUCTION}
      SetLength(SChannelTestImportedKeyContainers,
        Length(SChannelTestImportedKeyContainers) + 1);
      SChannelTestImportedKeyContainers[
        High(SChannelTestImportedKeyContainers)] := ContainerName;
      {$ENDIF}
      KeyHandle := 0;
      KeySpecification := 0;
      CallerOwnsKey := False;
      if CryptAcquireCertificatePrivateKey(Found,
         CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG or CRYPT_ACQUIRE_SILENT_FLAG, nil,
         KeyHandle, KeySpecification, CallerOwnsKey) and CallerOwnsKey then
      begin
        ASnapshot.ImportedKeys[Index].Handle := KeyHandle;
        if KeySpecification = CERT_NCRYPT_KEY_SPEC then
          Inc(OwnedKeys);
      end;
      if not Assigned(ASnapshot.Certificate) then
        ASnapshot.Certificate := CertDuplicateCertificateContext(Found);
      Found := CertFindCertificateInStore(ASnapshot.Store,
        CERT_ENCODING_TYPES, 0, CERT_FIND_HAS_PRIVATE_KEY, nil, Found);
    end;
  finally
    if Assigned(Found) then
      CertFreeCertificateContext(Found);
  end;
  if Length(ASnapshot.ImportedKeys) = 0 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity must contain a certificate and private key');
  if Length(ASnapshot.ImportedKeys) > 1 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity must contain exactly one certificate with a private key');
  if OwnedKeys <> 1 then
    raise ETransportSecurityError.Create(
      'Configured TLS PKCS#12 identity did not import into an owned CNG key');
  ASnapshot.KeyContainerName := ASnapshot.ImportedKeys[0].ContainerName;
end;

function ImportSChannelPkcs12Identity(const APkcs12Identity: TBytes;
  const APkcs12Passphrase: UnicodeString): TSChannelServerCredentialData;
var
  Identity: TBytes;
  IdentityBlob: TCryptDataBlob;
  Passphrase: array of WideChar;
  Snapshot: TSChannelServerCredentialData;
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
      key operations in lsass, which cannot reach an in-process ephemeral
      key: importing with PKCS12_NO_PERSIST_KEY makes
      AcquireCredentialsHandle fail with SEC_E_NO_CREDENTIALS. The holder
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
    {$IFNDEF PRODUCTION}
    SetLength(SChannelTestImportedKeyContainers, 0);
    {$ENDIF}
    RecordSChannelImportedKeys(Snapshot);
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

function CreateSChannelServerSnapshot(const APkcs12Identity: TBytes;
  const APkcs12Passphrase: UnicodeString;
  const AValidation: TTransportSecurityServerIdentityValidation):
  TSChannelServerCredentialData;
var
  AuthenticationData: Pointer;
  Expiry: SECURITY_INTEGER;
  LegacyCredentials: TSchannelCred;
  ModernCredentials: TSchCredentials;
  Snapshot: TSChannelServerCredentialData;
  Status: SECURITY_STATUS;
  TlsParameters: TTlsParameters;
begin
  Result := nil;
  Snapshot := ImportSChannelPkcs12Identity(APkcs12Identity,
    APkcs12Passphrase);
  try
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
  end;
end;

{ Client options on SChannel (ADR-0050).

  The client identity reuses the server's import: SChannel signs the client
  CertificateVerify in lsass as well, so the key is persisted in the user's
  CNG provider and the holder deletes it when the connection closes.

  Trust anchors use SCH_CRED_MANUAL_CRED_VALIDATION, so SChannel completes the
  handshake without judging the server and VerifySChannelClientPeer runs the
  chain and SSL policy itself. The anchors are evaluated first, offline, in
  an engine whose hExclusiveRoot is an in-memory store of the anchors.
  System plus anchors is not one native evaluation on Windows: when the
  anchors do not accept the peer, the current user's default engine is
  tried second with Windows' own retrieval behaviour, and either success
  accepts the peer. InsecureSkipVerify also uses manual validation and then
  skips the check. Without anchors or insecure mode SChannel's automatic
  validation stays in charge, exactly as without options. }
{ Parses the anchors with crypt32 into an in-memory store. Raises on the
  first certificate crypt32 cannot decode. }
function CreateSChannelAnchorStore(const AAnchors: TBytes): HCERTSTORE;
const
  CERT_STORE_PROV_MEMORY = 2;
  CERT_STORE_ADD_USE_EXISTING = 2;
var
  Anchors: TTransportSecurityCertificateList;
  I: Integer;
begin
  Anchors := ParseTransportSecurityTrustAnchors(AAnchors);
  Result := CertOpenStore(PAnsiChar(PtrUInt(CERT_STORE_PROV_MEMORY)), 0, 0,
    0, nil);
  if not Assigned(Result) then
    raise ETransportSecurityError.Create(
      'Failed to create the TLS trust-anchor store');
  try
    for I := 0 to High(Anchors) do
      if not CertAddEncodedCertificateToStore(Result, X509_ASN_ENCODING,
        @Anchors[I][0], Length(Anchors[I]), CERT_STORE_ADD_USE_EXISTING,
        nil) then
        raise ETransportSecurityError.CreateFmt(
          'Configured TLS trust anchor %d is not a valid X.509 certificate',
          [I + 1]);
  except
    CertCloseStore(Result, 0);
    raise;
  end;
end;

procedure PrepareSChannelClientCredential(
  const AOptions: TTransportSecurityClientOptions;
  var ACredential: TSchannelCred; var AIdentity: TObject;
  var AAnchorStore: Pointer);
var
  Identity: TSChannelServerCredentialData;
begin
  ACredential.dwFlags := ACredential.dwFlags or SCH_CRED_NO_DEFAULT_CREDS;
  if AOptions.InsecureSkipVerify or (Length(AOptions.TrustAnchors) > 0) then
    ACredential.dwFlags := ACredential.dwFlags or
      SCH_CRED_MANUAL_CRED_VALIDATION;
  { Anchors are parsed before the first handshake byte, so a malformed
    anchor never reaches the network. }
  if Length(AOptions.TrustAnchors) > 0 then
    AAnchorStore := CreateSChannelAnchorStore(AOptions.TrustAnchors);
  if Length(AOptions.ClientPkcs12) > 0 then
  begin
    Identity := ImportSChannelPkcs12Identity(AOptions.ClientPkcs12,
      AOptions.ClientPkcs12Passphrase);
    AIdentity := Identity;
    { SChannel builds the outgoing client Certificate message from the
      Windows stores, exactly as for a server, so the bundle's
      intermediates are published for the connection's lifetime and
      withdrawn when the identity is released. }
    PublishSChannelServerIssuers(Identity);
    ACredential.cCreds := 1;
    ACredential.paCred := @Identity.Certificate;
  end;
end;

procedure ReleaseSChannelClientState(var AIdentity: TObject;
  var AAnchorStore: Pointer);
var
  Identity: TSChannelServerCredentialData;
begin
  if Assigned(AAnchorStore) then
  begin
    CertCloseStore(AAnchorStore, 0);
    AAnchorStore := nil;
  end;
  if not Assigned(AIdentity) then
    Exit;
  Identity := TSChannelServerCredentialData(AIdentity);
  AIdentity := nil;
  Identity.Release;
end;

function CountStoreCertificates(const AStore: HCERTSTORE): Integer;
var
  Enumerated: PCertContext;
begin
  Result := 0;
  if not Assigned(AStore) then
    Exit;
  Enumerated := CertEnumCertificatesInStore(AStore, nil);
  while Assigned(Enumerated) do
  begin
    Inc(Result);
    Enumerated := CertEnumCertificatesInStore(AStore, Enumerated);
  end;
end;

function SChannelStoreHasCertificate(const AStore: HCERTSTORE;
  const ACertificate: PCertContext): Boolean;
const
  CERT_FIND_EXISTING = $000D0000;
var
  Found: PCertContext;
begin
  Found := CertFindCertificateInStore(AStore, CERT_ENCODING_TYPES, 0,
    CERT_FIND_EXISTING, ACertificate, nil);
  Result := Assigned(Found);
  if Result then
    CertFreeCertificateContext(Found);
end;

{ Builds APeer's chain in AEngine (nil for the current user's default
  engine), with APeer's own store as the extra source of intermediates, and
  applies the SSL chain policy for the given authentication direction.
  AReport.PolicyError is 0 when the chain is acceptable; the report also
  records the chain trust flags and whether every intermediate the chain
  used was among the certificates the peer sent. }
procedure SChannelEvaluateChain(const AEngine: Pointer;
  const APeer: PCertContext; const AHost: string;
  const AServerAuthentication: Boolean; const AChainFlags: LongWord;
  out AReport: TSChannelChainReport);
const
  CERT_CHAIN_POLICY_SSL = 4;
  AUTHTYPE_CLIENT = 1;
  AUTHTYPE_SERVER = 2;
  USAGE_MATCH_TYPE_AND = 0;
  CERT_E_CHAINING_LWPT = LongWord($800B010A);
  OID_CLIENT_AUTHENTICATION = '1.3.6.1.5.5.7.3.2';
var
  Chain: Pointer;
  ChainContext: PCertChainContextLWPT;
  ChainPara: TCertChainPara;
  Element: PCertChainElementLWPT;
  I: Integer;
  PolicyPara: TCertChainPolicyPara;
  PolicyStatus: TCertChainPolicyStatus;
  ServerName: UnicodeString;
  SimpleChain: PCertSimpleChainLWPT;
  SSLPara: TSSLExtraCertChainPolicyPara;
  Usages: array[0..0] of PAnsiChar;
begin
  FillChar(AReport, SizeOf(AReport), 0);
  AReport.PolicyError := CERT_E_CHAINING_LWPT;
  AReport.PeerStoreCount := CountStoreCertificates(APeer^.hCertStore);
  if AServerAuthentication then
    Usages[0] := PAnsiChar(OID_SERVER_AUTHENTICATION)
  else
    Usages[0] := PAnsiChar(OID_CLIENT_AUTHENTICATION);
  FillChar(ChainPara, SizeOf(ChainPara), 0);
  ChainPara.cbSize := SizeOf(ChainPara);
  ChainPara.RequestedUsage.dwType := USAGE_MATCH_TYPE_AND;
  ChainPara.RequestedUsage.Usage.cUsageIdentifier := 1;
  ChainPara.RequestedUsage.Usage.rgpszUsageIdentifier := @Usages[0];
  Chain := nil;
  {$IFNDEF PRODUCTION}
  if SChannelTestChainExecutionFailure = 1 then
  begin
    AReport.ExecutionFailure := 'CertGetCertificateChain failed: '
      + SChannelStatusText(LongWord(14 { ERROR_OUTOFMEMORY }));
    Exit;
  end;
  {$ENDIF}
  if not CertGetCertificateChain(AEngine, APeer, nil, APeer^.hCertStore,
    ChainPara, AChainFlags, nil, Chain) or not Assigned(Chain) then
  begin
    AReport.ExecutionFailure := 'CertGetCertificateChain failed: '
      + SChannelStatusText(LongWord(Windows.GetLastError));
    Exit;
  end;
  try
    ChainContext := PCertChainContextLWPT(Chain);
    AReport.ChainErrorStatus := ChainContext^.TrustStatus.dwErrorStatus;
    AReport.IntermediatesFromPeer := True;
    if ChainContext^.cChain > 0 then
    begin
      SimpleChain := ChainContext^.rgpChain^;
      AReport.ElementCount := SimpleChain^.cElement;
      { Element 0 is the peer's leaf and the last element the root; every
        element between them is an intermediate. }
      for I := 1 to Integer(SimpleChain^.cElement) - 2 do
      begin
        Element := PCertChainElementLWPT(PPointer(PtrUInt(
          SimpleChain^.rgpElement) + PtrUInt(I) * SizeOf(Pointer))^);
        if not SChannelStoreHasCertificate(APeer^.hCertStore,
           Element^.pCertContext) then
          AReport.IntermediatesFromPeer := False;
      end;
    end;
    ServerName := UnicodeString(AHost);
    FillChar(SSLPara, SizeOf(SSLPara), 0);
    SSLPara.cbSize := SizeOf(SSLPara);
    if AServerAuthentication then
    begin
      SSLPara.dwAuthType := AUTHTYPE_SERVER;
      SSLPara.pwszServerName := PWideChar(ServerName);
    end
    else
      SSLPara.dwAuthType := AUTHTYPE_CLIENT;
    FillChar(PolicyPara, SizeOf(PolicyPara), 0);
    PolicyPara.cbSize := SizeOf(PolicyPara);
    PolicyPara.pvExtraPolicyPara := @SSLPara;
    FillChar(PolicyStatus, SizeOf(PolicyStatus), 0);
    PolicyStatus.cbSize := SizeOf(PolicyStatus);
    { A False result means the policy check could not run, not that it
      rejected the chain; only a completed check reports dwError. }
    {$IFNDEF PRODUCTION}
    if SChannelTestChainExecutionFailure = 2 then
      AReport.ExecutionFailure := 'CertVerifyCertificateChainPolicy failed: '
        + SChannelStatusText(LongWord(14 { ERROR_OUTOFMEMORY }))
    else
    {$ENDIF}
    if CertVerifyCertificateChainPolicy(
      PAnsiChar(PtrUInt(CERT_CHAIN_POLICY_SSL)), Chain, PolicyPara,
      PolicyStatus) then
      AReport.PolicyError := PolicyStatus.dwError
    else
      AReport.ExecutionFailure := 'CertVerifyCertificateChainPolicy failed: '
        + SChannelStatusText(LongWord(Windows.GetLastError));
  finally
    CertFreeCertificateChain(Chain);
  end;
end;

{ An evaluation that could not run is an operational failure, which a
  retry may overcome, never a verdict on the peer. }
procedure RequireSChannelChainEvaluated(const AReport: TSChannelChainReport);
begin
  if AReport.ExecutionFailure <> '' then
    raise ETransportSecurityError.CreateFmt(
      'TLS certificate chain evaluation could not run: %s',
      [AReport.ExecutionFailure]);
end;

function SChannelChainPolicyError(const AEngine: Pointer;
  const APeer: PCertContext; const AHost: string;
  const AServerAuthentication: Boolean; const AChainFlags: LongWord):
  LongWord;
var
  Report: TSChannelChainReport;
begin
  SChannelEvaluateChain(AEngine, APeer, AHost, AServerAuthentication,
    AChainFlags, Report);
  RequireSChannelChainEvaluated(Report);
  Result := Report.PolicyError;
end;

function DescribeSChannelChainReport(
  const AReport: TSChannelChainReport): string;
begin
  Result := Format('policy %s, chain trust errors 0x%.8x, %d chain ' +
    'element(s), %d certificate(s) received',
    [SChannelStatusText(AReport.PolicyError), AReport.ChainErrorStatus,
     AReport.ElementCount, AReport.PeerStoreCount]);
end;

{ Chain evaluation in an engine whose only roots are AAnchors (ADR-0050).
  A private anchor set is evaluated offline: the engine and the chain call
  use cached URL retrieval only, fetch no issuer through AIA, and never
  trigger the automatic root-store update, so an unreachable URL in a
  certificate, or Windows Update being unreachable, can never stall the
  handshake. The retrieval timeout is also bounded in case a platform
  ignores the cache-only request. Revocation is not checked, exactly as in
  the option-less SChannel client. With ARequirePeerIntermediates the
  evaluation also fails unless every intermediate the chain used arrived in
  the peer's own certificate message. System stores are still searched for
  intermediates, so that check is explicit rather than a quirk of engine
  restriction. }
procedure SChannelEvaluateAnchorChain(const AAnchors: HCERTSTORE;
  const APeer: PCertContext; const AHost: string;
  const AServerAuthentication, ARequirePeerIntermediates: Boolean;
  out AReport: TSChannelChainReport);
const
  CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL = $00000004;
  CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE = $00000100;
  CERT_CHAIN_DISABLE_AIA = $00002000;
  ANCHOR_URL_RETRIEVAL_TIMEOUT_MILLISECONDS = 1000;
var
  ChainFlags: LongWord;
  Config: TCertChainEngineConfig;
  Engine: Pointer;
begin
  FillChar(Config, SizeOf(Config), 0);
  Config.cbSize := SizeOf(Config);
  Config.hExclusiveRoot := AAnchors;
  Config.dwFlags := CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL;
  Config.dwUrlRetrievalTimeout := ANCHOR_URL_RETRIEVAL_TIMEOUT_MILLISECONDS;
  ChainFlags := CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL or
    CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE or CERT_CHAIN_DISABLE_AIA;
  Engine := nil;
  if not CertCreateCertificateChainEngine(Config, Engine) or
     not Assigned(Engine) then
    raise ETransportSecurityError.CreateFmt(
      'Failed to create the TLS trust-anchor chain engine: %s',
      [SChannelStatusText(LongWord(Windows.GetLastError))]);
  try
    SChannelEvaluateChain(Engine, APeer, AHost, AServerAuthentication,
      ChainFlags, AReport);
  finally
    CertFreeCertificateChainEngine(Engine);
  end;
end;

function SChannelAnchorPolicyError(const AAnchors: HCERTSTORE;
  const APeer: PCertContext; const AHost: string;
  const AServerAuthentication: Boolean): LongWord;
var
  Report: TSChannelChainReport;
begin
  SChannelEvaluateAnchorChain(AAnchors, APeer, AHost, AServerAuthentication,
    False, Report);
  RequireSChannelChainEvaluated(Report);
  Result := Report.PolicyError;
end;

procedure VerifySChannelPeerCertificate(const APeer: PCertContext;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AAnchorStore: Pointer);
var
  ErrorCode: LongWord;
begin
  if not Assigned(AAnchorStore) then
    raise ETransportSecurityVerificationError.CreateFmt('%s: no trust anchors',
      [TLS_VERIFICATION_ERROR]);
  { The offline anchor evaluation runs first, so a server issued by a
    configured anchor is accepted without any network work in either mode.
    System plus anchors then falls back to the current user's default
    engine, which keeps Windows' own retrieval behaviour (AIA and root
    auto-update), exactly as the option-less client does. }
  ErrorCode := SChannelAnchorPolicyError(AAnchorStore, APeer, AHost, True);
  if (ErrorCode <> 0) and (AOptions.TrustMode = tstmSystemAndAnchors) then
    ErrorCode := SChannelChainPolicyError(nil, APeer, AHost, True, 0);
  if ErrorCode <> 0 then
    raise ETransportSecurityVerificationError.CreateFmt('%s: %s',
      [TLS_VERIFICATION_ERROR, SChannelStatusText(ErrorCode)]);
end;

procedure VerifySChannelClientPeer(const AContext: TSecHandle;
  const AHost: string; const AOptions: TTransportSecurityClientOptions;
  const AAnchorStore: Pointer);
var
  Context: TSecHandle;
  Peer: PCertContext;
begin
  if AOptions.InsecureSkipVerify or not Assigned(AAnchorStore) then
    Exit;
  Context := AContext;
  Peer := nil;
  if (QueryContextAttributesW(@Context, SECPKG_ATTR_REMOTE_CERT_CONTEXT,
     @Peer) <> SEC_E_OK) or not Assigned(Peer) then
    raise ETransportSecurityVerificationError.CreateFmt(
      '%s: the server presented no certificate', [TLS_VERIFICATION_ERROR]);
  try
    VerifySChannelPeerCertificate(Peer, AHost, AOptions, AAnchorStore);
  finally
    CertFreeCertificateContext(Peer);
  end;
end;

{ Native parse of the anchors and the identity without persisting a key:
  the PKCS#12 is opened with its passphrase under PKCS12_NO_PERSIST_KEY and
  must hold exactly one keyed certificate. }
procedure ValidateSChannelClientMaterial(
  const AOptions: TTransportSecurityClientOptions);
const
  PKCS12_NO_PERSIST_KEY = $00008000;
var
  AnchorStore: HCERTSTORE;
  Found: PCertContext;
  Identities: Integer;
  Identity: TBytes;
  IdentityBlob: TCryptDataBlob;
  Passphrase: array of WideChar;
  Store: HCERTSTORE;
begin
  if Length(AOptions.TrustAnchors) > 0 then
  begin
    AnchorStore := CreateSChannelAnchorStore(AOptions.TrustAnchors);
    CertCloseStore(AnchorStore, 0);
  end;
  if Length(AOptions.ClientPkcs12) = 0 then
    Exit;
  SetLength(Identity, Length(AOptions.ClientPkcs12));
  Move(AOptions.ClientPkcs12[0], Identity[0], Length(Identity));
  SetLength(Passphrase, Length(AOptions.ClientPkcs12Passphrase) + 1);
  Store := nil;
  try
    if Length(AOptions.ClientPkcs12Passphrase) > 0 then
      Move(AOptions.ClientPkcs12Passphrase[1], Passphrase[0],
        Length(AOptions.ClientPkcs12Passphrase) * SizeOf(WideChar));
    Passphrase[High(Passphrase)] := WideChar(0);
    IdentityBlob.cbData := Length(Identity);
    IdentityBlob.pbData := @Identity[0];
    Store := PFXImportCertStore(@IdentityBlob, @Passphrase[0],
      PKCS12_ALWAYS_CNG_KSP or PKCS12_NO_PERSIST_KEY);
    if not Assigned(Store) then
      raise ETransportSecurityError.Create(
        SCHANNEL_SERVER_IDENTITY_PARSE_ERROR);
    Identities := 0;
    Found := CertFindCertificateInStore(Store, CERT_ENCODING_TYPES, 0,
      CERT_FIND_HAS_PRIVATE_KEY, nil, nil);
    while Assigned(Found) do
    begin
      Inc(Identities);
      Found := CertFindCertificateInStore(Store, CERT_ENCODING_TYPES, 0,
        CERT_FIND_HAS_PRIVATE_KEY, nil, Found);
    end;
    if Identities = 0 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain a certificate and private key');
    if Identities > 1 then
      raise ETransportSecurityError.Create(
        'Configured TLS PKCS#12 identity must contain exactly one certificate with a private key');
  finally
    if Assigned(Store) then
      CertCloseStore(Store, 0);
    if Length(Passphrase) > 0 then
      FillChar(Passphrase[0], Length(Passphrase) * SizeOf(WideChar), 0);
    SetLength(Passphrase, 0);
    WipeBytes(Identity);
  end;
end;

function SChannelPeerCertificate(
  const AConnection: TTransportSecurityConnection): TBytes;
var
  Data: TSChannelData;
  Peer: PCertContext;
begin
  Result := nil;
  Data := TSChannelData(AConnection.BackendData);
  if not Assigned(Data) or not Data.HasContext then
    Exit;
  Peer := nil;
  if (QueryContextAttributesW(@Data.Context, SECPKG_ATTR_REMOTE_CERT_CONTEXT,
     @Peer) <> SEC_E_OK) or not Assigned(Peer) then
    Exit;
  try
    if Peer^.cbCertEncoded > 0 then
    begin
      SetLength(Result, Peer^.cbCertEncoded);
      Move(Peer^.pbCertEncoded^, Result[0], Peer^.cbCertEncoded);
    end;
  finally
    CertFreeCertificateContext(Peer);
  end;
end;

{ Test-only seam: '' when the accepted server connection received a client
  certificate that chains to the seam's anchors for client authentication
  using only intermediates from the client's own Certificate message;
  otherwise why not. }
function SChannelServerClientCertificateRejection(
  const AData: TSChannelServerData): string;
var
  Peer: PCertContext;
  Report: TSChannelChainReport;
  Status: SECURITY_STATUS;
begin
  Peer := nil;
  Status := QueryContextAttributesW(@AData.Context,
    SECPKG_ATTR_REMOTE_CERT_CONTEXT, @Peer);
  if (Status <> SEC_E_OK) or not Assigned(Peer) then
    Exit(Format('no client certificate (QueryContextAttributes %s)',
      [SChannelStatusText(LongWord(Status))]));
  try
    if not Assigned(AData.ClientAnchorStore) then
      Exit('no client anchors configured');
    SChannelEvaluateAnchorChain(AData.ClientAnchorStore, Peer, '', False,
      True, Report);
    if Report.PolicyError <> 0 then
      Exit('client chain rejected: ' + DescribeSChannelChainReport(Report));
    if not Report.IntermediatesFromPeer then
      Exit('client chain used an intermediate the client did not send: ' +
        DescribeSChannelChainReport(Report));
    Result := '';
  finally
    CertFreeCertificateContext(Peer);
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
  if Assigned(AData.ClientAnchorStore) then
  begin
    CertCloseStore(AData.ClientAnchorStore, 0);
    AData.ClientAnchorStore := nil;
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
  Rejection: string;
  RequestFlags: LongWord;
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

    RequestFlags := SChannelServerRequestFlags;
    if Data.RequireClientCertificate then
      RequestFlags := RequestFlags or ASC_REQ_MUTUAL_AUTH;
    Status := AcceptSecurityContext(@Data.Snapshot.Credential,
      ExistingContext, @InputDescriptor, RequestFlags,
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
      RecordServerFailure(Format('SChannel server handshake could not ' +
        'stage its token after AcceptSecurityContext %s',
        [SChannelStatusText(LongWord(Status))]));
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
        RecordServerFailure(Format('SChannel server stream-size query ' +
          'failed: %s', [SChannelStatusText(LongWord(Status))]));
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
      if Data.RequireClientCertificate then
      begin
        Rejection := SChannelServerClientCertificateRejection(Data);
        if Rejection <> '' then
        begin
          RecordServerFailure('SChannel server test seam refused the client ' +
            'certificate: ' + Rejection);
          PoisonSChannelServerConnection(AConnection);
          Result := tssError;
          Exit;
        end;
      end;
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
      RecordServerFailure(Format('SChannel server AcceptSecurityContext ' +
        'failed: %s', [SChannelStatusText(LongWord(Status))]));
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
    if Status = SEC_I_RENEGOTIATE then
    begin
      { TLS 1.3 uses this status for post-handshake KeyUpdate and session
        tickets. SChannel ordinarily returns the complete post-handshake token
        and following ciphertext as SECBUFFER_EXTRA. Microsoft documents that
        EXTRA is not guaranteed, in which case the same modified input buffer
        must be relabelled as the token. TLS 1.2 renegotiation remains fatal,
        preserving the no-renegotiation contract shared with OpenSSL. }
      if Data.Protocol <> SP_PROT_TLS1_3_SERVER then
      begin
        PoisonSChannelServerConnection(AConnection);
        Result.State := tssError;
        Exit;
      end;
      SetLength(ExtraInput, 0);
      for I := 0 to High(Buffers) do
        if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_EXTRA then
          AppendExtraBytes(ExtraInput, Data.EncryptedInput,
            Buffers[I].pvBuffer, Buffers[I].cbBuffer);
      if Length(ExtraInput) = 0 then
        ExtraInput := Copy(Data.EncryptedInput, 0,
          Length(Data.EncryptedInput));
      Data.EncryptedInput := ExtraInput;
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
    { Copy plaintext while EncryptedInput still owns the in-place
      DecryptMessage spans. Replacing it with the preserved tail first would
      leave the returned DATA pointer dangling. Harvest from index 1 because
      SEC_I_CONTEXT_EXPIRED leaves buffer 0 carrying the caller's label. }
    if Status = SEC_E_OK then
      for I := 1 to High(Buffers) do
        if SecBufferKind(Buffers[I].BufferType) = SECBUFFER_DATA then
          AppendBytes(Data.Plaintext, Buffers[I].pvBuffer,
            Buffers[I].cbBuffer);

    { SECBUFFER_EXTRA also points into EncryptedInput; preserve it only after
      harvesting every plaintext span and before replacing its owner. }
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

function WriteSChannelServer(var AConnection: TTransportSecurityConnection;
  const ABuffer: Pointer;
  const ALength: Integer): TTransportSecurityIOResult;
var
  BufferDescriptor: TSecBufferDesc;
  Buffers: array[0..3] of TSecBuffer;
  ChunkLength: Integer;
  Data: TSChannelServerData;
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
    SetLength(Data.RecordBuffer, MessageLength);
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  { Secure Transport and Security.framework ship with macOS. }
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Snapshot: TSecureTransportServerSnapshot;
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
    {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
    Snapshot := TSecureTransportServerSnapshot(FBackendData);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  OldSnapshot: TSecureTransportServerSnapshot;
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
    {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
    OldSnapshot := TSecureTransportServerSnapshot(FBackendData);
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
  try
    if FCriticalSectionInitialized then
      try
        ReplaceSnapshot(nil);
      finally
        DoneCriticalSection(FCriticalSection);
        FCriticalSectionInitialized := False;
      end;
    FBackendData := nil;
  finally
    inherited Destroy;
  end;
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Snapshot: TSecureTransportServerSnapshot;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Snapshot := CreateSecureTransportServerSnapshot(APkcs12Identity,
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

procedure ValidateTransportSecurityClientOptions(
  const AOptions: TTransportSecurityClientOptions);
begin
  ValidateClientOptionsStructure(AOptions);
  {$IFDEF DARWIN}
  ValidateSecureTransportClientMaterial(AOptions);
  {$ELSE}
  {$IFDEF MSWINDOWS}
  ValidateSChannelClientMaterial(AOptions);
  {$ELSE}
  ValidateOpenSSLClientMaterial(AOptions);
  {$ENDIF}
  {$ENDIF}
end;

procedure StartTransportSecurityInternal(
  var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string;
  const AOptions: TTransportSecurityClientOptions; const ADeadline,
  ATimeoutMilliseconds: QWord);
var
  UseOptions: Boolean;
begin
  { A zero-valued options record takes exactly the option-less path. }
  UseOptions := not TransportSecurityClientOptionsAreDefault(AOptions);
  { The backends prepare (and so natively parse) every option before the
    first handshake byte; only the structure is checked here. }
  if UseOptions then
    ValidateClientOptionsStructure(AOptions);

  FillChar(AConnection, SizeOf(AConnection), 0);
  AConnection.Socket := ASocket;
  AConnection.Backend := TSB_NONE;
  AConnection.Deadline := ADeadline;
  AConnection.TimeoutMilliseconds := ATimeoutMilliseconds;

  {$IFDEF DARWIN}
  StartSecureTransport(AConnection, AHost, AOptions, UseOptions);
  {$ELSE}
  {$IFDEF MSWINDOWS}
  StartSChannel(AConnection, AHost, AOptions, UseOptions);
  {$ELSE}
  StartOpenSSL(AConnection, AHost, AOptions, UseOptions);
  {$ENDIF}
  {$ENDIF}
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost,
    DefaultTransportSecurityClientOptions, 0, 0);
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost,
    DefaultTransportSecurityClientOptions, ADeadline, ATimeoutMilliseconds);
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string;
  const AOptions: TTransportSecurityClientOptions);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost, AOptions, 0, 0);
end;

procedure StartTransportSecurity(var AConnection: TTransportSecurityConnection;
  const ASocket: TSocket; const AHost: string;
  const AOptions: TTransportSecurityClientOptions; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  StartTransportSecurityInternal(AConnection, ASocket, AHost, AOptions,
    ADeadline, ATimeoutMilliseconds);
end;

function TransportSecurityPeerCertificate(
  const AConnection: TTransportSecurityConnection): TBytes;
begin
  Result := nil;
  if not AConnection.Active or not Assigned(AConnection.BackendData) then
    Exit;
  case AConnection.Backend of
    {$IFDEF DARWIN}
    TSB_SECURE_TRANSPORT:
      Result := SecureTransportContextPeerCertificate(
        TSecureTransportData(AConnection.BackendData).Context);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    TSB_SCHANNEL:
      Result := SChannelPeerCertificate(AConnection);
    {$ENDIF}
    {$IFDEF TRANSPORT_SECURITY_OPENSSL}
    TSB_OPENSSL:
      Result := OpenSSLPeerCertificate(AConnection);
    {$ENDIF}
  end;
end;

procedure BeginTransportSecurityServer(
  var AConnection: TTransportSecurityConnection;
  const AContext: TTransportSecurityServerContext);
begin
  ClearServerFailure;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  BeginSecureTransportServer(AConnection, AContext);
  {$ENDIF}
  {$ELSE}
  raise ETransportSecurityError.Create(TLS_SERVER_UNSUPPORTED_ERROR);
  {$ENDIF}
end;

function TransportSecurityServerHandshake(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  { Each handshake call reports only its own outcome: progress or success
    clears whatever an earlier call, on this or another connection of the
    same thread, recorded. }
  ClearServerFailure;
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Result := HandshakeOpenSSLServer(AConnection);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Result := HandshakeSChannelServer(AConnection);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Result := HandshakeSecureTransportServer(AConnection);
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Result := FeedSecureTransportServerCiphertext(AConnection, ABuffer,
    ALength);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  Result := SecureTransportServerInputFlow(Data);
  Exit;
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  Result := SecureTransportServerOutputFlow(Data);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  Result := SecureTransportServerPendingCiphertext(Data);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  Result := SecureTransportServerPendingCiphertext(Data);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  Pending := SecureTransportServerPendingCiphertext(Data);
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Result := ReadSecureTransportServer(AConnection, ABuffer, ALength);
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Result := WriteSecureTransportServer(AConnection, ABuffer, ALength);
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Result := CloseSecureTransportServerGracefully(AConnection);
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
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
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
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
  FreeSecureTransportServerData(Data);
  {$ENDIF}
  {$IFNDEF TRANSPORT_SECURITY_SERVER}
  AConnection.Active := False;
  AConnection.Backend := TSB_NONE;
  AConnection.BackendData := nil;
  {$ENDIF}
end;

{$IFDEF TRANSPORT_SECURITY_SERVER}
{$IFNDEF PRODUCTION}
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
type
  TOpenSSLSetVerify = procedure(ASSL: PSSL; AMode: LongInt;
    ACallback: Pointer); cdecl;
  TOpenSSLStoreNew = function: Pointer; cdecl;
  TOpenSSLStoreFree = procedure(AStore: Pointer); cdecl;
{$ENDIF}

procedure TransportSecurityTestRequireClientCertificate(
  var AConnection: TTransportSecurityConnection;
  const AClientAnchors: TBytes);
{$IFDEF TRANSPORT_SECURITY_OPENSSL}
const
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT_LWPT = $02;
  SSL_CTRL_SET_VERIFY_CERT_STORE_LWPT = 106;
var
  Data: TOpenSSLServerData;
  SetVerify: TOpenSSLSetVerify;
  Store: Pointer;
  StoreFree: TOpenSSLStoreFree;
  StoreNew: TOpenSSLStoreNew;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
var
  Data: TSChannelServerData;
{$ENDIF}
{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
var
  Data: TSecureTransportServerData;
{$ENDIF}
begin
  if Length(AClientAnchors) = 0 then
    raise ETransportSecurityError.Create(
      'TLS client-certificate seam needs client trust anchors');
  {$IFDEF TRANSPORT_SECURITY_OPENSSL}
  Data := OpenSSLServerData(AConnection);
  if not Assigned(Data) or Data.HandshakeDone then
    raise ETransportSecurityError.Create(
      'TLS client-certificate seam needs a fresh server connection');
  LoadOpenSSLClientProcedures;
  SetVerify := TOpenSSLSetVerify(GetProcedureAddress(SSLLibHandle,
    'SSL_set_verify'));
  StoreNew := TOpenSSLStoreNew(GetProcedureAddress(SSLUtilHandle,
    'X509_STORE_new'));
  StoreFree := TOpenSSLStoreFree(GetProcedureAddress(SSLUtilHandle,
    'X509_STORE_free'));
  if not Assigned(SetVerify) or not Assigned(StoreNew) or
     not Assigned(StoreFree) then
    raise ETransportSecurityError.Create(
      'OpenSSL runtime does not provide the client-certificate seam');
  { A connection-private verify store holding only the anchors: the
    client's intermediates can come only from its Certificate message. }
  Store := StoreNew();
  if not Assigned(Store) then
    raise ETransportSecurityError.Create(
      'Failed to create the client-certificate verify store');
  try
    AddOpenSSLTrustAnchorsToStore(Store,
      ParseTransportSecurityTrustAnchors(AClientAnchors));
    if SslCtrl(Data.SSL, SSL_CTRL_SET_VERIFY_CERT_STORE_LWPT, 1, Store) <> 1
      then
      raise ETransportSecurityError.Create(
        'Failed to install the client-certificate verify store');
  finally
    StoreFree(Store);
  end;
  SetVerify(Data.SSL, SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT_LWPT,
    nil);
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
  Data := SChannelServerData(AConnection);
  if not Assigned(Data) or Data.HandshakeDone or Data.HasContext then
    raise ETransportSecurityError.Create(
      'TLS client-certificate seam needs a fresh server connection');
  if Assigned(Data.ClientAnchorStore) then
    CertCloseStore(Data.ClientAnchorStore, 0);
  Data.ClientAnchorStore := CreateSChannelAnchorStore(AClientAnchors);
  Data.RequireClientCertificate := True;
  {$ENDIF}
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  Data := SecureTransportServerData(AConnection);
  if not Assigned(Data) or Data.HandshakeDone then
    raise ETransportSecurityError.Create(
      'TLS client-certificate seam needs a fresh server connection');
  if (SSLSetClientSideAuthenticate(Data.Context, K_ALWAYS_AUTHENTICATE)
     <> ERR_SEC_SUCCESS) or
     (SSLSetSessionOption(Data.Context,
      K_SSL_SESSION_OPTION_BREAK_ON_CLIENT_AUTH, True) <> ERR_SEC_SUCCESS) then
    raise ETransportSecurityError.Create(
      'Failed to require a TLS client certificate');
  if Data.ClientAnchorArray <> nil then
    CFRelease(Data.ClientAnchorArray);
  Data.ClientAnchorArray := nil;
  Data.ClientAnchorArray := CreateSecureTransportAnchorArray(
    ParseTransportSecurityTrustAnchors(AClientAnchors));
  Data.RequireClientCertificate := True;
  {$ENDIF}
end;
{$ENDIF}
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_SCHANNEL_SERVER}
{$IFNDEF PRODUCTION}
function TransportSecurityTestLastImportedKeyContainers: TUnicodeStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(SChannelTestImportedKeyContainers));
  for I := 0 to High(Result) do
    Result[I] := SChannelTestImportedKeyContainers[I];
end;

procedure TransportSecurityTestForceSChannelChainExecutionFailure(
  const AStage: Integer);
begin
  SChannelTestChainExecutionFailure := AStage;
end;

function TransportSecurityTestVerifyServerChain(const ALeaf,
  AIntermediates: TBytes; const AHost: string;
  const AOptions: TTransportSecurityClientOptions): string;
var
  Refused: Boolean;
begin
  Result := TransportSecurityTestVerifyServerChain(ALeaf, AIntermediates,
    AHost, AOptions, Refused);
end;

function TransportSecurityTestVerifyServerChain(const ALeaf,
  AIntermediates: TBytes; const AHost: string;
  const AOptions: TTransportSecurityClientOptions;
  out ARefused: Boolean): string;
const
  CERT_STORE_PROV_MEMORY = 2;
  CERT_STORE_ADD_USE_EXISTING = 2;
var
  AnchorStore: HCERTSTORE;
  I: Integer;
  Intermediates: TTransportSecurityCertificateList;
  PeerStore: HCERTSTORE;
  Leaf: PCertContext;
begin
  Result := '';
  AnchorStore := nil;
  Leaf := nil;
  PeerStore := CertOpenStore(PAnsiChar(PtrUInt(CERT_STORE_PROV_MEMORY)), 0,
    0, 0, nil);
  if not Assigned(PeerStore) then
    raise ETransportSecurityError.Create(
      'Failed to create the test peer store');
  try
    if (Length(ALeaf) = 0) or not CertAddEncodedCertificateToStore(PeerStore,
       X509_ASN_ENCODING, @ALeaf[0], Length(ALeaf),
       CERT_STORE_ADD_USE_EXISTING, @Leaf) then
      raise ETransportSecurityError.Create(
        'Test peer leaf is not a valid X.509 certificate');
    Intermediates := ParseTransportSecurityTrustAnchors(AIntermediates);
    for I := 0 to High(Intermediates) do
      if not CertAddEncodedCertificateToStore(PeerStore, X509_ASN_ENCODING,
        @Intermediates[I][0], Length(Intermediates[I]),
        CERT_STORE_ADD_USE_EXISTING, nil) then
        raise ETransportSecurityError.Create(
          'Test peer intermediate is not a valid X.509 certificate');
    if Length(AOptions.TrustAnchors) > 0 then
      AnchorStore := CreateSChannelAnchorStore(AOptions.TrustAnchors);
    ARefused := False;
    try
      VerifySChannelPeerCertificate(Leaf, AHost, AOptions, AnchorStore);
    except
      on E: ETransportSecurityError do
      begin
        Result := E.Message;
        ARefused := E is ETransportSecurityVerificationError;
      end;
    end;
  finally
    if Assigned(Leaf) then
      CertFreeCertificateContext(Leaf);
    if Assigned(AnchorStore) then
      CertCloseStore(AnchorStore, 0);
    CertCloseStore(PeerStore, 0);
  end;
end;

function TransportSecurityTestKeyContainerExists(
  const AContainerName: UnicodeString): Boolean;
var
  Key: PtrUInt;
  Status: LongInt;
begin
  Status := OpenSChannelKeyContainer('', AContainerName, Key);
  Result := Status = 0;
  if Result then
    NCryptFreeObject(Key)
  else if Status <> NTE_BAD_KEYSET_LWPT then
    raise ETransportSecurityError.CreateFmt(
      'Could not probe the CNG key container: 0x%x', [LongWord(Status)]);
end;
{$ENDIF}
{$ENDIF}

{$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
{$IFNDEF PRODUCTION}
procedure TransportSecurityTestForceSecureTransportCleanupFileFailure(
  const AEnabled: Boolean);
begin
  SecureTransportTestCleanupFileFailure := AEnabled;
end;

procedure TransportSecurityTestForceSecureTransportRecoveryUnlinkRace(
  const AEnabled: Boolean);
begin
  SecureTransportTestRecoveryUnlinkRace := AEnabled;
end;

procedure TransportSecurityTestForceSecureTransportRecoveryDeadOwnerPID(
  const APID: LongInt);
begin
  SecureTransportTestRecoveryDeadOwnerPID := APID;
end;

procedure TransportSecurityTestForceSecureTransportReplacementRace(
  const AOrdinaryCleanup, ARecovery: Boolean);
begin
  SecureTransportTestOrdinaryReplacementRace := AOrdinaryCleanup;
  SecureTransportTestRecoveryReplacementRace := ARecovery;
  SecureTransportTestReplacementOriginalPath := '';
  SecureTransportTestReplacementPreservedPath := '';
end;

procedure TransportSecurityTestForceSecureTransportImportReplacementRace(
  const ABeforeValidation, ABeforeOpen, AAfterMarkerLookup: Boolean);
begin
  SecureTransportTestImportReplacementRaceBeforeValidation :=
    ABeforeValidation;
  SecureTransportTestImportReplacementRaceBeforeOpen := ABeforeOpen;
  SecureTransportTestImportReplacementRaceAfterMarkerLookup :=
    AAfterMarkerLookup;
  SecureTransportTestReplacementOriginalPath := '';
  SecureTransportTestReplacementPreservedPath := '';
end;

procedure TransportSecurityTestForceSecureTransportBindABARace(
  const AEnabled: Boolean; const ACallsToSkip: LongInt);
begin
  SecureTransportTestBindABARace := AEnabled;
  SecureTransportTestBindABACallsToSkip := ACallsToSkip;
  SecureTransportTestReplacementOriginalPath := '';
  SecureTransportTestReplacementPreservedPath := '';
end;

procedure TransportSecurityTestForceSecureTransportFinalUnlinkReplacementRace(
  const AEnabled: Boolean);
begin
  SecureTransportTestFinalUnlinkReplacementRace := AEnabled;
  SecureTransportTestReplacementOriginalPath := '';
  SecureTransportTestReplacementPreservedPath := '';
end;

procedure TransportSecurityTestSecureTransportReplacementRacePaths(
  out AOriginalPath, APreservedPath: string);
begin
  AOriginalPath := SecureTransportTestReplacementOriginalPath;
  APreservedPath := SecureTransportTestReplacementPreservedPath;
end;

procedure TransportSecurityTestForceSecureTransportNetworkFetchStatus(
  const AStatus: LongInt);
begin
  SecureTransportTestNetworkFetchStatus := AStatus;
  SecureTransportTestNetworkFetchCalled := False;
end;

procedure TransportSecurityTestForceSecureTransportTrustEvaluationFailure(
  const AEnabled: Boolean);
begin
  SecureTransportTestTrustEvaluationFailure := AEnabled;
end;

function TransportSecurityTestSecureTransportNetworkFetchWasDisabled: Boolean;
begin
  Result := SecureTransportTestNetworkFetchCalled;
end;

function TransportSecurityTestInjectSecureTransportFatalStatus(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  Result := SecureTransportServerState(AConnection, ERR_SSL_CLOSED_ABORT,
    False);
end;

function TransportSecurityTestInjectSecureTransportPeerClose(
  var AConnection: TTransportSecurityConnection): TTransportSecurityState;
begin
  Result := SecureTransportServerState(AConnection,
    ERR_SSL_CLOSED_GRACEFUL, True);
end;
{$ENDIF}
{$ENDIF}

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
    {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
    TSB_SECURE_TRANSPORT_SERVER:
      FreeSecureTransportServerData(
        TSecureTransportServerData(AConnection.BackendData));
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

initialization
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  InitCriticalSection(SecureTransportServerSymbolLock);
  {$ENDIF}

finalization
  {$IFDEF TRANSPORT_SECURITY_SECURE_TRANSPORT_SERVER}
  DoneCriticalSection(SecureTransportServerSymbolLock);
  {$ENDIF}

end.
