# syntax=docker/dockerfile:1
#
# Example image for a self-hosted LWPT registry origin or mirror.
#
# This file is deployment documentation, not a build system. It installs a
# released `lwpt` binary, verified against a SHA-256 you pin, and never
# compiles LWPT; `./build/lwpt build` remains the only way LWPT builds
# itself. The operating guide is docs/registry-deployment.md.
#
# Build (the digests are in the release's lwpt-<version>-checksums.txt):
#
#   docker build \
#     --build-arg LWPT_VERSION=<version> \
#     --build-arg LWPT_SHA256_LINUX_X64=<sha256 of lwpt-<version>-linux-x64.tar.gz> \
#     --build-arg LWPT_SHA256_LINUX_ARM64=<sha256 of lwpt-<version>-linux-arm64.tar.gz> \
#     -t lwpt-registry:<version> docs/examples/registry
#
# The image holds no credentials, keys, or TLS identities. The data volume
# holds the registry; secrets and a read-only copy of registry.toml are
# mounted at run time.

# Pin the base image by digest in production (debian:bookworm-slim@sha256:...).
# The release binary links glibc and loads OpenSSL 3 at run time for TLS.
ARG BASE_IMAGE=debian:bookworm-slim

FROM ${BASE_IMAGE} AS fetch
ARG LWPT_VERSION=""
ARG LWPT_SHA256_LINUX_X64=""
ARG LWPT_SHA256_LINUX_ARM64=""
# CI overrides this with a loopback server holding a release-shaped archive
# of the exact commit under test; the checksum pin is the integrity check.
ARG LWPT_RELEASE_BASE_URL=https://github.com/frostney/lwpt/releases/download
# Release tags are the bare version (0.8.0); set this only for a v-prefixed tag.
ARG LWPT_RELEASE_TAG=""
ARG TARGETARCH
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    if [ -z "${LWPT_VERSION}" ]; then \
      echo "set --build-arg LWPT_VERSION to a released version" >&2; exit 1; \
    fi; \
    case "${TARGETARCH:-amd64}" in \
      amd64) platform=linux-x64; digest="${LWPT_SHA256_LINUX_X64}" ;; \
      arm64) platform=linux-arm64; digest="${LWPT_SHA256_LINUX_ARM64}" ;; \
      *) echo "no LWPT release archive for ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="lwpt-${LWPT_VERSION}-${platform}.tar.gz"; \
    if ! printf '%s' "${digest}" | grep -Eq '^[0-9a-f]{64}$'; then \
      echo "pin the SHA-256 of ${archive} (LWPT_SHA256_LINUX_X64 or _ARM64)" >&2; \
      exit 1; \
    fi; \
    curl --fail --silent --show-error --location --retry 3 \
      --output "/tmp/${archive}" \
      "${LWPT_RELEASE_BASE_URL}/${LWPT_RELEASE_TAG:-${LWPT_VERSION}}/${archive}"; \
    echo "${digest}  /tmp/${archive}" | sha256sum --check --strict -; \
    tar -xzf "/tmp/${archive}" -C /tmp; \
    install -D -m 0555 "/tmp/lwpt-${LWPT_VERSION}-${platform}/lwpt" /out/lwpt; \
    test "$(/out/lwpt --version | head -n 1)" = "lwpt ${LWPT_VERSION}"

FROM ${BASE_IMAGE}
# curl serves only the health check; libssl3 is the TLS runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 lwpt \
    && useradd --system --uid 10001 --gid 10001 --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin lwpt \
    && install -d -o 10001 -g 10001 -m 0700 /var/lib/lwpt-registry
# Root-owned and read-only: the service account cannot replace them.
COPY --from=fetch --chmod=0555 /out/lwpt /usr/local/bin/lwpt
COPY --chmod=0555 entrypoint.sh /usr/local/bin/lwpt-registry-entrypoint
COPY --chmod=0555 healthcheck.sh /usr/local/bin/lwpt-registry-healthcheck
ENV LWPT_REGISTRY_DATA=/var/lib/lwpt-registry
# One service account owns the data directory (ADR-0045 trust boundary).
USER 10001:10001
WORKDIR /var/lib/lwpt-registry
VOLUME ["/var/lib/lwpt-registry"]
EXPOSE 8443
# `registry serve` stops gracefully on SIGTERM: it stops accepting, cancels
# in-flight connections, drains its workers, and exits 0. Allow at least 15
# seconds (docker run --stop-timeout 15) before the runtime sends SIGKILL.
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD ["/usr/local/bin/lwpt-registry-healthcheck"]
# Exec form: lwpt runs as PID 1 and receives the stop signal itself.
ENTRYPOINT ["/usr/local/bin/lwpt-registry-entrypoint"]
CMD ["registry", "serve", "--data-dir", "/var/lib/lwpt-registry"]
