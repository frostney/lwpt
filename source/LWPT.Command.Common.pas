{ LWPT.Command.Common — shared command helpers. }
unit LWPT.Command.Common;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  Process,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.CompilerDriver,
  LWPT.Core,
  LWPT.Manifest;

{ Exit code of a finished TProcess, tolerant of which call reaped it.
  On Unix (FPC 3.2.2) WaitOnExit stores the already-decoded exit code,
  and ExitCode then re-applies wifexited/wexitstatus to that value —
  most nonzero exits (and every signal death) collapse to 0. When a
  Running poll reaps the child instead, the raw waitpid status is
  stored and ExitCode decodes correctly, so which value is trustworthy
  depends on a race. ExitStatus returns the stored word verbatim, so
  genuine failure is nonzero there on either path. Prefer ExitCode
  (correct on Windows and on the raw-status path), and trust ExitStatus
  whenever ExitCode claims success but the stored status disagrees. }
function  NormalisedExitCode(const AProcess: TProcess): Integer;
function  IsAbsoluteFilesystemPath(const APath: string): Boolean;
function  PatternHasGlob(const APattern: string): Boolean;
function  ResolveProjectPath(const AProjectRoot, APath: string): string;
function  ResolveRunnableCommand(const AProjectRoot,
  ACommand: string): string;

function  CreatePascalCompilerProcess(const ASrcFile: string;
  const AUnitPaths, AExtraArguments: array of string; out AOutBin: string;
  out ARequest: TLWPTBuildRequest; const ABuildRoot: string;
  const ADriver: TLWPTCompilerDriver;
  const AConfigurationFile: string = CFG_FILE): TProcess;
procedure AppendCompilerEnvironmentSearchPaths(
  var AUnitPaths, AIncludePaths: TStringArray);
{ Appends the directories that the unit, include, object and library search
  options among AOptions (-Fu, -Fi, -Fo, -Fl, -I) can make the compiler
  read, resolved as FPC 3.2 resolves them. An option lists entries separated
  by ";", and outside Windows also by ":". An entry may be Pascal-quoted. A
  leading "=" names a path below the sysroot, which -XR sets for -Fl and
  which is empty for every other option. "*" wildcards and "$" macros expand
  when the compiler runs, so such an entry adds its fixed leading directory,
  which holds every directory it can resolve to. An "=" entry of -Fl adds one
  directory per -XR value in AOptions and one without a sysroot, because the
  sysroot that applies depends on option order. An empty entry names the
  current directory, which this adds nothing for. }
procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray);
{ True when AHook must run: it declares no staleness gate (inputs plus
  output), its output is missing, an input is not older than the output,
  or the inputs or output differ in content from the last successful run's
  record. Times are compared at full filesystem resolution; see HookIsStale
  in the implementation for why an input as new as the output counts as
  stale, and why times alone are not enough. AInputDigest receives the
  digest of the resolved inputs for RecordHookRun ('' when ungated). }
function  HookIsStale(const AHook: THook;
  const AProjectRoot: string): Boolean; overload;
function  HookIsStale(const AHook: THook; const AProjectRoot: string;
  out AInputDigest: string): Boolean; overload;
{ Records that AHook just succeeded on inputs with AInputDigest (taken
  before it ran), together with the content of the output it left. The
  record is staged through ATmpRoot, the project's temporary root (the
  manifest's resolved tmp-dir). }
procedure RecordHookRun(const AHook: THook;
  const AProjectRoot, ATmpRoot, AInputDigest: string);
function  RunUserTask(const ATask: THook;
  const AProjectRoot, ATmpRoot: string): Integer;
procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const AProjectRoot, ATmpRoot: string);
procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const AProjectRoot, ATmpRoot: string;
  const AEnvironment: array of string);

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  LWPT.BuildSession,
  LWPT.CompilerDriver.FPC,
  LWPT.OutputRenderer,
  LWPT.ProcessRunner,
  LWPT.ProcessTree;

procedure CaptureSilentProcessChunk(const AData: RawByteString;
  const AStandardError: Boolean);
begin
  if AStandardError then CaptureSilentChildOutput('', AData)
  else CaptureSilentChildOutput(AData, '');
end;

function NormalisedExitCode(const AProcess: TProcess): Integer;
begin
  Result := AProcess.ExitCode;
  if (Result = 0) and (AProcess.ExitStatus <> 0) then
    Result := AProcess.ExitStatus;
end;

procedure AppendCompilerEnvironmentSearchPaths(
  var AUnitPaths, AIncludePaths: TStringArray);
var
  Raw, Part: string;
  StartAt, i, Count: Integer;
begin
  Raw := GetEnvironmentVariable(PROJECT_NAME + '_FPC_UNIT_PATHS');
  if Raw = '' then Exit;
  StartAt := 1;
  for i := 1 to Length(Raw) + 1 do
    if (i > Length(Raw)) or (Raw[i] = PathSeparator) then
    begin
      Part := Copy(Raw, StartAt, i - StartAt);
      if Part <> '' then
      begin
        Count := Length(AUnitPaths);
        SetLength(AUnitPaths, Count + 1);
        AUnitPaths[Count] := Part;
        Count := Length(AIncludePaths);
        SetLength(AIncludePaths, Count + 1);
        AIncludePaths[Count] := Part;
      end;
      StartAt := i + 1;
    end;
