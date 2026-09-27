{ LWPT.FetchPolicy.Test — dependency fetch destination policy (#303).

  Pins which hosts and address policy each source kind carries, then drives
  the policy end to end through the real ref-listing and HTTP paths against
  loopback mock servers: a git-host request aimed at a host its forge does
  not own is refused before connecting, and a redirect off a custom source's
  declared hosts is refused before the redirect target is contacted. }
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
    procedure TestBuiltInHostsAllowOnlyTheirForgeAndDenyPrivate;
    procedure TestCustomSourceAllowsTemplateHosts;
    procedure TestDirectURLAllowsAnyHostButNotPublicToPrivate;
    procedure TestLocalSourcesKeepBaseOptions;
    procedure TestUndeclaredCustomSourceIsAnError;
    procedure TestURLHostExtraction;
    procedure TestGitHostRefListingRefusesForeignHost;
    procedure TestCustomSourceRedirectOffTemplateHostsIsRefused;
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
var i: Integer;
begin
  Result := '';
  for i := 0 to High(AOptions.Destination.AllowedHosts) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + AOptions.Destination.AllowedHosts[i];
  end;
end;

function Options(const ADep: TDependency;
  const ASources: TCustomSourceArray): THTTPRequestOptions;
begin
  Result := DependencyFetchOptions(ADep, ASources,
    DefaultHTTPRequestOptions);
end;

procedure TFetchPolicySuite.TestBuiltInHostsAllowOnlyTheirForgeAndDenyPrivate;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skGitHost, hkGitHub, '', 'owner/repo'), nil);
  Expect<string>(HostList(O)).ToBe('github.com,codeload.github.com');
  Expect<Boolean>(O.Destination.PrivateAddresses = papDeny).ToBe(True);

  O := Options(Dep(skGitHost, hkGitLab, '', 'group/repo'), nil);
  Expect<string>(HostList(O)).ToBe('gitlab.com');
  Expect<Boolean>(O.Destination.PrivateAddresses = papDeny).ToBe(True);

  O := Options(Dep(skGitHost, hkBitbucket, '', 'team/repo'), nil);
  Expect<string>(HostList(O)).ToBe('bitbucket.org');
  Expect<Boolean>(O.Destination.PrivateAddresses = papDeny).ToBe(True);
end;

procedure TFetchPolicySuite.TestCustomSourceAllowsTemplateHosts;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skGitHost, hkCustom, 'forge', 'owner/repo'),
    Sources('forge',
      'https://Downloads.Example.com:8443/{user}/{repository}/{ref}.tar.gz',
      'https://git.example.com/{user}/{repository}.git'));
  Expect<string>(HostList(O))
    .ToBe('downloads.example.com,git.example.com');
  Expect<Boolean>(O.Destination.PrivateAddresses = papDenyAfterPublic)
    .ToBe(True);

  { A per-user host is rendered from the locator before it is allowed. }
  O := Options(Dep(skGitHost, hkCustom, 'pages', 'alice/repo'),
    Sources('pages',
      'https://{user}.pages.example/{repository}/{ref}.tar.gz',
      'https://{user}.pages.example/{repository}.git'));
  Expect<string>(HostList(O)).ToBe('alice.pages.example');
end;

procedure TFetchPolicySuite.TestDirectURLAllowsAnyHostButNotPublicToPrivate;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skURL, hkGitHub, '',
    'https://artifacts.example/lib.tar.gz'), nil);
  Expect<Integer>(Length(O.Destination.AllowedHosts)).ToBe(0);
  Expect<Boolean>(O.Destination.PrivateAddresses = papDenyAfterPublic)
    .ToBe(True);
end;

procedure TFetchPolicySuite.TestLocalSourcesKeepBaseOptions;
var O: THTTPRequestOptions;
begin
  O := Options(Dep(skLocal, hkGitHub, '', './vendor/x'), nil);
  Expect<Integer>(Length(O.Destination.AllowedHosts)).ToBe(0);
  Expect<Boolean>(O.Destination.PrivateAddresses = papAllow).ToBe(True);
  O := Options(Dep(skWorkspace, hkGitHub, '', ''), nil);
  Expect<Boolean>(O.Destination.PrivateAddresses = papAllow).ToBe(True);
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

procedure TFetchPolicySuite.TestURLHostExtraction;
begin
  Expect<string>(URLHost('https://GitHub.com/owner/repo.git')).ToBe(
    'github.com');
  Expect<string>(URLHost('https://user:pw@host.example:8443/x?y#z')).ToBe(
    'host.example');
  Expect<string>(URLHost('http://127.0.0.1:9/')).ToBe('127.0.0.1');
  Expect<string>(URLHost('https://[::1]:443/x')).ToBe('::1');
  Expect<string>(URLHost('https://host.example')).ToBe('host.example');
  Expect<string>(URLHost('not a url')).ToBe('');
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
      ListRemoteRefs('http://127.0.0.1:' + IntToStr(Mock.Port)
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

procedure TFetchPolicySuite.TestCustomSourceRedirectOffTemplateHostsIsRefused;
const
  CRLF = #13#10;
var
  Origin, Target: TMockHTTPServer;
  O: THTTPRequestOptions;
  NoHeaders: THTTPHeaders;
  Message, Base: string;
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
        Sources('forge', Base + '/{user}/{repository}/{ref}.tar.gz',
          Base + '/{user}/{repository}.git'));
      O.RequestTimeoutMilliseconds := 2000;
      NoHeaders := nil;
      Message := '';
      try
        HTTPGet(Base + '/owner/repo/v1.tar.gz', NoHeaders, O);
      except
        on E: EHTTPError do Message := E.Message;
      end;
      Expect<Boolean>(Origin.WaitDone(2000)).ToBe(True);
      Expect<string>(Message).ToBe('fetch host not allowed: localhost');
      Expect<Boolean>(Target.WaitDone(200)).ToBe(False);
    finally
      Origin.Free;
    end;
  finally
    Target.Free;
  end;
end;

procedure TFetchPolicySuite.SetupTests;
begin
  Test('built-in git hosts allow only their forge and deny private space',
    TestBuiltInHostsAllowOnlyTheirForgeAndDenyPrivate);
  Test('custom sources allow the hosts their templates name',
    TestCustomSourceAllowsTemplateHosts);
  Test('direct URLs allow any host but refuse public-to-private redirects',
    TestDirectURLAllowsAnyHostButNotPublicToPrivate);
  Test('local and workspace sources keep the base options',
    TestLocalSourcesKeepBaseOptions);
  Test('an undeclared custom source is a manifest error',
    TestUndeclaredCustomSourceIsAnError);
  Test('URL hosts are extracted without userinfo, port, or brackets',
    TestURLHostExtraction);
  Test('git-host ref listing refuses a host its forge does not own',
    TestGitHostRefListingRefusesForeignHost);
  Test('a redirect off a custom source''s template hosts is refused',
    TestCustomSourceRedirectOffTemplateHostsIsRefused);
end;

begin
  TestRunnerProgram.AddSuite(TFetchPolicySuite.Create(
    'fetch policy: dependency destinations'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
