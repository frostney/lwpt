{ LWPT.HookRuns.Test — the in-flight registry of gated runs (#442): which
  runs count as overlapping, how a nested run's ancestors are exempt, and
  how a dead run's marker is removed. A second process holds a marker
  through this program's own child mode. }
program LWPT.HookRuns.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  BaseUnix,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  LWPT.BuildSession,
  LWPT.Core,
  LWPT.HookRuns,
  TestingPascalLibrary,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  ChildArgument = '--hook-runs-holder';
  HolderMilliseconds = 60000;
  PollMilliseconds = 10;

type
  THookRunTests = class(TTestSuite)
  private
    FRoot, FRuns, FGuard: string;
    function RunFiles: Integer;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestSoleRunMayRecord;
    procedure TestOverlappingRunsMayNotRecord;
    procedure TestLaterRunFlagsEarlierRun;
    procedure TestAncestorDoesNotOverlap;
    procedure TestMalformedAncestorsAreIgnored;
    procedure TestDeadMarkerIsRemoved;
    procedure TestOtherProcessMarkerOverlaps;
    procedure TestUnfinishedRunLeavesNoMarker;
    {$IFDEF UNIX}
    procedure TestLinkedMarkerIsRemovedUnprobed;
    procedure TestLinkedLockIsRefused;
    procedure TestLockRedirectedBeforeFinishIsRefused;
    procedure TestLinkedStateDirectoryIsRefused;
    procedure TestUnlistableDirectoryIsRefused;
    {$ENDIF}
  end;

{ Child mode: hold a marker as another process would, until released. }
function RunHolder(const AMarker, AReady, ARelease: string): Integer;
var
  Guard: TObject;
  StartedAt: QWord;
begin
  Guard := AcquireOwnerGuard(AMarker, 'test marker');
  try
    WriteTextFile(AReady, '');
    StartedAt := GetTickCount64;
    while not FileExists(ARelease) do
    begin
      if GetTickCount64 - StartedAt >= HolderMilliseconds then Exit(1);
      Sleep(PollMilliseconds);
    end;
    Result := 0;
  finally
    Guard.Free;
  end;
end;

procedure THookRunTests.BeforeEach;
begin
  FRoot := CreateScratchRoot('hook-runs');
  FRuns := FRoot + '/out.runs';
  FGuard := FRoot + '/out.lock';
end;

procedure THookRunTests.AfterEach;
begin
  RecursiveDelete(FRoot);
end;

function THookRunTests.RunFiles: Integer;
var
  Search: TSearchRec;
begin
  Result := 0;
  if FindFirst(FRuns + '/*', faAnyFile, Search) = 0 then
  try
    repeat
      if (Search.Attr and faDirectory) = 0 then Inc(Result);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure THookRunTests.TestSoleRunMayRecord;
var
  Run: TLWPTHookRun;
begin
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Boolean>(FileExists(FRuns + '/' + Run.Id + '.run')).ToBe(True);
    Expect<Boolean>(Run.Finish).ToBe(True);
    Expect<Integer>(RunFiles).ToBe(0);
    { A run finishes once; a second call never permits a record. }
    Expect<Boolean>(Run.Finish).ToBe(False);
  finally
    Run.Free;
  end;
end;

procedure THookRunTests.TestOverlappingRunsMayNotRecord;
var
  First, Second: TLWPTHookRun;
begin
  First := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Second := TLWPTHookRun.Create(FRuns, FGuard, '');
    try
      Expect<Boolean>(Second.Finish).ToBe(False);
    finally
      Second.Free;
    end;
    Expect<Boolean>(First.Finish).ToBe(False);
  finally
    First.Free;
  end;
  Expect<Integer>(RunFiles).ToBe(0);
end;

{ The earlier run is flagged by the later one even when the later run has
  already finished when the earlier one does. }
procedure THookRunTests.TestLaterRunFlagsEarlierRun;
var
  First, Second: TLWPTHookRun;
begin
  First := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Second := TLWPTHookRun.Create(FRuns, FGuard, '');
    Second.Free;
    Expect<Boolean>(FileExists(FRuns + '/' + First.Id + '.overlapped'))
      .ToBe(True);
    Expect<Boolean>(First.Finish).ToBe(False);
  finally
    First.Free;
  end;
  { A run that starts after both finished overlaps nothing. }
  First := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Boolean>(First.Finish).ToBe(True);
  finally
    First.Free;
  end;
end;

{ Nested runs do not flag their ancestor, and while it runs they keep no
  record: its command may still write the output after them. }
procedure THookRunTests.TestAncestorDoesNotOverlap;
var
  Parent, Child, Grandchild: TLWPTHookRun;
  Ancestry: string;
begin
  Parent := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Ancestry := Parent.ChildEnvironment;
    Expect<string>(Ancestry).ToBe(HOOK_RUN_ANCESTORS_ENV + '=' + Parent.Id);
    Ancestry := Copy(Ancestry, Pos('=', Ancestry) + 1, MaxInt);
    Child := TLWPTHookRun.Create(FRuns, FGuard, Ancestry);
    try
      Expect<string>(Child.ChildEnvironment).ToBe(HOOK_RUN_ANCESTORS_ENV
        + '=' + Parent.Id + ',' + Child.Id);
      Grandchild := TLWPTHookRun.Create(FRuns, FGuard,
        Parent.Id + ',' + Child.Id);
      try
        Expect<Boolean>(Grandchild.Finish).ToBe(False);
      finally
        Grandchild.Free;
      end;
      Expect<Boolean>(Child.Finish).ToBe(False);
    finally
      Child.Free;
    end;
    Expect<Boolean>(Parent.Finish).ToBe(True);
  finally
    Parent.Free;
  end;
  { An ancestor that has finished no longer holds a nested run back. }
  Child := TLWPTHookRun.Create(FRuns, FGuard, Ancestry);
  try
    Expect<Boolean>(Child.Finish).ToBe(True);
  finally
    Child.Free;
  end;
end;

procedure THookRunTests.TestMalformedAncestorsAreIgnored;
var
  First, Second: TLWPTHookRun;
begin
  First := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    { Only exact, well-formed IDs exempt a run: a path, a glob or an ID
      with extra characters does not. }
    Second := TLWPTHookRun.Create(FRuns, FGuard,
      '../' + First.Id + ',*,' + First.Id + 'x, ' + First.Id);
    try
      Expect<string>(Second.ChildEnvironment).ToBe(HOOK_RUN_ANCESTORS_ENV
        + '=' + Second.Id);
      Expect<Boolean>(Second.Finish).ToBe(False);
    finally
      Second.Free;
    end;
    Expect<Boolean>(First.Finish).ToBe(False);
  finally
    First.Free;
  end;
end;

{ A marker whose owner exited without finishing is unlocked: it neither
  overlaps a new run nor stays behind, and neither does a leftover flag. }
procedure THookRunTests.TestDeadMarkerIsRemoved;
var
  Run: TLWPTHookRun;
begin
  ForceDirectories(FRuns);
  WriteTextFile(FRuns + '/1-2-3.run', '');
  WriteTextFile(FRuns + '/1-2-3.overlapped', '');
  WriteTextFile(FRuns + '/4-5-6.overlapped', '');
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Integer>(RunFiles).ToBe(1);
    Expect<Boolean>(Run.Finish).ToBe(True);
  finally
    Run.Free;
  end;
  Expect<Integer>(RunFiles).ToBe(0);
end;

procedure THookRunTests.TestOtherProcessMarkerOverlaps;
var
  Holder: TProcess;
  Run: TLWPTHookRun;
  Marker, Ready, Release: string;
  StartedAt: QWord;
  HolderExit: Integer;
begin
  ForceDirectories(FRuns);
  Marker := FRuns + '/7-8-9.run';
  Ready := FRoot + '/holder-ready';
  Release := FRoot + '/holder-release';
  Holder := TProcess.Create(nil);
  try
    Holder.Executable := ExpandFileName(ParamStr(0));
    Holder.Parameters.Add(ChildArgument);
    Holder.Parameters.Add(Marker);
    Holder.Parameters.Add(Ready);
    Holder.Parameters.Add(Release);
    Holder.Execute;
    try
      StartedAt := GetTickCount64;
      while not FileExists(Ready) do
      begin
        if not Holder.Running then
          raise Exception.Create('marker holder exited early');
        if GetTickCount64 - StartedAt >= HolderMilliseconds then
          raise Exception.Create('marker holder did not start');
        Sleep(PollMilliseconds);
      end;
      Run := TLWPTHookRun.Create(FRuns, FGuard, '');
      try
        { The live marker stays and is flagged; the new run may not record. }
        Expect<Boolean>(FileExists(Marker)).ToBe(True);
        Expect<Boolean>(FileExists(FRuns + '/7-8-9.overlapped')).ToBe(True);
        Expect<Boolean>(Run.Finish).ToBe(False);
      finally
        Run.Free;
      end;
      { With the holder as its ancestor, a run flags nothing, and keeps no
        record while the holder runs. }
      DeleteFile(FRuns + '/7-8-9.overlapped');
      Run := TLWPTHookRun.Create(FRuns, FGuard, '7-8-9');
      try
        Expect<Boolean>(FileExists(FRuns + '/7-8-9.overlapped')).ToBe(False);
        Expect<Boolean>(Run.Finish).ToBe(False);
      finally
        Run.Free;
      end;
    finally
      WriteTextFile(Release, '');
      HolderExit := FinishChild(Holder, HolderMilliseconds, 'marker holder');
    end;
    Expect<Integer>(HolderExit).ToBe(0);
  finally
    Holder.Free;
  end;
  { Once its owner is gone, the next registration removes its marker. }
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Boolean>(FileExists(Marker)).ToBe(False);
    Expect<Boolean>(Run.Finish).ToBe(True);
  finally
    Run.Free;
  end;
end;

procedure THookRunTests.TestUnfinishedRunLeavesNoMarker;
var
  Run: TLWPTHookRun;
begin
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  Run.Free;
  Expect<Integer>(RunFiles).ToBe(0);
end;

{$IFDEF UNIX}
{ A link in the runs directory is removed without opening what it names. }
procedure THookRunTests.TestLinkedMarkerIsRemovedUnprobed;
var
  Run: TLWPTHookRun;
  Target: string;
begin
  ForceDirectories(FRuns);
  Target := FRoot + '/target';
  WriteTextFile(Target, 'kept');
  Expect<Integer>(FpSymlink(PChar(Target), PChar(FRuns + '/1-1-1.run')))
    .ToBe(0);
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Boolean>(FileExists(FRuns + '/1-1-1.run')).ToBe(False);
    Expect<Boolean>(Run.Finish).ToBe(True);
  finally
    Run.Free;
  end;
  Expect<Boolean>(FileExists(Target)).ToBe(True);
end;
{$ENDIF}

{$IFDEF UNIX}
{ The short lock writes its holder's PID into its file, so a lock path that
  is a link is refused before anything is written through it. }
procedure THookRunTests.TestLinkedLockIsRefused;
var
  Target: string;
  Refused: Boolean;
begin
  Target := FRoot + '/target';
  WriteTextFile(Target, 'kept');
  Expect<Integer>(FpSymlink(PChar(Target), PChar(FGuard))).ToBe(0);
  Refused := False;
  try
    TLWPTHookRun.Create(FRuns, FGuard, '').Free;
  except
    on E: ELWPTError do Refused := True;
  end;
  Expect<Boolean>(Refused).ToBe(True);
  Expect<string>(Trim(ReadBinaryFile(Target))).ToBe('kept');
end;

{ A lock path redirected while the command ran is not written through when
  the run finishes, and the run keeps no record. }
procedure THookRunTests.TestLockRedirectedBeforeFinishIsRefused;
var
  Run: TLWPTHookRun;
  Target: string;
begin
  Target := FRoot + '/target';
  WriteTextFile(Target, 'kept');
  Run := TLWPTHookRun.Create(FRuns, FGuard, '');
  try
    Expect<Boolean>(DeleteFile(FGuard)).ToBe(True);
    Expect<Integer>(FpSymlink(PChar(Target), PChar(FGuard))).ToBe(0);
    Expect<Boolean>(Run.Finish).ToBe(False);
  finally
    Run.Free;
  end;
  Expect<string>(Trim(ReadBinaryFile(Target))).ToBe('kept');
end;

{ The directory above the lock's (hook-runs) may not be a link either. }
procedure THookRunTests.TestLinkedStateDirectoryIsRefused;
var
  Real, Linked: string;
  Refused: Boolean;
begin
  Real := FRoot + '/real';
  Linked := FRoot + '/linked';
  ForceDirectories(Real + '/active');
  Expect<Integer>(FpSymlink(PChar(Real), PChar(Linked))).ToBe(0);
  Refused := False;
  try
    TLWPTHookRun.Create(Linked + '/active/out.runs',
      Linked + '/active/out.lock', '').Free;
  except
    on E: ELWPTError do Refused := True;
  end;
  Expect<Boolean>(Refused).ToBe(True);
  Expect<Boolean>(FileExists(Real + '/active/out.lock')).ToBe(False);
end;

{ A directory that can be written but not listed would hide the other
  runs, so registration fails rather than run unseen. }
procedure THookRunTests.TestUnlistableDirectoryIsRefused;
var
  Refused: Boolean;
begin
  ForceDirectories(FRuns);
  Expect<Integer>(FpChmod(PChar(FRuns), &300)).ToBe(0);
  Refused := False;
  try
    try
      TLWPTHookRun.Create(FRuns, FGuard, '').Free;
    except
      on E: ELWPTError do Refused := True;
    end;
  finally
    FpChmod(PChar(FRuns), &700);
  end;
  Expect<Boolean>(Refused).ToBe(True);
end;
{$ENDIF}

procedure THookRunTests.SetupTests;
begin
  Test('a run that overlaps no other may record', TestSoleRunMayRecord);
  Test('two overlapping runs may not record',
    TestOverlappingRunsMayNotRecord);
  Test('a later run flags an earlier run that is still going',
    TestLaterRunFlagsEarlierRun);
  Test('nested runs flag no ancestor and record only after it finished',
    TestAncestorDoesNotOverlap);
  Test('malformed ancestor IDs are ignored',
    TestMalformedAncestorsAreIgnored);
  Test('a dead run''s marker is removed', TestDeadMarkerIsRemoved);
  Test('another process''s live marker overlaps',
    TestOtherProcessMarkerOverlaps);
  Test('an unfinished run leaves no marker', TestUnfinishedRunLeavesNoMarker);
  {$IFDEF UNIX}
  Test('a linked marker is removed without being probed',
    TestLinkedMarkerIsRemovedUnprobed);
  Test('a linked lock path is refused', TestLinkedLockIsRefused);
  Test('a lock redirected before the run finishes is not written through',
    TestLockRedirectedBeforeFinishIsRefused);
  Test('a linked state directory above the lock is refused',
    TestLinkedStateDirectoryIsRefused);
  { Permission bits do not restrict the superuser. }
  if FpGetEUID = 0 then
    Skip('a directory that cannot be listed is refused',
      TestUnlistableDirectoryIsRefused, 'running as the superuser')
  else
    Test('a directory that cannot be listed is refused',
      TestUnlistableDirectoryIsRefused);
  {$ENDIF}
end;

begin
  if (ParamCount = 4) and (ParamStr(1) = ChildArgument) then
    Halt(RunHolder(ParamStr(2), ParamStr(3), ParamStr(4)));
  TestRunnerProgram.AddSuite(THookRunTests.Create('hook runs'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
