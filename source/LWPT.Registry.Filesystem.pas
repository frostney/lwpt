{ LWPT.Registry.Filesystem - retained no-follow registry file access. }
unit LWPT.Registry.Filesystem;

{$I Shared.inc}
{$J-}

interface

uses
  Classes,
  SysUtils;

type
  ELWPTRegistryFileOpenError = class(Exception);

function OpenRegistryFileWithoutFollowingLinks(const APath: string): TStream;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows;
  {$ENDIF}

const
  {$IFDEF UNIX}
  {$IFDEF LINUX}
  AT_SYMLINK_NOFOLLOW_LWPT = $00000100;
  { Linux AArch64 overrides the asm-generic directory and no-follow bits. }
  {$IFDEF CPUAARCH64}
  O_DIRECTORY_LWPT = $00004000;
  O_NOFOLLOW_LWPT = $00008000;
  {$ELSE}
  O_DIRECTORY_LWPT = $00010000;
  O_NOFOLLOW_LWPT = $00020000;
  {$ENDIF}
  O_NONBLOCK_LWPT = $00000800;
  {$ELSE}
  {$IFDEF DARWIN}
  AT_SYMLINK_NOFOLLOW_LWPT = $00000020;
  O_DIRECTORY_LWPT = $00100000;
  O_NOFOLLOW_LWPT = $00000100;
  O_NONBLOCK_LWPT = $00000004;
  {$ELSE}
  AT_SYMLINK_NOFOLLOW_LWPT = AT_SYMLINK_NOFOLLOW;
  O_DIRECTORY_LWPT = O_DIRECTORY;
  O_NOFOLLOW_LWPT = O_NOFOLLOW;
  O_NONBLOCK_LWPT = O_NONBLOCK;
  {$ENDIF}
  {$ENDIF}
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  FILE_FLAG_BACKUP_SEMANTICS_LWPT = $02000000;
  FILE_FLAG_OPEN_REPARSE_POINT_LWPT = $00200000;
  FILE_READ_ATTRIBUTES_LWPT = $00000080;
  {$ENDIF}

type
  {$IFDEF MSWINDOWS}
  TRegistryHandleArray = array of THandle;
  {$ENDIF}

  TOwnedHandleStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

{$IFDEF UNIX}
function RegistryOpenAt(ADirectoryDescriptor: cint; APath: PChar;
  AFlags: cint): cint; cdecl; external 'c' name 'openat';
function RegistryFileStatusAt(ADirectoryDescriptor: cint; APath: PChar;
  var AFileStatus: BaseUnix.Stat; AFlags: cint): cint; cdecl;
  external 'c' name 'fstatat';
{$ENDIF}

destructor TOwnedHandleStream.Destroy;
begin
  {$IFDEF UNIX}
  FpClose(Handle);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Windows.CloseHandle(Handle);
  {$ENDIF}
  inherited Destroy;
end;

{$IFDEF UNIX}
function OpenRegistryFileWithoutFollowingLinks(const APath: string): TStream;
var
  Component: string;
  CurrentDescriptor, NextDescriptor, OpenFlags: cint;
  IsFinal, OpenedComponent: Boolean;
  LinkInfo, OpenInfo: BaseUnix.Stat;
  Position, Start: Integer;
