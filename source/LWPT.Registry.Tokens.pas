{ LWPT.Registry.Tokens -- origin publication credentials (ADR-0049).

  A token is <PROGRAM_NAME>_rt1_<token-id>_<secret>. Only the SHA-256 of the
  secret is stored, in an owner-only record per token. The server reads the
  record on every mutating request and caches nothing, so revocation and
  expiry take effect on the next request. No function here returns or
  reports a secret, except IssueRegistryToken's single result. }
unit LWPT.Registry.Tokens;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store;

const
  RegistryTokenDefaultExpiryDays = 90;
  RegistryTokenMinimumExpiryDays = 1;
  RegistryTokenMaximumExpiryDays = 365;
  RegistryMaximumActiveTokens = 1000;
  RegistryTokenLabelMaximumLength = 128;
  RegistryTokenMaximumPatterns = 64;
  REGISTRY_TOKEN_DIRECTORY = 'auth/tokens';
  REGISTRY_TOKEN_STAGING_DIRECTORY = 'auth/tmp';

type
  TLWPTRegistryTokenAction = (rtaPublish, rtaYank);
  TLWPTRegistryTokenActions = set of TLWPTRegistryTokenAction;

  { Why a presented credential failed. Recorded in audit files only; the
    client always receives one indistinguishable 401. }
  TLWPTRegistryAuthFailure = (rafNone, rafMissing, rafMalformed, rafUnknown,
    rafRevoked, rafExpired, rafMismatch);

  TLWPTRegistryToken = record
    ID, TokenLabel: string;
    Patterns: TStringArray;
    Actions: TLWPTRegistryTokenActions;
    CreatedAt, ExpiresAt, RevokedAt, SecretHash: string;
  end;
  TLWPTRegistryTokenArray = array of TLWPTRegistryToken;

function RegistryTokenPatternIsValid(const APattern: string): Boolean;
function RegistryTokenPatternMatches(const APattern, AName: string): Boolean;
{ True when the token grants AAction on package AName. An empty AName asks
  whether any pattern grants the action (object uploads are unscoped). }
function RegistryTokenPermits(const AToken: TLWPTRegistryToken;
  const AAction: TLWPTRegistryTokenAction; const AName: string): Boolean;
function RegistryTokenIsActive(const AToken: TLWPTRegistryToken;
  const ANow: string): Boolean;
{ Parses "publish[,yank]". }
function ParseRegistryTokenActions(const AText: string;
  out AActions: TLWPTRegistryTokenActions): Boolean;
function RegistryTokenActionsText(
  const AActions: TLWPTRegistryTokenActions): string;
function RegistryAuthFailureText(const AFailure: TLWPTRegistryAuthFailure): string;
{ Validates the credential grammar without consulting storage. }
function RegistryTokenIsWellFormed(const AToken: string): Boolean;
{ Issues a token and returns it; this is the only place a secret leaves the
  module. ANow is canonical UTC. }
function IssueRegistryToken(const ARoot: string; const APatterns: array of string;
  const AActions: TLWPTRegistryTokenActions; const AExpiresDays: Integer;
  const ALabel, ANow: string; out ARecord: TLWPTRegistryToken): string;
{ Atomically sets revoked_at, keeping the record. Returns False when the
  token was already revoked. }
function RevokeRegistryToken(const ARoot, ATokenID, ANow: string): Boolean;
function ListRegistryTokens(const ARoot: string): TLWPTRegistryTokenArray;
function RegistryHasActiveToken(const ARoot, ANow: string): Boolean;
{ Authenticates an Authorization header value. On success AToken holds the
  verified record; otherwise AFailure names the internal cause. }
function AuthenticateRegistryBearer(const ARoot, AAuthorization,
  ANow: string; out AToken: TLWPTRegistryToken;
  out AFailure: TLWPTRegistryAuthFailure): Boolean;
function RegistryTokenDocument(const AToken: TLWPTRegistryToken): string;
function ParseRegistryTokenDocument(const AText: string): TLWPTRegistryToken;
{ Canonical metadata line for registry verify; never includes the hash. }
function RegistryTokenMetadata(const AToken: TLWPTRegistryToken): string;
{$IFDEF REGISTRY_TESTING}
{ Lowers the active-token cap; zero restores RegistryMaximumActiveTokens. }
procedure SetRegistryMaximumActiveTokensForTesting(const ALimit: Integer);
{$ENDIF}

implementation

uses
  DateUtils,
  StrUtils,

  LWPT.ProducerLease,
  LWPT.Registry.Crypto,
  LWPT.Registry.Filesystem,
  LWPT.Registry.Verification,
  TOML;

const
  TOKEN_PREFIX = PROGRAM_NAME + '_rt1_';
  TOKEN_ID_LENGTH = 32;
  TOKEN_SECRET_LENGTH = 43;
  MAX_TOKEN_DOCUMENT_BYTES = 64 * 1024;
  BASE64URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  TOKEN_ISSUANCE_LEASE = 'registry-token-issuance';
  TOKEN_ISSUANCE_WAIT_MILLISECONDS = 5000;

{$IFDEF REGISTRY_TESTING}
var
  MaximumActiveTokensForTesting: Integer;

procedure SetRegistryMaximumActiveTokensForTesting(const ALimit: Integer);
begin
  MaximumActiveTokensForTesting := ALimit;
end;
{$ENDIF}

function MaximumActiveTokens: Integer;
begin
  Result := RegistryMaximumActiveTokens;
  {$IFDEF REGISTRY_TESTING}
  if MaximumActiveTokensForTesting > 0 then Result := MaximumActiveTokensForTesting;
  {$ENDIF}
end;

function IsLowerHexText(const AValue: string; const ALength: Integer): Boolean;
var
  Character: Char;
begin
  Result := Length(AValue) = ALength;
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function Base64URLEncode(const ABytes; const ACount: Integer): string;
var
  Data: PByte;
  Index, Accumulator, Bits: Integer;
begin
  Data := @ABytes;
  Result := '';
  Accumulator := 0;
  Bits := 0;
  for Index := 0 to ACount - 1 do
  begin
    Accumulator := ((Accumulator shl 8) or Data[Index]) and $FFFF;
    Inc(Bits, 8);
    while Bits >= 6 do
    begin
      Dec(Bits, 6);
      Result := Result + BASE64URL[((Accumulator shr Bits) and $3F) + 1];
    end;
  end;
  if Bits > 0 then
    Result := Result + BASE64URL[((Accumulator shl (6 - Bits)) and $3F) + 1];
end;

function IsBase64URLText(const AValue: string; const ALength: Integer): Boolean;
var
  Character: Char;
begin
  Result := Length(AValue) = ALength;
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_']) then
      Exit(False);
end;

function RegistryTokenIsWellFormed(const AToken: string): Boolean;
begin
  Result := (Length(AToken) = Length(TOKEN_PREFIX) + TOKEN_ID_LENGTH + 1
      + TOKEN_SECRET_LENGTH)
    and StartsStr(TOKEN_PREFIX, AToken)
    and IsLowerHexText(Copy(AToken, Length(TOKEN_PREFIX) + 1, TOKEN_ID_LENGTH),
      TOKEN_ID_LENGTH)
    and (AToken[Length(TOKEN_PREFIX) + TOKEN_ID_LENGTH + 1] = '_')
    and IsBase64URLText(Copy(AToken, Length(TOKEN_PREFIX) + TOKEN_ID_LENGTH + 2,
      MaxInt), TOKEN_SECRET_LENGTH);
end;

function SecretHash(const ASecret: string): string;
begin
  Result := SHA256BytesPrefixed(BytesOf(ASecret));
end;

{ Compares two equal-format digests without an early exit. }
function ConstantTimeEqual(const ALeft, ARight: string): Boolean;
var
  Index: Integer;
  Difference: Byte;
begin
  if Length(ALeft) <> Length(ARight) then Exit(False);
  Difference := 0;
  for Index := 1 to Length(ALeft) do
    Difference := Difference or (Byte(ALeft[Index]) xor Byte(ARight[Index]));
  Result := Difference = 0;
end;

function RegistryTokenPatternIsValid(const APattern: string): Boolean;
var
  Prefix: string;
  Index: Integer;
begin
  if APattern = '*' then Exit(True);
  if EndsStr('*', APattern) then
  begin
    Prefix := Copy(APattern, 1, Length(APattern) - 1);
    if (Prefix = '') or (Length(Prefix) > 127)
      or not (Prefix[1] in ['a'..'z', '0'..'9']) then Exit(False);
    for Index := 2 to Length(Prefix) do
      if not (Prefix[Index] in ['a'..'z', '0'..'9', '.', '_', '-']) then
        Exit(False);
    Exit(True);
  end;
  Result := RegistryPackageNameIsCanonical(APattern);
end;

function RegistryTokenPatternMatches(const APattern, AName: string): Boolean;
begin
  if APattern = '*' then Exit(True);
  if EndsStr('*', APattern) then
    Exit(StartsStr(Copy(APattern, 1, Length(APattern) - 1), AName));
  Result := APattern = AName;
end;

function RegistryTokenPermits(const AToken: TLWPTRegistryToken;
  const AAction: TLWPTRegistryTokenAction; const AName: string): Boolean;
var
  Pattern: string;
begin
  Result := False;
  if not (AAction in AToken.Actions) then Exit;
  if AName = '' then Exit(Length(AToken.Patterns) > 0);
  for Pattern in AToken.Patterns do
    if RegistryTokenPatternMatches(Pattern, AName) then Exit(True);
end;

function RegistryTokenIsActive(const AToken: TLWPTRegistryToken;
  const ANow: string): Boolean;
begin
  Result := (AToken.RevokedAt = '') and (ANow < AToken.ExpiresAt);
end;

function ParseRegistryTokenActions(const AText: string;
  out AActions: TLWPTRegistryTokenActions): Boolean;
var
  Parts: TStringList;
  Part: string;
begin
  AActions := [];
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := AText;
    for Part in Parts do
      if Part = 'publish' then Include(AActions, rtaPublish)
      else if Part = 'yank' then Include(AActions, rtaYank)
      else Exit(False);
  finally
    Parts.Free;
  end;
  Result := AActions <> [];
end;

function RegistryTokenActionsText(
  const AActions: TLWPTRegistryTokenActions): string;
begin
  Result := '[';
  if rtaPublish in AActions then Result := Result + '"publish"';
  if rtaYank in AActions then
  begin
    if rtaPublish in AActions then Result := Result + ', ';
    Result := Result + '"yank"';
  end;
  Result := Result + ']';
end;

function RegistryAuthFailureText(const AFailure: TLWPTRegistryAuthFailure): string;
const
  NAMES: array[TLWPTRegistryAuthFailure] of string = ('', 'missing',
    'malformed', 'unknown', 'revoked', 'expired', 'mismatch');
begin
  Result := NAMES[AFailure];
end;

function QuotedArray(const AValues: TStringArray): string;
var
  Index: Integer;
begin
  Result := '[';
  for Index := 0 to High(AValues) do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + RegistryTOMLQuote(AValues[Index]);
  end;
  Result := Result + ']';
end;

function RegistryTokenDocument(const AToken: TLWPTRegistryToken): string;
begin
  Result := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-token-v1')
    + #10 + 'id = ' + RegistryTOMLQuote(AToken.ID) + #10
    + 'label = ' + RegistryTOMLQuote(AToken.TokenLabel) + #10
    + 'packages = ' + QuotedArray(AToken.Patterns) + #10
    + 'actions = ' + RegistryTokenActionsText(AToken.Actions) + #10
    + 'created_at = ' + RegistryTOMLQuote(AToken.CreatedAt) + #10
    + 'expires_at = ' + RegistryTOMLQuote(AToken.ExpiresAt) + #10
    + 'revoked_at = ' + RegistryTOMLQuote(AToken.RevokedAt) + #10
    + 'secret_hash = ' + RegistryTOMLQuote(AToken.SecretHash) + #10;
end;

function RegistryTokenMetadata(const AToken: TLWPTRegistryToken): string;
begin
  Result := '{ id = ' + RegistryTOMLQuote(AToken.ID)
    + ', label = ' + RegistryTOMLQuote(AToken.TokenLabel)
    + ', packages = ' + QuotedArray(AToken.Patterns)
    + ', actions = ' + RegistryTokenActionsText(AToken.Actions)
    + ', created_at = ' + RegistryTOMLQuote(AToken.CreatedAt)
    + ', expires_at = ' + RegistryTOMLQuote(AToken.ExpiresAt)
    + ', revoked_at = ' + RegistryTOMLQuote(AToken.RevokedAt) + ' }';
end;

function LabelIsValid(const ALabel: string): Boolean;
var
  Character: Char;
begin
  Result := Length(ALabel) <= RegistryTokenLabelMaximumLength;
  if not Result then Exit;
  for Character in ALabel do
    if (Character < ' ') or (Character > '~') then Exit(False);
end;

procedure SortStrings(var AValues: TStringArray);
var
  Index, Inner: Integer;
  Value: string;
begin
  for Index := 1 to High(AValues) do
  begin
    Value := AValues[Index];
    Inner := Index - 1;
    while (Inner >= 0) and (CompareStr(AValues[Inner], Value) > 0) do
    begin
      AValues[Inner + 1] := AValues[Inner];
      Dec(Inner);
    end;
    AValues[Inner + 1] := Value;
  end;
end;

procedure CorruptToken;
begin
  raise ELWPTRegistryError.CreateStable('token_record_invalid',
    'a registry token record is not canonical');
end;

function ParseRegistryTokenDocument(const AText: string): TLWPTRegistryToken;
var
  Parser: TTOMLParser;
  Root, Node: TTOMLNode;
  Index: Integer;
  Actions: string;
begin
  Result := Default(TLWPTRegistryToken);
  Parser := TTOMLParser.Create;
  Root := nil;
  try
    try
      Root := Parser.ParseDocument(AText);
    except
      on E: Exception do CorruptToken;
    end;
    if TomlStr(Root, 'schema', '') <> PROGRAM_NAME + '-registry-token-v1' then
      CorruptToken;
    Result.ID := TomlStr(Root, 'id', '');
    Result.TokenLabel := TomlStr(Root, 'label', '');
    Result.CreatedAt := TomlStr(Root, 'created_at', '');
    Result.ExpiresAt := TomlStr(Root, 'expires_at', '');
    Result.RevokedAt := TomlStr(Root, 'revoked_at', '');
    Result.SecretHash := TomlStr(Root, 'secret_hash', '');
    Node := TomlGet(Root, 'packages');
    if not TomlIsArray(Node) or (Node.Items.Count < 1) then CorruptToken;
    SetLength(Result.Patterns, Node.Items.Count);
    for Index := 0 to Node.Items.Count - 1 do
    begin
      if not TomlIsString(Node.Items[Index]) then CorruptToken;
      Result.Patterns[Index] := Node.Items[Index].ScalarText;
      if not RegistryTokenPatternIsValid(Result.Patterns[Index]) then
        CorruptToken;
    end;
    Node := TomlGet(Root, 'actions');
    if not TomlIsArray(Node) then CorruptToken;
    Actions := '';
    for Index := 0 to Node.Items.Count - 1 do
    begin
      if not TomlIsString(Node.Items[Index]) then CorruptToken;
      if Index > 0 then Actions := Actions + ',';
      Actions := Actions + Node.Items[Index].ScalarText;
    end;
    if not ParseRegistryTokenActions(Actions, Result.Actions) then CorruptToken;
  finally
    Root.Free;
    Parser.Free;
  end;
  if not IsLowerHexText(Result.ID, TOKEN_ID_LENGTH)
    or not LabelIsValid(Result.TokenLabel)
    or not RegistryTimestampIsCanonical(Result.CreatedAt)
    or not RegistryTimestampIsCanonical(Result.ExpiresAt)
    or ((Result.RevokedAt <> '')
      and not RegistryTimestampIsCanonical(Result.RevokedAt))
    or not RegistryHashIsCanonical(Result.SecretHash)
    or (RegistryTokenDocument(Result) <> AText) then
    CorruptToken;
end;

function TokenDirectory(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ExpandFileName(ARoot))
    + StringReplace(REGISTRY_TOKEN_DIRECTORY, '/', PathDelim, [rfReplaceAll]);
end;

function StagingDirectory(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ExpandFileName(ARoot))
    + StringReplace(REGISTRY_TOKEN_STAGING_DIRECTORY, '/', PathDelim,
      [rfReplaceAll]);
end;

function TokenPath(const ARoot, ATokenID: string): string;
begin
  Result := IncludeTrailingPathDelimiter(TokenDirectory(ARoot)) + ATokenID
    + '.toml';
end;

function ReadTokenText(const APath: string; out AText: string): Boolean;
var
  Stream: TStream;
begin
  Result := False;
  AText := '';
  try
    Stream := OpenRegistryFileWithoutFollowingLinks(APath);
  except
    on E: ELWPTRegistryFileOpenError do Exit;
  end;
  try
    if Stream.Size > MAX_TOKEN_DOCUMENT_BYTES then CorruptToken;
    SetLength(AText, Stream.Size);
    if Length(AText) > 0 then Stream.ReadBuffer(AText[1], Length(AText));
  finally
    Stream.Free;
  end;
  Result := True;
end;

procedure RequireOrigin(const ARoot: string);
begin
  if IsDirSymlinkOrJunction(ExpandFileName(ARoot)) then
    raise ELWPTRegistryError.CreateStable('registry_path_link',
      'registry paths cannot contain symbolic links or reparse points');
  if LoadRegistryConfiguration(ARoot).Role <> rrOrigin then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'publication tokens exist only on origins');
