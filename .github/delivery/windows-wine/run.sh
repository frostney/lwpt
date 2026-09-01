#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repository=$(git -C "${script_dir}" rev-parse --show-toplevel)
artifact_dir=$(mktemp -d /tmp/lwpt-win32-artifacts.XXXXXX)
trap 'rm -rf "${artifact_dir}"' EXIT

cross_image=lwpt-win32-cross:3.2.2
wine_image=lwpt-wine32:bookworm
wine_prefix_volume=lwpt-wine32-prefix

docker build --platform linux/arm64 -f "${script_dir}/Dockerfile.cross" \
  -t "${cross_image}" "${script_dir}"
docker build --platform linux/386 -f "${script_dir}/Dockerfile.wine" \
  -t "${wine_image}" "${script_dir}"

docker run --rm --platform linux/arm64 \
  -v "${repository}:/workspace:ro" -v "${artifact_dir}:/out" \
  "${cross_image}" /workspace /out

docker volume inspect "${wine_prefix_volume}" > /dev/null 2>&1 \
  || docker volume create "${wine_prefix_volume}" > /dev/null
docker run --rm --platform linux/386 \
  -v "${wine_prefix_volume}:/wine-prefix" \
  -v "${artifact_dir}:/artifacts:ro" \
  "${wine_image}" /artifacts
