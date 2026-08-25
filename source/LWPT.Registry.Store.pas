{ LWPT.Registry.Store — durable content-addressed origin state.

  Immutable bytes are written before one atomic current-state pointer makes a
  publication visible. Readers load that pointer once and therefore observe a
  complete old or complete new snapshot while publication is in progress. }
unit LWPT.Registry.Store;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core;

const
  REGISTRY_DEFAULT_DATA_DIR = '.lwpt/registry';
  REGISTRY_DEFAULT_BASE_URL = 'http://localhost:8080';
  REGISTRY_DEFAULT_LISTEN_ADDRESS = 'localhost';
  REGISTRY_DEFAULT_PORT = 8080;

type
  ELWPTRegistryError = class(ELWPTError)
  public
    constructor CreateStable(const ACode, AMessage: string);
  end;

  TLWPTRegistryConfig = record
    Identity: string;
    BaseURL: string;
    ListenAddress: string;
    Port: Word;
    TLSPKCS12Path: string;
    TLSPasswordEnvironment: string;
  end;

  TLWPTRegistryState = record
    Sequence: QWord;
    SnapshotHash: string;
    CheckpointPath: string;
    SignaturePath: string;
  end;

  TLWPTRegistryPublication = record
    Name: string;
    Version: string;
    PublishedAt: string;
    Archive: TBytes;
  end;

  TLWPTRegistryStore = class
  private
    FRoot: string;
    FConfig: TLWPTRegistryConfig;
    function RootPath(const ARelative: string): string;
    function TmpRoot: string;
    function LoadSeed: TBytes;
    function ReadCurrentState: TLWPTRegistryState;
    procedure VerifyState(const AState: TLWPTRegistryState);
    procedure RecoverDerivedState(const AState: TLWPTRegistryState);
    procedure WriteImmutable(const ARelative: string;
      const ABytes: TBytes);
  public
    constructor Create(const ARoot: string);
    class function Initialize(const ARoot: string;
      const ARequested: TLWPTRegistryConfig;
      const APublishedAt: string): TLWPTRegistryStore;
    procedure Recover;
    procedure EnsureFreshCheckpoint(const ANow: string);
    procedure DescribeResource(const ARelative, AExpectedDigest: string;
      out APath: string; out ASize: Int64);
    function LoadCurrentState: TLWPTRegistryState;
    function LoadResource(const ARelative: string): TBytes;
    procedure Publish(const APublication: TLWPTRegistryPublication);
    property Config: TLWPTRegistryConfig read FConfig;
    property Root: string read FRoot;
  end;

function CanonicalRegistryURL(const AValue: string;
  const ARequireHTTPS: Boolean): string;
function RegistryKeyStoragePath(const AKeyID: string): string;
function RegistryTOMLQuote(const AValue: string): string;
function RegistryTimestampNow: string;
function RegistryConfiguration(const AIdentity, ABaseURL,
  AListenAddress: string; const APort: Word; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string): TLWPTRegistryConfig;
procedure ValidateRegistryConfiguration(const AConfig: TLWPTRegistryConfig);
{$IFDEF REGISTRY_TESTING}
procedure SetRegistryFailurePointForTesting(const APoint: string);
procedure SetRegistryPublicationBarrierForTesting(const AReadyPath,
  AReleasePath: string);
{$ENDIF}

implementation

uses
  DateUtils,
  Sockets,
  StrUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.ProducerLease,
  LWPT.Registry.Crypto,
  Semver;

const
  CONFIG_FILE = 'registry.toml';
  CURRENT_STATE_FILE = 'state/current.toml';
  SIGNING_SEED_FILE = 'keys/root.seed';
  INITIALIZATION_MARKER = '.initializing';
  CHECKPOINT_DOMAIN = PROJECT_NAME + '-REGISTRY-CHECKPOINT-V1' + #10;
  CHECKPOINT_RENEWAL_THRESHOLD_HOURS = 24;

{$IFDEF REGISTRY_TESTING}
var
  RegistryFailurePointForTesting: string;
  RegistryPublicationReadyPathForTesting: string;
  RegistryPublicationReleasePathForTesting: string;
procedure InjectRegistryFailure(const APoint: string); forward;
{$ENDIF}

{$IFDEF MSWINDOWS}
const
  SDDL_REVISION_1_LWPT = 1;
  PRIVATE_FILE_SDDL = 'D:P(A;;FA;;;OW)(A;;FA;;;SY)';

function ConvertStringSecurityDescriptorToSecurityDescriptorW(
  AStringSecurityDescriptor: PWideChar; AStringSDRevision: LongWord;
  out ASecurityDescriptor: Pointer; ASecurityDescriptorSize: PLongWord): LongBool;
  stdcall; external 'advapi32.dll'
  name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';
{$ENDIF}
{$IFDEF UNIX}
function CFSync(AHandle: cint): cint; cdecl; external name 'fsync';
{$ENDIF}

constructor ELWPTRegistryError.CreateStable(const ACode, AMessage: string);
begin
  inherited Create(ACode + ': ' + AMessage);
end;

function Bytes(const AValue: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AValue);
end;

function Text(const ABytes: TBytes): string;
begin
  Result := TEncoding.UTF8.GetString(ABytes);
end;

function RegistryTimestampNow: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

procedure ValidateRegistryPath(const APath: string);
var
  Current, Parent: string;
begin
  Current := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
  if Current = '' then
    raise ELWPTRegistryError.CreateStable('invalid_registry_path',
      'registry path is empty');
  while True do
  begin
    if IsDirSymlinkOrJunction(Current) then
      raise ELWPTRegistryError.CreateStable('registry_path_link',
        'registry paths cannot contain symbolic links or reparse points');
    Parent := ExcludeTrailingPathDelimiter(ExtractFileDir(Current));
    if (Parent = '') or (Parent = Current) then Break;
    Current := Parent;
  end;
end;

procedure AtomicCreatePrivateBytes(const ADestination, ATemporaryRoot: string;
  const ABytes: TBytes);
var
  Temporary: string;
  {$IFDEF UNIX}
  Descriptor, Written, Offset: Integer;
  FileInfo: Stat;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  BytesWritten: LongWord;
  Handle: THandle;
  SecurityAttributes: TSecurityAttributes;
  SecurityDescriptor: Pointer;
  {$ENDIF}
begin
  ValidateRegistryPath(ADestination);
  ValidateRegistryPath(ATemporaryRoot);
  if FileExists(ADestination) or IsDirSymlinkOrJunction(ADestination) then
    raise ELWPTRegistryError.CreateStable('private_key_exists',
      'refusing to replace an existing registry signing seed');
  ForceDirectories(ExtractFileDir(ADestination));
  ForceDirectories(ATemporaryRoot);
  Temporary := MakeTmpPath(ATemporaryRoot, 'private-key');
  {$IFDEF UNIX}
  Descriptor := FpOpen(PChar(Temporary), O_WRONLY or O_CREAT or O_EXCL,
    &600);
  if Descriptor < 0 then
    raise ELWPTRegistryError.CreateStable('private_key_permissions',
      'could not create private registry key staging with mode 0600');
  try
    Offset := 0;
    while Offset < Length(ABytes) do
    begin
      Written := FpWrite(Descriptor, ABytes[Offset], Length(ABytes) - Offset);
      if Written <= 0 then
        raise ELWPTRegistryError.CreateStable('private_key_write_failed',
          'could not write the complete registry signing seed');
      Inc(Offset, Written);
    end;
    if (FpChmod(Temporary, &600) <> 0) or (FpFStat(Descriptor, FileInfo) <> 0)
      or ((FileInfo.st_mode and &777) <> &600) or (CFSync(Descriptor) <> 0) then
      raise ELWPTRegistryError.CreateStable('private_key_permissions',
        'registry signing seed mode 0600 could not be guaranteed');
  finally
    FpClose(Descriptor);
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  SecurityDescriptor := nil;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorW(
    PWideChar(UnicodeString(PRIVATE_FILE_SDDL)), SDDL_REVISION_1_LWPT,
    SecurityDescriptor, nil) then
    raise ELWPTRegistryError.CreateStable('private_key_permissions',
      'could not create the private registry key ACL');
  try
    FillChar(SecurityAttributes, SizeOf(SecurityAttributes), 0);
    SecurityAttributes.nLength := SizeOf(SecurityAttributes);
    SecurityAttributes.lpSecurityDescriptor := SecurityDescriptor;
    Handle := Windows.CreateFileW(PWideChar(UnicodeString(Temporary)),
      GENERIC_WRITE, 0, @SecurityAttributes, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_WRITE_THROUGH, 0);
    if Handle = INVALID_HANDLE_VALUE then
      raise ELWPTRegistryError.CreateStable('private_key_permissions',
        'could not create private registry key staging with an owner-only ACL');
    try
      BytesWritten := 0;
      if (Length(ABytes) > 0) and (not Windows.WriteFile(Handle, ABytes[0],
        Length(ABytes), BytesWritten, nil) or
        (BytesWritten <> LongWord(Length(ABytes)))) then
        raise ELWPTRegistryError.CreateStable('private_key_write_failed',
          'could not write the complete registry signing seed');
      if not Windows.FlushFileBuffers(Handle) then
        raise ELWPTRegistryError.CreateStable('private_key_write_failed',
          'could not commit the private registry signing seed');
    finally
      Windows.CloseHandle(Handle);
    end;
  finally
    Windows.LocalFree(HLOCAL(SecurityDescriptor));
  end;
  {$ENDIF}
  try
    if not AtomicReplaceFile(Temporary, ADestination) then
      raise ELWPTRegistryError.CreateStable('private_key_write_failed',
        'could not atomically commit the private registry signing seed');
  except
    SysUtils.DeleteFile(Temporary);
    raise;
  end;
