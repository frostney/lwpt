{ LWPT.Registry.Server — foreground HTTP service for an origin store. }
unit LWPT.Registry.Server;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store,
  {$IFDEF MSWINDOWS}
  WinSock2;
  {$ELSE}
  Sockets;
  {$ENDIF}

const
  { The body deadline is this plus one second per declared MiB. }
  RegistryBodyBaseDeadlineMilliseconds = 30000;
  { Processing time granted after a complete body: the bounded lease waits
    plus the commit itself. }
  RegistryMutationProcessingMilliseconds = 20000;

type
  TLWPTRegistryHTTPResponse = record
    Status: Integer;
    Reason: string;
    ContentType: string;
    CacheControl: string;
    ETag: string;
    Body: TBytes;
    ResourcePath: string;
    ResourceLength: Int64;
    ResourceDigest: string;
    { Optional publication headers; empty or zero means absent. }
    Location: string;
    RetryAfter: Integer;
    Challenge: string;
  end;

  TLWPTRegistryHeader = record
    Name, Value: string;
  end;

  { A parsed request line and header block. Header names keep their wire
    case; lookups are case-insensitive. }
  TLWPTRegistryRequestHead = record
    Method, Target, Peer: string;
    Headers: array of TLWPTRegistryHeader;
  end;

  { A mutating request admitted past its header checks. The transport feeds
    exactly BodyLength bytes, then calls Finish once; a transport failure
    calls Abort instead. Neither Abort nor destruction raises. }
  TLWPTRegistryMutation = class
  public
    function BodyLength: Int64; virtual; abstract;
    function ExpectsContinue: Boolean; virtual; abstract;
    procedure Feed(const ABuffer; const ACount: Integer); virtual; abstract;
    function Finish: TLWPTRegistryHTTPResponse; virtual; abstract;
    procedure Abort; virtual; abstract;
  end;

  { Admits or refuses a non-read request after its headers. A nil result
    means AResponse is final and no body is read. }
  TLWPTRegistryMutationHandler = class
  public
    function BeginMutation(const AHead: TLWPTRegistryRequestHead;
      out AResponse: TLWPTRegistryHTTPResponse): TLWPTRegistryMutation;
      virtual; abstract;
    { Answers and records a mutating request that failed before routing.
      AMethod is already validated; nothing else of the request is kept. }
    function RefuseMalformed(const AMethod, APeer: string;
      const AStatus: Integer; const AReason, ACode, AMessage: string):
      TLWPTRegistryHTTPResponse; virtual; abstract;
  end;

  TLWPTRegistryServer = class
  private
    FStore: TLWPTRegistryStore;
    FHandler: TLWPTRegistryMutationHandler;
    FClients: TThreadList;
    FStopping: Boolean;
    procedure DrainClients;
    procedure ReapClients;
  public
    constructor Create(AStore: TLWPTRegistryStore);
    destructor Destroy; override;
    procedure RequestStop;
    procedure Run;
  end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string; AProgress: TSHA256Progress = nil):
  TLWPTRegistryHTTPResponse;
function RegistryErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string; const ARequestID: string = ''):
  TLWPTRegistryHTTPResponse;
{ A retryable 429 or 503 error with Retry-After. }
function RegistryRetryableErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage, ARequestID: string; const ARetryAfterSeconds: Integer):
  TLWPTRegistryHTTPResponse;
function NewRegistryRequestID: string;
{ Parses the header block (without its terminating blank line). Returns
  False for a malformed request line or header field. }
function ParseRegistryRequestHead(const AText, APeer: string;
  out AHead: TLWPTRegistryRequestHead): Boolean;
{ Values of every header named AName, in wire order. }
function RegistryHeaderValues(const AHead: TLWPTRegistryRequestHead;
  const AName: string): TStringArray;
function RegistryMethodIsRead(const AMethod: string): Boolean;
{ True when a '/'-separated path has a '.' or '..' segment. Names such as
  a..b are protocol-valid and are not dot segments. }
function RegistryPathHasDotSegment(const APath: string): Boolean;
{ The opaque package-list cursor after AName@AVersion, bound to the origin,
  snapshot, and listing scope (empty for the collection). }
function RegistryPackageCursor(const AIdentity, ASnapshot, AScope, AName,
  AVersion: string): string;
{ Answers one request whose headers are complete. Reads go through
  RegistryHTTPResponse; everything else goes to AHandler, which may return
  a mutation that needs a body. }
function RegistryDispatch(AStore: TLWPTRegistryStore;
  AHandler: TLWPTRegistryMutationHandler;
  const AHead: TLWPTRegistryRequestHead; AProgress: TSHA256Progress;
  out AMutation: TLWPTRegistryMutation): TLWPTRegistryHTTPResponse;
function RegistryBodyDeadlineMilliseconds(const ABodyLength: Int64): QWord;
function RegistryHeaderDeadlineMilliseconds: QWord;
{ Audits a mutating request whose head never completed (peer EOF, a read
  failure, or the header deadline). Only a recognizable method is kept, and
  no response is sent. }
procedure RegistryAuditIncompleteRequest(AHandler: TLWPTRegistryMutationHandler;
  const ARaw, APeer: string; const ATimedOut: Boolean);
{ The error for a request whose head could not be parsed or was too large.
  A recognizable mutating method is answered and audited through AHandler;
  only that method name is taken from ARaw. }
function RegistryMalformedRequestResponse(AHandler: TLWPTRegistryMutationHandler;
  const ARaw, APeer: string; const AStatus: Integer; const AReason, ACode,
  AMessage: string): TLWPTRegistryHTTPResponse;
function CreateRegistryMutationHandler(AStore: TLWPTRegistryStore):
  TLWPTRegistryMutationHandler;
function RegistryResourceFailureResponse(const ADiagnostic: string):
  TLWPTRegistryHTTPResponse;
function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;
function OpenRegistryHTTPResource(const AResponse: TLWPTRegistryHTTPResponse;
  AProgress: TSHA256Progress = nil): TStream;
{$IFDEF REGISTRY_TESTING}
{ Replaces the 30-second body deadline base; zero restores it. }
procedure SetRegistryBodyDeadlineForTesting(const ABaseMilliseconds: QWord);
{ Replaces the 10-second header deadline; zero restores it. }
procedure SetRegistryHeaderDeadlineForTesting(const AMilliseconds: QWord);
function RegistryDeadlineTimeoutForTesting(const ADeadline,
  ANow: QWord): LongInt;
function RegistryTLSShutdownStateIsTerminalForTesting(
  const AState: Integer): Boolean;
function RegistrySendResourcePlainForTesting(AStream: TStream;
  const ADeadline, AStartTime, AAdvancePerSend: QWord;
  const AMaximumSend: Integer): Integer;
{$ENDIF}

implementation

uses
  StrUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  {$IFDEF DARWIN}
  LWPT.Registry.Server.NetworkFramework,
  {$ENDIF}
  LWPT.Registry.Audit,
  LWPT.Registry.Crypto,
  LWPT.Registry.Filesystem,
  LWPT.Registry.Publication,
  LWPT.Registry.Verification,
  TransportSecurity;

const
  MAX_REQUEST_HEADER_BYTES = 32 * 1024;
  CLIENT_READ_TIMEOUT_MILLISECONDS = 10000;
  TLS_CIPHERTEXT_BUDGET_BYTES = 1024 * 1024;
  MAX_ACTIVE_CLIENTS = 32;
  {$IFDEF LINUX}
  REGISTRY_SOCKET_SEND_FLAGS = $4000; { Linux MSG_NOSIGNAL. }
  {$ELSE}
  REGISTRY_SOCKET_SEND_FLAGS = 0;
  {$ENDIF}
  {$IFDEF DARWIN}
  REGISTRY_SO_NOSIGPIPE = $1022;
  {$ENDIF}

var
  RegistryRequestSequence: LongInt;

threadvar
  { Ciphertext a TLS connection may receive; raised by an admitted body. }
  RegistryTLSCiphertextBudget: QWord;

{$IFDEF REGISTRY_TESTING}
var
  RegistryTestPlainSendActive: Boolean;
  RegistryTestPlainSendAdvance: QWord;
  RegistryTestPlainSendCalls: Integer;
  RegistryTestPlainSendMaximum: Integer;
  RegistryTestPlainSendTime: QWord;
{$ENDIF}

{$IFDEF DARWIN}
function CurrentRegistryDarwinTLSTransport: TRegistryDarwinTLSTransport;
begin
  Result := RegistryDarwinTLSTransportForKernelMajor(
    RegistryDarwinKernelReleaseMajor);
end;
{$ENDIF}

type
  {$IFDEF MSWINDOWS}
  TRegistrySockAddr = TSockAddrIn;
  TRegistrySockLen = LongInt;
  {$ELSE}
  TRegistrySockAddr = TInetSockAddr;
  TRegistrySockLen = TSockLen;
  {$ENDIF}

  TLWPTRegistryClientThread = class(TThread)
  private
    FSocket: TSocket;
    FStore: TLWPTRegistryStore;
    FHandler: TLWPTRegistryMutationHandler;
    FPeer: string;
    FTLSServerContext: TTransportSecurityServerContext;
    FTLSCiphertextReceived: QWord;
    FDeadline: QWord;
    FDone: Boolean;
    { Header bytes received before the head completed, kept only so an
      incomplete mutating request can be audited by its method. }
    FPartialHead: string;
    FHeadHandled: Boolean;
    procedure CheckDeadline;
    procedure ExecutePlain;
    procedure ExecuteTLS;
    function ReadBodyPlain(AMutation: TLWPTRegistryMutation;
      const ALeftover: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: TSocket; AStore: TLWPTRegistryStore;
      ATLSServerContext: TTransportSecurityServerContext;
      AHandler: TLWPTRegistryMutationHandler; const APeer: string);
    procedure Cancel;
    property Done: Boolean read FDone;
  end;

{$IFDEF MSWINDOWS}
procedure StartRegistrySockets;
var
  Data: TWSAData;
begin
  if WSAStartup($0202, Data) <> 0 then
    raise ELWPTRegistryError.CreateStable('listen_failed',
      'could not initialize the Windows socket provider');
end;

procedure StopRegistrySockets;
begin
  WSACleanup;
end;
{$ENDIF}

function RegistrySocket: TSocket; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.socket(AF_INET, SOCK_STREAM, 0);
  {$ELSE}
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  {$ENDIF}
end;

function RegistrySocketInvalid(const ASocket: TSocket): Boolean; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := ASocket = INVALID_SOCKET;
  {$ELSE}
  Result := ASocket < 0;
  {$ENDIF}
end;

procedure RegistrySocketClose(const ASocket: TSocket); inline;
begin
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(ASocket);
  {$ELSE}
  CloseSocket(ASocket);
  {$ENDIF}
end;

