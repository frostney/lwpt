{ CLIUnitClosure.Test — a host of the cli package links no Generics.* unit.

  Every unit a program uses is linked into it and initialized at every
  start. Generics.Collections brings a closure of its own (with FPC 3.2.2
  on Linux and macOS: Generics.MemoryExpanders, Generics.Defaults,
  Generics.Helpers, Generics.Strings, Generics.Hashes, Variants, VarUtils)
  that costs a host start-up time, peak memory and binary size even when
  the host never uses a generic collection (#419). This program compiles a
  probe host that uses every unit in packages/cli/source with the real
  compiler and `-vu`, and fails when the compiler registers any Generics.*
  unit for it.

  A canary probe that uses Generics.Collections directly proves the
  detection: if the compiler stops reporting units the way this program
  reads them, the canary fails instead of the guard passing vacuously. }

program CLIUnitClosure.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.ProcessSupport,
  Tests.Scratch;

const
  CLI_SOURCE = 'packages/cli/source';
  { How the compiler reports, under -vu, each unit a compilation uses. }
  REGISTERED_UNIT_MARKER = 'Registering new unit ';
  FORBIDDEN_UNIT_PREFIX = 'GENERICS.';

type
  TCLIUnitClosure = class(TTestSuite)
  private
    FScratch: string;
    function CompileProbe(const AName, AUsesList: string): TStringList;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestCanaryRegistersGenericsCollections;
    procedure TestCLIPackageRegistersNoGenericsUnit;
  end;

{ The package's units, from the file names in its source directory, test
  programs left out, so a new unit is covered without editing this list. }
function CLIPackageUnits: TStringList;
var
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(CLI_SOURCE + '/*.pas', faAnyFile, Search) = 0 then
  try
    repeat
      if not SameText(Copy(Search.Name, Length(Search.Name) - 8, 9),
        '.Test.pas') then
        Result.Add(ChangeFileExt(Search.Name, ''));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

{ The upper-case unit names the compiler registered, in its order. }
function RegisteredUnits(const ALog: string): TStringList;
var
  Lines: TStringList;
  Index, MarkerAt: Integer;
  Line: string;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := ALog;
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      MarkerAt := Pos(REGISTERED_UNIT_MARKER, Line);
      if MarkerAt > 0 then
        Result.Add(UpperCase(Trim(Copy(Line,
          MarkerAt + Length(REGISTERED_UNIT_MARKER), MaxInt))));
    end;
  finally
    Lines.Free;
  end;
end;

procedure TCLIUnitClosure.BeforeAll;
begin
  FScratch := CreateScratchRoot('cli-unit-closure');
end;

procedure TCLIUnitClosure.AfterAll;
begin
  RecursiveDelete(FScratch);
end;

{ Compiles a program that uses AUsesList, without linking, and returns the
  units the compiler registered for it. Fails the case when it does not
  compile. }
function TCLIUnitClosure.CompileProbe(const AName,
  AUsesList: string): TStringList;
var
  Directory, CLISource, Log: string;
  ExitStatus: Integer;
begin
  Directory := FScratch + '/' + AName;
  CLISource := ExpandFileName(CLI_SOURCE);
  ForceDirectories(Directory + '/units');
  WriteTextFile(Directory + '/probe.pas',
      'program Probe;'#10
    + '{$mode delphi}{$H+}'#10
    + 'uses ' + AUsesList + ';'#10
    + 'begin'#10
    + 'end.'#10);
  ExitStatus := RunChildCommand(Directory, TestCompilerExecutable,
    ['-B', '-Cn', '-vu', '-Fu' + CLISource, '-FU' + Directory + '/units',
     'probe.pas'], Log);
  if ExitStatus <> 0 then
    Fail(Format('probe %s did not compile (exit %d):'#10'%s',
      [AName, ExitStatus, CapturedOutputTail(Log)]));
  Result := RegisteredUnits(Log);
end;

procedure TCLIUnitClosure.TestCanaryRegistersGenericsCollections;
var
  Units: TStringList;
begin
  Units := CompileProbe('canary', 'Generics.Collections');
  try
    Expect<Boolean>(Units.IndexOf('GENERICS.COLLECTIONS') >= 0).ToBe(True);
  finally
    Units.Free;
  end;
end;

procedure TCLIUnitClosure.TestCLIPackageRegistersNoGenericsUnit;
var
  PackageUnits, Units: TStringList;
  Index: Integer;
  Missing, Forbidden: string;
begin
  PackageUnits := CLIPackageUnits;
  Units := nil;
  try
    Expect<Boolean>(PackageUnits.IndexOf('CLI.Options') >= 0).ToBe(True);
    PackageUnits.Delimiter := ',';
    PackageUnits.StrictDelimiter := True;
    Units := CompileProbe('cli-package', PackageUnits.DelimitedText);

    Missing := '';
    for Index := 0 to PackageUnits.Count - 1 do
      if Units.IndexOf(UpperCase(PackageUnits[Index])) < 0 then
        Missing := Missing + ' ' + PackageUnits[Index];
    Expect<string>(Missing).ToBe('');

    Forbidden := '';
    for Index := 0 to Units.Count - 1 do
      if Copy(Units[Index], 1, Length(FORBIDDEN_UNIT_PREFIX))
         = FORBIDDEN_UNIT_PREFIX then
        Forbidden := Forbidden + ' ' + Units[Index];
    Expect<string>(Forbidden).ToBe('');
  finally
    Units.Free;
    PackageUnits.Free;
  end;
end;

procedure TCLIUnitClosure.SetupTests;
begin
  Test('a probe that uses Generics.Collections registers it',
    TestCanaryRegistersGenericsCollections);
  Test('a host of every cli package unit registers no Generics.* unit',
    TestCLIPackageRegistersNoGenericsUnit);
end;

begin
  TestRunnerProgram.AddSuite(TCLIUnitClosure.Create(
    'CLIUnitClosure: the cli package links no Generics.* unit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
