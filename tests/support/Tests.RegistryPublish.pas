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
  Tests.RegistryHTTP;

const
  PUBLISH_TLS_PASSWORD = 'test-only';
  PUBLISH_RUN_TIMEOUT_MILLISECONDS = 180000;

type
  TPublishOrigin = class
  private
    FScratch, FData, FBase, FKeyID, FPublicKey, FOutputs: string;
    FListenPort: Word;
    FHTTPS: Boolean;
    FServe: TProcess;
    procedure ReadPin;
    function Environment: TStringArray;
  public
    { Runs `registry init`. ABasePort is advertised in the base URL (and so
      in the origin identity); AListenPort is where `serve` listens. }
    constructor Create(const AScratch, AName: string; const ABasePort,
      AListenPort: Word; const AHTTPS: Boolean = False);
    destructor Destroy; override;
    { Re-runs init to move the listener, keeping identity and keys. }
    procedure Listen(const APort: Word);
    function IssueToken(const AExtra: array of string): string;
    procedure RevokeToken(const AToken: string);
    { Rewrites the token record so it expired long ago. }
    procedure ExpireToken(const AToken: string);
    procedure Start(const ATesting: Boolean = False);
    procedure Stop;
    function Request(const AMethod, ATarget: string; const AHeaders: array of string;
      const ABody: TBytes): TRawHTTPResponse;
    function LatestSequence: Integer;
    property Base: string read FBase;
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
  HTTPClient,
  Tests.RegistryOrigin,
  Tests.RegistryProcess,
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
  const ABasePort, AListenPort: Word; const AHTTPS: Boolean);
var
  Run: TLwptResult;
begin
  inherited Create;
  FScratch := AScratch;
  FData := AScratch + '/' + AName;
  FHTTPS := AHTTPS;
  FListenPort := AListenPort;
  if AHTTPS then FBase := 'https://localhost:' + IntToStr(ABasePort)
  else FBase := 'http://localhost:' + IntToStr(ABasePort);
  if AHTTPS then
    Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
      '--port', IntToStr(AListenPort), '--tls-pkcs12', TLSFixturePath,
      '--tls-password-env', PasswordVariable], FScratch, Environment)
  else
    Run := RunLwpt(['registry', 'init', '--data-dir', FData, '--base-url', FBase,
      '--port', IntToStr(AListenPort)], FScratch);
  FOutputs := FOutputs + Run.Stdout + Run.Stderr;
  if Run.ExitCode <> 0 then
    raise Exception.Create('registry init failed: ' + Run.Stderr);
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
    '--port', IntToStr(APort)], FScratch);
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
  Run := RunLwpt(Arguments, FScratch);
  if Run.ExitCode <> 0 then
    raise Exception.Create('issue-token failed: ' + Run.Stderr);
  Result := Trim(Run.Stdout);
  if Pos(RegistryProgramName + '_rt1_', Result) <> 1 then
    raise Exception.Create('issue-token printed no token');
end;

procedure TPublishOrigin.RevokeToken(const AToken: string);
var
  Run: TLwptResult;
begin
  Run := RunLwpt(['registry', 'revoke-token', '--data-dir', FData, '--token-id',
    TokenID(AToken)], FScratch);
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
  Response := HTTPGet(FBase + ATarget, nil, Options);
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
var
  Started: QWord;
  Ready: Boolean;
begin
  if FServe <> nil then raise Exception.Create('origin already serving');
  FServe := TProcess.Create(nil);
  try
    if ATesting then FServe.Executable := ExpectedExe(LwptTestingBinaryPath)
    else FServe.Executable := ExpectedExe(LwptBinaryPath);
    FServe.CurrentDirectory := FScratch;
    FServe.Options := [poUsePipes];
    FServe.Parameters.Add('registry');
    FServe.Parameters.Add('serve');
    FServe.Parameters.Add('--data-dir');
    FServe.Parameters.Add(FData);
    if FHTTPS then ConfigureProcessEnvironment(FServe, Environment);
    BindRegistryChildToParent(FServe);
    FServe.Execute;
  except
    FreeAndNil(FServe);
    raise;
  end;
  Started := GetTickCount64;
  Ready := False;
  repeat
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
    try
      Ready := Request('GET', '/.well-known/' + RegistryProgramName + '-registry',
        [], nil).Status = 200;
    except
      Ready := False;
    end;
    if Ready or not FServe.Running then Break;
    Sleep(50);
  until GetTickCount64 - Started > 15000;
  if not Ready then
    raise Exception.Create('registry serve did not become ready: ' + FOutputs);
end;

procedure TPublishOrigin.Stop;
var
  Stopped: TRegistryStopResult;
begin
  if FServe = nil then Exit;
  try
    FOutputs := FOutputs + DrainAvailableStream(FServe.Output, 65536)
      + DrainAvailableStream(FServe.Stderr, 65536);
  except
  end;
  Stopped := StopRegistryProcess(FServe);
  if not Stopped.Stopped then
    WriteLn(StdErr, 'registry publish e2e cleanup: registry serve did not stop');
end;

end.
