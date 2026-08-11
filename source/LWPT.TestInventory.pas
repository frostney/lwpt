{ LWPT.TestInventory — runtime registration inventory contract. }
unit LWPT.TestInventory;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils;

const
  TEST_INVENTORY_PATH = 'tests/test-inventory.tsv';
  TEST_INVENTORY_SCHEMA = 'lwpt-test-inventory-v1';
  TEST_INVENTORY_DOC_BEGIN = '<!-- lwpt:test-inventory-counts:begin -->';
  TEST_INVENTORY_DOC_END = '<!-- lwpt:test-inventory-counts:end -->';

type
  ELWPTTestInventoryError = class(Exception);

  TLWPTTestInventoryEntry = record
    Path: string;
    Tier: string;
    Platform: string;
    Suites: Integer;
    Cases: Integer;
  end;

  TLWPTTestInventory = class
  private
    FPlatforms: TStringList;
    FEntries: array of TLWPTTestInventoryEntry;
    function PlatformMatches(const APattern, AOS,
      AArchitecture: string): Boolean;
    function PlatformSpecificity(const APattern, AOS,
      AArchitecture: string): Integer;
    function PlatformLabel(const AIndexes: array of Integer): string;
    function CountDisplayForPath(const APath: string): string;
    function AggregateDisplay(const ATier: string): string;
    function ProgramCount(const ATier: string): Integer;
    function RenderAggregateBlock: string;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    function Resolve(const APath, AOS, AArchitecture: string;
      out ATier: string; out ASuites, ACases: Integer): Boolean;
    procedure ValidatePlatform(const AOS, AArchitecture: string);
    procedure ValidateEmptyDiscovery;
    function ContainsPath(const APath: string): Boolean;
    procedure Paths(const APaths: TStrings);
    procedure ValidateDocumentation(const APath: string);
    procedure WriteDocumentation(const APath: string);
  end;

implementation

uses
  StrUtils;

function CanonicalInventoryPath(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '/', [rfReplaceAll]);
  while Copy(Result, 1, 2) = './' do Delete(Result, 1, 2);
end;

function SingularPlural(const ACount: Integer; const ASingular,
  APlural: string): string;
begin
  if ACount = 1 then Result := ASingular else Result := APlural;
end;

constructor TLWPTTestInventory.Create(const APath: string);
var
  Fields, Lines: TStringList;
  Entry: TLWPTTestInventoryEntry;
  i, n: Integer;
  Line: string;
begin
  inherited Create;
  FPlatforms := TStringList.Create;
  FPlatforms.CaseSensitive := False;
  Fields := TStringList.Create;
  Lines := TStringList.Create;
  try
    if not FileExists(APath) then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory file not found: %s', [APath]);
    Lines.LoadFromFile(APath);
    if (Lines.Count = 0) or (Trim(Lines[0]) <> TEST_INVENTORY_SCHEMA) then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory "%s" must begin with %s',
        [APath, TEST_INVENTORY_SCHEMA]);
    Fields.StrictDelimiter := True;
    Fields.Delimiter := #9;
    for i := 1 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if (Line = '') or (Line[1] = '#') then Continue;
      Fields.DelimitedText := Lines[i];
      if (Fields.Count = 2) and (Fields[0] = 'platform') then
      begin
        if FPlatforms.IndexOf(Fields[1]) < 0 then FPlatforms.Add(Fields[1]);
        Continue;
      end;
      if (Fields.Count <> 6) or (Fields[0] <> 'program')
         or not TryStrToInt(Fields[4], Entry.Suites)
         or not TryStrToInt(Fields[5], Entry.Cases)
         or (Entry.Suites < 0) or (Entry.Cases < 0) then
        raise ELWPTTestInventoryError.CreateFmt(
          'invalid test inventory row %d in "%s"', [i + 1, APath]);
      Entry.Platform := Fields[1];
      Entry.Tier := Fields[2];
      Entry.Path := CanonicalInventoryPath(Fields[3]);
      if (Entry.Tier <> 'unit') and (Entry.Tier <> 'integration')
         and (Entry.Tier <> 'e2e') then
        raise ELWPTTestInventoryError.CreateFmt(
          'invalid test inventory tier "%s" on row %d',
          [Entry.Tier, i + 1]);
      n := Length(FEntries);
      SetLength(FEntries, n + 1);
      FEntries[n] := Entry;
    end;
    if FPlatforms.Count = 0 then
      raise ELWPTTestInventoryError.Create(
        'test inventory declares no verified platforms');
  finally
    Lines.Free;
    Fields.Free;
  end;
