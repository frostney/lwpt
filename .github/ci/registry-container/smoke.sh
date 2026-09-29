#!/usr/bin/env bash
# Container smoke for the example registry image in docs/examples/registry.
#
#   smoke.sh --binary <lwpt>      Package <lwpt> exactly like a release
#                                 archive, serve it on loopback, and build the
#                                 image from it (ci.yml: the commit under test).
#   smoke.sh --release <tag>      Build the image from the published release
#                                 assets (release.yml: the release just cut).
#   smoke.sh --collect            Write diagnostics for every smoke container
#                                 and volume to $ARTIFACTS, then remove them.
#                                 Workflows run it as a separate bounded step,
#                                 so diagnostics survive a killed smoke.
#
# Both smoke modes run the example Dockerfile unchanged: download, pinned
# SHA-256 verification, and installation of a release-shaped archive. The
# smoke then proves that a wrong pin fails the build, the container runs as a
# non-root user on a read-only root file system with a read-only
# configuration mount, operator commands work in the serving container, a
# runner-side `registry publish` commits while the server runs, the documented
# reconfiguration procedure works, the data survive graceful stop and
# container replacement, and the TLS-terminating reverse-proxy example serves
# the same protocol. Every container-engine call goes through `dk`, which
# bounds it; on failure, container logs, health history, and data-volume
# listings are written to $ARTIFACTS.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CONTEXT="$REPO_ROOT/docs/examples/registry"
ARTIFACTS=${ARTIFACTS:-$PWD/registry-container-artifacts}
PREFIX=lwpt-smoke
IMAGE=$PREFIX-registry:test
NGINX_IMAGE=${NGINX_IMAGE:-nginx:1.28-alpine}
DIRECT_PORT=18443
PROXY_PORT=18444
DATA=/var/lib/lwpt-registry
HEALTH_DEADLINE_SECONDS=90

log() { printf '=== %s\n' "$*"; }
fail() { printf '::error::registry container smoke: %s\n' "$*" >&2; exit 1; }

# The only way this script reaches the container engine: every call has a
# deadline. --foreground keeps the call in this shell's process group, so a
# signal that stops the smoke also stops the call at once.
dk() {
  local seconds=$1
  shift
  timeout --foreground "$seconds" docker "$@"
}

smoke_containers() { dk 30 ps --all --filter "name=^$PREFIX-" --format '{{.Names}}' || true; }
smoke_volumes() { dk 30 volume ls --filter "name=^$PREFIX-" --format '{{.Name}}' || true; }
smoke_networks() { dk 30 network ls --filter "name=^$PREFIX-" --format '{{.Name}}' || true; }

# Bounded overall: at most four containers and two volumes, each call capped.
collect_artifacts() {
  mkdir -p "$ARTIFACTS"
  local name volume
  for name in $(smoke_containers); do
    dk 20 logs "$name" >"$ARTIFACTS/$name.log" 2>&1 || true
    dk 20 inspect "$name" >"$ARTIFACTS/$name.inspect.json" 2>&1 || true
  done
  if dk 20 image inspect "$IMAGE" >/dev/null 2>&1; then
    for volume in $(smoke_volumes); do
      # Names and sizes, plus the public configuration and activation
      # pointer. Signing seeds and token records are never copied out.
      # shellcheck disable=SC2016 # expanded by the container's shell
      dk 30 run --rm --entrypoint sh -v "$volume:/d:ro" "$IMAGE" -c \
        'find /d -maxdepth 4 -printf "%M %u %s %p\n"; for f in /d/registry.toml /d/state/current.toml; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done' \
        >"$ARTIFACTS/$volume.txt" 2>&1 || true
    done
  fi
}

remove_resources() {
  local name
  for name in $(smoke_containers); do dk 30 rm -f "$name" >/dev/null 2>&1 || true; done
  for name in $(smoke_networks); do dk 30 network rm "$name" >/dev/null 2>&1 || true; done
  for name in $(smoke_volumes); do dk 30 volume rm -f "$name" >/dev/null 2>&1 || true; done
}