procedure RegistrySocketShutdown(const ASocket: TSocket); inline;
begin
  {$IFDEF MSWINDOWS}
  WinSock2.shutdown(ASocket, SD_BOTH);
  {$ELSE}
  fpShutdown(ASocket, 2);
  {$ENDIF}
end;

function RegistrySetSocketOption(const ASocket: TSocket;
  const ALevel, AName: Integer; const AValue: Pointer;
  const ASize: Integer): Integer; inline;
begin
  {$IFDEF REGISTRY_TESTING}
  if RegistryTestPlainSendActive then Exit(0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.setsockopt(ASocket, ALevel, AName, PChar(AValue), ASize);
  {$ELSE}
  Result := fpSetSockOpt(ASocket, ALevel, AName, AValue, ASize);
  {$ENDIF}
end;

function RegistrySocketSend(const ASocket: TSocket; const ABuffer: Pointer;
  const ALength: Integer): Integer; inline;
begin
  {$IFDEF REGISTRY_TESTING}
  if RegistryTestPlainSendActive then
  begin
    Inc(RegistryTestPlainSendCalls);
    Inc(RegistryTestPlainSendTime, RegistryTestPlainSendAdvance);
    Result := ALength;
    if Result > RegistryTestPlainSendMaximum then
      Result := RegistryTestPlainSendMaximum;
    Exit;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.send(ASocket, ABuffer^, ALength, 0);
  {$ELSE}
  Result := fpSend(ASocket, ABuffer, ALength, REGISTRY_SOCKET_SEND_FLAGS);
  {$ENDIF}
end;

function RegistryPrepareSocketNoSigPipe(const ASocket: TSocket): Boolean;
{$IFDEF DARWIN}
var
  Enabled: LongInt;
{$ENDIF}
begin
  {$IFDEF DARWIN}
  Enabled := 1;
  Result := RegistrySetSocketOption(ASocket, SOL_SOCKET,
    REGISTRY_SO_NOSIGPIPE, @Enabled, SizeOf(Enabled)) = 0;
  {$ELSE}
  Result := True;
  {$ENDIF}
end;

function RegistryMonotonicMilliseconds: QWord; inline;
begin
  {$IFDEF REGISTRY_TESTING}
  if RegistryTestPlainSendActive then
    Exit(RegistryTestPlainSendTime);
  {$ENDIF}
  Result := GetTickCount64;
end;

function RegistrySocketReceive(const ASocket: TSocket;
  const ABuffer: Pointer; const ALength: Integer): Integer; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.recv(ASocket, ABuffer^, ALength, 0);
  {$ELSE}
  Result := fpRecv(ASocket, ABuffer, ALength, 0);
  {$ENDIF}
end;

function RegistrySocketBind(const ASocket: TSocket;
  var AAddress: TRegistrySockAddr): Integer; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.bind(ASocket, PSockAddr(@AAddress), SizeOf(AAddress));
  {$ELSE}
  Result := fpBind(ASocket, @AAddress, SizeOf(AAddress));
  {$ENDIF}
end;

function RegistrySocketListen(const ASocket: TSocket): Integer; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.listen(ASocket, 128);
  {$ELSE}
  Result := fpListen(ASocket, 128);
  {$ENDIF}
end;

procedure RegistrySocketReadSet(const ASocket: TSocket;
  out AReadSet: TFDSet); inline;
begin
  {$IFDEF MSWINDOWS}
  FillChar(AReadSet, SizeOf(AReadSet), 0);
  AReadSet.fd_count := 1;
  AReadSet.fd_array[0] := ASocket;
  {$ELSE}
  fpFD_ZERO(AReadSet);
  fpFD_SET(ASocket, AReadSet);
  {$ENDIF}
end;

function RegistrySocketSelect(const ASocket: TSocket; var AReadSet: TFDSet;
  var ATimeout: TTimeVal): Integer; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.select(0, @AReadSet, nil, nil, @ATimeout);
  {$ELSE}
  Result := fpSelect(ASocket + 1, @AReadSet, nil, nil, @ATimeout);
  {$ENDIF}
end;

function RegistrySocketAccept(const ASocket: TSocket;
  var AAddress: TRegistrySockAddr;
  var AAddressLength: TRegistrySockLen): TSocket; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.accept(ASocket, PSockAddr(@AAddress), @AAddressLength);
  {$ELSE}
  Result := fpAccept(ASocket, @AAddress, @AAddressLength);
  {$ENDIF}
end;

function RegistryIPv4Address(const AHost: string): LongWord; inline;
begin
  {$IFDEF MSWINDOWS}
  Result := WinSock2.inet_addr(PAnsiChar(AnsiString(AHost)));
  {$ELSE}
  Result := StrToNetAddr(AHost).s_addr;
  {$ENDIF}
end;

function Bytes(const AValue: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AValue);
end;

function Text(const ABytes: TBytes): string;
begin
  Result := TEncoding.UTF8.GetString(ABytes);
end;

function IsLowerHex64(const AValue: string): Boolean;
var
  Character: Char;
begin
  if Length(AValue) <> 64 then Exit(False);
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

function BasePath(const ABaseURL: string): string;
var
  AuthorityEnd, SchemeEnd: Integer;
begin
  SchemeEnd := Pos('://', ABaseURL);
  AuthorityEnd := PosEx('/', ABaseURL, SchemeEnd + 3);
  if AuthorityEnd = 0 then Exit('');
  Result := Copy(ABaseURL, AuthorityEnd, MaxInt);
end;

function NewRegistryRequestID: string;
var
  Identity: string;
begin
  Identity := RegistryTimestampNow + ':' + IntToStr(GetTickCount64) + ':'
    + IntToStr(InterlockedIncrement(RegistryRequestSequence));
  Result := Copy(SHA256Hex(Bytes(Identity)), 1, 26);
end;

function ErrorDocument(const ACode, AMessage, ARequestID: string;
  const ARetryable: Boolean): TBytes;
const
  RETRYABLE_TEXT: array[Boolean] of string = ('false', 'true');
begin
  Result := Bytes('schema = '
    + RegistryTOMLQuote(PROGRAM_NAME + '-registry-error-v1') + #10
    + 'code = ' + RegistryTOMLQuote(ACode) + #10
    + 'message = ' + RegistryTOMLQuote(AMessage) + #10
    + 'request_id = ' + RegistryTOMLQuote(ARequestID) + #10
    + 'retryable = ' + RETRYABLE_TEXT[ARetryable] + #10);
end;

function RegistryRetryableErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage, ARequestID: string; const ARetryAfterSeconds: Integer):
  TLWPTRegistryHTTPResponse;
begin
  Result := RegistryErrorResponse(AStatus, AReason, ACode, AMessage, ARequestID);
  Result.Body := ErrorDocument(ACode, AMessage, ARequestID, True);
  Result.RetryAfter := ARetryAfterSeconds;
  if Result.RetryAfter < 1 then Result.RetryAfter := 1;
end;

function RegistryErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string; const ARequestID: string):
  TLWPTRegistryHTTPResponse;
var
  RequestID: string;
begin
  RequestID := ARequestID;
  if RequestID = '' then RequestID := NewRegistryRequestID;
  Result := Default(TLWPTRegistryHTTPResponse);
  Result.Status := AStatus;
  Result.Reason := AReason;
  Result.ContentType := 'application/vnd.' + PROGRAM_NAME
    + '.registry-error+toml';
  Result.CacheControl := 'no-store';
  Result.ETag := '';
  Result.ResourcePath := '';
  Result.ResourceLength := 0;
  Result.ResourceDigest := '';
  Result.Body := ErrorDocument(ACode, AMessage, RequestID, False);
end;

function ErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string): TLWPTRegistryHTTPResponse;
begin
  Result := RegistryErrorResponse(AStatus, AReason, ACode, AMessage);
end;

function RegistryResourceFailureResponse(const ADiagnostic: string):
  TLWPTRegistryHTTPResponse;
begin
  if Pos('resource_hash_mismatch:', ADiagnostic) = 1 then
    Result := RegistryErrorResponse(500, 'Internal Server Error',
      'resource_hash_mismatch',
      'stored registry resource failed content verification')
  else Result := RegistryErrorResponse(500, 'Internal Server Error',
      'resource_verification_failed',
      'stored registry resource could not be verified');
end;

function ResourceResponse(AStore: TLWPTRegistryStore;
  const ARelative, AContentType, AETag, AExpectedDigest: string;
  const AImmutable: Boolean; AProgress: TSHA256Progress):
  TLWPTRegistryHTTPResponse;
var
  RouteStream: TStream;
begin
  Result := Default(TLWPTRegistryHTTPResponse);
  RouteStream := nil;
  try
    try
      SetLength(Result.Body, 0);
      AStore.DescribeResource(ARelative, Result.ResourcePath,
        Result.ResourceLength);
      Result.ResourceDigest := AExpectedDigest;
      if Result.ResourceDigest = '' then
      begin
        RouteStream := OpenRegistryHTTPResource(Result, AProgress);
        Result.ResourceDigest := 'sha256:' + SHA256Stream(RouteStream,
          AProgress);
      end;
      Result.Status := 200;
      Result.Reason := 'OK';
      Result.ContentType := AContentType;
      if AImmutable then
        Result.CacheControl := 'public, max-age=31536000, immutable'
      else Result.CacheControl := 'no-cache, must-revalidate';
      Result.ETag := AETag;
    except
      on E: ELWPTRegistryError do
        if Pos('connection_deadline:', E.Message) = 1 then
          raise
        else if Pos('resource_hash_mismatch:', E.Message) = 1 then
          Result := ErrorResponse(500, 'Internal Server Error',
            'resource_hash_mismatch',
            'stored registry resource failed content verification')
        else if Pos('resource_too_large:', E.Message) = 1 then
          Result := ErrorResponse(500, 'Internal Server Error',
            'resource_too_large',
            'stored registry resource exceeds the service limit')
        else Result := ErrorResponse(404, 'Not Found', 'not_found',
            'registry resource was not found');
    end;
  finally
    RouteStream.Free;
  end;
end;

{ Numeric checkpoints and content-addressed renewals, each with its signature. }
function CheckpointRouteIsWellFormed(const AName: string): Boolean;
var
  Name: string;
  Sequence: Int64;
begin
  Name := AName;
  if EndsStr('.sig.toml', Name) then Delete(Name, Length(Name) - 8, 9)
  else if EndsStr('.toml', Name) then Delete(Name, Length(Name) - 4, 5)
  else Exit(False);
  if StartsStr('renewals/sha256/', Name) then
    Exit(IsLowerHex64(Copy(Name, Length('renewals/sha256/') + 1, MaxInt)));
  Result := TryStrToInt64(Name, Sequence) and (Sequence > 0)
    and (IntToStr(Sequence) = Name);
end;

function RotationPageResponse(AStore: TLWPTRegistryStore;
  AView: TLWPTRegistryReadView; const AQuery: string;
  AProgress: TSHA256Progress): TLWPTRegistryHTTPResponse;
