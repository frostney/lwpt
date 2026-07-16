unit LinkCheck;

{$I Shared.inc}

interface

uses
  Classes,
  SysUtils;

type
  TLinkCheckSeverity = (lcsInfo, lcsError);

  { Injectable only to keep online policy tests deterministic. Production
    callers leave it nil and use the canonical HTTPClient transport. }
  TLinkCheckProbe = function(const AURL: string;
    const ATimeoutMs: Integer): Integer;

  TLinkCheckFinding = record
    Severity: TLinkCheckSeverity;
    Kind: string;
    Source: string;
    Line: Integer;
    Target: string;
    Message: string;
  end;

  TLinkCheckOptions = record
    Root: string;
    Online: Boolean;
    Jobs: Integer;
    TimeoutMs: Integer;
    AllowlistPath: string;
    Probe: TLinkCheckProbe;
  end;

  TLinkCheckReport = class
  private
    FFindings: array of TLinkCheckFinding;
    function GetCount: Integer;
    function GetFinding(const AIndex: Integer): TLinkCheckFinding;
  public
    procedure Add(const AFinding: TLinkCheckFinding);
    procedure Sort;
    function HasErrors: Boolean;
    function ToHuman: string;
    function ToJSON: string;
    property Count: Integer read GetCount;
    property Findings[const AIndex: Integer]: TLinkCheckFinding read GetFinding;
  end;

  { The package's deliberately small public surface. It owns discovery,
    Markdown parsing, filesystem containment, anchor indexing, allowlisting,
    and the optional network worker pool behind one operation. }
  TLinkChecker = class
  private
    FOptions: TLinkCheckOptions;
  public
    constructor Create(const AOptions: TLinkCheckOptions);
    function Check: TLinkCheckReport;
  end;

function DefaultLinkCheckOptions(const ARoot: string): TLinkCheckOptions;

implementation

uses
  HTTPClient;

type
  TMarkdownLink = record
    Source: string;
    Line: Integer;
    Target: string;
  end;

  TMarkdownLinks = array of TMarkdownLink;

  TOnlineJob = record
    Link: TMarkdownLink;
    Reason: string;
  end;

  TOnlineJobs = array of TOnlineJob;

  TOnlineState = class
  private
    FCriticalSection: TRTLCriticalSection;
    FNext: Integer;
    FJobs: TOnlineJobs;
    FFindings: array of TLinkCheckFinding;
  public
    constructor Create(const AJobs: TOnlineJobs);
    destructor Destroy; override;
    function Take(out AJob: TOnlineJob): Boolean;
    procedure AddFinding(const AFinding: TLinkCheckFinding);
    procedure AppendTo(const AReport: TLinkCheckReport);
  end;

  TOnlineWorker = class(TThread)
  private
    FState: TOnlineState;
    FTimeoutMs: Integer;
    FProbe: TLinkCheckProbe;
  protected
    procedure Execute; override;
  public
    constructor Create(const AState: TOnlineState; const ATimeoutMs: Integer;
      const AProbe: TLinkCheckProbe);
  end;

const
  DEFAULT_JOBS = 4;
  DEFAULT_TIMEOUT_MS = 10000;

function DefaultLinkCheckOptions(const ARoot: string): TLinkCheckOptions;
begin
  Result.Root := ARoot;
  Result.Online := False;
  Result.Jobs := DEFAULT_JOBS;
  Result.TimeoutMs := DEFAULT_TIMEOUT_MS;
  Result.AllowlistPath := '';
  Result.Probe := nil;
end;

function SeverityName(const ASeverity: TLinkCheckSeverity): string;
begin
  case ASeverity of
    lcsInfo: Result := 'info';
    lcsError: Result := 'error';
  end;
end;

