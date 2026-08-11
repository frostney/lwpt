unit TestingPascalLibrary.Protocol;

{$I Shared.inc}

interface

const
  TEST_INVENTORY_ENVIRONMENT = 'TESTING_PASCAL_LIBRARY_INVENTORY';
  TEST_INVENTORY_EXECUTABLE_ENVIRONMENT =
    'TESTING_PASCAL_LIBRARY_INVENTORY_EXECUTABLE';
  TEST_INVENTORY_MODE_ONLY = 'only';
  TEST_INVENTORY_MODE_REPORT = 'report';
  TEST_INVENTORY_PREFIX = 'tpl-inventory-v1'#9;

function CurrentTestInventoryMode: string;
function ConsumeCurrentTestInventoryMode: string;

implementation

uses
  SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ENDIF}
  ;

{$IFDEF UNIX}
function CUnsetEnvironmentVariable(AName: PAnsiChar): LongInt; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'unsetenv';
  {$ELSE}
  external name 'unsetenv';
  {$ENDIF}
{$ENDIF}

procedure ClearInventoryEnvironmentVariable(const AName: string);
{$IFDEF UNIX}
var
  Name: AnsiString;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Name: UnicodeString;
{$ENDIF}
begin
  {$IFDEF UNIX}
  Name := AnsiString(AName);
  if CUnsetEnvironmentVariable(PAnsiChar(Name)) <> 0 then
    raise Exception.CreateFmt('failed to consume test inventory variable %s',
      [AName]);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Name := UnicodeString(AName);
  if not Windows.SetEnvironmentVariableW(PWideChar(Name), nil) then
    raise Exception.CreateFmt('failed to consume test inventory variable %s',
      [AName]);
  {$ENDIF}
end;

function CurrentTestInventoryMode: string;
var
  ExpectedExecutable: string;
begin
  Result := GetEnvironmentVariable(TEST_INVENTORY_ENVIRONMENT);
  ExpectedExecutable := GetEnvironmentVariable(
    TEST_INVENTORY_EXECUTABLE_ENVIRONMENT);
  if (Result = '') or (ExpectedExecutable = '')
     or not SameFileName(ExpandFileName(ParamStr(0)),
       ExpandFileName(ExpectedExecutable)) then
    Result := '';
end;

function ConsumeCurrentTestInventoryMode: string;
begin
  Result := CurrentTestInventoryMode;
  if Result = '' then Exit;
  { The request authorizes exactly this process. Clearing it before any test
    body runs prevents same-executable subprocesses from inheriting a second
    valid report request. }
  ClearInventoryEnvironmentVariable(TEST_INVENTORY_ENVIRONMENT);
  ClearInventoryEnvironmentVariable(TEST_INVENTORY_EXECUTABLE_ENVIRONMENT);
end;

end.