end;

destructor TLWPTTestInventory.Destroy;
begin
  FPlatforms.Free;
  inherited Destroy;
end;

function TLWPTTestInventory.PlatformMatches(const APattern, AOS,
  AArchitecture: string): Boolean;
var
  Platform: string;
begin
  Platform := LowerCase(AOS + '/' + AArchitecture);
  if APattern = '*' then Exit(True);
  if SameText(APattern, 'unix/*') then
    Exit(not SameText(AOS, 'windows'));
  if Copy(APattern, Length(APattern) - 1, 2) = '/*' then
    Exit(SameText(Copy(APattern, 1, Length(APattern) - 2), AOS));
  Result := SameText(APattern, Platform);
end;

function TLWPTTestInventory.PlatformSpecificity(const APattern, AOS,
  AArchitecture: string): Integer;
begin
  if not PlatformMatches(APattern, AOS, AArchitecture) then Exit(0);
  if SameText(APattern, AOS + '/' + AArchitecture) then Exit(4);
  if SameText(APattern, AOS + '/*') then Exit(3);
  if SameText(APattern, 'unix/*') then Exit(2);
  Result := 1;
end;

function TLWPTTestInventory.Resolve(const APath, AOS,
  AArchitecture: string; out ATier: string; out ASuites,
  ACases: Integer): Boolean;
var
  i, Score, BestScore: Integer;
  Canonical: string;
begin
  Result := False;
  BestScore := 0;
  Canonical := CanonicalInventoryPath(APath);
  for i := 0 to High(FEntries) do
    if FEntries[i].Path = Canonical then
    begin
      Score := PlatformSpecificity(FEntries[i].Platform, AOS, AArchitecture);
      if Score = 0 then Continue;
      if Score = BestScore then
        raise ELWPTTestInventoryError.CreateFmt(
          'test inventory has ambiguous platform rules for "%s" on %s/%s',
          [Canonical, AOS, AArchitecture]);
      if Score > BestScore then
      begin
        Result := True;
        BestScore := Score;
        ATier := FEntries[i].Tier;
        ASuites := FEntries[i].Suites;
        ACases := FEntries[i].Cases;
      end;
    end;
end;

procedure TLWPTTestInventory.ValidatePlatform(const AOS,
  AArchitecture: string);
var
  Platform: string;
begin
  Platform := LowerCase(AOS + '/' + AArchitecture);
  if FPlatforms.IndexOf(Platform) < 0 then
    raise ELWPTTestInventoryError.CreateFmt(
      'test inventory does not declare the running platform %s', [Platform]);
end;

procedure TLWPTTestInventory.ValidateEmptyDiscovery;
var
  Paths: TStringList;
begin
  Paths := TStringList.Create;
  try
    Self.Paths(Paths);
    if Paths.Count <> 0 then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory is stale: "%s" is not a discovered test program',
        [Paths[0]]);
  finally
    Paths.Free;
  end;
end;

function TLWPTTestInventory.ContainsPath(const APath: string): Boolean;
var
  i: Integer;
  Canonical: string;
begin
  Canonical := CanonicalInventoryPath(APath);
  for i := 0 to High(FEntries) do
    if FEntries[i].Path = Canonical then Exit(True);
  Result := False;
end;

procedure TLWPTTestInventory.Paths(const APaths: TStrings);
var
  i: Integer;
begin
  APaths.Clear;
  for i := 0 to High(FEntries) do
    if APaths.IndexOf(FEntries[i].Path) < 0 then APaths.Add(FEntries[i].Path);
end;

function SplitPlatform(const APlatform: string; out AOS,
  AArchitecture: string): Boolean;
var
  Slash: Integer;
begin
  Slash := Pos('/', APlatform);
  Result := Slash > 1;
  if not Result then Exit;
  AOS := Copy(APlatform, 1, Slash - 1);
  AArchitecture := Copy(APlatform, Slash + 1, MaxInt);
  Result := AArchitecture <> '';