begin
  if (APath = '') or (APath[1] <> '/') then
    raise ELWPTRegistryFileOpenError.Create(
      'registry file path must be absolute');
  CurrentDescriptor := FpOpen(PChar('/'), O_RDONLY or O_DIRECTORY_LWPT
    or O_NONBLOCK_LWPT);
  if CurrentDescriptor < 0 then
    raise ELWPTRegistryFileOpenError.Create(
      'registry filesystem root could not be opened safely');
  try
    Position := 1;
    OpenedComponent := False;
    while Position <= Length(APath) do
    begin
      while (Position <= Length(APath)) and (APath[Position] = '/') do
        Inc(Position);
      if Position > Length(APath) then Break;
      Start := Position;
      while (Position <= Length(APath)) and (APath[Position] <> '/') do
        Inc(Position);
      Component := Copy(APath, Start, Position - Start);
      if (Component = '.') or (Component = '..') then
        raise ELWPTRegistryFileOpenError.Create(
          'registry file path is not canonical');
      while (Position <= Length(APath)) and (APath[Position] = '/') do
        Inc(Position);
      IsFinal := Position > Length(APath);
      if RegistryFileStatusAt(CurrentDescriptor, PChar(Component), LinkInfo,
        AT_SYMLINK_NOFOLLOW_LWPT) <> 0 then
        raise ELWPTRegistryFileOpenError.Create(
          'registry file component could not be inspected safely');
      if (LinkInfo.st_mode and S_IFMT) = S_IFLNK then
        raise ELWPTRegistryFileOpenError.Create(
          'registry file path contains a link');
      if IsFinal then
      begin
        if (LinkInfo.st_mode and S_IFMT) <> S_IFREG then
          raise ELWPTRegistryFileOpenError.Create(
            'registry file is not a regular file');
        OpenFlags := O_RDONLY or O_NOFOLLOW_LWPT or O_NONBLOCK_LWPT;
      end
      else
      begin
        if (LinkInfo.st_mode and S_IFMT) <> S_IFDIR then
          raise ELWPTRegistryFileOpenError.Create(
            'registry file parent is not a directory');
        OpenFlags := O_RDONLY or O_NOFOLLOW_LWPT or O_NONBLOCK_LWPT
          or O_DIRECTORY_LWPT;
      end;
      NextDescriptor := RegistryOpenAt(CurrentDescriptor, PChar(Component),
        OpenFlags);
      if NextDescriptor < 0 then
        raise ELWPTRegistryFileOpenError.Create(
          'registry file component changed while opening');
      if (FpFStat(NextDescriptor, OpenInfo) <> 0)
        or (OpenInfo.st_dev <> LinkInfo.st_dev)
        or (OpenInfo.st_ino <> LinkInfo.st_ino)
        or ((OpenInfo.st_mode and S_IFMT)
        <> (LinkInfo.st_mode and S_IFMT)) then
      begin
        FpClose(NextDescriptor);
        raise ELWPTRegistryFileOpenError.Create(
          'registry file component changed while opening');
      end;
      FpClose(CurrentDescriptor);
      CurrentDescriptor := NextDescriptor;
      OpenedComponent := True;
    end;
    if not OpenedComponent or ((OpenInfo.st_mode and S_IFMT) <> S_IFREG) then
      raise ELWPTRegistryFileOpenError.Create(
        'registry file is not a regular file');
    try
      Result := TOwnedHandleStream.Create(CurrentDescriptor);
    except
      FpClose(CurrentDescriptor);
      CurrentDescriptor := -1;
      raise;
    end;
    CurrentDescriptor := -1;
  finally
    if CurrentDescriptor >= 0 then FpClose(CurrentDescriptor);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure CloseRegistryHandles(var AHandles: TRegistryHandleArray);
var
  Index: Integer;
begin
  for Index := High(AHandles) downto 0 do
    if AHandles[Index] <> THandle(Windows.INVALID_HANDLE_VALUE) then
      Windows.CloseHandle(AHandles[Index]);
  SetLength(AHandles, 0);
end;

function RegistryWindowsRootLength(const APath: UnicodeString): Integer;
var
  Position: Integer;
