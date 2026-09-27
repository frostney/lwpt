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
    FRoot, FBaseURL, FKeyID, FPublicKey: string;
    FProcess: TProcess;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    procedure Publish(const AName, AVersion: string; const AArchive: TBytes);
    procedure Start;
    procedure Stop;
    property Root: string read FRoot;
    property BaseURL: string read FBaseURL;
    property KeyID: string read FKeyID;
    property PublicKey: string read FPublicKey;
  end;

function FindAvailableRegistryTestPort: Word;
function StartRegistryCLI(const ADataDirectory, ABaseURL: string): TProcess;
procedure StopRegistryCLI(var AProcess: TProcess);
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
  Tests.RegistryProcess,
  Tests.RegistryServer,
  TOML;

function RegistryArtifactHash(const AArchive: TBytes): string;
begin
  Result := SHA256BytesPrefixed(AArchive);
end;

function RegistryProgramName: string;
begin
  Result := PROGRAM_NAME;
end;

{ The port is free when observed but not reserved; StartRegistryCLI proves
  that the listener it reaches is the registry it started. }
function FindAvailableRegistryTestPort: Word;
var
  Reservation: TRegistryTestServer;
begin
  Reservation := TRegistryTestServer.Create(nil);
  try
    Result := Reservation.Port;
  finally
    Reservation.Free;
  end;
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

function StartRegistryCLI(const ADataDirectory, ABaseURL: string): TProcess;
var
  Started: QWord;
  Ready: Boolean;
  LastProbe, ExitState, Diagnostics, Discovery, Checkpoint, Expected: string;
  Body: TBytes;
begin
  Result := TProcess.Create(nil);
  Result.Executable := LwptBinaryPath;
  Result.Options := [poUsePipes];
  Result.Parameters.Add('registry');
  Result.Parameters.Add('serve');
  Result.Parameters.Add('--data-dir');
  Result.Parameters.Add(ADataDirectory);
  try
    Result.Execute;
    Started := GetTickCount64;
    LastProbe := '';
    repeat
      Ready := False;
      try
        Body := RegistryHTTPBody(ABaseURL + '/.well-known/' + PROGRAM_NAME + '-registry');
        SetString(Discovery, PAnsiChar(@Body[0]), Length(Body));
        { Another process may have bound the port first; only this registry's
          discovery document proves readiness. }
        Ready := Result.Running and (Pos('base_url = "' + ABaseURL + '"', Discovery) > 0);
        { Colliding fixtures can share a base URL; the served checkpoint
          proves the listener serves this data directory. }
        Expected := ServedCheckpoint(ADataDirectory);
        if Ready and (Expected <> '') then
        begin
          Body := RegistryHTTPBody(ABaseURL + '/v1/checkpoints/latest.toml');
          SetString(Checkpoint, PAnsiChar(@Body[0]), Length(Body));
          Ready := Checkpoint = Expected;
        end;
        if not Ready then LastProbe := 'listener did not serve this registry';
      except
        on E: Exception do LastProbe := Copy(E.Message, 1, 1024);
      end;
      if Ready then Exit;
      if not Result.Running then Break;
      Sleep(10);
    until GetTickCount64 - Started >= 5000;
    ExitState := 'running';
    if not Result.Running then ExitState := IntToStr(Result.ExitCode)
      + ' (status=' + IntToStr(Result.ExitStatus) + ')';
    Diagnostics := DrainAvailableStream(Result.Stderr, 4096);
    raise Exception.Create('registry CLI listener did not become ready; exit='
      + ExitState + '; last probe: ' + LastProbe + '; stderr: ' + Diagnostics);
  except
    StopRegistryCLI(Result);
    raise;
  end;
end;

procedure StopRegistryCLI(var AProcess: TProcess);
var
  Stopped: TRegistryStopResult;
  FailureMessage: string;
begin
  Stopped := StopRegistryProcess(AProcess);
  FailureMessage := '';
  if not Stopped.Stopped then
    FailureMessage := 'registry CLI listener did not stop after forced termination'
  else if Stopped.Forced then
    FailureMessage := 'registry CLI listener exceeded its 12000 ms shutdown bound';
  if FailureMessage <> '' then
  begin
    if ExceptObject <> nil then
      WriteLn(StdErr, 'registry E2E cleanup: ', FailureMessage)
    else raise Exception.Create(FailureMessage);
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

end.
