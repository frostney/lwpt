{ LWPT.TestArtifactSet.Test — deterministic complete test-artifact bundles. }
program LWPT.TestArtifactSet.Test;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  Classes,
  SysUtils,

  LWPT.BuildRequest,
  LWPT.Core,
  LWPT.TestArtifactSet,
  TestingPascalLibrary,
  Tests.Scratch;

type
  TTestArtifactSetContract = class(TTestSuite)
  private
    FScratch: string;
    procedure WriteBytes(const APath, AText: string);
    function ReadBytes(const APath: string): string;
  protected
    procedure BeforeAll; override;
    procedure AfterAll; override;
  public
    procedure SetupTests; override;
    procedure TestRoundTripPreservesCompleteSet;
    procedure TestMalformedBundleIsRejectedWithoutOutput;
    procedure TestSourceOutsidePrivateRootIsRejected;
    procedure TestLinkedSourceInsidePrivateRootIsRejected;
    procedure TestExistingDestinationIsRejected;
    procedure TestPhysicalSourceAliasIsRejected;
  end;

procedure TTestArtifactSetContract.WriteBytes(const APath, AText: string);
var
  Stream: TFileStream;
  Raw: RawByteString;
begin
  ForceDirectories(ExtractFileDir(APath));
  Raw := RawByteString(AText);
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(Raw) > 0 then Stream.WriteBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
end;

function TTestArtifactSetContract.ReadBytes(const APath: string): string;
var
  Stream: TFileStream;
  Raw: RawByteString;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Raw, Stream.Size);
    if Length(Raw) > 0 then Stream.ReadBuffer(Raw[1], Length(Raw));
  finally
    Stream.Free;
  end;
  Result := string(Raw);
end;

procedure TTestArtifactSetContract.BeforeAll;
begin
  FScratch := CreateScratchRoot('test-artifact-set');
end;

procedure TTestArtifactSetContract.AfterAll;
begin
  if DirectoryExists(FScratch) then WipeDir(FScratch);
end;

procedure TTestArtifactSetContract.TestRoundTripPreservesCompleteSet;
var
  Bundle, DestinationRoot, SourceRoot: string;
  Cached, Source: TLWPTArtifactArray;
  Reason: string;
