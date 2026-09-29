{ LWPT.Command.Registry — initialize and serve a self-hosted origin. }
unit LWPT.Command.Registry;

{$I Shared.inc}
{$J-}

interface

type
  { Raw registry init options as supplied on the command line. Empty budget
    values select the documented defaults. }
  TLWPTRegistryInitOptions = record
    DataDirectory, Identity, BaseURL, ListenAddress: string;
    Port: Integer;
    TLSPKCS12Path, TLSPasswordEnvironment: string;
    Role, Upstream, KeyID, PublicKey: string;
    MaximumStoreBytes, MaximumSyncBytes: string;
  end;

function RegistryInitDefaults: TLWPTRegistryInitOptions;
function CmdRegistryInit(const AOptions: TLWPTRegistryInitOptions): Integer;
function CmdRegistryServe(const ADataDirectory: string): Integer;
function CmdRegistrySync(const ADataDirectory: string): Integer;
function CmdRegistryVerify(const ADataDirectory: string): Integer;
function CmdRegistryRotateKey(const ADataDirectory, AExpectedKeyID: string): Integer;
{ Issues a publication token; the token is the command's only stdout line. }
function CmdRegistryIssueToken(const ADataDirectory, APackages, AActions,
  AExpiresDays, ALabel: string): Integer;
function CmdRegistryRevokeToken(const ADataDirectory, ATokenID: string): Integer;
{ Publishes one archive to a remote origin (ADR-0049); the result line is
  the command's only stdout line. }
function CmdRegistryPublish(const AArchivePath, AOrigin, AKeyID, APublicKey,
  ATokenEnvironment: string): Integer;

implementation

uses
  Classes,
  DateUtils,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.Core,
  LWPT.OutputRenderer,
  LWPT.Registry.Client,
  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store,
  LWPT.Registry.Tokens;

var
  ActiveRegistryServer: TLWPTRegistryServer = nil;

{$IFDEF UNIX}
function CSignal(const ASignal: LongInt;
  const AHandler: Pointer): Pointer; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'signal';
  {$ELSE}
  external name 'signal';
  {$ENDIF}

procedure RegistrySignalHandler(ASignal: LongInt); cdecl;
begin
  if Assigned(ActiveRegistryServer) then ActiveRegistryServer.RequestStop;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function RegistryConsoleControlHandler(AControlType: DWORD): BOOL; stdcall;
begin
  Result := AControlType in [CTRL_C_EVENT, CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT, CTRL_SHUTDOWN_EVENT];
  if Result and Assigned(ActiveRegistryServer) then
    ActiveRegistryServer.RequestStop;
end;
{$ENDIF}

function CurrentTimestamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

function RegistryInitDefaults: TLWPTRegistryInitOptions;
begin
  Result := Default(TLWPTRegistryInitOptions);
  Result.DataDirectory := REGISTRY_DEFAULT_DATA_DIR;
  Result.BaseURL := REGISTRY_DEFAULT_BASE_URL;
  Result.ListenAddress := REGISTRY_DEFAULT_LISTEN_ADDRESS;
  Result.Port := REGISTRY_DEFAULT_PORT;
  Result.Role := 'origin';
end;

function ParseByteBudget(const AValue: string; const ADefault: Int64): Int64;
begin
  if AValue = '' then Exit(ADefault);
  if not TryStrToInt64(AValue, Result) or (Result < 1)
    or (IntToStr(Result) <> AValue) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'byte budgets must be positive decimal integers');
end;

function CmdRegistryInit(const AOptions: TLWPTRegistryInitOptions): Integer;
var
  Config: TLWPTRegistryConfig;
  Store: TLWPTRegistryStore;
begin
  if (AOptions.Port < 1) or (AOptions.Port > 65535) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'port must be between 1 and 65535');
  Config := RegistryConfiguration(AOptions.Identity, AOptions.BaseURL,
    AOptions.ListenAddress, AOptions.Port, AOptions.TLSPKCS12Path,
    AOptions.TLSPasswordEnvironment);
  if AOptions.Role = 'mirror' then
  begin
    Config.Role := rrMirror;
    Config.UpstreamURL := AOptions.Upstream;
    Config.TrustKeyID := AOptions.KeyID;
    Config.TrustPublicKey := AOptions.PublicKey;
    Config.StoreBudgetBytes := ParseByteBudget(AOptions.MaximumStoreBytes,
      RegistryDefaultMirrorStoreBytes);
    Config.SyncBudgetBytes := ParseByteBudget(AOptions.MaximumSyncBytes,
      RegistryDefaultMirrorSyncBytes);
    if Config.TLSPKCS12Path <> '' then Config.TLSPKCS12Path := ExpandFileName(Config.TLSPKCS12Path);
    ValidateMirrorConfiguration(Config);
    Store := TLWPTRegistryMirror.Initialize(AOptions.DataDirectory, Config, CurrentTimestamp);
  end
  else
  begin
    if (AOptions.Role <> 'origin') or (AOptions.Upstream <> '') or (AOptions.KeyID <> '')
      or (AOptions.PublicKey <> '') or (AOptions.MaximumStoreBytes <> '')
      or (AOptions.MaximumSyncBytes <> '') then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        'role must be origin or mirror; upstream, pins, and byte budgets are mirror-only');
    Store := TLWPTRegistryStore.Initialize(AOptions.DataDirectory, Config, CurrentTimestamp);
  end;
  try
    WriteLn('initialized registry ', AOptions.Role, ' ', Store.Config.Identity, ' at ',
      ExpandFileName(AOptions.DataDirectory));
  finally
    Store.Free;
  end;
  Result := 0;
