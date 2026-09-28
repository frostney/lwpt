{ LWPT.FetchPolicy.Test — dependency fetch destination policy (ADR-0048).

  Pins which hosts, address policy, and scheme requirement each source kind
  carries: every network source requires https and a globally reachable
  address on every hop. The policy is then driven end to end through the real
  ref-listing and HTTP paths against loopback mock servers: a git-host
  request aimed at a host its forge does not own and a plaintext request are
  refused before connecting, a redirect off a custom source's declared hosts
  is refused before the target is contacted, and a custom source or direct
  URL cannot reach a private address. }
program LWPT.FetchPolicy.Test;

{$I Shared.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,

  HTTPClient,
  LWPT.Core,
  LWPT.FetchPolicy,
  LWPT.GitProtocol,
  LWPT.Manifest,
  TestingPascalLibrary,
  Tests.HTTPMockServer;

type
  TFetchPolicySuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestBuiltInForgesAllowOnlyTheirHostsAndDenyPrivate;
    procedure TestBuiltInForgeOrigins;
    procedure TestCustomSourceAllowsTemplateHosts;
    procedure TestCustomSourcesAndDirectURLsDenyPrivateAddresses;
    procedure TestLocalSourcesKeepBaseOptions;
    procedure TestUndeclaredCustomSourceIsAnError;
    procedure TestGitHostRefListingRefusesForeignHost;
    procedure TestPlaintextDependencyRequestIsRefused;
    procedure TestCustomSourceRedirectOffTemplateHostsIsRefused;
    procedure TestCustomSourceAndDirectURLCannotReachPrivateAddress;
  end;

function Dep(const AKind: TSourceKind; const AHost: THostKind;
  const AHostName, ALocator: string): TDependency;
begin
  Result := Default(TDependency);
  Result.Name := 'dep';
  Result.SrcKind := AKind;
  Result.SrcHost := AHost;
  Result.SrcHostName := AHostName;
  Result.SrcLocator := ALocator;
end;

function Sources(const AName, AArchive, AGit: string): TCustomSourceArray;
begin
  SetLength(Result, 1);
  Result[0].Name := AName;
  Result[0].ArchiveTemplate := AArchive;
  Result[0].GitTemplate := AGit;
end;

function HostList(const AOptions: THTTPRequestOptions): string;
var HostIndex: Integer;
begin
  Result := '';
  for HostIndex := 0 to High(AOptions.Destination.AllowedHosts) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + AOptions.Destination.AllowedHosts[HostIndex];
  end;
end;

function Options(const ADep: TDependency;
  const ASources: TCustomSourceArray): THTTPRequestOptions;
begin
  Result := DependencyFetchOptions(ADep, ASources, DefaultHTTPRequestOptions);
end;

function MockSources(const APort: Word): TCustomSourceArray;
var Base: string;
begin
  Base := 'https://127.0.0.1:' + IntToStr(APort);
  Result := Sources('forge', Base + '/{user}/{repository}/{ref}.tar.gz',
    Base + '/{user}/{repository}.git');
end;

function GetError(const AURL: string;
  const AOptions: THTTPRequestOptions): string;
var NoHeaders: THTTPHeaders;
begin
  Result := '';
  NoHeaders := nil;
  try
    HTTPGet(AURL, NoHeaders, AOptions);
  except
    on E: EHTTPError do Result := E.Message;
  end;
end;

procedure TFetchPolicySuite.TestBuiltInForgesAllowOnlyTheirHostsAndDenyPrivate;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skGitHost, hkGitHub, '', 'owner/repo'), nil);
  Expect<string>(HostList(O)).ToBe('github.com,codeload.github.com');
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papDeny).ToBe(True);
  Expect<Boolean>(O.Destination.RequireHTTPS).ToBe(True);

  O := Options(Dep(skGitHost, hkGitLab, '', 'group/repo'), nil);
  Expect<string>(HostList(O)).ToBe('gitlab.com');
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papDeny).ToBe(True);

  O := Options(Dep(skGitHost, hkBitbucket, '', 'team/repo'), nil);
  Expect<string>(HostList(O)).ToBe('bitbucket.org');
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papDeny).ToBe(True);
end;

