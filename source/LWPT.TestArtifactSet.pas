{ LWPT.TestArtifactSet — deterministic bundles for complete, immutable test
  compiler artifact sets. }
unit LWPT.TestArtifactSet;

{$I Shared.inc}
{$J-}

interface

uses
  LWPT.BuildRequest;

const
  TEST_ARTIFACT_SET_KIND = 'test-executable-set';

procedure WriteTestArtifactSet(const ABuildRoot, ADestination: string;
  const AArtifacts: TLWPTArtifactArray);
function MaterializeTestArtifactSet(const ABundlePath, ABuildRoot: string;
  out AArtifacts: TLWPTArtifactArray; out AReason: string): Boolean;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.BuildCache,
  LWPT.Core;

const
  ARTIFACT_SET_MAGIC = 'lwpt-test-artifact-set-v1'#10;
  ARTIFACT_SET_MAX_COUNT = 1024;
  ARTIFACT_SET_MAX_TEXT_BYTES = 64 * 1024;
  COPY_BUFFER_SIZE = 64 * 1024;

type
  TLWPTBundledArtifact = record
    Kind: string;
    RelativePath: string;
    SourceIdentity: string;
    SourcePath: string;
    UnixMode: Integer;
  end;
  TLWPTBundledArtifactArray = array of TLWPTBundledArtifact;

function PathWithinBuildRoot(const APath, ARoot: string): Boolean;
var
  Candidate, Root: string;
begin
  Candidate := ExpandFileName(APath);
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ARoot));
  Result := (Length(Candidate) > Length(Root))
    and SameFileName(Copy(Candidate, 1, Length(Root)), Root);
end;

function PathEntry(const APath: string; out AIsLink: Boolean): Boolean;
var
  Search: TSearchRec;
begin
  Result := FindFirst(APath, faAnyFile or faSymLink, Search) = 0;
  if not Result then
  begin
    AIsLink := False;
    Exit;
  end;
  try
    AIsLink := (Search.Attr and faSymLink) <> 0;
  finally
    FindClose(Search);
  end;
end;

function PathHasLinkedComponent(const ARoot, APath: string): Boolean;
var
  Components: TStringList;
  Current, Relative: string;
  IsLink: Boolean;
  i: Integer;
