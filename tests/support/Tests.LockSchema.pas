{ Tests.LockSchema — fixtures for the schema-v4 lockfile and its v3 upgrade
  (ADR-0052), shared by the integration programs that drive them.

  DowngradeLockToV3 turns a lock this binary wrote into the lock a pre-v4
  binary would have written for the same committed modules: `version = 3`
  and every computedHash replaced by the legacy digest of its module. It
  keeps the file's line endings. SubstituteModuleLayout applies the layout
  substitution from #352, which the legacy digest cannot see.
  ProjectSnapshot lists every file below a root with its SHA-256, so a
  refused command can be shown to change nothing. }

unit Tests.LockSchema;

{$mode delphi}{$H+}

interface

{ Rewrites AProject/lwpt.lock in place as schema v3 and returns the text. }
function DowngradeLockToV3(const AProject: string): string;
{ The value of AField in the [package.<AName>] entry of ALock, or ''. }
function LockEntryField(const ALock, AName, AField: string): string;
{ Empties AModule/AUnit and adds a root file named after the unit's first
  line, holding the rest: the legacy digest of the module is unchanged. }
procedure SubstituteModuleLayout(const AModule, AUnit: string);
{ Every file and directory below ARoot, one per line, with each file's
  SHA-256. Relative paths starting with an entry of AExcludes are left out. }
function ProjectSnapshot(const ARoot: string;
  const AExcludes: array of string): string;
{ Writes exact bytes, creating parent directories. }
procedure WriteExactFile(const APath, AContent: string);
{ Leaves a pending install transaction below AProject/.lwpt/tmp whose
  rollback file for module AName records the legacy `tree:sha256:` digest,
  as a pre-v4 binary interrupted after retaining the module would have. }
procedure PlantLegacyModuleRollback(const AProject, AName: string);
{ True while any *.rollback marker is left below ATmpRoot's transactions. }
function HasPendingRollback(const ATmpRoot: string): Boolean;

implementation

uses
  Classes,
  SysUtils,

  LWPT.Core;

procedure WriteExactFile(const APath, AContent: string);
var Stream: TFileStream;
begin
  ForceDirectories(ExtractFileDir(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(AContent) > 0 then Stream.WriteBuffer(AContent[1],
      Length(AContent));
  finally
    Stream.Free;
  end;
end;

function ReadExactFile(const APath: string): string;
var Stream: TFileStream;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[1], Length(Result));
  finally
    Stream.Free;
  end;
end;

function DowngradeLockToV3(const AProject: string): string;
var
  Text, Ending, Line, Current, Output: string;
  Lines: TStringList;
  i: Integer;
begin
  Text := ReadExactFile(AProject + '/lwpt.lock');
  if Pos(#13#10, Text) > 0 then Ending := #13#10 else Ending := #10;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    Current := '';
    Output := '';
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if Line = 'version = 4' then
        Line := 'version = 3'
      else if (Copy(Line, 1, 9) = '[package.') and (Line[Length(Line)] = ']') then
        Current := Copy(Line, 10, Length(Line) - 10)
      else if (Current <> '') and (Copy(Line, 1, 15) = 'computedHash = ') then
        Line := 'computedHash = "' + LegacyHashTree(AProject
          + '/.lwpt/modules/' + Current) + '"'
      else if Copy(Line, 1, 1) = '[' then
        Current := '';
      Output := Output + Line + Ending;
    end;
  finally
    Lines.Free;
  end;
  WriteExactFile(AProject + '/lwpt.lock', Output);
  Result := Output;
end;

function LockEntryField(const ALock, AName, AField: string): string;
var Rest: string; Start: Integer;
begin
  Result := '';
  Rest := StringReplace(ALock, #13#10, #10, [rfReplaceAll]);
  Start := Pos('[package.' + AName + ']'#10, Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start, MaxInt);
  Start := Pos(#10 + AField + ' = "', Rest);
  if Start = 0 then Exit;
  Rest := Copy(Rest, Start + Length(AField) + 5, MaxInt);
  Result := Copy(Rest, 1, Pos('"', Rest) - 1);
end;

procedure SubstituteModuleLayout(const AModule, AUnit: string);
var Original: string; Split: Integer;
begin
  Original := ReadExactFile(AModule + '/' + AUnit);
  Split := Pos(#10, Original);
  if Split <= 1 then
    raise Exception.Create('fixture: ' + AUnit + ' has no first line');
  WriteExactFile(AModule + '/' + AUnit, '');
  WriteExactFile(AModule + '/' + Copy(Original, 1, Split - 1),
    Copy(Original, Split + 1, MaxInt));
end;

procedure CollectSnapshot(const ARoot, ARel: string;
  const AExcludes: array of string; AList: TStringList);
var Search: TSearchRec; Rel: string; k: Integer; Excluded: Boolean;
begin
  if FindFirst(ARoot + '/' + ARel + '*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      Rel := ARel + Search.Name;
      Excluded := False;
      for k := 0 to High(AExcludes) do
        if Copy(Rel, 1, Length(AExcludes[k])) = AExcludes[k] then
          Excluded := True;
      if Excluded then Continue;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        AList.Add(Rel + '/');
        CollectSnapshot(ARoot, Rel + '/', AExcludes, AList);
      end
      else
        AList.Add(Rel + ' ' + SHA256File(ARoot + '/' + Rel));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function ProjectSnapshot(const ARoot: string;
  const AExcludes: array of string): string;
var List: TStringList;
begin
  List := TStringList.Create;
  try
    CollectSnapshot(ARoot, '', AExcludes, List);
    List.Sort;
    Result := List.Text;
  finally
    List.Free;
  end;
end;

procedure CopyFiles(const ASource, ATarget: string);
var Search: TSearchRec;
begin
  ForceDirectories(ATarget);
  if FindFirst(ASource + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) <> 0 then
        CopyFiles(ASource + '/' + Search.Name, ATarget + '/' + Search.Name)
      else
        WriteExactFile(ATarget + '/' + Search.Name,
          ReadExactFile(ASource + '/' + Search.Name));
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

procedure PlantLegacyModuleRollback(const AProject, AName: string);
var Transaction, Backup, Destination: string;
begin
  Transaction := AProject + '/.lwpt/tmp/install-transaction.legacy';
  Backup := Transaction + '/rollback-module-' + AName + '.legacy';
  Destination := ExpandFileName(AProject + '/.lwpt/modules/' + AName);
  WriteExactFile(Transaction + '/transaction.state', 'pending'#10);
  CopyFiles(AProject + '/.lwpt/modules/' + AName, Backup);
  WriteExactFile(Backup + '.rollback', Destination + #10 + 'tree:'
    + LegacyHashTree(Backup) + #10);
end;

function HasPendingRollback(const ATmpRoot: string): Boolean;
var Search, Marker: TSearchRec;
begin
  Result := False;
  if FindFirst(ATmpRoot + '/*', faAnyFile, Search) <> 0 then Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then Continue;
      if (Search.Attr and faDirectory) = 0 then Continue;
      if FindFirst(ATmpRoot + '/' + Search.Name + '/*.rollback', faAnyFile,
           Marker) = 0 then
      begin
        FindClose(Marker);
        Exit(True);
      end;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

end.
