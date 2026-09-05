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
  Tests.Scratch,
  TOML;

type
  TRegistryMirrorE2E = class(TTestSuite)
  private
    FScratch, FMirrorRoot, FMirrorURL: string;
    FOrigin: TRegistryOriginFixture;
    FMirrorServer: TProcess;
    function InitMirror(const AKeyID, APublicKey: string): TLwptResult;
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

function TRegistryMirrorE2E.InitMirror(const AKeyID, APublicKey: string): TLwptResult;
var
  Port: string;
begin
  Port := Copy(FMirrorURL, Length('http://localhost:') + 1, MaxInt);
  Port := Copy(Port, 1, Pos('/', Port) - 1);
  Result := RunLwpt(['registry', 'init', '--role', 'mirror', '--data-dir', FMirrorRoot,
    '--identity', FOrigin.BaseURL, '--base-url', FMirrorURL, '--port', Port,
    '--upstream', FOrigin.BaseURL, '--key-id', AKeyID, '--public-key', APublicKey]);
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