end;

function PersistedTOMLQuote(const AValue: string): string;
var
  Character: Char;
begin
  Result := '"';
  for Character in AValue do
    case Character of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31, #127:
        raise ELWPTRegistryError.CreateStable('invalid_configuration',
          'control characters are not permitted in persisted registry state');
      else Result := Result + Character;
    end;
  Result := Result + '"';
end;

function RegistryTOMLQuote(const AValue: string): string;
var
  Character: Char;
begin
  Result := '"';
  for Character in AValue do
    case Character of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31, #127:
        Result := Result + '\u00' + LowerCase(IntToHex(Ord(Character), 2));
      else Result := Result + Character;
    end;
  Result := Result + '"';
end;

function RegistryIndexStoragePath(const AName: string): string;
begin
  Result := 'indexes/sha256/' + SHA256Hex(Bytes(AName)) + '.toml';
end;

function Unquote(const AValue: string): string;
var
  Index: Integer;
begin
  if (Length(AValue) < 2) or (AValue[1] <> '"')
    or (AValue[Length(AValue)] <> '"') then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'expected a quoted TOML string');
  Result := '';
  Index := 2;
  while Index < Length(AValue) do
  begin
    if AValue[Index] <> '\' then
      Result := Result + AValue[Index]
    else
    begin
      Inc(Index);
      if Index >= Length(AValue) then
        raise ELWPTRegistryError.CreateStable('state_corrupt', 'truncated TOML escape');
      case AValue[Index] of
        '"', '\': Result := Result + AValue[Index];
        'b': Result := Result + #8;
        't': Result := Result + #9;
        'n': Result := Result + #10;
        'f': Result := Result + #12;
        'r': Result := Result + #13;
        else raise ELWPTRegistryError.CreateStable('state_corrupt', 'unsupported TOML escape');
      end;
    end;
    Inc(Index);
  end;
end;

function ReadBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  if not FileExists(APath) then
    raise ELWPTRegistryError.CreateStable('state_missing', 'required file is missing: ' + APath);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > High(Integer) then
      raise ELWPTRegistryError.CreateStable('state_corrupt', 'file exceeds supported size: ' + APath);
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function ReadText(const APath: string): string;
begin
  Result := Text(ReadBytes(APath));
end;

function KeyValue(const ADocument, AKey: string): string;
var
  Line, Prefix: string;
  Lines: TStringList;
begin
  Prefix := AKey + ' = ';
  Lines := TStringList.Create;
  try
    Lines.Text := ADocument;
    for Line in Lines do
      if StartsText(Prefix, Line) then
        Exit(Copy(Line, Length(Prefix) + 1, MaxInt));
  finally
    Lines.Free;
  end;
  raise ELWPTRegistryError.CreateStable('state_corrupt', 'missing field ' + AKey);
end;

function StringValue(const ADocument, AKey: string): string;
begin
  Result := Unquote(KeyValue(ADocument, AKey));
end;

function UIntValue(const ADocument, AKey: string): QWord;
var
  Raw: string;
begin
  Raw := KeyValue(ADocument, AKey);
  if not TryStrToQWord(Raw, Result) then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid non-negative integer field ' + AKey);
end;

function IsLowerHex(const AValue: string; const ALength: Integer): Boolean;
var
  Character: Char;
begin
  if Length(AValue) <> ALength then Exit(False);
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
  Result := True;
end;

function IsSHA256(const AValue: string): Boolean;
begin
  Result := StartsStr('sha256:', AValue)
    and IsLowerHex(Copy(AValue, 8, MaxInt), 64);
end;

function RegistryKeyStoragePath(const AKeyID: string): string;
var
  Digest: string;
begin
  if not StartsStr('ed25519:', AKeyID) then
    raise ELWPTRegistryError.CreateStable('key_invalid',
      'registry key identifier must use Ed25519');
  Digest := Copy(AKeyID, Length('ed25519:') + 1, MaxInt);
  if not IsLowerHex(Digest, 64) then
    raise ELWPTRegistryError.CreateStable('key_invalid',
      'registry key identifier has an invalid digest');
  { The protocol identifier contains a colon, which is not a valid Windows
    filename character. Disk paths retain only its already-typed digest. }
  Result := 'keys/ed25519-' + Digest + '.toml';
end;

function HexDigit(const ACharacter: Char): Integer;
begin
  case ACharacter of
    '0'..'9': Result := Ord(ACharacter) - Ord('0');
    'a'..'f': Result := Ord(ACharacter) - Ord('a') + 10;
    'A'..'F': Result := Ord(ACharacter) - Ord('A') + 10;
    else Result := -1;
  end;
end;

function IsUnreserved(const ACharacter: Char): Boolean;
begin
  Result := (ACharacter in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~']);
end;

function CanonicalPercentEncoding(const AValue: string): string;
const
  HEX = '0123456789ABCDEF';
var
  Decoded: Char;
  HighNibble, Index, LowNibble: Integer;
begin
  Result := '';
  Index := 1;
  while Index <= Length(AValue) do
  begin
    if AValue[Index] <> '%' then
    begin
      Result := Result + AValue[Index];
      Inc(Index);
      Continue;
    end;
    if Index + 2 > Length(AValue) then
      raise ELWPTRegistryError.CreateStable('invalid_url', 'truncated percent encoding');
    HighNibble := HexDigit(AValue[Index + 1]);
    LowNibble := HexDigit(AValue[Index + 2]);
    if (HighNibble < 0) or (LowNibble < 0) then
      raise ELWPTRegistryError.CreateStable('invalid_url', 'invalid percent encoding');
    Decoded := Char(HighNibble shl 4 or LowNibble);
    if IsUnreserved(Decoded) then
      Result := Result + Decoded
    else
      Result := Result + '%' + HEX[HighNibble + 1] + HEX[LowNibble + 1];
    Inc(Index, 3);
  end;
end;

function RemoveDotSegments(const APath: string): string;
var
  Input, Output, Segment: string;
  Slash: SizeInt;

  procedure RemoveLastSegment;
  var
    LastSlash: SizeInt;
  begin
    LastSlash := LastDelimiter('/', Output);
    if LastSlash > 0 then Delete(Output, LastSlash, MaxInt)
    else Output := '';
  end;
begin
  Input := APath;
  Output := '';
  while Input <> '' do
  begin
    if StartsStr('../', Input) then Delete(Input, 1, 3)
    else if StartsStr('./', Input) then Delete(Input, 1, 2)
    else if StartsStr('/./', Input) then Delete(Input, 1, 2)
    else if Input = '/.' then Input := '/'
    else if StartsStr('/../', Input) then
    begin
      Delete(Input, 1, 3);
      RemoveLastSegment;
    end
    else if Input = '/..' then
    begin
      Input := '/';
      RemoveLastSegment;
    end
    else if (Input = '.') or (Input = '..') then Input := ''
    else
    begin
      if Input[1] = '/' then
        Slash := PosEx('/', Input, 2)
      else Slash := Pos('/', Input);
      if Slash = 0 then
      begin
        Segment := Input;
        Input := '';
      end
      else
      begin
        Segment := Copy(Input, 1, Slash - 1);
        Delete(Input, 1, Slash - 1);
      end;
      Output := Output + Segment;
    end;
  end;
  Result := Output;
end;

function RFC5952(const AAddress: in6_addr): string;
var
  BestLength, BestStart, CurrentLength, CurrentStart, Index: Integer;
  Groups: array[0..7] of Word;
begin
  for Index := 0 to 7 do Groups[Index] :=
    Word(AAddress.u6_addr8[Index * 2]) shl 8
    or Word(AAddress.u6_addr8[Index * 2 + 1]);
  BestStart := -1;
  BestLength := 0;
  Index := 0;
  while Index < 8 do
  begin
    if Groups[Index] <> 0 then
    begin
      Inc(Index);
      Continue;
    end;
    CurrentStart := Index;
    while (Index < 8) and (Groups[Index] = 0) do Inc(Index);
    CurrentLength := Index - CurrentStart;
    if (CurrentLength >= 2) and (CurrentLength > BestLength) then
    begin
      BestStart := CurrentStart;
      BestLength := CurrentLength;
    end;
  end;
  Result := '';
  Index := 0;
  while Index < 8 do
  begin
    if Index = BestStart then
    begin
      Result := Result + '::';
      Inc(Index, BestLength);
      Continue;
    end;
    if (Result <> '') and (Result[Length(Result)] <> ':') then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(Groups[Index], 1));
    Inc(Index);
  end;
