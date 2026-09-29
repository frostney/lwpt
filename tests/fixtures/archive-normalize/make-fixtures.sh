#!/usr/bin/env bash
# Regenerates the independent-tool archive fixtures for
# source/LWPT.ArchiveNormalize.Test.pas. See README.md. The committed bytes
# are the fixtures; rerunning this script on another machine may change
# tool-recorded metadata (uid/gid extra fields, tool versions), which the
# normalizer drops, so the pinned canonical output hash does not change.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tree="$work/golden"
mkdir -p "$tree/source" "$tree/bin" "$tree/empty"
printf '[package]\nname = "golden"\nversion = "1.0.0"\nunits = ["source"]\n' \
  > "$tree/lwpt.toml"
printf '# golden\n\nNormalizer fixture.\n' > "$tree/README.md"
printf 'unit Golden;\n\ninterface\n\nimplementation\n\nend.\n' \
  > "$tree/source/Golden.pas"
printf '#!/bin/sh\necho golden\n' > "$tree/bin/run.sh"
chmod 0755 "$tree/bin/run.sh"
chmod 0644 "$tree/lwpt.toml" "$tree/README.md" "$tree/source/Golden.pas"
find "$tree" -exec touch -h -d '2024-05-06 07:08:10' {} +

# Info-ZIP: Unix host, UT/ux extra fields, explicit directory entries.
(cd "$work" && rm -f "$here/infozip.zip" \
  && zip -q -r -X -9 "$here/infozip.zip" golden/lwpt.toml golden/README.md \
       golden/source golden/bin golden/empty \
  && zip -q -X -9 "$here/infozip.zip" golden/)

# 7-Zip: its own attribute encoding and entry order, package at the root.
(cd "$tree" && rm -f "$here/sevenzip-root.zip" \
  && 7z a -tzip -mx=9 "$here/sevenzip-root.zip" lwpt.toml README.md source bin \
       empty > /dev/null)

# Python zipfile written to an unseekable stream: every entry carries a
# data descriptor with its signature, and the local CRC and sizes are 0.
python3 - "$tree" "$here/python-descriptors.zip" <<'PY'
import os, sys, zipfile

class Unseekable:
    def __init__(self, f): self.f = f
    def write(self, b): return self.f.write(b)
    def flush(self): self.f.flush()
    def tell(self): raise OSError("unseekable")
    def seek(self, *a): raise OSError("unseekable")

tree, out = sys.argv[1], sys.argv[2]
names = ["bin/run.sh", "source/Golden.pas", "README.md", "lwpt.toml"]
with open(out, "wb") as raw:
    with zipfile.ZipFile(Unseekable(raw), "w", zipfile.ZIP_DEFLATED) as z:
        for name in names:
            path = os.path.join(tree, name)
            info = zipfile.ZipInfo("golden/" + name, (2001, 2, 3, 4, 5, 6))
            info.create_system = 3
            info.external_attr = (os.stat(path).st_mode & 0xFFFF) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as f:
                z.writestr(info, f.read())
        info = zipfile.ZipInfo("golden/empty/", (2001, 2, 3, 4, 5, 6))
        info.create_system = 3
        info.external_attr = (0o40755 << 16) | 0x10
        z.writestr(info, b"")
        z.comment = b"python zipfile, data descriptors"
PY

# A tar.gz as git archive writes it: a pax global header, then one
# top-level directory.
git -C "$work" init -q golden-repo
cp -R "$tree/." "$work/golden-repo/"
git -C "$work/golden-repo" add -A
GIT_AUTHOR_DATE='2024-05-06T07:08:10Z' GIT_COMMITTER_DATE='2024-05-06T07:08:10Z' \
  git -C "$work/golden-repo" -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -q -m fixture
git -C "$work/golden-repo" archive --format=tar --prefix=golden-1.0.0/ HEAD \
  | gzip -n -9 > "$here/git-archive.tar.gz"
