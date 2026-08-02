unit LWPT.GitProtocol;

{$I Shared.inc}
{$modeswitch nestedcomments+}

{ LWPT.GitProtocol — list remote refs (tags + branches) via the git
  smart-HTTP transport's `info/refs?service=git-upload-pack` endpoint.

  Why this and not a host API (GitHub/GitLab/Bitbucket each have
  their own /tags JSON endpoint): the smart-HTTP path works against
  ANY git host with one URL pattern + one wire format, including
  self-hosted Gitea/Gogs/Forgejo/Bitbucket Server. No JSON parsing,
  no rate-limit auth tokens for public repos, no host-specific
  field-naming gotchas.

  Wire format (pkt-line, RFC: gitprotocol-http + gitprotocol-pack):

    Each "packet" is prefixed with a 4-byte ASCII hex length that
    INCLUDES the 4 prefix bytes themselves. So `001e<26 bytes>`
    means a 30-byte total packet with 26 bytes of payload. The
    special length `0000` is the "flush" packet (end-of-section).

    Response for info/refs?service=git-upload-pack looks like:

      001e# service=git-upload-pack\n
      0000
      00d8<sha> HEAD\0capability1 capability2 ...\n
      0040<sha> refs/heads/main\n
      003e<sha> refs/tags/v1.0.0\n
      0042<sha> refs/tags/v1.0.0^{}\n      <- "peeled" annotated tag
      ...
      0000

    Some servers skip the service-announce header packet + its
    flush — we tolerate both shapes by detecting and skipping the
    leading "# service=..." line if present.

  Filters:
    refs/tags/<name>   → tag entry (Kind = rkTag)
    refs/heads/<name>  → branch entry (Kind = rkBranch)
    ^{} peel suffix    → attached to the tag as PeeledSHA (the
                         underlying commit identity advertised by Git)
    HEAD               → ignored (not a useful target for fetches) }

interface

uses
  Classes,
  StrUtils,
  SysUtils,

  HTTPClient;

type
  TGitRefKind = (rkTag, rkBranch);

  TGitRef = record
    Kind : TGitRefKind;
    Name : string;     { tag name or branch name (no refs/tags/ prefix) }
    SHA  : string;     { 40-char ref object hash }
    PeeledSHA : string; { annotated-tag target commit; otherwise empty }
  end;

  TGitRefArray = array of TGitRef;

  EGitProtocolError = class(Exception);

{ Hit <ARepoURL>/info/refs?service=git-upload-pack and parse the
  pkt-line response into the ref list. ARepoURL must end in `.git`
  (the standard git-host convention); callers in LWPT.Core build
  the URL via GitRepoURL which appends `.git`. }
function ListRemoteRefs(const ARepoURL: string): TGitRefArray;

{ Lower-level: parse a raw pkt-line stream into refs. Exposed for
  unit tests that feed a captured info/refs fixture without going
  over the network. }
function ParseInfoRefs(const APayload: string): TGitRefArray;

implementation

const
  PKT_PREFIX_LEN = 4;

function FixtureRepositoryName(const ARepoURL: string): string;
var URL: string; Slash: Integer;
begin
  URL := ARepoURL;
  if Copy(URL, Length(URL) - 3, 4) = '.git' then
    SetLength(URL, Length(URL) - 4);
  Slash := LastDelimiter('/', URL);
  if Slash > 0 then
    Result := Copy(URL, Slash + 1, MaxInt)
  else
    Result := URL;
end;

procedure AppendFixtureRequest(const ARoot, ALine: string);
var Stream: TFileStream; Bytes: RawByteString; Path: string;
begin
  Path := IncludeTrailingPathDelimiter(ARoot) + 'requests.log';
  ForceDirectories(ExtractFileDir(Path));
  if FileExists(Path) then
    Stream := TFileStream.Create(Path, fmOpenReadWrite or fmShareDenyNone)
  else
    Stream := TFileStream.Create(Path, fmCreate or fmShareDenyNone);
  try
    Stream.Seek(0, soEnd);
    Bytes := RawByteString(ALine + LineEnding);
    if Length(Bytes) > 0 then Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

