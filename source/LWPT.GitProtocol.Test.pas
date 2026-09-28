program LWPT.GitProtocol.Test;

{ Commit-reachability proofs (ADR-0047) against recorded git upload-pack
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
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
  end;

  { Fails the test if the prover makes any request. }
  TRefusingTransport = class(TGitUploadPackTransport)
  public
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
  end;

  { Wraps another transport and replaces its ls-refs answer, so a host can
    lie about tips while every fetch still reaches real upload-pack. }
  TLsRefsOverrideTransport = class(TGitUploadPackTransport)
  private
    FInner: TGitUploadPackTransport;
    FLsRefs: TBytes;
  public
    constructor Create(AInner: TGitUploadPackTransport;
      const ALsRefs: TBytes);
    destructor Destroy; override;
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
  end;

  { Answers from fixed bytes per command, for framing cases no real host
    produces. }
  TCannedTransport = class(TGitUploadPackTransport)
  private
    FAdvertisement, FLsRefs, FFetch: TBytes;
    function Answer(const ABody: TBytes;
      const ABudget: TGitRequestBudget): TBytes;
  public
    DelayMilliseconds: Cardinal;
    DatesResponse: TBytes;
    Budgets: array of TGitRequestBudget;
    constructor Create(const AAdvertisement, ALsRefs, AFetch: TBytes);
    function Advertise(const ARepoURL: string; out AEffectiveRepoURL: string;
      const ABudget: TGitRequestBudget): TBytes; override;
    function Command(const ARepoURL: string; const ARequest: TBytes;
      const ABudget: TGitRequestBudget): TBytes; override;
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
    procedure TestPeeledTagMatchNeedsProof;
    procedure TestLyingPeeledTagIsNotTrusted;
    procedure TestInvalidAdvertisedNameIsNotAShortcut;
    procedure TestMissingNakIsAProtocolError;
    procedure TestProofSharesOneDeadline;
    procedure TestProofSharesOneByteBudget;
    procedure TestDateFetchInvalidPackFailsTheProof;
    procedure TestDateFetchRefusalIsTolerated;
    procedure TestAckForUnofferedObjectIsRefused;
    procedure TestLsRefsAcceptanceHonoursTheDeadline;
    procedure TestAcknowledgmentsAfterDoneAreRefused;
    procedure TestProofTipCapHasAClearError;
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
    procedure TestLsRefsIgnoresPeeledClaims;
    procedure TestLsRefsRejectsInvalidRefNames;
    procedure TestLsRefsDeduplicatesLinearly;
    procedure TestLsRefsEnforcesCountLimits;
    procedure TestRequestSizeIsCapped;
    procedure TestRequestSizeCountsTheFlush;
    procedure TestAcknowledgmentsAreValidated;
    procedure TestLegacyListingRejectsInvalidNames;
    procedure TestLegacyListingRejectsMalformedFraming;
    procedure TestLegacyListingIndexesPeelsLinearly;
    procedure TestLegacyListingEnforcesLimits;
    procedure TestLegacyListingRequiresItsTerminalFlush;
    procedure TestCapabilitiesRequireTheirTerminalFlush;
  end;

  THTTPTransportTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestCommandPostsProtocolV2Request;
    procedure TestOversizedBodyIsRefused;
    procedure TestRedirectBodiesCountAgainstTheBudget;
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
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
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
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
var Key: string;
begin
  Result := RunUploadPack(ARepoURL, ['--stateless-rpc'], ARequest);
  Key := SHA256Hex(ARequest);
  WriteBytes(OutputDir(ARepoURL) + Key + '.request', ARequest);
  WriteBytes(OutputDir(ARepoURL) + Key + '.response', Result);
end;

{ TRefusingTransport }

function TRefusingTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
begin
  raise Exception.Create('unexpected upload-pack advertisement request');
end;

function TRefusingTransport.Command(const ARepoURL: string;
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
begin
  raise Exception.Create('unexpected upload-pack command request');
end;

function IsLsRefsRequest(const ARequest: TBytes): Boolean;
var Head: AnsiString;
begin
  SetLength(Head, 19);
  if Length(ARequest) < 19 then Exit(False);
  Move(ARequest[0], Head[1], 19);
  Result := Head = '0014command=ls-refs';
end;

constructor TLsRefsOverrideTransport.Create(AInner: TGitUploadPackTransport;
  const ALsRefs: TBytes);
begin
  inherited Create;
  FInner := AInner;
  FLsRefs := ALsRefs;
end;

destructor TLsRefsOverrideTransport.Destroy;
begin
  FInner.Free;
  inherited Destroy;
end;

function TLsRefsOverrideTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
begin
  Result := FInner.Advertise(ARepoURL, AEffectiveRepoURL, ABudget);
end;

function TLsRefsOverrideTransport.Command(const ARepoURL: string;
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
begin
  if IsLsRefsRequest(ARequest) then
    Result := Copy(FLsRefs)
  else
    Result := FInner.Command(ARepoURL, ARequest, ABudget);
end;

constructor TCannedTransport.Create(const AAdvertisement, ALsRefs,
  AFetch: TBytes);
begin
  inherited Create;
  FAdvertisement := AAdvertisement;
  FLsRefs := ALsRefs;
  FFetch := AFetch;
end;

function TCannedTransport.Answer(const ABody: TBytes;
  const ABudget: TGitRequestBudget): TBytes;
begin
  SetLength(Budgets, Length(Budgets) + 1);
  Budgets[High(Budgets)] := ABudget;
  if DelayMilliseconds > 0 then Sleep(DelayMilliseconds);
  if Length(ABody) > ABudget.MaxResponseBytes then
    raise EGitResponseTooLarge.Create('canned response exceeds the budget');
  Result := Copy(ABody);
end;

function TCannedTransport.Advertise(const ARepoURL: string;
  out AEffectiveRepoURL: string; const ABudget: TGitRequestBudget): TBytes;
begin
  AEffectiveRepoURL := ARepoURL;
  Result := Answer(FAdvertisement, ABudget);
end;

function TCannedTransport.Command(const ARepoURL: string;
  const ARequest: TBytes; const ABudget: TGitRequestBudget): TBytes;
begin
  if IsLsRefsRequest(ARequest) then
    Result := Answer(FLsRefs, ABudget)
  else if (Length(DatesResponse) > 0)
     and (Pos('deepen 1', Text(ARequest)) > 0) then
    Result := Answer(DatesResponse, ABudget)
  else
    Result := Answer(FFetch, ABudget);
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

procedure TReachabilityTests.TestPeeledTagMatchNeedsProof;
var Refs: TGitRefArray; Outcome: TGitReachabilityResult;
begin
  { A peeled (^-brace) line is the host's unverified claim about what the tag object
    points to. Matching it is not proof: the tag object and its target
    must arrive hash-verified in a pack. }
  SetLength(Refs, 1);
  Refs[0] := Default(TGitRef);
  Refs[0].Kind := rkTag;
  Refs[0].Name := 'v0.2.0';
  Refs[0].SHA := Commit('v0.2.0-tag');
  Refs[0].PeeledSHA := Commit('c4');
  Outcome := Prove(Commit('c4'), Refs);
  Expect<Boolean>(Outcome.Reachable).ToBe(True);
  Expect<string>(Outcome.ProvingRef).ToBe('refs/tags/v0.2.0');
  Expect<Boolean>(Outcome.Requests > 0).ToBe(True);
end;

procedure TReachabilityTests.TestLyingPeeledTagIsNotTrusted;
var
  Transport: TGitUploadPackTransport;
  Outcome: TGitReachabilityResult;
begin
  { The host advertises the genuine v0.2.0 tag object but claims it peels
    to the fork-only f1, and gives main a peel it cannot have. The pack
    for the real tag object shows it points at c4. }
  Transport := TLsRefsOverrideTransport.Create(NewTransport, Bytes(
    PktLine(Commit('c6') + ' HEAD symref-target:refs/heads/main')
    + PktLine(Commit('c6') + ' refs/heads/main peeled:' + Commit('f1'))
    + PktLine(Commit('v0.2.0-tag') + ' refs/tags/v0.2.0 peeled:'
      + Commit('f1'))
    + PktFlush));
  try
    Outcome := ProveCommitReachable(Transport, REPO_URL, Commit('f1'), nil);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Outcome.Reachable).ToBe(False);
  Expect<Boolean>(Outcome.Known).ToBe(True);
end;

procedure TReachabilityTests.TestInvalidAdvertisedNameIsNotAShortcut;
var Refs: TGitRefArray; Transport: TRefusingTransport; Raised: Boolean;
begin
  { A resolver listing entry whose name is not a valid ref (here carrying a
    terminal escape) never proves anything by itself. }
  SetLength(Refs, 1);
  Refs[0] := Default(TGitRef);
  Refs[0].Kind := rkBranch;
  Refs[0].Name := 'main'#27'[2J';
  Refs[0].SHA := Commit('c6');
  Transport := TRefusingTransport.Create;
  Raised := False;
  try
    try
      ProveCommitReachable(Transport, REPO_URL, Commit('c6'), Refs);
    except
      on E: Exception do Raised := True;
    end;
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TReachabilityTests.TestMissingNakIsAProtocolError;
var Transport: TCannedTransport; Message: string;
begin
  { An acknowledgments section with neither ACK, ready, nor NAK is not an
    answer; it must not be read as "the host has no such object". }
  Transport := TCannedTransport.Create(
    Bytes(PktLine('version 2') + PktLine('ls-refs') + PktLine('fetch=shallow filter')
      + PktFlush),
    Bytes(PktLine(Commit('c6') + ' refs/heads/main') + PktFlush),
    Bytes(PktLine('acknowledgments') + PktFlush));
  Message := '';
  try
    try
      ProveCommitReachable(Transport, REPO_URL, Commit('c3'), nil);
    except
      on E: EGitReachabilityError do Message := E.Message;
    end;
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('neither ACK nor NAK', Message) > 0).ToBe(True);
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

function CannedHost: TCannedTransport;
begin
  Result := TCannedTransport.Create(
    Bytes(PktLine('version 2') + PktLine('ls-refs')
      + PktLine('fetch=shallow filter') + PktFlush),
    Bytes(PktLine(StringOfChar('6', 40) + ' refs/heads/main') + PktFlush),
    Bytes(PktLine('acknowledgments') + PktLine('NAK') + PktFlush));
end;

procedure TReachabilityTests.TestProofSharesOneDeadline;
var
  Transport: TCannedTransport;
  Limits: TGitProofLimits;
  Message: string;
begin
  { Each request is well inside any per-request timeout, but together they
    outlast the proof's single deadline; later requests get only what is
    left of it. }
  Transport := CannedHost;
  Transport.DelayMilliseconds := 120;
  Limits := DefaultGitProofLimits;
  Limits.TimeoutMilliseconds := 300;
  Message := '';
  try
    try
      ProveCommitReachable(Transport, REPO_URL, StringOfChar('3', 40), nil,
        Limits);
    except
      on E: EGitProofDeadlineExceeded do Message := E.Message;
    end;
    Expect<Boolean>(Pos('300 ms deadline', Message) > 0).ToBe(True);
    Expect<Boolean>(Length(Transport.Budgets) >= 2).ToBe(True);
    Expect<Boolean>(Transport.Budgets[1].TimeoutMilliseconds
      < Transport.Budgets[0].TimeoutMilliseconds).ToBe(True);
    Expect<Boolean>(Transport.Budgets[0].TimeoutMilliseconds <= 300)
      .ToBe(True);
  finally
    Transport.Free;
  end;
end;

procedure TReachabilityTests.TestProofSharesOneByteBudget;
var
  Transport: TCannedTransport;
  Limits: TGitProofLimits;
  Raised: Boolean;
begin
  { The advertisement alone fits; the ls-refs answer only fits what is
    left of the proof's total, not a fresh per-response allowance. }
  Transport := CannedHost;
  Limits := DefaultGitProofLimits;
  Limits.MaxTotalBytes := 80;
  Raised := False;
  try
    try
      ProveCommitReachable(Transport, REPO_URL, StringOfChar('3', 40), nil,
        Limits);
    except
      on E: EGitResponseTooLarge do Raised := True;
    end;
    Expect<Boolean>(Raised).ToBe(True);
    Expect<Boolean>(Transport.Budgets[1].MaxResponseBytes
      < Transport.Budgets[0].MaxResponseBytes).ToBe(True);
  finally
    Transport.Free;
  end;
end;

function TwoTipHost(const AFetch: AnsiString): TCannedTransport;
begin
  Result := TCannedTransport.Create(
    Bytes(PktLine('version 2') + PktLine('ls-refs')
      + PktLine('fetch=shallow filter') + PktFlush),
    Bytes(PktLine(StringOfChar('6', 40) + ' refs/heads/main')
      + PktLine(StringOfChar('7', 40) + ' refs/tags/v1') + PktFlush),
    Bytes(AFetch));
end;

function ProofError(ATransport: TGitUploadPackTransport;
  out AOutcome: TGitReachabilityResult): string;
begin
  Result := '';
  AOutcome := Default(TGitReachabilityResult);
  try
    AOutcome := ProveCommitReachable(ATransport, REPO_URL,
      StringOfChar('3', 40), nil);
  except
    on E: EGitReachabilityError do Result := E.Message;
  end;
end;

procedure TReachabilityTests.TestDateFetchInvalidPackFailsTheProof;
var Transport: TCannedTransport; Outcome: TGitReachabilityResult;
  Message: string;
begin
  { The date fetch only orders probes, but its pack is still evidence the
    host sent: a pack that fails validation fails the proof instead of
    being skipped. }
  Transport := TwoTipHost(PktLine('acknowledgments') + PktLine('NAK')
    + PktFlush);
  try
    Transport.DatesResponse := Bytes(PktLine('packfile')
      + LowerCase(IntToHex(4 + 1 + 32, 4)) + #1 + 'PACK'
      + StringOfChar(#0, 28) + PktFlush);
    Message := ProofError(Transport, Outcome);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('invalid pack', Message) > 0).ToBe(True);
end;

procedure TReachabilityTests.TestDateFetchRefusalIsTolerated;
var Transport: TCannedTransport; Outcome: TGitReachabilityResult;
  Message: string;
begin
  { A host that refuses the optional shallow fetch (an ERR line) only
    leaves the probes unordered. }
  Transport := TwoTipHost(PktLine('acknowledgments') + PktLine('NAK')
    + PktFlush);
  try
    Transport.DatesResponse := Bytes(PktLine('ERR upload-pack: deepen '
      + 'is not supported'));
    Message := ProofError(Transport, Outcome);
  finally
    Transport.Free;
  end;
  Expect<string>(Message).ToBe('');
  Expect<Boolean>(Outcome.Known).ToBe(False);
end;

procedure TReachabilityTests.TestAckForUnofferedObjectIsRefused;
var Transport: TCannedTransport; Outcome: TGitReachabilityResult;
  Message: string;
begin
  { The probe offered only the pin as a have; an ACK for anything else is
    not an answer to that request. }
  Transport := TwoTipHost(PktLine('acknowledgments')
    + PktLine('ACK ' + StringOfChar('9', 40)) + PktFlush);
  try
    { Decline the date fetch so the probe is what answers. }
    Transport.DatesResponse := Bytes(PktLine('ERR deepen unsupported'));
    Message := ProofError(Transport, Outcome);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('not offered', Message) > 0).ToBe(True);
end;

procedure TReachabilityTests.TestLsRefsAcceptanceHonoursTheDeadline;
var
  Transport: TCannedTransport;
  Listing: AnsiString;
  Limits: TGitProofLimits;
  Raised: Boolean;
  i: Integer;
begin
  { The listing arrives at once, but checking 90,000 refs outlasts a 25 ms
    budget; the pin (a listed tip) must not be accepted after the
    deadline. }
  Listing := '';
  for i := 1 to 90000 do
    Listing := Listing + PktLine(LowerCase(IntToHex(i mod 10000 + 1, 40))
      + ' refs/tags/t' + IntToStr(i));
  Transport := TCannedTransport.Create(
    Bytes(PktLine('version 2') + PktLine('ls-refs')
      + PktLine('fetch=shallow filter') + PktFlush),
    Bytes(Listing + PktFlush), nil);
  Limits := DefaultGitProofLimits;
  Limits.TimeoutMilliseconds := 25;
  Raised := False;
  try
    try
      ProveCommitReachable(Transport, REPO_URL, LowerCase(IntToHex(1, 40)),
        nil, Limits);
    except
      on E: EGitProofDeadlineExceeded do Raised := True;
    end;
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TReachabilityTests.TestAcknowledgmentsAfterDoneAreRefused;
var Transport: TCannedTransport; Outcome: TGitReachabilityResult;
  Message: string;
begin
  { The date fetch sends `done`; git omits the acknowledgments section for
    such a request, so an ACK there is malformed evidence. }
  Transport := TwoTipHost(PktLine('acknowledgments') + PktLine('NAK')
    + PktFlush);
  try
    Transport.DatesResponse := Bytes(PktLine('acknowledgments')
      + PktLine('ACK ' + StringOfChar('9', 40)) + PktFlush);
    Message := ProofError(Transport, Outcome);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('acknowledg', Message) > 0).ToBe(True);
end;

procedure TReachabilityTests.TestProofTipCapHasAClearError;
var
  Transport: TCannedTransport;
  Listing: AnsiString;
  Outcome: TGitReachabilityResult;
  Message: string;
  i: Integer;
begin
  Listing := '';
  for i := 1 to MAX_PROOF_TIPS + 1 do
    Listing := Listing + PktLine(LowerCase(IntToHex(i, 40))
      + ' refs/tags/t' + IntToStr(i));
  Transport := TCannedTransport.Create(
    Bytes(PktLine('version 2') + PktLine('ls-refs')
      + PktLine('fetch=shallow filter') + PktFlush),
    Bytes(Listing + PktFlush), nil);
  try
    Message := ProofError(Transport, Outcome);
  finally
    Transport.Free;
  end;
  Expect<Boolean>(Pos('pin a tag or branch', Message) > 0).ToBe(True);
end;

procedure TReachabilityTests.SetupTests;
begin
  Test('a pin equal to an advertised tip needs no request',
    TestAdvertisedTipNeedsNoRequest);
  Test('a pin matching only a peeled tag claim is proven from the tag object',
    TestPeeledTagMatchNeedsProof);
  Test('a host that lies about peeled tips cannot prove a fork commit',
    TestLyingPeeledTagIsNotTrusted);
  Test('an advertised ref with an invalid name is not an exact-tip proof',
    TestInvalidAdvertisedNameIsNotAShortcut);
  Test('an acknowledgments section without ACK or NAK is refused',
    TestMissingNakIsAProtocolError);
  Test('all requests of a proof share one monotonic deadline',
    TestProofSharesOneDeadline);
  Test('all responses of a proof share one byte budget',
    TestProofSharesOneByteBudget);
  Test('an invalid pack from the date fetch fails the proof',
    TestDateFetchInvalidPackFailsTheProof);
  Test('a host refusing the date fetch leaves probes unordered',
    TestDateFetchRefusalIsTolerated);
  Test('an ACK for an object that was not offered is refused',
    TestAckForUnofferedObjectIsRefused);
  Test('an exact ls-refs tip is not accepted after the deadline',
    TestLsRefsAcceptanceHonoursTheDeadline);
  Test('acknowledgments in the answer to a done request are refused',
    TestAcknowledgmentsAfterDoneAreRefused);
  Test('a repository past the proof tip cap gets an actionable error',
    TestProofTipCapHasAClearError);
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
  Expect<string>(Tips[1].Id).ToBe(StringOfChar('2', 40));
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

procedure TProtocolMessageTests.TestLsRefsIgnoresPeeledClaims;
var Tips: TGitTipArray; Head: string;
begin
  Tips := ParseLsRefsResponse(Bytes(
    Pkt(StringOfChar('1', 40) + ' refs/heads/main peeled:'
      + StringOfChar('9', 40))
    + Pkt(StringOfChar('2', 40) + ' refs/tags/v1 peeled:'
      + StringOfChar('3', 40))
    + PktFlush), Head);
  Expect<Integer>(Length(Tips)).ToBe(2);
  Expect<string>(Tips[0].Id).ToBe(StringOfChar('1', 40));
  Expect<string>(Tips[1].Id).ToBe(StringOfChar('2', 40));
end;

procedure TProtocolMessageTests.TestLsRefsRejectsInvalidRefNames;

  function Rejected(const AName: string): Boolean;
  var Head: string;
  begin
    Result := False;
    try
      ParseLsRefsResponse(Bytes(Pkt(StringOfChar('1', 40) + ' ' + AName)
        + PktFlush), Head);
    except
      on E: EGitReachabilityError do Result := True;
    end;
  end;

begin
  Expect<Boolean>(Rejected('refs/heads/ok'#27'[31mfake')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/a..b')).ToBe(True);
  Expect<Boolean>(Rejected('refs/tags/x.lock')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/a@{1}')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/.hidden')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/trailing/')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/star*')).ToBe(True);
  Expect<Boolean>(Rejected('refs/heads/release/1.0')).ToBe(False);
end;

function RepeatedLsRefs(ACount: Integer; ADistinct: Boolean): TBytes;
var Text: AnsiString; Line: AnsiString; i, n: Integer; Id: string;
begin
  Line := Pkt(StringOfChar('a', 40) + ' refs/tags/t0000000');
  SetLength(Text, ACount * Length(Line) + 4);
  n := 0;
  for i := 1 to ACount do
  begin
    if ADistinct then
      Id := LowerCase(IntToHex(i, 40))
    else
      Id := StringOfChar('a', 40);
    Line := Pkt(Id + ' refs/tags/t' + Format('%.7d', [i]));
    Move(Line[1], Text[n + 1], Length(Line));
    Inc(n, Length(Line));
  end;
  Line := PktFlush;
  Move(Line[1], Text[n + 1], Length(Line));
  Inc(n, Length(Line));
  SetLength(Text, n);
  Result := Bytes(Text);
end;

procedure TProtocolMessageTests.TestLsRefsDeduplicatesLinearly;
var Tips: TGitTipArray; Head: string; Started: QWord;
begin
  { 50,000 tags on one commit: one proof tip, parsed in linear time. }
  Started := GetTickCount64;
  Tips := ParseLsRefsResponse(RepeatedLsRefs(50000, False), Head);
  Expect<Integer>(Length(Tips)).ToBe(1);
  Expect<Boolean>(GetTickCount64 - Started < 5000).ToBe(True);
end;

procedure TProtocolMessageTests.TestLsRefsEnforcesCountLimits;

  function Rejected(const ABody: TBytes; const AExpected: string): Boolean;
  var Head, Message: string;
  begin
    Message := '';
    try
      ParseLsRefsResponse(ABody, Head);
    except
      on E: EGitReachabilityError do Message := E.Message;
    end;
    Result := Pos(AExpected, Message) > 0;
    if not Result then
      WriteLn('    expected "', AExpected, '", got "', Message, '"');
  end;

begin
  Expect<Boolean>(Rejected(RepeatedLsRefs(MAX_ADVERTISED_REFS + 1, False),
    'more than')).ToBe(True);
  Expect<Boolean>(Rejected(RepeatedLsRefs(MAX_PROOF_TIPS + 1, True),
    'distinct branch and tag tips')).ToBe(True);
end;

procedure TProtocolMessageTests.TestRequestSizeIsCapped;
var Arguments: array of string; i: Integer; Raised: Boolean;
begin
  SetLength(Arguments, MAX_UPLOAD_PACK_REQUEST_BYTES div 40);
  for i := 0 to High(Arguments) do
    Arguments[i] := 'want ' + StringOfChar('a', 40);
  Raised := False;
  try
    BuildV2CommandRequest(Default(TGitV2Capabilities), 'fetch', Arguments);
  except
    on E: EGitReachabilityError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  { MAX_PROOF_TIPS wants fit. }
  SetLength(Arguments, MAX_PROOF_TIPS + 8);
  Expect<Boolean>(Length(BuildV2CommandRequest(Default(TGitV2Capabilities),
    'fetch', Arguments)) <= MAX_UPLOAD_PACK_REQUEST_BYTES).ToBe(True);
end;

procedure TProtocolMessageTests.TestRequestSizeCountsTheFlush;
var
  Arguments: array of string;
  Base, Count, Rest, i: Integer;
  Request: TBytes;
  Raised: Boolean;
begin
  { Arguments that bring the body to two bytes under the limit before the
    closing flush: with the flush the request is over the limit. }
  Base := Length(PktLine('command=fetch')) + Length(PktDelim);
  Count := (MAX_UPLOAD_PACK_REQUEST_BYTES - Base - 16) div 1005;
  Rest := MAX_UPLOAD_PACK_REQUEST_BYTES - Base - 1005 * Count;
  SetLength(Arguments, Count + 1);
  for i := 0 to Count - 1 do Arguments[i] := StringOfChar('x', 1000);
  Arguments[Count] := StringOfChar('y', Rest - 2 - 5);
  Raised := False;
  Request := nil;
  try
    Request := BuildV2CommandRequest(Default(TGitV2Capabilities), 'fetch',
      Arguments);
  except
    on E: EGitReachabilityError do Raised := True;
  end;
  Expect<Boolean>(Raised or (Length(Request) <= MAX_UPLOAD_PACK_REQUEST_BYTES))
    .ToBe(True);
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TProtocolMessageTests.TestAcknowledgmentsAreValidated;

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

var Body: TBytes; Response: TGitFetchResponse;
begin
  Expect<Boolean>(Fails(Pkt('acknowledgments') + Pkt('ACK garbage')
    + PktFlush)).ToBe(True);
  Expect<Boolean>(Fails(Pkt('acknowledgments') + Pkt('ACK '
    + StringOfChar('a', 40)) + Pkt('NAK') + PktFlush)).ToBe(True);
  Body := Bytes(Pkt('acknowledgments') + Pkt('ACK ' + StringOfChar('a', 40))
    + PktFlush);
  Response := ParseFetchResponse(Body);
  Expect<Integer>(Length(Response.AckedIds)).ToBe(1);
  Expect<string>(Response.AckedIds[0]).ToBe(StringOfChar('a', 40));
end;

function LegacyLine(const S: string): AnsiString;
begin
  Result := LowerCase(IntToHex(Length(S) + 5, 4)) + S + #10;
end;

function LegacyFails(const APayload: AnsiString): Boolean;
begin
  Result := False;
  try
    ParseInfoRefs(APayload);
  except
    on E: EGitProtocolError do Result := True;
  end;
end;

procedure TProtocolMessageTests.TestLegacyListingRejectsInvalidNames;
begin
  Expect<Boolean>(LegacyFails(LegacyLine('# service=git-upload-pack')
    + '0000' + LegacyLine(StringOfChar('1', 40) + ' refs/tags/v1'#27'[2J')
    + '0000')).ToBe(True);
  Expect<Boolean>(LegacyFails(LegacyLine(StringOfChar('1', 40)
    + ' refs/heads/a..b') + '0000')).ToBe(True);
  { Fork namespaces are dropped, not validated. }
  Expect<Boolean>(LegacyFails(LegacyLine(StringOfChar('1', 40)
    + ' refs/pull/1/head') + LegacyLine(StringOfChar('2', 40)
    + ' refs/tags/v1') + '0000')).ToBe(False);
end;

procedure TProtocolMessageTests.TestLegacyListingRejectsMalformedFraming;
begin
  Expect<Boolean>(LegacyFails(LegacyLine(StringOfChar('1', 40)
    + ' refs/tags/v1') + 'zzzz')).ToBe(True);
  Expect<Boolean>(LegacyFails(LegacyLine(StringOfChar('1', 40)
    + ' refs/tags/v1') + '00ff' + 'short')).ToBe(True);
  Expect<Boolean>(LegacyFails(LegacyLine(StringOfChar('1', 40)
    + ' refs/tags/v1') + '0003')).ToBe(True);
end;

function LegacyTags(ACount: Integer; APeeled: Boolean): AnsiString;
var Text, Line: AnsiString; i, n: Integer; Name: string;
begin
  SetLength(Text, ACount * 150 + 8);
  n := 0;
  for i := 1 to ACount do
  begin
    Name := 'refs/tags/t' + Format('%.7d', [i]);
    Line := LegacyLine(LowerCase(IntToHex(i, 40)) + ' ' + Name);
    if APeeled then
      Line := Line + LegacyLine(LowerCase(IntToHex(i + 1, 40)) + ' ' + Name
        + '^{}');
    Move(Line[1], Text[n + 1], Length(Line));
    Inc(n, Length(Line));
  end;
  Text[n + 1] := '0'; Text[n + 2] := '0'; Text[n + 3] := '0';
  Text[n + 4] := '0';
  SetLength(Text, n + 4);
  Result := Text;
end;

procedure TProtocolMessageTests.TestLegacyListingIndexesPeelsLinearly;
var Refs: TGitRefArray; Started: QWord;
begin
  { 15,000 annotated tags with peel lines: each peel is found by index,
    not by scanning every earlier tag. }
  Started := GetTickCount64;
  Refs := ParseInfoRefs(LegacyTags(15000, True));
  Expect<Integer>(Length(Refs)).ToBe(15000);
  Expect<string>(Refs[14999].PeeledSHA).ToBe(LowerCase(IntToHex(15001, 40)));
  Expect<Boolean>(GetTickCount64 - Started < 2000).ToBe(True);
end;

procedure TProtocolMessageTests.TestLegacyListingEnforcesLimits;
var Message: string; Refs: TGitRefArray;
begin
  { The resolver's listing serves named requirements, so it is not bound
    by the proof's distinct-tip cap: 20,001 distinct tags still list. }
  Refs := ParseInfoRefs(LegacyTags(MAX_PROOF_TIPS + 1, False));
  Expect<Integer>(Length(Refs)).ToBe(MAX_PROOF_TIPS + 1);
  { Its own, larger branch-and-tag bound still holds. }
  Message := '';
  try
    ParseInfoRefs(LegacyTags(MAX_ADVERTISED_REFS + 1, False));
  except
    on E: EGitProtocolError do Message := E.Message;
  end;
  Expect<Boolean>(Pos('more than 100000 branches and tags', Message) > 0)
    .ToBe(True);
end;

procedure TProtocolMessageTests.TestLegacyListingRequiresItsTerminalFlush;
var Ref: AnsiString;
begin
  Ref := LegacyLine(StringOfChar('1', 40) + ' refs/tags/v1');
  { Truncated at a packet boundary: the service preamble's flush is not
    the advertisement's terminator. }
  Expect<Boolean>(LegacyFails(LegacyLine('# service=git-upload-pack')
    + '0000' + Ref)).ToBe(True);
  Expect<Boolean>(LegacyFails(Ref)).ToBe(True);
  Expect<Boolean>(LegacyFails(LegacyLine('# service=git-upload-pack')
    + '0000')).ToBe(True);
  { Complete forms. }
  Expect<Boolean>(LegacyFails(LegacyLine('# service=git-upload-pack')
    + '0000' + Ref + '0000')).ToBe(False);
  Expect<Boolean>(LegacyFails(Ref + '0000')).ToBe(False);
end;

procedure TProtocolMessageTests.TestCapabilitiesRequireTheirTerminalFlush;
var Raised: Boolean;
begin
  Raised := False;
  try
    ParseV2Capabilities(Bytes(Pkt('# service=git-upload-pack') + PktFlush
      + Pkt('version 2') + Pkt('ls-refs') + Pkt('fetch=shallow filter')));
  except
    on E: EGitReachabilityError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TProtocolMessageTests.SetupTests;
begin
  Test('pkt-lines and v2 command requests are framed exactly',
    TestPktLineFraming);
  Test('v2 capabilities parse after a smart-HTTP service preamble',
    TestCapabilitiesAcceptServicePreamble);
  Test('a v0 advertisement is not mistaken for v2',
    TestCapabilitiesRejectVersion0);
  Test('ls-refs keeps branch and tag tips and drops fork refs',
    TestLsRefsKeepsOnlyBranchesAndTags);
  Test('ls-refs rejects truncated or malformed responses',
    TestLsRefsRejectsTruncation);
  Test('fetch responses demultiplex side-band pack data in place',
    TestFetchDemultiplexesSideBand);
  Test('fetch responses surface ERR lines and side-band errors',
    TestFetchReportsRemoteErrors);
  Test('fetch responses with malformed framing are rejected',
    TestFetchRejectsMalformedFraming);
  Test('ls-refs uses raw ids and ignores unverified peeled claims',
    TestLsRefsIgnoresPeeledClaims);
  Test('ls-refs rejects names that are not valid refs',
    TestLsRefsRejectsInvalidRefNames);
  Test('ls-refs deduplicates many tags on one commit in linear time',
    TestLsRefsDeduplicatesLinearly);
  Test('ls-refs enforces ref-count and distinct-tip limits',
    TestLsRefsEnforcesCountLimits);
  Test('upload-pack request bodies are capped',
    TestRequestSizeIsCapped);
  Test('the request cap includes the closing flush',
    TestRequestSizeCountsTheFlush);
  Test('acknowledgments must be well-formed and consistent',
    TestAcknowledgmentsAreValidated);
  Test('the legacy listing rejects invalid branch and tag names',
    TestLegacyListingRejectsInvalidNames);
  Test('the legacy listing rejects malformed framing',
    TestLegacyListingRejectsMalformedFraming);
  Test('the legacy listing indexes peel lines in linear time',
    TestLegacyListingIndexesPeelsLinearly);
  Test('the legacy listing lists past the proof cap within its own limit',
    TestLegacyListingEnforcesLimits);
  Test('the legacy listing must end with its terminating flush',
    TestLegacyListingRequiresItsTerminalFlush);
  Test('a v2 capability advertisement must end with a flush',
    TestCapabilitiesRequireTheirTerminalFlush);
end;

{ THTTPTransportTests }

function FullBudget: TGitRequestBudget;
begin
  Result.TimeoutMilliseconds := 10000;
  Result.MaxResponseBytes := MAX_UPLOAD_PACK_RESPONSE_BYTES;
end;

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
        Bytes(PktLine('command=fetch') + PktDelim + PktFlush),
        FullBudget);
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
          + '/fixture/reach.git', Effective, FullBudget);
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

procedure THTTPTransportTests.TestRedirectBodiesCountAgainstTheBudget;
var
  Final, Hop: TMockHTTPServer;
  Transport: THTTPGitUploadPackTransport;
  Budget: TGitRequestBudget;
  Message, Effective: string;
begin
  { A 600-byte redirect body and a 100-byte final body: each fits a
    650-byte allowance alone, together they do not. }
  Final := TMockHTTPServer.Create(MockResponse(StringOfChar('f', 100)));
  try
    Final.Start;
    Hop := TMockHTTPServer.Create(Bytes('HTTP/1.1 302 Found'#13#10
      + 'Location: http://127.0.0.1:' + IntToStr(Final.Port)
      + '/moved/reach.git/info/refs?service=git-upload-pack'#13#10
      + 'Content-Length: 600'#13#10 + 'Connection: close'#13#10#13#10
      + StringOfChar('r', 600)));
    try
      Hop.Start;
      Transport := THTTPGitUploadPackTransport.Create(
        DefaultHTTPRequestOptions);
      Budget := FullBudget;
      Budget.MaxResponseBytes := 650;
      Message := '';
      try
        try
          Transport.Advertise('http://127.0.0.1:' + IntToStr(Hop.Port)
            + '/fixture/reach.git', Effective, Budget);
        except
          on E: EGitResponseTooLarge do Message := E.Message;
        end;
      finally
        Transport.Free;
      end;
      Hop.WaitDone;
    finally
      Hop.Free;
    end;
    Final.WaitDone(2000);
  finally
    Final.Free;
  end;
  Expect<Boolean>(Pos('650', Message) > 0).ToBe(True);
end;

procedure THTTPTransportTests.SetupTests;
begin
  Test('commands are POSTed to git-upload-pack as protocol v2',
    TestCommandPostsProtocolV2Request);
  Test('a response over the cap is refused as too large',
    TestOversizedBodyIsRefused);
  Test('redirect bodies count against the request budget',
    TestRedirectBodiesCountAgainstTheBudget);
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
  FOptions.Destination.PrivateAddressPolicy := papDeny;
  FOptions.Destination.RequireHTTPS := True;
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
