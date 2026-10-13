# LWPT user guide

Documentation for using LWPT in your own project and for running an LWPT registry. Start with the [consumer guide](./consumer-guide.md).

| File | Covers |
| --- | --- |
| [`consumer-guide.md`](./consumer-guide.md) | Released-tool installation, CLI and testing dependencies, runnable consumer example, tasks, and capability references |
| [`build-system.md`](./build-system.md) | Bootstrap pattern, `lwpt build` contract, `[build]` section + lifecycle hooks (`[prebuild]` / `[postbuild]` / `[pretest]` / etc.), `build/` output rules, cross-compile |
| [`health.md`](./health.md) | `lwpt health` scope, Pascal complexity scoring, thresholds, Git hotspot formula, and JSON schema |
| [`registry-spec.md`](./registry-spec.md) | Open origin-and-mirror HTTP registry protocol: stable identity, immutable records/objects, signed snapshots, publication, synchronization, and conformance fixtures |
| [`registry-deployment.md`](./registry-deployment.md) | Running a registry origin or mirror: the example container image in [`examples/registry/`](./examples/registry/), TLS and reverse-proxy shapes, secrets and tokens, graceful shutdown, backup and restore, upgrades, operational limits, portability assumptions, and the CI evidence |

Working on LWPT itself? See the [contributor guide](../contributor/README.md). Decision records live in [`docs/adr/`](../adr/).