if [ "${1:-}" = --collect ] && [ $# -eq 1 ]; then
  collect_artifacts
  remove_resources
  exit 0
fi

WORK=$(mktemp -d)
SERVER_PID=""

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    log "failed with status $status; collecting artifacts in $ARTIFACTS"
    collect_artifacts
  fi
  remove_resources
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

field() { sed -n "s/^$1 = \"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p"; }

usage() { fail "usage: smoke.sh --binary <lwpt> | --release <tag> | --collect"; }

[ $# -eq 2 ] || usage
TAG=""
case "$1" in
  --binary)
    CLIENT=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
    [ -x "$CLIENT" ] || fail "$2 is not an executable lwpt"
    VERSION=$("$CLIENT" --version | head -n 1 | sed -n 's/^lwpt \(.*\)$/\1/p')
    [ -n "$VERSION" ] || fail "cannot read the version of $CLIENT"
    log "packaging $CLIENT as release archive lwpt-$VERSION-linux-x64.tar.gz"
    mkdir -p "$WORK/release/$VERSION" "$WORK/pack/lwpt-$VERSION-linux-x64"
    cp "$CLIENT" "$WORK/pack/lwpt-$VERSION-linux-x64/lwpt"
    tar -C "$WORK/pack" -czf "$WORK/release/$VERSION/lwpt-$VERSION-linux-x64.tar.gz" \
      "lwpt-$VERSION-linux-x64"
    SHA256=$(sha256sum "$WORK/release/$VERSION/lwpt-$VERSION-linux-x64.tar.gz" | cut -d' ' -f1)
    RELEASE_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    python3 -m http.server --bind 127.0.0.1 --directory "$WORK/release" "$RELEASE_PORT" \
      >"$WORK/http.log" 2>&1 &
    SERVER_PID=$!
    RELEASE_BASE_URL=http://127.0.0.1:$RELEASE_PORT
    for _ in $(seq 1 50); do
      curl --silent --fail --max-time 2 --output /dev/null \
        "$RELEASE_BASE_URL/$VERSION/lwpt-$VERSION-linux-x64.tar.gz" && break
      sleep 0.1
    done
    ;;
  --release)
    TAG=$2
    VERSION=${TAG#v}
    RELEASE_BASE_URL=https://github.com/frostney/lwpt/releases/download
    log "fetching the published checksums of $TAG"
    curl --fail --silent --show-error --location --retry 3 --max-time 120 \
      --output "$WORK/checksums.txt" \
      "$RELEASE_BASE_URL/$TAG/lwpt-$VERSION-checksums.txt"
    SHA256=$(awk -v f="lwpt-$VERSION-linux-x64.tar.gz" '$2 == f { print $1 }' "$WORK/checksums.txt")
    [ -n "$SHA256" ] || fail "no linux-x64 digest in lwpt-$VERSION-checksums.txt"
    curl --fail --silent --show-error --location --retry 3 --max-time 300 \
      --output "$WORK/client.tar.gz" \
      "$RELEASE_BASE_URL/$TAG/lwpt-$VERSION-linux-x64.tar.gz"
    echo "$SHA256  $WORK/client.tar.gz" | sha256sum --check --strict -
    tar -C "$WORK" -xzf "$WORK/client.tar.gz"
    CLIENT=$WORK/lwpt-$VERSION-linux-x64/lwpt
    ;;
  *) usage ;;
esac

remove_resources
dk 30 version

build() {
  dk 300 build --progress=plain --network host \
    --build-arg "LWPT_VERSION=$VERSION" \
    --build-arg "LWPT_RELEASE_TAG=$TAG" \
    --build-arg "LWPT_SHA256_LINUX_X64=$1" \
    --build-arg "LWPT_RELEASE_BASE_URL=$RELEASE_BASE_URL" \
    --tag "$2" "$CONTEXT"
}

log "a wrong SHA-256 pin must fail the image build"
WRONG=$(printf '%064d' 0)
if build "$WRONG" "$PREFIX-registry:wrong-pin" >"$WORK/wrong-pin.log" 2>&1; then
  cat "$WORK/wrong-pin.log"
  fail "the image built although the archive does not match its pin"
