# Registry deployment

How to run a self-hosted LWPT registry origin or mirror in production: the
example container image, TLS and reverse-proxy shapes, secrets and tokens,
graceful shutdown, backup and restore, upgrades, operational limits, and the
portability assumptions behind them.

## Executive Summary

- **Registry service deployment is Linux-container-first.** The example image in
  [`docs/examples/registry/`](./examples/registry/) installs a released `lwpt`
  binary pinned by SHA-256, runs `lwpt registry serve` as UID 10001 with a
  read-only root file system and a read-only configuration mount, keeps all
  other state on one data volume, and checks health through the discovery
  endpoint. It is documentation, not a
  second build system. `./build/lwpt build` remains LWPT's only build.
- **Clients and verification work on every release platform.** `registry
  publish`, mirror `sync` and `verify`, and registry-backed `lwpt install`
  (including `--frozen` and `--offline`) run on all six release targets. The
  wire protocol is platform-neutral, and the
  [E2E matrix](#what-ci-proves) runs on Linux, macOS, and Windows.
- **TLS is terminated by the registry itself or re-encrypted by a proxy.** The
  base URL a client contacts must be the one the registry advertises, and
  plain HTTP is only for `http://localhost` development. A proxy cannot sit
  in front of a plain-HTTP registry.
- **Secrets never enter the image.** The PKCS#12 identity and its password
  are mounted at run time, publication tokens are issued into the volume and
  handed to CI once, and signing keys are generated inside the volume.
- **State is recoverable without extra coordination.** Publication commits
  through one atomic pointer, so a crash or a stop leaves the previous or the
  new head, and restart recovery reclaims staging. A backup must copy the
  pointer first or be taken from a stopped or frozen volume. Restoring an
  older backup rolls the origin back, and anyone who already saw a newer
  head notices.
- **Upgrades replace the image and keep the volume.** Every persisted
  document carries a `-v1` schema. A schema the binary does not know fails
  closed, so keep a backup and the previous image tag for rollback.

## Deployment shapes

| Shape | Base URL | Listener in the container | Use |
| --- | --- | --- | --- |
| [Direct TLS](#run-an-origin-with-direct-tls) | `https://registry.example.com` | `0.0.0.0:8443`, PKCS#12 identity | Production. Publish `443:8443`. |
| [Behind a re-encrypting proxy](#behind-a-reverse-proxy) | `https://registry.example.com` (the proxy's public URL) | `0.0.0.0:8443` on a private network, identity the proxy trusts | Production with an existing edge proxy, ACME, or access logs |
| [Local development](#local-development-over-plain-http) | `http://localhost:8080` | `localhost:8080`, host networking | Development only. Release consumers refuse it. |

A mirror uses the same shapes with its own base URL and the origin's
identity. See [Mirrors](#mirrors).

## The example image

[`docs/examples/registry/`](./examples/registry/) contains:

| File | Role |
| --- | --- |
| [`Dockerfile`](./examples/registry/Dockerfile) | Downloads `lwpt-<version>-linux-x64.tar.gz` or `-linux-arm64.tar.gz` from the release, verifies the pinned SHA-256, checks `lwpt --version`, and installs the binary root-owned with mode `0555`. |
| [`entrypoint.sh`](./examples/registry/entrypoint.sh) | Optionally loads the TLS password from a file, then `exec`s `lwpt`, so `lwpt` is PID 1. |
| [`healthcheck.sh`](./examples/registry/healthcheck.sh) | Reads `registry.toml` and fetches `<base-url>/.well-known/lwpt-registry` from the local listener. TLS is verified against the real host name. |
| [`nginx.conf`](./examples/registry/nginx.conf) | A TLS-terminating proxy that re-encrypts to the registry. |

Build it from a release that includes the `registry` command family. Releases
up to 0.7.0 do not have it. Take the digests from the release's
`lwpt-<version>-checksums.txt`:

```sh
docker build \
  --build-arg LWPT_VERSION=<version> \
  --build-arg LWPT_SHA256_LINUX_X64=<sha256 of lwpt-<version>-linux-x64.tar.gz> \
  --build-arg LWPT_SHA256_LINUX_ARM64=<sha256 of lwpt-<version>-linux-arm64.tar.gz> \
  -t lwpt-registry:<version> docs/examples/registry
```

A missing or wrong pin fails the build. Pin the Debian base image by digest
as well. The release binary links glibc, so a musl base such as Alpine does
not work, and it loads OpenSSL 3 (`libssl3`) at run time for TLS. The image
declares `/var/lib/lwpt-registry` as its data volume, owned by UID and GID
10001 with mode `0700`. A named volume inherits that ownership. A bind mount
must be `chown`ed to 10001 first.

## Run an origin with direct TLS

The examples use a named volume `lwpt-registry` and a host directory of
secrets mounted read-only at `/run/secrets`:

```text
/srv/lwpt-registry/secrets/registry.p12    PKCS#12: leaf, intermediates, key
/srv/lwpt-registry/secrets/tls-password    its password
```

The identity must pass the registry's strict certificate policy (ADR-0024):
a currently valid leaf for the base URL host with `serverAuth`, and every
bundled issuer a CA. It must also chain to the trust store of every client:
consumers, mirrors, and publishers verify against their system trust store.

**1. Initialize once.** The identity is fixed at the first initialization.
Choose the canonical public URL, which may be an IP address such as
`https://192.0.2.10`:

```sh
docker volume create lwpt-registry
docker run --rm \
  -v lwpt-registry:/var/lib/lwpt-registry \
  -v /srv/lwpt-registry/secrets:/run/secrets:ro \
  lwpt-registry:<version> registry init --data-dir /var/lib/lwpt-registry \
    --base-url https://registry.example.com --listen 0.0.0.0 --port 8443 \
    --tls-pkcs12 /run/secrets/registry.p12 \
    --tls-password-env LWPT_REGISTRY_TLS_PASSWORD
```

`init` writes `registry.toml`, generates the Ed25519 signing key inside the
volume, and signs sequence 1.

**2. Export the configuration.** `registry.toml` holds the identity, the
listener, and the TLS paths, and on a mirror the root pin. Only `init`
writes it. `serve`, `issue-token`, `revoke-token`, `rotate-key`, `verify`,
and `sync` read it and write only other paths in the data directory. Copy
it to a root-owned host file that the serving container mounts read-only
over the volume's copy, so the serving account cannot rewrite, replace, or
remove its own identity or pin:

```sh
install -d -m 0755 /srv/lwpt-registry/config
docker run --rm --entrypoint cat -v lwpt-registry:/var/lib/lwpt-registry:ro \
  lwpt-registry:<version> /var/lib/lwpt-registry/registry.toml \
  > /srv/lwpt-registry/config/registry.toml
chmod 0444 /srv/lwpt-registry/config/registry.toml
```

**3. Publish the trust pin out of band.** Consumers (`[registries]` `key-id`
and `public-key`), mirrors, and publishers pin the root key:

```sh
docker run --rm --entrypoint sh -v lwpt-registry:/var/lib/lwpt-registry:ro \
  lwpt-registry:<version> -c 'cat /var/lib/lwpt-registry/keys/ed25519-*.toml'
```

Copy `key_id` and `public_key` from that record. After a key rotation this
directory holds several records. The root pin stays the record with
`valid_from_sequence = 1`, and clients follow the signed rotation chain from
it.

**4. Serve.**

```sh
docker run --detach --name lwpt-registry --restart unless-stopped \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --stop-timeout 15 -p 443:8443 \
  -v lwpt-registry:/var/lib/lwpt-registry \
  -v /srv/lwpt-registry/config/registry.toml:/var/lib/lwpt-registry/registry.toml:ro \
  -v /srv/lwpt-registry/secrets:/run/secrets:ro \
  -e LWPT_REGISTRY_TLS_PASSWORD_FILE=/run/secrets/tls-password \
  lwpt-registry:<version>
```

**Reconfiguration.** `init` cannot rewrite a read-only mount, and a serving
process never needs to. To move the base URL, listener, or TLS paths:

1. Stop and remove the serving container. Replacing the host file while a
   container has it mounted would leave that container on the old file.
2. Run `registry init` with the new values in a one-off container that
   mounts the volume and the secrets but not the configuration file, as in
   step 1. It updates the volume's copy atomically and refuses to change
   the identity or, on a mirror, the root pin.
3. Export the configuration again, as in step 2.
4. Start the serving container as in step 4.

The volume's copy and the host file are then identical. Back up the host
file with the volume.

A read-only root needs a writable `/tmp`: `registry init` keeps its
initialization lease in the temporary directory, and `--silent` journals
output there. Because that lease is per container, run `init` and
reconfiguration for one data directory from one container at a time.

The server prints `registry <identity> listening at <base-url>` once it has
bound its port. It writes diagnostics, such as a failed checkpoint renewal or
audit write, to stderr with a request ID. There is no per-request access
log. Use a proxy's log for that. Every mutating request writes an audit
record under `audit/` in the volume.

**Health.** The image's `HEALTHCHECK` passes only when the local listener
serves this data directory's discovery document under the configured base
URL. When the certificate chains to a private CA, set
`LWPT_REGISTRY_HEALTH_CA` to a PEM file of that CA. Health is liveness only.
A mirror serving an expired checkpoint is still healthy, so monitor mirror
freshness separately (see [Mirrors](#mirrors)).

**Graceful shutdown.** `docker stop` sends `SIGTERM` to `lwpt`, which runs as
PID 1 and installs its own handler. The server stops accepting within
100 ms, cancels every in-flight connection instead of completing it, drains
its workers, releases the TLS context, and exits 0. `--stop-timeout 15`
covers the ten-second per-connection deadline plus teardown. A cancelled or
killed publication leaves either the previous or the new head, never a mix.
The publishing client retries or fails, and a retry is idempotent. Uploads
cut off mid-body are reclaimed at the next start. A `SIGKILL` after the
timeout is handled like a crash: the next start recovers.

**Certificate renewal.** The server reads the PKCS#12 file once, at start.
To renew, replace the file at the same path and restart the container.
Mirrors keep serving during the restart.

## Secrets and credentials

- **TLS identity.** Mount it read-only. The absolute path is persisted in
  `registry.toml`. The server opens each path component without following
  symbolic links and requires a regular file. Docker bind mounts and
  Compose file secrets satisfy this. Kubernetes Secret volumes expose each
  key through a symbolic link, which the registry refuses.
- **TLS password.** `registry serve` reads it from the environment variable
  named at `init` (`--tls-password-env`) while constructing the listener,
  and never persists it. Set `LWPT_REGISTRY_TLS_PASSWORD_FILE` to a mounted
  file to keep the value out of `docker inspect`. The entry point exports
  the file's content under the variable name used above, so the process
  environment holds it for the life of the process. Only the same UID and
  a sufficiently privileged root can read `/proc/<pid>/environ`, and they
  can already read the mounted password file, so the environment copy
  exposes nothing the file does not.
- **Publication tokens.** Issue one per publisher and scope it to package
  patterns. The token is printed once and stored only as a hash:

  ```sh
  docker exec lwpt-registry lwpt registry issue-token \
    --data-dir /var/lib/lwpt-registry --packages 'acme-*' \
    --expires-days 90 --label ci-acme --silent
  ```

  Store the output as the CI secret `LWPT_REGISTRY_TOKEN`. The publisher then
  runs `lwpt registry publish <archive> --origin <base-url> --key-id <pin>
  --public-key <pin>` without stopping the server. To rotate, issue a new
  token, switch the CI secret (validity periods may overlap), and revoke the
  old one with `lwpt registry revoke-token --data-dir
  /var/lib/lwpt-registry --token-id <id>`. `registry verify` lists token
  IDs, labels, scopes, and expiry, never secrets. Revocation and expiry take
  effect on the next request.
- **Signing keys.** The private seeds live in `keys/` inside the volume with
  owner-only permissions and never leave it except in backups. Rotate while
  serving with `lwpt registry rotate-key --data-dir /var/lib/lwpt-registry
  --from-key <current key id>`. Consumers and mirrors keep their root pin and
  verify the dual-signed rotation. A retry after a completed rotation fails
  its precondition instead of rotating twice.
- **The volume is the trust boundary.** Anyone who can write it can replace
  the keys, tokens, and signed state, and without the read-only
  configuration mount the identity and root pin too (ADR-0045). Give it to
  UID 10001 alone, and run `docker exec` operations as that user, which is
  the image default. `issue-token`, `revoke-token`, and `rotate-key` work in
  the serving container with the configuration mounted read-only. Do not
  place the volume on shared or network-writable storage.

## Behind a reverse proxy

Discovery advertises the registry's base URL, and every client refuses a
discovery document whose `base_url` differs from the URL it contacted
(`registry_discovery_scope_mismatch`). The registry accepts plain HTTP only
when that base URL is exactly `http://localhost`, and an HTTPS base URL
requires its own PKCS#12 identity. A proxy that terminates TLS in front of
a plain-HTTP registry therefore cannot serve remote clients. Two shapes
work:

- **Re-encryption.** The registry is initialized with the public URL as its
  base URL, listens on a private network, and presents a certificate for the
  public host name, usually from a private CA. The proxy presents the public
  certificate and verifies the registry's certificate against that CA.
  [`nginx.conf`](./examples/registry/nginx.conf) is a working example. CI
  runs it with the example image.
- **TLS passthrough.** A layer-4 proxy forwards the TCP stream by SNI, and
  the registry holds the public certificate as in
  [direct TLS](#run-an-origin-with-direct-tls).

Either way, the proxy must not compress responses, because hashes cover the
exact bytes, rewrite bodies, add or rewrite redirects (publication never
follows them), drop `Authorization`, or forward uploads without an exact
`Content-Length`. It must allow bodies up to the 256 MiB archive limit and
the upload deadline of 30 seconds plus one second per MiB. Behind a proxy,
the registry's per-peer limit of 20 failed authentications per minute
applies to the proxy's address, so rely on per-token limits and the proxy's
own rate limiting.

## Local development over plain HTTP

`--base-url http://localhost:8080` with the default `localhost` listener is
the development exception. The canonical host must be exactly `localhost`
and the listener loopback. `http://127.0.0.1`, other hosts, and
`--listen 0.0.0.0` are refused with `insecure_transport`. A loopback listener
inside a container is not reachable through `-p`, so run it with
`--network host` on a Linux Docker Engine. `registry publish` and mirror
`sync` accept the localhost contact. Release builds of `lwpt install` refuse
it, and only LWPT's test build accepts it.

## Mirrors

A mirror serves the origin's signed content during an origin outage and
never contacts the origin while serving a request. Initialize it with the
origin identity, its upstream contact, and the root pin:

```sh
docker run --rm -v lwpt-mirror:/var/lib/lwpt-registry \
  -v /srv/lwpt-mirror/secrets:/run/secrets:ro \
  lwpt-registry:<version> registry init --role mirror \
    --data-dir /var/lib/lwpt-registry \
    --identity https://registry.example.com \
    --upstream https://registry.example.com \
    --key-id <root key id> --public-key <root public key> \
    --base-url https://mirror.example.net --listen 0.0.0.0 --port 8443 \
    --tls-pkcs12 /run/secrets/registry.p12 \
    --tls-password-env LWPT_REGISTRY_TLS_PASSWORD
```

Export its configuration and serve it like an origin; the read-only mount
matters most here because a mirror's `registry.toml` holds its root pin.
Synchronization is explicit. Run it from the host's
scheduler, such as cron or a systemd timer, against the serving container:

```sh
docker exec lwpt-mirror lwpt registry sync --data-dir /var/lib/lwpt-registry
docker exec lwpt-mirror lwpt registry verify --data-dir /var/lib/lwpt-registry
```

- Sync often enough for publication latency, and at least every 12 hours.
  An origin renews its seven-day checkpoint only when less than 24 hours
  remain, so a mirror that syncs less often can serve an expired checkpoint,
  which consumers treat as stale and skip. Alert when `verify` reports
  `freshness = "expired"`.
- A failed sync never replaces the accepted state, and the mirror keeps
  serving it. `verify` reports the failed attempt.
- `--max-store-bytes` (32 GiB by default) and `--max-sync-bytes` (8 GiB by
  default) bound disk use.
- The upstream certificate must chain to the mirror's system trust store.
  On Linux that is OpenSSL's default verify paths, including
  `SSL_CERT_FILE` and `SSL_CERT_DIR`.

Consumers list mirrors in `[registries.<alias>].mirrors` and try them in
order, then the origin. An unreachable or stale contact advances to the
next. A trust failure stops the install. See
[ADR-0051](./adr/0051-registry-dependency-sources.md) and the manifest
reference in [`architecture.md`](./architecture.md).

## Backup and restore

**What to back up.** Back up the whole data directory except the transient
`tmp/`, `locks/`, and `incoming/`:

| Path | Contents | Notes |
| --- | --- | --- |
| `registry.toml` | Identity, base URL, listener, TLS paths, mirror pin | Needed to open the store. Back up the read-only host copy too; it must match the volume's. |
| `state/current.toml` | The activation pointer: sequence, snapshot, checkpoint, signature, clock floor | Defines what the registry serves |
| `keys/` | Public key records and the **private signing seeds** | Secret. Encrypt the backup and preserve owner-only permissions. |
| `auth/tokens/` | Token metadata and secret hashes | Owner-only. A restore reinstates the tokens it contains. |
| `objects/`, `records/`, `snapshots/`, `checkpoints/`, `rotations/`, `proofs/` | Immutable, content-addressed, and signed content | Never rewritten, never pruned on an origin |
| `indexes/` | Derived lookup aids | Rebuilt from the active snapshot at start |
| `audit/` | One record per mutating request | Not served, and never pruned by LWPT |

The TLS identity and password live outside the volume. Back them up in your
secret store.

**Consistent copies.** Publication writes every new file first and then
replaces the pointer atomically, and nothing an older pointer names is ever
removed. Any of these produces a restorable copy:

1. Stop the container, then copy the volume.
2. Copy **`registry.toml` and `state/` first**, then everything else, while
   the registry keeps serving. A publication that lands between the two
   steps only adds files that the copied pointer does not name. Startup
   recovery removes checkpoints and rotations ahead of the pointer.
3. Take a file-system or volume snapshot with the file system frozen
   (`fsfreeze`) or the registry stopped. LWPT's atomic writes survive a
   process crash, but they do not flush files to stable storage (ADR-0045).
   A snapshot of only what reached the disk has the same caveat as power
   loss.

**Restore.** Restore onto a volume owned by UID 10001, with permissions
preserved. Run `lwpt registry verify --data-dir <dir>` to confirm the
sequence, export the configuration again, then start the image. The first
start re-verifies the activated checkpoint, signature, and snapshot, reclaims
staging, and rebuilds indexes. To move the base URL or listener, follow the
[reconfiguration](#run-an-origin-with-direct-tls) steps. The identity is
kept.

**Rollback hazard.** A restored origin serves the sequence its backup
recorded. Consumers and mirrors that already accepted a later sequence
treat the older head as stale. When the restored origin publishes again, it
reuses sequence numbers that those clients have already seen with different
content, and they refuse the result as `checkpoint_equivocation`. Minimize
the window by backing up after every publication. A mirror that is ahead
keeps serving what it accepted. Protocol 1 has no fast-forward from a
mirror, so recovering those clients needs the maintainers' guidance.

A mirror is a verified copy of its origin. Restore it like an origin, or
re-initialize it and sync from scratch.

## Upgrades and the persisted schema

- **Procedure.** Back up, stop the old container (graceful), and start the
  new image tag on the same volume. The first start runs the same recovery
  and verification as any start. `registry init`, `serve`, `verify`, and
  `sync` need no migration step between releases that keep the schemas
  below.
- **Versioned documents.** The configuration
  (`lwpt-registry-origin-config-v1` or `-mirror-config-v1`), the activation
  pointer (`lwpt-registry-state-v1` or `-mirror-state-v1`), tokens
  (`lwpt-registry-token-v1`), audit records, and every protocol document
  carry a schema version.
- **Unknown schemas fail closed.** A binary that meets a configuration or
  state schema it does not know refuses to serve, verify, or sync with
  `state_corrupt: unsupported registry configuration schema` (or
  `... committed-state schema`) and changes no file. This is what a rollback
  to an older image looks like after a future release changes a persisted
  schema. Such a change needs its own ADR and migration notes. Keep the
  previous image tag and the pre-upgrade backup until the new version has
  served successfully.
- **Mixed versions.** Origins, mirrors, and clients of different releases
  interoperate while they speak protocol 1. A client fails clearly on a
  protocol or document schema it does not support, never by reinterpreting
  it ([`registry-spec.md`](./registry-spec.md#compatibility)).

## Operational limits

| Area | Limit | Source |
| --- | --- | --- |
| Connections | 32 concurrent; one HTTP/1.1 request per connection; one 10-second deadline for handshake, request, and response; 32 KiB of headers | [ADR-0043](./adr/0043-self-hosted-registry-origin.md) |
| Uploads | Archives up to 256 MiB, record bodies up to 64 KiB, two bodies in flight, a body deadline of 30 s plus 1 s per MiB | [ADR-0049](./adr/0049-registry-remote-publication.md) |
| Upload staging | Up to 1 GiB and 1,000 uncommitted uploads (507 beyond); completed, unreferenced uploads expire after one hour | ADR-0049 |
| Rate limits | 60 mutating requests per minute per token; 20 failed authentications per minute per peer address; in memory and reset on restart | ADR-0049 |
| Commits | Wait up to 5 s for the publication lease, then 503 with `Retry-After`; refused while the server clock is behind the active checkpoint | ADR-0049 |
| Tokens | Expire after 1 to 365 days (90 by default); at most 1,000 active | ADR-0049 |
| Checkpoints | Valid for exactly seven days; the origin renews with less than 24 hours left, at start or on the next request | ADR-0043, ADR-0045 |
| History | Verification walks the whole snapshot chain within 64 MiB of metadata, 10,000 documents, 10,000 snapshots, and 1,000 rotations | [`registry-spec.md`](./registry-spec.md#acquisition-and-locked-proof-verification) |
| Mirrors | 32 GiB store and 8 GiB per sync by default; two archive transfers at a time; 120 s per request; 60 minutes per sync | [ADR-0045](./adr/0045-verified-registry-mirror.md) |
| Storage growth | Objects, records, snapshots, checkpoints, and audit records are never pruned on an origin | ADR-0043, ADR-0049 |
| Addresses | Portable listeners are IPv4 only (IPv6 only on macOS 26 and newer); clients connect over IPv4 only | ADR-0043, ADR-0045 |

The history budget is the binding long-term limit. Every snapshot lists
every current record, about 75 bytes each, and publication, synchronization,
and installation verify the whole chain. The 64 MiB budget is therefore
reached after roughly 1,300 published versions or yank changes on one
origin. This figure is estimated from the document sizes, not measured.
Beyond it, the origin refuses the publication that would exceed the budget.
Verification time grows with history too. Plan capacity accordingly. A
retention or checkpointed-history design would need a protocol change.

## Portability assumptions

- **Wire protocol.** Canonical UTF-8 TOML with LF line endings, SHA-256
  content addresses, canonical URLs, and Ed25519 signatures computed in
  Pascal produce the same bytes on every platform. No protocol document
  contains an operating-system path.
- **Clients.** Publication, mirror synchronization and verification, and
  registry installs are supported on all six release targets. Registry
  clients connect over IPv4 and verify TLS against the platform trust store:
  SChannel on Windows, Secure Transport on macOS, and OpenSSL on Linux.
  `lwpt install` additionally requires HTTPS contacts on globally reachable
  addresses. A registry on a private network is not yet usable as a
  dependency source
  ([#313](https://github.com/frostney/lwpt/issues/313) tracks a user-level
  allowance). `registry publish` and mirror `sync` accept private
  addresses.
- **Service.** The supported service deployment is a Linux container on
  x86-64, which CI builds and smokes. The image also selects the
  `linux-arm64` archive, but CI does not build that variant. `registry
  serve` runs natively on macOS and Windows, and the E2E suites exercise its
  listener and TLS there, but this guide covers only Linux containers. A
  hard-killed Windows server can leave its CNG key container behind. A
  macOS server recovers its temporary keychain at the next start.
- **Storage.** The data directory must be on a local file system that
  provides atomic rename within the directory and operating-system advisory
  locks, with no symbolic links in any registry path. Network and shared
  file systems are not supported. Private files rely on POSIX mode `0600` or
  a Windows owner ACL. Restore a data directory onto the same operating
  system family. Cross-OS moves are untested.
- **Time.** Run a synchronized UTC clock. Origins refuse to commit while
  their clock is behind the active checkpoint, and mirrors refuse to sync
  while theirs is behind the accepted clock floor. Containers share the
  host's clock.

## What CI proves

| Evidence | Where | Platforms |
| --- | --- | --- |
| Registry E2E matrix: localhost HTTP development with live publication, reads, install, and restart; mirror sync, outage serving, and failover both ways; a publication crashed before activation and its recovery; key rotation while serving; HTTPS by host name and by IP address; future schemas failing closed; pointer-first backup, restore, and the refused rollback; an origin start that recovers from a taken port with its identity unchanged | [`tests/e2e/RegistryMatrix.E2E.Test.pas`](../tests/e2e/RegistryMatrix.E2E.Test.pas) in every `ci.yml` E2E run; a failing case uploads its scratch directory | All six release targets (Linux, macOS, and Windows runners) |
| Container smoke: a wrong pin fails the build; the image runs as UID 10001 with a read-only root and configuration that the service account cannot write, replace, or remove; health check; token issuance and key rotation in the serving container; live publication from the runner; graceful stop, the reconfiguration procedure, container replacement, and data survival; the re-encrypting nginx proxy | [`.github/ci/registry-container/smoke.sh`](../.github/ci/registry-container/smoke.sh): `ci.yml` job `registry-container` on the binary under test, and `release.yml` job `registry-container-smoke` on the published assets | Linux x86-64 |

The E2E matrix trusts the committed test root through the test build only,
so HTTPS consumers and mirrors are exercised over localhost HTTP. The
container smoke is off the automatic PR gate because it needs Docker and
image pulls. See [`ci.md`](./ci.md).
