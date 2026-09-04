{ LWPT.Command.Registry — initialize and serve a self-hosted origin. }
unit LWPT.Command.Registry;

{$I Shared.inc}
{$J-}

interface

function CmdRegistryInit(const ADataDirectory, AIdentity, ABaseURL,
  AListenAddress: string; const APort: Integer; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string; const ARole: string = 'origin';
  const AUpstream: string = ''; const AKeyID: string = '';
  const APublicKey: string = ''): Integer;
function CmdRegistryServe(const ADataDirectory: string): Integer;
function CmdRegistrySync(const ADataDirectory: string): Integer;
function CmdRegistryVerify(const ADataDirectory: string): Integer;

implementation

uses
  DateUtils,
  SysUtils,
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}

  LWPT.Registry.Mirror,
  LWPT.Registry.Server,
  LWPT.Registry.Store;

var
  ActiveRegistryServer: TLWPTRegistryServer = nil;

{$IFDEF UNIX}
function CSignal(const ASignal: LongInt;
  const AHandler: Pointer): Pointer; cdecl;
  {$IFDEF LINUX}
  external 'c' name 'signal';
  {$ELSE}
  external name 'signal';
  {$ENDIF}

procedure RegistrySignalHandler(ASignal: LongInt); cdecl;
begin
  if Assigned(ActiveRegistryServer) then ActiveRegistryServer.RequestStop;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function RegistryConsoleControlHandler(AControlType: DWORD): BOOL; stdcall;
begin
  Result := AControlType in [CTRL_C_EVENT, CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT, CTRL_SHUTDOWN_EVENT];
  if Result and Assigned(ActiveRegistryServer) then
    ActiveRegistryServer.RequestStop;
end;
{$ENDIF}

function CurrentTimestamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',
    LocalTimeToUniversal(Now));
end;

function CmdRegistryInit(const ADataDirectory, AIdentity, ABaseURL,
  AListenAddress: string; const APort: Integer; const ATLSPKCS12Path,
  ATLSPasswordEnvironment: string; const ARole, AUpstream, AKeyID,
  APublicKey: string): Integer;
var
  Config: TLWPTRegistryConfig;
  Store: TLWPTRegistryStore;
begin
  if (APort < 1) or (APort > 65535) then
    raise ELWPTRegistryError.CreateStable('invalid_configuration',
      'port must be between 1 and 65535');
  Config := RegistryConfiguration(AIdentity, ABaseURL, AListenAddress,
    APort, ATLSPKCS12Path, ATLSPasswordEnvironment);
  if ARole = 'mirror' then
  begin
    Config.Role := rrMirror;
    Config.UpstreamURL := AUpstream;
    Config.TrustKeyID := AKeyID;
    Config.TrustPublicKey := APublicKey;
    if Config.TLSPKCS12Path <> '' then Config.TLSPKCS12Path := ExpandFileName(Config.TLSPKCS12Path);
    ValidateMirrorConfiguration(Config);
    Store := TLWPTRegistryMirror.Initialize(ADataDirectory, Config, CurrentTimestamp);
  end
  else
  begin
    if (ARole <> 'origin') or (AUpstream <> '') or (AKeyID <> '') or (APublicKey <> '') then
      raise ELWPTRegistryError.CreateStable('invalid_configuration',
        'role must be origin or mirror; upstream and pins are mirror-only');
    Store := TLWPTRegistryStore.Initialize(ADataDirectory, Config, CurrentTimestamp);
  end;
  try
    WriteLn('initialized registry ', ARole, ' ', Store.Config.Identity, ' at ',
      ExpandFileName(ADataDirectory));
  finally
    Store.Free;
  end;
  Result := 0;
end;

function OpenRegistryStore(const ADataDirectory: string): TLWPTRegistryStore;
begin
  if LoadRegistryConfiguration(ADataDirectory).Role = rrMirror then
    Result := TLWPTRegistryMirror.Create(ADataDirectory)
  else Result := TLWPTRegistryStore.Create(ADataDirectory);
end;

function CmdRegistrySync(const ADataDirectory: string): Integer;
var
  Mirror: TLWPTRegistryMirror;
begin
  Mirror := TLWPTRegistryMirror.Create(ADataDirectory);
  try
    Mirror.Synchronize;
    WriteLn('synchronized registry mirror ', Mirror.Config.Identity);
  finally
    Mirror.Free;
  end;
  Result := 0;
end;

function CmdRegistryVerify(const ADataDirectory: string): Integer;
var
  Store: TLWPTRegistryStore;
begin
  Store := OpenRegistryStore(ADataDirectory);
  try
    if Store is TLWPTRegistryMirror then Write(TLWPTRegistryMirror(Store).VerifyMirror)
    else
    begin
      WriteLn('role = "origin"');
      WriteLn('origin = ', RegistryTOMLQuote(Store.Config.Identity));
      WriteLn('sequence = ', Store.LoadCurrentState.Sequence);
    end;
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
  Store := OpenRegistryStore(ADataDirectory);
  try
    Server := TLWPTRegistryServer.Create(Store);
    try
      Store.EnsureFreshCheckpoint(RegistryTimestampNow);
      ActiveRegistryServer := Server;
      {$IFDEF UNIX}
      CSignal(SIGINT, @RegistrySignalHandler);
      CSignal(SIGTERM, @RegistrySignalHandler);
      {$ENDIF}
      {$IFDEF MSWINDOWS}
      Windows.SetConsoleCtrlHandler(@RegistryConsoleControlHandler, True);
      {$ENDIF}
      Server.Run;
    finally
      {$IFDEF MSWINDOWS}
      Windows.SetConsoleCtrlHandler(@RegistryConsoleControlHandler, False);
      {$ENDIF}
      ActiveRegistryServer := nil;
      Server.Free;
    end;
  finally
    Store.Free;
  end;
  Result := 0;
end;

end.
