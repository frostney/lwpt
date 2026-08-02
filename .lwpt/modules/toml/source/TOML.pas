{ TOML — full TOML 1.1 parser.

  The grammar follows the spec; the AST is decoupled from any host
  runtime value system so the parser is consumable by any LWPT-using
  Pascal project. (The unit historically descended from GocciaScript's
  Goccia.TOML.pas, which embedded a TGocciaValue / TGocciaArrayValue
  / TGocciaObjectValue / Goccia.Temporal.Utils dependency tree; the
  an earlier refactor stripped those out — see git history for the diff.)

  AST shape:
    - Scalars carry a canonical-text string + a scalar-kind tag.
      Tests that need typed access call helpers like AsInt / AsBool
      / AsString.
    - Arrays use TTOMLNodeList directly (no shadow value field).
    - Tables use TTOMLNodeMap (TOrderedStringMap) directly (no
      shadow object field).
    - Date/time scalars store their canonical text + a scalar-kind
      tag; structural validation runs at parse time, but value
      extraction is the consumer's responsibility (parse the text
      yourself if you need broken-down components).
    - ParseDocument is the canonical entry point and returns a
      TTOMLNode tree.

  See ADR-0010 for the rationale on swapping our partial reader
  for the converted Goccia parser. }
unit TOML;

{$I Shared.inc}

interface

uses
  Generics.Collections,
  SysUtils,

  OrderedStringMap;

