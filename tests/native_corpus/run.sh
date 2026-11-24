#!/bin/sh
# Native conformance corpus runner for Linux x86-64 ELF64 images.
#
# Usage: sh tests/native_corpus/run.sh <compiler> [case ...]
#
# Needs ONLY an ELE compiler binary that implements
# `<compiler> build <file.l> --target elf --output <path>` (the ELE-written
# driver compiler-l/src/main_driver.l) and POSIX sh tools. No cargo, rustc or
# Stage 0. Cases may be selected by name (`hello`, `reject/use_after_move`).
#
# Positive case  <name>.l + <name>.stdout + <name>.exit (corpus root):
#   compiled, executed with stdin at EOF (</dev/null) and a timeout, in a
#   fresh temporary working directory; stdout must equal <name>.stdout byte
#   for byte and the exit status must equal <name>.exit.
# Reject case    reject/<name>.l + reject/<name>.diag:
#   the compiler must exit non-zero, print every non-empty line of
#   <name>.diag (stdout + stderr) and produce no output file.
# Known gaps     known_gaps.txt lists `<case> <targets>` (pe, elf or all,
#   comma separated). A listed case that fails is XFAIL; one that passes is
#   XPASS and fails the run, so a fixed gap must be removed from the list.
#
# Nothing is normalized: stdout is compared with cmp. Expected files are LF
# and tests/native_corpus/.gitattributes disables end-of-line conversion.
#
# Environment: ELE_CORPUS_TIMEOUT (run seconds, default 20),
# ELE_CORPUS_COMPILE_TIMEOUT (default 300), ELE_CORPUS_KEEP=1 keeps the work
# directory. Exit status: 0 if every case is PASS or XFAIL, 1 otherwise, 2 on
# usage or corpus layout errors.
set -u

if [ $# -lt 1 ]; then
    echo "usage: run.sh <compiler> [case ...]" >&2
    exit 2
fi
compiler=$1
shift
case $compiler in
    /*) ;;
    *) compiler=$(pwd)/$compiler ;;
esac
if [ ! -f "$compiler" ]; then
    echo "run.sh: compiler not found: $compiler" >&2
    exit 2
fi
corpus=${ELE_CORPUS_DIR:-$(cd "$(dirname "$0")" && pwd)}
run_timeout=${ELE_CORPUS_TIMEOUT:-20}
compile_timeout=${ELE_CORPUS_COMPILE_TIMEOUT:-300}
target=elf
tab=$(printf '\t')
cr=$(printf '\r')

work=$(mktemp -d "${TMPDIR:-/tmp}/ele-native-corpus.XXXXXX") || exit 2
report=$work/report.tsv
: >"$report"

# limited <seconds> <cwd> <stdout file> <stderr file> <command...>
# Runs the command with stdin at EOF; sets $status (128+signal when killed)
# and $timed_out (1 when the watchdog killed it).
limited() {
    limit=$1 dir=$2 out=$3 err=$4
    shift 4
    rm -f "$work/.timeout"
    (cd "$dir" && exec "$@") >"$out" 2>"$err" </dev/null &
    pid=$!
    (
        i=0
        while [ "$i" -lt "$limit" ]; do
            sleep 1
            kill -0 "$pid" 2>/dev/null || exit 0
            i=$((i + 1))
        done
        kill -9 "$pid" 2>/dev/null && : >"$work/.timeout"
    ) >/dev/null 2>&1 </dev/null &
    watchdog=$!
    wait "$pid"
    status=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    timed_out=0
    if [ -f "$work/.timeout" ]; then timed_out=1; fi
}

first_line() {
    sed -e '/^[[:space:]]*$/d' -e "s|$corpus/||g" "$@" 2>/dev/null | head -n 1
}

gap_targets() {
    [ -f "$corpus/known_gaps.txt" ] || return 1
    sed -e 's/#.*//' -e "s/$cr//" "$corpus/known_gaps.txt" | while read -r gname gtargets grest; do
        [ -n "$gname" ] || continue
        if [ "$gname" = "$1" ]; then
            printf '%s\n' "$gtargets"
            break
        fi
    done
}

is_gap() {
    targets=$(gap_targets "$1")
    case ",$targets," in
        *",all,"* | *",$target,"*) return 0 ;;
    esac
    return 1
}

# ---- corpus layout ----------------------------------------------------------
layout_errors=0
names=""
for source in "$corpus"/*.l; do
    [ -f "$source" ] || continue
    name=$(basename "$source" .l)
    if [ ! -f "$corpus/$name.stdout" ] || [ ! -f "$corpus/$name.exit" ]; then
        echo "run.sh: $name.l: a positive case needs $name.stdout and $name.exit" >&2
        layout_errors=1
        continue
    fi
    names="$names $name"
done
for source in "$corpus"/reject/*.l; do
    [ -f "$source" ] || continue
    name=$(basename "$source" .l)
    if [ ! -f "$corpus/reject/$name.diag" ]; then
        echo "run.sh: reject/$name.l: a reject case needs $name.diag" >&2
        layout_errors=1
        continue
    fi
    names="$names reject/$name"
done
if [ -f "$corpus/known_gaps.txt" ]; then
    gap_check=$(sed -e 's/#.*//' -e "s/$cr//" "$corpus/known_gaps.txt" | while read -r gname gtargets grest; do
        [ -n "$gname" ] || continue
        if [ -z "$gtargets" ] || [ -n "$grest" ]; then
            echo "known_gaps.txt: malformed line for '$gname'"
            continue
        fi
        case " $names " in
            *" $gname "*) ;;
            *) echo "known_gaps.txt: unknown case '$gname'" ;;
        esac
        for t in $(printf '%s' "$gtargets" | tr ',' ' '); do
            case $t in
                pe | elf | all) ;;
                *) echo "known_gaps.txt: unknown target '$t' for '$gname'" ;;
            esac
        done
    done)
    if [ -n "$gap_check" ]; then
        printf 'run.sh: %s\n' "$gap_check" >&2
        layout_errors=1
    fi
