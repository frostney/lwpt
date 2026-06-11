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
  teardown. }
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
var SR: TSearchRec; Base: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  if FindFirst(Base + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          RecursiveDelete(Base + SR.Name)
        else
          DeleteFile(Base + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  RemoveDir(APath);
end;

end.
