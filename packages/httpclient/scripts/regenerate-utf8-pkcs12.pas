#!/usr/bin/env instantfpc
program RegenerateUTF8PKCS12;

{$mode delphi}{$H+}{$codepage utf8}

uses
  SysUtils,

  DynLibs;

const
  INPUT_PATH =
    'packages/httpclient/source/fixtures/localhost-test-identity.p12';
  OUTPUT_PATH =
    'packages/httpclient/source/fixtures/localhost-utf8-passphrase.p12';
  OLD_PASSPHRASE = 'test-only';
  NEW_PASSPHRASE = 'pässword';

type
  TBIOFree = function(ABIO: Pointer): LongInt; cdecl;
  TBIONewFile = function(APath, AMode: PAnsiChar): Pointer; cdecl;
  Td2iPKCS12BIO = function(ABIO: Pointer;
    APKCS12: PPointer): Pointer; cdecl;
  TEVPKeyFree = procedure(AKey: Pointer); cdecl;
  Ti2dPKCS12BIO = function(ABIO, APKCS12: Pointer): LongInt; cdecl;
  TOpenSSLStackFree = procedure(AStack: Pointer); cdecl;
  TOpenSSLStackNum = function(AStack: Pointer): LongInt; cdecl;
  TOpenSSLStackValue = function(AStack: Pointer;
    AIndex: LongInt): Pointer; cdecl;
  TPKCS12Create = function(APassphrase, AName: PAnsiChar;
    APrivateKey, ACertificate, AChain: Pointer; ANidKey, ANidCertificate,
    AIterations, AMACIterations, AKeyType: Integer): Pointer; cdecl;
  TPKCS12Free = procedure(APKCS12: Pointer); cdecl;
  TPKCS12Parse = function(APKCS12: Pointer; APassphrase: PAnsiChar;
    out APrivateKey, ACertificate, AChain: Pointer): LongInt; cdecl;
  TX509Free = procedure(ACertificate: Pointer); cdecl;

procedure Wipe(var AValue: UTF8String);
begin
  if Length(AValue) > 0 then
    FillChar(PAnsiChar(AValue)^, Length(AValue), 0);
  AValue := '';
end;

var
  BIOFree: TBIOFree;
  BIONewFile: TBIONewFile;
  Certificate: Pointer;
  Chain: Pointer;
  CreateBundle: TPKCS12Create;
  CryptoHandle: TLibHandle;
  CryptoLibrary: string;
  DecodeBundle: Td2iPKCS12BIO;
  EVPKeyFree: TEVPKeyFree;
  InputBIO: Pointer;
  NewPassphrase: UTF8String;
  OldPassphrase: UTF8String;
  OpenSSLStackFree: TOpenSSLStackFree;
  OpenSSLStackNum: TOpenSSLStackNum;
  OpenSSLStackValue: TOpenSSLStackValue;
  OutputBIO: Pointer;
  OutputBundle: Pointer;
  ParseBundle: TPKCS12Parse;
  PrivateKey: Pointer;
  FreeBundle: TPKCS12Free;
  I: Integer;
  SourceBundle: Pointer;
  WriteBundle: Ti2dPKCS12BIO;
  X509Free: TX509Free;
