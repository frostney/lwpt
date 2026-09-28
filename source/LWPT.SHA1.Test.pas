program LWPT.SHA1.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  LWPT.SHA1,
  sha1,
  TestingPascalLibrary;

type
  TSHA1Tests = class(TTestSuite)
  private
    procedure TestFIPSVectors;
    procedure TestMatchesFPCForEveryLengthAndChunking;
  public
    procedure SetupTests; override;
  end;

function Hex(const ADigest: LWPT.SHA1.TSHA1Digest): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := Low(ADigest) to High(ADigest) do
    Result := Result + LowerCase(IntToHex(ADigest[Index], 2));
end;

function DigestOf(const AText: AnsiString): string;
begin
  if AText = '' then
    Result := Hex(LWPT.SHA1.SHA1Buffer(PAnsiChar('')^, 0))
  else
    Result := Hex(LWPT.SHA1.SHA1Buffer(AText[1], Length(AText)));
end;

procedure TSHA1Tests.TestFIPSVectors;
var
  Million: AnsiString;
begin
  Expect<string>(DigestOf('')).ToBe('da39a3ee5e6b4b0d3255bfef95601890afd80709');
  Expect<string>(DigestOf('abc')).ToBe('a9993e364706816aba3e25717850c26c9cd0d89d');
  Expect<string>(DigestOf(
    'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')).ToBe(
    '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
  Million := StringOfChar('a', 1000000);
  Expect<string>(DigestOf(Million)).ToBe('34aa973cd4c4daa4f61eeb2bdbad27316534016f');
end;

{ Every length from 0 to 300 bytes, fed whole and in 7-byte chunks, must
  match FPC's own sha1 unit (available to native test builds). That covers
  every padding boundary around 55, 56 and 64 bytes and multi-block input. }
procedure TSHA1Tests.TestMatchesFPCForEveryLengthAndChunking;
var
  Data: AnsiString;
  Length_, Offset, Take, Index: Integer;
  Context: LWPT.SHA1.TSHA1Context;
  Chunked: LWPT.SHA1.TSHA1Digest;
  Expected: string;
begin
  for Length_ := 0 to 300 do
  begin
    SetLength(Data, Length_);
    for Index := 1 to Length_ do
      Data[Index] := AnsiChar((Index * 31 + Length_) and $FF);
    Expected := SHA1Print(sha1.SHA1String(Data));
    Expect<string>(DigestOf(Data)).ToBe(Expected);
    LWPT.SHA1.SHA1Init(Context);
    Offset := 1;
    while Offset <= Length_ do
    begin
      Take := 7;
      if Offset + Take - 1 > Length_ then Take := Length_ - Offset + 1;
      LWPT.SHA1.SHA1Update(Context, Data[Offset], Take);
      Inc(Offset, Take);
    end;
    LWPT.SHA1.SHA1Final(Context, Chunked);
    Expect<string>(Hex(Chunked)).ToBe(Expected);
  end;
end;

procedure TSHA1Tests.SetupTests;
begin
  Test('FIPS 180 test vectors', TestFIPSVectors);
  Test('matches FPC''s sha1 for every length and chunking',
    TestMatchesFPCForEveryLengthAndChunking);
end;

begin
  TestRunnerProgram.AddSuite(TSHA1Tests.Create('LWPT.SHA1'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
