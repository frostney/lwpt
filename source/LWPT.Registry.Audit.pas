{ LWPT.Registry.Audit -- immutable per-request audit records (ADR-0049).

  Every mutating request on an origin writes one file. Records carry only
  validated route metadata: a route template and parameters that already
  passed their grammar, never the raw request target, a header, a body, a
  secret, or a secret hash. }
unit LWPT.Registry.Audit;

{$I Shared.inc}
{$J-}

interface

uses
  SysUtils,

  LWPT.Core;

const
  REGISTRY_AUDIT_DIRECTORY = 'audit';
  REGISTRY_AUDIT_STAGING_DIRECTORY = 'audit/.staging';
  REGISTRY_AUDIT_INVALID_ROUTE = 'invalid';

type
  TLWPTRegistryAuditRecord = record
    RequestID, ReceivedAt, CompletedAt, Peer, Method, Route: string;
    Name, Version, ArchiveHash, RecordHash: string;
    TokenID, Action: string;
    Status: Integer;
    Code: string;
    Sequence: QWord;
    CheckpointHash: string;
    AuthFailure: string;
  end;

function RegistryAuditDocument(const ARecord: TLWPTRegistryAuditRecord): string;
{ Writes the record atomically below ARoot and returns its relative path. }
function WriteRegistryAuditRecord(const ARoot: string;
  const ARecord: TLWPTRegistryAuditRecord): string;
{ Methods outside this set are recorded as "invalid". }
function RegistryAuditMethod(const AMethod: string): string;

implementation

uses
  LWPT.Registry.Store;

function RegistryAuditMethod(const AMethod: string): string;
begin
  if (AMethod = 'GET') or (AMethod = 'HEAD') or (AMethod = 'PUT')
    or (AMethod = 'POST') or (AMethod = 'DELETE') or (AMethod = 'PATCH')
    or (AMethod = 'OPTIONS') or (AMethod = 'TRACE') or (AMethod = 'CONNECT') then
    Result := AMethod
  else Result := REGISTRY_AUDIT_INVALID_ROUTE;
end;

function RegistryAuditDocument(const ARecord: TLWPTRegistryAuditRecord): string;
begin
  Result := 'schema = ' + RegistryTOMLQuote(PROGRAM_NAME + '-registry-audit-v1')
    + #10 + 'request_id = ' + RegistryTOMLQuote(ARecord.RequestID) + #10
    + 'received_at = ' + RegistryTOMLQuote(ARecord.ReceivedAt) + #10
    + 'completed_at = ' + RegistryTOMLQuote(ARecord.CompletedAt) + #10
    + 'peer = ' + RegistryTOMLQuote(ARecord.Peer) + #10
    + 'method = ' + RegistryTOMLQuote(ARecord.Method) + #10
    + 'route = ' + RegistryTOMLQuote(ARecord.Route) + #10
    + 'name = ' + RegistryTOMLQuote(ARecord.Name) + #10
    + 'version = ' + RegistryTOMLQuote(ARecord.Version) + #10
    + 'archive = ' + RegistryTOMLQuote(ARecord.ArchiveHash) + #10
    + 'record = ' + RegistryTOMLQuote(ARecord.RecordHash) + #10
    + 'token_id = ' + RegistryTOMLQuote(ARecord.TokenID) + #10
    + 'action = ' + RegistryTOMLQuote(ARecord.Action) + #10
    + 'status = ' + IntToStr(ARecord.Status) + #10
    + 'code = ' + RegistryTOMLQuote(ARecord.Code) + #10
    + 'sequence = ' + UIntToStr(ARecord.Sequence) + #10
    + 'checkpoint = ' + RegistryTOMLQuote(ARecord.CheckpointHash) + #10
    + 'auth_failure = ' + RegistryTOMLQuote(ARecord.AuthFailure) + #10;
end;

function CompactTimestamp(const AValue: string): string;
var
  Character: Char;
begin
  Result := '';
  for Character in AValue do
    if Character in ['0'..'9', 'T', 'Z'] then Result := Result + Character;
end;

function WriteRegistryAuditRecord(const ARoot: string;
  const ARecord: TLWPTRegistryAuditRecord): string;
var
  Root, Destination: string;
begin
  if (Length(ARecord.ReceivedAt) < 10) or (ARecord.RequestID = '') then
    raise ELWPTRegistryError.CreateStable('audit_write_failed',
      'audit record is missing its request identity');
  Result := REGISTRY_AUDIT_DIRECTORY + '/' + Copy(ARecord.ReceivedAt, 1, 4)
    + '/' + Copy(ARecord.ReceivedAt, 6, 2) + '/'
    + Copy(ARecord.ReceivedAt, 9, 2) + '/'
    + CompactTimestamp(ARecord.ReceivedAt) + '-' + ARecord.RequestID + '.toml';
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ARoot));
  Destination := Root + StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
  if FileExists(Destination) then
    raise ELWPTRegistryError.CreateStable('audit_write_failed',
      'audit record already exists');
  AtomicWriteBytes(Destination, Root + StringReplace(
    REGISTRY_AUDIT_STAGING_DIRECTORY, '/', PathDelim, [rfReplaceAll]),
    BytesOf(RegistryAuditDocument(ARecord)));
end;

end.
