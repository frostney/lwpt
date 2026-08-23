{ LWPT.Registry.Crypto -- dependency-free RFC 8032 Ed25519 operations.

  The implementation follows TweetNaCl's public-domain arithmetic and
  SHA-512 construction, with a strict canonical-S check on verification.
  Keeping the primitive in Pascal gives every release platform identical
  signature bytes and diagnostics without an OpenSSL or platform-provider
  dependency. }
unit LWPT.Registry.Crypto;

{$I Shared.inc}
{$Q-}
{$R-}
{$J-}

interface

uses
  SysUtils;

type
  TLWPTEd25519Seed = array[0..31] of Byte;
  TLWPTEd25519PublicKey = array[0..31] of Byte;
  TLWPTEd25519Signature = array[0..63] of Byte;

procedure GenerateEd25519Seed(out ASeed: TLWPTEd25519Seed);
procedure Ed25519PublicKey(const ASeed: TLWPTEd25519Seed;
  out APublicKey: TLWPTEd25519PublicKey);
procedure Ed25519Sign(const AMessage: TBytes; const ASeed: TLWPTEd25519Seed;
  out ASignature: TLWPTEd25519Signature);
function Ed25519Verify(const AMessage: TBytes;
  const APublicKey: TLWPTEd25519PublicKey;
  const ASignature: TLWPTEd25519Signature): Boolean;
function BytesToHex(const ABytes; const ALength: Integer): string;
function HexToBytes(const AValue: string; var ABytes;
  const ALength: Integer): Boolean;
function SHA512Hex(const AData: TBytes): string;

implementation

uses
  Classes,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  LWPT.Core;

type
  TGF = array[0..15] of Int64;
  TPoint = array[0..3] of TGF;
  TSHA512Digest = array[0..63] of Byte;
  TLongArray64 = array[0..63] of Int64;

