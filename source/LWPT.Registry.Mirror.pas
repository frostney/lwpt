{ LWPT.Registry.Mirror -- explicit pull synchronization and read-only serving. }
unit LWPT.Registry.Mirror;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Registry.Store,
  LWPT.Registry.Verification;

const
  RegistryMaximumMirrorArchiveBytes = Int64(256) * 1024 * 1024;

type
  {$IFDEF REGISTRY_TESTING}
  TRegistryMirrorTransferStats = record
    PeakReserved, CompletedReserved: Int64;
    MaximumWorkers: Integer;
    { Barriers for deterministic transfer tests, updated with Interlocked*. }
    CompletedWorkers, AdmissionsClosed: LongInt;
  end;
  PRegistryMirrorTransferStats = ^TRegistryMirrorTransferStats;
  {$ENDIF}

  TLWPTRegistryMirror = class(TLWPTRegistryStore)
  private
    FGeneration: TLWPTRegistryGeneration;
    FGenerationReference: IInterface;
    FGenerationState: TLWPTRegistryState;
    FSynchronizationDeadline: QWord;
    FStoreUsed, FAttemptWritten: Int64;
    FAttemptID, FAttemptStartedAt: string;
    FActivationExpiresAt, FActivationClockFloor: string;
    {$IFDEF REGISTRY_TESTING}
    FTransferStats: TRegistryMirrorTransferStats;
    FBeforeActivate: TSHA256Progress;
    FBeforeGenerationLock, FBeforeGenerationBuild: TSHA256Progress;
    FDeadlineProbe, FBeforeReplace, FAfterAdoption: TSHA256Progress;
    FSynchronizationMilliseconds: QWord;
    {$ENDIF}
    function Trust: TLWPTRegistryTrust;
    function Accepted(const AState: TLWPTRegistryState;
      const ACheckpoint: TBytes): TLWPTRegistryAcceptedState;
    function VerifyStateProof(const AState: TLWPTRegistryState;
      AProgress: TSHA256Progress = nil): TLWPTVerifiedRegistry;
    function BuildGeneration(const AKey: string; const AState: TLWPTRegistryState;
      const AVerified: TLWPTVerifiedRegistry): TLWPTRegistryGeneration;
    function RemainingSynchronizationMilliseconds: QWord;
    procedure CheckSynchronizationDeadline;
    procedure BeginAttempt;
    procedure SaveAttempt(const AOutcome, AError: string);
    procedure MarkAbandonedAttempt;
    procedure PrepareStorageBudget(AAccepted: TLWPTRegistryGeneration);
    procedure PruneUnaccepted(AAccepted: TLWPTRegistryGeneration);
    procedure Reserve(const ABytes: Int64);
    procedure ActivateBudgeted(const AState: TLWPTRegistryState);
    procedure CheckActivationGate;
    procedure WriteBudgeted(const ARelative: string; const ABytes: TBytes);
    procedure TransferArchives(const AAPI: string; const APackages: TLWPTRegistryPackageArray);
    {$IFDEF REGISTRY_TESTING}
    procedure RetainForTesting(const AVerified: TLWPTVerifiedRegistry;
      const AKeyDocuments: array of TBytes; const ALastSync: string);
    {$ENDIF}
  public
    destructor Destroy; override;
    procedure Recover; override;
    function LoadCurrentState(AProgress: TSHA256Progress = nil): TLWPTRegistryState; override;
    { Reuses one verified generation while the accepted state bytes are
      unchanged. At most one verification runs per store at a time. }
    function CaptureReadView(AProgress: TSHA256Progress = nil): TLWPTRegistryReadView; override;
    procedure Synchronize;
    function VerifyMirror: string;
  end;

