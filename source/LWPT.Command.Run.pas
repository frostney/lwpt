{ LWPT.Command.Run — run subcommand entrypoint. }
unit LWPT.Command.Run;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdRun(const AManifestPath, AName: string): Integer;

implementation

uses
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest;

{
  CmdRun — invoke a user-declared run-script (ADR-0013).

  AName is the section name (the manifest key for the script). When
  AName is empty, prints a list of every callable name (subcommands
  first, then user scripts). When AName matches no script and no
  subcommand, exits 1 with a hint listing both sets.

  Subcommand-aliasing (`lwpt run install` → `lwpt install`) is handled
  upstream in the CLI dispatcher (CLI.Subcommands.Run) — CmdRun is
  only reached for genuine user scripts. }

function CmdRun(const AManifestPath, AName: string): Integer;
var
  Man : TManifest;
  i   : Integer;
  Found : THook;
  Hit : Boolean;
begin
  Man := LoadManifest(AManifestPath);

  { Empty name → list mode (npm-run convention). }
  if AName = '' then
  begin
    WriteLn('available scripts:');
    if Length(Man.Scripts) = 0 then
      WriteLn('  (none — declare a top-level section with a `script` field)')
    else
      for i := 0 to High(Man.Scripts) do
        WriteLn('  ', Man.Scripts[i].Name, '  ',
                Man.Scripts[i].Script);
    WriteLn;
    WriteLn('subcommand aliases (also valid via `', PROGRAM_NAME, ' run <name>`):');
    WriteLn('  install  build  format  test  repair  init');
    Exit(0);
  end;

  { Look up by name. Scripts are root-only and already validated
    against subcommand-name collisions at manifest load. }
  Hit := False;
  for i := 0 to High(Man.Scripts) do
    if Man.Scripts[i].Name = AName then
    begin
      Found := Man.Scripts[i];
      Hit := True;
      Break;
    end;

  if not Hit then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: no script named "',
      AName, '"');
    if Length(Man.Scripts) > 0 then
    begin
      Write(ErrOutput, '  available scripts: ');
      for i := 0 to High(Man.Scripts) do
      begin
        if i > 0 then Write(ErrOutput, ', ');
        Write(ErrOutput, Man.Scripts[i].Name);
      end;
      WriteLn(ErrOutput);
    end
    else
      WriteLn(ErrOutput, '  (no scripts declared in ', AManifestPath, ')');
    Exit(1);
  end;

  { Execute the script directly and propagate its exit code (npm-run
    convention). Differs from lifecycle hooks (which raise on non-zero
    to abort the phase): a user-invoked script's exit code is the
    *answer* the user is asking for, so any propagation other than
    "what the script returned" loses information. }
  Result := RunUserScript(Found);
end;

end.
