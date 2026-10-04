{ Native origin fixture; mirror tests exercise only the actual CLI and HTTP. }
unit Tests.RegistryOrigin;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Process,
  SysUtils;

type
  TRegistryOriginFixture = class
  private
    FRoot, FBaseURL, FIdentity, FKeyID, FPublicKey: string;
    FProcess: TProcess;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    procedure Publish(const AName, AVersion: string; const AArchive: TBytes);
    procedure Start;
    procedure Stop;
    { Points the stopped origin at APort, e.g. one a test already holds. }
    procedure MoveToPort(const APort: Word);
    property Root: string read FRoot;
    { The current transport URL; it changes if a start relocates the port. }
    property BaseURL: string read FBaseURL;
    { The stable origin identity, fixed at initialization. }
    property Identity: string read FIdentity;
    property KeyID: string read FKeyID;
    property PublicKey: string read FPublicKey;
  end;

{ LaunchRegistryCLI, then waits until the announced child serves this
  registry's discovery document and checkpoint over plain HTTP. }
function StartRegistryCLI(const ADataDirectory: string; var ABaseURL: string;
  const AAllowRelocation: Boolean = True): TProcess;
function RegistryHTTPBody(const AURL: string): TBytes;
function RegistryArtifactHash(const AArchive: TBytes): string;
function RegistryProgramName: string;

implementation

uses
  HTTPClient,
  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Verification,
  Tests.LwptSubprocess,
  Tests.ProcessSupport,
  Tests.RegistryProcess,
  TOML;

function RegistryArtifactHash(const AArchive: TBytes): string;
begin
  Result := SHA256BytesPrefixed(AArchive);
end;

function RegistryProgramName: string;
begin
  Result := PROGRAM_NAME;
end;

function RegistryHTTPBody(const AURL: string): TBytes;
var
  Options: THTTPRequestOptions;
  Response: THTTPResponse;
begin
  Options := DefaultHTTPRequestOptions;
  Options.RequestTimeoutMilliseconds := 1000;
  Response := HTTPGet(AURL, nil, Options);
  if Response.StatusCode <> 200 then
    raise Exception.CreateFmt('HTTP %d for %s', [Response.StatusCode, AURL]);
  Result := Response.Body;
end;

{ The checkpoint this data directory serves, or nothing before activation.
  Its bytes name a unique key and time, so they identify the listener. }
function ServedCheckpoint(const ADataDirectory: string): string;
var
  Parser: TTOMLParser;
  Root: TTOMLNode;
  StateText: string;
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(ADataDirectory + '/state/current.toml') then Exit;
  Stream := TFileStream.Create(ADataDirectory + '/state/current.toml', fmOpenRead);
  try
    SetLength(StateText, Stream.Size);
    if Length(StateText) > 0 then Stream.ReadBuffer(StateText[1], Length(StateText));
  finally
    Stream.Free;
  end;
  Parser := TTOMLParser.Create;
  try
    Root := Parser.ParseDocument(StateText);
    try
      Stream := TFileStream.Create(ADataDirectory + '/' + TomlStr(Root, 'checkpoint', ''), fmOpenRead);
      try
        SetLength(Result, Stream.Size);
        if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
      finally
        Stream.Free;
      end;
    finally
      Root.Free;
    end;
  finally
    Parser.Free;
  end;
end;

function StartRegistryCLI(const ADataDirectory: string; var ABaseURL: string;
  const AAllowRelocation: Boolean): TProcess;
var
  Started: QWord;
  Serving: Boolean;
  LastProbe, ExitState, Discovery, Checkpoint, Expected: string;
  Body: TBytes;
begin
  Result := LaunchRegistryCLI(ADataDirectory, ABaseURL, [], '',
    AAllowRelocation);
  try
    Started := GetTickCount64;
    LastProbe := 'listener did not answer';
    repeat
      try
        Body := RegistryHTTPBody(ABaseURL + '/.well-known/' + PROGRAM_NAME + '-registry');
        SetString(Discovery, PAnsiChar(@Body[0]), Length(Body));
        Serving := Result.Running and (Pos('base_url = "' + ABaseURL + '"', Discovery) > 0);
        Expected := ServedCheckpoint(ADataDirectory);
        if Serving and (Expected <> '') then
        begin
          Body := RegistryHTTPBody(ABaseURL + '/v1/checkpoints/latest.toml');
          SetString(Checkpoint, PAnsiChar(@Body[0]), Length(Body));
          Serving := Checkpoint = Expected;
        end;
        if Serving then Exit;
        LastProbe := 'listener did not serve this registry';
      except
        on E: Exception do LastProbe := Copy(E.Message, 1, 1024);
      end;
      if not Result.Running then Break;
      Sleep(10);
    until GetTickCount64 - Started >= RegistryReadyMilliseconds;
    ExitState := 'running';
    if not Result.Running then ExitState := IntToStr(Result.ExitCode)
      + ' (status=' + IntToStr(Result.ExitStatus) + ')';
    raise Exception.Create('registry CLI listener did not become ready after '
      + 'announcing its bound port; exit=' + ExitState + '; last probe: '
      + LastProbe + '; stderr: ' + DrainAvailableStream(Result.Stderr, 4096));
  except
    StopRegistryCLI(Result);
    raise;
  end;
end;

constructor TRegistryOriginFixture.Create(const ARoot: string);
var
  Port: Word;
  Run: TLwptResult;
  Store: TLWPTRegistryStore;
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
  Parser: TTOMLParser;
  Key: TTOMLNode;
  KeyBytes: TBytes;
  KeyText: string;
begin
  inherited Create;
  FRoot := ARoot;
  Port := FindAvailableRegistryTestPort;
  FBaseURL := 'http://localhost:' + IntToStr(Port) + '/origin';
  FIdentity := FBaseURL;
  Run := RunLwpt(['registry', 'init', '--data-dir', FRoot,
    '--base-url', FBaseURL, '--port', IntToStr(Port)]);
  if Run.ExitCode <> 0 then raise Exception.Create(Run.Stderr);
  Store := TLWPTRegistryStore.Create(FRoot);
  Parser := TTOMLParser.Create;
  try
    Checkpoint := InspectRegistryCheckpoint(Store.LoadResource(Store.LoadCurrentState.CheckpointPath));
    FKeyID := Checkpoint.KeyId;
    KeyBytes := Store.LoadResource(RegistryKeyStoragePath(FKeyID));
    SetString(KeyText, PAnsiChar(@KeyBytes[0]), Length(KeyBytes));
    Key := Parser.ParseDocument(KeyText);
    try
      FPublicKey := TomlStr(Key, 'public_key', '');
    finally
      Key.Free;
    end;
  finally
    Parser.Free;
    Store.Free;
  end;
end;

destructor TRegistryOriginFixture.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TRegistryOriginFixture.Publish(const AName, AVersion: string; const AArchive: TBytes);
var
  Store: TLWPTRegistryStore;
  Publication: TLWPTRegistryPublication;
begin
  Store := TLWPTRegistryStore.Create(FRoot);
  try
    Publication := Default(TLWPTRegistryPublication);
    Publication.Name := AName;
    Publication.Version := AVersion;
    Publication.PublishedAt := RegistryTimestampNow;
    Publication.Archive := AArchive;
    Store.Publish(Publication);
  finally
    Store.Free;
  end;
end;

procedure TRegistryOriginFixture.Start;
begin
  if FProcess <> nil then raise Exception.Create('origin fixture already running');
  FProcess := StartRegistryCLI(FRoot, FBaseURL);
end;

procedure TRegistryOriginFixture.Stop;
begin
  StopRegistryCLI(FProcess);
end;

procedure TRegistryOriginFixture.MoveToPort(const APort: Word);
begin
  if Assigned(FProcess) then
    raise Exception.Create('registry origin must be stopped before moving');
  FBaseURL := RelocateRegistryPortTo(FRoot, FBaseURL, APort);
end;

end.
