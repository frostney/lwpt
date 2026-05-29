{ InstallLocalDiamond.Test — integration test for the transitive
  resolver against the canonical diamond graph:

                  root
                  /  \
             branch-a  branch-b
                  \  /
                  leaf-c

  Fixtures live under tests/fixtures/diamond/ (root, a, b, c, each a
  full lwpt.toml + minimal .pas source). The test:

    1. Copies the four fixture dirs into a per-test temp scratch
       (so the install doesn't pollute the fixtures and so successive
       runs are independent).
    2. chdir into the temp root/ and runs CmdInstall.
    3. Asserts on lwpt.lock (3 packages, names + sourceType), on
       lwpt.cfg (one -Fu per dep), and on the .lwpt/modules/ tree
       (each dep extracted with its source files present).
    4. Re-runs CmdInstall to confirm it's idempotent (no errors, lock
       and cfg unchanged).
    5. Runs CmdInstall --frozen and asserts it succeeds + does NOT
       overwrite the lockfile.

  This is the most-comprehensive happy-path test in v1 — it exercises
  LoadManifest, the BFS resolver, transitive child-manifest reading,
  conflict-check (vacuously, since all ranges match), local-source
  fetch, WriteLock, and WriteCfg in one pass. }

program InstallLocalDiamond.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  {$IFDEF MSWINDOWS}
  Process,
  {$ENDIF}
  StrUtils,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary;

type
  TInstallLocalDiamond = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot, FRepoRoot: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestInstallProducesLockfileWithThreePackages;
    procedure TestInstallProducesCfgWithThreeUnitPaths;
    procedure TestEachModuleTreeExists;
    procedure TestInstallIsIdempotent;
    procedure TestInstallReplacesBrokenModuleLink;
    procedure TestFrozenSucceedsWithoutRewritingLock;
  end;

  { --frozen must detect tampered modules trees (and tampered
    archive caches when those exist). Diamond uses local sources so
    there are no archives to tamper — the archive-hash mismatch case
    is exercised via a separate fixture (or once we have a network-
    backed fixture). Tree tampering is the canonical test here. }
  TFrozenTamperDetection = class(TTestSuite)
  private
    FOrigDir, FScratch, FRoot, FRepoRoot: string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll;  override;
  public
    procedure SetupTests; override;
    procedure TestFrozenDetectsTreeTamper;
    procedure TestRepairAndReinstallRestoresVerifiableState;
  end;

{ ── filesystem helpers (module-level so both suites share them) ─── }

procedure DiamondRecursiveCopy(const ASrc, ADst: string);
var
  SR: TSearchRec;
  SrcBase, DstBase: string;
  Stream: TFileStream;
  Sink:   TFileStream;
