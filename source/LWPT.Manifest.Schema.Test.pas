program LWPT.Manifest.Schema.Test;

{$I Shared.inc}

uses
  Classes,
  SysUtils,

  LWPT.Core,
  LWPT.Manifest,
  LWPT.Manifest.Schema,
  TestingPascalLibrary,
  TOML;

type
  TManifestSchemaTests = class(TTestSuite)
  private
    FScratch: string;
    function WriteManifest(const AName, AContent: string): string;
    procedure ExpectLoadError(const AContent, AMessage: string);
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestRegistryEntriesAreComplete;
    procedure TestDefaultsComeFromRegistry;
    procedure TestKnownAndReservedNamesPreserveCaseRules;
    procedure TestStrictRegistryFieldRejectsThroughLoader;
    procedure TestRootOnlyStrictFieldIsIgnoredForDependencies;
    procedure TestPermissivePoliciesRemainPermissive;
    procedure TestStrictUnknownKeyPoliciesReject;
  end;

function TManifestSchemaTests.WriteManifest(const AName,
  AContent: string): string;
var
  Contents: TStringList;
begin
  Result := FScratch + '/' + AName + '.toml';
  Contents := TStringList.Create;
  try
    Contents.Text := AContent;
    Contents.SaveToFile(Result);
  finally
    Contents.Free;
  end;
end;

procedure TManifestSchemaTests.ExpectLoadError(const AContent,
  AMessage: string);
var
  Raised: Boolean;
begin
  Raised := False;
  try
    LoadManifest(WriteManifest('invalid', AContent));
  except
    on E: EManifestError do
    begin
      Raised := True;
      if Pos(AMessage, E.Message) = 0 then
        Fail(Format('expected "%s" in "%s"', [AMessage, E.Message]));
    end;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TManifestSchemaTests.BeforeAll;
begin
  FScratch := ExpandFileName('build/tests/tmp/manifest-schema-'
    + IntToStr(GetProcessID));
  WipeDir(FScratch);
  ForceDirectories(FScratch);
end;

procedure TManifestSchemaTests.AfterAll;
begin
  WipeDir(FScratch);
end;

procedure TManifestSchemaTests.TestRegistryEntriesAreComplete;
var
  Section: TLWPTManifestSchemaSection;
  Field: TLWPTManifestSchemaField;
  SectionSpec: TLWPTManifestSectionSpec;
  Covered: Boolean;
begin
  for Section := Low(TLWPTManifestSchemaSection)
    to High(TLWPTManifestSchemaSection) do
  begin
    SectionSpec := ManifestSchemaSection(Section);
    Expect<Boolean>(SectionSpec.Path <> '').ToBe(True);
    Expect<Boolean>(SectionSpec.Shape <> '').ToBe(True);
    Expect<Boolean>(Ord(SectionSpec.FirstField)
      <= Ord(SectionSpec.LastField)).ToBe(True);
  end;
  for Field := Low(TLWPTManifestSchemaField)
    to High(TLWPTManifestSchemaField) do
  begin
    Expect<Boolean>(ManifestSchemaField(Field).Name <> '').ToBe(True);
    Expect<Boolean>(ManifestSchemaField(Field).Description <> '').ToBe(True);
    Covered := False;
    for Section := Low(TLWPTManifestSchemaSection)
      to High(TLWPTManifestSchemaSection) do
    begin
      SectionSpec := ManifestSchemaSection(Section);
      if (Ord(Field) >= Ord(SectionSpec.FirstField))
        and (Ord(Field) <= Ord(SectionSpec.LastField)) then
        Covered := True;
    end;
    Expect<Boolean>(Covered).ToBe(True);
  end;
end;

procedure TManifestSchemaTests.TestDefaultsComeFromRegistry;
begin
  Expect<string>(ManifestSchemaField(msfPackageVersion).DefaultValue)
    .ToBe(MANIFEST_DEFAULT_PACKAGE_VERSION);
  Expect<string>(ManifestSchemaField(msfCompilerVersion).DefaultValue)
    .ToBe(MANIFEST_DEFAULT_COMPILER_VERSION);
  Expect<string>(ManifestSchemaField(msfVersionPrefix).DefaultValue)
    .ToBe(MANIFEST_DEFAULT_VERSION_PREFIX);
end;

procedure TManifestSchemaTests.TestKnownAndReservedNamesPreserveCaseRules;
var
  Manifest: TManifest;