end;

function CanonicalHost(const AHost: string): string;
var
  Address4: in_addr;
  AllIPv4Characters: Boolean;
  Character: Char;
  LabelValue: string;
  Labels: TStringList;
  Index: Integer;
begin
  if AHost = '' then
    raise ELWPTRegistryError.CreateStable('invalid_url',
      'registry URL host is empty');
  AllIPv4Characters := True;
  for Character in AHost do
  begin
    if Ord(Character) > 127 then
      raise ELWPTRegistryError.CreateStable('invalid_url',
        'registry URL host must be ASCII');
    if not (Character in ['0'..'9', '.']) then AllIPv4Characters := False;
  end;
  if AllIPv4Characters then
  begin
    if not TryStrToHostAddr(AHost, Address4) then
      raise ELWPTRegistryError.CreateStable('invalid_url',
        'registry IPv4 host is invalid');
    Exit(HostAddrToStr(Address4));
  end;
  Labels := TStringList.Create;
  try
    Labels.Delimiter := '.';
    Labels.StrictDelimiter := True;
    Labels.DelimitedText := LowerCase(AHost);
    for Index := 0 to Labels.Count - 1 do
    begin
      LabelValue := Labels[Index];
      if (LabelValue = '') or (Length(LabelValue) > 63)
        or (LabelValue[1] = '-') or (LabelValue[Length(LabelValue)] = '-') then
        raise ELWPTRegistryError.CreateStable('invalid_url',
          'registry DNS host has an invalid label');
      for Character in LabelValue do
        if not (Character in ['a'..'z', '0'..'9', '-']) then
          raise ELWPTRegistryError.CreateStable('invalid_url',
            'registry DNS host has an invalid character');
    end;
  finally
    Labels.Free;
  end;
  Result := LowerCase(AHost);
end;

function CanonicalRegistryURL(const AValue: string;
  const ARequireHTTPS: Boolean): string;
var
  Authority, Host, Path, Port, Scheme: string;
  Address6: in6_addr;
  Character: Char;
  BracketEnd, Colon, Slash: Integer;
begin
  for Character in AValue do
    if (Ord(Character) <= 32) or (Character = '"') or (Character = '\') then
      raise ELWPTRegistryError.CreateStable('invalid_url',
        'registry URL contains a forbidden character');
  if Pos('://', AValue) = 0 then
    raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL must be absolute');
  Scheme := LowerCase(Copy(AValue, 1, Pos('://', AValue) - 1));
  if not ((Scheme = 'https') or (Scheme = 'http')) then
    raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL scheme must be https or http');
  if ARequireHTTPS and (Scheme <> 'https') then
    raise ELWPTRegistryError.CreateStable('invalid_identity', 'explicit origin identity must use https');
  Authority := Copy(AValue, Pos('://', AValue) + 3, MaxInt);
  if (Pos('?', Authority) > 0) or (Pos('#', Authority) > 0)
    or (Pos('@', Authority) > 0) then
    raise ELWPTRegistryError.CreateStable('invalid_url', 'user information, query, and fragment are forbidden');
  Slash := Pos('/', Authority);
  if Slash > 0 then
  begin
    Path := Copy(Authority, Slash, MaxInt);
    Authority := Copy(Authority, 1, Slash - 1);
  end
  else Path := '';
  if Authority = '' then raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL host is empty');
  Port := '';
  if Authority[1] = '[' then
  begin
    BracketEnd := Pos(']', Authority);
    if BracketEnd = 0 then raise ELWPTRegistryError.CreateStable('invalid_url', 'invalid bracketed IPv6 host');
    Host := Copy(Authority, 2, BracketEnd - 2);
    if not TryStrToHostAddr6(Host, Address6) then
      raise ELWPTRegistryError.CreateStable('invalid_url',
        'registry IPv6 host is invalid');
    Host := '[' + RFC5952(Address6) + ']';
    if Length(Authority) > BracketEnd then
    begin
      if Authority[BracketEnd + 1] <> ':' then
        raise ELWPTRegistryError.CreateStable('invalid_url', 'invalid authority after IPv6 host');
      Port := Copy(Authority, BracketEnd + 2, MaxInt);
    end;
  end
  else
  begin
    Colon := LastDelimiter(':', Authority);
    if Colon > 0 then
    begin
      Host := LowerCase(Copy(Authority, 1, Colon - 1));
      Port := Copy(Authority, Colon + 1, MaxInt);
    end
    else Host := Authority;
  end;
  if (Host <> '') and (Host[1] <> '[') then Host := CanonicalHost(Host);
  if Port <> '' then
  begin
    if (StrToIntDef(Port, 0) < 1) or (StrToIntDef(Port, 0) > 65535) then
      raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL port is invalid');
    Port := IntToStr(StrToInt(Port));
    if ((Scheme = 'https') and (Port = '443'))
      or ((Scheme = 'http') and (Port = '80')) then Port := '';
  end;
  if (Scheme = 'http') and (Host <> 'localhost') then
    raise ELWPTRegistryError.CreateStable('insecure_transport',
      'plain HTTP is permitted only for the exact host localhost');
  Path := RemoveDotSegments(CanonicalPercentEncoding(Path));
  Result := Scheme + '://' + Host;
  if Port <> '' then Result := Result + ':' + Port;
  if Path <> '/' then Result := Result + Path;
end;

function IsLoopbackListenAddress(const AValue: string): Boolean;
begin
  Result := SameText(AValue, 'localhost') or (AValue = '127.0.0.1');
end;

function IsAbsoluteFilesystemPath(const AValue: string): Boolean;
begin
  {$IFDEF UNIX}
  Result := (AValue <> '') and (AValue[1] = PathDelim);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := (Length(AValue) >= 3) and (AValue[2] = ':')
    and (AValue[3] in ['\', '/']);
  if not Result then Result := StartsStr('\\', AValue);
  {$ENDIF}
end;

function RegistryConfiguration(const AIdentity, ABaseURL,
  AListenAddress: string; const APort: Word; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string): TLWPTRegistryConfig;
begin
  Result.Identity := AIdentity;
  Result.BaseURL := ABaseURL;
  Result.ListenAddress := AListenAddress;
  Result.Port := APort;
  Result.TLSPKCS12Path := ATLSPKCS12Path;
  Result.TLSPasswordEnvironment := ATLSPasswordEnvironment;
end;

procedure ValidatePersistedConfigurationString(const AValue: string);
var
  Character: Char;
begin
  for Character in AValue do
    if Character in [#0..#31, #127] then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        'control characters are not permitted in registry configuration');
end;

procedure ValidatePersistedConfigurationStrings(
  const AConfig: TLWPTRegistryConfig);
begin
  ValidatePersistedConfigurationString(AConfig.Identity);
  ValidatePersistedConfigurationString(AConfig.BaseURL);
  ValidatePersistedConfigurationString(AConfig.ListenAddress);
  ValidatePersistedConfigurationString(AConfig.TLSPKCS12Path);
  ValidatePersistedConfigurationString(AConfig.TLSPasswordEnvironment);
end;

procedure ValidateRegistryConfiguration(const AConfig: TLWPTRegistryConfig);
var
  BaseURL, Identity: string;
begin
  ValidatePersistedConfigurationStrings(AConfig);
  BaseURL := CanonicalRegistryURL(AConfig.BaseURL, False);
  if BaseURL <> AConfig.BaseURL then
    raise ELWPTRegistryError.CreateStable('invalid_url', 'base URL is not canonical; use ' + BaseURL);
  Identity := CanonicalRegistryURL(AConfig.Identity,
    AConfig.Identity <> AConfig.BaseURL);
  if Identity <> AConfig.Identity then
    raise ELWPTRegistryError.CreateStable('invalid_identity', 'origin identity is not canonical; use ' + Identity);
  if (AConfig.ListenAddress = '') or (AConfig.Port = 0) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration', 'listen address and port are required');
  {$IFNDEF DARWIN}
  if not SameText(AConfig.ListenAddress, 'localhost')
    and (StrToNetAddr(AConfig.ListenAddress).s_addr = LongWord(-1)) then
    raise ELWPTRegistryError.CreateStable('invalid_listen_address',
      'listen address must be localhost or an IPv4 address on this platform');
  {$ENDIF}
  if StartsText('http://', AConfig.BaseURL)
    and not IsLoopbackListenAddress(AConfig.ListenAddress) then
    raise ELWPTRegistryError.CreateStable('insecure_transport',
      'plain HTTP registry must bind only to localhost or a loopback address');
  if StartsText('https://', AConfig.BaseURL) then
  begin
    if AConfig.TLSPKCS12Path = '' then
      raise ELWPTRegistryError.CreateStable('tls_configuration', 'HTTPS requires a PKCS#12 path');
    if AConfig.TLSPasswordEnvironment = '' then
      raise ELWPTRegistryError.CreateStable('tls_configuration', 'HTTPS requires a password environment name');
    if not IsAbsoluteFilesystemPath(AConfig.TLSPKCS12Path) then
      raise ELWPTRegistryError.CreateStable('tls_configuration',
        'HTTPS PKCS#12 path must be absolute in persisted configuration');
  end;
end;

function ConfigDocument(const AConfig: TLWPTRegistryConfig): string;
begin
  Result := 'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
    + '-registry-origin-config-v1') + #10
    + 'identity = ' + PersistedTOMLQuote(AConfig.Identity) + #10
    + 'base_url = ' + PersistedTOMLQuote(AConfig.BaseURL) + #10
    + 'listen_address = ' + PersistedTOMLQuote(AConfig.ListenAddress) + #10
    + 'port = ' + IntToStr(AConfig.Port) + #10
    + 'tls_pkcs12 = ' + PersistedTOMLQuote(AConfig.TLSPKCS12Path) + #10
    + 'tls_password_env = '
    + PersistedTOMLQuote(AConfig.TLSPasswordEnvironment) + #10;
end;

function ParseConfig(const ADocument: string): TLWPTRegistryConfig;
var
  PortValue: QWord;
begin
  if StringValue(ADocument, 'schema') <> PROGRAM_NAME
    + '-registry-origin-config-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'unsupported registry configuration schema');
  Result.Identity := StringValue(ADocument, 'identity');
  Result.BaseURL := StringValue(ADocument, 'base_url');
  Result.ListenAddress := StringValue(ADocument, 'listen_address');
  PortValue := UIntValue(ADocument, 'port');
  if PortValue > High(Word) then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'registry port is out of range');
  Result.Port := PortValue;
  Result.TLSPKCS12Path := StringValue(ADocument, 'tls_pkcs12');
  Result.TLSPasswordEnvironment := StringValue(ADocument,
    'tls_password_env');
  ValidateRegistryConfiguration(Result);
end;

function TimestampPlusSevenDays(const AValue: string): string;
var
  Parsed: TDateTime;
begin
  if not TryISO8601ToDate(AValue, Parsed, True) then
    raise ELWPTRegistryError.CreateStable('invalid_timestamp', 'published_at must be RFC 3339 UTC');
  if FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Parsed) <> AValue then
    raise ELWPTRegistryError.CreateStable('invalid_timestamp',
      'published_at must use whole UTC seconds and the Z suffix');
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', IncDay(Parsed, 7));
end;

function SnapshotDocument(const AOrigin: string; const ASequence: QWord;
  const APublishedAt, APrevious: string; const ARecords: TStrings): string;
var
  Index: Integer;
begin
  Result := 'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
    + '-registry-snapshot-v1') + #10
    + 'origin = ' + PersistedTOMLQuote(AOrigin) + #10
    + 'sequence = ' + UIntToStr(ASequence) + #10
    + 'published_at = ' + PersistedTOMLQuote(APublishedAt) + #10
    + 'previous = ' + PersistedTOMLQuote(APrevious) + #10
    + 'records = [';
  for Index := 0 to ARecords.Count - 1 do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + PersistedTOMLQuote(ARecords[Index]);
  end;
  Result := Result + ']' + #10;
