# Lockfile schema v4: a framed, streamed tree digest

## Status

Proposed on 2026-09-29. Issue
[#352](https://github.com/frostney/lwpt/issues/352). On 2026-09-29 the
maintainer settled that #352 is fixed by a lockfile schema v4 with a framed
tree digest. This record defines that digest, the v4 schema, and the
migration from v3. It amends the AGENTS.md hard constraint that calls v3 "the
last lockfile schema break in v1", and it amends
[ADR-0008](0008-lockfile-schema-v2-archive-hash.md),
[ADR-0009](0009-source-syntax-and-tag-resolution.md), and
[ADR-0051](0051-registry-dependency-sources.md) where they describe
`computedHash` or rule out a v4. The implementation PR applies the amendments
listed under "Rule amendments"; this record edits no other document. The
choices that remain open are listed at the end, each with a recommendation.

## Executive Summary

- `computedHash` becomes `sha256-tree2:<hex>`: SHA-256 over a domain-separated
  stream with one self-delimiting record per file. Each record holds a type
  byte, the length-prefixed UTF-8 relative path, the normalized content
  length, and the SHA-256 of the normalized content (a Merkle-style per-file
  digest). No arrangement of file contents can be read as a path or as a file
  boundary, so the layout substitution from #352 now changes the digest.
- The walk, the cross-platform path order, the CRLF normalization, and the
  NUL binary guard are unchanged. Each file is read once in fixed-size
  chunks. The whole tree is no longer buffered in memory.
- Schema v4 changes two things: the `version = 4` header and the
  `computedHash` value format. Every other key, including ADR-0051's registry
  fields and per-origin tables, is unchanged.
- Recommended v3 handling: install-class commands read a v3 lock and write
  v4. `--frozen` and `--offline` refuse v3 with a migration hint and change
  nothing. `lwpt repair` upgrades a v3 lock without network and without
  moving versions: it re-derives every module from its archive or source
  anchor, which the v3 `computedHash` cannot vouch for. v1 and v2 handling is
  unchanged.
- Committed modules and archives do not change. A migration commit changes
  only `lwpt.lock`, unless a committed module had drifted from its archive,
  in which case the re-derived tree replaces it and the change is reported.
- v4 is not declared the last schema break in v1. The amended constraint
  instead requires any later break to go through an ADR that ships a machine
  migration. A break must not rely on "delete the lock and reinstall".

## Context

### The flaw

`HashTree` (`source/LWPT.Core.pas`) collects every file below a module root,
sorts the canonical relative paths with `TreeHashPathCompare`, and hashes the
concatenation of `path + LF + NormalizeTreeHashContent(contents)` for each
file. Nothing records where a file's contents end, so the bytes after a
content LF can be read as the next file's path. The reviewer of PR #351
showed two layouts of the `json` test package with the same hash input:

| Layout | Files |
| --- | --- |
| Original | `lwpt.toml`; `source/json.pas` = `unit json;` LF `{ 1.3.0 }` LF `interface` LF `implementation` LF `end.` LF |
| Substituted | `lwpt.toml`; `source/json.pas` empty; a root file literally named `unit json;` holding the rest of the unit after its first LF |

Both hash to
`sha256:68f88ceb5c7c6ff44ff90c66861ad33fba687776194988f2aee59078b8c4508f`
(the vector table below gives the exact bytes). No SHA-256 collision is
involved: the two inputs are byte-identical.

### Where the tree hash is used

| Use | Site |
| --- | --- |
| `computedHash` written for every staged, published, or frozen-walked module | `LWPT.Install.pas`: fixed-point staging, publication (`R.Nodes[k].Hash := HashTree(FinalUnitDir)`), frozen graph walk |
| `--frozen` tree check against the lock | `VerifyAgainstLockfile` |
| `--offline` check that the re-derived tree reconstructs the lock | `VerifyOfflineAgainstLockfile` |
| Local and workspace preflight: the live source must still equal the staged snapshot | `ResolveGraphFixedPoint` recheck |
| Rollback sidecars: a retained copy must equal the original before restore | `SnapshotPathHash` (`tree:` + `HashTree`), used by `AtomicRetainPath`, `AtomicRestorePath`, and so by install recovery and `lwpt repair` |
| Registry `--frozen` re-derivation (ADR-0051 decision 4) | PR #351 compares the re-derived tree with the lock and then file for file with the installed tree (`RegistryTreeDifference`), because equal `HashTree` values do not prove equal layouts |

`--offline` and online installs re-derive each module from an archive that
`archiveHash` has already verified byte for byte, or from local source that
the user owns. In those flows the tree hash only checks consistency. The
exploitable case is `--frozen`, which checks the committed tree under
`.lwpt/modules/` and nothing else. A pull request that swaps a module's
layout without touching its archive or the lock passes `--frozen` for every
source kind. `SECURITY.md` lists this bypass class ("`lwpt install --frozen`
failing to detect a tampered archive or extracted tree") as in scope.

### What must be preserved

- **Inventory** (`CollectFiles`). The hash covers regular files, and file
  links whose target resolves, read through the link. It does not descend
  into directory links or list dangling links. `CopyDirTree` copies a tree by
  the same rules, so a staged copy hashes the same as its source. Rollback
  retention and the local preflight depend on that.
- **Order** (`TreeHashPathCompare`). ASCII case-insensitive, compared byte by
  byte, shorter first, with an ordinal tiebreak. It exists because
  `AnsiCompareText` sorts hyphenated names differently on Windows.
- **Content normalization** (`NormalizeTreeHashContent`). Each CRLF pair in
  text becomes LF, and a lone CR is kept. A file that contains a NUL byte is
  binary and is hashed verbatim. A CRLF checkout must verify against a lock
  written from LF files. `archiveHash` stays the byte-exact anchor.

### Lock facts that shape the migration

- `LoadLockfile` accepts only `version` equal to `LOCKFILE_SCHEMA_VERSION`.
  v1 and v2 fail with "Delete `lwpt.lock` and run `lwpt install`". Unknown
  entry keys are ignored, which is how ADR-0047, ADR-0048, and ADR-0051 made
  additive v3 changes.
- An online non-frozen install selects the highest advertised tag that
  satisfies each range (ADR-0031). It reuses a locked selection only when
  ref listing fails. Running `lwpt install` to upgrade therefore moves range
  dependencies to their newest satisfying versions, as any online install
  does. Deleting the lock does the same, and also discards
  `reachableFrom` proofs and ADR-0051's recorded accepted state.
- `--offline` restores from the lock and leaves `lwpt.lock` byte-identical
  (#226, ADR-0051).
- ADR-0051 decision 11: a lock that would be byte-identical is never
  rewritten. Any other lock change writes every registry origin's merged
  accepted state.

### Why a schema bump rather than only a new prefix

Issue #352 considered adding a new prefix inside v3. The maintainer chose v4
for three reasons:

- **Clear refusal by older binaries.** A v3 binary reading a
  prefix-only upgrade would compare its legacy digest against
  `sha256-tree2:` and report "the modules tree was modified after install".
  Under v4 it reports "schema v4; this lwpt expects v3" instead.
- **No legacy digests in v4.** A v4 lock can require the new prefix on
  every entry. Within v3, a lock that carries the legacy prefix stays
  verifiable with the flawed digest, so an edit back to the old form
  reopens the bypass.
- **A dated migration.** The schema change pins the moment the bypass
  closes, and its migration can be specified and tested.

## Decision

### 1. The `sha256-tree2` digest

**Inventory.** The same set as `CollectFiles`: regular files, and file links
whose target resolves, read through the link. Directories are never entries.
A file's directories are implied by its path, so empty directories do not
contribute (a Git checkout keeps none, so zero-install trees would not verify
if they did). Directory links and dangling links are not entries, which keeps
`CopyDirTree` parity. How `--frozen` treats links is decided in section 4, not
here. File mode, timestamps, and ownership are not covered, as in v3. The
digest is defined for directories only. The legacy fallbacks that hashed a
single file or the path string itself do not carry over, and a missing
directory is an error.

**Paths.** Each entry's path is relative to the module root, has components
separated by `/`, and has no leading or trailing separator and no `.` or `..`
component. The path is hashed as UTF-8 bytes:

- On POSIX, the name bytes are used as the filesystem reports them.
- On Windows, the UTF-16 names are converted to UTF-8. The conversion must
  not go through the ANSI code page.
- A path that is not well-formed UTF-8, or that contains NUL, is an error
  that names the path in escaped form. Such a tree cannot hash the same on
  every platform, so the digest fails closed.
- There is no Unicode normalization. Paths are hashed as stored.

**Order.** `TreeHashPathCompare` applied to the UTF-8 path bytes, unchanged.
Once entries are framed, any deterministic platform-independent order would
work. Keeping the existing order avoids a third ordering and keeps diagnostics
aligned with v3.

**Per-file content digest.** For each file:

- `content` is `NormalizeTreeHashContent(file bytes)`.
- `size` is its length in bytes.
- `digest` is `SHA-256(content)`, plain SHA-256 with no prefix. `sha256sum`
  of an LF text file reproduces it, and it equals PR #351's
  `NormalizedFileDigest`.

**Stream.** The tree digest is SHA-256 over `magic || record*`, in sorted
path order. All integers are unsigned big-endian.

| Field | Bytes | Value |
| --- | --- | --- |
| `magic` | 13 | ASCII `sha256-tree2` followed by one `0x00` byte |
| `type` | 1 | `0x01`, a file. No other value is defined in `tree2`. |
| `path_len` | 4 | Byte length of `path`, at least 1 |
| `path` | `path_len` | UTF-8 relative path |
| `size` | 8 | Byte length of the normalized content |
| `digest` | 32 | SHA-256 of the normalized content |

For example, a file `alpha.txt` holding `alpha` is the record
`01 00000009 616c7068612e747874 0000000000000005` followed by the digest
`8ed3f6ad…2223f8`.

**Why the encoding is unambiguous.** `magic` has a fixed length. Every
record starts with a fixed-size header that gives the lengths of its only
variable-length field, and the rest of the record is fixed-size. A stream
therefore decodes into exactly one sequence of `(path, size, digest)`
records. Two trees with different sets of paths, or with the same paths but
different normalized contents, produce different streams. Their digests can
be equal only through a SHA-256 collision. Two contents that normalize to
the same bytes, such as the CRLF and LF forms of one text, still share a
digest, as they did in v3. `size` is redundant with `digest` for integrity.
It costs eight bytes and states the content length that #352 asked the
encoding to make explicit.

**Why a per-file digest rather than inline content.** Normalization is
decided per file: a NUL anywhere in the file makes the whole file binary. An
inline `size || content` record would need that decision, and the
normalized length, before any content byte could be hashed. That means
buffering each file or reading it twice. Two reads let the file change
between them, and the resulting length prefix would disagree with the bytes
that follow. A per-file digest is computed in one pass. Two SHA-256 contexts
run in parallel, one over the raw bytes and one over the CRLF-normalized
bytes, and the file's NUL status at end of file selects which one to use.
Pascal source trees are small, so the second context costs little. The
normalized context can stop at the first NUL, because the file is then
binary.

**Streaming.** The walk collects and sorts only the path list, so memory
grows with the number of files, not their size. Each file is then opened
once and read to end of file in fixed chunks of 64 KiB, an implementation
constant. The digest does not depend on chunk size. `FS.Size` is not
trusted: bytes are counted as they are read. A CR at the end of a chunk is
held until the next chunk shows whether an LF follows. At end of file a
held CR is emitted as a lone CR. The outer SHA-256 context receives each
record as its file finishes. Neither the tree nor any single file is ever
fully in memory.

**Identifier.** `sha256-tree2` is the algorithm name. It appears in the lock
value `sha256-tree2:<64 lowercase hex>`, and its bytes are the `magic`. It
contains no program name, so a rename changes no digest (ADR-0001 governs
program-name literals, not wire constants). `archiveHash`,
`registryRecord`, and the other `sha256:` values keep their meaning:
SHA-256 over raw bytes.

### 2. Test vectors

The file contents are exact byte strings: LF is `0x0A`, CR is `0x0D`, and
NUL is `0x00`. The legacy column is the current `HashTree` output. It
reproduces the digests pinned in `LWPT.Core.Test.pas` (`5c970f…` and
`77386d…`), which confirms this model of the v3 encoding. A Python
`hashlib` model computed the `tree2` column, and a shell pipeline
(`printf`, `xxd`, `sha256sum`) confirmed the nested-tree vector
independently.

| Tree | Legacy `sha256:` | `sha256-tree2:` |
| --- | --- | --- |
| Empty directory | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `27822f587b72b705a08f0c9865fe020a44bbd681b87df7462f2cc46af0e33ab7` |
| Nested: `alpha.txt`=`alpha`, `nested/beta.bin`=`beta`, `nested/deeper/gamma.txt`=`gamma` | `5c970f737e82874a0c3c6bde83813385951ef2a78125d709ac4b46f5812ba4d4` | `24a5a83e163c4c78a47b5c93c5f7061ed40cff21bf794d2237e88d40114947ae` |
| Fold order: `leaf-ca-true.cnf`=`ca=true` LF, `leaf.cnf`=`leaf` LF, `README.md`=`# fixture` LF, `sub/a-b.pas`=`unit ab;` LF, `sub/ab.pas`=`unit ab2;` LF | `77386de0b4e46c60b337ea3255b2f68ddb48a46a1a216a828dce604a2f84ad85` | `c832919ae78620edac02c29d991b78b2895023c181110c3095d4b1759ed666b1` |
| #352 original: `lwpt.toml`=`[package]` LF `name = "json"` LF `version = "1.3.0"` LF `units = ["source"]` LF; `source/json.pas`=`unit json;` LF `{ 1.3.0 }` LF `interface` LF `implementation` LF `end.` LF | `68f88ceb5c7c6ff44ff90c66861ad33fba687776194988f2aee59078b8c4508f` | `10e083e1804357e2376467dedbb598b3059e7a69bd18f125498e5e92efca1c1a` |
| #352 substituted: same `lwpt.toml`; `source/json.pas` empty; `unit json;`=`{ 1.3.0 }` LF `interface` LF `implementation` LF `end.` LF | `68f88ceb5c7c6ff44ff90c66861ad33fba687776194988f2aee59078b8c4508f` (equal) | `67817df420cfac5318569f13b72d82082cc28f3e889aacaf392e37bfaf14943d` (different) |
| `unit.pas`=`unit A;` CRLF `begin` CRLF `end.` CRLF | `2bb80f3322fc70ef3ab7bda3fc07e71bbbbc153c0618e655bf4139af6bedbb05` | `7c177c9e38d6e6f87d4fcbc81e5af3e89d41ab13806c2ecc13cedcd74681bd8c` |
| `unit.pas`=`unit A;` LF `begin` LF `end.` LF | same as CRLF | same as CRLF |
| `blob.bin`=`a` CRLF NUL `b` CRLF (binary, verbatim) | `69934cb6a9d50a2d61ebb273ddbbcd6f8f29806a652a57e8e6bef1305d2d2782` | `cf31319e6c1d6b3e75f2fbece1f5f6d4d97f9105a455a7ca4511a123808c3836` |
| `blob.bin`=`a` LF NUL `b` LF | `4c3f6771f755d55099b1a72e54e0665187931cfb0ce5d2852d8d37569d1e12d6` | `e51425a5ce78cb9d69d51f068373e691b794c9b31c8b65ec522c5761a6650d7e` |
| `cr.txt`=`a` CR `b` CR (lone CRs kept) | `62f79a9f6fe3a6805be13d8d9a6040422b06f6bf9c39e172693c0d52f4831f8c` | `6767b67a1459191651578f01c861b4e6b7681825da5449dbdb7087c74bb1b5eb` |
| `empty.pas` with no bytes | `7de1b0d19b3467c2191240d86d4479c6635e73c0c30cb99f005e3213c45a17bb` | `86d302c47f0b9d1c94fd0385467be28c3d31fef8f03df93345c0203295b9df32` |
| `süß.pas` (UTF-8 `73 c3bc c39f 2e706173`)=`unit s;` LF | `2ac8aeee577349918473caaebe1f3cd79a1cd83c749c1c2a0c80969a206b9616` | `8398b468076302b8f9cf0a930f6e7d129f7201c6896bafabe2674385c7a25069` |

### 3. Lockfile schema v4

- **Changes.**
  - The header is `version = 4`.
  - Every `computedHash` is `sha256-tree2:` followed by 64 lowercase hex
    digits.
- **Unchanged.** Everything else keeps its v3 form and meaning:
  - the entry keys `source`, `resolvedRef`, `resolvedCommit`,
    `resolvedRefKind`, `reachableFrom`, `sourceIdentity`,
    `constraintFingerprint`, `resolvedURL`, `archiveHash`, `registryOrigin`,
    and `registryRecord`;
  - the `[registry."<identity>"]` tables and their byte-for-byte
    carry-forward rules;
  - the tolerance for unknown keys and unknown top-level tables;
  - rendering order.

  No field is added, renamed, or removed with v4.
- **Loader rules.**
  - A v4 lock whose `computedHash` has another prefix, or no prefix, fails to
    load as incompatible, naming the entry. A v4 lock never holds a legacy
    digest.
  - A lock with `version` above 4 fails with "schema v*N*; this lwpt reads
    up to v4". v1 and v2 keep their current error.
  - Every lock reader shares one version gate: `LoadLockfile`,
    `LoadRegistryLockTables`, and the `outdated` and `update` paths. v3
    handling is covered in section 5.
  - The writer never emits a non-`tree2` `computedHash`. The in-memory
    "unfetched" placeholder becomes an error before the lock is written.
- **ADR-0051.** Registry entries keep all their fields, and `archiveHash`
  still equals the signed record's `archive` digest. Decision 11 applies as
  written:
  - Rewriting a v3 lock as v4 is a real lock change, so that write carries
    every origin's merged accepted state.
  - After the rewrite, installs that change nothing leave the lock
    byte-identical. `tree2` is deterministic and identical across
    platforms, so a lock written on one OS does not churn on another.
  - ADR-0051's rejection of a v4 ("v3 stays the last schema break") was
    about the registry fields, which remain additive. This record supersedes
    only its closing claim.

### 4. Verification under v4

- **`--frozen`** compares the committed module tree's `tree2` digest with
  `computedHash`, and still checks `archiveHash`. It also fails when an
  installed module tree contains any link: a file link, a directory link, a
  junction, or a dangling link. The error names the path.
  - LWPT never installs links. Extraction materializes archive links as
    copies. Local and workspace copies read file links through and drop
    directory links.
  - Without this rule, a directory link added under a module's unit
    directory would be invisible to the digest, which omits directory links
    for `CopyDirTree` parity, yet FPC could read from it.
  - PR #351 already refuses links in registry trees. This rule extends that
    to every source kind.
- **`--offline`** is unchanged apart from the digest. It re-derives each
  module, compares it with `computedHash`, and leaves the lock
  byte-identical.
- **Registry re-derivation** (ADR-0051 decision 4). The tree re-derived from
  the proof-authenticated archive must have a `tree2` digest equal to both
  `computedHash` and the installed tree's digest. Equality now proves an
  equal layout. #351's per-file comparison is no longer needed for
  correctness. The implementation may keep it only to name the first
  differing path after a digest mismatch.
- **Local and workspace preflight** uses `tree2` on both sides.
- **Rollback sidecars.**
  - `SnapshotPathHash` records `tree:sha256-tree2:<hex>`.
  - Recovery by install or `lwpt repair` still accepts a sidecar that a
    pre-v4 binary wrote (`tree:sha256:<hex>`). It recomputes the legacy
    digest over the retained copy, so a transaction interrupted before an
    upgrade can still be recovered after it.
  - This is the only remaining use of the legacy digest besides its pinned
    tests. The legacy function is renamed to say so and is not used for
    lock verification.

### 5. Migration from v3 (recommended policy; see open decision 2)

| Command | On a v3 lock |
| --- | --- |
| `lwpt install`, `add`, `remove`, `update` (online, not frozen) | Loads v3 as the prior lock and resolves as usual. The prior lock's archive hashes still anchor refetches, and a failed ref listing still reuses a locked selection. Writes v4. Versions may move exactly as in any online install. |
| `lwpt install --frozen` | Fails before any verification with `ELockfileError`: "`lwpt.lock` is schema v3, whose tree hash cannot detect a rearranged module tree (ADR-0052). Run `lwpt repair` to upgrade it without network or version changes, or `lwpt install`, then commit `lwpt.lock`." Changes nothing. |
| `lwpt install --offline` | Fails before staging with the same hint. Changes nothing, and the byte-identical promise holds. |
| `lwpt repair` | After its existing steps (stale install lock, transaction recovery, sessions, retired images, workers, shared cache), upgrades a v3 lock without network or version changes, as below. A v4 lock is left alone. |
| `lwpt outdated` | Reads v3 as well as v4. It is read-only and uses only `resolvedRef`. |
| `lwpt build`, `lwpt test` | Do not read the lock's contents. The lock is part of their cache fingerprint, so the one-time rewrite causes one cache miss. |

**`lwpt repair`'s upgrade** runs under the install lock as an install
transaction (retention, rollback, `AtomicWriteText`):

1. **Check agreement.** The manifest and the v3 lock must agree as they must
   for `--offline`: source identity, constraint fingerprint, and a locked
   selection that still satisfies every requirement. If they disagree, the
   command fails with "the manifest changed since the lock was written; run
   `lwpt install`", and the lock stays v3.
2. **Re-derive modules.** Each module is re-derived without network, from
   its anchor:
   - Git-host and URL modules come from the committed archive or the
     per-user CAS, checked against `archiveHash`.
   - Registry modules come from archives verified through the committed
     proof and the manifest pin (ADR-0051).
   - Local and workspace modules come from their live source under the
     declared `include` and `exclude` policy.

   The v3 `computedHash` is not consulted. It is the value the flaw lets a
   forged tree match, and the archive and proof anchors do not depend on it.
3. **Report and publish.** When a committed module's `tree2` digest differs
   from its re-derived tree's, the command names the module, and the
   re-derived tree replaces it. This surfaces any earlier drift or tamper.
   The modules and `lwpt.cfg` are then published.
4. **Write the v4 lock.** It differs from the v3 lock only in `version`,
   every `computedHash`, and, because the lock changes, each registry
   origin's recorded accepted state where per-user state had advanced
   (decision 11).
5. **Handle failures.** A missing archive or proof fails with the
   `--offline` hint and rolls back, and the lock stays v3.

**Downgrade resistance.** Rewriting a v4 lock to v3, with legacy digests
that match a forged tree, gains nothing. `--frozen` refuses v3, and every
upgrade path re-derives trees from their anchors rather than from the
committed modules.

**Consumers.** GocciaScript (Path A, ADR-0017) and third parties migrate in
one PR:

1. Move the pinned `lwpt` binary to the release that ships v4.
2. Run `lwpt repair`, or `lwpt install` when newer versions are wanted.
3. Commit `lwpt.lock`.

After that PR, a binary older than v4 fails on the lock with the schema
message, so CI and contributors move together. LWPT's own lock, which holds
only `workspace:auto` entries, is upgraded in the implementation PR, and CI's
`install --frozen` on all six targets is the dogfood check. The
DEFINITION_OF_DONE rule for edited workspace packages is unchanged: rerun
`lwpt install` and commit the lock.

### 6. Zero-install

`.lwpt/modules/`, `.lwpt/archives/`, the proof documents, and `lwpt.cfg`
keep their bytes. `git clone && fpc @lwpt.cfg` is unaffected, because the
lock is not a compiler input. The only committed difference is the lock's
header and hash strings. The exception is a module that had drifted from its
anchor: the upgrade replaces it and reports it, so the drift shows in the
migration diff.

## Rule amendments

The implementation PR applies these in the same change as the code.

- **AGENTS.md, Hard Constraints.** Replace the `lwpt.lock` bullet with the
  text below. It includes PR #351's registry clause; if #351 has not merged
  first, drop the clause beginning "for registry entries".

  > - **`lwpt.lock` is machine-written, schema v4.** Never hand-edit. The schema records the verbatim manifest source string, the resolver's chosen ref (tag/SHA), the actual archive URL, the extracted tree's framed digest (`computedHash = "sha256-tree2:<hex>"`: per file, a length-prefixed UTF-8 path, the normalized content length, and the normalized content's SHA-256, in the cross-platform `TreeHashPathCompare` order, with CRLF→LF normalization for NUL-free files), and the cached-archive sha256. Registry entries add `registryOrigin` and `registryRecord`, and one `[registry."<identity>"]` table per origin records the pinned key id, the selection proof's checkpoint, and the recorded accepted state and clock floor; a byte-identical lock is never rewritten ([ADR-0051](./docs/adr/0051-registry-dependency-sources.md)). `--frozen` re-hashes the archive + tree, compares both to the stored hashes, and refuses any link inside an installed module; for registry entries, `--frozen` and `--offline` also verify the committed selection proof from the manifest pin, and `--frozen` re-derives the module tree from the proof-authenticated archive, because `computedHash` is unsigned. v1 and v2 lockfiles fail to load with a clear migration hint. A v3 lockfile is rewritten as v4 by `install`, `add`, `remove`, and `update`; `lwpt repair` upgrades it without network or version changes; `--frozen` and `--offline` refuse it with that hint. Corrupt lockfile → delete + re-run `lwpt install` to regenerate. See [ADR-0008](./docs/adr/0008-lockfile-schema-v2-archive-hash.md) (v1→v2 archiveHash split), [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md) (v2→v3 source-syntax refactor), and [ADR-0052](./docs/adr/0052-lockfile-schema-v4-framed-tree-digest.md) (v3→v4 framed tree digest). Any further schema break requires an ADR that ships a machine migration from the previous schema; "delete the lockfile and reinstall" is not a migration.

- **`docs/architecture.md`, "Lockfile schema".** Retitle the section v4.
  Update:
  - the `computedHash` row;
  - the registry paragraph's "file for file" sentence (section 4);
  - the older-schema paragraph: v3 handling as in section 5, and removal of
    "v3 is the last lockfile schema break planned for v1";
  - the `EVerifyError` row, adding links inside installed modules.
- **`CONTEXT.md`, "Lockfile".** "schema-v3" becomes "schema-v4", and
  "extracted-tree hash" becomes "framed extracted-tree digest".
- **`docs/testing.md`.** Update the `LWPT.Core.Test.pas` description of
  `HashTree` paths and `LoadLockfile`, and add the new rows below.
- **ADR-0008 and ADR-0009.** Add amendment notes that point here. ADR-0009's
  "v3 is the last schema break planned for v1" is superseded.
- **ADR-0051.** Add an amendment note: `computedHash` is `tree2` (v4), and
  `--frozen` step 4 relies on digest equality. The considered option
  "Lockfile schema v4. Rejected" stays as history, and the note points here.

## Test plan

| Criterion | Evidence |
| --- | --- |
| The digest matches the specification | `LWPT.Core.Test.pas` pins every vector in section 2 on all six targets. The Windows legs build the `süß.pas` fixture through the UTF-16 API. |
| #352's substitution changes the digest | Unit test: the two trees from section 2 give equal legacy digests and different `tree2` digests. Integration, once for each source kind (local, workspace, git-host fixture, URL, registry): install the `json` package, apply the substitution in `.lwpt/modules/json`, and `--frozen` fails with a tree-hash mismatch while the lock and archives are byte-identical. |
| Streaming equals the buffered definition | For sizes of chunk − 1, chunk, and chunk + 1: a CR as the last byte of a chunk followed by an LF, a CR at end of file, a NUL only in the last chunk after CRLFs in the first, and an empty file. Each per-file digest equals `SHA-256(NormalizeTreeHashContent(whole file))`. |
| The tree is not buffered | Hashing a tree with one 64 MiB file raises peak heap use (FPC heap status) by less than 1 MiB. |
| Cross-platform identity | The CRLF and LF trees give one digest, the fold-order vector holds on Windows, and CI's `install --frozen` passes on all six targets against the upgraded LWPT lock. |
| Invalid paths fail closed | On POSIX, a file name that is not well-formed UTF-8 fails the digest and the error names the escaped path. |
| Inventory and links | A `CopyDirTree` copy of a tree with a file link and a directory link has the same `tree2` digest as the original, so rollback retention succeeds. `--frozen` fails, naming the path, for a file link, a directory link, and a dangling link inside an installed module. |
| v4 writer and loader | An install writes `version = 4` and `sha256-tree2:` values. The lock round-trips. A v4 lock with one `sha256:` `computedHash` fails to load and names the entry. A `version = 5` lock fails with the "reads up to v4" message. The v1 and v2 hints are unchanged. |
| Non-frozen installs upgrade v3 | A committed v3 fixture project is upgraded by `install`, `add`, `remove`, and `update`. A second install is byte-identical (decision 11). In a registry project, the upgrade write carries merged accepted state and the selection proof is carried forward byte for byte. |
| `--frozen` and `--offline` refuse v3 | Each fails with the migration hint and zero transport requests. The lock, cfg, modules, archives, and proofs are byte-identical. |
| `lwpt repair` upgrades without network and without moving versions | The fixture advertises a newer satisfying tag, and the transport seam records zero requests. Afterward: `resolvedRef` and `resolvedCommit` are unchanged; modules and archives are byte-identical; the lock diff contains only `version`, `computedHash`, and decision-11 accepted-state lines; `--frozen` passes. |
| `lwpt repair` surfaces drift | A committed module altered by the #352 substitution under a v3 lock is replaced by the re-derived tree and named in the output. A missing archive fails with the `--offline` hint, rolls back, and leaves the lock v3. A manifest that disagrees with the lock fails with the `lwpt install` hint. |
| Downgrade | A v4 lock rewritten as v3 with legacy digests of a forged tree fails `--frozen`, and `lwpt repair` replaces the forged tree. |
| Legacy rollback sidecars | A pending transaction whose sidecar holds `tree:sha256:` is recovered by `install` and by `repair`. |
| Read-only readers | `lwpt outdated` reports from v3 and v4 locks alike. |
| Existing behavior | The existing install, offline, frozen, commit-pin, and registry suites pass after their expected `computedHash` values are updated. The only golden-lock differences are `version` and `computedHash`. |

## Considered options

- **Only a new prefix within v3, as #352 first suggested.** Rejected by the
  maintainer's decision; see "Why a schema bump" above.
- **Inline `size || content` records.** Rejected. The NUL guard decides
  normalization per file, so inline framing needs each file buffered or read
  twice. Two reads allow a mismatched length prefix if the file changes
  between them. The per-file digest is one pass with bounded memory.
- **Include empty directories, file modes, or link records (a NAR-like
  format).** Rejected. Git keeps no empty directories, so zero-install
  checkouts would fail to verify. Modes are not a Pascal build input and v3
  never covered them. Link records would break `CopyDirTree` parity, so
  rollback retention would fail on the very trees an install must repair.
  Links are handled by the `--frozen` refusal instead.
- **A new sort order, such as plain ordinal.** Rejected. Framing makes any
  deterministic order sound, and a third order would add risk for no gain.
- **`--frozen` verifies v3 with the legacy digest and warns.** Rejected as
  the recommendation (it is option C of open decision 2). It keeps the
  bypass open for any project that never upgrades, and a v4-to-v3 rewrite
  would reopen it.
- **Record per-file digests in the lock.** Rejected. It would make locks
  much larger and churn them on every file change. The single root digest
  is enough to detect a change, and the per-file comparison can name the
  differing path after a mismatch.
- **Sign the lock.** Out of scope, as ADR-0008 and ADR-0051 record.
  `computedHash` stays unsigned. v4 fixes the framing, not authenticity.

## Consequences

- `--frozen` detects every layout change to a committed module, as well as
  links inside it, for every source kind. The #352 bypass closes once a
  project's lock is v4.
- Tree hashing uses memory proportional to the number of files, not the
  bytes in the tree.
- Every project rewrites `lwpt.lock` once. Build and test caches miss once.
  Binaries older than v4 cannot read a v4 lock.
- Until a project upgrades, `--frozen` and `--offline` fail on its v3 lock.
  CI jobs that upgrade the binary without the lock go red with the
  migration hint.
- Non-ASCII file names must be well-formed UTF-8 to be hashed. The
  Windows extractor's ANSI-code-page path handling is unchanged by this
  record, so non-ASCII names in dependencies stay unportable on Windows
  until the extraction side is fixed separately.
- The legacy digest survives only to recover pre-upgrade rollback sidecars
  and to pin its own tests.

## Open decisions for the maintainer

1. **Milestone: 0.8.0 or 0.9.0.**
   - **Option A, 0.8.0.**
     - For: 0.8.0 is the release where registry lock entries first ship, so
       they would never appear in a released v3 lock. Consumers adopting
       the registry would rewrite their locks once, not twice. The
       git-host, URL, and local `--frozen` bypass is a `SECURITY.md`
       in-scope class, and 0.8.0 would close it.
     - Against: it adds an implementation PR to a milestone with 5 open
       issues. The registry path is already covered in 0.8.0, because
       #351's `--frozen` compares registry trees file for file.
   - **Option B, 0.9.0.**
     - For: 0.8.0 ships sooner. 0.9.0's #169 (dependency patching) and #170
       (`.lwptignore`) change what a module tree contains, so they could be
       designed against the v4 digest.
     - Against: 0.8.0 would ship registry entries in v3 locks, which then
       migrate in 0.9.0. The non-registry `--frozen` bypass stays open for
       one more release.
   - **Recommendation: A, 0.8.0.** The fix is a contained change to
     `LWPT.Core` and the lock loader. Shipping the registry on v4 avoids
     one migration for every early adopter. It also closes a security-class
     gap in the release that makes `--frozen` a registry trust boundary.
2. **v3 handling policy.**
   - **Option A, hard error everywhere, as for v1 and v2.** The hint says
     to delete the lock and run `lwpt install`. The simplest code. However,
     it needs network, moves every range dependency to its newest version,
     and drops `reachableFrom` proofs and registry accepted state.
   - **Option B, automatic upgrade** (section 5). Install-class commands
     read v3 and write v4. `--frozen` and `--offline` refuse v3 with the
     hint. `lwpt repair` upgrades without network or version changes.
   - **Option C, like B, but `--frozen` verifies v3 with the legacy digest
     and warns for one minor release.** It keeps CI green through the
     transition. It also keeps the bypass open and exposed to a v4-to-v3
     rewrite.
   - **Recommendation: B.** It is the only option that closes the bypass on
     upgrade without forcing dependency changes or network access.
3. **Where the network-free, version-stable upgrade lives.** This applies
   only under decision 2, option B.
   - **Option A, `lwpt repair`** (section 5). Repair already recovers
     toolkit state that an older or crashed binary left behind. It is
     network-free, and it carries no byte-identical promise.
   - **Option B, `lwpt install --offline` writes v4 once.** It reuses the
     offline pipeline directly, but breaks `--offline`'s documented promise
     that `lwpt.lock` stays byte-identical.
   - **Option C, no dedicated path.** Only an online `lwpt install`
     upgrades, and range dependencies move to their newest versions.
   - **Recommendation: A.** Offline's promise stays intact, and every
     project gets an upgrade that changes no dependency version.
4. **Whether v4 is declared the last schema break in v1.**
   - **Option A: declare it**, mirroring ADR-0009's wording.
   - **Option B: make no "last" claim.** Require any later break to go
     through an ADR that ships a machine migration from the previous schema
     (the AGENTS.md text above).
   - **Recommendation: B.** ADR-0009's claim did not hold. A rule about how
     breaks happen protects consumers better than a promise that none will.
