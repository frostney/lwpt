program LWPT.Registry.Tokens.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Tokens,
  TestingPascalLibrary,
  Tests.Scratch;

const
  ISSUED_AT = '2026-08-23T10:00:00Z';

type
  TIssueThread = class(TThread)
  private
    FRoot: string;
  protected
    procedure Execute; override;
  public
    Issued: Boolean;
    Failure: string;
    constructor Create(const ARoot: string);
  end;

  TRegistryTokenContract = class(TTestSuite)
  private
    FScratch: string;
    function Origin: string;
  protected
    procedure BeforeEach; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestTokenGrammar;
    procedure TestPatternsAndActions;
    procedure TestExpiryBounds;
    procedure TestIssuedRecordStoresOnlyAHash;
    procedure TestAuthenticationCauses;
    procedure TestRevocationIsImmediateAndIdempotent;
    procedure TestActiveTokenDiscovery;
    procedure TestTokensAreOriginOnly;
    procedure TestConcurrentIssuanceRespectsTheCap;
  end;

constructor TIssueThread.Create(const ARoot: string);
begin
  FRoot := ARoot;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TIssueThread.Execute;
var
  TokenRecord: TLWPTRegistryToken;
begin
  try
    IssueRegistryToken(FRoot, ['demo'], [rtaPublish], 90, '', ISSUED_AT,
      TokenRecord);
    Issued := True;
  except
    on E: Exception do Failure := E.Message;
  end;
end;

function TRegistryTokenContract.Origin: string;
var
  Store: TLWPTRegistryStore;
begin
  Result := FScratch + '/origin';
  if DirectoryExists(Result) then Exit;
  Store := TLWPTRegistryStore.Initialize(Result, RegistryConfiguration('',
    REGISTRY_DEFAULT_BASE_URL, REGISTRY_DEFAULT_LISTEN_ADDRESS,
    REGISTRY_DEFAULT_PORT, '', ''), ISSUED_AT);
  Store.Free;
end;

procedure TRegistryTokenContract.BeforeEach;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
  FScratch := CreateScratchRoot('registry-tokens');
end;

procedure TRegistryTokenContract.AfterAll;
begin
  if FScratch <> '' then RecursiveDelete(FScratch);
end;

procedure TRegistryTokenContract.TestTokenGrammar;
var
  Token: string;
  TokenRecord: TLWPTRegistryToken;
begin
  Token := IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, 'ci',
    ISSUED_AT, TokenRecord);
  Expect<Boolean>(RegistryTokenIsWellFormed(Token)).ToBe(True);
  Expect<Integer>(Length(Token)).ToBe(Length(PROGRAM_NAME + '_rt1_') + 32 + 1 + 43);
  Expect<Boolean>(Pos(PROGRAM_NAME + '_rt1_' + TokenRecord.ID + '_', Token) = 1)
    .ToBe(True);
  Expect<Boolean>(RegistryTokenIsWellFormed(Token + 'x')).ToBe(False);
  Expect<Boolean>(RegistryTokenIsWellFormed(UpperCase(Token))).ToBe(False);
  Expect<Boolean>(RegistryTokenIsWellFormed(StringReplace(Token, '_rt1_',
    '_rt2_', []))).ToBe(False);
  Expect<Boolean>(RegistryTokenIsWellFormed('')).ToBe(False);
end;

procedure TRegistryTokenContract.TestPatternsAndActions;
var
  Actions: TLWPTRegistryTokenActions;
  Token: TLWPTRegistryToken;