type
  ETOMLParseError = class(Exception);

  TTOMLNode = class;
  TTOMLNodeMap = TOrderedStringMap<TTOMLNode>;
  TTOMLNodeList = TObjectList<TTOMLNode>;
  TTOMLScalarKind = (tskString, tskInteger, tskFloat, tskBool,
    tskDateTime, tskDateTimeLocal, tskDateLocal, tskTimeLocal);
  TTOMLNodeKind = (tnkScalar, tnkArray, tnkTable, tnkArrayOfTables);

  { Out-parameter scratch records for the date/time validators.
    The parser uses these only during validation; the resulting AST
    stores the canonical text only, so the broken-down fields are
    discarded after validation. }
  TTemporalDateRecord = record
    Year, Month, Day: Integer;
  end;
  TTemporalTimeRecord = record
    Hour, Minute, Second: Integer;
    Millisecond, Microsecond, Nanosecond: Integer;
  end;

  { TOML AST node. The fields previously holding TGocciaValue /
    TGocciaArrayValue / TGocciaObjectValue references are gone; the
    Items + Children collections are now the authoritative storage. }
  TTOMLNode = class
  private
    FCanonicalValue: string;
    FChildren: TTOMLNodeMap;
    FDottedDefined: Boolean;
    FHeaderAllowed: Boolean;
    FHeaderDefined: Boolean;
    FItems: TTOMLNodeList;
    FKind: TTOMLNodeKind;
    FScalarKind: TTOMLScalarKind;
    FScalarText: string;
    FSealed: Boolean;
  public
    constructor CreateScalar(const AScalarText: string;
      const AScalarKind: TTOMLScalarKind;
      const ACanonicalValue: string);
    constructor CreateArray;
    constructor CreateTable(const AHeaderDefined, AHeaderAllowed,
      ASealed, ADottedDefined: Boolean);
    constructor CreateArrayOfTables(const ASealed: Boolean);
    destructor Destroy; override;

    function LastItem: TTOMLNode;

    property CanonicalValue: string read FCanonicalValue;
    property Children: TTOMLNodeMap read FChildren;
    property DottedDefined: Boolean read FDottedDefined write FDottedDefined;
    property HeaderAllowed: Boolean read FHeaderAllowed write FHeaderAllowed;
    property HeaderDefined: Boolean read FHeaderDefined write FHeaderDefined;
    property Items: TTOMLNodeList read FItems;
    property Kind: TTOMLNodeKind read FKind;
    property ScalarKind: TTOMLScalarKind read FScalarKind;
    property ScalarText: string read FScalarText;
    property Sealed: Boolean read FSealed write FSealed;
  end;

  TTOMLParser = class
  private
    FCurrentTable: TTOMLNode;
    FIndex: Integer;
    FRoot: TTOMLNode;
    FText: UTF8String;

    procedure Advance(const ACount: Integer = 1);
    procedure AppendCodePointUTF8(var ATarget: UTF8String;
      const ACodePoint: Cardinal);
    { AValueNode is the parsed scalar / array / inline-table — no
      separate value type is needed. AInlineTableNode is used only
      when AValueNode is itself an inline table whose sealed/dotted
      state needs preserving. }
    procedure AssignValue(const ATargetTable: TTOMLNode;
      const APath: TArray<string>; const AValueNode: TTOMLNode;
      const AInlineTableNode: TTOMLNode; const AAllowSealed: Boolean);
    procedure AttachChild(const ATable: TTOMLNode; const AKey: string;
      const ANode: TTOMLNode);
    function ConsumeComment: Boolean;
    function ConsumeNewline: Boolean;
    function CurrentChar: Char;
    function EnsureDottedKeyTable(const AContext: TTOMLNode;
      const AKey: string; const AAllowSealed: Boolean): TTOMLNode;
    function GetChild(const ATable: TTOMLNode;
      const AKey: string): TTOMLNode;
    function HasChars(const ACount: Integer): Boolean;
    function IsAtEnd: Boolean;
    function MatchText(const AText: string): Boolean;
    function ParseArray: TTOMLNode;
    function ParseBareKey: string;
    function ParseBareValue(const ADelimiters: string): TTOMLNode;
    function ParseBasicString(const AMultiline, AIsKey: Boolean): string;
    function ParseHexCodePoint(const ADigits: Integer): Cardinal;
    function ParseInlineTable: TTOMLNode;
    function ParseKeyPath: TArray<string>;
    procedure ParseKeyValuePair;
    function ParseLiteralString(const AMultiline, AIsKey: Boolean): string;
    function ParseQuotedKey: string;
    function ParseRegularTable(const APath: TArray<string>): TTOMLNode;
    function ParseTableArray(const APath: TArray<string>): TTOMLNode;
    procedure ParseTableHeader;
    function ParseTokenValue(const AToken: string): TTOMLNode;
    function ParseValue(const ADelimiters: string): TTOMLNode;
    function PeekChar(const AOffset: Integer = 0): Char;
    procedure RaiseParseError(const AMessage: string);
    procedure RequireNotSealed(const ANode: TTOMLNode; const AKey: string);
    procedure Reset(const AText: UTF8String);
    procedure SkipBlankLinesAndComments;
    procedure PrepareInput;
    procedure SkipWhitespace(const AAllowNewlines: Boolean);
    function TryParseBinaryInteger(const AToken: string;
      out AValue: Double): Boolean;
    function TryParseBoolean(const AToken: string;
      out ANode: TTOMLNode): Boolean;
    function TryParseDate(const AText: string;
      out ADate: TTemporalDateRecord): Boolean;
    function TryParseDateTime(const AText: string;
      out AScalarKind: TTOMLScalarKind;
      out ACanonicalText: string): Boolean;
    function TryParseDecimalInteger(const AToken: string;
      out AValue: Double): Boolean;
    function TryParseFloatValue(const AToken: string;
      out AValue: Double): Boolean;
    function TryParseHexInteger(const AToken: string;
      out AValue: Double): Boolean;
    function TryParseLocalTime(const AText: string;
      out ATime: TTemporalTimeRecord; out AParsedLength: Integer;
      out ACanonicalText: string): Boolean;
    function TryParseNumber(const AToken: string;
      out ANode: TTOMLNode): Boolean;
    function TryParseOctalInteger(const AToken: string;
      out AValue: Double): Boolean;
    function TryParseOffset(const AText: string;
      const AStartIndex: Integer; out AParsedLength: Integer): Boolean;
    function TryParseTimeOnly(const AText: string;
      out ACanonicalText: string): Boolean;
    function ValidateDigitsWithSeparators(const AText, AAllowedDigits: string;
      const AAllowEmpty: Boolean): Boolean;
  public
    { Canonical parse entry. The caller manages the returned root
      node's lifetime (Free it when done). }
    function ParseDocument(const AText: UTF8String): TTOMLNode;
  end;

implementation

uses
  Math;

function IsLeapYear(const AYear: Integer): Boolean; inline;
begin
  Result := ((AYear mod 4 = 0) and (AYear mod 100 <> 0))
         or (AYear mod 400 = 0);
end;

function IsValidDate(const AYear, AMonth, ADay: Integer): Boolean;
const
  DaysInMonth: array[1..12] of Integer =
    (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
var Limit: Integer;
begin
  Result := False;
  if (AMonth < 1) or (AMonth > 12) then Exit;
  if ADay < 1 then Exit;
  Limit := DaysInMonth[AMonth];
  if (AMonth = 2) and IsLeapYear(AYear) then Limit := 29;
  Result := ADay <= Limit;
end;

function IsValidTime(const AHour, AMinute, ASecond,
  AMillisecond, AMicrosecond, ANanosecond: Integer): Boolean;
begin
  Result := (AHour >= 0) and (AHour <= 23)
        and (AMinute >= 0) and (AMinute <= 59)
        and (ASecond >= 0) and (ASecond <= 60)   { allow leap second }
        and (AMillisecond >= 0) and (AMillisecond <= 999)
        and (AMicrosecond >= 0) and (AMicrosecond <= 999)
        and (ANanosecond >= 0) and (ANanosecond <= 999);
end;

function IsSpaceOrTab(const AChar: Char): Boolean;
begin
  Result := (AChar = ' ') or (AChar = #9);
end;

function IsNewlineChar(const AChar: Char): Boolean;
begin
  Result := (AChar = #10) or (AChar = #13);
end;

function IsControlCharacter(const AChar: Char): Boolean;
begin
  Result := (Ord(AChar) < 32) or (Ord(AChar) = 127);
end;

function TOMLFormatSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
end;

function IsDigit(const AChar: Char): Boolean;
begin
  Result := (AChar >= '0') and (AChar <= '9');
end;

function IsHexDigit(const AChar: Char): Boolean;
begin
  Result := IsDigit(AChar) or ((AChar >= 'a') and (AChar <= 'f')) or
    ((AChar >= 'A') and (AChar <= 'F'));
end;

function IsBareKeyCharacter(const AChar: Char): Boolean;
begin
  Result := IsDigit(AChar) or ((AChar >= 'a') and (AChar <= 'z')) or
    ((AChar >= 'A') and (AChar <= 'Z')) or (AChar = '_') or (AChar = '-');
end;

function NormalizeMultilineNewline(const AText: string; var AIndex: Integer): string;
const
  TOML_MULTILINE_NEWLINE = #10;
begin
  if (AIndex <= Length(AText)) and (AText[AIndex] = #13) then
  begin
    if (AIndex < Length(AText)) and (AText[AIndex + 1] = #10) then
      Inc(AIndex, 2)
    else
      raise ETOMLParseError.Create(
        'Bare carriage return is not allowed in TOML newlines.');
  end
  else
    Inc(AIndex);
  Result := TOML_MULTILINE_NEWLINE;
end;

function JoinPath(const APath: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(APath) - 1 do
  begin
    if Result <> '' then
      Result := Result + '.';
    Result := Result + APath[I];
  end;
end;

function JoinPathPrefix(const APath: TArray<string>; const ACount: Integer): string;
var
  I, Limit: Integer;
begin
  Result := '';
  Limit := ACount;
  if Limit > Length(APath) then
    Limit := Length(APath);
  for I := 0 to Limit - 1 do
  begin
    if Result <> '' then
      Result := Result + '.';
    Result := Result + APath[I];
  end;
end;

function StripUnderscores(const AText: string): string;
var
  C: Char;
  I: Integer;
begin
  Result := '';
  SetLength(Result, Length(AText));
  I := 0;
  for C in AText do
    if C <> '_' then
    begin
      Inc(I);
      Result[I] := C;
    end;
  SetLength(Result, I);
end;

function PadInteger(const AValue, ADigits: Integer): string;
begin
  Result := Format('%.*d', [ADigits, AValue]);
end;

function CanonicalizeFloatToken(const AToken: string): string;
var
  DotIndex, ExponentIndex: Integer;
  ExponentPart, Mantissa, SignPart: string;
begin
  if (AToken = 'inf') or (AToken = '+inf') then
    Exit('inf');
  if AToken = '-inf' then
    Exit('-inf');
  if (AToken = 'nan') or (AToken = '+nan') or (AToken = '-nan') then
    Exit('nan');

  SignPart := '';
  Mantissa := AToken;
  if (Mantissa <> '') and ((Mantissa[1] = '+') or (Mantissa[1] = '-')) then
  begin
    if Mantissa[1] = '-' then
      SignPart := '-';
    Delete(Mantissa, 1, 1);
  end;

  Mantissa := StripUnderscores(Mantissa);
  ExponentIndex := Pos('e', LowerCase(Mantissa));
  if ExponentIndex > 0 then
  begin
    ExponentPart := Copy(Mantissa, ExponentIndex + 1, MaxInt);
    Mantissa := Copy(Mantissa, 1, ExponentIndex - 1);
    if Pos('.', Mantissa) = 0 then
      Mantissa := Mantissa + '.0';
    Result := SignPart + Mantissa + 'e' + ExponentPart;
    Exit;
  end;

  DotIndex := Pos('.', Mantissa);
  if DotIndex = 0 then
    Result := SignPart + Mantissa + '.0'
  else
    Result := SignPart + Mantissa;
end;

function CanonicalizeIntegerToken(const AToken: string): string;
var
  C: Char;
  Digits: string;
  Value64: QWord;
begin
  if (Copy(AToken, 1, 2) = '0x') or (Copy(AToken, 1, 2) = '0o') or
     (Copy(AToken, 1, 2) = '0b') then
  begin
    Digits := StripUnderscores(Copy(AToken, 3, MaxInt));
    if Copy(AToken, 1, 2) = '0x' then
      Value64 := StrToQWord('$' + Digits)
    else
    begin
      Value64 := 0;
      for C in Digits do
        if Copy(AToken, 1, 2) = '0o' then
          Value64 := (Value64 * 8) + Ord(C) - Ord('0')
        else
          Value64 := (Value64 * 2) + Ord(C) - Ord('0');
    end;
    Exit(UIntToStr(Value64));
  end;

  Result := StripUnderscores(AToken);
  if (Result <> '') and (Result[1] = '+') then
    Delete(Result, 1, 1);
  if Result = '-0' then
    Result := '0';
end;

function IsFloatToken(const AToken: string): Boolean;
var
  LowerToken: string;
begin
  LowerToken := LowerCase(AToken);
  if (LowerToken = 'inf') or (LowerToken = '+inf') or (LowerToken = '-inf') or
     (LowerToken = 'nan') or (LowerToken = '+nan') or (LowerToken = '-nan') then
    Exit(True);
  if Pos('.', AToken) > 0 then
    Exit(True);
  if (Copy(LowerToken, 1, 2) = '0x') or (Copy(LowerToken, 1, 2) = '0o') or
     (Copy(LowerToken, 1, 2) = '0b') then
    Exit(False);
  Result := Pos('e', LowerToken) > 0;
end;

{ TTOMLNode }

{ TTOMLNode constructors: scalar text + kind are stored directly,
  and the Items / Children collections are the authoritative storage
  for array/table contents (no shadow value-system fields). }

constructor TTOMLNode.CreateScalar(const AScalarText: string;
  const AScalarKind: TTOMLScalarKind; const ACanonicalValue: string);
begin
  inherited Create;
  FKind := tnkScalar;
  FCanonicalValue := ACanonicalValue;
  FScalarKind := AScalarKind;
  FScalarText := AScalarText;
end;

constructor TTOMLNode.CreateArray;
begin
  inherited Create;
  FKind := tnkArray;
  FItems := TTOMLNodeList.Create(True);
end;

constructor TTOMLNode.CreateTable(
  const AHeaderDefined, AHeaderAllowed,
  ASealed, ADottedDefined: Boolean);
begin
  inherited Create;
  FKind := tnkTable;
  FDottedDefined := ADottedDefined;
  FHeaderDefined := AHeaderDefined;
  FHeaderAllowed := AHeaderAllowed;
  FSealed := ASealed;
  FChildren := TTOMLNodeMap.Create;
end;

constructor TTOMLNode.CreateArrayOfTables(const ASealed: Boolean);
begin
  inherited Create;
  FKind := tnkArrayOfTables;
  FSealed := ASealed;
  FItems := TTOMLNodeList.Create(True);
end;

destructor TTOMLNode.Destroy;
var
  Pair: TTOMLNodeMap.TKeyValuePair;
begin
  if Assigned(FChildren) then
  begin
    for Pair in FChildren do
      Pair.Value.Free;
    FChildren.Free;
  end;
  FItems.Free;
  inherited;
end;

function TTOMLNode.LastItem: TTOMLNode;
begin
  if (FKind <> tnkArrayOfTables) or (FItems.Count = 0) then
    Result := nil
  else
    Result := FItems[FItems.Count - 1];
end;

{ TTOMLParser }

procedure TTOMLParser.Reset(const AText: UTF8String);
begin
  FText := AText;
  FIndex := 1;
  FRoot.Free;
  FRoot := TTOMLNode.CreateTable(False, False,
    False, False);
  FCurrentTable := FRoot;
end;

procedure TTOMLParser.PrepareInput;
var
  B: Byte;
  I: Integer;
begin
  if (Length(FText) >= 3) and (Byte(FText[1]) = $EF) and
     (Byte(FText[2]) = $BB) and (Byte(FText[3]) = $BF) then
    FIndex := 4;

  for I := 1 to Length(FText) do
  begin
    B := Byte(FText[I]);
    if ((B < 32) and (B <> 9) and (B <> 10) and (B <> 13)) or (B = 127) then
      RaiseParseError('Input contains a forbidden control character (U+' +
        IntToHex(B, 4) + ').');
  end;
end;

function TTOMLParser.ParseDocument(const AText: UTF8String): TTOMLNode;
begin
  Reset(AText);
  try
    PrepareInput;
    SkipBlankLinesAndComments;
    while not IsAtEnd do
    begin
      if PeekChar = '[' then
        ParseTableHeader
      else
        ParseKeyValuePair;
      SkipBlankLinesAndComments;
    end;
    Result := FRoot;
    FRoot := nil;
  finally
    FText := '';
    FIndex := 1;
    FCurrentTable := nil;
    FRoot.Free;
    FRoot := nil;
  end;
end;

procedure TTOMLParser.RaiseParseError(const AMessage: string);
begin
  raise ETOMLParseError.Create(AMessage);
end;

function TTOMLParser.IsAtEnd: Boolean;
begin
  Result := FIndex > Length(FText);
end;

function TTOMLParser.HasChars(const ACount: Integer): Boolean;
begin
  Result := (FIndex + ACount - 1) <= Length(FText);
end;

function TTOMLParser.CurrentChar: Char;
begin
  if IsAtEnd then
    Result := #0
  else
    Result := FText[FIndex];
end;

function TTOMLParser.PeekChar(const AOffset: Integer): Char;
var
  Position: Integer;
begin
  Position := FIndex + AOffset;
  if (Position < 1) or (Position > Length(FText)) then
    Result := #0
  else
    Result := FText[Position];
end;

procedure TTOMLParser.Advance(const ACount: Integer);
begin
  Inc(FIndex, ACount);
end;

function TTOMLParser.MatchText(const AText: string): Boolean;
begin
  Result := Copy(FText, FIndex, Length(AText)) = AText;
end;

procedure TTOMLParser.SkipWhitespace(const AAllowNewlines: Boolean);
begin
  while not IsAtEnd do
  begin
    if IsSpaceOrTab(CurrentChar) then
      Advance
    else if AAllowNewlines and ConsumeNewline then
    begin
    end
    else if AAllowNewlines and ConsumeComment then
    begin
    end
    else
      Break;
  end;
end;

function TTOMLParser.ConsumeNewline: Boolean;
begin
  Result := False;
  if IsAtEnd then
    Exit;

  if CurrentChar = #13 then
  begin
    if PeekChar(1) <> #10 then
      RaiseParseError('Bare carriage return is not allowed in TOML newlines.');
    Result := True;
    Advance(2);
  end
  else if CurrentChar = #10 then
  begin
    Result := True;
    Advance;
  end;
end;

function TTOMLParser.ConsumeComment: Boolean;
begin
  Result := CurrentChar = '#';
  if not Result then
    Exit;

  while not IsAtEnd and not IsNewlineChar(CurrentChar) do
  begin
    if IsControlCharacter(CurrentChar) and (CurrentChar <> #9) then
      RaiseParseError('Comments cannot contain control characters.');
    Advance;
  end;
end;

procedure TTOMLParser.SkipBlankLinesAndComments;
begin
  while not IsAtEnd do
  begin
    while IsSpaceOrTab(CurrentChar) do
      Advance;
    if ConsumeComment then
    begin
      ConsumeNewline;
      Continue;
    end;
    if ConsumeNewline then
      Continue;
    Break;
  end;
end;

function TTOMLParser.ParseBareKey: string;
begin
  Result := '';
  while IsBareKeyCharacter(CurrentChar) do
  begin
    Result := Result + CurrentChar;
    Advance;
  end;
  if Result = '' then
    RaiseParseError('Expected a TOML key.');
end;

function TTOMLParser.ParseHexCodePoint(const ADigits: Integer): Cardinal;
var
  C: Char;
  HexText: string;
  Value64: QWord;
begin
  if not HasChars(ADigits) then
    RaiseParseError('Incomplete Unicode escape sequence.');
  HexText := Copy(FText, FIndex, ADigits);
  for C in HexText do
    if not IsHexDigit(C) then
      RaiseParseError('Invalid Unicode escape sequence.');
  Advance(ADigits);
  Value64 := StrToQWord('$' + HexText);
  if (Value64 > $10FFFF) or ((Value64 >= $D800) and (Value64 <= $DFFF)) then
    RaiseParseError('Unicode escape must be a Unicode scalar value.');
  Result := Cardinal(Value64);
end;

procedure TTOMLParser.AppendCodePointUTF8(var ATarget: UTF8String;
  const ACodePoint: Cardinal);
begin
  if ACodePoint <= $7F then
    ATarget := ATarget + Chr(ACodePoint)
  else if ACodePoint <= $7FF then
    ATarget := ATarget + Chr($C0 or (ACodePoint shr 6)) +
      Chr($80 or (ACodePoint and $3F))
  else if ACodePoint <= $FFFF then
    ATarget := ATarget + Chr($E0 or (ACodePoint shr 12)) +
      Chr($80 or ((ACodePoint shr 6) and $3F)) +
      Chr($80 or (ACodePoint and $3F))
  else
    ATarget := ATarget + Chr($F0 or (ACodePoint shr 18)) +
      Chr($80 or ((ACodePoint shr 12) and $3F)) +
      Chr($80 or ((ACodePoint shr 6) and $3F)) +
      Chr($80 or (ACodePoint and $3F));
end;

function TTOMLParser.ParseBasicString(const AMultiline,
  AIsKey: Boolean): string;
var
  Buffer: UTF8String;
  QuoteRun, StartIndex: Integer;
begin
  Buffer := '';
  if AMultiline then
    Advance(3)
  else
    Advance;

  if AMultiline and ConsumeNewline then
  begin
  end;

  while not IsAtEnd do
  begin
    if AMultiline then
    begin
      if MatchText('"""') then
      begin
        QuoteRun := 0;
        while PeekChar(QuoteRun) = '"' do
          Inc(QuoteRun);
        if QuoteRun > 5 then
          RaiseParseError('Multiline basic strings cannot contain three consecutive quotes.');
        if QuoteRun > 3 then
          Buffer := Buffer + Copy(FText, FIndex, QuoteRun - 3);
        Advance(QuoteRun);
        Exit(Buffer);
      end;
    end
    else if CurrentChar = '"' then
    begin
      Advance;
      Exit(Buffer);
    end;

    if CurrentChar = '\' then
    begin
      Advance;
      if AMultiline then
      begin
        StartIndex := FIndex;
        while IsSpaceOrTab(PeekChar(StartIndex - FIndex)) do
          Inc(StartIndex);
        if (StartIndex <= Length(FText)) and IsNewlineChar(FText[StartIndex]) then
        begin
          FIndex := StartIndex;
          ConsumeNewline;
          while IsSpaceOrTab(CurrentChar) or ConsumeNewline do
          begin
            while IsSpaceOrTab(CurrentChar) do
              Advance;
          end;
          Continue;
        end;
      end;

      case CurrentChar of
        'b':
          begin
            Buffer := Buffer + #8;
            Advance;
          end;
        't':
          begin
            Buffer := Buffer + #9;
            Advance;
          end;
        'n':
          begin
            Buffer := Buffer + #10;
            Advance;
          end;
        'f':
          begin
            Buffer := Buffer + #12;
            Advance;
          end;
        'r':
          begin
            Buffer := Buffer + #13;
            Advance;
          end;
        'e':
          begin
            Buffer := Buffer + #27;
            Advance;
          end;
        '"', '\':
          begin
            Buffer := Buffer + CurrentChar;
            Advance;
          end;
        'x':
          begin
            Advance;
            AppendCodePointUTF8(Buffer, ParseHexCodePoint(2));
          end;
        'u':
          begin
            Advance;
            AppendCodePointUTF8(Buffer, ParseHexCodePoint(4));
          end;
        'U':
          begin
            Advance;
            AppendCodePointUTF8(Buffer, ParseHexCodePoint(8));
          end;
      else
        RaiseParseError('Invalid escape sequence in TOML basic string.');
      end;
      Continue;
    end;

    if IsNewlineChar(CurrentChar) then
    begin
      if not AMultiline then
        RaiseParseError('Single-line basic strings cannot contain newlines.');
      Buffer := Buffer + NormalizeMultilineNewline(FText, FIndex);
      Continue;
    end;

    if IsControlCharacter(CurrentChar) and (CurrentChar <> #9) then
      RaiseParseError('Basic strings cannot contain control characters.');

    Buffer := Buffer + CurrentChar;
    Advance;
  end;

  if AIsKey then
    RaiseParseError('Unterminated quoted TOML key.')
  else
    RaiseParseError('Unterminated TOML basic string.');
end;

function TTOMLParser.ParseLiteralString(const AMultiline,
  AIsKey: Boolean): string;
var
  Buffer: UTF8String;
  QuoteRun: Integer;
begin
  Buffer := '';
  if AMultiline then
    Advance(3)
  else
    Advance;

  if AMultiline and ConsumeNewline then
  begin
  end;

  while not IsAtEnd do
  begin
    if AMultiline then
    begin
      if MatchText('''''''') then
      begin
        QuoteRun := 0;
        while PeekChar(QuoteRun) = '''' do
          Inc(QuoteRun);
        if QuoteRun > 5 then
          RaiseParseError('Multiline literal strings cannot contain three consecutive quotes.');
        if QuoteRun > 3 then
          Buffer := Buffer + Copy(FText, FIndex, QuoteRun - 3);
        Advance(QuoteRun);
        Exit(Buffer);
      end;
    end
    else if CurrentChar = '''' then
    begin
      Advance;
      Exit(Buffer);
    end;

    if IsNewlineChar(CurrentChar) then
    begin
      if not AMultiline then
        RaiseParseError('Single-line literal strings cannot contain newlines.');
      Buffer := Buffer + NormalizeMultilineNewline(FText, FIndex);
      Continue;
    end;

    if IsControlCharacter(CurrentChar) and (CurrentChar <> #9) then
      RaiseParseError('Literal strings cannot contain control characters.');

    Buffer := Buffer + CurrentChar;
    Advance;
  end;

  if AIsKey then
    RaiseParseError('Unterminated quoted TOML key.')
  else
    RaiseParseError('Unterminated TOML literal string.');
end;

function TTOMLParser.ParseQuotedKey: string;
begin
  if MatchText('"""') or MatchText('''''''') then
    RaiseParseError('TOML keys cannot use multiline strings.');

  if CurrentChar = '"' then
    Result := ParseBasicString(False, True)
  else if CurrentChar = '''' then
    Result := ParseLiteralString(False, True)
  else
    RaiseParseError('Expected a quoted TOML key.');
end;

function TTOMLParser.ParseKeyPath: TArray<string>;
var
  Key: string;
begin
  SetLength(Result, 0);
  SkipWhitespace(False);
  while True do
  begin
    if CurrentChar = '"' then
      Key := ParseQuotedKey
    else if CurrentChar = '''' then
      Key := ParseQuotedKey
    else
      Key := ParseBareKey;

    SetLength(Result, Length(Result) + 1);
    Result[Length(Result) - 1] := Key;

    SkipWhitespace(False);
    if CurrentChar <> '.' then
      Break;
    Advance;
    SkipWhitespace(False);
  end;
end;

function TTOMLParser.GetChild(const ATable: TTOMLNode;
  const AKey: string): TTOMLNode;
begin
  Result := nil;
  if Assigned(ATable) and Assigned(ATable.Children) then
    ATable.Children.TryGetValue(AKey, Result);
end;

procedure TTOMLParser.AttachChild(const ATable: TTOMLNode;
  const AKey: string; const ANode: TTOMLNode);
begin
  { Children.Add is the only storage path — the AST is the
    authoritative state. }
  ATable.Children.Add(AKey, ANode);
end;

procedure TTOMLParser.RequireNotSealed(const ANode: TTOMLNode;
  const AKey: string);
begin
  if Assigned(ANode) and ANode.Sealed then
    RaiseParseError(Format(
      'Inline table "%s" is fully defined and cannot be extended.',
      [AKey]));
end;

function TTOMLParser.EnsureDottedKeyTable(
  const AContext: TTOMLNode; const AKey: string;
  const AAllowSealed: Boolean): TTOMLNode;
var
  Existing: TTOMLNode;
begin
  if not AAllowSealed then
    RequireNotSealed(AContext, AKey);

  Existing := GetChild(AContext, AKey);
  if not Assigned(Existing) then
  begin
    Result := TTOMLNode.CreateTable(False, False,
      AAllowSealed or AContext.Sealed, True);
    AttachChild(AContext, AKey, Result);
    Exit;
  end;

  case Existing.Kind of
    tnkScalar:
      RaiseParseError(Format(
        'Cannot redefine "%s" as a table after assigning it a value.',
        [AKey]));
    tnkArrayOfTables:
      RaiseParseError(Format(
        'Cannot extend array of tables "%s" with a dotted key.',
        [AKey]));
  else
    begin
      if not Existing.DottedDefined then
        RaiseParseError(Format(
          'Cannot append to table "%s" with a dotted key after it was defined.',
          [AKey]));
      if Existing.Sealed and not AAllowSealed then
        RaiseParseError(Format(
          'Inline table "%s" is fully defined and cannot be extended.',
          [AKey]));
      Result := Existing;
    end;
  end;
end;

procedure TTOMLParser.AssignValue(const ATargetTable: TTOMLNode;
  const APath: TArray<string>; const AValueNode: TTOMLNode;
  const AInlineTableNode: TTOMLNode; const AAllowSealed: Boolean);
var
  Context, Existing, NewNode: TTOMLNode;
  I: Integer;
  PathLabel: string;
begin
  if Length(APath) = 0 then
    RaiseParseError('TOML assignments require at least one key.');

  Context := ATargetTable;
  for I := 0 to Length(APath) - 2 do
    Context := EnsureDottedKeyTable(Context, APath[I], AAllowSealed);

  if not AAllowSealed then
    RequireNotSealed(Context, APath[Length(APath) - 1]);

  Existing := GetChild(Context, APath[Length(APath) - 1]);
  if Assigned(Existing) then
  begin
    PathLabel := JoinPath(APath);
    RaiseParseError(Format('Cannot define "%s" more than once.', [PathLabel]));
  end;

  { Prefer AInlineTableNode (which carries the inline-table's
    sealed/dotted state); fall back to AValueNode for scalars / arrays.
    The parsed node attaches directly — no intermediate value wrapper. }
  if Assigned(AInlineTableNode) then
    NewNode := AInlineTableNode
  else if Assigned(AValueNode) then
    NewNode := AValueNode
  else
    RaiseParseError('Internal TOML error: missing parsed value node.');
  AttachChild(Context, APath[Length(APath) - 1], NewNode);
end;

function TTOMLParser.ParseRegularTable(
  const APath: TArray<string>): TTOMLNode;
var
  Context, Existing: TTOMLNode;
  I: Integer;
  PathLabel: string;
begin
  if Length(APath) = 0 then
    RaiseParseError('Table headers require at least one key part.');

  Context := FRoot;
  for I := 0 to Length(APath) - 1 do
  begin
    if Context.Sealed then
      RaiseParseError(Format(
        'Inline table "%s" is fully defined and cannot be extended.',
        [JoinPathPrefix(APath, I)]));

    Existing := GetChild(Context, APath[I]);
    if not Assigned(Existing) then
    begin
      Existing := TTOMLNode.CreateTable(
        I = Length(APath) - 1, I <> Length(APath) - 1, False, False);
      AttachChild(Context, APath[I], Existing);
    end
    else if Existing.Kind = tnkScalar then
      RaiseParseError(Format(
        'Cannot redefine "%s" as a table after assigning it a value.',
        [JoinPathPrefix(APath, I + 1)]))
    else if Existing.Kind = tnkArrayOfTables then
    begin
      if I = Length(APath) - 1 then
        RaiseParseError(Format(
          'Cannot redefine array of tables "%s" as a regular table.',
          [JoinPath(APath)]));
      Existing := Existing.LastItem;
      if not Assigned(Existing) then
        RaiseParseError(Format('Array of tables "%s" has no current item.',
          [JoinPathPrefix(APath, I + 1)]));
    end
    else if I = Length(APath) - 1 then
    begin
      PathLabel := JoinPath(APath);
      if Existing.Sealed then
        RaiseParseError(Format(
          'Inline table "%s" is fully defined and cannot be extended.',
          [PathLabel]));
      if Existing.HeaderDefined then
        RaiseParseError(Format('Cannot define table "%s" more than once.',
          [PathLabel]));
      if not Existing.HeaderAllowed then
        RaiseParseError(Format(
          'Table "%s" was already created by a dotted key or inline table.',
          [PathLabel]));
      Existing.HeaderDefined := True;
      Existing.HeaderAllowed := False;
      Existing.DottedDefined := False;
    end;

    Context := Existing;
  end;

  Result := Context;
end;

function TTOMLParser.ParseTableArray(
  const APath: TArray<string>): TTOMLNode;
var
  ArrayNode, Context, Existing, NewItem: TTOMLNode;
  I: Integer;
begin
  if Length(APath) = 0 then
    RaiseParseError('Array-of-table headers require at least one key part.');

  Context := FRoot;
  for I := 0 to Length(APath) - 2 do
  begin
    Existing := GetChild(Context, APath[I]);
    if not Assigned(Existing) then
    begin
      Existing := TTOMLNode.CreateTable(False, True,
        False, False);
      AttachChild(Context, APath[I], Existing);
    end
    else if Existing.Kind = tnkScalar then
      RaiseParseError(Format(
        'Cannot redefine "%s" as a table after assigning it a value.',
        [JoinPathPrefix(APath, I + 1)]))
    else if Existing.Kind = tnkArrayOfTables then
    begin
      Existing := Existing.LastItem;
      if not Assigned(Existing) then
        RaiseParseError(Format('Array of tables "%s" has no current item.',
          [JoinPathPrefix(APath, I + 1)]));
    end;

    if Existing.Sealed then
      RaiseParseError(Format(
        'Inline table "%s" is fully defined and cannot be extended.',
        [JoinPathPrefix(APath, I + 1)]));

    Context := Existing;
  end;

  Existing := GetChild(Context, APath[Length(APath) - 1]);
  if not Assigned(Existing) then
  begin
    ArrayNode := TTOMLNode.CreateArrayOfTables(False);
    AttachChild(Context, APath[Length(APath) - 1], ArrayNode);
  end
  else
  begin
    if Existing.Kind <> tnkArrayOfTables then
      RaiseParseError(Format(
        'Cannot redefine "%s" as an array of tables.',
        [JoinPath(APath)]));
    if Existing.Sealed then
      RaiseParseError(Format(
        'Inline table "%s" is fully defined and cannot be extended.',
        [JoinPath(APath)]));
    ArrayNode := Existing;
  end;

  NewItem := TTOMLNode.CreateTable(True, False,
    False, False);
  ArrayNode.Items.Add(NewItem);
  Result := NewItem;
end;

procedure TTOMLParser.ParseTableHeader;
var
  Path: TArray<string>;
  IsArrayHeader: Boolean;
begin
  IsArrayHeader := MatchText('[[');
  if IsArrayHeader then
    Advance(2)
  else
    Advance;

  Path := ParseKeyPath;
  SkipWhitespace(False);

  if IsArrayHeader then
  begin
    if not MatchText(']]') then
      RaiseParseError('Unterminated array-of-tables header.');
    Advance(2);
    FCurrentTable := ParseTableArray(Path);
  end
  else
  begin
    if CurrentChar <> ']' then
      RaiseParseError('Unterminated table header.');
    Advance;
    FCurrentTable := ParseRegularTable(Path);
  end;

  while IsSpaceOrTab(CurrentChar) do
    Advance;
  if ConsumeComment then
  begin
  end;
  if not IsAtEnd and not ConsumeNewline then
    RaiseParseError('Table headers must be followed by a newline or EOF.');
end;

procedure TTOMLParser.ParseKeyValuePair;
var
  KeyPath: TArray<string>;
  ValueNode: TTOMLNode;
begin
  KeyPath := ParseKeyPath;
  SkipWhitespace(False);
  if CurrentChar <> '=' then
    RaiseParseError('Expected "=" after TOML key.');
  Advance;
  SkipWhitespace(False);

  ValueNode := ParseValue('');
  AssignValue(FCurrentTable, KeyPath, ValueNode, ValueNode, False);

  while IsSpaceOrTab(CurrentChar) do
    Advance;
  if ConsumeComment then
  begin
  end;
  if not IsAtEnd and not ConsumeNewline then
    RaiseParseError('Key/value pairs must be followed by a newline or EOF.');
end;

function TTOMLParser.ParseArray: TTOMLNode;
var
  ElementNode: TTOMLNode;
begin
  Result := TTOMLNode.CreateArray;
  Advance;
  SkipWhitespace(True);
  if CurrentChar = ']' then
  begin
    Advance;
    Exit;
  end;

  while True do
  begin
    ElementNode := ParseValue(',]');
    Result.Items.Add(ElementNode);
    SkipWhitespace(True);
    if CurrentChar = ',' then
    begin
      Advance;
      SkipWhitespace(True);
      if CurrentChar = ']' then
      begin
        Advance;
        Exit;
      end;
      Continue;
    end;
    if CurrentChar = ']' then
    begin
      Advance;
      Exit;
    end;
    RaiseParseError('Expected "," or "]" after TOML array element.');
  end;
end;

function TTOMLParser.ParseInlineTable: TTOMLNode;
var
  InlineNode, ValueNode: TTOMLNode;
  KeyPath: TArray<string>;
begin
  InlineNode := TTOMLNode.CreateTable(False, False,
    True, False);
  Advance;
  SkipWhitespace(True);
  if CurrentChar = '}' then
  begin
    Advance;
    Exit(InlineNode);
  end;

  while True do
  begin
    KeyPath := ParseKeyPath;
    SkipWhitespace(True);
    if CurrentChar <> '=' then
      RaiseParseError('Expected "=" inside inline table.');
    Advance;
    SkipWhitespace(True);
    ValueNode := ParseValue(',}');
    AssignValue(InlineNode, KeyPath, ValueNode, ValueNode, True);

    SkipWhitespace(True);
    if CurrentChar = ',' then
    begin
      Advance;
      SkipWhitespace(True);
      if CurrentChar = '}' then
      begin
        Advance;
        Exit(InlineNode);
      end;
      Continue;
    end;
    if CurrentChar = '}' then
    begin
      Advance;
      Exit(InlineNode);
    end;
    RaiseParseError('Expected "," or "}" after inline table entry.');
  end;
end;

function TTOMLParser.ParseValue(const ADelimiters: string): TTOMLNode;
var
  StringValue: string;
begin
  if MatchText('"""') then
  begin
    StringValue := ParseBasicString(True, False);
    Exit(TTOMLNode.CreateScalar(
      StringValue, tskString, StringValue));
  end;
  if MatchText('''''''') then
  begin
    StringValue := ParseLiteralString(True, False);
    Exit(TTOMLNode.CreateScalar(
      StringValue, tskString, StringValue));
  end;

  case CurrentChar of
    '"':
      begin
        StringValue := ParseBasicString(False, False);
        Result := TTOMLNode.CreateScalar(
          StringValue, tskString, StringValue);
      end;
    '''':
      begin
        StringValue := ParseLiteralString(False, False);
        Result := TTOMLNode.CreateScalar(
          StringValue, tskString, StringValue);
      end;
    '[':
      Result := ParseArray;
    '{':
      Result := ParseInlineTable;
  else
    Result := ParseBareValue(ADelimiters);
  end;
end;

function TTOMLParser.ParseBareValue(const ADelimiters: string): TTOMLNode;
var
  StartIndex: Integer;
  Token: string;
begin
  StartIndex := FIndex;
  while not IsAtEnd do
  begin
    if IsNewlineChar(CurrentChar) or (CurrentChar = '#') then
      Break;
    if (ADelimiters <> '') and (Pos(CurrentChar, ADelimiters) > 0) then
      Break;
    Advance;
  end;

  Token := Trim(Copy(FText, StartIndex, FIndex - StartIndex));
  if Token = '' then
    RaiseParseError('Expected a TOML value.');

  Result := ParseTokenValue(Token);
end;

function TTOMLParser.TryParseBoolean(const AToken: string;
  out ANode: TTOMLNode): Boolean;
begin
  if AToken = 'true' then
  begin
    ANode := TTOMLNode.CreateScalar('true',
      tskBool, 'true');
    Exit(True);
  end;
  if AToken = 'false' then
  begin
    ANode := TTOMLNode.CreateScalar('false',
      tskBool, 'false');
    Exit(True);
  end;
  ANode := nil;
  Result := False;
end;

function TTOMLParser.ValidateDigitsWithSeparators(const AText,
  AAllowedDigits: string; const AAllowEmpty: Boolean): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := AAllowEmpty and (AText = '');
  if AText = '' then
    Exit;

  if AText[1] = '_' then
    Exit(False);
  if AText[Length(AText)] = '_' then
    Exit(False);

  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if C = '_' then
    begin
      if (I = 1) or (I = Length(AText)) then
        Exit(False);
      if (Pos(AText[I - 1], AAllowedDigits) = 0) or
         (Pos(AText[I + 1], AAllowedDigits) = 0) then
        Exit(False);
    end
    else if Pos(C, AAllowedDigits) = 0 then
      Exit(False);
  end;

  Result := True;
end;

function TTOMLParser.TryParseDecimalInteger(const AToken: string;
  out AValue: Double): Boolean;
var
  Digits, SignPart: string;
  IntValue: Int64;
begin
  Result := False;
  SignPart := '';
  Digits := AToken;
  if (Digits <> '') and ((Digits[1] = '+') or (Digits[1] = '-')) then
  begin
    SignPart := Digits[1];
    Delete(Digits, 1, 1);
  end;

  if Digits = '' then
    Exit(False);
  if not ValidateDigitsWithSeparators(Digits, '0123456789', False) then
    Exit(False);
  Digits := StripUnderscores(Digits);

  if (Length(Digits) > 1) and (Digits[1] = '0') then
    Exit(False);

  if not TryStrToInt64(SignPart + Digits, IntValue) then
    Exit(False);
  AValue := IntValue;
  Result := True;
end;

function TTOMLParser.TryParseHexInteger(const AToken: string;
  out AValue: Double): Boolean;
var
  Digits: string;
  Value64: QWord;
begin
  Result := False;
  if Copy(AToken, 1, 2) <> '0x' then
    Exit(False);
  Digits := Copy(AToken, 3, MaxInt);
  if not ValidateDigitsWithSeparators(Digits, '0123456789abcdefABCDEF', False) then
    Exit(False);
  Digits := StripUnderscores(Digits);
  if not TryStrToQWord('$' + Digits, Value64) then
    Exit(False);
  if Value64 > QWord(High(Int64)) then
    Exit(False);
  AValue := Value64;
  Result := True;
end;

function TTOMLParser.TryParseOctalInteger(const AToken: string;
  out AValue: Double): Boolean;
var
  C: Char;
  Digits: string;
  Value64: QWord;
begin
  Result := False;
  if Copy(AToken, 1, 2) <> '0o' then
    Exit(False);
  Digits := StripUnderscores(Copy(AToken, 3, MaxInt));
  if not ValidateDigitsWithSeparators(Copy(AToken, 3, MaxInt), '01234567', False) then
    Exit(False);
  Value64 := 0;
  for C in Digits do
    Value64 := (Value64 * 8) + Ord(C) - Ord('0');
  if Value64 > QWord(High(Int64)) then
    Exit(False);
  AValue := Value64;
  Result := True;
end;

function TTOMLParser.TryParseBinaryInteger(const AToken: string;
  out AValue: Double): Boolean;
var
  C: Char;
  Digits: string;
  Value64: QWord;
begin
  Result := False;
  if Copy(AToken, 1, 2) <> '0b' then
    Exit(False);
  if not ValidateDigitsWithSeparators(Copy(AToken, 3, MaxInt), '01', False) then
    Exit(False);
  Digits := StripUnderscores(Copy(AToken, 3, MaxInt));
  Value64 := 0;
  for C in Digits do
    Value64 := (Value64 * 2) + Ord(C) - Ord('0');
  if Value64 > QWord(High(Int64)) then
    Exit(False);
  AValue := Value64;
  Result := True;
end;

function TTOMLParser.TryParseFloatValue(const AToken: string;
  out AValue: Double): Boolean;
var
  ExponentPart, IntegerPart, LowerMantissa, Mantissa, NumberText, SignPart,
    FractionPart: string;
  ExponentIndex, DotIndex: Integer;
begin
  Result := False;
  if (AToken = 'inf') or (AToken = '+inf') then
  begin
    AValue := Infinity;
    Exit(True);
  end;
  if AToken = '-inf' then
  begin
    AValue := NegInfinity;
    Exit(True);
  end;
  if (AToken = 'nan') or (AToken = '+nan') or (AToken = '-nan') then
  begin
    AValue := NaN;
    Exit(True);
  end;

  SignPart := '';
  Mantissa := AToken;
  if (Mantissa <> '') and ((Mantissa[1] = '+') or (Mantissa[1] = '-')) then
  begin
    SignPart := Mantissa[1];
    Delete(Mantissa, 1, 1);
  end;
  if Mantissa = '' then
    Exit(False);

  LowerMantissa := LowerCase(Mantissa);
  ExponentPart := '';
  ExponentIndex := Pos('e', LowerMantissa);
  if ExponentIndex > 0 then
  begin
    ExponentPart := Copy(Mantissa, ExponentIndex, MaxInt);
    Mantissa := Copy(Mantissa, 1, ExponentIndex - 1);
  end;

  DotIndex := Pos('.', Mantissa);
  if (DotIndex = 0) and (ExponentPart = '') then
    Exit(False);

  if DotIndex > 0 then
  begin
    IntegerPart := Copy(Mantissa, 1, DotIndex - 1);
    FractionPart := Copy(Mantissa, DotIndex + 1, MaxInt);
    if (IntegerPart = '') or (FractionPart = '') then
      Exit(False);
    if not ValidateDigitsWithSeparators(IntegerPart, '0123456789', False) then
      Exit(False);
    if not ValidateDigitsWithSeparators(FractionPart, '0123456789', False) then
      Exit(False);
    IntegerPart := StripUnderscores(IntegerPart);
    FractionPart := StripUnderscores(FractionPart);
    if (Length(IntegerPart) > 1) and (IntegerPart[1] = '0') then
      Exit(False);
    NumberText := IntegerPart + '.' + FractionPart;
  end
  else
  begin
    if not ValidateDigitsWithSeparators(Mantissa, '0123456789', False) then
      Exit(False);
    Mantissa := StripUnderscores(Mantissa);
    if (Length(Mantissa) > 1) and (Mantissa[1] = '0') then
      Exit(False);
    NumberText := Mantissa;
  end;

  if ExponentPart <> '' then
  begin
    Delete(ExponentPart, 1, 1);
    if ExponentPart = '' then
      Exit(False);
    if (ExponentPart[1] = '+') or (ExponentPart[1] = '-') then
    begin
      NumberText := NumberText + 'e' + ExponentPart[1];
      Delete(ExponentPart, 1, 1);
    end
    else
      NumberText := NumberText + 'e';
    if not ValidateDigitsWithSeparators(ExponentPart, '0123456789', False) then
      Exit(False);
    NumberText := SignPart + NumberText + StripUnderscores(ExponentPart);
  end
  else
    NumberText := SignPart + NumberText;

  Result := TryStrToFloat(NumberText, AValue, TOMLFormatSettings);
end;

function TTOMLParser.TryParseNumber(const AToken: string;
  out ANode: TTOMLNode): Boolean;
var
  CanonicalText: string;
  Number: Double;
begin
  Result := TryParseFloatValue(AToken, Number) or
    TryParseHexInteger(AToken, Number) or
    TryParseOctalInteger(AToken, Number) or
    TryParseBinaryInteger(AToken, Number) or
    TryParseDecimalInteger(AToken, Number);
  if Result then
  begin
    if IsFloatToken(AToken) then
    begin
      CanonicalText := CanonicalizeFloatToken(AToken);
      { Scalar text == canonical text — numbers are kept in canonical
        form by the value reader; typed conversion is the consumer's job. }
      ANode := TTOMLNode.CreateScalar(CanonicalText,
        tskFloat, CanonicalText);
    end
    else
    begin
      CanonicalText := CanonicalizeIntegerToken(AToken);
      ANode := TTOMLNode.CreateScalar(CanonicalText,
        tskInteger, CanonicalText);
    end;
  end
  else
    ANode := nil;
end;

function TTOMLParser.TryParseDate(const AText: string;
  out ADate: TTemporalDateRecord): Boolean;
var
  Year, Month, Day: Integer;
begin
  Result := (Length(AText) = 10) and IsDigit(AText[1]) and IsDigit(AText[2]) and
    IsDigit(AText[3]) and IsDigit(AText[4]) and (AText[5] = '-') and
    IsDigit(AText[6]) and IsDigit(AText[7]) and (AText[8] = '-') and
    IsDigit(AText[9]) and IsDigit(AText[10]);
  if not Result then
    Exit;

  Year := StrToInt(Copy(AText, 1, 4));
  Month := StrToInt(Copy(AText, 6, 2));
  Day := StrToInt(Copy(AText, 9, 2));
  Result := IsValidDate(Year, Month, Day);
  if Result then
  begin
    ADate.Year := Year;
    ADate.Month := Month;
    ADate.Day := Day;
  end;
end;

function TTOMLParser.TryParseLocalTime(const AText: string;
  out ATime: TTemporalTimeRecord; out AParsedLength: Integer;
  out ACanonicalText: string): Boolean;
var
  FractionDigits, FractionValue, Hour, Minute, Second: Integer;
  FractionText: string;
  Position: Integer;
begin
  Result := False;
  ACanonicalText := '';
  FillChar(ATime, SizeOf(ATime), 0);
  AParsedLength := 0;
  if Length(AText) < 5 then
    Exit;
  if not (IsDigit(AText[1]) and IsDigit(AText[2]) and (AText[3] = ':') and
          IsDigit(AText[4]) and IsDigit(AText[5])) then
    Exit;

  Hour := StrToInt(Copy(AText, 1, 2));
  Minute := StrToInt(Copy(AText, 4, 2));
  Position := 6;
  Second := 0;

  if (Position <= Length(AText)) and (AText[Position] = ':') then
  begin
    Inc(Position);
    if (Position + 1 > Length(AText)) or not (IsDigit(AText[Position]) and
       IsDigit(AText[Position + 1])) then
      Exit;
    Second := StrToInt(Copy(AText, Position, 2));
    Inc(Position, 2);

    if (Position <= Length(AText)) and (AText[Position] = '.') then
    begin
      Inc(Position);
      FractionDigits := 0;
      FractionValue := 0;
      while (Position <= Length(AText)) and IsDigit(AText[Position]) do
      begin
        if FractionDigits < 9 then
          FractionValue := FractionValue * 10 + (Ord(AText[Position]) - Ord('0'));
        Inc(FractionDigits);
        Inc(Position);
      end;
      if FractionDigits = 0 then
        Exit;
      while FractionDigits < 9 do
      begin
        FractionValue := FractionValue * 10;
        Inc(FractionDigits);
      end;
      ATime.Millisecond := FractionValue div 1000000;
      ATime.Microsecond := (FractionValue div 1000) mod 1000;
      ATime.Nanosecond := FractionValue mod 1000;
    end;
  end;

  if not IsValidTime(Hour, Minute, Second, ATime.Millisecond,
    ATime.Microsecond, ATime.Nanosecond) then
    Exit;

  ATime.Hour := Hour;
  ATime.Minute := Minute;
  ATime.Second := Second;
  AParsedLength := Position - 1;
  ACanonicalText := PadInteger(Hour, 2) + ':' + PadInteger(Minute, 2) + ':' +
    PadInteger(Second, 2);
  if (ATime.Millisecond <> 0) or (ATime.Microsecond <> 0) or
     (ATime.Nanosecond <> 0) then
  begin
    FractionText := PadInteger(ATime.Millisecond, 3) +
      PadInteger(ATime.Microsecond, 3) + PadInteger(ATime.Nanosecond, 3);
    while (Length(FractionText) > 3) and
      (FractionText[Length(FractionText)] = '0') do
      Delete(FractionText, Length(FractionText), 1);
    ACanonicalText := ACanonicalText + '.' + FractionText;
  end;
  Result := True;
end;

function TTOMLParser.TryParseOffset(const AText: string;
  const AStartIndex: Integer; out AParsedLength: Integer): Boolean;
var
  Hours, Minutes: Integer;
begin
  Result := False;
  AParsedLength := 0;
  if AStartIndex > Length(AText) then
    Exit;

  if (AText[AStartIndex] = 'Z') or (AText[AStartIndex] = 'z') then
  begin
    AParsedLength := 1;
    Exit(True);
  end;

  if not ((AText[AStartIndex] = '+') or (AText[AStartIndex] = '-')) then
    Exit(False);
  if AStartIndex + 5 > Length(AText) then
    Exit(False);
  if not (IsDigit(AText[AStartIndex + 1]) and IsDigit(AText[AStartIndex + 2]) and
          (AText[AStartIndex + 3] = ':') and IsDigit(AText[AStartIndex + 4]) and
          IsDigit(AText[AStartIndex + 5])) then
    Exit(False);

  Hours := StrToInt(Copy(AText, AStartIndex + 1, 2));
  Minutes := StrToInt(Copy(AText, AStartIndex + 4, 2));
  Result := (Hours >= 0) and (Hours <= 23) and (Minutes >= 0) and (Minutes <= 59);
  if Result then
    AParsedLength := 6;
end;

function TTOMLParser.TryParseDateTime(const AText: string;
  out AScalarKind: TTOMLScalarKind; out ACanonicalText: string): Boolean;
var
  DateRec: TTemporalDateRecord;
  DelimiterChar: Char;
  DelimiterIndex, OffsetLength, TimeLength: Integer;
  OffsetText, TimeCanonical: string;
  TimeRec: TTemporalTimeRecord;
begin
  Result := False;
  ACanonicalText := '';
  AScalarKind := tskDateTime;
  DelimiterIndex := Pos('T', AText);
  if DelimiterIndex = 0 then
    DelimiterIndex := Pos('t', AText);
  if DelimiterIndex = 0 then
    DelimiterIndex := Pos(' ', AText);
  if DelimiterIndex = 0 then
    Exit(False);

  if not TryParseDate(Copy(AText, 1, DelimiterIndex - 1), DateRec) then
    Exit(False);
  if not TryParseLocalTime(Copy(AText, DelimiterIndex + 1, MaxInt), TimeRec,
    TimeLength, TimeCanonical) then
    Exit(False);

  if DelimiterIndex + TimeLength >= Length(AText) then
  begin
    AScalarKind := tskDateTimeLocal;
    ACanonicalText := Copy(AText, 1, DelimiterIndex - 1) + 'T' + TimeCanonical;
    Exit(True);
  end;

  Result := TryParseOffset(AText, DelimiterIndex + TimeLength + 1, OffsetLength) and
    (DelimiterIndex + TimeLength + OffsetLength = Length(AText));
  if not Result then
    Exit;

  DelimiterChar := AText[DelimiterIndex + TimeLength + 1];
  if (DelimiterChar = 'z') then
    OffsetText := 'Z'
  else
    OffsetText := Copy(AText, DelimiterIndex + TimeLength + 1, OffsetLength);
  AScalarKind := tskDateTime;
  ACanonicalText := Copy(AText, 1, DelimiterIndex - 1) + 'T' + TimeCanonical +
    OffsetText;
end;

function TTOMLParser.TryParseTimeOnly(const AText: string;
  out ACanonicalText: string): Boolean;
var
  ParsedLength: Integer;
  TimeCanonical: string;
  TimeRec: TTemporalTimeRecord;
begin
  Result := TryParseLocalTime(AText, TimeRec, ParsedLength, TimeCanonical) and
    (ParsedLength = Length(AText));
  if Result then
    ACanonicalText := TimeCanonical
  else
    ACanonicalText := '';
end;

function TTOMLParser.ParseTokenValue(const AToken: string): TTOMLNode;
var
  CanonicalText: string;
  DateRec: TTemporalDateRecord;
  ScalarKind: TTOMLScalarKind;
begin
  if TryParseBoolean(AToken, Result) then
    Exit;
  if TryParseNumber(AToken, Result) then
    Exit;
  if TryParseDateTime(AToken, ScalarKind, CanonicalText) then
  begin
    Result := TTOMLNode.CreateScalar(
      AToken, ScalarKind, CanonicalText);
    Exit;
  end;
  if TryParseTimeOnly(AToken, CanonicalText) then
  begin
    Result := TTOMLNode.CreateScalar(
      AToken, tskTimeLocal, CanonicalText);
    Exit;
  end;
  if TryParseDate(AToken, DateRec) then
  begin
    Result := TTOMLNode.CreateScalar(
      AToken, tskDateLocal, AToken);
    Exit;
  end;

  RaiseParseError('Invalid TOML value: ' + AToken);
end;

end.
