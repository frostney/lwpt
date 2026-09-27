{ LWPT.FetchPolicy — built-in forge origins and the destination policy for
  dependency fetches (ADR-0045).

  Every network request made on behalf of a dependency (ref listing and
  archive download) carries an HTTPClient destination policy derived from the
  dependency's declared source. The policy is checked on the initial request
  and on every redirect hop: every hop must use https, may reach only the
  hosts the source names, and must resolve to a globally reachable address.

    Built-in forge       Only the forge's own hosts (GitHub archives redirect
                         from github.com to codeload.github.com).
    Custom [sources]     Only the hosts named by the source's archive and git
                         templates.
    Direct URL           Any host.

  The address rule has no exception, whichever manifest declares the source:
  a fetched package cannot pivot LWPT into the user's network, and
  self-hosted forges on private networks are currently unsupported. Local and
  workspace sources make no request. }
unit LWPT.FetchPolicy;

{$I Shared.inc}

interface

uses
  HTTPClient,
  LWPT.Manifest;

{ Base https URL of a built-in forge, ending in '/': the repository is
  <origin><owner/repo>.git and every archive URL starts with the origin.
  '' for hkCustom. }
function BuiltInForgeOrigin(const AHost: THostKind): string;

{ ABase with ADep's destination policy applied. Raises EManifestError when a
  custom source is undeclared or its templates do not parse as https URLs. }
function DependencyFetchOptions(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  const ABase: THTTPRequestOptions): THTTPRequestOptions;

implementation

uses
  SysUtils,

  LWPT.Core;

type
  TBuiltInForge = record
    Origin: string;
    { A host the forge redirects archive downloads to; '' when none. }
    ArchiveRedirectHost: string;
  end;

const
  BuiltInForges: array[hkGitHub..hkBitbucket] of TBuiltInForge = (
    (Origin: 'https://github.com/'; ArchiveRedirectHost: 'codeload.github.com'),
    (Origin: 'https://gitlab.com/'; ArchiveRedirectHost: ''),
    (Origin: 'https://bitbucket.org/'; ArchiveRedirectHost: '')
  );

function BuiltInForgeOrigin(const AHost: THostKind): string;
begin
  if AHost = hkCustom then
    Exit('');
  Result := BuiltInForges[AHost].Origin;
end;

procedure AddHost(var AHosts: TStringArray; const AHost: string);
var HostIndex: Integer;
begin
  if AHost = '' then Exit;
  for HostIndex := 0 to High(AHosts) do
    if SameText(AHosts[HostIndex], AHost) then Exit;
  SetLength(AHosts, Length(AHosts) + 1);
  AHosts[High(AHosts)] := AHost;
end;

{ The host a custom-source template names for ADep. The user and repository
  placeholders may sit in the host, so they are rendered from the locator
  first; manifest validation keeps the ref placeholder out of the host. }
function TemplateHost(const ADep: TDependency; const ASourceName,
  ATemplate: string): string;
var SlashAt: Integer; User, Repository, Rendered: string;
begin
  SlashAt := Pos('/', ADep.SrcLocator);
  if SlashAt > 0 then
  begin
    User := Copy(ADep.SrcLocator, 1, SlashAt - 1);
    Repository := Copy(ADep.SrcLocator, SlashAt + 1, MaxInt);
  end
  else
  begin
    User := ADep.SrcLocator;
    Repository := '';
  end;
  Rendered := StringReplace(ATemplate, PLACEHOLDER_USER, User,
    [rfReplaceAll]);
  Rendered := StringReplace(Rendered, PLACEHOLDER_REPOSITORY, Repository,
    [rfReplaceAll]);
  Rendered := StringReplace(Rendered, PLACEHOLDER_REF, '', [rfReplaceAll]);
  try
    Result := HTTPURLHost(Rendered);
  except
    on E: EHTTPError do
      raise EManifestError.CreateFmt(
        'dependency "%s": [sources.%s] template "%s" is not a valid URL: %s',
        [ADep.Name, ASourceName, ATemplate, E.Message]);
  end;
end;

function DependencyFetchOptions(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  const ABase: THTTPRequestOptions): THTTPRequestOptions;
var
  Custom: TCustomSource;
  Hosts: TStringArray;
begin
  Result := ABase;
  if not (ADep.SrcKind in [skGitHost, skURL]) then
    Exit;
  Hosts := nil;
  if (ADep.SrcKind = skGitHost) and (ADep.SrcHost = hkCustom) then
  begin
    if not FindCustomSource(ACustomSources, ADep.SrcHostName, Custom) then
      raise EManifestError.CreateFmt(
        'dependency "%s" uses custom prefix "%s:" but no [sources.%s] '
        + 'table is declared in %s', [ADep.Name, ADep.SrcHostName,
        ADep.SrcHostName, MANIFEST_FILE]);
    AddHost(Hosts, TemplateHost(ADep, Custom.Name, Custom.ArchiveTemplate));
    AddHost(Hosts, TemplateHost(ADep, Custom.Name, Custom.GitTemplate));
  end
  else if ADep.SrcKind = skGitHost then
  begin
    AddHost(Hosts, HTTPURLHost(BuiltInForges[ADep.SrcHost].Origin));
    AddHost(Hosts, BuiltInForges[ADep.SrcHost].ArchiveRedirectHost);
  end;
  { Direct URLs keep an empty allowlist: the manifest names any host. }
  Result.Destination.AllowedHosts := Hosts;
  Result.Destination.PrivateAddressPolicy := papDeny;
  Result.Destination.RequireHTTPS := True;
end;

end.
