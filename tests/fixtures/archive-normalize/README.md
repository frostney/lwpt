# Archive normalizer fixtures

## Executive Summary

- These archives are written by independent tools, so the publication
  archive layer ([ADR-0049](../../../docs/adr/0049-registry-remote-publication.md))
  is tested against real-world zip and tar.gz bytes, not only against LWPT's
  own synthesiser.
- The three zips hold one tree, called the golden tree. Each normalizes to the
  same canonical tar.gz, whose SHA-256 is pinned as `GOLDEN_HASH` in
  `source/LWPT.ArchiveNormalize.Test.pas`.
- `make-fixtures.sh` regenerates them. The committed bytes are the fixtures.
  A rerun on another machine may change tool-recorded metadata such as
  uid/gid extra fields and tool versions. The normalizer drops that
  metadata, so a rerun must not change the pinned hash. If it does, the
  normalizer has a bug; do not repin the hash.

## Golden tree

```text
golden/
  lwpt.toml           [package] name = "golden", version = "1.0.0"
  README.md
  source/Golden.pas
  bin/run.sh          mode 0755
  empty/              an empty directory
```

## Files

| File | Tool | What it exercises |
| --- | --- | --- |
| `infozip.zip` | Info-ZIP Zip 3.0 (`zip -r -X -9`) | Unix host, `UT`/`ux` extra fields, explicit directory entries including the top-level directory, stored and deflated entries |
| `sevenzip-root.zip` | 7-Zip 23.01 (`7z a -tzip -mx=9`) | the package at the zip root, 7-Zip's own attribute encoding and entry order |
| `python-descriptors.zip` | Python `zipfile`, written to an unseekable stream | a data descriptor with its signature on every entry, zero local CRC and sizes, an implied `bin/` directory, and an archive comment |
| `git-archive.tar.gz` | `git archive --format=tar --prefix=golden-1.0.0/`, then `gzip -n -9` | a tar.gz as a release workflow produces it, with a leading pax global header; it is published unchanged |

## Provenance of the pinned hashes

When the hashes were pinned, they were cross-checked against an independent
reference. That reference was a separate ustar writer that follows the
ADR's canonical tar.gz text, compressed by zlib 1.3 with the same level,
window bits, memory level, strategy, and 64 KiB feeding. It produced output
byte-identical to LWPT's writer for this tree and for the synthesised
multi-chunk trees in `LWPT.TarWriter.Test` and
`LWPT.ArchiveNormalize.Test`.