end;

procedure AppendCompilerSearchDirectories(const AOptions: array of string;
  var ADirectories: TStringArray);
const
  SEARCH_OPTIONS: array[0..4] of string = ('-Fu', '-Fi', '-Fo', '-Fl', '-I');
  SYSROOT_OPTION = '-XR';
var
  Sysroots: TStringArray;

  procedure AddDirectory(APath: string);
  var
    Count, Position: Integer;
  begin
    for Position := 1 to Length(APath) do
      if APath[Position] in ['*', '?', '$'] then
      begin
        APath := Copy(APath, 1, Position - 1);
        while (APath <> '') and not (APath[Length(APath)] in ['/', '\']) do
          Delete(APath, Length(APath), 1);
        if APath = '' then APath := '.';
        Break;
      end;
    if APath = '' then Exit;
    Count := Length(ADirectories);
    SetLength(ADirectories, Count + 1);
    ADirectories[Count] := APath;
  end;

  { FPC's DePascalQuote: a leading ' starts a quoted entry in which ''
    stands for one quote; without its closing quote the entry stays as
    written. }
  function PascalUnquoted(const AEntry: string): string;
  var
    Position: Integer;
  begin
    Result := '';
    Position := 2;
    while Position <= Length(AEntry) do
    begin
      if AEntry[Position] = '''' then
      begin
        if (Position < Length(AEntry)) and (AEntry[Position + 1] = '''') then
          Inc(Position)
        else
          Exit;
      end;
      Result := Result + AEntry[Position];
      Inc(Position);
    end;
    Result := AEntry;
  end;

  procedure AddEntry(AEntry: string; const ALibrary: Boolean);
  var
    Bare: string;
    i: Integer;
  begin
    AEntry := Trim(AEntry);
    { A double-quoted entry reaches FPC as written, since no shell or
      response-file reader removes the quotes: watch both spellings. }
    if (Length(AEntry) >= 2) and (AEntry[1] = '"')
       and (AEntry[Length(AEntry)] = '"') then
      AddEntry(Copy(AEntry, 2, Length(AEntry) - 2), ALibrary)
    else if (AEntry <> '') and (AEntry[1] = '''') then
      AEntry := PascalUnquoted(AEntry);
    if (AEntry = '') or (AEntry[1] <> '=') then
    begin
      AddDirectory(AEntry);
      Exit;
    end;
    Bare := Copy(AEntry, 2, MaxInt);
    if ALibrary then
      for i := 0 to High(Sysroots) do AddDirectory(Sysroots[i] + Bare);
    AddDirectory(Bare);
  end;

  procedure AddOption(const AOption: string);
  var
    Entries, Option: string;
    i, Position, StartAt: Integer;
  begin
    Option := Trim(AOption);
    for i := 0 to High(SEARCH_OPTIONS) do
      if (Length(Option) > Length(SEARCH_OPTIONS[i]))
         and (Copy(Option, 1, Length(SEARCH_OPTIONS[i]))
           = SEARCH_OPTIONS[i]) then
      begin
        Entries := Copy(Option, Length(SEARCH_OPTIONS[i]) + 1, MaxInt);
        StartAt := 1;
        for Position := 1 to Length(Entries) + 1 do
          if (Position > Length(Entries)) or (Entries[Position] = ';')
             {$IFNDEF MSWINDOWS}or (Entries[Position] = ':'){$ENDIF} then
          begin
            AddEntry(Copy(Entries, StartAt, Position - StartAt),
              SEARCH_OPTIONS[i] = '-Fl');
            StartAt := Position + 1;
          end;
        Exit;
      end;
  end;

var
  Count, i: Integer;
  Option: string;
begin
  SetLength(Sysroots, 0);
  for i := 0 to High(AOptions) do
  begin
    Option := Trim(AOptions[i]);
    if (Length(Option) > Length(SYSROOT_OPTION))
       and (Copy(Option, 1, Length(SYSROOT_OPTION)) = SYSROOT_OPTION) then
    begin
      Count := Length(Sysroots);
      SetLength(Sysroots, Count + 1);
      Sysroots[Count] := Copy(Option, Length(SYSROOT_OPTION) + 1, MaxInt);
    end;
  end;
  for i := 0 to High(AOptions) do AddOption(AOptions[i]);
end;

function CreatePascalCompilerProcess(const ASrcFile: string;
  const AUnitPaths, AExtraArguments: array of string; out AOutBin: string;
  out ARequest: TLWPTBuildRequest; const ABuildRoot: string;
  const ADriver: TLWPTCompilerDriver;
  const AConfigurationFile: string): TProcess;
var
  Arguments: LWPT.Core.TStringArray;
  BuildDir: string;
  Capabilities: TLWPTCompilerCapabilities;
  ConfigurationUnitPaths: TStringArray;
  i, UnitPathCount: Integer;
  ScanDirs: TStringArray;

  function SourceBuildKey(const APath: string): string;
  begin
    { Keep compiler paths bounded while distinguishing equal basenames and
      sanitisation collisions by the canonical source path. }
    Result := BuildSessionPathKey(ExpandFileName(APath));
  end;

begin
  if not Assigned(ADriver) then
    raise ELWPTCompilerDriverError.Create('compiler driver is required');
  Result := TProcess.Create(nil);
  try
    if ABuildRoot <> '' then
      BuildDir := IncludeTrailingPathDelimiter(ABuildRoot)
        + SourceBuildKey(ASrcFile)
    else
      BuildDir := MakeTmpPath(TMP_DIR,
        'script-' + SourceBuildKey(ASrcFile));
    ForceDirectories(BuildDir);
    ForceDirectories(BuildDir + '/units');
    AOutBin := IncludeTrailingPathDelimiter(BuildDir)
             + ChangeFileExt(ExtractFileName(ASrcFile), '');

    { Describe the compilation before the selected driver adapts it. }
    ARequest := ADriver.CreateBuildRequest(ASrcFile, AOutBin);
    AOutBin := ARequest.Outputs.Artifact;
    SetLength(ConfigurationUnitPaths, 0);
    AppendUnitDirsFromCfg(AConfigurationFile, ConfigurationUnitPaths);
    UnitPathCount := Length(AUnitPaths) + Length(ConfigurationUnitPaths);
    SetLength(ARequest.Inputs.UnitPaths, UnitPathCount);
    SetLength(ARequest.Inputs.IncludePaths, UnitPathCount);
    for i := 0 to High(AUnitPaths) do
    begin
      ARequest.Inputs.UnitPaths[i] := AUnitPaths[i];
      ARequest.Inputs.IncludePaths[i] := AUnitPaths[i];
    end;
    for i := 0 to High(ConfigurationUnitPaths) do
    begin
      ARequest.Inputs.UnitPaths[Length(AUnitPaths) + i] :=
        ConfigurationUnitPaths[i];
      ARequest.Inputs.IncludePaths[Length(AUnitPaths) + i] :=
        ConfigurationUnitPaths[i];
    end;
    SetLength(ARequest.Inputs.ExtraArguments, Length(AExtraArguments));
    for i := 0 to High(AExtraArguments) do
      ARequest.Inputs.ExtraArguments[i] := AExtraArguments[i];
    AppendCompilerEnvironmentSearchPaths(ARequest.Inputs.UnitPaths,
      ARequest.Inputs.IncludePaths);
    ARequest.Outputs.ExecutableDirectory := BuildDir;
    ARequest.Outputs.UnitDirectory := BuildDir + '/units';
    ARequest.Outputs.ObjectDirectory := BuildDir + '/units';
    ValidateBuildRequest(ARequest);
    { A cached discovery result may shape the request, but every concrete
      compile revalidates live capabilities immediately before translation. }
    Capabilities := ADriver.ProbeCapabilities(ARequest.Target, True);
    EnsureBuildRequestCompatible(ARequest, Capabilities);
    ARequest.Compiler.VersionIdentity := Capabilities.VersionIdentity;

    Arguments := ADriver.InvocationArguments(ADriver.BuildArguments(ARequest,
      PascalSourceCompilerInvocationOptions(AConfigurationFile)));
    Result.Executable := ADriver.ExecutableName;
    if ADriver.WorkingDirectory <> '' then
      Result.CurrentDirectory := ADriver.WorkingDirectory;
    for i := 0 to High(Arguments) do
      Result.Parameters.Add(Arguments[i]);

    { Every -Fu directory is now on the parameter list (explicit, cfg and
      environment additions alike), so the staging path budget can be
      checked against the real worst-case assembly file name. }
    SetLength(ScanDirs, 0);
    AppendUnitDirsFromOptions(Result.Parameters, ScanDirs);
    EnsureCompilerPathBudget(BuildDir + '/units', BuildDir,
      LongestCompiledBaseNameLength(ScanDirs, ASrcFile));
  except
    Result.Free;
    raise;
  end;
end;

function CompilePascal(const ASrcFile: string; const AUnitPaths: array of string;
  out AOutBin: string; out ABuildResult: TLWPTBuildResult;
  out ARawOutput: string; const ABuildRoot: string): Boolean;
var
  Buffer: array[0..PROCESS_OUTPUT_BUFFER_SIZE - 1] of Byte;
  BytesRead, ExitCode: Integer;
  Driver: TLWPTCompilerDriver;
  P: TProcess;
  Request: TLWPTBuildRequest;
begin
  ABuildResult := DefaultBuildResult;
  ARawOutput := '';
  Driver := TLWPTFPCCompilerDriver.Create;
  try
    P := CreatePascalCompilerProcess(ASrcFile, AUnitPaths, [], AOutBin,
      Request, ABuildRoot, Driver);
    try
      P.Options := [poUsePipes, poStderrToOutPut];
      ExecuteUnmanagedProcess(P);
      repeat
        BytesRead := P.Output.Read(Buffer[0], SizeOf(Buffer));
        if BytesRead > 0 then
          AppendRawBytes(ARawOutput, Buffer[0], BytesRead);
      until BytesRead <= 0;
      P.WaitOnExit;
      ExitCode := NormalisedExitCode(P);
      ABuildResult := Driver.NormalizeResult(Request, ExitCode, ARawOutput);
      Result := ABuildResult.Success;
    finally
      P.Free;
    end;
  finally
    Driver.Free;
  end;
end;

function IsAbsoluteFilesystemPath(const APath: string): Boolean;
begin
  Result := (APath <> '') and (APath[1] in ['/', '\']);
  if not Result then
    Result := (Length(APath) >= 3) and (APath[2] = ':')
      and (APath[3] in ['/', '\']);
end;

function ResolveProjectPath(const AProjectRoot, APath: string): string;
begin
  if IsAbsoluteFilesystemPath(APath) then Exit(ExpandFileName(APath));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(AProjectRoot) + APath);
end;

function ResolveRunnableCommand(const AProjectRoot, ACommand: string): string;
{$IFDEF WINDOWS}
var
  SearchPath: string;
{$ENDIF}
begin
  if (Pos('/', ACommand) > 0) or (Pos('\', ACommand) > 0) then
  begin
    Result := ResolveProjectPath(AProjectRoot, ACommand);
    {$IFDEF WINDOWS}
    if (ExtractFileExt(Result) = '') and not FileExists(Result) then
    begin
      if FileExists(Result + '.exe') then Result := Result + '.exe'
      else if FileExists(Result + '.com') then Result := Result + '.com';
    end;
    {$ENDIF}
    Exit;
  end;

  {$IFDEF WINDOWS}
  { TProcess.Executable does not apply PATH or PATHEXT when it passes an
    application name directly to CreateProcess. Search only the inherited
    PATH (never the implicit current directory), without involving a shell. }
  SearchPath := GetEnvironmentVariable('PATH');
  Result := FileSearch(ACommand, SearchPath, [sfoStripQuotes]);
  if (Result = '') and (ExtractFileExt(ACommand) = '') then
  begin
    Result := FileSearch(ACommand + '.exe', SearchPath, [sfoStripQuotes]);
    if Result = '' then
      Result := FileSearch(ACommand + '.com', SearchPath, [sfoStripQuotes]);
  end;
  if Result = '' then Result := ACommand;
  {$ELSE}
  { Leave Unix lookup to execvp so a non-executable entry does not mask a
    later executable with the same name in PATH. }
  Result := ACommand;
  {$ENDIF}
end;

function PatternHasGlob(const APattern: string): Boolean;
begin
  Result := (Pos('*', APattern) > 0) or (Pos('?', APattern) > 0);
end;

function StaticGlobPrefix(const APattern: string): string;
var
  Segment: string;
  SlashAt, StartAt: Integer;
begin
  Result := '';
  StartAt := 1;
  while StartAt <= Length(APattern) do
  begin
    SlashAt := Pos('/', Copy(APattern, StartAt, MaxInt));
    if SlashAt = 0 then Segment := Copy(APattern, StartAt, MaxInt)
    else Segment := Copy(APattern, StartAt, SlashAt - 1);
    if PatternHasGlob(Segment) then Exit;
    if Result <> '' then Result := Result + '/';
    Result := Result + Segment;
    if SlashAt = 0 then Exit;
    Inc(StartAt, SlashAt);
  end;
end;

procedure CollectGlobFiles(const AProjectRoot, ADirectory, APattern: string;
  const AFiles: TStringList);
var
  Search: TSearchRec;
  FullPath, RelativePath: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile or faSymLink, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Name <> '') and (Search.Name[1] = '.') then Continue;
      FullPath := IncludeTrailingPathDelimiter(ADirectory) + Search.Name;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        if ((Search.Attr and faSymLink) = 0)
           and not IsDirSymlinkOrJunction(FullPath) then
          CollectGlobFiles(AProjectRoot, FullPath, APattern, AFiles);
      end
      else
      begin
        RelativePath := ExtractRelativePath(
          IncludeTrailingPathDelimiter(AProjectRoot), FullPath);
        RelativePath := StringReplace(RelativePath, '\', '/', [rfReplaceAll]);
        if MatchPathGlob(RelativePath, APattern) then AFiles.Add(FullPath);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure ResolveInputExpression(const AHook: THook;
  const AProjectRoot, AExpression: string; const AFiles: TStringList);
var
  i: Integer;
  Canonical, Prefix, SearchRoot: string;
  Matches: TStringList;
begin
  Matches := TStringList.Create;
  try
  Canonical := CanonicalPathGlob(AExpression);
  if IsAbsoluteFilesystemPath(Canonical) or (Canonical = '..')
     or (Copy(Canonical, 1, 3) = '../') then
    raise EManifestError.CreateFmt(
      'runnable "%s": input "%s" must be project-root-relative',
      [AHook.Name, AExpression]);
  if not PatternHasGlob(Canonical) then
  begin
    SearchRoot := ResolveProjectPath(AProjectRoot, Canonical);
    if not PathContains(AProjectRoot, SearchRoot) then
      raise EManifestError.CreateFmt(
        'runnable "%s": input "%s" must be project-root-relative',
        [AHook.Name, AExpression]);
    if FileExists(SearchRoot) then Matches.Add(SearchRoot);
  end
  else
  begin
    Prefix := StaticGlobPrefix(Canonical);
    if Prefix = '' then SearchRoot := AProjectRoot
    else
    begin
      SearchRoot := ResolveProjectPath(AProjectRoot, Prefix);
      if not PathContains(AProjectRoot, SearchRoot) then
        raise EManifestError.CreateFmt(
          'runnable "%s": input "%s" must be project-root-relative',
          [AHook.Name, AExpression]);
      if not DirectoryExists(SearchRoot) then
        SearchRoot := ExtractFileDir(SearchRoot);
    end;
    if DirectoryExists(SearchRoot) then
      CollectGlobFiles(AProjectRoot, SearchRoot, Canonical, Matches);
  end;
  if Matches.Count = 0 then
    raise EManifestError.CreateFmt(
      'runnable "%s": input expression "%s" matched no files',
      [AHook.Name, AExpression]);
  for i := 0 to Matches.Count - 1 do AFiles.Add(Matches[i]);
  finally
    Matches.Free;
  end;
end;

const
  HOOK_RUN_RECORD_DIR = BUILD_SESSIONS_DIR + '/hook-runs';
  HOOK_RUN_RECORD_SCHEMA = 'lwpt-hook-run-v1';
  HOOK_DIGEST_BUFFER_BYTES = 65536;

function HookTextDigest(const AText: string): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Bytes[0], Length(AText));
  Result := SHA256BytesPrefixed(Bytes);
end;

{ A project-relative path in the record's spelling. Only the platform's
  own separator maps to '/': on Unix a backslash is an ordinary filename
  character, so a\b and a/b stay distinct. }
function HookRecordPath(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  {$ENDIF}
end;

{ The record belongs to the output path: one hook writes one output, so
  the number of records stays bounded by the number of gated outputs. It
  lives below the default sessions directory, which repair never sweeps
  (repair reclaims only session directories). A lost record only makes the
  hook run once more. }
function HookRunRecordPath(const AHook: THook;
  const AProjectRoot: string): string;
var
  Key: string;
begin
  Key := HookTextDigest(HookRecordPath(AHook.Output));
  Result := ResolveProjectPath(AProjectRoot, HOOK_RUN_RECORD_DIR) + '/'
    + Copy(Key, Length('sha256:') + 1, 32) + '.record';
end;

{ The declaration the record was made for. A changed command, argument,
  input expression or output makes an older record inapplicable. Every
  field is length-prefixed, so no field can spell another. }
function HookDefinitionDigest(const AHook: THook): string;
var
  Fields: TStringList;
  i: Integer;
begin
  Fields := TStringList.Create;
  try
    Fields.Add('command=' + IntToStr(Length(AHook.Runnable.Command)) + ':'
      + AHook.Runnable.Command);
    for i := 0 to High(AHook.Runnable.Args) do
      Fields.Add('arg=' + IntToStr(Length(AHook.Runnable.Args[i])) + ':'
        + AHook.Runnable.Args[i]);
    for i := 0 to High(AHook.Inputs) do
      Fields.Add('input=' + IntToStr(Length(AHook.Inputs[i])) + ':'
        + AHook.Inputs[i]);
    Fields.Add('output=' + IntToStr(Length(AHook.Output)) + ':'
      + AHook.Output);
    Fields.LineBreak := #10;
    Result := HookTextDigest(Fields.Text);
  finally
    Fields.Free;
  end;
end;

{ A regular file opened for reading, validated through the opened handle:
  a FIFO, device or directory, even one swapped in after the path was
  matched, is refused before any read. On Unix the descriptor is opened
  without blocking and close-on-exec (through the spawn guard), so neither
  a FIFO nor a concurrently started compiler can hold it. Reads keep errors
  apart from end of file, which TStream.Read does not. }
{$IFDEF MSWINDOWS}
{ Declared here rather than through the Windows unit, whose names would
  shadow SysUtils routines this unit calls. }
function HookGetFileType(AHandle: THandle): LongWord; stdcall;
  external 'kernel32' name 'GetFileType';

const
  HOOK_FILE_TYPE_DISK = 1;
{$ENDIF}

type
  THookRegularFile = record
    {$IFDEF UNIX}
    Descriptor: LongInt;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Stream: TLWPTProtectedFileStream;
    {$ENDIF}
  end;

function OpenHookRegularFile(const APath: string;
  out AFile: THookRegularFile): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
{$ENDIF}
begin
  Result := False;
  {$IFDEF UNIX}
  AFile.Descriptor := OpenProtectedDescriptor(APath, O_RDONLY or O_NONBLOCK,
    0);
  if AFile.Descriptor < 0 then Exit;
  if (FpFStat(AFile.Descriptor, Info) <> 0)
    or not FpS_ISREG(Info.st_mode) then
  begin
    FpClose(AFile.Descriptor);
    Exit;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  try
    AFile.Stream := OpenProtectedFileStream(APath,
      fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do Exit;
  end;
  if HookGetFileType(AFile.Stream.Handle) <> HOOK_FILE_TYPE_DISK then
  begin
    FreeAndNil(AFile.Stream);
    Exit;
  end;
  {$ENDIF}
  Result := True;
end;

{ Bytes read, 0 at end of file, or -1 on a read error. }
function ReadHookRegularFile(var AFile: THookRegularFile; var ABuffer;
  const ACount: LongInt): LongInt;
begin
  {$IFDEF UNIX}
  repeat
    Result := FpRead(AFile.Descriptor, ABuffer, ACount);
  until (Result >= 0) or (FpGetErrNo <> ESysEINTR);
  if Result < 0 then Result := -1;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Result := FileRead(AFile.Stream.Handle, ABuffer, ACount);
  if Result < 0 then Result := -1;
  {$ENDIF}
end;

procedure CloseHookRegularFile(var AFile: THookRegularFile);
begin
  {$IFDEF UNIX}
  FpClose(AFile.Descriptor);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FreeAndNil(AFile.Stream);
  {$ENDIF}
end;

{ SHA-256 of a regular file's content, or '' when it is not a regular file
  or any open or read fails. '' always means stale, so an unreadable input
  runs the command and an unreadable output after a run only skips the
  record. }
function HookFileDigest(const APath: string): string;
var
  Buffer: array[0..HOOK_DIGEST_BUFFER_BYTES - 1] of Byte;
  Context: TSHA256Context;
  Digest: TSHA256Digest;
  Count: LongInt;
  HookFile: THookRegularFile;
begin
  Result := '';
  if not OpenHookRegularFile(APath, HookFile) then Exit;
  try
    SHA256Init(Context);
    repeat
      Count := ReadHookRegularFile(HookFile, Buffer[0], SizeOf(Buffer));
      if Count < 0 then Exit;
      if Count > 0 then SHA256Update(Context, Buffer[0], Count);
    until Count = 0;
    SHA256Final(Context, Digest);
    Result := SHA256DigestHex(Digest);
  finally
    CloseHookRegularFile(HookFile);
  end;
end;

{ A regular file's whole content, for the small run records. }
function ReadHookRegularText(const APath: string; out AText: string): Boolean;
var
  Buffer: array[0..HOOK_DIGEST_BUFFER_BYTES - 1] of Byte;
  Count: LongInt;
  HookFile: THookRegularFile;
begin
  Result := False;
  AText := '';
  if not OpenHookRegularFile(APath, HookFile) then Exit;
  try
    repeat
      Count := ReadHookRegularFile(HookFile, Buffer[0], SizeOf(Buffer));
      if Count < 0 then Exit;
      if Count > 0 then AppendRawBytes(AText, Buffer[0], Count);
    until Count = 0;
    Result := True;
  finally
    CloseHookRegularFile(HookFile);
  end;
end;

{ A collected input's path relative to the project root, in the record's
  spelling. Collected paths start with the root, so on Unix the prefix is
  stripped without reparsing the rest, where a backslash is an ordinary
  filename character that ExtractRelativePath would treat as a separator. }
function HookRelativeInputPath(const AProjectRoot, APath: string): string;
var
  Prefix: string;
begin
  Prefix := IncludeTrailingPathDelimiter(AProjectRoot);
  if Copy(APath, 1, Length(Prefix)) = Prefix then
    Result := Copy(APath, Length(Prefix) + 1, MaxInt)
  else
    Result := ExtractRelativePath(Prefix, APath);
  Result := HookRecordPath(Result);
end;

{ The files AHook's input expressions match, sorted and case-sensitive,
  so Foo.pas and foo.pas on a case-sensitive filesystem are two inputs
  rather than one. The gate and the post-run check use this one collector
  so their snapshots cover the same set. Raises as ResolveInputExpression
  does; the caller owns the list. }
function CollectHookInputs(const AHook: THook;
  const AProjectRoot: string): TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  try
    Result.CaseSensitive := True;
    Result.Sorted := True;
    Result.Duplicates := dupIgnore;
    for i := 0 to High(AHook.Inputs) do
      ResolveInputExpression(AHook, AProjectRoot, AHook.Inputs[i], Result);
  except
    Result.Free;
    raise;
  end;
end;

{ Content digest of the resolved input set: each file's project-relative
  path and SHA-256, in sorted order. A file that cannot be read gives ''
  so the hook counts as stale. }
function HookInputsDigest(const AProjectRoot: string;
  const AFiles: TStringList): string;
var
  Fields: TStringList;
  i: Integer;
  Content, Relative: string;
begin
  Result := '';
  Fields := TStringList.Create;
  try
    for i := 0 to AFiles.Count - 1 do
    begin
      Content := HookFileDigest(AFiles[i]);
      if Content = '' then Exit;
      Relative := HookRelativeInputPath(AProjectRoot, AFiles[i]);
      Fields.Add(IntToStr(Length(Relative)) + ':' + Relative + '=' + Content);
    end;
    Fields.LineBreak := #10;
    Result := HookTextDigest(Fields.Text);
  finally
    Fields.Free;
  end;
end;

function ReadHookRunRecord(const APath: string; out ADefinition, AInputs,
  AOutput: string): Boolean;
var
  Lines: TStringList;
  Text: string;
begin
  Result := False;
  ADefinition := '';
  AInputs := '';
  AOutput := '';
  if not ReadHookRegularText(APath, Text) then Exit;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    if (Lines.Count <> 4) or (Lines[0] <> HOOK_RUN_RECORD_SCHEMA) then Exit;
    ADefinition := Lines[1];
    AInputs := Lines[2];
    AOutput := Lines[3];
    Result := (ADefinition <> '') and (AInputs <> '') and (AOutput <> '');
  finally
    Lines.Free;
  end;
end;

{ Modification times alone cannot say whether an output was generated from
  the inputs present now. A version-control checkout, merge resolution or
  copy can write an output from another generation after the inputs, so it
  is newer than every input and yet stale. The gate therefore also compares
  content with the record of the last successful run: the declaration, the
  digest of the resolved inputs, and the digest of the output it left. A
  missing or unreadable record, or any difference, runs the command.

  The time comparison stays, at full resolution (#367), so that making an
  input newer (touch) still forces a run. FileAge rounds to whole seconds on
  Unix and to 2-second DOS time on Windows, so an input edited in the same
  tick as the output's last write looked as old as the output and the edit
  was skipped. An input exactly as new as the output is stale: equal times
  are rare at full resolution but common on filesystems that keep coarse
  ones (FAT, some network filesystems, HFS+ at one second), where an edit
  can carry the output's own time. The command therefore re-runs until its
  output is strictly newer than every input: usually once, but again on
  each invocation while the equality persists, as when several invocations
  land in one coarse tick or a generator leaves an unchanged output's time
  alone. An input that vanishes before it is read is stale too. }
function HookIsStale(const AHook: THook; const AProjectRoot: string;
  out AInputDigest: string): Boolean;
var
  OutputStamp, InputStamp: TLWPTModificationStamp;
  i: Integer;
  Files: TStringList;
  OutputPath, RecordedDefinition, RecordedInputs, RecordedOutput: string;
begin
  AInputDigest := '';
  { Always-run hooks (no inputs/output declared) never short-circuit. }
  if (AHook.Output = '') or (Length(AHook.Inputs) = 0) then Exit(True);
  Files := CollectHookInputs(AHook, AProjectRoot);
  try
    AInputDigest := HookInputsDigest(AProjectRoot, Files);
    OutputPath := ResolveProjectPath(AProjectRoot, AHook.Output);
    if not LongPathModificationStamp(OutputPath, OutputStamp) then
      Exit(True);
    for i := 0 to Files.Count - 1 do
      if not LongPathModificationStamp(Files[i], InputStamp)
        or (CompareModificationStamps(InputStamp, OutputStamp) >= 0) then
        Exit(True);
    if AInputDigest = '' then Exit(True);
    if not ReadHookRunRecord(HookRunRecordPath(AHook, AProjectRoot),
      RecordedDefinition, RecordedInputs, RecordedOutput) then
      Exit(True);
    Result := (RecordedDefinition <> HookDefinitionDigest(AHook))
      or (RecordedInputs <> AInputDigest)
      or (RecordedOutput <> HookFileDigest(OutputPath));
  finally
    Files.Free;
  end;
end;

function HookIsStale(const AHook: THook;
  const AProjectRoot: string): Boolean;
var
  InputDigest: string;
begin
  Result := HookIsStale(AHook, AProjectRoot, InputDigest);
end;

{ The inputs' digest now, or '' when they can no longer be collected. }
function CurrentHookInputsDigest(const AHook: THook;
  const AProjectRoot: string): string;
var
  Files: TStringList;
begin
  try
    Files := CollectHookInputs(AHook, AProjectRoot);
  except
    on E: Exception do Exit('');
  end;
  try
    Result := HookInputsDigest(AProjectRoot, Files);
  finally
    Files.Free;
  end;
end;

procedure RecordHookRun(const AHook: THook;
  const AProjectRoot, ATmpRoot, AInputDigest: string);
var
  Lines: TStringList;
  OutputDigest, RecordPath: string;
begin
  if (AHook.Output = '') or (Length(AHook.Inputs) = 0)
    or (AInputDigest = '') or AHook.SessionPrivateOutput then Exit;
  OutputDigest := HookFileDigest(
    ResolveProjectPath(AProjectRoot, AHook.Output));
  if OutputDigest = '' then Exit;
  { Inputs whose digest after the command differs from the one taken
    before it may or may not have reached the output, so nothing is
    recorded. Two snapshots cannot see a change that was reverted while
    the command ran. }
  if CurrentHookInputsDigest(AHook, AProjectRoot) <> AInputDigest then Exit;
  RecordPath := HookRunRecordPath(AHook, AProjectRoot);
  Lines := TStringList.Create;
  try
    Lines.Add(HOOK_RUN_RECORD_SCHEMA);
    Lines.Add(HookDefinitionDigest(AHook));
    Lines.Add(AInputDigest);
    Lines.Add(OutputDigest);
    Lines.LineBreak := #10;
    try
      { Staged through the project temporary root, like every multi-step
        write to toolkit state, so repair sweeps what an interrupted write
        leaves behind. }
      AtomicWriteText(RecordPath, ResolveProjectPath(AProjectRoot, ATmpRoot),
        Lines);
    except
      { The record only lets a later invocation skip the command. Without
        it the command runs again, which is always safe, so a write
        failure must not fail the command that just succeeded. }
      on E: Exception do;
    end;
  finally
    Lines.Free;
  end;
end;

function RunRunnableWithEnvironment(const AHook: THook;
  out AError: string; const AProjectRoot: string;
  const AEnvironment: array of string): Integer;
var
  P: TProcess;
  InheritedEnvironment: TStringList;
  i, j, SeparatorAt: Integer;
  Existing, ExistingName, ExtraName: string;
  CapturedError, CapturedOutput: string;
  ChildFailed: Boolean;
  ProcessOptions: TLWPTProcessRunOptions;
  ProcessRunner: TLWPTDuplexProcessRunner;
begin
  AError := '';
  P := TProcess.Create(nil);
  try
    P.Executable := ResolveRunnableCommand(AProjectRoot,
      AHook.Runnable.Command);
    P.CurrentDirectory := AProjectRoot;
    if Length(AEnvironment) > 0 then
    begin
      { Hooks run on the scheduler thread while build jobs materialise
        their own child environments; sweep via the shared snapshot so
        this walk cannot race the RTL's lazy env count (see LWPT.Core). }
      InheritedEnvironment := TStringList.Create;
      try
        AppendProcessEnvironment(InheritedEnvironment);
        for i := 0 to InheritedEnvironment.Count - 1 do
        begin
          Existing := InheritedEnvironment[i];
          SeparatorAt := Pos('=', Existing);
          if SeparatorAt > 0 then
            ExistingName := Copy(Existing, 1, SeparatorAt - 1)
          else
            ExistingName := Existing;
          for j := 0 to High(AEnvironment) do
          begin
            SeparatorAt := Pos('=', AEnvironment[j]);
            if SeparatorAt > 0 then
              ExtraName := Copy(AEnvironment[j], 1, SeparatorAt - 1)
            else
              ExtraName := AEnvironment[j];
            if SameText(ExistingName, ExtraName) then
            begin
              Existing := '';
              Break;
            end;
          end;
          if Existing <> '' then P.Environment.Add(Existing);
        end;
      finally
        InheritedEnvironment.Free;
      end;
      for i := 0 to High(AEnvironment) do
        P.Environment.Add(AEnvironment[i]);
    end;
    for j := 0 to High(AHook.Runnable.Args) do
      P.Parameters.Add(AHook.Runnable.Args[j]);
    try
      if SilentOutputActive then
      begin
        ProcessRunner := TLWPTDuplexProcessRunner.Create(P);
        try
          ProcessOptions := DefaultProcessRunOptions(
            'runnable "' + AHook.Name + '"');
          ProcessOptions.SeparateStandardError := True;
          ProcessOptions.DiscardCapturedOutput := True;
          ProcessOptions.OnOutputChunk := @CaptureSilentProcessChunk;
          BeginSilentChildOperation;
          ChildFailed := True;
          try
            Result := ProcessRunner.Run('', ProcessOptions, CapturedOutput,
              CapturedError);
            ChildFailed := Result <> 0;
          finally
            FinishSilentChildOperation(ChildFailed);
          end;
        finally
          ProcessRunner.Free;
        end;
      end
      else
      begin
        ExecuteUnmanagedProcess(P);
        P.WaitOnExit;
        Result := NormalisedExitCode(P);
      end;
    except
      on E: Exception do
      begin
        AError := 'command unavailable (' + E.Message + ')';
        Exit(127);
      end;
    end;
  finally
    P.Free;
  end;
end;

procedure RunHooksWithEnvironment(const APhase: string;
  const AHooks: THookArray; const AProjectRoot, ATmpRoot: string;
  const AEnvironment: array of string);
var
  i, Code: Integer;
  H: THook;
  InputDigest, RunnableError: string;
begin
  if Length(AHooks) = 0 then Exit;
  for i := 0 to High(AHooks) do
  begin
    H := AHooks[i];

    if not HookIsStale(H, AProjectRoot, InputDigest) then
    begin
      WriteLn('  [', APhase, '] ', H.Name, ' (skipped — output fresh)');
      Continue;
    end;

    WriteLn('  [', APhase, '] ', H.Name);

    Code := RunRunnableWithEnvironment(H, RunnableError, AProjectRoot,
      AEnvironment);
    if RunnableError <> '' then
      raise ELWPTError.CreateFmt(
        '[%s] %s: %s while running %s',
        [APhase, H.Name, RunnableError, H.Runnable.Command]);

    if Code <> 0 then
      raise ELWPTError.CreateFmt(
        '[%s] %s: command exited %d while running %s',
        [APhase, H.Name, Code, H.Runnable.Command]);
    RecordHookRun(H, AProjectRoot, ATmpRoot, InputDigest);
  end;
end;

procedure RunHooks(const APhase: string; const AHooks: THookArray;
  const AProjectRoot, ATmpRoot: string);
begin
  RunHooksWithEnvironment(APhase, AHooks, AProjectRoot, ATmpRoot, []);
end;

function RunUserTask(const ATask: THook;
  const AProjectRoot, ATmpRoot: string): Integer;
var
  InputDigest, TaskError: string;
begin
  if not HookIsStale(ATask, AProjectRoot, InputDigest) then Exit(0);
  Result := RunRunnableWithEnvironment(ATask, TaskError, AProjectRoot, []);
  if (Result = 0) and (TaskError = '') then
    RecordHookRun(ATask, AProjectRoot, ATmpRoot, InputDigest);
  if TaskError <> '' then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: ', TaskError, '.');
    if Result = 0 then Result := 1;
  end;
end;

end.
