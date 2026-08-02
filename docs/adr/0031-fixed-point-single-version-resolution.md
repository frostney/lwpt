# Resolve one graph-wide concrete version before publication

FPC exposes one global unit namespace, so an install graph cannot safely carry
two versions of one package. Resolving the first requirement encountered and
checking constraint pairs after fetch was insufficient: every pair can overlap
while the complete constraint set is empty, and the old walk published archive
and module state before it knew whether the graph was valid. This ADR completes
[issue #36](https://github.com/frostney/lwpt/issues/36).

LWPT now resolves materializing installs through deterministic fixed-point
rounds. A round starts from all root requirements, expands one candidate per
package, and accumulates every transitive requirement from those candidate
manifests. After the complete round, the resolver selects the highest
advertised SemVer tag satisfying the whole requirement set. Any changed
selection starts a new round. Repeating a prior selection vector is an
oscillation and fails; LWPT does not backtrack to a lower parent candidate.
An unsatisfied node does not emit a terminal conflict while independent queue
entries remain: those entries may still contribute requirements to the same
node. The final diagnostic is built only from the complete reachable
requirement set accumulated for the round.

Source identity is part of resolution. Requirements with the same package name
must name the same canonical source and extraction policy. Glob policy is
canonicalized once at manifest intake: backslashes become manifest-path `/`
separators, duplicates are removed, and case remains significant exactly as it
does during matching. Source conflicts are reported only after the reachable
queue has contributed all independent requirements, so the diagnostic names
every requirer and canonical source. A `workspace:<spec>` requirement is
normalized through root workspace discovery to the same local source identity
and candidate as its auto-discovered node; its range or exact version is still
checked against that workspace's declared version. Git smart-HTTP advertised refs are the
authority for literal tags and SemVer tags. Lightweight tags identify their
advertised object SHA; annotated tags identify the commit from their `^{}`
peeled ref. A tag and an explicit SHA unify only when that advertised commit
identity proves they are the same artifact. LWPT never guesses equivalence
across repositories or archive templates.

Archive downloads use that proven commit SHA rather than the mutable
user-facing ref. The v3 lock entry retains both `resolvedRef` for diagnostics
and `resolvedCommit` for immutable fetch/frozen identity, plus source-policy
and complete-constraint fingerprints. Frozen verification continues to accept
early v3 entries when their existing fields prove one unambiguous identity.
Only ambiguous entries -- such as a named Git ref combined with an explicit
SHA but no recorded authoritative commit -- fail with an instruction to run a
normal install and regenerate the additive evidence.

All candidate archives, extracted trees, and copied local sources remain below
`.lwpt/tmp/resolver-plan-*` during discovery. Complete source, identity, and
version validation happens before any candidate is published. Only the stable
plan moves the exact filtered candidate snapshot into committed state; local
and workspace sources are never reread or relinked during publication.
Lockfile and cfg writes follow. Before any committed path changes, LWPT makes a
content-validated rollback copy without removing the reader-visible old path.
Files, directories, and links retain their exact filesystem type; symlink and
junction rollback copies preserve their raw targets rather than copying through
them. LWPT journals each copy below one transaction root in `.lwpt/tmp/`. A
committed marker distinguishes cleanup from rollback after a crash.
`lwpt repair` restores a pending journal before ordinary tmp cleanup; normal
rollback validates every
backup, catches each restore failure independently, attempts every later
restore, retains failed evidence, and adds all rollback failures to the
original error. Add/remove publishes the manifest only after all other
fallible graph changes have succeeded. Conflicts name the
canonical source plus every requirer and constraint for the package.

## Considered Options

- **Keep pairwise `RangeIntersects` validation.** Rejected because pairwise
  overlap does not imply a non-empty intersection across three or more ranges.
- **Publish the first candidate and replace it when later constraints arrive.**
  Rejected because an invalid graph could mutate committed zero-install state.
- **Backtrack through lower parent versions.** Rejected. It makes selection
  order and search bounds part of the package contract, hides the highest
  candidate's incompatible transitive graph, and was not required for 0.5.0.
- **Treat matching tag text as artifact identity.** Rejected because identical
  names across different sources do not prove identical bytes or commits.

## Consequences

- Resolution may fetch and extract more than one candidate for a package across
  fixed-point rounds, but remote ref advertisements and unchanged candidate
  archives are cached for the transaction.
- SemVer 2.0.0 precedence chooses the highest satisfying tag; build metadata
  does not affect precedence.
- Direct URL and local sources remain unversioned. Conflicting source identities
  fail rather than being coerced into a versioned model.
- Local/workspace committed trees are immutable filtered snapshots of the
  validated plan, including for sources located inside the project root.
- Frozen install remains a network-free verification of the committed graph and
  lockfile rather than repeating materializing discovery. Compatible early v3
  lockfiles remain valid; missing identity evidence is rejected only when the
  manifest makes that identity ambiguous.
- Multiple installed versions, nested unit namespaces, and dependency-graph
  backtracking remain explicit non-goals.
