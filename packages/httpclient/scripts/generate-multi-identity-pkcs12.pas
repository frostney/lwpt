#!/usr/bin/env instantfpc
program GenerateMultiIdentityPKCS12;

{ Writes localhost-multi-identity.p12: one PKCS#12 bundle that carries two
  certificate-and-key identities (the test leaf and the test root, each with
  its own key). `openssl pkcs12 -export` can only emit one key, so this calls
  the OpenSSL PKCS#12 bag APIs directly. Run from the repository root; set
  OPENSSL_CRYPTO_LIBRARY when libcrypto 3 is not on the loader path. }

{$mode delphi}{$H+}

uses
  SysUtils,

  DynLibs;

const
  FIXTURES = 'packages/httpclient/source/fixtures/';
  OUTPUT_PATH = FIXTURES + 'localhost-multi-identity.p12';
  PASSPHRASE = 'test-only';
  NID_AES_256_CBC = 427;
  ITERATIONS = 2048;

type
  TBIOFree = function(ABIO: Pointer): LongInt; cdecl;
  TBIONewFile = function(APath, AMode: PAnsiChar): Pointer; cdecl;
  TPEMReadX509 = function(ABIO, AOut, ACallback, AUser: Pointer): Pointer;
    cdecl;
  TPEMReadKey = function(ABIO, AOut, ACallback, AUser: Pointer): Pointer;
    cdecl;
  TPKCS12AddCert = function(var ABags: Pointer;
    ACertificate: Pointer): Pointer; cdecl;
  TPKCS12AddKey = function(var ABags: Pointer; AKey: Pointer;
    AUsage, AIterations, AKeyNid: LongInt; APassphrase: PAnsiChar): Pointer;
    cdecl;
  TPKCS12AddLocalKeyID = function(ABag: Pointer; AName: PAnsiChar;
    ALength: LongInt): LongInt; cdecl;
  TPKCS12AddSafe = function(var ASafes: Pointer; ABags: Pointer;
    ASafeNid, AIterations: LongInt; APassphrase: PAnsiChar): LongInt; cdecl;
  TPKCS12AddSafes = function(ASafes: Pointer; ANid: LongInt): Pointer; cdecl;
  TPKCS12SetMAC = function(APKCS12: Pointer; APassphrase: PAnsiChar;
    APassphraseLength: LongInt; ASalt: Pointer; ASaltLength,
    AIterations: LongInt; ADigest: Pointer): LongInt; cdecl;
  TEVPDigest = function: Pointer; cdecl;
  Ti2dPKCS12BIO = function(ABIO, APKCS12: Pointer): LongInt; cdecl;

var
  AddCert: TPKCS12AddCert;
  AddKey: TPKCS12AddKey;
  AddLocalKeyID: TPKCS12AddLocalKeyID;
  AddSafe: TPKCS12AddSafe;
  AddSafes: TPKCS12AddSafes;
  BIOFree: TBIOFree;
  BIONewFile: TBIONewFile;
  CryptoHandle: TLibHandle;
  CryptoLibrary: string;
  PEMReadKey: TPEMReadKey;
  PEMReadX509: TPEMReadX509;
  SetMAC: TPKCS12SetMAC;
  SHA256: TEVPDigest;
  WriteBundle: Ti2dPKCS12BIO;

function Resolve(const AName: string): Pointer;
begin
  Result := GetProcedureAddress(CryptoHandle, AName);
  if Result = nil then
    raise Exception.CreateFmt('OpenSSL lacks %s', [AName]);
end;

function ReadPEM(const APath: string; const AKey: Boolean): Pointer;
var
  Input: Pointer;
begin
  Input := BIONewFile(PAnsiChar(AnsiString(FIXTURES + APath)), 'rb');
  if Input = nil then
    raise Exception.CreateFmt('Failed to open %s', [APath]);
  try
    if AKey then
      Result := PEMReadKey(Input, nil, nil, nil)
    else
      Result := PEMReadX509(Input, nil, nil, nil);
    if Result = nil then
      raise Exception.CreateFmt('Failed to read %s', [APath]);
  finally
    BIOFree(Input);
  end;
