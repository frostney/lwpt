{ Tests.RegistryConsumer -- a synthetic, signed Protocol 1 registry.

  Consumer tests need records with dependencies, yanks, renewals, and
  deliberately broken documents, which the origin's publication surface does
  not produce. This fixture signs canonical documents with its own Ed25519
  key and serves any accepted checkpoint through loopback contacts, each of
  which can act as an origin or a mirror, fail at the request layer, or
  serve an older view. }
unit Tests.RegistryConsumer;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Generics.Collections,
  SysUtils,

  LWPT.Registry.Crypto,
  Tests.RegistryServer;

type
  TSyntheticCheckpoint = record
    Sequence: Integer;
    Checkpoint, Signature: TBytes;
  end;

  TSyntheticRegistry = class
  private
    FIdentity, FKeyID, FPublicKey, FHead: string;
    FSeed: TLWPTEd25519Seed;
    FSequence: Integer;
    FDocuments: TDictionary<string, TBytes>;
    FActive: TDictionary<string, string>;
    FRecords: TDictionary<string, string>;
    FCheckpoints: TList<TSyntheticCheckpoint>;
    FLock: TRTLCriticalSection;
    function SignCheckpoint(const ASequence: Integer; const ASnapshot,
      APublishedAt, AExpiresAt: string): TSyntheticCheckpoint;
  public
    { ASeedByte selects a deterministic key; two registries built with the
      same byte share one pin. }
    constructor Create(const AIdentity: string; const ASeedByte: Byte = 7);
    destructor Destroy; override;
    { ADependencies holds "name@constraint" or "origin|name@constraint". }
    procedure AddPackage(const AName, AVersion: string; const AArchive: TBytes;
      const ADependencies: array of string; const AYanked: Boolean = False);
    { Replaces the record of name@version with one of the given yank state. }
    procedure SetYanked(const AName, AVersion: string; const AYanked: Boolean);
    { Commits the staged records as the next snapshot and signs it. Returns
      the new checkpoint index. }
    function Publish(const APublishedAt, AExpiresAt: string): Integer;
    { Signs another checkpoint for the current sequence (a renewal). }
    function Renew(const APublishedAt, AExpiresAt: string): Integer;
    { Signs arbitrary checkpoint fields; used for equivocation. }
    function SignRaw(const ASequence: Integer; const ASnapshot, APublishedAt,
      AExpiresAt: string): Integer;
    function CheckpointCount: Integer;
    function Checkpoint(const AIndex: Integer): TSyntheticCheckpoint;
    function Document(const APath: string; out ABytes: TBytes): Boolean;
    function RecordHash(const AName, AVersion: string): string;
    function ArchiveHashOf(const AName, AVersion: string): string;
    property Identity: string read FIdentity;
    property KeyID: string read FKeyID;
    property PublicKey: string read FPublicKey;
    property Sequence: Integer read FSequence;
    property Head: string read FHead;
  end;

  TSyntheticContactMode = (scmServe, scmFail, scmRedirect);

  { One loopback contact for a synthetic registry. }
  TSyntheticContact = class
  private
    FRegistry: TSyntheticRegistry;
    FServer: TRegistryTestServer;
    FPath, FRole: string;
    FLock: TRTLCriticalSection;
    FOverrides: TDictionary<string, TBytes>;
    FMissing: TStringList;
    function Handle(const ATarget: string; out AMediaType: string;
      out ABody: TBytes): Integer;
  public
    Mode: TSyntheticContactMode;
    { Checkpoint index served as latest; -1 serves the newest. }
    CheckpointIndex: Integer;
    { Replaces the advertised discovery origin when not empty. }
    AdvertisedOrigin: string;
    { Replaces the advertised protocol number when not zero. }
    AdvertisedProtocol: Integer;
    constructor Create(ARegistry: TSyntheticRegistry; const APath: string;
      const ARole: string = 'origin');
    destructor Destroy; override;
    function BaseURL: string;
    { Serves ABody instead of the document at the v1-relative APath. }
    procedure Override(const APath: string; const ABody: TBytes);
    { Answers 404 for the v1-relative APath. }
    procedure Hide(const APath: string);
    function Requests: Integer;
    function RequestedCount(const AFragment: string): Integer;
    property Registry: TSyntheticRegistry read FRegistry write FRegistry;
  end;

{ RFC 3339 UTC, whole seconds, offset from now. }
function RegistryStamp(const AOffsetSeconds: Int64): string;
{ A package archive in the installer's layout: one top-level directory
  holding lwpt.toml and source/<unit>.pas. }
