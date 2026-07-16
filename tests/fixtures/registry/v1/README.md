# Registry protocol v1 conformance corpus

This directory is the deterministic corpus for
[`docs/registry-spec.md`](../../../../docs/registry-spec.md).

All `.toml` payloads are canonical protocol bytes. Files under `objects/` use a
`.hex` suffix so the binary gzip archives remain reviewable: remove ASCII
whitespace and decode lowercase hexadecimal to obtain the exact HTTP body.
The decoded filename is the SHA-256 of those bytes.

The keys and signatures use public RFC 8032 test-vector material. They are test
data, not credentials. No private key is included.

## Valid chain

1. `checkpoints/1.toml` authenticates `snapshots/<hash>.toml` with the root key.
2. `rotations/2.toml` is signed by both the trusted root key and the new key.
3. `checkpoints/2.toml` authenticates the second snapshot with the new key.
4. A fresh client at checkpoint 2 walks its snapshot's `previous` hash back to
   snapshot 1 without relying on historical checkpoints.
5. Checkpoint 3 authenticates a package with local and cross-origin SemVer
   constraints.
6. Checkpoints 4 and 5 authenticate yank and restore replacement records.
7. Every snapshot contains exactly one record per package identity, and each
   record and archive object verifies by SHA-256.

## Required results

The cases in `cases.toml` are normative. A conforming client accepts all
`valid` entries and rejects each `invalid` entry with the named stable reason.
The invalid-signature case preserves the canonical checkpoint and matching
payload hash while corrupting only the Ed25519 signature, so conformance
requires cryptographic signature verification rather than hash checks alone.

The downgrade case is stateful: after accepting checkpoint sequence 2, serving
the otherwise valid sequence-1 checkpoint must fail with
`checkpoint_downgrade`.

## Endpoint fixture map

| Protocol resource | Fixture |
| --- | --- |
| Discovery | `discovery-origin.toml`, `discovery-mirror.toml` |
| Capabilities | `capabilities-origin.toml`, `capabilities-mirror.toml` |
| Public keys | `keys/root.toml`, `keys/rotated.toml` |
| Package records | `records/<sha256>.toml` |
| Archive objects | `objects/<sha256>.hex` |
| Snapshots | `snapshots/<sha256>.toml` |
| Checkpoints + signatures | `checkpoints/<sequence>.toml`, `checkpoints/<sequence>.sig.toml` |
| Key rotation | `rotations/2.toml`, `rotations/2.old.sig.toml`, `rotations/2.new.sig.toml` |
| Rotation discovery | `pages/rotations.toml` |
| Package listing | `pages/packages.toml`, `pages/packages-first.toml`, `pages/packages-second.toml`, `pages/package-example-lib.toml` |
| Endpoint contract | `endpoint-cases.toml` |
| Error and idempotency outcomes | `outcome-cases.toml`, `errors/*.toml` |
| Publication | The valid object and package-record bodies above plus `requests/package-missing-archive.toml` |
| Yank and restore | The records and snapshots dated `2026-01-04` and `2026-01-05` |
| URI validation | `uri-cases.toml`, `invalid/discovery-http-ip.toml` |