begin
  SourceRoot := FScratch + '/roundtrip/source';
  DestinationRoot := FScratch + '/roundtrip/destination';
  Bundle := FScratch + '/roundtrip/artifacts.bundle';
  WriteBytes(SourceRoot + '/bin/program', 'executable'#0'bytes');
  WriteBytes(SourceRoot + '/resources/runtime.dat', 'runtime data');
  SetLength(Source, 2);
  Source[0].Kind := 'runtime-resource';
  Source[0].Path := SourceRoot + '/resources/runtime.dat';
  Source[1].Kind := BUILD_OUTPUT_EXECUTABLE;
  Source[1].Path := SourceRoot + '/bin/program';

  WriteTestArtifactSet(SourceRoot, Bundle, Source);
  Expect<Boolean>(MaterializeTestArtifactSet(Bundle, DestinationRoot,
    Cached, Reason)).ToBe(True);
  Expect<string>(Reason).ToBe('hit');
  Expect<Integer>(Length(Cached)).ToBe(2);
  Expect<string>(Cached[0].Kind).ToBe(BUILD_OUTPUT_EXECUTABLE);
  Expect<string>(ReadBytes(Cached[0].Path)).ToBe('executable'#0'bytes');
  Expect<string>(Cached[1].Kind).ToBe('runtime-resource');
  Expect<string>(ReadBytes(Cached[1].Path)).ToBe('runtime data');
end;

procedure TTestArtifactSetContract.TestMalformedBundleIsRejectedWithoutOutput;
var
  Artifacts, Cached: TLWPTArtifactArray;
  Bundle, DestinationRoot, Reason, SourceRoot: string;
  Stream: TFileStream;
begin
  Bundle := FScratch + '/malformed/artifacts.bundle';
  DestinationRoot := FScratch + '/malformed/destination';
  SourceRoot := FScratch + '/malformed/source';
  WriteBytes(SourceRoot + '/first', 'complete first artifact');
  WriteBytes(SourceRoot + '/second', 'truncated second artifact');
  SetLength(Artifacts, 2);
  Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  Artifacts[0].Path := SourceRoot + '/first';
  Artifacts[1].Kind := 'runtime-resource';
  Artifacts[1].Path := SourceRoot + '/second';
  WriteTestArtifactSet(SourceRoot, Bundle, Artifacts);
  Stream := TFileStream.Create(Bundle, fmOpenWrite);
  try
    Stream.Size := Stream.Size - 1;
  finally
    Stream.Free;
  end;
  Expect<Boolean>(MaterializeTestArtifactSet(Bundle, DestinationRoot,
    Cached, Reason)).ToBe(False);
  Expect<string>(Reason).ToBe('artifact-set-invalid');
  Expect<Integer>(Length(Cached)).ToBe(0);
  Expect<Boolean>(FileExists(DestinationRoot + '/first')).ToBe(False);
  Expect<Boolean>(FileExists(DestinationRoot + '/second')).ToBe(False);
end;

procedure TTestArtifactSetContract.TestSourceOutsidePrivateRootIsRejected;
var
  Artifacts: TLWPTArtifactArray;
  Raised: Boolean;
begin
  WriteBytes(FScratch + '/outside/program', 'outside');
  SetLength(Artifacts, 1);
  Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  Artifacts[0].Path := FScratch + '/outside/program';
  Raised := False;
  try
    WriteTestArtifactSet(FScratch + '/private', FScratch + '/bundle',
      Artifacts);
  except
    on E: ELWPTError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
end;

procedure TTestArtifactSetContract.TestLinkedSourceInsidePrivateRootIsRejected;
var
  Artifacts: TLWPTArtifactArray;
  Raised: Boolean;
begin
  {$IFDEF UNIX}
  WriteBytes(FScratch + '/linked/outside', 'outside');
  ForceDirectories(FScratch + '/linked/private');
  if FpSymlink(PAnsiChar(FScratch + '/linked/outside'),
    PAnsiChar(FScratch + '/linked/private/program')) <> 0 then
    raise Exception.Create('fixture: artifact symlink creation failed');
  SetLength(Artifacts, 1);
  Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  Artifacts[0].Path := FScratch + '/linked/private/program';
  Raised := False;
  try
    WriteTestArtifactSet(FScratch + '/linked/private',
      FScratch + '/linked/bundle', Artifacts);
  except
    on E: ELWPTError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TTestArtifactSetContract.TestExistingDestinationIsRejected;
var
  Artifacts, Cached: TLWPTArtifactArray;
  Bundle, DestinationRoot, Reason, SourceRoot: string;
begin
  SourceRoot := FScratch + '/collision/source';
  DestinationRoot := FScratch + '/collision/destination';
  Bundle := FScratch + '/collision/artifacts.bundle';
  WriteBytes(SourceRoot + '/bin/program', 'cached executable');
  SetLength(Artifacts, 1);
  Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  Artifacts[0].Path := SourceRoot + '/bin/program';
  WriteTestArtifactSet(SourceRoot, Bundle, Artifacts);
  WriteBytes(DestinationRoot + '/bin/program', 'pre-existing bytes');

  Expect<Boolean>(MaterializeTestArtifactSet(Bundle, DestinationRoot,
    Cached, Reason)).ToBe(False);
  Expect<string>(Reason).ToBe('artifact-set-invalid');
  Expect<string>(ReadBytes(DestinationRoot + '/bin/program')).ToBe(
    'pre-existing bytes');
  Expect<Integer>(Length(Cached)).ToBe(0);
end;

procedure TTestArtifactSetContract.TestPhysicalSourceAliasIsRejected;
var
  Artifacts: TLWPTArtifactArray;
  Raised: Boolean;
begin
  {$IFDEF UNIX}
  WriteBytes(FScratch + '/physical-alias/private/program', 'program');
  if FpLink(PAnsiChar(FScratch + '/physical-alias/private/program'),
    PAnsiChar(FScratch + '/physical-alias/private/program-alias')) <> 0 then
    raise Exception.Create('fixture: artifact hard-link creation failed');
  SetLength(Artifacts, 2);
  Artifacts[0].Kind := BUILD_OUTPUT_EXECUTABLE;
  Artifacts[0].Path := FScratch + '/physical-alias/private/program';
  Artifacts[1].Kind := 'runtime-resource';
  Artifacts[1].Path := FScratch + '/physical-alias/private/program-alias';
  Raised := False;
  try
    WriteTestArtifactSet(FScratch + '/physical-alias/private',
      FScratch + '/physical-alias/bundle', Artifacts);
  except
    on E: ELWPTError do Raised := True;
  end;
  Expect<Boolean>(Raised).ToBe(True);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TTestArtifactSetContract.SetupTests;
begin
  Test('round trip preserves the complete artifact set',
    TestRoundTripPreservesCompleteSet);
  Test('malformed bundles are rejected without output',
    TestMalformedBundleIsRejectedWithoutOutput);
  Test('artifacts outside the private root are rejected',
    TestSourceOutsidePrivateRootIsRejected);
  Test('linked artifacts inside the private root are rejected',
    TestLinkedSourceInsidePrivateRootIsRejected);
  Test('existing destination aliases are rejected',
    TestExistingDestinationIsRejected);
  Test('physical source aliases are rejected',
    TestPhysicalSourceAliasIsRejected);
end;

begin
  TestRunnerProgram.AddSuite(
    TTestArtifactSetContract.Create('test artifact set'));
  TestRunnerProgram.Run;
end.
