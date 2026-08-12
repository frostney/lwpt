#!/usr/bin/env instantfpc
program UpdateTestInventory;

{$mode delphi}{$H+}

uses
  SysUtils,
  LWPT.TestInventory;

const
  DOCUMENTATION_PATH = 'docs/testing.md';

var
  CheckOnly: Boolean;
  Inventory: TLWPTTestInventory;
begin
  try
    CheckOnly := (ParamCount = 1) and (ParamStr(1) = '--check');
    if (ParamCount > 1) or ((ParamCount = 1) and not CheckOnly) then
      raise Exception.Create('usage: update-test-inventory.pas [--check]');
    Inventory := TLWPTTestInventory.Create(TEST_INVENTORY_PATH);
    try
      if CheckOnly then Inventory.ValidateDocumentation(DOCUMENTATION_PATH)
      else Inventory.WriteDocumentation(DOCUMENTATION_PATH);
    finally
      Inventory.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, 'test inventory: ', E.Message);
      Halt(1);
    end;
  end;
end.