function JSONEscape(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if Ord(C) < 32 then
        Result := Result + '\u' + IntToHex(Ord(C), 4)
      else
        Result := Result + C;
    end;
  end;
end;

function CompareFindings(constref ALeft, ARight: TLinkCheckFinding): Integer;
begin
  Result := CompareText(ALeft.Source, ARight.Source);
  if Result <> 0 then Exit;
  Result := ALeft.Line - ARight.Line;
  if Result <> 0 then Exit;
  Result := CompareText(ALeft.Target, ARight.Target);
  if Result <> 0 then Exit;
  Result := CompareText(ALeft.Kind, ARight.Kind);
  if Result <> 0 then Exit;
  Result := Ord(ALeft.Severity) - Ord(ARight.Severity);
end;

function TLinkCheckReport.GetCount: Integer;
begin
  Result := Length(FFindings);
end;

function TLinkCheckReport.GetFinding(const AIndex: Integer): TLinkCheckFinding;
begin
  if (AIndex < 0) or (AIndex >= Length(FFindings)) then
    raise ERangeError.CreateFmt('Finding index %d is out of range', [AIndex]);
  Result := FFindings[AIndex];
end;

procedure TLinkCheckReport.Add(const AFinding: TLinkCheckFinding);
var
  N: Integer;
begin
  N := Length(FFindings);
  SetLength(FFindings, N + 1);
  FFindings[N] := AFinding;
end;

procedure TLinkCheckReport.Sort;
  procedure QuickSort(const ALeft, ARight: Integer);
  var
    I, J: Integer;
    Pivot, Temporary: TLinkCheckFinding;
  begin
    I := ALeft;
    J := ARight;
    Pivot := FFindings[(ALeft + ARight) div 2];
    repeat
      while CompareFindings(FFindings[I], Pivot) < 0 do Inc(I);
      while CompareFindings(FFindings[J], Pivot) > 0 do Dec(J);
      if I <= J then
      begin
        Temporary := FFindings[I];
        FFindings[I] := FFindings[J];
        FFindings[J] := Temporary;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if ALeft < J then QuickSort(ALeft, J);
    if I < ARight then QuickSort(I, ARight);
  end;
begin
  if Length(FFindings) > 1 then
    QuickSort(0, High(FFindings));
end;

function TLinkCheckReport.HasErrors: Boolean;
var
  Finding: TLinkCheckFinding;
begin
  for Finding in FFindings do
    if Finding.Severity = lcsError then Exit(True);
  Result := False;
end;

function TLinkCheckReport.ToHuman: string;
var
  Lines: TStringList;
  Finding: TLinkCheckFinding;
begin
  Lines := TStringList.Create;
  try
    for Finding in FFindings do
      Lines.Add(Format('%s:%d: %s [%s] %s (%s)',
        [Finding.Source, Finding.Line, SeverityName(Finding.Severity),
         Finding.Kind, Finding.Message, Finding.Target]));
    if Length(FFindings) = 0 then
      Lines.Add('linkcheck: no broken links found');
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

function TLinkCheckReport.ToJSON: string;
var
  I: Integer;
  Finding: TLinkCheckFinding;
begin
  Result := '{"ok":' + LowerCase(BoolToStr(not HasErrors, True)) +
    ',"findings":[';
  for I := 0 to High(FFindings) do
  begin
    if I > 0 then Result := Result + ',';
    Finding := FFindings[I];
    Result := Result + '{"severity":"' + SeverityName(Finding.Severity) +
      '","kind":"' + JSONEscape(Finding.Kind) +
      '","source":"' + JSONEscape(Finding.Source) +
      '","line":' + IntToStr(Finding.Line) +
      ',"target":"' + JSONEscape(Finding.Target) +
      '","message":"' + JSONEscape(Finding.Message) + '"}';
  end;
  Result := Result + ']}';
end;

function MakeFinding(const ASeverity: TLinkCheckSeverity;
  const AKind, ASource: string; const ALine: Integer;
  const ATarget, AMessage: string): TLinkCheckFinding;
begin
  Result.Severity := ASeverity;
  Result.Kind := AKind;
  Result.Source := ASource;
  Result.Line := ALine;
  Result.Target := ATarget;
  Result.Message := AMessage;
end;

function IsMarkdownFile(const APath: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  Result := (Ext = '.md') or (Ext = '.mdx');
end;

function IsIgnoredDirectory(const AName: string): Boolean;
begin
  Result := SameText(AName, '.git') or SameText(AName, '.lwpt') or
    SameText(AName, 'build');
end;

procedure CollectMarkdownFiles(const ARoot, ADirectory: string;
  const AFiles: TStrings);
var
  Search: TSearchRec;
  Path: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Path := IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if not IsIgnoredDirectory(Search.Name) and
           ((Search.Attr and faSymLink) = 0) then
          CollectMarkdownFiles(ARoot, Path, AFiles);
      end
      else if IsMarkdownFile(Path) then
        AFiles.Add(Path);
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function StripMarkdownNoise(const ALine: string; var AInFence,
  AInComment: Boolean): string;
var
  I, Start: Integer;
  S: string;
begin
  S := ALine;
  if Pos('```', TrimLeft(S)) = 1 then
  begin
    AInFence := not AInFence;
    Exit('');
  end;
  if AInFence then Exit('');

  Result := '';
  I := 1;
  Start := 1;
  while I <= Length(S) do
  begin
    if AInComment then
    begin
      if Copy(S, I, 3) = '-->' then
      begin
        AInComment := False;
        Inc(I, 3);
        Start := I;
      end
      else
        Inc(I);
    end
    else if Copy(S, I, 4) = '<!--' then
    begin
      Result := Result + Copy(S, Start, I - Start);
      AInComment := True;
      Inc(I, 4);
    end
    else
      Inc(I);
  end;
  if not AInComment then
    Result := Result + Copy(S, Start, MaxInt);
end;

function RemoveOptionalTitle(const ATarget: string): string;
var
  I: Integer;
  InAngle: Boolean;
begin
  Result := Trim(ATarget);
  if (Length(Result) >= 2) and (Result[1] = '<') and
     (Result[Length(Result)] = '>') then
    Exit(Copy(Result, 2, Length(Result) - 2));
  InAngle := False;
  for I := 1 to Length(Result) do
  begin
    if Result[I] = '<' then InAngle := True
    else if Result[I] = '>' then InAngle := False
    else if (Result[I] in [' ', #9]) and not InAngle then
      Exit(Copy(Result, 1, I - 1));
  end;
end;

procedure ExtractLinks(const ASource, ALine: string; const ALineNumber: Integer;
  var ALinks: TMarkdownLinks);
var
  I, CloseBracket, OpenParen, CloseParen, Depth, N: Integer;
  Link: TMarkdownLink;
begin
  I := 1;
  while I <= Length(ALine) do
  begin
    if (ALine[I] = '[') and ((I = 1) or (ALine[I - 1] <> '!')) then
    begin
      CloseBracket := I + 1;
      while (CloseBracket <= Length(ALine)) and
            (ALine[CloseBracket] <> ']') do Inc(CloseBracket);
      OpenParen := CloseBracket + 1;
      if (OpenParen <= Length(ALine)) and (ALine[OpenParen] = '(') then
      begin
        CloseParen := OpenParen + 1;
        Depth := 1;
        while (CloseParen <= Length(ALine)) and (Depth > 0) do
        begin
          if ALine[CloseParen] = '(' then Inc(Depth)
          else if ALine[CloseParen] = ')' then Dec(Depth);
          Inc(CloseParen);
        end;
        if Depth = 0 then
        begin
          Link.Source := ASource;
          Link.Line := ALineNumber;
          Link.Target := RemoveOptionalTitle(Copy(ALine, OpenParen + 1,
            CloseParen - OpenParen - 2));
          if Link.Target <> '' then
          begin
            N := Length(ALinks);
            SetLength(ALinks, N + 1);
            ALinks[N] := Link;
          end;
          I := CloseParen;
          Continue;
        end;
      end;
    end;
    Inc(I);
  end;
end;

function GitHubSlug(const AHeading: string): string;
var
  I: Integer;
  C: Char;
  PendingDash: Boolean;
begin
  Result := '';
  PendingDash := False;
  for I := 1 to Length(Trim(AHeading)) do
  begin
    C := AHeading[I];
    if C in ['A'..'Z'] then C := Chr(Ord(C) + 32);
    if (C in ['a'..'z', '0'..'9', '_', '-']) or (Ord(C) >= 128) then
    begin
      if PendingDash and (Result <> '') and
         (Result[Length(Result)] <> '-') then Result := Result + '-';
      PendingDash := False;
      Result := Result + C;
    end
    else if C in [' ', #9] then
      PendingDash := True;
  end;
end;

function AnchorExists(const APath, AAnchor: string): Boolean;
var
  Lines, Seen: TStringList;
  I, Hashes, Count: Integer;
  Line, Heading, Base, Slug: string;
  InFence, InComment: Boolean;
begin
  Result := False;
  Lines := TStringList.Create;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    Lines.LoadFromFile(APath);
    InFence := False;
    InComment := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := StripMarkdownNoise(Lines[I], InFence, InComment);
      if (Pos('<a id="' + AAnchor + '"', LowerCase(Line)) > 0) or
         (Pos('<a name="' + AAnchor + '"', LowerCase(Line)) > 0) then
        Exit(True);
      Hashes := 0;
      while (Hashes < Length(Line)) and (Line[Hashes + 1] = '#') do
        Inc(Hashes);
      if (Hashes = 0) or (Hashes > 6) or
         (Length(Line) <= Hashes) or (Line[Hashes + 1] <> ' ') then Continue;
      Heading := Trim(Copy(Line, Hashes + 2, MaxInt));
      while (Heading <> '') and (Heading[Length(Heading)] = '#') do
        Delete(Heading, Length(Heading), 1);
      Base := GitHubSlug(Trim(Heading));
      if Base = '' then Continue;
      Count := 0;
      Slug := Base;
      while Seen.IndexOf(Slug) >= 0 do
      begin
        Inc(Count);
        Slug := Base + '-' + IntToStr(Count);
      end;
      Seen.Add(Slug);
      if SameText(Slug, AAnchor) then Exit(True);
    end;
  finally
    Seen.Free;
    Lines.Free;
  end;
end;

function PercentDecode(const AValue: string): string;
var
  I, Code: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AValue) do
  begin
    if (AValue[I] = '%') and (I + 2 <= Length(AValue)) and
       TryStrToInt('$' + Copy(AValue, I + 1, 2), Code) then
    begin
      Result := Result + Chr(Code);
      Inc(I, 3);
    end
    else
    begin
      Result := Result + AValue[I];
      Inc(I);
    end;
  end;
end;

function RelativeToRoot(const ARoot, APath: string): string;
begin
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(ARoot), APath);
  Result := StringReplace(Result, PathDelim, '/', [rfReplaceAll]);
end;

function FindDirectoryIndex(const ADirectory: string): string;
const
  Names: array[0..3] of string = ('README.md', 'index.md',
    'README.mdx', 'index.mdx');
var
  Name: string;
begin
  for Name in Names do
    if FileExists(IncludeTrailingPathDelimiter(ADirectory) + Name) then
      Exit(IncludeTrailingPathDelimiter(ADirectory) + Name);
  Result := '';
end;

function IsExternalURL(const ATarget: string): Boolean;
begin
  Result := (Pos('https://', LowerCase(ATarget)) = 1) or
    (Pos('http://', LowerCase(ATarget)) = 1);
end;

function IsIgnoredScheme(const ATarget: string): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(ATarget);
  Result := (Pos('mailto:', Lower) = 1) or (Pos('tel:', Lower) = 1) or
    (Pos('data:', Lower) = 1);
end;

function IsAbsolutePath(const APath: string): Boolean;
begin
  Result := (APath <> '') and
    ((APath[1] = PathDelim) or
     ((Length(APath) >= 3) and (APath[2] = ':') and
      (APath[3] in ['\', '/'])) or
     ((Length(APath) >= 2) and (APath[1] = '\') and (APath[2] = '\')));
end;

function ReadAllowlist(const ARoot, APath: string;
  const AReport: TLinkCheckReport): TStringList;
var
  Lines: TStringList;
  I, TabPos: Integer;
  Line, Target, Reason, FullPath: string;
begin
  Result := TStringList.Create;
  Result.NameValueSeparator := #9;
  Result.Sorted := True;
  Result.Duplicates := dupError;
  if APath = '' then Exit;
  if IsAbsolutePath(APath) then FullPath := APath
  else FullPath := ExpandFileName(IncludeTrailingPathDelimiter(ARoot) + APath);
  if not FileExists(FullPath) then
  begin
    AReport.Add(MakeFinding(lcsError, 'allowlist', RelativeToRoot(ARoot, FullPath),
      0, APath, 'allowlist file does not exist'));
    Exit;
  end;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FullPath);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or (Line[1] = '#') then Continue;
      TabPos := Pos(#9, Line);
      if TabPos = 0 then
      begin
        AReport.Add(MakeFinding(lcsError, 'allowlist',
          RelativeToRoot(ARoot, FullPath), I + 1, Line,
          'entry must be TARGET<TAB>REASON'));
        Continue;
      end;
      Target := Trim(Copy(Line, 1, TabPos - 1));
      Reason := Trim(Copy(Line, TabPos + 1, MaxInt));
      if (Target = '') or (Reason = '') then
      begin
        AReport.Add(MakeFinding(lcsError, 'allowlist',
          RelativeToRoot(ARoot, FullPath), I + 1, Line,
          'target and rationale must both be non-empty'));
        Continue;
      end;
      Result.Values[Target] := Reason;
    end;
  finally
    Lines.Free;
  end;
end;

constructor TOnlineState.Create(const AJobs: TOnlineJobs);
begin
  inherited Create;
  InitCriticalSection(FCriticalSection);
  FJobs := AJobs;
  FNext := 0;
end;

destructor TOnlineState.Destroy;
begin
  DoneCriticalSection(FCriticalSection);
  inherited Destroy;
end;

function TOnlineState.Take(out AJob: TOnlineJob): Boolean;
begin
  EnterCriticalSection(FCriticalSection);
  try
    Result := FNext < Length(FJobs);
    if Result then
    begin
      AJob := FJobs[FNext];
      Inc(FNext);
    end;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TOnlineState.AddFinding(const AFinding: TLinkCheckFinding);
var
  N: Integer;
begin
  EnterCriticalSection(FCriticalSection);
  try
    N := Length(FFindings);
    SetLength(FFindings, N + 1);
    FFindings[N] := AFinding;
  finally
    LeaveCriticalSection(FCriticalSection);
  end;
end;

procedure TOnlineState.AppendTo(const AReport: TLinkCheckReport);
var
  Finding: TLinkCheckFinding;
begin
  for Finding in FFindings do AReport.Add(Finding);
end;

constructor TOnlineWorker.Create(const AState: TOnlineState;
  const ATimeoutMs: Integer; const AProbe: TLinkCheckProbe);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FState := AState;
  FTimeoutMs := ATimeoutMs;
  FProbe := AProbe;
end;

procedure TOnlineWorker.Execute;
var
  Job: TOnlineJob;
  Headers: THTTPHeaders;
  Response: THTTPResponse;
  Options: THTTPRequestOptions;
  StatusCode: Integer;
begin
  Headers := nil;
  Options := DefaultHTTPRequestOptions;
  Options.TimeoutMs := FTimeoutMs;
  while FState.Take(Job) do
  begin
    try
      if Assigned(FProbe) then
        StatusCode := FProbe(Job.Link.Target, FTimeoutMs)
      else
      begin
        Response := HTTPHead(Job.Link.Target, Headers, Options);
        StatusCode := Response.StatusCode;
      end;
      if (StatusCode < 200) or (StatusCode >= 400) then
        FState.AddFinding(MakeFinding(lcsError, 'https', Job.Link.Source,
          Job.Link.Line, Job.Link.Target, 'HTTP status ' +
          IntToStr(StatusCode)))
      else if Job.Reason <> '' then
        FState.AddFinding(MakeFinding(lcsInfo, 'allowlisted', Job.Link.Source,
          Job.Link.Line, Job.Link.Target, Job.Reason));
    except
      on E: Exception do
        FState.AddFinding(MakeFinding(lcsError, 'https', Job.Link.Source,
          Job.Link.Line, Job.Link.Target, E.Message));
    end;
  end;
end;

procedure CheckOnline(const AJobs: TOnlineJobs; const AOptions: TLinkCheckOptions;
  const AReport: TLinkCheckReport);
var
  State: TOnlineState;
  Workers: array of TOnlineWorker;
  I, Count: Integer;
begin
  if Length(AJobs) = 0 then Exit;
  Count := AOptions.Jobs;
  if Count < 1 then Count := 1;
  if Count > Length(AJobs) then Count := Length(AJobs);
  State := TOnlineState.Create(AJobs);
  try
    SetLength(Workers, Count);
    for I := 0 to High(Workers) do
    begin
      Workers[I] := TOnlineWorker.Create(State, AOptions.TimeoutMs,
        AOptions.Probe);
      Workers[I].Start;
    end;
    for I := 0 to High(Workers) do
    begin
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
    State.AppendTo(AReport);
  finally
    State.Free;
  end;
end;

constructor TLinkChecker.Create(const AOptions: TLinkCheckOptions);
begin
  inherited Create;
  FOptions := AOptions;
end;

function TLinkChecker.Check: TLinkCheckReport;
var
  Root, FullSource, Source, Line, RawPath, Anchor, FullTarget,
    IndexPath, LowerTarget, Reason: string;
  Files, Lines, Allowlist: TStringList;
  Links: TMarkdownLinks;
  OnlineJobs: TOnlineJobs;
  Link: TMarkdownLink;
  Job: TOnlineJob;
  I, HashPos, N: Integer;
  InFence, InComment: Boolean;
begin
  Result := TLinkCheckReport.Create;
  SetLength(Links, 0);
  SetLength(OnlineJobs, 0);
  Root := ExcludeTrailingPathDelimiter(ExpandFileName(FOptions.Root));
  if not DirectoryExists(Root) then
  begin
    Result.Add(MakeFinding(lcsError, 'root', '.', 0, FOptions.Root,
      'root directory does not exist'));
    Exit;
  end;
  if FOptions.Jobs < 1 then FOptions.Jobs := 1;
  if FOptions.TimeoutMs < 1 then FOptions.TimeoutMs := DEFAULT_TIMEOUT_MS;

  Files := TStringList.Create;
  Lines := TStringList.Create;
  Allowlist := nil;
  try
    Files.Sorted := True;
    CollectMarkdownFiles(Root, Root, Files);
    Allowlist := ReadAllowlist(Root, FOptions.AllowlistPath, Result);
    for I := 0 to Files.Count - 1 do
    begin
      FullSource := Files[I];
      Source := RelativeToRoot(Root, FullSource);
      Lines.LoadFromFile(FullSource);
      InFence := False;
      InComment := False;
      for N := 0 to Lines.Count - 1 do
      begin
        Line := StripMarkdownNoise(Lines[N], InFence, InComment);
        ExtractLinks(Source, Line, N + 1, Links);
      end;
      Lines.Clear;
    end;

    for Link in Links do
    begin
      LowerTarget := LowerCase(Link.Target);
      if IsIgnoredScheme(Link.Target) then Continue;
      Reason := Allowlist.Values[Link.Target];
      if Reason <> '' then
      begin
        Result.Add(MakeFinding(lcsInfo, 'allowlisted', Link.Source,
          Link.Line, Link.Target, Reason));
        Continue;
      end;
      if IsExternalURL(Link.Target) then
      begin
        if Pos('http://', LowerTarget) = 1 then
          Result.Add(MakeFinding(lcsError, 'https', Link.Source, Link.Line,
            Link.Target, 'external links must use HTTPS'))
        else if FOptions.Online then
        begin
          Job.Link := Link;
          Job.Reason := '';
          SetLength(OnlineJobs, Length(OnlineJobs) + 1);
          OnlineJobs[High(OnlineJobs)] := Job;
        end;
        Continue;
      end;
      if Pos('://', Link.Target) > 0 then
      begin
        Result.Add(MakeFinding(lcsError, 'scheme', Link.Source, Link.Line,
          Link.Target, 'unsupported link scheme'));
        Continue;
      end;

      HashPos := Pos('#', Link.Target);
      if HashPos > 0 then
      begin
        RawPath := Copy(Link.Target, 1, HashPos - 1);
        Anchor := PercentDecode(Copy(Link.Target, HashPos + 1, MaxInt));
      end
      else
      begin
        RawPath := Link.Target;
        Anchor := '';
      end;
      RawPath := PercentDecode(RawPath);
      if RawPath = '' then
        FullTarget := ExpandFileName(IncludeTrailingPathDelimiter(Root) +
          StringReplace(Link.Source, '/', PathDelim, [rfReplaceAll]))
      else if (Length(RawPath) > 0) and (RawPath[1] = '/') then
        FullTarget := ExpandFileName(IncludeTrailingPathDelimiter(Root) +
          Copy(RawPath, 2, MaxInt))
      else
        FullTarget := ExpandFileName(IncludeTrailingPathDelimiter(Root) +
          ExtractFileDir(StringReplace(Link.Source, '/', PathDelim,
          [rfReplaceAll])) + PathDelim + RawPath);

      if Pos(IncludeTrailingPathDelimiter(Root),
        IncludeTrailingPathDelimiter(FullTarget)) <> 1 then
      begin
        Result.Add(MakeFinding(lcsError, 'path', Link.Source, Link.Line,
          Link.Target, 'target escapes the check root'));
        Continue;
      end;
      if DirectoryExists(FullTarget) then
      begin
        { A directory link is itself a valid GitHub repository target. Only
          resolve an index file when an anchor requires Markdown content. }
        if Anchor = '' then Continue;
        IndexPath := FindDirectoryIndex(FullTarget);
        if IndexPath = '' then
        begin
          Result.Add(MakeFinding(lcsError, 'directory-index', Link.Source,
            Link.Line, Link.Target, 'directory has no Markdown index'));
          Continue;
        end;
        FullTarget := IndexPath;
      end;
      if not FileExists(FullTarget) then
      begin
        Result.Add(MakeFinding(lcsError, 'file', Link.Source, Link.Line,
          Link.Target, 'target does not exist'));
        Continue;
      end;
      if (Anchor <> '') and not AnchorExists(FullTarget, Anchor) then
        Result.Add(MakeFinding(lcsError, 'anchor', Link.Source, Link.Line,
          Link.Target, 'anchor does not exist'));
    end;

    if FOptions.Online then
      CheckOnline(OnlineJobs, FOptions, Result);
    Result.Sort;
  finally
    Allowlist.Free;
    Lines.Free;
    Files.Free;
  end;
end;

end.
