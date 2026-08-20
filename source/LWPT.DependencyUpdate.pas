{ LWPT.DependencyUpdate — compare locked git-host deps to advertised
  tags and rewrite authored constraints (ADR-0039).

  `lwpt outdated` and `lwpt update` share this unit so the skip rules,
  SemVer comparison, and ^/~ bump stay one implementation. Remote refs
  are listed through the existing git smart-HTTP path (injected as
  TListRemoteRefsFn so unit tests never touch the network). }
unit LWPT.DependencyUpdate;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  SysUtils,

  LWPT.GitProtocol,
  LWPT.Install,
  LWPT.Manifest;

type
  TOutdatedStatus = (ousCurrent, ousNewer, ousMajor);

  TOutdatedEntry = record
    Name       : string;
    Source     : string;
    Locator    : string;
    Constraint : string;
    Locked     : string;
    Latest     : string;
    LatestRef  : string;
    Status     : TOutdatedStatus;
    Kind       : TVersionKind;
    Dep        : TDependency;
  end;
  TOutdatedEntryArray = array of TOutdatedEntry;

  TListRemoteRefsFn = function(const ARepoURL: string): TGitRefArray;

function StripVersionPrefix(const S: string): string;
function IsUpdatableSource(const ADep: TDependency): Boolean;
function GitHostRepoURL(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray): string;
function HighestSemverTag(const ARefs: TGitRefArray;
  out ARefName, AVersion: string): Boolean;
function ClassifyOutdatedStatus(const ALocked,
  ALatest: string): TOutdatedStatus;
function ConstraintSatisfiesLatest(const AConstraint: string;
  AKind: TVersionKind; const ALatest, ALatestRef: string): Boolean;
function BumpConstraint(const AConstraint: string; AKind: TVersionKind;
  const ALatest, ALatestRef: string): string;
function OutdatedStatusName(AStatus: TOutdatedStatus): string;
function CollectOutdated(const AManifest: TManifest;
  const ALock: TResolvedArray;
  const AListRefs: TListRemoteRefsFn): TOutdatedEntryArray;
function HasNonCurrent(const AEntries: TOutdatedEntryArray): Boolean;
function FilterNamedEntries(const AEntries: TOutdatedEntryArray;
  const ANames: array of string): TOutdatedEntryArray;
function FormatOutdatedTable(const AEntries: TOutdatedEntryArray): string;
function FormatOutdatedJSON(const AEntries: TOutdatedEntryArray): string;
function FindLockVersion(const ALock: TResolvedArray;
  const AName: string): string;

implementation

uses
  LWPT.Core,
  Semver;

function StripVersionPrefix(const S: string): string;
begin
  if (Length(S) > 0) and ((S[1] = 'v') or (S[1] = 'V')) then
    Result := Copy(S, 2, MaxInt)
  else
    Result := S;
end;

function IsUpdatableSource(const ADep: TDependency): Boolean;
begin
  Result := ADep.SrcKind = skGitHost;
end;

function SplitOwnerRepo(const ASlug: string;
  out AUser, ARepo: string): Boolean;
var
  Slash: Integer;
begin
  Slash := Pos('/', ASlug);
  Result := (Slash > 1) and (Slash < Length(ASlug));
  if not Result then Exit;
  AUser := Copy(ASlug, 1, Slash - 1);
  ARepo := Copy(ASlug, Slash + 1, MaxInt);
end;

function RenderURLTemplate(const ATemplate, AUser, ARepo,
  AResolvedRef: string): string;
begin
  Result := StringReplace(ATemplate, PLACEHOLDER_USER, AUser, [rfReplaceAll]);
  Result := StringReplace(Result, PLACEHOLDER_REPOSITORY, ARepo, [rfReplaceAll]);
  Result := StringReplace(Result, PLACEHOLDER_REF, AResolvedRef, [rfReplaceAll]);
end;

function GitHostRepoURL(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray): string;
var
  Custom: TCustomSource;
  User, RepoName: string;
