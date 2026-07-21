# Changelog

All notable changes to LWPT are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the GitHub Release notes are published from the matching section below.
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

### Other Changes

- Install-script e2e smoke (latest-resolving) + stamp release version from tag (ADR-0026) (#11)
- Skip live-network e2e tests on transient host downtime (#10)
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
