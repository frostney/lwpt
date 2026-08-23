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
    procedure WriteImmutable(const ARelative: string;
      const ABytes: TBytes);
  public
    constructor Create(const ARoot: string);
    class function Initialize(const ARoot: string;
      const ARequested: TLWPTRegistryConfig;
      const APublishedAt: string): TLWPTRegistryStore;
    procedure Recover;
    function LoadCurrentState: TLWPTRegistryState;
    function LoadResource(const ARelative: string): TBytes;
    procedure Publish(const APublication: TLWPTRegistryPublication);
    property Config: TLWPTRegistryConfig read FConfig;
    property Root: string read FRoot;
  end;

function CanonicalRegistryURL(const AValue: string;
  const ARequireHTTPS: Boolean): string;
function RegistryKeyStoragePath(const AKeyID: string): string;
function RegistryConfiguration(const AIdentity, ABaseURL,
  AListenAddress: string; const APort: Word; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string): TLWPTRegistryConfig;
procedure ValidateRegistryConfiguration(const AConfig: TLWPTRegistryConfig);

implementation

uses
  DateUtils,
  StrUtils,
  {$IFDEF UNIX}
  BaseUnix,
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

function Quote(const AValue: string): string;
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
      #0..#7, #11, #14..#31:
        raise ELWPTRegistryError.CreateStable('invalid_configuration',
          'control characters are not permitted in registry configuration');
      else Result := Result + Character;
    end;
  Result := Result + '"';
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
  Item: string;
  Index: Integer;
  Input, Output: TStringList;
begin
  if APath = '' then Exit('');
  Input := TStringList.Create;
  Output := TStringList.Create;
  try
    Input.Delimiter := '/';
    Input.StrictDelimiter := True;
    Input.DelimitedText := APath;
    for Item in Input do
      if (Item = '') or (Item = '.') then
        Continue
      else if Item = '..' then
      begin
        if Output.Count > 0 then Output.Delete(Output.Count - 1);
      end
      else Output.Add(Item);
    Result := '';
    for Index := 0 to Output.Count - 1 do Result := Result + '/' + Output[Index];
  finally
    Output.Free;
    Input.Free;
  end;
end;

function CanonicalRegistryURL(const AValue: string;
  const ARequireHTTPS: Boolean): string;
var
  Authority, Host, Path, Port, Scheme: string;
  BracketEnd, Colon, Slash: Integer;
begin
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
    Host := LowerCase(Copy(Authority, 1, BracketEnd));
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
    else Host := LowerCase(Authority);
  end;
  if Host = '' then raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL host is empty');
  if Port <> '' then
  begin
    if (StrToIntDef(Port, 0) < 1) or (StrToIntDef(Port, 0) > 65535) then
      raise ELWPTRegistryError.CreateStable('invalid_url', 'registry URL port is invalid');
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

procedure ValidateRegistryConfiguration(const AConfig: TLWPTRegistryConfig);
var
  BaseURL, Identity: string;
begin
  BaseURL := CanonicalRegistryURL(AConfig.BaseURL, False);
  if BaseURL <> AConfig.BaseURL then
    raise ELWPTRegistryError.CreateStable('invalid_url', 'base URL is not canonical; use ' + BaseURL);
  Identity := CanonicalRegistryURL(AConfig.Identity,
    AConfig.Identity <> AConfig.BaseURL);
  if Identity <> AConfig.Identity then
    raise ELWPTRegistryError.CreateStable('invalid_identity', 'origin identity is not canonical; use ' + Identity);
  if (AConfig.ListenAddress = '') or (AConfig.Port = 0) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration', 'listen address and port are required');
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
  end;
end;

