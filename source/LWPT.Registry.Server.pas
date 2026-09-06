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
  end;

  TLWPTRegistryServer = class
  private
    FStore: TLWPTRegistryStore;
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
function RegistryResourceFailureResponse(const ADiagnostic: string):
  TLWPTRegistryHTTPResponse;
function RegistryHTTPWireResponse(const AResponse: TLWPTRegistryHTTPResponse;
  const AIncludeBody: Boolean): TBytes;
function OpenRegistryHTTPResource(const AResponse: TLWPTRegistryHTTPResponse;
  AProgress: TSHA256Progress = nil): TStream;
{$IFDEF REGISTRY_TESTING}
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
  LWPT.Registry.Filesystem,
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
  {$IFDEF REGISTRY_TESTING}
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
    FTLSServerContext: TTransportSecurityServerContext;
    FTLSCiphertextReceived: QWord;
    FDeadline: QWord;
    FDone: Boolean;
    procedure CheckDeadline;
    procedure ExecutePlain;
    procedure ExecuteTLS;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: TSocket; AStore: TLWPTRegistryStore;
      ATLSServerContext: TTransportSecurityServerContext);
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

function RegistryErrorResponse(const AStatus: Integer; const AReason,
  ACode, AMessage: string; const ARequestID: string):
  TLWPTRegistryHTTPResponse;
var
  RequestID: string;