procedure ValidateMirrorConfiguration(const AConfig: TLWPTRegistryConfig);
{$IFDEF REGISTRY_TESTING}
function RegistryMirrorProofChecksForTesting: Integer;
function RegistryMirrorCanAdmitForTesting(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
procedure RegistryMirrorTransferForTesting(AMirror: TLWPTRegistryMirror;
  const AAPI: string; const APackages: TLWPTRegistryPackageArray);
function RegistryMirrorTransferStatsForTesting(AMirror: TLWPTRegistryMirror): PRegistryMirrorTransferStats;
procedure RegistryMirrorBeforeActivateForTesting(AMirror: TLWPTRegistryMirror;
  ACallback: TSHA256Progress);
procedure RegistryMirrorSynchronizationBudgetForTesting(AMirror: TLWPTRegistryMirror;
  const AMilliseconds: QWord);
{ Runs before a request takes the generation lock, and inside the lock before
  a generation is verified, so tests can order concurrent readers. }
procedure RegistryMirrorGenerationHooksForTesting(AMirror: TLWPTRegistryMirror;
  ABeforeLock, ABeforeBuild: TSHA256Progress);
{ ADeadlineProbe runs inside every synchronization deadline check;
  ABeforeReplace runs after the new pointer is staged, before its gate. }
procedure RegistryMirrorActivationHooksForTesting(AMirror: TLWPTRegistryMirror;
  ADeadlineProbe, ABeforeReplace: TSHA256Progress);
{ Runs after each verified archive is adopted into the object store. }
procedure RegistryMirrorAdoptionHookForTesting(AMirror: TLWPTRegistryMirror;
  AAfterAdoption: TSHA256Progress);
{ Lowers max_store_bytes to the bytes already accounted plus AHeadroom. }
procedure RegistryMirrorStoreHeadroomForTesting(AMirror: TLWPTRegistryMirror;
  const AHeadroom: Int64);
function RegistryMirrorConnectAddressForTesting(const AURL: string): string;
{ Persists a verified proof in the synchronized layout for fixtures. Key
  documents are the root record followed by one record per rotation. }
procedure RegistryMirrorRetainForTesting(AMirror: TLWPTRegistryMirror;
  const AVerified: TLWPTVerifiedRegistry; const AKeyDocuments: array of TBytes;
  const ALastSync: string);
{$ENDIF}

implementation

uses
  Generics.Collections,
  StrUtils,

  HTTPClient,
  LWPT.ProducerLease,
  LWPT.Registry.Client,
  LWPT.Registry.Filesystem,
  TOML;

const
  MirrorRequestTimeoutMilliseconds = RegistryRequestTimeoutMilliseconds;
  { Bounds one complete synchronization, including every metadata request and
    archive transfer. Each request uses the smaller remaining budget. }
  MirrorSynchronizationMilliseconds = 60 * 60 * 1000;
  MirrorAttemptPath = 'state/sync-attempt.toml';
  MaximumMirrorArchiveWorkers = 2;
  MirrorProofPrefix = 'proofs/sha256/';
  { Upper bound of one persisted attempt record, including a truncated error. }
  MirrorAttemptRecordBytes = 2048;
  MirrorAttemptErrorCharacters = 1024;

{$IFDEF REGISTRY_TESTING}
var
  MirrorProofChecks: LongInt;

function RegistryMirrorProofChecksForTesting: Integer;
begin
  Result := InterlockedCompareExchange(MirrorProofChecks, 0, 0);
end;

procedure RegistryMirrorBeforeActivateForTesting(AMirror: TLWPTRegistryMirror;
  ACallback: TSHA256Progress);
begin
  AMirror.FBeforeActivate := ACallback;
end;

procedure RegistryMirrorSynchronizationBudgetForTesting(AMirror: TLWPTRegistryMirror;
  const AMilliseconds: QWord);
begin
  AMirror.FSynchronizationMilliseconds := AMilliseconds;
end;

procedure RegistryMirrorActivationHooksForTesting(AMirror: TLWPTRegistryMirror;
  ADeadlineProbe, ABeforeReplace: TSHA256Progress);
begin
  AMirror.FDeadlineProbe := ADeadlineProbe;
  AMirror.FBeforeReplace := ABeforeReplace;
end;

procedure RegistryMirrorAdoptionHookForTesting(AMirror: TLWPTRegistryMirror;
  AAfterAdoption: TSHA256Progress);
begin
  AMirror.FAfterAdoption := AAfterAdoption;
end;

procedure RegistryMirrorStoreHeadroomForTesting(AMirror: TLWPTRegistryMirror;
  const AHeadroom: Int64);
begin
  AMirror.OverrideStoreBudgetForTesting(AMirror.FStoreUsed + AHeadroom);
end;

procedure RegistryMirrorGenerationHooksForTesting(AMirror: TLWPTRegistryMirror;
  ABeforeLock, ABeforeBuild: TSHA256Progress);
begin
  AMirror.FBeforeGenerationLock := ABeforeLock;
  AMirror.FBeforeGenerationBuild := ABeforeBuild;
end;
{$ENDIF}

type
  TLWPTMirrorArchiveWorker = class(TThread)
  private
    FURL: string;
    FPackage: TLWPTRegistryPackage;
    FTimeoutMilliseconds: QWord;
    FProgress: TSHA256Progress;
    {$IFDEF REGISTRY_TESTING}
    FStats: PRegistryMirrorTransferStats;
    {$ENDIF}
  protected
    procedure Execute; override;
  public
    Archive: TBytes;
    Error: string;
    constructor Create(const AAPI: string; const APackage: TLWPTRegistryPackage;
      const ATimeoutMilliseconds: QWord);
  end;

  TLWPTMirrorDocumentSource = class(TLWPTRegistryDocumentSource)
  public
    Store: TLWPTRegistryMirror;
    API: string;
    Progress: TSHA256Progress;
    function ReadDocument(const APath: string;
      const AMaximumBytes: Int64): TBytes; override;
    procedure CheckProgress; override;
  end;

function ProofPath(const AHash: string): string;
begin
  Result := MirrorProofPrefix + RegistryDigestHex(AHash) + '.toml';
end;

function ObjectPath(const AHash: string): string;
begin
  Result := 'objects/sha256/' + RegistryDigestHex(AHash);
end;

function DigestFromPath(const APath, APrefix, ASuffix: string): string;
begin
  Result := 'sha256:' + Copy(APath, Length(APrefix) + 1,
    Length(APath) - Length(APrefix) - Length(ASuffix));
end;

{$IFDEF REGISTRY_TESTING}
function RegistryMirrorConnectAddressForTesting(const AURL: string): string;
begin
  Result := RegistryConnectAddress(AURL);
end;
{$ENDIF}

{ The mirror has no destination policy beyond its configured upstream and
  bounds every request by the remaining synchronization budget. }
function GetDocument(const AURL, AMediaType: string;
  const AMaximumBytes: Int64; const ATimeoutMilliseconds: QWord): TBytes;
begin
  RequireRegistryRequestURI(AURL);
  if ATimeoutMilliseconds = 0 then
    raise ELWPTRegistryError.CreateStable('mirror_sync_deadline_exceeded',
      'synchronization exceeded its total time budget');
  Result := GetRegistryDocument(AURL, AMediaType, AMaximumBytes,
    ATimeoutMilliseconds, Default(THTTPDestinationPolicy));
end;

constructor TLWPTMirrorArchiveWorker.Create(const AAPI: string;
  const APackage: TLWPTRegistryPackage; const ATimeoutMilliseconds: QWord);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPackage := APackage;
  FTimeoutMilliseconds := ATimeoutMilliseconds;
  FURL := AAPI + '/objects/sha256/' + Copy(APackage.ArchiveHash, 8, 64);
end;

procedure TLWPTMirrorArchiveWorker.Execute;
var
  Stream: TBytesStream;
begin
  try
    try
      Archive := GetDocument(FURL, 'application/gzip', FPackage.ArchiveSize,
        FTimeoutMilliseconds);
      Stream := TBytesStream.Create(Archive);
      try
        VerifyRegistryArtifact(FPackage, Stream, FProgress);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        Error := E.Message;
        Archive := nil;
      end;
    end;
  finally
    {$IFDEF REGISTRY_TESTING}
    if Assigned(FStats) then InterlockedIncrement(FStats^.CompletedWorkers);
    {$ENDIF}
  end;
end;

function MirrorCanAdmit(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
begin
  { Subtraction after range checks avoids overflow even for hostile sizes.
    A reservation includes completed buffers until their owner is freed. }
  if (AWorkers < 0) or (AWorkers >= MaximumMirrorArchiveWorkers)
    or (AReserved < 0) or (AReserved > RegistryMaximumMirrorArchiveBytes)
    or (ASize < 0) then Exit(False);
  Result := ASize <= RegistryMaximumMirrorArchiveBytes - AReserved;
end;

{$IFDEF REGISTRY_TESTING}
function RegistryMirrorCanAdmitForTesting(const AReserved, ASize: Int64;
  const AWorkers: Integer): Boolean;
begin
  Result := MirrorCanAdmit(AReserved, ASize, AWorkers);
end;

procedure RegistryMirrorTransferForTesting(AMirror: TLWPTRegistryMirror;
  const AAPI: string; const APackages: TLWPTRegistryPackageArray);
begin
  AMirror.TransferArchives(AAPI, APackages);
end;

function RegistryMirrorTransferStatsForTesting(AMirror: TLWPTRegistryMirror): PRegistryMirrorTransferStats;
begin
  Result := @AMirror.FTransferStats;
end;
{$ENDIF}

destructor TLWPTRegistryMirror.Destroy;
begin
  FGenerationReference := nil;
  inherited Destroy;
end;

function TLWPTRegistryMirror.RemainingSynchronizationMilliseconds: QWord;
var
  Now: QWord;
begin
  if FSynchronizationDeadline = 0 then Exit(MirrorRequestTimeoutMilliseconds);
  Now := GetTickCount64;
  if Now >= FSynchronizationDeadline then Exit(0);
  Result := FSynchronizationDeadline - Now;
  if Result > MirrorRequestTimeoutMilliseconds then Result := MirrorRequestTimeoutMilliseconds;
end;

procedure TLWPTRegistryMirror.CheckSynchronizationDeadline;
begin
  {$IFDEF REGISTRY_TESTING}
  if Assigned(FDeadlineProbe) then FDeadlineProbe;
  {$ENDIF}
  if (FSynchronizationDeadline > 0) and (GetTickCount64 >= FSynchronizationDeadline) then
    raise ELWPTRegistryError.CreateStable('mirror_sync_deadline_exceeded',
      'synchronization exceeded its total time budget');
end;

procedure TLWPTRegistryMirror.Reserve(const ABytes: Int64);
begin
  if (ABytes < 0) or (ABytes > Config.SyncBudgetBytes - FAttemptWritten) then
    raise ELWPTRegistryError.CreateStable('mirror_sync_budget_exceeded',
      'synchronization would write more than max_sync_bytes');
  if ABytes > Config.StoreBudgetBytes - FStoreUsed then
    raise ELWPTRegistryError.CreateStable('mirror_store_budget_exceeded',
      'synchronization would grow the data directory beyond max_store_bytes');
  Inc(FAttemptWritten, ABytes);
  Inc(FStoreUsed, ABytes);
end;

{ The replacement is staged beside the old pointer before the rename, so the
  complete new document is reserved. Deadline and expiry are rechecked after
  staging, immediately before the atomic replacement. }
procedure TLWPTRegistryMirror.ActivateBudgeted(const AState: TLWPTRegistryState);
begin
  Reserve(Length(StateDocumentBytes(AState)));
  CheckSynchronizationDeadline;
  ActivateStateGated(AState, CheckActivationGate);
end;

procedure TLWPTRegistryMirror.CheckActivationGate;
var
  Now: string;
begin
  {$IFDEF REGISTRY_TESTING}
  if Assigned(FBeforeReplace) then FBeforeReplace;
  {$ENDIF}
  CheckSynchronizationDeadline;
  Now := RegistryTimestampNow;
  RequireRegistryClockAtFloor(Now, FActivationClockFloor);
  if FActivationExpiresAt <= Now then
    raise ELWPTRegistryStaleContactError.CreateStable('checkpoint_expired',
      'checkpoint expired before activation');
end;

procedure TLWPTRegistryMirror.WriteBudgeted(const ARelative: string;
  const ABytes: TBytes);
begin
  { Existing content-addressed bytes are compared, not charged again. }
  if not FileExists(RootPath(ARelative)) then Reserve(Length(ABytes));
  WriteImmutable(ARelative, ABytes);
end;

{ Empties ADirectory entry by entry, reporting progress for each one. Links
  are removed, never followed. }
procedure ClearDirectory(const ADirectory: string; const AProgress: TSHA256Progress);
var
  Search: TSearchRec;
  Path: string;
begin
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if Assigned(AProgress) then AProgress;
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Path := IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
      if ((Search.Attr and faDirectory) <> 0) and ((Search.Attr and faSymLink) = 0) then
      begin
        ClearDirectory(Path, AProgress);
        RemoveDir(Path);
      end
      else DeleteFile(Path);
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

function DirectoryBytes(const ADirectory: string; const AProgress: TSHA256Progress): Int64;
var
  Search: TSearchRec;
begin
  Result := 0;
  if SysUtils.FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if Assigned(AProgress) then AProgress;
      if (Search.Name = '.') or (Search.Name = '..')
        or ((Search.Attr and faSymLink) <> 0) then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        Inc(Result, DirectoryBytes(IncludeTrailingPathDelimiter(ADirectory) + Search.Name,
          AProgress))
      else Inc(Result, Search.Size);
    until SysUtils.FindNext(Search) <> 0;
  finally
    SysUtils.FindClose(Search);
  end;
end;

procedure TLWPTRegistryMirror.PruneUnaccepted(AAccepted: TLWPTRegistryGeneration);
const
  { Accepted archives, records, and snapshots only grow along one history,
    so every earlier generation's bulk content remains in the current one.
    Signed control documents are never pruned: a request that captured an
    earlier generation may still open its checkpoint, signature, or keys. }
  ContentDirectories: array[0..2] of string = ('objects/sha256', 'records/sha256',
    'snapshots/sha256');
var
  Relative: string;
  Search: TSearchRec;
  Retained: TStringList;
begin
  Retained := TStringList.Create;
  try
    Retained.Sorted := True;
    Retained.Duplicates := dupIgnore;
    if AAccepted <> nil then AAccepted.AppendStoredPaths(Retained);
    for Relative in ContentDirectories do
    begin
      if SysUtils.FindFirst(RootPath(Relative + '/*'), faAnyFile or faSymLink, Search) <> 0 then
        Continue;
      try
        repeat
          CheckSynchronizationDeadline;
          if (Search.Attr and faDirectory) <> 0 then Continue;
          if Retained.IndexOf(Relative + '/' + Search.Name) >= 0 then Continue;
          { A concurrent reader of an older generation may hold the file open;
            retention is then retried by the next attempt. }
          DeleteFile(RootPath(Relative + '/' + Search.Name));
        until SysUtils.FindNext(Search) <> 0;
      finally
        SysUtils.FindClose(Search);
      end;
    end;
  finally
    Retained.Free;
  end;
end;

procedure TLWPTRegistryMirror.PrepareStorageBudget(AAccepted: TLWPTRegistryGeneration);
begin
  ClearDirectory(TmpRoot, CheckSynchronizationDeadline);
  ForceDirectories(TmpRoot);
  FAttemptWritten := 0;
  FStoreUsed := DirectoryBytes(Root, CheckSynchronizationDeadline);
  { Unaccepted candidates stay available for retry only while a complete
    attempt still fits. Otherwise they are removed before reservation. }
  if FStoreUsed > Config.StoreBudgetBytes - Config.SyncBudgetBytes then
  begin
    PruneUnaccepted(AAccepted);
    FStoreUsed := DirectoryBytes(Root, CheckSynchronizationDeadline);
  end;
  { Later attempt records replace the current one through a staged copy. }
  Reserve(2 * MirrorAttemptRecordBytes);
end;

procedure TLWPTRegistryMirror.TransferArchives(const AAPI: string;
  const APackages: TLWPTRegistryPackageArray);
var
  Sizes: TDictionary<string, Int64>;
  Missing: TLWPTRegistryPackageArray;
  Package: TLWPTRegistryPackage;
  Workers: array[0..MaximumMirrorArchiveWorkers - 1] of TLWPTMirrorArchiveWorker;
  Reserved, PreviousSize, Planned: Int64;
  Count, Next, Admitted, I: Integer;
  Path, Failure: string;
  Stream: TStream;
begin
  {$IFDEF REGISTRY_TESTING}
  FTransferStats := Default(TRegistryMirrorTransferStats);
  {$ENDIF}
  Sizes := TDictionary<string, Int64>.Create;
  try
    { Validate the complete authenticated plan before any archive request.
      The same bytes may serve several records, but their size cannot differ. }
    for Package in APackages do
    begin
      if (Package.ArchiveSize < 0) or (Package.ArchiveSize > RegistryMaximumMirrorArchiveBytes) then
        raise ELWPTRegistryError.CreateStable('mirror_archive_limit_exceeded',
          'archive exceeds the bounded whole-body transfer limit');
      if Sizes.TryGetValue(Package.ArchiveHash, PreviousSize) then
      begin
        if PreviousSize <> Package.ArchiveSize then
          raise ELWPTRegistryError.CreateStable('registry_archive_size_conflict',
            'authenticated records disagree on one archive size');
      end
      else Sizes.Add(Package.ArchiveHash, Package.ArchiveSize);
    end;
    SetLength(Missing, Sizes.Count);
    Count := 0;
    Planned := 0;
    for Package in APackages do
      if Sizes.ContainsKey(Package.ArchiveHash) then
      begin
        Sizes.Remove(Package.ArchiveHash);
        Path := RootPath(ObjectPath(Package.ArchiveHash));
        if FileExists(Path) then
        begin
          CheckSynchronizationDeadline;
          Stream := OpenRegistryFileWithoutFollowingLinks(Path);
          try
            VerifyRegistryArtifact(Package, Stream, CheckSynchronizationDeadline);
          finally
            Stream.Free;
          end;
        end
        else
        begin
          Missing[Count] := Package;
          Inc(Count);
          Inc(Planned, Package.ArchiveSize);
        end;
      end;
  finally
    Sizes.Free;
  end;
  { Reserve the complete authenticated plan before the first transfer. }
  Reserve(Planned);
  Next := 0;
  while Next < Count do
  begin
    Reserved := 0;
    Admitted := 0;
    Failure := '';
    for I := Low(Workers) to High(Workers) do Workers[I] := nil;
    try
      { Bounded pairs deliberately drain before admitting another pair. This
        also keeps finished sibling buffers charged during slow transfers. }
      while (Next < Count) and MirrorCanAdmit(Reserved,
        Missing[Next].ArchiveSize, Admitted) do
      begin
        Workers[Admitted] := TLWPTMirrorArchiveWorker.Create(AAPI, Missing[Next],
          RemainingSynchronizationMilliseconds);
        Workers[Admitted].FProgress := CheckSynchronizationDeadline;
        {$IFDEF REGISTRY_TESTING}
        Workers[Admitted].FStats := @FTransferStats;
        {$ENDIF}
        Inc(Reserved, Missing[Next].ArchiveSize);
        Inc(Admitted);
        Inc(Next);
        Workers[Admitted - 1].Start;
      end;
      {$IFDEF REGISTRY_TESTING}
      if Reserved > FTransferStats.PeakReserved then FTransferStats.PeakReserved := Reserved;
      if Admitted > FTransferStats.MaximumWorkers then FTransferStats.MaximumWorkers := Admitted;
      InterlockedIncrement(FTransferStats.AdmissionsClosed);
      {$ENDIF}
      for I := 0 to Admitted - 1 do Workers[I].WaitFor;
      {$IFDEF REGISTRY_TESTING}
      if Reserved > FTransferStats.CompletedReserved then FTransferStats.CompletedReserved := Reserved;
      {$ENDIF}
      { Join every active request even after failure. Successful siblings are
        immutable retry material, never permission to activate a partial head. }
      { Adopt each verified buffer only while the synchronization budget
        holds; once it expires, no later sibling is adopted. A failed sibling
        does not prevent adopting the others as retry material. }
      for I := 0 to Admitted - 1 do
      begin
        try
          CheckSynchronizationDeadline;
        except
          on E: Exception do
          begin
            Failure := E.Message;
            Break;
          end;
        end;
        if Assigned(Workers[I].FatalException) then
        begin
          if Failure = '' then Failure := 'registry_archive_worker_failed: '
            + Workers[I].FatalException.ClassName;
        end
        else if Workers[I].Error <> '' then
        begin
          if Failure = '' then Failure := Workers[I].Error;
        end
        else
          try
            WriteImmutable(ObjectPath(Workers[I].FPackage.ArchiveHash), Workers[I].Archive);
            {$IFDEF REGISTRY_TESTING}
            if Assigned(FAfterAdoption) then FAfterAdoption;
            {$ENDIF}
          except
            on E: Exception do if Failure = '' then Failure := E.Message;
          end;
      end;
    finally
      for I := 0 to Admitted - 1 do
      begin
        PreviousSize := Workers[I].FPackage.ArchiveSize;
        Workers[I].Free;
        Dec(Reserved, PreviousSize);
      end;
    end;
    if Failure <> '' then raise ELWPTRegistryError.Create(Failure);
    CheckSynchronizationDeadline;
  end;
end;

procedure ValidateMirrorConfiguration(const AConfig: TLWPTRegistryConfig);
begin
  ValidateRegistryConfiguration(AConfig);
  if (AConfig.Role <> rrMirror)
    or not RegistryURIIsCanonical(AConfig.Identity, True)
    or not RegistryURIIsCanonical(AConfig.UpstreamURL, True)
    or not RegistryTrustRootIsValid(AConfig.TrustKeyID, AConfig.TrustPublicKey) then
    raise ELWPTRegistryError.CreateStable('invalid_mirror_configuration',
      'mirror role, canonical origin and upstream, and an explicit valid root pin are required');
  { HTTPClient connects over IPv4 only. Reject a bracketed IPv6 upstream at
    configuration time instead of accepting an endpoint sync cannot reach. }
  if Pos('://[', AConfig.UpstreamURL) > 0 then
    raise ELWPTRegistryError.CreateStable('invalid_mirror_configuration',
      'IPv6 upstream addresses are not supported; use a DNS name or IPv4 address');
end;

function TLWPTRegistryMirror.Trust: TLWPTRegistryTrust;
begin
  Result.Origin := Config.Identity;
  Result.KeyId := Config.TrustKeyID;
  Result.PublicKey := Config.TrustPublicKey;
end;

function TLWPTRegistryMirror.Accepted(const AState: TLWPTRegistryState;
  const ACheckpoint: TBytes): TLWPTRegistryAcceptedState;
var
  Checkpoint: TLWPTUntrustedRegistryCheckpoint;
begin
  if (AState.Sequence > High(Int64)) or not RegistryHashIsCanonical(AState.CheckpointHash) then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid accepted mirror state');
  { Locked-proof verification binds these times to the recorded hash. }
  Checkpoint := InspectRegistryCheckpoint(ACheckpoint);
  Result.Origin := Config.Identity;
  Result.Sequence := AState.Sequence;
  Result.Snapshot := AState.SnapshotHash;
  Result.CheckpointHash := AState.CheckpointHash;
  Result.KeyId := AState.TrustKeyID;
  Result.PublicKey := AState.TrustPublicKey;
  Result.PublishedAt := Checkpoint.PublishedAt;
  Result.ExpiresAt := Checkpoint.ExpiresAt;
  Result.ClockFloor := AState.ClockFloor;
end;

function TLWPTMirrorDocumentSource.ReadDocument(const APath: string;
  const AMaximumBytes: Int64): TBytes;
var
  Digest, MediaType: string;
begin
  if Assigned(Progress) then Progress;
  if StartsStr('snapshots/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('snapshots/sha256/') + 1, 64);
    MediaType := 'snapshot';
  end
  else if StartsStr('records/sha256/', APath) then
  begin
    Digest := Copy(APath, Length('records/sha256/') + 1, 64);
    MediaType := 'package';
  end
  else raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'unexpected proof resource');
  if not RegistryHashIsCanonical('sha256:' + Digest) or not EndsStr(Digest + '.toml', APath) then
    raise ELWPTRegistryError.CreateStable('invalid_resource_path', 'invalid proof resource hash');
  if (API = '') or FileExists(IncludeTrailingPathDelimiter(Store.Root) + APath) then
    Result := Store.LoadResource(APath, Progress, AMaximumBytes)
  else
    Result := GetDocument(API + '/' + APath, 'application/vnd.' + PROGRAM_NAME
      + '.registry-' + MediaType + '+toml', AMaximumBytes,
      Store.RemainingSynchronizationMilliseconds);
  if SHA256BytesPrefixed(Result) <> 'sha256:' + Digest then
    raise ELWPTRegistryError.CreateStable('resource_hash_mismatch', 'proof resource hash does not match');
  if API <> '' then Store.WriteBudgeted(APath, Result);
end;

procedure TLWPTMirrorDocumentSource.CheckProgress;
begin
  if Assigned(Progress) then Progress;
end;

function TLWPTRegistryMirror.VerifyStateProof(const AState: TLWPTRegistryState;
  AProgress: TSHA256Progress): TLWPTVerifiedRegistry;
var
  Source: TLWPTMirrorDocumentSource;
  Proof: TLWPTRegistryProof;
  Prefix: string;
  Budget: TLWPTRegistryMetadataBudget;
  Index: Integer;
  Rotation: TLWPTUntrustedRegistryRotation;
  KeyTrust: TLWPTRegistryTrust;
  Binding: TLWPTRegistryRotationBinding;

  function ReadBounded(const APath: string): TBytes;
  var
    Allowance: Int64;
  begin
    Allowance := Budget.Allowance;
    if Allowance > MAX_REGISTRY_CONTROL_DOCUMENT_BYTES then Allowance := MAX_REGISTRY_CONTROL_DOCUMENT_BYTES;
    Result := LoadResource(APath, AProgress, Allowance);
    Budget.Account(Result);
  end;

  { Proof documents are addressed by the hash the accepted state binds, so
    files left by unaccepted attempts can never join the chain. }
  function ReadProof(const AHash: string; const AAuxiliary: Boolean): TBytes;
  begin
    Result := ReadBounded(ProofPath(AHash));
    if SHA256BytesPrefixed(Result) <> AHash then
      raise ELWPTRegistryError.CreateStable('resource_hash_mismatch',
        'retained proof document does not match its accepted hash');
    if AAuxiliary then RememberRegistryRetrieval(Proof, Result);
  end;
begin
  Prefix := 'checkpoints/renewals/sha256/' + Copy(AState.CheckpointHash, 8, 64);
  {$IFDEF REGISTRY_TESTING}
  InterlockedIncrement(MirrorProofChecks);
  {$ENDIF}
  if (AState.Role <> rrMirror) or not RegistryHashIsCanonical(AState.CheckpointHash)
    or (AState.CheckpointPath <> Prefix + '.toml')
    or (AState.SignaturePath <> Prefix + '.sig.toml') then
    raise ELWPTRegistryError.CreateStable('state_corrupt', 'invalid mirror proof paths');
  Proof := Default(TLWPTRegistryProof);
  Source := TLWPTMirrorDocumentSource.Create;
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  try
    Proof.Checkpoint := ReadBounded(AState.CheckpointPath);
    Proof.Signature := ReadBounded(AState.SignaturePath);
    ValidateRegistryKeyDocument(ReadProof(AState.TrustKeyDocument, True), Trust,
      AState.Sequence);
    SetLength(Proof.Rotations, Length(AState.Rotations));
    for Index := 0 to High(AState.Rotations) do
    begin
      Binding := AState.Rotations[Index];
      Proof.Rotations[Index].Document := ReadProof(Binding.Document, False);
      Proof.Rotations[Index].OldSignature := ReadProof(Binding.OldSignature, False);
      Proof.Rotations[Index].NewSignature := ReadProof(Binding.NewSignature, False);
      Rotation := InspectRegistryRotation(Proof.Rotations[Index].Document);
      if Rotation.EffectiveSequence <> Binding.Sequence then
        raise ELWPTRegistryError.CreateStable('state_corrupt',
          'rotation binding sequence differs from its document');
      KeyTrust.Origin := Config.Identity;
      KeyTrust.KeyId := Rotation.ToKey;
      KeyTrust.PublicKey := Rotation.ToPublicKey;
      ValidateRegistryKeyDocument(ReadProof(Binding.KeyDocument, True), KeyTrust,
        Rotation.EffectiveSequence, True);
    end;
    Source.Store := Self;
    Source.Progress := AProgress;
    Result := VerifyRegistryProof(Proof, Trust, Accepted(AState, Proof.Checkpoint),
      RegistryTimestampNow, rvmLockedProof, Source, DefaultRegistryVerificationLimits);
  finally
    Budget.Free;
    Source.Free;
  end;
end;

function TLWPTRegistryMirror.BuildGeneration(const AKey: string;
  const AState: TLWPTRegistryState;
  const AVerified: TLWPTVerifiedRegistry): TLWPTRegistryGeneration;
var
  Document: TLWPTRegistryDocument;
  Package: TLWPTRegistryPackage;
  Binding: TLWPTRegistryRotationBinding;
  Rotation: TLWPTUntrustedRegistryRotation;
  Index: Integer;
  Prefix: string;
begin
  Result := TLWPTRegistryGeneration.Create(AKey);
  try
    Result.Add(AState.CheckpointPath, AState.CheckpointPath, AState.CheckpointHash);
    Result.Add(AState.SignaturePath, AState.SignaturePath,
      SHA256BytesPrefixed(AVerified.Proof.Signature));
    Result.Add(RegistryKeyStoragePath(Config.TrustKeyID),
      ProofPath(AState.TrustKeyDocument), AState.TrustKeyDocument);
    for Index := 0 to High(AState.Rotations) do
    begin
      Binding := AState.Rotations[Index];
      Rotation := InspectRegistryRotation(AVerified.Proof.Rotations[Index].Document);
      Result.Add(RegistryRotationPath(Binding.Sequence, RegistryRotationDocumentSuffix),
        ProofPath(Binding.Document), Binding.Document);
      Result.Add(RegistryRotationPath(Binding.Sequence, RegistryRotationOldSignatureSuffix),
        ProofPath(Binding.OldSignature), Binding.OldSignature);
      Result.Add(RegistryRotationPath(Binding.Sequence, RegistryRotationNewSignatureSuffix),
        ProofPath(Binding.NewSignature), Binding.NewSignature);
      Result.Add(RegistryKeyStoragePath(Rotation.ToKey), ProofPath(Binding.KeyDocument),
        Binding.KeyDocument);
      Result.AddRotation(Binding.Sequence);
    end;
    for Document in AVerified.Documents do
      if StartsStr('snapshots/sha256/', Document.Path) then
        Result.Add(Document.Path, Document.Path,
          DigestFromPath(Document.Path, 'snapshots/sha256/', '.toml'))
      else if StartsStr('records/sha256/', Document.Path) then
        Result.Add(Document.Path, Document.Path,
          DigestFromPath(Document.Path, 'records/sha256/', '.toml'));
    { Identities cannot leave history, so the head's archives are the complete
      accepted object set. }
    for Package in AVerified.Packages do
      Result.Add(ObjectPath(Package.ArchiveHash), ObjectPath(Package.ArchiveHash),
        Package.ArchiveHash);
  except
    Result.Free;
    raise;
  end;
end;

procedure TLWPTRegistryMirror.Recover;
begin
  ValidateMirrorConfiguration(Config);
  { Verified immutable resources survive interrupted synchronization. There is
    no origin seed, derived publication index, or temporary-directory sweep. }
  if FileExists(RootPath('state/current.toml')) then LoadCurrentState;
  MarkAbandonedAttempt;
end;

function TLWPTRegistryMirror.LoadCurrentState(AProgress: TSHA256Progress): TLWPTRegistryState;
begin
  Result := ReadCurrentState(AProgress);
  VerifyStateProof(Result, AProgress);
end;

function TLWPTRegistryMirror.CaptureReadView(AProgress: TSHA256Progress): TLWPTRegistryReadView;
var
  StateBytes: TBytes;
  Key: string;
  State: TLWPTRegistryState;
  Generation: TLWPTRegistryGeneration;
  Reference: IInterface;
begin
  {$IFDEF REGISTRY_TESTING}
  if Assigned(FBeforeGenerationLock) then FBeforeGenerationLock;
  {$ENDIF}
  EnterGeneration(AProgress);
  try
    { Read the pointer under the lock, so a delayed reader can never replace
      a newer cached generation with the one it observed earlier. }
    StateBytes := ReadCurrentStateBytes(AProgress);
    Key := SHA256BytesPrefixed(StateBytes);
    if (FGeneration = nil) or (FGeneration.Key <> Key) then
    begin
      {$IFDEF REGISTRY_TESTING}
      if Assigned(FBeforeGenerationBuild) then FBeforeGenerationBuild;
      {$ENDIF}
      State := StateFromBytes(StateBytes);
      Generation := BuildGeneration(Key, State, VerifyStateProof(State, AProgress));
      Reference := Generation;
      FGeneration := Generation;
      FGenerationReference := Reference;
      FGenerationState := State;
    end;
    Result := TLWPTRegistryReadView.Create(Self, FGenerationState, FGeneration);
  finally
    LeaveGeneration;
  end;
end;

function NewAttemptID: string;
begin
  Result := Copy(SHA256Hex(BytesOf(RegistryTimestampNow + ':'
    + IntToStr(GetProcessID) + ':' + IntToStr(GetTickCount64) + ':'
    + IntToStr(Random(MaxInt)))), 1, 26);
end;

procedure TLWPTRegistryMirror.SaveAttempt(const AOutcome, AError: string);
var
  Document: string;
begin
  Document := 'attempt_id = ' + RegistryTOMLQuote(FAttemptID) + #10
    + 'started_at = ' + RegistryTOMLQuote(FAttemptStartedAt) + #10
    + 'attempted_at = ' + RegistryTOMLQuote(RegistryTimestampNow) + #10
    + 'outcome = ' + RegistryTOMLQuote(AOutcome) + #10;
  { Upstream bytes can be reflected in errors; persist only a bounded prefix. }
  if AError <> '' then
    Document := Document + 'error = ' + RegistryTOMLQuote(Copy(AError, 1,
      MirrorAttemptErrorCharacters)) + #10;
  if Length(Document) > MirrorAttemptRecordBytes then
    Document := 'attempt_id = ' + RegistryTOMLQuote(FAttemptID) + #10
      + 'outcome = ' + RegistryTOMLQuote(AOutcome) + #10;
  ForceDirectories(TmpRoot);
  AtomicWriteBytes(RootPath(MirrorAttemptPath), TmpRoot, BytesOf(Document));
end;

procedure TLWPTRegistryMirror.BeginAttempt;
begin
  { The record and its staged replacement need headroom before the first
    write; without it the attempt stops without writing anything. }
  if 2 * MirrorAttemptRecordBytes > Config.StoreBudgetBytes
    - DirectoryBytes(Root, CheckSynchronizationDeadline) then
    raise ELWPTRegistryError.CreateStable('mirror_store_budget_exceeded',
      'the data directory has no room for an attempt record under max_store_bytes');
  FAttemptID := NewAttemptID;
  FAttemptStartedAt := RegistryTimestampNow;
  ForceDirectories(TmpRoot);
  SaveAttempt('in_progress', '');
end;

{ An in-progress record whose lease is free belongs to a process that stopped
  without recording its result. }
procedure TLWPTRegistryMirror.MarkAbandonedAttempt;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Parser: TTOMLParser;
  Root: TTOMLNode;
begin
  if not FileExists(RootPath(MirrorAttemptPath)) then Exit;
  Coordinator := nil;
  Lease := nil;
  Parser := nil;
  Root := nil;
  { Diagnostic maintenance is nonauthoritative. Any failure here, including
    the lease or the abandoned-record write, must never prevent opening and
    serving verified accepted state. }
  try
    try
      Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
      Lease := Coordinator.TryAcquire('registry-publication', 'registry mirror attempt recovery');
      if not Assigned(Lease) then Exit;
      Parser := TTOMLParser.Create;
      Root := Parser.ParseDocument(RegistryBytesText(LoadResource(MirrorAttemptPath,
        nil, MirrorAttemptRecordBytes)));
      if TomlStr(Root, 'outcome', '') <> 'in_progress' then Exit;
      FAttemptID := TomlStr(Root, 'attempt_id', '');
      FAttemptStartedAt := TomlStr(Root, 'started_at', '');
      SaveAttempt('abandoned', 'synchronization stopped before recording a result');
    except
      on Exception do;
    end;
  finally
    Root.Free;
    Parser.Free;
    Lease.Free;
    Coordinator.Free;
  end;
end;

type
  { Mirror acquisition: requests share the synchronization budget, and each
    accepted rotation is retained with its key record as it verifies. }
  TLWPTMirrorAcquisition = class(TLWPTRegistryAcquisition)
  protected
    function Fetch(const AURL, AMediaType: string;
      const AMaximumBytes: Int64): TBytes; override;
    procedure RotationAccepted(const ARotation: TLWPTRegistryRotationProof;
      const ASequence: Int64; const AKeyDocument: TBytes); override;
  public
    Mirror: TLWPTRegistryMirror;
    Bindings: TLWPTRegistryRotationBindingArray;
  end;

function TLWPTMirrorAcquisition.Fetch(const AURL, AMediaType: string;
  const AMaximumBytes: Int64): TBytes;
begin
  Result := GetDocument(AURL, AMediaType, AMaximumBytes,
    Mirror.RemainingSynchronizationMilliseconds);
end;

procedure TLWPTMirrorAcquisition.RotationAccepted(
  const ARotation: TLWPTRegistryRotationProof; const ASequence: Int64;
  const AKeyDocument: TBytes);
var
  BindingIndex: Integer;
begin
  BindingIndex := Length(Bindings);
  SetLength(Bindings, BindingIndex + 1);
  Bindings[BindingIndex].Sequence := ASequence;
  Bindings[BindingIndex].Document := SHA256BytesPrefixed(ARotation.Document);
  Bindings[BindingIndex].OldSignature := SHA256BytesPrefixed(ARotation.OldSignature);
  Bindings[BindingIndex].NewSignature := SHA256BytesPrefixed(ARotation.NewSignature);
  Bindings[BindingIndex].KeyDocument := SHA256BytesPrefixed(AKeyDocument);
  Mirror.WriteBudgeted(ProofPath(Bindings[BindingIndex].Document), ARotation.Document);
  Mirror.WriteBudgeted(ProofPath(Bindings[BindingIndex].OldSignature), ARotation.OldSignature);
  Mirror.WriteBudgeted(ProofPath(Bindings[BindingIndex].NewSignature), ARotation.NewSignature);
  Mirror.WriteBudgeted(ProofPath(Bindings[BindingIndex].KeyDocument), AKeyDocument);
end;

procedure TLWPTRegistryMirror.Synchronize;
var
  Coordinator: TLWPTProducerLeaseCoordinator;
  Lease: TLWPTProducerLease;
  Prior: TLWPTRegistryAcceptedState;
  Verified, PriorVerified: TLWPTVerifiedRegistry;
  Source: TLWPTMirrorDocumentSource;
  State: TLWPTRegistryState;
  Document: TBytes;
  Prefix: string;
  Budget: TLWPTRegistryMetadataBudget;
  RotationProof: TLWPTRegistryRotationProof;
  Acquisition: TLWPTMirrorAcquisition;
  AcceptedGeneration: TLWPTRegistryGeneration;
  AcceptedReference: IInterface;
  Binding: TLWPTRegistryRotationBinding;
begin
  Coordinator := TLWPTProducerLeaseCoordinator.Create(RootPath('locks'));
  Lease := nil;
  Source := nil;
  Budget := TLWPTRegistryMetadataBudget.Create(DefaultRegistryVerificationLimits);
  Acquisition := TLWPTMirrorAcquisition.Create(Budget);
  Acquisition.Mirror := Self;
  Acquisition.Contact := Config.UpstreamURL;
  Acquisition.Identity := Config.Identity;
  Acquisition.TrustKeyId := Config.TrustKeyID;
  Acquisition.TrustPublicKey := Config.TrustPublicKey;
  Acquisition.AlwaysFetchRootKey := True;
  AcceptedGeneration := nil;
  try
    Lease := Coordinator.TryAcquire('registry-publication', 'registry mirror synchronization');
    if not Assigned(Lease) then
      raise ELWPTRegistryError.CreateStable('publication_locked', 'another synchronization owns this mirror');
    { The budget starts before the first directory scan, so initial
      accounting, cleanup, and the attempt record are all inside it. }
    FSynchronizationDeadline := GetTickCount64 + MirrorSynchronizationMilliseconds;
    {$IFDEF REGISTRY_TESTING}
    if FSynchronizationMilliseconds > 0 then
      FSynchronizationDeadline := GetTickCount64 + FSynchronizationMilliseconds;
    {$ENDIF}
    BeginAttempt;
    try
      Prior := Default(TLWPTRegistryAcceptedState);
      if FileExists(RootPath('state/current.toml')) then
      begin
        State := ReadCurrentState(CheckSynchronizationDeadline);
        PriorVerified := VerifyStateProof(State, CheckSynchronizationDeadline);
        Prior := Accepted(State, PriorVerified.Proof.Checkpoint);
        AcceptedGeneration := BuildGeneration('', State, PriorVerified);
        AcceptedReference := AcceptedGeneration;
        Acquisition.Proof.Rotations := PriorVerified.Proof.Rotations;
        Acquisition.Bindings := Copy(State.Rotations);
        for RotationProof in Acquisition.Proof.Rotations do
        begin
          Budget.Account(RotationProof.Document);
          Budget.Account(RotationProof.OldSignature);
          Budget.Account(RotationProof.NewSignature);
        end;
        { Retained key records are part of the proof serving verifies, so
          acquisition charges them under the same limits. }
        for Binding in State.Rotations do
        begin
          Document := LoadResource(ProofPath(Binding.KeyDocument),
            CheckSynchronizationDeadline, MAX_REGISTRY_CONTROL_DOCUMENT_BYTES);
          Budget.Account(Document);
          RememberRegistryRetrieval(Acquisition.Proof, Document);
        end;
      end;
      Acquisition.PriorSequence := Prior.Sequence;
      { A clock behind accepted state fails before any upstream request. }
      RequireRegistryClockAtFloor(RegistryTimestampNow,
        RegistryLaterTimestamp(Prior.ClockFloor, Prior.PublishedAt));
      PrepareStorageBudget(AcceptedGeneration);
      Acquisition.Acquire;
      Source := TLWPTMirrorDocumentSource.Create;
      Source.Store := Self;
      Source.API := Acquisition.Discovery.API;
      Source.Progress := CheckSynchronizationDeadline;
      Verified := VerifyRegistryProof(Acquisition.Proof, Trust, Prior, RegistryTimestampNow,
        rvmAcquire, Source, DefaultRegistryVerificationLimits);
      TransferArchives(Acquisition.Discovery.API, Verified.Packages);
      State := Default(TLWPTRegistryState);
      State.Role := rrMirror;
      State.Sequence := Verified.State.Sequence;
      State.SnapshotHash := Verified.State.Snapshot;
      State.CheckpointHash := Verified.State.CheckpointHash;
      State.TrustKeyID := Verified.State.KeyId;
      State.TrustPublicKey := Verified.State.PublicKey;
      State.TrustKeyDocument := SHA256BytesPrefixed(Acquisition.KeyDocument);
      State.Rotations := Acquisition.Bindings;
      State.ClockFloor := Verified.State.ClockFloor;
      Prefix := 'checkpoints/renewals/sha256/' + Copy(State.CheckpointHash, 8, 64);
      State.CheckpointPath := Prefix + '.toml';
      State.SignaturePath := Prefix + '.sig.toml';
      WriteBudgeted(State.CheckpointPath, Acquisition.Proof.Checkpoint);
      WriteBudgeted(State.SignaturePath, Acquisition.Proof.Signature);
      WriteBudgeted(ProofPath(State.TrustKeyDocument), Acquisition.KeyDocument);
      { Verify the exact prospective state from disk, as serving and restart
        will, under the same limits. A head that could not be loaded again is
        never activated. The final clock check below follows this work. }
      Verified := VerifyStateProof(State, CheckSynchronizationDeadline);
      try
        SaveAttempt('verified', '');
      except
        on Exception do;
      end;
      { All immutable files are closed and verified before this atomic pointer.
        This is process-interruption recovery, not an fsync power-loss promise. }
      {$IFDEF REGISTRY_TESTING}
      if Assigned(FBeforeActivate) then FBeforeActivate;
      {$ENDIF}
      State.LastSync := RegistryTimestampNow;
      if Verified.ExpiresAt <= State.LastSync then
        raise ELWPTRegistryStaleContactError.CreateStable('checkpoint_expired',
          'checkpoint expired before activation');
      FActivationExpiresAt := Verified.ExpiresAt;
      FActivationClockFloor := State.ClockFloor;
      ActivateBudgeted(State);
    except
      on E: Exception do
      begin
        { Recording is best-effort; the synchronization failure is primary. }
        try
          SaveAttempt('failed', E.Message);
        except
          on Exception do;
        end;
        raise;
      end;
    end;
    try
      SaveAttempt('activated', '');
    except
      on Exception do;
    end;
  finally
    FSynchronizationDeadline := 0;
    AcceptedReference := nil;
    Acquisition.Free;
    Budget.Free;
    Source.Free;
    Lease.Free;
    Coordinator.Free;
  end;
end;

{$IFDEF REGISTRY_TESTING}
procedure TLWPTRegistryMirror.RetainForTesting(const AVerified: TLWPTVerifiedRegistry;
  const AKeyDocuments: array of TBytes; const ALastSync: string);
var
  State: TLWPTRegistryState;
  Document: TLWPTRegistryDocument;
  Rotation: TLWPTRegistryRotationProof;
  Binding: TLWPTRegistryRotationBinding;
  Index: Integer;
  Prefix: string;
begin
  for Document in AVerified.Documents do WriteImmutable(Document.Path, Document.Bytes);
  State := Default(TLWPTRegistryState);
  State.Role := rrMirror;
  State.Sequence := AVerified.State.Sequence;
  State.SnapshotHash := AVerified.State.Snapshot;
  State.TrustKeyID := AVerified.State.KeyId;
  State.TrustPublicKey := AVerified.State.PublicKey;
  State.CheckpointHash := AVerified.State.CheckpointHash;
  State.LastSync := ALastSync;
  State.ClockFloor := AVerified.State.ClockFloor;
  State.TrustKeyDocument := SHA256BytesPrefixed(AKeyDocuments[0]);
  WriteImmutable(ProofPath(State.TrustKeyDocument), AKeyDocuments[0]);
  SetLength(State.Rotations, Length(AVerified.Proof.Rotations));
  for Index := 0 to High(AVerified.Proof.Rotations) do
  begin
    Rotation := AVerified.Proof.Rotations[Index];
    Binding.Sequence := InspectRegistryRotation(Rotation.Document).EffectiveSequence;
    Binding.Document := SHA256BytesPrefixed(Rotation.Document);
    Binding.OldSignature := SHA256BytesPrefixed(Rotation.OldSignature);
    Binding.NewSignature := SHA256BytesPrefixed(Rotation.NewSignature);
    Binding.KeyDocument := SHA256BytesPrefixed(AKeyDocuments[Index + 1]);
    WriteImmutable(ProofPath(Binding.Document), Rotation.Document);
    WriteImmutable(ProofPath(Binding.OldSignature), Rotation.OldSignature);
    WriteImmutable(ProofPath(Binding.NewSignature), Rotation.NewSignature);
    WriteImmutable(ProofPath(Binding.KeyDocument), AKeyDocuments[Index + 1]);
    State.Rotations[Index] := Binding;
  end;
  Prefix := 'checkpoints/renewals/sha256/' + Copy(State.CheckpointHash, 8, 64);
  State.CheckpointPath := Prefix + '.toml';
  State.SignaturePath := Prefix + '.sig.toml';
  WriteImmutable(State.CheckpointPath, AVerified.Proof.Checkpoint);
  WriteImmutable(State.SignaturePath, AVerified.Proof.Signature);
  ActivateState(State);
end;

procedure RegistryMirrorRetainForTesting(AMirror: TLWPTRegistryMirror;
  const AVerified: TLWPTVerifiedRegistry; const AKeyDocuments: array of TBytes;
  const ALastSync: string);
begin
  AMirror.RetainForTesting(AVerified, AKeyDocuments, ALastSync);
end;
{$ENDIF}

function TLWPTRegistryMirror.VerifyMirror: string;
var
  State: TLWPTRegistryState;
  Verified: TLWPTVerifiedRegistry;
  Package: TLWPTRegistryPackage;
  Stream: TStream;
  Freshness: string;
begin
  Result := 'role = "mirror"' + #10 + 'origin = ' + RegistryTOMLQuote(Config.Identity) + #10;
  if FileExists(RootPath('state/current.toml')) then
  begin
    State := ReadCurrentState;
    Verified := VerifyStateProof(State);
    for Package in Verified.Packages do
    begin
      Stream := OpenRegistryFileWithoutFollowingLinks(RootPath('objects/sha256/'
        + Copy(Package.ArchiveHash, 8, 64)));
      try
        VerifyRegistryArtifact(Package, Stream);
      finally
        Stream.Free;
      end;
    end;
    Freshness := 'fresh';
    if Verified.ExpiresAt <= RegistryTimestampNow then Freshness := 'expired';
    Result := Result + 'sequence = ' + UIntToStr(State.Sequence) + #10
      + 'freshness = ' + RegistryTOMLQuote(Freshness) + #10
      + 'expires_at = ' + RegistryTOMLQuote(Verified.ExpiresAt) + #10
      + 'clock_floor = ' + RegistryTOMLQuote(Verified.State.ClockFloor) + #10
      + 'last_successful_sync = ' + RegistryTOMLQuote(State.LastSync) + #10;
  end
  else Result := Result + 'freshness = "uninitialized"' + #10;
  if FileExists(RootPath(MirrorAttemptPath)) then
    try
      Result := Result + RegistryBytesText(LoadResource(MirrorAttemptPath, nil,
        MirrorAttemptRecordBytes));
    except
      on E: ELWPTRegistryError do
        Result := Result + 'attempt_record = "unreadable"' + #10;
    end;
end;

end.