begin
  Result := '';
  if ADep.SrcKind <> skGitHost then Exit;
  case ADep.SrcHost of
    hkGitHub:
      Result := 'https://github.com/' + ADep.SrcLocator + '.git';
    hkGitLab:
      Result := 'https://gitlab.com/' + ADep.SrcLocator + '.git';
    hkBitbucket:
      Result := 'https://bitbucket.org/' + ADep.SrcLocator + '.git';
    hkCustom:
    begin
      if not FindCustomSource(ACustomSources, ADep.SrcHostName, Custom) then
        raise EManifestError.CreateFmt(
          'dependency "%s" uses custom prefix "%s:" but no [sources.%s] '
          + 'table is declared in %s',
          [ADep.Name, ADep.SrcHostName, ADep.SrcHostName, MANIFEST_FILE]);
      if not SplitOwnerRepo(ADep.SrcLocator, User, RepoName) then
        raise EManifestError.CreateFmt(
          'dependency "%s": custom source locator "%s" must be '
          + '"user/repository" shape', [ADep.Name, ADep.SrcLocator]);
      Result := RenderURLTemplate(Custom.GitTemplate, User, RepoName, '');
    end;
  else
    Result := '';
  end;
end;

function HighestSemverTag(const ARefs: TGitRefArray;
  out ARefName, AVersion: string): Boolean;
var
  i: Integer;
  Candidate: string;
begin
  Result := False;
  ARefName := '';
  AVersion := '';
  for i := 0 to High(ARefs) do
  begin
    if ARefs[i].Kind <> rkTag then Continue;
    Candidate := StripVersionPrefix(ARefs[i].Name);
    if Valid(Candidate, DefaultSemverOptions) = '' then Continue;
    if (not Result)
       or (Compare(Candidate, AVersion, DefaultSemverOptions) > 0) then
    begin
      ARefName := ARefs[i].Name;
      AVersion := Candidate;
      Result := True;
    end;
  end;
end;

function ClassifyOutdatedStatus(const ALocked,
  ALatest: string): TOutdatedStatus;
var
  LockedVersion, LatestVersion: string;
begin
  LockedVersion := StripVersionPrefix(ALocked);
  LatestVersion := StripVersionPrefix(ALatest);
  if LatestVersion = '' then Exit(ousCurrent);
  if LockedVersion = '' then
  begin
    if Valid(LatestVersion, DefaultSemverOptions) = '' then
      Exit(ousNewer);
    Exit(ousMajor);
  end;
  if (Valid(LockedVersion, DefaultSemverOptions) = '')
     or (Valid(LatestVersion, DefaultSemverOptions) = '') then
  begin
    if SameText(LockedVersion, LatestVersion)
       or SameText(ALocked, ALatest) then
      Exit(ousCurrent);
    Exit(ousNewer);
  end;
  if Compare(LatestVersion, LockedVersion, DefaultSemverOptions) <= 0 then
    Exit(ousCurrent);
  if MajorOf(LatestVersion, DefaultSemverOptions)
     <> MajorOf(LockedVersion, DefaultSemverOptions) then
    Exit(ousMajor);
  if (MajorOf(LockedVersion, DefaultSemverOptions) = 0)
     and (MinorOf(LatestVersion, DefaultSemverOptions)
       <> MinorOf(LockedVersion, DefaultSemverOptions)) then
    Exit(ousMajor);
  Result := ousNewer;
end;

function ConstraintSatisfiesLatest(const AConstraint: string;
  AKind: TVersionKind; const ALatest, ALatestRef: string): Boolean;
var
  LatestVersion: string;
begin
  LatestVersion := StripVersionPrefix(ALatest);
  if LatestVersion = '' then Exit(False);
  case AKind of
    vkSemverRange:
      Result := (Valid(LatestVersion, DefaultSemverOptions) <> '')
        and (ValidRange(AConstraint, DefaultSemverOptions) <> '')
        and Satisfies(LatestVersion, AConstraint, DefaultSemverOptions);
    vkSemverExact:
      Result := SameText(StripVersionPrefix(AConstraint), LatestVersion);
    vkLiteralTag:
      Result := (AConstraint = ALatestRef)
        or SameText(StripVersionPrefix(AConstraint), LatestVersion);
    vkCommitSha, vkNone:
      Result := False;
  else
    Result := False;
  end;