function ConfigDocument(const AConfig: TLWPTRegistryConfig): string;
begin
  Result := 'schema = ' + Quote(PROGRAM_NAME + '-registry-origin-config-v1') + #10
    + 'identity = ' + Quote(AConfig.Identity) + #10
    + 'base_url = ' + Quote(AConfig.BaseURL) + #10
    + 'listen_address = ' + Quote(AConfig.ListenAddress) + #10
    + 'port = ' + IntToStr(AConfig.Port) + #10
    + 'tls_pkcs12 = ' + Quote(AConfig.TLSPKCS12Path) + #10
    + 'tls_password_env = ' + Quote(AConfig.TLSPasswordEnvironment) + #10;
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
  Result := 'schema = ' + Quote(PROGRAM_NAME + '-registry-snapshot-v1') + #10
    + 'origin = ' + Quote(AOrigin) + #10
    + 'sequence = ' + UIntToStr(ASequence) + #10
    + 'published_at = ' + Quote(APublishedAt) + #10
    + 'previous = ' + Quote(APrevious) + #10
    + 'records = [';
  for Index := 0 to ARecords.Count - 1 do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + Quote(ARecords[Index]);
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
    + Quote(PROGRAM_NAME + '-registry-version-index-v1') + #10
    + 'origin = ' + Quote(AOrigin) + #10
    + 'name = ' + Quote(AName) + #10
    + 'versions = [';
  for Index := 0 to AEntries.Count - 1 do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + Quote(AEntries[Index]);
  end;
  Result := Result + ']' + #10;
end;

function ReadVersionIndex(const ADocument, AOrigin,
  AName: string): TStringList;
var
  Entry: string;
begin
  if StringValue(ADocument, 'schema') <> PROGRAM_NAME
    + '-registry-version-index-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'unsupported version-index schema');
  if StringValue(ADocument, 'origin') <> AOrigin then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'version-index origin does not match the store');
  if StringValue(ADocument, 'name') <> AName then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'version-index package name does not match its path');
  Result := ReadStringArray(ADocument, 'versions',
    'version-index versions');
  Result.NameValueSeparator := '=';
  for Entry in Result do
    if (Pos('=', Entry) < 2) or not IsSHA256(
      Copy(Entry, Pos('=', Entry) + 1, MaxInt)) then
      raise ELWPTRegistryError.CreateStable('state_corrupt',
        'version-index entry is invalid');
end;

function CheckpointDocument(const AOrigin: string; const ASequence: QWord;
  const ASnapshotHash, APublishedAt, AKeyID: string): string;
begin
  Result := 'schema = ' + Quote(PROGRAM_NAME + '-registry-checkpoint-v1') + #10
    + 'origin = ' + Quote(AOrigin) + #10
    + 'sequence = ' + UIntToStr(ASequence) + #10
    + 'snapshot = ' + Quote(ASnapshotHash) + #10
    + 'published_at = ' + Quote(APublishedAt) + #10
    + 'expires_at = ' + Quote(TimestampPlusSevenDays(APublishedAt)) + #10
    + 'key_id = ' + Quote(AKeyID) + #10;
end;

function SignatureDocument(const ACheckpoint: TBytes;
  const ASeed: TLWPTEd25519Seed; const AKeyID: string): string;
var
  SigningInput: TBytes;
  Signature: TLWPTEd25519Signature;
begin
  SigningInput := Bytes(CHECKPOINT_DOMAIN + Text(ACheckpoint));
  Ed25519Sign(SigningInput, ASeed, Signature);
  Result := 'schema = ' + Quote(PROGRAM_NAME + '-registry-signature-v1') + #10
    + 'algorithm = "ed25519"' + #10
    + 'key_id = ' + Quote(AKeyID) + #10
    + 'payload = ' + Quote('sha256:' + SHA256Hex(ACheckpoint)) + #10
    + 'signature = ' + Quote('hex:' + BytesToHex(Signature,
      SizeOf(Signature))) + #10;
end;

function StateDocument(const AState: TLWPTRegistryState): string;
begin
  Result := 'schema = ' + Quote(PROGRAM_NAME + '-registry-state-v1') + #10
    + 'sequence = ' + UIntToStr(AState.Sequence) + #10
    + 'snapshot = ' + Quote(AState.SnapshotHash) + #10
    + 'checkpoint = ' + Quote(AState.CheckpointPath) + #10
    + 'signature = ' + Quote(AState.SignaturePath) + #10;
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
end;

