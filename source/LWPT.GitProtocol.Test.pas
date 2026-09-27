program LWPT.GitProtocol.Test;

{ Commit-reachability proofs (ADR-0045) against recorded git upload-pack
  exchanges, plus the protocol v2 message parsers and the HTTP transport.

  The exchanges under tests/fixtures/git-reachability/upload-pack/ were
  recorded from `git upload-pack` serving the repository that
  tests/fixtures/git-reachability/make-repo.sh builds. To re-record after
  changing the requests the prover sends:

    tests/fixtures/git-reachability/make-repo.sh /tmp/reach
    LWPT_RECORD_GIT_FIXTURES=/tmp/reach ./build/lwpt test \
      source/LWPT.GitProtocol.Test.pas

  The live suite runs only with LWPT_ENABLE_NETWORK=1. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  Process,
  SysUtils,

  HTTPClient,
  LWPT.Core,
  LWPT.GitPack,
  LWPT.GitProtocol,
  TestingPascalLibrary,
  Tests.HTTPMockServer,
  Tests.Scratch;

const
  FIXTURE_DIR = 'tests/fixtures/git-reachability';
  REPO_URL = 'https://git.example.invalid/fixture/reach.git';
  NO_FILTER_REPO_URL = 'https://git.example.invalid/fixture/reach-nofilter.git';
  RECORD_ENV = 'LWPT_RECORD_GIT_FIXTURES';
  UNKNOWN_COMMIT = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

  CHECKOUT_URL = 'https://github.com/actions/checkout.git';
  { Chainguard's documented imposter commit: served under actions/checkout
    but reachable only from a fork. }
  CHECKOUT_IMPOSTER = 'c7d749a2d57b4b375d1ebcd17cfbfb60c676f18e';
  { "Add support for sparse checkouts (#1369)", 2023-06-09, on main. }
  CHECKOUT_LEGITIMATE = 'd106d4669b3bfcb17f11f83f98e1cab478e9f635';

type
  { Record mode: answers from `git upload-pack` on a local repository and
    writes each exchange under the fixture directory. }
  TRecordingTransport = class(TGitUploadPackTransport)
  private
    FRepository: string;
    function RunUploadPack(const ARepoURL: string;
      const AArguments: array of string; const AInput: TBytes): TBytes;
    function OutputDir(const ARepoURL: string): string;
  public
    constructor Create(const ARepository: string);
    function Advertise(const ARepoURL: string;
      out AEffectiveRepoURL: string): TBytes; override;
    function Command(const ARepoURL: string;
      const ARequest: TBytes): TBytes; override;
  end;

  { Fails the test if the prover makes any request. }
  TRefusingTransport = class(TGitUploadPackTransport)
  public
    function Advertise(const ARepoURL: string;
      out AEffectiveRepoURL: string): TBytes; override;
    function Command(const ARepoURL: string;
      const ARequest: TBytes): TBytes; override;
  end;

  TReachabilityTests = class(TTestSuite)
  private
    function Commit(const AName: string): string;
    function NewTransport: TGitUploadPackTransport;
    function Prove(const ACommit: string;
      const AAdvertised: TGitRefArray): TGitReachabilityResult;
    function ProveFails(const AURL, ACommit, AExpected: string;
      AMaxResponseBytes: Int64): Boolean;
  public
    procedure SetupTests; override;
    procedure TestAdvertisedTipNeedsNoRequest;
    procedure TestPeeledTagNeedsNoRequest;
    procedure TestCommitProvenFromNearestTag;
    procedure TestOldCommitProvenFromNearestTag;
    procedure TestLsRefsTipNeedsNoFetch;
    procedure TestSkewedCommitProvenThroughAllTips;
    procedure TestForkOnlyCommitIsUnreachable;
    procedure TestUnknownCommitIsReportedByNak;
    procedure TestHostWithoutFilterIsRefused;
    procedure TestOversizedResponseIsRefused;
    procedure TestAbbreviatedCommitIsRefused;
  end;

  TProtocolMessageTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestPktLineFraming;
    procedure TestCapabilitiesAcceptServicePreamble;
    procedure TestCapabilitiesRejectVersion0;
    procedure TestLsRefsKeepsOnlyBranchesAndTags;
    procedure TestLsRefsRejectsTruncation;
    procedure TestFetchDemultiplexesSideBand;
    procedure TestFetchReportsRemoteErrors;
    procedure TestFetchRejectsMalformedFraming;
  end;

  THTTPTransportTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCommandPostsProtocolV2Request;
    procedure TestOversizedBodyIsRefused;
  end;

  TLiveReachabilityTests = class(TTestSuite)
  private
    FSkipped: Boolean;
    FOptions: THTTPRequestOptions;
    FAdvertised: TGitRefArray;
    procedure ProveLive(const ACommit: string; AExpectReachable: Boolean);
  protected
    procedure BeforeAll; override;
  public
    procedure SetupTests; override;
    procedure TestImposterCommitIsUnreachable;
    procedure TestLegitimateOlderCommitIsReachable;
  end;

function Bytes(const S: AnsiString): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function Text(const B: TBytes): AnsiString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then Move(B[0], Result[1], Length(B));
end;

procedure WriteBytes(const APath: string; const AData: TBytes);
var Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(AData) > 0 then Stream.WriteBuffer(AData[0], Length(AData));
  finally
    Stream.Free;
  end;
end;

function Recording: Boolean;
begin
  Result := GetEnvironmentVariable(RECORD_ENV) <> '';
end;

{ TRecordingTransport }

constructor TRecordingTransport.Create(const ARepository: string);
begin
  inherited Create;
  FRepository := ExpandFileName(ARepository);
end;

function TRecordingTransport.OutputDir(const ARepoURL: string): string;
var Name: string;
begin
  Name := ChangeFileExt(ExtractFileName(ARepoURL), '');
  Result := FIXTURE_DIR + '/upload-pack/' + Name + '/';
end;

function TRecordingTransport.RunUploadPack(const ARepoURL: string;
  const AArguments: array of string; const AInput: TBytes): TBytes;
var
  Proc: TProcess;
  Buffer: array[0..65535] of Byte;
  Count, i, n: Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := 'git';
    { The no-filter fixture is the same repository served by a host that
      does not offer object filtering. }
    if Pos('nofilter', ARepoURL) > 0 then
    begin
      Proc.Parameters.Add('-c');
      Proc.Parameters.Add('uploadpack.allowFilter=false');
    end;
    Proc.Parameters.Add('upload-pack');
    for i := 0 to High(AArguments) do Proc.Parameters.Add(AArguments[i]);
    Proc.Parameters.Add(FRepository);
    for i := 0 to GetEnvironmentVariableCount - 1 do
      Proc.Environment.Add(GetEnvironmentString(i));
    Proc.Environment.Add('GIT_PROTOCOL=version=2');
    Proc.Options := [poUsePipes];
    Proc.Execute;
    if Length(AInput) > 0 then
      Proc.Input.WriteBuffer(AInput[0], Length(AInput));
    Proc.CloseInput;
    SetLength(Result, 0);
    repeat
      Count := Proc.Output.NumBytesAvailable;
      if Count = 0 then
      begin
        if not Proc.Running then Break;
        Sleep(5);
        Continue;
      end;
      if Count > SizeOf(Buffer) then Count := SizeOf(Buffer);
      Count := Proc.Output.Read(Buffer[0], Count);
      n := Length(Result);
      SetLength(Result, n + Count);
      Move(Buffer[0], Result[n], Count);
    until False;
    repeat
      Count := Proc.Output.Read(Buffer[0], SizeOf(Buffer));
      if Count <= 0 then Break;
      n := Length(Result);
      SetLength(Result, n + Count);
      Move(Buffer[0], Result[n], Count);
    until False;
  finally
    Proc.Free;
  end;
end;

function TRecordingTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string): TBytes;
begin
  AEffectiveRepoURL := ARepoURL;
  { Smart-HTTP hosts such as GitHub put the service announcement in front
    of the v2 capability advertisement; keep it so the parser sees the
    wire shape of a real host. }
  Result := Bytes(PktLine('# service=git-upload-pack') + PktFlush
    + Text(RunUploadPack(ARepoURL, ['--http-backend-info-refs'], nil)));
  WriteBytes(OutputDir(ARepoURL) + 'advertisement', Result);
