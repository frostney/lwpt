#!/usr/bin/env instantfpc
program LinkCheckCLI;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  LinkCheck;

procedure Usage;
begin
  WriteLn('Usage: link-check.pas [--root PATH] [--online] [--jobs N]');
  WriteLn('       [--timeout-ms N] [--allowlist PATH] [--format human|json]');
end;

function NeedValue(var AIndex: Integer; const AOption: string): string;
begin
  if AIndex >= ParamCount then
  begin
    WriteLn(ErrOutput, 'linkcheck: ', AOption, ' requires a value');
    Halt(2);
  end;
  Inc(AIndex);
  Result := ParamStr(AIndex);
end;

var
  Options: TLinkCheckOptions;
  Checker: TLinkChecker;
  Report: TLinkCheckReport;
  FormatName, Arg: string;
  I: Integer;
begin
  Options := DefaultLinkCheckOptions('.');
  FormatName := 'human';
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if Arg = '--root' then Options.Root := NeedValue(I, Arg)
    else if Arg = '--online' then Options.Online := True
    else if Arg = '--jobs' then Options.Jobs := StrToIntDef(NeedValue(I, Arg), 0)
    else if Arg = '--timeout-ms' then
      Options.TimeoutMs := StrToIntDef(NeedValue(I, Arg), 0)
    else if Arg = '--allowlist' then Options.AllowlistPath := NeedValue(I, Arg)
    else if Arg = '--format' then FormatName := LowerCase(NeedValue(I, Arg))
    else if (Arg = '--help') or (Arg = '-h') then
    begin
      Usage;
      Halt(0);
    end
    else
    begin
      WriteLn(ErrOutput, 'linkcheck: unknown option: ', Arg);
      Usage;
      Halt(2);
    end;
    Inc(I);
  end;
  if not ((FormatName = 'human') or (FormatName = 'json')) then
  begin
    WriteLn(ErrOutput, 'linkcheck: --format must be human or json');
    Halt(2);
  end;

  Checker := TLinkChecker.Create(Options);
  try
    Report := Checker.Check;
    try
      if FormatName = 'json' then WriteLn(Report.ToJSON)
      else Write(Report.ToHuman);
      if Report.HasErrors then ExitCode := 1 else ExitCode := 0;
    finally
      Report.Free;
    end;
  finally
    Checker.Free;
  end;
end.

