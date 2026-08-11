unit HTTPClient;

// Minimal HTTP/1.1 client built on raw BSD sockets.
// Supports GET, HEAD, and POST over HTTP and HTTPS.
// Cross-platform: Unix (macOS, Linux) and Windows.
// Synchronous API with deadline-aware nonblocking socket I/O.

{$I Shared.inc}

interface

uses
  SysUtils;

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

  THTTPRequestOptions = record
    MaxResponseBodyBytes: Int64;
    MaxResponseHeaderBytes: Integer;
    RequestTimeoutMilliseconds: QWord;
    MaximumRedirects: Integer;
  end;

  EHTTPError = class(Exception);

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

const
  DEFAULT_MAX_RESPONSE_BODY_BYTES = Int64(64) * 1024 * 1024;
  DEFAULT_MAX_RESPONSE_HEADER_BYTES = 64 * 1024;
  DEFAULT_REQUEST_TIMEOUT_MILLISECONDS = 120 * 1000;
  DEFAULT_MAXIMUM_REDIRECTS = 20;

{$IF DEFINED(UNIX) AND DEFINED(HTTPCLIENT_TESTING)}
var
  HTTPClientSelectTestHook: THTTPClientSelectTestHook;
{$ENDIF}

function DefaultHTTPRequestOptions: THTTPRequestOptions;
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
  Sockets, BaseUnix, NetDB,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  TransportSecurity;

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

{$IFDEF UNIX}
function ConnectSocket(const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  SockAddr: TInetSockAddr;
  HostEntry: THostEntry;
  Addr: in_addr;
  ConnectResult: Integer;
  SocketError: Integer;
  SocketErrorLength: TSockLen;
begin
  // Try as numeric IP first
  Addr := StrToNetAddr(AHost);
  if Addr.s_addr = 0 then
  begin
    // DNS lookup via netdb
    if not ResolveHostByName(AHost, HostEntry) then
      raise EHTTPError.CreateFmt('Failed to resolve host: %s', [AHost]);
    Addr := HostEntry.Addr;
  end;
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
  SockAddr.sin_addr := Addr;

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
{$ENDIF}

{$IFDEF MSWINDOWS}
function ConnectSocket(const AHost: string; const APort: Integer;
  const ADeadline, ATimeoutMilliseconds: QWord): TSocket;
var
  Hints, Res, Cur: PAddrInfo;
  PortStr: AnsiString;
  Sock: TSocket;
  ConnectResult: Integer;
  SocketError: Integer;
  SocketErrorLength: Integer;
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
      Sock := WinSock2.socket(Cur^.ai_family, Cur^.ai_socktype,
                               Cur^.ai_protocol);
      if Sock = INVALID_SOCKET then
      begin
        Cur := Cur^.ai_next;
        Continue;
      end;

      try
        SetSocketNonBlocking(Sock);
      except
        WinSock2.closesocket(Sock);
        raise;
      end;
      ConnectResult := WinSock2.connect(Sock, Cur^.ai_addr,
        Cur^.ai_addrlen);
      if ConnectResult = 0 then
        Break;
      if SocketWouldBlock then
      begin
        try
          WaitForSocket(Sock, False, True, ADeadline,
            ATimeoutMilliseconds);
          SocketError := 0;
          SocketErrorLength := SizeOf(SocketError);
          if (WinSock2.getsockopt(Sock, SOL_SOCKET, SO_ERROR,
             PChar(@SocketError), SocketErrorLength) = 0) and
             (SocketError = 0) then
            Break;
        except
          WinSock2.closesocket(Sock);
          raise;
        end;
      end;

      WinSock2.closesocket(Sock);
      Sock := INVALID_SOCKET;
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
    raise EHTTPError.CreateFmt(
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
    raise EHTTPError.CreateFmt(
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
        raise EHTTPError.CreateFmt(
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
  Parsed: THTTPParsedURL;
  Sock: TSocket;
  Transport: TTransportSecurityConnection;
  Request: AnsiString;
  Raw: TRawHTTPResponse;
  I, Redirects: Integer;
  CurrentURL, Location, HostHeader: string;
  HasRequestContent, HasUserAgent, IsHead: Boolean;
  HeaderName, Method, ContentType: string;
  Body: TBytes;
  Deadline, StartedAt: QWord;
begin
  ValidateRequestOptions(AOptions);
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
    FillChar(Transport, SizeOf(Transport), 0);
    Sock := ConnectSocket(Parsed.Host, Parsed.Port, Deadline,
      AOptions.RequestTimeoutMilliseconds);
    try
      if Parsed.Scheme = 'https' then
        StartTransportSecurity(Transport, Sock, Parsed.Host, Deadline,
          AOptions.RequestTimeoutMilliseconds);

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