end;

function TRecordingTransport.Command(const ARepoURL: string;
  const ARequest: TBytes): TBytes;
var Key: string;
begin
  Result := RunUploadPack(ARepoURL, ['--stateless-rpc'], ARequest);
  Key := SHA256Hex(ARequest);
  WriteBytes(OutputDir(ARepoURL) + Key + '.request', ARequest);
  WriteBytes(OutputDir(ARepoURL) + Key + '.response', Result);
end;

{ TRefusingTransport }

function TRefusingTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string): TBytes;
begin
  raise Exception.Create('unexpected upload-pack advertisement request');
end;

function TRefusingTransport.Command(const ARepoURL: string;
  const ARequest: TBytes): TBytes;
begin
  raise Exception.Create('unexpected upload-pack command request');
end;

{ TReachabilityTests }

function TReachabilityTests.Commit(const AName: string): string;
var Lines: TStringList; i: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FIXTURE_DIR + '/commits.txt');
    for i := 0 to Lines.Count - 1 do
      if Copy(Lines[i], 1, Length(AName) + 1) = AName + ' ' then
        Exit(Copy(Lines[i], Length(AName) + 2, 40));
  finally
    Lines.Free;
  end;
  raise Exception.Create('fixture commit not found: ' + AName);
end;

function TReachabilityTests.NewTransport: TGitUploadPackTransport;
begin
  if Recording then
    Result := TRecordingTransport.Create(GetEnvironmentVariable(RECORD_ENV))
  else
    Result := TGitFixtureUploadPackTransport.Create(FIXTURE_DIR);
