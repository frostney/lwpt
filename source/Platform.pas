unit Platform;

(* Platform — host OS + CPU detection table. LWPT-canonical per ADR-0017
   (descended from GocciaScript's earlier Goccia.Platform.pas; renamed +
   switched to the local Shared.inc include during a namespace
   cleanup).

   The constant value vocabulary is single-sourced across LWPT +
   GocciaScript so the build.os / build.arch placeholder values in LWPT
   manifests and the Goccia.build.os / Goccia.build.arch globals in
   GocciaScript match byte-for-byte. Adding a new platform requires
   changing one constant table in BOTH projects; the diff is
   mechanically obvious. *)

{$I Shared.inc}

interface

function GetBuildOS: string;
function GetBuildArch: string;

implementation

const
  {$IF DEFINED(DARWIN)}
  BuildOS = 'darwin';
  {$ELSEIF DEFINED(ANDROID)}
  BuildOS = 'android';
  {$ELSEIF DEFINED(LINUX)}
  BuildOS = 'linux';
  {$ELSEIF DEFINED(MSWINDOWS)}
  BuildOS = 'windows';
  {$ELSEIF DEFINED(FREEBSD)}
  BuildOS = 'freebsd';
  {$ELSEIF DEFINED(NETBSD)}
  BuildOS = 'netbsd';
  {$ELSEIF DEFINED(OPENBSD)}
  BuildOS = 'openbsd';
  {$ELSEIF DEFINED(AIX)}
  BuildOS = 'aix';
  {$ELSEIF DEFINED(SOLARIS)}
  BuildOS = 'solaris';
  {$ELSE}
  BuildOS = 'unknown';
  {$ENDIF}

  {$IF DEFINED(CPUX86_64)}
  BuildArchitecture = 'x86_64';
  {$ELSEIF DEFINED(CPUAARCH64)}
  BuildArchitecture = 'aarch64';
  {$ELSEIF DEFINED(CPUI386)}
  BuildArchitecture = 'x86';
  {$ELSEIF DEFINED(CPUARM)}
  BuildArchitecture = 'arm';
  {$ELSEIF DEFINED(CPUPOWERPC64)}
  BuildArchitecture = 'powerpc64';
  {$ELSEIF DEFINED(CPUPOWERPC)}
  BuildArchitecture = 'powerpc';
  {$ELSE}
  BuildArchitecture = 'unknown';
  {$ENDIF}

function GetBuildOS: string;
begin
  Result := BuildOS;
end;

function GetBuildArch: string;
begin
  Result := BuildArchitecture;
end;

end.
