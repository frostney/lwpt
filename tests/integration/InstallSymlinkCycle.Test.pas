{ InstallSymlinkCycle.Test — regression test: install-time tree walks
  must not walk THROUGH directory symlinks in a dependency's tree.

  Monorepo-local deps (path inside the project root) are installed as a
  symlink, so install-time tree walks (HashTree's CollectFiles, the
  FindModuleManifest BFS) traverse the dep's REAL tree — including any
  symlinks a user keeps in it. Unguarded, two distinct defects follow:

  1. loop -> .   (a link cycle): both walkers descend it repeatedly,
     re-enumerating the whole tree once per nesting level until the OS
     path-length limit finally stops them — wasted work, and phantom
     loop/... entries folded into lwpt.lock's computedHash.
  2. mirror -> packages   (a duplicate view): the manifest BFS sights
     the same nested lwpt.toml at the same depth through both names,
     reads that as "two manifests, ambiguous", and silently falls back
     to manifest-less behavior — the dep's units dirs and transitive
     deps are lost. This is the deterministic regression assertion:
     pre-guard the cfg loses the -Fu for the nested units dir.
  3. dangling -> does-not-exist : invisible to a faAnyFile-only
     FindFirst (the enumeration stats through the link and skips it),
     so WipeDir left it behind and failed on the non-empty dir — the
     suite could never re-run over its own scratch. CollectFiles must
     also keep excluding it (a dangling link cannot be opened/hashed).

  Unix-only in substance: the links are created with FpSymlink. On
  Windows the fixture degrades to a plain nested-manifest dep, which
  still exercises the walkers, just without the links.

  Layout built into a per-test scratch:

    root/vendor/cyclic/packages/leaf/lwpt.toml   nested manifest,
                                                 units=["src"]
    root/vendor/cyclic/packages/leaf/src/CycLeaf.pas
    root/vendor/cyclic/loop -> .                 the cycle (Unix only)
    root/vendor/cyclic/mirror -> packages        the duplicate view
    root/vendor/cyclic/dangling -> does-not-exist  the wipe survivor
    root/lwpt.toml                               cyclic = "./vendor/cyclic" }

program InstallSymlinkCycle.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Command.Install,
  LWPT.Core,
  TestingPascalLibrary;

type
  TInstallSymlinkCycle = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestInstallTerminatesAndLinksModule;
    procedure TestNestedManifestFoundDespiteCycle;
    procedure TestLockfileHashComputed;
  end;

procedure WriteTextFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

function ReadFileText(const APath: string): string;
var SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(APath);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ── lifecycle ─────────────────────────────────────────────────────── }

procedure TInstallSymlinkCycle.BeforeAll;
begin
  FOrigDir := GetCurrentDir;
  FScratch := ExpandFileName(
    FOrigDir + '/build/tests/tmp/install-symlink-cycle');
  FRoot    := FScratch + '/root';

  WipeDir(FScratch);

  { Local dep INSIDE the project root → installed via symlink, so the
    walkers see the real tree below. Manifest is nested (packages/leaf)
    so the BFS has to walk past the cycle entry to find it. }
  WriteTextFile(FRoot + '/vendor/cyclic/packages/leaf/' + MANIFEST_FILE,
      '[package]'#10
    + 'name = "cyclic"'#10
    + 'version = "1.0.0"'#10
    + 'units = ["src"]'#10);
  WriteTextFile(FRoot + '/vendor/cyclic/packages/leaf/src/CycLeaf.pas',
    'unit CycLeaf;'#10'interface'#10'implementation'#10'end.'#10);

  {$IFDEF UNIX}
  { loop -> . : resolves to its own parent, the minimal directory
    cycle. mirror -> packages : a second name for the manifest's
    parent, the false-ambiguity trap. }
  if FpSymlink('.',
       PAnsiChar(FRoot + '/vendor/cyclic/loop')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for cycle link');
  if FpSymlink('packages',
       PAnsiChar(FRoot + '/vendor/cyclic/mirror')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for mirror link');
  if FpSymlink('does-not-exist',
       PAnsiChar(FRoot + '/vendor/cyclic/dangling')) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for dangling link');
  {$ENDIF}

  WriteTextFile(FRoot + '/' + MANIFEST_FILE,
      '[package]'#10
    + 'name = "cycle-root"'#10
    + 'version = "0.0.0"'#10
    + 'units = ["src"]'#10
    + #10
    + '[dependencies]'#10
    + 'cyclic = "./vendor/cyclic"'#10);
  WriteTextFile(FRoot + '/src/RootMain.pas',
    'unit RootMain;'#10'interface'#10'implementation'#10'end.'#10);

  SetCurrentDir(FRoot);
  { The regression assertion: this returns at all. }
  CmdInstall(MANIFEST_FILE, False);
end;

procedure TInstallSymlinkCycle.AfterAll;
begin
  SetCurrentDir(FOrigDir);
  { Leave FScratch in place on failure so artefacts are inspectable. }
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TInstallSymlinkCycle.TestInstallTerminatesAndLinksModule;
begin
  Expect<Boolean>(DirectoryExists(FRoot + '/' + MODULES_DIR + '/cyclic'))
    .ToBe(True);
  Expect<Boolean>(FileExists(FRoot
    + '/' + MODULES_DIR + '/cyclic/packages/leaf/' + MANIFEST_FILE))
    .ToBe(True);
end;

procedure TInstallSymlinkCycle.TestNestedManifestFoundDespiteCycle;
var Cfg: string;
begin
  Expect<Boolean>(FileExists(FRoot + '/' + CFG_FILE)).ToBe(True);
  Cfg := ReadFileText(FRoot + '/' + CFG_FILE);
  { The BFS must skip the cycle link and still find the nested
    manifest — and must NOT see it twice through the link (which
    would read as ambiguous and fall back to the module root). }
  Expect<Boolean>(
    Pos('-Fu' + MODULES_DIR + '/cyclic/packages/leaf/src', Cfg) > 0)
    .ToBe(True);
end;

procedure TInstallSymlinkCycle.TestLockfileHashComputed;
var Lock: string;
begin
  { HashTree ran over the cycle-bearing tree and terminated with a
    real digest. }
  Expect<Boolean>(FileExists(FRoot + '/' + LOCKFILE)).ToBe(True);
  Lock := ReadFileText(FRoot + '/' + LOCKFILE);
  Expect<Boolean>(Pos('[package.cyclic]', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('sha256:', Lock) > 0).ToBe(True);
end;

procedure TInstallSymlinkCycle.SetupTests;
begin
  Test('install: terminates on a dir-symlink cycle and links the module',
    TestInstallTerminatesAndLinksModule);
  Test('install: nested manifest found once, not duplicated via the link',
    TestNestedManifestFoundDespiteCycle);
  Test('install: lockfile computedHash terminates over the cyclic tree',
    TestLockfileHashComputed);
end;

begin
  TestRunnerProgram.AddSuite(TInstallSymlinkCycle.Create(
    'install: symlink-cycle termination'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
