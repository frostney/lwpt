# Install transaction module

`LWPT.Core.pas` previously owned manifest intake, the whole install path, and most subcommand behavior: manifest parsing, workspace discovery, install locking, tmp cleanup, dependency resolution, fetching/materialising modules and archives, frozen verification, lockfile/cfg writing, build/test/format/init/repair/run command behavior, and low-level helpers. We deepened this into dedicated modules: `LWPT.Manifest` owns manifest intent plus its path context, `LWPT.Install` owns the install transaction, `LWPT.Command.*` modules own command-level behavior, and `LWPT.Formatter` owns the formatting engine. `LWPT.Core` becomes shared project identity, error hierarchy, and low-level helpers only.

## Considered Options

- **Extract only resolver/fetch.** Rejected because `CmdInstall` would still own transaction ordering, lock scope, frozen verification, and write sequencing. The module would be shallow: deleting it would leave the hardest install rules spread across callers.
- **Keep everything in `LWPT.Core.pas` as sections.** Rejected because `LWPT.Core.pas` is already the catch-all for manifest intake plus every subcommand. The install transaction is load-bearing enough to earn its own module seam.
- **Leave manifest intake in `LWPT.Core.pas` and pass both manifest path and manifest record.** Rejected because the real input is a manifest plus its origin context. Passing both separately creates an unnamed concept and invites double reads or path/manifest drift.
- **Create a shallow context-only manifest module.** Rejected because a `LWPT.Manifest` module that merely wraps `LWPT.Core.LoadManifest` would be a pass-through. The manifest module must own manifest model plus intake to be deep.
- **Only split install first.** Rejected after choosing the module shape because leaving build/test/format/init/repair/run inside `LWPT.Core` would preserve `Core` as the de facto command module. The target architecture is clearer if every subcommand has an explicit command module.
- **Make frozen a separate module.** Rejected because `lwpt install --frozen` validates the same manifest-to-toolkit-state relationship under the same lock and cleanup discipline. Frozen is an internal mode of the install transaction, not a separate command shape.
- **Introduce an `EInstallTransactionError` umbrella.** Rejected because `ELWPTError` is already the project-wide umbrella, and several current error classes are shared across subcommands. The install transaction preserves the existing specific error taxonomy.

## Consequences

- **New manifest module:** `source/LWPT.Manifest.pas` owns `TManifest`, manifest-related source/version types, manifest intake, source/version parsing, `TManifestContext`, and `LoadManifestContext`.
- **New install module:** `source/LWPT.Install.pas` owns the install transaction and its internal resolver/fetch/commit helpers.
- **New command modules:** `source/LWPT.Command.Install.pas`, `LWPT.Command.Build.pas`, `LWPT.Command.Testing.pas`, `LWPT.Command.Format.pas`, `LWPT.Command.Init.pas`, `LWPT.Command.Repair.pas`, and `LWPT.Command.Run.pas` own subcommand-level behavior.
- **Formatter rename:** the formatting engine moves from `LWPT.Format` to `LWPT.Formatter`; the command-level format scope lives in `LWPT.Command.Format`.
- **Hooks stay outside:** `[preinstall]` runs before the install transaction starts; `[postinstall]` runs after it ends. The install lock is not held while arbitrary lifecycle scripts run.
- **Frozen stays verification-only:** `lwpt install --frozen` refuses network, refuses lockfile/cfg updates, and verifies committed toolkit state. It does not re-materialise missing modules from committed archives.
- **Lock is implementation detail:** the install lock is owned by the install transaction module, not exposed as a caller-coordinated type.
- **Lockfile and cfg writes move behind the seam:** non-frozen transactions write `lwpt.lock` and cfg after successful materialisation; frozen transactions write neither.
- **Result is compact:** the transaction returns outcome data such as package count, lockfile path, and cfg path. It does not expose the full resolution graph as the public result.
- **Types move by ownership:** `LWPT.Core.pas` keeps project identity constants, the error hierarchy, and shared helpers that are not manifest-, install-, command-, or formatter-specific. `LWPT.Manifest.pas` gets the manifest model and context. `LWPT.Install.pas` gets `TInstallTransactionResult`, install lock implementation, resolver nodes, fetch/materialise logic, lockfile read/write, cfg write, frozen verification, and `ExtractArchive`.
- **Extractor remains testable internal:** `ExtractArchive` moves to `LWPT.Install` but remains exposed for focused archive tests until/unless archive extraction becomes its own deeper module.
