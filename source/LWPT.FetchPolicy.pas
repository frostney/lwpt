{ LWPT.FetchPolicy — destination policy for dependency fetches.

  Every network request made on behalf of a dependency (ref listing and
  archive download) carries an HTTPClient destination policy derived from the
  dependency's declared source. The policy is checked on the initial request
  and on every redirect hop, so a fetch cannot be steered to a host the
  source does not name, or from the public internet into a private network.

    Built-in git hosts   Only the forge's own hosts (GitHub archives redirect
                         from github.com to codeload.github.com). Every hop
                         must resolve to a public address.
    Custom [sources]     Only the hosts named by the source's archive and git
                         templates. A self-hosted forge on a private network
                         keeps working; a request that has reached a public
                         address cannot be redirected into private space.
    Direct URL           Any host (the manifest author named it), with the
                         same public-to-private redirect refusal.
    Local / workspace    No network; the base options are returned unchanged.
}
unit LWPT.FetchPolicy;

{$I Shared.inc}

interface

uses
  HTTPClient,
  LWPT.Manifest;

const
  GITHUB_HOST          = 'github.com';
  GITHUB_ARCHIVE_HOST  = 'codeload.github.com';
  GITLAB_HOST          = 'gitlab.com';
  BITBUCKET_HOST       = 'bitbucket.org';

{ ABase with ADep's destination policy applied. Raises EManifestError when a
  custom source is undeclared or its templates carry no host. }
function DependencyFetchOptions(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  const ABase: THTTPRequestOptions): THTTPRequestOptions;

{ Lowercased host of an absolute URL ('' when it has none): userinfo, port,
  path, query and IPv6 brackets are stripped. }
function URLHost(const AURL: string): string;

implementation

uses
  SysUtils,

  LWPT.Core;

function URLHost(const AURL: string): string;
var
  SchemeEnd, i: Integer;
  Authority: string;
begin
  Result := '';
  SchemeEnd := Pos('://', AURL);
  if SchemeEnd <= 1 then Exit;
  Authority := Copy(AURL, SchemeEnd + 3, MaxInt);
  for i := 1 to Length(Authority) do
    if Authority[i] in ['/', '?', '#'] then
    begin
      Authority := Copy(Authority, 1, i - 1);
      Break;
    end;
  i := LastDelimiter('@', Authority);
  if i > 0 then Authority := Copy(Authority, i + 1, MaxInt);
  if (Authority <> '') and (Authority[1] = '[') then
  begin
    i := Pos(']', Authority);
    if i = 0 then Exit;
    Exit(LowerCase(Copy(Authority, 2, i - 2)));
  end;
  i := Pos(':', Authority);
  if i > 0 then Authority := Copy(Authority, 1, i - 1);
  Result := LowerCase(Authority);
end;

procedure AddHost(var AHosts: TStringArray; const AHost: string);
var i: Integer;
begin
  if AHost = '' then Exit;
  for i := 0 to High(AHosts) do
    if SameText(AHosts[i], AHost) then Exit;
  SetLength(AHosts, Length(AHosts) + 1);
  AHosts[High(AHosts)] := AHost;
end;

// A template's host may itself carry the user or repository placeholder, so
// render the placeholders from the dependency's locator before extracting it.
function TemplateHost(const ATemplate, ALocator: string): string;
var Slash: Integer; User, Repository, Rendered: string;
begin
  Slash := Pos('/', ALocator);
  if Slash > 0 then
  begin
    User := Copy(ALocator, 1, Slash - 1);
    Repository := Copy(ALocator, Slash + 1, MaxInt);
  end
  else
  begin
    User := ALocator;
    Repository := '';
  end;
  Rendered := StringReplace(ATemplate, PLACEHOLDER_USER, User,
    [rfReplaceAll]);
  Rendered := StringReplace(Rendered, PLACEHOLDER_REPOSITORY, Repository,
    [rfReplaceAll]);
  Rendered := StringReplace(Rendered, PLACEHOLDER_REF, '', [rfReplaceAll]);
  Result := URLHost(Rendered);
end;

function DependencyFetchOptions(const ADep: TDependency;
  const ACustomSources: TCustomSourceArray;
  const ABase: THTTPRequestOptions): THTTPRequestOptions;
var
  Custom: TCustomSource;
  Hosts: TStringArray;
begin
  Result := ABase;
  Hosts := nil;
  case ADep.SrcKind of
    skGitHost:
      case ADep.SrcHost of
        hkGitHub:
        begin
          AddHost(Hosts, GITHUB_HOST);
          AddHost(Hosts, GITHUB_ARCHIVE_HOST);
          Result.Destination.PrivateAddresses := papDeny;
        end;
        hkGitLab:
        begin
          AddHost(Hosts, GITLAB_HOST);
          Result.Destination.PrivateAddresses := papDeny;
        end;
        hkBitbucket:
        begin
          AddHost(Hosts, BITBUCKET_HOST);
          Result.Destination.PrivateAddresses := papDeny;
        end;
        hkCustom:
        begin
          if not FindCustomSource(ACustomSources, ADep.SrcHostName,
               Custom) then
            raise EManifestError.CreateFmt(
              'dependency "%s" uses custom prefix "%s:" but no [sources.%s] '
              + 'table is declared in %s', [ADep.Name, ADep.SrcHostName,
              ADep.SrcHostName, MANIFEST_FILE]);
          AddHost(Hosts, TemplateHost(Custom.ArchiveTemplate,
            ADep.SrcLocator));
          AddHost(Hosts, TemplateHost(Custom.GitTemplate, ADep.SrcLocator));
          if Length(Hosts) = 0 then
            raise EManifestError.CreateFmt(
              'dependency "%s": [sources.%s] templates name no host',
              [ADep.Name, ADep.SrcHostName]);
          Result.Destination.PrivateAddresses := papDenyAfterPublic;
        end;
      end;
    skURL:
      Result.Destination.PrivateAddresses := papDenyAfterPublic;
  else
    Exit;
  end;
  Result.Destination.AllowedHosts := Hosts;
end;

end.