end;

function TLWPTTestInventory.PlatformLabel(
  const AIndexes: array of Integer): string;
var
  DarwinCount, LinuxCount, WindowsCount, i: Integer;
  Labels, Other: TStringList;
  OSName, Architecture: string;
begin
  DarwinCount := 0;
  LinuxCount := 0;
  WindowsCount := 0;
  Other := TStringList.Create;
  Labels := TStringList.Create;
  try
    for i := Low(AIndexes) to High(AIndexes) do
    begin
      SplitPlatform(FPlatforms[AIndexes[i]], OSName, Architecture);
      if SameText(OSName, 'darwin') then Inc(DarwinCount)
      else if SameText(OSName, 'linux') then Inc(LinuxCount)
      else if SameText(OSName, 'windows') then Inc(WindowsCount)
      else Other.Add(FPlatforms[AIndexes[i]]);
    end;
    if (DarwinCount = 2) and (LinuxCount = 2) then
    begin
      Labels.Add('Unix');
      DarwinCount := 0;
      LinuxCount := 0;
    end;
    if DarwinCount = 2 then Labels.Add('Darwin')
    else if DarwinCount > 0 then
      for i := Low(AIndexes) to High(AIndexes) do
        if Pos('darwin/', LowerCase(FPlatforms[AIndexes[i]])) = 1 then
          Labels.Add(FPlatforms[AIndexes[i]]);
    if LinuxCount = 2 then Labels.Add('Linux')
    else if LinuxCount > 0 then
      for i := Low(AIndexes) to High(AIndexes) do
        if Pos('linux/', LowerCase(FPlatforms[AIndexes[i]])) = 1 then
          Labels.Add(FPlatforms[AIndexes[i]]);
    if WindowsCount = 2 then Labels.Add('Windows')
    else if WindowsCount > 0 then
      for i := Low(AIndexes) to High(AIndexes) do
        if Pos('windows/', LowerCase(FPlatforms[AIndexes[i]])) = 1 then
          Labels.Add(FPlatforms[AIndexes[i]]);
    Labels.AddStrings(Other);
    Result := StringReplace(Trim(Labels.CommaText), ',', ', ', [rfReplaceAll]);
  finally
    Labels.Free;
    Other.Free;
  end;
end;

function TLWPTTestInventory.CountDisplayForPath(const APath: string): string;
type
  TCountGroup = record
    Suites, Cases: Integer;
    PlatformIndexes: array of Integer;
  end;
var
  Groups: array of TCountGroup;
  Architecture, OSName, Tier, Part: string;
  Cases, GroupIndex, i, n, Suites: Integer;
begin
  SetLength(Groups, 0);
  for i := 0 to FPlatforms.Count - 1 do
  begin
    if not SplitPlatform(FPlatforms[i], OSName, Architecture)
       or not Resolve(APath, OSName, Architecture, Tier, Suites, Cases) then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory has no rule for "%s" on %s',
        [APath, FPlatforms[i]]);
    GroupIndex := -1;
    for n := 0 to High(Groups) do
      if (Groups[n].Suites = Suites) and (Groups[n].Cases = Cases) then
        GroupIndex := n;
    if GroupIndex < 0 then
    begin
      GroupIndex := Length(Groups);
      SetLength(Groups, GroupIndex + 1);
      Groups[GroupIndex].Suites := Suites;
      Groups[GroupIndex].Cases := Cases;
    end;
    n := Length(Groups[GroupIndex].PlatformIndexes);
    SetLength(Groups[GroupIndex].PlatformIndexes, n + 1);
    Groups[GroupIndex].PlatformIndexes[n] := i;
  end;
  Result := '';
  for i := 0 to High(Groups) do
  begin
    Part := IntToStr(Groups[i].Cases) + ' '
      + SingularPlural(Groups[i].Cases, 'test', 'tests') + ' in '
      + IntToStr(Groups[i].Suites) + ' '
      + SingularPlural(Groups[i].Suites, 'suite', 'suites');
    if Length(Groups) > 1 then
      Part := Part + ' (' + PlatformLabel(Groups[i].PlatformIndexes) + ')';
    if Result <> '' then Result := Result + '; ';
    Result := Result + Part;
  end;