end;

function OpenRegistryStore(const ADataDirectory: string): TLWPTRegistryStore;
begin
  if LoadRegistryConfiguration(ADataDirectory).Role = rrMirror then
    Result := TLWPTRegistryMirror.Create(ADataDirectory)
  else Result := TLWPTRegistryStore.Create(ADataDirectory);
end;

function CmdRegistryRotateKey(const ADataDirectory, AExpectedKeyID: string): Integer;
var
  Store: TLWPTRegistryStore;
begin
  if AExpectedKeyID = '' then
    raise ELWPTRegistryError.CreateStable('invalid_configuration', 'rotate-key requires --from-key');
  Store := OpenRegistryStore(ADataDirectory);
  try
    Store.RotateKey(AExpectedKeyID, CurrentTimestamp);
    WriteLn('rotated registry signing key at sequence ', Store.LoadCurrentState.Sequence);
  finally
    Store.Free;
  end;
  Result := 0;
end;

function CmdRegistrySync(const ADataDirectory: string): Integer;
var
  Mirror: TLWPTRegistryMirror;
begin
  Mirror := TLWPTRegistryMirror.Create(ADataDirectory);
  try
    Mirror.Synchronize;
    WriteLn('synchronized registry mirror ', Mirror.Config.Identity);
  finally
    Mirror.Free;
  end;
  Result := 0;
end;

function CmdRegistryVerify(const ADataDirectory: string): Integer;
var
  Store: TLWPTRegistryStore;
  Tokens: TLWPTRegistryTokenArray;
  Line: string;
  Index: Integer;
begin
  Store := OpenRegistryStore(ADataDirectory);
  try
    if Store is TLWPTRegistryMirror then Write(TLWPTRegistryMirror(Store).VerifyMirror)
    else
    begin
      WriteLn('role = "origin"');
      WriteLn('origin = ', RegistryTOMLQuote(Store.Config.Identity));
      WriteLn('sequence = ', Store.LoadCurrentState.Sequence);
      Tokens := ListRegistryTokens(ADataDirectory);
      Line := 'tokens = [';
      for Index := 0 to High(Tokens) do
      begin
        if Index > 0 then Line := Line + ', ';
        Line := Line + RegistryTokenMetadata(Tokens[Index]);
      end;
      WriteLn(Line, ']');
    end;
  finally
    Store.Free;
  end;
  Result := 0;
end;

function CmdRegistryIssueToken(const ADataDirectory, APackages, AActions,
  AExpiresDays, ALabel: string): Integer;
