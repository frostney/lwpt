# LWPT

LWPT is a single-binary Pascal toolkit driven by a single TOML manifest. The toolkit's own surface — what a project declares, what LWPT writes to disk, how it talks about dependencies — is small enough that a shared glossary keeps PR review crisp and prevents new contributors from importing analogies from npm/Cargo/Boss that *look* right but quietly diverge.

## Language

### Manifest, lockfile, cfg

**Manifest**:
The single source of truth for what a project declares — its name, version, units, dependencies, build entries, formatter scope, and toolkit-state overrides. Always lives at `lwpt.toml` (derived from `PROGRAM_NAME`); never anywhere else.
*Avoid*: `package.json`, `Cargo.toml`, `pyproject.toml`, "project file", "config file". The manifest is hand-edited; everything else on disk is generated from it.

**Lockfile**:
The machine-written schema-v4 record at `lwpt.lock` of every resolved dependency's declared source, resolved ref and commit, canonical source and constraint identity, fetched URL, framed extracted-tree digest, and archive hash. Entries may also carry `resolvedRefKind` and `reachableFrom` (see *Reachability proof*); a registry entry carries `registryOrigin` and `registryRecord` instead of a commit, and one `[registry."<identity>"]` table per origin records its trust pin's key ID, *Selection proof*, and recorded *Accepted state*. Written only by `lwpt install`, its `add` / `remove` / `update` frontends, and `lwpt repair` (interrupted-install restore and the v3 upgrade); verified by `--frozen`, restored from by `--offline`. Never hand-edited.
*Avoid*: "snapshot" (see *Module snapshot* and *Registry snapshot*), "freeze file", "version pin". A pin is a manifest entry; the lockfile is the resolved graph.

