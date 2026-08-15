#!/usr/bin/env sh
# LWPT installer — macOS & Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/frostney/lwpt/main/scripts/install.sh | sh
#
# Honors the following environment variables:
#   INSTALL_DIR    where to drop the lwpt binary    (default: /usr/local/bin)
#   LWPT_VERSION   tag to install                    (default: latest release)
#   LWPT_REPO      GitHub owner/repo                 (default: frostney/lwpt)
#
# The release ships one tar.gz per OS/arch (zip on Windows). This
# script downloads the tar.gz for the host platform under a temp
# dir, extracts it, then moves the `lwpt` binary into INSTALL_DIR.
# Bundled docs (README.md, AGENTS.md, docs/*) are discarded — they
# live on github.com if you want them.
#
# Asset naming, mirroring .github/workflows/release.yml's package step:
#   lwpt-<version>-{macos,linux}-{arm64,x64}.tar.gz
#
# Mirrors the shape of GocciaScript's installer at
#   https://gocciascript.dev/install.sh
# adapted for LWPT's single-binary distribution.

set -e

REPO="${LWPT_REPO:-frostney/lwpt}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

err() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# --- detect OS -------------------------------------------------------
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) err "unsupported OS: $(uname -s) — try the Windows installer (install.ps1)" ;;
esac

# --- detect arch -----------------------------------------------------
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64"   ;;
  *) err "unsupported arch: $(uname -m)" ;;
esac

# --- resolve version -------------------------------------------------
if [ -n "${LWPT_VERSION:-}" ]; then
  TAG="$LWPT_VERSION"
else
  command -v curl >/dev/null 2>&1 || err "curl is required"
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -E '"tag_name":' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  [ -n "$TAG" ] || err "could not resolve latest release for ${REPO}"
fi
VERSION="${TAG#v}"

ASSET="lwpt-${VERSION}-${OS}-${ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
SUMS_URL="https://github.com/${REPO}/releases/download/${TAG}/lwpt-${VERSION}-checksums.txt"

# --- download + verify + extract ------------------------------------
TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t lwpt-install)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

printf 'Downloading %s\n' "$ASSET"
curl -fsSL -o "${TMPDIR}/${ASSET}" "$URL"

curl -fsSL -o "${TMPDIR}/checksums.txt" "$SUMS_URL" \
  || err "could not download checksums file at $SUMS_URL"

printf 'Verifying checksum\n'
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1; exit }' \
  "${TMPDIR}/checksums.txt")"
[ -n "$EXPECTED" ] || err "checksums file has no entry for $ASSET"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "${TMPDIR}/${ASSET}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "${TMPDIR}/${ASSET}" | awk '{print $1}')"
else
  err "neither sha256sum nor shasum is available"
fi

[ "$ACTUAL" = "$EXPECTED" ] \
  || err "checksum mismatch — expected $EXPECTED, got $ACTUAL"

cd "$TMPDIR"
tar xzf "$ASSET"

# Archive contains a single top-level dir named after the archive base.
PKG_DIR="${ASSET%.tar.gz}"
[ -d "$PKG_DIR" ] || err "extracted archive is missing expected dir ${PKG_DIR}"
[ -f "${PKG_DIR}/lwpt" ] || err "lwpt binary not found in archive"

# --- install ---------------------------------------------------------
SUDO=""
if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "$INSTALL_DIR is not writable and sudo is not available — set INSTALL_DIR to a writable location"
  fi
fi

$SUDO mkdir -p "$INSTALL_DIR"
chmod +x "${PKG_DIR}/lwpt"
$SUDO mv -f "${PKG_DIR}/lwpt" "${INSTALL_DIR}/lwpt"

printf '\nlwpt %s installed to %s\n' "$VERSION" "$INSTALL_DIR"

# Final sanity: invoke the freshly-installed binary if INSTALL_DIR is on PATH.
if command -v lwpt >/dev/null 2>&1; then
  printf '\n'
  lwpt --help | head -1 2>/dev/null || true
else
  printf '\nAdd %s to your PATH if it is not already there.\n' "$INSTALL_DIR"
fi