begin
  Expect<Boolean>(RegistryTokenPatternIsValid('*')).ToBe(True);
  Expect<Boolean>(RegistryTokenPatternIsValid('demo')).ToBe(True);
  Expect<Boolean>(RegistryTokenPatternIsValid('demo-*')).ToBe(True);
  Expect<Boolean>(RegistryTokenPatternIsValid('Demo')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternIsValid('de*mo')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternIsValid('**')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternIsValid('-x*')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternIsValid('')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternMatches('demo-*', 'demo-lib')).ToBe(True);
  Expect<Boolean>(RegistryTokenPatternMatches('demo-*', 'demolib')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternMatches('demo', 'demo-lib')).ToBe(False);
  Expect<Boolean>(RegistryTokenPatternMatches('*', 'anything')).ToBe(True);
  Expect<Boolean>(ParseRegistryTokenActions('publish,yank', Actions)).ToBe(True);
  Expect<Boolean>(Actions = [rtaPublish, rtaYank]).ToBe(True);
  Expect<Boolean>(ParseRegistryTokenActions('yank', Actions)).ToBe(True);
  Expect<Boolean>(ParseRegistryTokenActions('delete', Actions)).ToBe(False);
  Expect<Boolean>(ParseRegistryTokenActions('', Actions)).ToBe(False);
  Token := Default(TLWPTRegistryToken);
  Token.Actions := [rtaYank];
  SetLength(Token.Patterns, 1);
  Token.Patterns[0] := 'demo-*';
  Expect<Boolean>(RegistryTokenPermits(Token, rtaYank, 'demo-lib')).ToBe(True);
  Expect<Boolean>(RegistryTokenPermits(Token, rtaYank, 'other')).ToBe(False);
  Expect<Boolean>(RegistryTokenPermits(Token, rtaPublish, 'demo-lib')).ToBe(False);
  Expect<Boolean>(RegistryTokenPermits(Token, rtaPublish, '')).ToBe(False);
  Token.Actions := [rtaPublish];
  Expect<Boolean>(RegistryTokenPermits(Token, rtaPublish, '')).ToBe(True);
end;

procedure TRegistryTokenContract.TestExpiryBounds;
const
  INVALID_DAYS: array[0..2] of Integer = (0, 366, -1);
var
  TokenRecord: TLWPTRegistryToken;
  Days, Index: Integer;
  Diagnostic: string;
begin
  IssueRegistryToken(Origin, ['demo'], [rtaPublish],
    RegistryTokenDefaultExpiryDays, '', ISSUED_AT, TokenRecord);
  Expect<string>(TokenRecord.ExpiresAt).ToBe('2026-11-21T10:00:00Z');
  IssueRegistryToken(Origin, ['demo'], [rtaPublish], 1, '', ISSUED_AT,
    TokenRecord);
  Expect<string>(TokenRecord.ExpiresAt).ToBe('2026-08-24T10:00:00Z');
  IssueRegistryToken(Origin, ['demo'], [rtaPublish], 365, '', ISSUED_AT,
    TokenRecord);
  Expect<string>(TokenRecord.ExpiresAt).ToBe('2027-08-23T10:00:00Z');
  for Index := 0 to 2 do
  begin
    Days := INVALID_DAYS[Index];
    Diagnostic := '';
    try
      IssueRegistryToken(Origin, ['demo'], [rtaPublish], Days, '', ISSUED_AT,
        TokenRecord);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    Expect<Boolean>(Pos('invalid_configuration:', Diagnostic) = 1).ToBe(True);
  end;
end;

procedure TRegistryTokenContract.TestIssuedRecordStoresOnlyAHash;
var
  Token, Text, Secret: string;
  TokenRecord: TLWPTRegistryToken;
  {$IFDEF UNIX}
  Info: Stat;
  {$ENDIF}
