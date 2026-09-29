{ LWPT.ArchiveNormalize — the local, network-free publication archive layer
  (ADR-0049, "Archive contract" and "Zip normalization").

  `lwpt registry publish` takes a prebuilt .tar.gz or a .zip. The input
  type comes from the leading bytes, never the file name: 1f 8b is a
  tar.gz, 'PK'#3#4 or 'PK'#5#6 is a zip, anything else is refused with
  unsupported_archive.

  - A tar.gz is published exactly as given. ScanTarGzipArchive reads it
    without extracting it, through the installer's own gzip decoder and tar
    header reading, and applies the installer's traversal and link rules and
    255-byte component limit plus the 1 GiB expanded bound. It must have
    exactly one top-level directory, which the installer strips, holding a
    regular lwpt.toml that no other entry can replace once extracted (see
    ClassifyManifestPath).
  - A zip is normalized into the one canonical tar.gz (LWPT.TarWriter) after
    LWPT.Zip validates its container. Entry names must be strict UTF-8
    without control characters, relative, and free of '.', '..', and empty
    components; only regular files and directories are accepted. The
    normalized tree, with every implied parent directory, must have no path
    that is both a file and a directory, no duplicate, and no two paths equal
    under ASCII case folding. The package root is the zip root when it holds
    lwpt.toml, otherwise the single top-level directory, which must hold it.
    Output paths are <name>-<version>/<path below the root> and must fit
    ustar.

  For both, lwpt.toml is bounded in bytes (from its declared size, before
  it is decoded) and in TOML nodes. Its [package] version must be canonical
  SemVer, and its name must use the consumer package grammar (ADR-0051
  decision 6: 1 to 128 of [a-z0-9_-], starting with a letter or digit),
  the protocol grammar without '.', so every published package can be
  installed.

  Its [dependencies] become the record's dependencies (ADR-0051,
  "Dependency-bearing publication"; ADR-0049 decision 4 lifted). Every
  entry must be a registry: source without include or exclude filters, with
  a constraint already in the protocol's canonical grammar; its alias
  resolves through the manifest's own [registries], which must name the
  identity explicitly. A dependency on the package's own name is refused.
  Anything else is unsupported_dependencies.

  Nothing here reads a clock, the environment, the network, or project
  state, or writes a file: input and output are caller-owned memory. }
unit LWPT.ArchiveNormalize;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils,

  LWPT.Archive,
  LWPT.Core,
  LWPT.Registry.Verification;

const
  PUBLICATION_MANIFEST_NAME = MANIFEST_FILE;

type
  TLWPTArchiveKind = (akTarGzip, akZip);

  TLWPTPublicationManifest = record
    Name: string;
    Version: string;
    { [dependencies] mapped to record dependencies, in declaration order.
      Each names its origin identity explicitly; the record writer omits
      the publishing origin and sorts them in protocol order. }
    Dependencies: TLWPTRegistryDependencyArray;
  end;

  TLWPTPublicationArchive = record
    Kind: TLWPTArchiveKind;
    Manifest: TLWPTPublicationManifest;
    { The bytes to upload: the input itself for a tar.gz, or the canonical
      tar.gz normalized from a zip. }
    Archive: TBytes;
  end;

{ Classifies AInput by its leading bytes; raises unsupported_archive. }
function DetectArchiveKind(const AInput: TBytes): TLWPTArchiveKind;

{ Reads the publication identity and dependencies from lwpt.toml content.
  Raises archive_limit_exceeded past the manifest byte or TOML node budget,
  invalid_archive when it does not parse, invalid_package_name or
  invalid_version when the identity is not valid, and
  unsupported_dependencies when a dependency cannot become a record
  dependency. }
function InspectPublicationManifest(
  const AContent: TBytes): TLWPTPublicationManifest; overload;
