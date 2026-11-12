unit CLI.Parser;

{$I Shared.inc}

interface

uses
  Classes,

  CLI.Options;

const
  { The conventional end-of-options marker. Every argument after it is a
    positional, whatever it looks like; the marker itself is dropped. }
  END_OF_OPTIONS_MARKER = '--';

type
  TCommandLineArguments = array of string;

{ Parses AArguments against the given option definitions. Returns a
  TStringList of positional (non-option) arguments; the caller owns the
  returned list. Raises TParseError for unknown long flags and unmatched
  single-character short options. An unmatched multi-character
  single-dash token remains positional.

  A valued short option consumes the following argument (`-o output`)
  when its ShortName matches exactly, including a value that begins with
  `-`. AllowAttachedShortValue additionally enables an attached suffix
  (`-dDEBUG`, `-Fusource`); the longest registered short-name prefix wins.

  END_OF_OPTIONS_MARKER ends option parsing: the arguments after it are
  returned as positionals, verbatim.

  AStopAtFirstPositional ends option parsing at the first positional as
  well: that argument and every argument after it are returned verbatim,
  including a later END_OF_OPTIONS_MARKER. A program that launches another
  program uses it to hand the rest of the line through untouched. }
function ParseArguments(const AArguments: array of string;
  const AOptions: TOptionArray;
  const AStopAtFirstPositional: Boolean = False): TStringList;

{ Reports whether `--<ALongName>` or `-<AShortName>` is spelled out as an
  option before option parsing ends at the first positional or at
  END_OF_OPTIONS_MARKER. Reads AArguments under ParseArguments' rules, so a
  value consumed by a valued option is never taken for the flag. An empty
  ALongName or AShortName matches nothing. Applies no option and raises
  nothing: an argument ParseArguments would reject is still compared. }
function LeadingFlagGiven(const AArguments: array of string;
  const AOptions: TOptionArray; const ALongName, AShortName: string): Boolean;

{ Reports whether `--<ALongName>`, `-<AShortName>` or, when ABareWord is
  not empty, ABareWord in any letter case is given as an argument of its
  own before END_OF_OPTIONS_MARKER. Reads AArguments under ParseArguments'
  rules without AStopAtFirstPositional, so a value consumed by a valued
  option (`-o help`, `--output help`) is never taken for one of them. An
  empty ALongName, AShortName or ABareWord matches nothing, so a lone `-`
  is never a flag without a short name. Applies no option and raises
  nothing: an argument ParseArguments would reject is still compared. }
function FlagGiven(const AArguments: array of string;
  const AOptions: TOptionArray; const ALongName, AShortName: string;
  const ABareWord: string = ''): Boolean;

{ The index of END_OF_OPTIONS_MARKER as ParseArguments reads it without
  AStopAtFirstPositional, or Length(AArguments) when the arguments have
  none. A `--` that a valued short option takes as its value is not the
  marker. Applies no option and raises nothing: an argument ParseArguments
  would reject is skipped. }
function EndOfOptionsIndex(const AArguments: array of string;
  const AOptions: TOptionArray): Integer;

