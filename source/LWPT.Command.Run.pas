{ LWPT.Command.Run — run subcommand entrypoint. }
unit LWPT.Command.Run;

{$I Shared.inc}
{$J-}
{$modeswitch nestedcomments+}

interface

function CmdRun(const AManifestPath, AName: string;
  const AAliasNames: array of string): Integer;

implementation

uses
  SysUtils,

  LWPT.Command.Common,
  LWPT.Core,
  LWPT.Manifest;

{
  CmdRun — invoke a user-declared run task (ADR-0013).

  AName is the section name (the manifest key for the task). When
  AName is empty, prints a list of every callable name (user tasks,
  then subcommand aliases). AAliasNames carries the alias set the
  dispatcher actually accepts — the caller derives it from the live
  subcommand registry so this listing can never drift from dispatch.
  When AName matches no task and no subcommand, exits 1 with a hint
  listing the declared tasks.

  Subcommand-aliasing (`lwpt run install` → `lwpt install`) is handled
  upstream in the CLI dispatcher (CLI.Subcommands.Run) — CmdRun is
  only reached for genuine user tasks. }

function CmdRun(const AManifestPath, AName: string;
  const AAliasNames: array of string): Integer;
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
    WriteLn('available tasks:');
    if Length(Man.RunTasks) = 0 then
      WriteLn('  (none — declare a top-level section with a `command` field)')
    else
      for i := 0 to High(Man.RunTasks) do
        WriteLn('  ', Man.RunTasks[i].Name, '  ',
                Man.RunTasks[i].Runnable.Command);
    WriteLn;
    WriteLn('subcommand aliases (also valid via `', PROGRAM_NAME, ' run <name>`):');
    Write('  ');
    for i := 0 to High(AAliasNames) do
    begin
      if i > 0 then Write('  ');
      Write(AAliasNames[i]);
    end;
    WriteLn;
    Exit(0);
  end;

  { Look up by name. Tasks are root-only and already validated
    against subcommand-name collisions at manifest load. }
  Hit := False;
  for i := 0 to High(Man.RunTasks) do
    if Man.RunTasks[i].Name = AName then
    begin
      Found := Man.RunTasks[i];
      Hit := True;
      Break;
    end;

  if not Hit then
  begin
    WriteLn(ErrOutput, PROGRAM_NAME, ' run: no task named "',
      AName, '"');
    if Length(Man.RunTasks) > 0 then
    begin
      Write(ErrOutput, '  available tasks: ');
      for i := 0 to High(Man.RunTasks) do
      begin
        if i > 0 then Write(ErrOutput, ', ');
        Write(ErrOutput, Man.RunTasks[i].Name);
      end;
      WriteLn(ErrOutput);
    end
    else
      WriteLn(ErrOutput, '  (no tasks declared in ', AManifestPath, ')');
    Exit(1);
  end;

  { Execute the task directly and propagate its exit code (npm-run
    convention). Differs from lifecycle hooks (which raise on non-zero
    to abort the phase): a user-invoked task's exit code is the
    *answer* the user is asking for, so any propagation other than
    "what the command returned" loses information. }
  Result := RunUserTask(Found,
    ExtractFileDir(ExpandFileName(AManifestPath)));
end;

end.
