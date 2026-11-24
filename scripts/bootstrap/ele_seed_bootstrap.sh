#!/bin/sh
# Stage-0-free ELE bootstrap from a hash-pinned seed driver (POSIX, ELF64).
#
# Usage:
#   scripts/bootstrap/ele_seed_bootstrap.sh --seed <driver> --seed-sha256 <64 hex> \
#       --out-dir <new or empty dir> [--target elf] [--repo-root <dir>] \
#       [--forbid-toolchain-on-path] [--timeout <seconds>]
#
# Steps: verify the seed hash (refuse on mismatch); seed builds Gen1' from
# compiler-l/src/main_driver.l; Gen1' builds Gen2; Gen2 builds Gen3; require
# Gen2 == Gen3 bitwise (print both hashes and the first differing bytes
# otherwise); Gen3 compiles and runs scripts/bootstrap/smoke/cases.txt and
# compares exact stdout bytes and exit codes with the checked-in expectations;
# Gen3 must reject every program in scripts/bootstrap/smoke/reject.txt; write
# provenance.json and SHA256SUMS into the output directory.
#
# This script never runs cargo, rustc, rustup, Stage 0 (`l`), cl, link, gcc,
# clang or ld. Every compiler/program execution goes through run_image, which
# only executes images inside the output directory and refuses toolchain
# program names. `command -v` results for those programs are recorded in
# provenance.json for information only; --forbid-toolchain-on-path (or
# ELE_BOOTSTRAP_FORBID_TOOLCHAIN=1) makes a resolvable cargo/rustc/rustup an
# error.
set -eu

FORBIDDEN_TOOLS="cargo rustc rustup l cl link gcc clang ld lld ld.lld cc"
RUST_TOOLS="cargo rustc rustup"
DRIVER_SOURCE="compiler-l/src/main_driver.l"

SEED=""
SEED_SHA=""
TARGET="elf"
OUT_DIR=""
REPO_ROOT=""
FORBID="${ELE_BOOTSTRAP_FORBID_TOOLCHAIN:-0}"
TIMEOUT_SECS=600

die_usage() { echo "error: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --seed) [ $# -ge 2 ] || die_usage "--seed needs a value"; SEED=$2; shift 2 ;;
        --seed-sha256) [ $# -ge 2 ] || die_usage "--seed-sha256 needs a value"; SEED_SHA=$2; shift 2 ;;
        --target) [ $# -ge 2 ] || die_usage "--target needs a value"; TARGET=$2; shift 2 ;;
        --out-dir) [ $# -ge 2 ] || die_usage "--out-dir needs a value"; OUT_DIR=$2; shift 2 ;;
        --repo-root) [ $# -ge 2 ] || die_usage "--repo-root needs a value"; REPO_ROOT=$2; shift 2 ;;
        --timeout) [ $# -ge 2 ] || die_usage "--timeout needs a value"; TIMEOUT_SECS=$2; shift 2 ;;
        --forbid-toolchain-on-path) FORBID=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die_usage "unknown argument '$1'" ;;
    esac
done
[ -n "$SEED" ] || die_usage "--seed is required"
[ -n "$SEED_SHA" ] || die_usage "--seed-sha256 is required"
[ -n "$OUT_DIR" ] || die_usage "--out-dir is required"
[ "$TARGET" = "elf" ] || die_usage "this script bootstraps --target elf only (use ele_seed_bootstrap.ps1 for pe)"

if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
else
    REPO_ROOT=$(CDPATH= cd -- "$REPO_ROOT" && pwd)
fi

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
step() { echo "==> $*"; }

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    echo "error: need sha256sum or shasum" >&2; exit 2
fi
json_str() {
    # JSON string literal (or null for an empty value) for simple ASCII text.
    if [ -z "$1" ]; then printf 'null'; else
        printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')"
    fi
}

