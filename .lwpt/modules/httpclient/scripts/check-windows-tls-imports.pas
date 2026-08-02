#!/usr/bin/env instantfpc
program CheckWindowsTLSImports;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils;

type
  TBytes = array of Byte;

  TSection = record
    VirtualAddress, Span, RawOffset, RawSize: QWord;
  end;

  TSectionArray = array of TSection;

  TImportEntry = record
    Kind, DLLName, SymbolName: string;
  end;

  TImportEntries = array of TImportEntry;

  TPEImports = class
  private
    FData: TBytes;
    FIs64: Boolean;
    FImageBase, FDirectoriesCount, FDirectories, FOptionalEnd,
      FSizeOfHeaders: QWord;
    FSections: TSectionArray;
    procedure Require(const ACondition: Boolean; const AMessage: string);
    procedure RequireRange(const AOffset, ASize: QWord);
    function U16(const AOffset: QWord): Word;
    function U32(const AOffset: QWord): Cardinal;
    function U64(const AOffset: QWord): QWord;
    function FileOffset(const ARVA: QWord): QWord;
    function TextAt(const ARVA: QWord): string;
    procedure Directory(const AIndex: Cardinal; out ARVA, ASize: QWord);
    procedure AddSymbols(var AEntries: TImportEntries; const AKind,
      ADLLName: string; const AThunkRVA: QWord;
      const AValuesAreRVAs: Boolean = True);
    procedure AddNormalEntries(var AEntries: TImportEntries);
    procedure AddDelayEntries(var AEntries: TImportEntries);
  public
    constructor Create(const AData: TBytes);
    function Entries: TImportEntries;
  end;

const
  OPENSSL_FAMILIES: array[0..21] of string = (
    'SSL', 'TLS', 'BIO', 'EVP', 'X509', 'PKCS12', 'ERR', 'CRYPTO',
    'OPENSSL', 'OSSL', 'PEM', 'ASN1', 'RSA', 'DSA', 'DH', 'EC', 'BN',
    'RAND', 'HMAC', 'MD5', 'SHA', 'AES');

procedure Fail(const AMessage: string);
begin
  raise Exception.Create(AMessage);
end;

procedure TPEImports.Require(const ACondition: Boolean;
  const AMessage: string);
begin
  if not ACondition then
    Fail(AMessage);
end;

procedure TPEImports.RequireRange(const AOffset, ASize: QWord);
begin
  Require((AOffset <= QWord(Length(FData))) and
    (ASize <= QWord(Length(FData)) - AOffset), 'truncated PE data');
end;

function TPEImports.U16(const AOffset: QWord): Word;
begin
  RequireRange(AOffset, 2);
  Result := FData[AOffset] or (Word(FData[AOffset + 1]) shl 8);
end;

function TPEImports.U32(const AOffset: QWord): Cardinal;
begin
  RequireRange(AOffset, 4);
  Result := Cardinal(FData[AOffset]) or
    (Cardinal(FData[AOffset + 1]) shl 8) or
    (Cardinal(FData[AOffset + 2]) shl 16) or
    (Cardinal(FData[AOffset + 3]) shl 24);
end;

function TPEImports.U64(const AOffset: QWord): QWord;
begin
  Result := QWord(U32(AOffset)) or (QWord(U32(AOffset + 4)) shl 32);
end;

constructor TPEImports.Create(const AData: TBytes);
var
  PE, Optional, OptionalSize, SectionTable: QWord;
  Magic, SectionsCount: Word;
  Index: Integer;
