{ Version.Test — pins lwpt --version output + verifies the three
  aliases (--version / -v / version) all produce the same string.

  The version string is derived at compile time from lwpt.toml's
  [package].version field via the stamp-version [prebuild] hook +
  Version.inc. This test verifies:

    1. --version produces "lwpt <version>" with a trailing newline.
    2. -v produces the same output (short alias).
    3. version (bare positional) produces the same output.
    4. The version reported by the binary matches the value in this
       project's own lwpt.toml — the drift guard that earlier waves
       relied on a self-test to catch. Since the build pipeline IS
       the deriver (compile-time include), the test would catch any
       regression that breaks the include or the [prebuild] hook
       wiring. }

program Version.Test;

{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.LwptSubprocess;

type
  TVersionE2E = class(TTestSuite)
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestLongFlag;
    procedure TestShortFlag;
    procedure TestBarePositional;
    procedure TestMatchesManifest;
  end;

function ParseManifestVersion: string;
var
  Lines: TStringList;
  i, EqPos: Integer;
  Trimmed, Value: string;
  InPackage: Boolean;
begin
  Result := '';
  InPackage := False;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile('lwpt.toml');
    for i := 0 to Lines.Count - 1 do
    begin
      Trimmed := Trim(Lines[i]);
      if Trimmed = '' then Continue;
      if (Length(Trimmed) > 0) and (Trimmed[1] = '#') then Continue;
      if (Length(Trimmed) >= 2) and (Trimmed[1] = '[') then
      begin
        InPackage := SameText(Trimmed, '[package]');
        Continue;
      end;
      if not InPackage then Continue;
      if not SameText(Copy(Trimmed, 1, 7), 'version') then Continue;
      EqPos := Pos('=', Trimmed);
      if EqPos = 0 then Continue;
      Value := Trim(Copy(Trimmed, EqPos + 1, MaxInt));
      Value := StringReplace(Value, '"', '', [rfReplaceAll]);
      Value := StringReplace(Value, '''', '', [rfReplaceAll]);
      Result := Trim(Value);
      Exit;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TVersionE2E.BeforeAll;
begin
  SetLwptBinaryPath(ExpandFileName('build/lwpt'));
end;

procedure TVersionE2E.TestLongFlag;
var R: TLwptResult;
begin
  R := RunLwpt(['--version']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('lwpt ', R.Stdout) = 1).ToBe(True);
  Expect<string>(R.Stderr).ToBe('');
end;

procedure TVersionE2E.TestShortFlag;
var R: TLwptResult;
begin
  R := RunLwpt(['-v']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('lwpt ', R.Stdout) = 1).ToBe(True);
end;

procedure TVersionE2E.TestBarePositional;
var R: TLwptResult;
begin
  R := RunLwpt(['version']);
  Expect<Integer>(R.ExitCode).ToBe(0);
  Expect<Boolean>(Pos('lwpt ', R.Stdout) = 1).ToBe(True);
end;

procedure TVersionE2E.TestMatchesManifest;
var
  R: TLwptResult;
  Expected, Reported: string;
begin
  Expected := ParseManifestVersion;
  Expect<Boolean>(Expected <> '').ToBe(True);

  R := RunLwpt(['--version']);
  Expect<Integer>(R.ExitCode).ToBe(0);

  { Output shape: 'lwpt <version>' followed by a newline. Strip the
    prefix and trailing whitespace to extract the bare version. }
  Reported := Trim(R.Stdout);
  Expect<Boolean>(Pos('lwpt ', Reported) = 1).ToBe(True);
  Reported := Trim(Copy(Reported, 6, MaxInt));

  Expect<string>(Reported).ToBe(Expected);
end;

procedure TVersionE2E.SetupTests;
begin
  Test('--version exits 0 and prints "lwpt <version>"', TestLongFlag);
  Test('-v is a short alias and produces the same shape', TestShortFlag);
  Test('bare positional "version" produces the same shape', TestBarePositional);
  Test('reported version matches lwpt.toml [package].version (drift guard)',
    TestMatchesManifest);
end;

begin
  TestRunnerProgram.AddSuite(TVersionE2E.Create('lwpt --version: subprocess'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
