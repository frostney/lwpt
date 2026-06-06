{ Tests.LwptSubprocess — spawn ./build/lwpt as a subprocess and capture
  exit code, stdout, stderr.

  E2E tests need this because the whole point of the tier is to test
  the binary as users invoke it: argv parsing through the real CLI
  layer, exit codes the shell sees, stdout/stderr the user sees, and
  on-disk side effects in a real CWD. Tests that `uses LWPT.Core`
  link the library and skip the binary surface entirely — which is
  what Unit + Integration are for.

  Design choices:

    - Stdout and stderr are captured separately (not merged) so tests
      can assert on each independently. Most LWPT errors land on
      stderr; the success summaries land on stdout.
    - The caller's environment is inherited by default; AExtraEnv
      adds or overrides individual variables for that subprocess
      only.
    - cwd defaults to the current directory; AInDir overrides for
      per-test scratch dirs (matches the integration-tier pattern
      from InstallLocalDiamond.Test.pas).
    - The binary path is configurable via LwptBinaryPath but defaults
      to ./build/lwpt (resolved relative to the test's CWD, which
      lwpt test sets to the project root before launching each test).
    - poWaitOnExit + reading streams after exit. Output is short
      for LWPT subcommands; if a future subcommand streams large
      output we'll switch to incremental drain.

  Surface — kept minimal:

    function RunLwpt(const AArgs; AInDir; AExtraEnv): TLwptResult;
    function LwptBinaryPath: string;
    function ExpectedExe(const APath: string): string;
    procedure SetLwptBinaryPath(const APath: string);
}

unit Tests.LwptSubprocess;

{$mode delphi}{$H+}

interface

uses
  Classes,
  Process,
  SysUtils;

type
  TLwptResult = record
    ExitCode: Integer;
    Stdout:   string;
    Stderr:   string;
  end;

{ Spawn the lwpt binary with the given arguments. Stdout + stderr are
  captured separately. AInDir defaults to '' which means "inherit the
  caller's CWD". AExtraEnv is an array of "KEY=value" strings; each is
  added to the inherited environment, replacing any existing value
  with the same key. }
function RunLwpt(const AArgs: array of string;
  const AInDir: string = ''): TLwptResult; overload;
function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult; overload;

{ Path to the lwpt binary. Defaults to './build/lwpt' resolved at the
  point of the call. Override via SetLwptBinaryPath when running
  from a non-standard layout (e.g. a side-by-side comparison). }
function LwptBinaryPath: string;
function ExpectedExe(const APath: string): string;
procedure SetLwptBinaryPath(const APath: string);

{ Quick helper for "is the env saying skip network?". E2E tests that
  touch the live internet should consult this and self-skip via a
  WriteLn + early-return. }
function SkipNetworkTests: Boolean;

{ Did a non-zero `lwpt` result fail purely because the network / host
  was unreachable — as opposed to LWPT producing wrong output? E2E
  tests call this after their install run and SKIP (rather than FAIL)
  when it returns True: a TCP connect failure or DNS resolution
  failure to a third-party host (bitbucket.org, github.com, gitlab.com)
  is transient infrastructure flakiness, not an LWPT defect.

  Detection is deliberately NARROW — only HTTPClient's two clean
  pre-transfer failures:
    - "Failed to connect to <host>:<port>"   (TCP connect failed)
    - "Failed to resolve host: <host>"        (DNS lookup failed)
  Both fire before any byte is fetched or parsed. Errors that indicate
  a real LWPT bug — "truncated chunked body", "no header terminator",
  a hash mismatch, a missing extracted file — are intentionally NOT
  matched, so the e2e assertions still fail HARD on those. The split
  is the whole point: third-party downtime skips; LWPT regressions
  fail. }
function IsNetworkUnavailable(const AResult: TLwptResult): Boolean;

implementation

var
  GLwptBinaryPath: string = '';

function LwptBinaryPath: string;
begin
  if GLwptBinaryPath <> '' then Exit(GLwptBinaryPath);
  Result := ExpandFileName('build/lwpt');
end;