begin
  inherited Create;
  FData := Copy(AData);
  Require((Length(FData) >= 2) and (FData[0] = Ord('M')) and
    (FData[1] = Ord('Z')), 'missing DOS header');
  PE := U32($3C);
  RequireRange(PE, 4);
  Require((FData[PE] = Ord('P')) and (FData[PE + 1] = Ord('E')) and
    (FData[PE + 2] = 0) and (FData[PE + 3] = 0), 'missing PE header');
  SectionsCount := U16(PE + 6);
  OptionalSize := U16(PE + 20);
  Optional := PE + 24;
  RequireRange(Optional, OptionalSize);
  Magic := U16(Optional);
  Require((Magic = $10B) or (Magic = $20B),
    'unsupported PE optional header');
  FIs64 := Magic = $20B;
  if FIs64 then
  begin
    FImageBase := U64(Optional + 24);
    FDirectoriesCount := U32(Optional + 108);
    FDirectories := Optional + 112;
  end
  else
  begin
    FImageBase := U32(Optional + 28);
    FDirectoriesCount := U32(Optional + 92);
    FDirectories := Optional + 96;
  end;
  FOptionalEnd := Optional + OptionalSize;
  FSizeOfHeaders := U32(Optional + 60);
  SectionTable := FOptionalEnd;
  SetLength(FSections, SectionsCount);
  for Index := 0 to SectionsCount - 1 do
  begin
    RequireRange(SectionTable + QWord(Index) * 40, 40);
    FSections[Index].VirtualAddress :=
      U32(SectionTable + QWord(Index) * 40 + 12);
    FSections[Index].RawSize := U32(SectionTable + QWord(Index) * 40 + 16);
    FSections[Index].RawOffset := U32(SectionTable + QWord(Index) * 40 + 20);
    FSections[Index].Span := U32(SectionTable + QWord(Index) * 40 + 8);
    if FSections[Index].RawSize > FSections[Index].Span then
      FSections[Index].Span := FSections[Index].RawSize;
  end;
end;

function TPEImports.FileOffset(const ARVA: QWord): QWord;
var
  Index: Integer;
  Delta: QWord;
begin
  if ARVA < FSizeOfHeaders then
  begin
    RequireRange(ARVA, 1);
    Exit(ARVA);
  end;
  for Index := 0 to High(FSections) do
    if (ARVA >= FSections[Index].VirtualAddress) and
      (ARVA - FSections[Index].VirtualAddress < FSections[Index].Span) then
    begin
      Delta := ARVA - FSections[Index].VirtualAddress;
      Require(Delta < FSections[Index].RawSize,
        'RVA points outside raw section data');
      Result := FSections[Index].RawOffset + Delta;
      RequireRange(Result, 1);
      Exit;
    end;
  Fail('unmapped RVA');
  Result := 0;
end;

function TPEImports.TextAt(const ARVA: QWord): string;
var
  Offset, Finish, Index: QWord;
begin
  Offset := FileOffset(ARVA);
  Finish := Offset;
  while (Finish < QWord(Length(FData))) and (FData[Finish] <> 0) do
  begin
    Require(FData[Finish] < $80, 'non-ASCII import name');
    Inc(Finish);
  end;
  Require(Finish < QWord(Length(FData)), 'unterminated import name');
  Require(Finish > Offset, 'empty import name');
  SetLength(Result, Finish - Offset);
  for Index := Offset to Finish - 1 do
    Result[Index - Offset + 1] := Char(FData[Index]);
end;

procedure TPEImports.Directory(const AIndex: Cardinal;
  out ARVA, ASize: QWord);
var
  Entry: QWord;
begin
  if AIndex >= FDirectoriesCount then
  begin
    ARVA := 0;
    ASize := 0;
    Exit;
  end;
  Entry := FDirectories + QWord(AIndex) * 8;
  Require(Entry + 8 <= FOptionalEnd, 'truncated data directory');
  ARVA := U32(Entry);
  ASize := U32(Entry + 4);
end;

procedure AddEntry(var AEntries: TImportEntries; const AKind, ADLLName,
  ASymbolName: string);
var
  Index: Integer;
begin
  Index := Length(AEntries);
  SetLength(AEntries, Index + 1);
  AEntries[Index].Kind := AKind;
  AEntries[Index].DLLName := ADLLName;
  AEntries[Index].SymbolName := ASymbolName;
end;

procedure TPEImports.AddSymbols(var AEntries: TImportEntries;
  const AKind, ADLLName: string; const AThunkRVA: QWord;
  const AValuesAreRVAs: Boolean);
var
  Offset, Value, NameRVA, Width, OrdinalMask: QWord;
