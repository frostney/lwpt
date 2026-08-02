{ CLI.Prompts — interactive input helpers shared by CLI subcommands.

  Two primitives, no state, no DI: ReadPromptLine for free-form text
  with an optional default, and PromptYesNo for boolean confirmations
  with a default direction. Both print to stdout, drain stdin
  synchronously, and trim. Callers that want non-interactive
  behaviour (CI, `--yes`) gate the call site, not the helpers — these
  always prompt.

  Lives under the CLI namespace (no LWPT prefix) so it can graduate
  into a standalone package alongside CLI.Options / CLI.Parser once
  the LWPT bootstrap arc lets us replace vendoring with a managed dep
  (see ADR-0006). }
unit CLI.Prompts;

{$I Shared.inc}

interface

uses
  SysUtils;

{ Print APrompt followed by " (ADefault)" (when ADefault is non-empty)
  and ": ", then read a line. Returns the trimmed input, or ADefault
  if the user just pressed enter. ADefault may be '' to allow empty
  responses through unchanged. }
function ReadPromptLine(const APrompt, ADefault: string): string;

{ Print APrompt + " [Y/n]" / " [y/N]" depending on ADefault, read a
  line. Empty / whitespace-only response returns ADefault; 'y' or
  'yes' (case-insensitive) returns True, anything else returns
  False. Helpful for the install/build chain after lwpt init. }
function PromptYesNo(const APrompt: string; ADefault: Boolean): Boolean;

implementation

function ReadPromptLine(const APrompt, ADefault: string): string;
var Line: string;
begin
  Write(APrompt);
  if ADefault <> '' then Write(' (', ADefault, ')');
  Write(': ');
  Flush(Output);
  ReadLn(Line);
  Line := Trim(Line);
  if Line = '' then Result := ADefault else Result := Line;
end;

function PromptYesNo(const APrompt: string; ADefault: Boolean): Boolean;
var Line: string;
begin
  if ADefault then Line := 'Y/n' else Line := 'y/N';
  Write(APrompt, ' [', Line, ']: ');
  Flush(Output);
  ReadLn(Line);
  Line := LowerCase(Trim(Line));
  if Line = '' then Exit(ADefault);
  Result := (Line = 'y') or (Line = 'yes');
end;

end.