procedure TFetchPolicySuite.TestBuiltInForgeOrigins;
begin
  Expect<string>(BuiltInForgeOrigin(hkGitHub)).ToBe('https://github.com/');
  Expect<string>(BuiltInForgeOrigin(hkGitLab)).ToBe('https://gitlab.com/');
  Expect<string>(BuiltInForgeOrigin(hkBitbucket))
    .ToBe('https://bitbucket.org/');
  Expect<string>(BuiltInForgeOrigin(hkCustom)).ToBe('');
end;

procedure TFetchPolicySuite.TestCustomSourceAllowsTemplateHosts;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skGitHost, hkCustom, 'forge', 'owner/repo'),
    Sources('forge',
      'https://mirror@Downloads.Example.com:8443/{user}/{repository}/{ref}.tar.gz',
      'https://git.example.com/{user}/{repository}.git'));
  Expect<string>(HostList(O))
    .ToBe('downloads.example.com,git.example.com');

  { A per-user host is rendered from the locator before it is allowed. }
  O := Options(Dep(skGitHost, hkCustom, 'pages', 'alice/repo'),
    Sources('pages',
      'https://{user}.pages.example/{repository}/{ref}.tar.gz',
      'https://{user}.pages.example/{repository}.git'));
  Expect<string>(HostList(O)).ToBe('alice.pages.example');
end;

procedure TFetchPolicySuite.TestCustomSourcesAndDirectURLsDenyPrivateAddresses;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skGitHost, hkCustom, 'forge', 'o/r'),
    Sources('forge', 'https://forge.internal/{user}/{repository}/{ref}.tgz',
      'https://forge.internal/{user}/{repository}.git'));
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papDeny).ToBe(True);
  Expect<Boolean>(O.Destination.RequireHTTPS).ToBe(True);

  O := Options(Dep(skURL, hkGitHub, '',
    'https://artifacts.example/lib.tar.gz'), nil);
  Expect<Integer>(Length(O.Destination.AllowedHosts)).ToBe(0);
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papDeny).ToBe(True);
  Expect<Boolean>(O.Destination.RequireHTTPS).ToBe(True);
end;

procedure TFetchPolicySuite.TestLocalSourcesKeepBaseOptions;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skLocal, hkGitHub, '', './vendor/x'), nil);
  Expect<Integer>(Length(O.Destination.AllowedHosts)).ToBe(0);
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papAllow).ToBe(True);
  Expect<Boolean>(O.Destination.RequireHTTPS).ToBe(False);
  O := Options(Dep(skWorkspace, hkGitHub, '', ''), nil);
  Expect<Boolean>(O.Destination.PrivateAddressPolicy = papAllow).ToBe(True);
end;

procedure TFetchPolicySuite.TestUndeclaredCustomSourceIsAnError;
var Message: string;
begin
  Message := '';
  try
    Options(Dep(skGitHost, hkCustom, 'missing', 'owner/repo'), nil);
  except
    on E: EManifestError do Message := E.Message;
  end;
  Expect<Boolean>(Pos('no [sources.missing] table', Message) > 0)
    .ToBe(True);
end;

procedure TFetchPolicySuite.TestGitHostRefListingRefusesForeignHost;
var
  Mock: TMockHTTPServer;
  Message: string;
begin
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(nil));
  try
    Mock.Start;
    Message := '';
    try
      ListRemoteRefs('https://127.0.0.1:' + IntToStr(Mock.Port)
        + '/owner/repo.git', Options(Dep(skGitHost, hkGitHub, '',
        'owner/repo'), nil));
    except
      on E: EHTTPError do Message := E.Message;
    end;
    Expect<string>(Message).ToBe('fetch host not allowed: 127.0.0.1');
    Expect<Boolean>(Mock.WaitDone(200)).ToBe(False);
  finally
    Mock.Free;
  end;
end;

procedure TFetchPolicySuite.TestPlaintextDependencyRequestIsRefused;
var
  Mock: TMockHTTPServer;
begin
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(nil));
  try
    Mock.Start;
    Expect<string>(GetError('http://127.0.0.1:' + IntToStr(Mock.Port)
      + '/lib.tar.gz', Options(Dep(skURL, hkGitHub, '',
      'https://127.0.0.1/lib.tar.gz'), nil))).ToBe(
      'fetch scheme not allowed: http://127.0.0.1 (https is required)');
    Expect<Boolean>(Mock.WaitDone(200)).ToBe(False);
  finally
    Mock.Free;
  end;