end;

function TLWPTTestInventory.ProgramCount(const ATier: string): Integer;
var
  Paths: TStringList;
  i: Integer;
begin
  Paths := TStringList.Create;
  try
    Paths.CaseSensitive := True;
    for i := 0 to High(FEntries) do
      if ((ATier = '') or (FEntries[i].Tier = ATier))
         and (Paths.IndexOf(FEntries[i].Path) < 0) then
        Paths.Add(FEntries[i].Path);
    Result := Paths.Count;
  finally
    Paths.Free;
  end;
end;

function TLWPTTestInventory.AggregateDisplay(const ATier: string): string;
type
  TAggregateGroup = record
    Cases: Integer;
    PlatformIndexes: array of Integer;
  end;
var
  Groups: array of TAggregateGroup;
  Paths: TStringList;
  Architecture, OSName, Tier, Part: string;
  Cases, GroupIndex, i, j, n, Suites, Total: Integer;
begin
  Paths := TStringList.Create;
  try
    Paths.CaseSensitive := True;
    for i := 0 to High(FEntries) do
      if ((ATier = '') or (FEntries[i].Tier = ATier))
         and (Paths.IndexOf(FEntries[i].Path) < 0) then
        Paths.Add(FEntries[i].Path);
    SetLength(Groups, 0);
    for i := 0 to FPlatforms.Count - 1 do
    begin
      SplitPlatform(FPlatforms[i], OSName, Architecture);
      Total := 0;
      for j := 0 to Paths.Count - 1 do
      begin
        if not Resolve(Paths[j], OSName, Architecture, Tier, Suites, Cases) then
          raise ELWPTTestInventoryError.CreateFmt(
            'test inventory has no rule for "%s" on %s',
            [Paths[j], FPlatforms[i]]);
        Inc(Total, Cases);
      end;
      GroupIndex := -1;
      for n := 0 to High(Groups) do
        if Groups[n].Cases = Total then GroupIndex := n;
      if GroupIndex < 0 then
      begin
        GroupIndex := Length(Groups);
        SetLength(Groups, GroupIndex + 1);
        Groups[GroupIndex].Cases := Total;
      end;
      n := Length(Groups[GroupIndex].PlatformIndexes);
      SetLength(Groups[GroupIndex].PlatformIndexes, n + 1);
      Groups[GroupIndex].PlatformIndexes[n] := i;
    end;
    Result := '';
    for i := 0 to High(Groups) do
    begin
      Part := IntToStr(Groups[i].Cases);
      if Length(Groups) > 1 then
        Part := Part + ' ' + PlatformLabel(Groups[i].PlatformIndexes);
      if Result <> '' then Result := Result + ' / ';
      Result := Result + Part;
    end;
  finally
    Paths.Free;
  end;
end;

function TLWPTTestInventory.RenderAggregateBlock: string;
begin
  Result := TEST_INVENTORY_DOC_BEGIN + LineEnding
    + '| Tier | Files | Registered test cases |' + LineEnding
    + '| --- | ---: | --- |' + LineEnding
    + '| Unit | ' + IntToStr(ProgramCount('unit')) + ' | '
      + AggregateDisplay('unit') + ' |' + LineEnding
    + '| Integration | ' + IntToStr(ProgramCount('integration')) + ' | '
      + AggregateDisplay('integration') + ' |' + LineEnding
    + '| E2E | ' + IntToStr(ProgramCount('e2e')) + ' | '
      + AggregateDisplay('e2e') + ' |' + LineEnding
    + '| **Total** | **' + IntToStr(ProgramCount('')) + '** | **'
      + AggregateDisplay('') + '** |' + LineEnding
    + TEST_INVENTORY_DOC_END;
end;

function ReplaceCountCell(const ALine, ACount: string): string;
var
  FirstPipe, SecondPipe, ThirdPipe: Integer;
begin
  FirstPipe := Pos('|', ALine);
  SecondPipe := PosEx('|', ALine, FirstPipe + 1);
  ThirdPipe := PosEx('|', ALine, SecondPipe + 1);
  if (FirstPipe = 0) or (SecondPipe = 0) or (ThirdPipe = 0) then Exit(ALine);
  Result := Copy(ALine, 1, SecondPipe) + ' ' + ACount + ' '
    + Copy(ALine, ThirdPipe, MaxInt);
