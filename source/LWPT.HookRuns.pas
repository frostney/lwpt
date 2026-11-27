{ LWPT.HookRuns — in-flight runs of one staleness-gated output (#442).

  A gated hook or run task records its run after the command returns:
  the inputs it read before the command and the output it finds after.
  When two LWPT processes in one checkout run the same output at once, the
  output one of them finds may be the other's, generated from other
  inputs, and its record would then make that output look fresh.

  Nothing here waits across a command: a lock held from the gate through
  the command deadlocks a hook that delegates to a nested LWPT command for
  the same output, and a build that holds the only worker. Instead, every
  gated run of an output registers a marker for as long as it runs, and a
  run that overlapped another run of the same output records nothing, so
  the output stays stale and the next invocation runs it again.

  Each marker is a file held under an operating-system owner guard, so a
  crashed run's marker is visibly dead. Registering and finishing take a
  short per-output lock that is never held while a command runs. A run
  registering beside a live marker flags both runs as overlapped. Every
  pair of overlapping runs meets this way, because the later of the two
  registers while the earlier one's marker is live.

  A run exports its marker ID, after those of the runs it is nested in, to
  its command's environment. A nested LWPT run for the same output is part
  of its ancestor's run: neither flags the other, and the nested run keeps
  no record while that ancestor still runs, because the ancestor's command
  may write the output after it. The ancestor's own record covers both. }
unit LWPT.HookRuns;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils,

  LWPT.Core;

const
  { The IDs of the gated runs a command is nested in, comma-separated. }
  HOOK_RUN_ANCESTORS_ENV = PROJECT_NAME + '_HOOK_RUN_ANCESTORS';

type
  { One registered gated run. Create registers it below ADirectory, under
    the short lock at AGuardPath, and raises when it cannot: running
    unregistered would hide this run from the others. Its ancestors are
    the comma-separated IDs in AAncestors, or in HOOK_RUN_ANCESTORS_ENV;
    malformed IDs are ignored. Finish unregisters it and says whether its
    record may be written. Freeing an unfinished run unregisters it
    without a record. }
  TLWPTHookRun = class
  private
    FDirectory, FGuardPath, FId, FMarkerPath: string;
    FAncestors: TStringList;
    FOwner: TObject;
    FOverlapped, FNested, FFinished, FRegistered: Boolean;
    function IsAncestor(const AId: string): Boolean;
    procedure Register;
    procedure Release;
    procedure RequireUnlinkedState;
  public
    constructor Create(const ADirectory, AGuardPath: string); overload;
    constructor Create(const ADirectory, AGuardPath,
      AAncestors: string); overload;
    destructor Destroy; override;
    { True when this run may be recorded: no other run of this output
      overlapped it, apart from its ancestors and descendants, and no
      ancestor run of this output was still running when it registered.
      Never raises: a failure counts as an overlap, which only keeps the
      output stale. }
    function Finish: Boolean;
    { NAME=value for the command's environment. }
    function ChildEnvironment: string;
    property Id: string read FId;
  end;

implementation

uses
  DateUtils,

  LWPT.BuildSession;

const
  MARKER_EXTENSION = '.run';
  OVERLAP_EXTENSION = '.overlapped';
  MAX_RUN_ID_LENGTH = 64;

var
  LocalMarkersCriticalSection: TRTLCriticalSection;
  LocalMarkers: TStringList;
  RunCounter: LongInt = 0;

function NewRunId: string;
var
  Current: TDateTime;
begin
  Current := Now;
  Result := IntToStr(GetProcessID) + '-'
    + IntToStr(DateTimeToUnix(Current, False) * 1000
      + MilliSecondOfTheSecond(Current))
    + '-' + IntToStr(InterlockedIncrement(RunCounter));
end;

function ValidRunId(const AId: string): Boolean;
var
  i: Integer;
begin
  Result := (AId <> '') and (Length(AId) <= MAX_RUN_ID_LENGTH);
  if not Result then Exit;
  for i := 1 to Length(AId) do
    if not (AId[i] in ['0'..'9', '-']) then Exit(False);
end;

{ A marker this process holds is never probed: closing any descriptor of a
  file drops every fcntl lock the process holds on it. }
function IsLocalMarker(const APath: string): Boolean;
begin
  EnterCriticalSection(LocalMarkersCriticalSection);
  try
    Result := LocalMarkers.IndexOf(APath) >= 0;
  finally
    LeaveCriticalSection(LocalMarkersCriticalSection);
  end;
end;

procedure AddLocalMarker(const APath: string);
begin
  EnterCriticalSection(LocalMarkersCriticalSection);
  try
    LocalMarkers.Add(APath);
  finally
    LeaveCriticalSection(LocalMarkersCriticalSection);
  end;
end;

procedure RemoveLocalMarker(const APath: string);
var
  Index: Integer;
begin
  EnterCriticalSection(LocalMarkersCriticalSection);
  try
    Index := LocalMarkers.IndexOf(APath);
    if Index >= 0 then LocalMarkers.Delete(Index);
  finally
    LeaveCriticalSection(LocalMarkersCriticalSection);
  end;
end;

{ An empty flag file, opened without being inheritable by a child that
  another thread starts meanwhile. }
procedure CreateFlag(const APath: string);
begin
  if FileExists(APath) then Exit;
  OpenProtectedFileStream(APath, fmCreate).Free;
end;

{ Cleanup is best effort: what it removes is a finished or dead run's
  state, which no registration counts, so a file that cannot be removed
  now is removed by a later registration. }
procedure RemoveState(const APath: string);
begin
  DeleteFile(APath);
end;

constructor TLWPTHookRun.Create(const ADirectory, AGuardPath: string);
begin
  Create(ADirectory, AGuardPath,
    GetEnvironmentVariable(HOOK_RUN_ANCESTORS_ENV));
end;

constructor TLWPTHookRun.Create(const ADirectory, AGuardPath,
  AAncestors: string);
var
  Ancestors: TStringList;
  i: Integer;
begin
  inherited Create;
  FDirectory := ExcludeTrailingPathDelimiter(ADirectory);
  FGuardPath := AGuardPath;
  FAncestors := TStringList.Create;
  FAncestors.CaseSensitive := True;
  Ancestors := TStringList.Create;
  try
    Ancestors.Delimiter := ',';
    Ancestors.StrictDelimiter := True;
    Ancestors.DelimitedText := AAncestors;
    for i := 0 to Ancestors.Count - 1 do
      if ValidRunId(Ancestors[i]) then FAncestors.Add(Ancestors[i]);
  finally
    Ancestors.Free;
  end;
  FId := NewRunId;
  FMarkerPath := FDirectory + '/' + FId + MARKER_EXTENSION;
  Register;
end;

destructor TLWPTHookRun.Destroy;
begin
  if not FFinished then Finish;
  Release;
  FAncestors.Free;
  inherited Destroy;
end;

function TLWPTHookRun.IsAncestor(const AId: string): Boolean;
begin
  Result := FAncestors.IndexOf(AId) >= 0;
end;

{ The short lock writes to its file and the runs live beside it, so
  neither the lock, its directory nor the one above (hook-runs) may lead
  elsewhere. The lock itself is also opened without following a link. }
procedure TLWPTHookRun.RequireUnlinkedState;
var
  Directory: string;
begin
  Directory := ExtractFileDir(FGuardPath);
  if IsDirSymlinkOrJunction(FGuardPath) or IsDirSymlinkOrJunction(Directory)
     or IsDirSymlinkOrJunction(ExtractFileDir(Directory))
     or IsDirSymlinkOrJunction(FDirectory) then
    raise ELWPTError.CreateFmt('hook run state must not be a link: %s',
      [FGuardPath]);
end;

procedure TLWPTHookRun.Register;
var
  Guard: TObject;
  Search: TSearchRec;
  Entries: TStringList;
  Name, OtherId, OtherMarker: string;
  i: Integer;
begin
  RequireUnlinkedState;
  if not ForceDirectories(ExtractFileDir(FGuardPath))
     and not DirectoryExists(ExtractFileDir(FGuardPath)) then
    raise ELWPTError.CreateFmt('could not create hook run directory %s',
      [ExtractFileDir(FGuardPath)]);
  RequireUnlinkedState;
  Guard := AcquireShortLock(FGuardPath);
  try
    if IsDirSymlinkOrJunction(FDirectory) then
      raise ELWPTError.CreateFmt('hook run directory must not be a link: %s',
        [FDirectory]);
    if not ForceDirectories(FDirectory) and not DirectoryExists(FDirectory)
    then
      raise ELWPTError.CreateFmt('could not create hook run directory %s',
        [FDirectory]);
    Entries := TStringList.Create;
    try
      { A directory lists at least its own '.' entry, so a failure here is
        a listing that did not happen. A run that cannot see the others
        must not run unseen. }
      if FindFirst(FDirectory + '/*', faAnyFile or faSymLink, Search) <> 0
      then
        raise ELWPTError.CreateFmt('could not list hook run directory %s',
          [FDirectory]);
      try
        repeat
          { A link is never probed: the probe opens what it names. }
          if (Search.Attr and faSymLink) <> 0 then
            RemoveState(FDirectory + '/' + Search.Name)
          else if (Search.Attr and faDirectory) = 0 then
            Entries.Add(Search.Name);
        until FindNext(Search) <> 0;
      finally
        SysUtils.FindClose(Search);
      end;
      for i := 0 to Entries.Count - 1 do
      begin
        Name := Entries[i];
        if ExtractFileExt(Name) = MARKER_EXTENSION then
        begin
          OtherId := ChangeFileExt(Name, '');
          OtherMarker := FDirectory + '/' + Name;
          if IsLocalMarker(OtherMarker) or OwnerGuardHeld(OtherMarker) then
          begin
            if IsAncestor(OtherId) then
              FNested := True
            else
            begin
              FOverlapped := True;
              CreateFlag(FDirectory + '/' + OtherId + OVERLAP_EXTENSION);
            end;
          end
          else
          begin
            { Its owner exited without finishing. }
            RemoveState(OtherMarker);
            RemoveState(FDirectory + '/' + OtherId + OVERLAP_EXTENSION);
          end;
        end
        else if (ExtractFileExt(Name) = OVERLAP_EXTENSION)
          and not FileExists(FDirectory + '/' + ChangeFileExt(Name, '')
            + MARKER_EXTENSION) then
          RemoveState(FDirectory + '/' + Name);
      end;
    finally
      Entries.Free;
    end;
    AddLocalMarker(FMarkerPath);
    FRegistered := True;
    FOwner := AcquireOwnerGuard(FMarkerPath, 'hook run marker');
  finally
    Guard.Free;
  end;
end;

procedure TLWPTHookRun.Release;
begin
  FreeAndNil(FOwner);
  if FRegistered then RemoveLocalMarker(FMarkerPath);
  FRegistered := False;
end;

function TLWPTHookRun.Finish: Boolean;
var
  Guard: TObject;
  OverlapPath: string;
begin
  Result := False;
  if FFinished then Exit;
  FFinished := True;
  if FOwner = nil then
  begin
    Release;
    Exit;
  end;
  OverlapPath := FDirectory + '/' + FId + OVERLAP_EXTENSION;
  try
    RequireUnlinkedState;
    Guard := AcquireShortLock(FGuardPath);
    try
      Result := not FOverlapped and not FNested
        and not FileExists(OverlapPath);
      Release;
      RemoveState(FMarkerPath);
      RemoveState(OverlapPath);
    finally
      Guard.Free;
    end;
  except
    { The marker's guard is released either way, so the next registration
      removes what is left. }
    on E: Exception do
    begin
      Release;
      Result := False;
    end;
  end;
end;

function TLWPTHookRun.ChildEnvironment: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to FAncestors.Count - 1 do
    Result := Result + FAncestors[i] + ',';
  Result := HOOK_RUN_ANCESTORS_ENV + '=' + Result + FId;
end;

initialization
  InitCriticalSection(LocalMarkersCriticalSection);
  LocalMarkers := TStringList.Create;
  LocalMarkers.CaseSensitive := {$IFDEF MSWINDOWS}False{$ELSE}True{$ENDIF};

finalization
  LocalMarkers.Free;
  DoneCriticalSection(LocalMarkersCriticalSection);

end.
