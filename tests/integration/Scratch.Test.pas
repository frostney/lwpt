{ Scratch.Test — focused coverage for invocation-private test roots. }

program Scratch.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.Core,
  TestingPascalLibrary,
  Tests.Scratch;

const
  DeadLinkPIDSlug = 'zik0zi';
  DeadPIDSlug = 'zik0zj';

type
  TScratch = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRootsAreUniqueAcrossCalls;
    procedure TestReapingDeletesDeadAndLeavesLiveOwner;
    procedure TestRecursiveDeleteRemovesTreesPastMaxPath;
  end;

procedure TScratch.TestRootsAreUniqueAcrossCalls;
var
  FirstRoot, SecondRoot: string;
begin
  FirstRoot := CreateScratchRoot('scratch-unique');
  SecondRoot := CreateScratchRoot('scratch-unique');
  try
    Expect<Boolean>(FirstRoot <> SecondRoot).ToBe(True);
    Expect<Boolean>(DirectoryExists(FirstRoot)).ToBe(True);
    Expect<Boolean>(DirectoryExists(SecondRoot)).ToBe(True);
  finally
    RecursiveDelete(FirstRoot);
    RecursiveDelete(SecondRoot);
  end;
end;

procedure TScratch.TestReapingDeletesDeadAndLeavesLiveOwner;
var
  Base, DeadLink, DeadRoot, LiveRoot, NextRoot: string;
begin
  LiveRoot := CreateScratchRoot('scratch-reaping');
  Base := IncludeTrailingPathDelimiter(ExtractFileDir(LiveRoot));
  DeadRoot := Base + 'scratch-reaping-' + DeadPIDSlug + '-0';
  ForceDirectories(DeadRoot);
  WriteTextFile(DeadRoot + '/dead', 'dead');
  DeadLink := '';
  {$IFDEF UNIX}
  DeadLink := Base + 'scratch-reaping-' + DeadLinkPIDSlug + '-0';
  if FpSymlink(PAnsiChar(LiveRoot), PAnsiChar(DeadLink)) <> 0 then
    raise Exception.Create('fixture: FpSymlink failed for stale root');
  {$ENDIF}
  WriteTextFile(LiveRoot + '/alive', 'alive');
  NextRoot := '';
  try
    NextRoot := CreateScratchRoot('scratch-reaping');
    Expect<Boolean>(not DirectoryExists(DeadRoot)).ToBe(True);
    {$IFDEF UNIX}
    Expect<Boolean>(not DirectoryExists(DeadLink)).ToBe(True);
    {$ENDIF}
    Expect<Boolean>(DirectoryExists(LiveRoot)).ToBe(True);
    Expect<Boolean>(FileExists(LiveRoot + '/alive')).ToBe(True);
  finally
    RecursiveDelete(LiveRoot);
    RecursiveDelete(NextRoot);
    RecursiveDelete(DeadRoot);
    RecursiveDelete(DeadLink);
  end;
end;

{ #347: toolkit code legitimately nests state past the Windows MAX_PATH, so
  scratch cleanup must remove such trees. The fixture is written with the
  Core long-path helpers; the wipe uses only Tests.Scratch. }
procedure TScratch.TestRecursiveDeleteRemovesTreesPastMaxPath;
const
  { Win32 MAX_PATH, including the terminating NUL. }
  LEGACY_WINDOWS_MAX_PATH = 260;
var
  Root, Deep, FilePath: string;
  Stream: TLWPTProtectedFileStream;
begin
  Root := CreateScratchRoot('scratch-deep');
  Deep := Root;
  while Length(Deep) <= LEGACY_WINDOWS_MAX_PATH + 20 do
    Deep := Deep + '/' + StringOfChar('d', 48);
  FilePath := Deep + '/' + StringOfChar('f', 40) + '.txt';
  Expect<Boolean>(Length(FilePath) > LEGACY_WINDOWS_MAX_PATH).ToBe(True);
  Expect<Boolean>(LongPathForceDirectories(Deep + '/empty')).ToBe(True);
  Stream := OpenProtectedFileStream(FilePath, fmCreate);
  Stream.Free;
  Expect<Boolean>(LongPathFileExists(FilePath)).ToBe(True);

  RecursiveDelete(Root);

  Expect<Boolean>(LongPathFileExists(FilePath)).ToBe(False);
  Expect<Boolean>(LongPathDirectoryExists(Root)).ToBe(False);
end;

procedure TScratch.SetupTests;
begin
  Test('roots are unique across calls', TestRootsAreUniqueAcrossCalls);
  Test('recursive delete removes a tree past MAX_PATH',
    TestRecursiveDeleteRemovesTreesPastMaxPath);
  Test('reaping deletes dead owner and leaves live owner',
    TestReapingDeletesDeadAndLeavesLiveOwner);
end;

begin
  TestRunnerProgram.AddSuite(TScratch.Create('Scratch'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
