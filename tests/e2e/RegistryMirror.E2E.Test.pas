program RegistryMirror.E2E.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  HTTPClient,
  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryOrigin,
  Tests.RegistryProcess,
  Tests.RegistryServer,
  Tests.Scratch,
  TOML;

type
  TRegistryMirrorE2E = class(TTestSuite)
  private
    FScratch, FMirrorRoot, FMirrorURL: string;
    FOrigin: TRegistryOriginFixture;
    FMirrorServer: TProcess;
    function InitMirror(const AKeyID, APublicKey: string; const AUpstream: string = ''): TLwptResult;
    function Sync: TLwptResult;
    procedure RequireSuccess(const ALabel: string; const ARun: TLwptResult);
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure BootstrapOutageAndRestart;
    procedure IncrementalSyncReusesVerifiedObjects;
    procedure FailedSyncPreservesAcceptedPointer;
    procedure MissingAndWrongPinsFailClosed;
    procedure UpstreamKeyBytesArePreserved;
    procedure ForcedShutdownIsBounded;
    procedure SignedRotationsSurviveOutage;
    procedure ReadinessPreservesCLIDiagnostic;
    procedure BootstrapConsumesMultipleRotationPages;
  end;

function ReadBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function Text(const ABytes: TBytes): string;
begin
  Result := '';
  if Length(ABytes) > 0 then SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

function Field(const ADocument: string; const AName: string): string;
var
  Parser: TTOMLParser;
  Root, Node: TTOMLNode;
begin
  Parser := TTOMLParser.Create;
  try
    Root := Parser.ParseDocument(ADocument);
    try
      if not Root.Children.TryGetValue(AName, Node) then
        raise Exception.Create('missing registry fixture field: ' + AName);
      Result := Node.ScalarText;
    finally
      Root.Free;
    end;
  finally
    Parser.Free;
  end;
end;

function HTTPStatus(const AURL: string): Integer;
var
  Options: THTTPRequestOptions;
begin
  Options := DefaultHTTPRequestOptions;
  Options.RequestTimeoutMilliseconds := 1000;
  Result := HTTPGet(AURL, nil, Options).StatusCode;
end;

procedure WriteBytes(const APath: string; const ABytes: TBytes);
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

procedure TRegistryMirrorE2E.BeforeEach;
var
  Port: Word;
begin
  FScratch := CreateScratchRoot('registry-mirror-e2e');
  FOrigin := TRegistryOriginFixture.Create(FScratch + '/origin');
  FMirrorRoot := FScratch + '/mirror';
  Port := ReserveRegistryTestPort;
  FMirrorURL := 'http://localhost:' + IntToStr(Port) + '/mirror';
end;

procedure TRegistryMirrorE2E.AfterEach;
begin
  StopRegistryCLI(FMirrorServer);
  FreeAndNil(FOrigin);
  RecursiveDelete(FScratch);
end;

procedure TRegistryMirrorE2E.RequireSuccess(const ALabel: string; const ARun: TLwptResult);
begin
  DumpRunFailure(ALabel, ARun, 0);
  Expect<Integer>(ARun.ExitCode).ToBe(0);
  if ARun.ExitCode <> 0 then raise Exception.Create(ALabel + ': ' + ARun.Stderr);
end;

function TRegistryMirrorE2E.InitMirror(const AKeyID, APublicKey: string; const AUpstream: string): TLwptResult;
var
  Port, Upstream: string;
begin
  Upstream := AUpstream;
  if Upstream = '' then Upstream := FOrigin.BaseURL;
  Port := Copy(FMirrorURL, Length('http://localhost:') + 1, MaxInt);
  Port := Copy(Port, 1, Pos('/', Port) - 1);
  Result := RunLwpt(['registry', 'init', '--role', 'mirror', '--data-dir', FMirrorRoot,
    '--identity', FOrigin.BaseURL, '--base-url', FMirrorURL, '--port', Port,
    '--upstream', Upstream, '--key-id', AKeyID, '--public-key', APublicKey]);
end;

function TRegistryMirrorE2E.Sync: TLwptResult;
begin
  Result := RunLwpt(['registry', 'sync', '--data-dir', FMirrorRoot]);
end;

