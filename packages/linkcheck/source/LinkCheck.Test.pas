program LinkCheck.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  SysUtils,
  TestingPascalLibrary,
  LinkCheck;

type
  TLinkCheckSuite = class(TTestSuite)
  private
    FRoot: string;
    procedure WriteFile(const ARelativePath, AContents: string);
    function RunCheck(const AOnline: Boolean = False;
      const AAllowlist: string = ''): TLinkCheckReport;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;
    procedure TestRelativeFileAndDuplicateAnchors;
    procedure TestMissingFileAndDirectoryLink;
    procedure TestAllowlistRequiresRationaleAndReportsExclusion;
    procedure TestOnlineModeRequiresHTTPSAndClassifiesStatus;
    procedure TestJSONIsDeterministic;
  end;

var
  ProbeCalls: Integer;
  ProbeTimeout: Integer;

function NotFoundProbe(const AURL: string; const ATimeoutMs: Integer): Integer;
begin
  Inc(ProbeCalls);
  ProbeTimeout := ATimeoutMs;
  Result := 404;
end;

procedure DeleteTree(const APath: string);
var
  Search: TSearchRec;
  Child: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile,
    Search) = 0 then
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Child := IncludeTrailingPathDelimiter(APath) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then DeleteTree(Child)
      else DeleteFile(Child);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  RemoveDir(APath);
end;

procedure TLinkCheckSuite.WriteFile(const ARelativePath, AContents: string);
var
  Path: string;
  Stream: TFileStream;
  Bytes: UTF8String;
begin
  Path := IncludeTrailingPathDelimiter(FRoot) + ARelativePath;
  ForceDirectories(ExtractFileDir(Path));
  Bytes := UTF8String(AContents);
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

function TLinkCheckSuite.RunCheck(const AOnline: Boolean;
  const AAllowlist: string): TLinkCheckReport;
var
  Options: TLinkCheckOptions;
  Checker: TLinkChecker;
begin
  Options := DefaultLinkCheckOptions(FRoot);
  Options.Online := AOnline;
  Options.AllowlistPath := AAllowlist;
  Options.Jobs := 2;
  Options.TimeoutMs := 321;
  if AOnline then Options.Probe := NotFoundProbe;
  Checker := TLinkChecker.Create(Options);
  try
    Result := Checker.Check;
  finally
    Checker.Free;
  end;
end;

procedure TLinkCheckSuite.BeforeEach;
begin
  inherited BeforeEach;
  FRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'lwpt-linkcheck-' + IntToHex(Random(MaxInt), 8);
  ForceDirectories(FRoot);
  ProbeCalls := 0;
  ProbeTimeout := 0;
end;

procedure TLinkCheckSuite.AfterEach;
begin
  if DirectoryExists(FRoot) then DeleteTree(FRoot);
  inherited AfterEach;
end;

procedure TLinkCheckSuite.SetupTests;
begin
  Test('relative files and duplicate GitHub anchors resolve',
    TestRelativeFileAndDuplicateAnchors);
  Test('missing files fail and existing directories resolve',
    TestMissingFileAndDirectoryLink);
  Test('allowlist requires and reports a rationale',
    TestAllowlistRequiresRationaleAndReportsExclusion);
  Test('online mode enforces TLS and classifies HTTP status',
    TestOnlineModeRequiresHTTPSAndClassifiesStatus);
  Test('machine-readable output is deterministic', TestJSONIsDeterministic);
end;

procedure TLinkCheckSuite.TestRelativeFileAndDuplicateAnchors;
var
  Report: TLinkCheckReport;
begin
  WriteFile('README.md', '[first](docs/guide.md#repeat)' + LineEnding +
    '[second](docs/guide.md#repeat-1)' + LineEnding);
  WriteFile('docs/guide.md', '# Repeat' + LineEnding + '# Repeat' + LineEnding);
  Report := RunCheck;
  try
    Expect<Boolean>(Report.HasErrors).ToBe(False);
    Expect<Integer>(Report.Count).ToBe(0);
  finally
    Report.Free;
  end;