# ------------------------------------------------------------- output dir
if [ -e "$OUT_DIR" ]; then
    [ -d "$OUT_DIR" ] || { echo "refusing: output path '$OUT_DIR' exists and is not a directory" >&2; exit 2; }
    if [ -n "$(ls -A "$OUT_DIR")" ]; then
        echo "refusing: output directory '$OUT_DIR' is not empty; choose a new directory (existing outputs are never overwritten)" >&2
        exit 2
    fi
else
    mkdir -p "$OUT_DIR"
fi
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
LOG_DIR="$OUT_DIR/logs"
SMOKE_DIR="$OUT_DIR/smoke"
mkdir "$LOG_DIR" "$SMOKE_DIR"
PROV="$OUT_DIR/provenance.json"
STARTED=$(utc)

# Provenance pieces, assembled at exit (also on failure).
STATUS=failed
FAILURE=""
SOURCE_JSON=null
SEED_JSON=null
GUARD_JSON=null
GENS_JSON=""
FIXPOINT_JSON=null
SMOKE_JSON=""
REJECT_JSON=""

write_provenance() {
    {
        printf '{\n'
        printf '  "schema": "ele-seed-bootstrap/v1",\n'
        printf '  "status": "%s",\n' "$STATUS"
        printf '  "failure": %s,\n' "$(json_str "$FAILURE")"
        printf '  "target": "%s",\n' "$TARGET"
        printf '  "host": {"os": %s, "arch": %s, "script": "scripts/bootstrap/ele_seed_bootstrap.sh"},\n' \
            "$(json_str "$(uname -s)")" "$(json_str "$(uname -m)")"
        printf '  "started_utc": "%s",\n' "$STARTED"
        printf '  "finished_utc": "%s",\n' "$(utc)"
        printf '  "source": %s,\n' "$SOURCE_JSON"
        printf '  "seed": %s,\n' "$SEED_JSON"
        printf '  "guard": %s,\n' "$GUARD_JSON"
        printf '  "generations": [%s],\n' "$GENS_JSON"
        printf '  "fixpoint": %s,\n' "$FIXPOINT_JSON"
        printf '  "smoke": [%s],\n' "$SMOKE_JSON"
        printf '  "reject": [%s]\n' "$REJECT_JSON"
        printf '}\n'
    } > "$PROV"
}
fail() {
    FAILURE="$*"
    echo "BOOTSTRAP FAILED: $*" >&2
    write_provenance
    echo "provenance: $PROV"
    exit 1
}
assert_fresh() { [ ! -e "$1" ] || fail "refusing to overwrite existing output '$1'"; }