begin
  if (Length(APath) >= 3) and (APath[2] = ':') and (APath[3] = '\') then
    Exit(3);
  if (Length(APath) < 5) or (Copy(APath, 1, 2) <> '\\') then Exit(0);
  Position := 3;
  while (Position <= Length(APath)) and (APath[Position] <> '\') do
    Inc(Position);
  if Position > Length(APath) then Exit(0);
  Inc(Position);
  while (Position <= Length(APath)) and (APath[Position] <> '\') do
    Inc(Position);
  if Position > Length(APath) then Result := Length(APath)
  else Result := Position;
end;

function OpenRegistryFileWithoutFollowingLinks(const APath: string): TStream;
var
  ComponentEnd, ComponentStart: Integer;
  ExpectedPath, ParentPath: UnicodeString;
  FileInfo: TByHandleFileInformation;
  Handle, ParentHandle: THandle;
  ParentHandles: TRegistryHandleArray;
  RootLength: Integer;
begin
  ExpectedPath := UnicodeString(ExpandFileName(APath));
  ExpectedPath := StringReplace(ExpectedPath, '/', '\', [rfReplaceAll]);
  RootLength := RegistryWindowsRootLength(ExpectedPath);
  if RootLength = 0 then
    raise ELWPTRegistryFileOpenError.Create(
      'registry file path must be absolute');
  SetLength(ParentHandles, 0);
  Handle := THandle(Windows.INVALID_HANDLE_VALUE);
  try
    ComponentStart := RootLength + 1;
    while ComponentStart <= Length(ExpectedPath) do
    begin
      ComponentEnd := ComponentStart;
      while (ComponentEnd <= Length(ExpectedPath))
        and (ExpectedPath[ComponentEnd] <> '\') do Inc(ComponentEnd);
      if ComponentEnd > Length(ExpectedPath) then Break;
      ParentPath := Copy(ExpectedPath, 1, ComponentEnd - 1);
      ParentHandle := Windows.CreateFileW(PWideChar(ParentPath),
        FILE_READ_ATTRIBUTES_LWPT, Windows.FILE_SHARE_READ, nil,
        Windows.OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS_LWPT
          or FILE_FLAG_OPEN_REPARSE_POINT_LWPT, 0);
      if ParentHandle = THandle(Windows.INVALID_HANDLE_VALUE) then
        raise ELWPTRegistryFileOpenError.Create(
          'registry file parent could not be opened safely');
      if not Windows.GetFileInformationByHandle(ParentHandle, FileInfo)
        or ((FileInfo.dwFileAttributes
        and Windows.FILE_ATTRIBUTE_DIRECTORY) = 0)
        or ((FileInfo.dwFileAttributes
        and Windows.FILE_ATTRIBUTE_REPARSE_POINT) <> 0) then
      begin
        Windows.CloseHandle(ParentHandle);
        raise ELWPTRegistryFileOpenError.Create(
          'registry file parent is not a regular directory');
      end;
      SetLength(ParentHandles, Length(ParentHandles) + 1);
      ParentHandles[High(ParentHandles)] := ParentHandle;
      ComponentStart := ComponentEnd + 1;
    end;
    Handle := Windows.CreateFileW(PWideChar(ExpectedPath),
      Windows.GENERIC_READ, Windows.FILE_SHARE_READ or Windows.FILE_SHARE_WRITE
        or Windows.FILE_SHARE_DELETE, nil, Windows.OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT_LWPT, 0);
    if Handle = THandle(Windows.INVALID_HANDLE_VALUE) then
      raise ELWPTRegistryFileOpenError.Create(
        'registry file could not be opened safely');
    if not Windows.GetFileInformationByHandle(Handle, FileInfo)
      or ((FileInfo.dwFileAttributes
      and Windows.FILE_ATTRIBUTE_REPARSE_POINT) <> 0)
      or ((FileInfo.dwFileAttributes
      and Windows.FILE_ATTRIBUTE_DIRECTORY) <> 0) then
      raise ELWPTRegistryFileOpenError.Create(
        'registry file is not a regular non-reparse file');
    Result := TOwnedHandleStream.Create(Handle);
    Handle := THandle(Windows.INVALID_HANDLE_VALUE);
  finally
    if Handle <> THandle(Windows.INVALID_HANDLE_VALUE) then
      Windows.CloseHandle(Handle);
    CloseRegistryHandles(ParentHandles);
  end;
end;
{$ENDIF}

end.