begin
  BIOFree := nil;
  BIONewFile := nil;
  Certificate := nil;
  Chain := nil;
  CreateBundle := nil;
  CryptoHandle := dynlibs.NilHandle;
  DecodeBundle := nil;
  EVPKeyFree := nil;
  FreeBundle := nil;
  InputBIO := nil;
  OpenSSLStackFree := nil;
  OpenSSLStackNum := nil;
  OpenSSLStackValue := nil;
  OutputBIO := nil;
  OutputBundle := nil;
  ParseBundle := nil;
  PrivateKey := nil;
  SourceBundle := nil;
  WriteBundle := nil;
  X509Free := nil;
  OldPassphrase := UTF8Encode(UnicodeString(OLD_PASSPHRASE));
  NewPassphrase := UTF8Encode(UnicodeString(NEW_PASSPHRASE));
  try
    CryptoLibrary := GetEnvironmentVariable('OPENSSL_CRYPTO_LIBRARY');
    if CryptoLibrary = '' then
    begin
      {$IFDEF DARWIN}
      CryptoLibrary := 'libcrypto.3.dylib';
      {$ELSE}
      CryptoLibrary := 'libcrypto.so.3';
      {$ENDIF}
    end;
    CryptoHandle := LoadLibrary(CryptoLibrary);
    if CryptoHandle = dynlibs.NilHandle then
      raise Exception.Create('OpenSSL 3 libcrypto could not be loaded');
    BIOFree := TBIOFree(GetProcedureAddress(CryptoHandle, 'BIO_free'));
    BIONewFile := TBIONewFile(GetProcedureAddress(CryptoHandle,
      'BIO_new_file'));
    DecodeBundle := Td2iPKCS12BIO(GetProcedureAddress(CryptoHandle,
      'd2i_PKCS12_bio'));
    EVPKeyFree := TEVPKeyFree(GetProcedureAddress(CryptoHandle,
      'EVP_PKEY_free'));
    FreeBundle := TPKCS12Free(GetProcedureAddress(CryptoHandle,
      'PKCS12_free'));
    CreateBundle := TPKCS12Create(GetProcedureAddress(CryptoHandle,
      'PKCS12_create'));
    ParseBundle := TPKCS12Parse(GetProcedureAddress(CryptoHandle,
      'PKCS12_parse'));
    OpenSSLStackFree := TOpenSSLStackFree(GetProcedureAddress(CryptoHandle,
      'OPENSSL_sk_free'));
    OpenSSLStackNum := TOpenSSLStackNum(GetProcedureAddress(CryptoHandle,
      'OPENSSL_sk_num'));
    OpenSSLStackValue := TOpenSSLStackValue(GetProcedureAddress(CryptoHandle,
      'OPENSSL_sk_value'));
    WriteBundle := Ti2dPKCS12BIO(GetProcedureAddress(CryptoHandle,
      'i2d_PKCS12_bio'));
    X509Free := TX509Free(GetProcedureAddress(CryptoHandle, 'X509_free'));
    if not Assigned(BIOFree) or not Assigned(BIONewFile) or
       not Assigned(CreateBundle) or not Assigned(DecodeBundle) or
       not Assigned(EVPKeyFree) or not Assigned(FreeBundle) or
       not Assigned(OpenSSLStackFree) or not Assigned(OpenSSLStackNum) or
       not Assigned(OpenSSLStackValue) or not Assigned(ParseBundle) or
       not Assigned(WriteBundle) or not Assigned(X509Free) then
      raise Exception.Create('OpenSSL lacks the required PKCS#12 procedures');

    InputBIO := BIONewFile(PAnsiChar(AnsiString(INPUT_PATH)), 'rb');
    if not Assigned(InputBIO) then
      raise Exception.Create('Failed to open the source PKCS#12 fixture');
    SourceBundle := DecodeBundle(InputBIO, nil);
    if not Assigned(SourceBundle) then
      raise Exception.Create('Failed to decode the source PKCS#12 fixture');
    if ParseBundle(SourceBundle, PAnsiChar(OldPassphrase), PrivateKey,
      Certificate, Chain) <> 1 then
      raise Exception.Create('Failed to parse the source PKCS#12 fixture');
    OutputBundle := CreateBundle(PAnsiChar(NewPassphrase),
      'localhost-utf8-passphrase', PrivateKey, Certificate, Chain,
      0, 0, 0, 0, 0);
    if not Assigned(OutputBundle) then
      raise Exception.Create('Failed to create the UTF-8 PKCS#12 fixture');

    OutputBIO := BIONewFile(PAnsiChar(AnsiString(OUTPUT_PATH)), 'wb');
    if not Assigned(OutputBIO) then
      raise Exception.Create('Failed to open the UTF-8 PKCS#12 fixture');
    if WriteBundle(OutputBIO, OutputBundle) <> 1 then
      raise Exception.Create('Failed to write the UTF-8 PKCS#12 fixture');
  finally
    if Assigned(OutputBIO) and Assigned(BIOFree) then
      BIOFree(OutputBIO);
    if Assigned(OutputBundle) and Assigned(FreeBundle) then
      FreeBundle(OutputBundle);
    if Assigned(SourceBundle) and Assigned(FreeBundle) then
      FreeBundle(SourceBundle);
    if Assigned(InputBIO) and Assigned(BIOFree) then
      BIOFree(InputBIO);
    if Assigned(Chain) and Assigned(OpenSSLStackFree) and
       Assigned(OpenSSLStackNum) and Assigned(OpenSSLStackValue) and
       Assigned(X509Free) then
    begin
      for I := 0 to OpenSSLStackNum(Chain) - 1 do
        X509Free(OpenSSLStackValue(Chain, I));
      OpenSSLStackFree(Chain);
    end;
    if Assigned(Certificate) and Assigned(X509Free) then
      X509Free(Certificate);
    if Assigned(PrivateKey) and Assigned(EVPKeyFree) then
      EVPKeyFree(PrivateKey);
    Wipe(NewPassphrase);
    Wipe(OldPassphrase);
    if CryptoHandle <> dynlibs.NilHandle then
      UnloadLibrary(CryptoHandle);
  end;
end.
