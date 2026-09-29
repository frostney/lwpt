{ Tests.RegistryPublish -- a running origin for `registry publish` E2E tests.

  TPublishOrigin initializes a data directory through the CLI, reads its
  trust pin from the published key record, issues tokens, and runs
  `registry serve` as a bounded child bound to this test program. The
  base URL port and the listen port may differ, so a test can put a proxy
  on the advertised port. Package archives are synthesised here too. }
unit Tests.RegistryPublish;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Process,
  SysUtils,

  Tests.LwptSubprocess,
  Tests.RegistryHTTP,
  Tests.RegistryProcess;

const
  PUBLISH_TLS_PASSWORD = 'test-only';
  PUBLISH_RUN_TIMEOUT_MILLISECONDS = 180000;

type
  TPublishOrigin = class
  private
    FScratch, FData, FBase, FHost, FIdentity, FKeyID, FPublicKey,
      FOutputs: string;
    FListenPort: Word;
    FHTTPS: Boolean;
    FServe: TProcess;
    procedure ReadPin;
    function Environment: TStringArray;
  public
    { Runs `registry init`. ABasePort is advertised in the base URL (and so
      in the origin identity); AListenPort is where `serve` listens. AHost
      names the base URL host: an HTTPS origin may use `127.0.0.1`, which
      the TLS fixture also names. }
    constructor Create(const AScratch, AName: string; const ABasePort,
      AListenPort: Word; const AHTTPS: Boolean = False;
      const AIdentity: string = ''; const AHost: string = 'localhost');
    { Copies another origin's token record here, so this origin accepts
      that token too. }
    procedure AdoptToken(ASource: TPublishOrigin; const AToken: string);
    destructor Destroy; override;
    { Re-runs init to move the listener, keeping identity and keys. }
    procedure Listen(const APort: Word);
    function IssueToken(const AExtra: array of string): string;
    procedure RevokeToken(const AToken: string);
    { Rewrites the token record so it expired long ago. }
    procedure ExpireToken(const AToken: string);
    procedure Start(const ATesting: Boolean = False);
    { Start with AEnvironment ("KEY=value") added to the child's
      environment, e.g. a test-build seam. Readiness requires the child's
      own bind announcement, then this registry's discovery document. When
      the base URL and listener share a port, a port another process took
      after it was chosen moves the origin to a fresh one (Base changes,
      Identity does not). }
    procedure StartWith(const ATesting: Boolean;
      const AEnvironment: array of string);
    procedure Stop;
    { Stops through the bounded helper and reports how the child ended. }
    function StopGracefully: TRegistryStopResult;
    { Terminates the server without a graceful shutdown: SIGKILL on Unix,
      TerminateProcess on Windows. }
    procedure Kill;
    function Request(const AMethod, ATarget: string; const AHeaders: array of string;
      const ABody: TBytes): TRawHTTPResponse;
    function LatestSequence: Integer;
    property Base: string read FBase;
    property Host: string read FHost;
    { The origin identity fixed at initialization; Base may move. }
    property Identity: string read FIdentity;
    property DataDirectory: string read FData;
    property KeyID: string read FKeyID;
    property PublicKey: string read FPublicKey;
    property ListenPort: Word read FListenPort;
    property Outputs: string read FOutputs;
    property Serve: TProcess read FServe;
  end;

{ A package tar.gz with one top-level directory <name>-<version>/. }
function PublishTarGz(const AName, AVersion, AContent: string;
  const AManifestExtra: string = ''): TBytes;
{ A package zip; AVariant changes entry order, method, and timestamps
  without changing the normalized content. }
function PublishZip(const AName, AVersion, AContent: string;
  const AVariant: Integer = 0; const AManifestExtra: string = ''): TBytes;
function TokenSecret(const AToken: string): string;
function TokenID(const AToken: string): string;
{ Runs `registry publish` in ADirectory with the token in AVariable. An
  empty AVariable leaves --token-env out, so the default variable applies. }
function RunPublish(const AArchive, AOrigin, AKeyID, APublicKey, AVariable,
  AToken, ADirectory: string; const AExtraArguments: array of string;
  const AExtraEnvironment: array of string; const ATesting: Boolean = False): TLwptResult;
{ The one stdout line a successful publish prints, or ''. }
function PublishLine(const AResult: TLwptResult): string;
{ The archive hash a successful publish line names. }
function PublishedArchiveHash(const ALine: string): string;
function PublishedRecordHash(const ALine: string): string;
procedure WriteBinaryFile(const APath: string; const ABytes: TBytes);
function TLSFixturePath: string;
function TestRootCertificatePath: string;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  StrUtils,

  HTTPClient,
  Tests.RegistryOrigin,
  Tests.Scratch,
  Tests.TarSynth,
  Tests.ZipSynth,
  TransportSecurity;

