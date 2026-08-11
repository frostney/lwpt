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

implementation

uses
  SysUtils;

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

end.