end;

procedure AddIdentity(var ABags: Pointer; const ACertificatePath,
  AKeyPath, AKeyID: string);
var
  Bag: Pointer;
  KeyID: AnsiString;
begin
  KeyID := AnsiString(AKeyID);
  Bag := AddCert(ABags, ReadPEM(ACertificatePath, False));
  if (Bag = nil) or
     (AddLocalKeyID(Bag, PAnsiChar(KeyID), Length(KeyID)) <> 1) then
    raise Exception.CreateFmt('Failed to add certificate %s',
      [ACertificatePath]);
  Bag := AddKey(ABags, ReadPEM(AKeyPath, True), 0, ITERATIONS,
    NID_AES_256_CBC, PASSPHRASE);
  if (Bag = nil) or
     (AddLocalKeyID(Bag, PAnsiChar(KeyID), Length(KeyID)) <> 1) then
    raise Exception.CreateFmt('Failed to add key %s', [AKeyPath]);
end;

var
  Bags: Pointer;
  Bundle: Pointer;
  Output: Pointer;
  Safes: Pointer;
begin
  CryptoLibrary := GetEnvironmentVariable('OPENSSL_CRYPTO_LIBRARY');
  if CryptoLibrary = '' then
    CryptoLibrary := 'libcrypto.so.3';
  CryptoHandle := LoadLibrary(CryptoLibrary);
  if CryptoHandle = NilHandle then
    raise Exception.Create('OpenSSL 3 libcrypto could not be loaded');
  AddCert := TPKCS12AddCert(Resolve('PKCS12_add_cert'));
  AddKey := TPKCS12AddKey(Resolve('PKCS12_add_key'));
  AddLocalKeyID := TPKCS12AddLocalKeyID(Resolve('PKCS12_add_localkeyid'));
  AddSafe := TPKCS12AddSafe(Resolve('PKCS12_add_safe'));
  AddSafes := TPKCS12AddSafes(Resolve('PKCS12_add_safes'));
  BIOFree := TBIOFree(Resolve('BIO_free'));
  BIONewFile := TBIONewFile(Resolve('BIO_new_file'));
  PEMReadKey := TPEMReadKey(Resolve('PEM_read_bio_PrivateKey'));
  PEMReadX509 := TPEMReadX509(Resolve('PEM_read_bio_X509'));
  SetMAC := TPKCS12SetMAC(Resolve('PKCS12_set_mac'));
  SHA256 := TEVPDigest(Resolve('EVP_sha256'));
  WriteBundle := Ti2dPKCS12BIO(Resolve('i2d_PKCS12_bio'));

  Bags := nil;
  AddIdentity(Bags, 'localhost-test-leaf-cert.pem',
    'localhost-test-leaf-key.pem', 'identity-one');
  AddIdentity(Bags, 'test-root-cert.pem', 'test-root-key.pem',
    'identity-two');
  Safes := nil;
  if AddSafe(Safes, Bags, NID_AES_256_CBC, ITERATIONS, PASSPHRASE) <> 1 then
    raise Exception.Create('Failed to encrypt the PKCS#12 safe');
  Bundle := AddSafes(Safes, 0);
  if (Bundle = nil) or (SetMAC(Bundle, PASSPHRASE, -1, nil, 0, ITERATIONS,
     SHA256()) <> 1) then
    raise Exception.Create('Failed to seal the PKCS#12 bundle');
  Output := BIONewFile(PAnsiChar(AnsiString(OUTPUT_PATH)), 'wb');
  if (Output = nil) or (WriteBundle(Output, Bundle) <> 1) then
    raise Exception.Create('Failed to write the PKCS#12 bundle');
  BIOFree(Output);
  WriteLn('wrote ', OUTPUT_PATH);
end.
