#!/usr/bin/env bash
set -euo pipefail

repository=${1:-/workspace}
output=${2:-/out}
fpc_version=3.2.2
prefix=/opt/fpc-cross
compiler=${prefix}/lib/fpc/${fpc_version}/ppcross386
target=i386-win32
rtl_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl
objpas_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl-objpas
generics_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl-generics
process_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/fcl-process
paszlib_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/paszlib
fpc_source=/opt/fpc-source

mkdir -p "${output}/lwpt-units" "${output}/test-units" \
  "${output}/probe-units"
cd "${repository}"

common_args=(
  -Twin32 -Mdelphi -Sh -O2 -dFPC_SOFT_FPUX80
  -XPi686-w64-mingw32- -Xm
  -Fu"${rtl_dir}" -Fu"${objpas_dir}" -Fu"${generics_dir}"
  -Fu"${process_dir}" -Fu"${paszlib_dir}"
  -Fu"${fpc_source}/packages/fcl-base/src"
  -Fu"${fpc_source}/packages/fcl-net/src"
  -Fu"${fpc_source}/packages/openssl/src"
  -Fusource -Fisource
  -Fupackages/httpclient/source -Fipackages/httpclient/source
  -Fupackages/cli/source -Fipackages/cli/source
  -Fupackages/semver/source -Fipackages/semver/source
  -Fupackages/toml/source -Fipackages/toml/source
  -Fupackages/testing/source -Fipackages/testing/source
)

"${compiler}" "${common_args[@]}" -B -dPRODUCTION \
  -FU"${output}/lwpt-units" -FE"${output}" source/lwpt.pas

"${compiler}" "${common_args[@]}" -B -Futests/support \
  -FU"${output}/test-units" -FE"${output}" \
  tests/integration/TestScheduling.Test.pas

"${compiler}" "${common_args[@]}" -B -dLWPT_WINDOWS_WINE_DIAGNOSTIC \
  -FU"${output}/probe-units" -FE"${output}" \
  /opt/lwpt-diagnostic/Win32PipeDirectionProbe.pas

ls -l "${output}/lwpt.exe" "${output}/TestScheduling.Test.exe" \
  "${output}/Win32PipeDirectionProbe.exe"