end;

function ReadStringArray(const ADocument, AKey,
  ADescription: string): TStringList;
var
  ArrayValue, Item: string;
  Index: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupError;
  ArrayValue := Trim(KeyValue(ADocument, AKey));
  if (Length(ArrayValue) < 2) or (ArrayValue[1] <> '[')
    or (ArrayValue[Length(ArrayValue)] <> ']') then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      ADescription + ' must be an array');
  ArrayValue := Copy(ArrayValue, 2, Length(ArrayValue) - 2);
  Index := 1;
  while Index <= Length(ArrayValue) do
  begin
    while (Index <= Length(ArrayValue)) and (ArrayValue[Index] in [' ', ',']) do
      Inc(Index);
    if Index > Length(ArrayValue) then Break;
    if ArrayValue[Index] <> '"' then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        ADescription + ' item must be quoted');
    Item := '';
    Inc(Index);
    while (Index <= Length(ArrayValue)) and (ArrayValue[Index] <> '"') do
    begin
      Item := Item + ArrayValue[Index];
      Inc(Index);
    end;
    if Index > Length(ArrayValue) then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        'unterminated ' + ADescription + ' item');
    Inc(Index);
    Result.Add(Item);
  end;
end;

function ReadSnapshotRecords(const ADocument: string): TStringList;
begin
  Result := ReadStringArray(ADocument, 'records', 'snapshot records');
end;

function VersionIndexDocument(const AOrigin, AName: string;
  const AEntries: TStrings): string;
var
  Index: Integer;
begin
  Result := 'schema = '
    + PersistedTOMLQuote(PROGRAM_NAME + '-registry-version-index-v1') + #10
    + 'origin = ' + PersistedTOMLQuote(AOrigin) + #10
    + 'name = ' + PersistedTOMLQuote(AName) + #10
    + 'versions = [';
  for Index := 0 to AEntries.Count - 1 do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + PersistedTOMLQuote(AEntries[Index]);
  end;
  Result := Result + ']' + #10;
end;

function CheckpointDocument(const AOrigin: string; const ASequence: QWord;
  const ASnapshotHash, APublishedAt, AKeyID: string): string;
begin
  Result := 'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
    + '-registry-checkpoint-v1') + #10
    + 'origin = ' + PersistedTOMLQuote(AOrigin) + #10
    + 'sequence = ' + UIntToStr(ASequence) + #10
    + 'snapshot = ' + PersistedTOMLQuote(ASnapshotHash) + #10
    + 'published_at = ' + PersistedTOMLQuote(APublishedAt) + #10
    + 'expires_at = '
    + PersistedTOMLQuote(TimestampPlusSevenDays(APublishedAt)) + #10
    + 'key_id = ' + PersistedTOMLQuote(AKeyID) + #10;
end;

function SignatureDocument(const ACheckpoint: TBytes;
  const ASeed: TLWPTEd25519Seed; const AKeyID: string): string;
var
  SigningInput: TBytes;
  Signature: TLWPTEd25519Signature;
begin
  SigningInput := Bytes(CHECKPOINT_DOMAIN + Text(ACheckpoint));
  Ed25519Sign(SigningInput, ASeed, Signature);
  Result := 'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
    + '-registry-signature-v1') + #10
    + 'algorithm = "ed25519"' + #10
    + 'key_id = ' + PersistedTOMLQuote(AKeyID) + #10
    + 'payload = '
    + PersistedTOMLQuote('sha256:' + SHA256Hex(ACheckpoint)) + #10
    + 'signature = ' + PersistedTOMLQuote('hex:' + BytesToHex(Signature,
      SizeOf(Signature))) + #10;
end;

function StateDocument(const AState: TLWPTRegistryState): string;
begin
  Result := 'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
    + '-registry-state-v1') + #10
    + 'sequence = ' + UIntToStr(AState.Sequence) + #10
    + 'snapshot = ' + PersistedTOMLQuote(AState.SnapshotHash) + #10
    + 'checkpoint = ' + PersistedTOMLQuote(AState.CheckpointPath) + #10
    + 'signature = ' + PersistedTOMLQuote(AState.SignaturePath) + #10;
end;

function ParseState(const ADocument: string): TLWPTRegistryState;
begin
  if StringValue(ADocument, 'schema') <> PROGRAM_NAME
    + '-registry-state-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'unsupported committed-state schema');
  Result.Sequence := UIntValue(ADocument, 'sequence');
  Result.SnapshotHash := StringValue(ADocument, 'snapshot');
  Result.CheckpointPath := StringValue(ADocument, 'checkpoint');
  Result.SignaturePath := StringValue(ADocument, 'signature');
end;

constructor TLWPTRegistryStore.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ExpandFileName(ARoot);
  ValidateRegistryPath(FRoot);
  if FileExists(FRoot) and not DirectoryExists(FRoot) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_path',
      'registry data root is not a directory');
  if not FileExists(RootPath(CONFIG_FILE)) then
    raise ELWPTRegistryError.CreateStable('origin_not_initialized',
      'registry data directory is not initialized: ' + FRoot);
  FConfig := ParseConfig(ReadText(RootPath(CONFIG_FILE)));
  Recover;
end;

function TLWPTRegistryStore.RootPath(const ARelative: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot)
    + StringReplace(ARelative, '/', PathDelim, [rfReplaceAll]);
  ValidateRegistryPath(Result);
end;

function TLWPTRegistryStore.TmpRoot: string;
begin
  Result := RootPath('tmp');
end;