procedure TRegistryMirrorE2E.BootstrapOutageAndRestart;
var
  Archive: TBytes;
  Checkpoint, ArtifactURL: string;
  Run: TLwptResult;
begin
  Archive := BytesOf('archive' + #0 + 'binary');
  FOrigin.Publish('binary-package', '1.0.0', Archive);
  FOrigin.Start;
  RequireSuccess('mirror init', InitMirror(FOrigin.KeyID, FOrigin.PublicKey));
  Expect<Boolean>(FileExists(FMirrorRoot + '/keys/root.seed')).ToBe(False);
  RequireSuccess('bootstrap sync', Sync);
  Checkpoint := Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml'));
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  FOrigin.Stop;
  Expect<string>(Text(RegistryHTTPBody(FMirrorURL + '/v1/checkpoints/latest.toml'))).ToBe(Checkpoint);
  ArtifactURL := FMirrorURL + '/v1/objects/sha256/' + Copy(RegistryArtifactHash(Archive), 8, 64);
  Expect<string>(Text(RegistryHTTPBody(ArtifactURL))).ToBe(Text(Archive));
  Run := RunLwpt(['registry', 'verify', '--data-dir', FMirrorRoot]);
  RequireSuccess('mirror verify during outage', Run);
  Expect<Boolean>(Pos('freshness = "fresh"', Run.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos('last_successful_sync = "', Run.Stdout) > 0).ToBe(True);
  Expect<Boolean>(Pos(FOrigin.BaseURL, Run.Stdout) > 0).ToBe(True);
  StopRegistryCLI(FMirrorServer);
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  Expect<string>(Text(RegistryHTTPBody(ArtifactURL))).ToBe(Text(Archive));
  Run := Sync;
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<string>(Text(RegistryHTTPBody(FMirrorURL + '/v1/checkpoints/latest.toml'))).ToBe(Checkpoint);
  Run := RunLwpt(['registry', 'verify', '--data-dir', FMirrorRoot]);
  RequireSuccess('verify records failed sync without losing fresh content', Run);
  Expect<Boolean>(Pos('registry_transport_failed', Run.Stdout) > 0).ToBe(True);
end;

procedure TRegistryMirrorE2E.IncrementalSyncReusesVerifiedObjects;
var
  Archive: TBytes;
  ObjectPath: string;
begin
  Archive := BytesOf('first package');
  FOrigin.Publish('first-package', '1.0.0', Archive);
  FOrigin.Start;
  RequireSuccess('mirror init', InitMirror(FOrigin.KeyID, FOrigin.PublicKey));
  RequireSuccess('first sync', Sync);
  ObjectPath := '/objects/sha256/' + Copy(RegistryArtifactHash(Archive), 8, 64);
  Expect<Boolean>(DeleteFile(FOrigin.Root + ObjectPath)).ToBe(True);
  RequireSuccess('idempotent sync does not refetch verified object', Sync);
  FOrigin.Publish('second-package', '1.0.0', BytesOf('second package'));
  RequireSuccess('incremental sync reuses old verified object', Sync);
  RequireSuccess('verify incrementally mirrored artifacts',
    RunLwpt(['registry', 'verify', '--data-dir', FMirrorRoot]));
  Expect<string>(Text(ReadBytes(FMirrorRoot + ObjectPath))).ToBe(Text(Archive));
end;

procedure TRegistryMirrorE2E.FailedSyncPreservesAcceptedPointer;
var
  Archive: TBytes;
  PointerBefore, ObjectPath, Checkpoint, Candidate, CandidateHash,
    CandidateSnapshot, PreviousSnapshot, CandidatePrefix: string;
  Run: TLwptResult;
begin
  FOrigin.Publish('first-package', '1.0.0', BytesOf('first'));
  FOrigin.Start;
  RequireSuccess('mirror init', InitMirror(FOrigin.KeyID, FOrigin.PublicKey));
  RequireSuccess('first sync', Sync);
  PointerBefore := Text(ReadBytes(FMirrorRoot + '/state/current.toml'));
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  Checkpoint := Text(RegistryHTTPBody(FMirrorURL + '/v1/checkpoints/latest.toml'));
  PreviousSnapshot := Field(Checkpoint, 'snapshot');
  Archive := BytesOf('second');
  FOrigin.Publish('second-package', '1.0.0', Archive);
  Candidate := Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml'));
  CandidateSnapshot := Field(Candidate, 'snapshot');
  CandidateHash := RegistryArtifactHash(BytesOf(Candidate));
  CandidatePrefix := '/checkpoints/renewals/sha256/' + Copy(CandidateHash, 8, 64);
  { A crash can leave these exact staged files without activating the pointer. }
  WriteBytes(FMirrorRoot + CandidatePrefix + '.toml', BytesOf(Candidate));
  WriteBytes(FMirrorRoot + CandidatePrefix + '.sig.toml',
    RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.sig.toml'));
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1' + CandidatePrefix + '.toml')).ToBe(404);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1' + CandidatePrefix + '.sig.toml')).ToBe(404);
  ObjectPath := FOrigin.Root + '/objects/sha256/' + Copy(RegistryArtifactHash(Archive), 8, 64);
  WriteBytes(ObjectPath, BytesOf('tamper'));
  Run := Sync;
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<string>(Text(ReadBytes(FMirrorRoot + '/state/current.toml'))).ToBe(PointerBefore);
  Expect<string>(Text(RegistryHTTPBody(FMirrorURL + '/v1/checkpoints/latest.toml'))).ToBe(Checkpoint);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/snapshots/sha256/'
    + Copy(CandidateSnapshot, 8, 64) + '.toml')).ToBe(404);
  Expect<Boolean>(DeleteFile(ObjectPath)).ToBe(True);
  Run := Sync;
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<string>(Text(ReadBytes(FMirrorRoot + '/state/current.toml'))).ToBe(PointerBefore);
  WriteBytes(ObjectPath, Archive);
  RequireSuccess('retry after tampered and missing archive', Sync);
  Expect<Boolean>(Text(ReadBytes(FMirrorRoot + '/state/current.toml')) <> PointerBefore).ToBe(True);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/snapshots/sha256/'
    + Copy(CandidateSnapshot, 8, 64) + '.toml')).ToBe(200);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/snapshots/sha256/'
    + Copy(PreviousSnapshot, 8, 64) + '.toml')).ToBe(200);