function TLSFixturePath: string;
begin
  Result := ExpandFileName('tests/fixtures/registry/localhost-native-identity.p12');
end;

function TestRootCertificatePath: string;
begin
  Result := ExpandFileName('packages/httpclient/source/fixtures/test-root-cert.pem');
end;

function PasswordVariable: string;
begin
  Result := UpperCase(RegistryProgramName) + '_REGISTRY_PUBLISH_E2E_PASSWORD';
end;

procedure WriteBinaryFile(const APath: string; const ABytes: TBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
end;

function Manifest(const AName, AVersion, AExtra: string): string;
begin
  Result := '[package]' + #10 + 'name = "' + AName + '"' + #10
    + 'version = "' + AVersion + '"' + #10 + AExtra;
end;

function PublishTarGz(const AName, AVersion, AContent,
  AManifestExtra: string): TBytes;
var
  Root: string;
begin
  Root := AName + '-' + AVersion + '/';
  Result := Gzip(BuildTar([MakeDirectoryEntry(Root),
    MakeRegularFileEntry(Root + 'lwpt.toml',
      TextBytes(Manifest(AName, AVersion, AManifestExtra))),
    MakeRegularFileEntry(Root + 'source/content.txt', TextBytes(AContent))]));
end;

function PublishZip(const AName, AVersion, AContent: string;
  const AVariant: Integer; const AManifestExtra: string): TBytes;
var
  Zip: TZipSynth;
  Entry: TZipSynthEntry;
  Index: Integer;
begin
  Zip := TZipSynth.Create;
  try
    if AVariant = 0 then
    begin
      Zip.AddText('lwpt.toml', Manifest(AName, AVersion, AManifestExtra));
      Zip.AddText('source/content.txt', AContent);
    end
    else
    begin
      { Other order, stored entries, other timestamps, a comment. }
      Zip.AddText('source/content.txt', AContent, 0);
      Zip.AddDirectory('source/');
      Zip.AddText('lwpt.toml', Manifest(AName, AVersion, AManifestExtra), 0);
      for Index := 0 to Zip.Count - 1 do
      begin
        Entry := Zip.Entry(Index);
        Entry.DosDate := $5A21;
        Entry.DosTime := $6000 + Index;
        Zip.SetEntry(Index, Entry);
      end;
      Zip.Comment := 'variant';
    end;
    Result := Zip.Build;
  finally
    Zip.Free;
  end;
end;

function TokenSecret(const AToken: string): string;
begin
  Result := Copy(AToken, Length(AToken) - 42, 43);
end;

function TokenID(const AToken: string): string;
begin
  Result := Copy(AToken, Length(RegistryProgramName + '_rt1_') + 1, 32);
end;

function RunPublish(const AArchive, AOrigin, AKeyID, APublicKey, AVariable,
  AToken, ADirectory: string; const AExtraArguments: array of string;
  const AExtraEnvironment: array of string; const ATesting: Boolean): TLwptResult;
var
  Arguments, Environment: array of string;
  Index: Integer;
  Variable: string;
begin
  Arguments := nil;
  SetLength(Arguments, 3);
  Arguments[0] := 'registry';
  Arguments[1] := 'publish';
  Arguments[2] := AArchive;
  if AOrigin <> '' then
  begin
    SetLength(Arguments, Length(Arguments) + 2);
    Arguments[High(Arguments) - 1] := '--origin';
    Arguments[High(Arguments)] := AOrigin;
  end;
  if AKeyID <> '' then
  begin
    SetLength(Arguments, Length(Arguments) + 2);
    Arguments[High(Arguments) - 1] := '--key-id';
    Arguments[High(Arguments)] := AKeyID;
  end;
  if APublicKey <> '' then
  begin
    SetLength(Arguments, Length(Arguments) + 2);
    Arguments[High(Arguments) - 1] := '--public-key';
    Arguments[High(Arguments)] := APublicKey;
  end;
  Variable := AVariable;
  if Variable <> '' then
  begin
    SetLength(Arguments, Length(Arguments) + 2);
    Arguments[High(Arguments) - 1] := '--token-env';
    Arguments[High(Arguments)] := Variable;
  end
  else Variable := UpperCase(RegistryProgramName) + '_REGISTRY_TOKEN';
  for Index := 0 to High(AExtraArguments) do
  begin
    SetLength(Arguments, Length(Arguments) + 1);
    Arguments[High(Arguments)] := AExtraArguments[Index];
  end;
  Environment := nil;
  SetLength(Environment, 1);
  { An empty value is how a test leaves the variable unset. }
  Environment[0] := Variable + '=' + AToken;
  for Index := 0 to High(AExtraEnvironment) do
  begin
    SetLength(Environment, Length(Environment) + 1);
    Environment[High(Environment)] := AExtraEnvironment[Index];
  end;
  if ATesting then
    Result := RunLwptTesting(Arguments, ADirectory, Environment,
      PUBLISH_RUN_TIMEOUT_MILLISECONDS)
  else
    Result := RunLwpt(Arguments, ADirectory, Environment,
      PUBLISH_RUN_TIMEOUT_MILLISECONDS);
end;

function PublishLine(const AResult: TLwptResult): string;
var
  Lines: TStringList;
  Line: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AResult.Stdout;
    for Line in Lines do
      if (Pos('published ', Line) = 1) or (Pos('already published ', Line) = 1) then
        Exit(Line);
  finally
    Lines.Free;
  end;
end;

function HashAfter(const ALine, AMarker: string): string;
var
  Start: Integer;
begin
  Start := Pos(AMarker, ALine);
  if Start = 0 then Exit('');
  Result := Copy(ALine, Start + Length(AMarker), 71);
end;

function PublishedArchiveHash(const ALine: string): string;
begin
  Result := HashAfter(ALine, '(archive ');
end;

function PublishedRecordHash(const ALine: string): string;
begin
  Result := HashAfter(ALine, ', record ');
end;

{ --- TPublishOrigin -------------------------------------------------------- }

constructor TPublishOrigin.Create(const AScratch, AName: string;
  const ABasePort, AListenPort: Word; const AHTTPS: Boolean;
  const AIdentity, AHost: string);
var
  Run: TLwptResult;
begin
  inherited Create;
  FScratch := AScratch;
  FData := AScratch + '/' + AName;
  FHTTPS := AHTTPS;
  FHost := AHost;
  FListenPort := AListenPort;
  if AHTTPS then FBase := 'https://' + FHost + ':' + IntToStr(ABasePort)
  else FBase := 'http://' + FHost + ':' + IntToStr(ABasePort);
  if AHTTPS then
    Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
      '--port', IntToStr(AListenPort), '--tls-pkcs12', TLSFixturePath,
      '--tls-password-env', PasswordVariable], FScratch, Environment,
      PUBLISH_RUN_TIMEOUT_MILLISECONDS)
  else if AIdentity <> '' then
    Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
      '--port', IntToStr(AListenPort), '--identity', AIdentity], FScratch, [],
      PUBLISH_RUN_TIMEOUT_MILLISECONDS)
  else
    Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
      '--port', IntToStr(AListenPort)], FScratch, [],
      PUBLISH_RUN_TIMEOUT_MILLISECONDS);
  if Run.TimedOut then
    raise Exception.Create('registry init exceeded its bound');
  FOutputs := FOutputs + Run.Stdout + Run.Stderr;
  if Run.ExitCode <> 0 then
    raise Exception.Create('registry init failed: ' + Run.Stderr);
  if AIdentity <> '' then FIdentity := AIdentity
  else FIdentity := FBase;
  ReadPin;