var
  Parameters, Sequences, Seen: TStringList;
  Entry, Name, Value, Cursor, NextCursor, Scope, Prefix, Body: string;
  AfterSequence, LastSequence, Sequence, PageLimit: Int64;
  EqualsAt, Count: Integer;
  function CursorFor(const ASequence: Int64): string;
  begin
    Result := SHA256Hex(Bytes(AStore.Config.Identity + #10 + IntToStr(AfterSequence)
      + #10 + IntToStr(ASequence))) + '.' + IntToStr(ASequence);
  end;
begin
  Parameters := TStringList.Create;
  Sequences := nil;
  Seen := TStringList.Create;
  try
    Parameters.StrictDelimiter := True;
    Parameters.Delimiter := '&';
    Parameters.QuoteChar := #0;
    Parameters.DelimitedText := AQuery;
    AfterSequence := 0;
    PageLimit := RegistryRotationPageLimit;
    Cursor := '';
    for Entry in Parameters do
    begin
      EqualsAt := Pos('=', Entry);
      Name := Copy(Entry, 1, EqualsAt - 1);
      Value := Copy(Entry, EqualsAt + 1, MaxInt);
      if (EqualsAt = 0) or (Seen.IndexOf(Name) >= 0) then
        Exit(ErrorResponse(400, 'Bad Request', 'invalid_cursor', 'invalid rotation query'));
      Seen.Add(Name);
      if Name = 'cursor' then Cursor := Value
      else
      begin
        if not TryStrToInt64(Value, Sequence) or (Sequence < 0)
          or (IntToStr(Sequence) <> Value) then
          Exit(ErrorResponse(400, 'Bad Request', 'invalid_cursor', 'invalid rotation query'));
        if Name = 'after' then AfterSequence := Sequence
        else if Name = 'limit' then PageLimit := Sequence
        else Exit(ErrorResponse(400, 'Bad Request', 'invalid_cursor', 'unknown rotation query'));
      end;
    end;
    if (PageLimit < 1) or (PageLimit > RegistryRotationPageLimit) then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_cursor', 'rotation page limit must be 1 to 100'));
    LastSequence := AfterSequence;
    if Cursor <> '' then
    begin
      Scope := Copy(Cursor, 66, MaxInt);
      if not TryStrToInt64(Scope, LastSequence) or (LastSequence <= AfterSequence)
        or (Cursor <> CursorFor(LastSequence)) then
        Exit(ErrorResponse(400, 'Bad Request', 'invalid_cursor', 'rotation cursor scope mismatch'));
    end;
    Sequences := AView.RotationSequences(AProgress);
    Count := 0;
    NextCursor := '';
    Body := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-rotation-page-v1') + #10
      + 'origin = ' + RegistryTOMLQuote(AStore.Config.Identity) + #10 + 'items = [';
    for Entry in Sequences do
    begin
      Sequence := StrToInt64(Entry);
      if Sequence <= LastSequence then Continue;
      if Count >= PageLimit then
      begin
        NextCursor := CursorFor(LastSequence);
        Break;
      end;
      if Count > 0 then Body := Body + ', ';
      Prefix := AStore.Config.BaseURL + '/v1/';
      Body := Body + '{ effective_sequence = ' + Entry
        + ', rotation = ' + RegistryTOMLQuote(Prefix + RegistryRotationPath(Sequence,
          RegistryRotationDocumentSuffix))
        + ', old_signature = ' + RegistryTOMLQuote(Prefix + RegistryRotationPath(Sequence,
          RegistryRotationOldSignatureSuffix))
        + ', new_signature = ' + RegistryTOMLQuote(Prefix + RegistryRotationPath(Sequence,
          RegistryRotationNewSignatureSuffix)) + ' }';
      Inc(Count);
      LastSequence := Sequence;
    end;
    Body := Body + ']' + #10 + 'next_cursor = ' + RegistryTOMLQuote(NextCursor) + #10;
    if Length(Body) > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then
      Exit(ErrorResponse(500, 'Internal Server Error', 'resource_too_large', 'rotation page exceeds metadata limit'));
    Result := Default(TLWPTRegistryHTTPResponse);
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME + '.registry-rotation-page+toml';
    Result.Location := '';
    Result.CacheControl := 'no-cache';
    Result.Body := Bytes(Body);
  finally
    Seen.Free;
    Parameters.Free;
  end;
end;

{ Strict query decoding: name=value pairs separated by '&', percent escapes
  of exactly two hexadecimal digits, printable ASCII after decoding, and no
  repeated names. }
function DecodeQueryComponent(const AValue: string; out ADecoded: string): Boolean;
var
  Index, High, Low: Integer;
  Character: Char;
begin
  ADecoded := '';
  Index := 1;
  while Index <= Length(AValue) do
  begin
    Character := AValue[Index];
    if Character = '%' then
    begin
      if Index + 2 > Length(AValue) then Exit(False);
      High := Pos(UpCase(AValue[Index + 1]), '0123456789ABCDEF') - 1;
      Low := Pos(UpCase(AValue[Index + 2]), '0123456789ABCDEF') - 1;
      if (High < 0) or (Low < 0) then Exit(False);
      Character := Chr(High * 16 + Low);
      Inc(Index, 3);
    end
    else Inc(Index);
    if (Character < '!') or (Character > '~') then Exit(False);
    ADecoded := ADecoded + Character;
  end;
  Result := True;
end;

function ParseRegistryQuery(const AQuery: string;
  const AAllowed: array of string; AParameters: TStringList): Boolean;
var
  Pairs: TStringList;
  Pair, Name, Value: string;
  EqualsAt, Index: Integer;
  Known: Boolean;
begin
  Result := False;
  AParameters.Clear;
  if AQuery = '' then Exit(True);
  Pairs := TStringList.Create;
  try
    Pairs.StrictDelimiter := True;
    Pairs.Delimiter := '&';
    Pairs.QuoteChar := #0;
    Pairs.DelimitedText := AQuery;
    for Pair in Pairs do
    begin
      EqualsAt := Pos('=', Pair);
      if EqualsAt <= 1 then Exit;
      if not DecodeQueryComponent(Copy(Pair, 1, EqualsAt - 1), Name)
        or not DecodeQueryComponent(Copy(Pair, EqualsAt + 1, MaxInt), Value)
        or (Value = '') then Exit;
      Known := False;
      for Index := 0 to High(AAllowed) do
        if AAllowed[Index] = Name then Known := True;
      if not Known or (AParameters.IndexOfName(Name) >= 0) then Exit;
      AParameters.Add(Name + '=' + Value);
    end;
  finally
    Pairs.Free;
  end;
  Result := True;
end;

function PackageCursorBinding(const AIdentity, ASnapshot, AScope, APosition:
  string): string;
begin
  Result := Copy(SHA256Hex(Bytes(AIdentity + #10 + ASnapshot + #10 + AScope
    + #10 + APosition)), 1, 32);
end;

function RegistryPackageCursor(const AIdentity, ASnapshot, AScope, AName,
  AVersion: string): string;
begin
  Result := AName + ':' + AVersion + ':' + PackageCursorBinding(AIdentity,
    ASnapshot, AScope, AName + ':' + AVersion);
end;

function PackagePageResponse(AStore: TLWPTRegistryStore;
  AView: TLWPTRegistryReadView; const AName, AQuery: string;
  AProgress: TSHA256Progress): TLWPTRegistryHTTPResponse;
var
  Parameters, Parts: TStringList;
  Cursor, Snapshot, Body, NextCursor: string;
  Index: TLWPTRegistryPackageIndex;
  Reference: IInterface;
  Limit, Start, Item, Count: Integer;
begin
  Parameters := TStringList.Create;
  Parts := TStringList.Create;
  try
    if not ParseRegistryQuery(AQuery, ['limit', 'cursor', 'snapshot'],
      Parameters) then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
        'package query is invalid'));
    Limit := 50;
    if Parameters.IndexOfName('limit') >= 0 then
      if not TryStrToInt(Parameters.Values['limit'], Limit)
        or (IntToStr(Limit) <> Parameters.Values['limit']) or (Limit < 1)
        or (Limit > RegistryRotationPageLimit) then
        Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
          'package page limit must be 1 to 100'));
    Cursor := Parameters.Values['cursor'];
    Snapshot := Parameters.Values['snapshot'];
    if (Cursor <> '') and (Snapshot = '') then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
        'a cursor requires its snapshot'));
    if Cursor <> '' then
    begin
      Parts.StrictDelimiter := True;
      Parts.Delimiter := ':';
      Parts.QuoteChar := #0;
      Parts.DelimitedText := Cursor;
      { A position without a snapshot binding never belongs to the
        requested snapshot. }
      if Parts.Count = 2 then
        Exit(ErrorResponse(409, 'Conflict', 'snapshot_conflict',
          'cursor does not belong to the requested snapshot'));
      if Parts.Count <> 3 then
        Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
          'package cursor is invalid'));
    end;
    if Snapshot = '' then Snapshot := AView.State.SnapshotHash;
    Index := AStore.PackageIndex(AView, Snapshot, AProgress, Reference);
    if (Index = nil) and (Cursor <> '') then
      Exit(ErrorResponse(409, 'Conflict', 'snapshot_conflict',
        'cursor does not belong to the requested snapshot'));
    if Index = nil then
      Exit(ErrorResponse(409, 'Conflict', 'snapshot_conflict',
        'requested snapshot is not in accepted history'));
    if AName = '' then Start := 0
    else
    begin
      Start := Index.FirstOfName(AName);
      if Start < 0 then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'package was not found'));
    end;
    if Cursor <> '' then
    begin
      if Cursor <> RegistryPackageCursor(AStore.Config.Identity, Snapshot,
        AName, Parts[0], Parts[1]) then
        Exit(ErrorResponse(409, 'Conflict', 'snapshot_conflict',
          'cursor does not belong to the requested snapshot'));
      Start := Index.PositionAfter(Parts[0], Parts[1]);
      if (Start < 0) or ((AName <> '') and (Parts[0] <> AName)) then
        Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
          'package cursor is invalid'));
    end;
    Body := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-page-v1')
      + #10 + 'origin = ' + RegistryTOMLQuote(AStore.Config.Identity) + #10
      + 'snapshot = ' + RegistryTOMLQuote(Snapshot) + #10 + 'items = [';
    Count := 0;
    NextCursor := '';
    Item := Start;
    while (Item <= High(Index.Items))
      and ((AName = '') or (Index.Items[Item].Name = AName)) do
    begin
      if Count >= Limit then
      begin
        NextCursor := RegistryPackageCursor(AStore.Config.Identity, Snapshot,
          AName, Index.Items[Item - 1].Name, Index.Items[Item - 1].Version);
        Break;
      end;
      if Count > 0 then Body := Body + ', ';
      Body := Body + '{ name = ' + RegistryTOMLQuote(Index.Items[Item].Name)
        + ', version = ' + RegistryTOMLQuote(Index.Items[Item].Version)
        + ', record = ' + RegistryTOMLQuote(Index.Items[Item].RecordHash) + ' }';
      Inc(Count);
      Inc(Item);
    end;
    Body := Body + ']' + #10 + 'next_cursor = ' + RegistryTOMLQuote(NextCursor)
      + #10;
    Result := Default(TLWPTRegistryHTTPResponse);
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME
      + '.registry-page+toml';
    Result.CacheControl := 'no-cache';
    Result.Body := Bytes(Body);
  finally
    Parts.Free;
    Parameters.Free;
  end;
