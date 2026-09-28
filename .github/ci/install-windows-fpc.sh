#!/usr/bin/env bash
set -euo pipefail

# Keep native Windows test setup independent of Chocolatey's SourceForge
# mirror selection. Both PR and full CI call this one pinned acquisition path.
fpc_version=3.2.2
installer_name="fpc-${fpc_version}.i386-win32.exe"
installer_url="https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.exe"
installer_sha256=7ec78b1790ecac7685f440b17f9e03865bc09846b7c068a9270c4d37704b5ac8
install_root="${LWPT_WINDOWS_FPC_ROOT:-/c/fpc/${fpc_version}}"
fpc_bin="${install_root}/bin/i386-win32/fpc.exe"

if [ ! -f "${fpc_bin}" ]; then
  if [ -n "${RUNNER_TEMP:-}" ]; then
    installer_base=$(cygpath -u "${RUNNER_TEMP}")
  else
    installer_base="${TMPDIR:-/tmp}"
  fi
  installer_dir="${installer_base}/lwpt-fpc-installer"
  installer_path="${installer_dir}/${installer_name}"
  mkdir -p "${installer_dir}"

  echo "::group::Download pinned FPC ${fpc_version} installer"
  curl --fail --location --retry 2 --retry-all-errors \
    --retry-max-time 240 --connect-timeout 30 --max-time 120 \
    --output "${installer_path}" "${installer_url}"
  actual_sha256=$(sha256sum "${installer_path}" | awk '{print $1}')
  if [ "${actual_sha256}" != "${installer_sha256}" ]; then
    echo "::error::FPC installer checksum mismatch: expected ${installer_sha256}, got ${actual_sha256}"
    exit 1
  fi
  echo "::endgroup::"

  install_root_windows=$(cygpath -w "${install_root}")
  echo "::group::Install FPC ${fpc_version}"
  MSYS2_ARG_CONV_EXCL='*' "${installer_path}" \
    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART "/DIR=${install_root_windows}"
  echo "::endgroup::"
fi

if [ ! -f "${fpc_bin}" ]; then
  echo "::error::FPC installer completed without ${fpc_bin}"
  exit 1
fi

echo "Using FPC at ${fpc_bin}"
cygpath -w "$(dirname "${fpc_bin}")" >> "${GITHUB_PATH}"
LWPT_FPC_VALUE=$(cygpath -w "${fpc_bin}")
echo "LWPT_FPC=$LWPT_FPC_VALUE" >> "${GITHUB_ENV}"

instantfpc_bin=$(find "$(dirname "${fpc_bin}")" -name instantfpc.exe -type f 2>/dev/null | head -1 || true)
if [ -n "${instantfpc_bin}" ]; then
  echo "LWPT_INSTANTFPC=$(cygpath -w "${instantfpc_bin}")" >> "${GITHUB_ENV}"
fi

fpc_unit_paths=""
# fcl-json: InstallScript.E2E.Test uses fpjson. fcl-net stays for its RTL
# consumers. openssl is retained only so a future unit that needs it still
# resolves: per ADR-0033 no Windows source uses OpenSSL; both TLS directions
# are native SChannel.
for unit_dir in rtl rtl-objpas rtl-generics rtl-extra fcl-base fcl-process fcl-net fcl-json openssl paszlib hash; do
  unit_path=""
  for unit_target in i386-win32 x86_64-win64; do
    unit_path=$(find "${install_root}" -path "*/units/${unit_target}/${unit_dir}" -type d 2>/dev/null | head -1 || true)
    if [ -n "${unit_path}" ]; then break; fi
  done
  if [ -n "${unit_path}" ]; then
    unit_path_windows=$(cygpath -w "${unit_path}")
    if [ -z "${fpc_unit_paths}" ]; then
      fpc_unit_paths="${unit_path_windows}"
    else
      fpc_unit_paths="${fpc_unit_paths};${unit_path_windows}"
    fi
  fi
done
echo "LWPT_FPC_UNIT_PATHS=${fpc_unit_paths}" >> "${GITHUB_ENV}"

"${fpc_bin}" -iV
