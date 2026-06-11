{ Tests.Scratch — scratch-directory file helpers shared by the
  integration and E2E test programs.

  Every per-test scratch project needs the same two primitives: write
  a small text file (creating parent dirs) and wipe a directory tree.
  These used to be copy-pasted into each test program; this unit is
  their single home, next to Tests.LwptSubprocess (the support dir is
  already on every test's compile path via LWPT.Command.Testing).

  RecursiveDelete is symlink-aware: a symlink is unlinked, never
  followed, so a link planted inside a scratch tree (e.g. by the
  build --clean symlink regression test) cannot make the wipe escape
  the tree or recurse forever. Windows directory symlinks/junctions
  are not handled (DeleteFile cannot remove them) — no test creates
  them there. }

unit Tests.Scratch;

{$mode delphi}{$H+}

interface

procedure WriteTextFile(const APath, AContent: string);
procedure RecursiveDelete(const APath: string);

implementation

uses
  Classes,
  SysUtils;

procedure WriteTextFile(const APath, AContent: string);
var
  SL: TStringList;
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
var
  SR: TSearchRec;
  Base: string;
begin
  if not DirectoryExists(APath) then Exit;
  Base := IncludeTrailingPathDelimiter(APath);
  { faSymLink in the mask makes FindFirst report links as links; a
    symlink-to-dir then carries faSymLink and is unlinked instead of
    recursed into. }
  if FindFirst(Base + '*', faAnyFile or faSymLink, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if ((SR.Attr and faDirectory) <> 0)
           and ((SR.Attr and faSymLink) = 0) then
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
