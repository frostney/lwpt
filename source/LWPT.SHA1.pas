{ LWPT.SHA1 — SHA-1 (FIPS 180-4) for git object ids and pack checksums.

  The cross-compile toolchain ships only the RTL and package units LWPT
  already depends on; FPC's hash/sha1 unit is not among them. Like the
  SHA-256 in LWPT.Core, this is a small self-contained implementation with
  the same names and shapes as FPC's sha1 unit, so callers only swap the
  unit name. SHA-1 identifies git objects here; it is not used for any
  new security decision. }
unit LWPT.SHA1;

{$I Shared.inc}

interface

type
  TSHA1Digest = array[0..19] of Byte;

  TSHA1Context = record
    State: array[0..4] of Cardinal;
    Buffer: array[0..63] of Byte;
    BufferLength: Integer;
    TotalLength: QWord;
  end;

procedure SHA1Init(out AContext: TSHA1Context);
procedure SHA1Update(var AContext: TSHA1Context; const AData;
  const ACount: PtrUInt);
procedure SHA1Final(var AContext: TSHA1Context; out ADigest: TSHA1Digest);
function SHA1Buffer(const AData; const ACount: PtrUInt): TSHA1Digest;
function SHA1Match(const ALeft, ARight: TSHA1Digest): Boolean;

implementation

{ SHA-1 relies on 32-bit modular addition and rotation, which must wrap. }
{$PUSH}{$R-}{$Q-}
procedure SHA1Transform(var AContext: TSHA1Context; const ABlock: array of Byte);
var
  W: array[0..79] of Cardinal;
  A, B, C, D, E, F, K, Temp: Cardinal;
  T: Integer;
begin
  for T := 0 to 15 do
    W[T] := (Cardinal(ABlock[T * 4]) shl 24) or (Cardinal(ABlock[T * 4 + 1]) shl 16)
      or (Cardinal(ABlock[T * 4 + 2]) shl 8) or Cardinal(ABlock[T * 4 + 3]);
  for T := 16 to 79 do
    W[T] := RolDWord(W[T - 3] xor W[T - 8] xor W[T - 14] xor W[T - 16], 1);

  A := AContext.State[0];
  B := AContext.State[1];
  C := AContext.State[2];
  D := AContext.State[3];
  E := AContext.State[4];
  for T := 0 to 79 do
  begin
    if T < 20 then
    begin
      F := (B and C) or ((not B) and D);
      K := $5A827999;
    end
    else if T < 40 then
    begin
      F := B xor C xor D;
      K := $6ED9EBA1;
    end
    else if T < 60 then
    begin
      F := (B and C) or (B and D) or (C and D);
      K := $8F1BBCDC;
    end
    else
    begin
      F := B xor C xor D;
      K := $CA62C1D6;
    end;
    Temp := RolDWord(A, 5) + F + E + K + W[T];
    E := D;
    D := C;
    C := RolDWord(B, 30);
    B := A;
    A := Temp;
  end;
  Inc(AContext.State[0], A);
  Inc(AContext.State[1], B);
  Inc(AContext.State[2], C);
  Inc(AContext.State[3], D);
  Inc(AContext.State[4], E);
end;
{$POP}

procedure SHA1Init(out AContext: TSHA1Context);
begin
  FillChar(AContext, SizeOf(AContext), 0);
  AContext.State[0] := $67452301;
  AContext.State[1] := $EFCDAB89;
  AContext.State[2] := $98BADCFE;
  AContext.State[3] := $10325476;
  AContext.State[4] := $C3D2E1F0;
end;

procedure SHA1Update(var AContext: TSHA1Context; const AData;
  const ACount: PtrUInt);
var
  Remaining: PtrUInt;
  Take: Integer;
  Cursor: PByte;
begin
  if ACount = 0 then Exit;
  Cursor := @AData;
  Remaining := ACount;
  Inc(AContext.TotalLength, ACount);
  while Remaining > 0 do
  begin
    Take := SizeOf(AContext.Buffer) - AContext.BufferLength;
    if PtrUInt(Take) > Remaining then Take := Integer(Remaining);
    Move(Cursor^, AContext.Buffer[AContext.BufferLength], Take);
    Inc(Cursor, Take);
    Inc(AContext.BufferLength, Take);
    Dec(Remaining, PtrUInt(Take));
    if AContext.BufferLength = SizeOf(AContext.Buffer) then
    begin
      SHA1Transform(AContext, AContext.Buffer);
      AContext.BufferLength := 0;
    end;
  end;
end;

procedure SHA1Final(var AContext: TSHA1Context; out ADigest: TSHA1Digest);
var
  BitLength: QWord;
  Index: Integer;
begin
  BitLength := AContext.TotalLength * 8;
  AContext.Buffer[AContext.BufferLength] := $80;
  Inc(AContext.BufferLength);
  if AContext.BufferLength > 56 then
  begin
    { With 63 bytes buffered the marker fills the block; indexing
      Buffer[64] would be out of range even for a zero-length fill. }
    if AContext.BufferLength < SizeOf(AContext.Buffer) then
      FillChar(AContext.Buffer[AContext.BufferLength],
        SizeOf(AContext.Buffer) - AContext.BufferLength, 0);
    SHA1Transform(AContext, AContext.Buffer);
    AContext.BufferLength := 0;
  end;
  FillChar(AContext.Buffer[AContext.BufferLength],
    56 - AContext.BufferLength, 0);
  for Index := 0 to 7 do
    AContext.Buffer[63 - Index] := Byte((BitLength shr (8 * Index)) and $FF);
  SHA1Transform(AContext, AContext.Buffer);
  for Index := 0 to 4 do
  begin
    ADigest[Index * 4] := Byte((AContext.State[Index] shr 24) and $FF);
    ADigest[Index * 4 + 1] := Byte((AContext.State[Index] shr 16) and $FF);
    ADigest[Index * 4 + 2] := Byte((AContext.State[Index] shr 8) and $FF);
    ADigest[Index * 4 + 3] := Byte(AContext.State[Index] and $FF);
  end;
  FillChar(AContext, SizeOf(AContext), 0);
end;

function SHA1Buffer(const AData; const ACount: PtrUInt): TSHA1Digest;
var
  Context: TSHA1Context;
begin
  SHA1Init(Context);
  SHA1Update(Context, AData, ACount);
  SHA1Final(Context, Result);
end;

function SHA1Match(const ALeft, ARight: TSHA1Digest): Boolean;
var
  Index: Integer;
begin
  for Index := Low(ALeft) to High(ALeft) do
    if ALeft[Index] <> ARight[Index] then
      Exit(False);
  Result := True;
end;

end.
