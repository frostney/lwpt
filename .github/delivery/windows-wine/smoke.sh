#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:-/artifacts}
diagnostic_root=$(mktemp -d /tmp/lwpt-wine-smoke.XXXXXX)
trap 'rm -rf "${diagnostic_root}"' EXIT

cp "${artifact_dir}/lwpt.exe" "${diagnostic_root}/lwpt.exe"
cp "${artifact_dir}/Win32PipeDirectionProbe.exe" \
  "${diagnostic_root}/Win32PipeDirectionProbe.exe"

xvfb-run -a wine "${diagnostic_root}/Win32PipeDirectionProbe.exe"
xvfb-run -a wine "${diagnostic_root}/lwpt.exe" --help \
  > "${diagnostic_root}/help.txt"
grep -F 'usage: lwpt <command> [options]' "${diagnostic_root}/help.txt" \
  > /dev/null
printf 'Win32 PE load and command dispatch: pass\n'