fi
grep -q 'FAILED' "$WORK/wrong-pin.log" || { cat "$WORK/wrong-pin.log"; fail "the wrong-pin build failed for another reason"; }

log "building $IMAGE from lwpt $VERSION (sha256 $SHA256)"
build "$SHA256" "$IMAGE"

image_field() { dk 30 image inspect --format "$1" "$IMAGE"; }

log "image contract: non-root user, health check, exec-form entry point"
[ "$(image_field '{{.Config.User}}')" = "10001:10001" ] \
  || fail "the image does not run as 10001:10001"
case "$(image_field '{{json .Config.Healthcheck}}')" in
  *lwpt-registry-healthcheck*) ;;
  *) fail "the image has no registry health check" ;;
esac
[ "$(image_field '{{.Config.StopSignal}}')" = "SIGTERM" ] \
  || fail "the image does not stop with SIGTERM"

log "throwaway test PKI: a CA and a leaf for localhost and 127.0.0.1"
PKI=$WORK/pki
mkdir -p "$PKI"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=LWPT container smoke CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$PKI/ca.key" -out "$PKI/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
  -keyout "$PKI/leaf.key" -out "$PKI/leaf.csr" 2>/dev/null
printf '%s\n' 'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' \
  'subjectAltName=DNS:localhost,IP:127.0.0.1' >"$PKI/leaf.ext"
openssl x509 -req -days 2 -in "$PKI/leaf.csr" -CA "$PKI/ca.pem" -CAkey "$PKI/ca.key" \
  -CAcreateserial -extfile "$PKI/leaf.ext" -out "$PKI/leaf.pem" 2>/dev/null
TLS_PASSWORD=$(openssl rand -hex 24)
openssl pkcs12 -export -inkey "$PKI/leaf.key" -in "$PKI/leaf.pem" -certfile "$PKI/ca.pem" \
  -passout "pass:$TLS_PASSWORD" -out "$PKI/registry.p12"
