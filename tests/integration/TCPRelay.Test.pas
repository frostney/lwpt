program TCPRelay.Test;

{ The E2E relay (tests/support/Tests.TCPRelay.pas) must relay and count
  faithfully, and its teardown must stay bounded however the backend
  behaves: idle with no wake-up connection, during a backend connection
  that never completes, and while both copies are blocked. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  Sockets,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  WinSock2,
  {$ENDIF}
  Classes,
  SysUtils,

  TestingPascalLibrary,
  Tests.RegistryHTTP,
  Tests.RegistryServer,
  Tests.TCPRelay;

const
  { TEST-NET-1 is never routed: a connection there never completes (or,
    without a route, fails at once). }
  UNROUTED_HOST = '192.0.2.1';
  TEARDOWN_BOUND_MILLISECONDS = 2000;

type
  TTCPRelayTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestRelaysAndCountsConnections;
    procedure TestIdleTeardownNeedsNoWakeConnection;
    procedure TestTeardownDuringAStalledBackendConnection;
    procedure TestStalledBackendConnectionIsBounded;
    procedure TestTeardownWhileCopiesAreBlocked;
    procedure TestReadinessThatDisappearsBeforeAccept;
  end;

  { Takes the pending connection off the relay's listener after the
    relay saw it ready and before its own accept, once. }
  TAcceptThief = class
  public
    Taken: Integer;
    Stolen: TSocket;
    procedure Steal(ASender: TObject);
  end;

function TimedFree(ARelay: TTCPRelay): QWord;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  ARelay.Free;
  Result := GetTickCount64 - Started;
end;

procedure TTCPRelayTests.TestRelaysAndCountsConnections;
var
  Backend: TRegistryTestServer;
  Relay: TTCPRelay;
  Response: TRawHTTPResponse;
begin
  Backend := TRegistryTestServer.Create([RegistryRoute('/x', 'text/plain',
    RawHTTPBytes('relayed'))], True);
  try
    Backend.Start;
    Relay := TTCPRelay.Create(Backend.Port);
    try
      Response := RawHTTPRequest(Relay.Port, 'GET', '/x', [], nil, False, 5000);
      Expect<Integer>(Response.Status).ToBe(200);
      Expect<string>(RawHTTPBodyText(Response)).ToBe('relayed');
      Response := RawHTTPRequest(Relay.Port, 'GET', '/x', [], nil, False, 5000);
      Expect<Integer>(Response.Status).ToBe(200);
      Expect<Integer>(Relay.Accepted).ToBe(2);
      Expect<Integer>(Relay.FailedConnects).ToBe(0);
    finally
      Relay.Free;
    end;
  finally
    Backend.Free;
  end;
end;

procedure TTCPRelayTests.TestIdleTeardownNeedsNoWakeConnection;
var
  Relay: TTCPRelay;
begin
  { Nothing ever connects, so an accept could only be interrupted by a
    wake-up connection; the relay polls instead and needs none. }
  Relay := TTCPRelay.Create(1);
  Sleep(100);
  Expect<Boolean>(TimedFree(Relay) < TEARDOWN_BOUND_MILLISECONDS).ToBe(True);
end;

procedure TTCPRelayTests.TestTeardownDuringAStalledBackendConnection;
var
  Relay: TTCPRelay;
  Client: TRawHTTPConnection;
  Started: QWord;
begin
  Relay := TTCPRelay.Create(9, UNROUTED_HOST);
  Relay.ConnectTimeoutMilliseconds := 60000;
  Client := TRawHTTPConnection.Create(Relay.Port);
  try
    Started := GetTickCount64;
    while (Relay.Accepted = 0) and (GetTickCount64 - Started < 5000) do Sleep(10);
    Expect<Integer>(Relay.Accepted).ToBe(1);
    { The backend connection is pending (or already failed): either way
      teardown must not wait for its 60-second bound. }
    Expect<Boolean>(TimedFree(Relay) < TEARDOWN_BOUND_MILLISECONDS).ToBe(True);
  finally
    Client.Free;
  end;
end;

procedure TTCPRelayTests.TestStalledBackendConnectionIsBounded;
var
  Relay: TTCPRelay;
  Client: TRawHTTPConnection;
  Started: QWord;
begin
  Relay := TTCPRelay.Create(9, UNROUTED_HOST);
  try
    Relay.ConnectTimeoutMilliseconds := 500;
    Client := TRawHTTPConnection.Create(Relay.Port);
    try
      Started := GetTickCount64;
      { The relay gives up on the backend and closes the client. }
      Client.ReadResponse(10000);
      Expect<Boolean>(GetTickCount64 - Started < 5000).ToBe(True);
      Expect<Integer>(Relay.FailedConnects).ToBe(1);
    finally
      Client.Free;
    end;
  finally
    Relay.Free;
  end;
end;

procedure TTCPRelayTests.TestTeardownWhileCopiesAreBlocked;
var
  Relay: TTCPRelay;
  Silent: TRegistryTestServer;
  Client: TRawHTTPConnection;
  Started: QWord;
begin
  { A backend whose listener is never served completes the connection in
    the kernel and never answers, leaving both copies blocked in receive. }
  Silent := TRegistryTestServer.Create(nil);
  try
    Relay := TTCPRelay.Create(Silent.Port);
    Client := TRawHTTPConnection.Create(Relay.Port);
    try
      Started := GetTickCount64;
      while (Relay.Accepted = 0) and (GetTickCount64 - Started < 5000) do Sleep(10);
      Sleep(200);
      Expect<Integer>(Relay.FailedConnects).ToBe(0);
      Expect<Boolean>(TimedFree(Relay) < TEARDOWN_BOUND_MILLISECONDS).ToBe(True);
    finally
      Client.Free;
    end;
  finally
    Silent.Free;
  end;
end;

procedure TAcceptThief.Steal(ASender: TObject);
var
  Relay: TTCPRelay;
begin
  if Taken > 0 then Exit;
  Relay := TTCPRelay(ASender);
  {$IFDEF UNIX}
  Stolen := fpAccept(Relay.ListenSocket, nil, nil);
  {$ELSE}
  Stolen := WinSock2.accept(Relay.ListenSocket, nil, nil);
  {$ENDIF}
  Inc(Taken);
end;

procedure TTCPRelayTests.TestReadinessThatDisappearsBeforeAccept;
var
  Relay: TTCPRelay;
  Thief: TAcceptThief;
  Client: TRawHTTPConnection;
  Started: QWord;
begin
  Thief := TAcceptThief.Create;
  try
    Relay := TTCPRelay.Create(1);
    Relay.BeforeAccept := Thief.Steal;
    Client := TRawHTTPConnection.Create(Relay.Port);
    try
      Started := GetTickCount64;
      while (Thief.Taken = 0) and (GetTickCount64 - Started < 5000) do Sleep(10);
      Expect<Integer>(Thief.Taken).ToBe(1);
      Sleep(200);
      { The relay's accept found nothing and did not block, so it counted
        nothing and tears down at once. }
      Expect<Integer>(Relay.Accepted).ToBe(0);
      Expect<Boolean>(TimedFree(Relay) < TEARDOWN_BOUND_MILLISECONDS).ToBe(True);
    finally
      Client.Free;
    end;
    {$IFDEF UNIX}
    if Thief.Stolen >= 0 then CloseSocket(Thief.Stolen);
    {$ELSE}
    if Thief.Stolen <> INVALID_SOCKET then WinSock2.closesocket(Thief.Stolen);
    {$ENDIF}
  finally
    Thief.Free;
  end;
end;

procedure TTCPRelayTests.SetupTests;
begin
  Test('relays bytes unchanged and counts connections', TestRelaysAndCountsConnections);
  Test('idle teardown needs no wake-up connection', TestIdleTeardownNeedsNoWakeConnection);
  Test('teardown does not wait for a stalled backend connection',
    TestTeardownDuringAStalledBackendConnection);
  Test('a backend connection that never completes is bounded',
    TestStalledBackendConnectionIsBounded);
  Test('teardown ends copies blocked on an idle backend',
    TestTeardownWhileCopiesAreBlocked);
  Test('readiness that disappears before accept never blocks the relay',
    TestReadinessThatDisappearsBeforeAccept);
end;

begin
  TestRunnerProgram.AddSuite(TTCPRelayTests.Create('e2e tcp relay'));
  TestRunnerProgram.Run;
end.