end;

function ListRegistryTokens(const ARoot: string): TLWPTRegistryTokenArray;
var
  Search: TSearchRec;
  Text, Name: string;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(TokenDirectory(ARoot))
    + '*.toml', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      Name := Search.Name;
      if not IsLowerHexText(ChangeFileExt(Name, ''), TOKEN_ID_LENGTH) then
        Continue;
      if not ReadTokenText(IncludeTrailingPathDelimiter(TokenDirectory(ARoot))
        + Name, Text) then Continue;
      if Count = Length(Result) then SetLength(Result, Count * 2 + 8);
      Result[Count] := ParseRegistryTokenDocument(Text);
      if Result[Count].ID <> ChangeFileExt(Name, '') then CorruptToken;
      Inc(Count);
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
  SetLength(Result, Count);
end;

function RegistryHasActiveToken(const ARoot, ANow: string): Boolean;
var
  Search: TSearchRec;
  Text, Name: string;
begin
  Result := False;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(TokenDirectory(ARoot))
    + '*.toml', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      Name := Search.Name;
      if not IsLowerHexText(ChangeFileExt(Name, ''), TOKEN_ID_LENGTH) then
        Continue;
      if not ReadTokenText(IncludeTrailingPathDelimiter(TokenDirectory(ARoot))
        + Name, Text) then Continue;
      try
        if RegistryTokenIsActive(ParseRegistryTokenDocument(Text), ANow) then
          Exit(True);
      except
        on E: ELWPTRegistryError do Continue;
      end;
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function CreateToken(const ARoot: string;
  const AActions: TLWPTRegistryTokenActions; const AExpiresDays: Integer;
  const ALabel, ANow: string; const ACreated: TDateTime;
  var ARecord: TLWPTRegistryToken): string; forward;