function LoadFixtureRefs(const ARoot, ARepoURL: string): TGitRefArray;
var Lines: TStringList; Path, Line: string; i, p1, p2, p3, n: Integer;
begin
  Path := IncludeTrailingPathDelimiter(ARoot) + 'refs/'
    + FixtureRepositoryName(ARepoURL) + '.refs';
  if not FileExists(Path) then
    raise EGitProtocolError.CreateFmt(
      'test git fixture has no ref advertisement for %s (%s)',
      [ARepoURL, Path]);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    SetLength(Result, 0);
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if (Line = '') or (Line[1] = '#') then Continue;
      p1 := Pos('|', Line);
      p2 := PosEx('|', Line, p1 + 1);
      p3 := PosEx('|', Line, p2 + 1);
      if (p1 <= 1) or (p2 <= p1 + 1) or (p3 <= p2 + 1) then
        raise EGitProtocolError.CreateFmt(
          'invalid test ref fixture line in %s: %s', [Path, Line]);
      n := Length(Result);
      SetLength(Result, n + 1);
      if Copy(Line, 1, p1 - 1) = 'tag' then
        Result[n].Kind := rkTag
      else if Copy(Line, 1, p1 - 1) = 'branch' then
        Result[n].Kind := rkBranch
      else
        raise EGitProtocolError.CreateFmt(
          'invalid test ref kind in %s: %s', [Path, Line]);
      Result[n].Name := Copy(Line, p1 + 1, p2 - p1 - 1);
      Result[n].SHA := Copy(Line, p2 + 1, p3 - p2 - 1);
      Result[n].PeeledSHA := Copy(Line, p3 + 1, MaxInt);
    end;
  finally
    Lines.Free;
  end;
  AppendFixtureRequest(ARoot,
    'refs|' + FixtureRepositoryName(ARepoURL));
end;

function HexCharToInt(C: AnsiChar): Integer; inline;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := 10 + Ord(C) - Ord('a');
    'A'..'F': Result := 10 + Ord(C) - Ord('A');
  else
    Result := -1;
  end;
end;

function ReadPktLength(const ABuf: string; AOffset: Integer;
  out ALen: Integer): Boolean;
var i, D: Integer;
begin
  Result := False;
  ALen := 0;
  if AOffset + PKT_PREFIX_LEN - 1 > Length(ABuf) then Exit;
  for i := 0 to PKT_PREFIX_LEN - 1 do
  begin
    D := HexCharToInt(ABuf[AOffset + i]);
    if D < 0 then Exit;
    ALen := (ALen shl 4) or D;
  end;
  Result := True;
end;

function ParsePktLine(const APayload: string;
  out AParts: TStringArray): Boolean;
begin
  { Reserved for future use; not needed in v1. }
  Result := False;
  SetLength(AParts, 0);
  if APayload = '' then;
end;