end;

destructor TPublishOrigin.Destroy;
begin
  Stop;
  inherited Destroy;
end;

function TPublishOrigin.Environment: TStringArray;
begin
  Result := nil;
  if FHTTPS then
  begin
    SetLength(Result, 1);
    Result[0] := PasswordVariable + '=' + PUBLISH_TLS_PASSWORD;
  end;
end;

function QuotedValue(const AText, AKey: string): string;
var
  Start: Integer;
begin
  Result := '';
  Start := Pos(#10 + AKey + ' = "', #10 + AText);
  if Start = 0 then Exit;
  Result := Copy(AText, Start + Length(AKey) + 4, MaxInt);
  Result := Copy(Result, 1, Pos('"', Result) - 1);
end;

procedure TPublishOrigin.ReadPin;
var
  Search: TSearchRec;
  Text: string;
begin
  if FindFirst(FData + '/keys/ed25519-*.toml', faAnyFile, Search) <> 0 then
    raise Exception.Create('origin key record is missing');
  try
    Text := ReadBinaryFile(FData + '/keys/' + Search.Name);
  finally
    FindClose(Search);
  end;
  FKeyID := QuotedValue(Text, 'key_id');
  FPublicKey := QuotedValue(Text, 'public_key');
end;

procedure TPublishOrigin.Listen(const APort: Word);
var
  Run: TLwptResult;
begin
  Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
    '--port', IntToStr(APort)], FScratch, [], PUBLISH_RUN_TIMEOUT_MILLISECONDS);
  if Run.ExitCode <> 0 then
    raise Exception.Create('registry re-init failed: ' + Run.Stderr);
  FListenPort := APort;
