#!/bin/sh
# Native ELF64 terminal integration over redirected input.
# Usage: sh tests/elepad/terminal.sh /absolute/path/to/ele
set -eu
ele=${1:?provide autonomous ELE driver path}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
"$ele" build "$root/apps/elepad/src/terminal.l" --lib "$root" --target elf --output "$work/elepad-terminal"
chmod +x "$work/elepad-terminal"
printf 'ab\r\ncd' > "$work/sample.l"
printf '\033[C\303\251\033[B\177\023\021' | "$work/elepad-terminal" "$work/sample.l" > "$work/screen" 2> "$work/errors"
printf 'a\303\251b\r\nc' > "$work/expected"
cmp "$work/expected" "$work/sample.l"
printf 'PASS native ELEPad terminal edit/save/reopen\n'
printf 'ab\r\ncd' > "$work/sample.l"
set +e
printf 'x' | "$work/elepad-terminal" "$work/sample.l" > "$work/screen" 2> "$work/errors"
status=$?
set -e
test "$status" -eq 33
printf 'ab\r\ncd' > "$work/expected"
cmp "$work/expected" "$work/sample.l"
printf 'PASS unsaved EOF leaves source unchanged\n'
# Ctrl+A, Ctrl+X, Ctrl+Z, Ctrl+Y, Ctrl+Z, 'x', Ctrl+Z, Ctrl+F 'c' Enter,
# Escape (ESC ESC), 'Z' replaces the found "c", Ctrl+S, Ctrl+Q.
printf 'ab\r\ncd' > "$work/sample.l"
printf '\001\030\032\031\032x\032\006c\r\033\033Z\023\021' | "$work/elepad-terminal" "$work/sample.l" > "$work/screen" 2> "$work/errors"
printf 'ab\r\nZd' > "$work/expected"
cmp "$work/expected" "$work/sample.l"
printf 'PASS native ELEPad undo/redo, cut, find and replace-selection\n'
# Typing then undoing back to the loaded text is clean: Ctrl+Q quits at once.
printf 'ab\r\ncd' > "$work/sample.l"
printf 'xy\032\021' | "$work/elepad-terminal" "$work/sample.l" > "$work/screen" 2> "$work/errors"
printf 'ab\r\ncd' > "$work/expected"
cmp "$work/expected" "$work/sample.l"
printf 'PASS undo to the loaded state clears the unsaved marker\n'
