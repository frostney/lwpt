# Build targets use a dependency-aware bounded parallel scheduler

`lwpt build` treats manifest build entries as a directed acyclic graph. An
inline build entry may declare `depends = ["target", ...]`; named builds include
the requested targets' transitive prerequisites. Unknown prerequisites and
cycles fail before hooks, session creation, or compiler work.

Ready targets run concurrently by default. `--jobs=<n>` sets a positive
invocation-local ceiling and `--jobs=1` provides sequential execution. The
scheduler also acquires one `LWPT.WorkerBudget` lease for every active compiler,
so the machine-wide budget can reduce effective concurrency below that ceiling.
Compiler output is captured per worker, drained while the child runs, and
replayed with final results in manifest order. Exceptional scheduler cleanup
terminates active compiler children and waits for them, covering cancellation
and process reaping on both Unix and Windows.

## Considered options

- **Infer prerequisites from Pascal source.** Rejected. Unit dependencies do
  not reliably identify build-output dependencies, and parsing FPC's complete
  conditional source model would duplicate the compiler.
- **Run every target concurrently and publish at the end.** Rejected. A
  dependent must not start until each prerequisite has published successfully;
  otherwise stale or failed prerequisites can still launch downstream work.
- **A manifest DAG plus worker-budget leases.** Chosen. The graph is explicit
  and host-independent, while the existing coordinator supplies bounded
  capacity across worktrees and processes.

## Consequences

- Whole-build prebuild runs once. A target's prebuild hooks run once before its
  worker starts; its postbuild hooks run once against the private candidate
  before publication. Dependants become ready only after atomic publication.
- A failed or stale target blocks only its transitive dependants. Independent
  targets continue, and blocked targets appear as failures in the
  manifest-ordered final report.
- Dependency-free manifests preserve ADR-0020's batch publication contract:
  whole-build postbuild sees all private candidates and gates publication. A
  graph requires progressive publication, so whole-build postbuild runs once
  after every selected output publishes. It can fail the build but cannot roll
  back prerequisites. Transformations remain per-target hook work.
- The implementation uses FreePascal RTL threads and `TProcess` only. Tests
  cover startup, output capture beyond a pipe buffer, cancellation, reaping,
  dependency ordering, failure isolation, `--jobs=1`, and deterministic result
  order through code paths compiled on Unix and Windows.