**Cfg**:
The FPC response fragment at `lwpt.cfg` listing `-Fu` and `-Fi` paths. Emitted by `lwpt install`; consumed by `fpc @lwpt.cfg` directly and by every other LWPT subcommand. The through-line that makes the package manager the foundation for the rest of the toolkit.
*Avoid*: "search paths file", "fpc args", "config" alone (it's never just "config" — always "cfg").

### Dependency graph

**Module**:
An extracted dependency tree under `.lwpt/modules/<dep>/`. The thing FPC's `-Fu` paths point at. Always one per direct or transitive dependency name; never multiple versions of the same name (the resolver forbids it — see *Conflict*).
*Avoid*: "Pascal unit" (that's a `.pas` file), "package" (too overloaded), "node modules" (npm parallel; LWPT modules dir is committed, not regenerable).

**Module snapshot**:
The exact validated, include/exclude-filtered tree that the install transaction publishes as a module from the stable resolver plan, whatever the source kind. Its framed digest is the lock's `computedHash`. Never a live link to its source.
*Avoid*: "snapshot" alone (a *Registry snapshot* is origin state named by a signed checkpoint), "copy", "link".

**Archive**:
The committed `.tar.gz` at `.lwpt/archives/<dep>-<safe-ref>.tar.gz` that produced a module. Source of truth for hash verification on `lwpt install --frozen`. Per ADR-0002 Z-both, archives live alongside extracted modules so a tampered modules tree is detectable.
*Avoid*: "tarball" (acceptable in prose, but on disk it's an archive), "cache" (a cache is regenerable; archives are committed).

**Source kind**:
Where LWPT fetches a dependency from, named by its source string. One of `githost` (default host `github`; the `gitlab:` / `bitbucket:` prefixes or a custom `[sources.<name>]` host select the others), `url` (any `https://...` tarball), `local` (path or `local:` prefix), `workspace` (the [`workspace:` protocol](#workspace-protocol)), or `registry` (`registry:[<alias>/]<package>`, selected from a *Registry snapshot* through the root `[registries]` table). Auto-discovered workspaces enter the graph as `local` dependencies. See ADR-0009 and ADR-0051.
*Avoid*: "protocol" (HTTPS is the protocol; the source kind is the URL-template + ref semantics), "repository type".

**Dependency include / exclude**:
The optional `include = [...]` and `exclude = [...]` glob arrays on a dependency. They select the *Module snapshot* published from a fetched archive or local source. The retired `subdir` field is a hard error; use an include such as `src/middleware/**` instead.
*Avoid*: "subdir" (retired), "include path" (that's `-Fi`), "filter" alone (does not say whether files are added or removed).

### Resolver

**Resolver**:
The deterministic fixed-point rounds that start from every root requirement, expand one candidate per package, accumulate every transitive requirement and canonical source identity, and repeat when the highest satisfying selection changes. Only a stable, completely validated plan is published. Produces a flat graph because FPC has one global unit namespace; no nested versioning is possible.
*Avoid*: "dep walker" alone, "SAT solver" (LWPT selects the highest satisfying candidate and detects oscillation; it does not backtrack).

**Conflict**:
The complete reachable requirement set for one package having no satisfying version, or naming incompatible canonical sources or extraction policies. Hard error per the flat-graph rule. Reported only after independent requirements have contributed, with every requirer named so the manifest tree is editable to resolve.
*Avoid*: "version mismatch", "dependency hell", "conflict" used loosely (it is specifically graph-wide incompatibility for one package identity).

### Install + builds

**Frozen**:
The `lwpt install --frozen` mode that refuses to update the lockfile, refuses network, and verifies committed toolkit state against the lockfile. CI's safety floor. Frozen is verification-only: it writes no committed state and never re-materialises a missing module. It re-derives a local or workspace module snapshot from its source, and a registry module from its proof-authenticated archive, in private scratch; a missing local or workspace source fails. Contrast *Offline install*, which restores state.
*Avoid*: "locked", "strict", "ci mode", "offline" (a different mode). Frozen is the specific term.

**Offline install**:
The `lwpt install --offline` mode that restores the locked graph without network: it materialises git-host, URL, and registry modules and the cfg from committed archives or the per-user archive CAS, restores missing registry proof documents from the per-user document store, and leaves the lockfile byte-identical. Local and workspace modules are still copied from their source directories, so those must be present: a missing local or workspace source fails. Requires an existing lockfile; anything it cannot restore and verify fails before publication. Mutually exclusive with `--frozen`.
*Avoid*: "offline mode" alone, "cached install", "frozen" (frozen verifies; offline restores).

**Install transaction**:
The single `lwpt install` operation that, under the install lock, resolves dependencies, materialises toolkit state, verifies frozen state when requested, and commits lockfile/cfg changes as one coherent update. It is LWPT's atomic-ish toolkit-state update, not a database transaction.
*Avoid*: "install process", "install pipeline", "transaction" alone.

**Zero-install**:
The default property of every LWPT project: after `git clone`, `fpc @lwpt.cfg` builds the project without running `lwpt install` first. Achieved by committing `.lwpt/modules/` and `.lwpt/archives/`. See ADR-0002.
*Avoid*: "checked-in deps" (Yarn's term), "vendored" (retired per ADR-0017 — see *Vendored*).

**Bootstrap**:
The one-time `scripts/bootstrap.pas` (via `bootstrap.sh` / `bootstrap.bat`) that produces the first `build/lwpt` binary on a fresh clone. After bootstrap, `./build/lwpt build` is the steady-state entry point.
*Avoid*: "setup", "install" (bootstrap is for the toolkit itself, not for a project's dependencies).

**FPC packages slice**:
The curated set of FPC packages made available to a LWPT CI build target. Plural by definition: never a single package, and never a subset of a package. A packages-slice rescope adapts this set to the project currently being built; the inherited GocciaScript-shaped slice was valid for GocciaScript, while LWPT's package-manager path needs its own slice. Individual units such as `zstream.ppu`, `crc.ppu`, or `sockets.ppu` are verification points inside the slice, not the thing being sliced. Native targets may use the package layout from the native FPC install; cross targets may use packages built into the cached cross-toolchain.
*Avoid*: "unit slice", "package slice", "exact RTL units", "completeness bug", "cross-compiled FPC" when the target uses a native FPC package layout.

**Toolkit state**:
Everything under `.lwpt/` at a project's root. `modules/` and `archives/` are committed zero-install state, including `archives/registry-proofs/`, the signed registry documents that prove each locked registry selection (a set derived from the lock). `tmp/` is the gitignored install workspace and rollback journal; `sessions/` is gitignored invocation-private compiler staging. `install.lock` is the install concurrency file, and `session-roots` records identity-verified relocated session namespaces for repair. The gitignored `workers/` is the worker-budget fallback when the per-user state directory is unwritable, and `registry/` is the default data directory of `lwpt registry`. Every published module is a *Module snapshot*, including local and workspace sources.
*Avoid*: "node_modules" (npm-specific naming), "vendor dir" alone (`packages/` is the monorepo-internal "where packages live" — see *Package (graduated)*; `.lwpt/modules/` is the per-project installed-tree location, NOT a vendor dir in the historical Delphi/FreePascal sense).

**Monorepo**:
A project topology where the root `lwpt.toml` declares one or more local-path dependencies whose resolved absolute path lives under the directory containing that root `lwpt.toml`. The idiomatic declaration is the `[workspaces]` section (`include = ["packages/*"]`) — each matched dir with its own `lwpt.toml` becomes a [Workspace](#workspace) and is auto-installed as a [Monorepo dep](#monorepo-dep). The older explicit-`[dependencies]`-with-local-paths form (`httpclient = "./packages/httpclient"`) still works but is verbose; `[workspaces]` is the preferred shape post-ADR-0014. LWPT itself is a monorepo by this definition.
*Avoid*: "submodule" (git-specific), "nested package" (suggests packaging nesting like Maven multi-module).

<a id="workspace"></a>
**Workspace**:
A directory under a manifest-bearing project that contains its own `lwpt.toml` and is discovered by that manifest's `[workspaces]` include globs. Each workspace is a self-contained LWPT package — its own `[package]`, `[build]`, `[dependencies]`, and (optionally) its own tests. `lwpt install` auto-installs every discovered workspace as a [Monorepo dep](#monorepo-dep). Two workspaces with the same `[package].name` in the same discovery set are a hard error. Dependency manifests may also declare `[workspaces]`; those nested workspaces are enqueued by the resolver like any other local-path dep. Mirrors the npm/yarn/pnpm/bun `workspaces` convention; `[workspaces].include` is the LWPT analogue of JS's top-level `workspaces` array. See [ADR-0014 amendment "Workspaces"](./docs/adr/0014-packages-extraction.md#amendment-workspace-auto-discovery).
*Avoid*: "workspace" applied loosely to any local-path dep — the term is reserved for [workspaces]-discovered packages specifically.

<a id="workspace-protocol"></a>
**`workspace:` protocol**:
A dependency source string of the form `"workspace:<spec>"` (e.g. `workspace:*`, `workspace:^0.1.0`, `workspace:1.2.3`) that resolves **strictly** to a discovered workspace of matching name. Used inside a workspace's own `lwpt.toml` `[dependencies]` to depend on a sibling workspace. If no matching workspace is found, the resolver hard-errors naming the available workspaces — it never falls through to a registry or git-host lookup. Mirrors yarn / pnpm / bun's `workspace:` protocol. The `<spec>` is either `*` (any) or a SemVer range/exact that gets matched against the target workspace's `[package].version`.
*Avoid*: "workspace dep" alone (use [Monorepo dep](#monorepo-dep) for the broader concept; this term is specifically about the `workspace:`-prefixed source string).

<a id="monorepo-dep"></a>
**Monorepo dep**:
A local dependency whose resolved path is under the project root, usually a discovered workspace. Resolution reads it as a candidate, but publication copies its *Module snapshot* into `.lwpt/modules/<name>/`; later source edits require another `lwpt install`, and `--frozen` re-derives the snapshot from the source and fails on drift or a missing source. This keeps committed zero-install state identical to the stable plan instead of exposing a live mutable link.
*Avoid*: "workspace dep" (not every in-project local dependency was workspace-discovered), "linked dep" (materializing installs no longer publish links).

**External-path dep**:
A local dependency whose resolved path **escapes** the project root (`../../X`, absolute paths to elsewhere). Like an in-project local dependency, it is published only as its *Module snapshot*; the term distinguishes source location, not installation strategy. `--frozen` checks the committed snapshot against the lockfile, then re-derives it from the source and fails on drift or a missing source.
*Avoid*: "remote local" (oxymoron), "linked dep" (local dependencies publish snapshots).

### Fetch trust

**Destination policy**:
The per-request network rule every dependency request carries on every hop: HTTPS only, only the hosts its source allows (any host for a direct URL), and only globally reachable addresses. It covers ref listing, reachability proofs, and archive fetches; a registry request may reach only its *Contact*'s host and follows no redirects.
*Avoid*: "allowlist" alone (hosts are one of three checks), "firewall", "SSRF filter".

**Reachability proof**:
The commits-only git smart-HTTP exchange that accepts a commit-SHA pin only when it is a full 40-character SHA reachable from an advertised `refs/heads/*` or `refs/tags/*` tip. The lock records the proving ref as `reachableFrom`; `--frozen` and `--offline` never prove, and warn about an entry without one.
*Avoid*: "commit verification", "signed commit", "SHA check" (it proves ancestry, not signatures or content).

**Moved tag**:
A locked tag that the host now advertises at a different commit, re-publishes under another SemVer spelling, or replaces with a branch. The install fails until a reviewed `lwpt install --accept-moved-tags` re-pins it. Branches may move.
*Avoid*: "retag", "force-pushed tag", "tag drift".

### Registry

**Registry origin**:
The authority that assigns monotonic snapshot sequences and signs checkpoints for its packages, initialized by `lwpt registry init` (role `origin`, the default) and served by `lwpt registry serve`. It alone accepts publication.
*Avoid*: "registry server" (a server runs either role), "upstream" alone, "index".

**Registry mirror**:
An independently operated, read-only registry that `lwpt registry sync` fills with an origin's verified documents and archives. It presents the origin's identity and signatures, never its own namespace, and serves without contacting the origin.
*Avoid*: "mirror" in the GocciaScript sense (see *Value mirror (GocciaScript)*), "proxy", "cache", "replica".

**Role**:
Whether a registry data directory is an `origin` or a `mirror`, fixed at `lwpt registry init --role` and never changed by reconfiguration.
*Avoid*: "mode", "registry type".

**Origin identity**:
The stable canonical URI that names a registry origin (HTTPS for every consumer). It is part of package identity `(origin identity, name, version)` and survives every move of the origin or its mirrors.
*Avoid*: "origin URL", "registry URL", "base URL" (a base URL is where one instance is reached; see *Contact*).

**Contact**:
The base URL of one origin or mirror instance as a consumer tries it. A `[registries.<alias>]` declaration lists its mirror contacts, tried in order, before its origin contact. Contacts never enter package identity.
*Avoid*: "endpoint", "registry URL", "server".

**Trust pin**:
The Ed25519 root `key-id` and `public-key` of one origin, declared in the reviewed root manifest's `[registries.<alias>]` (or passed to `registry init --role mirror` and `registry publish`). It is the only root of trust: signed rotations extend trust from it, nothing is trusted on first use, and changing it is a human edit.
*Avoid*: "root pin", "manifest pin", "pinned root key", "TOFU key".

**Registry snapshot**:
An immutable, ordered set of exactly one current record hash per package identity, linked to its predecessor and named by a signed checkpoint. Consumers select versions only from a verified registry snapshot.
*Avoid*: "snapshot" alone (see *Module snapshot*), "package list" (`/v1/packages` is an unsigned convenience view), "index".

**Checkpoint**:
The small, expiring document naming an origin's current registry snapshot and sequence, authenticated by a detached Ed25519 signature.
*Avoid*: "head" alone, "tree head", "release".

**Selection proof**:
The signed documents that prove a locked registry selection: checkpoint, signature, rotations, head registry snapshot, and selected records. The lock's `[registry."<identity>"]` table names them, and `archives/registry-proofs/` commits their bytes, so `--frozen` and `--offline` verify from the trust pin without network.
*Avoid*: "registry proof" alone, "attestation", "receipt".

**Accepted state**:
The highest verified registry state per origin identity and trust pin: sequence, registry snapshot, checkpoint, signing key, rotations, and clock floor. It is kept per user, which alone holds the true high-water mark, and in the lock as the recorded accepted state at the last lock change; acquisition must extend both.
*Avoid*: "per-user registry state", "consumer state", "trust store", "high-water mark" alone.

**Clock floor**:
The latest checkpoint `published_at` ever accepted for an origin, kept with each accepted state and a mirror's state. Acquisition refuses while the local clock is earlier, and the floor never goes down; `--frozen` and `--offline` do not apply it.
*Avoid*: "rollback floor", "timestamp floor", "last seen time".

**Document store**:
The per-user content-addressed store of every registry document a consumer verified, beside the per-user accepted state (relocatable with `LWPT_REGISTRY_STATE_DIR`). Every document is re-verified before use; documents off every accepted history are evicted least recently used beyond `LWPT_REGISTRY_STATE_MAX_BYTES`.
*Avoid*: "registry cache" (it is not in the shared cache), "proof store", "registry-proofs" (the committed directory).

**Publication token**:
The bearer credential that authorizes `lwpt registry publish` (or a yank) on one origin, issued by `lwpt registry issue-token` for named package patterns, actions, and a bounded lifetime, and withdrawn by `lwpt registry revoke-token`. The origin stores only a hash of its secret.
*Avoid*: "API key", "auth token", "password", "credential" alone.

### Build lifecycle

**Build request**:
A schema-versioned, compiler-neutral description of one compilation: compiler
identity or version constraint, target tuple, source set and entry point,
defines, ordered extra arguments and search paths, resources, output kind,
build mode, and private output locations. `LWPT.BuildRequest` owns validation
and canonical TOML serialization. The request says what to build; a compiler
driver decides how to express it on a compiler command line.
*Avoid*: "FPC request" (the structure is compiler-neutral), "compiler args"
(an adapter output), "publication fingerprint" (a separate concurrency
snapshot that embeds the request).

**Target tuple**:
The desired output platform carried by a build request: required OS and
architecture plus optional ABI and execution environment. It is independent
of both the host running LWPT and the selected compiler. A compiler capability
set can advertise many native and cross target tuples.
*Avoid*: "platform" alone (host or target is ambiguous), "compiler target"
(wrongly attaches the tuple to one compiler installation), "target" alone
(conflicts with the retired name for a build entry).

**Compiler capabilities**:
A schema-versioned declaration of one compiler identity and version plus every
target tuple, output kind, and build mode its driver can accept. Compatibility
requires matching compiler constraints, target tuple, output kind, and mode;
failure is explicit and never falls back to another compiler or target.
*Avoid*: "compiler entry" (suggests duplicating one entry per platform),
"fallback list" (unsupported requests are errors).

**Compiler driver**:
The adapter that probes a compiler's capabilities, translates a build request
into its command line, and normalizes its output into a build result. Built-in
drivers are `fpc`, `delphi`, `blaise`, and `lakon`; any other driver ID names
an external driver, a profile or embedding-host command that speaks the
versioned TOML protocol as a short-lived child process.
*Avoid*: "backend" alone, "toolchain" (a driver adapts one compiler, it does
not install one), "compiler wrapper".

**Compiler profile**:
A named root-manifest `[compiler.profiles.<name>]` entry that selects a
compiler driver plus an optional runnable command and version constraint.
`[compiler].default` names the project profile and a build entry's `compiler`
overrides it; dependency manifests can neither declare nor select one.
*Avoid*: "toolchain", "compiler config", "executable" / "script" (retired
profile fields).

**Runnable command**:
A direct child-process definition containing one `command` and an ordered
`args` array. Commands containing a path resolve from the project root unless
absolute; bare names use the inherited `PATH`. LWPT starts the process in the
project root, inherits the parent environment, and passes arguments without a
shell. It never infers an interpreter or special-cases a file extension. Hooks,
run tasks, compiler profiles, and host compiler registrations share this
definition while retaining their surface-specific lifecycle and protocol rules.
*Avoid*: "command line" (suggests shell parsing), "script command" (there is no
script distinction), "executable field" (the manifest field is `command`).

**Build result**:
A schema-versioned compiler-neutral outcome containing success, normalized
diagnostics, produced artifacts, and dependency metadata. Compiler-native
messages and paths are translated at the driver boundary before entering this
structure.
*Avoid*: "FPC output" (driver-specific), "process result" (too narrow: the
contract also carries artifacts and dependency metadata).

<a id="hook"></a>
**Hook**:
A root-owned runnable command with one or more lifecycle attachment points. An
optional paired `inputs`/`output` declaration applies shared literal/glob
staleness evaluation: every expression must match, a missing or older output
runs, and a fresh output skips. Bare-string shorthand `"tools/generate"` means
the direct no-argument command `{ command = "tools/generate" }`. Hooks run
sequentially in insertion order, inherit the caller environment, and stop the
phase on the first non-zero exit.
*Avoid*: "hook script" (commands are not implicitly scripts), "trigger"
(suggests event-listener semantics).

**Lifecycle phase**:
The point at which a hook section attaches to a subcommand run. Six top-level sections — `[preinstall]`, `[postinstall]`, `[prebuild]`, `[postbuild]`, `[pretest]`, `[posttest]` — plus the `prebuild` and `postbuild` fields available on each `[build].<entry>` inline table (per-item, build only). `add`, `remove`, and `update` run the install hooks around their install transaction (`update` only when it has something to update); `test --inventory` runs no test hooks. `format`, `repair`, `init`, `run`, `agents`, `outdated`, `duplication`, `health`, and `registry` have no hook surface; the rationale for the original refusals lives in the lifecycle ADR.
*Avoid*: "lifecycle event" (suggests dynamic dispatch), "build phase" (subcommand-specific; we mean any phase of install, build, or test).

### Testing

**Test program**:
A self-contained `*.Test.pas` source discovered by `lwpt test`, compiled into
invocation-private staging, and run as one scheduler job. The discovered
inventory is frozen before `[pretest]`; the hook may prepare a program's inputs
but cannot add programs to the current invocation.
*Avoid*: "test suite" (one program may register several suites), "test case"
(a program contains cases), "test target" (target means an output platform).

**Test selector**:
A project-root-relative positional argument to `lwpt test` that selects test
programs by exact file, recursive directory, or LWPT glob. Multiple selectors
form one deduplicated union, every selector must match, and selection runs
exactly the matching programs.
*Avoid*: "filter" (suggests name-substring matching), "test name" (selectors
identify program paths, not cases registered inside a program).

**Build entry** (build item):
A single binary declaration in the `[build]` table — the thing `lwpt build` compiles, one per iteration. Multi-entry form: `[build.cli] source = "..."` (or the TOML-equivalent inline `[build] cli = { source = "..." }`). Single-entry shorthand: `[build] source = "..."` directly under `[build]` defaults the entry name to `[package].name` and the output to `build/<entry-name>`. Each entry takes `source` (required), `output` (optional), ordered `flags` (optional), an optional compiler profile, an independent optional complete target tuple, and optional per-entry `prebuild` / `postbuild` hook tables. Flags, compiler, and target are root-manifest behavior; dependency manifests cannot select executable policy. Renamed from the pre-ADR-0013 `[targets]`.
*Avoid*: "target" (pre-ADR-0013 term; overloaded with Bazel/Make vocabulary and doesn't match LWPT's verb-noun pairing).

**Build session**:
A project-owned, per-invocation private workspace for compiler outputs and
diagnostic logs. Its storage root may be project-local or relocated, but
ownership and repair remain bound to exactly one project.
*Avoid*: "build directory" (the public output directory is separate),
"temporary directory" (failed sessions are intentionally retained).

<a id="run-task"></a>
**Run task**:
A user-declared root-manifest callable addressed by `lwpt run <name>`. Any
otherwise-unknown top-level section containing `command` becomes a task, such
as `[deploy] command = "tools/deploy"`. It reuses the hook command and optional
staleness fields. Its arguments are manifest-defined only, a fresh task skips
successfully, and a child exit code is propagated exactly. Reserved built-in
subcommand names hard-error. Dependency tasks are dropped without execution.
*Avoid*: "run-script" or "script" (commands include binaries and explicit
interpreters), "recipe" (Just-specific).

**Run**:
The `lwpt run <name>` subcommand. Two behaviours under one verb: if `<name>` matches any registered subcommand, aliases to that subcommand with the remaining args (`lwpt run install --frozen` ≡ `lwpt install --frozen`); otherwise looks up `<name>` in the manifest's [Run task](#run-task) entries and invokes it. `lwpt run` alone lists every callable name. The aliasing layer is in the CLI dispatcher, not in the run-handler — option parsing for subcommands works unchanged.
*Avoid*: "exec" (executes-into-this connotation; lwpt run is dispatch + spawn).

**Agents block**:
The marker-fenced region (`<!-- lwpt:agents:begin -->` … `<!-- lwpt:agents:end -->`) inside a project's `AGENTS.md` that `lwpt agents` writes and `lwpt agents --check` verifies (per ADR-0027). Machine-written from the subcommand registry — the same objects that drive `--help` — plus the manifest's [Run task](#run-task) entries. Byte-deterministic: LF line endings, no version stamp or timestamp, so `--check` fails only on real drift. Everything outside the markers is hand-written and never touched by the toolkit.
*Avoid*: "generated AGENTS.md" (the file is the host; only the block is generated), "agents section" loosely (the term is specifically the marker-fenced region), "agent docs" (harness-side instruction files like CLAUDE.md are a different layer).

### Shared cache

**Shared cache**:
The per-user, disposable store under `LWPT_CACHE_DIR` (or the platform cache
directory) that every project on the machine shares. One aggregate byte budget
(`LWPT_CACHE_MAX_BYTES`) covers all of its namespaces; admission evicts least
recently used objects, and `lwpt repair` is its only maintenance path. Its
paths never enter committed state, and its absence is never a correctness
failure.
*Avoid*: "global cache", "store" alone, "archives" (archives are committed
project state).

**Per-user archive CAS**:
The shared-cache namespace of dependency archives addressed by the SHA-256 of
their raw bytes. An install may copy an object into its plan only when a
lockfile entry or a signed registry record already names that digest, and it
re-hashes the copy before use.
*Avoid*: "download cache", "archive cache" (ambiguous with the committed
`.lwpt/archives/`).

**Build-result cache**:
The shared-cache namespace of verified build-entry artifacts addressed by a
compiler-neutral fingerprint of everything that can change the output. A hit
replaces the compile and is verified before publication; `--no-cache` and
`--clean` bypass it.
*Avoid*: "incremental build" (FPC's own unit reuse is separate), "ccache".

**Test-executable cache**:
The shared-cache namespace of verified compiled test programs, addressed like
the build-result cache under a distinct test-program identity. It reuses
compilation only: every invocation still runs every selected program.
*Avoid*: "test result cache" (pass and fail are never cached).

**Producer lease**:
An operating-system file lock that makes one local process the producer of one
keyed object (a cache miss, a registry publication, a per-user accepted-state
merge) while others wait or refuse. The kernel lock, not its heartbeat
metadata, decides liveness, so a crashed producer releases it.
*Avoid*: "lock file" alone (the guard file outlives the lease), "mutex",
"heartbeat lock".

### Manifest interpolation

**Placeholder**:
A `{name}` token in a manifest string field that the loader substitutes at parse time. LWPT uses two dialects on disjoint surfaces: `{user}` / `{repository}` / `{ref}` apply *only* inside `[sources]` URL templates; the build-lifecycle dialect applies everywhere else that takes substitution — `[build].<entry>.<field>`, top-level hook section fields, per-entry hook fields, and run-task command fields. The build-lifecycle vars are `{package.name}` and `{package.version}` (from `[package]`), `{item.name}` / `{item.source}` / `{item.output}` (per-item context, valid only inside per-entry hook fields or `[build].<entry>` fields), and `{platform.os}` / `{platform.arch}` (host platform). Unknown placeholders are a hard error at manifest load, with the unknown var named in the message.
*Avoid*: "interpolation" alone (the process, not the thing), "variable" (suggests assignable; placeholders are read-only at substitution time), "template variable" (overloaded with `[sources]` template terms).

**Value mirror (GocciaScript)**:
A LWPT design choice that adopts a value vocabulary co-developed with GocciaScript so the two projects stay aligned as either evolves. Current value mirror: `{platform.os}` and `{platform.arch}` placeholder *values* match `Goccia.build.os` and `Goccia.build.arch` (same canonical strings — darwin/linux/etc); `source/Platform.pas` is LWPT-canonical for the OS/arch detection table per [ADR-0017](./docs/adr/0017-packages-lwpt-canonical.md). It is **value-only** — access paths diverge (`Goccia.build.os` in JS ↔ `{platform.os}` in TOML) since LWPT renamed the namespace under ADR-0013.
*Avoid*: "mirror" alone (reserved for *Registry mirror*), "copy" (the value list IS copied, but the value mirror is the deliberate decision to keep copying as upstream changes), "sync" (suggests bidirectional or automatic; mirroring is unidirectional and manual).

### Formatter

**Format scope**:
The set of files `lwpt format` (and `--check`) processes for a project. The seed is `[package].units`, additions come from `[format].include`, toolkit state (the project-root `.lwpt/` plus any `[lwpt]` override paths) is protected by default unless an explicit include matches it, and subtractions come from `[format].exclude`. There is no implicit project-shape convention beyond the toolkit-state safety boundary.
*Avoid*: "format target" (overloaded with `[targets]`), "format paths" alone (ambiguous about files vs dirs), "files to format" (incomplete — it's a set, not a list).

**Glob**:
A path pattern used in `[format].include` / `[format].exclude` entries. Syntax: `*` matches one path segment, `**` matches any depth (recursion is explicit), `?` matches one non-`/` character. Plain literal paths (no glob characters) are valid globs that match exactly themselves. A plain dir name is shorthand for `<dir>/*.{pas,inc,dpr,lpr}` — top-level only.
*Avoid*: "regex", "pattern" alone (too generic), "wildcard" (informally fine, but `**` isn't a wildcard in shell tradition — it's a globstar).

**Include / exclude**:
The composition primitives for format scope. `include` adds globs to the working set and is the explicit override for the default toolkit-state protection; `exclude` removes globs last, including files also named by an include. Both arrays accept files and dirs (via globs); both follow the same recursion rule (explicit via `**`).
*Avoid*: "allowlist / denylist" (suggests gatekeeping; format scope is just set arithmetic), "ignore" (associates with `.gitignore` semantics, which are different).

### Analysis

**Analysis scope**:
The set of Pascal sources that `lwpt duplication` and `lwpt health` analyze. Package unit roots and exact build-entry sources seed it, `[analysis].include` adds, and `[analysis].exclude` subtracts last; each file belongs to its deepest discovered workspace, and a workspace inherits the root `[analysis]` table unless it declares its own. Independent of *Format scope*.
*Avoid*: "format scope" (a separate set), "lint scope", "health scope" (both commands share one scope).

### Vendored & graduation

**Vendored** (retired per ADR-0017):
The earlier term for code copied from GocciaScript-as-upstream. Retired: LWPT and GocciaScript are sister projects under the same owner, not upstream/downstream; LWPT's `packages/<name>/` is the canonical source for the shared utilities (HTTPClient, CLI, Semver, TOML, TestingPascalLibrary, etc.). The word "vendored" implies a one-way pull from an external authority; the actual relationship is co-ownership with LWPT canonical. Use **Package** instead.
*Use*: **Package** (the umbrella term — every `packages/<name>/` is a package, regardless of who consumes it).
*Avoid*: "vendored" / "vendored package" / "shared package" / "graduated package" (all describe consumption patterns or history, not the thing itself).

**Package**:
A standalone LWPT project — own `lwpt.toml`, own `source/`, own tests, own version. Defined by structure (a directory with these contents resolvable as an `lwpt.toml`-bearing project), not by who consumes it. Current `packages/<name>/` set inside LWPT's monorepo: `httpclient`, `cli`, `semver`, `toml`, `testing`. A package is the **umbrella term**; "shared package", "vendored package", "graduated package" are not separate categories — every package is potentially shareable, and the actual consumption pattern (within-workspace vs cross-project vs git-host vs local-path) is a property of *who uses it*, not of the package itself. The same package, unchanged, can be consumed as a monorepo workspace today and as a third-party git-host dep tomorrow. Post-v1, individual packages graduate out of LWPT's monorepo into their own repos when warranted; the package's structure is identical before and after the move.
*Avoid*: "shared package" / "vendored package" / "graduated package" (none are separate categories — they describe consumption patterns or history, not the thing itself); "module" (overloaded with `.lwpt/modules/<name>/` which is the *installed* tree, not the source); "vendor dir" (Go/PHP historical term); "subpackage" (suggests nesting under a parent package; these are peers).

**Patch marker** (retired per ADR-0017):
The earlier inline `{ [gpm patch] }` / `{ [LWPT patch] }` comment convention. Retired: LWPT-canonical code has no upstream to mark deltas against; git history is the canonical record. Existing marker comments were rewritten as plain Pascal comments preserving the *why* (e.g. why HTTPClient uses a byte-safe `AppendRawBytes` instead of `Copy(PAnsiChar)`).
*Use*: plain Pascal comments that explain non-obvious *why* (`{ ... }` syntax, no marker prefix); commit messages for the *what* and *when*.

**Graduation**:
A **relocation event** for a package — leaving LWPT's monorepo for its own standalone repo. NOT a state transition of the package's identity (the package is canonical-at-LWPT before and canonical-at-its-own-repo after; the *thing* doesn't change, only its filesystem location + consumption mechanism). Triggered when warranted by signals like an external contributor base, a release cadence diverging from LWPT's, or CI / docs needs that warrant dedicated workflows. Per ADR-0017, each graduation gets its own ADR documenting trigger + transition plan. Today's five in-monorepo packages (`httpclient`, `cli`, `semver`, `toml`, `testing`) plus the `source/`-resident extraction candidate (`Platform.pas`) are all canonical regardless of where they live; graduation is mechanical, not categorical.
*Avoid*: "extraction" alone (suggests a one-way pull); "split" (suggests separation; graduation is specifically becoming a peer-located standalone repo).

**Prerelease** (the GitHub-flag sense):
A per-release boolean on a GitHub Release. `release.yml` sets it from the *tag shape*: a tag containing a hyphen (`0.1.0-rc.2`, `0.2.0-beta`) is published with `prerelease: true`; a plain `MAJOR.MINOR.PATCH` tag (`0.1.0`, `1.4.2`) is a normal release. The GitHub `/releases/latest` API returns the newest **normal** (non-prerelease-flagged) release, ignoring prerelease-flagged ones. This is **orthogonal to "pre-1.0"**: `0.1.0` is a pre-1.0 SemVer version but, published without a hyphen, it is a *normal* release that `/releases/latest` returns. Tooling that resolves "latest" (install scripts, the install-script e2e test) keys off the GitHub flag, not the 1.0 milestone.
*Avoid*: conflating "prerelease" (the GitHub flag, hyphen-driven) with "pre-1.0" (a `0.x.y` SemVer version) — they are independent; a `0.x.y` can be either flagged or normal.

## Example dialogue

> **Reviewer**: This PR adds a new dep — why does `lwpt.lock` show two versions of `horse`?
>
> **Author**: It doesn't. There's one `horse` row. What you're seeing is two requirers (us + jhonson) named in the audit log next to it.
>
> **Reviewer**: Right. And the `.lwpt/archives/horse-3.0.0.tar.gz` is what we'd re-fetch if the modules tree gets tampered with?
>
> **Author**: That's the Z-both pattern from ADR-0002 — archives are the verification belt, modules are what FPC actually reads. The hash in the lockfile checks both on `--frozen`.
>
> **Reviewer**: One last thing — the manifest entry says `dep = "octocat/hello@^1"` but the repo is on GitLab. Won't that break?
>
> **Author**: It'd break. Should be `dep = "gitlab:octocat/hello@^1"`. The githost prefix names the URL template, not the protocol.
