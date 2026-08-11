{ LWPT.Manifest.Schema — immutable structural manifest registry. }
unit LWPT.Manifest.Schema;

{$I Shared.inc}
{$J-}

interface

uses
  TOML;

const
  MANIFEST_DEFAULT_NAME = 'unnamed';
  MANIFEST_DEFAULT_PACKAGE_VERSION = '0.0.0';
  MANIFEST_DEFAULT_COMPILER_VERSION = '*';
  MANIFEST_DEFAULT_VERSION_PREFIX = 'BAKED';

type
  TLWPTManifestSchemaSection = (
    mssPackage,
    mssDependencies,
    mssDependencyEntry,
    mssSources,
    mssSourceEntry,
    mssWorkspaces,
    mssBuild,
    mssBuildEntry,
    mssBuildTarget,
    mssCompiler,
    mssCompilerProfile,
    mssVersion,
    mssToolkit,
    mssFormat,
    mssAnalysis,
    mssHealth,
    mssDuplication,
    mssTest,
    mssLifecycleHooks,
    mssHookEntry,
    mssRunTask
  );

  TLWPTManifestSchemaField = (
    msfPackageName,
    msfPackageVersion,
    msfPackageUnits,
    msfDependencyEntry,
    msfDependencySource,
    msfDependencyVersion,
    msfDependencyInclude,
    msfDependencyExclude,
    msfDependencyRepo,
    msfDependencyRef,
    msfDependencyTag,
    msfDependencyAsset,
    msfDependencyPath,
    msfDependencySubdir,
    msfSourceEntry,
    msfSourceArchive,
    msfSourceGit,
    msfWorkspaceInclude,
    msfWorkspaceExclude,
    msfBuildEntry,
    msfBuildSource,
    msfBuildOutput,
    msfBuildDepends,
    msfBuildFlags,
    msfBuildCompiler,
    msfBuildTarget,
    msfBuildPrebuild,
    msfBuildPostbuild,
    msfTargetOS,
    msfTargetArchitecture,
    msfTargetABI,
    msfTargetEnvironment,
    msfCompilerDefault,
    msfCompilerProfiles,
    msfCompilerDriver,
    msfCompilerCommand,
    msfCompilerArgs,
    msfCompilerVersion,
    msfCompilerExecutable,
    msfCompilerScript,
    msfVersionOutput,
    msfVersionPrefix,
    msfToolkitModulesDir,
    msfToolkitArchivesDir,
    msfToolkitTmpDir,
    msfToolkitCfgFile,
    msfFormatInclude,
    msfFormatExclude,
    msfAnalysisInclude,
    msfAnalysisExclude,
    msfHealthRoutineCyclomatic,
    msfHealthRoutineCognitive,
    msfHealthFileCyclomatic,
    msfHealthFileCognitive,
    msfHealthHotspotScore,
    msfDuplicationMinimumTokens,
    msfDuplicationMaximumPercent,
    msfTestBail,
    msfTestFlags,
    msfLifecycleHookEntry,
    msfHookCommand,
    msfHookArgs,
    msfHookInputs,
    msfHookOutput,
    msfHookScript
  );

  TLWPTManifestValueKind = (
    mvkAny,
    mvkString,
    mvkInteger,
    mvkStringArray,
    mvkTable,
    mvkStringOrTable
  );

  TLWPTManifestInvalidPolicy = (
    mipError,
    mipDomainError,
    mipIgnoreAsAbsent,
    mipSkipInvalidItems,
    mipLegacyPassThrough
  );

  TLWPTManifestUnknownKeyPolicy = (
    mukIgnore,
    mukError
  );

  TLWPTManifestScope = (
    mscAllManifests,
    mscRootOnly
  );

  TLWPTManifestRequirement = (
    mrOptional,
    mrRequired,
    mrRequiredDomain,
    mrConditional
  );

  TLWPTManifestSectionSpec = record
    Path: string;
    TopLevelNames: string;
    Shape: string;
    Scope: TLWPTManifestScope;
    InvalidPolicy: TLWPTManifestInvalidPolicy;
    UnknownKeyPolicy: TLWPTManifestUnknownKeyPolicy;
    FirstField: TLWPTManifestSchemaField;
    LastField: TLWPTManifestSchemaField;
    Description: string;
  end;

  TLWPTManifestFieldSpec = record
    Name: string;
    ValueKind: TLWPTManifestValueKind;
    Requirement: TLWPTManifestRequirement;
    DefaultValue: string;
    Scope: TLWPTManifestScope;
    InvalidPolicy: TLWPTManifestInvalidPolicy;
    NonEmpty: Boolean;
    Description: string;
  end;

