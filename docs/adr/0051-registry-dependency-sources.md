# Registry dependency sources

> **Amended by [ADR-0052](./0052-lockfile-schema-v4-framed-tree-digest.md):** `computedHash` is the framed `sha256-tree2` digest of lockfile schema v4, and `--frozen` step 4 relies on digest equality between the re-derived tree, the installed tree, and `computedHash`; the file-for-file comparison only names the first difference. The registry fields and decision 11 are unchanged. The considered option "Lockfile schema v4. Rejected" stays as history: its rejection concerned the registry fields, which remain additive, and only this record's closing claim that v3 stays the last schema break is superseded.
>
> **Amended 2026-10-03 ([#345](https://github.com/frostney/lwpt/issues/345)), per-user document store eviction:** Per-user accepted-state files are never evicted, and no command removes them; "Per-user consumer state lives outside the cache and is not evicted" below means those files. The per-user document store beside them is bounded. Documents outside every stored state's current accepted history are evicted least recently used once their bytes exceed `LWPT_REGISTRY_STATE_MAX_BYTES` (default 64 MiB, the verifier's cumulative metadata limit). These are checkpoints the accepted head has replaced and their signatures, and documents of deleted states. The accepted history is the accepted checkpoint and its signatures, the snapshot chain through `previous`, every record those snapshots name, and the accepted rotations; it is never evicted. Re-pinning alone does not make an old history evictable: the old pin's state file remains, and its history stays live until that file is deleted. Any uncertainty about the live set removes nothing, including a broken chain link (a missing, unreadable, or corrupt accepted snapshot), an unreadable state file, or a directory that cannot be listed completely. Limitation: a lock whose selection proof lags the accepted head keeps its checkpoint and signature in the store only by recency, so `--offline` restore of those two documents after eviction needs their committed copies; the lock's snapshot, records, and rotations lie on the accepted history and stay restorable. `lwpt repair` reports the store and removes nothing from it.

## Status

Accepted on 2026-09-29 by the maintainer, who settled the ten decisions at
the end of this record as recommended, and added an eleventh on what the lock
records about accepted state after review. Issue
[#62](https://github.com/frostney/lwpt/issues/62). The implementation PR
applies the amendments listed under "Rule amendments"; this record does not
edit other documents. It completes the deferral recorded in
[ADR-0004](0004-http-registry-deferred-to-v2.md), amends
[ADR-0009](0009-source-syntax-and-tag-resolution.md) (a new source kind and
manifest section), [ADR-0048](0048-git-host-fetch-trust.md) (registry
destinations), and [ADR-0049](0049-registry-remote-publication.md) (its
decision 4), and specifies the consumer side of the
[registry protocol](../registry-spec.md). It also covers the registry half of
[issue #226](https://github.com/frostney/lwpt/issues/226).

## Executive Summary

- A dependency names a registry package as `registry:<package>@<range>` (the
  default registry) or `registry:<alias>/<package>@<range>`. The root
  manifest's `[registries]` table maps each alias to an origin identity, a
  pinned Ed25519 root key, an origin contact, and ordered mirrors.
- Package identity is `(origin identity, name, version)`. Contact URLs never
  enter identity, so moving an origin or changing mirrors changes no lock
  identity. A trust pin comes only from `lwpt.toml`. A signed rotation extends
  trust from the pin without editing it, and nothing is trusted on first use.
- An online install makes one verified acquisition per origin. It tries the
  contacts in order and moves to the next contact after a request failure or a
  stale contact. A trust failure aborts the install. Versions are selected
  from the authenticated snapshot through the existing graph-wide resolver.
- `lwpt.lock` stays schema v3. Registry entries add optional fields, and a
  per-origin table records the checkpoint that the selection was verified
  against. The signed documents that prove inclusion are committed next to
  the archives. `--frozen` and `--offline` then verify registry identity
  offline from the manifest pin, re-derive each module tree from its
  authenticated archive, and never construct a transport.
- Accepted registry state and the clock-rollback floor live in two places:
  per-user state, which rises monotonically across projects, and the lock's
  per-origin table, which covers fresh machines and CI. Acquisition must
  extend both.

## Context

Registry servers, mirrors, and publication exist; nothing lets a dependency
consume them. As of `fb5c7d3`:

| Shipped | Where |
| --- | --- |
| Source kinds `skGitHost`, `skURL`, `skLocal`, `skWorkspace`; host kinds including `hkCustom` | `source/LWPT.Manifest.pas:49`, `:57` |
| Source parsing: `https://`, paths, `local:`, `workspace:`, `gitlab:`, `bitbucket:`, `github:`, a `[sources.<name>]` prefix, else `owner/repo`; unknown prefix is an error in manifests and `hkCustom` in lockfiles (permissive mode) | `LWPT.Manifest.pas:427-533`, permissive branch `:509-515`, error `:516-521` |
| Bare shorthand splits on the last `@`; the inline table takes `source`, `version`, `include`, `exclude`; legacy keys hard-error | `LWPT.Manifest.pas:665-714`, `:772-836` |
| Version kinds: SemVer range, exact SemVer, commit SHA, literal tag, none | `LWPT.Manifest.pas:110`, `:579-610` |
| `[sources]` names that shadow `github`, `gitlab`, `bitbucket`, or `local` are rejected | `LWPT.Manifest.pas:1443-1450` |
| Unknown top-level sections without `command` warn and are dropped | `LWPT.Manifest.pas:1924` |
| Graph nodes are keyed by package name; requirements naming different canonical sources for one name are a conflict | `LWPT.Install.pas:2519-2555`, `:2713`, `:3037` |
| Canonical source identity per kind plus extraction policy | `LWPT.Install.pas:2341-2389` |
| Highest-tag selection over the whole accumulated requirement set (git refs only) | `source/LWPT.Resolver.pas:125-219` |
| Fixed-point materializing resolution; offline selects locked nodes for network-backed kinds; a failed ref listing reuses a satisfying lock entry | `LWPT.Install.pas:2783`, `:2903-2933`, `:3333-3336`, `:3396-3420` |
| Offline archive staging from the committed archive or the per-user CAS, then whole-graph lock comparison with the lock left byte-identical | `LWPT.Install.pas:2935-2994`, `:4052-4137`, `:4508-4509` |
| Frozen walk reads modules only, then compares identity, fingerprint, constraints, archive, and tree hashes | `LWPT.Install.pas:2646-2776`, `:4376-4503` |
| `--offline` and `--frozen` are mutually exclusive; `--accept-moved-tags` excludes both | `source/lwpt.pas:171-203` |
| Per-user archive CAS keyed by raw SHA-256 (`dependency-archives` namespace) | `source/LWPT.ObjectStore.pas:19-20`, `:79`; [ADR-0036](0036-per-user-dependency-archive-cas.md) |
| Destination policy: HTTPS, declared hosts, non-global addresses refused on every hop | `source/LWPT.FetchPolicy.pas:112-142` |
| Archive response cap of 256 MiB | `LWPT.Install.pas:165` |
| Registry verifier: `VerifyRegistryProof` in `rvmAcquire` or `rvmLockedProof` mode, `VerifyRegistryArtifact`, discovery and capability validation, trust-root and URI checks | `source/LWPT.Registry.Verification.pas:120`, `:196-203`, `:141-165` |
| Clock-rollback floor check (`local_clock_behind_accepted_state`), applied only in acquisition mode | `Verification.pas:426-434`, `:1477` |
| `ELWPTRegistryStaleContactError` for downgrade, expiry, and renewal rollback, raised only after every trust check | `Verification.pas:34`, `:1595-1607` |
| History verification always walks to sequence 1, reading every snapshot and every unique record, and requires the prior accepted snapshot to be on the path | `Verification.pas:1303-1396` (`:1339`, `:1386`, `:1394`) |
| Locked-proof mode requires the recorded checkpoint hash and sequence, then still verifies full history | `Verification.pas:1478-1489`, `:1587-1593` |
| Default limits: 4 MiB per document, 64 MiB total, 10,000 documents, 10,000 snapshots, 1,000 rotations | `Verification.pas:1185-1192` |
| Mirror acquisition: discovery scope checks, checkpoint/signature pair retry, key record, rotation pages, localhost pinned to `127.0.0.1`, no redirects, per-request deadline | `source/LWPT.Registry.Mirror.pas:127-138`, `:240-334`, `:1067-1250` |

### Lockfile parser facts

These facts decide whether registry entries can extend schema v3:

- `LoadLockfile` requires an integer `version` equal to exactly 3
  (`LWPT.Install.pas:2072-2082`).
- It reads only the `version` key and the `[package]` table. Any other
  top-level key or table is ignored.
- Inside `[package]`, children that are not tables are skipped (`:2091`).
- Each entry is read key by key with defaults (`:2094-2104`), so unknown keys
  are ignored. [ADR-0031](0031-fixed-point-single-version-resolution.md),
  [ADR-0047](0047-commit-pins-must-be-reachable.md), and
  [ADR-0048](0048-git-host-fetch-trust.md) already added optional fields this
  way. [ADR-0008](0008-lockfile-schema-v2-archive-hash.md) anticipated the
  pattern.
- An unknown `source` prefix is accepted as a custom git host
  (`:2111-2116`). An older binary would misread a `registry:` lock entry.
  It never gets that far: it parses the manifest first, and the manifest
  parser rejects the unknown prefix (`LWPT.Manifest.pas:516-521`). This holds
  for the root, workspace members, and child manifests that the frozen walk
  loads (`LWPT.Install.pas:2746-2773`).
- The TOML package supports quoted keys and arrays of tables
  (`packages/toml/source/TOML.pas:943-970`, `:48`).

### What is missing

- **No registry source kind or consumer configuration.**
- **No executable contact selection or failover.** The protocol
  specification defines the policy
  ([Client contact selection and failover](../registry-spec.md#client-contact-selection-and-failover)).
  The mirror uses exactly one upstream.
- **Acquisition exists only inside the mirror.** `Synchronize` is coupled to
  the mirror store and its budgets.
- **No consumer-side accepted state.** Issue
  [#320](https://github.com/frostney/lwpt/issues/320) left the consumer's
  clock floor to this issue, and ADR-0049 left cross-invocation history to
  this issue's "consumer trust store".
- **No offline verification shape for a consumer.** The shipped locked-proof
  mode needs the complete snapshot history. A consumer project does not
  retain it.
- **Remote publication is accepted but not implemented.** ADR-0049 is
  accepted, but `registry publish` does not exist yet: the CLI offers
  `init|sync|verify|rotate-key|serve` (`source/lwpt.pas:916`), and the
  in-process `Publish` hard-codes `dependencies = []`
  (`source/LWPT.Registry.Store.pas:2986`). ADR-0049 decision 4, which
  refuses archives whose `lwpt.toml` declares `[dependencies]` until this
  ADR defines registry dependency sources, is therefore an accepted contract
  still pending implementation under
  [#54](https://github.com/frostney/lwpt/issues/54).
- **`install --offline` does not yet cover registry dependencies.** It shipped
  in PR #283 for git-host, direct-URL, local, and workspace dependencies
  (`tests/integration/InstallGitGraph.Test.pas:41-65`). The PR left
  registry-backed acceptance to #62, and it must enter the locked offline
  path before any registry client is constructed.

## Decision

### Manifest source syntax

```toml
[dependencies]
json   = "registry:json@^1.2.0"          # the default registry
http   = "registry:corp/http@~2.0.0"     # an explicit registry alias
extras = { source = "registry:corp/extras", version = "^0.3.0", include = ["source/**"] }
```

- **Grammar (decision 1).** `registry:<package>` or
  `registry:<alias>/<package>`. The kind is visible in the string, as
  ADR-0009 requires, and the bare-string and inline-table forms share one
  parser.
  - The package segment uses the consumer package grammar
    `[a-z0-9][a-z0-9_-]{0,127}`. This is the protocol grammar without `.`
    (see decision 6).
  - An alias matches `[a-z0-9][a-z0-9_-]{0,63}`. The alias `default` is
    reserved.
- **Versions.** Only SemVer ranges and exact SemVer versions are accepted,
  and they are matched against canonical registry versions. A `v`-prefixed
  spec, a commit SHA, and a literal tag fail at manifest load with a message
  saying that registry versions are SemVer without `v`. An omitted version
  means any version, subject to the yank rule.
- **Name.** The dependency key must equal the registry package name. A graph
  slot and a `.lwpt/modules/<name>/` directory therefore name exactly one
  `(origin, name)`. A transitive record dependency on the same package merges
  into the same node, not into a second copy of the same units.
- **Reserved prefix.** `registry` joins the prefixes that `[sources]` may
  not shadow (`LWPT.Manifest.pas:1446`).
- **Extraction policy.** `include` and `exclude` behave as for other kinds
  and remain part of the canonical source identity.
- **Where registry dependencies may be declared.** They may be declared in
  the root manifest and in workspace members. The dependencies of a registry
  package come from its signed record, not from the archive's `lwpt.toml`.
  The manifest of a git-host, URL, or local package that declares a
  `registry:` dependency fails with an actionable error in this version (see
  decision 5).

### Registry declarations

```toml
[registries]
default = "corp"                                     # optional with exactly one registry

[registries.corp]
identity   = "https://packages.example.com"          # optional; see precedence level 3
key-id     = "ed25519:<64 hex digits>"
public-key = "hex:<64 hex digits>"
origin     = "https://packages.example.com"          # origin contact; defaults to identity
mirrors    = ["https://mirror.example.net/lwpt"]     # tried first, in this order
```

- **Root-only.** `[registries]` is read from the root manifest only. It is
  the same supply-chain stance as hooks, workspaces, and compiler profiles.
  - A workspace member's own `[registries]` is used when that member is
    published (see below). During an install, its aliases resolve through
    the root.
  - An alias that is defined in both the root and a workspace member must
    have the same identity and pin. Otherwise loading fails.
- **Validation.** Every value is checked at load. The manifest schema
  registry marks the section root-only, invalid values as errors, and
  unknown keys as errors.
  - `key-id` and `public-key` must pass `RegistryTrustRootIsValid`.
  - `identity`, `origin`, and each mirror must be canonical protocol URIs
    (`RegistryURIIsCanonical`) using `https`.
  - Bracketed IPv6 hosts are rejected, because HTTPClient dials IPv4 only
    (the ADR-0045 precedent).
  - Duplicate contacts are rejected.
  - One identity may appear under only one alias.
  - `origin` is required when `identity` is omitted.
- **No secrets and no machine-local data.** Protocol 1 reads are
  unauthenticated, so there is no credential to store. Machine-local
  contacts, private-network allowances, and TLS trust anchors belong to the
  user-level configuration of [#313](https://github.com/frostney/lwpt/issues/313),
  never to `lwpt.toml` (decision 9).

### Effective origin precedence

The effective origin of a registry dependency is resolved in this order:

1. **Dependency declaration.** For a record dependency, the dependency's
   `origin` is used. When the dependency omits `origin`, the record's own
   origin is used, as the protocol requires. For a manifest dependency, the
   alias in `registry:<alias>/<package>` is used.
2. **Consumer registry configuration.** The root's `[registries].default` is
   used, or the only declared registry when there is exactly one.
3. **Endpoint-advertised default.** This applies when the selected
   declaration omits `identity`. The identity is then the `origin` that the
   declaration's contacts advertise in their discovery documents. It is
   accepted only after a checkpoint that verifies through the configured pin
   names the same origin. It is then recorded in `lwpt.lock`. A later
   advertisement of a different identity is a hard error that tells the
   user to declare `identity`, never a replacement (decision 2).
4. **Otherwise** resolution fails with an actionable error:
   - "`json` uses `registry:json` but no registry is declared; add
     `[registries.<alias>]`";
   - "registries `corp` and `oss` are declared and no default is set; write
     `registry:<alias>/json` or set `[registries] default`";
   - "`util` is required by `json@1.2.0` from `https://a`, but origin
     `https://b` is not declared; add a `[registries.<alias>]` with its
     identity and key".

A record's origin is matched against declared identities, and against
advertised identities that are already established in the same transaction
or recorded in the lock. A record can never introduce a trust pin.

### Trust persistence and rotation

- **Pin location.** The pin is part of reviewed project configuration in
  `lwpt.toml`.
  - `lwpt.lock` records only the pinned key ID, as evidence.
  - User configuration may add contacts but never pins, so a local file
    cannot change what a project trusts.
  - A missing pin is an error. Nothing is trusted on first use.
- **Rotation needs no edit.** Signed rotations
  ([ADR-0045](0045-verified-registry-mirror.md)) extend trust from the pin
  through `VerifyRegistryProof`. The current key and the rotation triplet
  hashes are part of the accepted state and of the lock's per-origin table.
  The committed proof carries their exact bytes.
- **Changing the pin is a human edit, visible in review**, used to recover
  from key compromise or re-initialization.
  - `--frozen` and `--offline` fail with "trust pin for `<identity>` changed;
    run `lwpt install` online".
  - An online install verifies from the new pin and rewrites that origin's
    lock table.
  - A key change that is not reachable from the pin through a signed chain
    is a trust failure. It never re-pins.

### Accepted state and the clock-rollback floor

The protocol requires the highest accepted sequence, the trusted key state,
and the clock floor to be persisted per origin identity. This ADR keeps two
records (decision 3):

- **Per-user consumer state.** Acquisition uses it to protect against
  downgrades and clock rollback.
  - One file per `(identity, pinned root key ID)` holds the
    `lwpt-registry-consumer-state-v1` document. It records the accepted key,
    the sequence, the snapshot, the checkpoint hash, `published_at`,
    `expires_at`, `clock_floor`, and the rotation triplet hashes.
  - The file lives under the per-user configuration root that worker state
    already uses (`GetAppConfigDir`; `LWPT.WorkerBudget.pas:425-426`), not
    under the disposable cache.
  - `LWPT_REGISTRY_STATE_DIR` overrides the location, as
    `LWPT_WORKER_STATE_DIR` does, for CI and test isolation.
  - Updates take a per-user producer lease
    ([ADR-0038](0038-local-producer-leases.md)), merge monotonically (the
    sequence and floor never go down), and replace the file atomically
    inside the state directory.
  - Keying by the pin as well as the identity prevents a project with a
    stale pin from poisoning another project's state.
  - This is the only record of the true high-water mark: the highest
    accepted sequence and the highest `published_at` ever accepted.
- **Project lock state.** The lock's per-origin table holds two separate
  things (see "Lockfile representation"):
  - the **selection proof**: the checkpoint that the current selection was
    verified against, backed by committed documents; and
  - the **recorded accepted state**: the merged accepted state, meaning
    sequence, snapshot, checkpoint hash, key, times, and `clockFloor`,
    captured the last time the lock changed (decision 11).

  They differ because acquisition can advance without changing the
  selection, and because a later checkpoint may carry an earlier
  `published_at` while the floor keeps the historical maximum
  (`registry-spec.md:444-457`; `Verification.pas:1616`). The recorded
  accepted state is not the highest state ever accepted: it lags whenever
  acquisitions advance without any other lock change. On a machine with no
  per-user state, such as fresh CI, it is the prior.
- **Acquisition prior.** It is the newer of the per-user state and the
  lock's recorded accepted state, and the new head must extend both, as
  well as the selection proof's snapshot. Each must lie on its verified
  history, or the result is `checkpoint_equivocation`. The clock floor is
  the later of the per-user `clock_floor` and the lock's `clockFloor`.
- **Fresh-CI limitation.** A machine with empty per-user state knows only
  the lock's recorded accepted state. A stale or withholding contact can
  therefore serve it any authentic checkpoint at or above the recorded
  sequence, hiding publications newer than that checkpoint. The window is
  bounded by the maximum checkpoint lifetime from
  [#320](https://github.com/frostney/lwpt/issues/320): an accepted
  checkpoint was published at most seven days plus five minutes of skew
  before the machine's clock, and an older one is stale. The contact can
  never downgrade below the recorded sequence, and can never cause a
  selection below the locked one, because the new head must extend both the
  recorded state and the selection proof. This is the protocol's bound for a
  client without prior state.
- **What the lock can and cannot prove.** The recorded accepted-state fields are
  unsigned, trusted project state, like the rest of the lock. Editing them
  can only weaken protection for that checkout or cause a denial of
  service; it cannot introduce trust, because keys must still be reached
  from the pin. Signatures also cannot detect a checkout whose proof
  documents and lock were replaced together by an older authentic pair: on
  fresh CI that older state verifies. The committed state supplies
  authenticity, not an independently remembered minimum. Reviewing lock
  diffs, and per-user state on long-lived machines, remain the controls for
  project-state rollback.
- **`--frozen` and `--offline`** apply neither the floor nor expiry. They
  follow the protocol's locked-proof exception.
- **Corrupt state.** Corrupt per-user state fails acquisition, naming the
  file. It is never reset silently, because a reset lowers the floor.
  `lwpt repair` leaves it alone.

### Acquisition, contact selection, and transparency

- **Contacts.** The contacts for a declaration are tried in this order:
  1. user-level mirrors (after #313), then
  2. manifest `mirrors` in declaration order, then
  3. the `origin` contact.

  Duplicates are removed by canonical URL. Every attempt uses the same
  expected identity, pin, and prior.
- **One attempt:**
  1. Discovery at `<contact>/.well-known/lwpt-registry`. Its `base_url`
     must equal the contact, and its `origin` must equal the expected
     identity or establish it (precedence level 3). Every service URL must
     stay under the contact and use only unambiguous segments (the
     `Mirror.pas:1108-1114`, `:1191-1194` rule).
  2. Capabilities, through `ValidateRegistryCapabilities`.
  3. The checkpoint and signature pair. It is re-read at most three times,
     and only while the checkpoint is advancing.
  4. The key record and rotation pages, when the checkpoint key is not yet
     trusted.
  5. `VerifyRegistryProof(rvmAcquire)` with the merged prior. The verifier
     reads snapshots and records through a document source that first
     consults a per-user `registry-documents` object store, keyed and
     re-verified by SHA-256. It then falls back to the same contact.
- **Classification** follows the protocol:
  - HTTPClient errors, non-2xx responses, any 3xx, and deadlines advance to
    the next contact.
  - `ELWPTRegistryStaleContactError` advances too.
  - `local_clock_behind_accepted_state` aborts before any request.
  - Every other failure aborts without trying another contact. This
    includes unsupported protocols, schemas, or capabilities.
  - When every contact is stale, the install fails with the stale
    diagnostic, which lists each contact.
  - When every contact fails at the request layer, the install reuses the
    locked selection for that origin's nodes, after verifying it from the
    committed proof as `--frozen` does, and warns (decision 8). It does so
    only while the locked version still satisfies every accumulated
    requirement. Otherwise, or with no lock entry, the fetch error lists
    each contact. A trust failure never falls back.
- **One head per origin.** An install acquires each origin once and caches
  the result across fixed-point rounds, so every dependency from that origin
  is selected from the same verified head.
- **Transparency** is a client contract on every release platform.
  - Inclusion: the selected record hash is in the signed head snapshot, its
    `archive` digest is the lock's `archiveHash`, and the archive bytes hash
    to it (`VerifyRegistryArtifact`).
  - Consistency: the head's history reaches the per-user and locked
    snapshots.
  - Ed25519 and SHA-256 are the in-tree Pascal implementations, so the
    verdicts are identical on all six release targets.
- **Shared client.** The acquisition code is extracted from
  `TLWPTRegistryMirror.Synchronize` into a shared registry client unit, which
  mirror synchronization and `registry publish` then reuse. The mirror keeps
  its single-upstream behavior.

### Resolution

- `LWPT.Resolver` gains `SelectHighestVersion`, which works on registry
  versions instead of git refs.
  - The candidates are the verified head's packages with the node's
    `(origin, name)`. Yanked records are excluded unless one is the locked
    selection (decision 7).
  - It picks the highest version that satisfies every accumulated
    requirement, whether from a manifest spec or a record constraint. It
    uses `Semver.Satisfies` with `DefaultSemverOptions`, so prerelease
    handling matches git tags.
  - An empty candidate set produces the existing complete-requirement-set
    conflict diagnostic.
- Registry nodes run inside the existing fixed-point rounds. Their edges come
  from signed records, which are available before any archive is downloaded,
  so discovering a registry candidate needs no extraction.
- A git-host and a registry dependency, or two origins, that share one
  package name are a conflict, through the existing canonical-source check.
  There is still one version of each package per graph.
- Package lists (`/v1/packages`) are never used for selection. They are an
  unauthenticated convenience view. The verified snapshot is the index.

### Fetching and materialization

- **Archive sources**, in order:
  1. the committed project archive, when the lock entry matches;
  2. the per-user CAS, looked up by the record's `archive` digest;
  3. the contact that produced the accepted proof, at
     `<api>/objects/sha256/<hex>`.

  The CAS lookup is safe without a prior lock entry, because the digest is
  signed. That extends ADR-0036's rule for registry nodes only. A fetch is
  capped at the signed `archive_size`, which is at most 256 MiB. Archive
  fetching never switches to another contact, as the protocol requires.
- **Checks.** `VerifyRegistryArtifact` runs before bytes are cached or
  extracted, and extraction uses the installer's existing protections. The
  extracted `lwpt.toml` `[package]` name and version must equal the record.
  Otherwise the failure is `registry_manifest_identity_mismatch`, a trust
  failure.
- **Publication.** Everything is staged below the plan root and published
  only after the whole graph validates
  ([ADR-0031](0031-fixed-point-single-version-resolution.md)). Verified
  archives are admitted to the CAS. The CAS key, the record `archive`, and
  the lock `archiveHash` are one identity.

### Lockfile representation (schema v3, additive)

Registry entries in `[package.<name>]`:

| Key | Value |
| --- | --- |
| `source` | Verbatim manifest string, for example `registry:corp/json`; a record-derived entry writes `registry:<name>` |
| `resolvedRef` | Selected canonical version |
| `registryOrigin` | Origin identity (new) |
| `registryRecord` | `sha256:` of the selected record bytes (new) |
| `resolvedURL` | Archive URL that the committed archive was fetched from. It is kept while `registryRecord` is unchanged, is informational, and is never compared |
| `sourceIdentity` | `registry\|<identity>\|<name>` plus extraction policy; no alias and no contact |
| `constraintFingerprint`, `computedHash`, `archiveHash` | As today; `archiveHash` equals the record's `archive` |

`resolvedCommit`, `resolvedRefKind`, and `reachableFrom` are omitted for
registry entries. One table per origin records the proof:

```toml
[registry."https://packages.example.com"]
trustKeyId = "ed25519:..."   # pinned root key
keyId = "ed25519:..."        # key that signed the checkpoint
sequence = 42
snapshot = "sha256:..."
checkpoint = "sha256:..."
signature = "sha256:..."
publishedAt = "2026-09-29T00:00:00Z"
expiresAt = "2026-10-06T00:00:00Z"
rotations = ["sha256:...", "sha256:...", "sha256:..."]  # document, old, new per rotation
acceptedSequence = 57                                   # recorded accepted state
acceptedSnapshot = "sha256:..."
acceptedCheckpoint = "sha256:..."
acceptedKeyId = "ed25519:..."
acceptedPublishedAt = "2026-10-20T00:00:00Z"
acceptedExpiresAt = "2026-10-27T00:00:00Z"
acceptedRotations = ["sha256:..."]
clockFloor = "2026-10-20T00:00:00Z"                    # floor at the last lock change
```

The keys from `keyId` through `rotations` are the selection proof. The
`accepted*` keys and `clockFloor` are the recorded accepted state, with the
same meaning as `TLWPTRegistryAcceptedState`, captured at the last lock
change. It is never behind the selection proof and never moves backwards,
but it may lag the per-user state, which alone carries the true high-water
mark.

- **When the selection proof changes.** An origin's selection proof and
  entries are carried forward byte for byte unless:
  - the set of selected records for that origin changes;
  - the pin changes; or
  - the retained proof fails verification.
- **When the recorded accepted state advances (decision 11).** The
  transaction first computes the new lock with every origin's recorded
  accepted state unchanged. If that lock differs from the old one in any
  byte, for any reason, it is written with every origin's recorded accepted
  state set to the merged maximum of the old lock, the per-user state, and
  this install's acquisitions. If it is byte-identical, the file is not
  written at all, even when acquisition advanced.

  Acquisition progress and checkpoint renewals alone therefore never
  rewrite the lock, while any lock change carries the project's floor
  forward. Per-user state still advances on every acquisition.
- **A yanked locked version.** When a locked version is yanked upstream and a
  re-record is needed, the entry takes the new record of the same identity.
  The archive and dependencies are the same, and `VerifyImmutablePackage`
  already enforces that (`Verification.pas:1285-1301`).
- **No schema bump.** This fits schema v3 for the reasons listed under
  "Lockfile parser facts":
  - The version gate is unchanged.
  - New entry keys and the `[registry]` table are ignored by current readers.
  - An older binary fails closed at manifest parse before it acts on a
    registry entry.
- **No legacy acceptance.** No earlier registry entries exist, so a registry
  entry that lacks `registryOrigin`, `registryRecord`, or its origin table is
  incompatible. `--frozen` and `--offline` fail, and an online install
  resolves again.

### Committed proof documents

- **Contents.** The exact bytes of each origin's checkpoint, signature
  envelope, rotation triplets, head snapshot, and selected records are
  committed. They live at
  `<archives-dir>/registry-proofs/sha256/<hex>.toml`, beside the archives
  (ADR-0002 zero-install). They also follow the `[lwpt] archives-dir`
  override.
- **What is not committed.** Key records and retrieval documents are not
  needed offline (ADR-0045).
- **Ownership.** The directory is a derived function of the lock. The
  install transaction:
  1. stages exactly the referenced set;
  2. publishes it with the lockfile and the cfg, with rollback retention; and
  3. removes unreferenced documents in the same transaction.

  `add` and `remove` inherit this behavior.
- **Size.** The head snapshot dominates, at about 80 bytes per published
  identity. It changes only when an origin's selection changes. Snapshots
  hold record hashes only, not package names.

### `--frozen`

`--frozen` stays network-free: no contact is selected and no transport is
constructed. It changes no committed state, lockfile, or cfg. For each
registry node it runs the existing identity, fingerprint, constraint,
archive, and tree checks, and in addition:

1. The manifest's pin for the node's origin has the same key ID as the lock's
   `trustKeyId`. When a declaration omits `identity`, the lock supplies the
   identity.
2. Each proof document exists under its hash name and hashes to it.
3. A new verifier entry, `VerifyRegistryLockedSelection`, checks the proof:
   - the checkpoint hash equals the lock's;
   - the signature verifies under the key that the committed rotation chain
     reaches from the pin;
   - the snapshot hash is the checkpoint's;
   - `registryRecord` is a member of that snapshot; and
   - the record's origin, name, version, and archive equal the lock.

   It walks no history (decision 4).
4. The installed module tree is authenticated, not only the archive. The
   existing tree check compares the installed tree with the lock's
   `computedHash` (`LWPT.Install.pas:4023`), which is unsigned: a pull
   request could edit a unit and recompute it. For each registry node,
   `--frozen` therefore extracts the proof-authenticated archive under the
   declared `include` and `exclude` policy into a private, uniquely named
   scratch directory below `.lwpt/tmp/`, hashes it with `HashTree`, and
   requires that hash to equal both the installed tree's hash and
   `computedHash`. The scratch directory is removed on exit. Frozen
   verification still skips the recovery and cleanup of other `tmp/`
   state, and an interrupted run's residue is reclaimed by the next
   materializing install or `lwpt repair`. No network is used.
5. The graph edges of a registry node come from its committed record. The
   frozen graph therefore equals the online one.
6. Expiry and the clock floor are not applied. An expired proof is reported
   for information only.

The same gap exists for git-host and direct-URL sources. There it is an
existing limitation by design: their `archiveHash` is unsigned too, so
re-deriving the tree from the archive would add no authenticity. Closing it
for those kinds is out of scope.

### `--offline` (#226)

Registry nodes take the existing locked path (`LWPT.Install.pas:3333`) before
any registry client exists. `--offline` runs the same verification as
`--frozen`, and then materializes the state:

- **Archives** come from the committed archive or the CAS.
- **Modules** are always re-extracted from the proof-authenticated archive
  under the declared extraction policy. The staged tree's hash must equal
  `computedHash`, and the staged tree replaces the installed one, so an
  edited unit is detected even when `computedHash` was recomputed to match.
- **Missing proof documents** come from the per-user `registry-documents`
  store, verified by hash, and are published with the modules and cfg.
- **The lockfile** is left byte-identical.
- **Failures.** A miss, corruption, pin drift, or manifest drift fails before
  publication, as for the other kinds.

### Network and TLS rules

- **Destination policy.** Each attempt uses HTTPClient with `AllowedHosts`
  set to the contact's host alone, `RequireHTTPS`, `papDeny`, and
  `MaximumRedirects = 0`.
- **Private addresses.** Manifest-declared contacts are public-only, as under
  ADR-0048. A contact on a private network follows #313's two-key rule: the
  root manifest declares the registry, and the user's configuration allows
  the exact host. A contact that user configuration supplies is
  user-authorized. Loopback, link-local, metadata, unspecified, and
  multicast addresses are always refused.
- **Plain HTTP** to `http://localhost` is accepted only in the
  `lwpt-testing` build (`INSTALL_TESTING`,
  [ADR-0044](0044-test-seams-only-in-test-builds.md)). It is dialled at
  `127.0.0.1` through `ConnectAddress` (`Mirror.pas:240-248`). A release
  build rejects the contact at manifest load with `insecure_transport`.
- **TLS** uses the system trust store by default. Trust anchors for a private
  certificate authority use the options in
  [PR #339](https://github.com/frostney/lwpt/pull/339)'s ADR-0050
  (`TrustAnchors`, anchors-only mode). They come from user configuration,
  keyed by the exact contact host, and never from `lwpt.toml` (decision 9).
  `InsecureSkipVerify` is never set. Redirects are off, so anchors never
  reach another authority.
- **Bounds.** Each request has a deadline (120 seconds, the mirror value).
  Each contact attempt has a bounded total budget, and the verifier's limits
  apply. All bounds are named constants.
- **Which commands use the network.** Registry traffic belongs to `install`,
  `add`, `remove`, and `update`, the install-class commands.

### Dependency-bearing publication

This lifts [ADR-0049](0049-registry-remote-publication.md) decision 4
(decision 10). It specifies behavior for `registry publish`, which ADR-0049
accepted but #54 has not yet implemented; that implementation is a
prerequisite for these rules and for the publication end-to-end tests.

- **Mapping.** `registry publish` maps the archive manifest's
  `[dependencies]` to record `dependencies`.
- **Only registry sources.** Every entry must be a `registry:` source.
  Anything else fails with `unsupported_dependencies`.
- **No extraction filters.** A protocol 1 record dependency carries only
  `origin`, `name`, and `version`, and the canonical decoder accepts exactly
  that (`Verification.pas:1026`). A dependency with `include` or `exclude`
  would lose its filter in the record, so consumers could install other
  units or hit source conflicts the publisher never saw. Such a dependency
  fails with `unsupported_dependencies`. Protocol 1 is not extended.
  Consumers therefore install record-derived dependencies unfiltered; a root
  dependency on the same package with its own filters has a different
  source identity and conflicts, as today.
- **Aliases.** They resolve through the archive manifest's own
  `[registries]`, which must declare `identity` explicitly. There is no
  endpoint-advertised identity at publish time.
- **Same origin.** A dependency on the publishing origin omits `origin`.
- **Constraints.** A constraint must already be in the protocol's canonical
  grammar (`RegistryConstraintIsCanonical`, `Verification.pas:470`). A
  non-canonical spec fails and names the canonical spelling. Publishing does
  not rewrite it.
- **Order.** Entries are sorted in protocol order.
- **Name.** `[package].name` must use the consumer package grammar
  (decision 6).

### Other commands

- **`add`.** `lwpt add registry:json@^1.2.0` derives the name from the
  package, and a different `--name` is an error. The manifest edit and the
  install-before-write ordering are unchanged
  ([ADR-0019](0019-add-remove-subcommands.md)).
- **`remove`.** Its lockfile-diff pruning also covers proof documents,
  through the derived-set rule.
- **`outdated` and `update`.** They skip registry dependencies, as they skip
  URL and local ones. Registry support is a follow-up issue.
- **`repair`.** It never touches per-user registry state.

## Rule amendments

ADRs and the specification are edited only by the implementation PR, so the
documents it touches describe shipped behavior. That PR must apply each
amendment below in the same change as the code it describes.

- **`docs/registry-spec.md`:**
  - **Locked-proof paragraph (decision 4).** Amend "Acquisition and locked
    proof verification". A consumer's locked selection proof verifies the
    checkpoint hash, the signature through the rotation chain from the pin,
    the snapshot hash, record membership, the record fields, and archive
    identity without retained history. The mirror's retained proof still
    verifies full history. Neither applies expiry or the clock floor.
  - **Trust roots and key rotation (decision 2).** The paragraph stating
    that initial trust pins an origin identity and a key out of band
    (`registry-spec.md:513-515`) gains a consumer exception: a consumer
    may pin only the key and take the identity that its contacts
    advertise, accepted only after a checkpoint that verifies through that
    key names it, and never replaced once locked. Mirrors keep the
    configured-identity requirement unchanged: `registry init --role
    mirror` still requires an explicit origin identity with the key.
  - **Contact selection and failover.** Contacts from user configuration
    precede manifest mirrors, and consumer acquisition follows no redirects:
    a 3xx is a request-layer failure.
  - **Implementation boundary.** Replace the sentence saying the protocol
    adds no source kind with a pointer to this ADR.
- **ADR-0049, decision 4 (lifted by decision 10).** Add an amendment note
  that dependency-bearing archives are accepted under "Dependency-bearing
  publication" above, and add the consumer package-name grammar (decision 6)
  to its archive contract.
- **ADR-0009 and ADR-0048.** Add amendment notes pointing here for the
  `registry:` source kind and `[registries]` section, and for the registry
  destination policy.
- **`AGENTS.md` Hard Constraints:**
  - **"Git sources use HTTP archive endpoints for content".** List
    `registry:` as a source kind, citing this ADR.
  - **"Zero-install by default".** Add `<archives-dir>/registry-proofs/` to
    committed state as a set derived from the lock.
  - **"All multi-step file writes go through `.lwpt/tmp/`".** Name proof
    documents as toolkit-owned committed state written through the atomic
    helpers, and per-user registry state as replaced atomically inside its
    own state directory.
  - **"`lwpt.lock` is machine-written, schema v3".** Add the additive
    registry fields and the per-origin `[registry."<identity>"]` table.
- **`AGENTS.md` Safety / Boundaries:**
  - **Committed state.** The install transaction, and its `add` and
    `remove` frontends, is the only writer of `registry-proofs/`, and removes
    unreferenced proof documents.
  - **"Network operations are explicit".** `install`, `add`, `remove`, and
    `update` reach registry contacts; `--frozen` and `--offline` never do.
- **`docs/architecture.md`.** Add the lockfile table rows, the
  `registry-proofs` layout row, and the `registry:` source rows.
- **Manifest schema registry.** Register `[registries]` and the `registry:`
  prefix, then regenerate the `lwpt agents` block.

## Test plan

Deterministic tests run in the `lwpt-testing` build against local
`registry serve` origins and mirrors (`tests/support/Tests.RegistryOrigin.pas`,
`Tests.RegistryServer.pas`) and the v1 conformance corpus. The CI matrix runs
them on all six release targets. Rows that publish through
`registry publish` depend on the #54 implementation of ADR-0049; until it
lands, consumer tests seed origins through the in-process test publisher.

| Acceptance criterion | Evidence |
| --- | --- |
| #62: a dependency selects a protocol-v1 origin explicitly | Integration: `registry:corp/json@^1` installs from a local origin. The lock records `registryOrigin`, `registryRecord`, and the origin table, and `lwpt.cfg` exposes the units. |
| #62: defaults follow the precedence; missing or ambiguous defaults fail | Manifest unit tests: `default` key, a single implied registry, two registries without a default, no registries, a reserved alias, a pin that fails validation. Integration: an omitted `identity` records the advertised identity; a later different advertisement fails without writing state; a record dependency on an undeclared origin fails with the declaration hint. |
| #62: one concrete version through the graph-wide resolver | `SelectHighestVersion` unit tests for ranges, exact versions, prereleases, yanks, and empty sets. Integration: a diamond where the root wants `^1` and a record wants `<1.3.0` selects `1.2.x`; an unsatisfiable set gives the complete conflict diagnostic; git and registry sources sharing a name conflict. |
| #62: origin and mirror URLs change without identity changes | Install, then change `origin` and `mirrors` and install again. `sourceIdentity`, `registryOrigin`, `registryRecord`, and the lock bytes are unchanged, and `--frozen` passes. |
| #62: identity, signatures, hashes, expiry, and sequence verified before state changes; tampered, downgraded, expired, conflicting, or unsupported state fails | Tamper matrix: a bad checkpoint signature, a record whose bytes do not match its hash, an archive whose bytes do not match its hash, an extracted manifest with the wrong identity, a checkpoint lifetime over the limit, a checkpoint from the future, a checkpoint older than the lock, same-sequence equivocation, a discovery naming another origin, an unsupported protocol, a missing capability. Each asserts that modules, archives, the lock, the cfg, proof documents, and per-user state are byte-identical. |
| #62 and #55: a verified mirror satisfies an install and keeps the origin identity | E2E: origin, then `registry sync` to a mirror, then stop the origin and install through the mirror. The lock names the origin identity, `resolvedURL` names the mirror, and the CAS object key equals the record `archive` and the lock `archiveHash`. |
| #55: contact selection and failover | Scripted contacts. A request failure or 3xx advances; an expired, older, or renewal-rolled-back contact advances; a trust failure on the first contact aborts, and the second contact receives zero requests; all-stale produces the stale diagnostic; all request failures reuse a satisfying locked selection with a warning and fail without one (decision 8); a clock behind the floor aborts before any request. The archive is fetched only from the contact that produced the accepted proof. |
| #54 amendment: inclusion, consistency, stale checkpoints, malformed proofs, offline and frozen | A record missing from the head snapshot fails. A head that does not extend the per-user or locked snapshot is `checkpoint_equivocation`. Non-canonical documents and malformed envelopes are rejected. Stale-checkpoint cases are covered above; offline and frozen cases below. |
| #62: the lock records enough for network-free frozen verification | Clone the project into a fresh directory with an empty cache and state directory; `--frozen` passes with a transport seam counting zero requests. |
| #62: `--frozen` succeeds offline and fails on drift | Each mutation fails with its named error and changes nothing: flipping an archive byte, editing a module file, editing `registryRecord`, `checkpoint`, or `trustKeyId`, flipping a byte in a proof document, deleting a proof document, changing the manifest pin, schema version 2. A coordinated tamper, editing a unit under `.lwpt/modules/json` and recomputing `computedHash` to match, fails because the tree re-extracted from the authenticated archive differs; the same tamper under `--offline` fails before publication. An expired proof still passes. |
| #62: every client platform; localhost HTTP test-only; remote HTTPS | Six-target CI. A release-build test rejects an `http://localhost` contact at load, and an `http://` non-localhost contact is rejected in both builds. The HTTPS path uses the committed test root through the test-only anchor seam (ADR-0049 decision 7). |
| #62: existing behavior unchanged | The existing install, offline, frozen, and commit-pin suites pass unchanged, and lock bytes for projects without registry dependencies are golden-compared. |
| #62: the ADR records syntax, defaults, trust, and schema | This ADR. |
| #226: restored from the shared cache without network | A registry lock with a deleted committed archive restores from the CAS with zero transport requests. |
| #226: committed archives satisfy offline installs without the cache | An empty cache directory, restored from committed archives and proofs. |
| #226: missing modules and configuration reconstructed | Deleted `.lwpt/modules/json`, `lwpt.cfg`, and one proof document are rebuilt, the proof from the document store. |
| #226: a cache or archive miss fails without change | Neither source is available; the command fails with the offline hint, and project state and per-user state are byte-identical. |
| #226: corruption rejected, not fetched around | A flipped archive, a flipped proof document, and a flipped CAS object each fail with zero requests. |
| #226: manifest and lock drift fails | A changed range, alias identity, or pin. |
| #226: lockfile byte-identical; normal and frozen unchanged | The lock hash is compared before and after, and the frozen and normal registry suites above pass. |
| Per-user state | Two projects share an origin and the floor never decreases. Corrupt state fails and names the file. Two concurrent installs merge monotonically under the lease. |
| Fresh-CI restoration of the recorded accepted state | With an empty state directory, an online install uses the lock's `accepted*` state and `clockFloor` as the prior: a contact serving a checkpoint older than `acceptedSequence` is stale, a clock behind `clockFloor` aborts before any request, and a later checkpoint whose `published_at` is earlier than `clockFloor` leaves the floor unchanged. An install that changes any lock byte advances every origin's recorded accepted state to the merged maximum. |
| Unchanged selection, then empty-state restoration (decision 11) | Lock at sequence 42; an online install acquires sequence 57 with the selection unchanged: the lock stays byte-identical at 42 and the per-user state advances to 57. With the state directory then emptied, acquisition accepts an unexpired checkpoint at sequence 42 or above, including one below 57, and rejects one below 42 as stale; the selection never falls below the locked one. |
| Where registry dependencies may be declared (decision 5) | A workspace member declaring `registry:corp/json` installs through the root's `[registries.corp]`; a member whose own `[registries.corp]` names a different identity or pin fails at load. A git-host, URL, or local dependency whose `lwpt.toml` declares a `registry:` dependency fails with the actionable error, and nothing is published. |
| Publication refuses unsupported dependencies (requires #54) | Archives whose `lwpt.toml` declares a git-host dependency, a `registry:` dependency with `include` or `exclude`, a non-canonical constraint, or an alias without explicit `identity` each fail locally with `unsupported_dependencies` before any connection. A dependency-bearing archive without those issues publishes a record whose dependencies equal the mapped manifest. |
| Limits | A `REGISTRY_TESTING` limits seam makes an acquisition exceed its documents or bytes limit; it fails with `proof_limit_exceeded` and changes nothing. |

## Considered options

- **Version selection from `/v1/packages` pages.** Rejected. Pages are
  unauthenticated convenience views. The verified snapshot already lists
  every identity, and the records it lists are signed.
- **Lockfile schema v4.** Rejected. Every addition is optional, current
  readers ignore it, and older binaries fail closed at manifest parse. v3
  stays the last schema break.
- **Pin in the lock, or pin on first contact.** Rejected. That is trust on
  first use, and the issue forbids it.
- **Pin or contacts in user configuration only.** Rejected for the pin: the
  same checkout would trust different keys on different machines. Accepted
  for machine-local contacts, which never change identity.
- **Record every contact's archive URL on each install.** Rejected. Lock
  churn would reflect which mirror happened to answer.
- **Follow redirects with revalidation**, which the protocol permits.
  Rejected for consumers, as for the mirror and for publication. A redirect
  counts as a request failure and advances to the next contact.
- **A manifest-declared CA anchor.** See decision 9.

## Consequences

- **Registry packages behave like any other dependency.**
  - Consumers get reproducible, zero-install registry dependencies that can
    be verified offline.
  - Moving an origin or its mirrors is a manifest edit with no lock
    identity change.
- **New toolkit-owned state.** The proof directory is committed and derived
  from the lock. Per-user consumer state lives outside the cache and is not
  evicted.
  - Deleting per-user state is an explicit user action that lowers
    protection until the next acquisition.
  - Losing it is recoverable, because the lock supplies the prior.
- **Verification cost grows with the registry.** Acquisition still verifies
  the full history to sequence 1.
  - The per-user document store saves transfer only. The verifier charges
    every distinct snapshot and record against its 64 MiB budget whether it
    was downloaded or read from the store (`Verification.pas:1251-1266`).
  - Each snapshot lists every identity visible at its sequence, so history
    bytes grow roughly quadratically. With one new identity per
    publication, the quoted record hashes alone take about 75 bytes each
    per snapshot, so the budget is exhausted around 1,300 publications,
    earlier with larger records and other metadata. Yanks and restores
    replace a hash rather than adding one. Beyond that, consumers fail
    closed with `proof_limit_exceeded`, well before the 10,000-document
    limit.
  - The protocol already lets a returning client stop at its accepted
    snapshot. An incremental verifier mode is a follow-up issue, shared with
    the mirror.
- **Commit size.** A consumer project commits one head snapshot per origin,
  at about 80 bytes per published identity, rewritten only when that
  origin's selection changes.
- **Names.** Registry package names that contain `.` cannot be consumed by
  LWPT (decision 6). Two origins that publish the same name cannot both be in
  one graph, because FPC has one unit namespace.
- **Before #313 lands**, registries must be reachable at public addresses
  with certificates from the system trust store.
- **`outdated` and `update`** do not yet report registry dependencies.

## Decisions

The maintainer settled these on 2026-09-29: decisions 1 to 10 as
recommended, and decision 11 after review. The sections above already apply
them.

1. **Syntax: `registry:<package>` and `registry:<alias>/<package>`.** One
   reserved prefix keeps the kind visible in the string, as ADR-0009
   requires, and shares no namespace with `[sources]`. The rejected options
   were the alias as the prefix (`corp:<package>`) and a bare version
   (`json = "^1.2.0"`), which would turn typos into registry lookups.
2. **An endpoint-advertised identity is used when a declaration omits
   `identity`.** It is accepted only under the configured pin, recorded in
   the lock, and never replaced. This meets #62's precedence as written
   without trust on first use. The residual risk, an operator reusing one
   key for several origins, is frozen by the lock.
3. **Accepted state and the clock floor live both in per-user state and in
   the lock.** Acquisition extends the newer and checks the floor against
   both. The lock alone gives no protection across projects on one machine,
   and per-user state alone gives none on fresh CI. The lock keeps its
   recorded accepted state and floor separately from the selection proof.
4. **`--frozen` and `--offline` verify a committed inclusion proof from the
   manifest pin**, through `VerifyRegistryLockedSelection` and the
   specification amendment. This detects a pull request that consistently
   rewrites the lock, archives, and modules, because the installed tree is
   re-derived from the authenticated archive. It costs one snapshot per
   origin rather than up to 64 MiB of history.
5. **Registry dependencies are refused in git-host, URL, and local package
   manifests for now.** Workspace members use the root's registries, and
   registry packages take their edges from signed records. Naming an
   identity explicitly from such manifests, with trust still from the root,
   is a follow-up. Letting them declare their own pins was rejected because
   a dependency would choose trust roots.
6. **Consumers install only `[a-z0-9][a-z0-9_-]{0,127}`, the dependency key
   equals the package name, and `registry publish` enforces the same
   grammar.** Dots conflict with `ValidPackageName` and with Windows
   trailing-dot paths, and aliasing would let one package occupy two graph
   slots.
7. **Yanked versions are never newly selected, even by an exact version.**
   A locked yanked version stays, with a warning, and `--frozen` and
   `--offline` are unaffected. This matches Cargo's lock-respecting
   semantics.
8. **When every contact fails at the request layer, an online install
   reuses the locked selection, verified from the committed proof, and
   warns.** It never does so after a trust failure or when every contact is
   stale, which would hide a freeze attack. This matches the git
   ref-listing fallback (`LWPT.Install.pas:3396-3420`).
9. **#62 ships public HTTPS contacts with the system trust store.**
   User-level mirrors, private-host allowances, and trust anchors keyed by
   exact host arrive with #313's configuration file, never in `lwpt.toml`.
   Registry content is authenticated by signatures, so anchors are machine
   transport policy; blocking #62 on #313 would delay public origins for no
   security gain.
10. **ADR-0049 decision 4 is lifted in the #62 implementation**, as
    specified under "Dependency-bearing publication", including the refusal
    of dependencies with extraction filters. The #54 implementation of
    `registry publish` is a prerequisite. Consumer end-to-end
    tests publish real dependency chains through `registry publish`, and one
    ADR owns the mapping from manifest sources to records.
11. **The lock stays stable; it records accepted state only when it changes
    for another reason.** Settled by the maintainer after review. The
    lock's `accepted*` fields and `clockFloor` are the merged accepted state
    captured at the last lock change, not the highest state ever accepted;
    per-user state carries the true high-water mark. Acquisition progress
    alone never rewrites the lock, so checkouts do not churn. The cost is
    the fresh-CI limitation above: with empty per-user state, a stale
    contact can withhold publications newer than the recorded state, within
    the seven-day-plus-skew checkpoint lifetime, but can never downgrade
    below the recorded sequence or the locked selection. Persisting every
    acquisition advance into the lock was rejected because it would rewrite
    the lock on every install that saw a new checkpoint.
