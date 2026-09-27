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

  Commit reachability (ADR-0047). A commit-SHA pin is accepted only when the
  commit is reachable from an advertised refs/heads/* or refs/tags/* tip.
  ProveCommitReachable first compares the pin with the advertised tips
  (no extra request). Otherwise it speaks protocol v2 over the same
  smart-HTTP endpoint:

    GET  <repo>/info/refs?service=git-upload-pack   capability advertisement
    POST <repo>/git-upload-pack  command=ls-refs    tips and HEAD target
    POST <repo>/git-upload-pack  command=fetch      commits-only packs

  Every fetch sends `filter tree:0` and never `thin-pack`, so the host
  returns only commits and annotated tags, and every delta base is in the
  pack. With `want <tip>` and `have <pin>` the host sends exactly the
  objects reachable from the tip but not from the pin; LWPT.GitPack
  recomputes their ids and the pin is reachable iff one of them names it as
  a parent (or, for a tag object, as its target). Peel claims in listings
  are never trusted. The whole proof shares one deadline and byte budget,
  and listings are capped in ref count and distinct tips. Archives remain
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
  { The proof's single monotonic deadline passed. }
  EGitProofDeadlineExceeded = class(EGitReachabilityError);

  { What one request may still spend of its proof's shared budget. }
  TGitRequestBudget = record
    TimeoutMilliseconds: QWord;
    MaxResponseBytes: Int64;
  end;

  { Transport for the smart-HTTP upload-pack service. Implementations must
    finish within ABudget.TimeoutMilliseconds and refuse any response larger
    than the smaller of their own cap and ABudget.MaxResponseBytes with
    EGitResponseTooLarge rather than truncating it. }
  TGitUploadPackTransport = class
  public
    { Protocol v2 capability advertisement. AEffectiveRepoURL is the
      repository URL that later commands must use (it differs from
      ARepoURL when the advertisement request was redirected). }
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; virtual; abstract;
    { One protocol v2 command request; returns the raw response body. }
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; virtual; abstract;
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
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
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
    function ReadResponse(const APath: string;
      const ABudget: TGitRequestBudget): TBytes;
  public
    { ALogRequests appends each exchange to <root>/requests.log, as the
      ref-listing fixture does, so install tests can count requests. }
    constructor Create(const ARoot: string; AMaxResponseBytes: Int64 = 0;
      ALogRequests: Boolean = False);
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
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

  { A branch or tag tip from ls-refs. Id is the object the ref names (an
    annotated tag's own object id); a peel is only ever taken from a
    hash-verified tag object in a pack, never from the listing. }
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

  { Budget shared by every request of one proof. }
  TGitProofLimits = record
    TimeoutMilliseconds: QWord;
    MaxTotalBytes: Int64;
  end;

const
  { Largest upload-pack response accepted in one request. A proof that
    needs more is refused (EGitResponseTooLarge) rather than trusted. }
  MAX_UPLOAD_PACK_RESPONSE_BYTES = Int64(64) * 1024 * 1024;
  UPLOAD_PACK_REQUEST_TIMEOUT_MILLISECONDS = 120 * 1000;
  { Tips probed individually, nearest commit date first, before the
    all-tips round. }
  MAX_NEAREST_TIP_PROBES = 4;
  { Hostile-listing limits: ls-refs lines accepted, bytes in one ref name,
    and distinct tip commits a proof will name in its requests. }
  MAX_ADVERTISED_REFS = 100000;
  MAX_REF_NAME_LENGTH = 1024;
  MAX_PROOF_TIPS = 20000;
  { Largest request body a proof sends (MAX_PROOF_TIPS wants fit). }
  MAX_UPLOAD_PACK_REQUEST_BYTES = 2 * 1024 * 1024;
  { One monotonic budget for the whole proof, shared by its requests. }
  MAX_REACHABILITY_PROOF_MILLISECONDS = 180 * 1000;
  MAX_REACHABILITY_PROOF_BYTES = Int64(128) * 1024 * 1024;

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

{ True when AName is a well-formed ref name by git's check-ref-format rules
  (no control characters, spaces, `~^:?*[\`, `..`, an at-sign before an
  opening brace, empty or dot-led components, `.lock` components, or a
  trailing `/` or `.`) and at most MAX_REF_NAME_LENGTH bytes. }
function IsValidGitRefName(const AName: string): Boolean;

function DefaultGitProofLimits: TGitProofLimits;

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
  resolver already holds; a pin equal to the object a well-named branch or
  tag names is accepted without any request (peeled claims are not). The
  whole proof shares one deadline and byte budget (ALimits, default
  DefaultGitProofLimits). Raises EGitReachabilityError when no verdict can
  be reached (unsupported host, limit, malformed response). }
function ProveCommitReachable(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult; overload;
function ProveCommitReachable(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string; const AAdvertised: TGitRefArray;
  const ALimits: TGitProofLimits): TGitReachabilityResult; overload;

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

function IsValidGitRefName(const AName: string): Boolean;
var i, ComponentStart: Integer; C: Char; Component: string;
begin
  Result := False;
  if (AName = '') or (Length(AName) > MAX_REF_NAME_LENGTH) then Exit;
  if (AName[Length(AName)] = '/') or (AName[Length(AName)] = '.') then Exit;
  if (Pos('..', AName) > 0) or (Pos('@{', AName) > 0)
     or (Pos('//', AName) > 0) or (AName[1] = '/') or (AName = '@') then
    Exit;
  for i := 1 to Length(AName) do
  begin
    C := AName[i];
    if (Ord(C) < $20) or (Ord(C) = $7F)
       or (C in [' ', '~', '^', ':', '?', '*', '[', '\']) then Exit;
  end;
  ComponentStart := 1;
  for i := 1 to Length(AName) + 1 do
    if (i > Length(AName)) or (AName[i] = '/') then
    begin
      Component := Copy(AName, ComponentStart, i - ComponentStart);
      if (Component = '') or (Component[1] = '.')
         or ((Length(Component) >= 5)
           and (Copy(Component, Length(Component) - 4, 5) = '.lock')) then
        Exit;
      ComponentStart := i + 1;
    end;
  Result := True;
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
var
  Lines: array of AnsiString;
  Size: Int64;
  i, n, Offset: Integer;

  procedure Add(const ALine: AnsiString);
  begin
    Lines[n] := ALine;
    Inc(Size, Length(ALine));
    Inc(n);
  end;

begin
  SetLength(Lines, Length(AArguments) + 5);
  n := 0;
  Size := 0;
  Add(PktLine('command=' + ACommand));
  { A constant agent keeps recorded request bodies (and so the fixture
    keys that name their responses) independent of the LWPT version. }
  if ACapabilities.Agent then Add(PktLine('agent=' + PROGRAM_NAME));
  if ACapabilities.ObjectFormat <> '' then
    Add(PktLine('object-format=' + ACapabilities.ObjectFormat));
  Add(PktDelim);
  for i := 0 to High(AArguments) do
  begin
    Add(PktLine(AArguments[i]));
    if Size > MAX_UPLOAD_PACK_REQUEST_BYTES then
      raise EGitReachabilityError.CreateFmt(
        'upload-pack %s request would exceed the %d-byte request limit',
        [ACommand, MAX_UPLOAD_PACK_REQUEST_BYTES]);
  end;
  Add(PktFlush);
  { One allocation: joining thousands of want lines by repeated
    concatenation would be quadratic. }
  SetLength(Result, Size);
  Offset := 0;
  for i := 0 to n - 1 do
  begin
    Move(Lines[i][1], Result[Offset], Length(Lines[i]));
    Inc(Offset, Length(Lines[i]));
  end;
end;

function ParseLsRefsResponse(const ABody: TBytes;
  out AHeadTarget: string): TGitTipArray;
var
  Offset, Start, Len, i, n, Lines: Integer;
  Kind: TPktKind;
  Line, Id, Name, Target: string;
  Fields: TStringArray;
  Terminated: Boolean;
  Seen: TDictionary<string, Boolean>;
begin
  SetLength(Result, 0);
  AHeadTarget := '';
  Offset := 0;
  n := 0;
  Lines := 0;
  Terminated := False;
  Seen := TDictionary<string, Boolean>.Create;
  try
    while NextPkt(ABody, Offset, Kind, Start, Len) do
    begin
      if Kind = pkFlush then
      begin
        Terminated := True;
        Break;
      end;
      if Kind <> pkData then
        raise EGitReachabilityError.Create('unexpected ls-refs framing');
      Inc(Lines);
      if Lines > MAX_ADVERTISED_REFS then
        raise EGitReachabilityError.CreateFmt(
          'ls-refs advertised more than %d refs', [MAX_ADVERTISED_REFS]);
      Line := PktText(ABody, Start, Len);
      if StartsWith(Line, 'ERR ') then
        raise EGitReachabilityError.Create('remote error: '
          + Copy(Line, 5, MaxInt));
      Fields := Line.Split([' ']);
      if Length(Fields) < 2 then
        raise EGitReachabilityError.Create('malformed ls-refs line');
      Id := Fields[0];
      Name := Fields[1];
      Target := '';
      { `peeled:` attributes are the host's unverified claims and are
        ignored; a tag is peeled only through its hash-verified object. }
      for i := 2 to High(Fields) do
        if StartsWith(Fields[i], 'symref-target:') then
          Target := Copy(Fields[i], 15, MaxInt);
      if Name = 'HEAD' then
      begin
        if IsValidGitRefName(Target) then AHeadTarget := Target;
        Continue;
      end;
      { Only branch and tag tips can prove reachability. Hosts also keep
        refs/pull/* and refs/merge-requests/* for fork contributions; those
        are never requested and are ignored if a host sends them anyway. }
      if not (StartsWith(Name, 'refs/heads/')
         or StartsWith(Name, 'refs/tags/')) then
        Continue;
      if not IsValidGitRefName(Name) then
        raise EGitReachabilityError.Create(
          'ls-refs advertised an invalid ref name');
      if not IsLowerHexId(Id) then
        raise EGitReachabilityError.CreateFmt(
          'ls-refs advertised a malformed id for %s', [Name]);
      if Seen.ContainsKey(Id) then Continue;
      if Seen.Count >= MAX_PROOF_TIPS then
        raise EGitReachabilityError.CreateFmt(
          'ls-refs advertised more than %d distinct tips', [MAX_PROOF_TIPS]);
      Seen.Add(Id, True);
      if n >= Length(Result) then SetLength(Result, 2 * n + 16);
      Result[n].Name := Name;
      Result[n].Id := Id;
      Inc(n);
    end;
  finally
    Seen.Free;
  end;
  SetLength(Result, n);
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

function EffectiveLimit(AOwn: Int64; const ABudget: TGitRequestBudget): Int64;
begin
  Result := AOwn;
  if ABudget.MaxResponseBytes < Result then
    Result := ABudget.MaxResponseBytes;
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
end;

function BudgetedOptions(const ABase: THTTPRequestOptions; AOwnLimit: Int64;
  const ABudget: TGitRequestBudget; out ALimit: Int64): THTTPRequestOptions;
begin
  Result := ABase;
  ALimit := EffectiveLimit(AOwnLimit, ABudget);
  Result.MaxResponseBodyBytes := ALimit;
  { The request may use what is left of the proof's shared deadline; the
    per-request ceiling stays the upload-pack request timeout. }
  Result.RequestTimeoutMilliseconds := UPLOAD_PACK_REQUEST_TIMEOUT_MILLISECONDS;
  if ABudget.TimeoutMilliseconds < Result.RequestTimeoutMilliseconds then
    Result.RequestTimeoutMilliseconds := ABudget.TimeoutMilliseconds;
end;

function THTTPGitUploadPackTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
var
  URL, Final: string;
  Headers: THTTPHeaders;
  Options: THTTPRequestOptions;
  Limit: Int64;
  Resp: THTTPResponse;
begin
  URL := UploadPackBaseURL(ARepoURL) + INFO_REFS_SUFFIX;
  SetLength(Headers, 1);
  Headers[0].Name := 'Git-Protocol';
  Headers[0].Value := 'version=2';
  Options := BudgetedOptions(FOptions, FMaxResponseBytes, ABudget, Limit);
  try
    Resp := HTTPGet(URL, Headers, Options);
  except
    on E: EHTTPResponseTooLarge do
      raise TooLarge(URL, Limit);
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
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
var
  URL: string;
  Headers: THTTPHeaders;
  Options: THTTPRequestOptions;
  Limit: Int64;
  Resp: THTTPResponse;
begin
  URL := UploadPackBaseURL(ARepoURL) + UPLOAD_PACK_SUFFIX;
  SetLength(Headers, 2);
  Headers[0].Name := 'Git-Protocol';
  Headers[0].Value := 'version=2';
  Headers[1].Name := 'Accept';
  Headers[1].Value := 'application/x-git-upload-pack-result';
  Options := BudgetedOptions(FOptions, FMaxResponseBytes, ABudget, Limit);
  { A redirected POST would be replayed as a GET; the advertisement has
    already resolved any redirect. }
  Options.MaximumRedirects := 0;
  try
    Resp := HTTPPost(URL, ARequest, 'application/x-git-upload-pack-request',
      Headers, Options);
  except
    on E: EHTTPResponseTooLarge do
      raise TooLarge(URL, Limit);
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

function TGitFixtureUploadPackTransport.ReadResponse(const APath: string;
  const ABudget: TGitRequestBudget): TBytes;
var Stream: TFileStream; Limit: Int64;
begin
  if not FileExists(APath) then
    raise EGitReachabilityError.CreateFmt(
      'test git fixture has no recorded upload-pack response (%s)', [APath]);
  Limit := EffectiveLimit(FMaxResponseBytes, ABudget);
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    if Stream.Size > Limit then raise TooLarge(APath, Limit);
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function TGitFixtureUploadPackTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
var Repository: string;
begin
  Repository := FixtureRepositoryName(ARepoURL);
  AEffectiveRepoURL := ARepoURL;
  if FLogRequests then
    AppendFixtureRequest(FRoot, 'upload-pack|' + Repository + '|advertise');
  Result := ReadResponse(FRoot + 'upload-pack/' + Repository
    + '/advertisement', ABudget);
end;

function TGitFixtureUploadPackTransport.Command(const ARepoURL: string;
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
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
    + SHA256Hex(ARequest) + '.response', ABudget);
end;
{$ENDIF}

{ ───────────────────────────────────────────────────────────────────
  Reachability proof
  ─────────────────────────────────────────────────────────────────── }

function DefaultGitProofLimits: TGitProofLimits;
begin
  Result.TimeoutMilliseconds := MAX_REACHABILITY_PROOF_MILLISECONDS;
  Result.MaxTotalBytes := MAX_REACHABILITY_PROOF_BYTES;
end;

type
  TReachabilityRun = record
    Transport: TGitUploadPackTransport;
    RepoURL: string;
    Capabilities: TGitV2Capabilities;
    Limits: TGitProofLimits;
    StartedAt: QWord;
    Requests: Integer;
    BytesReceived: Int64;
  end;

{ What the next request may spend: the time left before the proof's single
  monotonic deadline and the bytes left in its total budget. }
function NextBudget(const ARun: TReachabilityRun): TGitRequestBudget;
var Elapsed: QWord;
begin
  Elapsed := GetTickCount64 - ARun.StartedAt;
  if Elapsed >= ARun.Limits.TimeoutMilliseconds then
    raise EGitProofDeadlineExceeded.CreateFmt(
      'reachability proof exceeded its %d ms deadline',
      [ARun.Limits.TimeoutMilliseconds]);
  if ARun.BytesReceived >= ARun.Limits.MaxTotalBytes then
    raise EGitResponseTooLarge.CreateFmt(
      'reachability proof exceeded its %d-byte budget',
      [ARun.Limits.MaxTotalBytes]);
  Result.TimeoutMilliseconds := ARun.Limits.TimeoutMilliseconds - Elapsed;
  Result.MaxResponseBytes := ARun.Limits.MaxTotalBytes - ARun.BytesReceived;
end;

procedure Received(var ARun: TReachabilityRun; const ABody: TBytes);
begin
  Inc(ARun.Requests);
  Inc(ARun.BytesReceived, Length(ABody));
  { A transport that overran its allowance is still bounded here. }
  if GetTickCount64 - ARun.StartedAt > ARun.Limits.TimeoutMilliseconds then
    raise EGitProofDeadlineExceeded.CreateFmt(
      'reachability proof exceeded its %d ms deadline',
      [ARun.Limits.TimeoutMilliseconds]);
  if ARun.BytesReceived > ARun.Limits.MaxTotalBytes then
    raise EGitResponseTooLarge.CreateFmt(
      'reachability proof exceeded its %d-byte budget',
      [ARun.Limits.MaxTotalBytes]);
end;

function RunCommand(var ARun: TReachabilityRun; const ACommand: string;
  const AArguments: array of string): TBytes;
var Request: TBytes;
begin
  Request := BuildV2CommandRequest(ARun.Capabilities, ACommand, AArguments);
  Result := ARun.Transport.Command(ARun.RepoURL, Request, NextBudget(ARun));
  Received(ARun, Result);
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

{ Committer times of the tips and the target, from one shallow commits-only
  fetch. A tag tip's time is its verified target commit's. The times only
  choose which tips to probe first, so a host that refuses the request
  simply leaves the probes unordered. }
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
    on E: EGitProofDeadlineExceeded do
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
      if Graph.TryGetCommit(Graph.PeelToCommit(ATips[i].Id), Commit) then
        Result.AddOrSetValue(ATips[i].Id, Commit.CommitTime);
  finally
    Graph.Free;
  end;
end;

{ Tips to probe one at a time: the MAX_NEAREST_TIP_PROBES committed closest
  after the target (the release that first contains an old pin is usually
  the next one), then the default branch. Selecting the few nearest in one
  pass keeps this linear in the tip count. }
function ChooseProbes(const ATips: TGitTipArray; const AHeadTarget,
  ATarget: string; const ATimes: TDictionary<string, Int64>): TGitTipArray;
var
  TargetTime, Time, Other: Int64;
  i, j, n: Integer;
  Present: Boolean;

  function Before(const AFirst: TGitTip; AFirstTime: Int64;
    const ASecond: TGitTip; ASecondTime: Int64): Boolean;
  begin
    Result := (AFirstTime < ASecondTime) or ((AFirstTime = ASecondTime)
      and (AFirst.Name < ASecond.Name));
  end;

begin
  SetLength(Result, 0);
  if (ATimes <> nil) and ATimes.TryGetValue(ATarget, TargetTime) then
  begin
    SetLength(Result, MAX_NEAREST_TIP_PROBES);
    n := 0;
    for i := 0 to High(ATips) do
    begin
      if not ATimes.TryGetValue(ATips[i].Id, Time)
         or (Time < TargetTime) then Continue;
      { Insert into the small sorted prefix, dropping the farthest. }
      j := n;
      while j > 0 do
      begin
        Other := ATimes[Result[j - 1].Id];
        if not Before(ATips[i], Time, Result[j - 1], Other) then Break;
        if j < MAX_NEAREST_TIP_PROBES then Result[j] := Result[j - 1];
        Dec(j);
      end;
      if j < MAX_NEAREST_TIP_PROBES then
      begin
        Result[j] := ATips[i];
        if n < MAX_NEAREST_TIP_PROBES then Inc(n);
      end;
    end;
    SetLength(Result, n);
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
  const ARepoURL, ACommit: string; const AAdvertised: TGitRefArray;
  const ALimits: TGitProofLimits): TGitReachabilityResult;
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

  { Exact tip: the pin is the very object a well-named branch or tag names
    in the listing the resolver already made. A `^`-peel is only the host's
    claim about an annotated tag's target, so it is never an exact tip; such
    a pin is proven below from the hash-verified tag object. }
  for i := 0 to High(AAdvertised) do
    if SameText(AAdvertised[i].SHA, Target)
       and IsValidGitRefName(RefFullName(AAdvertised[i])) then
    begin
      Result.Reachable := True;
      Result.ProvingRef := RefFullName(AAdvertised[i]);
      Exit;
    end;

  Run := Default(TReachabilityRun);
  Run.Transport := ATransport;
  Run.Limits := ALimits;
  Run.StartedAt := GetTickCount64;
  try
    Body := ATransport.Advertise(ARepoURL, Run.RepoURL, NextBudget(Run));
    Received(Run, Body);
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

    Body := RunCommand(Run, 'ls-refs', ['symrefs', 'ref-prefix HEAD',
      'ref-prefix refs/heads/', 'ref-prefix refs/tags/']);
    Tips := ParseLsRefsResponse(Body, HeadTarget);
    Body := nil;
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
        { Only an explicit NAK says no have was common, i.e. the host has
          no such object; silence is a malformed answer, not a verdict. }
        if not Response.Nak then
          raise EGitReachabilityError.Create(
            'upload-pack acknowledged neither ACK nor NAK');
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
    SetLength(Remaining, Length(Tips));
    j := 0;
    for i := 0 to High(Tips) do
    begin
      IsExcluded := False;
      for Found := 0 to High(Excluded) do
        IsExcluded := IsExcluded or (Excluded[Found].Id = Tips[i].Id);
      if IsExcluded then Continue;
      Remaining[j] := Tips[i];
      Inc(j);
    end;
    SetLength(Remaining, j);
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
  const ARepoURL, ACommit: string; const AAdvertised: TGitRefArray;
  const ALimits: TGitProofLimits): TGitReachabilityResult;
begin
  try
    Result := ProveCommitReachableCore(ATransport, ARepoURL, ACommit,
      AAdvertised, ALimits);
  except
    on E: EGitPackError do
      raise EGitReachabilityError.CreateFmt('%s sent an invalid pack: %s',
        [ARepoURL, E.Message]);
  end;
end;

function ProveCommitReachable(const ATransport: TGitUploadPackTransport;
  const ARepoURL, ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult;
begin
  Result := ProveCommitReachable(ATransport, ARepoURL, ACommit, AAdvertised,
    DefaultGitProofLimits);
end;

end.
