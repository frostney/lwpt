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

function ReserveRegistryTestPort: Word;
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

function ReserveRegistryTestPort: Word;
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

function StartRegistryCLI(const ADataDirectory, ABaseURL: string): TProcess;
var
  Started: QWord;
  Ready: Boolean;
  LastProbe, ExitState, Diagnostics: string;
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
        RegistryHTTPBody(ABaseURL + '/.well-known/' + PROGRAM_NAME + '-registry');
        Ready := True;
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
  Port := ReserveRegistryTestPort;
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