end;

function TReachabilityTests.Prove(const ACommit: string;
  const AAdvertised: TGitRefArray): TGitReachabilityResult;
var Transport: TGitUploadPackTransport;
begin
  Transport := NewTransport;
  try
    Result := ProveCommitReachable(Transport, REPO_URL, ACommit, AAdvertised);
  finally
    Transport.Free;
  end;
end;

function TReachabilityTests.ProveFails(const AURL, ACommit,
  AExpected: string; AMaxResponseBytes: Int64): Boolean;
var Transport: TGitUploadPackTransport; Message: string;
begin
  if Recording then
    Transport := TRecordingTransport.Create(GetEnvironmentVariable(RECORD_ENV))
  else
    Transport := TGitFixtureUploadPackTransport.Create(FIXTURE_DIR,
      AMaxResponseBytes);
  Message := '';
  try
    try
      ProveCommitReachable(Transport, AURL, ACommit, nil);
    except
      on E: EGitReachabilityError do
        Message := E.Message;
    end;
  finally
    Transport.Free;
  end;
  { Record mode has no cap; it only needs to capture the exchanges. }
  Result := Recording and (AMaxResponseBytes > 0)
    or ((Message <> '') and (Pos(AExpected, Message) > 0));
  if not Result then
    WriteLn('    expected error containing "', AExpected, '", got "',
      Message, '"');
end;

procedure TReachabilityTests.TestAdvertisedTipNeedsNoRequest;
var Refs: TGitRefArray; Transport: TRefusingTransport;
  Outcome: TGitReachabilityResult;
begin
  SetLength(Refs, 1);
  Refs[0] := Default(TGitRef);
  Refs[0].Kind := rkBranch;
  Refs[0].Name := 'main';
  Refs[0].SHA := Commit('c6');
  Transport := TRefusingTransport.Create;
  try
    Outcome := ProveCommitReachable(Transport, REPO_URL,
      UpperCase(Commit('c6')), Refs);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/heads/main');
  Expect<Integer>(Outcome.Requests).ToBe(0);
end;

