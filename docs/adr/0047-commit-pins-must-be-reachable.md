# Commit-SHA pins must be reachable from an advertised branch or tag

Issue [#303](https://github.com/frostney/lwpt/issues/303) found that a dependency pinned to a commit SHA installed whatever the host's archive endpoint served for that id. GitHub and GitLab serve commits that exist only in forks, pull requests, or merge requests under the upstream repository's name, so `actions/checkout@c7d749a2d57b4b375d1ebcd17cfbfb60c676f18e` (Chainguard's documented imposter commit) installed fork code that looks like upstream. When every requirement for a dependency was a SHA, resolution skipped ref listing entirely.

This ADR amends [ADR-0009](./0009-source-syntax-and-tag-resolution.md) and the AGENTS.md hard constraint "Git sources use HTTP archive endpoints, not the git protocol". Archives remain the only source of dependency content. The git smart-HTTP upload-pack service, already used for tag listing, may now also carry commits-only reachability proofs.

## Decision

- **A commit-SHA pin is accepted only when the commit is reachable from an advertised `refs/heads/*` or `refs/tags/*` tip.** `refs/pull/*`, `refs/merge-requests/*`, and every other namespace never count. The rule applies when all of a dependency's requirements are SHAs. When a SHA constrains a named requirement (a tag, range, or branch), the selected commit is already an advertised tip.
- **Only full 40-character SHAs can be pinned.** An abbreviated pin fails online resolution with an error that asks for the full SHA. A prefix cannot be proven: some hosts resolve it to any matching object, including one that exists only in a fork.
- **Exact tip first.** If the pin equals an advertised branch head, tag, or peeled annotated tag from the listing the resolver already makes (`info/refs`), it is accepted with no extra request.
- **Otherwise, a set-difference proof over protocol v2** (`LWPT.GitProtocol.ProveCommitReachable`):
  1. `GET <repo>/info/refs?service=git-upload-pack` with `Git-Protocol: version=2`. The host must offer `ls-refs` and `fetch` with the `filter` feature, and a `sha1` object format. Otherwise the pin is refused and the error suggests pinning a tag or branch.
  2. `ls-refs` with `peel`, `symrefs`, and prefixes `HEAD`, `refs/heads/`, `refs/tags/` gives the tips (tags peeled to commits) and the default branch.
  3. One shallow `fetch` (`deepen 1`, `filter tree:0`) of the tips and the pin gives their committer dates. The dates only order the next step. A host that refuses this request leaves the probes unordered.
  4. Up to four tips committed closest after the pin, then the default branch, are probed one at a time with `want <tip>`, `have <pin>`, `filter tree:0`, and no `done`. A tip that cannot reach the pin costs only an acknowledgment. When the host is ready, it streams `pack(tip --not pin)`. A `NAK` means the host has no such object, so the pin fails as unknown.
  5. The remaining tips go in one final round, with `have` for the pin and for every probed tip whose pack proved it does not contain the pin.
  6. Every pack is requested with `filter tree:0` and without `thin-pack`. `LWPT.GitPack` recomputes each commit's SHA-1 from the received bytes and walks parent links from the tips. The pin is reachable if and only if a received commit lists it as a parent. The walk is complete: every commit on a path from a tip to the pin is not an ancestor of the pin, nor of an excluded tip (that tip would then contain the pin), so the host must send it. The walk is sound: every hop is hash-verified from an advertised tip.
- **Negotiation alone is never trusted.** upload-pack marks a `have`'s parents as common, so `ready` also fires for a fork commit that sits on top of upstream history.
- **Limits** (named constants):
  - `MAX_UPLOAD_PACK_RESPONSE_BYTES` (64 MiB) per response, enforced while reading through `HTTPClient`'s `MaxResponseBodyBytes`. An oversized response raises the new `EHTTPResponseTooLarge` (`httpclient` 0.6.0) and the pin is refused.
  - The pack reader caps the object count (`MAX_PACK_OBJECT_COUNT`, 1,000,000), each inflated object and delta result (`MAX_PACK_OBJECT_BYTES`, 8 MiB), the total inflated bytes (`MAX_PACK_INFLATED_BYTES`, 256 MiB), and the inflate ratio (`MAX_PACK_INFLATE_RATIO`, 32 times the pack size plus 1 MiB).
  - It range-checks every delta instruction, resolves `REF_DELTA` bases that appear before or after the delta, and rejects trees, blobs, thin packs, delta cycles, checksum mismatches, and trailing bytes.
  - A proof makes at most nine requests after the listing.
- **Scope of the git protocol.** Only ref listing and commits-only reachability proofs. No tree or blob is requested or accepted. Content still comes from the archive endpoint and is hashed into the lockfile as before. LWPT speaks HTTP only and never runs `git`. Every upload-pack request carries the dependency's destination policy (`LWPT.FetchPolicy`), like ref listing and archive fetches. Commands are posted to the repository URL that the capability request resolved, so a renamed repository keeps working.
- **When the proof runs.** Whenever an online install, `add`, `remove`, or `update` selects a SHA pin whose lock entry is new or records a different commit. An existing lock entry with the same source identity and the same commit is not proven again. It was proven when written and is trusted like the committed archive it names. `--frozen` and `--offline` never touch the network, so they never prove anything.
- **The lockfile schema does not change** (v3).

## Considered Options

- **Negotiation only (`ready` without a pack).** Cheapest. Rejected as unsound: the linux `refs/pull/932/head` commit and the actions/checkout imposter both got `ready` or `ACK` from a branch that does not contain them.
- **A `deepen-since` graph walk.** Rejected: skewed commit dates reject valid pins, and it transfers more than the set difference (vscode: 97.9 MB against 16.5 MB).
- **Host APIs such as GitHub's compare endpoint.** Rejected for the reasons in ADR-0009: host-specific, JSON, and rate-limited.
- **Re-verify every locked pin on every online install.** Rejected. It adds requests to every install and fails installs that were already reviewed once upstream rewrites history. Checking at the moment a pin enters or changes the lock catches the attack (a manifest or PR that pins fork code), while the lock itself is reviewed like any committed content.
- **Accept abbreviated SHAs with a warning.** Rejected: an unverified pin is the defect this ADR removes.

## Consequences

- A pin to a fork-only, pull-request-only, or unknown commit fails before its archive is fetched, and nothing is published. `lwpt add` leaves `lwpt.toml` unchanged (ADR-0019's install-before-write ordering).
- Abbreviated SHA pins that installed before now fail online resolution. `--frozen` and `--offline` keep working from an existing lock. The README example uses a full SHA.
- A pin can become unprovable. If upstream force-pushes or deletes the only branch that contained the commit, the next change to that lock entry fails with an error naming the commit. Existing lock entries keep installing. Users see this as "pin a commit from the repository's own history".
- Hosts without protocol v2 `filter` support can still use pins that equal an advertised tip. Other pins on those hosts must switch to a tag or branch. GitHub, GitLab, Bitbucket, and Codeberg all advertise `filter`.
- Cost, measured against live hosts (spike and `LWPT_ENABLE_NETWORK=1` tests):
  - Exact-tip pins cost nothing beyond the listing.
  - The actions/checkout imposter commit is refused after 9 requests and 259 KB.
  - A 2023 actions/checkout commit is proven through `v3.5.3` in 4 requests and 88 KB.
  - Nearest-tip probing keeps old pins in large repositories small. For a 2015 linux commit, the spike measured 506 KB through the nearest tag against 489 MB from the default branch.
  - Proofs that genuinely need more than 64 MiB, such as a fork commit based on old linux history, are refused rather than trusted.
- FPC's SHA-1 has no collision detection. Forging a path would need a second preimage of an existing commit, so the risk is accepted.
- Recorded upload-pack exchanges under `tests/fixtures/git-reachability/` are keyed by the SHA-256 of the request body. A change to the requests the prover sends must re-record them with the command in `source/LWPT.GitProtocol.Test.pas`.