end;

function TPublishOrigin.IssueToken(const AExtra: array of string): string;
var
  Arguments: array of string;
  Index: Integer;
  Run: TLwptResult;
begin
  Arguments := nil;
  SetLength(Arguments, 4 + Length(AExtra));
  Arguments[0] := 'registry';
  Arguments[1] := 'issue-token';
  Arguments[2] := '--data-dir';
  Arguments[3] := FData;
  for Index := 0 to High(AExtra) do Arguments[4 + Index] := AExtra[Index];
  Run := RunLwpt(Arguments, FScratch, [], PUBLISH_RUN_TIMEOUT_MILLISECONDS);
  if Run.ExitCode <> 0 then
    raise Exception.Create('issue-token failed: ' + Run.Stderr);
  Result := Trim(Run.Stdout);
  if Pos(RegistryProgramName + '_rt1_', Result) <> 1 then
    raise Exception.Create('issue-token printed no token');
end;

procedure TPublishOrigin.AdoptToken(ASource: TPublishOrigin; const AToken: string);
var
  Path: string;
begin
  Path := '/auth/tokens/' + TokenID(AToken) + '.toml';
  ForceDirectories(FData + '/auth/tokens');
  WriteBinaryFile(FData + Path, BytesOf(ReadBinaryFile(ASource.DataDirectory + Path)));
end;

procedure TPublishOrigin.RevokeToken(const AToken: string);
var
  Run: TLwptResult;
begin
  Run := RunLwpt(['registry', 'revoke-token', '--data-dir', FData, '--token-id',
    TokenID(AToken)], FScratch, [], PUBLISH_RUN_TIMEOUT_MILLISECONDS);
  if Run.ExitCode <> 0 then
    raise Exception.Create('revoke-token failed: ' + Run.Stderr);
end;

procedure TPublishOrigin.ExpireToken(const AToken: string);
var
  Path, Text, Created, Expires: string;
  Stream: TFileStream;
begin
  Path := FData + '/auth/tokens/' + TokenID(AToken) + '.toml';
  Text := ReadBinaryFile(Path);
  Created := QuotedValue(Text, 'created_at');
  Expires := QuotedValue(Text, 'expires_at');
  Text := StringReplace(Text, 'created_at = "' + Created + '"',
    'created_at = "2020-01-01T00:00:00Z"', []);
  Text := StringReplace(Text, 'expires_at = "' + Expires + '"',
    'expires_at = "2020-01-02T00:00:00Z"', []);
  { In place, so the owner-only file keeps its permissions. }
  Stream := TFileStream.Create(Path, fmOpenReadWrite);
  try
    Stream.Size := 0;
    if Text <> '' then Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
end;

function TPublishOrigin.Request(const AMethod, ATarget: string;
  const AHeaders: array of string; const ABody: TBytes): TRawHTTPResponse;
var
  Options: THTTPRequestOptions;
  Response: THTTPResponse;
  Stream: TFileStream;
  Header: THTTPHeader;