function ManifestSchemaSection(
  ASection: TLWPTManifestSchemaSection): TLWPTManifestSectionSpec;
function ManifestSchemaField(
  AField: TLWPTManifestSchemaField): TLWPTManifestFieldSpec;
function ManifestValueKindText(AKind: TLWPTManifestValueKind): string;
function ManifestInvalidPolicyText(
  APolicy: TLWPTManifestInvalidPolicy): string;
function ManifestUnknownKeyPolicyText(
  APolicy: TLWPTManifestUnknownKeyPolicy): string;
function ManifestScopeText(AScope: TLWPTManifestScope): string;
function ManifestRequirementText(
  ARequirement: TLWPTManifestRequirement): string;
function IsKnownManifestSection(const AName: string): Boolean;
function IsReservedManifestTaskName(const AName: string): Boolean;
procedure ValidateManifestStructure(ARoot: TTOMLNode; AIsRoot: Boolean);

implementation

uses
  SysUtils,

  LWPT.Core,
  OrderedStringMap;

const
  MANIFEST_SECTIONS: array[TLWPTManifestSchemaSection]
    of TLWPTManifestSectionSpec = (
    (Path: '[package]'; TopLevelNames: 'package'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfPackageName; LastField: msfPackageUnits;
      Description: 'Package identity and Pascal unit roots.'),
    (Path: '[dependencies]'; TopLevelNames: 'dependencies'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfDependencyEntry; LastField: msfDependencyEntry;
      Description: 'Named dependency declarations.'),
    (Path: '[dependencies].<name>'; TopLevelNames: '';
      Shape: 'string or inline table';
      Scope: mscAllManifests; InvalidPolicy: mipLegacyPassThrough;
      UnknownKeyPolicy: mukIgnore; FirstField: msfDependencySource;
      LastField: msfDependencySubdir;
      Description: 'A source shorthand or expanded dependency declaration.'),
    (Path: '[sources]'; TopLevelNames: 'sources'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfSourceEntry; LastField: msfSourceEntry;
      Description: 'Named custom Git-host URL templates.'),
    (Path: '[sources].<name>'; TopLevelNames: ''; Shape: 'inline table';
      Scope: mscAllManifests; InvalidPolicy: mipIgnoreAsAbsent;
      UnknownKeyPolicy: mukIgnore; FirstField: msfSourceArchive;
      LastField: msfSourceGit;
      Description: 'One custom Git-host source.'),
    (Path: '[workspaces]'; TopLevelNames: 'workspaces'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfWorkspaceInclude; LastField: msfWorkspaceExclude;
      Description: 'Workspace discovery globs.'),
    (Path: '[build]'; TopLevelNames: 'build'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfBuildEntry; LastField: msfBuildEntry;
      Description: 'Single-entry shorthand or named build entries.'),
    (Path: '[build].<name>'; TopLevelNames: ''; Shape: 'string or table';
      Scope: mscAllManifests; InvalidPolicy: mipLegacyPassThrough;
      UnknownKeyPolicy: mukIgnore; FirstField: msfBuildSource;
      LastField: msfBuildPostbuild;
      Description: 'One compiler-neutral build entry.'),
    (Path: '[build].<name>.target'; TopLevelNames: ''; Shape: 'table';
      Scope: mscRootOnly;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukError;
      FirstField: msfTargetOS; LastField: msfTargetEnvironment;
      Description: 'An explicit complete compiler target tuple.'),
    (Path: '[compiler]'; TopLevelNames: 'compiler'; Shape: 'table';
      Scope: mscRootOnly;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukIgnore;
      FirstField: msfCompilerDefault; LastField: msfCompilerProfiles;
      Description: 'Root-owned compiler profile selection.'),
    (Path: '[compiler.profiles].<name>'; TopLevelNames: ''; Shape: 'table';
      Scope: mscRootOnly; InvalidPolicy: mipError;
      UnknownKeyPolicy: mukIgnore; FirstField: msfCompilerDriver;
      LastField: msfCompilerScript;
      Description: 'One built-in or external compiler profile.'),
    (Path: '[version]'; TopLevelNames: 'version'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfVersionOutput; LastField: msfVersionPrefix;
      Description: 'Generated version-include settings.'),
    (Path: '[' + PROGRAM_NAME + ']'; TopLevelNames: PROGRAM_NAME;
      Shape: 'table';
      Scope: mscAllManifests; InvalidPolicy: mipIgnoreAsAbsent;
      UnknownKeyPolicy: mukIgnore; FirstField: msfToolkitModulesDir;
      LastField: msfToolkitCfgFile;
      Description: 'Toolkit-state path overrides.'),
    (Path: '[format]'; TopLevelNames: 'format'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfFormatInclude; LastField: msfFormatExclude;
      Description: 'Formatter scope additions and subtractions.'),
    (Path: '[analysis]'; TopLevelNames: 'analysis'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukIgnore;
      FirstField: msfAnalysisInclude; LastField: msfAnalysisExclude;
      Description: 'Shared Pascal analysis source scope.'),
    (Path: '[health]'; TopLevelNames: 'health'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukError;
      FirstField: msfHealthRoutineCyclomatic;
      LastField: msfHealthHotspotScore;
      Description: 'Optional complexity and hotspot limits.'),
    (Path: '[duplication]'; TopLevelNames: 'duplication'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukIgnore;
      FirstField: msfDuplicationMinimumTokens;
      LastField: msfDuplicationMaximumPercent;
      Description: 'Token-clone floor and optional percentage limit.'),
    (Path: '[test]'; TopLevelNames: 'test'; Shape: 'table';
      Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfTestBail; LastField: msfTestFlags;
      Description: 'Test compiler and scheduler policy.'),
    (Path: '[preinstall] / [postinstall] / [prebuild] / [postbuild] / '
      + '[pretest] / [posttest]'; TopLevelNames: 'preinstall|postinstall|'
      + 'prebuild|postbuild|pretest|posttest'; Shape: 'table';
      Scope: mscRootOnly;
      InvalidPolicy: mipIgnoreAsAbsent; UnknownKeyPolicy: mukIgnore;
      FirstField: msfLifecycleHookEntry; LastField: msfLifecycleHookEntry;
      Description: 'Root lifecycle command maps.'),
    (Path: '<hook entry>'; TopLevelNames: '';
      Shape: 'string or inline table';
      Scope: mscAllManifests; InvalidPolicy: mipError;
      UnknownKeyPolicy: mukError; FirstField: msfHookCommand;
      LastField: msfHookScript;
      Description: 'A direct command with optional staleness gating.'),
    (Path: '[<task-name>]'; TopLevelNames: ''; Shape: 'table';
      Scope: mscRootOnly;
      InvalidPolicy: mipError; UnknownKeyPolicy: mukError;
      FirstField: msfHookCommand; LastField: msfHookScript;
      Description: 'An otherwise-unknown top-level section carrying command.')
  );

  MANIFEST_FIELDS: array[TLWPTManifestSchemaField]
    of TLWPTManifestFieldSpec = (
    (Name: 'name'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: MANIFEST_DEFAULT_NAME; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Package name; the legacy root name fallback still warns.'),
    (Name: 'version'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: MANIFEST_DEFAULT_PACKAGE_VERSION; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Package version.'),
    (Name: 'units'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Pascal unit-root paths.'),
    (Name: '<name>'; ValueKind: mvkStringOrTable; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipLegacyPassThrough; NonEmpty: False;
      Description: 'Bare <source>@<version> shorthand or an inline table.'),
    (Name: 'source'; ValueKind: mvkString; Requirement: mrRequiredDomain;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: True; Description: 'owner/repo (GitHub), '
      + '<host>:owner/repo (built-in or custom host), an HTTPS tarball, '
      + 'a local path, or workspace:<version>.'),
    (Name: 'version'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'none'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Version range, exact version, SHA, or tag.'),
    (Name: 'include'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'all files'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Post-extraction include globs.'),
    (Name: 'exclude'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'none'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Post-extraction exclude globs.'),
    (Name: 'repo'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; any declaration is an error.'),
    (Name: 'ref'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; any declaration is an error.'),
    (Name: 'tag'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; any declaration is an error.'),
    (Name: 'asset'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; any declaration is an error.'),
    (Name: 'path'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; any declaration is an error.'),
    (Name: 'subdir'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; use include globs.'),
    (Name: '<name>'; ValueKind: mvkTable; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'One custom source declaration.'),
    (Name: 'archive'; ValueKind: mvkString; Requirement: mrRequiredDomain;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: True; Description: 'HTTPS archive template containing '
      + '{user}, {repository}, and {ref}.'),
    (Name: 'git'; ValueKind: mvkString; Requirement: mrRequiredDomain;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: True; Description: 'HTTPS smart-HTTP template containing '
      + '{user} and {repository}.'),
    (Name: 'include'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Workspace discovery globs.'),
    (Name: 'exclude'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Workspace exclusion globs.'),
    (Name: '<name>'; ValueKind: mvkStringOrTable; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipLegacyPassThrough; NonEmpty: False;
      Description: 'Named entry; build.source enables single-entry shorthand.'),
    (Name: 'source'; ValueKind: mvkString; Requirement: mrConditional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Compiler entry-point path.'),
    (Name: 'output'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'build/<name>'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Published executable path.'),
    (Name: 'depends'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Prerequisite build-entry names.'),
    (Name: 'flags'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Ordered compiler-driver arguments.'),
    (Name: 'compiler'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: '[compiler].default'; Scope: mscRootOnly;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Named compiler-profile override.'),
    (Name: 'target'; ValueKind: mvkTable; Requirement: mrOptional;
      DefaultValue: 'compiler native target'; Scope: mscRootOnly;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Explicit target tuple.'),
    (Name: 'prebuild'; ValueKind: mvkTable; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Per-entry prebuild command map.'),
    (Name: 'postbuild'; ValueKind: mvkTable; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Per-entry postbuild command map.'),
    (Name: 'os'; ValueKind: mvkString; Requirement: mrRequired;
      DefaultValue: ''; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Target operating system.'),
    (Name: 'architecture'; ValueKind: mvkString; Requirement: mrRequired;
      DefaultValue: ''; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Target architecture.'),
    (Name: 'abi'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Optional target ABI.'),
    (Name: 'environment'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Optional target execution environment.'),
    (Name: 'default'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'host default'; Scope: mscRootOnly;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Default profile name.'),
    (Name: 'profiles'; ValueKind: mvkTable; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Named compiler-profile map.'),
    (Name: 'driver'; ValueKind: mvkString; Requirement: mrRequired;
      DefaultValue: ''; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Built-in or external driver identity.'),
    (Name: 'command'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'driver default'; Scope: mscRootOnly;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Direct compiler command.'),
    (Name: 'args'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Ordered command arguments.'),
    (Name: 'version'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: MANIFEST_DEFAULT_COMPILER_VERSION; Scope: mscRootOnly;
      InvalidPolicy: mipError; NonEmpty: True;
      Description: 'Compiler version constraint.'),
    (Name: 'executable'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscRootOnly;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; use command and args.'),
    (Name: 'script'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscRootOnly;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; use command and args.'),
    (Name: 'output'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Generated include path.'),
    (Name: 'prefix'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: MANIFEST_DEFAULT_VERSION_PREFIX; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Generated constant prefix.'),
    (Name: 'modules-dir'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'toolkit default'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Installed-module directory override.'),
    (Name: 'archives-dir'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'toolkit default'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Archive-cache directory override.'),
    (Name: 'tmp-dir'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'toolkit default'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Private temporary directory override.'),
    (Name: 'cfg-file'; ValueKind: mvkString; Requirement: mrOptional;
      DefaultValue: 'toolkit default'; Scope: mscAllManifests;
      InvalidPolicy: mipIgnoreAsAbsent; NonEmpty: False;
      Description: 'Compiler response-file override.'),
    (Name: 'include'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Formatter-scope additions.'),
    (Name: 'exclude'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipSkipInvalidItems; NonEmpty: False;
      Description: 'Formatter-scope subtraction.'),
    (Name: 'include'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Analysis-scope additions.'),
    (Name: 'exclude'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Analysis-scope subtraction.'),
    (Name: 'max-routine-cyclomatic'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Non-negative routine cyclomatic limit.'),
    (Name: 'max-routine-cognitive'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Non-negative routine cognitive limit.'),
    (Name: 'max-file-cyclomatic'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Non-negative file cyclomatic limit.'),
    (Name: 'max-file-cognitive'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Non-negative file cognitive limit.'),
    (Name: 'max-hotspot-score'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Integer hotspot limit from 0 to 100.'),
    (Name: 'minimum-tokens'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: '100';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Clone floor; minimum accepted value is 25.'),
    (Name: 'maximum-percent'; ValueKind: mvkInteger;
      Requirement: mrOptional; DefaultValue: 'unset';
      Scope: mscAllManifests; InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Integer duplication limit from 0 to 100.'),
    (Name: 'bail'; ValueKind: mvkInteger; Requirement: mrOptional;
      DefaultValue: '0'; Scope: mscAllManifests;
      InvalidPolicy: mipError; NonEmpty: False;
      Description: 'Non-negative failure count; zero runs the full queue.'),
    (Name: 'flags'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Ordered test compiler arguments.'),
    (Name: '<name>'; ValueKind: mvkStringOrTable; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscRootOnly; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'One lifecycle hook.'),
    (Name: 'command'; ValueKind: mvkString; Requirement: mrRequiredDomain;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: True; Description: 'Direct child-process command.'),
    (Name: 'args'; ValueKind: mvkStringArray; Requirement: mrOptional;
      DefaultValue: 'empty'; Scope: mscAllManifests; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Ordered command arguments.'),
    (Name: 'inputs'; ValueKind: mvkStringArray; Requirement: mrConditional;
      DefaultValue: 'empty'; Scope: mscAllManifests; InvalidPolicy: mipError;
      NonEmpty: True; Description: 'Non-empty staleness input globs.'),
    (Name: 'output'; ValueKind: mvkString; Requirement: mrConditional;
      DefaultValue: 'empty'; Scope: mscAllManifests; InvalidPolicy: mipError;
      NonEmpty: False; Description: 'Staleness output, paired with inputs.'),
    (Name: 'script'; ValueKind: mvkAny; Requirement: mrOptional;
      DefaultValue: ''; Scope: mscAllManifests;
      InvalidPolicy: mipDomainError;
      NonEmpty: False; Description: 'Retired; use command and args.')
  );

  RESERVED_TASK_NAMES: array[0..20] of string = (
    'install', 'add', 'remove', 'build', 'format', 'test', 'repair',
    'init', 'run', 'agents', 'health', 'duplication',
    'package', 'dependencies', 'sources', 'workspaces', 'version',
    PROGRAM_NAME, 'analysis', 'compiler', 'generated');

function ManifestSchemaSection(
  ASection: TLWPTManifestSchemaSection): TLWPTManifestSectionSpec;
begin
  Result := MANIFEST_SECTIONS[ASection];
end;

function ManifestSchemaField(
  AField: TLWPTManifestSchemaField): TLWPTManifestFieldSpec;
begin
  Result := MANIFEST_FIELDS[AField];
end;

function ManifestValueKindText(AKind: TLWPTManifestValueKind): string;
begin
  case AKind of
    mvkAny: Result := 'retired';
    mvkString: Result := 'string';
    mvkInteger: Result := 'integer';
    mvkStringArray: Result := 'array of strings';
    mvkTable: Result := 'table';
    mvkStringOrTable: Result := 'string or table';
  end;
end;

function ManifestInvalidPolicyText(
  APolicy: TLWPTManifestInvalidPolicy): string;
begin
  case APolicy of
    mipError: Result := 'invalid values are errors';
    mipDomainError: Result := 'invalid values are errors';
    mipIgnoreAsAbsent: Result := 'invalid values are ignored as absent';
    mipSkipInvalidItems: Result := 'invalid values and items are skipped';
    mipLegacyPassThrough: Result := 'other values retain legacy handling';
  end;
end;

function ManifestUnknownKeyPolicyText(
  APolicy: TLWPTManifestUnknownKeyPolicy): string;
begin
  case APolicy of
    mukIgnore: Result := 'unknown keys are ignored';
    mukError: Result := 'unknown keys are errors';
  end;
end;

function ManifestScopeText(AScope: TLWPTManifestScope): string;
begin
  case AScope of
    mscAllManifests: Result := 'all manifests';
    mscRootOnly: Result := 'root manifest only';
  end;
end;

function ManifestRequirementText(
  ARequirement: TLWPTManifestRequirement): string;
begin
  case ARequirement of
    mrOptional: Result := 'optional';
    mrRequired: Result := 'required';
    mrRequiredDomain: Result := 'required';
    mrConditional: Result := 'conditional';
  end;
end;

function IsKnownManifestSection(const AName: string): Boolean;
var
  Section: TLWPTManifestSchemaSection;
  Names: string;
  Delimiter: SizeInt;
begin
  for Section := Low(TLWPTManifestSchemaSection)
    to High(TLWPTManifestSchemaSection) do
  begin
    Names := MANIFEST_SECTIONS[Section].TopLevelNames;
    while Names <> '' do
    begin
      Delimiter := Pos('|', Names);
      if Delimiter = 0 then
      begin
        if AName = Names then Exit(True);
        Names := '';
      end
      else
      begin
        if AName = Copy(Names, 1, Delimiter - 1) then Exit(True);
        Delete(Names, 1, Delimiter);
      end;
    end;
  end;
  Result := False;
end;

function IsReservedManifestTaskName(const AName: string): Boolean;
var
  NameIndex: Integer;
begin
  for NameIndex := Low(RESERVED_TASK_NAMES) to High(RESERVED_TASK_NAMES) do
    if SameText(AName, RESERVED_TASK_NAMES[NameIndex]) then Exit(True);
  Result := False;
end;

function NodeMatchesKind(ANode: TTOMLNode;
  AKind: TLWPTManifestValueKind): Boolean;
begin
  case AKind of
    mvkAny: Result := True;
    mvkString: Result := TomlIsString(ANode);
    mvkInteger: Result := TomlIsInt(ANode);
    mvkStringArray: Result := TomlIsArray(ANode);
    mvkTable: Result := TomlIsTable(ANode);
    mvkStringOrTable: Result := TomlIsString(ANode) or TomlIsTable(ANode);
  end;
end;

function ExpectedValueText(AKind: TLWPTManifestValueKind): string;
begin
  case AKind of
    mvkInteger,
    mvkStringArray: Result := 'an ' + ManifestValueKindText(AKind);
  else
    Result := 'a ' + ManifestValueKindText(AKind);
  end;
end;

procedure ValidateFieldValue(ANode: TTOMLNode;
  AField: TLWPTManifestSchemaField; const APath: string;
  AIsRoot: Boolean);
var
  FieldSpec: TLWPTManifestFieldSpec;
  ItemIndex: Integer;
begin
  FieldSpec := MANIFEST_FIELDS[AField];
  if (FieldSpec.Scope = mscRootOnly) and not AIsRoot then Exit;
  if ANode = nil then
  begin
    if FieldSpec.Requirement = mrRequired then
      raise EManifestError.CreateFmt('%s is required', [APath]);
    Exit;
  end;
  if (FieldSpec.ValueKind = mvkAny)
    and (FieldSpec.InvalidPolicy = mipError) then
    raise EManifestError.CreateFmt('%s is retired', [APath]);
  if not NodeMatchesKind(ANode, FieldSpec.ValueKind) then
  begin
    if FieldSpec.InvalidPolicy = mipError then
      raise EManifestError.CreateFmt('%s must be %s',
        [APath, ExpectedValueText(FieldSpec.ValueKind)]);
    Exit;
  end;
  if (FieldSpec.ValueKind = mvkString) and FieldSpec.NonEmpty
    and (FieldSpec.Requirement <> mrRequiredDomain)
    and (ANode.ScalarText = '') then
    raise EManifestError.CreateFmt('%s must not be empty', [APath]);
  if FieldSpec.ValueKind <> mvkStringArray then Exit;
  if FieldSpec.InvalidPolicy <> mipError then Exit;
  for ItemIndex := 0 to ANode.Items.Count - 1 do
  begin
    if not TomlIsString(ANode.Items[ItemIndex]) then
      raise EManifestError.CreateFmt('%s[%d] must be a string',
        [APath, ItemIndex]);
    if FieldSpec.NonEmpty and (ANode.Items[ItemIndex].ScalarText = '') then
      raise EManifestError.CreateFmt('%s[%d] must not be empty',
        [APath, ItemIndex]);
  end;
end;

function FieldIsDeclared(AField: TLWPTManifestSchemaField;
  const AName: string): Boolean;
begin
  Result := (MANIFEST_FIELDS[AField].Name = AName)
    and (AName <> '<name>');
end;

procedure ValidateTableFields(ANode: TTOMLNode;
  ASection: TLWPTManifestSchemaSection; const APath: string;
  AIsRoot: Boolean);
var
  SectionSpec: TLWPTManifestSectionSpec;
  Field: TLWPTManifestSchemaField;
  Pair: TTOMLNodeMap.TKeyValuePair;
  Known: Boolean;
begin
  if not TomlIsTable(ANode) then Exit;
  SectionSpec := MANIFEST_SECTIONS[ASection];
  for Field := SectionSpec.FirstField to SectionSpec.LastField do
    if MANIFEST_FIELDS[Field].Name <> '<name>' then
      ValidateFieldValue(TomlGet(ANode, MANIFEST_FIELDS[Field].Name), Field,
        APath + '.' + MANIFEST_FIELDS[Field].Name, AIsRoot);
  if SectionSpec.UnknownKeyPolicy <> mukError then Exit;
  for Pair in ANode.Children do
  begin
    Known := False;
    for Field := SectionSpec.FirstField to SectionSpec.LastField do
      if FieldIsDeclared(Field, Pair.Key) then
      begin
        Known := True;
        Break;
      end;
    if not Known then
      raise EManifestError.CreateFmt('%s has unknown field "%s"',
        [APath, Pair.Key]);
  end;
end;

function ValidateSectionNode(ARoot: TTOMLNode; const AName: string;
  ASection: TLWPTManifestSchemaSection; AIsRoot: Boolean): TTOMLNode;
var
  SectionSpec: TLWPTManifestSectionSpec;
begin
  Result := TomlGet(ARoot, AName);
  if Result = nil then Exit;
  SectionSpec := MANIFEST_SECTIONS[ASection];
  if (SectionSpec.Scope = mscRootOnly) and not AIsRoot then Exit(nil);
  if TomlIsTable(Result) then Exit;
  if SectionSpec.InvalidPolicy = mipError then
    raise EManifestError.CreateFmt('[%s] must be a table', [AName]);
  Result := nil;
end;

procedure ValidateHookMap(ANode: TTOMLNode; const APath: string;
  AIsRoot: Boolean);
var
  Pair: TTOMLNodeMap.TKeyValuePair;
begin
  if not TomlIsTable(ANode) then Exit;
  for Pair in ANode.Children do
  begin
    if not NodeMatchesKind(Pair.Value, mvkStringOrTable) then
      raise EManifestError.CreateFmt('%s.%s must be string or table',
        [APath, Pair.Key]);
    if TomlIsTable(Pair.Value) then
      ValidateTableFields(Pair.Value, mssHookEntry,
        APath + '.' + Pair.Key, AIsRoot);
  end;
end;

procedure ValidateManifestStructure(ARoot: TTOMLNode; AIsRoot: Boolean);
const
  HOOK_SECTION_NAMES: array[0..5] of string = (
    'preinstall', 'postinstall', 'prebuild', 'postbuild', 'pretest',
    'posttest');
var
  Node, Entries, EntryNode: TTOMLNode;
  Pair: TTOMLNodeMap.TKeyValuePair;
  HookIndex: Integer;
begin
  Node := ValidateSectionNode(ARoot, 'package', mssPackage, AIsRoot);
  ValidateTableFields(Node, mssPackage, 'package', AIsRoot);

  Node := ValidateSectionNode(ARoot, 'sources', mssSources, AIsRoot);
  if TomlIsTable(Node) then
    for Pair in Node.Children do
      if TomlIsTable(Pair.Value) then
        ValidateTableFields(Pair.Value, mssSourceEntry,
          'sources.' + Pair.Key, AIsRoot);

  Node := ValidateSectionNode(ARoot, 'dependencies', mssDependencies,
    AIsRoot);
  if TomlIsTable(Node) then
    for Pair in Node.Children do
      if TomlIsTable(Pair.Value) then
        ValidateTableFields(Pair.Value, mssDependencyEntry,
          'dependencies.' + Pair.Key, AIsRoot);

  Node := ValidateSectionNode(ARoot, 'workspaces', mssWorkspaces, AIsRoot);
  ValidateTableFields(Node, mssWorkspaces, 'workspaces', AIsRoot);

  Node := ValidateSectionNode(ARoot, 'analysis', mssAnalysis, AIsRoot);
  ValidateTableFields(Node, mssAnalysis, 'analysis', AIsRoot);
  Node := ValidateSectionNode(ARoot, 'health', mssHealth, AIsRoot);
  ValidateTableFields(Node, mssHealth, 'health', AIsRoot);
  Node := ValidateSectionNode(ARoot, 'duplication', mssDuplication, AIsRoot);
  ValidateTableFields(Node, mssDuplication, 'duplication', AIsRoot);
  Node := ValidateSectionNode(ARoot, 'test', mssTest, AIsRoot);
  ValidateTableFields(Node, mssTest, 'test', AIsRoot);

  Node := ValidateSectionNode(ARoot, 'compiler', mssCompiler, AIsRoot);
  ValidateTableFields(Node, mssCompiler, 'compiler', AIsRoot);
  if TomlIsTable(Node) then
  begin
    Entries := TomlGet(Node, 'profiles');
    if TomlIsTable(Entries) then
      for Pair in Entries.Children do
      begin
        if not TomlIsTable(Pair.Value) then
          raise EManifestError.CreateFmt(
            '[compiler.profiles.%s] must be a table', [Pair.Key]);
        ValidateTableFields(Pair.Value, mssCompilerProfile,
          'compiler.profiles.' + Pair.Key, AIsRoot);
      end;
  end;

  Node := ValidateSectionNode(ARoot, 'build', mssBuild, AIsRoot);
  if TomlIsTable(Node) then
  begin
    if TomlIsString(TomlGet(Node, 'source')) then
    begin
      ValidateTableFields(Node, mssBuildEntry, 'build', AIsRoot);
      EntryNode := TomlGet(Node, 'target');
      if AIsRoot and (EntryNode <> nil) then
      begin
        if not TomlIsTable(EntryNode) then
          raise EManifestError.Create('build.target must be a table');
        ValidateTableFields(EntryNode, mssBuildTarget, 'build.target',
          AIsRoot);
      end;
      ValidateHookMap(TomlGet(Node, 'prebuild'), 'build.prebuild', AIsRoot);
      ValidateHookMap(TomlGet(Node, 'postbuild'), 'build.postbuild', AIsRoot);
    end
    else
      for Pair in Node.Children do
        if TomlIsTable(Pair.Value) then
        begin
          ValidateTableFields(Pair.Value, mssBuildEntry,
            'build.' + Pair.Key, AIsRoot);
          EntryNode := TomlGet(Pair.Value, 'target');
          if AIsRoot and (EntryNode <> nil) then
          begin
            if not TomlIsTable(EntryNode) then
              raise EManifestError.CreateFmt('build.%s.target must be a table',
                [Pair.Key]);
            ValidateTableFields(EntryNode, mssBuildTarget,
              'build.' + Pair.Key + '.target', AIsRoot);
          end;
          ValidateHookMap(TomlGet(Pair.Value, 'prebuild'),
            'build.' + Pair.Key + '.prebuild', AIsRoot);
          ValidateHookMap(TomlGet(Pair.Value, 'postbuild'),
            'build.' + Pair.Key + '.postbuild', AIsRoot);
        end;
  end;

  ValidateTableFields(ValidateSectionNode(ARoot, 'version', mssVersion,
    AIsRoot), mssVersion, 'version', AIsRoot);
  ValidateTableFields(ValidateSectionNode(ARoot, PROGRAM_NAME, mssToolkit,
    AIsRoot), mssToolkit, PROGRAM_NAME, AIsRoot);
  ValidateTableFields(ValidateSectionNode(ARoot, 'format', mssFormat,
    AIsRoot), mssFormat, 'format', AIsRoot);

  if AIsRoot then
  begin
    for HookIndex := Low(HOOK_SECTION_NAMES) to High(HOOK_SECTION_NAMES) do
    begin
      Node := ValidateSectionNode(ARoot, HOOK_SECTION_NAMES[HookIndex],
        mssLifecycleHooks, True);
      ValidateHookMap(Node, HOOK_SECTION_NAMES[HookIndex], True);
    end;
    for Pair in ARoot.Children do
      if not IsKnownManifestSection(Pair.Key)
        and TomlIsTable(Pair.Value)
        and ((TomlGet(Pair.Value, 'command') <> nil)
          or (TomlGet(Pair.Value, 'script') <> nil)) then
        ValidateTableFields(Pair.Value, mssRunTask, Pair.Key, True);
  end;
end;

end.
