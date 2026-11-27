#!/usr/bin/env bash
# Temporary diagnostic entry point for the native-backend regression.
set -euo pipefail

source_file=source/LWPT.Core.pas
scratch=$(mktemp -d "$(cygpath -u "$RUNNER_TEMP")/sha-reg.XXXXXX")
cp "$source_file" "$scratch/core.pas"
trap 'cp "$scratch/core.pas" "$source_file"; rm -rf -- "$scratch"' EXIT
export LWPT_CACHE_DIR
LWPT_CACHE_DIR=$(cygpath -w "$scratch/cache")
targets=(source/LWPT.Core.Test.pas source/LWPT.CacheLifecycle.Test.pas source/LWPT.Registry.Incoming.Test.pas)

./build/lwpt.exe test "${targets[@]}" --no-cache --verbose

# Leave the tests and counters in place. Change only the Windows backend
# selection so the same programs take the original portable implementation.
python - <<'PY'
from pathlib import Path

path = Path("source/LWPT.Core.pas")
source = path.read_text(encoding="utf-8")

def replace_once(old, replacement):
    global source
    if source.count(old) != 1:
        raise SystemExit(f"unexpected SHA-256 mutation match count for {old!r}")
    source = source.replace(old, replacement)

native = "{$ELSEIF DEFINED(MSWINDOWS)}"
compiled = "{$ELSEIF DEFINED(MSWINDOWS) AND NOT DEFINED(LWPT_PORTABLE_SHA256_MUTATION)}"
if source.count(native) != 2:
    raise SystemExit("unexpected Windows SHA-256 backend match count")
source = "{$DEFINE LWPT_PORTABLE_SHA256_MUTATION}\n" + source.replace(native, compiled)
replace_once("{$IFDEF MSWINDOWS}\n  InitWindowsSHA256;",
    "{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(LWPT_PORTABLE_SHA256_MUTATION)}\n  InitWindowsSHA256;")
replace_once("function SHA256Bytes(const AData: TBytes): TSHA256Digest;",
    """{$IFDEF LWPT_PORTABLE_SHA256_MUTATION}
procedure SHA256Discard(var AContext: TSHA256Context);
begin
  FillChar(AContext, SizeOf(AContext), 0);
end;
{$ENDIF}

function SHA256Bytes(const AData: TBytes): TSHA256Digest;""")
path.write_text(source, encoding="utf-8")
PY

if ./build/lwpt.exe test "${targets[@]}" --no-cache > "$scratch/portable.log" 2>&1; then
  cat "$scratch/portable.log"
  printf 'The regression unexpectedly passed on the portable backend.\n' >&2
  exit 1
fi
cat "$scratch/portable.log"
grep -F 'FAIL source/LWPT.Core.Test.pas' "$scratch/portable.log"
grep -F 'FAIL source/LWPT.CacheLifecycle.Test.pas' "$scratch/portable.log"
grep -F 'Expected 0 to be 1' "$scratch/portable.log"
grep -F 'Expected 0 to be 2' "$scratch/portable.log"
printf 'The native-completion assertions rejected the portable backend.\n'
