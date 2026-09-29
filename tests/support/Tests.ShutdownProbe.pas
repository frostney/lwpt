{ Tests.ShutdownProbe — observes a child process after LWPT's units have
  finalized.

  List this unit in a program's uses clause before any unit it should
  outlive. It depends only on System (and BaseUnix on Linux), so it is
  initialized before, and finalized after, Classes, SysUtils and every LWPT
  unit. Its finalization calls the armed check and, when the check reports
  live threads, writes a diagnostic to standard error and replaces the exit
  code with ShutdownProbeFailureExitCode. On Linux it also counts the
  process's threads through /proc/self/task, so a thread that outlived its
  owner's shutdown is caught independently of that owner's bookkeeping.
  Only when every check passes does it write ShutdownProbeCleanMarker to
  standard output: a process that ended before reaching the probe, such as
  through an emergency exit that skips finalization, never prints it. }
unit Tests.ShutdownProbe;

{$mode delphi}{$H+}

interface

type
  { Returns how many threads that should have ended are still alive. }
  TShutdownProbeCheck = function: Integer;

const
  ShutdownProbeFailureExitCode = 86;
  ShutdownProbeFailure = 'shutdown probe: threads outlived unit finalization';
  ShutdownProbeCleanMarker = 'shutdown probe: clean';

procedure ArmShutdownProbe(const ACheck: TShutdownProbeCheck);

implementation

{$IFDEF LINUX}
uses
  BaseUnix;
{$ENDIF}

var
  ArmedCheck: TShutdownProbeCheck = nil;

procedure ArmShutdownProbe(const ACheck: TShutdownProbeCheck);
begin
  ArmedCheck := ACheck;
end;

{$IFDEF LINUX}
{ Threads besides the calling one, or -1 when the count is unavailable. }
function OtherOperatingSystemThreads: Integer;
var
  Directory: pDir;
  Entry: pDirent;
begin
  Directory := FpOpendir('/proc/self/task');
  if Directory = nil then Exit(-1);
  Result := -1;
  repeat
    Entry := FpReaddir(Directory^);
    if (Entry <> nil) and (Entry^.d_name[0] <> '.') then Inc(Result);
  until Entry = nil;
  FpClosedir(Directory^);
end;
{$ENDIF}

procedure ReportLiveThreads(const ALive: Integer; const ASource: string);
begin
  { The runtime flushed its standard files before finalizing units. }
  WriteLn(StdErr, ShutdownProbeFailure, ': ', ALive, ' ', ASource);
  Flush(StdErr);
  ExitCode := ShutdownProbeFailureExitCode;
end;

procedure RunArmedCheck;
var
  Clean: Boolean;
{$IFDEF LINUX}
const
  TaskSettleAttempts = 200;
  TaskSettleNanoseconds = 10 * 1000 * 1000;
var
  Attempt: Integer;
  Pause: TTimeSpec;
{$ENDIF}
var
  Live: Integer;
begin
  if not Assigned(ArmedCheck) then Exit;
  Live := ArmedCheck();
  Clean := Live = 0;
  if not Clean then ReportLiveThreads(Live, 'by the armed check');
  {$IFDEF LINUX}
  { A joined thread's task entry can outlast pthread_join by a moment; a
    thread that was never joined stays listed. }
  Live := OtherOperatingSystemThreads;
  Attempt := 1;
  while (Live <> 0) and (Attempt < TaskSettleAttempts) do
  begin
    Pause.tv_sec := 0;
    Pause.tv_nsec := TaskSettleNanoseconds;
    FpNanoSleep(@Pause, nil);
    Live := OtherOperatingSystemThreads;
    Inc(Attempt);
  end;
  if Live <> 0 then
  begin
    Clean := False;
    ReportLiveThreads(Live, 'in /proc/self/task');
  end;
  {$ENDIF}
  if Clean then
  begin
    WriteLn(Output, ShutdownProbeCleanMarker);
    Flush(Output);
  end;
end;

finalization
  RunArmedCheck;

end.