function StripTrailingNewline(const S: string): string;
begin
  Result := S;
  while (Length(Result) > 0) and
        ((Result[Length(Result)] = #10) or (Result[Length(Result)] = #13)) do
    SetLength(Result, Length(Result) - 1);
end;

function ParseRefLine(const APayload: string; out AOut: TGitRef): Boolean;
const PREFIX_TAG    = 'refs/tags/';
      PREFIX_BRANCH = 'refs/heads/';
var
  Trimmed, RestAfterSha, RefName : string;
  SpacePos, NulPos : Integer;
begin
  Result := False;
  AOut := Default(TGitRef);
  Trimmed := StripTrailingNewline(APayload);
  if Length(Trimmed) < 41 then Exit;   { sha + space + at least 1 }

  SpacePos := Pos(' ', Trimmed);
  if (SpacePos <> 41) then Exit;
  AOut.SHA := Copy(Trimmed, 1, 40);
  RestAfterSha := Copy(Trimmed, SpacePos + 1, MaxInt);

  { The FIRST ref line carries capabilities after a NUL byte. Strip
    them — we only care about the ref name. }
  NulPos := Pos(#0, RestAfterSha);
  if NulPos > 0 then
    RefName := Copy(RestAfterSha, 1, NulPos - 1)
  else
    RefName := RestAfterSha;

  if (Length(RefName) > Length(PREFIX_TAG)) and
     (Copy(RefName, 1, Length(PREFIX_TAG)) = PREFIX_TAG) then
  begin
    AOut.Kind := rkTag;
    AOut.Name := Copy(RefName, Length(PREFIX_TAG) + 1, MaxInt);
    Result := True;
    Exit;
  end;

  if (Length(RefName) > Length(PREFIX_BRANCH)) and
     (Copy(RefName, 1, Length(PREFIX_BRANCH)) = PREFIX_BRANCH) then
  begin
    AOut.Kind := rkBranch;
    AOut.Name := Copy(RefName, Length(PREFIX_BRANCH) + 1, MaxInt);
    Result := True;
    Exit;
  end;
end;

function ParseInfoRefs(const APayload: string): TGitRefArray;
var
  Offset, PktLen, BodyLen, N, i: Integer;
  PktBody: string;
  Ref: TGitRef;
  PeeledName: string;
begin
  SetLength(Result, 0);
  Offset := 1;
  N := 0;
  while Offset <= Length(APayload) do
  begin
    if not ReadPktLength(APayload, Offset, PktLen) then Break;
    if PktLen = 0 then
    begin
      { flush packet — section boundary. Advance past it and keep
        reading; there may be a second section. }
      Inc(Offset, PKT_PREFIX_LEN);
      Continue;
    end;
    if PktLen < PKT_PREFIX_LEN then Break;
    BodyLen := PktLen - PKT_PREFIX_LEN;
    if Offset + PktLen - 1 > Length(APayload) then Break;
    PktBody := Copy(APayload, Offset + PKT_PREFIX_LEN, BodyLen);
    Inc(Offset, PktLen);

    { Skip the service-announce line and HEAD. }
    if (Length(PktBody) >= 1) and (PktBody[1] = '#') then Continue;

    if ParseRefLine(PktBody, Ref) then
    begin
      if (Ref.Kind = rkTag) and (Length(Ref.Name) > 3)
         and (Copy(Ref.Name, Length(Ref.Name) - 2, 3) = '^{}') then
      begin
        PeeledName := Copy(Ref.Name, 1, Length(Ref.Name) - 3);
        for i := 0 to High(Result) do
          if (Result[i].Kind = rkTag) and (Result[i].Name = PeeledName) then
          begin
            Result[i].PeeledSHA := Ref.SHA;
            Break;
          end;
        Continue;
      end;
      SetLength(Result, N + 1);
      Result[N] := Ref;
      Inc(N);
    end;
  end;
end;

function ListRemoteRefs(const ARepoURL: string): TGitRefArray;
var
  URL : string;
  FixtureRoot: string;
  Resp : THTTPResponse;
  Headers : THTTPHeaders;
  Body : string;
  i : Integer;
begin
  if ARepoURL = '' then
    raise EGitProtocolError.Create('ListRemoteRefs: empty repo URL');

  FixtureRoot := GetEnvironmentVariable('LWPT_TEST_GIT_FIXTURE_DIR');
  if FixtureRoot <> '' then
    Exit(LoadFixtureRefs(FixtureRoot, ARepoURL));

  URL := ARepoURL;
  if Pos('?', URL) > 0 then
    URL := URL + '&service=git-upload-pack'
  else
    URL := URL + '/info/refs?service=git-upload-pack';

  { Smart-HTTP v0 negotiation: the Accept header is conventional but
    not strictly required. Servers that DO check it return v2 protocol
    if absent (different framing). Sending the legacy v0 accept keeps
    the response in pkt-line form regardless. }
  SetLength(Headers, 2);
  Headers[0].Name  := 'Accept';
  Headers[0].Value := 'application/x-git-upload-pack-advertisement';
  Headers[1].Name  := 'Git-Protocol';
  Headers[1].Value := 'version=1';   { force v1 framing }
  Resp := HTTPGet(URL, Headers);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    raise EGitProtocolError.CreateFmt(
      'ListRemoteRefs %s: HTTP %d %s',
      [URL, Resp.StatusCode, Resp.StatusText]);

  { TBytes -> string byte-perfect copy; the body is binary-ish
    (pkt-line is ASCII-only in the length prefix + ref payload, but
    can have NULs as field separators). }
  SetLength(Body, Length(Resp.Body));
  for i := 0 to High(Resp.Body) do
    Body[i + 1] := AnsiChar(Resp.Body[i]);

  Result := ParseInfoRefs(Body);
end;

end.