function InspectPublicationManifest(const AContent: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest; overload;

{ The canonical protocol spelling of AConstraint when whitespace, commas,
  or a leading '=' are all that keep it from the canonical grammar, or ''
  when there is none. }
function CanonicalConstraintSuggestion(const AConstraint: string): string;

{ Validates a tar.gz for publication without extracting it. }
function ScanTarGzipArchive(const AInput: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest;

{ Normalizes a zip into the canonical tar.gz written to ATarget. On failure
  ATarget holds partial output that the caller must discard. }
function NormalizeZipArchive(const AInput: TBytes; const ATarget: TStream;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest;

{ The publish client's entry point: detects the input type, validates or
  normalizes it, and maps its dependencies, all before any credential or
  connection is touched. }
function PreparePublicationArchive(
  const AInput: TBytes): TLWPTPublicationArchive; overload;
function PreparePublicationArchive(const AInput: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationArchive; overload;

implementation

uses
  Generics.Collections,

  LWPT.Gzip,
  LWPT.Manifest,
  LWPT.TarWriter,
  LWPT.Zip,
  TOML;

const
  { Longest GNU long name the scan buffers. Far past every platform's path
    limit, so only an archive the installer could not extract is refused. }
  MAXIMUM_TAR_LONG_NAME_BYTES = 64 * 1024;

procedure RaiseInvalid(const ADetail: string);
begin
  raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID, ADetail);
end;

function DetectArchiveKind(const AInput: TBytes): TLWPTArchiveKind;
begin
  if (Length(AInput) >= 2) and (AInput[0] = $1F) and (AInput[1] = $8B) then
    Exit(akTarGzip);
  if (Length(AInput) >= 4) and (AInput[0] = Ord('P')) and (AInput[1] = Ord('K'))
     and (((AInput[2] = 3) and (AInput[3] = 4))
       or ((AInput[2] = 5) and (AInput[3] = 6))) then
    Exit(akZip);
  raise ELWPTArchiveError.CreateStable(ARCHIVE_UNSUPPORTED,
    'input is neither a gzip tar (1f 8b) nor a zip (PK 03 04 or PK 05 06)');
end;

{ ---------------------------------------------------------------------------
  Manifest identity
  --------------------------------------------------------------------------- }

procedure RequireManifestSize(const ASize: Int64;
  const ALimits: TLWPTArchiveLimits);
begin
  if ASize > ALimits.MaximumManifestBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      PUBLICATION_MANIFEST_NAME + ' is %d bytes; the limit is %d',
      [ASize, ALimits.MaximumManifestBytes]);
end;

{ ---------------------------------------------------------------------------
  Dependency mapping (ADR-0051, "Dependency-bearing publication")
  --------------------------------------------------------------------------- }

procedure RaiseUnsupportedDependency(const ADetail: string);
begin
  raise ELWPTArchiveError.CreateStable(ARCHIVE_UNSUPPORTED_DEPENDENCIES,
    PUBLICATION_MANIFEST_NAME + ' ' + ADetail);
end;

function IsConstraintOperator(const AToken: string): Boolean;
begin
  Result := (AToken = '<') or (AToken = '<=') or (AToken = '>')
    or (AToken = '>=') or (AToken = '=') or (AToken = '^') or (AToken = '~');
end;

{ One ' || ' arm: tokens split on white space, an operator token joined to
  the version after it, and a lone '=' comparator dropped. }
function NormalizeConstraintArm(const AArm: string): string;
var
  Tokens: TStringArray;
  Token, Pending: string;
begin
  Result := '';
  Pending := '';
  Tokens := StringReplace(StringReplace(AArm, #9, ' ', [rfReplaceAll]), ',',
    ' ', [rfReplaceAll]).Split([' '], TStringSplitOptions.ExcludeEmpty);
  for Token in Tokens do
    if IsConstraintOperator(Token) and (Pending = '') then
      Pending := Token
    else
    begin
      if Result <> '' then Result := Result + ' ';
      Result := Result + Pending + Token;
      Pending := '';
    end;
  if Pending <> '' then Exit('');
  if (Length(Result) > 1) and (Result[1] = '=') and (Result[2] <> '=')
     and (Pos(' ', Result) = 0) then
    Delete(Result, 1, 1);
end;

function CanonicalConstraintSuggestion(const AConstraint: string): string;
var
  Arms: TStringArray;
  Arm, Normalized: string;
begin
  Result := '';
  Arms := StringReplace(AConstraint, '||', #0, [rfReplaceAll]).Split([#0]);
  for Arm in Arms do
  begin
    Normalized := NormalizeConstraintArm(Arm);
    if Normalized = '' then Exit('');
    if Result <> '' then Result := Result + ' || ';
    Result := Result + Normalized;
  end;
  if (Result = AConstraint) or not RegistryConstraintIsCanonical(Result) then
    Result := '';
end;

{ The origin identity a registry dependency's alias names in the
  publishing manifest's own [registries] (ADR-0051: "Aliases"). There is no
  endpoint-advertised identity at publish time, so the declaration must
  name it. }
function PublicationDependencyOrigin(ARegistries: TTOMLNode;
  const ADependency: TDependency): string;
var
  Alias: string;
  Pair: TTOMLNodeMap.TKeyValuePair;
  Entry, DefaultNode: TTOMLNode;
  Count: Integer;
begin
  Alias := ADependency.RegistryAlias;
  if not TomlIsTable(ARegistries) then
    RaiseUnsupportedDependency('dependency "' + ADependency.Name + '": '
      + ADependency.SrcOriginal + ' needs a [registries] declaration naming '
      + 'its origin identity');
  if Alias = '' then
  begin
    DefaultNode := TomlGet(ARegistries, REGISTRY_DEFAULT_KEY);
    if TomlIsString(DefaultNode) then
      Alias := DefaultNode.ScalarText
    else if DefaultNode <> nil then
      RaiseUnsupportedDependency('[registries] default must name a declared '
        + 'registry alias')
    else
    begin
      Count := 0;
      for Pair in ARegistries.Children do
        if TomlIsTable(Pair.Value) then
        begin
          Inc(Count);
          Alias := Pair.Key;
        end;
      if Count <> 1 then
        RaiseUnsupportedDependency('dependency "' + ADependency.Name + '": '
          + ADependency.SrcOriginal + ' names no registry alias and [registries] '
          + 'declares ' + IntToStr(Count) + ' registries without a default; '
          + 'write registry:<alias>/' + ADependency.Name
          + ' or set [registries] default');
    end;
  end;
  Entry := TomlGet(ARegistries, Alias);
  if (Alias = REGISTRY_DEFAULT_KEY) or not TomlIsTable(Entry) then
    RaiseUnsupportedDependency('dependency "' + ADependency.Name + '": '
      + 'registry alias "' + Alias + '" is not declared under [registries]');
  Result := TomlStr(Entry, 'identity', '');
  if Result = '' then
    RaiseUnsupportedDependency('dependency "' + ADependency.Name + '": '
      + '[registries.' + Alias + '] must declare identity explicitly; a '
      + 'published record names its dependency''s origin identity, and there '
      + 'is no advertised identity at publish time');
  if not RegistryURIIsCanonical(Result, True) or (Pos('://[', Result) > 0) then
    RaiseUnsupportedDependency('dependency "' + ADependency.Name + '": '
      + '[registries.' + Alias + '] identity "' + Result + '" is not a '
      + 'canonical https registry URI (plain http only for localhost; no '
      + 'IPv6 literal)');
end;

{ ADR-0051 decision 10: [dependencies] as record dependencies. Entries are
  read with the manifest's own dependency parser, so the key, alias,
  package-name, and version rules are the ones consumers apply. }
function MapPublicationDependencies(ARoot: TTOMLNode;
  const APackageName: string): TLWPTRegistryDependencyArray;
var
  Dependencies, Node: TTOMLNode;
  Pair: TTOMLNodeMap.TKeyValuePair;
  Dependency: TDependency;
  Source, Suggestion: string;
  n: Integer;
begin
  Result := nil;
  Dependencies := TomlGet(ARoot, 'dependencies');
  if Dependencies = nil then Exit;
  if not TomlIsTable(Dependencies) then
    RaiseUnsupportedDependency('[dependencies] must be a table');
  for Pair in Dependencies.Children do
  begin
    Node := Pair.Value;
    if TomlIsString(Node) then
      Source := Node.ScalarText
    else if TomlIsTable(Node) then
      Source := TomlStr(Node, 'source', '')
    else
      RaiseUnsupportedDependency('dependency "' + Pair.Key + '" must be a '
        + 'string or an inline table');
    if Copy(Source, 1, Length(REGISTRY_SOURCE_PREFIX) + 1)
       <> REGISTRY_SOURCE_PREFIX + ':' then
      RaiseUnsupportedDependency('dependency "' + Pair.Key + '" is not a '
        + REGISTRY_SOURCE_PREFIX + ': source; a published package may depend '
        + 'only on registry packages, because its record carries only an '
        + 'origin, a name, and a version constraint');
    if TomlIsTable(Node)
       and ((TomlGet(Node, 'include') <> nil) or (TomlGet(Node, 'exclude') <> nil)) then
      RaiseUnsupportedDependency('dependency "' + Pair.Key + '" declares '
        + 'include or exclude; a protocol 1 record dependency cannot carry '
        + 'extraction filters, so consumers would install it unfiltered');
    Dependency := Default(TDependency);
    Dependency.Name := Pair.Key;
    try
      if TomlIsString(Node) then
        ParseBareDepString(Source, nil, Dependency)
      else
        ParseTableDep(Node, nil, Dependency);
    except
      on E: EManifestError do
        RaiseUnsupportedDependency(E.Message);
    end;
    { Refused on every origin: on its own origin it is a cycle through one
      identity, and on another it is a second package with this name,
      which no graph can hold (one package per name). }
    if Dependency.SrcLocator = APackageName then
      RaiseUnsupportedDependency('dependency "' + Pair.Key + '" names this '
        + 'package itself; a package cannot depend on its own name');
    if Dependency.VersionSpec = '' then
      RaiseUnsupportedDependency('dependency "' + Pair.Key + '" has no version '
        + 'constraint; a record dependency needs one, for example ^1.0.0');
    if not RegistryConstraintIsCanonical(Dependency.VersionSpec) then
    begin
      Suggestion := CanonicalConstraintSuggestion(Dependency.VersionSpec);
      if Suggestion <> '' then
        RaiseUnsupportedDependency('dependency "' + Pair.Key + '": constraint "'
          + Dependency.VersionSpec + '" is not in the protocol''s canonical '
          + 'grammar; write "' + Suggestion + '"')
      else
        RaiseUnsupportedDependency('dependency "' + Pair.Key + '": constraint "'
          + Dependency.VersionSpec + '" is not in the protocol''s canonical '
          + 'grammar: an exact version, ^ or ~ before a full version, '
          + 'comparators such as ">=1.0.0 <2.0.0", or alternatives joined '
          + 'by " || "');
    end;
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Origin := PublicationDependencyOrigin(TomlGet(ARoot, 'registries'),
      Dependency);
    Result[n].Name := Dependency.SrcLocator;
    Result[n].Version := Dependency.VersionSpec;
  end;
end;

{ ---------------------------------------------------------------------------
  Manifest inspection
  --------------------------------------------------------------------------- }

function InspectPublicationManifest(
  const AContent: TBytes): TLWPTPublicationManifest;
begin
  Result := InspectPublicationManifest(AContent, DefaultArchiveLimits);
end;

function InspectPublicationManifest(const AContent: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest;
var
  Parser: TTOMLParser;
  Root, PackageNode, NameNode, VersionNode: TTOMLNode;
  Text: UTF8String;
begin
  Result := Default(TLWPTPublicationManifest);
  RequireManifestSize(Length(AContent), ALimits);
  SetLength(Text, Length(AContent));
  if Length(AContent) > 0 then Move(AContent[0], Text[1], Length(AContent));
  Root := nil;
  Parser := TTOMLParser.Create;
  try
    Parser.MaximumNodes := ALimits.MaximumManifestNodes;
    try
      Root := Parser.ParseDocument(Text);
    except
      on E: ETOMLLimitError do
        raise ELWPTArchiveError.CreateStable(ARCHIVE_LIMIT_EXCEEDED,
          PUBLICATION_MANIFEST_NAME + ' exceeds its parse budget: '
          + E.Message);
      on E: ETOMLParseError do
        raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID,
          PUBLICATION_MANIFEST_NAME + ' does not parse: ' + E.Message);
    end;
  finally
    Parser.Free;
  end;
  try
    PackageNode := TomlGet(Root, 'package');
    NameNode := nil;
    VersionNode := nil;
    if TomlIsTable(PackageNode) then
    begin
      NameNode := TomlGet(PackageNode, 'name');
      VersionNode := TomlGet(PackageNode, 'version');
    end;
    if not TomlIsString(NameNode)
       or not RegistryPackageNameIsCanonical(NameNode.ScalarText)
       or not ValidRegistryPackageName(NameNode.ScalarText) then
      raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID_PACKAGE_NAME,
        PUBLICATION_MANIFEST_NAME + ' [package] name is missing or does not '
        + 'match [a-z0-9][a-z0-9_-]{0,127}, the package names consumers can '
        + 'install');
    if not TomlIsString(VersionNode)
       or not RegistryVersionIsCanonical(VersionNode.ScalarText) then
      raise ELWPTArchiveError.CreateStable(ARCHIVE_INVALID_VERSION,
        PUBLICATION_MANIFEST_NAME + ' [package] version is missing or not '
        + 'canonical SemVer 2.0.0');
    Result.Name := NameNode.ScalarText;
    Result.Version := VersionNode.ScalarText;
    Result.Dependencies := MapPublicationDependencies(Root, Result.Name);
  finally
    Root.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Manifest aliases
  --------------------------------------------------------------------------- }

type
  TManifestPathKind = (mpkNone, mpkExact, mpkAlias);

function AsciiFold(const APath: string): string;
var
  i: Integer;
begin
  Result := APath;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then
      Result[i] := Chr(Ord(Result[i]) + 32);
end;

{ Whether a path relative to the package root can name the root lwpt.toml.
  Extraction expands the name, so '.' and empty components vanish
  ('./lwpt.toml' is exact). A case-insensitive Windows or macOS file system
  also equates ASCII case, and Windows equates a trailing '.' or ' ', an
  NTFS stream suffix (':...'), and an 8.3 short name (PROGRAM_NAME is
  short enough to be its own 8.3 stem, so that is PROGRAM_NAME + '~').
  Any of those is an alias: on some platform it can replace, or be
  replaced by, the manifest that was inspected. }
function ClassifyManifestPath(const ARelPath: string): TManifestPathKind;
var
  Parts: TStringArray;
  Kept, Folded: string;
  Count, i, Colon: Integer;
begin
  Parts := StringReplace(ARelPath, '\', '/', [rfReplaceAll]).Split(['/']);
  Count := 0;
  Kept := '';
  for i := 0 to High(Parts) do
    if (Parts[i] <> '') and (Parts[i] <> '.') then
    begin
      Inc(Count);
      Kept := Parts[i];
    end;
  if Count <> 1 then Exit(mpkNone);
  if Kept = PUBLICATION_MANIFEST_NAME then Exit(mpkExact);
  Folded := AsciiFold(Kept);
  Colon := Pos(':', Folded);
  if Colon > 0 then Folded := System.Copy(Folded, 1, Colon - 1);
  while (Folded <> '') and (Folded[Length(Folded)] in ['.', ' ']) do
    SetLength(Folded, Length(Folded) - 1);
  if (Folded = PUBLICATION_MANIFEST_NAME)
     or (System.Copy(Folded, 1, Length(PROGRAM_NAME) + 1)
       = PROGRAM_NAME + '~') then
    Result := mpkAlias
  else
    Result := mpkNone;
end;

{ ---------------------------------------------------------------------------
  tar.gz scan
  --------------------------------------------------------------------------- }

type
  TTarScanState = (tssHeader, tssLongName, tssData, tssEnd);

  { Receives the decoded tar stream from GunzipStream and checks each entry
    as the installer's ReadTarEntry would read it. }
  TLWPTTarScanner = class(TStream)
  private
    FLimits: TLWPTArchiveLimits;
    FExpanded: Int64;
    FState: TTarScanState;
    FHeader: array[0..511] of Byte;
    FHeaderCount: Integer;
    FZeroBlocks: Integer;
    FRemaining: Int64;
    FLongName: RawByteString;
    FPendingLongName: string;
    FHasPendingLongName: Boolean;
    FCapture: Boolean;
    FCaptureRemaining: Int64;
    FManifest: TBytesStream;
    FManifestSeen: Boolean;
    FTop: string;
    FHasTop: Boolean;
    procedure HeaderComplete;
    procedure CheckEntry(const AName: string; const ATypeFlag: Byte;
      const ALinkName: string; const ASize: Int64);
    procedure EnterData(const ASize: Int64);
  public
    constructor Create(const ALimits: TLWPTArchiveLimits);
    destructor Destroy; override;
    function Write(const ABuffer; ACount: Longint): Longint; override;
    function Read(var ABuffer; ACount: Longint): Longint; override;
    procedure Finish;
  end;

constructor TLWPTTarScanner.Create(const ALimits: TLWPTArchiveLimits);
begin
  inherited Create;
  FLimits := ALimits;
  FManifest := TBytesStream.Create(nil);
end;

destructor TLWPTTarScanner.Destroy;
begin
  FManifest.Free;
  inherited Destroy;
end;

function TLWPTTarScanner.Read(var ABuffer; ACount: Longint): Longint;
begin
  Result := 0;
end;

procedure CheckComponents(const ARelName: string);
var
  Parts: TStringArray;
  i: Integer;
begin
  Parts := StringReplace(ARelName, '\', '/', [rfReplaceAll]).Split(['/']);
  for i := 0 to High(Parts) do
    if Length(Parts[i]) > ARCHIVE_NAME_COMPONENT_LIMIT then
      RaiseInvalid(Format('entry "%s" has a %d-byte name component; the '
        + 'limit is %d', [ARelName, Length(Parts[i]),
        ARCHIVE_NAME_COMPONENT_LIMIT]));
end;

procedure TLWPTTarScanner.CheckEntry(const AName: string;
  const ATypeFlag: Byte; const ALinkName: string; const ASize: Int64);
var
  Normalized, Top, RelName, Alias: string;
  Slash: Integer;
  TypeChar: Char;
begin
  TypeChar := Chr(ATypeFlag);
  Normalized := StringReplace(AName, '\', '/', [rfReplaceAll]);
  Slash := Pos('/', Normalized);
  { pax headers at the top level ('g' is what git archive writes) are
    metadata the installer never extracts. }
  if (Slash = 0) and (TypeChar in ['g', 'x']) then Exit;
  if Slash > 0 then
    Top := System.Copy(Normalized, 1, Slash - 1)
  else
    Top := Normalized;
  if Top = '' then
    RaiseInvalid(Format('entry "%s" is an absolute path', [AName]));
  if not FHasTop then
  begin
    FTop := Top;
    FHasTop := True;
  end
  else if Top <> FTop then
    RaiseInvalid(Format('archive must have exactly one top-level directory; '
      + 'found "%s" and "%s"', [FTop, Top]));
  if (Slash = 0) and (TypeChar <> '5') then
    RaiseInvalid(Format('entry "%s" is not inside the top-level directory',
      [AName]));
  RelName := StripFirstComponent(AName);
  if RelName = '' then Exit;
  if LooksLikeAbsoluteArchivePath(RelName)
     or ArchiveRelPathHasParentSegment(RelName) then
    RaiseInvalid(Format('entry path escapes the extraction root: %s',
      [AName]));
  CheckComponents(RelName);
  Alias := ArchivePathPlatformAlias(RelName);
  if Alias <> '' then
    RaiseInvalid(Format('entry "%s" %s', [AName, Alias]));
  if TypeChar in ['1', '2'] then
  begin
    if ArchiveLinkTargetEscapesRoot(RelName, ALinkName) then
      RaiseInvalid(Format('link target escapes the extraction root: %s -> %s',
        [AName, ALinkName]));
  end;
  { Exactly one entry may reach the root manifest's destination, and it
    must be a regular file: any second spelling of it would replace the
    inspected identity when installed. }
  case ClassifyManifestPath(RelName) of
    mpkAlias:
      RaiseInvalid(Format('entry "%s" aliases %s', [AName,
        PUBLICATION_MANIFEST_NAME]));
    mpkExact:
      begin
        if not (TypeChar in ['0', #0]) then
          RaiseInvalid(PUBLICATION_MANIFEST_NAME + ' is not a regular file');
        if FManifestSeen then
          RaiseInvalid(PUBLICATION_MANIFEST_NAME + ' appears more than once');
        RequireManifestSize(ASize, FLimits);
        FManifestSeen := True;
        FCapture := True;
      end;
  end;
end;

procedure TLWPTTarScanner.EnterData(const ASize: Int64);
begin
  { The payload is followed by padding to the next 512-byte block. }
  FRemaining := ASize + (512 - ASize mod 512) mod 512;
  FCaptureRemaining := ASize;
  if FRemaining > 0 then FState := tssData
  else FCapture := False;
end;

procedure TLWPTTarScanner.HeaderComplete;
var
  i: Integer;
  AllZero: Boolean;
  Name, Prefix, LinkName: string;
  Size: Int64;
  TypeFlag: Byte;
begin
  FHeaderCount := 0;
  AllZero := True;
  for i := 0 to 511 do
    if FHeader[i] <> 0 then
    begin
      AllZero := False;
      Break;
    end;
  if AllZero then
  begin
    Inc(FZeroBlocks);
    if FZeroBlocks >= 2 then FState := tssEnd;
    Exit;
  end;
  FZeroBlocks := 0;
  Name := TarStr(FHeader, 0, 100);
  Size := TarOctal(FHeader, 124, 12);
  TypeFlag := FHeader[156];
  LinkName := TarStr(FHeader, 157, 100);
  Prefix := TarStr(FHeader, 345, 155);
  if (TypeFlag = Ord('L')) or (TypeFlag = Ord('K')) then
  begin
    if Size > MAXIMUM_TAR_LONG_NAME_BYTES then
      RaiseInvalid(Format('GNU long name of %d bytes exceeds %d',
        [Size, MAXIMUM_TAR_LONG_NAME_BYTES]));
    FLongName := '';
    FRemaining := Size;
    if Size > 0 then
      FState := tssLongName
    else
    begin
      FPendingLongName := '';
      FHasPendingLongName := True;
      EnterData(0);
    end;
    Exit;
  end;
  if FHasPendingLongName and (FPendingLongName <> '') then
    Name := FPendingLongName
  else if Prefix <> '' then
    Name := Prefix + '/' + Name;
  FPendingLongName := '';
  FHasPendingLongName := False;
  CheckEntry(Name, TypeFlag, LinkName, Size);
  EnterData(Size);
end;

function TLWPTTarScanner.Write(const ABuffer; ACount: Longint): Longint;
var
  Source: PByte;
  Left, Take: Integer;
  Pad: Int64;
begin
  Result := ACount;
  if ACount <= 0 then Exit;
  if FExpanded + ACount > FLimits.MaximumExpandedBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'tar.gz expands past %d bytes', [FLimits.MaximumExpandedBytes]);
  Inc(FExpanded, ACount);
  Source := @ABuffer;
  Left := ACount;
  while Left > 0 do
    case FState of
      tssEnd:
        Left := 0;
      tssHeader:
        begin
          Take := 512 - FHeaderCount;
          if Take > Left then Take := Left;
          Move(Source^, FHeader[FHeaderCount], Take);
          Inc(FHeaderCount, Take);
          Inc(Source, Take);
          Dec(Left, Take);
          if FHeaderCount = 512 then HeaderComplete;
        end;
      tssLongName:
        begin
          Take := Left;
          if Take > FRemaining then Take := Integer(FRemaining);
          SetLength(FLongName, Length(FLongName) + Take);
          Move(Source^, FLongName[Length(FLongName) - Take + 1], Take);
          Inc(Source, Take);
          Dec(Left, Take);
          Dec(FRemaining, Take);
          if FRemaining = 0 then
          begin
            { The installer's folding: NULs removed, then trimmed. }
            FPendingLongName := Trim(StringReplace(FLongName, #0, '',
              [rfReplaceAll]));
            FHasPendingLongName := True;
            Pad := (512 - Length(FLongName) mod 512) mod 512;
            FState := tssHeader;
            if Pad > 0 then
            begin
              FRemaining := Pad;
              FState := tssData;
            end;
          end;
        end;
      tssData:
        begin
          Take := Left;
          if Take > FRemaining then Take := Integer(FRemaining);
          if FCapture and (FCaptureRemaining > 0) then
          begin
            if FCaptureRemaining < Take then
              FManifest.WriteBuffer(Source^, Integer(FCaptureRemaining))
            else
              FManifest.WriteBuffer(Source^, Take);
            Dec(FCaptureRemaining, Take);
            if FCaptureRemaining < 0 then FCaptureRemaining := 0;
          end;
          Inc(Source, Take);
          Dec(Left, Take);
          Dec(FRemaining, Take);
          if FRemaining = 0 then
          begin
            FState := tssHeader;
            FCapture := False;
          end;
        end;
    end;
end;

procedure TLWPTTarScanner.Finish;
begin
  if (FState = tssLongName) or (FState = tssData)
     or ((FState = tssHeader) and (FHeaderCount <> 0)) then
    RaiseInvalid('tar stream ends inside an entry');
  if not FHasTop or not FManifestSeen then
    RaiseInvalid('archive has no ' + PUBLICATION_MANIFEST_NAME
      + ' in its single top-level directory');
end;

function ScanTarGzipArchive(const AInput: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest;
var
  Source: TBytesStream;
  Scanner: TLWPTTarScanner;
begin
  if Length(AInput) > ALimits.MaximumInputBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'tar.gz input is %d bytes; the limit is %d',
      [Int64(Length(AInput)), ALimits.MaximumInputBytes]);
  if DetectArchiveKind(AInput) <> akTarGzip then
    raise ELWPTArchiveError.CreateStable(ARCHIVE_UNSUPPORTED,
      'input is not a gzip stream');
  Source := TBytesStream.Create(AInput);
  Scanner := TLWPTTarScanner.Create(ALimits);
  try
    try
      GunzipStream(Source, Scanner);
    except
      on E: EExtractError do
        RaiseInvalid(E.Message);
    end;
    Scanner.Finish;
    Result := InspectPublicationManifest(System.Copy(Scanner.FManifest.Bytes,
      0, Scanner.FManifest.Size), ALimits);
  finally
    Scanner.Free;
    Source.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  zip normalization
  --------------------------------------------------------------------------- }

type
  TTreeKind = (tkImpliedDirectory, tkExplicitDirectory, tkFile);

  { One path of the normalized tree, relative to the package root. Entry is
    the zip entry index, or -1 for an implied directory. }
  TTreeItem = record
    Path: string;
    Kind: TTreeKind;
    Entry: Integer;
    Executable: Boolean;
    TarPath: string;
  end;
  TTreeItemArray = array of TTreeItem;

  { Forwards decoded bytes to the tar writer's current file. }
  TLWPTWriterSink = class(TStream)
  private
    FWriter: TLWPTCanonicalTarGzipWriter;
  public
    constructor Create(const AWriter: TLWPTCanonicalTarGzipWriter);
    function Write(const ABuffer; ACount: Longint): Longint; override;
    function Read(var ABuffer; ACount: Longint): Longint; override;
  end;

  { Decodes and discards, so a directory entry's payload is still checked. }
  TLWPTDiscardSink = class(TStream)
  public
    function Write(const ABuffer; ACount: Longint): Longint; override;
    function Read(var ABuffer; ACount: Longint): Longint; override;
  end;

  TLWPTZipNormalizer = class
  private
    FLimits: TLWPTArchiveLimits;
    FZip: TLWPTZipArchive;
    FPaths: TArray<string>;
    FDirectory: TArray<Boolean>;
    FExecutable: TArray<Boolean>;
    FItems: TTreeItemArray;
    FItemCount: Integer;
    FTreePathBytes: Int64;
    FIndex: TDictionary<string, Integer>;
    FFolded: TDictionary<string, string>;
    FRootEntries: TList<Integer>;
    FManifestEntry: Integer;
    FManifest: TLWPTPublicationManifest;
    procedure CheckEntryNames;
    procedure MapPackageRoot;
    procedure AddTreePath(const APath: string; const AKind: TTreeKind;
      const AEntry: Integer; const AExecutable: Boolean);
    procedure BuildTree;
    procedure ReadManifest;
    procedure AssignTarPaths;
  public
    constructor Create(const AInput: TBytes;
      const ALimits: TLWPTArchiveLimits);
    destructor Destroy; override;
    { Validates everything but the payloads other than lwpt.toml. }
    procedure Load;
    { Decodes every entry into the canonical tar.gz. }
    procedure Write(const ATarget: TStream);
    property Manifest: TLWPTPublicationManifest read FManifest;
  end;

constructor TLWPTWriterSink.Create(const AWriter: TLWPTCanonicalTarGzipWriter);
begin
  inherited Create;
  FWriter := AWriter;
end;

function TLWPTWriterSink.Write(const ABuffer; ACount: Longint): Longint;
begin
  FWriter.WriteFileData(ABuffer, ACount);
  Result := ACount;
end;

function TLWPTWriterSink.Read(var ABuffer; ACount: Longint): Longint;
begin
  Result := 0;
end;

function TLWPTDiscardSink.Write(const ABuffer; ACount: Longint): Longint;
begin
  Result := ACount;
end;

function TLWPTDiscardSink.Read(var ABuffer; ACount: Longint): Longint;
begin
  Result := 0;
end;

{ The entry rules for one '/'-separated relative path: non-empty, at most
  AMaximumBytes long (checked first, so an absurd name is refused before it
  is split), not absolute or drive-relative, and free of '..', '.', empty,
  and over-long components. They run on every zip name and again on every
  path below the package root, because removing the top-level directory
  can expose a new first component such as 'C:'. }
procedure CheckRelativePath(const APath, AWhere: string;
  const AMaximumBytes: Integer);
var
  Parts: TStringArray;
  k: Integer;
  Alias: string;
begin
  if APath = '' then
    RaiseInvalid(AWhere + ' has an empty path');
  if Length(APath) > AMaximumBytes then
    RaiseInvalid(Format('%s is %d bytes, longer than any path ustar can hold',
      [AWhere, Length(APath)]));
  if LooksLikeAbsoluteArchivePath(APath) then
    RaiseInvalid(AWhere + ' is an absolute path');
  if ArchiveRelPathHasParentSegment(APath) then
    RaiseInvalid(AWhere + ' has a ".." component');
  Parts := APath.Split(['/']);
  for k := 0 to High(Parts) do
  begin
    if (Parts[k] = '') or (Parts[k] = '.') then
      RaiseInvalid(AWhere + ' has an empty or "." component');
    if Length(Parts[k]) > ARCHIVE_NAME_COMPONENT_LIMIT then
      RaiseInvalid(Format('%s has a %d-byte component; the limit is %d',
        [AWhere, Length(Parts[k]), ARCHIVE_NAME_COMPONENT_LIMIT]));
  end;
  Alias := ArchivePathPlatformAlias(APath);
  if Alias <> '' then
    RaiseInvalid(AWhere + ' ' + Alias);
end;

const
  { A zip name may carry one top-level directory component and '/' above
    its package-relative path. }
  MAXIMUM_ZIP_NAME_BYTES = ARCHIVE_NAME_COMPONENT_LIMIT + 1
    + USTAR_MAXIMUM_PATH_BYTES;
  { Below the root '<name>-<version>/' (at least two bytes) of a ustar
    path. }
  MAXIMUM_PACKAGE_PATH_BYTES = USTAR_MAXIMUM_PATH_BYTES - 2;

function FirstComponent(const APath: string): string;
var
  Slash: Integer;
begin
  Slash := Pos('/', APath);
  if Slash = 0 then
    Result := APath
  else
    Result := System.Copy(APath, 1, Slash - 1);
end;

constructor TLWPTZipNormalizer.Create(const AInput: TBytes;
  const ALimits: TLWPTArchiveLimits);
begin
  inherited Create;
  FLimits := ALimits;
  FZip := TLWPTZipArchive.Create(AInput, ALimits);
  FIndex := TDictionary<string, Integer>.Create;
  FFolded := TDictionary<string, string>.Create;
  FRootEntries := TList<Integer>.Create;
  FManifestEntry := -1;
end;

destructor TLWPTZipNormalizer.Destroy;
begin
  FRootEntries.Free;
  FFolded.Free;
  FIndex.Free;
  FZip.Free;
  inherited Destroy;
end;

{ Entry rules: each name on its own. }
procedure TLWPTZipNormalizer.CheckEntryNames;
const
  UNIX_TYPE_MASK = $F000;
  UNIX_REGULAR = $8000;
  UNIX_DIRECTORY = $4000;
  UNIX_SYMLINK = $A000;
  UNIX_EXECUTE_BITS = &111;
  MSDOS_VOLUME_LABEL = $08;
  MSDOS_DIRECTORY = $10;
var
  i: Integer;
  E: TLWPTZipEntry;
  Name, Body, Where, Kind: string;
  IsDirectory: Boolean;
  UnixMode: Cardinal;
begin
  SetLength(FPaths, FZip.Count);
  SetLength(FDirectory, FZip.Count);
  SetLength(FExecutable, FZip.Count);
  for i := 0 to FZip.Count - 1 do
  begin
    E := FZip.Entries[i];
    Where := Format('zip entry %d', [i]);
    if not IsStrictUTF8WithoutControls(E.Name) then
      RaiseInvalid(Where + ' name is not strict UTF-8 or holds a control '
        + 'character');
    Name := StringReplace(E.Name, '\', '/', [rfReplaceAll]);
    Where := Format('zip entry "%s"', [Name]);
    IsDirectory := (Name <> '') and (Name[Length(Name)] = '/');
    if IsDirectory then
      Body := System.Copy(Name, 1, Length(Name) - 1)
    else
      Body := Name;
    if Length(Name) > MAXIMUM_ZIP_NAME_BYTES + 1 then
      Where := Format('zip entry %d', [i]);
    CheckRelativePath(Body, Where, MAXIMUM_ZIP_NAME_BYTES);
    if IsDirectory and ((E.UncompressedSize <> 0) or (E.Crc32 <> 0)) then
      RaiseInvalid(Where + ' is a directory with content');
    case E.HostSystem of
      ZIP_HOST_UNIX:
        begin
          UnixMode := E.ExternalAttributes shr 16;
          case UnixMode and UNIX_TYPE_MASK of
            0, UNIX_REGULAR, UNIX_DIRECTORY:
              ;
            UNIX_SYMLINK:
              RaiseInvalid(Where + ' is a symbolic link');
          else
            begin
              case UnixMode and UNIX_TYPE_MASK of
                $1000: Kind := 'a FIFO';
                $2000: Kind := 'a character device';
                $6000: Kind := 'a block device';
                $C000: Kind := 'a socket';
              else
                Kind := 'not a regular file or directory';
              end;
              RaiseInvalid(Where + ' is ' + Kind);
            end;
          end;
          FExecutable[i] := not IsDirectory
            and ((UnixMode and UNIX_EXECUTE_BITS) <> 0);
        end;
      ZIP_HOST_MSDOS:
        begin
          if (E.ExternalAttributes and MSDOS_VOLUME_LABEL) <> 0 then
            RaiseInvalid(Where + ' is a volume label');
          if ((E.ExternalAttributes and MSDOS_DIRECTORY) <> 0)
             <> IsDirectory then
            RaiseInvalid(Where + ' directory attribute disagrees with its '
              + 'trailing slash');
        end;
    end;
    FPaths[i] := Body;
    FDirectory[i] := IsDirectory;
  end;
end;

{ The package root: the zip root when it holds lwpt.toml, otherwise the
  single top-level directory, which must hold it. Paths become relative to
  the root; an explicit entry for the root itself maps to ''. }
procedure TLWPTZipNormalizer.MapPackageRoot;
var
  i: Integer;
  Top: string;
  RootHasManifest: Boolean;
begin
  RootHasManifest := False;
  for i := 0 to High(FPaths) do
    if not FDirectory[i] and (FPaths[i] = PUBLICATION_MANIFEST_NAME) then
      RootHasManifest := True;
  if RootHasManifest then
  begin
    for i := 0 to High(FPaths) do
      CheckRelativePath(FPaths[i], Format('zip entry "%s"', [FPaths[i]]),
        MAXIMUM_PACKAGE_PATH_BYTES);
    Exit;
  end;
  if Length(FPaths) = 0 then
    RaiseInvalid('zip has no ' + PUBLICATION_MANIFEST_NAME);
  Top := FirstComponent(FPaths[0]);
  for i := 0 to High(FPaths) do
    if (FirstComponent(FPaths[i]) <> Top)
       or ((FPaths[i] = Top) and not FDirectory[i]) then
      RaiseInvalid('zip must hold ' + PUBLICATION_MANIFEST_NAME + ' at its '
        + 'root or in its single top-level directory');
  for i := 0 to High(FPaths) do
    if FPaths[i] = Top then
      FPaths[i] := ''
    else
    begin
      FPaths[i] := System.Copy(FPaths[i], Length(Top) + 2, MaxInt);
      CheckRelativePath(FPaths[i], Format('zip entry "%s/%s"',
        [Top, FPaths[i]]), MAXIMUM_PACKAGE_PATH_BYTES);
    end;
end;

procedure TLWPTZipNormalizer.AddTreePath(const APath: string;
  const AKind: TTreeKind; const AEntry: Integer; const AExecutable: Boolean);
var
  Existing: Integer;
  Folded, Other: string;
  Item: TTreeItem;
begin
  if FIndex.TryGetValue(APath, Existing) then
  begin
    case FItems[Existing].Kind of
      tkFile:
        if AKind = tkFile then
          RaiseInvalid(Format('zip holds "%s" more than once', [APath]))
        else if AKind = tkImpliedDirectory then
          RaiseInvalid(Format('zip file "%s" is an ancestor of another '
            + 'entry', [APath]))
        else
          RaiseInvalid(Format('zip path "%s" is both a file and a directory',
            [APath]));
      tkExplicitDirectory:
        if AKind = tkFile then
          RaiseInvalid(Format('zip path "%s" is both a file and a directory',
            [APath]))
        else if AKind = tkExplicitDirectory then
          RaiseInvalid(Format('zip holds "%s/" more than once', [APath]));
      tkImpliedDirectory:
        if AKind = tkFile then
          RaiseInvalid(Format('zip file "%s" is an ancestor of another '
            + 'entry', [APath]))
        else if AKind = tkExplicitDirectory then
        begin
          FItems[Existing].Kind := tkExplicitDirectory;
          FItems[Existing].Entry := AEntry;
        end;
    end;
    Exit;
  end;
  { Every distinct path is held twice (exact and folded), so their bytes are
    bounded before either copy is made. }
  if FTreePathBytes + Length(APath) > FLimits.MaximumTreePathBytes then
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'zip tree paths, with implied directories, pass %d bytes',
      [FLimits.MaximumTreePathBytes]);
  Inc(FTreePathBytes, Length(APath));
  if ClassifyManifestPath(APath) = mpkAlias then
    RaiseInvalid(Format('zip path "%s" aliases %s',
      [APath, PUBLICATION_MANIFEST_NAME]));
  Folded := AsciiFold(APath);
  if FFolded.TryGetValue(Folded, Other) then
    RaiseInvalid(Format('zip paths "%s" and "%s" differ only in ASCII case',
      [Other, APath]));
  FFolded.Add(Folded, APath);
  Item := Default(TTreeItem);
  Item.Path := APath;
  Item.Kind := AKind;
  Item.Entry := AEntry;
  Item.Executable := AExecutable;
  if FItemCount = Length(FItems) then
    SetLength(FItems, 2 * FItemCount + 16);
  FItems[FItemCount] := Item;
  FIndex.Add(APath, FItemCount);
  Inc(FItemCount);
end;

function ParentPath(const APath: string): string;
var
  i: Integer;
begin
  for i := Length(APath) downto 1 do
    if APath[i] = '/' then Exit(System.Copy(APath, 1, i - 1));
  Result := '';
end;

{ Namespace rules over the whole normalized tree, with every implied
  parent. Each entry is added with all of its ancestors, so a file that is
  an ancestor, or a file beside a directory, is caught whichever order the
  zip lists them in. }
procedure TLWPTZipNormalizer.BuildTree;
var
  i: Integer;
  Path: string;
  Kind: TTreeKind;
begin
  for i := 0 to High(FPaths) do
  begin
    if FPaths[i] = '' then
    begin
      if FRootEntries.Count > 0 then
        RaiseInvalid('zip holds its top-level directory more than once');
      FRootEntries.Add(i);
      Continue;
    end;
    if FDirectory[i] then
      Kind := tkExplicitDirectory
    else
      Kind := tkFile;
    AddTreePath(FPaths[i], Kind, i, FExecutable[i]);
    if (Kind = tkFile) and (FPaths[i] = PUBLICATION_MANIFEST_NAME) then
      FManifestEntry := i;
    Path := ParentPath(FPaths[i]);
    while Path <> '' do
    begin
      AddTreePath(Path, tkImpliedDirectory, -1, False);
      Path := ParentPath(Path);
    end;
  end;
  SetLength(FItems, FItemCount);
  if FManifestEntry < 0 then
    RaiseInvalid('zip has no ' + PUBLICATION_MANIFEST_NAME
      + ' at its package root');
end;

procedure TLWPTZipNormalizer.ReadManifest;
var
  Target: TBytesStream;
  Content: TBytes;
begin
  { Bounded by its declared size before anything is decoded; decoding then
    enforces the declared size. }
  RequireManifestSize(FZip.Entries[FManifestEntry].UncompressedSize,
    FLimits);
  Target := TBytesStream.Create(nil);
  try
    FZip.DecodeEntry(FManifestEntry, Target);
    Content := System.Copy(Target.Bytes, 0, Target.Size);
  finally
    Target.Free;
  end;
  FManifest := InspectPublicationManifest(Content, FLimits);
end;

procedure TLWPTZipNormalizer.AssignTarPaths;
var
  Root, Prefix, Name: string;
  i: Integer;
begin
  Root := FManifest.Name + '-' + FManifest.Version;
  if not SplitUstarPath(Root + '/', Prefix, Name) then
    RaiseInvalid(Format('path "%s/" does not fit ustar', [Root]));
  for i := 0 to High(FItems) do
  begin
    FItems[i].TarPath := Root + '/' + FItems[i].Path;
    if FItems[i].Kind <> tkFile then
      FItems[i].TarPath := FItems[i].TarPath + '/';
    if not SplitUstarPath(FItems[i].TarPath, Prefix, Name) then
      RaiseInvalid(Format('path "%s" does not fit ustar''s 155-byte prefix '
        + 'and 100-byte name', [FItems[i].TarPath]));
  end;
end;

procedure TLWPTZipNormalizer.Load;
begin
  CheckEntryNames;
  MapPackageRoot;
  BuildTree;
  ReadManifest;
  AssignTarPaths;
end;

procedure SortItems(var AItems: TTreeItemArray);
var
  Scratch: TTreeItemArray;

  procedure MergeSort(const ALow, AHigh: Integer);
  var
    Middle, Left, Right, Target: Integer;
  begin
    if ALow >= AHigh then Exit;
    Middle := ALow + (AHigh - ALow) div 2;
    MergeSort(ALow, Middle);
    MergeSort(Middle + 1, AHigh);
    Left := ALow;
    Right := Middle + 1;
    Target := ALow;
    while (Left <= Middle) and (Right <= AHigh) do
    begin
      if CompareTarPaths(AItems[Left].TarPath, AItems[Right].TarPath) <= 0
         then
      begin
        Scratch[Target] := AItems[Left];
        Inc(Left);
      end
      else
      begin
        Scratch[Target] := AItems[Right];
        Inc(Right);
      end;
      Inc(Target);
    end;
    while Left <= Middle do
    begin
      Scratch[Target] := AItems[Left];
      Inc(Left);
      Inc(Target);
    end;
    while Right <= AHigh do
    begin
      Scratch[Target] := AItems[Right];
      Inc(Right);
      Inc(Target);
    end;
    for Target := ALow to AHigh do
      AItems[Target] := Scratch[Target];
  end;

begin
  SetLength(Scratch, Length(AItems));
  MergeSort(0, High(AItems));
end;

procedure TLWPTZipNormalizer.Write(const ATarget: TStream);
var
  Writer: TLWPTCanonicalTarGzipWriter;
  Sink: TLWPTWriterSink;
  Discard: TLWPTDiscardSink;
  Items: TTreeItemArray;
  i: Integer;
  E: TLWPTZipEntry;
begin
  Items := System.Copy(FItems, 0, Length(FItems));
  SortItems(Items);
  Writer := TLWPTCanonicalTarGzipWriter.Create(ATarget,
    FLimits.MaximumOutputBytes);
  Sink := TLWPTWriterSink.Create(Writer);
  Discard := TLWPTDiscardSink.Create;
  try
    for i := 0 to FRootEntries.Count - 1 do
      FZip.DecodeEntry(FRootEntries[i], Discard);
    Writer.AddDirectory(FManifest.Name + '-' + FManifest.Version);
    for i := 0 to High(Items) do
    begin
      if Items[i].Kind = tkFile then
      begin
        E := FZip.Entries[Items[i].Entry];
        Writer.BeginFile(Items[i].TarPath, E.UncompressedSize,
          Items[i].Executable);
        FZip.DecodeEntry(Items[i].Entry, Sink);
        Writer.EndFile;
      end
      else
      begin
        if Items[i].Kind = tkExplicitDirectory then
          FZip.DecodeEntry(Items[i].Entry, Discard);
        Writer.AddDirectory(System.Copy(Items[i].TarPath, 1,
          Length(Items[i].TarPath) - 1));
      end;
    end;
    Writer.Finish;
  finally
    Discard.Free;
    Sink.Free;
    Writer.Free;
  end;
end;

function NormalizeZipArchive(const AInput: TBytes; const ATarget: TStream;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationManifest;
var
  Normalizer: TLWPTZipNormalizer;
begin
  Normalizer := TLWPTZipNormalizer.Create(AInput, ALimits);
  try
    Normalizer.Load;
    Normalizer.Write(ATarget);
    Result := Normalizer.Manifest;
  finally
    Normalizer.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Entry point
  --------------------------------------------------------------------------- }

function PreparePublicationArchive(
  const AInput: TBytes): TLWPTPublicationArchive;
begin
  Result := PreparePublicationArchive(AInput, DefaultArchiveLimits);
end;

function PreparePublicationArchive(const AInput: TBytes;
  const ALimits: TLWPTArchiveLimits): TLWPTPublicationArchive;
var
  Normalizer: TLWPTZipNormalizer;
  Output: TBytesStream;
begin
  Result := Default(TLWPTPublicationArchive);
  Result.Kind := DetectArchiveKind(AInput);
  if Result.Kind = akTarGzip then
  begin
    Result.Manifest := ScanTarGzipArchive(AInput, ALimits);
    Result.Archive := AInput;
    Exit;
  end;
  Normalizer := TLWPTZipNormalizer.Create(AInput, ALimits);
  try
    Normalizer.Load;
    Result.Manifest := Normalizer.Manifest;
    Output := TBytesStream.Create(nil);
    try
      Normalizer.Write(Output);
      Result.Archive := System.Copy(Output.Bytes, 0, Output.Size);
    finally
      Output.Free;
    end;
  finally
    Normalizer.Free;
  end;
end;

end.