function IssueRegistryToken(const ARoot: string; const APatterns: array of string;
  const AActions: TLWPTRegistryTokenActions; const AExpiresDays: Integer;
  const ALabel, ANow: string; out ARecord: TLWPTRegistryToken): string;
var
  Existing: TLWPTRegistryTokenArray;
  Index, Active: Integer;
  Created: TDateTime;
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Deadline: QWord;
begin
  Result := '';
  ARecord := Default(TLWPTRegistryToken);
  RequireOrigin(ARoot);
  if (AExpiresDays < RegistryTokenMinimumExpiryDays)
    or (AExpiresDays > RegistryTokenMaximumExpiryDays) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--expires-days must be between 1 and 365');
  if AActions = [] then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--actions must name publish, yank, or both');
  if (Length(APatterns) < 1) or (Length(APatterns) > RegistryTokenMaximumPatterns) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--packages must name 1 to 64 package patterns');
  if not LabelIsValid(ALabel) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--label must be at most 128 printable ASCII characters');
  if not TryISO8601ToDate(ANow, Created, True)
    or not RegistryTimestampIsCanonical(ANow) then
    raise ELWPTRegistryError.CreateStable('invalid_timestamp',
      'token creation time must be canonical UTC');
  SetLength(ARecord.Patterns, Length(APatterns));
  for Index := 0 to High(APatterns) do
  begin
    if not RegistryTokenPatternIsValid(APatterns[Index]) then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        '--packages entries must be package names, a name prefix ending in *, or *');
    ARecord.Patterns[Index] := APatterns[Index];
  end;
  SortStrings(ARecord.Patterns);
  for Index := 1 to High(ARecord.Patterns) do
    if ARecord.Patterns[Index] = ARecord.Patterns[Index - 1] then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        '--packages entries must be unique');
  { Counting and creating form one step, serialized across processes, so
    concurrent issuance cannot pass the active-token cap. }
  Coordinator := TLWPTProducerLeaseCoordinator.Create(
    IncludeTrailingPathDelimiter(ExpandFileName(ARoot)) + 'locks');
  Lease := nil;
  try
    Deadline := GetTickCount64 + TOKEN_ISSUANCE_WAIT_MILLISECONDS;
    repeat
      Lease := Coordinator.TryAcquire(TOKEN_ISSUANCE_LEASE,
        'registry token issuance');
      if Assigned(Lease) then Break;
      if GetTickCount64 >= Deadline then
        raise ELWPTRegistryError.CreateStable('token_issuance_locked',
          'another process is issuing a token; retry');
      Sleep(10);
    until False;
    Existing := ListRegistryTokens(ARoot);
    Active := 0;
    for Index := 0 to High(Existing) do
      if RegistryTokenIsActive(Existing[Index], ANow) then Inc(Active);
    if Active >= MaximumActiveTokens then
      raise ELWPTRegistryError.CreateStable('token_limit_exceeded',
        'the origin already has the maximum number of active tokens');
    Result := CreateToken(ARoot, AActions, AExpiresDays, ALabel, ANow, Created,
      ARecord);
  finally
    Lease.Free;
    Coordinator.Free;
  end;
