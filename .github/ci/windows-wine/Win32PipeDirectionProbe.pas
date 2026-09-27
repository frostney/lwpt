program Win32PipeDirectionProbe;

{$mode delphi}{$H+}

uses
  LWPT.ProcessTree,
  Windows;

procedure Require(const ACondition: Boolean; const AMessage: string);
begin
  if ACondition then Exit;
  WriteLn(ErrOutput, AMessage, ': ', GetLastError);
  Halt(1);
end;

var
  ReadHandle, WriteHandle: THandle;
  SecurityAttributes: TSecurityAttributes;
begin
  FillChar(SecurityAttributes, SizeOf(SecurityAttributes), 0);
  SecurityAttributes.nLength := SizeOf(SecurityAttributes);
  SecurityAttributes.bInheritHandle := True;
  Require(CreatePipe(ReadHandle, WriteHandle, @SecurityAttributes, 4096),
    'CreatePipe failed');
  try
    Require(ValidInheritedPipeHandle(PtrInt(ReadHandle), FILE_READ_DATA),
      'read end rejected read capability');
    Require(not ValidInheritedPipeHandle(PtrInt(WriteHandle), FILE_READ_DATA),
      'write end accepted read capability');
    Require(ValidInheritedPipeHandle(PtrInt(WriteHandle), FILE_WRITE_DATA),
      'write end rejected write capability');
    Require(not ValidInheritedPipeHandle(PtrInt(ReadHandle), FILE_WRITE_DATA),
      'read end accepted write capability');
    WriteLn('anonymous pipe direction capabilities: pass');
  finally
    CloseHandle(ReadHandle);
    CloseHandle(WriteHandle);
  end;
end.