function RegistryPackageArchive(const AName, AVersion: string;
  const AManifestName: string = ''; const AManifestVersion: string = ''): TBytes;
function RegistrySHA256(const ABytes: TBytes): string;

implementation

uses
  DateUtils,

  LWPT.Core,
  Tests.TarSynth;

const
  DAY = 24 * 60 * 60;

function RegistrySHA256(const ABytes: TBytes): string;
begin
  Result := SHA256BytesPrefixed(ABytes);
end;

function RegistryStamp(const AOffsetSeconds: Int64): string;
var Stamp: TDateTime;
begin
  Stamp := IncSecond(LocalTimeToUniversal(Now), AOffsetSeconds);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', Stamp);
end;

function Hex(const AHash: string): string;
begin
  Result := Copy(AHash, 8, 64);
end;

function RegistryPackageArchive(const AName, AVersion, AManifestName,
  AManifestVersion: string): TBytes;
var Entries: TByteArrays; ManifestName, ManifestVersion, UnitName: string;
begin
  ManifestName := AManifestName;
  if ManifestName = '' then ManifestName := AName;
  ManifestVersion := AManifestVersion;
  if ManifestVersion = '' then ManifestVersion := AVersion;
  UnitName := StringReplace(AName, '-', '_', [rfReplaceAll]);
  SetLength(Entries, 2);
  Entries[0] := MakeRegularFileEntry(AName + '-' + AVersion + '/lwpt.toml',
    BytesOf('[package]'#10 + 'name = "' + ManifestName + '"'#10
      + 'version = "' + ManifestVersion + '"'#10 + 'units = ["source"]'#10));
  Entries[1] := MakeRegularFileEntry(AName + '-' + AVersion + '/source/'
    + UnitName + '.pas', BytesOf('unit ' + UnitName + ';'#10
    + '{ ' + AVersion + ' }'#10 + 'interface'#10 + 'implementation'#10
    + 'end.'#10));
  Result := Gzip(BuildTar(Entries));
end;

constructor TSyntheticRegistry.Create(const AIdentity: string;
  const ASeedByte: Byte);
var PublicKey: TLWPTEd25519PublicKey; Raw: TBytes;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FIdentity := AIdentity;
  FillChar(FSeed, SizeOf(FSeed), ASeedByte);
  Ed25519PublicKey(FSeed, PublicKey);
  SetLength(Raw, SizeOf(PublicKey));
  Move(PublicKey[0], Raw[0], SizeOf(PublicKey));
  FPublicKey := 'hex:' + BytesToHex(PublicKey, SizeOf(PublicKey));
  FKeyID := 'ed25519:' + SHA256Hex(Raw);
  FDocuments := TDictionary<string, TBytes>.Create;
  FActive := TDictionary<string, string>.Create;
  FRecords := TDictionary<string, string>.Create;
  FCheckpoints := TList<TSyntheticCheckpoint>.Create;
  FDocuments.AddOrSetValue('keys/' + FKeyID + '.toml', BytesOf(
    'schema = "lwpt-registry-key-v1"'#10
    + 'origin = "' + FIdentity + '"'#10
    + 'key_id = "' + FKeyID + '"'#10
    + 'algorithm = "ed25519"'#10
    + 'public_key = "' + FPublicKey + '"'#10
    + 'valid_from_sequence = 1'#10));
end;

destructor TSyntheticRegistry.Destroy;
begin
  FCheckpoints.Free;
  FRecords.Free;
  FActive.Free;
  FDocuments.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function RecordDocument(const AOrigin, AName, AVersion, AArchiveHash: string;
  const AArchiveSize: Integer; const APublishedAt: string;
  const AYanked: Boolean; const ADependencies: string): TBytes;
var Yanked: string;
begin
  if AYanked then Yanked := 'true' else Yanked := 'false';
  Result := BytesOf('schema = "lwpt-registry-package-v1"'#10
    + 'origin = "' + AOrigin + '"'#10
    + 'name = "' + AName + '"'#10
    + 'version = "' + AVersion + '"'#10
    + 'archive = "' + AArchiveHash + '"'#10
    + 'archive_size = ' + IntToStr(AArchiveSize) + #10
    + 'published_at = "' + APublishedAt + '"'#10
    + 'yanked = ' + Yanked + #10
    + 'dependencies = [' + ADependencies + ']'#10);
end;

procedure TSyntheticRegistry.AddPackage(const AName, AVersion: string;
  const AArchive: TBytes; const ADependencies: array of string;
  const AYanked: Boolean);
var
  Sorted: TStringList;
  Index, Bar, At: Integer;
  Origin, Rest, Line, Dependencies, Hash, ArchiveHash: string;
  Bytes: TBytes;
begin
  Sorted := TStringList.Create;
  try
    Sorted.CaseSensitive := True;
    for Index := 0 to High(ADependencies) do
    begin
      Bar := Pos('|', ADependencies[Index]);
      if Bar > 0 then
      begin
        Origin := Copy(ADependencies[Index], 1, Bar - 1);
        Rest := Copy(ADependencies[Index], Bar + 1, MaxInt);
      end
      else
      begin
        Origin := FIdentity;
        Rest := ADependencies[Index];
      end;
      At := Pos('@', Rest);
      Sorted.Add(Origin + #0 + Copy(Rest, 1, At - 1) + #0
        + Copy(Rest, At + 1, MaxInt));
    end;
    Sorted.Sort;
    Dependencies := '';
    for Index := 0 to Sorted.Count - 1 do
    begin
      Rest := Sorted[Index];
      Origin := Copy(Rest, 1, Pos(#0, Rest) - 1);
      Delete(Rest, 1, Pos(#0, Rest));
      Line := '{ ';
      if Origin <> FIdentity then Line := Line + 'origin = "' + Origin + '", ';
      Line := Line + 'name = "' + Copy(Rest, 1, Pos(#0, Rest) - 1)
        + '", version = "' + Copy(Rest, Pos(#0, Rest) + 1, MaxInt) + '" }';
      if Dependencies <> '' then Dependencies := Dependencies + ', ';
      Dependencies := Dependencies + Line;
    end;
  finally
    Sorted.Free;
  end;
  ArchiveHash := RegistrySHA256(AArchive);
  Bytes := RecordDocument(FIdentity, AName, AVersion, ArchiveHash,
    Length(AArchive), RegistryStamp(-60), AYanked, Dependencies);
  Hash := RegistrySHA256(Bytes);
  EnterCriticalSection(FLock);
  try
    FDocuments.AddOrSetValue('objects/sha256/' + Hex(ArchiveHash), AArchive);
    FDocuments.AddOrSetValue('records/sha256/' + Hex(Hash) + '.toml', Bytes);
    FActive.AddOrSetValue(AName + '@' + AVersion, Hash);
    FRecords.AddOrSetValue(Hash, Dependencies);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TSyntheticRegistry.SetYanked(const AName, AVersion: string;
  const AYanked: Boolean);
var
  OldHash, Dependencies, ArchiveHash, Text, Hash: string;
  Old, Archive, Bytes: TBytes;
  Start, Stop: Integer;
begin
  OldHash := FActive[AName + '@' + AVersion];
  Old := FDocuments['records/sha256/' + Hex(OldHash) + '.toml'];
  SetString(Text, PAnsiChar(@Old[0]), Length(Old));
  Start := Pos('archive = "', Text) + Length('archive = "');
  Stop := Pos('"', Copy(Text, Start, MaxInt));
  ArchiveHash := Copy(Text, Start, Stop - 1);
  Archive := FDocuments['objects/sha256/' + Hex(ArchiveHash)];
  Dependencies := FRecords[OldHash];
  Bytes := RecordDocument(FIdentity, AName, AVersion, ArchiveHash,
    Length(Archive), RegistryStamp(-30), AYanked, Dependencies);
  Hash := RegistrySHA256(Bytes);
  EnterCriticalSection(FLock);
  try
    FDocuments.AddOrSetValue('records/sha256/' + Hex(Hash) + '.toml', Bytes);
    FActive.AddOrSetValue(AName + '@' + AVersion, Hash);
    FRecords.AddOrSetValue(Hash, Dependencies);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticRegistry.SignCheckpoint(const ASequence: Integer;
  const ASnapshot, APublishedAt, AExpiresAt: string): TSyntheticCheckpoint;
var
  Payload, Message: TBytes;
  Signature: TLWPTEd25519Signature;
  Domain: TBytes;
begin
  Result.Sequence := ASequence;
  Result.Checkpoint := BytesOf('schema = "lwpt-registry-checkpoint-v1"'#10
    + 'origin = "' + FIdentity + '"'#10
    + 'sequence = ' + IntToStr(ASequence) + #10
    + 'snapshot = "' + ASnapshot + '"'#10
    + 'published_at = "' + APublishedAt + '"'#10
    + 'expires_at = "' + AExpiresAt + '"'#10
    + 'key_id = "' + FKeyID + '"'#10);
  Payload := Result.Checkpoint;
  Domain := BytesOf('LWPT-REGISTRY-CHECKPOINT-V1'#10);
  SetLength(Message, Length(Domain) + Length(Payload));
  Move(Domain[0], Message[0], Length(Domain));
  Move(Payload[0], Message[Length(Domain)], Length(Payload));
  Ed25519Sign(Message, FSeed, Signature);
  Result.Signature := BytesOf('schema = "lwpt-registry-signature-v1"'#10
    + 'algorithm = "ed25519"'#10
    + 'key_id = "' + FKeyID + '"'#10
    + 'payload = "' + RegistrySHA256(Payload) + '"'#10
    + 'signature = "hex:' + BytesToHex(Signature, SizeOf(Signature)) + '"'#10);
end;

function TSyntheticRegistry.Publish(const APublishedAt,
  AExpiresAt: string): Integer;
var
  Records: TStringList;
  Hash, Line: string;
  Snapshot: TBytes;
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Records := TStringList.Create;
    try
      Records.CaseSensitive := True;
      for Hash in FActive.Values do Records.Add(Hash);
      Records.Sort;
      Line := '';
      for Index := 0 to Records.Count - 1 do
      begin
        if Index > 0 then Line := Line + ', ';
        Line := Line + '"' + Records[Index] + '"';
      end;
    finally
      Records.Free;
    end;
    Inc(FSequence);
    Snapshot := BytesOf('schema = "lwpt-registry-snapshot-v1"'#10
      + 'origin = "' + FIdentity + '"'#10
      + 'sequence = ' + IntToStr(FSequence) + #10
      + 'published_at = "' + APublishedAt + '"'#10
      + 'previous = "' + FHead + '"'#10
      + 'records = [' + Line + ']'#10);
    FHead := RegistrySHA256(Snapshot);
    FDocuments.AddOrSetValue('snapshots/sha256/' + Hex(FHead) + '.toml', Snapshot);
    FCheckpoints.Add(SignCheckpoint(FSequence, FHead, APublishedAt, AExpiresAt));
    Result := FCheckpoints.Count - 1;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticRegistry.Renew(const APublishedAt, AExpiresAt: string): Integer;
begin
  Result := SignRaw(FSequence, FHead, APublishedAt, AExpiresAt);
end;

function TSyntheticRegistry.SignRaw(const ASequence: Integer; const ASnapshot,
  APublishedAt, AExpiresAt: string): Integer;
begin
  EnterCriticalSection(FLock);
  try
    FCheckpoints.Add(SignCheckpoint(ASequence, ASnapshot, APublishedAt, AExpiresAt));
    Result := FCheckpoints.Count - 1;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticRegistry.CheckpointCount: Integer;
begin
  Result := FCheckpoints.Count;
end;

function TSyntheticRegistry.Checkpoint(const AIndex: Integer): TSyntheticCheckpoint;
begin
  EnterCriticalSection(FLock);
  try
    if AIndex < 0 then Result := FCheckpoints[FCheckpoints.Count - 1]
    else Result := FCheckpoints[AIndex];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticRegistry.Document(const APath: string; out ABytes: TBytes): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDocuments.TryGetValue(APath, ABytes);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticRegistry.RecordHash(const AName, AVersion: string): string;
begin
  Result := FActive[AName + '@' + AVersion];
end;

function TSyntheticRegistry.ArchiveHashOf(const AName, AVersion: string): string;
var Bytes: TBytes; Text: string; Start: Integer;
begin
  Bytes := FDocuments['records/sha256/' + Hex(RecordHash(AName, AVersion)) + '.toml'];
  SetString(Text, PAnsiChar(@Bytes[0]), Length(Bytes));
  Start := Pos('archive = "', Text) + Length('archive = "');
  Result := Copy(Text, Start, 71);
end;

{ ---------------------------------------------------------------------------
  Contacts
  --------------------------------------------------------------------------- }

constructor TSyntheticContact.Create(ARegistry: TSyntheticRegistry;
  const APath, ARole: string);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FRegistry := ARegistry;
  FPath := APath;
  FRole := ARole;
  CheckpointIndex := -1;
  FOverrides := TDictionary<string, TBytes>.Create;
  FMissing := TStringList.Create;
  FServer := TRegistryTestServer.Create(nil, True);
  FServer.Handler := Handle;
  FServer.Start;
end;

destructor TSyntheticContact.Destroy;
begin
  FServer.Free;
  FMissing.Free;
  FOverrides.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TSyntheticContact.BaseURL: string;
begin
  Result := 'http://localhost:' + IntToStr(FServer.Port) + FPath;
end;

procedure TSyntheticContact.Override(const APath: string; const ABody: TBytes);
begin
  EnterCriticalSection(FLock);
  try
    FOverrides.AddOrSetValue(APath, ABody);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TSyntheticContact.Hide(const APath: string);
begin
  EnterCriticalSection(FLock);
  try
    FMissing.Add(APath);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TSyntheticContact.Requests: Integer;
begin
  Result := FServer.RequestCount;
end;

function TSyntheticContact.RequestedCount(const AFragment: string): Integer;
var Targets: TStringList; Target: string;
begin
  Result := 0;
  Targets := FServer.RequestedTargets;
  try
    for Target in Targets do
      if Pos(AFragment, Target) > 0 then Inc(Result);
  finally
    Targets.Free;
  end;
end;

function MediaFor(const APath: string): string;
begin
  if Pos('objects/', APath) = 1 then Exit('application/gzip');
  if Pos('snapshots/', APath) = 1 then Exit('application/vnd.lwpt.registry-snapshot+toml');
  if Pos('records/', APath) = 1 then Exit('application/vnd.lwpt.registry-package+toml');
  if Pos('keys/', APath) = 1 then Exit('application/vnd.lwpt.registry-key+toml');
  if APath = 'checkpoints/latest.sig.toml' then
    Exit('application/vnd.lwpt.registry-signature+toml');
  if APath = 'checkpoints/latest.toml' then
    Exit('application/vnd.lwpt.registry-checkpoint+toml');
  if APath = 'capabilities' then
    Exit('application/vnd.lwpt.registry-capabilities+toml');
  Result := 'text/plain';
end;

function TSyntheticContact.Handle(const ATarget: string; out AMediaType: string;
  out ABody: TBytes): Integer;
var
  Relative, Origin, Base: string;
  Current: TSyntheticCheckpoint;
  Protocol: Integer;
begin
  ABody := nil;
  AMediaType := 'text/plain';
  EnterCriticalSection(FLock);
  try
    if Mode = scmFail then Exit(503);
    if Mode = scmRedirect then Exit(302);
    Base := BaseURL;
    if ATarget = FPath + '/.well-known/lwpt-registry' then
    begin
      Origin := AdvertisedOrigin;
      if Origin = '' then Origin := FRegistry.Identity;
      Protocol := AdvertisedProtocol;
      if Protocol = 0 then Protocol := 1;
      AMediaType := 'application/vnd.lwpt.registry-discovery+toml';
      ABody := BytesOf('schema = "lwpt-registry-discovery-v1"'#10
        + 'protocol = ' + IntToStr(Protocol) + #10
        + 'origin = "' + Origin + '"'#10
        + 'base_url = "' + Base + '"'#10
        + 'role = "' + FRole + '"'#10
        + 'api = "' + Base + '/v1"'#10
        + 'capabilities = "' + Base + '/v1/capabilities"'#10
        + 'checkpoint = "' + Base + '/v1/checkpoints/latest.toml"'#10);
      Exit(200);
    end;
    if Copy(ATarget, 1, Length(FPath) + 4) <> FPath + '/v1/' then Exit(404);
    Relative := Copy(ATarget, Length(FPath) + 5, MaxInt);
    if FMissing.IndexOf(Relative) >= 0 then Exit(404);
    AMediaType := MediaFor(Relative);
    if FOverrides.TryGetValue(Relative, ABody) then Exit(200);
    if Relative = 'capabilities' then
    begin
      ABody := BytesOf('schema = "lwpt-registry-capabilities-v1"'#10
        + 'protocol = 1'#10
        + 'hashes = ["sha256"]'#10
        + 'signatures = ["ed25519"]'#10
        + 'schemas = ["lwpt-registry-capabilities-v1", "lwpt-registry-checkpoint-v1", '
        + '"lwpt-registry-discovery-v1", "lwpt-registry-error-v1", '
        + '"lwpt-registry-key-v1", "lwpt-registry-package-v1", '
        + '"lwpt-registry-signature-v1", "lwpt-registry-snapshot-v1"]'#10
        + 'features = ["snapshot-sync-v1"]'#10
        + 'auth_schemes = []'#10
        + 'max_page_size = 100'#10);
      Exit(200);
    end;
    if (Relative = 'checkpoints/latest.toml')
       or (Relative = 'checkpoints/latest.sig.toml') then
    begin
      if FRegistry.CheckpointCount = 0 then Exit(404);
      Current := FRegistry.Checkpoint(CheckpointIndex);
      if Relative = 'checkpoints/latest.toml' then ABody := Current.Checkpoint
      else ABody := Current.Signature;
      Exit(200);
    end;
    if FRegistry.Document(Relative, ABody) then Exit(200);
    Result := 404;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
