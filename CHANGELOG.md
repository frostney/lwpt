# Changelog

All notable changes to LWPT are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the GitHub Release notes are published from the matching section below.
## [0.8.0] - 2026-10-05

### Upgrade notes

- **Lockfile schema v4 (breaking).** 0.8.0 reads only schema v4 lockfiles, which use a framed tree digest (ADR-0052). `install`, `add`, `remove`, `update` and `outdated` refuse a v3 `lwpt.lock`. Run `lwpt repair` once in each project and commit the updated `lwpt.lock` (#355).
- **Upgrade every lwpt install, including pinned ones.** A 0.7.0 `lwpt build` or `lwpt test` can wedge the shared per-user worker budget. It writes a request with `pid=0` and empty `lease-tokens` that claims the whole budget, which stalls every other lwpt on the machine. 0.8.0 can't wedge this way (#312). If a pre-0.8.0 run hangs with such a request, terminate it: its PID is the prefix of the request's file name.
- **Leftover 0.7.0 install locks.** `lwpt repair` now reclaims `.lwpt/install.lock` only when a kernel record lock proves its owner has exited (ADR-0053). A lock left by a crashed 0.7.0 install has no such record, so repair names the file. Delete it by hand once no install or repair is running for the project.

### Bug Fixes

- fix(repair): reclaim the install lock only from a provably dead owner and hold it while recovering (#392)
- fix(registry): wipe the TLS identity password on every platform (#390)
- fix(registry): share delete access on Windows reads and never treat transient state absence as fresh (#383)
- fix(test): make lwpt test --inventory work on the repository and explain failures (#382)
- fix(install): verify local and workspace snapshots against their sources under --frozen (#379)
- fix(hooks): judge hook and task staleness by full-resolution modification times (#369)
- fix(build): make the stamp-version hook safe under concurrent self-builds (#362)
- fix(core): address toolkit state by extended-length paths on Windows (#364)
- fix(build): serialize version-include generation across concurrent builds (#360)
- fix(httpclient): verify TLS trust anchors offline so SChannel never blocks on network retrieval (#346)
- fix(test): join test workers before freeing what they share (#341)
- fix(process-tree): stop and join signal forwarders before runtime shutdown (#337)
- fix(build): self-host on Windows: bootstrap writes lwpt.exe and rebuilds replace the running image (#336)
- fix(install): end crash-injection seams without running finalization (#332)
- fix(install): extract archives without paszlib's 255-character path limit (#328)
- fix(workers): detect the Linux online processor count for the default budget (#325)
- fix(format): keep comments and strings out of the rename passes (#307)
- fix(install): harden git-host fetches against redirects, moved tags and test seams (#308)
- fix(test): wait for BuildFairness children to release their handles on Windows (#311)
- fix(process): let a child that closes stdin early decide the result (#305)
- fix(workers): keep coordinator state readable when children inherit locks (#312)
- fix(process-tree): accept Darwin's spurious setpgid EPERM once the group exists (#310)
- fix(build): preserve FIFO position while polling worker capacity (#296)
- fix(workers): detect the macOS logical CPU budget (#295)
- fix(cli): improve help discovery and consumer documentation (#293)
- fix(test): transfer PID payload read ownership in TestScheduling (#291)
- fix(format): preserve uses clauses that carry comments (#289)
- fix(process-tree): harden Windows pipe validation (#290)
- fix(cache): prevent inherited locks and isolate Ctrl-Break delivery (#273)
- fix(cache): recover repeated staged verification interrupts (#272)
- fix(cache): retry transient staged verification opens (#265)
- fix(test): transfer WorkerBudget marker ownership (#263)
- fix(cache): preserve transitive build references (#259)

### Documentation

- docs: sync documentation and records with shipped behavior for 0.8.0 (#391)
- docs(registry): container deployment guide and registry end-to-end matrix (#56) (#357)
- docs(adr): propose lockfile schema v4 with a framed tree digest (ADR-0052, #352) (#353)
- docs(adr): propose registry dependency sources (ADR-0051, #62) (#340)
- docs(adr): propose ADR-0049 registry remote publication (#54) (#334)
- docs(orchestration): cap lane waits at five minutes (#326)

### Internal

- test: bound every child-process wait in test code and guard it (#368)
- test(httpclient): move the retrieval recorder below every ephemeral port range (#373)
- test: share delete access when reading files a live writer may be renaming on Windows (#371)
- test(registry): relocate publication origins and bound every registry child wait (#363)
- test: hand cross-process payloads over through their completion marker, and guard the pattern (#359)
- test(support): give tarsynth gzip temp files unique names (#354)
- test(registry): start Registry.E2E servers on kernel-chosen ports (#348)
- ci(windows): compile x86_64-win64 test programs as win64 (#335)
- ci: replace managed delivery with the known-good-route skills (#315)
- test(cache): bound the scale test relative to one cache walk (#327)
- chore(skills): refresh known-good-route workflows (#304)
- ci: run the full test queue so one run reports every failure (#306)
- chore(ci): inherit CodeRabbit's central frostney config (#298)
- test: expose Darwin scheduling failures (#277)
- fix(ci): extend focused scheduling diagnostic budget (#261)
- ci: add trusted Linux scheduling observability (#270)
- fix(delivery): accept exact no-code review skips (#267)
- test: stabilize scheduling fixture startup (#256)
- test(cache): preserve ObjectStore child failure diagnostics (#252)
- test: make sibling fanout proof structural (#255)
- test: stabilize scheduling fixture phases (#251)

### New Features

- feat(registry): bound the per-user registry document store (#366)
- feat(registry): publish packages with registry dependencies (#62, ADR-0049 decision 4 lift) (#356)
- feat(install): lockfile schema v4 with a framed tree digest (ADR-0052) (#355)
- feat(registry): lwpt registry publish client (#54 slice 3) (#350)
- feat(install): verify and restore registry dependencies under --frozen and --offline (#62 slice B, #226) (#351)
- feat(install): consume registry dependencies online (#62 slice A) (#344)
- feat(registry): authenticated remote publication, server side (#54 slice 2) (#343)
- feat(archive): canonical tar.gz writer, bounded zip reader, and publication archive validation (#54 slice 1) (#342)
- feat(httpclient): outbound TLS client options (trust anchors, client identity, insecure mode, peer certificate) (#339)
- feat(registry): enforce a maximum checkpoint lifetime and a clock-rollback floor (#333)
- feat(registry): add verified read-only mirrors and signed key rotation (#292)
- feat(install): accept commit pins only when reachable from upstream refs (#316)
- feat(registry): add self-hosted content-addressed origin (#253)
- feat(install): add locked offline materialization (#283)

### Performance

- perf(cache): load the lifecycle index and judge admissions in near-linear time (#297)
## [0.7.0] - 2026-08-23

### Bug Fixes

- fix(release): align preparation with shipped behavior (#246)
- fix(delivery): open review only after PR is ready (#240)
- fix(test): observe sibling cancellation fanout (#228)
- fix(review): include tests in Macroscope correctness (#233)
- fix(build): retry Win32 version-include replace (#230)
- fix(test): avoid waiting for inherited pipe EOF (#224)
- fix(cli): reject unexpected positional arguments (#220)

### Internal

- chore(skills): install agent-writing (#245)
- chore(skills): refresh project workflows (#244)
- ci: bridge selector-driven test routes (#243)
- ci: add reusable LWPT dependency updater (#231)
- test: capture Darwin scheduling recurrence evidence (#218)

### New Features

- feat(build): focus routine progress output (#242)
- feat(test): keep grouping in userland (#241)
- feat(test): cache verified executables (#234)
- feat(cache): bound shared cache lifecycle (#225)
- feat(deps): give consumers a sanctioned way to bump git-host packages (#229)
- feat(cache): coalesce producer misses (#222)
- feat(build): cache verified build results (#221)
- feat(install): add per-user dependency archive CAS (#219)
## [0.6.1] - 2026-08-15

### Bug Fixes

- fix(release): require installer checksum verification (#216)
- fix(ci): run default scheduling diagnostic (#215)
- fix(test): hand off WorkerBudget marker reads (#206)
- fix(process-tree): reconcile exited Windows jobs (#210)
- fix(test): stabilize Windows scheduling fixtures (#203)
- fix(test): bind nested scheduling acknowledgement (#200)

### Internal

- ci: bound native test jobs (#199)
- ci: prune no-op delivery observer events (#202)
- refactor(delivery): use native admission job (#197)

### Other Changes

- Validate Chocolatey FPC retry success
## [0.6.0] - 2026-08-12

### Bug Fixes

- fix(httpclient): harden socket waits and chunk bounds (#183)

### Documentation

- docs: align release readiness contracts (#195)
- docs(release): reuse integrated CI evidence (#189)
- docs(testing): correct HTTPClient test count (#182)

### Internal

- chore: refresh workflow skills and repair full-CI finalization (#194)
- ci: tolerate absent Windows compiler roots (#193)
- ci: make cross-platform proof progressive (#192)

### New Features

- feat(test): verify runtime registration inventory (#191)
- feat(delivery): discover active review adapters (#190)
- feat(test): select test paths and globs (#185)
- feat(httpclient): native SChannel server TLS on Windows (win64 + win32) (#184)
- feat(build): allow relocating session staging (#181)
- HTTPClient: add POST support on a body-capable request core (#180)
- feat(manifest): expose declarative schema (#179)
- feat(test): support manifest compiler flags (#177)
- Unify direct commands and compiler targets (#176)
## [0.5.1] - 2026-08-10

### Bug Fixes

- fix(install): pin the frozen constraint fingerprint to LF line endings (#168)
- fix(testing): fail the process by default when a suite fails (#167)
- fix(test): synchronize concurrency fixtures (#173)

### Internal

- ci: add managed delivery orchestration (#166)
## [0.5.0] - 2026-08-04

### Bug Fixes

- fix(process): preserve Windows job assignment ordering (#157)
- fix(worker-budget): make delegation handoff atomic (#152)
- Skip writer threads for empty process input (#151)
- Retry concurrent worker-budget state-root creation (#139)

### Documentation

- docs: remove stale analysis roadmap links (#163)

### Internal

- chore: reconcile release preparation findings (#164)
- chore(skills): add run-retro workflow (#162)
- test(build): expose raw status on observable failure (#147)
- test(process): make missing-ack cancellation deterministic (#158)
- refactor(process): type Windows process-tree state (#150)
- test(worker-budget): expose delegation failure state (#143)
- refactor(output): share typed progress reporting (#144)
- test(compiler): await Windows proxy release (#146)
- Run HTTP mock-server regressions natively on Windows (#130)
- ci: gate stacked PR validation (#129)

### New Features

- Acknowledge nested process-tree termination (#155)
- Forward Windows console cancellation (#154)
- Add universal silent output mode (#149)
- Add the typed output event foundation (#136)
- Harden TLS server identity lifecycle (#148)
- Add Lakon compiler driver (#142)
- Add Delphi compiler driver (#140)
- Add Blaise compiler driver (#141)
- Add deterministic HTTP fetch-failure tests (#131)
- Report Pascal complexity and Git health hotspots (#138)
- Detect Type-2 duplication across typed Pascal regions (#137)
- Expose root-owned compiler profiles and embedding defaults (#132)
- Resolve one dependency version across the full graph (#134)
- Bound encrypted TLS handshake buffering (#135)
- Add the shared Pascal analysis foundation (#133)
- feat(cli): report subcommand completion timings (#128)
## [0.4.0] - 2026-08-01

### Bug Fixes

- fix(test): retry transient worker scratch cleanup (#124)
- fix(test): classify latest-release resolution failures (#119)
- fix(core): normalize tree-hash path separators for cross-platform lockfiles (#116)
- fix(format): exclude toolkit state by default (#111)

### Internal

- chore: synchronize release readiness contracts (#125)
- ci: restore Windows E2E and frozen installs (#123)
- ci(pr): gate e2e on the Linux leg and add a native aarch64-darwin leg (#115)

### New Features

- feat(build): support per-target compiler flags (#121)
- feat(init): adopt existing manifests (#120)
- feat(build): move FPC compilation and capability probing behind the driver seam (#118)
- feat(workers): fall back to a repo-local state dir when the default is unwritable (#117)
## [0.3.0] - 2026-07-21

### Bug Fixes

- fix(test): repair the two post-#84 main failures (Linux TLS close, darwin fpc-proxy misroute) (#105)
- fix(core): keep sibling tmp paths of bare filenames in current directory (#91)
- fix(test): surface nested-run failures in TestScheduling via shared diagnostics (#104)
- fix(test): contention-robust, self-diagnosing BuildSessions concurrency barriers (#103)
- fix(test): widen BuildSessions concurrency-barrier windows to stop main flaking (#101)
- fix(core): guarantee fresh MakeTmpPath results under same-window calls (#79)
- fix(test): isolate integration-test scratch directories per invocation (#80)
- fix(build): report nonzero compiler exits dropped by TProcess on unix (#69)
- fix(test): remove Windows worker-budget races (#68)

### Documentation

- docs: 0.3.0 release-preparation truth sync (#110)
- docs: add retro gates from the PR #105 root-cause session (#106)
- docs: define product direction and delivery gates (#57)

### Internal

- ci(release): stamp the tag version with a host-linkable FPC (#114)
- test: apply codex-review findings on the #105 fixes (#108)
- refactor(run): derive list-mode subcommand aliases from the live registry (#94)
- refactor(test): derive suite descriptions from PROJECT_NAME (#82)
- ci: harden release governance (#63)
- chore(skills): update project skill set (#26)

### New Features

- feat(agents): add agents subcommand generating the AGENTS.md command reference (#93)
- feat(build): schedule targets in parallel (#67)
- feat(build): define compiler-neutral build requests (#66)
- feat: run test programs in parallel with numeric bail (#65)
- Support valued and attached short CLI options (#59)

### Other Changes

- Server-side accept TLS: memory-BIO, PKCS#12, nonblocking handshake (#70) (#84)
- Process-tree cascade termination (#73) + observable parallel work (#41) (#83)
- Keep compiler staging paths within FPC's 255-character limit (#75)
- Specify the decentralized HTTP registry protocol (#58)
- Isolate build sessions and publish outputs atomically (#60)
- Coordinate a machine-wide worker budget (#61)
## [0.2.0] - 2026-06-24

### Bug Fixes

- Fix Windows build break and harden install-time tree walks (#21)
- Fix nested-manifest discovery, multi-target build, and [format] exclude for hidden dirs (#17)
- Fix Windows name resolution collisions (#15)

### New Features

- Add lwpt add/remove subcommands (ADR-0019) (#20)
- Add pre-merge Windows compile signal to pr.yml (win64 cross-compile) (#23)
- Add Windows bootstrap smoke to CI (#14)

### Other Changes

- more more skills
- Guard CopyDirTree and archive-link materialization against directory cycles; dedup hash helpers (#22)
- Upgrade build --clean to whole-tree artefact sweep with stale-artefact retry hint (#18)
- Isolate FPC unit output per build target and mode (#19)
- Regenerate lwpt.lock and gate PRs on install --frozen (#16)
- Deepen install transaction architecture (#13)
## [0.1.0] - 2026-06-04

### Bug Fixes

- Skip live-network e2e tests on transient host downtime (#10)

### Other Changes

- Install-script e2e smoke (latest-resolving) + stamp release version from tag (ADR-0018) (#11)
## [0.1.0-rc.2] - 2026-06-02

### Bug Fixes

- Fix release archive format for macOS targets (#8)
## [0.1.0-rc.1] - 2026-06-01

### Bug Fixes

- Fix Windows SChannel archive fetches (#5)
- Fix CI output paths and module link handling (#1)

### Internal

- Update skills (#4)

### Other Changes

- Align release tag examples with SemVer 2.0.0 canonical form (#6)
- Rescope CI FPC packages slice for LWPT (#2)
- Initial version
- Initial commit
