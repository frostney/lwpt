#!/usr/bin/env bash
set -euo pipefail

# Keep native Windows test setup independent of Chocolatey's SourceForge
# mirror selection. Both PR and full CI call this one pinned acquisition path.
#
# Usage: install-windows-fpc.sh <i386-win32|x86_64-win64>
#
# The argument is the target the job's test programs must be compiled for.
# The official FPC 3.2.2 Windows distribution's native compiler is i386, so
# every target installs the i386-win32 base (host tools, fpc.cfg, InstantFPC).
# The x86_64-win64 target also installs the official x86_64-win64 cross
# add-on and publishes its ppcrossx64.exe as LWPT_FPC, so `lwpt test` builds
# and runs 64-bit test programs on that leg (issue #329).
fpc_version=3.2.2
target="${1:-}"
case "${target}" in
  i386-win32)
    test_compiler_name=fpc.exe
    expected_target="win32 i386"
    expected_pointer_bits=32
    ;;
  x86_64-win64)
    test_compiler_name=ppcrossx64.exe
    expected_target="win64 x86_64"
    expected_pointer_bits=64
    ;;
  *)
    echo "::error::usage: $0 <i386-win32|x86_64-win64> (got '${target}')"
    exit 2
    ;;
esac

base_installer_url="https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.exe"
base_installer_sha256=7ec78b1790ecac7685f440b17f9e03865bc09846b7c068a9270c4d37704b5ac8
cross_installer_url="https://downloads.freepascal.org/fpc/dist/3.2.2/i386-win32/fpc-3.2.2.i386-win32.cross.x86_64-win64.exe"
cross_installer_sha256=9b4ea18d9c0a613fcc815b78612967a62d539e8c42070299c5c3c2ce8f712768

install_root="${LWPT_WINDOWS_FPC_ROOT:-/c/fpc/${fpc_version}}"
host_bin_dir="${install_root}/bin/i386-win32"
fpc_bin="${host_bin_dir}/fpc.exe"
test_compiler="${host_bin_dir}/${test_compiler_name}"

if [ -n "${RUNNER_TEMP:-}" ]; then
  work_base=$(cygpath -u "${RUNNER_TEMP}")
else
  work_base="${TMPDIR:-/tmp}"
fi
work_dir="${work_base}/lwpt-fpc-installer"
mkdir -p "${work_dir}"

# install_pinned <label> <url> <sha256>
install_pinned() {
  local label=$1 url=$2 expected_sha256=$3
  local installer_path="${work_dir}/${url##*/}"
  local actual_sha256 install_root_windows

  echo "::group::Download pinned ${label}"
  curl --fail --location --retry 2 --retry-all-errors \
    --retry-max-time 240 --connect-timeout 30 --max-time 120 \
    --output "${installer_path}" "${url}"
  actual_sha256=$(sha256sum "${installer_path}" | awk '{print $1}')
  if [ "${actual_sha256}" != "${expected_sha256}" ]; then
    echo "::error::${label} checksum mismatch: expected ${expected_sha256}, got ${actual_sha256}"
    exit 1
  fi
  echo "::endgroup::"

  install_root_windows=$(cygpath -w "${install_root}")
  echo "::group::Install ${label}"
  MSYS2_ARG_CONV_EXCL='*' "${installer_path}" \
    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART "/DIR=${install_root_windows}"
  echo "::endgroup::"
}

if [ ! -f "${fpc_bin}" ]; then
  install_pinned "FPC ${fpc_version} installer" \
    "${base_installer_url}" "${base_installer_sha256}"
fi
if [ ! -f "${fpc_bin}" ]; then
  echo "::error::FPC installer completed without ${fpc_bin}"
  exit 1
fi

if [ "${target}" = "x86_64-win64" ] && [ ! -f "${test_compiler}" ]; then
  install_pinned "FPC ${fpc_version} x86_64-win64 cross add-on" \
    "${cross_installer_url}" "${cross_installer_sha256}"
fi
if [ ! -f "${test_compiler}" ]; then
  echo "::error::FPC ${target} setup completed without ${test_compiler}"
  exit 1
fi

# The native bin keeps fpc and InstantFPC on PATH for host-side scripts; only
# LWPT_FPC selects the compiler that builds test programs.
echo "Using FPC for ${target} test programs at ${test_compiler}"
cygpath -w "${host_bin_dir}" >> "${GITHUB_PATH}"
LWPT_FPC_VALUE=$(cygpath -w "${test_compiler}")
echo "LWPT_FPC=$LWPT_FPC_VALUE" >> "${GITHUB_ENV}"

# LWPT itself no longer reads LWPT_INSTANTFPC: hooks run InstantFPC from
# PATH. The variable is published only as a diagnostic, printed by
# LWPT.CompilerDriver.FPC.Test when bare instantfpc fails to resolve.
instantfpc_bin=$(find "${host_bin_dir}" -name instantfpc.exe -type f 2>/dev/null | head -1 || true)
if [ -n "${instantfpc_bin}" ]; then
  echo "LWPT_INSTANTFPC=$(cygpath -w "${instantfpc_bin}")" >> "${GITHUB_ENV}"
fi

fpc_unit_paths=""
# fcl-json: InstallScript.E2E.Test uses fpjson. fcl-net stays for its RTL
# consumers. openssl is retained only so a future unit that needs it still
# resolves: per ADR-0033 no Windows source uses OpenSSL; both TLS directions
# are native SChannel. Units come from the requested target only: a unit
# directory of the other Windows target would silently mix architectures.
for unit_dir in rtl rtl-objpas rtl-generics rtl-extra fcl-base fcl-process fcl-net fcl-json openssl paszlib hash; do
  unit_path="${install_root}/units/${target}/${unit_dir}"
  if [ ! -d "${unit_path}" ]; then
    echo "::error::FPC ${target} setup completed without ${unit_path}"
    exit 1
  fi
  unit_path_windows=$(cygpath -w "${unit_path}")
  if [ -z "${fpc_unit_paths}" ]; then
    fpc_unit_paths="${unit_path_windows}"
  else
    fpc_unit_paths="${fpc_unit_paths};${unit_path_windows}"
  fi
done
echo "LWPT_FPC_UNIT_PATHS=${fpc_unit_paths}" >> "${GITHUB_ENV}"

"${test_compiler}" -iV
actual_target=$("${test_compiler}" -iTO -iTP | tr -d '\r')
if [ "${actual_target}" != "${expected_target}" ]; then
  echo "::error::${test_compiler} targets '${actual_target}', expected '${expected_target}'"
  exit 1
fi

# Build and run a probe so the log shows the compiler banner
# ("Target OS: Win64 for x64" on the x86_64 leg) and the runner executes an
# image of the expected width.
probe_dir="${work_dir}/target-probe"
rm -rf "${probe_dir}"
mkdir -p "${probe_dir}"
printf 'program FPCTargetProbe;\nbegin\n  WriteLn(SizeOf(Pointer) * 8);\nend.\n' \
  > "${probe_dir}/probe.pas"
echo "::group::Probe ${target} test compiler"
(cd "${probe_dir}" && "${test_compiler}" -l probe.pas)
echo "::endgroup::"
probe_bits=$("${probe_dir}/probe.exe" | tr -d '\r')
if [ "${probe_bits}" != "${expected_pointer_bits}" ]; then
  echo "::error::${target} probe reported ${probe_bits}-bit pointers, expected ${expected_pointer_bits}"
  exit 1
fi
echo "${target} test programs compile as ${expected_pointer_bits}-bit images"
