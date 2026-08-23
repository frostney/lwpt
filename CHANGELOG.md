# Changelog

All notable changes to LWPT are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the GitHub Release notes are published from the matching section below.
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
