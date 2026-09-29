unit HTTPClient;

// Minimal HTTP/1.1 client built on raw BSD sockets.
// Supports GET, HEAD, and POST over HTTP and HTTPS.
// Cross-platform: Unix (macOS, Linux) and Windows.
// Synchronous API with deadline-aware nonblocking socket I/O.

{$I Shared.inc}

{$IF DEFINED(DARWIN) OR (DEFINED(LINUX) AND NOT DEFINED(ANDROID))}
{$DEFINE HTTPCLIENT_NATIVE_RESOLVER}
{$ENDIF}

interface

uses
  SysUtils,

  TransportSecurity;

type
  THTTPHeader = record
    Name: string;
    Value: string;
  end;

  THTTPHeaders = array of THTTPHeader;

  THTTPResponse = record
    StatusCode: Integer;
    StatusText: string;
    Headers: THTTPHeaders;
    Body: TBytes;
    FinalURL: string;
    Redirected: Boolean;
  end;

  { How a request treats destinations whose address is not globally
    reachable according to the IANA IPv4 and IPv6 special-purpose address
    registries (loopback, private-use, link-local, shared, documentation,
    benchmarking, multicast, reserved, and similar ranges). }
  THTTPPrivateAddressPolicy = (
    { No address classification; the host name is dialled as given. }
    papAllow,
    { Every hop, including the first, must resolve to a globally reachable
      address. }
    papDeny
  );

  { Per-request destination policy, applied to the initial request and to
    every redirect hop, in this order: the scheme check, then the host
    allowlist (before any name resolution, so a refused host causes no DNS
    lookup and no connection), then the address policy. When an address
    policy is active the host is resolved once into a binary address, that
    address is classified, and the connection dials exactly that address;
    TLS still verifies the peer against the host name. Such a request dials
    IPv4 only: an IPv6 destination is refused unless it is an IPv4-mapped,
    IPv4-compatible, or NAT64 well-known-prefix (64:ff9b::/96) spelling,
    which is treated as its embedded IPv4 address. }
  THTTPDestinationPolicy = record
    { Case-insensitive exact host names; empty allows any host. }
    AllowedHosts: TStringArray;
    PrivateAddressPolicy: THTTPPrivateAddressPolicy;
    { Refuse any hop, including a redirect target, whose scheme is not
      https, so a redirect can never downgrade to plaintext. }
    RequireHTTPS: Boolean;
  end;

  THTTPRequestOptions = record
    MaxResponseBodyBytes: Int64;
    MaxResponseHeaderBytes: Integer;
    RequestTimeoutMilliseconds: QWord;
    MaximumRedirects: Integer;
    Destination: THTTPDestinationPolicy;
    { Optional canonical literal IPv4 address dialled for the first hop
      without name resolution. The URL still supplies the Host header and
      the TLS server name; redirects dial their own hosts. Cannot be combined
      with an address policy. Empty dials the URL host as usual. }
    ConnectAddress: string;
    { Outbound TLS client options (trust anchors, client identity, insecure
      mode) for https hops to the request's own origin: the same scheme,
      host, and port as the initial URL. A redirect to any other origin
      connects with the default options (system trust, full verification,
      no client certificate), so a client certificate, private trust
      anchors, or an insecure exemption never follow a redirect off the
      configured origin. The zero value is today's behaviour. Invalid
      options fail before any connection is attempted. }
    TLS: TTransportSecurityClientOptions;
  end;

  EHTTPError = class(Exception);
  { The response body is larger than MaxResponseBodyBytes. Raised as soon as
    the limit is known to be exceeded (a declared Content-Length, a chunk
    size, or the received bytes), before the excess is read. }
  EHTTPResponseTooLarge = class(EHTTPError);

  {$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
  { Test-only select seam. Production code must leave this nil. The hook can
    simulate the two syscall outcomes that otherwise depend on signal and
    network timing while leaving ordinary readiness to the real select call. }
  THTTPClientSelectTestAction = (selectUseSystem, selectInterrupted,
    selectFailed);
  THTTPClientSelectTestHook = function(const ASocket: PtrInt;
    const ARead, AWrite: Boolean;
    const AAttempt: Integer): THTTPClientSelectTestAction;
  {$ENDIF}

  {$IFDEF HTTPCLIENT_TESTING}
  { Test-only resolver seam. Production code must leave this nil. Returning
    True supplies the IPv4 literal to dial for AHost and whether the
    destination policy must treat it as private, so a loopback mock server can
    stand in for a public host. Returning False keeps real resolution and
    classification. Consulted only while an address policy is active. }
  THTTPClientResolveTestHook = function(const AHost: string;
    out AAddress: string; out APrivate: Boolean): Boolean;
  { Test-only scheme seam. Production code must leave this nil. Returning
    True lets a plaintext hop to AHost stand in for an authenticated https
    hop under RequireHTTPS, so a loopback mock can play an HTTPS origin whose
    redirect is then checked like every other hop. }
  THTTPClientHTTPSStandInTestHook = function(const AHost: string): Boolean;
  {$ENDIF}

const
  DEFAULT_MAX_RESPONSE_BODY_BYTES = Int64(64) * 1024 * 1024;
  DEFAULT_MAX_RESPONSE_HEADER_BYTES = 64 * 1024;
  DEFAULT_REQUEST_TIMEOUT_MILLISECONDS = 120 * 1000;
  DEFAULT_MAXIMUM_REDIRECTS = 20;

{$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
var
  HTTPClientSelectTestHook: THTTPClientSelectTestHook;
{$ENDIF}
{$IFDEF HTTPCLIENT_TESTING}
var
  HTTPClientResolveTestHook: THTTPClientResolveTestHook;
  HTTPClientHTTPSStandInTestHook: THTTPClientHTTPSStandInTestHook;
{$ENDIF}

function DefaultHTTPRequestOptions: THTTPRequestOptions;
{ Lowercased host of an absolute http or https URL, parsed exactly as a
  request would parse it (userinfo, port and IPv6 brackets removed). Raises
  EHTTPError for a URL a request would reject. }
function HTTPURLHost(const AURL: string): string;
{$IFDEF HTTPCLIENT_TESTING}
{ Test-only views of the destination classifier. '' when AAddressText is a
  strict IPv4 or IPv6 literal of a globally reachable address, otherwise the
  name of the registry block that makes it non-global ('not an address
  literal' for any other text, including shortened or numeric IPv4). }
function NonGlobalAddressReason(const AAddressText: string): string;
{ True when AHost may be contacted under APolicy's host allowlist. }
function IsHTTPHostAllowed(const APolicy: THTTPDestinationPolicy;
  const AHost: string): Boolean;
{$ENDIF}
function HTTPGet(const AURL: string;
  const AHeaders: THTTPHeaders): THTTPResponse; overload;
function HTTPGet(const AURL: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse; overload;
function HTTPHead(const AURL: string;
  const AHeaders: THTTPHeaders): THTTPResponse; overload;
function HTTPHead(const AURL: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse; overload;
function HTTPPost(const AURL: string; const ABody: TBytes;
  const AContentType: string;
  const AHeaders: THTTPHeaders): THTTPResponse; overload;
function HTTPPost(const AURL: string; const ABody: TBytes;
  const AContentType: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse; overload;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  Sockets,
  {$IFDEF DARWIN}
  CTypes,
  InitC
  {$ELSE}
  {$IFDEF HTTPCLIENT_NATIVE_RESOLVER}
  cNetDB
  {$ELSE}
  { Preserve the existing resolver on other Unix targets until their native
    bindings have platform evidence; do not infer their addrinfo ABI. }
  NetDB
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2
  {$ENDIF}
  ;

const
  CRLF            = #13#10;
  RECV_BUF_SIZE   = 8192;

{ [gpm vendoring patch] Append N raw bytes from a buffer to an AnsiString.
  The original chunked-read path used Copy(PAnsiChar(@Buf[0]), 1, N), which
  treats the buffer as a C string and truncates at the first #0 byte —
  corrupting any binary payload (e.g. gzip tarballs). Content-length and
  read-to-close paths already Move() correctly; only the chunked path was
  affected. Consider upstreaming this fix to GocciaScript HTTPClient.pas. }
procedure AppendRawBytes(var ADest: AnsiString;
  const ABuf; const N: Integer); inline;
var Old: Integer;
begin
  if N <= 0 then Exit;
  Old := Length(ADest);
  SetLength(ADest, Old + N);
  Move(ABuf, ADest[Old + 1], N);
end;

type
  THTTPParsedURL = record
    Scheme: string;
    Host: string;
    Port: Integer;
    Path: string;
  end;

{$IFDEF DARWIN}
{ Darwin netdb.h places canonname before addr, unlike Linux. socklen_t is
  unsigned 32-bit on both Darwin release architectures, not pointer-sized. }
{$push}
{$packrecords c}
type
  PAddrInfo = ^TAddrInfo;
  TAddrInfo = record
    ai_flags, ai_family, ai_socktype, ai_protocol: cint;
    ai_addrlen: cuint32;
    ai_canonname: PAnsiChar;
    ai_addr: PSockAddr;
    ai_next: PAddrInfo;
  end;
  PPAddrInfo = ^PAddrInfo;
{$pop}

function Getaddrinfo(ANodeName, AServName: PAnsiChar;
  AHints: PAddrInfo; AResult: PPAddrInfo): cint; cdecl;
  external clib name 'getaddrinfo';
procedure Freeaddrinfo(AInfo: PAddrInfo); cdecl;
  external clib name 'freeaddrinfo';
{$ENDIF}

{$IFDEF MSWINDOWS}
type
  PAddrInfo = ^TAddrInfo;
  TAddrInfo = record
    ai_flags: LongInt;
    ai_family: LongInt;
    ai_socktype: LongInt;
    ai_protocol: LongInt;
    ai_addrlen: PtrUInt;
    ai_canonname: PAnsiChar;
    ai_addr: PSockAddr;
    ai_next: PAddrInfo;
  end;

function Getaddrinfo(ANodeName, AServName: PAnsiChar;
  AHints: PAddrInfo; out ARes: PAddrInfo): LongInt; stdcall;
  external WINSOCK2_DLL name 'getaddrinfo';
procedure Freeaddrinfo(AI: PAddrInfo); stdcall;
  external WINSOCK2_DLL name 'freeaddrinfo';

var
  GWinSockInitialized: Boolean = False;

procedure EnsureWinSockInit;
var
  WSAData: TWSAData;
begin
  if GWinSockInitialized then Exit;
  if WSAStartup($0202, WSAData) <> 0 then
    raise EHTTPError.Create('WSAStartup failed');
  GWinSockInitialized := True;
end;
{$ENDIF}

// ---------------------------------------------------------------------------
// Minimal URL parsing (self-contained, no engine dependencies)
// ---------------------------------------------------------------------------

function ParseHTTPURL(const AURL: string): THTTPParsedURL;
var
  S, Rest: string;
  I: Integer;
begin
  Result.Scheme := '';
  Result.Host := '';
  Result.Port := 0;
  Result.Path := '/';

  S := AURL;

  // Scheme
  I := Pos('://', S);
  if I > 0 then
  begin
    Result.Scheme := LowerCase(Copy(S, 1, I - 1));
    Rest := Copy(S, I + 3, Length(S));
  end
  else
    raise EHTTPError.Create('Invalid URL: missing scheme');

  if (Result.Scheme <> 'http') and (Result.Scheme <> 'https') then
    raise EHTTPError.Create('Unsupported scheme: ' + Result.Scheme);

  // Split host from path
  I := Pos('/', Rest);
  if I > 0 then
  begin
    Result.Path := Copy(Rest, I, Length(Rest));
    Rest := Copy(Rest, 1, I - 1);
  end;

  // Strip userinfo if present
  I := Pos('@', Rest);
  if I > 0 then
    Rest := Copy(Rest, I + 1, Length(Rest));

  // Parse host:port
  if (Length(Rest) > 0) and (Rest[1] = '[') then
  begin
    // IPv6 — strip brackets for DNS resolution
    I := Pos(']', Rest);
    if I > 0 then
    begin
      Result.Host := Copy(Rest, 2, I - 2);
      Rest := Copy(Rest, I + 1, Length(Rest));
      if (Length(Rest) > 0) and (Rest[1] = ':') then
        Result.Port := StrToIntDef(Copy(Rest, 2, Length(Rest)), 0);
    end
    else
      Result.Host := Copy(Rest, 2, Length(Rest));
  end
  else
  begin
    I := Pos(':', Rest);
    if I > 0 then
    begin
      Result.Host := Copy(Rest, 1, I - 1);
      Result.Port := StrToIntDef(Copy(Rest, I + 1, Length(Rest)), 0);
    end
    else
      Result.Host := Rest;
  end;

  if Result.Host = '' then
    raise EHTTPError.Create('Invalid URL: empty host');

  // Default ports
  if Result.Port = 0 then
  begin
    if Result.Scheme = 'https' then
      Result.Port := 443
    else
      Result.Port := 80;
  end;

  if Result.Path = '' then
    Result.Path := '/';
end;

procedure RaiseRequestDeadline(const ATimeoutMilliseconds: QWord);
begin
  raise EHTTPError.CreateFmt(
    'HTTP request deadline exceeded after %d ms',
    [ATimeoutMilliseconds]);
end;

procedure CheckRequestDeadline(const ADeadline,
  ATimeoutMilliseconds: QWord); inline;
begin
  if GetTickCount64 >= ADeadline then
    RaiseRequestDeadline(ATimeoutMilliseconds);
end;

function RemainingRequestMilliseconds(const ADeadline,
  ATimeoutMilliseconds: QWord): Integer;
var
  NowTick, Remaining: QWord;
begin
  NowTick := GetTickCount64;
  if NowTick >= ADeadline then
    RaiseRequestDeadline(ATimeoutMilliseconds);
  Remaining := ADeadline - NowTick;
  if Remaining > QWord(High(Integer)) then
    Result := High(Integer)
  else
    Result := Integer(Remaining);
  if Result < 1 then
    Result := 1;
end;

function SocketWouldBlock: Boolean; inline;
{$IFDEF UNIX}
var
  ErrorCode: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ErrorCode: Integer;
{$ENDIF}
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

procedure SetSocketNonBlocking(const ASock: TSocket);
{$IFDEF UNIX}
var
  Flags: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Mode: u_long;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Flags := fpFcntl(ASock, F_GETFL, 0);
  if (Flags < 0) or
     (fpFcntl(ASock, F_SETFL, Flags or O_NONBLOCK) < 0) then
    raise EHTTPError.Create('Failed to configure nonblocking HTTP socket');
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Mode := 1;
  if WinSock2.ioctlsocket(ASock, LongInt(FIONBIO), Mode) <> 0 then
    raise EHTTPError.Create('Failed to configure nonblocking HTTP socket');
  {$ENDIF}
end;

procedure WaitForSocket(const ASock: TSocket; const ARead, AWrite: Boolean;
  const ADeadline, ATimeoutMilliseconds: QWord);
{$IFDEF UNIX}
var
  ReadSet, WriteSet: TFDSet;
  ReadSetPointer, WriteSetPointer: PFDSet;
  Attempt: Integer;
  Interrupted: Boolean;
  Ready: Integer;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ExceptSet, ReadSet, WriteSet: TFDSet;
  ExceptSetPointer, ReadSetPointer, WriteSetPointer: PFDSet;
  Timeout: TTimeVal;
  Ready: Integer;
  Remaining: Integer;
{$ENDIF}
begin
  {$IFDEF UNIX}
  { A signal delivered while select() blocks fails it with EINTR — a healthy
    socket, not a fault. Recompute the remaining time to the deadline (which
    raises once it lapses) and wait again; only a different error is fatal.
    The fd sets are rebuilt each pass because select() leaves their contents
    unspecified after an EINTR return. }
  Attempt := 0;
  repeat
    Inc(Attempt);
    fpFD_ZERO(ReadSet);
    fpFD_ZERO(WriteSet);
    ReadSetPointer := nil;
    WriteSetPointer := nil;
    if ARead then
    begin
      fpFD_SET(ASock, ReadSet);
      ReadSetPointer := @ReadSet;
    end;
    if AWrite then
    begin
      fpFD_SET(ASock, WriteSet);
      WriteSetPointer := @WriteSet;
    end;
    {$IFDEF HTTPCLIENT_TESTING}
    if Assigned(HTTPClientSelectTestHook) then
      case HTTPClientSelectTestHook(PtrInt(ASock), ARead, AWrite, Attempt) of
        selectUseSystem:
          begin
            Ready := fpSelect(ASock + 1, ReadSetPointer, WriteSetPointer, nil,
              RemainingRequestMilliseconds(ADeadline,
                ATimeoutMilliseconds));
            Interrupted := (Ready < 0) and (fpgeterrno = ESysEINTR);
          end;
        selectInterrupted:
          begin
            Ready := -1;
            Interrupted := True;
          end;
        selectFailed:
          begin
            Ready := -1;
            Interrupted := False;
          end;
      end
    else
    {$ENDIF}
    begin
      Ready := fpSelect(ASock + 1, ReadSetPointer, WriteSetPointer, nil,
        RemainingRequestMilliseconds(ADeadline, ATimeoutMilliseconds));
      Interrupted := (Ready < 0) and (fpgeterrno = ESysEINTR);
    end;
    if Ready >= 0 then
      Break;
    if not Interrupted then
      raise EHTTPError.Create('HTTP socket readiness wait failed');
  until False;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FillChar(ReadSet, SizeOf(ReadSet), 0);
  FillChar(WriteSet, SizeOf(WriteSet), 0);
  FillChar(ExceptSet, SizeOf(ExceptSet), 0);
  ReadSetPointer := nil;
  WriteSetPointer := nil;
  ExceptSetPointer := nil;
  if ARead then
  begin
    ReadSet.fd_count := 1;
    ReadSet.fd_array[0] := ASock;
    ReadSetPointer := @ReadSet;
  end;
  if AWrite then
  begin
    WriteSet.fd_count := 1;
    WriteSet.fd_array[0] := ASock;
    WriteSetPointer := @WriteSet;
  end;
  if ARead or AWrite then
  begin
    { Winsock may report a failed nonblocking connect only through the
      exception set. Writability alone can therefore wait until the request
      deadline even though SO_ERROR is already available. Callers still read
      SO_ERROR or perform their send/receive operation after readiness. }
    ExceptSet.fd_count := 1;
    ExceptSet.fd_array[0] := ASock;
    ExceptSetPointer := @ExceptSet;
  end;
  Remaining := RemainingRequestMilliseconds(ADeadline,
    ATimeoutMilliseconds);
  Timeout.tv_sec := Remaining div 1000;
  Timeout.tv_usec := (Remaining mod 1000) * 1000;
  Ready := WinSock2.select(0, ReadSetPointer, WriteSetPointer,
    ExceptSetPointer, @Timeout);
  {$ENDIF}
  if Ready = 0 then
    RaiseRequestDeadline(ATimeoutMilliseconds);
  if Ready < 0 then
    raise EHTTPError.Create('HTTP socket readiness wait failed');
  CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
end;

// ---------------------------------------------------------------------------
// Socket connect (cross-platform)
// ---------------------------------------------------------------------------

type
  { An IPv4 address in network byte order, first octet first. }
  THTTPIPv4Octets = array[0..3] of Byte;

{$IFDEF UNIX}
function ResolveSocketAddress(const AHost: string): in_addr;
var
  {$IFDEF HTTPCLIENT_NATIVE_RESOLVER}
  Hints: TAddrInfo;
  Addresses, Current: PAddrInfo;
  {$ELSE}
  HostEntry: THostEntry;
  {$ENDIF}
begin
  Result := StrToNetAddr(AHost);
  if Result.s_addr <> 0 then Exit;
  {$IFDEF HTTPCLIENT_NATIVE_RESOLVER}
  FillChar(Hints, SizeOf(Hints), 0);
  Hints.ai_family := AF_INET;
  Hints.ai_socktype := SOCK_STREAM;
  Hints.ai_protocol := IPPROTO_TCP;
  Addresses := nil;
  { Native resolution honors system host databases and keeps its result list
    request-local. It remains synchronous; ConnectSocket checks the shared
    request deadline immediately after this lookup returns. }
  if Getaddrinfo(PAnsiChar(AHost), nil, @Hints, @Addresses) <> 0 then
    raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
  try
    Current := Addresses;
    while Current <> nil do
    begin
      if (Current^.ai_family = AF_INET) and (Current^.ai_addr <> nil)
        and (Current^.ai_addrlen >= SizeOf(TInetSockAddr)) then
        Exit(PInetSockAddr(Current^.ai_addr)^.sin_addr);
      Current := Current^.ai_next;
    end;
    raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
  finally
    if Addresses <> nil then Freeaddrinfo(Addresses);
  end;
  {$ELSE}
  if not ResolveHostByName(AHost, HostEntry) then
    raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
  Result := HostEntry.Addr;
  {$ENDIF}
end;

{ Connects to exactly AAddress; no name resolution happens here. AHost only
  names the destination in error messages. }
function ConnectIPv4Socket(const AAddress: THTTPIPv4Octets;
  const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  SockAddr: TInetSockAddr;
  ConnectResult: Integer;
  SocketError: Integer;
  SocketErrorLength: TSockLen;
begin
  CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);

  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Result < 0 then
    raise EHTTPError.Create('Failed to create socket');
  try
    SetSocketNonBlocking(Result);
  except
    CloseSocket(Result);
    raise;
  end;

  FillChar(SockAddr, SizeOf(SockAddr), 0);
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := htons(APort);
  Move(AAddress[0], SockAddr.sin_addr, SizeOf(AAddress));

  ConnectResult := fpConnect(Result, @SockAddr, SizeOf(SockAddr));
  if (ConnectResult <> 0) and not SocketWouldBlock then
  begin
    CloseSocket(Result);
    raise EHTTPError.CreateFmt('Failed to connect to %s:%d', [AHost, APort]);
  end;
  if ConnectResult <> 0 then
  begin
    { WaitForSocket can raise (deadline lapsed or select failure); the just
      created socket must be closed on any exit through this block or its fd
      leaks. Mirrors the Windows connect path's try/except. The getsockopt
      failure path raises inside the try so the single except closes the fd
      exactly once. }
    try
      WaitForSocket(Result, False, True, ADeadline, ATimeoutMilliseconds);
      SocketError := 0;
      SocketErrorLength := SizeOf(SocketError);
      if (fpGetSockOpt(Result, SOL_SOCKET, SO_ERROR, @SocketError,
         @SocketErrorLength) <> 0) or (SocketError <> 0) then
        raise EHTTPError.CreateFmt('Failed to connect to %s:%d',
          [AHost, APort]);
    except
      CloseSocket(Result);
      raise;
    end;
  end;
end;

function ConnectSocket(const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  Addr: in_addr;
  Octets: THTTPIPv4Octets;
begin
  Addr := ResolveSocketAddress(AHost);
  CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
  Move(Addr, Octets[0], SizeOf(Octets));
  Result := ConnectIPv4Socket(Octets, AHost, APort, ADeadline,
    ATimeoutMilliseconds);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{ One nonblocking connect attempt to exactly AAddress. Returns False with
  ASocket = INVALID_SOCKET when the attempt fails; raises only for deadline
  or readiness-wait failures, after closing the socket. }
function TryConnectSockAddr(const AFamily, ASocketType, AProtocol: LongInt;
  const AAddress: PSockAddr; const AAddressLength: LongInt;
  const ADeadline, ATimeoutMilliseconds: QWord;
  out ASocket: TSocket): Boolean;
var
  ConnectResult: Integer;
  SocketError: Integer;
  SocketErrorLength: Integer;
begin
  Result := False;
  ASocket := WinSock2.socket(AFamily, ASocketType, AProtocol);
  if ASocket = INVALID_SOCKET then
    Exit;
  try
    SetSocketNonBlocking(ASocket);
  except
    WinSock2.closesocket(ASocket);
    ASocket := INVALID_SOCKET;
    raise;
  end;
  ConnectResult := WinSock2.connect(ASocket, AAddress, AAddressLength);
  if ConnectResult = 0 then
    Exit(True);
  if SocketWouldBlock then
  begin
    try
      WaitForSocket(ASocket, False, True, ADeadline, ATimeoutMilliseconds);
      SocketError := 0;
      SocketErrorLength := SizeOf(SocketError);
      if (WinSock2.getsockopt(ASocket, SOL_SOCKET, SO_ERROR,
         PChar(@SocketError), SocketErrorLength) = 0) and
         (SocketError = 0) then
        Exit(True);
    except
      WinSock2.closesocket(ASocket);
      ASocket := INVALID_SOCKET;
      raise;
    end;
  end;
  WinSock2.closesocket(ASocket);
  ASocket := INVALID_SOCKET;
end;

{ Connects to exactly AAddress; no name resolution happens here. AHost only
  names the destination in error messages. }
function ConnectIPv4Socket(const AAddress: THTTPIPv4Octets;
  const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  SockAddr: TSockAddrIn;
begin
  EnsureWinSockInit;
  CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
  FillChar(SockAddr, SizeOf(SockAddr), 0);
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := htons(APort);
  Move(AAddress[0], SockAddr.sin_addr, SizeOf(AAddress));
  if not TryConnectSockAddr(AF_INET, SOCK_STREAM, IPPROTO_TCP,
     PSockAddr(@SockAddr), SizeOf(SockAddr), ADeadline,
     ATimeoutMilliseconds, Result) then
    raise EHTTPError.CreateFmt('Failed to connect to %s:%d', [AHost, APort]);
end;

function ConnectSocket(const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  Hints, Res, Cur: PAddrInfo;
  PortStr: AnsiString;
  Sock: TSocket;
begin
  EnsureWinSockInit;

  FillChar(Hints, SizeOf(Hints), 0);
  New(Hints);
  try
    FillChar(Hints^, SizeOf(TAddrInfo), 0);
    Hints^.ai_family := AF_INET;
    Hints^.ai_socktype := SOCK_STREAM;
    Hints^.ai_protocol := IPPROTO_TCP;
    PortStr := AnsiString(IntToStr(APort));
    Res := nil;

    if Getaddrinfo(PAnsiChar(AnsiString(AHost)), PAnsiChar(PortStr),
                   Hints, Res) <> 0 then
      raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
  finally
    Dispose(Hints);
  end;
  CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);

  try
    Cur := Res;
    Sock := INVALID_SOCKET;
    while Assigned(Cur) do
    begin
      if TryConnectSockAddr(Cur^.ai_family, Cur^.ai_socktype,
         Cur^.ai_protocol, Cur^.ai_addr, LongInt(Cur^.ai_addrlen),
         ADeadline, ATimeoutMilliseconds, Sock) then
        Break;
      Cur := Cur^.ai_next;
    end;

    if Sock = INVALID_SOCKET then
      raise EHTTPError.CreateFmt('Failed to connect to %s:%d', [AHost, APort]);

    Result := Sock;
  finally
    Freeaddrinfo(Res);
  end;
end;
{$ENDIF}

// ---------------------------------------------------------------------------
// Platform-neutral socket I/O wrappers
// ---------------------------------------------------------------------------

function SocketSend(const ASock: TSocket; const ABuf: Pointer;
  const ALen: Integer): Integer; inline;
begin
  {$IFDEF UNIX}
  Result := fpSend(ASock, ABuf, ALen, 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.send(ASock, ABuf^, ALen, 0);
  {$ENDIF}
end;

function SocketRecv(const ASock: TSocket; const ABuf: Pointer;
  const ALen: Integer): Integer; inline;
begin
  {$IFDEF UNIX}
  Result := fpRecv(ASock, ABuf, ALen, 0);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := WinSock2.recv(ASock, ABuf^, ALen, 0);
  {$ENDIF}
end;

procedure SocketClose(const ASock: TSocket); inline;
begin
  {$IFDEF UNIX}
  CloseSocket(ASock);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2.closesocket(ASock);
  {$ENDIF}
end;

// ---------------------------------------------------------------------------
// Send / Receive wrappers (unified TLS + plain)
// ---------------------------------------------------------------------------

procedure SendAllBuffer(const ASock: TSocket;
  var ATransport: TTransportSecurityConnection;
  const AData: Pointer; const ALength: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord);
var
  Sent, Total, Len, N: Integer;
begin
  Total := ALength;
  Sent := 0;
  while Sent < Total do
  begin
    CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
    Len := Total - Sent;
    if ATransport.Active then
      N := TransportSecurityWrite(ATransport, PByte(AData) + Sent, Len)
    else
      N := SocketSend(ASock, PByte(AData) + Sent, Len);
    if (N < 0) and SocketWouldBlock then
    begin
      WaitForSocket(ASock, False, True, ADeadline,
        ATimeoutMilliseconds);
      Continue;
    end;
    if N <= 0 then
      raise EHTTPError.Create('Send failed');
    Inc(Sent, N);
    CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
  end;
end;

procedure SendAll(const ASock: TSocket;
  var ATransport: TTransportSecurityConnection;
  const AData: AnsiString; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  if Length(AData) > 0 then
    SendAllBuffer(ASock, ATransport, @AData[1], Length(AData), ADeadline,
      ATimeoutMilliseconds);
end;

procedure SendAllBytes(const ASock: TSocket;
  var ATransport: TTransportSecurityConnection;
  const AData: TBytes; const ADeadline,
  ATimeoutMilliseconds: QWord);
begin
  if Length(AData) > 0 then
    SendAllBuffer(ASock, ATransport, @AData[0], Length(AData), ADeadline,
      ATimeoutMilliseconds);
end;

function RecvBytes(const ASock: TSocket;
  var ATransport: TTransportSecurityConnection;
  var ABuf: array of Byte; const ALen: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): Integer;
begin
  repeat
    CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
    if ATransport.Active then
      Result := TransportSecurityRead(ATransport, ABuf, ALen)
    else
      Result := SocketRecv(ASock, @ABuf[0], ALen);
    if (Result < 0) and SocketWouldBlock then
      WaitForSocket(ASock, True, False, ADeadline,
        ATimeoutMilliseconds)
    else
    begin
      CheckRequestDeadline(ADeadline, ATimeoutMilliseconds);
      Exit;
    end;
  until False;
end;

// ---------------------------------------------------------------------------
// HTTP response parsing
// ---------------------------------------------------------------------------

type
  TRawHTTPResponse = record
    StatusCode: Integer;
    StatusText: string;
    Headers: THTTPHeaders;
    Body: TBytes;
  end;

function FindHeaderValue(const AHeaders: THTTPHeaders;
  const AName: string): string;
var
  I: Integer;
  Lower: string;
begin
  Result := '';
  Lower := LowerCase(AName);
  for I := 0 to High(AHeaders) do
    if AHeaders[I].Name = Lower then
    begin
      Result := AHeaders[I].Value;
      Exit;
    end;
end;

procedure AppendBodyBytes(var ABody: TBytes; const ASource;
  const ALength: Integer; const AMaxBodyBytes: Int64);
var
  PreviousLength: Integer;
begin
  if ALength <= 0 then
    Exit;
  PreviousLength := Length(ABody);
  if (Int64(PreviousLength) > AMaxBodyBytes - ALength) then
    raise EHTTPResponseTooLarge.CreateFmt(
      'HTTP response body exceeds configured limit of %d bytes',
      [AMaxBodyBytes]);
  SetLength(ABody, PreviousLength + ALength);
  Move(ASource, ABody[PreviousLength], ALength);
end;

function TryParseUnsignedDecimal(const AValue: string;
  out AParsed: Int64): Boolean;
var
  Digit: Int64;
  I: Integer;
begin
  Result := False;
  AParsed := 0;
  if AValue = '' then
    Exit;
  for I := 1 to Length(AValue) do
  begin
    if not (AValue[I] in ['0'..'9']) then
      Exit;
    Digit := Ord(AValue[I]) - Ord('0');
    if AParsed > (High(Int64) - Digit) div 10 then
      Exit;
    AParsed := AParsed * 10 + Digit;
  end;
  Result := True;
end;

function TryParseUnsignedHex(const AValue: string;
  out AParsed: Int64): Boolean;
var
  Digit: Int64;
  I: Integer;
begin
  Result := False;
  AParsed := 0;
  if AValue = '' then
    Exit;
  for I := 1 to Length(AValue) do
  begin
    case AValue[I] of
      '0'..'9': Digit := Ord(AValue[I]) - Ord('0');
      'a'..'f': Digit := Ord(AValue[I]) - Ord('a') + 10;
      'A'..'F': Digit := Ord(AValue[I]) - Ord('A') + 10;
    else
      Exit;
    end;
    if AParsed > (High(Int64) - Digit) div 16 then
      Exit;
    AParsed := AParsed * 16 + Digit;
  end;
  Result := True;
end;

procedure ParseContentLength(const AHeaders: THTTPHeaders;
  const AMaxBodyBytes: Int64; out AHasContentLength: Boolean;
  out AContentLength: Int64);
var
  I: Integer;
  ParsedLength: Int64;
  Value: string;
begin
  AHasContentLength := False;
  AContentLength := 0;
  for I := 0 to High(AHeaders) do
    if AHeaders[I].Name = 'content-length' then
    begin
      Value := Trim(AHeaders[I].Value);
      if not TryParseUnsignedDecimal(Value, ParsedLength) then
        raise EHTTPError.CreateFmt('Invalid HTTP Content-Length: %s',
          [Value]);
      if AHasContentLength and (ParsedLength <> AContentLength) then
        raise EHTTPError.Create(
          'Invalid HTTP response: conflicting Content-Length headers');
      AHasContentLength := True;
      AContentLength := ParsedLength;
    end;

  if AHasContentLength and (AContentLength > AMaxBodyBytes) then
    raise EHTTPResponseTooLarge.CreateFmt(
      'HTTP response body exceeds configured limit of %d bytes',
      [AMaxBodyBytes]);
end;

function ReadResponse(const ASock: TSocket;
  var ATransport: TTransportSecurityConnection;
  const AIsHead: Boolean;
  const AOptions: THTTPRequestOptions;
  const ADeadline: QWord): TRawHTTPResponse;
var
  Buf: array[0..RECV_BUF_SIZE - 1] of Byte;
  RawHeader: AnsiString;
  N, HeaderEnd, HeaderBytes, I, J, ChunkSize: Integer;
  ChunkSizeValue, ContentLen: Int64;
  HasContentLength: Boolean;
  Line, HeaderBlock: string;
  Lines: array of string;
  ColonPos: Integer;
  TransferEncoding: string;
  BodyBytes: TBytes;
  ChunkBuf: AnsiString;
  Remaining: Integer;
begin
  Result.StatusCode := 0;
  Result.StatusText := '';
  SetLength(Result.Headers, 0);
  SetLength(Result.Body, 0);

  // Read until we find the end of headers (CRLFCRLF)
  RawHeader := '';
  HeaderEnd := 0;
  repeat
    N := RecvBytes(ASock, ATransport, Buf, RECV_BUF_SIZE, ADeadline,
      AOptions.RequestTimeoutMilliseconds);
    if N <= 0 then Break;
    AppendRawBytes(RawHeader, Buf[0], N); { Byte-safe accumulator: this
      buffer also holds body-prefix bytes that arrive in the same recv as
      the headers; a Copy(PAnsiChar) cast would truncate them at the first
      #0, corrupting binary downloads. }
    HeaderEnd := Pos(CRLF + CRLF, string(RawHeader));
    if HeaderEnd > 0 then
    begin
      HeaderBytes := HeaderEnd + Length(CRLF + CRLF) - 1;
      if HeaderBytes > AOptions.MaxResponseHeaderBytes then
        raise EHTTPError.CreateFmt(
          'HTTP response headers exceed configured limit of %d bytes',
          [AOptions.MaxResponseHeaderBytes]);
    end
    else if Length(RawHeader) >= AOptions.MaxResponseHeaderBytes then
      raise EHTTPError.CreateFmt(
        'HTTP response headers exceed configured limit of %d bytes',
        [AOptions.MaxResponseHeaderBytes]);
  until HeaderEnd > 0;

  if HeaderEnd = 0 then
    raise EHTTPError.Create('Invalid HTTP response: no header terminator');

  // Split headers from any body bytes already received
  HeaderBlock := Copy(string(RawHeader), 1, HeaderEnd - 1);
  I := HeaderEnd + 4; // skip CRLFCRLF
  if I <= Length(RawHeader) then
  begin
    SetLength(BodyBytes, Length(RawHeader) - I + 1);
    Move(RawHeader[I], BodyBytes[0], Length(BodyBytes));
  end
  else
    SetLength(BodyBytes, 0);

  // Parse status line: "HTTP/1.1 200 OK"
  I := Pos(CRLF, HeaderBlock);
  if I > 0 then
    Line := Copy(HeaderBlock, 1, I - 1)
  else
    Line := HeaderBlock;

  J := Pos(' ', Line);
  if J > 0 then
  begin
    Delete(Line, 1, J);
    J := Pos(' ', Line);
    if J > 0 then
    begin
      Result.StatusCode := StrToIntDef(Copy(Line, 1, J - 1), 0);
      Result.StatusText := Copy(Line, J + 1, Length(Line));
    end
    else
      Result.StatusCode := StrToIntDef(Line, 0);
  end;

  // Parse header lines
  HeaderBlock := Copy(HeaderBlock, Pos(CRLF, HeaderBlock) + 2, Length(HeaderBlock));
  SetLength(Lines, 0);
  while Length(HeaderBlock) > 0 do
  begin
    I := Pos(CRLF, HeaderBlock);
    if I > 0 then
    begin
      SetLength(Lines, Length(Lines) + 1);
      Lines[High(Lines)] := Copy(HeaderBlock, 1, I - 1);
      Delete(HeaderBlock, 1, I + 1);
    end
    else
    begin
      if HeaderBlock <> '' then
      begin
        SetLength(Lines, Length(Lines) + 1);
        Lines[High(Lines)] := HeaderBlock;
      end;
      Break;
    end;
  end;

  SetLength(Result.Headers, Length(Lines));
  for I := 0 to High(Lines) do
  begin
    ColonPos := Pos(':', Lines[I]);
    if ColonPos > 0 then
    begin
      Result.Headers[I].Name := LowerCase(Trim(Copy(Lines[I], 1, ColonPos - 1)));
      Result.Headers[I].Value := Trim(Copy(Lines[I], ColonPos + 1, Length(Lines[I])));
    end
    else
    begin
      Result.Headers[I].Name := LowerCase(Trim(Lines[I]));
      Result.Headers[I].Value := '';
    end;
  end;

  // Don't read body for HEAD requests or 1xx/204/304 responses
  if AIsHead or (Result.StatusCode div 100 = 1) or
     (Result.StatusCode = 204) or (Result.StatusCode = 304) then
    Exit;

  // Read body
  TransferEncoding := LowerCase(FindHeaderValue(Result.Headers, 'transfer-encoding'));

  if Pos('chunked', TransferEncoding) > 0 then
  begin
    // Chunked transfer encoding.
    // Byte-safe seed for ChunkBuf: the alternative `ChunkBuf := AnsiString(BodyBytes)`
    // cast truncates at the first $00 byte because FPC's TBytes -> AnsiString
    // conversion is NUL-aware. The explicit byte copy preserves any in-band
    // $00 bytes (common for binary archives whose first chunk straddles the
    // header terminator) so the subsequent chunk-size + body parse sees the
    // full byte stream. The original symptom was random byte loss in GitLab
    // archives ~1 KB into the body where the first chunk boundary fell.
    SetLength(ChunkBuf, Length(BodyBytes));
    if Length(BodyBytes) > 0 then
      Move(BodyBytes[0], ChunkBuf[1], Length(BodyBytes));
    SetLength(Result.Body, 0);

    while True do
    begin
      while Pos(CRLF, string(ChunkBuf)) = 0 do
      begin
        if Length(ChunkBuf) >= AOptions.MaxResponseHeaderBytes then
          raise EHTTPError.CreateFmt(
            'HTTP chunk-size line exceeds configured limit of %d bytes',
            [AOptions.MaxResponseHeaderBytes]);
        N := RecvBytes(ASock, ATransport, Buf, RECV_BUF_SIZE, ADeadline,
          AOptions.RequestTimeoutMilliseconds);
        if N <= 0 then
          raise EHTTPError.Create('Invalid HTTP response: truncated chunked body');
        AppendRawBytes(ChunkBuf, Buf[0], N); { Byte-safe — Copy(PAnsiChar) would truncate at the first #0 }
      end;
      I := Pos(CRLF, string(ChunkBuf));
      if I - 1 > AOptions.MaxResponseHeaderBytes then
        raise EHTTPError.CreateFmt(
          'HTTP chunk-size line exceeds configured limit of %d bytes',
          [AOptions.MaxResponseHeaderBytes]);
      Line := Copy(string(ChunkBuf), 1, I - 1);
      Delete(ChunkBuf, 1, I + 1);

      J := Pos(';', Line);
      if J > 0 then
        Line := Copy(Line, 1, J - 1);

      Line := Trim(Line);
      if not TryParseUnsignedHex(Line, ChunkSizeValue) then
        raise EHTTPError.CreateFmt('Invalid HTTP chunk size: %s', [Line]);
      if ChunkSizeValue > AOptions.MaxResponseBodyBytes -
         Length(Result.Body) then
        raise EHTTPResponseTooLarge.CreateFmt(
          'HTTP response body exceeds configured limit of %d bytes',
          [AOptions.MaxResponseBodyBytes]);
      { ChunkBuf must hold both the payload and its trailing CRLF. Reject a
        frame that cannot fit in the Integer-indexed accumulator before any
        addition can overflow, even when the caller permits that body size. }
      if ChunkSizeValue > High(Integer) - 2 then
        raise EHTTPError.CreateFmt(
          'HTTP chunk size exceeds supported frame limit of %d bytes',
          [High(Integer) - 2]);
      ChunkSize := Integer(ChunkSizeValue);
      if ChunkSize = 0 then Break;

      while Length(ChunkBuf) < ChunkSize + 2 do
      begin
        N := RecvBytes(ASock, ATransport, Buf, RECV_BUF_SIZE, ADeadline,
          AOptions.RequestTimeoutMilliseconds);
        if N <= 0 then
          raise EHTTPError.Create('Invalid HTTP response: truncated chunked body');
        AppendRawBytes(ChunkBuf, Buf[0], N); { Byte-safe — Copy(PAnsiChar) would truncate at the first #0 }
      end;

      AppendBodyBytes(Result.Body, ChunkBuf[1], ChunkSize,
        AOptions.MaxResponseBodyBytes);
      Delete(ChunkBuf, 1, ChunkSize + 2);
    end;
  end
  else
  begin
    ParseContentLength(Result.Headers, AOptions.MaxResponseBodyBytes,
      HasContentLength, ContentLen);

    if HasContentLength then
    begin
      SetLength(Result.Body, 0);

      // Copy bytes already read with headers
      if Length(BodyBytes) > 0 then
      begin
        Remaining := Integer(ContentLen);
        N := Length(BodyBytes);
        if N > Remaining then
          N := Remaining;
        if N > 0 then
          AppendBodyBytes(Result.Body, BodyBytes[0], N,
            AOptions.MaxResponseBodyBytes);
      end;

      // Read remaining
      while Int64(Length(Result.Body)) < ContentLen do
      begin
        N := RecvBytes(ASock, ATransport, Buf, RECV_BUF_SIZE, ADeadline,
          AOptions.RequestTimeoutMilliseconds);
        if N <= 0 then
          raise EHTTPError.Create(
            'Invalid HTTP response: truncated fixed-length body');
        Remaining := Integer(ContentLen - Length(Result.Body));
        if N > Remaining then N := Remaining;
        AppendBodyBytes(Result.Body, Buf[0], N,
          AOptions.MaxResponseBodyBytes);
      end;
    end
    else
    begin
      // Read until connection close
      SetLength(Result.Body, 0);
      if Length(BodyBytes) > 0 then
        AppendBodyBytes(Result.Body, BodyBytes[0], Length(BodyBytes),
          AOptions.MaxResponseBodyBytes);
      repeat
        N := RecvBytes(ASock, ATransport, Buf, RECV_BUF_SIZE, ADeadline,
          AOptions.RequestTimeoutMilliseconds);
        if N <= 0 then Break;
        AppendBodyBytes(Result.Body, Buf[0], N,
          AOptions.MaxResponseBodyBytes);
      until False;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Destination resolution and address policy
//
// The per-hop host allowlist and non-global address deny follow GocciaScript's
// HTTPClient. Classification works on binary addresses, never on text, against
// named blocks transcribed from the IANA IPv4 and IPv6 Special-Purpose Address
// Registries (entries whose "Globally Reachable" is False or N/A), plus the
// multicast and reserved spaces. A request under an address policy dials the
// exact IPv4 address it classified.
// ---------------------------------------------------------------------------

type
  THTTPIPv6Octets = array[0..15] of Byte;

  { A parsed destination address. IPv4 occupies Octets[0..3]. }
  THTTPAddress = record
    IsIPv6: Boolean;
    Octets: THTTPIPv6Octets;
  end;

  THTTPIPv4Block = record
    Prefix: THTTPIPv4Octets;
    PrefixBits: Byte;
    Name: string;
  end;

  THTTPIPv6Block = record
    Prefix: THTTPIPv6Octets;
    PrefixBits: Byte;
    Name: string;
  end;

  { What the address policy decided for one hop. Pinned destinations are
    dialled at Address instead of resolving the host name again. }
  THTTPDialTarget = record
    Pinned: Boolean;
    Address: THTTPIPv4Octets;
  end;

const
  IPv4NonGlobalBlocks: array[0..14] of THTTPIPv4Block = (
    (Prefix: (0, 0, 0, 0); PrefixBits: 8; Name: 'this network'),
    (Prefix: (10, 0, 0, 0); PrefixBits: 8; Name: 'private-use'),
    (Prefix: (100, 64, 0, 0); PrefixBits: 10; Name: 'shared address space'),
    (Prefix: (127, 0, 0, 0); PrefixBits: 8; Name: 'loopback'),
    (Prefix: (169, 254, 0, 0); PrefixBits: 16; Name: 'link-local'),
    (Prefix: (172, 16, 0, 0); PrefixBits: 12; Name: 'private-use'),
    (Prefix: (192, 0, 0, 0); PrefixBits: 24;
      Name: 'IETF protocol assignments'),
    (Prefix: (192, 0, 2, 0); PrefixBits: 24; Name: 'documentation'),
    (Prefix: (192, 88, 99, 0); PrefixBits: 24;
      Name: 'deprecated 6to4 relay anycast'),
    (Prefix: (192, 168, 0, 0); PrefixBits: 16; Name: 'private-use'),
    (Prefix: (198, 18, 0, 0); PrefixBits: 15; Name: 'benchmarking'),
    (Prefix: (198, 51, 100, 0); PrefixBits: 24; Name: 'documentation'),
    (Prefix: (203, 0, 113, 0); PrefixBits: 24; Name: 'documentation'),
    (Prefix: (224, 0, 0, 0); PrefixBits: 4; Name: 'multicast'),
    (Prefix: (240, 0, 0, 0); PrefixBits: 4;
      Name: 'reserved (including limited broadcast)')
  );

  { Globally reachable exceptions inside a non-global block. }
  IPv4GlobalExceptions: array[0..1] of THTTPIPv4Block = (
    (Prefix: (192, 0, 0, 9); PrefixBits: 32;
      Name: 'port control protocol anycast'),
    (Prefix: (192, 0, 0, 10); PrefixBits: 32; Name: 'TURN anycast')
  );

  { Global unicast; every IPv6 address outside it is not globally reachable. }
  IPv6GlobalUnicast: THTTPIPv6Block = (
    Prefix: ($20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    PrefixBits: 3; Name: 'global unicast');

  IPv6NonGlobalBlocks: array[0..14] of THTTPIPv6Block = (
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 128; Name: 'unspecified'),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
      PrefixBits: 128; Name: 'loopback'),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $FF, $FF, 0, 0, 0, 0);
      PrefixBits: 96; Name: 'IPv4-mapped'),
    (Prefix: (0, $64, $FF, $9B, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 48; Name: 'local-use IPv4/IPv6 translation'),
    (Prefix: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 64; Name: 'discard-only'),
    (Prefix: (1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 64; Name: 'dummy prefix'),
    (Prefix: ($20, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 23; Name: 'IETF protocol assignments'),
    (Prefix: ($20, 1, $0D, $B8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 32; Name: 'documentation'),
    (Prefix: ($20, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 16; Name: '6to4'),
    (Prefix: ($3F, $FF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 20; Name: 'documentation'),
    (Prefix: ($5F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 16; Name: 'segment routing'),
    (Prefix: ($FC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 7; Name: 'unique-local'),
    (Prefix: ($FE, $80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 10; Name: 'link-local'),
    (Prefix: ($FE, $C0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 10; Name: 'deprecated site-local'),
    (Prefix: ($FF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 8; Name: 'multicast')
  );

  IPv6GlobalExceptions: array[0..6] of THTTPIPv6Block = (
    (Prefix: ($20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1);
      PrefixBits: 128; Name: 'port control protocol anycast'),
    (Prefix: ($20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2);
      PrefixBits: 128; Name: 'TURN anycast'),
    (Prefix: ($20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3);
      PrefixBits: 128; Name: 'DNS-SD service registration anycast'),
    (Prefix: ($20, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 32; Name: 'AMT'),
    (Prefix: ($20, 1, 0, 4, 1, $12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 48; Name: 'AS112-v6'),
    (Prefix: ($20, 1, 0, $20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 28; Name: 'ORCHIDv2'),
    (Prefix: ($20, 1, 0, $30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 28; Name: 'drone remote ID')
  );

  { IPv6 prefixes whose low 32 bits carry an IPv4 address that the
    destination is treated as: IPv4-mapped, IPv4-compatible, and the NAT64
    well-known prefix (RFC 6052), which may only embed global IPv4. }
  IPv4EmbeddingPrefixes: array[0..2] of THTTPIPv6Block = (
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $FF, $FF, 0, 0, 0, 0);
      PrefixBits: 96; Name: 'IPv4-mapped'),
    (Prefix: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 96; Name: 'IPv4-compatible'),
    (Prefix: (0, $64, $FF, $9B, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
      PrefixBits: 96; Name: 'IPv4/IPv6 translation')
  );

  IPv4OctetCount = 4;
  IPv6GroupCount = 8;
  IPv6EmbeddedIPv4Offset = 12;

{ True when the first APrefixBits bits of AAddress equal APrefix. }
function PrefixMatches(const AAddress, APrefix: array of Byte;
  const APrefixBits: Integer): Boolean;
var
  ByteIndex, RemainingBits: Integer;
  Mask: Byte;
begin
  RemainingBits := APrefixBits;
  ByteIndex := 0;
  while RemainingBits >= 8 do
  begin
    if AAddress[ByteIndex] <> APrefix[ByteIndex] then
      Exit(False);
    Inc(ByteIndex);
    Dec(RemainingBits, 8);
  end;
  if RemainingBits > 0 then
  begin
    Mask := Byte($FF shl (8 - RemainingBits));
    if (AAddress[ByteIndex] and Mask) <> (APrefix[ByteIndex] and Mask) then
      Exit(False);
  end;
  Result := True;
end;

{ Dotted-quad IPv4 text only. Deliberately strict: shortened forms ("127.1"),
  hexadecimal octets, octets with a leading zero ("010"), and bare integers
  are not literals. They are left to name resolution, whose binary answer is
  what gets classified and dialled. }
function TryParseIPv4(const AValue: string;
  out AOctets: THTTPIPv4Octets): Boolean;
var
  CharacterIndex, Part, Digits, Value: Integer;
  Current: Char;
begin
  Result := False;
  FillChar(AOctets, SizeOf(AOctets), 0);
  Part := 0;
  Value := 0;
  Digits := 0;
  for CharacterIndex := 1 to Length(AValue) do
  begin
    Current := AValue[CharacterIndex];
    if (Current >= '0') and (Current <= '9') then
    begin
      { A multi-digit octet may not start with 0: other parsers read it as
        octal, so it is not a canonical literal. }
      if (Digits = 1) and (Value = 0) then Exit;
      Inc(Digits);
      if Digits > 3 then Exit;
      Value := Value * 10 + (Ord(Current) - Ord('0'));
      if Value > 255 then Exit;
    end
    else if Current = '.' then
    begin
      if (Digits = 0) or (Part >= IPv4OctetCount - 1) then Exit;
      AOctets[Part] := Byte(Value);
      Inc(Part);
      Value := 0;
      Digits := 0;
    end
    else
      Exit;
  end;
  if (Digits = 0) or (Part <> IPv4OctetCount - 1) then Exit;
  AOctets[IPv4OctetCount - 1] := Byte(Value);
  Result := True;
end;

{ Parses colon-separated hexadecimal groups; the last group may be a dotted
  IPv4 tail when AAllowIPv4Tail, counting as two groups. }
function TryParseIPv6Groups(const AText: string;
  const AAllowIPv4Tail: Boolean; var AGroups: array of Word;
  out ACount: Integer): Boolean;
var
  Parts: TStringArray;
  PartIndex, CharacterIndex, Digit: Integer;
  Value: Cardinal;
  Tail: THTTPIPv4Octets;
begin
  Result := False;
  ACount := 0;
  if AText = '' then Exit(True);
  Parts := AText.Split([':']);
  for PartIndex := 0 to High(Parts) do
  begin
    if (PartIndex = High(Parts)) and AAllowIPv4Tail
       and (Pos('.', Parts[PartIndex]) > 0) then
    begin
      if (ACount + 2 > Length(AGroups))
         or not TryParseIPv4(Parts[PartIndex], Tail) then Exit;
      AGroups[ACount] := (Word(Tail[0]) shl 8) or Tail[1];
      AGroups[ACount + 1] := (Word(Tail[2]) shl 8) or Tail[3];
      Inc(ACount, 2);
      Continue;
    end;
    if (Length(Parts[PartIndex]) = 0) or (Length(Parts[PartIndex]) > 4)
       or (ACount >= Length(AGroups)) then Exit;
    Value := 0;
    for CharacterIndex := 1 to Length(Parts[PartIndex]) do
    begin
      case Parts[PartIndex][CharacterIndex] of
        '0'..'9': Digit := Ord(Parts[PartIndex][CharacterIndex]) - Ord('0');
        'a'..'f': Digit := Ord(Parts[PartIndex][CharacterIndex]) - Ord('a')
          + 10;
        'A'..'F': Digit := Ord(Parts[PartIndex][CharacterIndex]) - Ord('A')
          + 10;
      else
        Exit;
      end;
      Value := Value * 16 + Cardinal(Digit);
    end;
    AGroups[ACount] := Word(Value);
    Inc(ACount);
  end;
  Result := True;
end;

{ Parses every textual IPv6 form (compressed, uncompressed, mixed with a
  dotted IPv4 tail) into its 16 bytes. Zone identifiers are refused. }
function TryParseIPv6(const AValue: string;
  out AOctets: THTTPIPv6Octets): Boolean;
var
  Head, Tail: array[0..IPv6GroupCount - 1] of Word;
  Groups: array[0..IPv6GroupCount - 1] of Word;
  HeadCount, TailCount, GroupIndex, CompressAt: Integer;
  Text: string;
begin
  Result := False;
  FillChar(AOctets, SizeOf(AOctets), 0);
  Text := AValue;
  if (Length(Text) >= 2) and (Text[1] = '[')
     and (Text[Length(Text)] = ']') then
    Text := Copy(Text, 2, Length(Text) - 2);
  if (Text = '') or (Pos('%', Text) > 0) then Exit;
  FillChar(Groups, SizeOf(Groups), 0);
  CompressAt := Pos('::', Text);
  if CompressAt > 0 then
  begin
    if Pos('::', Copy(Text, CompressAt + 2, MaxInt)) > 0 then Exit;
    if not TryParseIPv6Groups(Copy(Text, 1, CompressAt - 1), False, Head,
       HeadCount) then Exit;
    if not TryParseIPv6Groups(Copy(Text, CompressAt + 2, MaxInt), True,
       Tail, TailCount) then Exit;
    if HeadCount + TailCount > IPv6GroupCount - 1 then Exit;
    for GroupIndex := 0 to HeadCount - 1 do
      Groups[GroupIndex] := Head[GroupIndex];
    for GroupIndex := 0 to TailCount - 1 do
      Groups[IPv6GroupCount - TailCount + GroupIndex] := Tail[GroupIndex];
  end
  else
  begin
    if not TryParseIPv6Groups(Text, True, Groups, HeadCount) then Exit;
    if HeadCount <> IPv6GroupCount then Exit;
  end;
  for GroupIndex := 0 to IPv6GroupCount - 1 do
  begin
    AOctets[GroupIndex * 2] := Byte(Groups[GroupIndex] shr 8);
    AOctets[GroupIndex * 2 + 1] := Byte(Groups[GroupIndex] and $FF);
  end;
  Result := True;
end;

{ Rewrites an IPv6 address that embeds an IPv4 destination (see
  IPv4EmbeddingPrefixes) as that IPv4 address, so every spelling of the same
  IPv4 destination is classified and dialled identically. The unspecified
  and loopback addresses stay IPv6. }
procedure CanonicalizeAddress(var AAddress: THTTPAddress);
var
  BlockIndex: Integer;
  Embedded: THTTPIPv4Octets;
begin
  if not AAddress.IsIPv6 then Exit;
  if PrefixMatches(AAddress.Octets, IPv6NonGlobalBlocks[0].Prefix, 128)
     or PrefixMatches(AAddress.Octets, IPv6NonGlobalBlocks[1].Prefix, 128) then
    Exit;
  for BlockIndex := 0 to High(IPv4EmbeddingPrefixes) do
    if PrefixMatches(AAddress.Octets, IPv4EmbeddingPrefixes[BlockIndex].Prefix,
       IPv4EmbeddingPrefixes[BlockIndex].PrefixBits) then
    begin
      Move(AAddress.Octets[IPv6EmbeddedIPv4Offset], Embedded[0],
        SizeOf(Embedded));
      AAddress := Default(THTTPAddress);
      Move(Embedded[0], AAddress.Octets[0], SizeOf(Embedded));
      Exit;
    end;
end;

{ '' when AAddress is globally reachable, otherwise the name of the
  registry block that makes it non-global. }
function NonGlobalReason(const AAddress: THTTPAddress): string;
var
  BlockIndex: Integer;
begin
  Result := '';
  if not AAddress.IsIPv6 then
  begin
    for BlockIndex := 0 to High(IPv4GlobalExceptions) do
      if PrefixMatches(AAddress.Octets, IPv4GlobalExceptions[BlockIndex].Prefix,
         IPv4GlobalExceptions[BlockIndex].PrefixBits) then
        Exit('');
    for BlockIndex := 0 to High(IPv4NonGlobalBlocks) do
      if PrefixMatches(AAddress.Octets, IPv4NonGlobalBlocks[BlockIndex].Prefix,
         IPv4NonGlobalBlocks[BlockIndex].PrefixBits) then
        Exit(IPv4NonGlobalBlocks[BlockIndex].Name);
    Exit('');
  end;
  for BlockIndex := 0 to High(IPv6GlobalExceptions) do
    if PrefixMatches(AAddress.Octets, IPv6GlobalExceptions[BlockIndex].Prefix,
       IPv6GlobalExceptions[BlockIndex].PrefixBits) then
      Exit('');
  for BlockIndex := 0 to High(IPv6NonGlobalBlocks) do
    if PrefixMatches(AAddress.Octets, IPv6NonGlobalBlocks[BlockIndex].Prefix,
       IPv6NonGlobalBlocks[BlockIndex].PrefixBits) then
      Exit(IPv6NonGlobalBlocks[BlockIndex].Name);
  if not PrefixMatches(AAddress.Octets, IPv6GlobalUnicast.Prefix,
     IPv6GlobalUnicast.PrefixBits) then
    Result := 'outside global unicast';
end;

function FormatAddress(const AAddress: THTTPAddress): string;
var
  GroupIndex: Integer;
begin
  if not AAddress.IsIPv6 then
    Exit(Format('%d.%d.%d.%d', [AAddress.Octets[0], AAddress.Octets[1],
      AAddress.Octets[2], AAddress.Octets[3]]));
  Result := '';
  for GroupIndex := 0 to IPv6GroupCount - 1 do
  begin
    if GroupIndex > 0 then Result := Result + ':';
    Result := Result + LowerCase(IntToHex(
      (Word(AAddress.Octets[GroupIndex * 2]) shl 8)
      or AAddress.Octets[GroupIndex * 2 + 1], 1));
  end;
end;

{ Parses AHost as an address literal, or resolves it once to one IPv4
  address. The binary result is what gets classified and dialled. }
function ResolveDestinationAddress(const AHost: string): THTTPAddress;
{$IFDEF UNIX}
var
  ResolvedAddress: in_addr;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Hints, Res: PAddrInfo;
  SockAddr: PSockAddrIn;
{$ENDIF}
var
  IPv4: THTTPIPv4Octets;
begin
  Result := Default(THTTPAddress);
  if AHost = '' then
    raise EHTTPError.Create('Failed to resolve host: (empty)');
  if TryParseIPv4(AHost, IPv4) then
    Move(IPv4[0], Result.Octets[0], SizeOf(IPv4))
  else if Pos(':', AHost) > 0 then
  begin
    if not TryParseIPv6(AHost, Result.Octets) then
      raise EHTTPError.CreateFmt('Invalid IPv6 address: %s', [AHost]);
    Result.IsIPv6 := True;
  end
  else
  begin
    {$IFDEF UNIX}
    ResolvedAddress := ResolveSocketAddress(AHost);
    Move(ResolvedAddress, Result.Octets[0], IPv4OctetCount);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    EnsureWinSockInit;
    New(Hints);
    try
      FillChar(Hints^, SizeOf(TAddrInfo), 0);
      Hints^.ai_family := AF_INET;
      Hints^.ai_socktype := SOCK_STREAM;
      Hints^.ai_protocol := IPPROTO_TCP;
      Res := nil;
      if Getaddrinfo(PAnsiChar(AnsiString(AHost)), nil, Hints, Res) <> 0 then
        raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
      try
        if not Assigned(Res) or not Assigned(Res^.ai_addr) then
          raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
        SockAddr := PSockAddrIn(Res^.ai_addr);
        Move(SockAddr^.sin_addr, Result.Octets[0], IPv4OctetCount);
      finally
        Freeaddrinfo(Res);
      end;
    finally
      Dispose(Hints);
    end;
    {$ENDIF}
  end;
  CanonicalizeAddress(Result);
end;

{$IFDEF HTTPCLIENT_TESTING}
function NonGlobalAddressReason(const AAddressText: string): string;
var
  Address: THTTPAddress;
  IPv4: THTTPIPv4Octets;
begin
  Address := Default(THTTPAddress);
  if TryParseIPv4(Trim(AAddressText), IPv4) then
    Move(IPv4[0], Address.Octets[0], SizeOf(IPv4))
  else if TryParseIPv6(Trim(AAddressText), Address.Octets) then
    Address.IsIPv6 := True
  else
    Exit('not an address literal');
  CanonicalizeAddress(Address);
  Result := NonGlobalReason(Address);
end;
{$ENDIF}

function IsHTTPHostAllowed(const APolicy: THTTPDestinationPolicy;
  const AHost: string): Boolean;
var
  HostIndex: Integer;
begin
  if Length(APolicy.AllowedHosts) = 0 then
    Exit(True);
  for HostIndex := 0 to High(APolicy.AllowedHosts) do
    if SameText(APolicy.AllowedHosts[HostIndex], AHost) then
      Exit(True);
  Result := False;
end;

{ Applies APolicy to one hop. The scheme and host checks run before any
  resolution, so a refused hop causes no DNS lookup and no connection. The
  address check runs on the resolved binary address, which the caller then
  dials without resolving the name again. }
function ResolveAllowedDestination(const APolicy: THTTPDestinationPolicy;
  const AParsed: THTTPParsedURL): THTTPDialTarget;
var
  Address: THTTPAddress;
  Reason: string;
  {$IFDEF HTTPCLIENT_TESTING}
  TestAddress: string;
  TestPrivate: Boolean;
  TestOctets: THTTPIPv4Octets;
  {$ENDIF}
begin
  Result := Default(THTTPDialTarget);
  if APolicy.RequireHTTPS and (AParsed.Scheme <> 'https')
     {$IFDEF HTTPCLIENT_TESTING}
     and not (Assigned(HTTPClientHTTPSStandInTestHook)
       and HTTPClientHTTPSStandInTestHook(AParsed.Host))
     {$ENDIF} then
    raise EHTTPError.CreateFmt(
      'fetch scheme not allowed: %s://%s (https is required)',
      [AParsed.Scheme, AParsed.Host]);
  if not IsHTTPHostAllowed(APolicy, AParsed.Host) then
    raise EHTTPError.CreateFmt('fetch host not allowed: %s', [AParsed.Host]);
  if APolicy.PrivateAddressPolicy = papAllow then
    Exit;

  {$IFDEF HTTPCLIENT_TESTING}
  if Assigned(HTTPClientResolveTestHook) and
     HTTPClientResolveTestHook(AParsed.Host, TestAddress, TestPrivate) then
  begin
    if not TryParseIPv4(TestAddress, TestOctets) then
      raise EHTTPError.CreateFmt('test resolver returned "%s"',
        [TestAddress]);
    Address := Default(THTTPAddress);
    Move(TestOctets[0], Address.Octets[0], SizeOf(TestOctets));
    if TestPrivate then Reason := 'test-designated private'
    else Reason := '';
  end
  else
  {$ENDIF}
  begin
    Address := ResolveDestinationAddress(AParsed.Host);
    Reason := NonGlobalReason(Address);
  end;

  if Reason <> '' then
    raise EHTTPError.CreateFmt(
      'fetch destination not allowed: %s resolves to %s address %s',
      [AParsed.Host, Reason, FormatAddress(Address)]);
  if Address.IsIPv6 then
    raise EHTTPError.CreateFmt(
      'fetch destination not supported: %s resolves to IPv6 address %s, '
      + 'which a policy-checked request cannot dial', [AParsed.Host,
      FormatAddress(Address)]);
  Result.Pinned := True;
  Move(Address.Octets[0], Result.Address[0], IPv4OctetCount);
end;

// ---------------------------------------------------------------------------
// Core request logic
// ---------------------------------------------------------------------------

procedure ValidateRequestOptions(const AOptions: THTTPRequestOptions);
begin
  if (AOptions.MaxResponseBodyBytes < 0) or
     (AOptions.MaxResponseBodyBytes > High(Integer)) then
    raise EHTTPError.Create(
      'HTTP maximum response body size must be between 0 and High(Integer)');
  if AOptions.MaxResponseHeaderBytes < Length(CRLF + CRLF) then
    raise EHTTPError.Create(
      'HTTP maximum response header size must be at least 4 bytes');
  if AOptions.MaxResponseHeaderBytes >
     High(Integer) - RECV_BUF_SIZE then
    raise EHTTPError.Create(
      'HTTP maximum response header size is too large');
  if AOptions.RequestTimeoutMilliseconds = 0 then
    raise EHTTPError.Create('HTTP request timeout must be greater than zero');
  if AOptions.MaximumRedirects < 0 then
    raise EHTTPError.Create('HTTP maximum redirects must not be negative');
  try
    ValidateTransportSecurityClientOptions(AOptions.TLS);
  except
    on E: ETransportSecurityError do
      raise EHTTPError.Create(E.Message);
  end;
end;

{ True when AParsed names the same origin (scheme, host, port) as
  AOrigin. Hosts compare case-insensitively, as HTTP origins do. }
function IsSameHTTPOrigin(const AOrigin, AParsed: THTTPParsedURL): Boolean;
begin
  Result := (AOrigin.Scheme = AParsed.Scheme) and
    SameText(AOrigin.Host, AParsed.Host) and
    (AOrigin.Port = AParsed.Port);
end;

procedure ValidateRequestContentType(const AContentType: string);
begin
  if (Pos(#13, AContentType) > 0) or (Pos(#10, AContentType) > 0) then
    raise EHTTPError.Create(
      'HTTP content type must not contain carriage return or line feed');
end;

function DoRequest(const AMethod, AURL: string;
  const ABody: TBytes; const AContentType: string;
  const AManagesContentHeaders: Boolean;
  const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions;
  const AMaxRedirects: Integer): THTTPResponse;
var
  Origin, Parsed: THTTPParsedURL;
  Sock: TSocket;
  Transport: TTransportSecurityConnection;
  Request: AnsiString;
  Raw: TRawHTTPResponse;
  I, Redirects: Integer;
  CurrentURL, Location, HostHeader: string;
  DialTarget: THTTPDialTarget;
  ConnectOctets: THTTPIPv4Octets;
  HasRequestContent, HasUserAgent, IsHead: Boolean;
  HeaderName, Method, ContentType: string;
  Body: TBytes;
  Deadline, StartedAt: QWord;
begin
  ValidateRequestOptions(AOptions);
  if AOptions.ConnectAddress <> '' then
  begin
    if not TryParseIPv4(AOptions.ConnectAddress, ConnectOctets) then
      raise EHTTPError.Create('HTTP connect address must be a canonical literal IPv4 address');
    if AOptions.Destination.PrivateAddressPolicy <> papAllow then
      raise EHTTPError.Create('HTTP connect address cannot be combined with an address policy');
  end;
  if AManagesContentHeaders then
    ValidateRequestContentType(AContentType);
  StartedAt := GetTickCount64;
  if AOptions.RequestTimeoutMilliseconds > High(QWord) - StartedAt then
    Deadline := High(QWord)
  else
    Deadline := StartedAt + AOptions.RequestTimeoutMilliseconds;
  CurrentURL := AURL;
  Redirects := 0;
  Result.Redirected := False;
  Method := UpperCase(AMethod);
  IsHead := (Method = 'HEAD');
  Body := ABody;
  ContentType := AContentType;
  HasRequestContent := AManagesContentHeaders;

  while True do
  begin
    CheckRequestDeadline(Deadline, AOptions.RequestTimeoutMilliseconds);
    Parsed := ParseHTTPURL(CurrentURL);
    if Redirects = 0 then
      Origin := Parsed;
    { Runs on every pass, so each redirect hop is checked exactly like the
      initial request before any connection is attempted. }
    DialTarget := ResolveAllowedDestination(AOptions.Destination, Parsed);
    CheckRequestDeadline(Deadline, AOptions.RequestTimeoutMilliseconds);
    FillChar(Transport, SizeOf(Transport), 0);
    if (AOptions.ConnectAddress <> '') and (Redirects = 0) then
    begin
      DialTarget.Pinned := True;
      DialTarget.Address := ConnectOctets;
    end;
    { TLS below still verifies Parsed.Host: pinning changes which address is
      dialled, never which identity the peer must prove. }
    if DialTarget.Pinned then
      Sock := ConnectIPv4Socket(DialTarget.Address, Parsed.Host, Parsed.Port,
        Deadline, AOptions.RequestTimeoutMilliseconds)
    else
      Sock := ConnectSocket(Parsed.Host, Parsed.Port, Deadline,
        AOptions.RequestTimeoutMilliseconds);
    try
      { TLS options apply only to the configured origin; every other hop
        uses the default, fully verified client. }
      if Parsed.Scheme = 'https' then
      begin
        if IsSameHTTPOrigin(Origin, Parsed) then
          StartTransportSecurity(Transport, Sock, Parsed.Host, AOptions.TLS,
            Deadline, AOptions.RequestTimeoutMilliseconds)
        else
          StartTransportSecurity(Transport, Sock, Parsed.Host, Deadline,
            AOptions.RequestTimeoutMilliseconds);
      end;

      try
        // Build Host header value
        if ((Parsed.Scheme = 'http') and (Parsed.Port = 80)) or
           ((Parsed.Scheme = 'https') and (Parsed.Port = 443)) then
          HostHeader := Parsed.Host
        else
          HostHeader := Parsed.Host + ':' + IntToStr(Parsed.Port);

        Request := AnsiString(Method + ' ' + Parsed.Path + ' HTTP/1.1' + CRLF);
        Request := Request + AnsiString('Host: ' + HostHeader + CRLF);
        Request := Request + AnsiString('Connection: close' + CRLF);

        // Check if user provided User-Agent
        HasUserAgent := False;
        for I := 0 to High(AHeaders) do
          if LowerCase(AHeaders[I].Name) = 'user-agent' then
            HasUserAgent := True;

        if not HasUserAgent then
          Request := Request + AnsiString('User-Agent: GocciaScript/1.0' + CRLF);

        if HasRequestContent then
        begin
          Request := Request + AnsiString('Content-Length: ' +
            IntToStr(Length(Body)) + CRLF);
          Request := Request + AnsiString('Content-Type: ' + ContentType + CRLF);
        end;

        // Add custom headers. Request content owns its framing and media type.
        for I := 0 to High(AHeaders) do
        begin
          HeaderName := LowerCase(AHeaders[I].Name);
          if HeaderName = 'host' then Continue;
          if AManagesContentHeaders and
             ((HeaderName = 'content-length') or
              (HeaderName = 'content-type') or
              (HeaderName = 'transfer-encoding')) then Continue;
          Request := Request + AnsiString(AHeaders[I].Name + ': ' + AHeaders[I].Value + CRLF);
        end;

        Request := Request + AnsiString(CRLF);

        SendAll(Sock, Transport, Request, Deadline,
          AOptions.RequestTimeoutMilliseconds);
        if HasRequestContent then
          SendAllBytes(Sock, Transport, Body, Deadline,
            AOptions.RequestTimeoutMilliseconds);
        Raw := ReadResponse(Sock, Transport, IsHead, AOptions, Deadline);
        CheckRequestDeadline(Deadline,
          AOptions.RequestTimeoutMilliseconds);
      finally
        CloseTransportSecurity(Transport);
      end;
    finally
      SocketClose(Sock);
    end;

    // Handle redirects
    if (Raw.StatusCode >= 301) and (Raw.StatusCode <= 308) and
       (Raw.StatusCode <> 304) and (Raw.StatusCode <> 305) then
    begin
      Location := FindHeaderValue(Raw.Headers, 'location');
      if (Location <> '') and (Redirects < AMaxRedirects) then
      begin
        Inc(Redirects);
        Result.Redirected := True;

        // Handle relative URLs
        if (Length(Location) > 0) and (Location[1] = '/') then
          CurrentURL := Parsed.Scheme + '://' + HostHeader + Location
        else if Pos('://', Location) = 0 then
          CurrentURL := Parsed.Scheme + '://' + HostHeader + '/' + Location
        else
          CurrentURL := Location;

        // RFC 9205 recommends browser-compatible POST rewriting for 301/302.
        // 303 always retrieves with GET; 307/308 preserve method and content.
        if (Raw.StatusCode = 303) or
           (((Raw.StatusCode = 301) or (Raw.StatusCode = 302)) and
            (Method = 'POST')) then
        begin
          Method := 'GET';
          IsHead := False;
          SetLength(Body, 0);
          ContentType := '';
          HasRequestContent := False;
        end;

        Continue;
      end;
    end;

    // No redirect — build final response
    Result.StatusCode := Raw.StatusCode;
    Result.StatusText := Raw.StatusText;
    Result.Headers := Raw.Headers;
    Result.Body := Raw.Body;
    Result.FinalURL := CurrentURL;
    Break;
  end;
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function DefaultHTTPRequestOptions: THTTPRequestOptions;
begin
  Result.MaxResponseBodyBytes := DEFAULT_MAX_RESPONSE_BODY_BYTES;
  Result.MaxResponseHeaderBytes := DEFAULT_MAX_RESPONSE_HEADER_BYTES;
  Result.RequestTimeoutMilliseconds :=
    DEFAULT_REQUEST_TIMEOUT_MILLISECONDS;
  Result.MaximumRedirects := DEFAULT_MAXIMUM_REDIRECTS;
  Result.Destination.AllowedHosts := nil;
  Result.Destination.PrivateAddressPolicy := papAllow;
  Result.Destination.RequireHTTPS := False;
  Result.ConnectAddress := '';
  Result.TLS := DefaultTransportSecurityClientOptions;
end;

function HTTPURLHost(const AURL: string): string;
begin
  Result := LowerCase(ParseHTTPURL(AURL).Host);
end;

function HTTPGet(const AURL: string;
  const AHeaders: THTTPHeaders): THTTPResponse;
begin
  Result := HTTPGet(AURL, AHeaders, DefaultHTTPRequestOptions);
end;

function HTTPGet(const AURL: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse;
begin
  try
    Result := DoRequest('GET', AURL, nil, '', False, AHeaders, AOptions,
      AOptions.MaximumRedirects);
  except
    on E: ETransportSecurityError do
      raise EHTTPError.Create(E.Message);
  end;
end;

function HTTPHead(const AURL: string;
  const AHeaders: THTTPHeaders): THTTPResponse;
begin
  Result := HTTPHead(AURL, AHeaders, DefaultHTTPRequestOptions);
end;

function HTTPHead(const AURL: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse;
begin
  try
    Result := DoRequest('HEAD', AURL, nil, '', False, AHeaders, AOptions,
      AOptions.MaximumRedirects);
  except
    on E: ETransportSecurityError do
      raise EHTTPError.Create(E.Message);
  end;
end;

function HTTPPost(const AURL: string; const ABody: TBytes;
  const AContentType: string;
  const AHeaders: THTTPHeaders): THTTPResponse;
begin
  Result := HTTPPost(AURL, ABody, AContentType, AHeaders,
    DefaultHTTPRequestOptions);
end;

function HTTPPost(const AURL: string; const ABody: TBytes;
  const AContentType: string; const AHeaders: THTTPHeaders;
  const AOptions: THTTPRequestOptions): THTTPResponse;
begin
  try
    Result := DoRequest('POST', AURL, ABody, AContentType, True,
      AHeaders, AOptions, AOptions.MaximumRedirects);
  except
    on E: ETransportSecurityError do
      raise EHTTPError.Create(E.Message);
  end;
end;

end.
