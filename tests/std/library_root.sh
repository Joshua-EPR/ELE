#!/bin/sh
# Usage: sh tests/std/library_root.sh /absolute/path/to/ele
set -eu
ele=${1:?provide ELE driver path}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source="$root/apps/elepad/src/console_import_smoke.l"
out=$(mktemp /tmp/ele-libroot-XXXXXX)
trap 'rm -f "$out"' EXIT HUP INT TERM
rm -f "$out"
if "$ele" build "$source" --target elf -o "$out" >/dev/null 2>&1; then
  echo "FAIL import succeeded without --lib" >&2; exit 1
fi
"$ele" build "$source" --lib "$root" --target elf -o "$out"
chmod +x "$out"
"$out" | grep -q '^elepad-console-import-ok$'
echo "PASS std library root from ELEPad"