procedure TReachabilityTests.TestPeeledTagNeedsNoRequest;
var Refs: TGitRefArray; Transport: TRefusingTransport;
  Outcome: TGitReachabilityResult;
begin
  SetLength(Refs, 1);
  Refs[0] := Default(TGitRef);
  Refs[0].Kind := rkTag;
  Refs[0].Name := 'v0.2.0';
  Refs[0].SHA := Commit('v0.2.0-tag');
  Refs[0].PeeledSHA := Commit('c4');
  Transport := TRefusingTransport.Create;
  try
    Outcome := ProveCommitReachable(Transport, REPO_URL, Commit('c4'), Refs);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/tags/v0.2.0');
end;

procedure TReachabilityTests.TestCommitProvenFromNearestTag;
var Outcome: TGitReachabilityResult;
begin
  { c3 is on main below the annotated tag v0.2.0 (c4), the tip committed
    closest after it: advertisement, ls-refs, commit times, one probe. }
  Outcome := Prove(Commit('c3'), nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/tags/v0.2.0');
  Expect<Integer>(Outcome.Requests).ToBe(4);
end;

procedure TReachabilityTests.TestOldCommitProvenFromNearestTag;
var Outcome: TGitReachabilityResult;
begin
  Outcome := Prove(Commit('c1'), nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/tags/v0.1.0');
  Expect<Integer>(Outcome.Requests).ToBe(4);
end;

procedure TReachabilityTests.TestLsRefsTipNeedsNoFetch;
var Outcome: TGitReachabilityResult;
begin
  { Without a resolver listing, a pin equal to an ls-refs tip still needs
    no fetch: advertisement plus ls-refs. }
  Outcome := Prove(Commit('c2'), nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/tags/v0.1.0');
  Expect<Integer>(Outcome.Requests).ToBe(2);
end;

procedure TReachabilityTests.TestSkewedCommitProvenThroughAllTips;
var Outcome: TGitReachabilityResult;
begin
  { r1 claims a commit date later than every tip, so no tip is "near" it
    and the default-branch probe cannot reach it. The all-tips round still
    proves it through release/0.1: dates only order probes. }
  Outcome := Prove(Commit('r1'), nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/heads/release/0.1');
  Expect<Integer>(Outcome.Requests).ToBe(5);
end;

procedure TReachabilityTests.TestForkOnlyCommitIsUnreachable;
var Outcome: TGitReachabilityResult;
begin
  { f1 exists only under refs/pull/1/head, on top of c3 from main. The host
    acknowledges it (it has the object), the main probe cannot prove it,
    and pack(all tips --not f1) holds no commit whose parent is f1. }
  Outcome := Prove(Commit('f1'), nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(False);
  Expect<Boolean>(Outcome.Known).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('');
  Expect<Integer>(Outcome.Requests).ToBe(5);
end;

procedure TReachabilityTests.TestUnknownCommitIsReportedByNak;
var Outcome: TGitReachabilityResult;
begin
  Outcome := Prove(UNKNOWN_COMMIT, nil);
  Expect<Boolean>(Outcome.Reachable).ToBe(False);
  Expect<Boolean>(Outcome.Known).ToBe(False);
end;

procedure TReachabilityTests.TestHostWithoutFilterIsRefused;
begin
  Expect<Boolean>(ProveFails(NO_FILTER_REPO_URL, Commit('c3'),
    'does not advertise the fetch "filter" capability', 0)).ToBe(True);
end;

procedure TReachabilityTests.TestOversizedResponseIsRefused;
begin
  { Large enough for the advertisement and ls-refs, too small for the
    first pack-bearing response. }
  Expect<Boolean>(ProveFails(REPO_URL, Commit('c3'), 'proof limit',
    1024)).ToBe(True);
end;

procedure TReachabilityTests.TestAbbreviatedCommitIsRefused;
var Transport: TRefusingTransport; Message: string;
begin
  Transport := TRefusingTransport.Create;
  Message := '';
  try
    try
      ProveCommitReachable(Transport, REPO_URL, Copy(Commit('c3'), 1, 12),
        nil);
    except
      on E: EGitReachabilityError do Message := E.Message;
    end;
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('not a full 40-character commit id', Message) > 0)
    .ToBe(True);
end;

procedure TReachabilityTests.SetupTests;
begin
  Test('a pin equal to an advertised tip needs no request',
    TestAdvertisedTipNeedsNoRequest);
  Test('a pin equal to a peeled annotated tag needs no request',
    TestPeeledTagNeedsNoRequest);
  Test('a commit below a tag is proven from the nearest tag',
    TestCommitProvenFromNearestTag);
  Test('an old commit is proven from the first tag after it',
    TestOldCommitProvenFromNearestTag);
  Test('an ls-refs tip is accepted without fetching',
    TestLsRefsTipNeedsNoFetch);
  Test('a commit with a skewed date is proven by the all-tips round',
    TestSkewedCommitProvenThroughAllTips);
  Test('a fork-only commit is unreachable', TestForkOnlyCommitIsUnreachable);
  Test('an object the host does not have is reported as unknown',
    TestUnknownCommitIsReportedByNak);
  Test('a host without the filter capability is refused',
    TestHostWithoutFilterIsRefused);
  Test('a response over the size limit is refused',
    TestOversizedResponseIsRefused);
  Test('an abbreviated commit id is refused before any request',
    TestAbbreviatedCommitIsRefused);
end;

{ TProtocolMessageTests }

function Pkt(const S: string): AnsiString;
begin
  Result := PktLine(S);
end;

function SideBand(AChannel: Byte; const AData: AnsiString): AnsiString;
begin
  Result := LowerCase(IntToHex(Length(AData) + 5, 4)) + AnsiChar(AChannel)
    + AData;
end;

procedure TProtocolMessageTests.TestPktLineFraming;
var Request: AnsiString; Capabilities: TGitV2Capabilities;
begin
  Expect<string>(PktLine('ls-refs')).ToBe('000cls-refs'#10);
  Capabilities := Default(TGitV2Capabilities);
  Capabilities.Agent := True;
  Capabilities.ObjectFormat := 'sha1';
  Request := Text(BuildV2CommandRequest(Capabilities, 'fetch',
    ['done']));
  Expect<string>(Request).ToBe('0012command=fetch'#10 + '000fagent=lwpt'#10
    + '0017object-format=sha1'#10 + '0001' + '0009done'#10 + '0000');
  Capabilities := Default(TGitV2Capabilities);
  Request := Text(BuildV2CommandRequest(Capabilities, 'ls-refs', []));
  Expect<string>(Request).ToBe('0014command=ls-refs'#10 + '0001' + '0000');
end;

procedure TProtocolMessageTests.TestCapabilitiesAcceptServicePreamble;
var Capabilities: TGitV2Capabilities;
begin
  Capabilities := ParseV2Capabilities(Bytes(Pkt('# service=git-upload-pack')
    + PktFlush + Pkt('version 2') + Pkt('agent=git/github-x')
    + Pkt('ls-refs=unborn') + Pkt('fetch=shallow wait-for-done filter')
    + Pkt('server-option') + Pkt('object-format=sha1') + PktFlush));
  Expect<Boolean>(Capabilities.Version2).ToBe(True);
  Expect<Boolean>(Capabilities.LsRefs).ToBe(True);
  Expect<Boolean>(Capabilities.Fetch).ToBe(True);
  Expect<Boolean>(Capabilities.FetchFilter).ToBe(True);
  Expect<Boolean>(Capabilities.Agent).ToBe(True);
  Expect<string>(Capabilities.ObjectFormat).ToBe('sha1');
  Capabilities := ParseV2Capabilities(Bytes(Pkt('version 2')
    + Pkt('ls-refs') + Pkt('fetch=shallow') + PktFlush));
  Expect<Boolean>(Capabilities.FetchFilter).ToBe(False);
end;

procedure TProtocolMessageTests.TestCapabilitiesRejectVersion0;
var Capabilities: TGitV2Capabilities;
begin
  Capabilities := ParseV2Capabilities(Bytes(Pkt('# service=git-upload-pack')
    + PktFlush + Pkt(StringOfChar('a', 40) + ' HEAD'#0'multi_ack filter')
    + PktFlush));
  Expect<Boolean>(Capabilities.Version2).ToBe(False);
  Expect<Boolean>(Capabilities.FetchFilter).ToBe(False);
end;

procedure TProtocolMessageTests.TestLsRefsKeepsOnlyBranchesAndTags;
var Tips: TGitTipArray; Head: string;
begin
  Tips := ParseLsRefsResponse(Bytes(
    Pkt(StringOfChar('1', 40) + ' HEAD symref-target:refs/heads/main')
    + Pkt(StringOfChar('1', 40) + ' refs/heads/main')
    + Pkt(StringOfChar('2', 40) + ' refs/tags/v1 peeled:'
      + StringOfChar('3', 40))
    + Pkt(StringOfChar('4', 40) + ' refs/pull/7/head')
    + Pkt(StringOfChar('5', 40) + ' refs/merge-requests/2/head')
    + PktFlush), Head);
  Expect<string>(Head).ToBe('refs/heads/main');
  Expect<Integer>(Length(Tips)).ToBe(2);
  Expect<string>(Tips[0].Name).ToBe('refs/heads/main');
  Expect<string>(Tips[1].Name).ToBe('refs/tags/v1');
  Expect<string>(Tips[1].Id).ToBe(StringOfChar('3', 40));
end;

procedure TProtocolMessageTests.TestLsRefsRejectsTruncation;
var Raised: Boolean; Head: string;
begin
  Raised := False;
  try
    ParseLsRefsResponse(Bytes(Pkt(StringOfChar('1', 40)
      + ' refs/heads/main')), Head);
  except
    on E: EGitReachabilityError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  Raised := False;
  try
    ParseLsRefsResponse(Bytes(Pkt('xyz refs/heads/main') + PktFlush), Head);
  except
    on E: EGitReachabilityError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TProtocolMessageTests.TestFetchDemultiplexesSideBand;
var Body: TBytes; Response: TGitFetchResponse;
begin
  Body := Bytes(Pkt('acknowledgments') + Pkt('ACK ' + StringOfChar('a', 40))
    + Pkt('ready') + PktDelim + Pkt('packfile')
    + SideBand(2, 'progress') + SideBand(1, 'PA') + SideBand(1, 'CK'#0)
    + PktFlush);
  Response := ParseFetchResponse(Body);
  Expect<Boolean>(Response.Acknowledged).ToBe(True);
  Expect<Boolean>(Response.Ready).ToBe(True);
  Expect<Boolean>(Response.HasPack).ToBe(True);
  Expect<string>(Text(Response.Pack)).ToBe('PACK'#0);
  Expect<Integer>(Length(Body)).ToBe(0);

  Body := Bytes(Pkt('acknowledgments') + Pkt('NAK') + PktFlush);
  Response := ParseFetchResponse(Body);
  Expect<Boolean>(Response.Nak).ToBe(True);
  Expect<Boolean>(Response.HasPack).ToBe(False);
end;

procedure TProtocolMessageTests.TestFetchReportsRemoteErrors;
var Body: TBytes; Message: string;
begin
  Body := Bytes(Pkt('ERR upload-pack: not our ref ' + StringOfChar('d', 40)));
  Message := '';
  try
    ParseFetchResponse(Body);
  except
    on E: EGitReachabilityError do Message := E.Message;
  end;
  Expect<Boolean>(Pos('not our ref', Message) > 0).ToBe(True);
  Body := Bytes(Pkt('packfile') + SideBand(3, 'fatal: out of memory')
    + PktFlush);
  Message := '';
  try
    ParseFetchResponse(Body);
  except
    on E: EGitReachabilityError do Message := E.Message;
  end;
  Expect<Boolean>(Pos('out of memory', Message) > 0).ToBe(True);
end;

procedure TProtocolMessageTests.TestFetchRejectsMalformedFraming;

  function Fails(const AResponse: AnsiString): Boolean;
  var Body: TBytes;
  begin
    Body := Bytes(AResponse);
    Result := False;
    try
      ParseFetchResponse(Body);
    except
      on E: EGitReachabilityError do Result := True;
    end;
  end;

begin
  { No terminating flush. }
  Expect<Boolean>(Fails(Pkt('packfile') + SideBand(1, 'PACK'))).ToBe(True);
  { A length that runs past the end. }
  Expect<Boolean>(Fails('00ffpackfile')).ToBe(True);
  { Non-hex length. }
  Expect<Boolean>(Fails('zzzz')).ToBe(True);
  { Reserved length 3. }
  Expect<Boolean>(Fails('0003')).ToBe(True);
  { Unknown section, and an unknown side-band channel. }
  Expect<Boolean>(Fails(Pkt('packfile-uris') + PktFlush)).ToBe(True);
  Expect<Boolean>(Fails(Pkt('packfile') + SideBand(9, 'x') + PktFlush))
    .ToBe(True);
end;

procedure TProtocolMessageTests.SetupTests;
begin
  Test('pkt-lines and v2 command requests are framed exactly',
    TestPktLineFraming);
  Test('v2 capabilities parse after a smart-HTTP service preamble',
    TestCapabilitiesAcceptServicePreamble);
  Test('a v0 advertisement is not mistaken for v2',
    TestCapabilitiesRejectVersion0);
  Test('ls-refs keeps branches and peeled tags and drops fork refs',
    TestLsRefsKeepsOnlyBranchesAndTags);
  Test('ls-refs rejects truncated or malformed responses',
    TestLsRefsRejectsTruncation);
  Test('fetch responses demultiplex side-band pack data in place',
    TestFetchDemultiplexesSideBand);
  Test('fetch responses surface ERR lines and side-band errors',
    TestFetchReportsRemoteErrors);
  Test('fetch responses with malformed framing are rejected',
    TestFetchRejectsMalformedFraming);
end;

{ THTTPTransportTests }

function MockResponse(const ABody: AnsiString): TBytes;
begin
  Result := BuildSimpleResponse(Bytes(ABody));
end;

procedure THTTPTransportTests.TestCommandPostsProtocolV2Request;
var
  Server: TMockHTTPServer;
  Transport: THTTPGitUploadPackTransport;
  Response: TBytes;
  Request: string;
begin
  Server := TMockHTTPServer.Create(MockResponse(Pkt('acknowledgments')
    + Pkt('NAK') + PktFlush));
  try
    Server.Start;
    Transport := THTTPGitUploadPackTransport.Create(DefaultHTTPRequestOptions);
    try
      Response := Transport.Command('http://127.0.0.1:'
        + IntToStr(Server.Port) + '/fixture/reach.git/',
        Bytes(PktLine('command=fetch') + PktDelim + PktFlush));
    finally
      Transport.Free;
    end;
    Server.WaitDone;
    Request := Text(Server.ReceivedRequest);
  finally
    Server.Free;
  end;
  Expect<Boolean>(Pos('POST /fixture/reach.git/git-upload-pack HTTP/1.1',
    Request) = 1).ToBe(True);
  Expect<Boolean>(Pos('Git-Protocol: version=2', Request) > 0).ToBe(True);
  Expect<Boolean>(Pos(
    'Content-Type: application/x-git-upload-pack-request', Request) > 0)
    .ToBe(True);
  Expect<Boolean>(Pos('0012command=fetch'#10'00010000', Request) > 0)
    .ToBe(True);
  Expect<string>(Text(Response)).ToBe(Pkt('acknowledgments') + Pkt('NAK')
    + PktFlush);
end;

procedure THTTPTransportTests.TestOversizedBodyIsRefused;
var
  Server: TMockHTTPServer;
  Transport: THTTPGitUploadPackTransport;
  Message, Effective: string;
begin
  Server := TMockHTTPServer.Create(MockResponse(StringOfChar('x', 4096)));
  try
    Server.Start;
    Transport := THTTPGitUploadPackTransport.Create(DefaultHTTPRequestOptions,
      1024);
    Message := '';
    try
      try
        Transport.Advertise('http://127.0.0.1:' + IntToStr(Server.Port)
          + '/fixture/reach.git', Effective);
      except
        on E: EGitResponseTooLarge do Message := E.Message;
      end;
    finally
      Transport.Free;
    end;
    Server.WaitDone;
  finally
    Server.Free;
  end;
  Expect<Boolean>(Pos('exceeds the 1024-byte proof limit', Message) > 0)
    .ToBe(True);
end;

procedure THTTPTransportTests.SetupTests;
begin
  Test('commands are POSTed to git-upload-pack as protocol v2',
    TestCommandPostsProtocolV2Request);
  Test('a response over the cap is refused as too large',
    TestOversizedBodyIsRefused);
end;

{ TLiveReachabilityTests }

procedure TLiveReachabilityTests.BeforeAll;
begin
  FSkipped := GetEnvironmentVariable('LWPT_ENABLE_NETWORK') <> '1';
  if FSkipped then
  begin
    WriteLn('  [skip] LWPT_ENABLE_NETWORK=1 not set; live reachability '
      + 'tests skipped');
    Exit;
  end;
  { The same destination policy install applies to a GitHub dependency. }
  FOptions := DefaultHTTPRequestOptions;
  FOptions.Destination.AllowedHosts := ['github.com'];
  FOptions.Destination.PrivateAddresses := papDeny;
  try
    FAdvertised := ListRemoteRefs(CHECKOUT_URL, FOptions);
  except
    on E: EHTTPError do
      if (Pos('Failed to connect', E.Message) > 0)
         or (Pos('Failed to resolve', E.Message) > 0) then
      begin
        WriteLn('  [skip] github.com unreachable: ', E.Message);
        FSkipped := True;
      end
      else
        raise;
  end;
end;

procedure TLiveReachabilityTests.ProveLive(const ACommit: string;
  AExpectReachable: Boolean);
var
  Transport: THTTPGitUploadPackTransport;
  Outcome: TGitReachabilityResult;
  Started: QWord;
begin
  if FSkipped then
  begin
    Expect<Boolean>(True).ToBe(True);
    Exit;
  end;
  Transport := THTTPGitUploadPackTransport.Create(FOptions);
  try
    Started := GetTickCount64;
    Outcome := ProveCommitReachable(Transport, CHECKOUT_URL, ACommit,
      FAdvertised);
    WriteLn(Format('    %s: reachable=%s known=%s via "%s", %d requests, '
      + '%d bytes, %d ms', [Copy(ACommit, 1, 12),
      BoolToStr(Outcome.Reachable, True), BoolToStr(Outcome.Known, True),
      Outcome.ProvingRef, Outcome.Requests, Outcome.BytesReceived,
      GetTickCount64 - Started]));
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Outcome.Reachable).ToBe(AExpectReachable);
  Expect<Boolean>(Outcome.Known).ToBe(True);
end;

procedure TLiveReachabilityTests.TestImposterCommitIsUnreachable;
begin
  ProveLive(CHECKOUT_IMPOSTER, False);
end;

procedure TLiveReachabilityTests.TestLegitimateOlderCommitIsReachable;
begin
  ProveLive(CHECKOUT_LEGITIMATE, True);
end;

procedure TLiveReachabilityTests.SetupTests;
begin
  Test('actions/checkout imposter commit is unreachable',
    TestImposterCommitIsUnreachable);
  Test('an older actions/checkout main commit is reachable',
    TestLegitimateOlderCommitIsReachable);
end;

begin
  TestRunnerProgram.AddSuite(TReachabilityTests.Create(
    'git reachability: recorded upload-pack exchanges'));
  TestRunnerProgram.AddSuite(TProtocolMessageTests.Create(
    'git reachability: protocol v2 messages'));
  TestRunnerProgram.AddSuite(THTTPTransportTests.Create(
    'git reachability: HTTP transport'));
  TestRunnerProgram.AddSuite(TLiveReachabilityTests.Create(
    'git reachability: live GitHub'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
