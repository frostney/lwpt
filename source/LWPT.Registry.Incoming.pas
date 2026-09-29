{ LWPT.Registry.Incoming -- accounted staging for publication uploads.

  Uploads run outside the publication lease (ADR-0049). The registry-incoming
  producer lease guards every accounting-relevant transition of the incoming/
  namespace: creating a reservation, completing it, deleting a reservation or
  a completed entry, and moving a completed entry into objects/. A file's
  length is its charge, so a reservation counts in full from admission.
  Liveness of an in-progress upload is its own producer lease, never a file
  age. }
unit LWPT.Registry.Incoming;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.ProducerLease,
  LWPT.Registry.Store;

const
  { Equal to the mirror and installer archive limits. }
  RegistryMaximumArchiveBytes = Int64(256) * 1024 * 1024;
  { Uploads not yet committed, including those in progress. }
  RegistryIncomingBudgetBytes = Int64(1024) * 1024 * 1024;
  RegistryIncomingBudgetEntries = 1000;
  RegistryIncomingGuardWaitMilliseconds = 2000;
  { Completed, unreferenced uploads expire after this age. }
  RegistryIncomingExpirySeconds = 3600;
  REGISTRY_INCOMING_LEASE = 'registry-incoming';
  REGISTRY_PUBLICATION_LEASE = 'registry-publication';
  REGISTRY_UPLOAD_LEASE_PREFIX = 'registry-upload:';

type
  { A bounded wait for a registry lease timed out. The request answers a
    retryable temporary failure. }
  ELWPTRegistryBusy = class(ELWPTRegistryError);
  { Admission would exceed the unreferenced-upload budget. }
  ELWPTRegistryIncomingFull = class(ELWPTRegistryError);

  TLWPTRegistryUploadOutcome = (ruoCreated, ruoExisting, ruoMismatch);

  TLWPTRegistryIncoming = class;

  { One admitted upload. It owns its reservation file and its upload lease
    from admission until completion or abandonment. }
  TLWPTRegistryUpload = class
  private
    FIncoming: TLWPTRegistryIncoming;
    FID, FPartPath: string;
    FLease: TLWPTProducerLease;
    FStream: TStream;
    FDeclared, FReceived: Int64;
    FContext: TSHA256Context;
    FFinished: Boolean;
    procedure CloseStream;
    procedure ReleaseLease(const ARetire: Boolean);
    function DeletePart: Boolean;
  public
    destructor Destroy; override;
    procedure Write(const ABuffer; const ACount: Integer);
    { Verifies the received bytes against AExpectedHex and completes the
      upload under the guard. Raises ELWPTRegistryBusy when the guard wait
      times out; the reservation then stays charged and reclaimable. }
    function Complete(const AExpectedHex: string): TLWPTRegistryUploadOutcome;
    { Deletes the reservation after a failure. Returns False when the guard
      wait timed out and the reservation was left for reclamation. }
    function Abandon: Boolean;
    property ID: string read FID;
    property Declared: Int64 read FDeclared;
    property Received: Int64 read FReceived;
  end;

  TLWPTRegistryIncoming = class
  private
    FRoot, FIncomingRoot, FCompletedRoot, FObjectsRoot: string;
    FCoordinator: TLWPTProducerLeaseCoordinator;
    function AcquireGuard: TObject;
    procedure ReclaimUnderGuard;
    procedure ScanUnderGuard(out ABytes: Int64; out AEntries: Integer;
      out AExpiredBytes: Int64; out AExpiredEntries: Integer);
    function TryAdmit(const ALength: Int64;
      const AFinal: Boolean): TLWPTRegistryUpload;
    procedure ExpireAsPublicationHolder;
  public
    constructor Create(const ARoot: string);
    destructor Destroy; override;
    { Reserves ALength bytes. Raises ELWPTRegistryBusy on a guard timeout and
      ELWPTRegistryIncomingFull when the budget would be exceeded; neither
      leaves a reservation behind. }
    function Admit(const ALength: Int64): TLWPTRegistryUpload;
    { Publication-lease holders only: reclaim abandoned reservations and
      expire completed entries. AWait selects the bounded two-second guard
      wait; otherwise a busy guard is not waited for. Returns False when the
      guard was busy. }
    function Sweep(const AWait: Boolean = True): Boolean;
    function CompletedPath(const AHex: string): string;
    function ObjectPath(const AHex: string): string;
    { Publication-lease holders only: moves a completed, already rehashed
      entry into objects/. Raises ELWPTRegistryBusy on a guard timeout, when
      nothing has moved. }
    procedure Adopt(const AHex: string);
    { Current charge; takes the guard. }
    procedure Usage(out ABytes: Int64; out AEntries: Integer);
    property Root: string read FRoot;
  end;

