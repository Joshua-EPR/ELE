#!/bin/sh
# Linux half of tests/std/console_input.ps1: runs ELF64 builds of
# std/io/console_test.l and std/io/console_keys.l (built beforehand with
#   ele build console_test.l --target elf -o <dir>/console_test
#   ele build console_keys.l --target elf -o <dir>/console_keys
# ) over redirected bytes and over a real pseudo-terminal (script(1)).
#   sh tests/std/console_input.sh <dir>
set -u
dir=${1:?usage: console_input.sh <dir with console_test and console_keys>}
cd "$dir" || exit 2
chmod +x console_test console_keys
failures=0
check() {
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got $2, expected $3)"; failures=$((failures + 1)); fi
}

printf 'a\303\251\033[A\033[1;5C\033[3~\023\177\r\t\033\033\033OP\033[15~\360\237\230\200\377\033x' | ./console_test
check 'decoder: byte sequence' $? 0
printf 'b' | ./console_test
check 'decoder: mismatch is reported' $? 2
printf 'a\303' | ./console_test
check 'decoder: truncated UTF-8 then end' $? 3
./console_test < /dev/null
check 'decoder: empty input' $? 2

if command -v script >/dev/null 2>&1; then
    # Inside one pseudo-terminal: settings before, the demo (raw mode, keys
    # x, Ctrl+S, Up, Escape), settings after. Both stty -g lines must match.
    out=$( (sleep 1; printf 'x\023\033[A\033\033') | script -qc 'stty -g; ./console_keys; stty -g' /dev/null | tr -d '\r')
    echo "$out"
    first=$(echo "$out" | grep -E '^[0-9a-f]+(:[0-9a-f]+)+$' | head -n 1)
    last=$(echo "$out" | grep -E '^[0-9a-f]+(:[0-9a-f]+)+$' | tail -n 1)
    check 'pty: raw input entered' "$(echo "$out" | grep -c 'press keys')" 1
    check 'pty: Ctrl+S arrives as a key' "$(echo "$out" | grep -c 'Ctrl+S detected')" 1
    check 'pty: Up decoded from CSI' "$(echo "$out" | grep -c 'key up')" 1
    check 'pty: terminal settings restored' "$first" "$last"
else
    echo "SKIP pty checks: script(1) not available"
fi

[ "$failures" -eq 0 ] && echo 'all console input tests passed'
exit "$failures"