end;

procedure TRegistryMirrorE2E.UpstreamKeyBytesArePreserved;
var
  KeyPath, KeyDocument: string;
begin
  FOrigin.Publish('package', '1.0.0', BytesOf('archive'));
  KeyPath := '/keys/ed25519-' + Copy(FOrigin.KeyID, Length('ed25519:') + 1, 64) + '.toml';
  KeyDocument := StringReplace(Text(ReadBytes(FOrigin.Root + KeyPath)),
    'valid_from_sequence = 1', 'valid_from_sequence = 2', []);
  WriteBytes(FOrigin.Root + KeyPath, BytesOf(KeyDocument));
  FOrigin.Start;
  RequireSuccess('mirror init pins key effective at current sequence',
    InitMirror(FOrigin.KeyID, FOrigin.PublicKey));
  RequireSuccess('mirror sync preserves upstream key record', Sync);
  Expect<string>(Text(ReadBytes(FMirrorRoot + KeyPath))).ToBe(KeyDocument);
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  Expect<string>(Text(RegistryHTTPBody(FMirrorURL + '/v1/keys/'
    + FOrigin.KeyID + '.toml'))).ToBe(KeyDocument);
end;

procedure TRegistryMirrorE2E.SignedRotationsSurviveOutage;
var
  KeyTwo, KeyThree, PointerBefore, RotationPath, Page, Cursor: string;
  OldSignature, RotationDocument: TBytes;
