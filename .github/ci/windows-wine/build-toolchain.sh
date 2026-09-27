#!/usr/bin/env bash
set -euo pipefail

source_archive=${1:?FPC source archive is required}
fpc_version=3.2.2
source_root=/opt/fpc-source
prefix=/opt/fpc-cross
native_rtl=/usr/lib/aarch64-linux-gnu/fpc/${fpc_version}/units/aarch64-linux/rtl
compiler=${prefix}/lib/fpc/${fpc_version}/ppcross386
target=i386-win32

mkdir -p "${source_root}"
tar xzf "${source_archive}" --strip-components=1 -C "${source_root}"
mkdir -p "${prefix}/lib/fpc/${fpc_version}" "${prefix}/bin"

# FPC 3.2.2 assumes an 80-bit native Extended while building the i386
# compiler. AArch64's native compiler has Double-sized Extended instead.
sed -i \
  's/   bestrealrec = TExtended80Rec;/{$ifdef FPC_HAS_TYPE_EXTENDED}\n   bestrealrec = TExtended80Rec;\n{$else}\n   bestrealrec = TDoubleRec;\n{$endif}/' \
  "${source_root}/compiler/i386/cpuinfo.pas"

cd "${source_root}/compiler"
mkdir -p i386/units/i386-win32
ppca64 -dFPC_SOFT_FPUX80 -di386 -dRELEASE -O2 -Xs -n -Tlinux \
  -Fui386 -Fusystems -Fux86 -Fii386 -Fu"${native_rtl}" \
  -FE. -FUi386/units/i386-win32 pp.pas
mv pp "${compiler}"
chmod +x "${compiler}"

cd "${source_root}"
make rtl \
  PP=/usr/local/bin/ppcross386-wrapper \
  CPU_TARGET=i386 \
  OS_TARGET=win32 \
  OPT=-dFPC_SOFT_FPUX80 \
  BINUTILSPREFIX=i686-w64-mingw32-

rtl_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl
objpas_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl-objpas
generics_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/rtl-generics
process_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/fcl-process
paszlib_dir=${prefix}/lib/fpc/${fpc_version}/units/${target}/paszlib

mkdir -p "${rtl_dir}" "${objpas_dir}" "${generics_dir}" \
  "${process_dir}" "${paszlib_dir}"
cp rtl/units/${target}/* "${rtl_dir}/"

"${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
  -Fu"${rtl_dir}" -Fu"${objpas_dir}" -FU"${objpas_dir}" \
  -Fipackages/rtl-objpas/src/inc -Fipackages/rtl-objpas/src/win \
  packages/rtl-objpas/src/win/varutils.pp
for unit_name in variants strutils dateutils; do
  "${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
    -Fu"${rtl_dir}" -Fu"${objpas_dir}" -FU"${objpas_dir}" \
    "packages/rtl-objpas/src/inc/${unit_name}.pp"
done

for unit_name in generics.hashes generics.strings generics.defaults \
  generics.helpers generics.memoryexpanders generics.collections; do
  unit_source="packages/rtl-generics/src/${unit_name}.pas"
  if [ -f "${unit_source}" ]; then
    "${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
      -Fu"${rtl_dir}" -Fu"${objpas_dir}" -Fu"${generics_dir}" \
      -FU"${generics_dir}" "${unit_source}"
  fi
done

"${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
  -Fu"${rtl_dir}" -FU"${process_dir}" \
  -Fipackages/fcl-process/src/win packages/fcl-process/src/pipes.pp
"${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
  -Fu"${rtl_dir}" -Fu"${process_dir}" -FU"${process_dir}" \
  -Fipackages/fcl-process/src/win packages/fcl-process/src/process.pp

"${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
  -Fu"${rtl_dir}" -Fu"${paszlib_dir}" -Fupackages/hash/src \
  -FU"${paszlib_dir}" packages/paszlib/src/zstream.pp

if [ ! -f "${rtl_dir}/winsock2.ppu" ]; then
  "${compiler}" -Twin32 -O2 -dFPC_SOFT_FPUX80 -XPi686-w64-mingw32- \
    -Fu"${rtl_dir}" -FU"${rtl_dir}" packages/rtl-extra/src/win/winsock2.pp
fi