end;

function CreateToken(const ARoot: string;
  const AActions: TLWPTRegistryTokenActions; const AExpiresDays: Integer;
  const ALabel, ANow: string; const ACreated: TDateTime;
  var ARecord: TLWPTRegistryToken): string;
var
  IDBytes: array[0..15] of Byte;
  SecretBytes: array[0..31] of Byte;
  Secret: string;
begin
  RegistryRandomBytes(IDBytes[0], SizeOf(IDBytes));
  RegistryRandomBytes(SecretBytes[0], SizeOf(SecretBytes));
  try
    ARecord.ID := BytesToHex(IDBytes[0], SizeOf(IDBytes));
    Secret := Base64URLEncode(SecretBytes[0], SizeOf(SecretBytes));
    ARecord.TokenLabel := ALabel;
    ARecord.Actions := AActions;
    ARecord.CreatedAt := ANow;
    ARecord.ExpiresAt := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
      IncDay(ACreated, AExpiresDays));
    ARecord.RevokedAt := '';
    ARecord.SecretHash := SecretHash(Secret);
    ForceDirectories(TokenDirectory(ARoot));
    RegistryWritePrivateFile(TokenPath(ARoot, ARecord.ID),
      StagingDirectory(ARoot), BytesOf(RegistryTokenDocument(ARecord)), False);
    Result := TOKEN_PREFIX + ARecord.ID + '_' + Secret;
  finally
    FillChar(SecretBytes, SizeOf(SecretBytes), 0);
    if Length(Secret) > 0 then FillChar(Secret[1], Length(Secret), 0);
  end;
