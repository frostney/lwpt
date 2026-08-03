program LWPT.OutputRenderer.Test;

{$I Shared.inc}

uses
  SysUtils,

  LWPT.OutputRenderer,
  TestingPascalLibrary;

type
  TLWPTEmergencyRingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestChunkedOutputPreservesMostRecentTail;
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

procedure TLWPTEmergencyRingTests.SetupTests;
begin
  Test('chunked output preserves the exact most-recent 1 MiB tail',
    TestChunkedOutputPreservesMostRecentTail);
end;

begin
  TestRunnerProgram.AddSuite(TLWPTEmergencyRingTests.Create(
    'LWPT silent emergency ring'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