begin
  Token := IssueRegistryToken(Origin, ['zeta', 'alpha*'], [rtaYank, rtaPublish],
    30, 'release ci', ISSUED_AT, TokenRecord);
  Secret := Copy(Token, Length(PROGRAM_NAME + '_rt1_') + 32 + 2, MaxInt);
  Text := ReadBinaryFile(Origin + '/auth/tokens/' + TokenRecord.ID + '.toml');
  Expect<Boolean>(Pos(Secret, Text) = 0).ToBe(True);
  Expect<Boolean>(Pos(Token, Text) = 0).ToBe(True);
  Expect<Boolean>(Pos('packages = ["alpha*", "zeta"]', Text) > 0).ToBe(True);
  Expect<Boolean>(Pos('actions = ["publish", "yank"]', Text) > 0).ToBe(True);
  Expect<Boolean>(Pos('secret_hash = "' + SHA256BytesPrefixed(BytesOf(Secret))
    + '"', Text) > 0).ToBe(True);
  Expect<string>(ParseRegistryTokenDocument(Text).ID).ToBe(TokenRecord.ID);
  Expect<Boolean>(Pos('secret_hash', RegistryTokenMetadata(TokenRecord)) = 0)
    .ToBe(True);
  {$IFDEF UNIX}
  Expect<Integer>(FpStat(Origin + '/auth/tokens/' + TokenRecord.ID + '.toml',
    Info)).ToBe(0);
  Expect<Integer>(Info.st_mode and &777).ToBe(&600);
  {$ENDIF}
end;

procedure TRegistryTokenContract.TestAuthenticationCauses;
var
  Token, Expired: string;
  TokenRecord, Verified: TLWPTRegistryToken;
  Failure: TLWPTRegistryAuthFailure;
  Now: string;
  Last: Char;
begin
  Now := '2026-08-24T00:00:00Z';
  Token := IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, '',
    ISSUED_AT, TokenRecord);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer ' + Token, Now,
    Verified, Failure)).ToBe(True);
  Expect<string>(Verified.ID).ToBe(TokenRecord.ID);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'bearer ' + Token, Now,
    Verified, Failure)).ToBe(True);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, '', Now, Verified,
    Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('missing');
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Basic ' + Token, Now,
    Verified, Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('malformed');
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer '
    + StringReplace(Token, TokenRecord.ID, StringOfChar('0', 32), []), Now,
    Verified, Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('unknown');
  Last := 'Q';
  if Token[Length(Token)] = 'Q' then Last := 'R';
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer '
    + Copy(Token, 1, Length(Token) - 1) + Last, Now, Verified,
    Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('mismatch');
  Expect<string>(Verified.ID).ToBe('');
  Expired := IssueRegistryToken(Origin, ['demo'], [rtaPublish], 1, '',
    ISSUED_AT, TokenRecord);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer ' + Expired,
    '2026-08-24T09:59:59Z', Verified, Failure)).ToBe(True);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer ' + Expired,
    '2026-08-24T10:00:00Z', Verified, Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('expired');
end;

procedure TRegistryTokenContract.TestRevocationIsImmediateAndIdempotent;
var
  Token: string;
  TokenRecord, Verified: TLWPTRegistryToken;
  Failure: TLWPTRegistryAuthFailure;
  Tokens: TLWPTRegistryTokenArray;
begin
  Token := IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, '',
    ISSUED_AT, TokenRecord);
  Expect<Boolean>(RevokeRegistryToken(Origin, TokenRecord.ID,
    '2026-08-23T11:00:00Z')).ToBe(True);
  Expect<Boolean>(AuthenticateRegistryBearer(Origin, 'Bearer ' + Token,
    '2026-08-23T12:00:00Z', Verified, Failure)).ToBe(False);
  Expect<string>(RegistryAuthFailureText(Failure)).ToBe('revoked');
  Expect<Boolean>(RevokeRegistryToken(Origin, TokenRecord.ID,
    '2026-08-23T12:00:00Z')).ToBe(False);
  Tokens := ListRegistryTokens(Origin);
  Expect<Integer>(Length(Tokens)).ToBe(1);
  Expect<string>(Tokens[0].RevokedAt).ToBe('2026-08-23T11:00:00Z');
end;

procedure TRegistryTokenContract.TestActiveTokenDiscovery;
var
  TokenRecord: TLWPTRegistryToken;