begin
  Require(AThunkRVA <> 0, 'missing import name table');
  Offset := FileOffset(AThunkRVA);
  if FIs64 then
  begin
    Width := 8;
    OrdinalMask := QWord(1) shl 63;
  end
  else
  begin
    Width := 4;
    OrdinalMask := QWord(1) shl 31;
  end;
  while True do
  begin
    if FIs64 then
      Value := U64(Offset)
    else
      Value := U32(Offset);
    if Value = 0 then
      Exit;
    if Value and OrdinalMask <> 0 then
      AddEntry(AEntries, AKind, ADLLName, '#' + IntToStr(Value and $FFFF))
    else
    begin
      if AValuesAreRVAs then
        NameRVA := Value
      else
      begin
        Require(Value >= FImageBase, 'invalid import name address');
        NameRVA := Value - FImageBase;
      end;
      AddEntry(AEntries, AKind, ADLLName, TextAt(NameRVA + 2));
    end;
    Inc(Offset, Width);
  end;
end;

procedure TPEImports.AddNormalEntries(var AEntries: TImportEntries);
var
  RVA, Size, Offset, Finish, Thunk: QWord;
  DLLName: string;
begin
  Directory(1, RVA, Size);
  if RVA = 0 then
    Exit;
  Offset := FileOffset(RVA);
  Finish := Offset + Size;
  Require((Size >= 20) and (Finish <= QWord(Length(FData))),
    'invalid import directory');
  while Offset + 20 <= Finish do
  begin
    if (U32(Offset) = 0) and (U32(Offset + 4) = 0) and
      (U32(Offset + 8) = 0) and (U32(Offset + 12) = 0) and
      (U32(Offset + 16) = 0) then
      Exit;
    DLLName := TextAt(U32(Offset + 12));
    Thunk := U32(Offset);
    if Thunk = 0 then
      Thunk := U32(Offset + 16);
    AddSymbols(AEntries, 'import', DLLName, Thunk);
    Inc(Offset, 20);
  end;
  Fail('unterminated import directory');
end;

procedure TPEImports.AddDelayEntries(var AEntries: TImportEntries);
var
  RVA, Size, Offset, Finish, NameAddress, ThunkAddress: QWord;
  RVABased: Boolean;
  DLLName: string;
begin
  Directory(13, RVA, Size);
  if RVA = 0 then
    Exit;
  Offset := FileOffset(RVA);
  Finish := Offset + Size;
  Require((Size >= 32) and (Finish <= QWord(Length(FData))),
    'invalid delay-import directory');
  while Offset + 32 <= Finish do
  begin
    if (U32(Offset) = 0) and (U32(Offset + 4) = 0) and
      (U32(Offset + 8) = 0) and (U32(Offset + 12) = 0) and
      (U32(Offset + 16) = 0) and (U32(Offset + 20) = 0) and
      (U32(Offset + 24) = 0) and (U32(Offset + 28) = 0) then
      Exit;
    RVABased := U32(Offset) and 1 <> 0;
    NameAddress := U32(Offset + 4);
    ThunkAddress := U32(Offset + 16);
    if ThunkAddress = 0 then
      ThunkAddress := U32(Offset + 12);
    if not RVABased then
    begin
      Require((NameAddress >= FImageBase) and
        (ThunkAddress >= FImageBase), 'invalid delay-import address');
      Dec(NameAddress, FImageBase);
      Dec(ThunkAddress, FImageBase);
    end;
    DLLName := TextAt(NameAddress);
    AddSymbols(AEntries, 'delay-import', DLLName, ThunkAddress, RVABased);
    Inc(Offset, 32);
  end;
  Fail('unterminated delay-import directory');
end;

function TPEImports.Entries: TImportEntries;
begin
  SetLength(Result, 0);
  AddNormalEntries(Result);
  AddDelayEntries(Result);
end;

function StartsWith(const AValue, APrefix: string): Boolean;
begin
  Result := Copy(AValue, 1, Length(APrefix)) = APrefix;
end;

function IsOpenSSLDLL(const AName: string): Boolean;
var
  Name: string;
begin
  Name := LowerCase(AName);
  Result := (Pos('libssl', Name) > 0) or (Pos('libcrypto', Name) > 0) or
    (Pos('openssl', Name) > 0) or (Pos('ssleay32', Name) > 0) or
    (Pos('libeay32', Name) > 0);