function RegistryUploadIDIsValid(const AValue: string): Boolean;

{$IFDEF REGISTRY_TESTING}
type
  TRegistryIncomingHook = procedure(const APoint: string) of object;
{ Runs while the guard is held at 'admission-scan' (after incoming/sha256/,
  before the root), 'reclaim', 'expire', 'complete', and 'adopt'; and at
  'expiry-owned' once admission owns the publication lease to remove
  expired uploads, before it waits for the guard; and at 'admission-final'
  before the admission attempt that follows that removal, holding nothing. }
procedure SetRegistryIncomingHookForTesting(AHook: TRegistryIncomingHook);
{$ENDIF}

implementation

uses
  DateUtils,

  LWPT.Registry.Crypto;

{$IFDEF REGISTRY_TESTING}
var
  IncomingHook: TRegistryIncomingHook;

procedure SetRegistryIncomingHookForTesting(AHook: TRegistryIncomingHook);
begin
  IncomingHook := AHook;
end;

procedure RunHook(const APoint: string);
begin
  if Assigned(IncomingHook) then IncomingHook(APoint);
end;
{$ENDIF}

function RegistryUploadIDIsValid(const AValue: string): Boolean;
var
  Character: Char;
begin
  Result := Length(AValue) = 32;
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function IsLowerHex64(const AValue: string): Boolean;
var
  Character: Char;
begin
  Result := Length(AValue) = 64;
  if not Result then Exit;
  for Character in AValue do
    if not (Character in ['0'..'9', 'a'..'f']) then Exit(False);
end;

function NewUploadID: string;
var
  Random: array[0..15] of Byte;
begin
  RegistryRandomBytes(Random[0], SizeOf(Random));
  Result := BytesToHex(Random[0], SizeOf(Random));
end;

{ TLWPTRegistryIncoming }

constructor TLWPTRegistryIncoming.Create(const ARoot: string);
begin
  inherited Create;
  FRoot := ExcludeTrailingPathDelimiter(ExpandFileName(ARoot));
  FIncomingRoot := IncludeTrailingPathDelimiter(FRoot) + 'incoming';
  FCompletedRoot := IncludeTrailingPathDelimiter(FIncomingRoot) + 'sha256';
  FObjectsRoot := IncludeTrailingPathDelimiter(FRoot) + 'objects'
    + PathDelim + 'sha256';
  if IsDirSymlinkOrJunction(FIncomingRoot)
    or IsDirSymlinkOrJunction(FCompletedRoot) then
    raise ELWPTRegistryError.CreateStable('registry_path_link',
      'registry paths cannot contain symbolic links or reparse points');
  FCoordinator := TLWPTProducerLeaseCoordinator.Create(
    IncludeTrailingPathDelimiter(FRoot) + 'locks');
end;

destructor TLWPTRegistryIncoming.Destroy;
begin
  FCoordinator.Free;
  inherited Destroy;
end;

function TLWPTRegistryIncoming.CompletedPath(const AHex: string): string;
begin
  if not IsLowerHex64(AHex) then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'object digest is not canonical');
  Result := IncludeTrailingPathDelimiter(FCompletedRoot) + AHex;
end;

function TLWPTRegistryIncoming.ObjectPath(const AHex: string): string;
begin
  if not IsLowerHex64(AHex) then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'object digest is not canonical');
  Result := IncludeTrailingPathDelimiter(FObjectsRoot) + AHex;