begin
  Result := False;
  Relative := ExtractRelativePath(IncludeTrailingPathDelimiter(
    ExpandFileName(ARoot)), ExpandFileName(APath));
  Relative := StringReplace(Relative, '\', '/', [rfReplaceAll]);
  Components := TStringList.Create;
  try
    Components.StrictDelimiter := True;
    Components.Delimiter := '/';
    Components.QuoteChar := #0;
    Components.DelimitedText := Relative;
    Current := ExpandFileName(ARoot);
    for i := 0 to Components.Count - 1 do
    begin
      if (Components[i] = '') or (Components[i] = '.') then Continue;
      Current := IncludeTrailingPathDelimiter(Current) + Components[i];
      if PathEntry(Current, IsLink) and IsLink then Exit(True);
    end;
  finally
    Components.Free;
  end;
end;

function PhysicalFileIdentity(const APath: string): string;
{$IFDEF UNIX}
var
  Info: BaseUnix.Stat;
begin
  Result := '';
  if FpStat(APath, Info) <> 0 then Exit;
  Result := IntToStr(Int64(Info.st_dev)) + ':' + IntToStr(Int64(Info.st_ino));
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
var
  Handle: THandle;
  Info: TByHandleFileInformation;
begin
  Result := '';
  Handle := CreateFileW(PWideChar(UnicodeString(APath)), 0,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if Handle = INVALID_HANDLE_VALUE then Exit;
  try
    if GetFileInformationByHandle(Handle, Info) then
      Result := IntToHex(Info.dwVolumeSerialNumber, 8) + ':'
        + IntToHex(Info.nFileIndexHigh, 8) + ':'
        + IntToHex(Info.nFileIndexLow, 8);
  finally
    CloseHandle(Handle);
  end;
end;
{$ENDIF}

procedure WriteUInt64(AStream: TStream; const AValue: QWord);
var
  Bytes: array[0..7] of Byte;
  i: Integer;
begin
  for i := 0 to 7 do Bytes[i] := Byte(AValue shr (i * 8));
  AStream.WriteBuffer(Bytes[0], SizeOf(Bytes));
end;

function ReadUInt64(AStream: TStream; out AValue: QWord): Boolean;
var
  Bytes: array[0..7] of Byte;
  i: Integer;
begin
  Result := AStream.Read(Bytes[0], SizeOf(Bytes)) = SizeOf(Bytes);
  if not Result then Exit;
  AValue := 0;
  for i := 0 to 7 do AValue := AValue or (QWord(Bytes[i]) shl (i * 8));
end;

procedure WriteString(AStream: TStream; const AValue: string);
var
  Raw: RawByteString;
begin
  Raw := RawByteString(AValue);
  WriteUInt64(AStream, Length(Raw));
  if Length(Raw) > 0 then AStream.WriteBuffer(Raw[1], Length(Raw));
end;

function ReadString(AStream: TStream; out AValue: string): Boolean;
var
  LengthValue: QWord;
  Raw: RawByteString;
begin
  Result := False;
  AValue := '';
  if not ReadUInt64(AStream, LengthValue)
     or (LengthValue > ARTIFACT_SET_MAX_TEXT_BYTES)
     or (LengthValue > QWord(AStream.Size - AStream.Position)) then Exit;
  SetLength(Raw, LengthValue);
  if (LengthValue > 0)
     and (AStream.Read(Raw[1], LengthValue) <> Int64(LengthValue)) then Exit;
  AValue := string(Raw);
  Result := True;
end;

function PortableRelativePath(const ARoot, APath: string): string;
begin
  if not PathWithinBuildRoot(APath, ARoot) then
    raise ELWPTError.CreateFmt(
      'test artifact is outside its private compilation root: %s', [APath]);
  if PathHasLinkedComponent(ARoot, APath) then
    raise ELWPTError.CreateFmt(
      'test artifact traverses a link inside its private compilation root: %s',
      [APath]);
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(
    ExpandFileName(ARoot)), ExpandFileName(APath));
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  if (Result = '') or (Result = '.') or (Copy(Result, 1, 3) = '../')
     or (Pos('/../', '/' + Result + '/') > 0) then
    raise ELWPTError.CreateFmt('invalid relative test artifact path: %s',
      [Result]);
end;

function SafeDestination(const ARoot, ARelativePath: string;
  out ADestination: string): Boolean;
var
  NativePath: string;
begin
  Result := False;
  ADestination := '';
  if (ARelativePath = '') or (ARelativePath[1] = '/')
     or (Pos('\', ARelativePath) > 0)
     or (Copy(ARelativePath, 1, 3) = '../')
     or (Pos('/../', '/' + ARelativePath + '/') > 0) then Exit;
  NativePath := StringReplace(ARelativePath, '/', PathDelim,
    [rfReplaceAll]);
  ADestination := ExpandFileName(IncludeTrailingPathDelimiter(ARoot)
    + NativePath);
  Result := PathWithinBuildRoot(ADestination, ARoot);
end;

procedure SortArtifacts(var AArtifacts: TLWPTBundledArtifactArray);
var
  i, j: Integer;
  Temporary: TLWPTBundledArtifact;
begin
  for i := 0 to High(AArtifacts) - 1 do
    for j := i + 1 to High(AArtifacts) do
      if AArtifacts[j].RelativePath < AArtifacts[i].RelativePath then
      begin
        Temporary := AArtifacts[i];
        AArtifacts[i] := AArtifacts[j];
        AArtifacts[j] := Temporary;
      end;
end;

procedure CopyBytes(const ASource, ADestination: TStream;
  const ACount: QWord);
var
  Buffer: array[0..COPY_BUFFER_SIZE - 1] of Byte;
  Remaining: QWord;
  Chunk: LongInt;
begin
  Remaining := ACount;
  while Remaining > 0 do
  begin
    if Remaining > SizeOf(Buffer) then Chunk := SizeOf(Buffer)
    else Chunk := LongInt(Remaining);
    if ASource.Read(Buffer[0], Chunk) <> Chunk then
      raise ELWPTError.Create('truncated test artifact set');
    ADestination.WriteBuffer(Buffer[0], Chunk);
    Dec(Remaining, Chunk);
  end;
end;

function ApplyArtifactUnixMode(const APath: string;
  const AMode: Integer): Boolean;
begin
  {$IFDEF UNIX}
  Exit(FpChmod(APath, AMode) = 0);
  {$ENDIF}
  Result := True;
end;

procedure WriteTestArtifactSet(const ABuildRoot, ADestination: string;
  const AArtifacts: TLWPTArtifactArray);
var
  Artifacts: TLWPTBundledArtifactArray;
  Bundle, Source: TFileStream;
  i, j: Integer;
  Magic: RawByteString;
begin
  if (Length(AArtifacts) = 0)
     or (Length(AArtifacts) > ARTIFACT_SET_MAX_COUNT) then
    raise ELWPTError.Create('test artifact set has an invalid size');
  SetLength(Artifacts, Length(AArtifacts));
  for i := 0 to High(AArtifacts) do
  begin
    if not FileExists(AArtifacts[i].Path) then
      raise ELWPTError.CreateFmt('test artifact does not exist: %s',
        [AArtifacts[i].Path]);
    Artifacts[i].Kind := AArtifacts[i].Kind;
    Artifacts[i].RelativePath := PortableRelativePath(ABuildRoot,
      AArtifacts[i].Path);
    Artifacts[i].SourceIdentity := PhysicalFileIdentity(AArtifacts[i].Path);
    if Artifacts[i].SourceIdentity = '' then
      raise ELWPTError.CreateFmt('cannot identify test artifact: %s',
        [AArtifacts[i].Path]);
    Artifacts[i].SourcePath := AArtifacts[i].Path;
    Artifacts[i].UnixMode := BuildArtifactUnixMode(AArtifacts[i].Path);
  end;
  SortArtifacts(Artifacts);
  for i := 0 to High(Artifacts) do
    for j := 0 to i - 1 do
      if (Artifacts[j].RelativePath = Artifacts[i].RelativePath)
         or (Artifacts[j].SourceIdentity = Artifacts[i].SourceIdentity) then
        raise ELWPTError.CreateFmt('duplicate test artifact path: %s',
          [Artifacts[i].RelativePath]);

  ForceDirectories(ExtractFileDir(ADestination));
  Bundle := TFileStream.Create(ADestination, fmCreate);
  try
    Magic := RawByteString(ARTIFACT_SET_MAGIC);
    Bundle.WriteBuffer(Magic[1], Length(Magic));
    WriteUInt64(Bundle, Length(Artifacts));
    for i := 0 to High(Artifacts) do
    begin
      WriteString(Bundle, Artifacts[i].RelativePath);
      WriteString(Bundle, Artifacts[i].Kind);
      WriteUInt64(Bundle, Artifacts[i].UnixMode);
      Source := TFileStream.Create(Artifacts[i].SourcePath,
        fmOpenRead or fmShareDenyNone);
      try
        WriteUInt64(Bundle, Source.Size);
        CopyBytes(Source, Bundle, Source.Size);
      finally
        Source.Free;
      end;
    end;
  finally
    Bundle.Free;
  end;
end;

function MaterializeTestArtifactSet(const ABundlePath, ABuildRoot: string;
  out AArtifacts: TLWPTArtifactArray; out AReason: string): Boolean;
var
  Bundle, Destination: TFileStream;
  Count, ContentLength, Mode: QWord;
  CreatedPaths: TStringList;
  DestinationPath, Kind, Magic, RelativePath: string;
  RawMagic: RawByteString;
  DestinationIsLink: Boolean;
  i: Integer;
begin
  Result := False;
  AReason := 'artifact-set-invalid';
  SetLength(AArtifacts, 0);
  CreatedPaths := TStringList.Create;
  {$IFDEF MSWINDOWS}
  CreatedPaths.CaseSensitive := False;
  {$ELSE}
  CreatedPaths.CaseSensitive := True;
  {$ENDIF}
  Bundle := nil;
  try
    try
      Bundle := TFileStream.Create(ABundlePath, fmOpenRead or fmShareDenyNone);
      SetLength(RawMagic, Length(ARTIFACT_SET_MAGIC));
      if Bundle.Read(RawMagic[1], Length(RawMagic)) <> Length(RawMagic) then
      begin
        AReason := 'artifact-set-invalid: truncated-magic';
        Exit;
      end;
      Magic := string(RawMagic);
      if Magic <> ARTIFACT_SET_MAGIC then
      begin
        AReason := 'artifact-set-invalid: magic';
        Exit;
      end;
      if not ReadUInt64(Bundle, Count) then
      begin
        AReason := 'artifact-set-invalid: truncated-count';
        Exit;
      end;
      if (Count = 0) or (Count > ARTIFACT_SET_MAX_COUNT) then
      begin
        AReason := 'artifact-set-invalid: count';
        Exit;
      end;
      SetLength(AArtifacts, Count);
      for i := 0 to Count - 1 do
      begin
        if not ReadString(Bundle, RelativePath) then
        begin
          AReason := 'artifact-set-invalid: relative-path';
          Exit;
        end;
        if not ReadString(Bundle, Kind) or (Kind = '') then
        begin
          AReason := 'artifact-set-invalid: kind';
          Exit;
        end;
        if not ReadUInt64(Bundle, Mode) or (Mode > $1FF) then
        begin
          AReason := 'artifact-set-invalid: mode';
          Exit;
        end;
        if not ReadUInt64(Bundle, ContentLength)
           or (ContentLength > QWord(Bundle.Size - Bundle.Position)) then
        begin
          AReason := 'artifact-set-invalid: content-length';
          Exit;
        end;
        if not SafeDestination(ABuildRoot, RelativePath, DestinationPath) then
        begin
          AReason := 'artifact-set-invalid: destination-path';
          Exit;
        end;
        if PathHasLinkedComponent(ABuildRoot,
          ExtractFileDir(DestinationPath)) then
        begin
          AReason := 'artifact-set-invalid: destination-parent-link';
          Exit;
        end;
        if PathEntry(DestinationPath, DestinationIsLink) then
        begin
          AReason := 'artifact-set-invalid: destination-exists';
          Exit;
        end;
        if CreatedPaths.IndexOf(DestinationPath) >= 0 then
        begin
          AReason := 'artifact-set-invalid: duplicate-destination';
          Exit;
        end;
        CreatedPaths.Add(DestinationPath);
        ForceDirectories(ExtractFileDir(DestinationPath));
        Destination := TFileStream.Create(DestinationPath, fmCreate);
        try
          CopyBytes(Bundle, Destination, ContentLength);
        finally
          Destination.Free;
        end;
        if not ApplyArtifactUnixMode(DestinationPath, Mode) then
        begin
          AReason := 'artifact-set-invalid: destination-mode';
          Exit;
        end;
        AArtifacts[i].Kind := Kind;
        AArtifacts[i].Path := DestinationPath;
        AArtifacts[i].Digest := 'sha256:' + SHA256File(DestinationPath);
      end;
      if Bundle.Position <> Bundle.Size then
      begin
        AReason := 'artifact-set-invalid: trailing-bytes';
        Exit;
      end;
      AReason := 'hit';
      Result := True;
    except
      on E: Exception do
        AReason := 'artifact-set-invalid: exception-' + E.ClassName;
    end;
  finally
    Bundle.Free;
    if not Result then
    begin
      for i := 0 to CreatedPaths.Count - 1 do
        SysUtils.DeleteFile(CreatedPaths[i]);
      SetLength(AArtifacts, 0);
    end;
    CreatedPaths.Free;
  end;
end;

end.
