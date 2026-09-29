#!/bin/sh
# Entry point of the example LWPT registry image (docs/registry-deployment.md).
#
# `registry serve` reads the PKCS#12 password from the environment variable
# named by `registry init --tls-password-env`. The example uses
# LWPT_REGISTRY_TLS_PASSWORD. Orchestrators that deliver secrets as files set
# LWPT_REGISTRY_TLS_PASSWORD_FILE instead; its content (without trailing
# newlines) becomes the variable. The script then replaces itself with lwpt,
# so lwpt is PID 1 and receives the stop signal directly.
set -eu

if [ -n "${LWPT_REGISTRY_TLS_PASSWORD_FILE:-}" ]; then
  LWPT_REGISTRY_TLS_PASSWORD=$(cat -- "$LWPT_REGISTRY_TLS_PASSWORD_FILE")
  export LWPT_REGISTRY_TLS_PASSWORD
  unset LWPT_REGISTRY_TLS_PASSWORD_FILE
fi

exec /usr/local/bin/lwpt "$@"
