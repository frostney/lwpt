{ LWPT.Archive.Test — the archive-contract primitives shared by the
  installer's extraction preflight and the publication archive layer
  (ADR-0049): traversal tests, the lexical link-target containment check,
  strict UTF-8 names, the installer's tar header readers, the stable error
  shape, and the fixed bounds. }
program LWPT.Archive.Test;

{$I Shared.inc}

uses
  SysUtils,

  LWPT.Archive,
  TestingPascalLibrary;

type
  TArchiveSuite = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestDefaultLimitsMatchTheADR;
    procedure TestAbsolutePaths;
    procedure TestParentSegments;
    procedure TestLinkTargetContainment;
    procedure TestStrictUTF8Names;
    procedure TestInstallerTarHeaderReaders;
    procedure TestStableErrorShape;
  end;

procedure TArchiveSuite.TestDefaultLimitsMatchTheADR;
var
  Limits: TLWPTArchiveLimits;
begin
  Limits := DefaultArchiveLimits;
  Expect<Int64>(Limits.MaximumInputBytes).ToBe(268435456);
  Expect<Integer>(Limits.MaximumZipEntries).ToBe(10000);
  Expect<Int64>(Limits.MaximumExpandedBytes).ToBe(1073741824);
  Expect<Int64>(Limits.MaximumOutputBytes).ToBe(268435456);
  Expect<Integer>(ARCHIVE_NAME_COMPONENT_LIMIT).ToBe(255);
end;

procedure TArchiveSuite.TestAbsolutePaths;
begin
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('/etc/passwd')).ToBe(True);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('\windows')).ToBe(True);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('C:/x')).ToBe(True);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('z:x')).ToBe(True);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('a/b')).ToBe(False);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('1:x')).ToBe(False);
  Expect<Boolean>(LooksLikeAbsoluteArchivePath('')).ToBe(False);
end;

procedure TArchiveSuite.TestParentSegments;
begin
  Expect<Boolean>(ArchiveRelPathHasParentSegment('..')).ToBe(True);
  Expect<Boolean>(ArchiveRelPathHasParentSegment('a/../b')).ToBe(True);
  Expect<Boolean>(ArchiveRelPathHasParentSegment('a\..\b')).ToBe(True);
  Expect<Boolean>(ArchiveRelPathHasParentSegment('a/..')).ToBe(True);
  Expect<Boolean>(ArchiveRelPathHasParentSegment('a/..b/c..')).ToBe(False);
  Expect<Boolean>(ArchiveRelPathHasParentSegment('a/./b')).ToBe(False);
end;

procedure TArchiveSuite.TestLinkTargetContainment;
begin
  { Resolved against the link's own directory, as the installer does. }
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', 'b')).ToBe(False);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', '../b')).ToBe(False);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/b/link', '../../c'))
    .ToBe(False);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('link', 'a/./b')).ToBe(False);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('link', '../x')).ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', '../../x'))
    .ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', 'b/../../../x'))
    .ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', '..\..\x'))
    .ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', '/etc/passwd'))
    .ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', 'C:\x')).ToBe(True);
  { The extraction root itself is outside the root, as the installer's
    containment test holds. }
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('a/link', '..')).ToBe(True);
  Expect<Boolean>(ArchiveLinkTargetEscapesRoot('link', '.')).ToBe(True);
end;

procedure TArchiveSuite.TestStrictUTF8Names;
begin
  Expect<Boolean>(IsStrictUTF8WithoutControls('plain/name.txt')).ToBe(True);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$C3#$BC'ber')).ToBe(True);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$E2#$82#$AC)).ToBe(True);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$F0#$9F#$98#$80)).ToBe(True);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$F4#$8F#$BF#$BF)).ToBe(True);
  { Overlong '/', a surrogate, past U+10FFFF, truncated, a stray
    continuation byte, and Latin-1. }
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$C0#$AF)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$E0#$80#$AF)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$ED#$A0#$80)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$F4#$90#$80#$80)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls('a'#$E2#$82)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$80'a')).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$FC'ber')).ToBe(False);
  { C0, DEL, and C1 controls. }
  Expect<Boolean>(IsStrictUTF8WithoutControls('a'#0'b')).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls('a'#10)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls('a'#$7F)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$C2#$85)).ToBe(False);
  Expect<Boolean>(IsStrictUTF8WithoutControls(#$C2#$A0)).ToBe(True);
end;

procedure TArchiveSuite.TestInstallerTarHeaderReaders;
var
  Block: array[0..31] of Byte;
begin
  Expect<string>(StripFirstComponent('top/a/b')).ToBe('a/b');
  Expect<string>(StripFirstComponent('top\a\b')).ToBe('a/b');
  Expect<string>(StripFirstComponent('top/')).ToBe('');
  Expect<string>(StripFirstComponent('top')).ToBe('');
  FillChar(Block, SizeOf(Block), 0);
  Move(PAnsiChar('  0755 '#0)^, Block[0], 8);
  Expect<Int64>(TarOctal(Block, 0, 8)).ToBe(493);
  Move(PAnsiChar('00000000017'#0)^, Block[8], 12);
  Expect<Int64>(TarOctal(Block, 8, 12)).ToBe(15);
  Move(PAnsiChar('name'#0'junk')^, Block[20], 9);
  Expect<string>(TarStr(Block, 20, 9)).ToBe('name');
end;

procedure TArchiveSuite.TestStableErrorShape;
var
  Code, Message: string;
begin
  Code := '';
  try
    raise ELWPTArchiveError.CreateStableFmt(ARCHIVE_LIMIT_EXCEEDED,
      'input is %d bytes', [7]);
  except
    on E: ELWPTArchiveError do
    begin
      Code := E.Code;
      Message := E.Message;
    end;
  end;
  Expect<string>(Code).ToBe('archive_limit_exceeded');
  Expect<string>(Message).ToBe('archive_limit_exceeded: input is 7 bytes');
  Expect<string>(ARCHIVE_UNSUPPORTED).ToBe('unsupported_archive');
  Expect<string>(ARCHIVE_UNSUPPORTED_DEPENDENCIES)
    .ToBe('unsupported_dependencies');
end;

procedure TArchiveSuite.SetupTests;
begin
  Test('default limits match the ADR bounds',
    TestDefaultLimitsMatchTheADR);
  Test('absolute and drive-letter paths', TestAbsolutePaths);
  Test('parent-directory components', TestParentSegments);
  Test('link targets resolve inside the root lexically',
    TestLinkTargetContainment);
  Test('entry names must be strict UTF-8 without controls',
    TestStrictUTF8Names);
  Test('the installer''s tar header readers are shared',
    TestInstallerTarHeaderReaders);
  Test('refusals carry a stable code', TestStableErrorShape);
end;

begin
  TestRunnerProgram.AddSuite(TArchiveSuite.Create('LWPT.Archive'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