# ------------------------------------------------------------- exec guard
assert_allowed_image() {
    case "$1" in
        "$OUT_DIR"/*) ;;
        *) fail "guard: refusing to execute '$1': only images inside the bootstrap output directory may run" ;;
    esac
    _base=$(basename -- "$1"); _base=${_base%.*}
    for _t in $FORBIDDEN_TOOLS; do
        [ "$_base" != "$_t" ] || fail "guard: refusing to execute '$1': '$_t' is a forbidden toolchain program"
    done
}
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout $TIMEOUT_SECS"; fi
# run_image <workdir> <logname> <image> [args...]; sets RC, stdout/stderr in logs.
run_image() {
    _wd=$1; _log=$2; _img=$3; shift 3
    assert_allowed_image "$_img"
    set +e
    (cd "$_wd" && exec $TIMEOUT_CMD "$_img" "$@") </dev/null >"$LOG_DIR/$_log.stdout" 2>"$LOG_DIR/$_log.stderr"
    RC=$?
    set -e
}

# ------------------------------------------------------------- guard info
step "guard: toolchain programs on PATH (recorded for information; never executed)"
_info=""
for _t in $FORBIDDEN_TOOLS; do
    _p=$(command -v "$_t" 2>/dev/null || true)
    printf '    %-7s %s\n' "$_t" "${_p:-(not found)}"
    _info="$_info${_info:+, }\"$_t\": $(json_str "$_p")"
done
_never=""
for _t in $FORBIDDEN_TOOLS; do _never="$_never${_never:+, }\"$_t\""; done
GUARD_JSON="{\"never_executed\": [$_never], \"executes_only_inside_out_dir\": true, \"rust_toolchain_forbidden\": $([ "$FORBID" = 1 ] && echo true || echo false), \"host_tools_info\": {$_info}}"
if [ "$FORBID" = 1 ]; then
    _present=""
    for _t in $RUST_TOOLS; do
        if command -v "$_t" >/dev/null 2>&1; then _present="$_present $_t"; fi
    done
    [ -z "$_present" ] || fail "guard: Rust toolchain resolvable on PATH but forbidden:$_present"
fi

# ------------------------------------------------------------- source info
# An explicit ELE_SOURCE_COMMIT wins and skips git entirely (useful when the
# checkout is shared with another OS, e.g. a Windows tree seen from WSL).
COMMIT=""; COMMIT_FROM=unknown; DIRTY=null
if [ -n "${ELE_SOURCE_COMMIT:-}" ]; then
    COMMIT=$ELE_SOURCE_COMMIT; COMMIT_FROM=env:ELE_SOURCE_COMMIT
elif command -v git >/dev/null 2>&1 && COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null); then
    COMMIT_FROM=git
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then DIRTY=true; else DIRTY=false; fi
else
    COMMIT=""
fi
if [ -z "$COMMIT" ] && [ -n "${GITHUB_SHA:-}" ]; then COMMIT=$GITHUB_SHA; COMMIT_FROM=env:GITHUB_SHA; fi
[ -f "$REPO_ROOT/$DRIVER_SOURCE" ] || fail "driver source not found: $REPO_ROOT/$DRIVER_SOURCE"
SOURCE_JSON="{\"commit\": $(json_str "$COMMIT"), \"commit_from\": \"$COMMIT_FROM\", \"tracked_files_dirty\": $DIRTY, \"driver_source\": \"$DRIVER_SOURCE\", \"driver_source_sha256\": \"$(sha256 "$REPO_ROOT/$DRIVER_SOURCE")\"}"

# ------------------------------------------------------------- seed
step "verify seed '$SEED'"
case "$SEED_SHA" in
    *[!0-9a-fA-F]*) fail "seed sha256 must be 64 hex characters" ;;
esac
[ ${#SEED_SHA} -eq 64 ] || fail "seed sha256 must be 64 hex characters"
EXPECTED=$(printf '%s' "$SEED_SHA" | tr 'A-F' 'a-f')
[ -f "$SEED" ] || fail "seed not found: $SEED"
_sb=$(basename -- "$SEED"); _sb=${_sb%.*}
for _t in $FORBIDDEN_TOOLS; do
    [ "$_sb" != "$_t" ] || fail "guard: seed '$SEED' is named like a forbidden toolchain program ('$_t')"
done
ACTUAL=$(sha256 "$SEED")
SEED_JSON="{\"file_name\": $(json_str "$(basename -- "$SEED")"), \"sha256_expected\": \"$EXPECTED\", \"sha256_actual\": \"$ACTUAL\", \"size\": $(wc -c < "$SEED" | tr -d ' ')}"
[ "$ACTUAL" = "$EXPECTED" ] || fail "seed hash mismatch: expected $EXPECTED, got $ACTUAL"
SEED_COPY="$OUT_DIR/seed.elf"
assert_fresh "$SEED_COPY"
cp "$SEED" "$SEED_COPY"
chmod 755 "$SEED_COPY"
[ "$(sha256 "$SEED_COPY")" = "$EXPECTED" ] || fail "seed copy hash mismatch (file changed while copying)"
echo "    seed sha256 $ACTUAL (matches pin)"
run_image "$REPO_ROOT" seed-help "$SEED_COPY" --help
if [ "$RC" -ne 0 ] || ! grep -q 'ELE Compiler Driver' "$LOG_DIR/seed-help.stdout"; then
    fail "seed does not identify as the ELE compiler driver (--help)"
fi

# ------------------------------------------------------------- generations
build_gen() {
    _name=$1; _by=$2; _compiler=$3
    _out="$OUT_DIR/$_name.elf"
    assert_fresh "$_out"
    step "$_by builds $_name"
    _s0=$(utc); _t0=$(date +%s)
    run_image "$REPO_ROOT" "build-$_name" "$_compiler" build "$DRIVER_SOURCE" --target "$TARGET" --output "$_out"
    _secs=$(( $(date +%s) - _t0 ))
    if [ "$RC" -ne 0 ] || [ ! -f "$_out" ]; then
        fail "$_by failed to build $_name (exit $RC): $(head -c 2000 "$LOG_DIR/build-$_name.stderr")"
    fi
    [ "$(head -c 4 "$_out" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || fail "$_name is not an ELF image"
    chmod 755 "$_out"
    _sha=$(sha256 "$_out"); _size=$(wc -c < "$_out" | tr -d ' ')
    echo "    $_name sha256 $_sha ($_size bytes, ${_secs} s)"
    GENS_JSON="$GENS_JSON${GENS_JSON:+, }{\"name\": \"$_name\", \"built_by\": \"$_by\", \"file\": \"$_name.elf\", \"sha256\": \"$_sha\", \"size\": $_size, \"started_utc\": \"$_s0\", \"finished_utc\": \"$(utc)\", \"seconds\": $_secs}"
}
build_gen gen1prime seed "$SEED_COPY"
build_gen gen2 gen1prime "$OUT_DIR/gen1prime.elf"
build_gen gen3 gen2 "$OUT_DIR/gen2.elf"

# ------------------------------------------------------------- fixpoint
G1=$(sha256 "$OUT_DIR/gen1prime.elf"); G2=$(sha256 "$OUT_DIR/gen2.elf"); G3=$(sha256 "$OUT_DIR/gen3.elf")
[ "$G1" = "$G2" ] && G1EQ=true || G1EQ=false
step "fixpoint check Gen2 == Gen3"
echo "    gen2 $G2"
echo "    gen3 $G3"
if cmp -s "$OUT_DIR/gen2.elf" "$OUT_DIR/gen3.elf"; then
    FIXPOINT_JSON="{\"gen2_sha256\": \"$G2\", \"gen3_sha256\": \"$G3\", \"gen2_equals_gen3\": true, \"gen1prime_equals_gen2\": $G1EQ}"
    echo "    BITWISE EQUAL (gen1prime == gen2: $G1EQ)"
else
    S2=$(wc -c < "$OUT_DIR/gen2.elf" | tr -d ' '); S3=$(wc -c < "$OUT_DIR/gen3.elf" | tr -d ' ')
    NDIFF=$(cmp -l "$OUT_DIR/gen2.elf" "$OUT_DIR/gen3.elf" 2>/dev/null | wc -l | tr -d ' ')
    echo "    sizes: gen2 $S2 bytes, gen3 $S3 bytes; differing bytes in common prefix: $NDIFF"
    echo "    first differences (1-based offset, octal gen2, octal gen3):"
    cmp -l "$OUT_DIR/gen2.elf" "$OUT_DIR/gen3.elf" 2>/dev/null | head -n 16 | sed 's/^/      /'
    FIXPOINT_JSON="{\"gen2_sha256\": \"$G2\", \"gen3_sha256\": \"$G3\", \"gen2_equals_gen3\": false, \"gen1prime_equals_gen2\": $G1EQ, \"difference\": {\"size_gen2\": $S2, \"size_gen3\": $S3, \"differing_bytes_common\": $NDIFF}}"
    fail "NOT A FIXPOINT: Gen2 and Gen3 differ bitwise (see differences above and provenance.json)"
fi
GEN3="$OUT_DIR/gen3.elf"

# ------------------------------------------------------------- smoke
SMOKE_ROOT="$REPO_ROOT/scripts/bootstrap/smoke"
FAILS=0
NSMOKE=0
while IFS='|' read -r name src want_exit; do
    case "$name" in ''|'#'*) continue ;; esac
    NSMOKE=$((NSMOKE + 1))
    exe="$SMOKE_DIR/$name.elf"
    assert_fresh "$exe"
    step "smoke $name ($src)"
    run_image "$REPO_ROOT" "smoke-build-$name" "$GEN3" build "$src" --target "$TARGET" --output "$exe"
    build_rc=$RC; got=null; match=false; ok=false
    if [ "$build_rc" -eq 0 ] && [ -f "$exe" ]; then
        chmod 755 "$exe"
        run_image "$SMOKE_DIR" "smoke-run-$name" "$exe"
        got=$RC
        if cmp -s "$LOG_DIR/smoke-run-$name.stdout" "$SMOKE_ROOT/expected/$name.stdout"; then match=true; fi
        if [ "$match" = true ] && [ "$got" -eq "$want_exit" ]; then ok=true; fi
    else
        echo "    build failed: $(head -c 2000 "$LOG_DIR/smoke-build-$name.stderr")"
    fi
    echo "    exit $got (want $want_exit), stdout $([ "$match" = true ] && echo match || echo MISMATCH) -> $([ "$ok" = true ] && echo ok || echo FAIL)"
    [ "$ok" = true ] || FAILS=$((FAILS + 1))
    SMOKE_JSON="$SMOKE_JSON${SMOKE_JSON:+, }{\"name\": \"$name\", \"source\": \"$src\", \"build_exit\": $build_rc, \"expected_exit\": $want_exit, \"actual_exit\": $got, \"stdout_match\": $match, \"ok\": $ok}"
done < "$SMOKE_ROOT/cases.txt"

NREJECT=0
while IFS='|' read -r name src want_exit needle; do
    case "$name" in ''|'#'*) continue ;; esac
    NREJECT=$((NREJECT + 1))
    exe="$SMOKE_DIR/reject-$name.elf"
    assert_fresh "$exe"
    step "reject $name ($src)"
    run_image "$REPO_ROOT" "reject-$name" "$GEN3" build "$src" --target "$TARGET" --output "$exe"
    wrote=false; [ ! -e "$exe" ] || wrote=true
    has=false; grep -qF -- "$needle" "$LOG_DIR/reject-$name.stderr" && has=true
    ok=false
    if [ "$RC" -eq "$want_exit" ] && [ "$has" = true ] && [ "$wrote" = false ]; then ok=true; fi
    echo "    exit $RC (want $want_exit), stderr has $needle: $has, image written: $wrote -> $([ "$ok" = true ] && echo ok || echo FAIL)"
    [ "$ok" = true ] || FAILS=$((FAILS + 1))
    REJECT_JSON="$REJECT_JSON${REJECT_JSON:+, }{\"name\": \"$name\", \"source\": \"$src\", \"expected_exit\": $want_exit, \"actual_exit\": $RC, \"required_stderr\": $(json_str "$needle"), \"stderr_matched\": $has, \"image_written\": $wrote, \"ok\": $ok}"
done < "$SMOKE_ROOT/reject.txt"

[ "$NSMOKE" -gt 0 ] && [ "$NREJECT" -gt 0 ] || fail "smoke or reject manifest is empty"
[ "$FAILS" -eq 0 ] || fail "$FAILS smoke/reject check(s) failed"

# ------------------------------------------------------------- manifest
SUMS="$OUT_DIR/SHA256SUMS"
assert_fresh "$SUMS"
for f in seed.elf gen1prime.elf gen2.elf gen3.elf; do
    printf '%s  %s\n' "$(sha256 "$OUT_DIR/$f")" "$f"
done > "$SUMS"

STATUS=ok
write_provenance
step "OK: Stage-0-free chain seed -> gen1prime -> gen2 -> gen3 is a bitwise fixpoint ($G3)"
echo "provenance: $PROV"
