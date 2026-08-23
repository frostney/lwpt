{ LWPT.Command.Registry — initialize and serve a self-hosted origin. }
unit LWPT.Command.Registry;

{$I Shared.inc}
{$J-}

interface

function CmdRegistryInit(const ADataDirectory, AIdentity, ABaseURL,
  AListenAddress: string; const APort: Integer; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string): Integer;
function CmdRegistryServe(const ADataDirectory: string): Integer;

implementation

uses
  DateUtils,
  SysUtils,

  LWPT.Registry.Server,
  LWPT.Registry.Store;

function CurrentTimestamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

function CmdRegistryInit(const ADataDirectory, AIdentity, ABaseURL,
  AListenAddress: string; const APort: Integer; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string): Integer;
var
  Config: TLWPTRegistryConfig;
  Store: TLWPTRegistryStore;
begin
  if (APort < 1) or (APort > 65535) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'port must be between 1 and 65535');
  Config := RegistryConfiguration(AIdentity, ABaseURL, AListenAddress,
    APort, ATLSPKCS12Path, ATLSPasswordEnvironment);
  Store := TLWPTRegistryStore.Initialize(ADataDirectory, Config,
    CurrentTimestamp);
  try
    WriteLn('initialized registry origin ', Store.Config.Identity, ' at ',
      ExpandFileName(ADataDirectory));
  finally
    Store.Free;
  end;
  Result := 0;
end;

function CmdRegistryServe(const ADataDirectory: string): Integer;
var
  Server: TLWPTRegistryServer;
  Store: TLWPTRegistryStore;
begin
  Store := TLWPTRegistryStore.Create(ADataDirectory);
  try
    Server := TLWPTRegistryServer.Create(Store);
    try
      Server.Run;
    finally
      Server.Free;
    end;
  finally
    Store.Free;
  end;
  Result := 0;
end;

end.