end;

function BumpConstraint(const AConstraint: string; AKind: TVersionKind;
  const ALatest, ALatestRef: string): string;
var
  LatestVersion: string;
begin
  LatestVersion := StripVersionPrefix(ALatest);
  if LatestVersion = '' then
  begin
    if ALatestRef <> '' then Exit(ALatestRef);
    Exit(AConstraint);
  end;
  if (AConstraint <> '') and (AConstraint[1] = '^') then
    Exit('^' + LatestVersion);
  if (AConstraint <> '') and (AConstraint[1] = '~') then
    Exit('~' + LatestVersion);
  if AKind = vkSemverExact then Exit(LatestVersion);
  if AKind = vkSemverRange then Exit('^' + LatestVersion);
  if ALatestRef <> '' then Exit(ALatestRef);
  Result := LatestVersion;
end;

function OutdatedStatusName(AStatus: TOutdatedStatus): string;
begin
  case AStatus of
    ousCurrent: Result := 'current';
    ousNewer  : Result := 'newer';
    ousMajor  : Result := 'major';
  else
    Result := 'current';
  end;
end;

function FindLockVersion(const ALock: TResolvedArray;
  const AName: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ALock) do
    if SameText(ALock[i].Name, AName) then
      Exit(ALock[i].Version);
end;

function CollectOutdated(const AManifest: TManifest;
  const ALock: TResolvedArray;
  const AListRefs: TListRemoteRefsFn): TOutdatedEntryArray;
var
  i, N: Integer;
  Refs: TGitRefArray;
  Entry: TOutdatedEntry;
  RepoURL, LatestRef, LatestVersion: string;
begin
  SetLength(Result, 0);
  N := 0;
  for i := 0 to High(AManifest.Deps) do
  begin
    if not IsUpdatableSource(AManifest.Deps[i]) then Continue;
    Entry := Default(TOutdatedEntry);
    Entry.Dep := AManifest.Deps[i];
    Entry.Name := AManifest.Deps[i].Name;
    Entry.Source := AManifest.Deps[i].SrcOriginal;
    Entry.Locator := AManifest.Deps[i].SrcLocator;
    Entry.Constraint := AManifest.Deps[i].VersionSpec;
    Entry.Kind := AManifest.Deps[i].VersionKind;
    Entry.Locked := FindLockVersion(ALock, Entry.Name);
    RepoURL := GitHostRepoURL(AManifest.Deps[i], AManifest.CustomSources);
    if RepoURL = '' then Continue;
    if Assigned(AListRefs) then
      Refs := AListRefs(RepoURL)
    else
      Refs := ListRemoteRefs(RepoURL);
    if not HighestSemverTag(Refs, LatestRef, LatestVersion) then Continue;
    Entry.LatestRef := LatestRef;
    Entry.Latest := LatestVersion;
    Entry.Status := ClassifyOutdatedStatus(Entry.Locked, LatestVersion);
    SetLength(Result, N + 1);
    Result[N] := Entry;
    Inc(N);
  end;
end;

function HasNonCurrent(const AEntries: TOutdatedEntryArray): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(AEntries) do
    if AEntries[i].Status <> ousCurrent then Exit(True);
  Result := False;
end;

function FilterNamedEntries(const AEntries: TOutdatedEntryArray;
  const ANames: array of string): TOutdatedEntryArray;
var
  i, j, N: Integer;
  Found: Boolean;
