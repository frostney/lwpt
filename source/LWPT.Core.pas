{ LWPT.Core — project identity, error hierarchy, and shared helpers. }
unit LWPT.Core;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

uses
  Classes,
  SysUtils,

  TOML;

const
  PROGRAM_NAME    = 'lwpt';
  PROJECT_NAME    = 'LWPT';
  {$I Version.inc}

  MANIFEST_FILE = PROGRAM_NAME + '.toml';
  LOCKFILE      = PROGRAM_NAME + '.lock';
  CFG_FILE      = PROGRAM_NAME + '.cfg';

  LWPT_DIR      = '.' + PROGRAM_NAME;
  MODULES_DIR   = LWPT_DIR + '/modules';
  ARCHIVES_DIR  = LWPT_DIR + '/archives';
  TMP_DIR       = LWPT_DIR + '/tmp';
  INSTALL_LOCK  = LWPT_DIR + '/install.lock';

  GITIGNORE_LINE = LWPT_DIR + '/tmp/';

  PLACEHOLDER_USER       = '{user}';
  PLACEHOLDER_REPOSITORY = '{repository}';
  PLACEHOLDER_REF        = '{ref}';

type
  ELWPTError = class(Exception)
  public
    Operation: string;
    Recovery: string;
  end;
  EFetchError       = class(ELWPTError);
  EVerifyError      = class(ELWPTError);
  EExtractError     = class(ELWPTError);
  ELockfileError    = class(ELWPTError);
  EManifestError    = class(ELWPTError);
  EConcurrencyError = class(ELWPTError);

  TStringArray = array of string;

function  FPCExecutable: string;
function  InstantFPCExecutable: string;
procedure AddEnvUnitPathParameters(AParameters: TStrings);
function  NativePath(const APath: string): string;

function  TomlGet(ANode: TTOMLNode; const AKey: string): TTOMLNode;
function  TomlIsString(ANode: TTOMLNode): Boolean;
function  TomlIsInt(ANode: TTOMLNode): Boolean;
function  TomlIsTable(ANode: TTOMLNode): Boolean;
function  TomlIsArray(ANode: TTOMLNode): Boolean;
function  TomlStr(ANode: TTOMLNode; const AKey, ADefault: string): string;
function  TomlInt(ANode: TTOMLNode; const AKey: string; ADefault: Int64): Int64;

function  MatchPathGlob(const APath, APattern: string): Boolean;
procedure ApplyIncludeExclude(const ARoot: string; const AIncludes, AExcludes: TStringArray);

function  CopyFileContent(const ASrc, ADst: string): Boolean;
procedure CopyDirTree(const ASrc, ADst: string);
function  MakeTmpPath(const ATmpRoot, AHint: string): string;
procedure WipeDir(const APath: string);
function  AtomicMoveFile(const ASrc, ADst: string): Boolean;
function  AtomicMoveDir(const ASrc, ADst: string): Boolean;
procedure AtomicWriteText(const ADst: string; const ATmpRoot: string; const AContent: TStringList);
procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);
function  SHA256BytesPrefixed(const ABytes: TBytes): string;
function  SHA256Hex(const AData: TBytes): string;
function  SHA256File(const APath: string): string;
function  HashTree(const APathOrArchive: string): string;

implementation