end;

function TLWPTRegistryIncoming.AcquireGuard: TObject;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + RegistryIncomingGuardWaitMilliseconds;
  repeat
    Result := FCoordinator.TryAcquireGuard(REGISTRY_INCOMING_LEASE);
    if Assigned(Result) then Exit;
    if GetTickCount64 >= Deadline then
      raise ELWPTRegistryBusy.CreateStable('temporary_failure',
        'the upload staging guard is busy');
    Sleep(5);
  until False;
end;

procedure TLWPTRegistryIncoming.ReclaimUnderGuard;
var
  Candidates: TStringList;
  Search: TSearchRec;
  Name, UploadID, PartPath: string;
  Guard: TObject;
begin
  Candidates := TStringList.Create;
  try
    if SysUtils.FindFirst(IncludeTrailingPathDelimiter(FIncomingRoot)
      + '*.part', faAnyFile, Search) = 0 then
    try
      repeat
        Name := Search.Name;
        if (Search.Attr and faDirectory) <> 0 then Continue;
        UploadID := Copy(Name, 1, Length(Name) - Length('.part'));
        if RegistryUploadIDIsValid(UploadID) then Candidates.Add(UploadID);
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
    for UploadID in Candidates do
    begin
      { Another upload's lease is only ever tried without waiting. Holding it
        proves that no live request owns the reservation. }
      Guard := FCoordinator.TryAcquireGuard(REGISTRY_UPLOAD_LEASE_PREFIX
        + UploadID);
      if not Assigned(Guard) then Continue;
      try
        PartPath := IncludeTrailingPathDelimiter(FIncomingRoot) + UploadID
          + '.part';
        {$IFDEF REGISTRY_TESTING}
        RunHook('reclaim');
        {$ENDIF}
        if FileExists(PartPath) then SysUtils.DeleteFile(PartPath);
      finally
        Guard.Free;
      end;
      try
        FCoordinator.TryRetireKey(REGISTRY_UPLOAD_LEASE_PREFIX + UploadID);
      except
        { Lease state is diagnostic residue; the reservation is gone. }
      end;
    end;
  finally
    Candidates.Free;
  end;
end;

procedure TLWPTRegistryIncoming.ScanUnderGuard(out ABytes: Int64;
  out AEntries: Integer; out AExpiredBytes: Int64;
  out AExpiredEntries: Integer);
var
  Cutoff: TDateTime;

  procedure ScanDirectory(const ADirectory: string; const ACompleted: Boolean);
  var
    Search: TSearchRec;
    Stamp: TDateTime;
  begin
    if SysUtils.FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
      faAnyFile or faSymLink, Search) <> 0 then Exit;
    try
      repeat
        if (Search.Name = '.') or (Search.Name = '..') then Continue;
        if ((Search.Attr and faDirectory) <> 0)
          and ((Search.Attr and faSymLink) = 0) then Continue;
        Inc(ABytes, Int64(Search.Size));
        Inc(AEntries);
        if ACompleted and IsLowerHex64(Search.Name)
          and ((Search.Attr and faDirectory) = 0)
          and FileAge(IncludeTrailingPathDelimiter(ADirectory) + Search.Name, Stamp)
          and (Stamp < Cutoff) then
        begin
          Inc(AExpiredBytes, Int64(Search.Size));
          Inc(AExpiredEntries);
        end;
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
  end;

begin
  ABytes := 0;
  AEntries := 0;
  AExpiredBytes := 0;
  AExpiredEntries := 0;
  Cutoff := IncSecond(Now, -RegistryIncomingExpirySeconds);
  { Completed entries first, then reservations. Every transition between the
    two happens under the guard this scan holds, so none is missed. }
  ScanDirectory(FCompletedRoot, True);
  {$IFDEF REGISTRY_TESTING}
  RunHook('admission-scan');
  {$ENDIF}
  ScanDirectory(FIncomingRoot, False);
end;