var
  Actions: TLWPTRegistryTokenActions;
  Days: Integer;
  Parts: TStringList;
  Patterns: array of string;
  Index: Integer;
  Token: string;
  TokenRecord: TLWPTRegistryToken;
begin
  if APackages = '' then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'issue-token requires --packages');
  Days := RegistryTokenDefaultExpiryDays;
  if AExpiresDays <> '' then
    if not TryStrToInt(AExpiresDays, Days) or (IntToStr(Days) <> AExpiresDays)
      or (Days < RegistryTokenMinimumExpiryDays)
      or (Days > RegistryTokenMaximumExpiryDays) then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        '--expires-days must be a decimal integer from 1 to 365');
  if AActions = '' then Actions := [rtaPublish]
  else if not ParseRegistryTokenActions(AActions, Actions) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      '--actions must be publish, yank, or publish,yank');
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.QuoteChar := #0;
    Parts.DelimitedText := APackages;
    SetLength(Patterns, Parts.Count);
    for Index := 0 to Parts.Count - 1 do Patterns[Index] := Parts[Index];
  finally
    Parts.Free;
  end;
  Token := IssueRegistryToken(ADataDirectory, Patterns, Actions, Days, ALabel,
    CurrentTimestamp, TokenRecord);
  try
    WriteCommandOutcomeLine(Token);
  finally
    if Length(Token) > 0 then FillChar(Token[1], Length(Token), 0);
  end;
  Result := 0;
end;

function CmdRegistryRevokeToken(const ADataDirectory, ATokenID: string): Integer;
begin
  if ATokenID = '' then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'revoke-token requires --token-id');
  if RevokeRegistryToken(ADataDirectory, ATokenID, CurrentTimestamp) then
    WriteLn('revoked registry token ', ATokenID)
  else WriteLn('registry token ', ATokenID, ' was already revoked');
  Result := 0;
end;

function CmdRegistryPublish(const AArchivePath, AOrigin, AKeyID, APublicKey,
  ATokenEnvironment: string): Integer;
var
  Options: TLWPTRegistryPublishOptions;
begin
  Options.ArchivePath := AArchivePath;
  Options.Origin := AOrigin;
  Options.KeyID := AKeyID;
  Options.PublicKey := APublicKey;
  Options.TokenEnvironment := ATokenEnvironment;
  WriteCommandOutcomeLine(RegistryPublishResultLine(PublishToRegistry(Options)));
  Result := 0;
end;

function CmdRegistryServe(const ADataDirectory: string): Integer;
var
  Server: TLWPTRegistryServer;
  Store: TLWPTRegistryStore;
  {$IFDEF INSTALL_TESTING}
  Barrier: string;
  {$ENDIF}
begin
  {$IFDEF INSTALL_TESTING}
  { <ready-path>|<release-path>: pause each publication between its durable
    checkpoint and the pointer replacement, so a test can kill the server
    there. }
  Barrier := TestSeamValue('REGISTRY_PUBLICATION_BARRIER');
  if Pos('|', Barrier) > 1 then
    SetRegistryPublicationBarrierForTesting(Copy(Barrier, 1, Pos('|', Barrier) - 1),
      Copy(Barrier, Pos('|', Barrier) + 1, MaxInt));
  {$ENDIF}
  Store := OpenRegistryStore(ADataDirectory);
  try
    Server := TLWPTRegistryServer.Create(Store);
    try
      Store.EnsureFreshCheckpoint(RegistryTimestampNow);
      ActiveRegistryServer := Server;
      {$IFDEF UNIX}
      CSignal(SIGINT, @RegistrySignalHandler);
      CSignal(SIGTERM, @RegistrySignalHandler);
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      Windows.SetConsoleCtrlHandler(@RegistryConsoleControlHandler, True);
      {$ENDIF}
      Server.Run;
    finally
      {$IFDEF MSWINDOWS}
      Windows.SetConsoleCtrlHandler(@RegistryConsoleControlHandler, False);
      {$ENDIF}
      ActiveRegistryServer := nil;
      Server.Free;
    end;
  finally
    Store.Free;
  end;
  Result := 0;
end;

end.