end;

function StripDecoration(const AName: string): string;
var
  AtPos: Integer;
begin
  Result := UpperCase(AName);
  while (Result <> '') and (Result[1] = '_') do
    Delete(Result, 1, 1);
  AtPos := Pos('@', Result);
  if AtPos > 0 then
    Delete(Result, AtPos, MaxInt);
end;

function IsOpenSSLSymbol(const AName: string): Boolean;
var
  Name: string;
  Index: Integer;
begin
  Name := StripDecoration(AName);
  { Pascal unit symbols such as OPENSSL_$$_INITSSLINTERFACE are the
    runtime-loader implementation, not C OpenSSL linkage. }
  if Pos('$', Name) > 0 then
    Exit(False);
  { Windows thread-local-storage runtime symbols (the PE .tls directory:
    _tls_index, _tls_used, __tls_start__/__tls_end__) decorate to TLS_*
    and would otherwise match the OpenSSL "TLS" family. They are FPC /
    binutils threadvar plumbing, present in every threaded binary — not
    OpenSSL's TLS_method family. }
  if (Name = 'TLS_INDEX') or (Name = 'TLS_USED')
    or (Name = 'TLS_START__') or (Name = 'TLS_END__') then
    Exit(False);
  for Index := Low(OPENSSL_FAMILIES) to High(OPENSSL_FAMILIES) do
    if StartsWith(Name, OPENSSL_FAMILIES[Index] + '_') then
      Exit(True);
  Result := StartsWith(Name, 'D2I_') or StartsWith(Name, 'I2D_') or
    StartsWith(Name, 'SK_') or (Name = 'OPENSSL_VERSION') or
    (Name = 'OPENSSL_VERSION_NUM') or (Name = 'SSLEAY') or
    (Name = 'SSLEAY_VERSION');
end;

function IsSystemDLL(const AName: string): Boolean;
var
  Name: string;
begin
  Name := LowerCase(AName);
  Result := StartsWith(Name, 'api-ms-win-') or
    StartsWith(Name, 'ext-ms-win-') or (Name = 'kernel32.dll') or
    (Name = 'ntdll.dll') or (Name = 'advapi32.dll') or
    (Name = 'bcrypt.dll') or (Name = 'crypt32.dll') or
    (Name = 'ole32.dll') or (Name = 'secur32.dll') or
    (Name = 'shell32.dll') or (Name = 'user32.dll') or
    (Name = 'ws2_32.dll') or (Name = 'msvcrt.dll') or
    (Name = 'ucrtbase.dll');
end;

function IsIdentifierChar(const AValue: Char): Boolean;
begin
  Result := (AValue in ['A'..'Z', 'a'..'z', '0'..'9', '_', '$', '@']);
end;

function FindOpenSSLMapSymbol(const ALine: string): string;
var
  StartPos, Finish: Integer;
  Candidate: string;
begin
  StartPos := 1;
  while StartPos <= Length(ALine) do
  begin
    while (StartPos <= Length(ALine)) and
      not IsIdentifierChar(ALine[StartPos]) do
      Inc(StartPos);
    Finish := StartPos;
    while (Finish <= Length(ALine)) and IsIdentifierChar(ALine[Finish]) do
      Inc(Finish);
    Candidate := Copy(ALine, StartPos, Finish - StartPos);
    if (Candidate <> '') and IsOpenSSLSymbol(Candidate) then
      Exit(Candidate);
    StartPos := Finish + 1;
  end;
  Result := '';
end;

function IsOpenSSLArchive(const ALine: string): Boolean;
var
  Line: string;
begin
  Line := LowerCase(ALine);
  Result := ((Pos('.a', Line) > 0) or (Pos('.lib', Line) > 0)) and
    ((Pos('libssl', Line) > 0) or (Pos('libcrypto', Line) > 0) or
    (Pos('openssl', Line) > 0) or (Pos('ssleay32', Line) > 0) or
    (Pos('libeay32', Line) > 0));
end;

procedure AddMapProblems(const ALines: TStrings; const AProblems: TStrings;
  out ARecognized: Boolean);
var
  Index: Integer;
  Line, SymbolName: string;
begin
  ARecognized := False;
  for Index := 0 to ALines.Count - 1 do
  begin
    Line := ALines[Index];
    if (Pos('# Object files:', Line) > 0) or
      (Pos('Linker script and memory map', Line) > 0) or
      (Pos('.o', Line) > 0) or (Pos('.a', Line) > 0) or
      (Pos('.lib', Line) > 0) then
      ARecognized := True;
    if IsOpenSSLArchive(Line) then
      AProblems.Add('link map line ' + IntToStr(Index + 1) +
        ': OpenSSL archive input');
    SymbolName := FindOpenSSLMapSymbol(Line);
    if SymbolName <> '' then
      AProblems.Add('link map line ' + IntToStr(Index + 1) +
        ': symbol ' + SymbolName);
  end;
end;

function LoadBytes(const APath: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size > High(Integer) then
      Fail('PE binary is too large');
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure CheckFiles(const ABinaryPath, AMapPath: string);
var
  Parser: TPEImports;
  Entries: TImportEntries;
  MapLines, Problems: TStringList;
  Index, SystemImports: Integer;
  MapRecognized: Boolean;
begin
  Parser := TPEImports.Create(LoadBytes(ABinaryPath));
  try
    Entries := Parser.Entries;
  finally
    Parser.Free;
  end;
  Problems := TStringList.Create;
  MapLines := TStringList.Create;
  try
    SystemImports := 0;
    for Index := 0 to High(Entries) do
    begin
      if IsOpenSSLDLL(Entries[Index].DLLName) then
        Problems.Add(Entries[Index].Kind + ' DLL ' + Entries[Index].DLLName);
      if IsOpenSSLSymbol(Entries[Index].SymbolName) then
        Problems.Add(Entries[Index].Kind + ' symbol ' +
          Entries[Index].SymbolName + ' from ' + Entries[Index].DLLName);
      if IsSystemDLL(Entries[Index].DLLName) and
        not StartsWith(Entries[Index].SymbolName, '#') then
        Inc(SystemImports);
    end;
    if SystemImports = 0 then
      Fail('no named Windows-system import found');
    MapLines.LoadFromFile(AMapPath);
    if Trim(MapLines.Text) = '' then
      Fail('link map is empty');
    AddMapProblems(MapLines, Problems, MapRecognized);
    if not MapRecognized then
      Fail('link map contains no recognizable object or archive evidence');
    if Problems.Count > 0 then
      Fail('prohibited OpenSSL linkage:' + LineEnding + '  ' +
        StringReplace(Trim(Problems.Text), LineEnding, LineEnding + '  ',
        [rfReplaceAll]));
    WriteLn('OK: inspected ', Length(Entries),
      ' named normal/delay imports (', SystemImports,
      ' system) and final linker map');
  finally
    MapLines.Free;
    Problems.Free;
  end;
end;

procedure Put16(var AData: TBytes; const AOffset: Integer;
  const AValue: Word);
begin
  AData[AOffset] := AValue and $FF;
  AData[AOffset + 1] := AValue shr 8;
end;

procedure Put32(var AData: TBytes; const AOffset: Integer;
  const AValue: Cardinal);
begin
  Put16(AData, AOffset, AValue and $FFFF);
  Put16(AData, AOffset + 2, AValue shr 16);
end;

procedure Put64(var AData: TBytes; const AOffset: Integer;
  const AValue: QWord);
begin
  Put32(AData, AOffset, AValue and $FFFFFFFF);
  Put32(AData, AOffset + 4, AValue shr 32);
end;

procedure PutText(var AData: TBytes; const AOffset: Integer;
  const AValue: AnsiString);
var
  Index: Integer;
begin
  for Index := 1 to Length(AValue) do
    AData[AOffset + Index - 1] := Ord(AValue[Index]);
end;

function Fixture(const AIs64: Boolean): TBytes;
var
  OptionalSize, Machine, Optional, Directories, Section, Index: Integer;
  Thunks, Names: array[0..2] of Cardinal;

  function Offset(const ARVA: Cardinal): Integer;
  begin
    Result := ARVA - $1000 + $200;
  end;

begin
  SetLength(Result, $800);
  FillChar(Result[0], Length(Result), 0);
  Result[0] := Ord('M');
  Result[1] := Ord('Z');
  Put32(Result, $3C, $80);
  PutText(Result, $80, 'PE'#0#0);
  if AIs64 then
  begin
    OptionalSize := $F0;
    Machine := $8664;
  end
  else
  begin
    OptionalSize := $E0;
    Machine := $14C;
  end;
  Put16(Result, $84, Machine);
  Put16(Result, $86, 1);
  Put16(Result, $94, OptionalSize);
  Optional := $98;
  if AIs64 then
  begin
    Put16(Result, Optional, $20B);
    Put64(Result, Optional + 24, $140000000);
    Put32(Result, Optional + 108, 16);
    Directories := Optional + 112;
  end
  else
  begin
    Put16(Result, Optional, $10B);
    Put32(Result, Optional + 28, $400000);
    Put32(Result, Optional + 92, 16);
    Directories := Optional + 96;
  end;
  Put32(Result, Optional + 60, $200);
  Put32(Result, Directories + 8, $1000);
  Put32(Result, Directories + 12, 60);
  Put32(Result, Directories + 13 * 8, $1040);
  Put32(Result, Directories + 13 * 8 + 4, 64);
  Section := Optional + OptionalSize;
  PutText(Result, Section, '.idata'#0#0);
  Put32(Result, Section + 8, $600);
  Put32(Result, Section + 12, $1000);
  Put32(Result, Section + 16, $600);
  Put32(Result, Section + 20, $200);
  Put32(Result, Offset($1000), $1140);
  Put32(Result, Offset($1000) + 12, $10C0);
  Put32(Result, Offset($1000) + 16, $1160);
  Put32(Result, Offset($1014), $1150);
  Put32(Result, Offset($1014) + 12, $10E0);
  Put32(Result, Offset($1014) + 16, $1170);
  Put32(Result, Offset($1040), 1);
  Put32(Result, Offset($1040) + 4, $1100);
  Put32(Result, Offset($1040) + 12, $1180);
  Put32(Result, Offset($1040) + 16, $1190);
  PutText(Result, Offset($10C0), 'renamed.dll'#0);
  PutText(Result, Offset($10E0), 'KERNEL32.dll'#0);
  PutText(Result, Offset($1100), 'crypto-shim.dll'#0);
  Thunks[0] := $1140;
  Thunks[1] := $1150;
  Thunks[2] := $1190;
  Names[0] := $1200;
  Names[1] := $1220;
  Names[2] := $1240;
  for Index := 0 to 2 do
    if AIs64 then
      Put64(Result, Offset(Thunks[Index]), Names[Index])
    else
      Put32(Result, Offset(Thunks[Index]), Names[Index]);
  PutText(Result, Offset($1200), #0#0'SSL_read'#0);
  PutText(Result, Offset($1220), #0#0'GetProcAddress'#0);
  PutText(Result, Offset($1240), #0#0'EVP_DigestInit_ex'#0);
end;

procedure AddFixtureEntries(var AEntries: TImportEntries;
  const AIs64: Boolean);
var
  Parser: TPEImports;
  Parsed: TImportEntries;
  OldLength, Index: Integer;
begin
  Parser := TPEImports.Create(Fixture(AIs64));
  try
    Parsed := Parser.Entries;
  finally
    Parser.Free;
  end;
  OldLength := Length(AEntries);
  SetLength(AEntries, OldLength + Length(Parsed));
  for Index := 0 to High(Parsed) do
    AEntries[OldLength + Index] := Parsed[Index];
end;

procedure SelfTest;
var
  Entries: TImportEntries;
  Lines, Problems: TStringList;
  Index: Integer;
  FoundNormal, FoundDelay, FoundSystem, Recognized: Boolean;
begin
  SetLength(Entries, 0);
  AddFixtureEntries(Entries, False);
  AddFixtureEntries(Entries, True);
  FoundNormal := False;
  FoundDelay := False;
  FoundSystem := False;
  for Index := 0 to High(Entries) do
  begin
    FoundNormal := FoundNormal or ((Entries[Index].Kind = 'import') and
      (Entries[Index].SymbolName = 'SSL_read') and
      IsOpenSSLSymbol(Entries[Index].SymbolName));
    FoundDelay := FoundDelay or ((Entries[Index].Kind = 'delay-import') and
      (Entries[Index].SymbolName = 'EVP_DigestInit_ex') and
      IsOpenSSLSymbol(Entries[Index].SymbolName));
    FoundSystem := FoundSystem or (IsSystemDLL(Entries[Index].DLLName) and
      (Entries[Index].SymbolName = 'GetProcAddress'));
  end;
  if not FoundNormal then
    Fail('normal-import canary was not detected');
  if not FoundDelay then
    Fail('delay-import canary was not detected');
  if not FoundSystem then
    Fail('system-import canary was not parsed');
  if not IsOpenSSLDLL('ssleay32.dll') then
    Fail('legacy-DLL canary was not detected');
  if not IsOpenSSLDLL('openssl3.dll') then
    Fail('renamed-DLL canary was not detected');
  if not IsOpenSSLDLL('libssl-3-x64.dll') then
    Fail('versioned-DLL canary was not detected');
  if not IsOpenSSLSymbol('OpenSSL_version_num') or
    not IsOpenSSLSymbol('_EVP_DigestInit_ex@8') then
    Fail('decorated-symbol canary was not detected');
  { Windows thread-local-storage runtime symbols must not be misread as
    OpenSSL, while a genuine OpenSSL TLS_ symbol still must be. }
  if IsOpenSSLSymbol('_tls_index') or IsOpenSSLSymbol('___tls_start__') or
    IsOpenSSLSymbol('___tls_end__') or IsOpenSSLSymbol('_tls_used') then
    Fail('thread-local-storage symbol was misflagged as OpenSSL linkage');
  if not IsOpenSSLSymbol('TLS_server_method') then
    Fail('OpenSSL TLS_ symbol canary was not detected');
  Lines := TStringList.Create;
  Problems := TStringList.Create;
  try
    Lines.Text := 'Linker script and memory map' + LineEnding +
      'libssl.a(x.o)' + LineEnding + 'renamed.a(x.o) SSL_accept';
    AddMapProblems(Lines, Problems, Recognized);
    if not Recognized or (Problems.Count < 2) then
      Fail('static-link canaries were not detected');
    Lines.Text := 'Linker script and memory map' + LineEnding +
      'libsafe.a(x.o) _main' + LineEnding +
      'transportsecurity.o TRANSPORTSECURITY_$$_OPENSSL_VERSION_NUMBER';
    Problems.Clear;
    AddMapProblems(Lines, Problems, Recognized);
    if not Recognized or (Problems.Count <> 0) then
      Fail('safe link-map canary was rejected');
  finally
    Problems.Free;
    Lines.Free;
  end;
  WriteLn('OK: prohibited normal/delay import and static-link canaries detected');
end;

procedure Run;
var
  BinaryPath, MapPath: string;
  Index: Integer;
  RunSelfTest: Boolean;
begin
  BinaryPath := '';
  MapPath := '';
  RunSelfTest := False;
  Index := 1;
  while Index <= ParamCount do
  begin
    if ParamStr(Index) = '--self-test' then
      RunSelfTest := True
    else if ParamStr(Index) = '--map' then
    begin
      Inc(Index);
      if Index > ParamCount then
        Fail('--map requires a path');
      MapPath := ParamStr(Index);
    end
    else if BinaryPath = '' then
      BinaryPath := ParamStr(Index)
    else
      Fail('unexpected argument: ' + ParamStr(Index));
    Inc(Index);
  end;
  if RunSelfTest then
    SelfTest;
  if BinaryPath <> '' then
  begin
    if MapPath = '' then
      Fail('--map is required with a PE binary');
    CheckFiles(BinaryPath, MapPath);
  end
  else if not RunSelfTest then
    Fail('a PE binary or --self-test is required');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'PE OpenSSL linkage check failed: ', E.Message);
      Halt(2);
    end;
  end;
end.
