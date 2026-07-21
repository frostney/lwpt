# Changelog

All notable changes to LWPT are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the GitHub Release notes are published from the matching section below.
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