fi
if [ "$layout_errors" -ne 0 ]; then
    rm -rf "$work"
    exit 2
fi
if [ $# -gt 0 ]; then
    selected=""
    for name in $names; do
        for wanted in "$@"; do
            if [ "$name" = "$wanted" ]; then selected="$selected $name"; fi
        done
    done
    names=$selected
fi

record() { # <case> <kind> <passed 0|1> <detail>
    if is_gap "$1"; then
        if [ "$3" -eq 1 ]; then
            result=XPASS
            detail="listed in known_gaps.txt but passes: remove it from the list"
        else
            result=XFAIL
            detail=$4
        fi
    else
        if [ "$3" -eq 1 ]; then result=PASS; else result=FAIL; fi
        detail=$4
    fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$result" "$detail" >>"$report"
}

# ---- cases ------------------------------------------------------------------
for name in $names; do
    case $name in
        reject/*)
            base=${name#reject/}
            dir=$work/reject-$base
            mkdir -p "$dir"
            image=$dir/$base.elf
            limited "$compile_timeout" "$dir" "$dir/build.out" "$dir/build.err" \
                "$compiler" build "$corpus/reject/$base.l" --target "$target" --output "$image"
            if [ "$timed_out" -eq 1 ]; then
                record "$name" reject 0 "compile timed out after $compile_timeout s"
                continue
            fi
            cat "$dir/build.out" "$dir/build.err" >"$dir/build.all"
            problems=""
            if [ "$status" -eq 0 ]; then problems="$problems; compiler exited 0"; fi
            if [ -e "$image" ]; then problems="$problems; an output image was produced"; fi
            while IFS= read -r needle || [ -n "$needle" ]; do
                needle=${needle%"$cr"}
                [ -n "$needle" ] || continue
                if ! grep -F -q -e "$needle" "$dir/build.all"; then
                    problems="$problems; missing diagnostic '$needle' (got: $(first_line "$dir/build.all"))"
                fi
            done <"$corpus/reject/$base.diag"
            if [ -z "$problems" ]; then
                record "$name" reject 1 ""
            else
                record "$name" reject 0 "${problems#; }"
            fi
            ;;
        *)
            dir=$work/$name
            mkdir -p "$dir"
            image=$dir/$name.elf
            limited "$compile_timeout" "$dir" "$dir/build.out" "$dir/build.err" \
                "$compiler" build "$corpus/$name.l" --target "$target" --output "$image"
            if [ "$timed_out" -eq 1 ]; then
                record "$name" run 0 "compile timed out after $compile_timeout s"
                continue
            fi
            if [ "$status" -ne 0 ] || [ ! -f "$image" ]; then
                record "$name" run 0 "compile exit $status: $(first_line "$dir/build.err" "$dir/build.out")"
                continue
            fi
            chmod u+x "$image"
            limited "$run_timeout" "$dir" "$dir/stdout" "$dir/stderr" "$image"
            if [ "$timed_out" -eq 1 ]; then
                record "$name" run 0 "timed out after $run_timeout s"
                continue
            fi
            expected_code=$(tr -d " \r\n$tab" <"$corpus/$name.exit")
            problems=""
            if [ "$status" -ne "$expected_code" ]; then
                problems="$problems; exit $status, expected $expected_code"
            fi
            if ! cmp -s "$corpus/$name.stdout" "$dir/stdout"; then
                where=$(cmp "$corpus/$name.stdout" "$dir/stdout" 2>&1 | head -n 1)
                problems="$problems; stdout differs: $where"
            fi
            if [ -z "$problems" ]; then
                record "$name" run 1 ""
            else
                record "$name" run 0 "${problems#; }"
            fi
            ;;
    esac
done

# ---- report -----------------------------------------------------------------
width=$(awk -F "$tab" 'BEGIN { w = 12 } length($1) > w { w = length($1) } END { print w }' "$report")
awk -F "$tab" -v w="$width" 'BEGIN { printf "%-" w "s  %-6s  %-6s  %s\n", "CASE", "KIND", "RESULT", "DETAIL" }
    { printf "%-" w "s  %-6s  %-6s  %s\n", $1, $2, $3, $4 }' "$report"
total=$(wc -l <"$report" | tr -d ' ')
count() { awk -F "$tab" -v r="$1" '$3 == r { n++ } END { print n + 0 }' "$report"; }
pass=$(count PASS)
fail=$(count FAIL)
xfail=$(count XFAIL)
xpass=$(count XPASS)
echo
echo "target=$target cases=$total pass=$pass fail=$fail xfail=$xfail xpass=$xpass"
if [ "$total" -eq 0 ]; then
    echo "run.sh: no cases selected" >&2
    rm -rf "$work"
    exit 2
fi
if [ $((fail + xpass)) -gt 0 ] || [ "${ELE_CORPUS_KEEP:-0}" = 1 ]; then
    echo "work directory kept: $work"
else
    rm -rf "$work"
fi
if [ $((fail + xpass)) -gt 0 ]; then
    exit 1
fi
exit 0
