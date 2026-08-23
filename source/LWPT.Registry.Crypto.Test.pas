program LWPT.Registry.Crypto.Test;

{$mode delphi}{$H+}

uses
  SysUtils,

  LWPT.Registry.Crypto,
  TestingPascalLibrary;

type
  TRegistryCryptoContract = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRFC8032EmptyMessageVector;
    procedure TestRFC8032SingleByteVector;
    procedure TestTamperingHasStableRejection;
    procedure TestSHA512EmptyVector;
  end;

procedure TRegistryCryptoContract.TestRFC8032EmptyMessageVector;
var
  Message: TBytes;
  PublicKey: TLWPTEd25519PublicKey;
  Seed: TLWPTEd25519Seed;
  Signature: TLWPTEd25519Signature;
begin
  SetLength(Message, 0);
  Expect<Boolean>(HexToBytes(
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    Seed, SizeOf(Seed))).ToBe(True);
  SetLength(Message, SizeOf(Seed));
  Move(Seed[0], Message[0], SizeOf(Seed));
  Expect<string>(SHA512Hex(Message)).ToBe(
    '357c83864f2833cb427a2ef1c00a013cfdff2768d980c0a3a520f006904de90'
    + 'f9b4f0afe280b746a778684e75442502057b7473a03f08f96f5a38e9287e01f8f');
  SetLength(Message, 0);
  Ed25519PublicKey(Seed, PublicKey);
  Expect<string>(BytesToHex(PublicKey, SizeOf(PublicKey))).ToBe(
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
  Ed25519Sign(Message, Seed, Signature);
  Expect<string>(BytesToHex(Signature, SizeOf(Signature))).ToBe(
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
    + '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b');
  Expect<Boolean>(Ed25519Verify(Message, PublicKey, Signature)).ToBe(True);
end;

procedure TRegistryCryptoContract.TestSHA512EmptyVector;
var
  Message: TBytes;
begin
  SetLength(Message, 0);
  Expect<string>(SHA512Hex(Message)).ToBe(
    'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
    + '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e');
end;

procedure TRegistryCryptoContract.TestRFC8032SingleByteVector;
var
  Message: TBytes;
  PublicKey: TLWPTEd25519PublicKey;
  Seed: TLWPTEd25519Seed;
  Signature: TLWPTEd25519Signature;
begin
  SetLength(Message, 1);
  Message[0] := $72;
  Expect<Boolean>(HexToBytes(
    '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    Seed, SizeOf(Seed))).ToBe(True);
  Ed25519PublicKey(Seed, PublicKey);
  Expect<string>(BytesToHex(PublicKey, SizeOf(PublicKey))).ToBe(
    '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c');
  Ed25519Sign(Message, Seed, Signature);
  Expect<string>(BytesToHex(Signature, SizeOf(Signature))).ToBe(
    '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
    + '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00');
  Expect<Boolean>(Ed25519Verify(Message, PublicKey, Signature)).ToBe(True);
end;

procedure TRegistryCryptoContract.TestTamperingHasStableRejection;
var
  Message: TBytes;
  PublicKey: TLWPTEd25519PublicKey;
  Seed: TLWPTEd25519Seed;
  Signature: TLWPTEd25519Signature;
begin
  FillChar(Seed, SizeOf(Seed), 7);
  Message := TEncoding.UTF8.GetBytes('registry checkpoint');
  Ed25519PublicKey(Seed, PublicKey);
  Ed25519Sign(Message, Seed, Signature);
  Signature[4] := Signature[4] xor $80;
  Expect<Boolean>(Ed25519Verify(Message, PublicKey, Signature)).ToBe(False);
end;

procedure TRegistryCryptoContract.SetupTests;
begin
  Test('RFC 8032 empty-message vector is exact',
    TestRFC8032EmptyMessageVector);
  Test('RFC 8032 one-byte vector is exact',
    TestRFC8032SingleByteVector);
  Test('tampered signatures are rejected', TestTamperingHasStableRejection);
  Test('SHA-512 empty-message vector is exact', TestSHA512EmptyVector);
end;

begin
  TestRunnerProgram.AddSuite(TRegistryCryptoContract.Create(
    'registry Ed25519'));
  TestRunnerProgram.Run;
end.
