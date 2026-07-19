{ Scratch.Test — focused coverage for invocation-private test roots. }

program Scratch.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  SysUtils,

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

procedure TScratch.SetupTests;
begin
  Test('roots are unique across calls', TestRootsAreUniqueAcrossCalls);
  Test('reaping deletes dead owner and leaves live owner',
    TestReapingDeletesDeadAndLeavesLiveOwner);
end;

begin
  TestRunnerProgram.AddSuite(TScratch.Create('Scratch'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