# The secrets directory is mounted read-only; the container user reads it.
SECRETS=$WORK/secrets
mkdir -p "$SECRETS"
cp "$PKI/registry.p12" "$PKI/ca.pem" "$SECRETS/"
printf '%s\n' "$TLS_PASSWORD" >"$SECRETS/tls-password"
chmod 0755 "$SECRETS"
chmod 0444 "$SECRETS"/*

# One-off operator container on the volume alone: init and reconfiguration.
in_volume() {
  local volume=$1
  shift
  dk 120 run --rm --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges \
    -v "$volume:$DATA" -v "$SECRETS:/run/secrets:ro" "$IMAGE" "$@"
}

# The documented export: the configuration `init` wrote into the volume
# becomes a host file that serving containers mount read-only.
export_config() {
  local volume=$1 target=$2
  mkdir -p "$(dirname "$target")"
  dk 60 run --rm --entrypoint cat -v "$volume:$DATA:ro" "$IMAGE" \
    "$DATA/registry.toml" >"$target.new"
  chmod 0444 "$target.new"
  mv -f "$target.new" "$target"
}

pin_of() {
  local record
  record=$(dk 60 run --rm --entrypoint sh -v "$1:$DATA:ro" "$IMAGE" -c \
    "cat $DATA/keys/ed25519-*.toml")
  KEY_ID=$(printf '%s\n' "$record" | field key_id | head -n 1)
  PUBLIC_KEY=$(printf '%s\n' "$record" | field public_key | head -n 1)
  [ -n "$KEY_ID" ] && [ -n "$PUBLIC_KEY" ] || fail "no key record in volume $1"
}

wait_healthy() {
  local name=$1 status=""
  for _ in $(seq 1 "$HEALTH_DEADLINE_SECONDS"); do
    status=$(dk 10 inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)
    [ "$status" = healthy ] && return 0
    [ "$(dk 10 inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" = true ] \
      || fail "$name exited before becoming healthy"
    sleep 1
  done
  fail "$name was not healthy within ${HEALTH_DEADLINE_SECONDS}s (last status: $status)"
}

start_registry() {
  local name=$1 volume=$2 config=$3
  shift 3
  dk 60 run --detach --name "$name" \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --stop-timeout 15 --health-interval 2s \
    -v "$volume:$DATA" -v "$config:$DATA/registry.toml:ro" \
    -v "$SECRETS:/run/secrets:ro" \
    -e LWPT_REGISTRY_TLS_PASSWORD_FILE=/run/secrets/tls-password \
    -e LWPT_REGISTRY_HEALTH_CA=/run/secrets/ca.pem \
    "$@" "$IMAGE" >/dev/null
  wait_healthy "$name"
}

in_container() {
  local name=$1
  shift
  dk 60 exec "$name" "$@"
}

# The serving account can modify neither the binary nor its configuration.
check_protection() {
  local name=$1
  [ "$(in_container "$name" sh -c 'sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" /proc/1/status')" = 10001 ] \
    || fail "PID 1 of $name does not run as uid 10001"
  case "$(in_container "$name" sh -c 'tr "\000" " " </proc/1/cmdline')" in
    "/usr/local/bin/lwpt registry serve "*) ;;
    *) fail "PID 1 of $name is not lwpt registry serve" ;;
  esac
  if in_container "$name" sh -c 'touch /usr/local/bin/lwpt' 2>/dev/null; then
    fail "the service account can modify the binary"
  fi
  if in_container "$name" sh -c "echo '# tampered' >>$DATA/registry.toml" 2>/dev/null; then
    fail "the service account can write the configuration"
  fi
  if in_container "$name" sh -c "mv $DATA/registry.toml $DATA/moved.toml" 2>/dev/null; then
    fail "the service account can replace the configuration"
  fi
  if in_container "$name" sh -c "rm -f $DATA/registry.toml" 2>/dev/null; then
    fail "the service account can remove the configuration"
  fi
}

package_archive() {
  local version=$1 content=$2
  mkdir -p "$WORK/pkg-$version/smoke-lib-$version"
  printf '[package]\nname = "smoke-lib"\nversion = "%s"\n' "$version" \
    >"$WORK/pkg-$version/smoke-lib-$version/lwpt.toml"
  printf '%s\n' "$content" >"$WORK/pkg-$version/smoke-lib-$version/README"
  tar -C "$WORK/pkg-$version" -czf "$WORK/smoke-lib-$version.tar.gz" "smoke-lib-$version"
}

# Publishes from the runner through the release client, trusting only the
# throwaway CA through the OpenSSL default verify paths.
publish() {
  local origin=$1 version=$2 sequence=$3 output
  output=$(cd "$WORK" && SSL_CERT_FILE="$PKI/ca.pem" SSL_CERT_DIR=/nonexistent \
    LWPT_REGISTRY_TOKEN="$TOKEN" timeout 180 "$CLIENT" registry publish \
    "$WORK/smoke-lib-$version.tar.gz" --origin "$origin" --key-id "$KEY_ID" \
    --public-key "$PUBLIC_KEY" --silent) || fail "publish smoke-lib@$version to $origin failed"
  printf '%s\n' "$output"
  case "$output" in
    "published smoke-lib@$version to $origin at sequence $sequence (archive "*) ;;
    *) fail "unexpected publish result: $output" ;;
  esac
  ARCHIVE_HASH=$(printf '%s' "$output" | sed -n 's/.*(archive sha256:\([0-9a-f]*\), record.*/\1/p')
  RECORD_HASH=$(printf '%s' "$output" | sed -n 's/.*, record sha256:\([0-9a-f]*\))$/\1/p')
}

get() {
  curl --fail --silent --show-error --max-time 10 --cacert "$PKI/ca.pem" "$@"
}

read_back() {
  local origin=$1 version=$2
  get "$origin/v1/records/sha256/$RECORD_HASH.toml" >"$WORK/record.toml"
  grep -qx "version = \"$version\"" "$WORK/record.toml" || fail "record of $version not served"
  get "$origin/v1/objects/sha256/$ARCHIVE_HASH" >"$WORK/object.tar.gz"
  [ "$(sha256sum <"$WORK/object.tar.gz" | cut -d' ' -f1)" = "$ARCHIVE_HASH" ] \
    || fail "the served archive does not match its hash"
  [ "$(sha256sum <"$WORK/smoke-lib-$version.tar.gz" | cut -d' ' -f1)" = "$ARCHIVE_HASH" ] \
    || fail "the served archive is not the published one"
}

