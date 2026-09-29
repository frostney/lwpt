# Lockfile schema v4: a framed, streamed tree digest

## Status

Accepted on 2026-09-29 by the maintainer, who settled the four decisions at
the end of this record. Issue
[#352](https://github.com/frostney/lwpt/issues/352), milestone 0.8.0. The
maintainer had already settled that #352 is fixed by a lockfile schema v4
with a framed tree digest. This record defines that digest, the v4 schema,
and the migration from v3. It amends the AGENTS.md hard constraint that calls
v3 "the last lockfile schema break in v1", and it amends
[ADR-0008](0008-lockfile-schema-v2-archive-hash.md),
[ADR-0009](0009-source-syntax-and-tag-resolution.md), and
[ADR-0051](0051-registry-dependency-sources.md) where they describe
`computedHash` or rule out a v4. The implementation PR applies the amendments
listed under "Rule amendments"; this record edits no other document.

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
- A v3 lock is a hard error, as v1 and v2 are. `install`, `add`, `remove`,
  `update`, `outdated`, `--frozen`, and `--offline` refuse it, change
  nothing, and point to `lwpt repair`. `lwpt repair` is the only command that
  turns a v3 lock into v4. It works without network and without moving
  versions: it re-derives every module from its archive or source anchor,
  which the v3 `computedHash` cannot vouch for. v1 and v2 handling is
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
  ref listing fails. Regenerating a lock with `lwpt install`, the v1 and v2
  recovery, therefore needs network and moves range dependencies to their
  newest satisfying versions. Deleting the lock first also discards
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
- On Windows, the UTF-16 names are converted to UTF-8 strictly. The
  conversion must not go through the ANSI code page, and it must reject
  malformed UTF-16 rather than repair it: `WideCharToMultiByte(CP_UTF8,
  WC_ERR_INVALID_CHARS, …)` or an equivalent validating conversion. An
  unpaired high or low surrogate is an error and is never replaced with
  U+FFFD. Replacement would map distinct names, such as one holding U+D800
  and one holding U+DC00, to the same valid UTF-8 path, and validating the
  output alone cannot detect that. A correctly paired surrogate, such as
  U+1D518 (`35d8 18dd` in UTF-16LE), becomes its four-byte UTF-8 form
  `f09d9498`.
- A path that is not well-formed UTF-8, or that contains NUL, is an error
  that names the path in escaped form. On Windows the same applies to a
  name that is not well-formed UTF-16. Such a tree cannot hash the same on
  every platform, so the digest fails closed.
- There is no Unicode normalization. Paths are hashed as stored.

**Order.** `TreeHashPathCompare` applied to the UTF-8 path bytes, unchanged.
Once entries are framed, any deterministic platform-independent order would
work. Keeping the existing order avoids a third ordering and keeps diagnostics
aligned with v3. The comparator's ordinal tiebreak orders paths that differ
only in ASCII case, such as `A.pas` before `a.pas`, whatever order the
filesystem enumerates them in.

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
record starts with a fixed-size header that gives the length of its only
variable-length field, and the rest of the record is fixed-size. A stream
therefore decodes into exactly one sequence of `(path, size, digest)`
records: the framing is injective over such sequences, and the record
boundaries also fix the file count. It is not injective over file contents
directly, because two equal-length contents that collide under the inner
SHA-256 give identical records. The guarantee is therefore conditional:
assuming SHA-256 is collision-resistant, equal tree digests imply equal
covered trees, meaning the same paths with the same normalized contents. A
collision would be needed at either layer, in a per-file digest or in the
outer stream digest, to break it. Unlike v3, no collision-free
rearrangement of bytes produces equal digests. Two contents that normalize
to the same bytes, such as the CRLF and LF forms of one text, still share a
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
| Supplementary plane: U+1D518 followed by `.pas` (UTF-8 `f09d9498 2e706173`)=`unit u;` LF | `d4beb95e5f9d918a1a7beddc50331157c88d431063f5e3d3483520594ffa10bb` | `07c9aecdbc478349c8f2c275ff6e01717a166118cd2e2e8f1089b9be5486fe8a` |
| Case collision: `A.pas`=`unit A;` LF and `a.pas`=`unit a;` LF, supplied in either enumeration order; the tiebreak puts `A.pas` first | `c179b461d81015e4bfdcaa89a916b3b84f473b00f4466ee5412f8cda08b39d37` | `ce003a228b9696df3a9f38e525a88fc8e295feb855f7850e9ac49a6615c4256a` |

Without the ordinal tiebreak, `a.pas` could precede `A.pas`, and the
case-collision tree would hash to `sha256-tree2:7a033516…4ea0a` instead. None
of the other vectors would change, so only this row exercises the tiebreak.
Default Windows and macOS filesystems cannot hold both names. The on-disk
vector is therefore pinned on case-sensitive filesystems (the Linux legs).
On every platform, the comparator is also tested directly on an in-memory
path list supplied in both input orders, with no filesystem involved.

Names with an unpaired surrogate have no vector: `tree2` rejects them, as
described under "Paths".

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
  - `lwpt repair`'s v3-to-v4 upgrade is a real lock change, so that write
    carries every origin's merged accepted state.
  - After the upgrade, installs that change nothing leave the lock
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
    upgrade can still be recovered after it. On a v3 lock, install refuses
    before recovery (section 5), so `lwpt repair` is where such a
    transaction is recovered.
  - This is the only remaining use of the legacy digest besides its pinned
    tests. The legacy function is renamed to say so and is not used for
    lock verification.

### 5. Migration from v3 (decisions 2 and 3)

A v3 lock is a hard error, as v1 and v2 are, and `lwpt repair` is the only
command that turns it into v4. Every lock reader refuses v3 through the
shared version gate with one `ELockfileError` message:

> `lwpt.lock` is schema v3, whose tree hash cannot detect a rearranged module
> tree (ADR-0052). Run `lwpt repair` to upgrade it to v4 without network
> access and without changing dependency versions, then commit `lwpt.lock`.
> Deleting `lwpt.lock` and running `lwpt install` also works, but needs
> network access and moves range dependencies to their newest matching
> versions.

The program name in the message comes from `PROGRAM_NAME` (ADR-0001).

| Command | On a v3 lock |
| --- | --- |
| `lwpt install`, `add`, `remove`, `update` | Refuse with the message. The gate runs before transaction recovery, tmp cleanup, rollback retention, and any manifest write, so the command changes nothing: `lwpt.toml`, the lock, the cfg, modules, archives, and proofs keep their bytes. There is no automatic upgrade. |
| `lwpt install --frozen` | Refuses with the message before any verification. Changes nothing. It never verifies a legacy digest. |
| `lwpt install --offline` | Refuses with the message before staging. Changes nothing, and the byte-identical promise holds. |
| `lwpt outdated` | Refuses with the message, like every lock reader. |
| `lwpt repair` | After its existing steps (stale install lock, transaction recovery, sessions, retired images, workers, shared cache), upgrades a v3 lock without network or version changes, as below. A v4 lock, or a project without a lock, is left alone. |
| `lwpt build`, `lwpt test` | Do not read the lock's contents. The lock is part of their cache fingerprint, so the one-time upgrade causes one cache miss. |

**`lwpt repair`'s upgrade** is the only reader that accepts a v3 lock. It
runs under the install lock as an install transaction (retention, rollback,
`AtomicWriteText`):

1. **Check agreement.** The manifest and the v3 lock must agree as they must
   for `--offline`: source identity, constraint fingerprint, and a locked
   selection that still satisfies every requirement. If they disagree, the
   command fails, and the lock stays v3. The message says to restore the
   manifest the lock was written from, run `lwpt repair`, and then change
   the manifest, or to delete the lock and run `lwpt install`.
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
5. **Handle failures.** Any failure rolls the transaction back, and the
   lock stays v3. The `--offline` hint does not fit here, because it
   suggests an online `lwpt install`, which refuses the remaining v3 lock
   and points back to repair. A missing anchor, or one whose hash does not
   match, therefore fails with a migration-specific `ELockfileError`
   message instead. For example, for an archive:

   > `lwpt repair` cannot upgrade `lwpt.lock` from schema v3: the archive
   > for "json" at `.lwpt/archives/json-1.3.0.tar.gz` is missing or does not
   > match its locked `archiveHash`, and the per-user cache has no matching
   > copy. Restore that exact archive, for example from version control,
   > and run `lwpt repair` again. To give up the version-stable migration,
   > delete `lwpt.lock` and run `lwpt install`; that needs network access
   > and moves range dependencies to their newest matching versions.

   A missing or corrupt registry proof document gets the same message,
   naming the document's hash path instead of the archive.

After the upgrade, decision 11 holds: an install that changes nothing leaves
the v4 lock byte-identical on every platform.

**Downgrade resistance.** Rewriting a v4 lock to v3, with legacy digests
that match a forged tree, gains nothing. Every command except `lwpt repair`
refuses v3, and repair re-derives trees from their anchors rather than from
the committed modules or the v3 `computedHash`.

**Consumers.** GocciaScript (Path A, ADR-0017) and third parties migrate in
one PR:

1. Move the pinned `lwpt` binary to the release that ships v4 (0.8.0).
2. Run `lwpt repair`. When newer dependency versions are wanted, run
   `lwpt install` afterwards, or delete the lock and run `lwpt install`
   instead.
3. Commit `lwpt.lock`.

After that PR, a binary older than v4 fails on the lock with the schema
message, so CI and contributors move together. LWPT's own lock, which holds
only `workspace:auto` entries, is upgraded with `lwpt repair` in the
implementation PR, and CI's
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

  > - **`lwpt.lock` is machine-written, schema v4.** Never hand-edit. The schema records the verbatim manifest source string, the resolver's chosen ref (tag/SHA), the actual archive URL, the extracted tree's framed digest (`computedHash = "sha256-tree2:<hex>"`: per file, a length-prefixed, strictly validated UTF-8 path (malformed UTF-16 names on Windows are rejected, never replaced), the normalized content length, and the normalized content's SHA-256, in the cross-platform `TreeHashPathCompare` order, with CRLF→LF normalization for NUL-free files), and the cached-archive sha256. Registry entries add `registryOrigin` and `registryRecord`, and one `[registry."<identity>"]` table per origin records the pinned key id, the selection proof's checkpoint, and the recorded accepted state and clock floor; a byte-identical lock is never rewritten ([ADR-0051](./docs/adr/0051-registry-dependency-sources.md)). `--frozen` re-hashes the archive + tree, compares both to the stored hashes, and refuses any link inside an installed module; for registry entries, `--frozen` and `--offline` also verify the committed selection proof from the manifest pin, and `--frozen` re-derives the module tree from the proof-authenticated archive, because `computedHash` is unsigned. v1 and v2 lockfiles fail to load with a clear migration hint. A v3 lockfile is a hard error too: every command that reads the lock (`install`, `add`, `remove`, `update`, `outdated`, `--frozen`, `--offline`) refuses it and changes nothing, pointing to `lwpt repair`, the only command that upgrades v3 to v4 — without network and without changing dependency versions, by re-deriving every module from its archive or source and never trusting the v3 tree hash. Corrupt lockfile → delete + re-run `lwpt install` to regenerate. See [ADR-0008](./docs/adr/0008-lockfile-schema-v2-archive-hash.md) (v1→v2 archiveHash split), [ADR-0009](./docs/adr/0009-source-syntax-and-tag-resolution.md) (v2→v3 source-syntax refactor), and [ADR-0052](./docs/adr/0052-lockfile-schema-v4-framed-tree-digest.md) (v3→v4 framed tree digest). Any further schema break requires an ADR that ships a machine migration from the previous schema; "delete the lockfile and reinstall" is not a migration.

- **AGENTS.md, Safety / Boundaries.** The bullet on committed state limits
  changes to `.lwpt/modules/` and `.lwpt/archives/` to `lwpt install` and
  its `add` and `remove` frontends. `lwpt repair`'s migration publishes
  re-derived modules and can restore an archive from the per-user cache, so
  add one sentence that permits exactly that case and nothing else:

  > `lwpt repair` writes this state only to upgrade a schema-v3 lockfile to v4 ([ADR-0052](./docs/adr/0052-lockfile-schema-v4-framed-tree-digest.md)): through the install transaction, under the install lock, it re-derives each locked module from its verified archive, proof, or source and republishes the modules, archives, proofs, cfg, and lockfile. It never runs on a v4 lockfile and never resolves or fetches.

- **`docs/quick-start.md`, "Recovery from a crashed install".** Replace
  "Repair never touches `.lwpt/modules/`, `.lwpt/archives/`, or the last
  successfully published build output." with:

  > Repair never touches the last successfully published build output. It changes `.lwpt/modules/`, `.lwpt/archives/`, and `lwpt.lock` only when the lockfile is schema v3: it then upgrades the lockfile to v4 without network access and without changing dependency versions, re-deriving each module from its committed archive or source ([ADR-0052](./adr/0052-lockfile-schema-v4-framed-tree-digest.md)). Commit the resulting `lwpt.lock`.

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
| The digest matches the specification | `LWPT.Core.Test.pas` pins every vector in section 2 on all six targets, except that the on-disk case-collision vector is pinned on the Linux legs. The Windows legs build the `süß.pas` and U+1D518 fixtures through the UTF-16 API, so the supplementary-plane name exercises surrogate-pair conversion. |
| The case tiebreak is pinned | On every target, a unit test sorts the in-memory list `a.pas`, `A.pas` and the list `A.pas`, `a.pas` with `TreeHashPathCompare`; both give `A.pas`, `a.pas`. On the Linux legs, the two-file tree hashes to the pinned `ce003a22…` whichever order it was created in. |
| #352's substitution changes the digest | Unit test: the two trees from section 2 give equal legacy digests and different `tree2` digests. Integration, once for each source kind (local, workspace, git-host fixture, URL, registry): install the `json` package, apply the substitution in `.lwpt/modules/json`, and `--frozen` fails with a tree-hash mismatch while the lock and archives are byte-identical. |
| Streaming equals the buffered definition | For sizes of chunk − 1, chunk, and chunk + 1: a CR as the last byte of a chunk followed by an LF, a CR at end of file, a NUL only in the last chunk after CRLFs in the first, and an empty file. Each per-file digest equals `SHA-256(NormalizeTreeHashContent(whole file))`. |
| The tree is not buffered | Hashing a tree with one 64 MiB file raises peak heap use (FPC heap status) by less than 1 MiB. |
| Cross-platform identity | The CRLF and LF trees give one digest, the fold-order vector holds on Windows, and CI's `install --frozen` passes on all six targets against the upgraded LWPT lock. |
| Invalid paths fail closed | On POSIX, a file name that is not well-formed UTF-8 fails the digest, and the error names the escaped path. On Windows, names containing a lone high surrogate (U+D800), a lone low surrogate (U+DC00), or a reversed pair (U+DC00 U+D800) each fail the digest with an error naming the escaped UTF-16 name. A tree holding two such names that U+FFFD replacement would merge also fails, and never yields a digest. |
| Inventory and links | A `CopyDirTree` copy of a tree with a file link and a directory link has the same `tree2` digest as the original, so rollback retention succeeds. `--frozen` fails, naming the path, for a file link, a directory link, and a dangling link inside an installed module. |
| v4 writer and loader | An install writes `version = 4` and `sha256-tree2:` values. The lock round-trips. A v4 lock with one `sha256:` `computedHash` fails to load and names the entry. A `version = 5` lock fails with the "reads up to v4" message. The v1 and v2 hints are unchanged. |
| Every command refuses v3 and changes nothing | Against a committed v3 fixture project (git-host, local, workspace, and registry entries, plus an interrupted transaction's rollback files): `install`, `add`, `remove`, `update`, `outdated`, `install --frozen`, and `install --offline` each fail with the `ELockfileError` message, which names `lwpt repair` and the delete-and-install alternative. The transport seam records zero requests. `lwpt.toml`, the lock, the cfg, modules, archives, proofs, and `.lwpt/tmp/` are byte-identical afterwards. |
| `lwpt repair` upgrades without network and without moving versions | The fixture advertises a newer satisfying tag, and the transport seam records zero requests. Afterward: `resolvedRef` and `resolvedCommit` are unchanged; modules and archives are byte-identical; the lock diff contains only `version`, `computedHash`, and decision-11 accepted-state lines; `--frozen` passes. In a registry project, the selection proof is carried forward byte for byte. |
| No churn after the upgrade (decision 11) | After `lwpt repair`, an online `install` with an unchanged selection and an `install --offline` both leave the v4 lock byte-identical. The same holds when the lock written on Linux is installed on the Windows and macOS legs. |
| `lwpt repair` never trusts the v3 hash | A committed module altered by the #352 substitution under a v3 lock, with its `computedHash` recomputed to the matching legacy value, is replaced by the re-derived tree and named in the output. A missing archive and an archive with a flipped byte, with no copy in the per-user cache, each fail with the migration-specific message from section 5. The test asserts the full text: the archive path, "run `lwpt repair` again", and the delete-and-install alternative with its network and version warning. A deleted registry proof document fails with the same message naming its hash path. Each failure rolls back and leaves the lock v3 and every other file byte-identical. A manifest that disagrees with the lock fails with its hint and leaves the lock v3. A v4 lock is left untouched. |
| Downgrade | A v4 lock rewritten as v3 with legacy digests of a forged tree is refused by `--frozen` and every other reader, and `lwpt repair` replaces the forged tree. |
| Legacy rollback files | A pending transaction whose rollback file holds `tree:sha256:` is recovered by `lwpt repair` on a v3 lock, and by `install` once the lock is v4. |
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
- **Install-class commands upgrade a v3 lock automatically.** Rejected by
  decision 2. An online install would upgrade and move range dependencies
  in one step, so a schema migration could arrive with unreviewed version
  changes.
- **`--frozen` verifies v3 with the legacy digest and warns for a
  transition release.** Rejected by decision 2. It keeps the bypass open
  for any project that never upgrades, and a v4-to-v3 rewrite would reopen
  it.
- **`lwpt install --offline` writes v4 once.** Rejected by decision 3. It
  breaks `--offline`'s documented promise that `lwpt.lock` stays
  byte-identical.
- **Delete the lock and run `lwpt install` as the only migration, as for
  v1 and v2.** Rejected as the primary path by decision 3. It needs network,
  moves every range dependency, and drops `reachableFrom` proofs and
  registry accepted state. The hint still mentions it as an alternative.
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
- Every project runs `lwpt repair` and commits `lwpt.lock` once. Build and
  test caches miss once. Binaries older than v4 cannot read a v4 lock.
- Until a project upgrades, every command that reads its lock fails with
  the migration message. CI jobs that upgrade the binary without the lock go
  red with that message, and nothing in the checkout changes.
- `lwpt repair` gains a lock-writing step. It runs only on a v3 lock, under
  the install lock and the install transaction's rollback.
- Non-ASCII file names must be well-formed UTF-8 to be hashed. The
  Windows extractor's ANSI-code-page path handling is unchanged by this
  record, so non-ASCII names in dependencies stay unportable on Windows
  until the extraction side is fixed separately.
- The legacy digest survives only to recover pre-upgrade rollback files and
  to pin its own tests.

## Decisions

The maintainer settled these on 2026-09-29. The sections above already
apply them.

1. **Milestone: 0.8.0.** 0.8.0 is the release where registry lock entries
   first ship, so no released lock ever carries a registry entry under v3,
   and registry adopters rewrite their locks once. It also closes the
   git-host, URL, and local `--frozen` bypass, a `SECURITY.md` in-scope
   class, in the release that makes `--frozen` a registry trust boundary.
   Deferring to 0.9.0, so that #169 and #170 could be designed against the
   new digest, was rejected: it would ship v3 registry locks and keep the
   bypass open for another release.
2. **A v3 lock is a hard error, as v1 and v2 are.** `install`, `add`,
   `remove`, `update`, `outdated`, `--frozen`, and `--offline` refuse it and
   change nothing. No command silently upgrades it. A schema migration is
   then always a deliberate, reviewable step and never arrives bundled with
   version changes from an online install. `--frozen` never verifies a
   legacy digest, so neither an unupgraded project nor a v4-to-v3 rewrite
   can reopen the bypass. The rejected options were automatic upgrade by
   install-class commands and a transition release in which `--frozen`
   verified v3 with a warning.
3. **`lwpt repair` is the upgrade, and the only command that writes v4 from
   a v3 lock.** It works without network and without changing dependency
   versions. It re-derives every module from its archive, proof, or source
   anchor, never trusting the v3 `computedHash`, and writes v4 through the
   install transaction. The hard-error message points to it, and also says
   that deleting the lock and running `lwpt install` works but needs network
   and moves range dependencies. Repair already recovers state left by an
   older or crashed binary, and it carries no byte-identical promise.
   Writing v4 from `install --offline` was rejected because it would break
   that command's byte-identical promise. After the upgrade, decision 11 of
   ADR-0051 holds unchanged, and recovery keeps accepting rollback files
   written with the legacy digest.
4. **No "last break" claim.** v4 is not declared the last schema break in
   v1. Instead, any further break requires an ADR that ships a machine
   migration from the previous schema, as the AGENTS.md text above states.
   ADR-0009's claim did not hold, and a rule about how breaks happen
   protects consumers better than a promise that none will.
