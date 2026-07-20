{ Tests.ProcessSupport — cross-platform process-liveness assertions. }
unit Tests.ProcessSupport;

{$mode delphi}{$H+}

interface

const
  ProcessPollMilliseconds = 10;
  SecondsPerDay = 86400;

function ProcessIsRunning(const APID: Integer): Boolean;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows
  {$ENDIF};

function ProcessIsRunning(const APID: Integer): Boolean;
{$IFDEF UNIX}
begin
  Result := (APID > 0)
    and ((FpKill(APID, 0) = 0) or (FpGetErrNo = ESysEPERM));
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  ExitCode: DWORD;
  Handle: THandle;
begin
  if APID <= 0 then Exit(False);
  Handle := Windows.OpenProcess(Windows.PROCESS_QUERY_INFORMATION,
    False, DWORD(APID));
  if Handle = 0 then Exit(False);
  try
    Result := Windows.GetExitCodeProcess(Handle, ExitCode)
      and (ExitCode = Windows.STILL_ACTIVE);
  finally
    Windows.CloseHandle(Handle);
  end;
end;
{$ENDIF}

end.