begin
  RequestID := ARequestID;
  if RequestID = '' then RequestID := NewRegistryRequestID;
  Result.Status := AStatus;
  Result.Reason := AReason;
  Result.ContentType := 'application/vnd.' + PROGRAM_NAME
    + '.registry-error+toml';
  Result.CacheControl := 'no-store';
  Result.ETag := '';
  Result.ResourcePath := '';
  Result.ResourceLength := 0;
  Result.ResourceDigest := '';
  Result.Body := Bytes('schema = '
    + RegistryTOMLQuote(PROGRAM_NAME + '-registry-error-v1') + #10
    + 'code = ' + RegistryTOMLQuote(ACode) + #10
    + 'message = ' + RegistryTOMLQuote(AMessage) + #10
    + 'request_id = ' + RegistryTOMLQuote(RequestID) + #10
    + 'retryable = false' + #10);
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
    PageLimit := 100;
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
    if (PageLimit < 1) or (PageLimit > 100) then
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
      Prefix := AStore.Config.BaseURL + '/v1/rotations/' + Entry;
      Body := Body + '{ effective_sequence = ' + Entry
        + ', rotation = ' + RegistryTOMLQuote(Prefix + '.toml')
        + ', old_signature = ' + RegistryTOMLQuote(Prefix + '.old.sig.toml')
        + ', new_signature = ' + RegistryTOMLQuote(Prefix + '.new.sig.toml') + ' }';
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
    Result.CacheControl := 'no-cache';
    Result.Body := Bytes(Body);
  finally
    Seen.Free;
    Parameters.Free;
  end;
end;

function RegistryHTTPResponse(AStore: TLWPTRegistryStore;
  const AMethod, ATarget: string; AProgress: TSHA256Progress):
  TLWPTRegistryHTTPResponse;
var
  APIPath, Digest, KeyID, Prefix, Relative, RequestID, RoleName, Target, Query: string;
  State: TLWPTRegistryState;
  View: TLWPTRegistryReadView;
begin
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
  if Pos('?', Target) > 0 then
  begin
    Query := Copy(Target, Pos('?', Target) + 1, MaxInt);
    Target := Copy(Target, 1, Pos('?', Target) - 1);
    if Target <> Prefix + '/v1/rotations' then
      Exit(ErrorResponse(400, 'Bad Request', 'invalid_request_target', 'query is only supported for rotation pages'));
  end;
  if Prefix = '' then Prefix := '';
  if not StartsStr(Prefix + '/', Target) then
    Exit(ErrorResponse(404, 'Not Found', 'not_found',
      'request target is outside the configured registry base path'));
  APIPath := Copy(Target, Length(Prefix) + 1, MaxInt);
  if (Pos('..', APIPath) > 0) or (Pos('%', APIPath) > 0) then
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
    Result.Body := Bytes('schema = "' + PROGRAM_NAME
      + '-registry-capabilities-v1"' + #10 + 'protocol = 1' + #10
      + 'hashes = ["sha256"]' + #10 + 'signatures = ["ed25519"]' + #10
      + 'schemas = ["' + PROGRAM_NAME + '-registry-capabilities-v1", "'
      + PROGRAM_NAME + '-registry-checkpoint-v1", "' + PROGRAM_NAME
      + '-registry-discovery-v1", "' + PROGRAM_NAME
      + '-registry-error-v1", "' + PROGRAM_NAME
      + '-registry-key-rotation-v1", "' + PROGRAM_NAME
      + '-registry-key-v1", "' + PROGRAM_NAME
      + '-registry-package-v1", "' + PROGRAM_NAME
      + '-registry-rotation-page-v1", "' + PROGRAM_NAME
      + '-registry-signature-v1", "' + PROGRAM_NAME
      + '-registry-snapshot-v1"]' + #10
      + 'features = ["rotation-chain-v1", "snapshot-sync-v1"]' + #10
      + 'auth_schemes = []' + #10
      + 'max_page_size = 100' + #10);
    Exit;
  end;
  View := AStore.CaptureReadView(AProgress);
  try
    State := View.State;
    if APIPath = '/v1/rotations' then Exit(RotationPageResponse(AStore, View, Query, AProgress));
    if StartsStr('/v1/rotations/', APIPath) then
    begin
      Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
      if not View.ResourceIsPublished(Relative, AProgress) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
      if EndsStr('.sig.toml', Relative) then Digest := 'signature'
      else Digest := 'key-rotation';
      Exit(ResourceResponse(AStore, Relative, 'application/vnd.' + PROGRAM_NAME
        + '.registry-' + Digest + '+toml', '', '', True, AProgress));
    end;
    if APIPath = '/v1/checkpoints/latest.toml' then
      Exit(ResourceResponse(AStore, State.CheckpointPath,
        'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', '',
        '', False, AProgress));
    if APIPath = '/v1/checkpoints/latest.sig.toml' then
      Exit(ResourceResponse(AStore, State.SignaturePath,
        'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', '',
        '', False, AProgress));
    if StartsStr('/v1/objects/sha256/', APIPath) then
    begin
      Digest := Copy(APIPath, Length('/v1/objects/sha256/') + 1, MaxInt);
      if not IsLowerHex64(Digest) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found'));
      Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
      Exit(ResourceResponse(AStore, Relative, 'application/gzip',
        '"sha256:' + Digest + '"', 'sha256:' + Digest, True, AProgress));
    end;
    if StartsStr('/v1/records/sha256/', APIPath) then
    begin
      Digest := Copy(APIPath, Length('/v1/records/sha256/') + 1,
        Length(APIPath) - Length('/v1/records/sha256/') - Length('.toml'));
      if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found'));
      Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
      Exit(ResourceResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-package+toml',
        '"sha256:' + Digest + '"', 'sha256:' + Digest, True, AProgress));
    end;
    if StartsStr('/v1/snapshots/sha256/', APIPath) then
    begin
      Digest := Copy(APIPath, Length('/v1/snapshots/sha256/') + 1,
        Length(APIPath) - Length('/v1/snapshots/sha256/') - Length('.toml'));
      if not EndsStr('.toml', APIPath) or not IsLowerHex64(Digest) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found'));
      Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
      if not View.ResourceIsPublished(Relative, AProgress) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
      Exit(ResourceResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-snapshot+toml',
        '"sha256:' + Digest + '"', 'sha256:' + Digest, True, AProgress));
    end;
    if StartsStr('/v1/keys/ed25519:', APIPath) then
    begin
      KeyID := Copy(APIPath, Length('/v1/keys/') + 1,
        Length(APIPath) - Length('/v1/keys/') - Length('.toml'));
      if not EndsStr('.toml', APIPath) or not StartsStr('ed25519:', KeyID)
        or not IsLowerHex64(Copy(KeyID, Length('ed25519:') + 1,
          MaxInt)) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found',
          'registry resource was not found'));
      Relative := RegistryKeyStoragePath(KeyID);
      if not View.ResourceIsPublished(Relative, AProgress) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
      Exit(ResourceResponse(AStore, Relative,
        'application/vnd.' + PROGRAM_NAME + '.registry-key+toml', '', '',
        True, AProgress));
    end;
    if StartsStr('/v1/checkpoints/', APIPath) then
    begin
      Relative := Copy(APIPath, Length('/v1/') + 1, MaxInt);
      if not View.ResourceIsPublished(Relative, AProgress) then
        Exit(ErrorResponse(404, 'Not Found', 'not_found', 'registry resource was not found'));
      if EndsStr('.sig.toml', APIPath) then
        Exit(ResourceResponse(AStore, Relative,
          'application/vnd.' + PROGRAM_NAME + '.registry-signature+toml', '',
          '', False, AProgress));
      if EndsStr('.toml', APIPath) then
        Exit(ResourceResponse(AStore, Relative,
          'application/vnd.' + PROGRAM_NAME + '.registry-checkpoint+toml', '',
          '', False, AProgress));
    end;
    Result := ErrorResponse(404, 'Not Found', 'not_found',
      'registry resource was not found');
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
    + AResponse.Reason + #13#10 + 'Content-Type: ' + AResponse.ContentType
    + #13#10 + 'Content-Length: ' + IntToStr(ContentLength) + #13#10
    + 'Cache-Control: ' + AResponse.CacheControl + #13#10;
  if AResponse.ETag <> '' then Header := Header + 'ETag: ' + AResponse.ETag
    + #13#10;
  Header := Header + 'Connection: close' + #13#10 + #13#10;
  HeaderBytes := Bytes(Header);
  if not AIncludeBody or (AResponse.ResourcePath <> '') then Exit(HeaderBytes);
  SetLength(Result, Length(HeaderBytes) + Length(AResponse.Body));
  if Length(HeaderBytes) > 0 then Move(HeaderBytes[0], Result[0],
    Length(HeaderBytes));
  if Length(AResponse.Body) > 0 then Move(AResponse.Body[0],
    Result[Length(HeaderBytes)], Length(AResponse.Body));