begin
  ForceDirectories(ADst);
  SrcBase := IncludeTrailingPathDelimiter(ASrc);
  DstBase := IncludeTrailingPathDelimiter(ADst);
  if FindFirst(SrcBase + '*', faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        DiamondRecursiveCopy(SrcBase + SR.Name, DstBase + SR.Name)
      else
      begin
        Stream := TFileStream.Create(SrcBase + SR.Name,
                    fmOpenRead or fmShareDenyNone);
        try
          Sink := TFileStream.Create(DstBase + SR.Name, fmCreate);
          try
            if Stream.Size > 0 then Sink.CopyFrom(Stream, Stream.Size);
          finally
            Sink.Free;
          end;
        finally
          Stream.Free;
        end;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure DiamondRecursiveDelete(const APath: string);
var
  SR: TSearchRec;
  Base: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          DiamondRecursiveDelete(Base + SR.Name)
        else
          DeleteFile(Base + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

procedure DiamondInstallToScratch(const ARepoRoot, AScratch, ARoot: string);
const
  PKGS: array[0..3] of string = ('root', 'a', 'b', 'c');
var i: Integer;
begin
  DiamondRecursiveDelete(AScratch);
  ForceDirectories(AScratch);
  for i := Low(PKGS) to High(PKGS) do
    DiamondRecursiveCopy(
      ARepoRoot + '/tests/fixtures/diamond/' + PKGS[i],
      AScratch + '/' + PKGS[i]);
  SetCurrentDir(ARoot);
  CmdInstall('lwpt.toml', False);
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

function PosCount(const AHaystack, ANeedle: string): Integer;
var P: Integer;
begin
  Result := 0;
  P := Pos(ANeedle, AHaystack);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx(ANeedle, AHaystack, P + Length(ANeedle));
  end;
end;

{ ── lifecycle ─────────────────────────────────────────────────────── }

procedure TInstallLocalDiamond.BeforeAll;
begin
  FOrigDir  := GetCurrentDir;
  { FRepoRoot is whatever CWD was when lwpt test launched this binary.
    The test's binary lives under build/tests/<...>/ and the fixtures
    under tests/fixtures/diamond/<...>/ — both resolved from CWD. }
  FRepoRoot := GetCurrentDir;
  FScratch  := ExpandFileName(
    FRepoRoot + '/build/tests/tmp/install-local-diamond');
  FRoot     := FScratch + '/root';
  DiamondInstallToScratch(FRepoRoot, FScratch, FRoot);
end;

procedure TInstallLocalDiamond.AfterAll;
begin
  SetCurrentDir(FOrigDir);
  { Leave FScratch in place on failure so artefacts are inspectable. }
end;

{ ── tests ─────────────────────────────────────────────────────────── }

procedure TInstallLocalDiamond.TestInstallProducesLockfileWithThreePackages;
var Lock: string;
begin
  Expect<Boolean>(FileExists(FRoot + '/lwpt.lock')).ToBe(True);
  Lock := ReadFileText(FRoot + '/lwpt.lock');
  Expect<Integer>(PosCount(Lock, '[package.')).ToBe(3);
  Expect<Boolean>(Pos('[package.branch-a]', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('[package.branch-b]', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('[package.leaf-c]', Lock) > 0).ToBe(True);
  { Schema v3: source kind is inferable from the locator string, so
    no sourceType field; the local-source locators are paths
    (../a, ../b, ../c). }
  Expect<Boolean>(Pos('source = "../a"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('source = "../b"', Lock) > 0).ToBe(True);
  Expect<Boolean>(Pos('source = "../c"', Lock) > 0).ToBe(True);
end;

procedure TInstallLocalDiamond.TestInstallProducesCfgWithThreeUnitPaths;
var Cfg: string;
begin
  Expect<Boolean>(FileExists(FRoot + '/lwpt.cfg')).ToBe(True);
  Cfg := ReadFileText(FRoot + '/lwpt.cfg');
  { Each dep contributes -Fu AND -Fi (Pascal convention: .inc files
    live next to the .pas units). The manifest's own units array adds
    one -Fu / -Fi pair for "src". With three deps + the manifest's
    "src", expect at least four -Fu lines and four -Fi lines. }
  Expect<Boolean>(PosCount(Cfg, '-Fu') >= 4).ToBe(True);
  Expect<Boolean>(PosCount(Cfg, '-Fi') >= 4).ToBe(True);
  Expect<Boolean>(Pos('branch-a', Cfg) > 0).ToBe(True);
  Expect<Boolean>(Pos('branch-b', Cfg) > 0).ToBe(True);
  Expect<Boolean>(Pos('leaf-c', Cfg) > 0).ToBe(True);
end;

procedure TInstallLocalDiamond.TestEachModuleTreeExists;
begin
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/branch-a'))
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/branch-b'))
    .ToBe(True);
  Expect<Boolean>(DirectoryExists(FRoot + '/.lwpt/modules/leaf-c'))
    .ToBe(True);

  { Spot-check the source content survived the copy. }
  Expect<Boolean>(FileExists(FRoot + '/.lwpt/modules/leaf-c/src/LeafC.pas'))
    .ToBe(True);
  Expect<Boolean>(FileExists(FRoot + '/.lwpt/modules/branch-a/src/BranchA.pas'))
    .ToBe(True);
end;

procedure TInstallLocalDiamond.TestInstallIsIdempotent;
var Lock1, Lock2: string;
begin
  Lock1 := ReadFileText(FRoot + '/lwpt.lock');
  CmdInstall('lwpt.toml', False);
  Lock2 := ReadFileText(FRoot + '/lwpt.lock');
  Expect<string>(Lock2).ToBe(Lock1);
end;

procedure TInstallLocalDiamond.TestInstallReplacesBrokenModuleLink;
var
  ModulePath: string;
  {$IFDEF UNIX}
  MissingTargetPath: string;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  TargetPath: string;
  P: TProcess;
  {$ENDIF}
begin
  ModulePath := FRoot + '/.lwpt/modules/branch-a';
  DiamondRecursiveDelete(ModulePath);

  {$IFDEF UNIX}
  MissingTargetPath := FScratch + '/missing-branch-a-target';
  DiamondRecursiveDelete(MissingTargetPath);
  if FileExists(MissingTargetPath) then
    DeleteFile(MissingTargetPath);
  Expect<Integer>(FpSymlink(
    PChar(MissingTargetPath),
    PChar(ModulePath))).ToBe(0);
  {$ENDIF}

  {$IFDEF MSWINDOWS}
  TargetPath := FScratch + '/missing-junction-target';
  DiamondRecursiveDelete(TargetPath);
  ForceDirectories(TargetPath);
  P := TProcess.Create(nil);
  try
    P.Executable := 'cmd.exe';
    P.Parameters.Add('/C');
    P.Parameters.Add('mklink /J "' +
      StringReplace(ModulePath, '/', '\', [rfReplaceAll]) + '" "' +
      StringReplace(TargetPath, '/', '\', [rfReplaceAll]) + '"');
    P.Options := [poWaitOnExit];
    P.Execute;
    Expect<Integer>(P.ExitStatus).ToBe(0);
  finally
    P.Free;
  end;
  DiamondRecursiveDelete(TargetPath);
  {$ENDIF}

  CmdInstall('lwpt.toml', False);
  Expect<Boolean>(FileExists(ModulePath + '/src/BranchA.pas')).ToBe(True);
end;

procedure TInstallLocalDiamond.TestFrozenSucceedsWithoutRewritingLock;
var
  LockBefore, LockAfter: string;
  Raised: Boolean;
begin
  LockBefore := ReadFileText(FRoot + '/lwpt.lock');
  Raised := False;
  try
    CmdInstall('lwpt.toml', True);   { --frozen }
  except
    on E: Exception do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(False);
  LockAfter := ReadFileText(FRoot + '/lwpt.lock');
  Expect<string>(LockAfter).ToBe(LockBefore);
end;

procedure TInstallLocalDiamond.SetupTests;
begin
  Test('install: lockfile has three packages with the right names',
    TestInstallProducesLockfileWithThreePackages);
  Test('install: lwpt.cfg lists each dep''s -Fu path',
    TestInstallProducesCfgWithThreeUnitPaths);
  Test('install: each .lwpt/modules/<dep>/ tree exists with source files',
    TestEachModuleTreeExists);
  Test('install: re-running is idempotent (lockfile byte-equal)',
    TestInstallIsIdempotent);
  Test('install: broken .lwpt/modules link is replaced',
    TestInstallReplacesBrokenModuleLink);
  Test('install --frozen: succeeds + leaves the lockfile unchanged',
    TestFrozenSucceedsWithoutRewritingLock);
end;

{ ── TFrozenTamperDetection ────────────────────────────────────── }

procedure TFrozenTamperDetection.BeforeAll;
begin
  FOrigDir  := GetCurrentDir;
  FRepoRoot := GetCurrentDir;
  FScratch  := ExpandFileName(
    FRepoRoot + '/build/tests/tmp/install-frozen-tamper');
  FRoot     := FScratch + '/root';
  DiamondInstallToScratch(FRepoRoot, FScratch, FRoot);
end;

procedure TFrozenTamperDetection.AfterAll;
begin
  SetCurrentDir(FOrigDir);
end;

procedure TFrozenTamperDetection.TestFrozenDetectsTreeTamper;
var
  Tampered: string;
  Stream: TFileStream;
  Bytes: TBytes;
  Raised: Boolean;
  MsgContainsTreeMismatch: Boolean;
  Err: Exception;
begin
  { Append a byte to an extracted source file under .lwpt/modules/.
    The tree hash is sensitive to every file's bytes, so this must
    cause a mismatch on the next --frozen run. }
  Tampered := FRoot + '/.lwpt/modules/leaf-c/src/LeafC.pas';
  Expect<Boolean>(FileExists(Tampered)).ToBe(True);

  Stream := TFileStream.Create(Tampered, fmOpenWrite);
  try
    Stream.Position := Stream.Size;
    Bytes := BytesOf(#10 + '// tamper marker');
    Stream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;

  Raised := False;
  MsgContainsTreeMismatch := False;
  Err := nil;
  try
    CmdInstall('lwpt.toml', True);   { --frozen }
  except
    on E: EVerifyError do
    begin
      Raised := True;
      Err := Exception(AcquireExceptionObject);
      MsgContainsTreeMismatch :=
        (Pos('tree hash mismatch', E.Message) > 0)
        and (Pos('leaf-c', E.Message) > 0);
    end;
  end;
  try
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(MsgContainsTreeMismatch).ToBe(True);
  finally
    Err.Free;
  end;
end;

procedure TFrozenTamperDetection.TestRepairAndReinstallRestoresVerifiableState;
var Raised: Boolean;
begin
  { Re-run the full install (non-frozen) to regenerate the tree from
    the local source. Then --frozen should succeed cleanly — the
    tampered state is healed by a normal install. This is the
    documented recovery path for hash-mismatch errors. }
  CmdInstall('lwpt.toml', False);
  Raised := False;
  try
    CmdInstall('lwpt.toml', True);
  except
    on E: Exception do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(False);
end;

procedure TFrozenTamperDetection.SetupTests;
begin
  Test('--frozen detects extracted-tree tampering with EVerifyError',
    TestFrozenDetectsTreeTamper);
  Test('re-running install (non-frozen) restores a verifiable state',
    TestRepairAndReinstallRestoresVerifiableState);
end;

begin
  TestRunnerProgram.AddSuite(TInstallLocalDiamond.Create(
    'install: local-source diamond graph'));
  TestRunnerProgram.AddSuite(TFrozenTamperDetection.Create(
    'install --frozen: tamper detection'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