end;

function RevokeRegistryToken(const ARoot, ATokenID, ANow: string): Boolean;
var
  Text: string;
  Token: TLWPTRegistryToken;
begin
  RequireOrigin(ARoot);
  if not IsLowerHexText(ATokenID, TOKEN_ID_LENGTH) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--token-id must be 32 lowercase hexadecimal digits');
  if not RegistryTimestampIsCanonical(ANow) then
    raise ELWPTRegistryError.CreateStable('invalid_timestamp',
      'revocation time must be canonical UTC');
  if not ReadTokenText(TokenPath(ARoot, ATokenID), Text) then
    raise ELWPTRegistryError.CreateStable('token_not_found',
      'no token with that ID exists on this origin');
  Token := ParseRegistryTokenDocument(Text);
  if Token.ID <> ATokenID then CorruptToken;
  if Token.RevokedAt <> '' then Exit(False);
  Token.RevokedAt := ANow;
  RegistryWritePrivateFile(TokenPath(ARoot, ATokenID), StagingDirectory(ARoot),
    BytesOf(RegistryTokenDocument(Token)), True);
  Result := True;
end;

function AuthenticateRegistryBearer(const ARoot, AAuthorization,
  ANow: string; out AToken: TLWPTRegistryToken;
  out AFailure: TLWPTRegistryAuthFailure): Boolean;
