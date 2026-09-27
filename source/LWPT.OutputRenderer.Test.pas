program LWPT.OutputRenderer.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.OutputRenderer,
  TestingPascalLibrary,
  Tests.SpawnGuardProbe;

type
  TLWPTEmergencyRingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestChunkedOutputPreservesMostRecentTail;
    {$IFDEF UNIX}
    procedure TestSilentJournalStaysOutOfChildren;
    procedure TestDescriptorReporterSeesInheritance;
    {$ENDIF}
  end;

procedure TLWPTEmergencyRingTests.TestChunkedOutputPreservesMostRecentTail;
const
  SECOND_CHUNK_BYTES = 700000;
var
  FirstChunk, SecondChunk, Tail: RawByteString;
  Ring: TLWPTEmergencyRing;
begin
  FirstChunk := StringOfChar('a', 700000);
  SecondChunk := StringOfChar('b', SECOND_CHUNK_BYTES);
  Ring := TLWPTEmergencyRing.Create(SizeInt(SilentEmergencyReserveBytes));
  try
    Ring.Append(FirstChunk);
    Ring.Append(SecondChunk);
    Tail := Ring.Tail;
    Expect<Integer>(Length(Tail)).ToBe(
      Integer(SilentEmergencyReserveBytes));
    Expect<string>(Copy(Tail, 1,
      Length(Tail) - SECOND_CHUNK_BYTES)).ToBe(
      StringOfChar('a', Length(Tail) - SECOND_CHUNK_BYTES));
    Expect<string>(Copy(Tail, Length(Tail) - SECOND_CHUNK_BYTES + 1,
      SECOND_CHUNK_BYTES)).ToBe(SecondChunk);
  finally
    Ring.Free;
  end;
end;

{$IFDEF UNIX}
function SilentJournalCandidates: TStringList;
var
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(GetTempDir(False) + 'lwpt*', faAnyFile, Search) = 0 then
  try
    repeat
      Result.Add(GetTempDir(False) + Search.Name);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{ Build and test commands spawn compilers, hooks and test programs while a
  silent invocation keeps its read-write output journal open. None of those
  children may inherit the journal. }
procedure TLWPTEmergencyRingTests.TestSilentJournalStaysOutOfChildren;
var
  Before, After: TStringList;
  Journals: array of string;
  Index, InheritedCount: Integer;
  Renderer: TLWPTOutputRenderer;
begin
  Before := SilentJournalCandidates;
  After := nil;
  Renderer := TLWPTOutputRenderer.Create;
  try
    Renderer.BeginSilent('journal-inheritance');
    try
      After := SilentJournalCandidates;
      SetLength(Journals, 0);
      for Index := 0 to After.Count - 1 do
        if Before.IndexOf(After[Index]) < 0 then
        begin
          SetLength(Journals, Length(Journals) + 1);
          Journals[High(Journals)] := After[Index];
        end;
      InheritedCount := ChildInheritedFileCount(Journals,
        GetTempDir(False) + 'lwpt-journal-probe-' + IntToStr(GetProcessID));
    finally
      Renderer.FinishSilent(0, 0);
    end;
  finally
    Renderer.Free;
    After.Free;
    Before.Free;
  end;
  Expect<Boolean>(Length(Journals) >= 1).ToBe(True);
  Expect<Integer>(InheritedCount).ToBe(0);
end;

{ Positive control for every descriptor-inheritance assertion: the reporter
  child must see a descriptor this process deliberately leaves inheritable. }
procedure TLWPTEmergencyRingTests.TestDescriptorReporterSeesInheritance;
var
  Descriptor: THandle;
  Path: string;
begin
  Path := GetTempDir(False) + 'lwpt-inheritance-control-'
    + IntToStr(GetProcessID);
  Descriptor := FileCreate(Path);
  Expect<Boolean>(Descriptor <> THandle(-1)).ToBe(True);
  try
    Expect<Integer>(ChildInheritedFileCount([Path],
      Path + '.probe')).ToBe(1);
  finally
    FileClose(Descriptor);
    DeleteFile(Path);
  end;
end;
{$ENDIF}

procedure TLWPTEmergencyRingTests.SetupTests;
begin
  Test('chunked output preserves the exact most-recent 1 MiB tail',
    TestChunkedOutputPreservesMostRecentTail);
  {$IFDEF UNIX}
  Test('descriptor reporter sees a deliberately inherited descriptor',
    TestDescriptorReporterSeesInheritance);
  Test('silent output journal stays out of spawned children',
    TestSilentJournalStaysOutOfChildren);
  {$ENDIF}
end;

begin
  TestRunnerProgram.AddSuite(TLWPTEmergencyRingTests.Create(
    'LWPT silent emergency ring'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