end;

function PackageVersionResponse(AStore: TLWPTRegistryStore;
  AView: TLWPTRegistryReadView; const AName, AVersion, AQuery: string;
  AProgress: TSHA256Progress): TLWPTRegistryHTTPResponse;
var
  Parameters: TStringList;
  Snapshot, StoredPath, Digest, RecordHash: string;
  Index: TLWPTRegistryPackageIndex;
  Reference: IInterface;
  Item: Integer;
begin
  Parameters := TStringList.Create;
  try
    if not ParseRegistryQuery(AQuery, ['snapshot'], Parameters) then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
        'package query is invalid'));
    Snapshot := Parameters.Values['snapshot'];
    if Snapshot = '' then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request',
        'exact-version lookup requires a snapshot'));
    Index := AStore.PackageIndex(AView, Snapshot, AProgress, Reference);
    if Index = nil then
      Exit(ErrorResponse(409, 'Conflict', 'snapshot_conflict',
        'requested snapshot is not in accepted history'));
    RecordHash := '';
    Item := Index.FirstOfName(AName);
    if Item >= 0 then
      while (Item <= High(Index.Items)) and (Index.Items[Item].Name = AName) do
      begin
        if Index.Items[Item].Version = AVersion then
          RecordHash := Index.Items[Item].RecordHash;
        Inc(Item);
      end;
    if (RecordHash = '') or not AView.Resolve('records/sha256/'
      + Copy(RecordHash, 8, 64) + '.toml', StoredPath, Digest, AProgress) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'package version was not found'));
    Result := ResourceResponse(AStore, StoredPath, 'application/vnd.'
      + PROGRAM_NAME + '.registry-package+toml', '"' + RecordHash + '"',
      Digest, True, AProgress);
  finally
    Parameters.Free;
  end;
end;

function RegistryCapabilitiesBody(AStore: TLWPTRegistryStore): string;
var
  Publication: Boolean;
begin
  Publication := (AStore.Config.Role = rrOrigin)
    and RegistryPublicationEnabled(AStore.Root, RegistryTimestampNow);
  Result := 'schema = "' + PROGRAM_NAME
    + '-registry-capabilities-v1"' + #10 + 'protocol = 1' + #10
    + 'hashes = ["sha256"]' + #10 + 'signatures = ["ed25519"]' + #10
    + 'schemas = ["' + PROGRAM_NAME + '-registry-capabilities-v1", "'
    + PROGRAM_NAME + '-registry-checkpoint-v1", "' + PROGRAM_NAME
    + '-registry-discovery-v1", "' + PROGRAM_NAME
    + '-registry-error-v1", "' + PROGRAM_NAME
    + '-registry-key-rotation-v1", "' + PROGRAM_NAME
    + '-registry-key-v1", "' + PROGRAM_NAME
    + '-registry-package-v1", "' + PROGRAM_NAME
    + '-registry-page-v1", "' + PROGRAM_NAME
    + '-registry-rotation-page-v1", "' + PROGRAM_NAME
    + '-registry-signature-v1", "' + PROGRAM_NAME
    + '-registry-snapshot-v1"]' + #10;
  if Publication then
    Result := Result + 'features = ["package-list-v1", "publication-v1", '
      + '"rotation-chain-v1", "snapshot-sync-v1"]' + #10
      + 'auth_schemes = ["bearer"]' + #10
  else
    Result := Result + 'features = ["package-list-v1", "rotation-chain-v1", '
      + '"snapshot-sync-v1"]' + #10 + 'auth_schemes = []' + #10;
  Result := Result + 'max_page_size = ' + IntToStr(RegistryRotationPageLimit)
    + #10;
end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string; AProgress: TSHA256Progress):
  TLWPTRegistryHTTPResponse;
var
  APIPath, Digest, KeyID, Prefix, Relative, RequestID, RoleName, Target, Query,
    MediaType, ETag, Name, StoredPath, ContentType, PackageVersion: string;
  Sequence: Int64;
  Immutable, HasQuery: Boolean;
  State: TLWPTRegistryState;
  View: TLWPTRegistryReadView;
begin
  Result := Default(TLWPTRegistryHTTPResponse);
  RoleName := 'origin';
  if AStore.Config.Role = rrMirror then RoleName := 'mirror';
  try
    AStore.EnsureFreshCheckpoint(RegistryTimestampNow, AProgress);
  except
    on E: ELWPTRegistryError do
    begin
      if Pos('connection_deadline:', E.Message) = 1 then raise;
      RequestID := NewRegistryRequestID;
      {$IFDEF UNIX}
      Relative := 'registry request ' + RequestID
        + ' checkpoint renewal failed: ' + E.Message + LineEnding;
      FpWrite(StdErrorHandle, Relative[1], Length(Relative));
      {$ELSE}
      WriteLn(ErrOutput, 'registry request ', RequestID,
        ' checkpoint renewal failed: ', E.Message);
      {$ENDIF}
      Exit(RegistryErrorResponse(500, 'Internal Server Error',
        'checkpoint_renewal_failed',
        'the active checkpoint could not be renewed', RequestID));
    end;
  end;
  if not SameText(AMethod, 'GET') and not SameText(AMethod, 'HEAD') then
    Exit(ErrorResponse(405, 'Method Not Allowed', 'method_not_allowed',
      'only GET and HEAD are supported'));
  if Pos('#', ATarget) > 0 then
    Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target',
      'request target is not canonical'));
  Prefix := BasePath(AStore.Config.BaseURL);
  Target := ATarget;
  Query := '';
  HasQuery := Pos('?', Target) > 0;
  if HasQuery then
  begin
    Query := Copy(Target, Pos('?', Target) + 1, MaxInt);
    Target := Copy(Target, 1, Pos('?', Target) - 1);
  end;
  if not StartsStr(Prefix + '/', Target) then
  begin
    if HasQuery then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target',
        'query is only supported for rotation and package pages'));
    Exit(ErrorResponse(404, 'Not Found', 'not_found',
      'request target is outside the configured registry base path'));
  end;
  APIPath := Copy(Target, Length(Prefix) + 1, MaxInt);
  { Queries are accepted only where the protocol defines them: rotation
    discovery and the package views. }
  if HasQuery and (APIPath <> '/v1/rotations') and (APIPath <> '/v1/packages')
    and not StartsStr('/v1/packages/', APIPath) then
    Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target',
      'query is only supported for rotation and package pages'));
  if RegistryPathHasDotSegment(APIPath) or (Pos('%', APIPath) > 0) then
    Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target',
      'request target is not canonical'));
  if APIPath = '/.well-known/' + PROGRAM_NAME + '-registry' then
  begin
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME
      + '.registry-discovery+toml';
    Result.CacheControl := 'no-cache';
    Result.ETag := '';
    Result.ResourcePath := '';
    Result.ResourceLength := 0;
    Result.ResourceDigest := '';
    Result.Body := Bytes('schema = "' + PROGRAM_NAME
      + '-registry-discovery-v1"' + #10 + 'protocol = 1' + #10
      + 'origin = "' + AStore.Config.Identity + '"' + #10
      + 'base_url = "' + AStore.Config.BaseURL + '"' + #10
      + 'role = "' + RoleName + '"' + #10 + 'api = "' + AStore.Config.BaseURL
      + '/v1"' + #10 + 'capabilities = "' + AStore.Config.BaseURL
      + '/v1/capabilities"' + #10 + 'checkpoint = "'
      + AStore.Config.BaseURL + '/v1/checkpoints/latest.toml"' + #10
      + 'rotations = "' + AStore.Config.BaseURL + '/v1/rotations"' + #10);
    Exit;
  end;
  if APIPath = '/v1/capabilities' then
  begin
    Result.Status := 200;
    Result.Reason := 'OK';
    Result.ContentType := 'application/vnd.' + PROGRAM_NAME
      + '.registry-capabilities+toml';
    Result.CacheControl := 'no-cache';
    Result.ETag := '';
    Result.ResourcePath := '';
    Result.ResourceLength := 0;
    Result.ResourceDigest := '';
    Result.Body := Bytes(RegistryCapabilitiesBody(AStore));
    Exit;
  end;
  if (APIPath = '/v1/packages') or StartsStr('/v1/packages/', APIPath) then
  begin
    Name := '';
    PackageVersion := '';
    if APIPath <> '/v1/packages' then
    begin
      Name := Copy(APIPath, Length('/v1/packages/') + 1, MaxInt);
      if Pos('/', Name) > 0 then
      begin
        PackageVersion := Copy(Name, Pos('/', Name) + 1, MaxInt);
        Name := Copy(Name, 1, Pos('/', Name) - 1);
        if not RegistryVersionIsCanonical(PackageVersion) then
          Exit(ErrorResponse(404, 'Not Found', 'not_found',
            'registry resource was not found'));
      end;
      if not RegistryPackageNameIsCanonical(Name) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found'));
    end;
    if not AStore.HasAcceptedState then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    View := AStore.CaptureReadView(AProgress);
    try
      if PackageVersion <> '' then
        Result := PackageVersionResponse(AStore, View, Name, PackageVersion,
          Query, AProgress)
      else Result := PackagePageResponse(AStore, View, Name, Query, AProgress);
    finally
      View.Free;
    end;
    Exit;
  end;
  { Classify the target before capturing state. Unknown or malformed routes
    never load or verify retained proof. }
  Relative := '';
  MediaType := '';
  ETag := '';
  Immutable := True;
  if APIPath = '/v1/rotations' then
    Relative := ''
  else if StartsStr('/v1/rotations/', APIPath) then
  begin
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Name := Copy(Relative, Length('rotations/') + 1, MaxInt);
    MediaType := 'key-rotation';
    if EndsStr('.old.sig.toml', Name) or EndsStr('.new.sig.toml', Name) then
    begin
      Delete(Name, Length(Name) - 12, 13);
      MediaType := 'signature';
    end
    else if EndsStr('.toml', Name) then Delete(Name, Length(Name) - 4, 5)
    else Name := '';
    if not TryStrToInt64(Name, Sequence) or (Sequence < 2)
      or (IntToStr(Sequence) <> Name) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
  end
  else if APIPath = '/v1/checkpoints/latest.toml' then
  begin
    MediaType := 'checkpoint';
    Immutable := False;
  end
  else if APIPath = '/v1/checkpoints/latest.sig.toml' then
  begin
    MediaType := 'signature';
    Immutable := False;
  end
  else if StartsStr('/v1/objects/sha256/', APIPath) then
  begin
    Digest := Copy(APIPath, Length('/v1/objects/sha256/') + 1, MaxInt);
    if not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    ETag := '"sha256:' + Digest + '"';
  end
  else if StartsStr('/v1/records/sha256/', APIPath)
    or StartsStr('/v1/snapshots/sha256/', APIPath) then
  begin
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    Digest := Copy(Relative, Pos('/sha256/', Relative) + Length('/sha256/'), MaxInt);
    if not EndsStr('.toml', Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Delete(Digest, Length(Digest) - 4, 5);
    if not IsLowerHex64(Digest) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    if StartsStr('records/', Relative) then MediaType := 'package'
    else MediaType := 'snapshot';
    ETag := '"sha256:' + Digest + '"';
  end
  else if StartsStr('/v1/keys/ed25519:', APIPath) then
  begin
    KeyID := Copy(APIPath, Length('/v1/keys/') + 1,
      Length(APIPath) - Length('/v1/keys/') - Length('.toml'));
    if not EndsStr('.toml', APIPath) or not StartsStr('ed25519:', KeyID)
      or not IsLowerHex64(Copy(KeyID, Length('ed25519:') + 1,
        MaxInt)) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found',
        'registry resource was not found'));
    Relative := RegistryKeyStoragePath(KeyID);
    MediaType := 'key';
  end
  else if StartsStr('/v1/checkpoints/', APIPath)
    and CheckpointRouteIsWellFormed(Copy(APIPath, Length('/v1/checkpoints/') + 1, MaxInt)) then
  begin
    Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
    if EndsStr('.sig.toml', APIPath) then MediaType := 'signature'
    else MediaType := 'checkpoint';
    Immutable := False;
  end
  else
    Exit(ErrorResponse(404, 'Not Found', 'not_found',
      'registry resource was not found'));
  { A mirror publishes nothing before its first activation. }
  if not AStore.HasAcceptedState then
    Exit(ErrorResponse(404, 'Not Found', 'not_found',
      'registry resource was not found'));
  View := AStore.CaptureReadView(AProgress);
  try
    State := View.State;
    if APIPath = '/v1/rotations' then Exit(RotationPageResponse(AStore, View, Query, AProgress));
    if APIPath = '/v1/checkpoints/latest.toml' then Relative := State.CheckpointPath
    else if APIPath = '/v1/checkpoints/latest.sig.toml' then Relative := State.SignaturePath;
    if not View.Resolve(Relative, StoredPath, Digest, AProgress) then
      Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
    if MediaType = '' then ContentType := 'application/gzip'
    else ContentType := 'application/vnd.' + PROGRAM_NAME + '.registry-' + MediaType + '+toml';
    Result := ResourceResponse(AStore, StoredPath, ContentType, ETag, Digest,
      Immutable, AProgress);
  finally
    View.Free;
  end;