procedure TLWPTRegistryIncoming.Usage(out ABytes: Int64;
  out AEntries: Integer);
var
  Guard: TObject;
  ExpiredBytes: Int64;
  ExpiredEntries: Integer;
begin
  Guard := AcquireGuard;
  try
    ScanUnderGuard(ABytes, AEntries, ExpiredBytes, ExpiredEntries);
  finally
    Guard.Free;
  end;
end;

type
  { Admission would fit once expired completed uploads are removed. }
  ELWPTRegistryExpiredCharge = class(ELWPTRegistryIncomingFull);

procedure TLWPTRegistryIncoming.ExpireAsPublicationHolder;
var
  Deadline: QWord;
  Publication: TObject;
  Swept: Boolean;
begin
  { Completed uploads expire only under the publication lease. Admission
    holds no lease here, so waiting for publication ownership and then for
    the accounting guard keeps the publication-then-incoming order. Both
    waits are bounded; a timeout is a retryable busy answer. }
  Deadline := GetTickCount64 + RegistryPublicationLeaseWaitMilliseconds;
  repeat
    Publication := FCoordinator.TryAcquireGuard(REGISTRY_PUBLICATION_LEASE);
    if Assigned(Publication) then Break;
    if GetTickCount64 >= Deadline then
      raise ELWPTRegistryBusy.CreateStable('temporary_failure',
        'expired uploads cannot be removed while another publication runs');
    Sleep(10);
  until False;
  try
    {$IFDEF REGISTRY_TESTING}
    RunHook('expiry-owned');
    {$ENDIF}
    Swept := Sweep(True);
  finally
    Publication.Free;
  end;
  if not Swept then
    raise ELWPTRegistryBusy.CreateStable('temporary_failure',
      'the upload staging guard is busy');
end;

function TLWPTRegistryIncoming.Admit(const ALength: Int64): TLWPTRegistryUpload;
begin
  if (ALength < 0) or (ALength > RegistryMaximumArchiveBytes) then
    raise ELWPTRegistryError.CreateStable('payload_too_large',
      'declared upload length exceeds the archive limit');
  ForceDirectories(FCompletedRoot);
  if IsDirSymlinkOrJunction(FIncomingRoot)
    or IsDirSymlinkOrJunction(FCompletedRoot) then
    raise ELWPTRegistryError.CreateStable('registry_path_link',
      'registry paths cannot contain symbolic links or reparse points');
  try
    Result := TryAdmit(ALength, False);
  except
    on E: ELWPTRegistryExpiredCharge do
    begin
      { Capacity is held by expired uploads: remove them, then admit once
        more. A second refusal is final. }
      ExpireAsPublicationHolder;
      Result := TryAdmit(ALength, True);
    end;
  end;
end;

function TLWPTRegistryIncoming.TryAdmit(const ALength: Int64;
  const AFinal: Boolean): TLWPTRegistryUpload;
var
  Charged, ExpiredBytes: Int64;
  Entries, ExpiredEntries: Integer;
  Guard: TObject;
  Lease: TLWPTProducerLease;
  UploadID, PartPath: string;
  Stream: TFileStream;