end;

procedure TLinkCheckSuite.TestMissingFileAndDirectoryLink;
var
  Report: TLinkCheckReport;
begin
  ForceDirectories(IncludeTrailingPathDelimiter(FRoot) + 'empty');
  WriteFile('README.md', '[missing](no.md)' + LineEnding +
    '[directory](empty/)' + LineEnding);
  Report := RunCheck;
  try
    Expect<Boolean>(Report.HasErrors).ToBe(True);
    Expect<Integer>(Report.Count).ToBe(1);
    Expect<string>(Report.Findings[0].Kind).ToBe('file');
  finally
    Report.Free;
  end;
end;

procedure TLinkCheckSuite.TestAllowlistRequiresRationaleAndReportsExclusion;
var
  Report: TLinkCheckReport;
begin
  WriteFile('README.md', '[accepted](https://example.invalid/accepted)');
  WriteFile('.linkcheck-allowlist',
    'https://example.invalid/accepted' + #9 + 'upstream is intentionally gone');
  Report := RunCheck(False, '.linkcheck-allowlist');
  try
    Expect<Boolean>(Report.HasErrors).ToBe(False);
    Expect<Integer>(Report.Count).ToBe(1);
    Expect<string>(Report.Findings[0].Kind).ToBe('allowlisted');
    Expect<string>(Report.Findings[0].Message).ToBe(
      'upstream is intentionally gone');
  finally
    Report.Free;
  end;

  WriteFile('.linkcheck-allowlist', 'https://example.invalid/accepted');
  Report := RunCheck(False, '.linkcheck-allowlist');
  try
    Expect<Boolean>(Report.HasErrors).ToBe(True);
    Expect<string>(Report.Findings[0].Kind).ToBe('allowlist');
  finally
    Report.Free;
  end;
end;

procedure TLinkCheckSuite.TestOnlineModeRequiresHTTPSAndClassifiesStatus;
var
  Report: TLinkCheckReport;
begin
  WriteFile('README.md', '[insecure](http://example.invalid)' + LineEnding +
    '[missing](https://example.invalid/missing)' + LineEnding);
  Report := RunCheck(True);
  try
    Expect<Boolean>(Report.HasErrors).ToBe(True);
    Expect<Integer>(Report.Count).ToBe(2);
    Expect<Integer>(ProbeCalls).ToBe(1);
    Expect<Integer>(ProbeTimeout).ToBe(321);
    Expect<string>(Report.Findings[0].Message).ToBe(
      'external links must use HTTPS');
    Expect<string>(Report.Findings[1].Message).ToBe('HTTP status 404');
  finally
    Report.Free;
  end;
end;

procedure TLinkCheckSuite.TestJSONIsDeterministic;
var
  FirstReport, SecondReport: TLinkCheckReport;
begin
  WriteFile('README.md', '[z](z.md)' + LineEnding + '[a](a.md)' + LineEnding);
  FirstReport := RunCheck;
  SecondReport := RunCheck;
  try
    Expect<string>(FirstReport.ToJSON).ToBe(SecondReport.ToJSON);
    Expect<string>(FirstReport.ToJSON).ToBe(
      '{"ok":false,"findings":[' +
      '{"severity":"error","kind":"file","source":"README.md",' +
      '"line":1,"target":"z.md","message":"target does not exist"},' +
      '{"severity":"error","kind":"file","source":"README.md",' +
      '"line":2,"target":"a.md","message":"target does not exist"}]}');
  finally
    SecondReport.Free;
    FirstReport.Free;
  end;
end;

var
  Suite: TLinkCheckSuite;
begin
  Randomize;
  Suite := TLinkCheckSuite.Create('linkcheck');
  TestRunnerProgram.AddSuite(Suite);
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