end;

constructor TLWPTRegistryClientThread.Create(const ASocket: TSocket;
  AStore: TLWPTRegistryStore;
  ATLSServerContext: TTransportSecurityServerContext);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSocket := ASocket;
  FStore := AStore;
  FTLSServerContext := ATLSServerContext;
  FTLSCiphertextReceived := 0;
  FDeadline := GetTickCount64 + CLIENT_READ_TIMEOUT_MILLISECONDS;
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

procedure TLWPTRegistryClientThread.ExecutePlain;
var
  Buffer: array[0..4095] of Byte;
  HeaderEnd, Received, Space: Integer;
  IncludeBody: Boolean;
  Method, Request, RequestLine, Target: string;
  ResourceStream: TStream;
  Response: TLWPTRegistryHTTPResponse;
  Wire: TBytes;
begin
  ResourceStream := nil;
  try
    try
      Request := '';
      repeat
        CheckDeadline;
        ApplyDeadlineTimeout(FSocket, FDeadline);
        Received := RegistrySocketReceive(FSocket, @Buffer[0], Length(Buffer));
        if Received <= 0 then Exit;
        if Length(Request) + Received > MAX_REQUEST_HEADER_BYTES then
        begin
          Response := ErrorResponse(431, 'Request Header Fields Too Large',
            'request_headers_too_large', 'request headers exceed 32 KiB');
          SendAll(FSocket, RegistryHTTPWireResponse(Response, True), FDeadline);
          Exit;
        end;
        SetString(RequestLine, PAnsiChar(@Buffer[0]), Received);
        Request := Request + RequestLine;
        HeaderEnd := Pos(#13#10#13#10, Request);
      until HeaderEnd > 0;
      RequestLine := Copy(Request, 1, Pos(#13#10, Request) - 1);
      Space := Pos(' ', RequestLine);
      if Space = 0 then
        Response := ErrorResponse(400, 'Bad Request', 'invalid_request',
          'request line is invalid')
      else
      begin
        Method := Copy(RequestLine, 1, Space - 1);
        Delete(RequestLine, 1, Space);
        Space := Pos(' ', RequestLine);
        if Space = 0 then
          Response := ErrorResponse(400, 'Bad Request', 'invalid_request',
            'request line is invalid')
        else
        begin
          Target := Copy(RequestLine, 1, Space - 1);
          Response := RegistryHTTPResponse(FStore, Method, Target,
            CheckDeadline);
        end;
      end;
      IncludeBody := not SameText(Method, 'HEAD');
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
  if AReceivedTotal > TLS_CIPHERTEXT_BUDGET_BYTES then
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
  Buffer: array[0..4095] of Byte;
  Connection: TTransportSecurityConnection;
  HeaderEnd, Space: Integer;
  IncludeBody: Boolean;
  Method, Request, RequestChunk, RequestLine, Target: string;
  ResourceStream: TStream;
  Response: TLWPTRegistryHTTPResponse;
  ResultState: TTransportSecurityState;
  IOResult: TTransportSecurityIOResult;
  Wire: TBytes;
begin
  ResourceStream := nil;
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
    repeat
      CheckDeadline;
      IOResult := TransportSecurityServerRead(Connection, Buffer,
        Length(Buffer));
      if IOResult.BytesProcessed > 0 then
      begin
        SetString(RequestChunk, PAnsiChar(@Buffer[0]),
          IOResult.BytesProcessed);
        Request := Request + RequestChunk;
        if Length(Request) > MAX_REQUEST_HEADER_BYTES then
          raise ELWPTRegistryError.CreateStable('request_headers_too_large',
            'request headers exceed 32 KiB');
      end;
      HeaderEnd := Pos(#13#10#13#10, Request);
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
    RequestLine := Copy(Request, 1, Pos(#13#10, Request) - 1);
    Space := Pos(' ', RequestLine);
    if Space = 0 then Exit;
    Method := Copy(RequestLine, 1, Space - 1);
    Delete(RequestLine, 1, Space);
    Space := Pos(' ', RequestLine);
    if Space = 0 then Exit;
    Target := Copy(RequestLine, 1, Space - 1);
    Response := RegistryHTTPResponse(FStore, Method, Target, CheckDeadline);
    IncludeBody := not SameText(Method, 'HEAD');
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
  RegistrySocketShutdown(FSocket);
  RegistrySocketClose(FSocket);
  FDone := True;
end;

constructor TLWPTRegistryServer.Create(AStore: TLWPTRegistryStore);
begin
  inherited Create;
  FStore := AStore;
  FClients := TThreadList.Create;
  FStopping := False;
end;

destructor TLWPTRegistryServer.Destroy;
begin
  RequestStop;
  DrainClients;
  FClients.Free;
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
  {$IFDEF DARWIN}
  Passphrase: string;
  {$ENDIF}
  TLSServerContext: TTransportSecurityServerContext;
begin
  {$IFDEF MSWINDOWS}
  StartRegistrySockets;
  try
  {$ENDIF}
  TLSServerContext := nil;
  if StartsText('https://', FStore.Config.BaseURL) then
  begin
    {$IFDEF DARWIN}
    Passphrase := SysUtils.GetEnvironmentVariable(
      FStore.Config.TLSPasswordEnvironment);
    if CurrentRegistryDarwinTLSTransport = rdttNetworkFramework then
    begin
      RunNetworkFrameworkRegistryServer(FStore,
        FStore.Config.TLSPKCS12Path, Passphrase, @FStopping);
      Exit;
    end;
    try
      TLSServerContext := TTransportSecurityServerContext.Create(
        FStore.Config.TLSPKCS12Path, UnicodeString(Passphrase));
    finally
      if Length(Passphrase) > 0 then
        FillChar(Passphrase[1], Length(Passphrase) * SizeOf(Char), 0);
      Passphrase := '';
    end;
    {$ELSE}
    TLSServerContext := TTransportSecurityServerContext.Create(
      FStore.Config.TLSPKCS12Path,
      UnicodeString(SysUtils.GetEnvironmentVariable(
        FStore.Config.TLSPasswordEnvironment)));
    {$ENDIF}
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
        TLSServerContext);
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