begin
  {$IFDEF REGISTRY_TESTING}
  if AFinal then RunHook('admission-final');
  {$ENDIF}
  UploadID := NewUploadID;
  { The upload's own lease is taken before its reservation exists and before
    any other lease is held. }
  Lease := FCoordinator.TryAcquire(REGISTRY_UPLOAD_LEASE_PREFIX + UploadID,
    'registry upload');
  if not Assigned(Lease) then
    raise ELWPTRegistryBusy.CreateStable('temporary_failure',
      'the upload lease is unavailable');
  Stream := nil;
  PartPath := IncludeTrailingPathDelimiter(FIncomingRoot) + UploadID + '.part';
  try
    Guard := AcquireGuard;
    try
      ReclaimUnderGuard;
      ScanUnderGuard(Charged, Entries, ExpiredBytes, ExpiredEntries);
      if (Entries + 1 > RegistryIncomingBudgetEntries)
        or (ALength > RegistryIncomingBudgetBytes - Charged) then
      begin
        if not AFinal and (ExpiredEntries > 0)
          and (Entries - ExpiredEntries + 1 <= RegistryIncomingBudgetEntries)
          and (ALength <= RegistryIncomingBudgetBytes - (Charged - ExpiredBytes)) then
          raise ELWPTRegistryExpiredCharge.CreateStable('storage_budget_exceeded',
            'expired uploads hold the budget');
        raise ELWPTRegistryIncomingFull.CreateStable('storage_budget_exceeded',
          'unreferenced uploads would exceed their budget');
      end;
      Stream := TFileStream.Create(PartPath, fmCreate);
      try
        Stream.Size := ALength;
        Stream.Position := 0;
      except
        FreeAndNil(Stream);
        SysUtils.DeleteFile(PartPath);
        raise;
      end;
    finally
      Guard.Free;
    end;
  except
    Stream.Free;
    Lease.Free;
    try
      FCoordinator.TryRetireKey(REGISTRY_UPLOAD_LEASE_PREFIX + UploadID);
    except
    end;
    raise;
  end;
  Result := TLWPTRegistryUpload.Create;
  Result.FIncoming := Self;
  Result.FID := UploadID;
  Result.FPartPath := PartPath;
  Result.FLease := Lease;
  Result.FStream := Stream;
  Result.FDeclared := ALength;
  Result.FReceived := 0;
  SHA256Init(Result.FContext);
end;

function TLWPTRegistryIncoming.Sweep(const AWait: Boolean): Boolean;
var
  Guard: TObject;
  Expired: TStringList;
  Search: TSearchRec;
  Name: string;
  Cutoff, Stamp: TDateTime;
begin
  if AWait then
    try
      Guard := AcquireGuard;
    except
      on E: ELWPTRegistryBusy do Exit(False);
    end
  else
  begin
    Guard := FCoordinator.TryAcquireGuard(REGISTRY_INCOMING_LEASE);
    if not Assigned(Guard) then Exit(False);
  end;
  Expired := TStringList.Create;
  try
    ReclaimUnderGuard;
    Cutoff := IncSecond(Now, -RegistryIncomingExpirySeconds);
    if SysUtils.FindFirst(IncludeTrailingPathDelimiter(FCompletedRoot) + '*',
      faAnyFile, Search) = 0 then
    try
      repeat
        Name := Search.Name;
        if not IsLowerHex64(Name) or ((Search.Attr and faDirectory) <> 0) then
          Continue;
        if FileAge(IncludeTrailingPathDelimiter(FCompletedRoot) + Name, Stamp)
          and (Stamp < Cutoff) then
          Expired.Add(Name);
      until SysUtils.FindNext(Search) <> 0;
    finally
      SysUtils.FindClose(Search);
    end;
    for Name in Expired do
    begin
      {$IFDEF REGISTRY_TESTING}
      RunHook('expire');
      {$ENDIF}
      SysUtils.DeleteFile(IncludeTrailingPathDelimiter(FCompletedRoot) + Name);
    end;
    Result := True;
  finally
    Expired.Free;
    Guard.Free;
  end;
end;

procedure TLWPTRegistryIncoming.Adopt(const AHex: string);
var
  Guard: TObject;
  Source, Destination: string;
begin
  Source := CompletedPath(AHex);
  Destination := ObjectPath(AHex);
  Guard := AcquireGuard;
  try
    {$IFDEF REGISTRY_TESTING}
    RunHook('adopt');
    {$ENDIF}
    if FileExists(Destination) then
    begin
      if FileExists(Source) then SysUtils.DeleteFile(Source);
      Exit;
    end;
    if not FileExists(Source) then
      raise ELWPTRegistryError.CreateStable('failed_dependency',
        'referenced archive object is not present');
    ForceDirectories(FObjectsRoot);
    if IsDirSymlinkOrJunction(FObjectsRoot) then
      raise ELWPTRegistryError.CreateStable('registry_path_link',
        'registry paths cannot contain symbolic links or reparse points');
    if not AtomicReplaceFile(Source, Destination) then
      raise ELWPTRegistryError.CreateStable('state_write_failed',
        'could not move an upload into the object store');
  finally
    Guard.Free;
  end;