begin
  if not FHTTPS then
    Exit(RawHTTPRequest(FListenPort, AMethod, ATarget, AHeaders, ABody,
      AMethod <> 'GET', 10000));
  if (AMethod <> 'GET') or (Length(AHeaders) > 0) then
    raise Exception.Create('the HTTPS test origin serves only plain GET requests');
  { Reads over TLS trust exactly the committed test root. }
  Options := DefaultHTTPRequestOptions;
  Options.RequestTimeoutMilliseconds := 10000;
  Options.MaximumRedirects := 0;
  Stream := TFileStream.Create(TestRootCertificatePath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Options.TLS.TrustAnchors, Stream.Size);
    Stream.ReadBuffer(Options.TLS.TrustAnchors[0], Stream.Size);
  finally
    Stream.Free;
  end;
  Options.TLS.TrustMode := tstmAnchorsOnly;
  { The listener directly, so a relay on the advertised port counts only
    the client's connections. }
  Response := HTTPGet('https://' + FHost + ':' + IntToStr(FListenPort) + ATarget,
    nil, Options);
  Result := Default(TRawHTTPResponse);
  Result.Status := Response.StatusCode;
  Result.Head := 'HTTP/1.1 ' + IntToStr(Response.StatusCode);
  for Header in Response.Headers do
    Result.Head := Result.Head + #13#10 + Header.Name + ': ' + Header.Value;
  Result.Body := Response.Body;
end;

function TPublishOrigin.LatestSequence: Integer;
var
  Body: string;
  Start: Integer;
begin
  Body := RawHTTPBodyText(Request('GET', '/v1/checkpoints/latest.toml', [], nil));
  Start := Pos(#10 + 'sequence = ', Body);
  if Start = 0 then Exit(-1);
  Body := Copy(Body, Start + Length(#10 + 'sequence = '), MaxInt);
  Result := StrToIntDef(Copy(Body, 1, Pos(#10, Body) - 1), -1);
end;

procedure TPublishOrigin.Start(const ATesting: Boolean);
begin
  StartWith(ATesting, []);
end;

procedure TPublishOrigin.StartWith(const ATesting: Boolean;
  const AEnvironment: array of string);
var
  Started: QWord;
  Ready: Boolean;
  Variables: TStringArray;
  Index: Integer;
  Executable, BaseURL, LastProbe, Discovery: string;
  Relocatable: Boolean;
begin
  if FServe <> nil then raise Exception.Create('origin already serving');
  if ATesting then Executable := ExpectedExe(LwptTestingBinaryPath)
  else Executable := ExpectedExe(LwptBinaryPath);
  Variables := Environment;
  for Index := 0 to High(AEnvironment) do
  begin
    SetLength(Variables, Length(Variables) + 1);
    Variables[High(Variables)] := AEnvironment[Index];
  end;
  { A relay may own the advertised port; only a direct origin can move. }
  Relocatable := EndsStr(':' + IntToStr(FListenPort), FBase);
  BaseURL := FBase;
  FServe := LaunchRegistryCLI(FData, BaseURL, Variables, FScratch, Relocatable,
    Executable);
  if BaseURL <> FBase then
  begin
    FBase := BaseURL;
    FListenPort := StrToInt(Copy(BaseURL, LastDelimiter(':', BaseURL) + 1,
      MaxInt));
  end;
  { The child owns the port now; its discovery must name this registry. }
  Started := GetTickCount64;
  Ready := False;
  LastProbe := 'no probe';
  repeat
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
    try
      Discovery := RawHTTPBodyText(Request('GET', '/.well-known/'
        + RegistryProgramName + '-registry', [], nil));
      Ready := Pos('base_url = "' + FBase + '"', Discovery) > 0;
      LastProbe := Copy(Discovery, 1, 512);
    except
      on E: Exception do LastProbe := Copy(E.Message, 1, 512);
    end;
    if Ready or not FServe.Running then Break;
    Sleep(20);
  until GetTickCount64 - Started > RegistryReadyMilliseconds;
  if not Ready then
  begin
    StopGracefully;
    raise Exception.Create('registry serve announced ' + FBase
      + ' but did not serve its discovery; last probe: ' + LastProbe
      + '; output: ' + FOutputs);
  end;
end;

procedure TPublishOrigin.Stop;
begin
  StopGracefully;
end;

function TPublishOrigin.StopGracefully: TRegistryStopResult;
begin
  Result := Default(TRegistryStopResult);
  Result.ExitStatus := -1;
  Result.Stopped := True;
  if FServe = nil then Exit;
  try
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
  except
  end;
  Result := StopRegistryProcess(FServe);
  if not Result.Stopped then
    WriteLn(StdErr, 'registry publish e2e cleanup: registry serve did not stop');
end;

procedure TPublishOrigin.Kill;
begin
  if FServe = nil then Exit;
  {$IFDEF UNIX}
  FpKill(FServe.ProcessID, SIGKILL);
  {$ELSE}
  TerminateProcess(FServe.Handle, 1);
  {$ENDIF}
  StopGracefully;
end;

end.