const
  GF0: TGF = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  GF1: TGF = (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  D: TGF = ($78a3, $1359, $4dca, $75eb, $d8ab, $4141, $0a4d, $0070,
    $e898, $7779, $4079, $8cc7, $fe73, $2b6f, $6cee, $5203);
  D2: TGF = ($f159, $26b2, $9b94, $ebd6, $b156, $8283, $149a, $00e0,
    $d130, $eef3, $80f2, $198e, $fce7, $56df, $d9dc, $2406);
  X: TGF = ($d51a, $8f25, $2d60, $c956, $a7b2, $9525, $c760, $692c,
    $dc5c, $fdd6, $e231, $c0a4, $53fe, $cd6e, $36d3, $2169);
  Y: TGF = ($6658, $6666, $6666, $6666, $6666, $6666, $6666, $6666,
    $6666, $6666, $6666, $6666, $6666, $6666, $6666, $6666);
  SQRT_MINUS_ONE: TGF = ($a0b0, $4a0e, $1b27, $c4ee, $e478, $ad2f,
    $1806, $2f43, $d7a7, $3dfb, $0099, $2b4d, $df0b, $4fc1, $2480,
    $2b83);
  GROUP_ORDER: array[0..31] of Byte = ($ed, $d3, $f5, $5c, $1a, $63,
    $12, $58, $d6, $9c, $f7, $a2, $de, $f9, $de, $14, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $10);
  SHA512_IV: TSHA512Digest = (
    $6a,$09,$e6,$67,$f3,$bc,$c9,$08,$bb,$67,$ae,$85,$84,$ca,$a7,$3b,
    $3c,$6e,$f3,$72,$fe,$94,$f8,$2b,$a5,$4f,$f5,$3a,$5f,$1d,$36,$f1,
    $51,$0e,$52,$7f,$ad,$e6,$82,$d1,$9b,$05,$68,$8c,$2b,$3e,$6c,$1f,
    $1f,$83,$d9,$ab,$fb,$41,$bd,$6b,$5b,$e0,$cd,$19,$13,$7e,$21,$79);
  { FPC 3.2.2 parses hexadecimal literals with the high bit set as signed
    Int64 values. Keep the bit patterns signed here and cast at the use site;
    declaring these as QWord produces misleading compile-time range warnings. }
  SHA512_K: array[0..79] of Int64 = (
    $428a2f98d728ae22,$7137449123ef65cd,$b5c0fbcfec4d3b2f,$e9b5dba58189dbbc,
    $3956c25bf348b538,$59f111f1b605d019,$923f82a4af194f9b,$ab1c5ed5da6d8118,
    $d807aa98a3030242,$12835b0145706fbe,$243185be4ee4b28c,$550c7dc3d5ffb4e2,
    $72be5d74f27b896f,$80deb1fe3b1696b1,$9bdc06a725c71235,$c19bf174cf692694,
    $e49b69c19ef14ad2,$efbe4786384f25e3,$0fc19dc68b8cd5b5,$240ca1cc77ac9c65,
    $2de92c6f592b0275,$4a7484aa6ea6e483,$5cb0a9dcbd41fbd4,$76f988da831153b5,
    $983e5152ee66dfab,$a831c66d2db43210,$b00327c898fb213f,$bf597fc7beef0ee4,
    $c6e00bf33da88fc2,$d5a79147930aa725,$06ca6351e003826f,$142929670a0e6e70,
    $27b70a8546d22ffc,$2e1b21385c26c926,$4d2c6dfc5ac42aed,$53380d139d95b3df,
    $650a73548baf63de,$766a0abb3c77b2a8,$81c2c92e47edaee6,$92722c851482353b,
    $a2bfe8a14cf10364,$a81a664bbc423001,$c24b8b70d0f89791,$c76c51a30654be30,
    $d192e819d6ef5218,$d69906245565a910,$f40e35855771202a,$106aa07032bbd1b8,
    $19a4c116b8d2d0c8,$1e376c085141ab53,$2748774cdf8eeb99,$34b0bcb5e19b48a8,
    $391c0cb3c5c95a63,$4ed8aa4ae3418acb,$5b9cca4f7763e373,$682e6ff3d6b2b8a3,
    $748f82ee5defb2fc,$78a5636f43172f60,$84c87814a1f0ab72,$8cc702081a6439ec,
    $90befffa23631e28,$a4506cebde82bde9,$bef9a3f7b2c67915,$c67178f2e372532b,
    $ca273eceea26619c,$d186b8c721c0c207,$eada7dd6cde0eb1e,$f57d4f7fee6ed178,
    $06f067aa72176fba,$0a637dc5a2c898a6,$113f9804bef90dae,$1b710b35131c471b,
    $28db77f523047d84,$32caab7b40c72493,$3c9ebe0a15c9bebc,$431d67c49c100d4c,
    $4cc5d4becb3e42b6,$597f299cfc657e2a,$5fcb6fab3ad6faec,$6c44198c4a475817);

{$IFDEF MSWINDOWS}
function BCryptGenRandom(AAlgorithm: THandle; ABuffer: Pointer;
  ALength, AFlags: Cardinal): LongInt; stdcall;
  external 'bcrypt.dll' name 'BCryptGenRandom';
{$ENDIF}

function BytesToHex(const ABytes; const ALength: Integer): string;
const
  HEX = '0123456789abcdef';
var
  Bytes: PByte;
  Index: Integer;
begin
  Bytes := @ABytes;
  SetLength(Result, ALength * 2);
  for Index := 0 to ALength - 1 do
  begin
    Result[Index * 2 + 1] := HEX[(Bytes[Index] shr 4) + 1];
    Result[Index * 2 + 2] := HEX[(Bytes[Index] and $0f) + 1];
  end;
end;

function HexNibble(const AValue: Char): Integer;
begin
  if AValue in ['0'..'9'] then Exit(Ord(AValue) - Ord('0'));
  if AValue in ['a'..'f'] then Exit(Ord(AValue) - Ord('a') + 10);
  Result := -1;
end;

function HexToBytes(const AValue: string; var ABytes;
  const ALength: Integer): Boolean;
var
  Bytes: PByte;
  HighNibble, Index, LowNibble: Integer;
begin
  Result := False;
  if Length(AValue) <> ALength * 2 then Exit;
  Bytes := @ABytes;
  for Index := 0 to ALength - 1 do
  begin
    HighNibble := HexNibble(AValue[Index * 2 + 1]);
    LowNibble := HexNibble(AValue[Index * 2 + 2]);
    if (HighNibble < 0) or (LowNibble < 0) then Exit;
    Bytes[Index] := Byte((HighNibble shl 4) or LowNibble);
  end;
  Result := True;
end;

procedure GenerateEd25519Seed(out ASeed: TLWPTEd25519Seed);
{$IFDEF UNIX}
var
  Stream: TFileStream;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Stream := TFileStream.Create('/dev/urandom', fmOpenRead or fmShareDenyNone);
  try
    Stream.ReadBuffer(ASeed[0], SizeOf(ASeed));
  finally
    Stream.Free;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if BCryptGenRandom(0, @ASeed[0], SizeOf(ASeed), $00000002) <> 0 then
    raise ELWPTError.Create('registry_key_generation_failed: secure random source failed');
  {$ENDIF}
end;

function RotateRight(const AValue: QWord; const ACount: Integer): QWord;
begin
  Result := (AValue shr ACount) or (AValue shl (64 - ACount));
end;

function LoadBigEndian64(const AData: PByte): QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to 7 do Result := (Result shl 8) or AData[Index];
end;

procedure StoreBigEndian64(AData: PByte; AValue: QWord);
var
  Index: Integer;
begin
  for Index := 7 downto 0 do
  begin
    AData[Index] := Byte(AValue);
    AValue := AValue shr 8;
  end;
end;

procedure SHA512Blocks(var AState: TSHA512Digest; const AData: PByte;
  ALength: NativeUInt);
var
  A, B, Z: array[0..7] of QWord;
  W: array[0..15] of QWord;
  Index, Round: Integer;
  T: QWord;
  Cursor: PByte;
begin
  for Index := 0 to 7 do
  begin
    Z[Index] := LoadBigEndian64(@AState[Index * 8]);
    A[Index] := Z[Index];
  end;
  Cursor := AData;
  while ALength >= 128 do
  begin
    for Index := 0 to 15 do W[Index] := LoadBigEndian64(@Cursor[Index * 8]);
    for Round := 0 to 79 do
    begin
      B := A;
      T := A[7] + (RotateRight(A[4], 14) xor RotateRight(A[4], 18)
        xor RotateRight(A[4], 41)) + ((A[4] and A[5]) xor
        ((not A[4]) and A[6])) + QWord(SHA512_K[Round]) + W[Round mod 16];
      B[7] := T + (RotateRight(A[0], 28) xor RotateRight(A[0], 34)
        xor RotateRight(A[0], 39)) + ((A[0] and A[1]) xor
        (A[0] and A[2]) xor (A[1] and A[2]));
      B[3] := B[3] + T;
      for Index := 0 to 7 do A[(Index + 1) mod 8] := B[Index];
      if (Round mod 16) = 15 then
        for Index := 0 to 15 do
          W[Index] := W[Index] + W[(Index + 9) mod 16]
            + (RotateRight(W[(Index + 1) mod 16], 1)
              xor RotateRight(W[(Index + 1) mod 16], 8)
              xor (W[(Index + 1) mod 16] shr 7))
            + (RotateRight(W[(Index + 14) mod 16], 19)
              xor RotateRight(W[(Index + 14) mod 16], 61)
              xor (W[(Index + 14) mod 16] shr 6));
    end;
    for Index := 0 to 7 do
    begin
      A[Index] := A[Index] + Z[Index];
      Z[Index] := A[Index];
    end;
    Inc(Cursor, 128);
    Dec(ALength, 128);
  end;
  for Index := 0 to 7 do StoreBigEndian64(@AState[Index * 8], Z[Index]);
end;

procedure SHA512(const AData: TBytes; out ADigest: TSHA512Digest);
var
  BitLength, Remaining, TotalPadding: QWord;
  Buffer: TBytes;
  Index: Integer;
begin
  ADigest := SHA512_IV;
  if Length(AData) >= 128 then
    SHA512Blocks(ADigest, @AData[0], (Length(AData) div 128) * 128);
  Remaining := Length(AData) mod 128;
  if Remaining < 112 then TotalPadding := 128 else TotalPadding := 256;
  SetLength(Buffer, TotalPadding);
  FillChar(Buffer[0], Length(Buffer), 0);
  if Remaining > 0 then
    Move(AData[Length(AData) - Remaining], Buffer[0], Remaining);
  Buffer[Remaining] := $80;
  BitLength := QWord(Length(AData)) shl 3;
  StoreBigEndian64(@Buffer[Length(Buffer) - 8], BitLength);
  for Index := Length(Buffer) - 16 to Length(Buffer) - 9 do Buffer[Index] := 0;
  SHA512Blocks(ADigest, @Buffer[0], Length(Buffer));
end;

function SHA512Hex(const AData: TBytes): string;
var
  Digest: TSHA512Digest;
begin
  SHA512(AData, Digest);
  Result := BytesToHex(Digest, SizeOf(Digest));
end;

procedure SetGF(var AResult: TGF; const AValue: TGF);
begin
  AResult := AValue;
end;

function ShiftRightSigned(const AValue: Int64;
  const ACount: Integer): Int64; inline;
begin
  if AValue >= 0 then
    Result := Int64(QWord(AValue) shr ACount)
  else
    Result := not Int64(QWord(not AValue) shr ACount);
end;

procedure Carry25519(var AValue: TGF);
var
  Carry: Int64;
  Index: Integer;
begin
  for Index := 0 to 15 do
  begin
    AValue[Index] := AValue[Index] + (Int64(1) shl 16);
    Carry := ShiftRightSigned(AValue[Index], 16);
    if Index < 15 then
      AValue[Index + 1] := AValue[Index + 1] + Carry - 1
    else
      AValue[0] := AValue[0] + 38 * (Carry - 1);
    AValue[Index] := AValue[Index] - (Carry shl 16);
  end;
end;

procedure Select25519(var ALeft, ARight: TGF; const ASelect: Byte);
var
  Mask, Temporary: Int64;
  Index: Integer;
begin
  Mask := not (Int64(ASelect) - 1);
  for Index := 0 to 15 do
  begin
    Temporary := Mask and (ALeft[Index] xor ARight[Index]);
    ALeft[Index] := ALeft[Index] xor Temporary;
    ARight[Index] := ARight[Index] xor Temporary;
  end;
end;

procedure Pack25519(var AResult: TLWPTEd25519PublicKey;
  const AValue: TGF);
var
  Difference, Reduced: TGF;
  Borrow, Index, Pass: Integer;
begin
  Reduced := AValue;
  Carry25519(Reduced);
  Carry25519(Reduced);
  Carry25519(Reduced);
  for Pass := 0 to 1 do
  begin
    Difference[0] := Reduced[0] - $ffed;
    for Index := 1 to 14 do
    begin
      Difference[Index] := Reduced[Index] - $ffff
        - (ShiftRightSigned(Difference[Index - 1], 16) and 1);
      Difference[Index - 1] := Difference[Index - 1] and $ffff;
    end;
    Difference[15] := Reduced[15] - $7fff
      - (ShiftRightSigned(Difference[14], 16) and 1);
    Borrow := ShiftRightSigned(Difference[15], 16) and 1;
    Difference[14] := Difference[14] and $ffff;
    Select25519(Reduced, Difference, Byte(1 - Borrow));
  end;
  for Index := 0 to 15 do
  begin
    AResult[Index * 2] := Byte(Reduced[Index]);
    AResult[Index * 2 + 1] := Byte(Reduced[Index] shr 8);
  end;
end;

function Equal32(const ALeft, ARight): Boolean;
var
  Difference: Cardinal;
  Index: Integer;
  LeftBytes, RightBytes: PByte;
begin
  Difference := 0;
  LeftBytes := @ALeft;
  RightBytes := @ARight;
  for Index := 0 to 31 do
    Difference := Difference or (LeftBytes[Index] xor RightBytes[Index]);
  Result := Difference = 0;
end;

function NotEqual25519(const ALeft, ARight: TGF): Boolean;
var
  LeftBytes, RightBytes: TLWPTEd25519PublicKey;
begin
  Pack25519(LeftBytes, ALeft);
  Pack25519(RightBytes, ARight);
  Result := not Equal32(LeftBytes, RightBytes);
end;

function Parity25519(const AValue: TGF): Byte;
var
  PackedBytes: TLWPTEd25519PublicKey;
begin
  Pack25519(PackedBytes, AValue);
  Result := PackedBytes[0] and 1;
end;

procedure Unpack25519(var AResult: TGF;
  const AValue: TLWPTEd25519PublicKey);
var
  Index: Integer;
begin
  for Index := 0 to 15 do
    AResult[Index] := AValue[Index * 2]
      + (Int64(AValue[Index * 2 + 1]) shl 8);
  AResult[15] := AResult[15] and $7fff;
end;

procedure AddGF(var AResult: TGF; const ALeft, ARight: TGF);
var
  Index: Integer;
begin
  for Index := 0 to 15 do AResult[Index] := ALeft[Index] + ARight[Index];
end;

procedure SubtractGF(var AResult: TGF; const ALeft, ARight: TGF);
var
  Index: Integer;
begin
  for Index := 0 to 15 do AResult[Index] := ALeft[Index] - ARight[Index];
end;

procedure MultiplyGF(var AResult: TGF; const ALeft, ARight: TGF);
var
  Product: array[0..30] of Int64;
  LeftIndex, RightIndex: Integer;
begin
  FillChar(Product, SizeOf(Product), 0);
  for LeftIndex := 0 to 15 do
    for RightIndex := 0 to 15 do
      Product[LeftIndex + RightIndex] := Product[LeftIndex + RightIndex]
        + ALeft[LeftIndex] * ARight[RightIndex];
  for LeftIndex := 0 to 14 do
    Product[LeftIndex] := Product[LeftIndex] + 38 * Product[LeftIndex + 16];
  for LeftIndex := 0 to 15 do AResult[LeftIndex] := Product[LeftIndex];
  Carry25519(AResult);
  Carry25519(AResult);
end;

procedure SquareGF(var AResult: TGF; const AValue: TGF);
begin
  MultiplyGF(AResult, AValue, AValue);
end;

procedure Invert25519(var AResult: TGF; const AValue: TGF);
var
  Power: TGF;
  Exponent: Integer;
begin
  Power := AValue;
  for Exponent := 253 downto 0 do
  begin
    SquareGF(Power, Power);
    if (Exponent <> 2) and (Exponent <> 4) then
      MultiplyGF(Power, Power, AValue);
  end;
  AResult := Power;
end;

procedure Power2523(var AResult: TGF; const AValue: TGF);
var
  Power: TGF;
  Exponent: Integer;
begin
  Power := AValue;
  for Exponent := 250 downto 0 do
  begin
    SquareGF(Power, Power);
    if Exponent <> 1 then MultiplyGF(Power, Power, AValue);
  end;
  AResult := Power;
end;

procedure AddPoint(var ALeft: TPoint; const ARight: TPoint);
var
  A, B, C, DValue, E, F, G, H, Temporary: TGF;
begin
  SubtractGF(A, ALeft[1], ALeft[0]);
  SubtractGF(Temporary, ARight[1], ARight[0]);
  MultiplyGF(A, A, Temporary);
  AddGF(B, ALeft[0], ALeft[1]);
  AddGF(Temporary, ARight[0], ARight[1]);
  MultiplyGF(B, B, Temporary);
  MultiplyGF(C, ALeft[3], ARight[3]);
  MultiplyGF(C, C, D2);
  MultiplyGF(DValue, ALeft[2], ARight[2]);
  AddGF(DValue, DValue, DValue);
  SubtractGF(E, B, A);
  SubtractGF(F, DValue, C);
  AddGF(G, DValue, C);
  AddGF(H, B, A);
  MultiplyGF(ALeft[0], E, F);
  MultiplyGF(ALeft[1], H, G);
  MultiplyGF(ALeft[2], G, F);
  MultiplyGF(ALeft[3], E, H);
end;

procedure SwapPoint(var ALeft, ARight: TPoint; const ASelect: Byte);
var
  Index: Integer;
begin
  for Index := 0 to 3 do Select25519(ALeft[Index], ARight[Index], ASelect);
end;

procedure ScalarMultiply(var AResult: TPoint; APoint: TPoint;
  const AScalar: PByte);
var
  Bit, Index: Integer;
begin
  SetGF(AResult[0], GF0);
  SetGF(AResult[1], GF1);
  SetGF(AResult[2], GF1);
  SetGF(AResult[3], GF0);
  for Index := 255 downto 0 do
  begin
    Bit := (AScalar[Index div 8] shr (Index and 7)) and 1;
    SwapPoint(AResult, APoint, Byte(Bit));
    AddPoint(APoint, AResult);
    AddPoint(AResult, AResult);
    SwapPoint(AResult, APoint, Byte(Bit));
  end;
end;

procedure ScalarBase(var AResult: TPoint; const AScalar: PByte);
var
  Base: TPoint;
begin
  SetGF(Base[0], X);
  SetGF(Base[1], Y);
  SetGF(Base[2], GF1);
  MultiplyGF(Base[3], X, Y);
  ScalarMultiply(AResult, Base, AScalar);
end;

procedure PackPoint(var AResult: TLWPTEd25519PublicKey;
  const APoint: TPoint);
var
  Inverse, XValue, YValue: TGF;
begin
  Invert25519(Inverse, APoint[2]);
  MultiplyGF(XValue, APoint[0], Inverse);
  MultiplyGF(YValue, APoint[1], Inverse);
  Pack25519(AResult, YValue);
  AResult[31] := AResult[31] xor (Parity25519(XValue) shl 7);
end;

procedure ModGroupOrder(var AResult: TLWPTEd25519PublicKey;
  var AValue: TLongArray64);
var
  Carry: Int64;
  Index, OrderIndex: Integer;
begin
  for Index := 63 downto 32 do
  begin
    Carry := 0;
    for OrderIndex := Index - 32 to Index - 13 do
    begin
      AValue[OrderIndex] := AValue[OrderIndex] + Carry
        - 16 * AValue[Index] * GROUP_ORDER[OrderIndex - (Index - 32)];
      Carry := ShiftRightSigned(AValue[OrderIndex] + 128, 8);
      AValue[OrderIndex] := AValue[OrderIndex] - (Carry shl 8);
    end;
    OrderIndex := Index - 12;
    AValue[OrderIndex] := AValue[OrderIndex] + Carry;
    AValue[Index] := 0;
  end;
  Carry := 0;
  for OrderIndex := 0 to 31 do
  begin
    AValue[OrderIndex] := AValue[OrderIndex] + Carry
      - ShiftRightSigned(AValue[31], 4) * GROUP_ORDER[OrderIndex];
    Carry := ShiftRightSigned(AValue[OrderIndex], 8);
    AValue[OrderIndex] := AValue[OrderIndex] and 255;
  end;
  for OrderIndex := 0 to 31 do
    AValue[OrderIndex] := AValue[OrderIndex] - Carry * GROUP_ORDER[OrderIndex];
  for Index := 0 to 31 do
  begin
    AValue[Index + 1] := AValue[Index + 1]
      + ShiftRightSigned(AValue[Index], 8);
    AResult[Index] := Byte(AValue[Index] and 255);
  end;
end;

procedure ReduceDigest(var ADigest: TSHA512Digest);
var
  Reduced: TLWPTEd25519PublicKey;
  Values: TLongArray64;
  Index: Integer;
begin
  for Index := 0 to 63 do Values[Index] := ADigest[Index];
  ModGroupOrder(Reduced, Values);
  FillChar(ADigest, SizeOf(ADigest), 0);
  Move(Reduced[0], ADigest[0], SizeOf(Reduced));
end;

function UnpackNegative(var APoint: TPoint;
  const AEncoded: TLWPTEd25519PublicKey): Boolean;
var
  Check, Denominator, Denominator2, Denominator4, Denominator6,
    Numerator, Temporary: TGF;
begin
  SetGF(APoint[2], GF1);
  Unpack25519(APoint[1], AEncoded);
  SquareGF(Numerator, APoint[1]);
  MultiplyGF(Denominator, Numerator, D);
  SubtractGF(Numerator, Numerator, APoint[2]);
  AddGF(Denominator, APoint[2], Denominator);
  SquareGF(Denominator2, Denominator);
  SquareGF(Denominator4, Denominator2);
  MultiplyGF(Denominator6, Denominator4, Denominator2);
  MultiplyGF(Temporary, Denominator6, Numerator);
  MultiplyGF(Temporary, Temporary, Denominator);
  Power2523(Temporary, Temporary);
  MultiplyGF(Temporary, Temporary, Numerator);
  MultiplyGF(Temporary, Temporary, Denominator);
  MultiplyGF(Temporary, Temporary, Denominator);
  MultiplyGF(APoint[0], Temporary, Denominator);
  SquareGF(Check, APoint[0]);
  MultiplyGF(Check, Check, Denominator);
  if NotEqual25519(Check, Numerator) then
    MultiplyGF(APoint[0], APoint[0], SQRT_MINUS_ONE);
  SquareGF(Check, APoint[0]);
  MultiplyGF(Check, Check, Denominator);
  if NotEqual25519(Check, Numerator) then Exit(False);
  if Parity25519(APoint[0]) = (AEncoded[31] shr 7) then
    SubtractGF(APoint[0], GF0, APoint[0]);
  MultiplyGF(APoint[3], APoint[0], APoint[1]);
  Result := True;
end;

function ScalarCanonical(const AScalar: PByte): Boolean;
var
  Index: Integer;
begin
  for Index := 31 downto 0 do
  begin
    if AScalar[Index] < GROUP_ORDER[Index] then Exit(True);
    if AScalar[Index] > GROUP_ORDER[Index] then Exit(False);
  end;
  Result := False;
end;

procedure Ed25519PublicKey(const ASeed: TLWPTEd25519Seed;
  out APublicKey: TLWPTEd25519PublicKey);
var
  Digest: TSHA512Digest;
  Point: TPoint;
  SeedBytes: TBytes;
begin
  SetLength(SeedBytes, SizeOf(ASeed));
  Move(ASeed[0], SeedBytes[0], SizeOf(ASeed));
  SHA512(SeedBytes, Digest);
  Digest[0] := Digest[0] and 248;
  Digest[31] := (Digest[31] and 127) or 64;
  ScalarBase(Point, @Digest[0]);
  PackPoint(APublicKey, Point);
end;

procedure Ed25519Sign(const AMessage: TBytes; const ASeed: TLWPTEd25519Seed;
  out ASignature: TLWPTEd25519Signature);
var
  Expanded, HashValue, Nonce: TSHA512Digest;
  PublicKey, RPoint: TLWPTEd25519PublicKey;
  Point: TPoint;
  HashInput, SeedBytes: TBytes;
  Products: TLongArray64;
  Index, Multiplier: Integer;
begin
  SetLength(SeedBytes, SizeOf(ASeed));
  Move(ASeed[0], SeedBytes[0], SizeOf(ASeed));
  SHA512(SeedBytes, Expanded);
  Expanded[0] := Expanded[0] and 248;
  Expanded[31] := (Expanded[31] and 127) or 64;
  ScalarBase(Point, @Expanded[0]);
  PackPoint(PublicKey, Point);

  SetLength(HashInput, 32 + Length(AMessage));
  Move(Expanded[32], HashInput[0], 32);
  if Length(AMessage) > 0 then Move(AMessage[0], HashInput[32], Length(AMessage));
  SHA512(HashInput, Nonce);
  ReduceDigest(Nonce);
  ScalarBase(Point, @Nonce[0]);
  PackPoint(RPoint, Point);
  Move(RPoint[0], ASignature[0], 32);

  SetLength(HashInput, 64 + Length(AMessage));
  Move(RPoint[0], HashInput[0], 32);
  Move(PublicKey[0], HashInput[32], 32);
  if Length(AMessage) > 0 then Move(AMessage[0], HashInput[64], Length(AMessage));
  SHA512(HashInput, HashValue);
  ReduceDigest(HashValue);
  FillChar(Products, SizeOf(Products), 0);
  for Index := 0 to 31 do Products[Index] := Nonce[Index];
  for Index := 0 to 31 do
    for Multiplier := 0 to 31 do
      Products[Index + Multiplier] := Products[Index + Multiplier]
        + Int64(HashValue[Index]) * Expanded[Multiplier];
  ModGroupOrder(PublicKey, Products);
  Move(PublicKey[0], ASignature[32], 32);
  FillChar(Expanded, SizeOf(Expanded), 0);
  FillChar(Products, SizeOf(Products), 0);
end;

function Ed25519Verify(const AMessage: TBytes;
  const APublicKey: TLWPTEd25519PublicKey;
  const ASignature: TLWPTEd25519Signature): Boolean;
var
  Encoded, REncoded: TLWPTEd25519PublicKey;
  HashValue: TSHA512Digest;
  HashInput: TBytes;
  LeftPoint, PublicPoint: TPoint;
begin
  Result := False;
  if not ScalarCanonical(@ASignature[32]) then Exit;
  if not UnpackNegative(PublicPoint, APublicKey) then Exit;
  SetLength(HashInput, 64 + Length(AMessage));
  Move(ASignature[0], HashInput[0], 32);
  Move(APublicKey[0], HashInput[32], 32);
  if Length(AMessage) > 0 then Move(AMessage[0], HashInput[64], Length(AMessage));
  SHA512(HashInput, HashValue);
  ReduceDigest(HashValue);
  ScalarMultiply(LeftPoint, PublicPoint, @HashValue[0]);
  ScalarBase(PublicPoint, @ASignature[32]);
  AddPoint(LeftPoint, PublicPoint);
  PackPoint(Encoded, LeftPoint);
  Move(ASignature[0], REncoded[0], 32);
  Result := Equal32(Encoded, REncoded);
end;

end.