begin
  FOrigin.Publish('rotating-package', '1.0.0', BytesOf('rotating archive'));
  FOrigin.Start;
  RequireSuccess('first local rotation', RunLwpt(['registry', 'rotate-key', '--data-dir',
    FOrigin.Root, '--from-key', FOrigin.KeyID]));
  KeyTwo := Field(Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml')), 'key_id');
  RequireSuccess('second local rotation', RunLwpt(['registry', 'rotate-key', '--data-dir',
    FOrigin.Root, '--from-key', KeyTwo]));
  KeyThree := Field(Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml')), 'key_id');
  Expect<Integer>(RunLwpt(['registry', 'rotate-key', '--data-dir', FOrigin.Root,
    '--from-key', KeyTwo]).ExitCode).ToBe(1);
  Expect<string>(Field(Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml')), 'key_id')).ToBe(KeyThree);
  RequireSuccess('root-pinned mirror init after two rotations', InitMirror(FOrigin.KeyID, FOrigin.PublicKey));
  RequireSuccess('bootstrap verifies both complete signed transitions', Sync);
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  Page := Text(RegistryHTTPBody(FMirrorURL + '/v1/rotations?after=0&limit=1'));
  Expect<Boolean>(Pos('effective_sequence = 3', Page) > 0).ToBe(True);
  Cursor := Field(Page, 'next_cursor');
  Expect<Boolean>(Cursor <> '').ToBe(True);
  Page := Text(RegistryHTTPBody(FMirrorURL + '/v1/rotations?after=0&limit=1&cursor=' + Cursor));
  Expect<Boolean>(Pos('effective_sequence = 4', Page) > 0).ToBe(True);
  Expect<string>(Field(Page, 'next_cursor')).ToBe('');
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/rotations?after=1&limit=1&cursor=' + Cursor)).ToBe(400);
  PointerBefore := Text(ReadBytes(FMirrorRoot + '/state/current.toml'));
  RequireSuccess('incremental local rotation', RunLwpt(['registry', 'rotate-key', '--data-dir',
    FOrigin.Root, '--from-key', KeyThree]));
  RotationPath := FOrigin.Root + '/rotations/5';
  OldSignature := ReadBytes(RotationPath + '.old.sig.toml');
  RotationDocument := ReadBytes(RotationPath + '.toml');
  WriteBytes(RotationPath + '.old.sig.toml', BytesOf('tampered'));
  Expect<Integer>(Sync.ExitCode).ToBe(1);
  Expect<string>(Text(ReadBytes(FMirrorRoot + '/state/current.toml'))).ToBe(PointerBefore);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/rotations/5.toml')).ToBe(404);
  WriteBytes(RotationPath + '.old.sig.toml', OldSignature);
  WriteBytes(RotationPath + '.toml', BytesOf(StringReplace(Text(RotationDocument),
    'from_key = "' + KeyThree + '"', 'from_key = "' + FOrigin.KeyID + '"', [])));
  Expect<Integer>(Sync.ExitCode).ToBe(1);
  Expect<string>(Text(ReadBytes(FMirrorRoot + '/state/current.toml'))).ToBe(PointerBefore);
  WriteBytes(RotationPath + '.toml', RotationDocument);
  Expect<Boolean>(DeleteFile(RotationPath + '.old.sig.toml')).ToBe(True);
  Expect<Integer>(Sync.ExitCode).ToBe(1);
  Expect<string>(Text(ReadBytes(FMirrorRoot + '/state/current.toml'))).ToBe(PointerBefore);
  WriteBytes(RotationPath + '.old.sig.toml', OldSignature);
  RequireSuccess('retry accepts only the verified new transition', Sync);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/rotations/3.old.sig.toml')).ToBe(200);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/keys/' + KeyTwo + '.toml')).ToBe(200);
  FOrigin.Stop;
  StopRegistryCLI(FMirrorServer);
  FMirrorServer := StartRegistryCLI(FMirrorRoot, FMirrorURL);
  Expect<Integer>(HTTPStatus(FMirrorURL + '/v1/rotations/5.new.sig.toml')).ToBe(200);
  RequireSuccess('offline verification retains the entire signed chain',
    RunLwpt(['registry', 'verify', '--data-dir', FMirrorRoot]));
  Expect<Boolean>(FileExists(FMirrorRoot + '/keys/root.seed')).ToBe(False);
end;

procedure TRegistryMirrorE2E.ReadinessPreservesCLIDiagnostic;
var
  Child: TProcess;
  Diagnostic: string;
begin
  Child := nil;
  Diagnostic := '';
  try
    try
      Child := StartRegistryCLI(FScratch + '/missing', FMirrorURL);
    except
      on E: Exception do Diagnostic := E.Message;
    end;
    if Pos('exit=1', Diagnostic) = 0 then WriteLn(StdErr, Diagnostic);
    Expect<Boolean>(Pos('exit=1', Diagnostic) > 0).ToBe(True);
    Expect<Boolean>(Pos('origin_not_initialized:', Diagnostic) > 0).ToBe(True);
    Expect<Boolean>(Pos('last probe:', Diagnostic) > 0).ToBe(True);
  finally
    StopRegistryCLI(Child);
  end;
end;

procedure TRegistryMirrorE2E.BootstrapConsumesMultipleRotationPages;
var
  Proxy: TRegistryTestServer;
  Routes: TRegistryHTTPRouteArray;
  ProxyURL, KeyTwo, Page, Cursor: string;

  procedure AddRoute(const APath, AKind: string; const ARewrite: Boolean = False);
  var
    Body: TBytes;
    Document: string;
  begin
    Body := RegistryHTTPBody(FOrigin.BaseURL + APath);
    if ARewrite then
    begin
      Document := StringReplace(Text(Body), FOrigin.BaseURL + '/v1', ProxyURL + '/v1', [rfReplaceAll]);
      Document := StringReplace(Document, 'base_url = "' + FOrigin.BaseURL + '"',
        'base_url = "' + ProxyURL + '"', []);
      Document := StringReplace(Document, 'max_page_size = 100', 'max_page_size = 1', []);
      Body := BytesOf(Document);
    end;
    SetLength(Routes, Length(Routes) + 1);
    Routes[High(Routes)] := RegistryRoute('/proxy' + APath,
      'application/vnd.lwpt.registry-' + AKind + '+toml', Body);
  end;

  procedure AddPublicDirectory(const ADirectory, AKind: string);
  var
    Entry: TSearchRec;
    Name, Kind: string;
  begin
    if FindFirst(FOrigin.Root + '/' + ADirectory + '/*.toml', faAnyFile, Entry) <> 0 then Exit;
    try
      repeat
        if Entry.Attr and faDirectory <> 0 then Continue;
        Name := Entry.Name;
        Kind := AKind;
        if ADirectory = 'keys' then
          Name := Field(Text(ReadBytes(FOrigin.Root + '/keys/' + Name)), 'key_id') + '.toml';
        if Pos('.sig.toml', Name) > 0 then Kind := 'signature';
        AddRoute('/v1/' + ADirectory + '/' + Name, Kind);
      until FindNext(Entry) <> 0;
    finally
      FindClose(Entry);
    end;
  end;

begin
  FOrigin.Start;
  RequireSuccess('first pagination rotation', RunLwpt(['registry', 'rotate-key',
    '--data-dir', FOrigin.Root, '--from-key', FOrigin.KeyID]));
  KeyTwo := Field(Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/checkpoints/latest.toml')), 'key_id');
  RequireSuccess('second pagination rotation', RunLwpt(['registry', 'rotate-key',
    '--data-dir', FOrigin.Root, '--from-key', KeyTwo]));
  Proxy := TRegistryTestServer.Create(nil);
  try
    ProxyURL := 'http://localhost:' + IntToStr(Proxy.Port) + '/proxy';
    AddRoute('/.well-known/lwpt-registry', 'discovery', True);
    AddRoute('/v1/capabilities', 'capabilities', True);
    AddRoute('/v1/checkpoints/latest.toml', 'checkpoint');
    AddRoute('/v1/checkpoints/latest.sig.toml', 'signature');
    AddPublicDirectory('keys', 'key');
    AddPublicDirectory('rotations', 'key-rotation');
    AddPublicDirectory('snapshots/sha256', 'snapshot');
    Page := Text(RegistryHTTPBody(FOrigin.BaseURL + '/v1/rotations?after=0&limit=1'));
    Cursor := Field(Page, 'next_cursor');
    Expect<Boolean>(Cursor <> '').ToBe(True);
    AddRoute('/v1/rotations?after=0&limit=1', 'rotation-page', True);
    AddRoute('/v1/rotations?after=0&limit=1&cursor=' + Cursor, 'rotation-page', True);
    Proxy.SetRoutes(Routes);
    Proxy.Start;
    FOrigin.Stop;
    RequireSuccess('mirror initialized against one-item-page transport',
      InitMirror(FOrigin.KeyID, FOrigin.PublicKey, ProxyURL));
    RequireSuccess('actual CLI consumes both pages and original signed bytes', Sync);
    RequireSuccess('retained multi-page proof verifies without origin',
      RunLwpt(['registry', 'verify', '--data-dir', FMirrorRoot]));
  finally
    Proxy.Free;
  end;
end;

procedure TRegistryMirrorE2E.ForcedShutdownIsBounded;
var
  Child: TProcess;
  Started: QWord;
  Stopped: TRegistryStopResult;
  ReadyPath: string;
begin
  ReadyPath := FScratch + '/stubborn-child-ready';
  Child := TProcess.Create(nil);
  try
    Child.Executable := ParamStr(0);
    Child.Parameters.Add('--registry-stubborn-child');
    Child.Parameters.Add(ReadyPath);
    Child.Execute;
    Started := GetTickCount64;
    while not FileExists(ReadyPath) and Child.Running
      and (GetTickCount64 - Started < 2000) do Sleep(10);
    Expect<Boolean>(FileExists(ReadyPath)).ToBe(True);
    Started := GetTickCount64;
    Stopped := StopRegistryProcess(Child, 25, 2000);
    Expect<Boolean>(GetTickCount64 - Started < 2500).ToBe(True);
    Expect<Boolean>(Stopped.Stopped).ToBe(True);
    Expect<Boolean>(Child = nil).ToBe(True);
    {$IFDEF UNIX}
    Expect<Boolean>(Stopped.Forced).ToBe(True);
    {$ENDIF}
  finally
    StopRegistryProcess(Child, 25, 2000);
  end;
end;

procedure TRegistryMirrorE2E.MissingAndWrongPinsFailClosed;
var
  Other: TRegistryOriginFixture;
  Run: TLwptResult;
begin
  Run := InitMirror('', '');
  Expect<Integer>(Run.ExitCode).ToBe(1);
  Expect<Boolean>(FileExists(FMirrorRoot + '/registry.toml')).ToBe(False);
  Other := TRegistryOriginFixture.Create(FScratch + '/other-origin');
  try
    FOrigin.Start;
    RequireSuccess('explicit different pin is persisted, never replaced by discovery',
      InitMirror(Other.KeyID, Other.PublicKey));
    Run := Sync;
    Expect<Integer>(Run.ExitCode).ToBe(1);
    Expect<Boolean>(FileExists(FMirrorRoot + '/state/current.toml')).ToBe(False);
    Run := InitMirror(FOrigin.KeyID, FOrigin.PublicKey);
    Expect<Integer>(Run.ExitCode).ToBe(1);
    Expect<Boolean>(Pos('identity_conflict', Run.Stderr) > 0).ToBe(True);
  finally
    Other.Free;
  end;
end;

procedure TRegistryMirrorE2E.SetupTests;
begin
  Test('CLI mirror bootstrap survives origin outage and restart', BootstrapOutageAndRestart);
  Test('incremental and idempotent sync reuse verified objects', IncrementalSyncReusesVerifiedObjects);
  Test('tampered or missing objects preserve the live accepted pointer', FailedSyncPreservesAcceptedPointer);
  Test('missing and wrong root pins fail without trust replacement', MissingAndWrongPinsFailClosed);
  Test('mirror preserves exact pinned upstream key bytes', UpstreamKeyBytesArePreserved);
  Test('shared listener shutdown force-kills and reaps within its bound', ForcedShutdownIsBounded);
  Test('signed rotation bootstrap and incremental retry retain offline provenance', SignedRotationsSurviveOutage);
  Test('readiness failures retain the original CLI diagnostic and exit status', ReadinessPreservesCLIDiagnostic);
  Test('bootstrap consumes multiple bounded rotation pages with exact signed bytes', BootstrapConsumesMultipleRotationPages);
end;

begin
  if ParamStr(1) = '--registry-stubborn-child' then
  begin
    {$IFDEF UNIX}
    FpSignal(SIGTERM, SignalHandler(SIG_IGN));
    {$ENDIF}
    WriteBytes(ParamStr(2), BytesOf('ready'));
    Sleep(10000); { Independent finite fallback if the parent test aborts. }
    Halt(0);
  end;
  TestRunnerProgram.AddSuite(TRegistryMirrorE2E.Create('registry mirror E2E'));
  TestRunnerProgram.Run;
end.