end;

function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;
var
  ContentLength: Int64;
  Header: string;
  HeaderBytes: TBytes;
begin
  if AResponse.ResourcePath <> '' then
    ContentLength := AResponse.ResourceLength
  else ContentLength := Length(AResponse.Body);
  Header := 'HTTP/1.1 ' + IntToStr(AResponse.Status) + ' '
    + AResponse.Reason + #13#10;
  if AResponse.ContentType <> '' then
    Header := Header + 'Content-Type: ' + AResponse.ContentType + #13#10;
  { A 204 carries neither a body nor a length. }
  if AResponse.Status <> 204 then
    Header := Header + 'Content-Length: ' + IntToStr(ContentLength) + #13#10;
  if AResponse.CacheControl <> '' then
    Header := Header + 'Cache-Control: ' + AResponse.CacheControl + #13#10;
  if AResponse.ETag <> '' then Header := Header + 'ETag: ' + AResponse.ETag
    + #13#10;
  if AResponse.Location <> '' then
    Header := Header + 'Location: ' + AResponse.Location + #13#10;
  if AResponse.RetryAfter > 0 then
    Header := Header + 'Retry-After: ' + IntToStr(AResponse.RetryAfter) + #13#10;
  if AResponse.Challenge <> '' then
    Header := Header + 'WWW-Authenticate: ' + AResponse.Challenge + #13#10;
  Header := Header + 'Connection: close' + #13#10 + #13#10;
  HeaderBytes := Bytes(Header);
  if not AIncludeBody or (AResponse.ResourcePath <> '') then Exit(HeaderBytes);
  SetLength(Result, Length(HeaderBytes) + Length(AResponse.Body));
  if Length(HeaderBytes) > 0 then Move(HeaderBytes[0], Result[0],
    Length(HeaderBytes));
  if Length(AResponse.Body) > 0 then Move(AResponse.Body[0],
    Result[Length(HeaderBytes)], Length(AResponse.Body));
end;

function ParseRegistryRequestHead(const AText, APeer: string;
  out AHead: TLWPTRegistryRequestHead): Boolean;
var
  Lines: TStringList;
  Line, RequestLine, Name, Value: string;
  Space, Colon, Index, Count: Integer;
  Character: Char;