function ExpectedExe(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  if ExtractFileExt(Result) = '' then Result := Result + '.exe';
  {$ENDIF}
end;

procedure SetLwptBinaryPath(const APath: string);
begin
  GLwptBinaryPath := APath;
end;

function SkipNetworkTests: Boolean;
begin
  Result := GetEnvironmentVariable('LWPT_SKIP_NETWORK') = '1';
end;

function IsNetworkUnavailable(const AResult: TLwptResult): Boolean;
var
  Err: string;
begin
  if AResult.ExitCode = 0 then Exit(False);
  Err := LowerCase(AResult.Stderr);
  Result := (Pos('failed to connect to', Err) > 0)
         or (Pos('failed to resolve host', Err) > 0);
end;

{ Drain a stream into a string buffer. Stops at EOF; assumes the
  subprocess has already exited so no blocking reads. Uses a 4 KiB
  chunk size — large enough that LWPT's typical output (a few lines)
  fits in one read. }
function DrainStream(AStream: TStream): string;
const
  CHUNK = 4 * 1024;
var
  Buf: array of Byte;
  N, Total: Integer;
begin
  Result := '';
  SetLength(Buf, CHUNK);
  Total := 0;
  while True do
  begin
    N := AStream.Read(Buf[0], CHUNK);
    if N <= 0 then Break;
    SetLength(Result, Total + N);
    Move(Buf[0], Result[Total + 1], N);
    Inc(Total, N);
  end;
end;

function RunLwpt(const AArgs: array of string;
  const AInDir: string): TLwptResult;
var Empty: array of string;
begin
  SetLength(Empty, 0);
  Result := RunLwpt(AArgs, AInDir, Empty);
end;

function RunLwpt(const AArgs: array of string;
  const AInDir: string;
  const AExtraEnv: array of string): TLwptResult;
var
  P: TProcess;
  i: Integer;
  SavedDir: string;
begin
  Result.ExitCode := -1;
  Result.Stdout   := '';
  Result.Stderr   := '';

  P := TProcess.Create(nil);
  try
    P.Executable := LwptBinaryPath;
    for i := 0 to High(AArgs) do P.Parameters.Add(AArgs[i]);
    P.Options := [poUsePipes];
    if AInDir <> '' then P.CurrentDirectory := AInDir;

    { Environment: TProcess inherits the parent env when P.Environment
      is empty. To add extras, we have to copy the parent env first
      and then add ours. SysUtils.GetEnvironmentString(i) lets us walk
      the parent's env. }
    if Length(AExtraEnv) > 0 then
    begin
      for i := 1 to GetEnvironmentVariableCount do
        P.Environment.Add(GetEnvironmentString(i));
      for i := 0 to High(AExtraEnv) do
        P.Environment.Add(AExtraEnv[i]);
    end;

    { Run + drain. We do NOT use poWaitOnExit with poUsePipes; on
      Linux+macOS that pair can deadlock when the child blocks
      writing past the pipe buffer because the parent isn't reading.
      Instead: Execute, then drain both streams while the child runs,
      then WaitOnExit. }
    SavedDir := GetCurrentDir;
    try
      P.Execute;
      while P.Running do
      begin
        if P.Output.NumBytesAvailable > 0 then
          Result.Stdout := Result.Stdout + DrainStream(P.Output);
        if P.Stderr.NumBytesAvailable > 0 then
          Result.Stderr := Result.Stderr + DrainStream(P.Stderr);
        Sleep(10);
      end;
      { final drain after exit }
      if P.Output.NumBytesAvailable > 0 then
        Result.Stdout := Result.Stdout + DrainStream(P.Output);
      if P.Stderr.NumBytesAvailable > 0 then
        Result.Stderr := Result.Stderr + DrainStream(P.Stderr);
      { Normalise across platforms: TProcess.ExitStatus is the raw
        waitpid(2) status word on Unix and the GetExitCodeProcess
        return on Windows. ExitCode is normalised across both. }
      Result.ExitCode := P.ExitCode;
    finally
      SetCurrentDir(SavedDir);
    end;
  finally
    P.Free;
  end;
end;

end.
