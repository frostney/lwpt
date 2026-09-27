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
    HEAD               → ignored (not a useful target for fetches)

  Commit reachability (ADR-0045). A commit-SHA pin is accepted only when the
  commit is reachable from an advertised refs/heads/* or refs/tags/* tip.
  ProveCommitReachable first compares the pin with the advertised tips
  (no extra request). Otherwise it speaks protocol v2 over the same
  smart-HTTP endpoint:

    GET  <repo>/info/refs?service=git-upload-pack   capability advertisement
    POST <repo>/git-upload-pack  command=ls-refs    tips, peeled, HEAD target
    POST <repo>/git-upload-pack  command=fetch      commits-only packs

  Every fetch sends `filter tree:0` and never `thin-pack`, so the host
  returns only commits and every delta base is in the pack. With
  `want <tip>` and `have <pin>` the host sends exactly the commits reachable
  from the tip but not from the pin; LWPT.GitPack recomputes their ids and
  the pin is reachable iff one of them lists it as a parent. Archives remain
  the only source of dependency content: no tree or blob is ever requested
  or accepted. }

interface

uses
  Classes,
  StrUtils,
  SysUtils,

  HTTPClient,
  LWPT.Core,
  LWPT.GitPack;

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
  { A reachability proof could not be completed: the host lacks a required
    protocol feature, a response was malformed, or a limit was hit. The pin
    is neither accepted nor declared unreachable. }
  EGitReachabilityError = class(EGitProtocolError);
  EGitResponseTooLarge = class(EGitReachabilityError);

  { Transport for the smart-HTTP upload-pack service. Implementations must
    refuse any response larger than their byte cap with
    EGitResponseTooLarge rather than truncating it. }
  TGitUploadPackTransport = class
  public
    { Protocol v2 capability advertisement. AEffectiveRepoURL is the
      repository URL that later commands must use (it differs from
      ARepoURL when the advertisement request was redirected). }
    function Advertise(const ARepoURL: string;
      out AEffectiveRepoURL: string): TBytes; virtual; abstract;
    { One protocol v2 command request; returns the raw response body. }
    function Command(const ARepoURL: string;
      const ARequest: TBytes): TBytes; virtual; abstract;
  end;

  THTTPGitUploadPackTransport = class(TGitUploadPackTransport)
  private
    FOptions: THTTPRequestOptions;
    FMaxResponseBytes: Int64;
  public
    { AOptions carries the dependency's destination policy; the transport
      sets the response cap (AMaxResponseBytes, default
      MAX_UPLOAD_PACK_RESPONSE_BYTES) and the request timeout. }
    constructor Create(const AOptions: THTTPRequestOptions;
      AMaxResponseBytes: Int64 = 0);
    function Advertise(const ARepoURL: string;
      out AEffectiveRepoURL: string): TBytes; override;
    function Command(const ARepoURL: string;
      const ARequest: TBytes): TBytes; override;
  end;

  {$IFDEF INSTALL_TESTING}
  { Test-build-only fixture transport (ADR-0044): replays recorded exchanges
    from <root>/upload-pack/<repository>/ -- `advertisement` for the
    capability request and `<sha256>.response` for the command request
    whose body hashes to <sha256>. Install selects it through the same
    variable as the ref-listing fixture; release builds do not compile it. }
  TGitFixtureUploadPackTransport = class(TGitUploadPackTransport)
  private
    FRoot: string;
    FMaxResponseBytes: Int64;
    FLogRequests: Boolean;
    function ReadResponse(const APath: string): TBytes;
  public
    { ALogRequests appends each exchange to <root>/requests.log, as the
      ref-listing fixture does, so install tests can count requests. }
    constructor Create(const ARoot: string; AMaxResponseBytes: Int64 = 0;
      ALogRequests: Boolean = False);
    function Advertise(const ARepoURL: string;
      out AEffectiveRepoURL: string): TBytes; override;
    function Command(const ARepoURL: string;
      const ARequest: TBytes): TBytes; override;
  end;
  {$ENDIF}

  TGitV2Capabilities = record
    Version2: Boolean;
    LsRefs: Boolean;
    Fetch: Boolean;
    FetchFilter: Boolean;
    Agent: Boolean;
    ObjectFormat: string;   { '' when not advertised }
  end;

  { A branch or tag tip from ls-refs; Id is the peeled commit for tags. }
  TGitTip = record
    Name: string;           { full ref name, e.g. refs/tags/v1.0.0 }
    Id: string;
  end;
  TGitTipArray = array of TGitTip;

  TGitFetchResponse = record
    Acknowledged: Boolean;  { an ACK line arrived }
    Nak: Boolean;           { an explicit NAK arrived }
    Ready: Boolean;
    HasPack: Boolean;
    Pack: TBytes;
  end;

  TGitReachabilityResult = record
    { The pin is reachable from ProvingRef. }
    Reachable: Boolean;
    { False when the host answered NAK: it has no object with this id. }
    Known: Boolean;
    ProvingRef: string;
    Requests: Integer;
    BytesReceived: Int64;
  end;

const
  { Largest upload-pack response accepted in one request. A proof that
    needs more is refused (EGitResponseTooLarge) rather than trusted. }
  MAX_UPLOAD_PACK_RESPONSE_BYTES = Int64(64) * 1024 * 1024;
  UPLOAD_PACK_REQUEST_TIMEOUT_MILLISECONDS = 120 * 1000;
  { Tips probed individually, nearest commit date first, before the
    all-tips round. }
  MAX_NEAREST_TIP_PROBES = 4;

{ Hit <ARepoURL>/info/refs?service=git-upload-pack and parse the
  pkt-line response into the ref list. ARepoURL must end in `.git`
  (the standard git-host convention); callers build the URL via
  GitRepoURL which appends `.git`. AOptions carries the dependency's
  destination policy (LWPT.FetchPolicy), enforced on every redirect hop. }
function ListRemoteRefs(const ARepoURL: string;
  const AOptions: THTTPRequestOptions): TGitRefArray;

{ Lower-level: parse a raw pkt-line stream into refs. Exposed for
  unit tests that feed a captured info/refs fixture without going
  over the network. }
function ParseInfoRefs(const APayload: string): TGitRefArray;

{ pkt-line framing: a data line (payload plus LF), flush, and delim. }
function PktLine(const APayload: string): AnsiString;
function PktFlush: AnsiString;
function PktDelim: AnsiString;

{ Protocol v2 pieces, exposed for tests that replay captured responses. }
function ParseV2Capabilities(const ABody: TBytes): TGitV2Capabilities;
function BuildV2CommandRequest(const ACapabilities: TGitV2Capabilities;
  const ACommand: string; const AArguments: array of string): TBytes;
function ParseLsRefsResponse(const ABody: TBytes;
  out AHeadTarget: string): TGitTipArray;
{ Consumes ABody: the side-band pack is compacted into the same buffer and
  returned as Pack. }
function ParseFetchResponse(var ABody: TBytes): TGitFetchResponse;

{ Prove that ACommit (40 hex characters) is reachable from an advertised
  refs/heads/* or refs/tags/* tip. AAdvertised is the ref listing the
  resolver already holds; a pin equal to one of its tips is accepted without
  any request. Raises EGitReachabilityError when no verdict can be reached
  (unsupported host, limit, malformed response). }
function ProveCommitReachable(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult;

implementation

uses
  Generics.Collections;

const
  PKT_PREFIX_LEN = 4;

{$IFDEF INSTALL_TESTING}
{ Test-build-only fixture transport (ADR-0044): with
  <PROJECT_NAME>_TEST_GIT_FIXTURE_DIR set, ref advertisements are read from
  <dir>/refs/<repository>.refs instead of the network. Release builds do not
  compile this seam and ignore the variable. }
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
{$ENDIF}

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

function ListRemoteRefs(const ARepoURL: string;
  const AOptions: THTTPRequestOptions): TGitRefArray;
var
  URL : string;
  {$IFDEF INSTALL_TESTING}
  FixtureRoot: string;
  {$ENDIF}
  Resp : THTTPResponse;
  Headers : THTTPHeaders;
  Body : string;
  i : Integer;
begin
  if ARepoURL = '' then
    raise EGitProtocolError.Create('ListRemoteRefs: empty repo URL');

  {$IFDEF INSTALL_TESTING}
  FixtureRoot := SysUtils.GetEnvironmentVariable(
    PROJECT_NAME + '_TEST_GIT_FIXTURE_DIR');
  if FixtureRoot <> '' then
    Exit(LoadFixtureRefs(FixtureRoot, ARepoURL));
  {$ENDIF}

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
  Resp := HTTPGet(URL, Headers, AOptions);
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

{ ───────────────────────────────────────────────────────────────────
  pkt-line framing
  ─────────────────────────────────────────────────────────────────── }

type
  TPktKind = (pkData, pkFlush, pkDelim, pkResponseEnd);

function PktLine(const APayload: string): AnsiString;
var Len: Integer;
begin
  Len := Length(APayload) + 1 + PKT_PREFIX_LEN;
  if Len > 65520 then
    raise EGitProtocolError.Create('pkt-line payload is too long');
  Result := LowerCase(IntToHex(Len, PKT_PREFIX_LEN)) + APayload + #10;
end;

function PktFlush: AnsiString;
begin
  Result := '0000';
end;

function PktDelim: AnsiString;
begin
  Result := '0001';
end;

function NextPkt(const ABuf: TBytes; var APos: Integer; out AKind: TPktKind;
  out AStart, ALength: Integer): Boolean;
var i, Digit, Len: Integer;
begin
  AStart := 0;
  ALength := 0;
  AKind := pkData;
  Result := APos < Length(ABuf);
  if not Result then Exit;
  if APos + PKT_PREFIX_LEN > Length(ABuf) then
    raise EGitReachabilityError.Create('truncated pkt-line length');
  Len := 0;
  for i := 0 to PKT_PREFIX_LEN - 1 do
  begin
    Digit := HexCharToInt(AnsiChar(ABuf[APos + i]));
    if Digit < 0 then
      raise EGitReachabilityError.Create('invalid pkt-line length');
    Len := (Len shl 4) or Digit;
  end;
  Inc(APos, PKT_PREFIX_LEN);
  case Len of
    0: AKind := pkFlush;
    1: AKind := pkDelim;
    2: AKind := pkResponseEnd;
    3: raise EGitReachabilityError.Create('invalid pkt-line length 3');
  else
    ALength := Len - PKT_PREFIX_LEN;
    if APos + ALength > Length(ABuf) then
      raise EGitReachabilityError.Create('truncated pkt-line');
    AStart := APos;
    Inc(APos, ALength);
  end;
end;

function PktText(const ABuf: TBytes; AStart, ALength: Integer): string;
begin
  SetLength(Result, ALength);
  if ALength > 0 then Move(ABuf[AStart], Result[1], ALength);
  Result := StripTrailingNewline(Result);
end;

function BytesOf(const AText: AnsiString): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Result[0], Length(AText));
end;

function StartsWith(const AText, APrefix: string): Boolean; inline;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

function IsLowerHexId(const AValue: string): Boolean;
begin
  Result := IsFullGitObjectId(AValue) and (LowerCase(AValue) = AValue);
end;

{ ───────────────────────────────────────────────────────────────────
  Protocol v2 messages
  ─────────────────────────────────────────────────────────────────── }

function ParseV2Capabilities(const ABody: TBytes): TGitV2Capabilities;
var
  Offset, Start, Len, Equals: Integer;
  Kind: TPktKind;
  Line, Key, Value: string;
  SeenLine: Boolean;
  Features: TStringArray;
  Feature: string;
begin
  Result := Default(TGitV2Capabilities);
  Offset := 0;
  SeenLine := False;
  while NextPkt(ABody, Offset, Kind, Start, Len) do
  begin
    if Kind <> pkData then
    begin
      { The optional "# service=" preamble ends with its own flush. }
      if SeenLine then Break;
      Continue;
    end;
    Line := PktText(ABody, Start, Len);
    if not SeenLine then
    begin
      if StartsWith(Line, '# service=') then Continue;
      SeenLine := True;
      if Line <> 'version 2' then Exit;   { a v0/v1 advertisement }
      Result.Version2 := True;
      Continue;
    end;
    Equals := Pos('=', Line);
    if Equals > 0 then
    begin
      Key := Copy(Line, 1, Equals - 1);
      Value := Copy(Line, Equals + 1, MaxInt);
    end
    else
    begin
      Key := Line;
      Value := '';
    end;
    if Key = 'ls-refs' then
      Result.LsRefs := True
    else if Key = 'agent' then
      Result.Agent := True
    else if Key = 'object-format' then
      Result.ObjectFormat := Value
    else if Key = 'fetch' then
    begin
      Result.Fetch := True;
      Features := Value.Split([' ']);
      for Feature in Features do
        if Feature = 'filter' then Result.FetchFilter := True;
    end;
  end;
end;

function BuildV2CommandRequest(const ACapabilities: TGitV2Capabilities;
  const ACommand: string; const AArguments: array of string): TBytes;
var Request: AnsiString; i: Integer;
begin
  Request := PktLine('command=' + ACommand);
  { A constant agent keeps recorded request bodies (and so the fixture
    keys that name their responses) independent of the LWPT version. }
  if ACapabilities.Agent then
    Request := Request + PktLine('agent=' + PROGRAM_NAME);
  if ACapabilities.ObjectFormat <> '' then
    Request := Request + PktLine('object-format='
      + ACapabilities.ObjectFormat);
  Request := Request + PktDelim;
  for i := 0 to High(AArguments) do
    Request := Request + PktLine(AArguments[i]);
  Result := BytesOf(Request + PktFlush);
end;

function ParseLsRefsResponse(const ABody: TBytes;
  out AHeadTarget: string): TGitTipArray;
var
  Offset, Start, Len, i, n: Integer;
  Kind: TPktKind;
  Line, Id, Name, Peeled, Target: string;
  Fields: TStringArray;
  Terminated: Boolean;
begin
  SetLength(Result, 0);
  AHeadTarget := '';
  Offset := 0;
  Terminated := False;
  while NextPkt(ABody, Offset, Kind, Start, Len) do
  begin
    if Kind = pkFlush then
    begin
      Terminated := True;
      Break;
    end;
    if Kind <> pkData then
      raise EGitReachabilityError.Create('unexpected ls-refs framing');
    Line := PktText(ABody, Start, Len);
    if StartsWith(Line, 'ERR ') then
      raise EGitReachabilityError.Create('remote error: '
        + Copy(Line, 5, MaxInt));
    Fields := Line.Split([' ']);
    if Length(Fields) < 2 then
      raise EGitReachabilityError.Create('malformed ls-refs line');
    Id := Fields[0];
    Name := Fields[1];
    Peeled := '';
    Target := '';
    for i := 2 to High(Fields) do
      if StartsWith(Fields[i], 'peeled:') then
        Peeled := Copy(Fields[i], 8, MaxInt)
      else if StartsWith(Fields[i], 'symref-target:') then
        Target := Copy(Fields[i], 15, MaxInt);
    if Name = 'HEAD' then
    begin
      AHeadTarget := Target;
      Continue;
    end;
    { Only branch and tag tips can prove reachability. Hosts also keep
      refs/pull/* and refs/merge-requests/* for fork contributions; those
      are never requested and are ignored if a host sends them anyway. }
    if not (StartsWith(Name, 'refs/heads/')
       or StartsWith(Name, 'refs/tags/')) then
      Continue;
    if Peeled <> '' then Id := Peeled;
    if not IsLowerHexId(Id) then
      raise EGitReachabilityError.CreateFmt(
        'ls-refs advertised a malformed id for %s', [Name]);
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Name := Name;
    Result[n].Id := Id;
  end;
  if not Terminated then
    raise EGitReachabilityError.Create('ls-refs response is truncated');
end;

function ParseFetchResponse(var ABody: TBytes): TGitFetchResponse;
var
  Offset, Start, Len, WritePos: Integer;
  Kind: TPktKind;
  Section, Line: string;
  Terminated: Boolean;
begin
  Result := Default(TGitFetchResponse);
  Offset := 0;
  WritePos := 0;
  Section := '';
  Terminated := False;
  while NextPkt(ABody, Offset, Kind, Start, Len) do
  begin
    if Kind in [pkFlush, pkResponseEnd] then
    begin
      Terminated := True;
      Break;
    end;
    if Kind = pkDelim then
    begin
      if Section = 'packfile' then
        raise EGitReachabilityError.Create('fetch response continues '
          + 'after its packfile section');
      Section := '';
      Continue;
    end;
    if Section = 'packfile' then
    begin
      if Len < 1 then
        raise EGitReachabilityError.Create('empty side-band packet');
      case ABody[Start] of
        1:
        begin
          { Side-band framing only removes bytes, so the pack is compacted
            in place and never needs a second response-sized buffer. }
          if Len > 1 then
            Move(ABody[Start + 1], ABody[WritePos], Len - 1);
          Inc(WritePos, Len - 1);
        end;
        2:;  { progress }
        3: raise EGitReachabilityError.Create('remote error: '
             + PktText(ABody, Start + 1, Len - 1));
      else
        raise EGitReachabilityError.CreateFmt(
          'invalid side-band channel %d', [ABody[Start]]);
      end;
      Continue;
    end;
    Line := PktText(ABody, Start, Len);
    if StartsWith(Line, 'ERR ') then
      raise EGitReachabilityError.Create('remote error: '
        + Copy(Line, 5, MaxInt));
    if Section = '' then
    begin
      if (Line <> 'acknowledgments') and (Line <> 'shallow-info')
         and (Line <> 'wanted-refs') and (Line <> 'packfile') then
        raise EGitReachabilityError.CreateFmt(
          'unexpected fetch response section "%s"', [Line]);
      Section := Line;
      if Section = 'packfile' then Result.HasPack := True;
    end
    else if Section = 'acknowledgments' then
    begin
      if Line = 'NAK' then
        Result.Nak := True
      else if Line = 'ready' then
        Result.Ready := True
      else if StartsWith(Line, 'ACK ') then
        Result.Acknowledged := True
      else
        raise EGitReachabilityError.CreateFmt(
          'unexpected acknowledgment "%s"', [Line]);
    end;
    { shallow-info and wanted-refs lines carry nothing the proof needs. }
  end;
  if not Terminated then
    raise EGitReachabilityError.Create('fetch response is truncated');
  if Result.HasPack then
  begin
    SetLength(ABody, WritePos);
    Result.Pack := ABody;
  end;
  ABody := nil;
end;

{ ───────────────────────────────────────────────────────────────────
  Transports
  ─────────────────────────────────────────────────────────────────── }

const
  INFO_REFS_SUFFIX = '/info/refs?service=git-upload-pack';
  UPLOAD_PACK_SUFFIX = '/git-upload-pack';

function UploadPackBaseURL(const ARepoURL: string): string;
begin
  if (ARepoURL = '') or (Pos('?', ARepoURL) > 0) then
    raise EGitReachabilityError.CreateFmt(
      'cannot derive the upload-pack endpoint of "%s"', [ARepoURL]);
  Result := ARepoURL;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function TooLarge(const AURL: string;
  ALimit: Int64): EGitResponseTooLarge;
begin
  Result := EGitResponseTooLarge.CreateFmt(
    'upload-pack response from %s exceeds the %d-byte proof limit',
    [AURL, ALimit]);
end;

constructor THTTPGitUploadPackTransport.Create(
  const AOptions: THTTPRequestOptions; AMaxResponseBytes: Int64);
begin
  inherited Create;
  if AMaxResponseBytes <= 0 then
    FMaxResponseBytes := MAX_UPLOAD_PACK_RESPONSE_BYTES
  else
    FMaxResponseBytes := AMaxResponseBytes;
  FOptions := AOptions;
  FOptions.MaxResponseBodyBytes := FMaxResponseBytes;
  FOptions.RequestTimeoutMilliseconds :=
    UPLOAD_PACK_REQUEST_TIMEOUT_MILLISECONDS;
end;

function THTTPGitUploadPackTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string): TBytes;
var
  URL, Final: string;
  Headers: THTTPHeaders;
  Resp: THTTPResponse;
begin
  URL := UploadPackBaseURL(ARepoURL) + INFO_REFS_SUFFIX;
  SetLength(Headers, 1);
  Headers[0].Name := 'Git-Protocol';
  Headers[0].Value := 'version=2';
  try
    Resp := HTTPGet(URL, Headers, FOptions);
  except
    on E: EHTTPResponseTooLarge do
      raise TooLarge(URL, FMaxResponseBytes);
    on E: EHTTPError do
      raise EGitReachabilityError.CreateFmt('%s: %s', [URL, E.Message]);
  end;
  if Resp.StatusCode <> 200 then
    raise EGitReachabilityError.CreateFmt('%s: HTTP %d %s',
      [URL, Resp.StatusCode, Resp.StatusText]);
  AEffectiveRepoURL := UploadPackBaseURL(ARepoURL);
  { Commands follow a redirected advertisement, as git clients do, so a
    renamed repository keeps working; the destination policy has already
    vetted every hop. }
  Final := Resp.FinalURL;
  if Resp.Redirected and (Length(Final) > Length(INFO_REFS_SUFFIX))
     and (Copy(Final, Length(Final) - Length(INFO_REFS_SUFFIX) + 1,
       MaxInt) = INFO_REFS_SUFFIX) then
    AEffectiveRepoURL := Copy(Final, 1,
      Length(Final) - Length(INFO_REFS_SUFFIX));
  Result := Resp.Body;
end;

function THTTPGitUploadPackTransport.Command(const ARepoURL: string;
  const ARequest: TBytes): TBytes;
var
  URL: string;
  Headers: THTTPHeaders;
  Options: THTTPRequestOptions;
  Resp: THTTPResponse;
begin
  URL := UploadPackBaseURL(ARepoURL) + UPLOAD_PACK_SUFFIX;
  SetLength(Headers, 2);
  Headers[0].Name := 'Git-Protocol';
  Headers[0].Value := 'version=2';
  Headers[1].Name := 'Accept';
  Headers[1].Value := 'application/x-git-upload-pack-result';
  Options := FOptions;
  { A redirected POST would be replayed as a GET; the advertisement has
    already resolved any redirect. }
  Options.MaximumRedirects := 0;
  try
    Resp := HTTPPost(URL, ARequest, 'application/x-git-upload-pack-request',
      Headers, Options);
  except
    on E: EHTTPResponseTooLarge do
      raise TooLarge(URL, FMaxResponseBytes);
    on E: EHTTPError do
      raise EGitReachabilityError.CreateFmt('%s: %s', [URL, E.Message]);
  end;
  if Resp.StatusCode <> 200 then
    raise EGitReachabilityError.CreateFmt('%s: HTTP %d %s',
      [URL, Resp.StatusCode, Resp.StatusText]);
  Result := Resp.Body;
end;

{$IFDEF INSTALL_TESTING}
constructor TGitFixtureUploadPackTransport.Create(const ARoot: string;
  AMaxResponseBytes: Int64; ALogRequests: Boolean);
begin
  inherited Create;
  FLogRequests := ALogRequests;
  FRoot := IncludeTrailingPathDelimiter(ARoot);
  if AMaxResponseBytes <= 0 then
    FMaxResponseBytes := MAX_UPLOAD_PACK_RESPONSE_BYTES
  else
    FMaxResponseBytes := AMaxResponseBytes;
end;

function TGitFixtureUploadPackTransport.ReadResponse(
  const APath: string): TBytes;
var Stream: TFileStream;
begin
  if not FileExists(APath) then
    raise EGitReachabilityError.CreateFmt(
      'test git fixture has no recorded upload-pack response (%s)', [APath]);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size > FMaxResponseBytes then
      raise EGitResponseTooLarge.CreateFmt(
        'upload-pack response from %s exceeds the %d-byte proof limit',
        [APath, FMaxResponseBytes]);
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function TGitFixtureUploadPackTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string): TBytes;
var Repository: string;
begin
  Repository := FixtureRepositoryName(ARepoURL);
  AEffectiveRepoURL := ARepoURL;
  if FLogRequests then
    AppendFixtureRequest(FRoot, 'upload-pack|' + Repository + '|advertise');
  Result := ReadResponse(FRoot + 'upload-pack/' + Repository
    + '/advertisement');
end;

function TGitFixtureUploadPackTransport.Command(const ARepoURL: string;
  const ARequest: TBytes): TBytes;
var
  Repository, CommandLine: string;
  Offset, Start, Len: Integer;
  Kind: TPktKind;
begin
  Repository := FixtureRepositoryName(ARepoURL);
  CommandLine := '';
  Offset := 0;
  if NextPkt(ARequest, Offset, Kind, Start, Len) and (Kind = pkData) then
    CommandLine := PktText(ARequest, Start, Len);
  if FLogRequests then
    AppendFixtureRequest(FRoot, 'upload-pack|' + Repository + '|'
      + Copy(CommandLine, Length('command=') + 1, MaxInt));
  Result := ReadResponse(FRoot + 'upload-pack/' + Repository + '/'
    + SHA256Hex(ARequest) + '.response');
end;
{$ENDIF}

{ ───────────────────────────────────────────────────────────────────
  Reachability proof
  ─────────────────────────────────────────────────────────────────── }

type
  TReachabilityRun = record
    Transport: TGitUploadPackTransport;
    RepoURL: string;
    Capabilities: TGitV2Capabilities;
    Requests: Integer;
    BytesReceived: Int64;
  end;

function RunCommand(var ARun: TReachabilityRun; const ACommand: string;
  const AArguments: array of string): TBytes;
begin
  Result := ARun.Transport.Command(ARun.RepoURL,
    BuildV2CommandRequest(ARun.Capabilities, ACommand, AArguments));
  Inc(ARun.Requests);
  Inc(ARun.BytesReceived, Length(Result));
end;

function RunFetch(var ARun: TReachabilityRun; const AWants,
  AHaves: array of string; ADone: Boolean;
  ADeepen: Boolean = False): TGitFetchResponse;
var
  Arguments: array of string;
  Body: TBytes;
  i, n: Integer;
begin
  SetLength(Arguments, 5 + Length(AWants) + Length(AHaves));
  n := 0;
  Arguments[n] := 'no-progress'; Inc(n);
  Arguments[n] := 'ofs-delta'; Inc(n);
  { Never `thin-pack`: every delta base must be in the pack. }
  Arguments[n] := 'filter tree:0'; Inc(n);
  if ADeepen then
  begin
    Arguments[n] := 'deepen 1';
    Inc(n);
  end;
  for i := 0 to High(AWants) do
  begin
    Arguments[n] := 'want ' + AWants[i];
    Inc(n);
  end;
  for i := 0 to High(AHaves) do
  begin
    Arguments[n] := 'have ' + AHaves[i];
    Inc(n);
  end;
  if ADone then
  begin
    Arguments[n] := 'done';
    Inc(n);
  end;
  SetLength(Arguments, n);
  Body := RunCommand(ARun, 'fetch', Arguments);
  Result := ParseFetchResponse(Body);
end;

function RefFullName(const ARef: TGitRef): string;
begin
  if ARef.Kind = rkTag then
    Result := 'refs/tags/' + ARef.Name
  else
    Result := 'refs/heads/' + ARef.Name;
end;

function DistinctTips(const ATips: TGitTipArray): TGitTipArray;
var i, j, n: Integer; Seen: Boolean;
begin
  SetLength(Result, Length(ATips));
  n := 0;
  for i := 0 to High(ATips) do
  begin
    Seen := False;
    for j := 0 to n - 1 do
      if Result[j].Id = ATips[i].Id then
      begin
        Seen := True;
        Break;
      end;
    if Seen then Continue;
    Result[n] := ATips[i];
    Inc(n);
  end;
  SetLength(Result, n);
end;

{ Committer times of the tips and the target, from one shallow commits-only
  fetch. They only choose which tips to probe first, so a host that refuses
  the request simply leaves the probes unordered. }
function CollectCommitTimes(var ARun: TReachabilityRun;
  const ATips: TGitTipArray; const ATarget: string): TDictionary<string, Int64>;
var
  Wants: array of string;
  Response: TGitFetchResponse;
  Graph: TGitCommitGraph;
  Commit: TGitCommitRecord;
  i: Integer;
begin
  Result := nil;
  SetLength(Wants, Length(ATips) + 1);
  for i := 0 to High(ATips) do Wants[i] := ATips[i].Id;
  Wants[High(Wants)] := ATarget;
  try
    Response := RunFetch(ARun, Wants, [], True, True);
    if not Response.HasPack then Exit;
    Graph := ReadCommitPack(Response.Pack, DefaultGitPackLimits);
  except
    on E: EGitResponseTooLarge do
      raise;
    on E: EGitProtocolError do
      Exit;
    on E: EGitPackError do
      Exit;
  end;
  try
    if not Graph.TryGetCommit(ATarget, Commit) then Exit;
    Result := TDictionary<string, Int64>.Create;
    Result.AddOrSetValue(ATarget, Commit.CommitTime);
    for i := 0 to High(ATips) do
      if Graph.TryGetCommit(ATips[i].Id, Commit) then
        Result.AddOrSetValue(ATips[i].Id, Commit.CommitTime);
  finally
    Graph.Free;
  end;
end;

{ Tips to probe one at a time: those committed closest after the target
  (the release that first contains an old pin is usually the next one),
  then the default branch. }
function ChooseProbes(const ATips: TGitTipArray; const AHeadTarget,
  ATarget: string; const ATimes: TDictionary<string, Int64>): TGitTipArray;
var
  Candidates: TGitTipArray;
  TargetTime, TimeA, TimeB: Int64;
  i, j, n: Integer;
  Swap: TGitTip;
  Present: Boolean;
begin
  SetLength(Result, 0);
  if (ATimes <> nil) and ATimes.TryGetValue(ATarget, TargetTime) then
  begin
    SetLength(Candidates, 0);
    for i := 0 to High(ATips) do
      if ATimes.TryGetValue(ATips[i].Id, TimeA) and (TimeA >= TargetTime) then
      begin
        n := Length(Candidates);
        SetLength(Candidates, n + 1);
        Candidates[n] := ATips[i];
      end;
    { Insertion sort by (commit time, ref name): tip counts are small and
      the order must be deterministic. }
    for i := 1 to High(Candidates) do
    begin
      j := i;
      while j > 0 do
      begin
        TimeA := ATimes[Candidates[j - 1].Id];
        TimeB := ATimes[Candidates[j].Id];
        if (TimeA < TimeB) or ((TimeA = TimeB)
           and (Candidates[j - 1].Name <= Candidates[j].Name)) then Break;
        Swap := Candidates[j - 1];
        Candidates[j - 1] := Candidates[j];
        Candidates[j] := Swap;
        Dec(j);
      end;
    end;
    n := Length(Candidates);
    if n > MAX_NEAREST_TIP_PROBES then n := MAX_NEAREST_TIP_PROBES;
    Result := Copy(Candidates, 0, n);
  end;
  for i := 0 to High(ATips) do
    if ATips[i].Name = AHeadTarget then
    begin
      Present := False;
      for j := 0 to High(Result) do
        Present := Present or (Result[j].Id = ATips[i].Id);
      if not Present then
      begin
        n := Length(Result);
        SetLength(Result, n + 1);
        Result[n] := ATips[i];
      end;
      Break;
    end;
  if (Length(Result) = 0) and (Length(ATips) > 0) then
  begin
    SetLength(Result, 1);
    Result[0] := ATips[0];
  end;
end;

function ProveCommitReachableCore(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult;
var
  Run: TReachabilityRun;
  Target, HeadTarget: string;
  Tips, Probes, Remaining, Excluded: TGitTipArray;
  Times: TDictionary<string, Int64>;
  Response: TGitFetchResponse;
  Graph: TGitCommitGraph;
  Wants, Haves: array of string;
  Body: TBytes;
  i, j, Found: Integer;
  IsExcluded: Boolean;
begin
  Result := Default(TGitReachabilityResult);
  Result.Known := True;
  if not IsFullGitObjectId(ACommit) then
    raise EGitReachabilityError.CreateFmt(
      '"%s" is not a full 40-character commit id', [ACommit]);
  Target := LowerCase(ACommit);

  { Exact tip: the pin is itself an advertised branch head, tag, or peeled
    tag. Needs no request beyond the listing the resolver already made. }
  for i := 0 to High(AAdvertised) do
    if SameText(AAdvertised[i].SHA, Target)
       or SameText(AAdvertised[i].PeeledSHA, Target) then
    begin
      Result.Reachable := True;
      Result.ProvingRef := RefFullName(AAdvertised[i]);
      Exit;
    end;

  Run := Default(TReachabilityRun);
  Run.Transport := ATransport;
  try
    Body := ATransport.Advertise(ARepoURL, Run.RepoURL);
    Inc(Run.Requests);
    Inc(Run.BytesReceived, Length(Body));
    Run.Capabilities := ParseV2Capabilities(Body);
    if not (Run.Capabilities.Version2 and Run.Capabilities.LsRefs
       and Run.Capabilities.Fetch) then
      raise EGitReachabilityError.CreateFmt(
        '%s does not offer git protocol v2 ls-refs and fetch', [ARepoURL]);
    if not Run.Capabilities.FetchFilter then
      raise EGitReachabilityError.CreateFmt(
        '%s does not advertise the fetch "filter" capability', [ARepoURL]);
    if (Run.Capabilities.ObjectFormat <> '')
       and (Run.Capabilities.ObjectFormat <> 'sha1') then
      raise EGitReachabilityError.CreateFmt(
        '%s uses object format %s; only sha1 repositories can be verified',
        [ARepoURL, Run.Capabilities.ObjectFormat]);

    Body := RunCommand(Run, 'ls-refs', ['symrefs', 'peel', 'ref-prefix HEAD',
      'ref-prefix refs/heads/', 'ref-prefix refs/tags/']);
    Tips := DistinctTips(ParseLsRefsResponse(Body, HeadTarget));
    for i := 0 to High(Tips) do
      if Tips[i].Id = Target then
      begin
        Result.Reachable := True;
        Result.ProvingRef := Tips[i].Name;
        Exit;
      end;
    if Length(Tips) = 0 then Exit;

    Times := nil;
    if Length(Tips) > 1 then
      Times := CollectCommitTimes(Run, Tips, Target);
    try
      Probes := ChooseProbes(Tips, HeadTarget, Target, Times);
    finally
      Times.Free;
    end;

    { Probe single tips without `done`: a host that cannot reach the pin from
      the tip stops after its acknowledgments, so a miss costs a few bytes.
      When it is ready it sends pack(tip --not pin); if the walk finds no
      path, the tip is proven not to contain the pin and is excluded below. }
    SetLength(Excluded, 0);
    for i := 0 to High(Probes) do
    begin
      Response := RunFetch(Run, [Probes[i].Id], [Target], False);
      if not Response.Acknowledged and not Response.Ready then
      begin
        { NAK: no have was common, so the host has no such object. }
        Result.Known := False;
        Exit;
      end;
      if not Response.Ready then Continue;
      if not Response.HasPack then
        raise EGitReachabilityError.Create(
          'upload-pack reported ready without sending a pack');
      Graph := ReadCommitPack(Response.Pack, DefaultGitPackLimits);
      try
        if Graph.FindReachingStart([Probes[i].Id], Target) = 0 then
        begin
          Result.Reachable := True;
          Result.ProvingRef := Probes[i].Name;
          Exit;
        end;
      finally
        Graph.Free;
      end;
      SetLength(Excluded, Length(Excluded) + 1);
      Excluded[High(Excluded)] := Probes[i];
    end;

    { Every remaining tip at once. A commit on any path tip -> ... -> pin is
      neither an ancestor of the pin nor of an excluded tip (that tip would
      then contain the pin), so the set difference always holds the path. }
    SetLength(Remaining, 0);
    for i := 0 to High(Tips) do
    begin
      IsExcluded := False;
      for j := 0 to High(Excluded) do
        IsExcluded := IsExcluded or (Excluded[j].Id = Tips[i].Id);
      if IsExcluded then Continue;
      SetLength(Remaining, Length(Remaining) + 1);
      Remaining[High(Remaining)] := Tips[i];
    end;
    if Length(Remaining) = 0 then Exit;
    SetLength(Wants, Length(Remaining));
    for i := 0 to High(Remaining) do Wants[i] := Remaining[i].Id;
    SetLength(Haves, Length(Excluded) + 1);
    Haves[0] := Target;
    for i := 0 to High(Excluded) do Haves[i + 1] := Excluded[i].Id;
    Response := RunFetch(Run, Wants, Haves, True);
    if not Response.HasPack then
      raise EGitReachabilityError.Create(
        'upload-pack answered the final round without a pack');
    Graph := ReadCommitPack(Response.Pack, DefaultGitPackLimits);
    try
      Found := Graph.FindReachingStart(Wants, Target);
      if Found >= 0 then
      begin
        Result.Reachable := True;
        Result.ProvingRef := Remaining[Found].Name;
      end;
    finally
      Graph.Free;
    end;
  finally
    Result.Requests := Run.Requests;
    Result.BytesReceived := Run.BytesReceived;
  end;
end;

function ProveCommitReachable(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult;
begin
  try
    Result := ProveCommitReachableCore(ATransport, ARepoURL, ACommit,
      AAdvertised);
  except
    on E: EGitPackError do
      raise EGitReachabilityError.CreateFmt('%s sent an invalid pack: %s',
        [ARepoURL, E.Message]);
  end;
end;

end.