sequence_of() {
  get "$1/v1/checkpoints/latest.toml" >"$WORK/latest.toml"
  field sequence <"$WORK/latest.toml"
}

issue_token() {
  local name=$1 label=$2
  TOKEN=$(in_container "$name" lwpt registry issue-token --data-dir "$DATA" \
    --packages 'smoke-*' --expires-days 1 --label "$label" --silent)
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$TOKEN"; fi
}

#
# Direct TLS: the container terminates TLS with a mounted PKCS#12 identity.
#
DIRECT_ORIGIN=https://localhost:$DIRECT_PORT
DIRECT_VOLUME=$PREFIX-direct
DIRECT_CONFIG=$WORK/config-direct/registry.toml
dk 30 volume create "$DIRECT_VOLUME" >/dev/null

log "registry init in volume $DIRECT_VOLUME, then export its configuration"
in_volume "$DIRECT_VOLUME" registry init --data-dir "$DATA" --base-url "$DIRECT_ORIGIN" \
  --listen 0.0.0.0 --port 8443 --tls-pkcs12 /run/secrets/registry.p12 \
  --tls-password-env LWPT_REGISTRY_TLS_PASSWORD
export_config "$DIRECT_VOLUME" "$DIRECT_CONFIG"
pin_of "$DIRECT_VOLUME"

log "serving (read-only root and configuration, no capabilities, non-root)"
start_registry "$PREFIX-a" "$DIRECT_VOLUME" "$DIRECT_CONFIG" -p "127.0.0.1:$DIRECT_PORT:8443"
check_protection "$PREFIX-a"
get "$DIRECT_ORIGIN/.well-known/lwpt-registry" >"$WORK/discovery.toml"
grep -qx "base_url = \"$DIRECT_ORIGIN\"" "$WORK/discovery.toml" \
  || fail "discovery does not advertise $DIRECT_ORIGIN"
issue_token "$PREFIX-a" container-smoke

log "live publication from the runner, then read-back"
package_archive 1.0.0 "container smoke 1.0.0"
publish "$DIRECT_ORIGIN" 1.0.0 2
read_back "$DIRECT_ORIGIN" 1.0.0
FIRST_RECORD=$RECORD_HASH
FIRST_ARCHIVE=$ARCHIVE_HASH

log "graceful stop"
STARTED=$(date +%s)
dk 60 stop "$PREFIX-a" >/dev/null
STOPPED=$(( $(date +%s) - STARTED ))
[ "$(dk 10 inspect --format '{{.State.ExitCode}}' "$PREFIX-a")" = 0 ] \
  || fail "registry serve did not exit 0 on SIGTERM"
[ "$STOPPED" -lt 15 ] || fail "graceful stop took ${STOPPED}s"
dk 30 logs "$PREFIX-a" >"$WORK/first.log" 2>&1
grep -q "listening at $DIRECT_ORIGIN" "$WORK/first.log" \
  || fail "the stopped container did not log its listener"
dk 30 rm "$PREFIX-a" >/dev/null

log "documented reconfiguration: init on the volume alone, export, restart"
cp "$DIRECT_CONFIG" "$WORK/config-before.toml"
in_volume "$DIRECT_VOLUME" registry init --data-dir "$DATA" --base-url "$DIRECT_ORIGIN" \
  --listen 0.0.0.0 --port 8443 --tls-pkcs12 /run/secrets/registry.p12 \
  --tls-password-env LWPT_REGISTRY_TLS_PASSWORD
export_config "$DIRECT_VOLUME" "$DIRECT_CONFIG"
cmp -s "$WORK/config-before.toml" "$DIRECT_CONFIG" \
  || fail "an unchanged reconfiguration changed registry.toml"