function TLWPTRegistryStore.LoadSeed: TBytes;
var
  Seed: TLWPTEd25519Seed;
begin
  if not HexToBytes(Trim(Text(LoadResource(SIGNING_SEED_FILE))), Seed,
    SizeOf(Seed)) then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'registry signing seed is invalid');
  SetLength(Result, SizeOf(Seed));
  Move(Seed[0], Result[0], SizeOf(Seed));
end;

procedure TLWPTRegistryStore.WriteImmutable(const ARelative: string;
  const ABytes: TBytes);
var
  Existing: TBytes;
begin
  if FileExists(RootPath(ARelative)) then
  begin
    Existing := ReadBytes(RootPath(ARelative));
    if (Length(Existing) <> Length(ABytes)) or ((Length(ABytes) > 0)
      and not CompareMem(@Existing[0], @ABytes[0], Length(ABytes))) then
      raise ELWPTRegistryError.CreateStable('immutable_conflict',
        'content-addressed path already contains different bytes: ' + ARelative);
    Exit;
  end;
  AtomicWriteBytes(RootPath(ARelative), TmpRoot, ABytes);
end;

function InitializationArtifact(const AName: string): Boolean;
begin
  Result := (AName = INITIALIZATION_MARKER) or (AName = 'tmp')
    or (AName = 'keys') or (AName = 'objects') or (AName = 'records')
    or (AName = 'snapshots') or (AName = 'checkpoints')
    or (AName = 'indexes') or (AName = 'state');
end;

procedure PrepareUnconfiguredRoot(const ARoot: string);
var
  Entries: TStringList;
  EntryPath: string;
  Search: TSearchRec;
  Index: Integer;