begin
  Expect<Boolean>(RegistryHasActiveToken(Origin, ISSUED_AT)).ToBe(False);
  IssueRegistryToken(Origin, ['demo'], [rtaPublish], 1, '', ISSUED_AT,
    TokenRecord);
  Expect<Boolean>(RegistryHasActiveToken(Origin, ISSUED_AT)).ToBe(True);
  Expect<Boolean>(RegistryHasActiveToken(Origin, '2026-08-25T00:00:00Z'))
    .ToBe(False);
  IssueRegistryToken(Origin, ['demo'], [rtaPublish], 30, '', ISSUED_AT,
    TokenRecord);
  RevokeRegistryToken(Origin, TokenRecord.ID, ISSUED_AT);
  Expect<Boolean>(RegistryHasActiveToken(Origin, '2026-08-25T00:00:00Z'))
    .ToBe(False);
end;

procedure TRegistryTokenContract.TestTokensAreOriginOnly;
var
  Diagnostic: string;
  TokenRecord: TLWPTRegistryToken;
begin
  Diagnostic := '';
  try
    IssueRegistryToken(FScratch + '/missing', ['demo'], [rtaPublish], 90, '',
      ISSUED_AT, TokenRecord);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('origin_not_initialized:', Diagnostic) = 1).ToBe(True);
  Diagnostic := '';
  try
    IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, 'bad' + #10 + 'label',
      ISSUED_AT, TokenRecord);
  except
    on E: Exception do Diagnostic := E.Message;
  end;
  Expect<Boolean>(Pos('invalid_configuration:', Diagnostic) = 1).ToBe(True);
end;

procedure TRegistryTokenContract.TestConcurrentIssuanceRespectsTheCap;
var
  Threads: array[0..5] of TIssueThread;
  TokenRecord: TLWPTRegistryToken;
  Index, Issued, Refused, Active: Integer;
  Tokens: TLWPTRegistryTokenArray;
begin
  SetRegistryMaximumActiveTokensForTesting(3);
  try
    IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, '', ISSUED_AT,
      TokenRecord);
    IssueRegistryToken(Origin, ['demo'], [rtaPublish], 90, '', ISSUED_AT,
      TokenRecord);
    for Index := 0 to High(Threads) do
      Threads[Index] := TIssueThread.Create(Origin);
    Issued := 0;
    Refused := 0;
    for Index := 0 to High(Threads) do
    begin
      Threads[Index].WaitFor;
      if Threads[Index].Issued then Inc(Issued);
      if Pos('token_limit_exceeded:', Threads[Index].Failure) = 1 then
        Inc(Refused);
      Threads[Index].Free;
    end;
    Expect<Integer>(Issued).ToBe(1);
    Expect<Integer>(Refused).ToBe(5);
    Tokens := ListRegistryTokens(Origin);
    Active := 0;
    for Index := 0 to High(Tokens) do
      if RegistryTokenIsActive(Tokens[Index], ISSUED_AT) then Inc(Active);
    Expect<Integer>(Active).ToBe(3);
  finally
    SetRegistryMaximumActiveTokensForTesting(0);
  end;
end;

procedure TRegistryTokenContract.SetupTests;
begin
  Test('tokens follow the prefixed identifier and secret grammar', TestTokenGrammar);
  Test('patterns and actions scope a token', TestPatternsAndActions);
  Test('every token expires within 1 to 365 days', TestExpiryBounds);
  Test('issued records hold only a hash in an owner-only file',
    TestIssuedRecordStoresOnlyAHash);
  Test('authentication distinguishes causes internally', TestAuthenticationCauses);
  Test('revocation takes effect immediately and is idempotent',
    TestRevocationIsImmediateAndIdempotent);
  Test('publication is enabled only by an active token', TestActiveTokenDiscovery);
  Test('tokens require an initialized origin and a printable label',
    TestTokensAreOriginOnly);
  Test('concurrent issuance cannot pass the active-token cap',
    TestConcurrentIssuanceRespectsTheCap);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryTokenContract.Create('registry tokens'));
  TestRunnerProgram.Run;
end.