log "container replacement on the same volume"
start_registry "$PREFIX-b" "$DIRECT_VOLUME" "$DIRECT_CONFIG" -p "127.0.0.1:$DIRECT_PORT:8443"
check_protection "$PREFIX-b"
[ "$(sequence_of "$DIRECT_ORIGIN")" = 2 ] || fail "the replacement lost the signed head"
RECORD_HASH=$FIRST_RECORD
ARCHIVE_HASH=$FIRST_ARCHIVE
read_back "$DIRECT_ORIGIN" 1.0.0

log "operator key rotation in the serving container, then a root-pinned publish"
in_container "$PREFIX-b" lwpt registry rotate-key --data-dir "$DATA" --from-key "$KEY_ID" \
  >"$WORK/rotate.log"
grep -q 'rotated registry signing key at sequence 3' "$WORK/rotate.log" \
  || fail "rotate-key did not rotate at sequence 3"
package_archive 1.1.0 "container smoke 1.1.0"
publish "$DIRECT_ORIGIN" 1.1.0 4
read_back "$DIRECT_ORIGIN" 1.1.0
cmp -s "$WORK/config-before.toml" "$DIRECT_CONFIG" \
  || fail "serving changed the mounted configuration"

#
# Behind a TLS-terminating reverse proxy that re-encrypts to the registry.
#
PROXY_ORIGIN=https://localhost:$PROXY_PORT
PROXY_VOLUME=$PREFIX-proxied
PROXY_REGISTRY_CONFIG=$WORK/config-proxied/registry.toml
NETWORK=$PREFIX-net
dk 30 volume create "$PROXY_VOLUME" >/dev/null
dk 30 network create "$NETWORK" >/dev/null

log "registry init behind the proxy: the public URL is the base URL"
in_volume "$PROXY_VOLUME" registry init --data-dir "$DATA" --base-url "$PROXY_ORIGIN" \
  --listen 0.0.0.0 --port 8443 --tls-pkcs12 /run/secrets/registry.p12 \
  --tls-password-env LWPT_REGISTRY_TLS_PASSWORD
export_config "$PROXY_VOLUME" "$PROXY_REGISTRY_CONFIG"
pin_of "$PROXY_VOLUME"
# No published port: only the proxy reaches the registry.
start_registry "$PREFIX-p" "$PROXY_VOLUME" "$PROXY_REGISTRY_CONFIG" \
  --network "$NETWORK" --network-alias registry
issue_token "$PREFIX-p" proxy-smoke

PROXY_CONFIG=$WORK/proxy
mkdir -p "$PROXY_CONFIG/tls"
sed 's/registry\.example\.com/localhost/g' "$CONTEXT/nginx.conf" >"$PROXY_CONFIG/nginx.conf"
cp "$PKI/leaf.pem" "$PROXY_CONFIG/tls/proxy.pem"
cp "$PKI/leaf.key" "$PROXY_CONFIG/tls/proxy.key"
cp "$PKI/ca.pem" "$PROXY_CONFIG/tls/registry-ca.pem"
chmod -R a+rX "$PROXY_CONFIG"
dk 180 run --detach --name "$PREFIX-nginx" --network "$NETWORK" \
  -p "127.0.0.1:$PROXY_PORT:8443" \
  -v "$PROXY_CONFIG/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PROXY_CONFIG/tls:/etc/nginx/tls:ro" "$NGINX_IMAGE" >/dev/null
for _ in $(seq 1 60); do
  get "$PROXY_ORIGIN/.well-known/lwpt-registry" >"$WORK/proxy-discovery.toml" 2>/dev/null && break
  sleep 1
done
grep -qx "base_url = \"$PROXY_ORIGIN\"" "$WORK/proxy-discovery.toml" \
  || fail "the proxy does not serve the registry's discovery for $PROXY_ORIGIN"

log "live publication and read-back through the proxy"
publish "$PROXY_ORIGIN" 1.0.0 2
read_back "$PROXY_ORIGIN" 1.0.0
[ "$(sequence_of "$PROXY_ORIGIN")" = 2 ] || fail "the proxied head is not sequence 2"

log "registry container smoke passed for lwpt $VERSION"