begin
  Expect<Boolean>(IsKnownManifestSection('package')).ToBe(True);
  Expect<Boolean>(IsKnownManifestSection('preinstall')).ToBe(True);
  Expect<Boolean>(IsKnownManifestSection('Package')).ToBe(False);
  Expect<Boolean>(IsReservedManifestTaskName('agents')).ToBe(True);
  Expect<Boolean>(IsReservedManifestTaskName('Agents')).ToBe(True);
  Expect<Boolean>(IsReservedManifestTaskName('generated')).ToBe(True);
  Expect<Boolean>(IsReservedManifestTaskName('Preinstall')).ToBe(False);
  Expect<Boolean>(IsReservedManifestTaskName('deploy')).ToBe(False);
  Manifest := LoadManifest(WriteManifest('case-rules',
    '[package]'#10 +
    'name = "case-rules"'#10 +
    '[Preinstall]'#10 +
    'command = "tools/preinstall"'#10));
  Expect<Integer>(Length(Manifest.RunTasks)).ToBe(1);
  Expect<string>(Manifest.RunTasks[0].Name).ToBe('Preinstall');
end;

procedure TManifestSchemaTests.TestStrictRegistryFieldRejectsThroughLoader;
const
  INPUT =
    '[package]'#10 +
    'name = "strict-schema"'#10 +
    '[test]'#10 +
    'flags = "-dWRONG"'#10;
var
  Spec: TLWPTManifestFieldSpec;
begin
  Spec := ManifestSchemaField(msfTestFlags);
  Expect<Integer>(Ord(Spec.ValueKind)).ToBe(Ord(mvkStringArray));
  Expect<Integer>(Ord(Spec.InvalidPolicy)).ToBe(Ord(mipError));
  Expect<Integer>(Ord(ManifestSchemaField(msfDependencySource).Requirement))
    .ToBe(Ord(mrRequiredDomain));
  Expect<Integer>(Ord(ManifestSchemaField(msfDependencySource).InvalidPolicy))
    .ToBe(Ord(mipDomainError));
  ExpectLoadError(INPUT, 'test.flags must be an array of strings');
end;

procedure TManifestSchemaTests
  .TestRootOnlyStrictFieldIsIgnoredForDependencies;
const
  INPUT =
    '[package]'#10 +
    'name = "child"'#10 +
    '[test]'#10 +
    'flags = "ignored-child-policy"'#10;
var
  Manifest: TManifest;
begin
  Manifest := LoadManifest(WriteManifest('child', INPUT), False);
  Expect<Integer>(Length(Manifest.TestFlags)).ToBe(0);
end;

procedure TManifestSchemaTests.TestPermissivePoliciesRemainPermissive;
const
  INPUT =
    '[package]'#10 +
    'name = "permissive"'#10 +
    'units = ["source", 7]'#10 +
    '[format]'#10 +
    'include = "ignored"'#10 +
    '[workspaces]'#10 +
    'exclude = ["build/**", false]'#10;
var
  Manifest: TManifest;
begin
  Manifest := LoadManifest(WriteManifest('permissive', INPUT));
  Expect<Integer>(Length(Manifest.Units)).ToBe(1);
  Expect<string>(Manifest.Units[0]).ToBe('source');
  Expect<Integer>(Length(Manifest.FormatIncludes)).ToBe(0);
  Expect<Integer>(Length(Manifest.WorkspaceExcludes)).ToBe(1);
end;

procedure TManifestSchemaTests.TestStrictUnknownKeyPoliciesReject;
const
  HEALTH_INPUT =
    '[package]'#10 +
    'name = "health-unknown"'#10 +
    '[health]'#10 +
    'mystery = 1'#10;
  TARGET_INPUT =
    '[package]'#10 +
    'name = "target-unknown"'#10 +
    '[build.app]'#10 +
    'source = "source/app.pas"'#10 +
    'target = { os = "linux", architecture = "x86_64", mystery = "x" }'#10;
begin
  ExpectLoadError(HEALTH_INPUT, 'health has unknown field "mystery"');
  ExpectLoadError(TARGET_INPUT,
    'build.app.target has unknown field "mystery"');
end;

procedure TManifestSchemaTests.SetupTests;
begin
  Test('registry entries have complete renderable metadata',
    TestRegistryEntriesAreComplete);
  Test('parser defaults are declared by the registry',
    TestDefaultsComeFromRegistry);
  Test('known and reserved section names preserve parser case rules',
    TestKnownAndReservedNamesPreserveCaseRules);
  Test('strict registry field rejects through LoadManifest',
    TestStrictRegistryFieldRejectsThroughLoader);
  Test('root-only strict field remains ignored in dependency manifests',
    TestRootOnlyStrictFieldIsIgnoredForDependencies);
  Test('permissive invalid-value policies preserve legacy behavior',
    TestPermissivePoliciesRemainPermissive);
  Test('strict unknown-key policies reject through LoadManifest',
    TestStrictUnknownKeyPoliciesReject);
end;

begin
  TestRunnerProgram.AddSuite(TManifestSchemaTests.Create(
    PROJECT_NAME + '.Manifest.Schema: structural registry'));
  TestRunnerProgram.Run;
end.