var
  Credential, Secret, Text, TokenID: string;
  Matches: Boolean;
begin
  Result := False;
  AToken := Default(TLWPTRegistryToken);
  AFailure := rafMissing;
  if AAuthorization = '' then Exit;
  AFailure := rafMalformed;
  if (Length(AAuthorization) < 8)
    or not SameText(Copy(AAuthorization, 1, 7), 'Bearer ') then Exit;
  Credential := Copy(AAuthorization, 8, MaxInt);
  if not RegistryTokenIsWellFormed(Credential) then Exit;
  TokenID := Copy(Credential, Length(TOKEN_PREFIX) + 1, TOKEN_ID_LENGTH);
  Secret := Copy(Credential, Length(TOKEN_PREFIX) + TOKEN_ID_LENGTH + 2, MaxInt);
  try
    AFailure := rafUnknown;
    if not ReadTokenText(TokenPath(ARoot, TokenID), Text) then Exit;
    try
      AToken := ParseRegistryTokenDocument(Text);
    except
      on E: ELWPTRegistryError do Exit;
    end;
    if AToken.ID <> TokenID then Exit;
    Matches := ConstantTimeEqual(SecretHash(Secret), AToken.SecretHash);
    if not Matches then
    begin
      AFailure := rafMismatch;
      Exit;
    end;
    if AToken.RevokedAt <> '' then
    begin
      AFailure := rafRevoked;
      Exit;
    end;
    if not (ANow < AToken.ExpiresAt) then
    begin
      AFailure := rafExpired;
      Exit;
    end;
    AFailure := rafNone;
    Result := True;
  finally
    if Length(Secret) > 0 then FillChar(Secret[1], Length(Secret), 0);
    if Length(Credential) > 0 then FillChar(Credential[1], Length(Credential), 0);
    if not Result then AToken := Default(TLWPTRegistryToken);
  end;
end;

end.
