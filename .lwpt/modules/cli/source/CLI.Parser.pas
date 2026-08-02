unit CLI.Parser;

{$I Shared.inc}

interface

uses
  Classes,

  CLI.Options;

{ Parses command-line arguments against the given option definitions.
  Returns a TStringList of positional (non-option) arguments; the caller
  owns the returned list. Raises TParseError for unknown long flags and
  unmatched single-character short options. An unmatched multi-character
  single-dash token remains positional.

  A valued short option consumes the following argv (`-o output`) when
  its ShortName matches exactly, including a value that begins with `-`.
  AllowAttachedShortValue additionally enables an attached suffix
  (`-dDEBUG`, `-Fusource`); the longest registered short-name prefix wins.

  AStartArg defaults to 1 (the first real argv after the program name).
  Callers that need to skip a leading word — e.g. `lwpt run <subcmd>`
  delegates to the named subcommand by re-parsing argv from position 2
  onward, treating <subcmd>'s args as if they were the top-level args
  for that subcommand — pass AStartArg=2 (or higher). }
function ParseCommandLine(const AOptions: TOptionArray;
  AStartArg: Integer = 1): TStringList;

implementation

uses
  SysUtils;

const
  LONG_FLAG_PREFIX = '--';
  SHORT_FLAG_CHAR = '-';
  FLAG_VALUE_SEPARATOR = '=';

procedure SplitFlag(const AArg: string; out AName, AValue: string);
var
  EqualPos: Integer;
  Body: string;
begin
  Body := Copy(AArg, Length(LONG_FLAG_PREFIX) + 1, MaxInt);
  EqualPos := Pos(FLAG_VALUE_SEPARATOR, Body);
  if EqualPos > 0 then
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

function ParseCommandLine(const AOptions: TOptionArray;
  AStartArg: Integer = 1): TStringList;
var
  I, Count: Integer;
  Arg, Name, Value: string;
  Option: TOptionBase;
  HasEquals: Boolean;
begin
  Result := TStringList.Create;
  try
    I := AStartArg;
    Count := ParamCount;
    while I <= Count do
    begin
      Arg := ParamStr(I);

      if Copy(Arg, 1, Length(LONG_FLAG_PREFIX)) = LONG_FLAG_PREFIX then
      begin
        HasEquals := Pos(FLAG_VALUE_SEPARATOR,
          Copy(Arg, Length(LONG_FLAG_PREFIX) + 1, MaxInt)) > 0;
        SplitFlag(Arg, Name, Value);
        Option := FindOption(AOptions, Name);
        if Option = nil then
          raise TParseError.CreateFmt('Unknown option: --%s', [Name]);

        { Plain string/integer options accept the space-separated form
          (--mode release) as well as --mode=release; flag options
          still take no value. }
        if (Value = '') and (not HasEquals) and
           not (Option is TFlagOption) then
        begin
          if (I >= Count) or
             (Copy(ParamStr(I + 1), 1, 1) = SHORT_FLAG_CHAR) then
            raise TParseError.CreateFmt(
              '--%s requires a value', [Name]);
          Inc(I);
          Value := ParamStr(I);
        end;

        Option.Apply(Value);
      end
      else if (Length(Arg) > 1) and
              (Arg[1] = SHORT_FLAG_CHAR) and
              (Arg[2] <> SHORT_FLAG_CHAR) then
      begin
        Name := Copy(Arg, 2, MaxInt);
        Option := FindOptionShortExact(AOptions, Name);
        if Option <> nil then
        begin
          Value := '';
          if not (Option is TFlagOption) then
          begin
            if I >= Count then
              raise TParseError.CreateFmt(
                '-%s requires a value', [Name]);
            Inc(I);
            Value := ParamStr(I);
          end;
        end
        else
          Option := FindOptionShortAttached(AOptions, Name, Value);

        if Option = nil then
        begin
          { Preserve the pre-valued-short behavior for multi-character
            single-dash tokens when no option opted into attachment:
            they remain positional. A one-character short name is the
            only shape that was previously recognized and rejected as
            unknown. }
          if Length(Name) = 1 then
            raise TParseError.CreateFmt('Unknown option: %s', [Arg]);
          Result.Add(Arg);
        end
        else
          Option.Apply(Value);
      end
      else
        Result.Add(Arg);

      Inc(I);
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