{ The process's own arguments from position AStartArg onward. }
function GetCommandLineArguments(
  const AStartArg: Integer = 1): TCommandLineArguments;

{ ParseArguments over the process's own arguments.

  AStartArg defaults to 1 (the first real argv after the program name).
  Callers that need to skip leading words pass a higher position. }
function ParseCommandLine(const AOptions: TOptionArray;
  AStartArg: Integer = 1): TStringList;

implementation

uses
  SysUtils;

const
  LONG_FLAG_PREFIX = '--';
  SHORT_FLAG_CHAR = '-';
  FLAG_VALUE_SEPARATOR = '=';

type
  TArgumentKind = (akPositional, akEndOfOptions, akOption, akRejected);

  { How one argument reads at its position: the single description of the
    option syntax that ParseArguments, LeadingFlagGiven, FlagGiven and
    EndOfOptionsIndex share. }
  TArgumentReading = record
    Kind: TArgumentKind;
    Option: TOptionBase;  { akOption }
    Value: string;        { akOption }
    Width: Integer;       { arguments read: 2 with a separated value }
    Rejection: string;    { akRejected: the TParseError message }
  end;

procedure SplitFlag(const AArg: string; out AName, AValue: string;
  out AHasEquals: Boolean);
var
  EqualPos: Integer;
  Body: string;
begin
  Body := Copy(AArg, Length(LONG_FLAG_PREFIX) + 1, MaxInt);
  EqualPos := Pos(FLAG_VALUE_SEPARATOR, Body);
  AHasEquals := EqualPos > 0;
  if AHasEquals then
  begin
    AName := Copy(Body, 1, EqualPos - 1);
    AValue := Copy(Body, EqualPos + 1, MaxInt);
  end
  else
  begin
    AName := Body;
    AValue := '';
  end;
end;

function FindOption(const AOptions: TOptionArray;
  const AName: string): TOptionBase;
var
  I: Integer;
begin
  for I := 0 to High(AOptions) do
    if AOptions[I].LongName = AName then
      Exit(AOptions[I]);
  Result := nil;
end;

function FindOptionShortExact(const AOptions: TOptionArray;
  const AShortName: string): TOptionBase;
var
  I: Integer;
begin
  for I := 0 to High(AOptions) do
    if AOptions[I].ShortName = AShortName then
      Exit(AOptions[I]);
  Result := nil;
end;

function FindOptionShortAttached(const AOptions: TOptionArray;
  const ABody: string; out AValue: string): TOptionBase;
var
  I, BestLength: Integer;
  ShortName: string;
begin
  Result := nil;
  AValue := '';
  BestLength := 0;
  for I := 0 to High(AOptions) do
  begin
    ShortName := AOptions[I].ShortName;
    if (ShortName <> '') and
       not (AOptions[I] is TFlagOption) and
       AOptions[I].AllowAttachedShortValue and
       (Length(ShortName) > BestLength) and
       (Length(ABody) > Length(ShortName)) and
       (Copy(ABody, 1, Length(ShortName)) = ShortName) then
    begin
      Result := AOptions[I];
      BestLength := Length(ShortName);
      AValue := Copy(ABody, BestLength + 1, MaxInt);
    end;
  end;
end;

function ReadArgument(const AArguments: array of string;
  const AIndex: Integer; const AOptions: TOptionArray): TArgumentReading;
var
  Arg, Name: string;
  HasEquals, HasNext: Boolean;
begin
  Arg := AArguments[AIndex];
  HasNext := AIndex < High(AArguments);
  Result.Kind := akOption;
  Result.Option := nil;
  Result.Value := '';
  Result.Width := 1;
  Result.Rejection := '';

  if Arg = END_OF_OPTIONS_MARKER then
    Result.Kind := akEndOfOptions
  else if Copy(Arg, 1, Length(LONG_FLAG_PREFIX)) = LONG_FLAG_PREFIX then
  begin
    SplitFlag(Arg, Name, Result.Value, HasEquals);
    Result.Option := FindOption(AOptions, Name);
    if Result.Option = nil then
    begin
      Result.Kind := akRejected;
      Result.Rejection := Format('Unknown option: --%s', [Name]);
    end
    { Plain string/integer options accept the space-separated form
      (--mode release) as well as --mode=release; flag options
      still take no value. }
    else if (Result.Value = '') and (not HasEquals) and
            not (Result.Option is TFlagOption) then
    begin
      if (not HasNext) or
         (Copy(AArguments[AIndex + 1], 1, 1) = SHORT_FLAG_CHAR) then
      begin
        Result.Kind := akRejected;
        Result.Rejection := Format('--%s requires a value', [Name]);
      end
      else
      begin
        Result.Value := AArguments[AIndex + 1];
        Result.Width := 2;
      end;
    end;
  end
  else if (Length(Arg) > 1) and
          (Arg[1] = SHORT_FLAG_CHAR) and
          (Arg[2] <> SHORT_FLAG_CHAR) then
  begin
    Name := Copy(Arg, 2, MaxInt);
    Result.Option := FindOptionShortExact(AOptions, Name);
    if Result.Option <> nil then
    begin
      if not (Result.Option is TFlagOption) then
      begin
        if not HasNext then
        begin
          Result.Kind := akRejected;
          Result.Rejection := Format('-%s requires a value', [Name]);
        end
        else
        begin
          Result.Value := AArguments[AIndex + 1];
          Result.Width := 2;
        end;
      end;
    end
    else
    begin
      Result.Option := FindOptionShortAttached(AOptions, Name, Result.Value);
      if Result.Option = nil then
      begin
        { Preserve the pre-valued-short behavior for multi-character
          single-dash tokens when no option opted into attachment:
          they remain positional. A one-character short name is the
          only shape that was previously recognized and rejected as
          unknown. }
        if Length(Name) = 1 then
        begin
          Result.Kind := akRejected;
          Result.Rejection := Format('Unknown option: %s', [Arg]);
        end
        else
          Result.Kind := akPositional;
      end;
    end;
  end
  else
    Result.Kind := akPositional;
end;

function ParseArguments(const AArguments: array of string;
  const AOptions: TOptionArray;
  const AStopAtFirstPositional: Boolean = False): TStringList;
var
  I, VerbatimFrom: Integer;
  Reading: TArgumentReading;
begin
  Result := TStringList.Create;
  try
    I := 0;
    VerbatimFrom := Length(AArguments);
    while I < VerbatimFrom do
    begin
      Reading := ReadArgument(AArguments, I, AOptions);
      case Reading.Kind of
        akRejected:
          raise TParseError.Create(Reading.Rejection);
        akOption:
          Reading.Option.Apply(Reading.Value);
        akEndOfOptions:
          VerbatimFrom := I + 1;
        akPositional:
          begin
            if AStopAtFirstPositional then
              VerbatimFrom := I
            else
              Result.Add(AArguments[I]);
          end;
      end;
      Inc(I, Reading.Width);
    end;
    for I := VerbatimFrom to High(AArguments) do
      Result.Add(AArguments[I]);
  except
    Result.Free;
    raise;
  end;
end;

{ The scan LeadingFlagGiven and FlagGiven share. It compares only the
  argument each reading starts at, so a value a valued option consumes is
  never compared. }
function ScanForFlag(const AArguments: array of string;
  const AOptions: TOptionArray; const ALongName, AShortName,
  ABareWord: string; const AStopAtFirstPositional: Boolean): Boolean;
var
  I: Integer;
  Reading: TArgumentReading;
begin
  I := 0;
  while I <= High(AArguments) do
  begin
    Reading := ReadArgument(AArguments, I, AOptions);
    if (Reading.Kind = akEndOfOptions) or
       (AStopAtFirstPositional and (Reading.Kind = akPositional)) then
      Exit(False);
    if ((ALongName <> '') and
        (AArguments[I] = LONG_FLAG_PREFIX + ALongName)) or
       ((AShortName <> '') and
        (AArguments[I] = SHORT_FLAG_CHAR + AShortName)) or
       ((ABareWord <> '') and SameText(AArguments[I], ABareWord)) then
      Exit(True);
    Inc(I, Reading.Width);
  end;
  Result := False;
end;

function LeadingFlagGiven(const AArguments: array of string;
  const AOptions: TOptionArray; const ALongName, AShortName: string): Boolean;
begin
  Result := ScanForFlag(AArguments, AOptions, ALongName, AShortName, '',
    True);
end;

function FlagGiven(const AArguments: array of string;
  const AOptions: TOptionArray; const ALongName, AShortName: string;
  const ABareWord: string = ''): Boolean;
begin
  Result := ScanForFlag(AArguments, AOptions, ALongName, AShortName,
    ABareWord, False);
end;

function EndOfOptionsIndex(const AArguments: array of string;
  const AOptions: TOptionArray): Integer;
var
  Reading: TArgumentReading;
begin
  Result := 0;
  while Result <= High(AArguments) do
  begin
    Reading := ReadArgument(AArguments, Result, AOptions);
    if Reading.Kind = akEndOfOptions then
      Exit;
    Inc(Result, Reading.Width);
  end;
end;

function GetCommandLineArguments(
  const AStartArg: Integer = 1): TCommandLineArguments;
var
  I: Integer;
begin
  Result := nil;
  if AStartArg > ParamCount then
    Exit;
  SetLength(Result, ParamCount - AStartArg + 1);
  for I := AStartArg to ParamCount do
    Result[I - AStartArg] := ParamStr(I);
end;

function ParseCommandLine(const AOptions: TOptionArray;
  AStartArg: Integer = 1): TStringList;
begin
  Result := ParseArguments(GetCommandLineArguments(AStartArg), AOptions);
end;

end.