end;

{ TLWPTRegistryUpload }

procedure TLWPTRegistryUpload.CloseStream;
begin
  FreeAndNil(FStream);
end;

procedure TLWPTRegistryUpload.ReleaseLease(const ARetire: Boolean);
begin
  FreeAndNil(FLease);
  if not ARetire then Exit;
  try
    FIncoming.FCoordinator.TryRetireKey(REGISTRY_UPLOAD_LEASE_PREFIX + FID);
  except
    { Lease state is diagnostic residue; the reservation is already gone. }
  end;
end;

function TLWPTRegistryUpload.DeletePart: Boolean;
var
  Guard: TObject;
begin
  try
    Guard := FIncoming.AcquireGuard;
  except
    on E: ELWPTRegistryBusy do Exit(False);
  end;
  try
    SysUtils.DeleteFile(FPartPath);
    Result := True;
  finally
    Guard.Free;
  end;
end;

procedure TLWPTRegistryUpload.Write(const ABuffer; const ACount: Integer);
begin
  if ACount <= 0 then Exit;
  if FFinished or not Assigned(FStream) then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'upload is no longer open');
  if ACount > FDeclared - FReceived then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'upload body exceeds its declared length');
  FStream.WriteBuffer(ABuffer, ACount);
  SHA256Update(FContext, ABuffer, ACount);
  Inc(FReceived, ACount);
end;

function TLWPTRegistryUpload.Complete(
  const AExpectedHex: string): TLWPTRegistryUploadOutcome;
var
  Digest: TSHA256Digest;
  Guard: TObject;
  Completed, ObjectFile: string;
begin
  if FFinished then
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'upload is already finished');
  CloseStream;
  if FReceived <> FDeclared then
  begin
    Abandon;
    raise ELWPTRegistryError.CreateStable('invalid_request',
      'upload body is shorter than its declared length');
  end;
  SHA256Final(FContext, Digest);
  if SHA256DigestHex(Digest) <> AExpectedHex then
  begin
    if not Abandon then
      raise ELWPTRegistryBusy.CreateStable('temporary_failure',
        'the upload staging guard is busy');
    Exit(ruoMismatch);
  end;
  Completed := FIncoming.CompletedPath(AExpectedHex);
  ObjectFile := FIncoming.ObjectPath(AExpectedHex);
  try
    Guard := FIncoming.AcquireGuard;
  except
    on E: ELWPTRegistryBusy do
    begin
      { The reservation stays charged. Releasing the upload lease makes it
        reclaimable by the next admission or publication-lease holder. }
      FFinished := True;
      ReleaseLease(False);
      raise;
    end;
  end;
  try
    {$IFDEF REGISTRY_TESTING}
    RunHook('complete');
    {$ENDIF}
    if FileExists(Completed) or FileExists(ObjectFile) then
    begin
      SysUtils.DeleteFile(FPartPath);
      Result := ruoExisting;
    end
    else
    begin
      if not AtomicReplaceFile(FPartPath, Completed) then
        raise ELWPTRegistryError.CreateStable('state_write_failed',
          'could not complete the upload');
      FileSetDate(Completed, DateTimeToFileDate(Now));
      Result := ruoCreated;
    end;
  finally
    Guard.Free;
  end;
  FFinished := True;
  ReleaseLease(True);
end;

function TLWPTRegistryUpload.Abandon: Boolean;
begin
  if FFinished then Exit(True);
  CloseStream;
  FFinished := True;
  Result := DeletePart;
  ReleaseLease(Result);
end;

destructor TLWPTRegistryUpload.Destroy;
begin
  try
    if not FFinished then Abandon;
  except
    { Destruction never raises; an unremoved reservation stays reclaimable. }
  end;
  CloseStream;
  FLease.Free;
  inherited Destroy;
end;

end.