function FPCExecutable: string;
begin
  Result := GetEnvironmentVariable('LWPT_FPC');
  if Result = '' then
    Result := GetEnvironmentVariable('FPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'fpc.exe';
  {$ELSE}
  Result := 'fpc';
  {$ENDIF}
end;

function InstantFPCExecutable: string;
begin
  Result := GetEnvironmentVariable('LWPT_INSTANTFPC');
  if Result = '' then
    Result := GetEnvironmentVariable('INSTANTFPC');
  if Result <> '' then
    Exit;
  {$IFDEF MSWINDOWS}
  Result := 'instantfpc.exe';
  {$ELSE}
  Result := 'instantfpc';
  {$ENDIF}
end;

procedure AddEnvUnitPathParameters(AParameters: TStrings);
var
  Raw, Part : string;
  StartAt, i : Integer;
begin
  Raw := GetEnvironmentVariable('LWPT_FPC_UNIT_PATHS');
  if Raw = '' then
    Exit;

  StartAt := 1;
  for i := 1 to Length(Raw) + 1 do
    if (i > Length(Raw)) or (Raw[i] = PathSeparator) then
    begin
      Part := Copy(Raw, StartAt, i - StartAt);
      if Part <> '' then
      begin
        AParameters.Add('-Fu' + Part);
        AParameters.Add('-Fi' + Part);
      end;
      StartAt := i + 1;
    end;
end;

function NativePath(const APath: string): string;
begin
  Result := APath;
  {$IFDEF MSWINDOWS}
  Result := StringReplace(Result, '/', DirectorySeparator, [rfReplaceAll]);
  {$ENDIF}
end;

{ ===========================================================================
  TOML helpers — manifest + lockfile readers used to drive their
  own partial reader (TTomlReader / TTomlNode record); after the
  TOML.pas conversion (port of GocciaScript's full TOML 1.1 parser)
  the readers go through TTOMLParser + the TTOMLNode class hierarchy.

  Helpers below provide the same conveniences as the old TomlGet /
  TomlStr but operate on TTOMLNode (class) instead of PTomlNode
  (record pointer). Lookup uses TOrderedStringMap.TryGetValue which
  is O(1) average and preserves insertion order for iteration.
  =========================================================================== }
function TomlGet(ANode: TTOMLNode; const AKey: string): TTOMLNode;
begin
  Result := nil;
  if (ANode = nil) or (ANode.Kind <> tnkTable) then Exit;
  if not ANode.Children.TryGetValue(AKey, Result) then Result := nil;
end;

function TomlIsString(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskString);
end;

function TomlIsInt(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and (ANode.Kind = tnkScalar)
        and (ANode.ScalarKind = tskInteger);
end;

function TomlIsTable(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil) and (ANode.Kind = tnkTable);
end;

function TomlIsArray(ANode: TTOMLNode): Boolean; inline;
begin
  Result := (ANode <> nil)
        and ((ANode.Kind = tnkArray) or (ANode.Kind = tnkArrayOfTables));
end;

function TomlStr(ANode: TTOMLNode;
  const AKey, ADefault: string): string;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsString(N) then Result := N.ScalarText
  else Result := ADefault;
end;

function TomlInt(ANode: TTOMLNode; const AKey: string;
  ADefault: Int64): Int64;
var N: TTOMLNode;
begin
  N := TomlGet(ANode, AKey);
  if TomlIsInt(N) then Result := StrToInt64Def(N.ScalarText, ADefault)
  else Result := ADefault;
end;

function MatchSegment(const APattern, AName: string): Boolean;
var
  P, N, StarP, StarN: Integer;
begin
  P := 1; N := 1;
  StarP := 0; StarN := 0;
  while N <= Length(AName) do
  begin
    if (P <= Length(APattern)) and (APattern[P] = '?') then
    begin Inc(P); Inc(N); end
    else if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin StarP := P; Inc(P); StarN := N; end
    else if (P <= Length(APattern)) and (APattern[P] = AName[N]) then
    begin Inc(P); Inc(N); end
    else if StarP <> 0 then
    begin P := StarP + 1; Inc(StarN); N := StarN; end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do Inc(P);
  Result := P > Length(APattern);
end;

function SplitPathSegments(const APath: string): TStringArray;
var i, Start, n: Integer;
begin
  SetLength(Result, 0);
  Start := 1;
  for i := 1 to Length(APath) do
    if APath[i] = '/' then
    begin
      if i > Start then
      begin
        n := Length(Result); SetLength(Result, n + 1);
        Result[n] := Copy(APath, Start, i - Start);
      end;
      Start := i + 1;
    end;
  if Start <= Length(APath) then
  begin
    n := Length(Result); SetLength(Result, n + 1);
    Result[n] := Copy(APath, Start, MaxInt);
  end;
end;

function MatchPathGlob(const APath, APattern: string): Boolean;
var
  PathSegs, PatSegs: TStringArray;

  function DoMatch(APathIdx, APatIdx: Integer): Boolean;
  var i: Integer;
  begin
    while (APatIdx < Length(PatSegs))
          and (PathSegs <> nil) and (APathIdx <= High(PathSegs)) do
    begin
      if PatSegs[APatIdx] = '**' then
      begin
        { ** at the end of the pattern matches every remaining path
          segment unconditionally. Otherwise try matching it against
          0..N path segments and recurse on the rest. }
        if APatIdx = High(PatSegs) then Exit(True);
        for i := APathIdx to Length(PathSegs) do
          if DoMatch(i, APatIdx + 1) then Exit(True);
        Exit(False);
      end;
      if not MatchSegment(PatSegs[APatIdx], PathSegs[APathIdx]) then
        Exit(False);
      Inc(APathIdx); Inc(APatIdx);
    end;
    { Trailing ** in the pattern matches a zero-segment tail. }
    while (APatIdx < Length(PatSegs)) and (PatSegs[APatIdx] = '**') do
      Inc(APatIdx);
    Result := (APathIdx >= Length(PathSegs))
          and (APatIdx >= Length(PatSegs));
  end;

begin
  PathSegs := SplitPathSegments(APath);
  PatSegs  := SplitPathSegments(APattern);
  Result := DoMatch(0, 0);
end;

{ Apply [dependencies].<name>.include / .exclude globs against the
  freshly-extracted modules tree under ARoot. Files outside the
  include set OR inside the exclude set are deleted; empty dirs are
  reaped after the file pass. ARoot itself is never deleted. }
function PathMatchesAny(const ARelPath: string;
  const AGlobs: TStringArray): Boolean;
var i: Integer;
begin
  for i := 0 to High(AGlobs) do
    if MatchPathGlob(ARelPath, AGlobs[i]) then Exit(True);
  Result := False;
end;

procedure ApplyIncludeExclude(const ARoot: string;
  const AIncludes, AExcludes: TStringArray);

  function ShouldKeep(const ARelPath: string): Boolean;
  begin
    Result := True;
    if (Length(AIncludes) > 0) and not PathMatchesAny(ARelPath, AIncludes) then
      Exit(False);
    if PathMatchesAny(ARelPath, AExcludes) then
      Exit(False);
  end;

  function WalkAndPrune(const ADir, ARelDir: string): Integer;
  var SR: TSearchRec; Base, RelPath, Full: string;
  begin
    Result := 0;
    Base := IncludeTrailingPathDelimiter(ADir);
    if FindFirst(Base + '*', faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if ARelDir = '' then RelPath := SR.Name
          else RelPath := ARelDir + '/' + SR.Name;
          Full := Base + SR.Name;
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if WalkAndPrune(Full, RelPath) = 0 then
              RemoveDir(Full)
            else
              Inc(Result);
          end
          else if ShouldKeep(RelPath) then
            Inc(Result)
          else
            DeleteFile(Full);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
  end;

begin
  if (Length(AIncludes) = 0) and (Length(AExcludes) = 0) then Exit;
  WalkAndPrune(ARoot, '');
end;

function CopyFileContent(const ASrc, ADst: string): Boolean;
var SrcS, DstS: TFileStream;
begin
  Result := False;
  if not FileExists(ASrc) then Exit;
  try
    SrcS := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
    try
      DstS := TFileStream.Create(ADst, fmCreate);
      try
        if SrcS.Size > 0 then DstS.CopyFrom(SrcS, SrcS.Size);
      finally
        DstS.Free;
      end;
    finally
      SrcS.Free;
    end;
    Result := True;
  except
    Result := False;
  end;
end;

{ Recursive directory copy. Used for the local source and for resolving
  directory symlinks during extraction. }
procedure CopyDirTree(const ASrc, ADst: string);
var SR: TSearchRec; S, D: string;
begin
  ForceDirectories(ADst);
  S := IncludeTrailingPathDelimiter(ASrc);
  D := IncludeTrailingPathDelimiter(ADst);
  if FindFirst(S + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        CopyDirTree(S + SR.Name, D + SR.Name)
      else
        CopyFileContent(S + SR.Name, D + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function ProcessIdStr: string;
begin
  Result := IntToStr(GetProcessID);
end;

function MakeTmpPath(const ATmpRoot, AHint: string): string;
var Counter: Int64;
begin
  ForceDirectories(ATmpRoot);
  Counter := Round(Now * 1000000);   { microseconds since epoch-ish; unique enough }
  Result := IncludeTrailingPathDelimiter(ATmpRoot)
          + AHint + '.' + ProcessIdStr + '.' + IntToStr(Counter) + '.tmp';
end;

procedure WipeDir(const APath: string);
var SR: TSearchRec; Base, Full: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := Base + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          WipeDir(Full)
        else
          DeleteFile(Full);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

function AtomicMoveFile(const ASrc, ADst: string): Boolean;
var DstDir: string;
begin
  if not FileExists(ASrc) then Exit(False);
  if FileExists(ADst) then DeleteFile(ADst);
  DstDir := ExtractFileDir(ADst);
  if DstDir <> '' then ForceDirectories(DstDir);
  Result := RenameFile(ASrc, ADst);
  if Result then Exit;
  { Rename failed — most commonly EXDEV (cross-filesystem). Fall back
    to copy-then-delete; the source is untouched until the copy is
    fully written, so a crash mid-copy still leaves the source intact
    for retry. }
  if CopyFileContent(ASrc, ADst) then
  begin
    DeleteFile(ASrc);
    Result := True;
  end;
end;

function AtomicMoveDir(const ASrc, ADst: string): Boolean;
var DstDir: string;
begin
  if not DirectoryExists(ASrc) then Exit(False);
  WipeDir(ADst);   { idempotent: tolerates the dst not existing }
  DstDir := ExtractFileDir(ExcludeTrailingPathDelimiter(ADst));
  if DstDir <> '' then ForceDirectories(DstDir);
  Result := RenameFile(ASrc, ADst);
  if Result then Exit;
  { EXDEV path: recursive copy + wipe-source. Slower, not strictly
    atomic against crashes mid-copy, but the partial-state isn't worse
    than what we started with — repair recovers. }
  ForceDirectories(ADst);
  CopyDirTree(ASrc, ADst);
  WipeDir(ASrc);
  Result := DirectoryExists(ADst);
end;

procedure EnsureDstDir(const ADst: string);
var D: string;
begin
  D := ExtractFileDir(ADst);
  if D <> '' then ForceDirectories(D);
end;

procedure AtomicWriteText(const ADst: string;
  const ATmpRoot: string; const AContent: TStringList);
var Tmp: string;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write-' + ExtractFileName(ADst));
  EnsureDstDir(ADst);
  AContent.SaveToFile(Tmp);
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

procedure AtomicWriteBytes(const ADst, ATmpRoot: string; const ABytes: TBytes);
var Tmp: string; Stream: TFileStream;
begin
  Tmp := MakeTmpPath(ATmpRoot, 'write-' + ExtractFileName(ADst));
  EnsureDstDir(ADst);
  Stream := TFileStream.Create(Tmp, fmCreate);
  try
    if Length(ABytes) > 0 then Stream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    Stream.Free;
  end;
  if not AtomicMoveFile(Tmp, ADst) then
  begin
    DeleteFile(Tmp);
    raise EExtractError.CreateFmt(
      'atomic write of "%s" failed (could not commit tmp file)', [ADst]);
  end;
end;

{ Sha256 of a TBytes for the [resolved].archiveHash field. The same hex
  shape as HashTree ('sha256:<hex>') so callers can compare directly. }
function SHA256BytesPrefixed(const ABytes: TBytes): string;
begin
  Result := 'sha256:' + SHA256Hex(ABytes);
end;

type
  TSHA256Digest = array[0..31] of Byte;

{ SHA-256 performs intentional modular arithmetic on 32-bit values
  (Cardinals): the compression loop's `temp1 := h + s1 + ch + K[t] + W[t]`
  and `W[t] := W[t-16] + s0 + W[t-7] + s1` deliberately wrap on
  overflow — that's how the algorithm produces correct hashes. FPC's
  range check ({$R+}) detects the intermediate Int64-promoted sums
  exceeding Cardinal's range and raises EangeError. Disable range
  checking inside this function so the modular arithmetic runs as
  written. The unit tests (NIST vectors) don't catch this because
  the test compiler doesn't pass -Cr; lwpt's dev build does, and the
  network-source archive-hash path was the first call site to hit
  it after the matching ADR. }
{$PUSH}{$R-}{$Q-}
function SHA256Bytes(const AData: TBytes): TSHA256Digest;
const
  K: array[0..63] of Cardinal = (
    $428a2f98,$71374491,$b5c0fbcf,$e9b5dba5,$3956c25b,$59f111f1,$923f82a4,$ab1c5ed5,
    $d807aa98,$12835b01,$243185be,$550c7dc3,$72be5d74,$80deb1fe,$9bdc06a7,$c19bf174,
    $e49b69c1,$efbe4786,$0fc19dc6,$240ca1cc,$2de92c6f,$4a7484aa,$5cb0a9dc,$76f988da,
    $983e5152,$a831c66d,$b00327c8,$bf597fc7,$c6e00bf3,$d5a79147,$06ca6351,$14292967,
    $27b70a85,$2e1b2138,$4d2c6dfc,$53380d13,$650a7354,$766a0abb,$81c2c92e,$92722c85,
    $a2bfe8a1,$a81a664b,$c24b8b70,$c76c51a3,$d192e819,$d6990624,$f40e3585,$106aa070,
    $19a4c116,$1e376c08,$2748774c,$34b0bcb5,$391c0cb3,$4ed8aa4a,$5b9cca4f,$682e6ff3,
    $748f82ee,$78a5636f,$84c87814,$8cc70208,$90befffa,$a4506ceb,$bef9a3f7,$c67178f2);
var
  HV: array[0..7] of Cardinal;
  W: array[0..63] of Cardinal;
  Msg: TBytes;
  BitLen: QWord;
  i, t, ChunkStart: Integer;
  a,b,c,d,e,f,g,h, s0,s1, ch, maj, temp1, temp2: Cardinal;

  function RotR(x: Cardinal; n: Byte): Cardinal; inline;
  begin
    Result := (x shr n) or (x shl (32 - n));
  end;

begin
  HV[0]:=$6a09e667; HV[1]:=$bb67ae85; HV[2]:=$3c6ef372; HV[3]:=$a54ff53a;
  HV[4]:=$510e527f; HV[5]:=$9b05688c; HV[6]:=$1f83d9ab; HV[7]:=$5be0cd19;

  BitLen := QWord(Length(AData)) * 8;
  { pad: 0x80, then zeros, then 64-bit big-endian length }
  Msg := Copy(AData, 0, Length(AData));
  SetLength(Msg, Length(Msg) + 1);
  Msg[High(Msg)] := $80;
  while (Length(Msg) mod 64) <> 56 do
    SetLength(Msg, Length(Msg) + 1);
  SetLength(Msg, Length(Msg) + 8);
  for i := 0 to 7 do
    Msg[Length(Msg) - 1 - i] := Byte((BitLen shr (8 * i)) and $FF);

  ChunkStart := 0;
  while ChunkStart < Length(Msg) do
  begin
    for t := 0 to 15 do
      W[t] := (Cardinal(Msg[ChunkStart + t*4    ]) shl 24) or
              (Cardinal(Msg[ChunkStart + t*4 + 1]) shl 16) or
              (Cardinal(Msg[ChunkStart + t*4 + 2]) shl 8) or
              (Cardinal(Msg[ChunkStart + t*4 + 3]));
    for t := 16 to 63 do
    begin
      s0 := RotR(W[t-15],7) xor RotR(W[t-15],18) xor (W[t-15] shr 3);
      s1 := RotR(W[t-2],17) xor RotR(W[t-2],19) xor (W[t-2] shr 10);
      W[t] := W[t-16] + s0 + W[t-7] + s1;
    end;

    a:=HV[0]; b:=HV[1]; c:=HV[2]; d:=HV[3];
    e:=HV[4]; f:=HV[5]; g:=HV[6]; h:=HV[7];

    for t := 0 to 63 do
    begin
      s1   := RotR(e,6) xor RotR(e,11) xor RotR(e,25);
      ch   := (e and f) xor ((not e) and g);
      temp1:= h + s1 + ch + K[t] + W[t];
      s0   := RotR(a,2) xor RotR(a,13) xor RotR(a,22);
      maj  := (a and b) xor (a and c) xor (b and c);
      temp2:= s0 + maj;
      h:=g; g:=f; f:=e; e:=d + temp1;
      d:=c; c:=b; b:=a; a:=temp1 + temp2;
    end;

    Inc(HV[0],a); Inc(HV[1],b); Inc(HV[2],c); Inc(HV[3],d);
    Inc(HV[4],e); Inc(HV[5],f); Inc(HV[6],g); Inc(HV[7],h);
    Inc(ChunkStart, 64);
  end;

  for i := 0 to 7 do
  begin
    Result[i*4    ] := Byte((HV[i] shr 24) and $FF);
    Result[i*4 + 1] := Byte((HV[i] shr 16) and $FF);
    Result[i*4 + 2] := Byte((HV[i] shr 8) and $FF);
    Result[i*4 + 3] := Byte( HV[i]         and $FF);
  end;
end;
{$POP}

function SHA256Hex(const AData: TBytes): string;
var D: TSHA256Digest; i: Integer;
begin
  D := SHA256Bytes(AData);
  Result := '';
  for i := 0 to 31 do
    Result := Result + LowerCase(IntToHex(D[i], 2));
end;

function SHA256File(const APath: string): string;
var FS: TFileStream; Buf: TBytes;
begin
  if not FileExists(APath) then Exit('');
  FS := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Buf, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Buf[0], FS.Size);
  finally
    FS.Free;
  end;
  Result := SHA256Hex(Buf);
end;

{ Hash of an installed package: SHA-256 over every extracted file's bytes,
  visited in sorted relative-path order so the digest is stable regardless
  of filesystem enumeration order or which mirror served the archive.
  This is the value that goes in lwpt.lock's computedHash. }
procedure CollectFiles(const ARoot, ARel: string; AList: TStringList);
var SR: TSearchRec; Path, RelPath: string;
begin
  Path := IncludeTrailingPathDelimiter(ARoot + ARel);
  if FindFirst(Path + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      RelPath := ARel + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectFiles(ARoot, RelPath + PathDelim, AList)
      else
        AList.Add(RelPath);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
end;

function HashTree(const APathOrArchive: string): string;
var
  Files : TStringList;
  Acc   : TBytes;
  i, n  : Integer;
  Chunk : TBytes;
  FS    : TFileStream;
  FullPath : string;
begin
  { directory: hash the sorted file tree }
  if DirectoryExists(APathOrArchive) then
  begin
    Files := TStringList.Create;
    try
      CollectFiles(IncludeTrailingPathDelimiter(APathOrArchive), '', Files);
      Files.Sort;
      SetLength(Acc, 0);
      for i := 0 to Files.Count - 1 do
      begin
        { fold the relative path in too, so renames change the hash }
        Chunk := BytesOf(Files[i] + #10);
        n := Length(Acc);
        SetLength(Acc, n + Length(Chunk));
        if Length(Chunk) > 0 then Move(Chunk[0], Acc[n], Length(Chunk));

        FullPath := IncludeTrailingPathDelimiter(APathOrArchive) + Files[i];
        FS := TFileStream.Create(FullPath, fmOpenRead or fmShareDenyNone);
        try
          n := Length(Acc);
          SetLength(Acc, n + FS.Size);
          if FS.Size > 0 then FS.ReadBuffer(Acc[n], FS.Size);
        finally
          FS.Free;
        end;
      end;
      Result := 'sha256:' + SHA256Hex(Acc);
    finally
      Files.Free;
    end;
  end
  { file (e.g. the archive itself): hash its bytes }
  else if FileExists(APathOrArchive) then
    Result := 'sha256:' + SHA256File(APathOrArchive)
  else
    Result := 'sha256:' + SHA256Hex(BytesOf(APathOrArchive));
end;

end.
