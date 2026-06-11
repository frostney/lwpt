{ Tests.Fixtures — shared filesystem helpers for test scratch dirs.

  Consolidates the per-test private copies of WriteTestFile (née
  WriteFile) and RecursiveDelete that used to be duplicated across
  the integration and e2e suites. Tests build fixture projects under
  build/tests/tmp/<suite>/ and tear them down between runs; these two
  helpers are the whole vocabulary for that.

  Surface — kept minimal:

    procedure WriteTestFile(const APath, AContent: string);
    procedure RecursiveDelete(const APath: string);
}

unit Tests.Fixtures;

{$mode delphi}{$H+}

interface

{ Write AContent to APath, creating parent directories as needed.
  TStringList-backed: content is normalised to line-based text with a
  trailing newline — fine for manifests and Pascal sources, not for
  binary fixtures. }
procedure WriteTestFile(const APath, AContent: string);

{ Delete APath and everything under it. No-op when the directory does
  not exist, so it is safe as both setup (clear stale state) and
  teardown. Symlinks and Windows junctions are removed as nodes,
  never traversed — fixture trees can contain links into live package
  sources (the installer's monorepo link path). }
procedure RecursiveDelete(const APath: string);

implementation

uses
  Classes,
  SysUtils;

procedure WriteTestFile(const APath, AContent: string);
var SL: TStringList;
begin
  ForceDirectories(ExtractFileDir(APath));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(APath);
  finally
    SL.Free;
  end;
end;

procedure RecursiveDelete(const APath: string);
var SR: TSearchRec; Base, Full: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  { faSymLink in the filter makes FindFirst report links via lstat
    instead of their targets; the same $400 bit is
    FILE_ATTRIBUTE_REPARSE_POINT on Windows, so junctions carry it
    too. Without it, a dir symlink stats as a plain directory and the
    recursion would wipe the link TARGET. }
  if FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := Base + SR.Name;
        if (SR.Attr and faSymLink) <> 0 then
        begin
          { remove the link node itself; never descend }
          if (SR.Attr and faDirectory) <> 0 then
            RemoveDir(Full)      { Windows junction / dir reparse point }
          else
            DeleteFile(Full);    { Unix symlink (any target), file link }
        end
        else if (SR.Attr and faDirectory) <> 0 then
          RecursiveDelete(Full)
        else
          DeleteFile(Full);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

end.