begin
  SetLength(Result, 0);
  N := 0;
  for i := 0 to High(ANames) do
  begin
    Found := False;
    for j := 0 to High(AEntries) do
      if SameText(AEntries[j].Name, ANames[i]) then
      begin
        SetLength(Result, N + 1);
        Result[N] := AEntries[j];
        Inc(N);
        Found := True;
        Break;
      end;
    if not Found then
      raise EManifestError.CreateFmt(
        'no updatable git-host dependency named "%s"', [ANames[i]]);
  end;
end;

function PadRight(const S: string; AWidth: Integer): string;
begin
  Result := S;
  while Length(Result) < AWidth do
    Result := Result + ' ';
end;

function FormatOutdatedTable(const AEntries: TOutdatedEntryArray): string;
var
  i: Integer;
  Widths: array[0..4] of Integer;
  Headers: array[0..4] of string;
  Cells: array of array[0..4] of string;
  Line: string;

  procedure Consider(ACol: Integer; const AText: string);
  begin
    if Length(AText) > Widths[ACol] then Widths[ACol] := Length(AText);
  end;

begin
  if Length(AEntries) = 0 then
    Exit('No updatable git-host dependencies.' + #10);

  Headers[0] := 'NAME';
  Headers[1] := 'CONSTRAINT';
  Headers[2] := 'LOCKED';
  Headers[3] := 'LATEST';
  Headers[4] := 'STATUS';
  for i := 0 to 4 do Widths[i] := Length(Headers[i]);
  SetLength(Cells, Length(AEntries));
  for i := 0 to High(AEntries) do
  begin
    Cells[i][0] := AEntries[i].Name;
    Cells[i][1] := AEntries[i].Constraint;
    Cells[i][2] := AEntries[i].Locked;
    Cells[i][3] := AEntries[i].Latest;
    Cells[i][4] := OutdatedStatusName(AEntries[i].Status);
    Consider(0, Cells[i][0]);
    Consider(1, Cells[i][1]);
    Consider(2, Cells[i][2]);
    Consider(3, Cells[i][3]);
    Consider(4, Cells[i][4]);
  end;

  Line := PadRight(Headers[0], Widths[0]) + '  '
    + PadRight(Headers[1], Widths[1]) + '  '
    + PadRight(Headers[2], Widths[2]) + '  '
    + PadRight(Headers[3], Widths[3]) + '  '
    + Headers[4];
  Result := Line + #10;
  for i := 0 to High(AEntries) do
  begin
    Line := PadRight(Cells[i][0], Widths[0]) + '  '
      + PadRight(Cells[i][1], Widths[1]) + '  '
      + PadRight(Cells[i][2], Widths[2]) + '  '
      + PadRight(Cells[i][3], Widths[3]) + '  '
      + Cells[i][4];
    Result := Result + Line + #10;
  end;
end;

function JSONEscape(const AValue: string): string;
var
  i: Integer;
  ValueByte: Byte;
begin
  Result := '"';
  for i := 1 to Length(AValue) do
  begin
    ValueByte := Byte(AValue[i]);
    case AValue[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if ValueByte < 32 then
        Result := Result + '\u00' + IntToHex(ValueByte, 2)
      else
        Result := Result + AValue[i];
    end;
  end;
  Result := Result + '"';
end;

function FormatOutdatedJSON(const AEntries: TOutdatedEntryArray): string;
var
  i: Integer;
begin
  Result := '{"packages":[';
  for i := 0 to High(AEntries) do
  begin
    if i > 0 then Result := Result + ',';
    Result := Result + '{"name":' + JSONEscape(AEntries[i].Name)
      + ',"source":' + JSONEscape(AEntries[i].Source)
      + ',"locator":' + JSONEscape(AEntries[i].Locator)
      + ',"constraint":' + JSONEscape(AEntries[i].Constraint)
      + ',"locked":' + JSONEscape(AEntries[i].Locked)
      + ',"latest":' + JSONEscape(AEntries[i].Latest)
      + ',"latestRef":' + JSONEscape(AEntries[i].LatestRef)
      + ',"status":' + JSONEscape(OutdatedStatusName(AEntries[i].Status))
      + '}';
  end;
  Result := Result + ']}'#10;
end;

end.