begin
  Result := False;
  AHead := Default(TLWPTRegistryRequestHead);
  AHead.Peer := APeer;
  { Bare CR or LF inside a line is malformed; only CRLF separates lines. }
  Lines := TStringList.Create;
  try
    Line := AText;
    while Line <> '' do
    begin
      Colon := Pos(#13#10, Line);
      if Colon = 0 then
      begin
        Lines.Add(Line);
        Break;
      end;
      Lines.Add(Copy(Line, 1, Colon - 1));
      Delete(Line, 1, Colon + 1);
    end;
    for Index := 0 to Lines.Count - 1 do
      if (Pos(#13, Lines[Index]) > 0) or (Pos(#10, Lines[Index]) > 0)
        or (Pos(#0, Lines[Index]) > 0) then Exit;
    if Lines.Count = 0 then Exit;
    RequestLine := Lines[0];
    Space := Pos(' ', RequestLine);
    if Space <= 1 then Exit;
    AHead.Method := Copy(RequestLine, 1, Space - 1);
    Delete(RequestLine, 1, Space);
    Space := Pos(' ', RequestLine);
    if Space <= 1 then Exit;
    AHead.Target := Copy(RequestLine, 1, Space - 1);
    for Character in AHead.Method do
      if not (Character in ['A'..'Z', 'a'..'z']) then Exit;
    Count := 0;
    SetLength(AHead.Headers, Lines.Count - 1);
    for Index := 1 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      if Line = '' then Continue;
      { Obsolete line folding and fields without a name are malformed. }
      if Line[1] in [' ', #9] then Exit;
      Colon := Pos(':', Line);
      if Colon <= 1 then Exit;
      Name := Copy(Line, 1, Colon - 1);
      for Character in Name do
        if not (Character in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.',
          '!', '#', '$', '%', '&', '''', '*', '+', '^', '`', '|', '~']) then
          Exit;
      Value := Trim(Copy(Line, Colon + 1, MaxInt));
      AHead.Headers[Count].Name := Name;
      AHead.Headers[Count].Value := Value;
      Inc(Count);
    end;
    SetLength(AHead.Headers, Count);
  finally
    Lines.Free;
  end;
  Result := True;
end;

function RegistryHeaderValues(const AHead: TLWPTRegistryRequestHead;
  const AName: string): TStringArray;
var
  Index, Count: Integer;
begin
  Result := nil;
  Count := 0;
  for Index := 0 to High(AHead.Headers) do
    if SameText(AHead.Headers[Index].Name, AName) then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := AHead.Headers[Index].Value;
      Inc(Count);
    end;
end;

function RegistryPathHasDotSegment(const APath: string): Boolean;
var
  Start, Index: Integer;
  Segment: string;
begin
  Result := False;
  Start := 1;
  for Index := 1 to Length(APath) + 1 do
    if (Index > Length(APath)) or (APath[Index] = '/') then
    begin
      Segment := Copy(APath, Start, Index - Start);
      if (Segment = '.') or (Segment = '..') then Exit(True);
      Start := Index + 1;
    end;
end;

function RegistryMethodIsRead(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'GET') or SameText(AMethod, 'HEAD');
end;

function RegistryDispatch(AStore: TLWPTRegistryStore;
  AHandler: TLWPTRegistryMutationHandler;
  const AHead: TLWPTRegistryRequestHead; AProgress: TSHA256Progress;
  out AMutation: TLWPTRegistryMutation): TLWPTRegistryHTTPResponse;
begin
  AMutation := nil;
  if RegistryMethodIsRead(AHead.Method) or not Assigned(AHandler) then
    Exit(RegistryHTTPResponse(AStore, AHead.Method, AHead.Target, AProgress));
  AMutation := AHandler.BeginMutation(AHead, Result);
end;

{$IFDEF REGISTRY_TESTING}
var
  RegistryHeaderDeadlineForTesting: QWord;

procedure SetRegistryHeaderDeadlineForTesting(const AMilliseconds: QWord);
begin
  RegistryHeaderDeadlineForTesting := AMilliseconds;
end;
{$ENDIF}

function RegistryHeaderDeadlineMilliseconds: QWord;
begin
  Result := CLIENT_READ_TIMEOUT_MILLISECONDS;
  {$IFDEF REGISTRY_TESTING}
  if RegistryHeaderDeadlineForTesting > 0 then
    Result := RegistryHeaderDeadlineForTesting;
  {$ENDIF}
end;

procedure RegistryAuditIncompleteRequest(AHandler: TLWPTRegistryMutationHandler;
  const ARaw, APeer: string; const ATimedOut: Boolean);
begin
  if ARaw = '' then Exit;
  try
    if ATimedOut then
      RegistryMalformedRequestResponse(AHandler, ARaw, APeer, 408,
        'Request Timeout', 'request_timeout',
        'request headers did not arrive in time')
    else RegistryMalformedRequestResponse(AHandler, ARaw, APeer, 400,
      'Bad Request', 'invalid_request', 'request headers are incomplete');
  except
    { Auditing an abandoned connection never fails the listener. }
  end;
end;

{$IFDEF REGISTRY_TESTING}
var
  RegistryBodyDeadlineBaseForTesting: QWord;

procedure SetRegistryBodyDeadlineForTesting(const ABaseMilliseconds: QWord);
begin
  RegistryBodyDeadlineBaseForTesting := ABaseMilliseconds;
end;
{$ENDIF}

function RegistryBodyDeadlineMilliseconds(const ABodyLength: Int64): QWord;
const
  MEBIBYTE = Int64(1024) * 1024;
begin
  Result := RegistryBodyBaseDeadlineMilliseconds;
  {$IFDEF REGISTRY_TESTING}
  if RegistryBodyDeadlineBaseForTesting > 0 then
    Result := RegistryBodyDeadlineBaseForTesting;
  {$ENDIF}
  if ABodyLength > 0 then
    Inc(Result, QWord((ABodyLength + MEBIBYTE - 1) div MEBIBYTE) * 1000);
end;

function RegistryMalformedRequestResponse(AHandler: TLWPTRegistryMutationHandler;
  const ARaw, APeer: string; const AStatus: Integer; const AReason, ACode,
  AMessage: string): TLWPTRegistryHTTPResponse;
var
  Method: string;
  Index: Integer;
begin
  Method := '';
  for Index := 1 to Length(ARaw) do
  begin
    if ARaw[Index] = ' ' then Break;
    if not (ARaw[Index] in ['A'..'Z']) or (Index > 16) then
    begin
      Method := '';
      Break;
    end;
    Method := Method + ARaw[Index];
  end;
  if Assigned(AHandler) and (Method <> '') and not RegistryMethodIsRead(Method)
    and (RegistryAuditMethod(Method) = Method) then
    Exit(AHandler.RefuseMalformed(Method, APeer, AStatus, AReason, ACode,
      AMessage));
  Result := ErrorResponse(AStatus, AReason, ACode, AMessage);
end;

function CreateRegistryMutationHandler(AStore: TLWPTRegistryStore):
  TLWPTRegistryMutationHandler;
begin
  Result := TLWPTRegistryPublisher.Create(AStore);
end;

function RegistryPeerAddress(const AAddress: TRegistrySockAddr): string;
var
  Octets: array[0..3] of Byte absolute AAddress.sin_addr;
begin
  Result := IntToStr(Octets[0]) + '.' + IntToStr(Octets[1]) + '.'
    + IntToStr(Octets[2]) + '.' + IntToStr(Octets[3]);
end;

constructor TLWPTRegistryClientThread.Create(const ASocket: TSocket;
  AStore: TLWPTRegistryStore;
  ATLSServerContext: TTransportSecurityServerContext;
  AHandler: TLWPTRegistryMutationHandler; const APeer: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSocket := ASocket;
  FStore := AStore;
  FHandler := AHandler;
  FPeer := APeer;
  FTLSServerContext := ATLSServerContext;
  FTLSCiphertextReceived := 0;
  FDeadline := GetTickCount64 + RegistryHeaderDeadlineMilliseconds;
  FDone := False;
end;

procedure TLWPTRegistryClientThread.CheckDeadline;
begin
  if Terminated or (GetTickCount64 >= FDeadline) then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'registry connection exceeded its total deadline');
end;

procedure TLWPTRegistryClientThread.Cancel;
begin
  Terminate;
  RegistrySocketShutdown(FSocket);
end;

function RegistryDeadlineTimeout(const ADeadline, ANow: QWord): LongInt;
var
  Remaining: QWord;
begin
  if ANow >= ADeadline then Exit(1);
  Remaining := ADeadline - ANow;
  if Remaining > High(LongInt) then Exit(High(LongInt));
  Result := LongInt(Remaining);
  if Result < 1 then Result := 1;
end;

function RegistryTLSShutdownStateIsTerminal(
  const AState: TTransportSecurityState): Boolean; inline;
begin
  Result := AState in [tssDone, tssError, tssPeerClosed];
end;

{$IFDEF REGISTRY_TESTING}
function RegistryDeadlineTimeoutForTesting(const ADeadline,
  ANow: QWord): LongInt;
begin
  Result := RegistryDeadlineTimeout(ADeadline, ANow);
end;

function RegistryTLSShutdownStateIsTerminalForTesting(
  const AState: Integer): Boolean;
begin
  Result := (AState >= Ord(Low(TTransportSecurityState)))
    and (AState <= Ord(High(TTransportSecurityState)))
    and RegistryTLSShutdownStateIsTerminal(TTransportSecurityState(AState));
end;
{$ENDIF}

procedure ApplyDeadlineTimeout(const ASocket: TSocket;
  const ADeadline: QWord);
var
  TimeoutMilliseconds: LongInt;
  {$IFDEF UNIX}
  Timeout: TTimeVal;
  {$ELSE}
  Timeout: LongInt;
  {$ENDIF}
begin
  TimeoutMilliseconds := RegistryDeadlineTimeout(ADeadline, GetTickCount64);
  {$IFDEF UNIX}
  Timeout.tv_sec := TimeoutMilliseconds div 1000;
  Timeout.tv_usec := (TimeoutMilliseconds mod 1000) * 1000;
  {$ELSE}
  Timeout := TimeoutMilliseconds;
  {$ENDIF}
  RegistrySetSocketOption(ASocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout,
    SizeOf(Timeout));
  RegistrySetSocketOption(ASocket, SOL_SOCKET, SO_SNDTIMEO, @Timeout,
    SizeOf(Timeout));
end;

procedure SendAll(const ASocket: TSocket; const ABytes: TBytes;
  const ADeadline: QWord);
var
  Offset, Sent: Integer;
begin
  Offset := 0;
  while Offset < Length(ABytes) do
  begin
    if GetTickCount64 >= ADeadline then Exit;
    ApplyDeadlineTimeout(ASocket, ADeadline);
    Sent := RegistrySocketSend(ASocket, @ABytes[Offset],
      Length(ABytes) - Offset);
    if Sent <= 0 then Exit;
    Inc(Offset, Sent);
  end;
end;

function OpenRegistryHTTPResource(const AResponse: TLWPTRegistryHTTPResponse;
  AProgress: TSHA256Progress): TStream;
begin
  Result := nil;
  if AResponse.ResourcePath = '' then Exit;
  if Assigned(AProgress) then AProgress;
  try
    Result := OpenRegistryFileWithoutFollowingLinks(AResponse.ResourcePath);
  except
    on E: ELWPTRegistryFileOpenError do
      raise ELWPTRegistryError.CreateStable('resource_changed', E.Message);
  end;
  try
    if (Result.Size <> AResponse.ResourceLength)
      or (Result.Size > MAX_REGISTRY_RESOURCE_BYTES) then
      raise ELWPTRegistryError.CreateStable('resource_changed',
        'registry resource size changed after routing');
    if (AResponse.ResourceDigest <> '')
      and ('sha256:' + SHA256Stream(Result, AProgress)
      <> AResponse.ResourceDigest) then
      raise ELWPTRegistryError.CreateStable('resource_hash_mismatch',
        'registry resource changed after routing');
    Result.Position := 0;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

procedure SendResourcePlain(const ASocket: TSocket;
  AStream: TStream; const ADeadline: QWord);
var
  Buffer: array[0..65535] of Byte;
  ReadCount, Sent, SentTotal: Integer;
begin
  repeat
    if RegistryMonotonicMilliseconds >= ADeadline then Exit;
    ReadCount := AStream.Read(Buffer[0], SizeOf(Buffer));
    SentTotal := 0;
    while SentTotal < ReadCount do
    begin
      if RegistryMonotonicMilliseconds >= ADeadline then Exit;
      ApplyDeadlineTimeout(ASocket, ADeadline);
      Sent := RegistrySocketSend(ASocket, @Buffer[SentTotal],
        ReadCount - SentTotal);
      if Sent <= 0 then Exit;
      Inc(SentTotal, Sent);
    end;
  until ReadCount = 0;
end;

{$IFDEF REGISTRY_TESTING}
function RegistrySendResourcePlainForTesting(AStream: TStream;
  const ADeadline, AStartTime, AAdvancePerSend: QWord;
  const AMaximumSend: Integer): Integer;
begin
  RegistryTestPlainSendActive := True;
  RegistryTestPlainSendAdvance := AAdvancePerSend;
  RegistryTestPlainSendCalls := 0;
  RegistryTestPlainSendMaximum := AMaximumSend;
  RegistryTestPlainSendTime := AStartTime;
  try
    { The testing seam intercepts deadline socket options and every send before
      the portable placeholder socket is observed. }
    SendResourcePlain(0, AStream, ADeadline);
    Result := RegistryTestPlainSendCalls;
  finally
    RegistryTestPlainSendActive := False;
  end;
end;

{$ENDIF}

function TLWPTRegistryClientThread.ReadBodyPlain(
  AMutation: TLWPTRegistryMutation; const ALeftover: string): Boolean;
var
  Buffer: array[0..65535] of Byte;
  Remaining: Int64;
  Count, Received: Integer;
begin
  Result := False;
  Remaining := AMutation.BodyLength;
  FDeadline := GetTickCount64 + RegistryBodyDeadlineMilliseconds(Remaining);
  try
    if (Remaining > 0) and AMutation.ExpectsContinue then
      SendAll(FSocket, Bytes('HTTP/1.1 100 Continue' + #13#10#13#10), FDeadline);
    Count := Length(ALeftover);
    if Count > Remaining then Count := Integer(Remaining);
    if Count > 0 then
    begin
      AMutation.Feed(ALeftover[1], Count);
      Dec(Remaining, Count);
    end;
    while Remaining > 0 do
    begin
      CheckDeadline;
      ApplyDeadlineTimeout(FSocket, FDeadline);
      Count := Length(Buffer);
      if Count > Remaining then Count := Integer(Remaining);
      Received := RegistrySocketReceive(FSocket, @Buffer[0], Count);
      if Received <= 0 then Exit;
      AMutation.Feed(Buffer[0], Received);
      Dec(Remaining, Received);
    end;
  except
    Exit;
  end;
  FDeadline := GetTickCount64 + RegistryMutationProcessingMilliseconds;
  Result := True;
end;

procedure TLWPTRegistryClientThread.ExecutePlain;
var
  Buffer: array[0..4095] of Byte;
  HeaderEnd, Received: Integer;
  IncludeBody: Boolean;
  Chunk, Request: string;
  Head: TLWPTRegistryRequestHead;
  Mutation: TLWPTRegistryMutation;
  ResourceStream: TStream;
  Response: TLWPTRegistryHTTPResponse;
  Wire: TBytes;
begin
  ResourceStream := nil;
  Mutation := nil;
  try
    try
      Request := '';
      repeat
        CheckDeadline;
        ApplyDeadlineTimeout(FSocket, FDeadline);
        Received := RegistrySocketReceive(FSocket, @Buffer[0], Length(Buffer));
        if Received <= 0 then Exit;
        SetString(Chunk, PAnsiChar(@Buffer[0]), Received);
        Request := Request + Chunk;
        FPartialHead := Copy(Request, 1, 32);
        HeaderEnd := Pos(#13#10#13#10, Request);
        if ((HeaderEnd = 0) and (Length(Request) > MAX_REQUEST_HEADER_BYTES))
          or (HeaderEnd > MAX_REQUEST_HEADER_BYTES) then
        begin
          FHeadHandled := True;
          Response := RegistryMalformedRequestResponse(FHandler, Request, FPeer,
            431, 'Request Header Fields Too Large', 'request_headers_too_large',
            'request headers exceed 32 KiB');
          SendAll(FSocket, RegistryHTTPWireResponse(Response, True), FDeadline);
          Exit;
        end;
      until HeaderEnd > 0;
      FHeadHandled := True;
      if not ParseRegistryRequestHead(Copy(Request, 1, HeaderEnd - 1), FPeer,
        Head) then
        Response := RegistryMalformedRequestResponse(FHandler, Request, FPeer,
          400, 'Bad Request', 'invalid_request', 'request line is invalid')
      else
      begin
        { Admission and its refusal get their own processing deadline, so
          bounded lease waits cannot outlast the header deadline and drop
          a retryable answer. }
        if not RegistryMethodIsRead(Head.Method) then
          FDeadline := GetTickCount64 + RegistryMutationProcessingMilliseconds;
        Response := RegistryDispatch(FStore, FHandler, Head, CheckDeadline,
          Mutation);
        if Assigned(Mutation) then
        begin
          if not ReadBodyPlain(Mutation, Copy(Request, HeaderEnd + 4,
            MaxInt)) then
          begin
            Mutation.Abort;
            Exit;
          end;
          Response := Mutation.Finish;
          FreeAndNil(Mutation);
        end;
      end;
      IncludeBody := not SameText(Head.Method, 'HEAD');
      if Response.ResourcePath <> '' then
        try
          ResourceStream := OpenRegistryHTTPResource(Response, CheckDeadline);
        except
          on E: Exception do
            Response := RegistryResourceFailureResponse(E.Message);
        end;
      Wire := RegistryHTTPWireResponse(Response,
        IncludeBody and (Response.ResourcePath = ''));
      CheckDeadline;
      SendAll(FSocket, Wire, FDeadline);
      if IncludeBody and Assigned(ResourceStream) then
        SendResourcePlain(FSocket, ResourceStream, FDeadline);
    finally
      Mutation.Free;
      ResourceStream.Free;
    end;
  except
    { A malformed client must not end the foreground server. }
  end;
end;

procedure FlushTLSCiphertext(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection; const ADeadline: QWord);
var
  Buffer: Pointer;
  Pending, Sent: Integer;
begin
  while TransportSecurityPendingCiphertext(AConnection) > 0 do
  begin
    if GetTickCount64 >= ADeadline then
      raise ELWPTRegistryError.CreateStable('connection_deadline',
        'registry connection exceeded its total deadline');
    ApplyDeadlineTimeout(ASocket, ADeadline);
    Pending := TransportSecurityGetCiphertext(AConnection, Buffer);
    if Pending <= 0 then Exit;
    Sent := RegistrySocketSend(ASocket, Buffer, Pending);
    if Sent <= 0 then
      raise ELWPTRegistryError.CreateStable('tls_io_failed',
        'could not send TLS ciphertext');
    TransportSecurityConsumeCiphertext(AConnection, Sent);
  end;
end;

procedure ReceiveTLSCiphertext(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection;
  var AReceivedTotal: QWord; const ADeadline: QWord);
var
  Buffer: array[0..16383] of Byte;
  Accepted, Received: Integer;
begin
  if GetTickCount64 >= ADeadline then
    raise ELWPTRegistryError.CreateStable('connection_deadline',
      'registry connection exceeded its total deadline');
  ApplyDeadlineTimeout(ASocket, ADeadline);
  Received := RegistrySocketReceive(ASocket, @Buffer[0], Length(Buffer));
  if Received <= 0 then
    raise ELWPTRegistryError.CreateStable('tls_io_failed',
      'TLS peer closed before completing the request');
  Inc(AReceivedTotal, Received);
  if AReceivedTotal > RegistryTLSCiphertextBudget then
    raise ELWPTRegistryError.CreateStable('tls_input_limit',
      'TLS connection exceeded its ciphertext byte budget');
  Accepted := TransportSecurityFeedCiphertext(AConnection, @Buffer[0],
    Received);
  if Accepted <> Received then
    raise ELWPTRegistryError.CreateStable('tls_input_limit',
      'TLS ciphertext exceeded the configured input capacity');
end;

procedure SendTLSBuffer(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection; const ABuffer;
  const ACount: Integer; const ADeadline: QWord;
  var AReceivedTotal: QWord);
var
  Buffer: PByte;
  Offset: Integer;
  IOResult: TTransportSecurityIOResult;
  RetryPending: Boolean;
begin
  Buffer := @ABuffer;
  Offset := 0;
  RetryPending := False;
  while Offset < ACount do
  begin
    if GetTickCount64 >= ADeadline then
      raise ELWPTRegistryError.CreateStable('connection_deadline',
        'registry connection exceeded its total deadline');
    if RetryPending then
      IOResult := TransportSecurityServerWrite(AConnection, nil, 0)
    else
      IOResult := TransportSecurityServerWrite(AConnection, @Buffer[Offset],
        ACount - Offset);
    if IOResult.BytesProcessed > 0 then
    begin
      Inc(Offset, IOResult.BytesProcessed);
      RetryPending := False;
    end
    else if RetryPending and (IOResult.State = tssDone)
      and (TransportSecurityPendingCiphertext(AConnection) = 0) then
      RetryPending := False
    else if IOResult.State in [tssWantRead, tssWantWrite] then
      RetryPending := True;
    FlushTLSCiphertext(ASocket, AConnection, ADeadline);
    if (IOResult.BytesProcessed = 0) and (IOResult.State = tssWantRead) then
      ReceiveTLSCiphertext(ASocket, AConnection, AReceivedTotal, ADeadline)
    else if (IOResult.BytesProcessed = 0) and not
      (IOResult.State in [tssDone, tssWantWrite]) then
      raise ELWPTRegistryError.CreateStable('tls_io_failed',
        'TLS response write failed');
  end;
end;

procedure SendResourceTLS(const ASocket: TSocket;
  var AConnection: TTransportSecurityConnection;
  AStream: TStream; const ADeadline: QWord;
  var AReceivedTotal: QWord);
var
  Buffer: array[0..65535] of Byte;
  ReadCount: Integer;
begin
  repeat
    ReadCount := AStream.Read(Buffer[0], SizeOf(Buffer));
    if ReadCount > 0 then SendTLSBuffer(ASocket, AConnection, Buffer[0],
      ReadCount, ADeadline, AReceivedTotal);
  until ReadCount = 0;
end;

procedure TLWPTRegistryClientThread.ExecuteTLS;
var
  Buffer: array[0..16383] of Byte;
  Connection: TTransportSecurityConnection;
  Count, HeaderEnd: Integer;
  IncludeBody, BodyComplete, Oversized: Boolean;
  Request, RequestChunk, Leftover: string;
  Head: TLWPTRegistryRequestHead;
  Mutation: TLWPTRegistryMutation;
  Remaining: Int64;
  ResourceStream: TStream;
  Response: TLWPTRegistryHTTPResponse;
  ResultState: TTransportSecurityState;
  IOResult: TTransportSecurityIOResult;
  Wire: TBytes;
begin
  ResourceStream := nil;
  Mutation := nil;
  RegistryTLSCiphertextBudget := TLS_CIPHERTEXT_BUDGET_BYTES;
  FillChar(Connection, SizeOf(Connection), 0);
  BeginTransportSecurityServer(Connection, FTLSServerContext);
  try
    repeat
      CheckDeadline;
      FlushTLSCiphertext(FSocket, Connection, FDeadline);
      ResultState := TransportSecurityServerHandshake(Connection);
      case ResultState of
        tssDone:;
        tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
          FTLSCiphertextReceived, FDeadline);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection, FDeadline);
        else raise ELWPTRegistryError.CreateStable('tls_handshake_failed',
          'TLS server handshake failed');
      end;
    until (ResultState = tssDone)
      and (TransportSecurityPendingCiphertext(Connection) = 0);
    Request := '';
    Oversized := False;
    repeat
      CheckDeadline;
      IOResult := TransportSecurityServerRead(Connection, Buffer, 4096);
      if IOResult.BytesProcessed > 0 then
      begin
        SetString(RequestChunk, PAnsiChar(@Buffer[0]),
          IOResult.BytesProcessed);
        Request := Request + RequestChunk;
        FPartialHead := Copy(Request, 1, 32);
      end;
      HeaderEnd := Pos(#13#10#13#10, Request);
      if ((HeaderEnd = 0) and (Length(Request) > MAX_REQUEST_HEADER_BYTES))
        or (HeaderEnd > MAX_REQUEST_HEADER_BYTES) then
      begin
        Oversized := True;
        Break;
      end;
      if HeaderEnd > 0 then Break;
      case IOResult.State of
        tssDone:;
        tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
          FTLSCiphertextReceived, FDeadline);
        tssWantWrite: FlushTLSCiphertext(FSocket, Connection, FDeadline);
        else raise ELWPTRegistryError.CreateStable('tls_io_failed',
          'TLS request read failed');
      end;
    until False;
    Head := Default(TLWPTRegistryRequestHead);
    FHeadHandled := True;
    if Oversized then
      Response := RegistryMalformedRequestResponse(FHandler, Request, FPeer,
        431, 'Request Header Fields Too Large', 'request_headers_too_large',
        'request headers exceed 32 KiB')
    else if not ParseRegistryRequestHead(Copy(Request, 1, HeaderEnd - 1), FPeer,
      Head) then
      Response := RegistryMalformedRequestResponse(FHandler, Request, FPeer,
        400, 'Bad Request', 'invalid_request', 'request line is invalid')
    else
    begin
      if not RegistryMethodIsRead(Head.Method) then
        FDeadline := GetTickCount64 + RegistryMutationProcessingMilliseconds;
      Response := RegistryDispatch(FStore, FHandler, Head, CheckDeadline,
        Mutation);
    end;
    if Assigned(Mutation) then
    begin
      Remaining := Mutation.BodyLength;
      BodyComplete := False;
      try
        FDeadline := GetTickCount64 + RegistryBodyDeadlineMilliseconds(Remaining);
        { Record overhead is far below 1/32 of the plaintext. }
        RegistryTLSCiphertextBudget := TLS_CIPHERTEXT_BUDGET_BYTES
          + QWord(Remaining) + QWord(Remaining div 32) + 65536;
        if (Remaining > 0) and Mutation.ExpectsContinue then
        begin
          Wire := Bytes('HTTP/1.1 100 Continue' + #13#10#13#10);
          SendTLSBuffer(FSocket, Connection, Wire[0], Length(Wire), FDeadline,
            FTLSCiphertextReceived);
        end;
        Leftover := Copy(Request, HeaderEnd + 4, MaxInt);
        Count := Length(Leftover);
        if Count > Remaining then Count := Integer(Remaining);
        if Count > 0 then
        begin
          Mutation.Feed(Leftover[1], Count);
          Dec(Remaining, Count);
        end;
        while Remaining > 0 do
        begin
          CheckDeadline;
          Count := Length(Buffer);
          if Count > Remaining then Count := Integer(Remaining);
          IOResult := TransportSecurityServerRead(Connection, Buffer, Count);
          if IOResult.BytesProcessed > 0 then
          begin
            Mutation.Feed(Buffer[0], IOResult.BytesProcessed);
            Dec(Remaining, IOResult.BytesProcessed);
            Continue;
          end;
          case IOResult.State of
            tssDone:;
            tssWantRead: ReceiveTLSCiphertext(FSocket, Connection,
              FTLSCiphertextReceived, FDeadline);
            tssWantWrite: FlushTLSCiphertext(FSocket, Connection, FDeadline);
            else raise ELWPTRegistryError.CreateStable('tls_io_failed',
              'TLS request body read failed');
          end;
        end;
        BodyComplete := True;
      finally
        if not BodyComplete then
        begin
          Mutation.Abort;
          FreeAndNil(Mutation);
        end;
      end;
      FDeadline := GetTickCount64 + RegistryMutationProcessingMilliseconds;
      Response := Mutation.Finish;
      FreeAndNil(Mutation);
    end;
    IncludeBody := not SameText(Head.Method, 'HEAD');
    if Response.ResourcePath <> '' then
      try
        ResourceStream := OpenRegistryHTTPResource(Response, CheckDeadline);
      except
        on E: Exception do
          Response := RegistryResourceFailureResponse(E.Message);
      end;
    Wire := RegistryHTTPWireResponse(Response,
      IncludeBody and (Response.ResourcePath = ''));
    if Length(Wire) > 0 then SendTLSBuffer(FSocket, Connection, Wire[0],
      Length(Wire), FDeadline, FTLSCiphertextReceived);
    if IncludeBody and Assigned(ResourceStream) then
      SendResourceTLS(FSocket, Connection, ResourceStream, FDeadline,
        FTLSCiphertextReceived);
    FlushTLSCiphertext(FSocket, Connection, FDeadline);
    repeat
      ResultState := CloseTransportSecurityServerGracefully(Connection);
      if not RegistryTLSShutdownStateIsTerminal(ResultState) then
      begin
        CheckDeadline;
        FlushTLSCiphertext(FSocket, Connection, FDeadline);
        if ResultState = tssWantRead then
          ReceiveTLSCiphertext(FSocket, Connection, FTLSCiphertextReceived,
            FDeadline);
      end;
    until RegistryTLSShutdownStateIsTerminal(ResultState);
  finally
    Mutation.Free;
    ResourceStream.Free;
    AbortTransportSecurityServer(Connection);
  end;
end;

procedure TLWPTRegistryClientThread.Execute;
begin
  try
    if Assigned(FTLSServerContext) then ExecuteTLS
    else ExecutePlain;
  except
    { Connection-scoped protocol and I/O failures do not stop the listener. }
  end;
  { A head that began but never completed: exactly one audit record for a
    recognizable mutating method, whether or not a response can be sent. }
  if not FHeadHandled then
    RegistryAuditIncompleteRequest(FHandler, FPartialHead, FPeer,
      GetTickCount64 >= FDeadline);
  FPartialHead := '';
  RegistrySocketShutdown(FSocket);
  RegistrySocketClose(FSocket);
  FDone := True;
end;

constructor TLWPTRegistryServer.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create;
  FStore := AStore;
  FHandler := CreateRegistryMutationHandler(AStore);
  FClients := TThreadList.Create;
  FStopping := False;
end;

destructor TLWPTRegistryServer.Destroy;
begin
  RequestStop;
  DrainClients;
  FClients.Free;
  FHandler.Free;
  inherited Destroy;
end;

procedure TLWPTRegistryServer.RequestStop;
begin
  FStopping := True;
end;

procedure TLWPTRegistryServer.ReapClients;
var
  Clients: TList;
  Client: TLWPTRegistryClientThread;
  Index: Integer;
begin
  Clients := FClients.LockList;
  try
    for Index := Clients.Count - 1 downto 0 do
    begin
      Client := TLWPTRegistryClientThread(Clients[Index]);
      if Client.Done then
      begin
        Clients.Delete(Index);
        Client.WaitFor;
        Client.Free;
      end;
    end;
  finally
    FClients.UnlockList;
  end;
end;

procedure TLWPTRegistryServer.DrainClients;
var
  Clients: TList;
  Client: TLWPTRegistryClientThread;
  Index: Integer;
begin
  Clients := FClients.LockList;
  try
    for Index := 0 to Clients.Count - 1 do
      TLWPTRegistryClientThread(Clients[Index]).Cancel;
  finally
    FClients.UnlockList;
  end;
  while True do
  begin
    Clients := FClients.LockList;
    try
      if Clients.Count = 0 then Exit;
      Client := TLWPTRegistryClientThread(Clients[0]);
      Clients.Delete(0);
    finally
      FClients.UnlockList;
    end;
    Client.WaitFor;
    Client.Free;
  end;
end;

procedure TLWPTRegistryServer.Run;
var
  Address: TRegistrySockAddr;
  AddressLength: TRegistrySockLen;
  ClientSocket, ListenSocket: TSocket;
  Client: TLWPTRegistryClientThread;
  Clients: TList;
  ListenHost: string;
  ReadSet: TFDSet;
  Reuse: LongInt;
  SelectResult: Integer;
  SelectTimeout: TTimeVal;
  {$IFDEF UNIX}
  Timeout: TTimeVal;
  {$ELSE}
  Timeout: LongInt;
  {$ENDIF}
  Passphrase: string;
  WidePassphrase: UnicodeString;
  TLSServerContext: TTransportSecurityServerContext;
begin
  {$IFDEF MSWINDOWS}
  StartRegistrySockets;
  try
  {$ENDIF}
  TLSServerContext := nil;
  if StartsText('https://', FStore.Config.BaseURL) then
  begin
    { Both copies of the PKCS#12 password are held in uniquely owned
      variables and wiped before the listener run loop begins, on success
      and on failure. The process environment still holds the password for
      the life of the process (docs/registry-deployment.md), so this narrows
      the exposure without removing it. }
    Passphrase := '';
    WidePassphrase := '';
    try
      Passphrase := SysUtils.GetEnvironmentVariable(
        FStore.Config.TLSPasswordEnvironment);
      UniqueString(Passphrase);
      {$IFDEF DARWIN}
      if CurrentRegistryDarwinTLSTransport = rdttNetworkFramework then
      begin
        { Wipes Passphrase before its run loop begins. }
        RunNetworkFrameworkRegistryServer(FStore,
          FStore.Config.TLSPKCS12Path, Passphrase, @FStopping, FHandler);
        Exit;
      end;
      {$ENDIF}
      WidePassphrase := UnicodeString(Passphrase);
      UniqueString(WidePassphrase);
      TLSServerContext := TTransportSecurityServerContext.Create(
        FStore.Config.TLSPKCS12Path, WidePassphrase);
    finally
      WipeSecretString(WidePassphrase);
      WipeSecretString(Passphrase);
    end;
  end;
  ListenHost := FStore.Config.ListenAddress;
  if SameText(ListenHost, 'localhost') then ListenHost := '127.0.0.1';
  ListenSocket := RegistrySocket;
  if RegistrySocketInvalid(ListenSocket) then
  begin
    TLSServerContext.Free;
    raise ELWPTRegistryError.CreateStable('listen_failed',
      'could not create the registry socket');
  end;
  try
    Reuse := 1;
    if not RegistryPrepareSocketNoSigPipe(ListenSocket) then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not disable broken-pipe signals on the registry socket');
    {$IFDEF MSWINDOWS}
    if RegistrySetSocketOption(ListenSocket, SOL_SOCKET,
      SO_EXCLUSIVEADDRUSE, @Reuse, SizeOf(Reuse)) <> 0 then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not reserve the registry listen address exclusively');
    {$ELSE}
    RegistrySetSocketOption(ListenSocket, SOL_SOCKET, SO_REUSEADDR, @Reuse,
      SizeOf(Reuse));
    {$ENDIF}
    FillChar(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := htons(FStore.Config.Port);
    Address.sin_addr.s_addr := RegistryIPv4Address(ListenHost);
    if Address.sin_addr.s_addr = LongWord(-1) then
      raise ELWPTRegistryError.CreateStable('invalid_listen_address',
        'listen address must be localhost or an IPv4 address');
    if RegistrySocketBind(ListenSocket, Address) <> 0 then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not bind ' + FStore.Config.ListenAddress + ':'
        + IntToStr(FStore.Config.Port));
    if RegistrySocketListen(ListenSocket) <> 0 then
      raise ELWPTRegistryError.CreateStable('listen_failed',
        'could not listen on the configured registry socket');
    WriteLn('registry ', FStore.Config.Identity, ' listening at ',
      FStore.Config.BaseURL);
    { Announce the bound listener promptly, even when stdout is a pipe, so a
      supervisor can tell that this process owns the configured port. }
    Flush(Output);
    while not FStopping do
    begin
      ReapClients;
      RegistrySocketReadSet(ListenSocket, ReadSet);
      SelectTimeout.tv_sec := 0;
      SelectTimeout.tv_usec := 100000;
      SelectResult := RegistrySocketSelect(ListenSocket, ReadSet,
        SelectTimeout);
      if SelectResult < 0 then
      begin
        if FStopping then Break;
        Continue;
      end;
      if SelectResult = 0 then Continue;
      AddressLength := SizeOf(Address);
      ClientSocket := RegistrySocketAccept(ListenSocket, Address,
        AddressLength);
      if RegistrySocketInvalid(ClientSocket) then
      begin
        if FStopping then Break;
        Continue;
      end;
      Clients := FClients.LockList;
      try
        if Clients.Count >= MAX_ACTIVE_CLIENTS then
        begin
          RegistrySocketShutdown(ClientSocket);
          RegistrySocketClose(ClientSocket);
          Continue;
        end;
      finally
        FClients.UnlockList;
      end;
      {$IFDEF UNIX}
      Timeout.tv_sec := CLIENT_READ_TIMEOUT_MILLISECONDS div 1000;
      Timeout.tv_usec := (CLIENT_READ_TIMEOUT_MILLISECONDS mod 1000) * 1000;
      {$ELSE}
      Timeout := CLIENT_READ_TIMEOUT_MILLISECONDS;
      {$ENDIF}
      RegistrySetSocketOption(ClientSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout,
        SizeOf(Timeout));
      RegistrySetSocketOption(ClientSocket, SOL_SOCKET, SO_SNDTIMEO, @Timeout,
        SizeOf(Timeout));
      Client := TLWPTRegistryClientThread.Create(ClientSocket, FStore,
        TLSServerContext, FHandler, RegistryPeerAddress(Address));
      Clients := FClients.LockList;
      try
        Clients.Add(Client);
      finally
        FClients.UnlockList;
      end;
      Client.Start;
    end;
  finally
    FStopping := True;
    RegistrySocketClose(ListenSocket);
    DrainClients;
    TLSServerContext.Free;
  end;
  {$IFDEF MSWINDOWS}
  finally
    StopRegistrySockets;
  end;
  {$ENDIF}
end;

end.
