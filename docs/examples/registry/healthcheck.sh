#!/bin/sh
# Health check of the example LWPT registry image (docs/registry-deployment.md).
#
# Healthy means this container's listener serves the discovery document of
# the registry in its data directory. The check reads the persisted
# configuration, so it follows `registry init` without extra settings. It
# connects to the local listener while keeping the configured base URL, so
# TLS verifies the certificate against the real host name. Set
# LWPT_REGISTRY_HEALTH_CA to a PEM file when that certificate chains to a
# private CA instead of the system trust store.
set -eu

data="${LWPT_REGISTRY_DATA:-/var/lib/lwpt-registry}"
config="$data/registry.toml"

base_url=$(sed -n 's/^base_url = "\(.*\)"$/\1/p' "$config")
listen=$(sed -n 's/^listen_address = "\(.*\)"$/\1/p' "$config")
port=$(sed -n 's/^port = \([0-9][0-9]*\)$/\1/p' "$config")
if [ -z "$base_url" ] || [ -z "$listen" ] || [ -z "$port" ]; then
  echo "unhealthy: $config has no base_url, listen_address, or port" >&2
  exit 1
fi

case "$listen" in
  0.0.0.0 | localhost) address=127.0.0.1 ;;
  *) address=$listen ;;
esac

set -- --fail --silent --show-error --max-time 5 --proto =http,https \
  --connect-to "::$address:$port"
if [ -n "${LWPT_REGISTRY_HEALTH_CA:-}" ]; then
  set -- "$@" --cacert "$LWPT_REGISTRY_HEALTH_CA"
fi

body=$(curl "$@" "$base_url/.well-known/lwpt-registry")
case "$body" in
  *'schema = "lwpt-registry-discovery-v1"'*"base_url = \"$base_url\""*) exit 0 ;;
esac
echo "unhealthy: $base_url did not serve this registry's discovery document" >&2
exit 1
