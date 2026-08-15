# LWPT installer — Windows.
#
# Usage:
#   irm https://raw.githubusercontent.com/frostney/lwpt/main/scripts/install.ps1 | iex
#
# Honors the following environment variables:
#   $env:LWPT_INSTALL_DIR  where to drop lwpt.exe
#                          (default: $env:USERPROFILE\bin)
#   $env:LWPT_VERSION      tag to install        (default: latest release)
#   $env:LWPT_REPO         GitHub owner/repo     (default: frostney/lwpt)
#
# The release ships a zip per arch (matches release.yml's packaging
# step). This script downloads + extracts it under a temp dir, then
# moves lwpt.exe into the install dir and adds the dir to the user
# PATH if not already there.
#
# Asset naming:
#   lwpt-<version>-windows-{x64,x86}.zip
#
# Mirrors the shape of GocciaScript's installer at
#   https://gocciascript.dev/install.ps1
# adapted for LWPT's single-binary distribution.

$ErrorActionPreference = "Stop"

$Repo = if ($env:LWPT_REPO) { $env:LWPT_REPO } else { "frostney/lwpt" }
$InstallDir = if ($env:LWPT_INSTALL_DIR) { $env:LWPT_INSTALL_DIR } else { "$env:USERPROFILE\bin" }

# --- detect arch -----------------------------------------------------
$Arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

# --- resolve version -------------------------------------------------
if ($env:LWPT_VERSION) {
  $Tag = $env:LWPT_VERSION
} else {
  $Latest = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing
  $Tag = $Latest.tag_name
  if (-not $Tag) {
    throw "install.ps1: could not resolve latest release for $Repo"
  }
}
$Version = $Tag -replace '^v', ''

$Asset = "lwpt-$Version-windows-$Arch.zip"
$Url = "https://github.com/$Repo/releases/download/$Tag/$Asset"
$SumsUrl = "https://github.com/$Repo/releases/download/$Tag/lwpt-$Version-checksums.txt"

# --- download + verify + extract ------------------------------------
$TempDir = Join-Path $env:TEMP "lwpt-install-$([guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
  Write-Host "Downloading $Asset"
  $ZipPath = Join-Path $TempDir $Asset
  Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing

  $SumsPath = Join-Path $TempDir "checksums.txt"
  Invoke-WebRequest -Uri $SumsUrl -OutFile $SumsPath -UseBasicParsing -ErrorAction Stop

  Write-Host "Verifying checksum"
  $line = Get-Content $SumsPath | Where-Object { $_ -match " $([regex]::Escape($Asset))$" } | Select-Object -First 1
  if (-not $line) {
    throw "install.ps1: checksums file has no entry for $Asset"
  }
  $expected = ($line -split '\s+')[0].ToLower()
  $actual = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
  if ($expected -ne $actual) {
    throw "install.ps1: checksum mismatch — expected $expected, got $actual"
  }

  Expand-Archive -Path $ZipPath -DestinationPath $TempDir -Force

  # Archive contains a single top-level dir named after the archive base.
  $PkgDir = Join-Path $TempDir ($Asset -replace '\.zip$', '')
  if (-not (Test-Path $PkgDir)) {
    throw "install.ps1: extracted archive is missing expected dir $PkgDir"
  }
  $SrcExe = Join-Path $PkgDir "lwpt.exe"
  if (-not (Test-Path $SrcExe)) {
    throw "install.ps1: lwpt.exe not found in archive"
  }

  # --- install -------------------------------------------------------
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $DestExe = Join-Path $InstallDir "lwpt.exe"
  Move-Item -Force $SrcExe $DestExe

  # --- ensure InstallDir is on user PATH -----------------------------
  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $UserPath) { $UserPath = "" }
  $alreadyOnPath = ($UserPath -split ';') -contains $InstallDir
  if (-not $alreadyOnPath) {
    $newPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "Added $InstallDir to user PATH (open a new shell to pick it up)."
  }

  Write-Host ""
  Write-Host "lwpt $Version installed to $InstallDir"
} finally {
  Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