end;

function ExtractInventoryDocPath(const ALine: string): string;
var
  StartPos, EndPos: Integer;
begin
  Result := '';
  if (TrimLeft(ALine) = '') or (TrimLeft(ALine)[1] <> '|') then Exit;
  StartPos := Pos('`', ALine);
  if StartPos = 0 then Exit;
  EndPos := PosEx('`', ALine, StartPos + 1);
  if EndPos = 0 then Exit;
  Result := Copy(ALine, StartPos + 1, EndPos - StartPos - 1);
  if not SameText(ExtractFileExt(Result), '.pas') then Result := '';
end;

function TLWPTTestInventoryDocumentation(const AInventory: TLWPTTestInventory;
  const APath: string): string;
var
  InventoryPaths, Lines, SeenPaths: TStringList;
  Block, DocPath: string;
  BeginIndex, EndIndex, i: Integer;
begin
  InventoryPaths := TStringList.Create;
  Lines := TStringList.Create;
  SeenPaths := TStringList.Create;
  try
    InventoryPaths.CaseSensitive := True;
    SeenPaths.CaseSensitive := True;
    AInventory.Paths(InventoryPaths);
    Lines.LoadFromFile(APath);
    for i := 0 to Lines.Count - 1 do
    begin
      DocPath := ExtractInventoryDocPath(Lines[i]);
      if (DocPath <> '') and AInventory.ContainsPath(DocPath) then
      begin
        if SeenPaths.IndexOf(DocPath) >= 0 then
          raise ELWPTTestInventoryError.CreateFmt(
            'test inventory documentation repeats "%s" in "%s"; run '
            + 'instantfpc -Fu./source -Fi./source '
            + 'scripts/update-test-inventory.pas', [DocPath, APath]);
        SeenPaths.Add(DocPath);
        Lines[i] := ReplaceCountCell(Lines[i],
          AInventory.CountDisplayForPath(DocPath));
      end;
    end;
    for i := 0 to InventoryPaths.Count - 1 do
      if SeenPaths.IndexOf(InventoryPaths[i]) < 0 then
        raise ELWPTTestInventoryError.CreateFmt(
          'test inventory documentation is missing "%s" in "%s"; run '
          + 'instantfpc -Fu./source -Fi./source '
          + 'scripts/update-test-inventory.pas', [InventoryPaths[i], APath]);
    BeginIndex := Lines.IndexOf(TEST_INVENTORY_DOC_BEGIN);
    EndIndex := Lines.IndexOf(TEST_INVENTORY_DOC_END);
    if (BeginIndex < 0) or (EndIndex < BeginIndex) then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory markers are missing or invalid in "%s"', [APath]);
    Block := AInventory.RenderAggregateBlock;
    while EndIndex >= BeginIndex do
    begin
      Lines.Delete(BeginIndex);
      Dec(EndIndex);
    end;
    { Insert the complete generated block as individual lines. }
    with TStringList.Create do
      try
        Text := Block;
        for i := Count - 1 downto 0 do Lines.Insert(BeginIndex, Strings[i]);
      finally
        Free;
      end;
    Result := Lines.Text;
  finally
    SeenPaths.Free;
    Lines.Free;
    InventoryPaths.Free;
  end;
end;

procedure TLWPTTestInventory.ValidateDocumentation(const APath: string);
var
  Actual, Expected: TStringList;
begin
  Actual := TStringList.Create;
  Expected := TStringList.Create;
  try
    Actual.LoadFromFile(APath);
    Expected.Text := TLWPTTestInventoryDocumentation(Self, APath);
    if Actual.Text <> Expected.Text then
      raise ELWPTTestInventoryError.CreateFmt(
        'test inventory documentation is stale: run instantfpc -Fu./source '
        + '-Fi./source scripts/update-test-inventory.pas',
        []);
  finally
    Expected.Free;
    Actual.Free;
  end;
end;

procedure TLWPTTestInventory.WriteDocumentation(const APath: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := TLWPTTestInventoryDocumentation(Self, APath);
    Lines.SaveToFile(APath);
  finally
    Lines.Free;
  end;
end;

end.