function TLWPTRegistryStore.TmpRoot: string;
begin
  Result := RootPath('tmp');
end;

function TLWPTRegistryStore.LoadSeed: TBytes;
var
  Seed: TLWPTEd25519Seed;
begin
  if not HexToBytes(Trim(ReadText(RootPath(SIGNING_SEED_FILE))), Seed,
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

  function AtRoot(const ARelative: string): string;
  begin
    Result := IncludeTrailingPathDelimiter(RootDir)
      + StringReplace(ARelative, '/', PathDelim, [rfReplaceAll]);
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
  RootDir := ExpandFileName(ARoot);
  TemporaryRoot := IncludeTrailingPathDelimiter(RootDir) + 'tmp';
  if FileExists(IncludeTrailingPathDelimiter(RootDir)
    + INITIALIZATION_MARKER) and not FileExists(
      IncludeTrailingPathDelimiter(RootDir) + CONFIG_FILE) then
  begin
    { No configuration means no initialization ever committed. Reclaim only
      a directory carrying our marker, then rebuild it from fresh key bytes. }
    WipeDir(RootDir);
  end;
  ForceDirectories(RootDir);
  if FileExists(IncludeTrailingPathDelimiter(RootDir) + CONFIG_FILE) then
  begin
    Existing := TLWPTRegistryStore.Create(ARoot);
    try
      Config := ARequested;
      if Config.Identity = '' then Config.Identity := Existing.Config.Identity;
      Config.BaseURL := CanonicalRegistryURL(Config.BaseURL, False);
      Config.Identity := CanonicalRegistryURL(Config.Identity,
        Config.Identity <> Config.BaseURL);
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
  ValidateRegistryConfiguration(Config);
  TimestampPlusSevenDays(APublishedAt);
  ForceDirectories(TemporaryRoot);
  AtomicWriteBytes(AtRoot(INITIALIZATION_MARKER), TemporaryRoot,
    Bytes('registry initialization in progress' + #10));
  ConfigBytes := Bytes(ConfigDocument(Config));
  GenerateEd25519Seed(Seed);
  AtomicWriteBytes(AtRoot(SIGNING_SEED_FILE), TemporaryRoot,
    Bytes(BytesToHex(Seed, SizeOf(Seed)) + #10));
  {$IFDEF UNIX}
  FpChmod(PChar(AtRoot(SIGNING_SEED_FILE)), &600);
  {$ENDIF}
  try
    Ed25519PublicKey(Seed, PublicKey);
    SetLength(PublicKeyBytes, SizeOf(PublicKey));
    Move(PublicKey[0], PublicKeyBytes[0], SizeOf(PublicKey));
    KeyID := 'ed25519:' + SHA256Hex(PublicKeyBytes);
    WriteInitialImmutable(RegistryKeyStoragePath(KeyID), Bytes(
      'schema = ' + Quote(PROGRAM_NAME + '-registry-key-v1') + #10
      + 'origin = ' + Quote(Config.Identity) + #10
      + 'key_id = ' + Quote(KeyID) + #10
      + 'algorithm = "ed25519"' + #10
      + 'public_key = ' + Quote('hex:' + BytesToHex(PublicKey,
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
    { Configuration is the initialization commit marker. Constructors cannot
      observe an origin until all immutable state and its pointer are ready. }
    AtomicWriteBytes(AtRoot(CONFIG_FILE), TemporaryRoot, ConfigBytes);
    SysUtils.DeleteFile(AtRoot(INITIALIZATION_MARKER));
    Result := TLWPTRegistryStore.Create(ARoot);
  except
    FreeAndNil(Result);
    raise;
  end;
end;

procedure TLWPTRegistryStore.Recover;
var
  CheckpointBytes, KeyBytes, SignatureBytes, SigningInput: TBytes;
  CheckpointDocumentText, KeyDocumentText, SignatureDocumentText: string;
  KeyID, Payload, PublicKeyHex, SignatureHex: string;
  PublicKey: TLWPTEd25519PublicKey;
  Signature: TLWPTEd25519Signature;
  State: TLWPTRegistryState;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
begin
  { A live publisher owns temporary staging. A restart may serve the last
    committed pointer immediately, but only a process that acquires the
    advisory guard may reclaim abandoned staging. OS locks disappear when a
    publisher crashes, so persistent guard files are never liveness proof. }
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication',
      'registry startup recovery');
    if Assigned(Lease) then
    begin
      if DirectoryExists(TmpRoot) then WipeDir(TmpRoot);
      ForceDirectories(TmpRoot);
    end;
  finally
    Lease.Free;
    Coordinator.Free;
  end;
  State := ReadCurrentState;
  if not IsSHA256(State.SnapshotHash) then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'committed snapshot hash is invalid');
  if State.CheckpointPath <> 'checkpoints/' + UIntToStr(State.Sequence)
    + '.toml' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'committed checkpoint path is invalid');
  if State.SignaturePath <> 'checkpoints/' + UIntToStr(State.Sequence)
    + '.sig.toml' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'committed signature path is invalid');
  if SHA256BytesPrefixed(LoadResource('snapshots/sha256/'
    + Copy(State.SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml'))
    <> State.SnapshotHash then
    raise ELWPTRegistryError.CreateStable('snapshot_hash_mismatch',
      'committed snapshot bytes do not match the activation pointer');
  CheckpointBytes := LoadResource(State.CheckpointPath);
  SignatureBytes := LoadResource(State.SignaturePath);
  CheckpointDocumentText := Text(CheckpointBytes);
  SignatureDocumentText := Text(SignatureBytes);
  if StringValue(CheckpointDocumentText, 'schema') <> PROGRAM_NAME
    + '-registry-checkpoint-v1' then
    raise ELWPTRegistryError.CreateStable('state_corrupt',
      'unsupported checkpoint schema');
  if StringValue(CheckpointDocumentText, 'origin') <> FConfig.Identity then
    raise ELWPTRegistryError.CreateStable('checkpoint_origin_mismatch',
      'checkpoint origin differs from the configured identity');
  if UIntValue(CheckpointDocumentText, 'sequence') <> State.Sequence then
    raise ELWPTRegistryError.CreateStable('checkpoint_state_mismatch',
      'checkpoint sequence differs from committed state');
  if StringValue(CheckpointDocumentText, 'snapshot') <> State.SnapshotHash then
    raise ELWPTRegistryError.CreateStable('checkpoint_state_mismatch',
      'checkpoint snapshot differs from committed state');
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

function TLWPTRegistryStore.ReadCurrentState: TLWPTRegistryState;
begin
  Result := ParseState(ReadText(RootPath(CURRENT_STATE_FILE)));
end;

function TLWPTRegistryStore.LoadCurrentState: TLWPTRegistryState;
begin
  Result := ReadCurrentState;
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

procedure TLWPTRegistryStore.Publish(
  const APublication: TLWPTRegistryPublication);
var
  Character: Char;
  ArchiveHash, ExistingRecordHash, IndexPath, KeyID, RecordHash,
    SnapshotHash: string;
  Checkpoint, RecordBytes, SeedBytes, Signature, Snapshot: TBytes;
  CurrentSnapshot, IndexDocument, RecordDocument: string;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  PublicKey: TLWPTEd25519PublicKey;
  Records, VersionEntries: TStringList;
  Seed: TLWPTEd25519Seed;
  State: TLWPTRegistryState;
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
    ArchiveHash := SHA256BytesPrefixed(APublication.Archive);
    WriteImmutable('objects/sha256/' + Copy(ArchiveHash,
      Length('sha256:') + 1, MaxInt), APublication.Archive);
    RecordDocument := 'schema = '
      + Quote(PROGRAM_NAME + '-registry-package-v1') + #10
      + 'origin = ' + Quote(FConfig.Identity) + #10
      + 'name = ' + Quote(APublication.Name) + #10
      + 'version = ' + Quote(APublication.Version) + #10
      + 'archive = ' + Quote(ArchiveHash) + #10
      + 'archive_size = ' + IntToStr(Length(APublication.Archive)) + #10
      + 'published_at = ' + Quote(APublication.PublishedAt) + #10
      + 'yanked = false' + #10
      + 'dependencies = []' + #10;
    RecordBytes := Bytes(RecordDocument);
    RecordHash := SHA256BytesPrefixed(RecordBytes);
    WriteImmutable('records/sha256/' + Copy(RecordHash,
      Length('sha256:') + 1, MaxInt) + '.toml', RecordBytes);
    CurrentSnapshot := Text(LoadResource('snapshots/sha256/'
      + Copy(State.SnapshotHash, Length('sha256:') + 1, MaxInt) + '.toml'));
    IndexPath := RootPath('indexes/' + APublication.Name + '.toml');
    if FileExists(IndexPath) then
      VersionEntries := ReadVersionIndex(ReadText(IndexPath),
        FConfig.Identity, APublication.Name)
    else
    begin
      VersionEntries := TStringList.Create;
      VersionEntries.Sorted := True;
      VersionEntries.Duplicates := dupError;
      VersionEntries.NameValueSeparator := '=';
    end;
    try
      ExistingRecordHash := VersionEntries.Values[APublication.Version];
      if ExistingRecordHash <> '' then
      begin
        if ExistingRecordHash = RecordHash then Exit;
        raise ELWPTRegistryError.CreateStable('identity_conflict',
          'package version is immutable: ' + APublication.Name + '@'
          + APublication.Version);
      end;
      VersionEntries.Add(APublication.Version + '=' + RecordHash);
      Records := ReadSnapshotRecords(CurrentSnapshot);
      try
        Records.Add(RecordHash);
        Snapshot := Bytes(SnapshotDocument(FConfig.Identity,
          State.Sequence + 1, APublication.PublishedAt, State.SnapshotHash,
          Records));
      finally
        Records.Free;
      end;
      IndexDocument := VersionIndexDocument(FConfig.Identity,
        APublication.Name, VersionEntries);
    finally
      VersionEntries.Free;
    end;
    SnapshotHash := SHA256BytesPrefixed(Snapshot);
    WriteImmutable('snapshots/sha256/' + Copy(SnapshotHash,
      Length('sha256:') + 1, MaxInt) + '.toml', Snapshot);
    SeedBytes := LoadSeed;
    Move(SeedBytes[0], Seed[0], SizeOf(Seed));
    Ed25519PublicKey(Seed, PublicKey);
    SetLength(SeedBytes, SizeOf(PublicKey));
    Move(PublicKey[0], SeedBytes[0], SizeOf(PublicKey));
    KeyID := 'ed25519:' + SHA256Hex(SeedBytes);
    Checkpoint := Bytes(CheckpointDocument(FConfig.Identity,
      State.Sequence + 1, SnapshotHash, APublication.PublishedAt, KeyID));
    Signature := Bytes(SignatureDocument(Checkpoint, Seed, KeyID));
    WriteImmutable('checkpoints/' + UIntToStr(State.Sequence + 1) + '.toml',
      Checkpoint);
    WriteImmutable('checkpoints/' + UIntToStr(State.Sequence + 1)
      + '.sig.toml', Signature);
    AtomicWriteBytes(RootPath('indexes/' + APublication.Name + '.toml'),
      TmpRoot, Bytes(IndexDocument));
    State.Sequence := State.Sequence + 1;
    State.SnapshotHash := SnapshotHash;
    State.CheckpointPath := 'checkpoints/' + UIntToStr(State.Sequence) + '.toml';
    State.SignaturePath := 'checkpoints/' + UIntToStr(State.Sequence)
      + '.sig.toml';
    AtomicWriteBytes(RootPath(CURRENT_STATE_FILE), TmpRoot,
      Bytes(StateDocument(State)));
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

end.
