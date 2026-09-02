{ Tests.PayloadHandoff — read-ownership transfer for a payload file one
  process writes and another process reads.

  Windows publishes a path before the writer's handle is released. The
  reader's FileExists therefore succeeds while the writer still owns the
  file, and the reader's open fails with "The process cannot access the file
  because it is being used by another process". Issues #205 and #262 hit
  this on the worker coordinator's markers; PR #289's Windows CI run hit it
  on this repository's scheduling PID payloads.

  The fix is ordering, not waiting longer. A writer writes the payload,
  waits for that write to return, and only then creates an existence-only
  <path>.complete marker. A reader polls for the marker and opens the
  payload only after the marker appears. The reader never opens the marker
  itself — existence is the marker's whole content — so the marker cannot in
  turn collide with the writer's handle. Per issue #262, keep the marker
  existence-only, and do not paper over a missing one with a sleep or a
  wider timeout.

  Generated fixture programs are built as Pascal source text and cannot use
  this unit, so EmitPayloadCompletion renders the same handover for them and
  keeps the suffix single-sourced. }

unit Tests.PayloadHandoff;

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  PayloadCompleteSuffix = '.complete';

type
  EPayloadNotPublished = class(Exception);

procedure PublishReadablePayload(const APath, AContent: string);
procedure PublishPayloadCompletion(const APath: string);
procedure RetractPayload(const APath: string);
function PayloadIsReadable(const APath: string): Boolean;
function ReadPayloadText(const APath: string): string;
function EmitPayloadCompletion(const ATextVariable,
  APayloadPathLiteral: string): string;

implementation

uses
  Tests.Scratch;

function PayloadIsReadable(const APath: string): Boolean;
begin
  Result := FileExists(APath + PayloadCompleteSuffix) and FileExists(APath);
end;

procedure PublishPayloadCompletion(const APath: string);
begin
  WriteTextFile(APath + PayloadCompleteSuffix, '');
end;

procedure PublishReadablePayload(const APath, AContent: string);
begin
  WriteTextFile(APath, AContent);
  PublishPayloadCompletion(APath);
end;

procedure RetractPayload(const APath: string);
begin
  { The marker goes first: a payload without its marker reads as unpublished,
    while a marker without its payload would claim ownership of nothing. }
  DeleteFile(APath + PayloadCompleteSuffix);
  DeleteFile(APath);
end;

function ReadPayloadText(const APath: string): string;
begin
  if not FileExists(APath + PayloadCompleteSuffix) then
    raise EPayloadNotPublished.CreateFmt(
      'payload "%s" has no %s marker: its writer has not transferred read '
      + 'ownership', [APath, PayloadCompleteSuffix]);
  if not FileExists(APath) then
    raise EPayloadNotPublished.CreateFmt(
      'payload "%s" is marked complete but is absent', [APath]);
  Result := ReadBinaryFile(APath);
end;

function EmitPayloadCompletion(const ATextVariable,
  APayloadPathLiteral: string): string;
begin
  Result :=
      '  Assign(' + ATextVariable + ', ' + APayloadPathLiteral + ' + '''
    + PayloadCompleteSuffix + ''');'#10
    + '  Rewrite(' + ATextVariable + ');'#10
    + '  Close(' + ATextVariable + ');'#10;
end;

end.
