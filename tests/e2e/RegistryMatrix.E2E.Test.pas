program RegistryMatrix.E2E.Test;

{ The registry end-to-end matrix (#56). Each case composes the processes an
  operator and a consumer actually run -- `registry init`, `issue-token`,
  `serve`, `publish`, `sync`, `verify`, `rotate-key`, and a consumer
  `install` -- across one lifecycle boundary:

  - localhost-only HTTP development, live publication and reads while the
    origin serves, a consumer install, and a graceful restart;
  - mirror synchronization, mirror serving while the origin is down, and
    consumer contact failover in both directions;
  - a publication crashed between its durable checkpoint and activation,
    recovery on restart, and the retried publication;
  - signed key rotation while the origin serves, followed by root-pinned
    publication, mirror synchronization, and a consumer install;
  - HTTPS deployments addressed by host name and by IP address;
  - persisted schema versions: a future configuration or state schema
    fails closed without changing the data directory;
  - a pointer-first backup taken while publishing, its restore, and the
    rollback hazard an older restore creates for mirrors.

  Every child process is bound to this program, bounded, and stopped by the
  case's cleanup, including after a failure. A failing case prints its
  command log, server output, and a listing of its data directories, and the
  scratch directory is kept for inspection. The cases use loopback only and
  run on every platform the E2E stage runs; the only platform difference is
  that Windows has no graceful stop signal, so the graceful exit status is
  asserted on Unix. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  Generics.Collections,
  Process,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess,
  Tests.RegistryHTTP,
  Tests.RegistryOrigin,
  Tests.RegistryProcess,
  Tests.RegistryPublish,
  Tests.Scratch;

const
  PACKAGE_NAME = 'mxlib';
  RUN_TIMEOUT_MILLISECONDS = 120000;
  SERVE_REFUSAL_TIMEOUT_MILLISECONDS = 30000;
  CLIENT_BARRIER_TIMEOUT_MILLISECONDS = 30000;
  DUMP_LINE_LIMIT = 400;

type
  { A data directory served through `registry serve`: a mirror or a restored
    origin. }
  TMatrixServer = class
  public
    Name, Root, URL: string;
    Port: Word;
    Process: TProcess;
    Output: string;
    destructor Destroy; override;
    procedure Drain;
    procedure Stop;
  end;

  TRegistryMatrixE2E = class(TTestSuite)
  private
    FScratch, FCase: string;
    FFailed: Boolean;
    FLog: TStringList;
    FOrigins: TObjectList<TPublishOrigin>;
    FServers: TObjectList<TMatrixServer>;
    FArchives: Integer;
    procedure Guard(const ACase: string; const ABody: TTestMethod);
    procedure Cleanup;
    procedure DumpCase(const AReason: string);
    procedure Log(const ALabel: string; const ARun: TLwptResult);
    procedure Require(const ALabel: string; const ARun: TLwptResult);
    procedure RequireFailure(const ALabel: string; const ARun: TLwptResult;
      const ACode: string);
    function RunCLI(const ALabel: string; const AArguments: array of string;
      const ATimeoutMilliseconds: QWord = RUN_TIMEOUT_MILLISECONDS): TLwptResult;
    function NewOrigin(const AName: string; const AHTTPS: Boolean = False;
      const AHost: string = 'localhost'): TPublishOrigin;
    function NewMirror(const AName, AIdentity, AUpstream, AKeyID,
      APublicKey: string): TMatrixServer;
    function InitMirror(AMirror: TMatrixServer; const AIdentity, AUpstream,
      AKeyID, APublicKey: string): TLwptResult;
    function Sync(AMirror: TMatrixServer): TLwptResult;
    function Verify(const ARoot: string): TLwptResult;
    procedure Serve(AServer: TMatrixServer);
    procedure FollowOrigin(AMirror: TMatrixServer; AOrigin: TPublishOrigin;
      const AUpstream: string);
    function WriteArchive(const AVersion, AContent: string): string;
    function Publish(const ALabel, AOrigin, AKeyID, APublicKey, AToken,
      AVersion, AContent: string; const ATesting: Boolean = False;
      const AEnvironment: TStringArray = nil): TLwptResult;
    procedure ExpectPublished(const ARun: TLwptResult; const AIdentity,
      AVersion: string; const ASequence: Integer);
    function Registries(const AIdentity, AKeyID, APublicKey, AOrigin: string;
      const AMirrors: array of string): string;
    function Install(const AName, ARegistries, AConstraint: string): TLwptResult;
    function ConsumerRoot(const AName: string): string;
    procedure ExpectInstalled(const AName, AContent: string);
    function OriginText(AOrigin: TPublishOrigin; const ATarget: string): string;
    function ServerText(AServer: TMatrixServer; const ATarget: string): string;
    procedure BodyLocalhostDevelopment;
    procedure BodyMirrorOutageAndFailover;
    procedure BodyInterruptedPublication;
    procedure BodyKeyRotationWhileServing;
    procedure BodyHTTPSDeployments;
    procedure DeployHTTPS(const ATag, AHost: string);
    procedure BodySchemaVersions;
    procedure ExpectSchemaRefused(const ARoot, AFile, AOld, ANew,
      ACode: string; const ACommands: array of string);
    procedure BodyBackupAndRestore;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestLocalhostDevelopment;
    procedure TestMirrorOutageAndFailover;
    procedure TestInterruptedPublication;
    procedure TestKeyRotationWhileServing;
    procedure TestHTTPSDeployments;
    procedure TestSchemaVersions;
    procedure TestBackupAndRestore;
  end;

{ --- small helpers ------------------------------------------------------- }

function ProjectPrefix: string;
begin
  Result := UpperCase(RegistryProgramName);
end;

function BytesText(const ABytes: TBytes): string;
begin
  Result := '';
  if Length(ABytes) > 0 then
    SetString(Result, PAnsiChar(@ABytes[0]), Length(ABytes));
end;

function Contains(const AText, APart: string): Boolean;
begin
  Result := Pos(APart, AText) > 0;
end;

{ A top-level `key = value` field of a canonical registry document, with the
  quotes of a string value removed. }
function DocumentField(const ADocument, AKey: string): string;
var
  Start: Integer;
begin
  Result := '';
  Start := Pos(#10 + AKey + ' = ', #10 + ADocument);
  if Start = 0 then Exit;
  Result := Copy(ADocument, Start + Length(AKey) + 3, MaxInt);
  if Pos(#10, Result) > 0 then Result := Copy(Result, 1, Pos(#10, Result) - 1);
  if (Length(Result) >= 2) and (Result[1] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function DocumentSequence(const ADocument: string): Integer;
begin
  Result := StrToIntDef(DocumentField(ADocument, 'sequence'), -1);
end;

procedure CopyFileBytes(const ASource, ATarget: string);
begin
  ForceDirectories(ExtractFileDir(ATarget));
  WriteBinaryFile(ATarget, BytesOf(ReadBinaryFile(ASource)));
end;

{ Copies a directory tree byte for byte, skipping the named top-level
  entries. }
procedure CopyTree(const ASource, ATarget: string;
  const ASkip: array of string);
var
  Entry: TSearchRec;
  Skipped: Boolean;
  Index: Integer;
begin
  ForceDirectories(ATarget);
  if FindFirst(ASource + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
      Skipped := False;
      for Index := 0 to High(ASkip) do
        if Entry.Name = ASkip[Index] then Skipped := True;
      if Skipped then Continue;
      if (Entry.Attr and faDirectory) <> 0 then
        CopyTree(ASource + '/' + Entry.Name, ATarget + '/' + Entry.Name, [])
      else CopyFileBytes(ASource + '/' + Entry.Name, ATarget + '/' + Entry.Name);
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

{ Every regular file below ARoot with its SHA-256, in a stable order. }
procedure CollectFingerprint(const ARoot, ARelative: string;
  const ALines: TStringList);
var
  Entry: TSearchRec;
  Path: string;
begin
  if FindFirst(ARoot + ARelative + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
      Path := ARelative + '/' + Entry.Name;
      if (Entry.Attr and faDirectory) <> 0 then
        CollectFingerprint(ARoot, Path, ALines)
      else ALines.Add(Path + ' ' + RegistryArtifactHash(
        BytesOf(ReadBinaryFile(ARoot + Path))));
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

function TreeFingerprint(const ARoot: string): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    CollectFingerprint(ARoot, '', Lines);
    Lines.Sort;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function DirectoryEntryCount(const APath: string): Integer;
var
  Entry: TSearchRec;
begin
  Result := 0;
  if FindFirst(APath + '/*', faAnyFile, Entry) <> 0 then Exit;
  try
    repeat
      if (Entry.Name <> '.') and (Entry.Name <> '..') then Inc(Result);
    until FindNext(Entry) <> 0;
  finally
    FindClose(Entry);
  end;
end;

{ Ends a process at once, like a host crash or a cancelled CI job. }
procedure KillProcess(var AProcess: TProcess);
begin
  if AProcess = nil then Exit;
  if AProcess.Running then
  begin
    {$IFDEF UNIX}
    FpKill(AProcess.ProcessID, SIGKILL);
    {$ELSE}
    TerminateProcess(AProcess.Handle, 1);
    {$ENDIF}
  end;
  StopRegistryProcess(AProcess);
end;

{ --- TMatrixServer --------------------------------------------------------- }

destructor TMatrixServer.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TMatrixServer.Drain;
begin
  if Process = nil then Exit;
  try
    Output := Output + DrainAvailableStream(Process.Output, 65536)
      + DrainAvailableStream(Process.Stderr, 65536);
  except
  end;
end;

procedure TMatrixServer.Stop;
begin
  Drain;
  StopRegistryCLI(Process);
end;

{ --- case lifecycle -------------------------------------------------------- }

procedure TRegistryMatrixE2E.BeforeAll;
begin
  FScratch := CreateScratchRoot('rmx');
  FLog := TStringList.Create;
  FOrigins := TObjectList<TPublishOrigin>.Create(True);
  FServers := TObjectList<TMatrixServer>.Create(True);
end;

procedure TRegistryMatrixE2E.AfterAll;
var
  Started: QWord;
  Failure: string;
begin
  Cleanup;
  FOrigins.Free;
  FServers.Free;
  FLog.Free;
  if FFailed then
  begin
    WriteLn('registry matrix: scratch kept for inspection at ', FScratch);
    Exit;
  end;
  Started := GetTickCount64;
  Failure := '';
  repeat
    try
      RecursiveDelete(FScratch);
      Exit;
    except
      on E: Exception do Failure := E.Message;
    end;
    Sleep(50);
  until GetTickCount64 - Started >= 10000;
  WriteLn(StdErr, 'registry matrix cleanup: ', Failure);
end;

procedure TRegistryMatrixE2E.Guard(const ACase: string;
  const ABody: TTestMethod);
begin
  FCase := FScratch + '/' + ACase;
  ForceDirectories(FCase + '/w');
  FLog.Clear;
  try
    try
      ABody();
    except
      on E: Exception do
      begin
        FFailed := True;
        DumpCase(E.Message);
        raise;
      end;
    end;
  finally
    Cleanup;
  end;
end;

{ Stops every server this case started. Each stop is bounded; a server that
  exceeded its shutdown bound is reported by StopRegistryCLI. }
procedure TRegistryMatrixE2E.Cleanup;
begin
  if Assigned(FServers) then FServers.Clear;
  if Assigned(FOrigins) then FOrigins.Clear;
end;

procedure TRegistryMatrixE2E.DumpCase(const AReason: string);
var
  Lines: Integer;
  Origin: TPublishOrigin;
  Server: TMatrixServer;

  procedure Walk(const ADirectory, APrefix: string);
  var
    Entry: TSearchRec;
    Path: string;
  begin
    if FindFirst(ADirectory + '/*', faAnyFile, Entry) <> 0 then Exit;
    try
      repeat
        if (Entry.Name = '.') or (Entry.Name = '..') then Continue;
        Inc(Lines);
        if Lines > DUMP_LINE_LIMIT then Exit;
        Path := ADirectory + '/' + Entry.Name;
        if (Entry.Attr and faDirectory) <> 0 then
        begin
          WriteLn('  ', APrefix, Entry.Name, '/');
          Walk(Path, APrefix + Entry.Name + '/');
        end
        else
        begin
          WriteLn('  ', APrefix, Entry.Name, ' (', Entry.Size, ' bytes)');
          { Small public state documents explain most failures. Seeds and
            token records are never printed. }
          if ((Entry.Name = 'registry.toml') or (Entry.Name = 'current.toml')
            or (Entry.Name = 'sync-attempt.toml')) and (Entry.Size < 4096) then
            WriteLn(ReadBinaryFile(Path));
        end;
      until FindNext(Entry) <> 0;
    finally
      FindClose(Entry);
    end;
  end;

begin
  WriteLn('--- registry matrix failure in ', FCase, ' ---');
  WriteLn(AReason);
  WriteLn('--- command log ---');
  WriteLn(FLog.Text);
  if Assigned(FOrigins) then
    for Origin in FOrigins do
    begin
      if Assigned(Origin.Serve) then
      try
        Origin.Stop;
      except
      end;
      WriteLn('--- origin ', Origin.DataDirectory, ' (', Origin.Base,
        ') output ---');
      WriteLn(Origin.Outputs);
    end;
  if Assigned(FServers) then
    for Server in FServers do
    begin
      Server.Drain;
      WriteLn('--- ', Server.Name, ' ', Server.Root, ' (', Server.URL,
        ') output ---');
      WriteLn(Server.Output);
    end;
  WriteLn('--- files ---');
  Lines := 0;
  Walk(FCase, '');
end;

procedure TRegistryMatrixE2E.Log(const ALabel: string; const ARun: TLwptResult);
begin
  FLog.Add('$ ' + ALabel + ' -> exit ' + IntToStr(ARun.ExitCode));
  if ARun.TimedOut then FLog.Add('  (timed out)');
  if Trim(ARun.Stdout) <> '' then FLog.Add('  stdout: ' + Trim(ARun.Stdout));
  if Trim(ARun.Stderr) <> '' then FLog.Add('  stderr: ' + Trim(ARun.Stderr));
end;

procedure TRegistryMatrixE2E.Require(const ALabel: string;
  const ARun: TLwptResult);
begin
  if ARun.ExitCode <> 0 then
    raise Exception.Create(ALabel + ' failed with exit ' + IntToStr(ARun.ExitCode)
      + ': ' + Trim(ARun.Stderr));
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

procedure TRegistryMatrixE2E.RequireFailure(const ALabel: string;
  const ARun: TLwptResult; const ACode: string);
begin
  if (ARun.ExitCode <> 1) or not Contains(ARun.Stderr, ACode) then
    raise Exception.Create(ALabel + ': expected exit 1 with "' + ACode
      + '", got exit ' + IntToStr(ARun.ExitCode) + ': ' + Trim(ARun.Stderr));
  Expect<Integer>(ARun.ExitCode).ToBe(1);
end;

function TRegistryMatrixE2E.RunCLI(const ALabel: string;
  const AArguments: array of string;
  const ATimeoutMilliseconds: QWord): TLwptResult;
begin
  Result := RunLwpt(AArguments, FCase + '/w', [], ATimeoutMilliseconds);
  Log(ALabel, Result);
end;

function TRegistryMatrixE2E.NewOrigin(const AName: string;
  const AHTTPS: Boolean; const AHost: string): TPublishOrigin;
var
  Port: Word;
begin
  Port := FindAvailableRegistryTestPort;
  Result := TPublishOrigin.Create(FCase, AName, Port, Port, AHTTPS, '', AHost);
  FOrigins.Add(Result);
end;

function TRegistryMatrixE2E.InitMirror(AMirror: TMatrixServer;
  const AIdentity, AUpstream, AKeyID, APublicKey: string): TLwptResult;
begin
  Result := RunCLI(AMirror.Name + ' init', ['registry', 'init', '--role',
    'mirror', '--data-dir', AMirror.Root, '--identity', AIdentity, '--base-url',
    AMirror.URL, '--port', IntToStr(AMirror.Port), '--upstream', AUpstream,
    '--key-id', AKeyID, '--public-key', APublicKey]);
end;

function TRegistryMatrixE2E.NewMirror(const AName, AIdentity, AUpstream,
  AKeyID, APublicKey: string): TMatrixServer;
begin
  Result := TMatrixServer.Create;
  FServers.Add(Result);
  Result.Name := AName;
  Result.Root := FCase + '/' + AName;
  Result.Port := FindAvailableRegistryTestPort;
  Result.URL := 'http://localhost:' + IntToStr(Result.Port);
  Require(AName + ' init', InitMirror(Result, AIdentity, AUpstream, AKeyID,
    APublicKey));
end;

function TRegistryMatrixE2E.Sync(AMirror: TMatrixServer): TLwptResult;
begin
  Result := RunCLI(AMirror.Name + ' sync', ['registry', 'sync', '--data-dir',
    AMirror.Root]);
end;

function TRegistryMatrixE2E.Verify(const ARoot: string): TLwptResult;
begin
  Result := RunCLI('verify ' + ExtractFileName(ARoot), ['registry', 'verify',
    '--data-dir', ARoot]);
end;

procedure TRegistryMatrixE2E.Serve(AServer: TMatrixServer);
begin
  if AServer.Process <> nil then
    raise Exception.Create(AServer.Name + ' is already serving');
  { Readiness requires this child's own bind announcement, then discovery
    and the checkpoint this data directory holds. }
  AServer.Process := StartRegistryCLI(AServer.Root, AServer.URL);
  { A start that recovered from a port collision moved the listener. }
  AServer.Port := StrToInt(Copy(AServer.URL, LastDelimiter(':', AServer.URL)
    + 1, MaxInt));
end;

{ An origin restart that recovered from a port collision moved its base
  URL; the mirror's upstream follows it, as an operator would. }
procedure TRegistryMatrixE2E.FollowOrigin(AMirror: TMatrixServer;
  AOrigin: TPublishOrigin; const AUpstream: string);
begin
  if AOrigin.Base = AUpstream then Exit;
  Require(AMirror.Name + ' follows the moved origin', InitMirror(AMirror,
    AOrigin.Identity, AOrigin.Base, AOrigin.KeyID, AOrigin.PublicKey));
end;

function TRegistryMatrixE2E.WriteArchive(const AVersion,
  AContent: string): string;
begin
  Inc(FArchives);
  Result := FCase + '/w/a' + IntToStr(FArchives) + '.tar.gz';
  WriteBinaryFile(Result, PublishTarGz(PACKAGE_NAME, AVersion, AContent));
end;

function TRegistryMatrixE2E.Publish(const ALabel, AOrigin, AKeyID,
  APublicKey, AToken, AVersion, AContent: string; const ATesting: Boolean;
  const AEnvironment: TStringArray): TLwptResult;
begin
  Result := RunPublish(WriteArchive(AVersion, AContent), AOrigin, AKeyID,
    APublicKey, '', AToken, FCase + '/w', [], AEnvironment, ATesting);
  Log(ALabel, Result);
end;

{ The success line names the authenticated origin identity, not the
  contacted base URL. }
procedure TRegistryMatrixE2E.ExpectPublished(const ARun: TLwptResult;
  const AIdentity, AVersion: string; const ASequence: Integer);
var
  Expected: string;
begin
  Expected := 'published ' + PACKAGE_NAME + '@' + AVersion + ' to ' + AIdentity
    + ' at sequence ' + IntToStr(ASequence) + ' (archive ';
  if Pos(Expected, PublishLine(ARun)) <> 1 then
    raise Exception.Create('expected "' + Expected + '", got "'
      + PublishLine(ARun) + '"; stderr: ' + Trim(ARun.Stderr));
  Expect<Integer>(ARun.ExitCode).ToBe(0);
end;

function TRegistryMatrixE2E.Registries(const AIdentity, AKeyID, APublicKey,
  AOrigin: string; const AMirrors: array of string): string;
var
  Index: Integer;
begin
  Result := '[registries.corp]'#10 + 'identity = "' + AIdentity + '"'#10
    + 'key-id = "' + AKeyID + '"'#10 + 'public-key = "' + APublicKey + '"'#10
    + 'origin = "' + AOrigin + '"'#10;
  if Length(AMirrors) = 0 then Exit;
  Result := Result + 'mirrors = [';
  for Index := 0 to High(AMirrors) do
  begin
    if Index > 0 then Result := Result + ', ';
    Result := Result + '"' + AMirrors[Index] + '"';
  end;
  Result := Result + ']'#10;
end;

function TRegistryMatrixE2E.ConsumerRoot(const AName: string): string;
begin
  Result := FCase + '/' + AName;
end;

{ A consumer project with isolated per-user registry state and cache. The
  test build carries the development exception for http://localhost
  contacts; release binaries require HTTPS on a public address. }
function TRegistryMatrixE2E.Install(const AName, ARegistries,
  AConstraint: string): TLwptResult;
var
  Root: string;
begin
  Root := ConsumerRoot(AName);
  ForceDirectories(Root + '/p/source');
  ForceDirectories(Root + '/s');
  ForceDirectories(Root + '/c');
  WriteBinaryFile(Root + '/p/source/main.pas', BytesOf('program main;'#10
    + '{$mode delphi}{$H+}'#10 + 'begin end.'#10));
  WriteBinaryFile(Root + '/p/lwpt.toml', BytesOf('[package]'#10
    + 'name = "consumer"'#10 + 'version = "1.0.0"'#10 + 'units = ["source"]'#10
    + ARegistries + '[dependencies]'#10 + PACKAGE_NAME + ' = "registry:corp/'
    + PACKAGE_NAME + '@' + AConstraint + '"'#10));
  Result := RunLwptTesting(['install'], Root + '/p',
    [ProjectPrefix + '_REGISTRY_STATE_DIR=' + Root + '/s',
     ProjectPrefix + '_CACHE_DIR=' + Root + '/c'], RUN_TIMEOUT_MILLISECONDS);
  Log('install ' + AName, Result);
end;

procedure TRegistryMatrixE2E.ExpectInstalled(const AName, AContent: string);
var
  Path: string;
begin
  Path := ConsumerRoot(AName) + '/p/.lwpt/modules/' + PACKAGE_NAME
    + '/source/content.txt';
  if not FileExists(Path) then
    raise Exception.Create('consumer ' + AName + ' has no installed ' + Path);
  Expect<string>(ReadBinaryFile(Path)).ToBe(AContent);
end;

function TRegistryMatrixE2E.OriginText(AOrigin: TPublishOrigin;
  const ATarget: string): string;
var
  Response: TRawHTTPResponse;
begin
  Response := AOrigin.Request('GET', ATarget, [], nil);
  if Response.Status <> 200 then
    raise Exception.Create('GET ' + ATarget + ' from ' + AOrigin.Base
      + ' answered ' + IntToStr(Response.Status));
  Result := RawHTTPBodyText(Response);
end;

function TRegistryMatrixE2E.ServerText(AServer: TMatrixServer;
  const ATarget: string): string;
begin
  Result := BytesText(RegistryHTTPBody(AServer.URL + ATarget));
end;

const
  CHECKPOINT_PATH = '/v1/checkpoints/latest.toml';

{ --- cases ----------------------------------------------------------------- }

procedure TRegistryMatrixE2E.TestLocalhostDevelopment;
begin
  Guard('a', BodyLocalhostDevelopment);
end;

procedure TRegistryMatrixE2E.BodyLocalhostDevelopment;
var
  Origin: TPublishOrigin;
  Token, Line, RecordText, Discovery, Checkpoint, Port: string;
  Archive: TBytes;
  PID: Integer;
  Run: TLwptResult;
  Stopped: TRegistryStopResult;
begin
  { Plain HTTP is a development exception for the exact host localhost on a
    loopback listener. Anything else is refused before any state exists. }
  Port := IntToStr(FindAvailableRegistryTestPort);
  RequireFailure('remote plain HTTP', RunCLI('init remote http', ['registry',
    'init', '--data-dir', FCase + '/r', '--base-url',
    'http://registry.example.com:' + Port, '--port', Port]),
    'insecure_transport');
  RequireFailure('loopback address plain HTTP', RunCLI('init 127.0.0.1 http',
    ['registry', 'init', '--data-dir', FCase + '/r', '--base-url',
    'http://127.0.0.1:' + Port, '--port', Port]), 'insecure_transport');
  RequireFailure('wildcard listener plain HTTP', RunCLI('init wildcard http',
    ['registry', 'init', '--data-dir', FCase + '/r', '--base-url',
    'http://localhost:' + Port, '--port', Port, '--listen', '0.0.0.0']),
    'insecure_transport');
  Expect<Boolean>(FileExists(FCase + '/r/registry.toml')).ToBe(False);

  { Initialization, a scoped token, and live publication while serving. }
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME, '--expires-days', '1',
    '--label', 'matrix']);
  Origin.Start;
  PID := Origin.Serve.ProcessID;
  Expect<Integer>(DocumentSequence(OriginText(Origin, CHECKPOINT_PATH))).ToBe(1);
  Archive := PublishTarGz(PACKAGE_NAME, '1.0.0', 'one');
  Run := Publish('publish 1.0.0', Origin.Base, Origin.KeyID, Origin.PublicKey,
    Token, '1.0.0', 'one');
  ExpectPublished(Run, Origin.Identity, '1.0.0', 2);
  Expect<Boolean>(Origin.Serve.Running).ToBe(True);
  Expect<Integer>(Origin.Serve.ProcessID).ToBe(PID);

  { Reads: discovery, the signed head, the record, and the exact archive. }
  Discovery := OriginText(Origin, '/.well-known/' + RegistryProgramName
    + '-registry');
  Expect<string>(DocumentField(Discovery, 'role')).ToBe('origin');
  Expect<string>(DocumentField(Discovery, 'base_url')).ToBe(Origin.Base);
  Checkpoint := OriginText(Origin, CHECKPOINT_PATH);
  Expect<Integer>(DocumentSequence(Checkpoint)).ToBe(2);
  Expect<string>(DocumentField(Checkpoint, 'key_id')).ToBe(Origin.KeyID);
  Line := PublishLine(Run);
  RecordText := OriginText(Origin, '/v1/records/sha256/'
    + Copy(PublishedRecordHash(Line), 8, 64) + '.toml');
  Expect<string>(DocumentField(RecordText, 'name')).ToBe(PACKAGE_NAME);
  Expect<string>(DocumentField(RecordText, 'version')).ToBe('1.0.0');
  Expect<string>(DocumentField(RecordText, 'archive'))
    .ToBe(RegistryArtifactHash(Archive));
  Expect<string>(OriginText(Origin, '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(Archive), 8, 64))).ToBe(BytesText(Archive));

  { A consumer resolves, verifies, and installs from the running origin. }
  Run := Install('c1', Registries(Origin.Identity, Origin.KeyID, Origin.PublicKey,
    Origin.Base, []), '^1.0.0');
  Require('consumer install', Run);
  ExpectInstalled('c1', 'one');
  { Only the test build accepts the localhost development contact. }
  Run := RunLwpt(['install'], ConsumerRoot('c1') + '/p',
    [ProjectPrefix + '_REGISTRY_STATE_DIR=' + ConsumerRoot('c1') + '/s',
     ProjectPrefix + '_CACHE_DIR=' + ConsumerRoot('c1') + '/c'],
    RUN_TIMEOUT_MILLISECONDS);
  Log('release install c1', Run);
  RequireFailure('release binary localhost contact', Run, 'insecure_transport');

  { A graceful stop and a fresh process on the same data directory serve the
    same signed head, and publication continues from it. }
  Stopped := Origin.StopGracefully;
  Expect<Boolean>(Stopped.Stopped).ToBe(True);
  Expect<Boolean>(Stopped.Forced).ToBe(False);
  {$IFDEF UNIX}
  { SIGTERM is a graceful stop. Windows has no such signal for a console
    child, so the helper terminates it there. }
  Expect<Integer>(Stopped.ExitStatus).ToBe(0);
  {$ENDIF}
  Origin.Start;
  Expect<string>(OriginText(Origin, CHECKPOINT_PATH)).ToBe(Checkpoint);
  Run := Publish('publish 1.1.0 after restart', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.1.0', 'two');
  ExpectPublished(Run, Origin.Identity, '1.1.0', 3);
  Require('consumer install after restart', Install('c2',
    Registries(Origin.Identity, Origin.KeyID, Origin.PublicKey, Origin.Base, []),
    '^1.0.0'));
  ExpectInstalled('c2', 'two');
end;

procedure TRegistryMatrixE2E.TestMirrorOutageAndFailover;
begin
  Guard('b', BodyMirrorOutageAndFailover);
end;

procedure TRegistryMatrixE2E.BodyMirrorOutageAndFailover;
var
  Origin: TPublishOrigin;
  Mirror: TMatrixServer;
  Token, Checkpoint, Dead, Lock, Upstream: string;
  Archive: TBytes;
  Run: TLwptResult;
begin
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Origin.Start;
  ExpectPublished(Publish('publish 1.0.0', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.0.0', 'one'), Origin.Identity, '1.0.0', 2);
  Archive := PublishTarGz(PACKAGE_NAME, '1.0.0', 'one');

  { The mirror synchronizes and verifies the origin's signed history. }
  Mirror := NewMirror('m', Origin.Identity, Origin.Base, Origin.KeyID,
    Origin.PublicKey);
  Require('mirror sync', Sync(Mirror));
  Serve(Mirror);
  Checkpoint := OriginText(Origin, CHECKPOINT_PATH);

  { Origin outage: the mirror keeps serving the exact signed head and
    archive, reports fresh proof, and a failed sync changes nothing. }
  Origin.Stop;
  Expect<string>(ServerText(Mirror, CHECKPOINT_PATH)).ToBe(Checkpoint);
  Expect<string>(ServerText(Mirror, '/v1/objects/sha256/'
    + Copy(RegistryArtifactHash(Archive), 8, 64))).ToBe(BytesText(Archive));
  Run := Verify(Mirror.Root);
  Require('mirror verify during outage', Run);
  Expect<Boolean>(Contains(Run.Stdout, 'freshness = "fresh"')).ToBe(True);
  Expect<Integer>(DocumentSequence(Run.Stdout)).ToBe(2);
  RequireFailure('mirror sync during outage', Sync(Mirror),
    'registry_transport_failed');
  Expect<string>(ServerText(Mirror, CHECKPOINT_PATH)).ToBe(Checkpoint);

  { Failover: an unreachable mirror is skipped, the serving mirror answers,
    and the origin (down) is never needed. }
  Dead := 'http://localhost:' + IntToStr(FindAvailableRegistryTestPort);
  Run := Install('c1', Registries(Origin.Identity, Origin.KeyID, Origin.PublicKey,
    Origin.Base, [Dead, Mirror.URL]), '^1.0.0');
  Require('install through the mirror during the outage', Run);
  ExpectInstalled('c1', 'one');
  Lock := ReadBinaryFile(ConsumerRoot('c1') + '/p/lwpt.lock');
  Expect<Boolean>(Contains(Lock, 'resolvedURL = "' + Mirror.URL
    + '/v1/objects/')).ToBe(True);
  Expect<Boolean>(Contains(Lock, 'registryOrigin = "' + Origin.Identity + '"'))
    .ToBe(True);

  { The origin returns and publishes; an incremental sync catches up. }
  Upstream := Origin.Base;
  Origin.Start;
  FollowOrigin(Mirror, Origin, Upstream);
  ExpectPublished(Publish('publish 1.1.0', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.1.0', 'two'), Origin.Identity, '1.1.0', 3);
  Require('incremental mirror sync', Sync(Mirror));
  Expect<Integer>(DocumentSequence(ServerText(Mirror, CHECKPOINT_PATH))).ToBe(3);

  { The mirror goes down instead: the consumer falls back to the origin. }
  Mirror.Stop;
  Run := Install('c2', Registries(Origin.Identity, Origin.KeyID, Origin.PublicKey,
    Origin.Base, [Mirror.URL]), '^1.0.0');
  Require('install through the origin while the mirror is down', Run);
  ExpectInstalled('c2', 'two');
  Expect<Boolean>(Contains(ReadBinaryFile(ConsumerRoot('c2') + '/p/lwpt.lock'),
    'resolvedURL = "' + Origin.Base + '/v1/objects/')).ToBe(True);
end;

procedure TRegistryMatrixE2E.TestInterruptedPublication;
begin
  Guard('c', BodyInterruptedPublication);
end;

procedure TRegistryMatrixE2E.BodyInterruptedPublication;
var
  Origin: TPublishOrigin;
  Mirror: TMatrixServer;
  Client: TProcess;
  Token, Ready, Release, Before, ClientOutput, Archive: string;
  Started: QWord;
  Run: TLwptResult;
begin
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Ready := FCase + '/ready';
  Release := FCase + '/release';
  { The test build pauses each publication after its checkpoint, snapshot,
    and record are durable and before the activation pointer moves. The
    release path is never created, so the crash happens there. }
  Origin.StartWith(True, [ProjectPrefix + '_TEST_REGISTRY_PUBLICATION_BARRIER='
    + Ready + '|' + Release]);
  Before := OriginText(Origin, CHECKPOINT_PATH);
  Archive := WriteArchive('1.0.0', 'one');

  Client := TProcess.Create(nil);
  try
    Client.Executable := ExpectedExe(LwptBinaryPath);
    Client.CurrentDirectory := FCase + '/w';
    Client.Options := [poUsePipes];
    Client.Parameters.Add('registry');
    Client.Parameters.Add('publish');
    Client.Parameters.Add(Archive);
    Client.Parameters.Add('--origin');
    Client.Parameters.Add(Origin.Base);
    Client.Parameters.Add('--key-id');
    Client.Parameters.Add(Origin.KeyID);
    Client.Parameters.Add('--public-key');
    Client.Parameters.Add(Origin.PublicKey);
    ConfigureProcessEnvironment(Client, [ProjectPrefix + '_REGISTRY_TOKEN='
      + Token]);
    BindRegistryChildToParent(Client);
    Client.Execute;
    ClientOutput := '';
    Started := GetTickCount64;
    while not FileExists(Ready) and Client.Running
      and (GetTickCount64 - Started < CLIENT_BARRIER_TIMEOUT_MILLISECONDS) do
    begin
      ClientOutput := ClientOutput + DrainAvailableStream(Client.Output, 65536)
        + DrainAvailableStream(Client.Stderr, 65536);
      Sleep(10);
    end;
    if not FileExists(Ready) then
      raise Exception.Create('the publication never reached its activation '
        + 'barrier; client: ' + ClientOutput + DrainAvailableStream(Client.Stderr));
    { Readers keep the old complete head while the new one is staged. }
    Expect<string>(OriginText(Origin, CHECKPOINT_PATH)).ToBe(Before);
    { Crash both sides: the server and the publishing CI job. }
    Origin.Kill;
    ClientOutput := ClientOutput + DrainAvailableStream(Client.Output, 65536)
      + DrainAvailableStream(Client.Stderr, 65536);
    KillProcess(Client);
  finally
    KillProcess(Client);
  end;
  FLog.Add('crashed publish client output: ' + Trim(ClientOutput));
  Expect<Boolean>(Contains(ClientOutput, 'published ')).ToBe(False);

  { Offline, the data directory still holds the previous signed head, and
    opening it reclaims the crashed publication's private staging. }
  Run := Verify(Origin.DataDirectory);
  Require('verify after the crash', Run);
  Expect<Integer>(DocumentSequence(Run.Stdout)).ToBe(1);
  Expect<Integer>(DirectoryEntryCount(Origin.DataDirectory + '/tmp')).ToBe(0);

  { The restarted origin serves exactly the old head, which a mirror
    verifies end to end. }
  Origin.Start;
  Expect<string>(OriginText(Origin, CHECKPOINT_PATH)).ToBe(Before);
  Mirror := NewMirror('m', Origin.Identity, Origin.Base, Origin.KeyID,
    Origin.PublicKey);
  Require('mirror sync after recovery', Sync(Mirror));
  Expect<Integer>(DocumentSequence(Verify(Mirror.Root).Stdout)).ToBe(1);

  { The retried publication commits the same identity at the next
    sequence: the interrupted attempt consumed nothing. }
  ExpectPublished(Publish('retried publish', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.0.0', 'one'), Origin.Identity, '1.0.0', 2);
  Require('mirror sync after the retry', Sync(Mirror));
  Run := Verify(Mirror.Root);
  Expect<Integer>(DocumentSequence(Run.Stdout)).ToBe(2);
  Expect<Boolean>(Contains(Run.Stdout, 'freshness = "fresh"')).ToBe(True);
end;

procedure TRegistryMatrixE2E.TestKeyRotationWhileServing;
begin
  Guard('d', BodyKeyRotationWhileServing);
end;

procedure TRegistryMatrixE2E.BodyKeyRotationWhileServing;
var
  Origin: TPublishOrigin;
  Mirror: TMatrixServer;
  Token, Checkpoint, Rotations: string;
  PID: Integer;
  Run: TLwptResult;
begin
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Origin.Start;
  PID := Origin.Serve.ProcessID;
  ExpectPublished(Publish('publish 1.0.0', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.0.0', 'one'), Origin.Identity, '1.0.0', 2);
  Mirror := NewMirror('m', Origin.Identity, Origin.Base, Origin.KeyID,
    Origin.PublicKey);
  Require('mirror sync before rotation', Sync(Mirror));

  { Rotation is operator-local and runs against the live data directory. }
  Run := RunCLI('rotate-key', ['registry', 'rotate-key', '--data-dir',
    Origin.DataDirectory, '--from-key', Origin.KeyID]);
  Require('rotate-key while serving', Run);
  Expect<Boolean>(Contains(Run.Stdout,
    'rotated registry signing key at sequence 3')).ToBe(True);
  Expect<Integer>(Origin.Serve.ProcessID).ToBe(PID);
  Checkpoint := OriginText(Origin, CHECKPOINT_PATH);
  Expect<Integer>(DocumentSequence(Checkpoint)).ToBe(3);
  Expect<Boolean>(DocumentField(Checkpoint, 'key_id') <> Origin.KeyID).ToBe(True);
  Rotations := OriginText(Origin, '/v1/rotations?after=0&limit=10');
  Expect<Boolean>(Contains(Rotations, 'effective_sequence = 3')).ToBe(True);

  { Every client keeps only the root pin and walks the dual-signed chain. }
  ExpectPublished(Publish('publish 1.1.0 after rotation', Origin.Base,
    Origin.KeyID, Origin.PublicKey, Token, '1.1.0', 'two'), Origin.Identity,
    '1.1.0', 4);
  Require('mirror sync across the rotation', Sync(Mirror));
  Expect<Integer>(DocumentSequence(Verify(Mirror.Root).Stdout)).ToBe(4);
  { A repeated rotation with the old expected key fails its precondition. }
  RequireFailure('stale rotate-key', RunCLI('rotate-key again', ['registry',
    'rotate-key', '--data-dir', Origin.DataDirectory, '--from-key',
    Origin.KeyID]), 'rotation_precondition_failed');
  Expect<Integer>(Origin.LatestSequence).ToBe(4);

  { During an origin outage the consumer verifies the rotation chain from
    its root pin through the mirror. }
  Serve(Mirror);
  Origin.Stop;
  Require('install across the rotation', Install('c1', Registries(Origin.Identity,
    Origin.KeyID, Origin.PublicKey, Origin.Base, [Mirror.URL]), '^1.0.0'));
  ExpectInstalled('c1', 'two');
end;

procedure TRegistryMatrixE2E.TestHTTPSDeployments;
begin
  Guard('e', BodyHTTPSDeployments);
end;

procedure TRegistryMatrixE2E.BodyHTTPSDeployments;
begin
  DeployHTTPS('h', 'localhost');
  DeployHTTPS('i', '127.0.0.1');
end;

{ An HTTPS origin addressed by AHost. The committed test identity names both
  `localhost` and `127.0.0.1`; only the test build trusts its root. }
procedure TRegistryMatrixE2E.DeployHTTPS(const ATag, AHost: string);
var
  Origin: TPublishOrigin;
  Token, Discovery: string;
  Trust: TStringArray;
  Run: TLwptResult;
begin
  Origin := NewOrigin(ATag, True, AHost);
  Expect<Boolean>(Pos('https://' + AHost + ':', Origin.Base) = 1).ToBe(True);
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Origin.Start;
  Discovery := OriginText(Origin, '/.well-known/' + RegistryProgramName
    + '-registry');
  Expect<string>(DocumentField(Discovery, 'origin')).ToBe(Origin.Identity);
  Expect<string>(DocumentField(Discovery, 'base_url')).ToBe(Origin.Base);
  SetLength(Trust, 1);
  Trust[0] := ProjectPrefix + '_TEST_REGISTRY_TRUST_ANCHORS='
    + TestRootCertificatePath;
  ExpectPublished(Publish('publish over https ' + AHost, Origin.Base,
    Origin.KeyID, Origin.PublicKey, Token, '1.0.0', 'tls ' + AHost, True, Trust),
    Origin.Identity, '1.0.0', 2);
  { The release binary verifies against the system store only, for the host
    name and the IP address alike. }
  Run := Publish('release publish over https ' + AHost, Origin.Base,
    Origin.KeyID, Origin.PublicKey, Token, '1.0.1', 'refused');
  RequireFailure('untrusted certificate', Run,
    'registry_tls_verification_failed');
  Expect<Integer>(Origin.LatestSequence).ToBe(2);
  Origin.Stop;
end;

procedure TRegistryMatrixE2E.TestSchemaVersions;
begin
  Guard('f', BodySchemaVersions);
end;

{ Replaces AFile below ARoot with AOld changed to ANew, runs each command
  and requires it to fail with ACode, and requires the data directory to be
  byte-identical to the altered tree right after every rejection. Only then
  is the original file restored. }
procedure TRegistryMatrixE2E.ExpectSchemaRefused(const ARoot, AFile, AOld,
  ANew, ACode: string; const ACommands: array of string);
var
  Original, Altered, Fingerprint: string;
  Index: Integer;
  Run: TLwptResult;
begin
  Original := ReadBinaryFile(ARoot + '/' + AFile);
  Altered := StringReplace(Original, AOld, ANew, []);
  if Altered = Original then
    raise Exception.Create(AFile + ' does not contain ' + AOld);
  WriteBinaryFile(ARoot + '/' + AFile, BytesOf(Altered));
  Fingerprint := TreeFingerprint(ARoot);
  for Index := 0 to High(ACommands) do
  begin
    Run := RunCLI(ACommands[Index] + ' with ' + ANew, ['registry',
      ACommands[Index], '--data-dir', ARoot], SERVE_REFUSAL_TIMEOUT_MILLISECONDS);
    RequireFailure(ACommands[Index] + ' with ' + ANew, Run, ACode);
    Expect<Boolean>(Contains(Run.Stdout, 'listening at')).ToBe(False);
    Expect<string>(TreeFingerprint(ARoot)).ToBe(Fingerprint);
  end;
  WriteBinaryFile(ARoot + '/' + AFile, BytesOf(Original));
end;

procedure TRegistryMatrixE2E.BodySchemaVersions;
const
  CONFIG_REFUSED = 'state_corrupt: unsupported registry configuration schema';
  STATE_REFUSED = 'state_corrupt: unsupported committed-state schema';
var
  Origin: TPublishOrigin;
  Mirror: TMatrixServer;
  Token, Checkpoint, Before, MirrorBefore, Upstream: string;
begin
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Origin.Start;
  ExpectPublished(Publish('publish 1.0.0', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.0.0', 'one'), Origin.Identity, '1.0.0', 2);
  Checkpoint := OriginText(Origin, CHECKPOINT_PATH);
  Mirror := NewMirror('m', Origin.Identity, Origin.Base, Origin.KeyID,
    Origin.PublicKey);
  Require('mirror sync', Sync(Mirror));
  Origin.Stop;
  Before := TreeFingerprint(Origin.DataDirectory);
  MirrorBefore := TreeFingerprint(Mirror.Root);

  { Documents written by a newer schema are refused before anything is
    opened, served, recovered, or rewritten: an origin's configuration and
    committed state for serve and verify, a mirror's for sync and verify. }
  ExpectSchemaRefused(Origin.DataDirectory, 'registry.toml',
    '-registry-origin-config-v1"', '-registry-origin-config-v2"',
    CONFIG_REFUSED, ['serve', 'verify']);
  ExpectSchemaRefused(Origin.DataDirectory, 'state/current.toml',
    '-registry-state-v1"', '-registry-state-v2"', STATE_REFUSED,
    ['serve', 'verify']);
  ExpectSchemaRefused(Mirror.Root, 'registry.toml',
    '-registry-mirror-config-v1"', '-registry-mirror-config-v2"',
    CONFIG_REFUSED, ['sync', 'verify', 'serve']);
  ExpectSchemaRefused(Mirror.Root, 'state/current.toml',
    '-registry-mirror-state-v1"', '-registry-mirror-state-v2"', STATE_REFUSED,
    ['sync', 'verify', 'serve']);
  Expect<string>(TreeFingerprint(Origin.DataDirectory)).ToBe(Before);
  Expect<string>(TreeFingerprint(Mirror.Root)).ToBe(MirrorBefore);

  { The supported schema serves the same signed head again. }
  Upstream := Origin.Base;
  Origin.Start;
  FollowOrigin(Mirror, Origin, Upstream);
  Expect<string>(OriginText(Origin, CHECKPOINT_PATH)).ToBe(Checkpoint);
  Require('mirror sync after the restore', Sync(Mirror));
end;

procedure TRegistryMatrixE2E.TestBackupAndRestore;
begin
  Guard('g', BodyBackupAndRestore);
end;

procedure TRegistryMatrixE2E.BodyBackupAndRestore;
var
  Origin: TPublishOrigin;
  Witness, Restored, Fresh: TMatrixServer;
  Token, Backup, Head: string;
  Run: TLwptResult;
begin
  Origin := NewOrigin('o');
  Token := Origin.IssueToken(['--packages', PACKAGE_NAME]);
  Origin.Start;
  ExpectPublished(Publish('publish 1.0.0', Origin.Base, Origin.KeyID,
    Origin.PublicKey, Token, '1.0.0', 'one'), Origin.Identity, '1.0.0', 2);
  Witness := NewMirror('m1', Origin.Identity, Origin.Base, Origin.KeyID,
    Origin.PublicKey);
  Require('witness sync', Sync(Witness));

  { A file-level backup of a serving origin copies the configuration and
    the activation pointer first, then the immutable content. A
    publication that lands between the two phases only adds unreferenced
    files to the copy. }
  Backup := FCase + '/b';
  CopyFileBytes(Origin.DataDirectory + '/registry.toml', Backup + '/registry.toml');
  CopyTree(Origin.DataDirectory + '/state', Backup + '/state', []);
  ExpectPublished(Publish('publish 1.1.0 during the backup', Origin.Base,
    Origin.KeyID, Origin.PublicKey, Token, '1.1.0', 'two'), Origin.Identity,
    '1.1.0', 3);
  Require('witness sync of sequence 3', Sync(Witness));
  CopyTree(Origin.DataDirectory, Backup, ['registry.toml', 'state', 'tmp',
    'locks', 'incoming']);

  { The origin is lost. The backup restores as a complete, verifiable origin
    at the head its pointer names. }
  Origin.Stop;
  Run := Verify(Backup);
  Require('verify the restored backup', Run);
  Expect<Integer>(DocumentSequence(Run.Stdout)).ToBe(2);
  Restored := TMatrixServer.Create;
  FServers.Add(Restored);
  Restored.Name := 'restored';
  Restored.Root := Backup;
  Restored.URL := Origin.Base;
  Serve(Restored);
  Head := ServerText(Restored, CHECKPOINT_PATH);
  Expect<Integer>(DocumentSequence(Head)).ToBe(2);
  Fresh := NewMirror('m2', Origin.Identity, Restored.URL, Origin.KeyID,
    Origin.PublicKey);
  Require('fresh mirror of the restored origin', Sync(Fresh));
  Expect<Integer>(DocumentSequence(Verify(Fresh.Root).Stdout)).ToBe(2);

  { Rollback hazard: the restored origin reuses sequence 3 for different
    content. A mirror that already accepted the lost sequence 3 refuses the
    rolled-back history as equivocation and keeps serving what it had. }
  ExpectPublished(Publish('publish diverging 1.1.0', Restored.URL, Origin.KeyID,
    Origin.PublicKey, Token, '1.1.0', 'diverged'), Origin.Identity, '1.1.0', 3);
  Require('point the witness at the restored origin', InitMirror(Witness,
    Origin.Identity, Restored.URL, Origin.KeyID, Origin.PublicKey));
  RequireFailure('witness sync after rollback', Sync(Witness),
    'checkpoint_equivocation');
  Run := Verify(Witness.Root);
  Require('witness verify after rollback', Run);
  Expect<Integer>(DocumentSequence(Run.Stdout)).ToBe(3);
end;

procedure TRegistryMatrixE2E.SetupTests;
begin
  Test('localhost HTTP development: init policy, live publish, reads, install, and restart',
    TestLocalhostDevelopment);
  Test('a mirror syncs, serves through an origin outage, and consumers fail over both ways',
    TestMirrorOutageAndFailover);
  Test('a publication crashed before activation leaves the old head and its retry commits',
    TestInterruptedPublication);
  Test('a key rotated while serving is followed by root-pinned publish, sync, and install',
    TestKeyRotationWhileServing);
  Test('HTTPS origins addressed by host name and by IP address publish and verify',
    TestHTTPSDeployments);
  Test('future configuration and state schemas fail serve, verify, and sync without changing data',
    TestSchemaVersions);
  Test('a pointer-first backup restores a verifiable origin and a rollback is refused',
    TestBackupAndRestore);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryMatrixE2E.Create('registry matrix e2e'));
  TestRunnerProgram.Run;
end.
