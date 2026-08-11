program LWPT.TestInventory.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.TestInventory,
  Platform,
  TestingPascalLibrary;

type
  TTestInventoryTests = class(TTestSuite)
  private
    function TemporaryPath(const AName: string): string;
  public
    procedure SetupTests; override;
    procedure TestCanonicalDocumentationIsCurrent;
    procedure TestPlatformRulesResolveBySpecificity;
    procedure TestAmbiguousRulesFailClosed;
    procedure TestPlatformRulesCannotChangeTier;
    procedure TestStaleDocumentationFailsWithUpdateCommand;
    procedure TestRunningPlatformIsDeclared;
    procedure TestMissingDocumentationRowFails;
  end;

function TTestInventoryTests.TemporaryPath(const AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False))
    + 'lwpt-test-inventory-' + IntToHex(GetTickCount64, 16) + '-' + AName;
end;

procedure TTestInventoryTests.TestRunningPlatformIsDeclared;
var
  Inventory: TLWPTTestInventory;
begin
  Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
  try
    Inventory.ValidatePlatform(Platform.GetBuildOS, Platform.GetBuildArch);
    Expect<Boolean>(True).ToBe(True);
  finally
    Inventory.Free;
  end;
end;

procedure TTestInventoryTests.TestMissingDocumentationRowFails;
var
  Failed: Boolean;
  Inventory: TLWPTTestInventory;
  Lines: TStringList;
  Path: string;
begin
  Path := TemporaryPath('missing-row.md');
  Lines := TStringList.Create;
  try
    Lines.Add(TEST_INVENTORY_DOC_BEGIN);
    Lines.Add('stale');
    Lines.Add(TEST_INVENTORY_DOC_END);
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
  Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
  try
    Failed := False;
    try
      Inventory.WriteDocumentation(Path);
    except
      on E: ELWPTTestInventoryError do
        Failed := Pos('documentation is missing', E.Message) > 0;
    end;
    Expect<Boolean>(Failed).ToBe(True);
  finally
    Inventory.Free;
    DeleteFile(Path);
  end;
end;

procedure TTestInventoryTests.TestCanonicalDocumentationIsCurrent;
var
  Inventory: TLWPTTestInventory;
begin
  Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
  try
    Inventory.ValidateDocumentation('docs/testing.md');
    Expect<Boolean>(True).ToBe(True);
  finally
    Inventory.Free;
  end;
end;

procedure TTestInventoryTests.TestPlatformRulesResolveBySpecificity;
var
  Cases, Suites: Integer;
  Inventory: TLWPTTestInventory;
  Tier: string;
begin
  Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
  try
    Expect<Boolean>(Inventory.Resolve(
      'packages/httpclient/source/HTTPClient.Test.pas', 'darwin', 'aarch64',
      Tier, Suites, Cases)).ToBe(True);
    Expect<string>(Tier).ToBe('unit');
    Expect<Integer>(Suites).ToBe(4);
    Expect<Integer>(Cases).ToBe(35);
    Expect<Boolean>(Inventory.Resolve(
      'packages/httpclient/source/HTTPClient.Test.pas', 'windows', 'i386',
      Tier, Suites, Cases)).ToBe(True);
    Expect<Integer>(Cases).ToBe(33);
  finally
    Inventory.Free;
  end;
end;

procedure TTestInventoryTests.TestAmbiguousRulesFailClosed;
var
  Failed: Boolean;
  Inventory: TLWPTTestInventory;
  Lines: TStringList;
  Path, Tier: string;
  Cases, Suites: Integer;
begin
  Path := TemporaryPath('ambiguous.tsv');
  Lines := TStringList.Create;
  try
    Lines.Add(TEST_INVENTORY_SCHEMA);
    Lines.Add('platform'#9'darwin/aarch64');
    Lines.Add('program'#9'*'#9'unit'#9'a.Test.pas'#9'1'#9'1');
    Lines.Add('program'#9'*'#9'unit'#9'a.Test.pas'#9'1'#9'1');
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
  Inventory := TLWPTTestInventory.Create(Path);
  try
    Failed := False;
    try
      Inventory.Resolve('a.Test.pas', 'darwin', 'aarch64', Tier, Suites,
        Cases);
    except
      on ELWPTTestInventoryError do Failed := True;
    end;
    Expect<Boolean>(Failed).ToBe(True);
  finally
    Inventory.Free;
    DeleteFile(Path);
  end;
end;

procedure TTestInventoryTests.TestPlatformRulesCannotChangeTier;
var
  Failed: Boolean;
  Lines: TStringList;
  Path: string;
begin
  Path := TemporaryPath('tier-change.tsv');
  Lines := TStringList.Create;
  try
    Lines.Add(TEST_INVENTORY_SCHEMA);
    Lines.Add('platform'#9'darwin/aarch64');
    Lines.Add('program'#9'*'#9'unit'#9'a.Test.pas'#9'1'#9'1');
    Lines.Add('program'#9'darwin/*'#9'integration'#9'a.Test.pas'#9'1'#9'1');
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
  Failed := False;
  try
    TLWPTTestInventory.Create(Path).Free;
  except
    on E: ELWPTTestInventoryError do
      Failed := Pos('changes tier from unit to integration', E.Message) > 0;
  end;
  Expect<Boolean>(Failed).ToBe(True);
  DeleteFile(Path);
end;

procedure TTestInventoryTests.TestStaleDocumentationFailsWithUpdateCommand;
var
  Failed: Boolean;
  Inventory: TLWPTTestInventory;
  Lines: TStringList;
  Path: string;
begin
  Path := TemporaryPath('stale.md');
  Lines := TStringList.Create;
  try
    Lines.Add('| File | Suites / tests | What it asserts |');
    Lines.Add('| --- | --- | --- |');
    Lines.Add('| **`source/LWPT.TestInventory.Test.pas`** | stale | test |');
    Lines.Add(TEST_INVENTORY_DOC_BEGIN);
    Lines.Add('stale');
    Lines.Add(TEST_INVENTORY_DOC_END);
    Lines.SaveToFile(Path);
  finally
    Lines.Free;
  end;
  Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
  try
    Failed := False;
    try
      Inventory.ValidateDocumentation(Path);
    except
      on E: ELWPTTestInventoryError do
      begin
        Failed := Pos('update-test-inventory.pas', E.Message) > 0;
      end;
    end;
    Expect<Boolean>(Failed).ToBe(True);
  finally
    Inventory.Free;
    DeleteFile(Path);
  end;
end;

procedure TTestInventoryTests.SetupTests;
begin
  Test('platform rules resolve by specificity',
    TestPlatformRulesResolveBySpecificity);
  Test('ambiguous platform rules fail closed', TestAmbiguousRulesFailClosed);
  Test('platform rules cannot change a program tier',
    TestPlatformRulesCannotChangeTier);
  Test('canonical documentation is current',
    TestCanonicalDocumentationIsCurrent);
  Test('stale documentation names the update command',
    TestStaleDocumentationFailsWithUpdateCommand);
  Test('the running platform is declared', TestRunningPlatformIsDeclared);
  Test('documentation requires one row per inventory path',
    TestMissingDocumentationRowFails);
end;

begin
  TestRunnerProgram.AddSuite(TTestInventoryTests.Create('test inventory'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
