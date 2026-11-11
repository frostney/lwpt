# LWPT user guide

Documentation for using LWPT in your own project and for running an LWPT registry. Start with the [consumer guide](./consumer-guide.md).

| File | Covers |
| --- | --- |
| [`consumer-guide.md`](./consumer-guide.md) | Released-tool installation, CLI and testing dependencies, runnable consumer example, tasks, and capability references |
| [`cli-package.md`](./cli-package.md) | Building a program's command line on the `cli` package: host description, top-level flags, argument pass-through, the end-of-options marker, subcommand aliasing, usage errors, and in-process tests |
| [`build-system.md`](./build-system.md) | Bootstrap pattern, `lwpt build` contract, `[build]` section + lifecycle hooks (`[prebuild]` / `[postbuild]` / `[pretest]` / etc.), `build/` output rules, cross-compile |
| [`health.md`](./health.md) | `lwpt health` scope, Pascal complexity scoring, thresholds, Git hotspot formula, and JSON schema |
| [`registry-spec.md`](./registry-spec.md) | Open origin-and-mirror HTTP registry protocol: stable identity, immutable records/objects, signed snapshots, publication, synchronization, and conformance fixtures |
| [`registry-deployment.md`](./registry-deployment.md) | Running a registry origin or mirror: the example container image in [`examples/registry/`](../examples/registry/), TLS and reverse-proxy shapes, secrets and tokens, graceful shutdown, backup and restore, upgrades, operational limits, portability assumptions, and the CI evidence |

The [environment variables](../contributor/tooling.md#environment-variables) that configure LWPT for your machine (shared cache location and budget, worker budget, registry state, compiler selection), along with duplication analysis, test programs, formatter scope and `lwpt repair`, are documented once in the contributor guide; see its [shared references](../contributor/README.md).

Working on LWPT itself? See the [contributor guide](../contributor/README.md). Decision records live in [`docs/adr/`](../adr/).