begin
  Entries := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(ARoot) + '*',
      faAnyFile or faSymLink, Search) = 0 then
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        if not InitializationArtifact(Search.Name) then
          raise ELWPTRegistryError.CreateStable('origin_directory_not_empty',
            'uninitialized registry root contains caller-owned entry '
            + Search.Name);
        Entries.Add(Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    if (Entries.Count > 0) and (Entries.IndexOf(INITIALIZATION_MARKER) < 0) then
      raise ELWPTRegistryError.CreateStable('origin_directory_not_empty',
        'nonempty registry root has no initialization ownership marker');
    if Entries.Count > 0 then
    begin
      EntryPath := IncludeTrailingPathDelimiter(ARoot)
        + INITIALIZATION_MARKER;
      ValidateRegistryPath(EntryPath);
      if ReadText(EntryPath) <> 'registry initialization in progress' + #10 then
        raise ELWPTRegistryError.CreateStable('origin_directory_not_empty',
          'registry initialization ownership marker is invalid');
    end;
    for Index := 0 to Entries.Count - 1 do
    begin
      EntryPath := IncludeTrailingPathDelimiter(ARoot) + Entries[Index];
      ValidateRegistryPath(EntryPath);
      if not AtomicRemovePath(EntryPath) then
        raise ELWPTRegistryError.CreateStable('initialization_recovery_failed',
          'could not remove owned incomplete artifact ' + Entries[Index]);
    end;
  finally
    Entries.Free;
  end;
end;

class function TLWPTRegistryStore.Initialize(const ARoot: string;
  const ARequested: TLWPTRegistryConfig;
  const APublishedAt: string): TLWPTRegistryStore;
var
  Checkpoint, ConfigBytes, PublicKeyBytes, Signature, Snapshot: TBytes;
  Config: TLWPTRegistryConfig;
  Existing: TLWPTRegistryStore;
  KeyID, SnapshotHash: string;
  PublicKey: TLWPTEd25519PublicKey;
  Records: TStringList;
  Seed: TLWPTEd25519Seed;
  State: TLWPTRegistryState;
  RootDir, TemporaryRoot: string;
  InitCoordinator: TLWPTProducerLeaseCoordinator;
  InitLease: TLWPTProducerLease;

  function AtRoot(const ARelative: string): string;
  begin
    Result := IncludeTrailingPathDelimiter(RootDir)
      + StringReplace(ARelative, '/', PathDelim, [rfReplaceAll]);
    ValidateRegistryPath(Result);
  end;

  procedure WriteInitialImmutable(const ARelative: string;
    const ABytes: TBytes);
  begin
    if FileExists(AtRoot(ARelative)) then
      raise ELWPTRegistryError.CreateStable('immutable_conflict',
        'initial registry path already exists: ' + ARelative);
    AtomicWriteBytes(AtRoot(ARelative), TemporaryRoot, ABytes);
  end;
begin
  Result := nil;
  { Reject values that cannot be persisted and reopened before initialization
    acquires a lease or creates any registry-owned filesystem state. }
  ValidatePersistedConfigurationStrings(ARequested);
  RootDir := ExpandFileName(ARoot);
  ValidateRegistryPath(RootDir);
  if FileExists(RootDir) and not DirectoryExists(RootDir) then
    raise ELWPTRegistryError.CreateStable('invalid_registry_path',
      'registry data root is not a directory');
  TemporaryRoot := IncludeTrailingPathDelimiter(RootDir) + 'tmp';
  InitCoordinator := TLWPTProducerLeaseCoordinator.Create(
    IncludeTrailingPathDelimiter(GetTempDir) + PROGRAM_NAME
    + '-registry-initialization-leases');
  InitLease := nil;
  try
    InitLease := InitCoordinator.TryAcquire(RootDir,
      'registry initialization and reconfiguration');
    if not Assigned(InitLease) then
      raise ELWPTRegistryError.CreateStable('initialization_locked',
        'another process is initializing or reconfiguring this origin');
    ForceDirectories(RootDir);
    ValidateRegistryPath(RootDir);
    if not FileExists(IncludeTrailingPathDelimiter(RootDir) + CONFIG_FILE) then
      PrepareUnconfiguredRoot(RootDir);
    ForceDirectories(RootDir);
    if FileExists(IncludeTrailingPathDelimiter(RootDir) + CONFIG_FILE) then
    begin
      Existing := TLWPTRegistryStore.Create(ARoot);
      try
        if FileExists(AtRoot(INITIALIZATION_MARKER)) then
        begin
          if not SysUtils.DeleteFile(AtRoot(INITIALIZATION_MARKER)) then
            raise ELWPTRegistryError.CreateStable(
              'initialization_recovery_failed',
              'could not reconcile committed origin initialization marker');
        end;
        Config := ARequested;
        if Config.Identity = '' then Config.Identity := Existing.Config.Identity;
        Config.BaseURL := CanonicalRegistryURL(Config.BaseURL, False);
        Config.Identity := CanonicalRegistryURL(Config.Identity,
          Config.Identity <> Config.BaseURL);
        if Config.TLSPKCS12Path <> '' then
          Config.TLSPKCS12Path := ExpandFileName(Config.TLSPKCS12Path);
        if Config.Identity <> Existing.Config.Identity then
          raise ELWPTRegistryError.CreateStable('identity_conflict',
            'initialized origin identity cannot be changed');
        ValidateRegistryConfiguration(Config);
        AtomicWriteBytes(Existing.RootPath(CONFIG_FILE), Existing.TmpRoot,
          Bytes(ConfigDocument(Config)));
      finally
        Existing.Free;
      end;
      Exit(TLWPTRegistryStore.Create(ARoot));
    end;
    Config := ARequested;
    Config.BaseURL := CanonicalRegistryURL(Config.BaseURL, False);
    if Config.Identity = '' then Config.Identity := Config.BaseURL
    else Config.Identity := CanonicalRegistryURL(Config.Identity, True);
    if Config.TLSPKCS12Path <> '' then
      Config.TLSPKCS12Path := ExpandFileName(Config.TLSPKCS12Path);
    ValidateRegistryConfiguration(Config);
    TimestampPlusSevenDays(APublishedAt);
    ForceDirectories(TemporaryRoot);
    AtomicWriteBytes(AtRoot(INITIALIZATION_MARKER), TemporaryRoot,
      Bytes('registry initialization in progress' + #10));
    ConfigBytes := Bytes(ConfigDocument(Config));
    GenerateEd25519Seed(Seed);
    AtomicCreatePrivateBytes(AtRoot(SIGNING_SEED_FILE), TemporaryRoot,
      Bytes(BytesToHex(Seed, SizeOf(Seed)) + #10));
    try
      Ed25519PublicKey(Seed, PublicKey);
      SetLength(PublicKeyBytes, SizeOf(PublicKey));
      Move(PublicKey[0], PublicKeyBytes[0], SizeOf(PublicKey));
      KeyID := 'ed25519:' + SHA256Hex(PublicKeyBytes);
      WriteInitialImmutable(RegistryKeyStoragePath(KeyID), Bytes(
        'schema = ' + PersistedTOMLQuote(PROGRAM_NAME
        + '-registry-key-v1') + #10
        + 'origin = ' + PersistedTOMLQuote(Config.Identity) + #10
        + 'key_id = ' + PersistedTOMLQuote(KeyID) + #10
        + 'algorithm = "ed25519"' + #10
        + 'public_key = ' + PersistedTOMLQuote('hex:' + BytesToHex(PublicKey,
          SizeOf(PublicKey))) + #10
        + 'valid_from_sequence = 1' + #10));
      Records := TStringList.Create;
      try
        Snapshot := Bytes(SnapshotDocument(Config.Identity, 1,
          APublishedAt, '', Records));
      finally
        Records.Free;
      end;
      SnapshotHash := 'sha256:' + SHA256Hex(Snapshot);
      WriteInitialImmutable('snapshots/sha256/'
        + Copy(SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml', Snapshot);
      Checkpoint := Bytes(CheckpointDocument(Config.Identity, 1, SnapshotHash,
        APublishedAt, KeyID));
      Signature := Bytes(SignatureDocument(Checkpoint, Seed, KeyID));
      WriteInitialImmutable('checkpoints/1.toml', Checkpoint);
      WriteInitialImmutable('checkpoints/1.sig.toml', Signature);
      State.Sequence := 1;
      State.SnapshotHash := SnapshotHash;
      State.CheckpointPath := 'checkpoints/1.toml';
      State.SignaturePath := 'checkpoints/1.sig.toml';
      AtomicWriteBytes(AtRoot(CURRENT_STATE_FILE), TemporaryRoot,
        Bytes(StateDocument(State)));
      AtomicWriteBytes(AtRoot(CONFIG_FILE), TemporaryRoot, ConfigBytes);
      {$IFDEF REGISTRY_TESTING}
      InjectRegistryFailure('initialization-activation');
      {$ENDIF}
      SysUtils.DeleteFile(AtRoot(INITIALIZATION_MARKER));
      Result := TLWPTRegistryStore.Create(ARoot);
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    FillChar(Seed, SizeOf(Seed), 0);
    InitLease.Free;
    InitCoordinator.Free;
  end;
end;

procedure TLWPTRegistryStore.VerifyState(const AState: TLWPTRegistryState);
var
  CheckpointBytes, KeyBytes, SignatureBytes, SigningInput: TBytes;
  CheckpointDocumentText, KeyDocumentText, SignatureDocumentText: string;
  KeyID, Payload, PublicKeyHex, PublishedAt, SignatureHex: string;
  PublicKey: TLWPTEd25519PublicKey;
  Signature: TLWPTEd25519Signature;
  ExpectedCheckpointHash, RenewalPrefix: string;
begin
  if not IsSHA256(AState.SnapshotHash) then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'committed snapshot hash is invalid');
  RenewalPrefix := 'checkpoints/renewals/sha256/';
  if AState.CheckpointPath = 'checkpoints/' + UIntToStr(AState.Sequence)
    + '.toml' then
  begin
    if AState.SignaturePath <> 'checkpoints/' + UIntToStr(AState.Sequence)
      + '.sig.toml' then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        'committed signature path is invalid');
  end
  else
  begin
    if not StartsStr(RenewalPrefix, AState.CheckpointPath)
      or not EndsStr('.toml', AState.CheckpointPath) then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        'committed checkpoint path is invalid');
    ExpectedCheckpointHash := Copy(AState.CheckpointPath,
      Length(RenewalPrefix) + 1,
      Length(AState.CheckpointPath) - Length(RenewalPrefix) - 5);
    if not IsSHA256('sha256:' + ExpectedCheckpointHash)
      or (AState.SignaturePath <> RenewalPrefix + ExpectedCheckpointHash
        + '.sig.toml') then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        'committed renewal paths are invalid');
  end;
  if SHA256BytesPrefixed(LoadResource('snapshots/sha256/'
    + Copy(AState.SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml'))
    <> AState.SnapshotHash then
    raise ELWPTRegistryError.CreateStable('snapshot_hash_mismatch',
      'committed snapshot bytes do not match the activation pointer');
  CheckpointBytes := LoadResource(AState.CheckpointPath);
  SignatureBytes := LoadResource(AState.SignaturePath);
  if StartsStr(RenewalPrefix, AState.CheckpointPath)
    and (SHA256Hex(CheckpointBytes) <> ExpectedCheckpointHash) then
    raise ELWPTRegistryError.CreateStable('checkpoint_hash_mismatch',
      'committed renewal checkpoint bytes do not match their path');
  CheckpointDocumentText := Text(CheckpointBytes);
  SignatureDocumentText := Text(SignatureBytes);
  if StringValue(CheckpointDocumentText, 'schema') <> PROGRAM_NAME
    + '-registry-checkpoint-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'unsupported checkpoint schema');
  if StringValue(CheckpointDocumentText, 'origin') <> FConfig.Identity then
    raise ELWPTRegistryError.CreateStable('checkpoint_origin_mismatch',
      'checkpoint origin differs from the configured identity');
  if UIntValue(CheckpointDocumentText, 'sequence') <> AState.Sequence then
    raise ELWPTRegistryError.CreateStable('checkpoint_state_mismatch',
      'checkpoint sequence differs from committed state');
  if StringValue(CheckpointDocumentText, 'snapshot') <> AState.SnapshotHash then
    raise ELWPTRegistryError.CreateStable('checkpoint_state_mismatch',
      'checkpoint snapshot differs from committed state');
  PublishedAt := StringValue(CheckpointDocumentText, 'published_at');
  if StringValue(CheckpointDocumentText, 'expires_at')
    <> TimestampPlusSevenDays(PublishedAt) then
    raise ELWPTRegistryError.CreateStable('checkpoint_expiry_invalid',
      'checkpoint expiry is not seven days after publication');
  KeyID := StringValue(CheckpointDocumentText, 'key_id');
  if StringValue(SignatureDocumentText, 'key_id') <> KeyID then
    raise ELWPTRegistryError.CreateStable('signature_key_mismatch',
      'checkpoint and signature name different keys');
  if StringValue(SignatureDocumentText, 'schema') <> PROGRAM_NAME
    + '-registry-signature-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'unsupported signature schema');
  if StringValue(SignatureDocumentText, 'algorithm') <> 'ed25519' then
    raise ELWPTRegistryError.CreateStable('signature_invalid',
      'checkpoint signature algorithm is unsupported');
  Payload := StringValue(SignatureDocumentText, 'payload');
  if Payload <> SHA256BytesPrefixed(CheckpointBytes) then
    raise ELWPTRegistryError.CreateStable('signature_payload_mismatch',
      'signature payload does not match checkpoint bytes');
  KeyBytes := LoadResource(RegistryKeyStoragePath(KeyID));
  KeyDocumentText := Text(KeyBytes);
  if StringValue(KeyDocumentText, 'schema') <> PROGRAM_NAME
    + '-registry-key-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'unsupported registry key schema');
  if StringValue(KeyDocumentText, 'origin') <> FConfig.Identity then
    raise ELWPTRegistryError.CreateStable('key_origin_mismatch',
      'registry key origin differs from the configured identity');
  if StringValue(KeyDocumentText, 'algorithm') <> 'ed25519' then
    raise ELWPTRegistryError.CreateStable('key_invalid',
      'registry key algorithm is unsupported');
  if StringValue(KeyDocumentText, 'key_id') <> KeyID then
    raise ELWPTRegistryError.CreateStable('key_id_mismatch', 'key record identifier does not match its path');
  PublicKeyHex := StringValue(KeyDocumentText, 'public_key');
  SignatureHex := StringValue(SignatureDocumentText, 'signature');
  if not StartsStr('hex:', PublicKeyHex)
    or not HexToBytes(Copy(PublicKeyHex, 5, MaxInt), PublicKey,
      SizeOf(PublicKey)) then
    raise ELWPTRegistryError.CreateStable('key_invalid', 'Ed25519 public key encoding is invalid');
  SetLength(KeyBytes, SizeOf(PublicKey));
  Move(PublicKey[0], KeyBytes[0], SizeOf(PublicKey));
  if KeyID <> 'ed25519:' + SHA256Hex(KeyBytes) then
    raise ELWPTRegistryError.CreateStable('key_id_mismatch',
      'registry key identifier does not match its public key');
  if not StartsStr('hex:', SignatureHex)
    or not HexToBytes(Copy(SignatureHex, 5, MaxInt), Signature,
      SizeOf(Signature)) then
    raise ELWPTRegistryError.CreateStable('signature_invalid', 'Ed25519 signature encoding is invalid');
  SigningInput := Bytes(CHECKPOINT_DOMAIN + Text(CheckpointBytes));
  if not Ed25519Verify(SigningInput, PublicKey, Signature) then
    raise ELWPTRegistryError.CreateStable('signature_invalid', 'checkpoint signature verification failed');
end;

procedure TLWPTRegistryStore.RecoverDerivedState(
  const AState: TLWPTRegistryState);
var
  ActiveIndexFiles, ActiveNames, Records, Versions: TStringList;
  Entry, FileName, Name, RecordHash, RecordText, Version: string;
  Index: Integer;
  Search: TSearchRec;
begin
  Records := ReadSnapshotRecords(Text(LoadResource('snapshots/sha256/'
    + Copy(AState.SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml')));
  ActiveNames := TStringList.Create;
  ActiveNames.Sorted := True;
  ActiveNames.Duplicates := dupIgnore;
  ActiveNames.OwnsObjects := True;
  ActiveIndexFiles := TStringList.Create;
  ActiveIndexFiles.Sorted := True;
  ActiveIndexFiles.Duplicates := dupIgnore;
  try
    for RecordHash in Records do
    begin
      if not IsSHA256(RecordHash) then
        raise ELWPTRegistryError.CreateStable('state_corrupt',
          'snapshot contains an invalid record hash');
      RecordText := Text(LoadResource('records/sha256/'
        + Copy(RecordHash, Length('sha256:') + 1, MaxInt) + '.toml'));
      if SHA256BytesPrefixed(Bytes(RecordText)) <> RecordHash then
        raise ELWPTRegistryError.CreateStable('record_hash_mismatch',
          'active package record bytes do not match their path');
      Name := StringValue(RecordText, 'name');
      Version := StringValue(RecordText, 'version');
      Index := ActiveNames.IndexOf(Name);
      if Index < 0 then
      begin
        Versions := TStringList.Create;
        Versions.Sorted := True;
        Versions.Duplicates := dupError;
        ActiveNames.AddObject(Name, Versions);
      end
      else Versions := TStringList(ActiveNames.Objects[Index]);
      Versions.Add(Version + '=' + RecordHash);
    end;
    ForceDirectories(RootPath('indexes/sha256'));
    for Index := 0 to ActiveNames.Count - 1 do
    begin
      Versions := TStringList(ActiveNames.Objects[Index]);
      Entry := VersionIndexDocument(FConfig.Identity, ActiveNames[Index],
        Versions);
      FileName := RegistryIndexStoragePath(ActiveNames[Index]);
      ActiveIndexFiles.Add(ExtractFileName(FileName));
      FileName := RootPath(FileName);
      if not FileExists(FileName) or (ReadText(FileName) <> Entry) then
        AtomicWriteBytes(FileName, TmpRoot, Bytes(Entry));
    end;
    { Indexes are internal derived state. Remove the pre-hash layout rather
      than retaining aliases that are not portable to every release host. }
    if FindFirst(RootPath('indexes/*.toml'), faAnyFile, Search) = 0 then
    try
      repeat
        if not SysUtils.DeleteFile(RootPath('indexes/' + Search.Name)) then
          raise ELWPTRegistryError.CreateStable('recovery_failed',
            'could not remove an index from the non-portable layout');
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    if FindFirst(RootPath('indexes/sha256/*.toml'), faAnyFile, Search) = 0 then
    try
      repeat
        if ActiveIndexFiles.IndexOf(Search.Name) < 0 then
          if not SysUtils.DeleteFile(RootPath('indexes/sha256/'
            + Search.Name)) then
            raise ELWPTRegistryError.CreateStable('recovery_failed',
              'could not remove an index absent from committed state');
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    if FindFirst(RootPath('checkpoints/*.toml'), faAnyFile, Search) = 0 then
    try
      repeat
        FileName := Search.Name;
        if EndsStr('.sig.toml', FileName) then
          Name := Copy(FileName, 1, Length(FileName) - Length('.sig.toml'))
        else Name := ChangeFileExt(FileName, '');
        if (StrToQWordDef(Name, 0) > AState.Sequence)
          and not SysUtils.DeleteFile(RootPath('checkpoints/' + FileName)) then
          raise ELWPTRegistryError.CreateStable('recovery_failed',
            'could not remove an uncommitted checkpoint');
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
  finally
    ActiveIndexFiles.Free;
    ActiveNames.Free;
    Records.Free;
  end;
end;

procedure TLWPTRegistryStore.Recover;
var
  State: TLWPTRegistryState;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
begin
  State := ReadCurrentState;
  VerifyState(State);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication',
      'registry startup recovery');
    if Assigned(Lease) then
    begin
      if DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
      ForceDirectories(TmpRoot);
      RecoverDerivedState(State);
    end;
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

function TLWPTRegistryStore.ReadCurrentState: TLWPTRegistryState;
begin
  Result := ParseState(ReadText(RootPath(CURRENT_STATE_FILE)));
end;

function TLWPTRegistryStore.LoadCurrentState: TLWPTRegistryState;
begin
  Result := ReadCurrentState;
  VerifyState(Result);
end;

function TLWPTRegistryStore.LoadResource(const ARelative: string): TBytes;
var
  FullPath: string;
begin
  if (ARelative = '') or (ARelative[1] = '/') or (Pos('..', ARelative) > 0)
    or (Pos('\', ARelative) > 0) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'registry resource path is invalid');
  FullPath := RootPath(ARelative);
  if not PathContains(FRoot, FullPath) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'registry resource escapes its data root');
  Result := ReadBytes(FullPath);
end;

procedure TLWPTRegistryStore.DescribeResource(const ARelative,
  AExpectedDigest: string; out APath: string; out ASize: Int64);
var
  Stream: TFileStream;
begin
  if (ARelative = '') or (ARelative[1] = '/') or (Pos('..', ARelative) > 0)
    or (Pos('\', ARelative) > 0) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path',
      'registry resource path is invalid');
  APath := RootPath(ARelative);
  if not PathContains(FRoot, APath) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path',
      'registry resource escapes its data root');
  if not FileExists(APath) then
    raise ELWPTRegistryError.CreateStable('state_missing',
      'required file is missing: ' + APath);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    ASize := Stream.Size;
  finally
    Stream.Free;
  end;
  if (AExpectedDigest <> '')
    and ('sha256:' + SHA256File(APath) <> AExpectedDigest) then
    raise ELWPTRegistryError.CreateStable('resource_hash_mismatch',
      'content-addressed resource bytes do not match the request path');
end;

{$IFDEF REGISTRY_TESTING}
procedure SetRegistryFailurePointForTesting(const APoint: string);
begin
  RegistryFailurePointForTesting := APoint;
end;

procedure SetRegistryPublicationBarrierForTesting(const AReadyPath,
  AReleasePath: string);
begin
  RegistryPublicationReadyPathForTesting := AReadyPath;
  RegistryPublicationReleasePathForTesting := AReleasePath;
end;

procedure InjectRegistryFailure(const APoint: string);
begin
  if RegistryFailurePointForTesting = APoint then
    raise ELWPTRegistryError.CreateStable('injected_registry_failure',
      'test failure after ' + APoint);
end;
{$ENDIF}

procedure TLWPTRegistryStore.EnsureFreshCheckpoint(const ANow: string);
var
  Checkpoint, SeedBytes, Signature: TBytes;
  CheckpointHash, CheckpointText, ExpiresAt, KeyID, RenewalPath: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  ExpiresDate, NowDate: TDateTime;
  Lease: TLWPTProducerLease;
  PublicKey: TLWPTEd25519PublicKey;
  Seed: TLWPTEd25519Seed;
  State: TLWPTRegistryState;
begin
  TimestampPlusSevenDays(ANow);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication',
      'registry checkpoint renewal');
    if not Assigned(Lease) then Exit;
    State := ReadCurrentState;
    VerifyState(State);
    CheckpointText := Text(LoadResource(State.CheckpointPath));
    ExpiresAt := StringValue(CheckpointText, 'expires_at');
    if not TryISO8601ToDate(ExpiresAt, ExpiresDate, True)
      or not TryISO8601ToDate(ANow, NowDate, True) then
      raise ELWPTRegistryError.CreateStable('checkpoint_expiry_invalid',
        'checkpoint expiry is not canonical UTC');
    if ExpiresDate > IncHour(NowDate,
      CHECKPOINT_RENEWAL_THRESHOLD_HOURS) then Exit;
    KeyID := StringValue(CheckpointText, 'key_id');
    SeedBytes := LoadSeed;
    try
      if Length(SeedBytes) <> SizeOf(Seed) then
        raise ELWPTRegistryError.CreateStable('state_corrupt',
          'registry signing seed has the wrong length');
      Move(SeedBytes[0], Seed[0], SizeOf(Seed));
      Ed25519PublicKey(Seed, PublicKey);
      SetLength(SeedBytes, SizeOf(PublicKey));
      Move(PublicKey[0], SeedBytes[0], SizeOf(PublicKey));
      if KeyID <> 'ed25519:' + SHA256Hex(SeedBytes) then
        raise ELWPTRegistryError.CreateStable('key_id_mismatch',
          'registry signing seed does not match the active key');
      Checkpoint := Bytes(CheckpointDocument(FConfig.Identity,
        State.Sequence, State.SnapshotHash, ANow, KeyID));
      Signature := Bytes(SignatureDocument(Checkpoint, Seed, KeyID));
    finally
      FillChar(Seed, SizeOf(Seed), 0);
      if Length(SeedBytes) > 0 then FillChar(SeedBytes[0], Length(SeedBytes), 0);
    end;
    CheckpointHash := SHA256Hex(Checkpoint);
    RenewalPath := 'checkpoints/renewals/sha256/' + CheckpointHash;
    WriteImmutable(RenewalPath + '.toml', Checkpoint);
    WriteImmutable(RenewalPath + '.sig.toml', Signature);
    {$IFDEF REGISTRY_TESTING}
    InjectRegistryFailure('renewal-checkpoint');
    {$ENDIF}
    State.CheckpointPath := RenewalPath + '.toml';
    State.SignaturePath := RenewalPath + '.sig.toml';
    AtomicWriteBytes(RootPath(CURRENT_STATE_FILE), TmpRoot,
      Bytes(StateDocument(State)));
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

procedure TLWPTRegistryStore.Publish(
  const APublication: TLWPTRegistryPublication);
var
  Character: Char;
  ArchiveHash, ExistingRecordHash, IndexPath, KeyID, RecordHash,
    SnapshotHash: string;
  Checkpoint, RecordBytes, SeedBytes, Signature, Snapshot: TBytes;
  ActiveRecordDocument, CurrentSnapshot, IndexDocument, RecordDocument: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  PublicKey: TLWPTEd25519PublicKey;
  Records, VersionEntries: TStringList;
  Seed: TLWPTEd25519Seed;
  State: TLWPTRegistryState;
  {$IFDEF REGISTRY_TESTING}
  BarrierStartedAt: QWord;
  {$ENDIF}
begin
  if (Length(APublication.Name) < 1) or (Length(APublication.Name) > 128)
    or not (APublication.Name[1] in ['a'..'z', '0'..'9']) then
    raise ELWPTRegistryError.CreateStable('invalid_package_name', 'package name is not canonical');
  for Character in APublication.Name do
    if not (Character in ['a'..'z', '0'..'9', '.', '_', '-']) then
      raise ELWPTRegistryError.CreateStable('invalid_package_name', 'package name is not canonical');
  if Valid(APublication.Version, DefaultSemverOptions) <> APublication.Version then
    raise ELWPTRegistryError.CreateStable('invalid_version', 'package version is not canonical SemVer 2.0.0');
  TimestampPlusSevenDays(APublication.PublishedAt);
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication',
      'registry snapshot publication');
    if not Assigned(Lease) then
      raise ELWPTRegistryError.CreateStable('publication_locked', 'another publication owns the origin');
    if DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
    ForceDirectories(TmpRoot);
    State := ReadCurrentState;
    VerifyState(State);
    RecoverDerivedState(State);
    ArchiveHash := SHA256BytesPrefixed(APublication.Archive);
    WriteImmutable('objects/sha256/' + Copy(ArchiveHash,
      Length('sha256:') + 1, MaxInt), APublication.Archive);
    RecordDocument := 'schema = '
      + PersistedTOMLQuote(PROGRAM_NAME + '-registry-package-v1') + #10
      + 'origin = ' + PersistedTOMLQuote(FConfig.Identity) + #10
      + 'name = ' + PersistedTOMLQuote(APublication.Name) + #10
      + 'version = ' + PersistedTOMLQuote(APublication.Version) + #10
      + 'archive = ' + PersistedTOMLQuote(ArchiveHash) + #10
      + 'archive_size = ' + IntToStr(Length(APublication.Archive)) + #10
      + 'published_at = ' + PersistedTOMLQuote(APublication.PublishedAt) + #10
      + 'yanked = false' + #10
      + 'dependencies = []' + #10;
    RecordBytes := Bytes(RecordDocument);
    RecordHash := SHA256BytesPrefixed(RecordBytes);
    WriteImmutable('records/sha256/' + Copy(RecordHash,
      Length('sha256:') + 1, MaxInt) + '.toml', RecordBytes);
    CurrentSnapshot := Text(LoadResource('snapshots/sha256/'
      + Copy(State.SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml'));
    VersionEntries := TStringList.Create;
    VersionEntries.Sorted := True;
    VersionEntries.Duplicates := dupError;
    VersionEntries.NameValueSeparator := '=';
    Records := ReadSnapshotRecords(CurrentSnapshot);
    try
      for ExistingRecordHash in Records do
      begin
        if not IsSHA256(ExistingRecordHash) then
          raise ELWPTRegistryError.CreateStable('state_corrupt',
            'snapshot contains an invalid record hash');
        ActiveRecordDocument := Text(LoadResource('records/sha256/'
          + Copy(ExistingRecordHash, Length('sha256:') + 1, MaxInt)
          + '.toml'));
        if SHA256BytesPrefixed(Bytes(ActiveRecordDocument))
          <> ExistingRecordHash then
          raise ELWPTRegistryError.CreateStable('record_hash_mismatch',
            'active package record bytes do not match their path');
        if StringValue(ActiveRecordDocument, 'name') = APublication.Name then
        begin
          VersionEntries.Add(StringValue(ActiveRecordDocument, 'version')
            + '=' + ExistingRecordHash);
          if StringValue(ActiveRecordDocument, 'version')
            = APublication.Version then
          begin
            if ExistingRecordHash = RecordHash then Exit;
            raise ELWPTRegistryError.CreateStable('identity_conflict',
              'package version is immutable: ' + APublication.Name + '@'
              + APublication.Version);
          end;
        end;
      end;
      VersionEntries.Add(APublication.Version + '=' + RecordHash);
      Records.Add(RecordHash);
      Snapshot := Bytes(SnapshotDocument(FConfig.Identity,
        State.Sequence + 1, APublication.PublishedAt, State.SnapshotHash,
        Records));
      IndexDocument := VersionIndexDocument(FConfig.Identity,
        APublication.Name, VersionEntries);
    finally
      Records.Free;
      VersionEntries.Free;
    end;
    IndexPath := RootPath(RegistryIndexStoragePath(APublication.Name));
    {
      Immutable publication bytes are prepared first. Only current.toml
      activates them; indexes are derived aliases and follow activation.
    }
    SnapshotHash := SHA256BytesPrefixed(Snapshot);
    WriteImmutable('snapshots/sha256/' + Copy(SnapshotHash,
      Length('sha256:') + 1, MaxInt) + '.toml', Snapshot);
    SeedBytes := LoadSeed;
    try
      Move(SeedBytes[0], Seed[0], SizeOf(Seed));
      Ed25519PublicKey(Seed, PublicKey);
      SetLength(SeedBytes, SizeOf(PublicKey));
      Move(PublicKey[0], SeedBytes[0], SizeOf(PublicKey));
      KeyID := 'ed25519:' + SHA256Hex(SeedBytes);
      Checkpoint := Bytes(CheckpointDocument(FConfig.Identity,
        State.Sequence + 1, SnapshotHash, APublication.PublishedAt, KeyID));
      Signature := Bytes(SignatureDocument(Checkpoint, Seed, KeyID));
    finally
      FillChar(Seed, SizeOf(Seed), 0);
      if Length(SeedBytes) > 0 then FillChar(SeedBytes[0], Length(SeedBytes), 0);
    end;
    WriteImmutable('checkpoints/' + UIntToStr(State.Sequence + 1) + '.toml',
      Checkpoint);
    WriteImmutable('checkpoints/' + UIntToStr(State.Sequence + 1)
      + '.sig.toml', Signature);
    {$IFDEF REGISTRY_TESTING}
    InjectRegistryFailure('checkpoint');
    {$ENDIF}
    State.Sequence := State.Sequence + 1;
    State.SnapshotHash := SnapshotHash;
    State.CheckpointPath := 'checkpoints/' + UIntToStr(State.Sequence) + '.toml';
    State.SignaturePath := 'checkpoints/' + UIntToStr(State.Sequence)
      + '.sig.toml';
    {$IFDEF REGISTRY_TESTING}
    if RegistryPublicationReadyPathForTesting <> '' then
    begin
      AtomicWriteBytes(RegistryPublicationReadyPathForTesting, TmpRoot,
        Bytes('ready' + #10));
      BarrierStartedAt := GetTickCount64;
      while not FileExists(RegistryPublicationReleasePathForTesting) do
      begin
        if GetTickCount64 - BarrierStartedAt >= 10000 then
          raise ELWPTRegistryError.CreateStable('test_barrier_timeout',
            'publication activation barrier timed out');
        Sleep(10);
      end;
    end;
    {$ENDIF}
    AtomicWriteBytes(RootPath(CURRENT_STATE_FILE), TmpRoot,
      Bytes(StateDocument(State)));
    {$IFDEF REGISTRY_TESTING}
    InjectRegistryFailure('activation');
    {$ENDIF}
    AtomicWriteBytes(IndexPath, TmpRoot, Bytes(IndexDocument));
    { No additional commit follows the alias. A crash here is recovered by
      rebuilding aliases from the authenticated active snapshot. }
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

end.