end;

procedure TFetchPolicySuite.TestCustomSourceRedirectOffTemplateHostsIsRefused;
const
  CRLF = #13#10;
var
  Origin, Target: TMockHTTPServer;
  O: THTTPRequestOptions;
  Base: string;
begin
  Target := TMockHTTPServer.Create(BuildSimpleResponse(BytesOf('tarball')));
  try
    Target.Start;
    Origin := TMockHTTPServer.Create(BytesOf('HTTP/1.1 302 Found' + CRLF
      + 'Location: http://localhost:' + IntToStr(Target.Port) + '/x' + CRLF
      + 'Content-Length: 0' + CRLF + 'Connection: close' + CRLF + CRLF));
    try
      Origin.Start;
      Base := 'http://127.0.0.1:' + IntToStr(Origin.Port);
      O := Options(Dep(skGitHost, hkCustom, 'forge', 'owner/repo'),
        MockSources(Origin.Port));
      { The mock servers are plaintext loopback endpoints; only the host
        rule is under test here. }
      O.Destination.RequireHTTPS := False;
      O.Destination.PrivateAddressPolicy := papAllow;
      O.RequestTimeoutMilliseconds := 2000;
      Expect<string>(GetError(Base + '/owner/repo/v1.tar.gz', O))
        .ToBe('fetch host not allowed: localhost');
      Expect<Boolean>(Origin.WaitDone(2000)).ToBe(True);
      Expect<Boolean>(Target.WaitDone(200)).ToBe(False);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure TFetchPolicySuite.
  TestCustomSourceAndDirectURLCannotReachPrivateAddress;
var
  Mock: TMockHTTPServer;
begin
  Mock := TMockHTTPServer.Create(BuildSimpleResponse(nil));
  try
    Mock.Start;
    Expect<string>(GetError('https://127.0.0.1:' + IntToStr(Mock.Port)
      + '/owner/repo.git/info/refs',
      Options(Dep(skGitHost, hkCustom, 'forge', 'owner/repo'),
      MockSources(Mock.Port)))).ToBe(
      'fetch destination not allowed: 127.0.0.1 resolves to loopback '
      + 'address 127.0.0.1');
    Expect<string>(GetError('https://127.0.0.1:' + IntToStr(Mock.Port)
      + '/lib.tar.gz', Options(Dep(skURL, hkGitHub, '',
      'https://127.0.0.1/lib.tar.gz'), nil))).ToBe(
      'fetch destination not allowed: 127.0.0.1 resolves to loopback '
      + 'address 127.0.0.1');
    Expect<Boolean>(Mock.WaitDone(200)).ToBe(False);
  finally
    Mock.Free;
  end;
end;

procedure TFetchPolicySuite.SetupTests;
begin
  Test('built-in forges allow only their hosts and deny private space',
    TestBuiltInForgesAllowOnlyTheirHostsAndDenyPrivate);
  Test('built-in forge origins are defined once', TestBuiltInForgeOrigins);
  Test('custom sources allow the hosts their templates name',
    TestCustomSourceAllowsTemplateHosts);
  Test('custom sources and direct URLs require https and deny private space',
    TestCustomSourcesAndDirectURLsDenyPrivateAddresses);
  Test('local and workspace sources keep the base options',
    TestLocalSourcesKeepBaseOptions);
  Test('an undeclared custom source is a manifest error',
    TestUndeclaredCustomSourceIsAnError);
  Test('git-host ref listing refuses a host its forge does not own',
    TestGitHostRefListingRefusesForeignHost);
  Test('a plaintext dependency request is refused before connecting',
    TestPlaintextDependencyRequestIsRefused);
  Test('a redirect off a custom source''s template hosts is refused',
    TestCustomSourceRedirectOffTemplateHostsIsRefused);
  Test('a custom source or direct URL cannot reach a private address',
    TestCustomSourceAndDirectURLCannotReachPrivateAddress);
end;

begin
  TestRunnerProgram.AddSuite(TFetchPolicySuite.Create(
    'fetch policy: dependency destinations'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
