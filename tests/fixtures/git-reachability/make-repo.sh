#!/usr/bin/env bash
# Builds the deterministic git repository behind the commit-reachability
# fixtures (ADR-0047) and regenerates the committed pack files.
#
#   tests/fixtures/git-reachability/make-repo.sh <empty-or-missing-dir>
#
# Fixed identities and timestamps make every object id reproducible, so the
# ids in commits.txt stay stable across runs and git versions. The recorded
# upload-pack exchanges under upload-pack/ are refreshed separately by
# running source/LWPT.GitProtocol.Test.pas in record mode against this
# repository (the command is in that program's header comment).
#
# History (committer dates advance one day per commit):
#
#   main:        c1 - c2 - c3 - c4 - c5 - c6        (HEAD -> main)
#                      \    \    \
#                       \    \    v0.2.0 (annotated tag on c4)
#   release/0.1:         r1 - r2   (r1 is dated 2024-03-01: clock skew)
#                             \
#   refs/pull/1/head:          f1  (fork-only: parent c3, no branch or tag)
#
#   v0.1.0: lightweight tag on c2
set -euo pipefail

target=${1:?usage: make-repo.sh <directory>}
here=$(cd "$(dirname "$0")" && pwd)

if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
  echo "make-repo.sh: $target is not empty" >&2
  exit 1
fi
mkdir -p "$target"
cd "$target"

export GIT_AUTHOR_NAME="LWPT Fixture"
export GIT_AUTHOR_EMAIL="fixture@example.invalid"
export GIT_COMMITTER_NAME="LWPT Fixture"
export GIT_COMMITTER_EMAIL="fixture@example.invalid"
export GIT_CONFIG_NOSYSTEM=1
export HOME="$target"

git -c init.defaultBranch=main init -q .
git config uploadpack.allowFilter true
git config commit.gpgsign false
git config tag.gpgsign false

day=0
stamp() {
  day=$((day + 1))
  local when
  when=${1:-$(printf '2024-01-%02dT12:00:00Z' "$day")}
  export GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when"
}

# Long, nearly identical messages make pack-objects store most commits as
# deltas, so the committed packs exercise delta resolution.
paragraph() {
  local i
  for i in $(seq 1 24); do
    printf 'Line %02d of the reachability fixture commit message body.\n' "$i"
  done
}

commit() {
  local name=$1
  stamp "${2:-}"
  printf '%s\n' "$name" > "$name.txt"
  git add "$name.txt"
  { printf '%s\n\n' "$name"; paragraph; } | git commit -q -F -
  printf '%s %s\n' "$name" "$(git rev-parse HEAD)" >> "$here/commits.txt.new"
}

: > "$here/commits.txt.new"
commit c1
commit c2
git tag v0.1.0
commit c3
c3=$(git rev-parse HEAD)
commit c4
stamp
git tag -a v0.2.0 -m "v0.2.0"
commit c5
commit c6

git checkout -q -b release/0.1 "$(git rev-parse v0.1.0)"
commit r1 2024-03-01T12:00:00Z
commit r2

git checkout -q --detach "$c3"
commit f1
git update-ref refs/pull/1/head HEAD
git checkout -q main

mv "$here/commits.txt.new" "$here/commits.txt"
printf 'v0.2.0-tag %s\n' "$(git rev-parse v0.2.0)" >> "$here/commits.txt"

# Every commit (f1 included), as OFS_DELTA and REF_DELTA packs.
git rev-list --all > "$target/.commit-list"
git pack-objects -q --stdout --window=50 --depth=50 --delta-base-offset \
  < "$target/.commit-list" > "$here/commits-ofs.pack"
git pack-objects -q --stdout --window=50 --depth=50 \
  < "$target/.commit-list" > "$here/commits-ref.pack"
rm -f "$target/.commit-list"
