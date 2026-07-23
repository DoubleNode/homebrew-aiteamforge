#!/bin/bash
# tests/test-xaca-0831-alloc-slot-atomicity.sh
#
# XACA-0831-004: validation test for the XACA-0818 atomic knowledge-ID
# allocator (_kb_alloc_slot), now ported into BOTH tap-shipped helper files:
#   share/templates/kanban/kanban-helpers.template.sh
#   share/templates/aliases/kanban-aliases.sh
#
# _kb_alloc_slot <target_dir> <prefix> <slug> serializes the whole
# "scan existing <prefix>NNN-*.md -> compute next NNN -> reserve an empty
# placeholder" critical section under an exclusive perl-flock lock keyed by a
# cksum hash of the absolute target_dir (lock lives at
# ${TMPDIR:-/tmp}/kb-alloc-<hash>.lock -- deliberately OUTSIDE the git-synced
# knowledge tree, see the XACA-0818 retro on the in-tree-lock wedge). This is
# Mechanism A (the fix). Mechanism B is the fleet duplicate-slot BACKSTOP: a
# post-merge gate (canonical scripts/kb-knowledge-sync.sh, Guard 4, ~L288-301,
# variable `_dup_slots`) that scans a directory tree for two *.md files
# sharing the same "<letters><NNN>-" slot key and fails loudly if any exist.
# Mechanism B is an ALARM, not a fix -- consumers already had it (ported
# earlier) but without Mechanism A the alarm could only ever report duplicates
# it had no way to prevent. This suite proves Mechanism A now actually
# prevents what Mechanism B would otherwise have to report.
#
#   PART A -- concurrency / no-duplicate-slot, run separately against EACH
#     ported copy (template AND aliases -- a fix present in one file but not
#     the other must fail this test). >=20 concurrent `_kb_alloc_slot` calls,
#     each in its own backgrounded `zsh -c` subshell (own interpreter, own
#     `source` -- matching real independent concurrent callers, not just
#     backgrounded functions sharing one process), fired at ONE shared target
#     directory, then `wait`ed. Asserts:
#       A1: every one of the N calls returns a non-empty filename that exists
#       A2: the N returned filenames are ALL DISTINCT (no two writers got
#           handed the same file)
#       A3: the N files actually created on disk == N (no writer silently
#           failed / no writer's file got clobbered)
#       A4: the N reserved NNN slots are ALL DISTINCT (the core atomicity
#           contract -- this is what Mechanism A must guarantee and what a
#           TOCTOU race would violate)
#       A5: the NNN slot set is exactly the CONTIGUOUS range 1..N (proves the
#           allocator is a true monotonic counter, not just accidentally
#           collision-free with gaps)
#
#   PART B -- Mechanism B reports clean post-port. After each Part A run,
#     the dup-slot detector is applied (mirrored verbatim from
#     scripts/kb-knowledge-sync.sh's `_dup_slots` computation) to the produced
#     directory and asserted to report ZERO duplicates -- i.e. Mechanism A's
#     output satisfies Mechanism B's own alarm criterion.
#
#   PART C [NEGATIVE CONTROL] -- proves Part B's assertion actually BITES.
#     A directory is hand-constructed with two files deliberately sharing the
#     slot k002 (k002-foo.md + k002-bar.md), and the SAME detector function is
#     asserted to report a NON-EMPTY collision naming both files. Without this
#     control, a detector that always reports "clean" (e.g. broken glob, wrong
#     awk key) would make Part B pass VACUOUSLY -- see memory
#     feedback_tap_test_harness_vacuous_green.
#
# REQUIRES ZSH ON PATH, NOT JUST BASH (memory: known QA trap -- wrong-shell
# vacuous pass): _kb_alloc_slot and its callers are zsh functions defined
# inside zsh-shebang (`#!/bin/zsh`) files. EVERY invocation of the ported
# function in this suite runs inside its own `zsh -c "source ...; ..."`
# subshell (matching test-xaca-0746's / test-xaca-0788's convention) -- the
# system-under-test NEVER executes under bash, regardless of which shell
# drives this test file. `command -v zsh` is a hard prerequisite (checked
# below, fatal if absent) so a missing zsh can never silently degrade this
# into "0 real writers ran" and print a false green.
#
# The OUTER driver deliberately stays `#!/bin/bash` (not zsh) because
# tests/test-runner.sh unconditionally invokes every discovered test file via
# `bash "$test_file"` -- a zsh-shebang outer script would be silently
# re-executed under bash by the shared runner and could mis-parse zsh-only
# syntax outside the `zsh -c` blocks. This is the same reason both reference
# tests (test-xaca-0788, test-xaca-0746) use a bash outer / zsh-c inner split.
#
# Run standalone:
#   bash tests/test-xaca-0831-alloc-slot-atomicity.sh
# OR via tests/test-runner.sh (auto-discovered as test-*.sh).
#
# Sandboxed: every file this test creates or scans lives under a mktemp
# TEST_TMP_DIR -- never the real ~/knowledge or ~/knowledge-local tree.
#
# Exit 0 = all assertions passed (and the negative control fired correctly).
# Exit 1 = any assertion failed, a required tool (zsh/perl/awk/sed/find) is
# missing, or zero assertions ran (vacuous run).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi
if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: kanban-aliases.sh not found at: $ALIASES_PATH" >&2
    exit 1
fi
if ! grep -q '_kb_alloc_slot()' "$TEMPLATE_PATH"; then
    echo "FATAL: _kb_alloc_slot() not found in $TEMPLATE_PATH -- has the XACA-0818 port regressed?" >&2
    exit 1
fi
if ! grep -q '_kb_alloc_slot()' "$ALIASES_PATH"; then
    echo "FATAL: _kb_alloc_slot() not found in $ALIASES_PATH -- has the XACA-0818 port regressed?" >&2
    exit 1
fi
# Hard prerequisites. zsh IS the system-under-test's runtime -- if it is
# unavailable we CANNOT stub the concurrency case into a vacuous pass, so we
# fail loudly instead (matches test-xaca-0788's escalation contract).
for _tool in zsh perl awk sed find; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH -- cannot exercise the perl-flock allocator / dup-slot detector." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0788's `ok` pattern): explicit
# pass/fail counters independent of any outer harness, so a run with zero real
# assertions can never read as "all passed" (memory:
# feedback_tap_test_harness_vacuous_green -- tap assert_* helpers record only
# on FAILURE elsewhere in this repo; we do not rely on that convention here).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi

_P0831_PASS=0
_P0831_FAIL=0

# ok <label> <cond(1|0)> [failure_detail]
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _P0831_PASS=$((_P0831_PASS + 1)); test_pass
    else
        _P0831_FAIL=$((_P0831_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0831-alloc-slot-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0831"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Render both shipped files (install-time {{PLACEHOLDER}} substitution) --
# mirrors test-xaca-0746's / test-xaca-0788's rendering approach. Neither
# file's _kb_alloc_slot consumes these placeholders directly, but the files
# must parse cleanly end-to-end when sourced.
# ─────────────────────────────────────────────────────────────────────────────
_render() {
    local src="$1" dst="$2"
    sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
         s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
         s|{{ORG_NAME}}|TestOrg|g; \
         s|{{ORG_SLUG}}|testorg|g" \
        "$src" > "$dst"
}

TEMPLATE_RENDERED="$WORK_DIR/kanban-helpers-template-rendered.sh"
_render "$TEMPLATE_PATH" "$TEMPLATE_RENDERED"

ALIASES_RENDERED="$WORK_DIR/kanban-aliases-rendered.sh"
_render "$ALIASES_PATH" "$ALIASES_RENDERED"

# ─────────────────────────────────────────────────────────────────────────────
# Mechanism B mirror: the fleet duplicate-slot detector, copied verbatim
# (algorithm only -- no REPO_DIR/log/exit-code plumbing) from the canonical
# source of truth `scripts/kb-knowledge-sync.sh` Guard 4, lines ~288-301,
# variable `_dup_slots`. Per the canonical-source rule (XACA-0340) that file
# -- not its tap mirror -- is authoritative; this test intentionally
# reimplements the ALGORITHM inline (as the canonical Guard 4 itself does
# relative to kb-knowledge-validate) rather than sourcing/invoking the daemon
# script, which requires a live git repo with an upstream to pass its own
# Guards 1-3 and is out of scope for a pure allocator test. Pure POSIX
# find/sed/awk -- no bash- or zsh-only syntax -- so it runs identically
# under this file's bash driver.
#
# Usage: _detect_dup_slots <dir>  -- prints one line per collision (empty
# output == no duplicates found).
# ─────────────────────────────────────────────────────────────────────────────
_detect_dup_slots() {
    local dir="$1"
    find "$dir" -type f -name '*.md' ! -name 'INDEX.md' -not -path '*/.git/*' -print0 2>/dev/null \
    | while IFS= read -r -d '' _f; do
        local _d="${_f%/*}" _b="${_f##*/}"
        local _slot
        _slot="$(printf '%s\n' "$_b" | sed -n 's/^\([a-z][a-z]*[0-9][0-9][0-9]\)-.*\.md$/\1/p')"
        [ -n "$_slot" ] && printf '%s\t%s\t%s\n' "$_d" "$_slot" "$_b"
      done \
    | awk -F'\t' '{ key=$1 "\t" $2; c[key]++; if (c[key]==1) { first[key]=$3 } else { print $1 "  slot=" $2 "  collides: " first[key] " + " $3 } }'
}

# ─────────────────────────────────────────────────────────────────────────────
# Part A/B runner: fires N_WRITERS concurrent `_kb_alloc_slot` calls against a
# single shared target dir, each in its own backgrounded `zsh -c` subshell
# that independently sources the given rendered file -- a real independent
# concurrent caller, not just a backgrounded function sharing one
# interpreter. Populates the RES_* globals consumed by the caller.
# ─────────────────────────────────────────────────────────────────────────────
N_WRITERS="${XACA_0831_N_WRITERS:-25}"

_run_concurrent_alloc() {
    local label="$1" rendered_file="$2"
    local sandbox="$WORK_DIR/${label}-sandbox"
    local target_dir="$sandbox/agents/testpersona"
    local ret_dir="$sandbox/returns"
    mkdir -p "$target_dir" "$ret_dir"

    local i
    local pids=()
    for (( i = 1; i <= N_WRITERS; i++ )); do
        (
            zsh -c "
                source '$rendered_file' >/dev/null 2>&1
                _kb_alloc_slot '$target_dir' 'k' 'writer-${i}'
            " > "$ret_dir/ret_${i}.txt" 2>"$ret_dir/err_${i}.txt"
        ) &
        pids+=("$!")
    done
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # ── Collect the N returned filenames (one per writer, stdout of the call) ──
    local rf content
    local returned=()
    for (( i = 1; i <= N_WRITERS; i++ )); do
        rf="$ret_dir/ret_${i}.txt"
        content=""
        [ -f "$rf" ] && content="$(tr -d '[:space:]' < "$rf" 2>/dev/null)"
        returned+=("$content")
    done

    RES_RETURNED_NONEMPTY_COUNT=0
    RES_RETURNED_EXISTS_COUNT=0
    for content in "${returned[@]}"; do
        if [ -n "$content" ]; then
            RES_RETURNED_NONEMPTY_COUNT=$((RES_RETURNED_NONEMPTY_COUNT + 1))
            [ -f "$content" ] && RES_RETURNED_EXISTS_COUNT=$((RES_RETURNED_EXISTS_COUNT + 1))
        fi
    done
    RES_DISTINCT_RETURNED_COUNT=$(
        printf '%s\n' "${returned[@]}" | grep -v '^$' | sort -u | wc -l | tr -d ' '
    )

    # ── Collect the files actually created on disk + their NNN slots ──────────
    shopt -s nullglob
    local created_files=("${target_dir}"/k[0-9][0-9][0-9]-*.md)
    shopt -u nullglob
    RES_FILE_COUNT=${#created_files[@]}
    RES_TARGET_DIR="$target_dir"

    local f base numstr num
    local nnn_list=()
    for f in "${created_files[@]}"; do
        base=$(basename "$f")
        numstr=$(printf '%s' "$base" | grep -oE '^k[0-9]{3}' | tr -d 'k')
        [ -z "$numstr" ] && continue
        num=$((10#$numstr))
        nnn_list+=("$num")
    done

    if [ "${#nnn_list[@]}" -gt 0 ]; then
        RES_DISTINCT_NNN_COUNT=$(printf '%s\n' "${nnn_list[@]}" | sort -u | wc -l | tr -d ' ')
        RES_ACTUAL_SEQ="$(printf '%s\n' "${nnn_list[@]}" | sort -n | tr '\n' ' ')"
    else
        RES_DISTINCT_NNN_COUNT=0
        RES_ACTUAL_SEQ=""
    fi

    # Contiguity: sorted NNN list must equal exactly "1 2 3 ... N_WRITERS".
    local expected_seq="" n
    for (( n = 1; n <= N_WRITERS; n++ )); do expected_seq+="$n "; done
    if [ "$RES_ACTUAL_SEQ" = "$expected_seq" ]; then
        RES_CONTIGUOUS=1
    else
        RES_CONTIGUOUS=0
    fi

    # ── Mechanism B mirror applied to the produced directory ──────────────────
    RES_DUP_SLOTS="$(_detect_dup_slots "$sandbox")"
}

# ═══════════════════════════════════════════════════════════════════════════
# PART A/B -- run against EACH ported copy independently.
# ═══════════════════════════════════════════════════════════════════════════
for _label in template aliases; do
    if [ "$_label" = "template" ]; then
        _rendered="$TEMPLATE_RENDERED"
        _display="kanban-helpers.template.sh"
    else
        _rendered="$ALIASES_RENDERED"
        _display="kanban-aliases.sh"
    fi

    printf '\n%s\n' "--- ${_display}: ${N_WRITERS} concurrent _kb_alloc_slot calls at one shared target dir ---"
    _run_concurrent_alloc "$_label" "$_rendered"

    ok "A1[$_label]: all ${N_WRITERS} concurrent calls returned a non-empty, existing filename" \
       "$([ "$RES_RETURNED_NONEMPTY_COUNT" -eq "$N_WRITERS" ] && [ "$RES_RETURNED_EXISTS_COUNT" -eq "$N_WRITERS" ] && echo 1 || echo 0)" \
       "non-empty returns: $RES_RETURNED_NONEMPTY_COUNT/${N_WRITERS}; returns pointing at an existing file: $RES_RETURNED_EXISTS_COUNT/${N_WRITERS}"

    ok "A2[$_label]: the ${N_WRITERS} returned filenames are ALL DISTINCT (no two writers handed the same file)" \
       "$([ "$RES_DISTINCT_RETURNED_COUNT" -eq "$N_WRITERS" ] && echo 1 || echo 0)" \
       "expected ${N_WRITERS} distinct returned filenames, got $RES_DISTINCT_RETURNED_COUNT"

    ok "A3[$_label]: ${N_WRITERS} files were actually created on disk (no writer silently failed)" \
       "$([ "$RES_FILE_COUNT" -eq "$N_WRITERS" ] && echo 1 || echo 0)" \
       "expected ${N_WRITERS} files in $RES_TARGET_DIR, found $RES_FILE_COUNT"

    ok "A4[$_label]: the ${N_WRITERS} reserved NNN slots are ALL DISTINCT (core atomicity contract; a TOCTOU race would violate this)" \
       "$([ "$RES_DISTINCT_NNN_COUNT" -eq "$N_WRITERS" ] && echo 1 || echo 0)" \
       "expected ${N_WRITERS} distinct NNN slots, got $RES_DISTINCT_NNN_COUNT -- ids: $RES_ACTUAL_SEQ"

    ok "A5[$_label]: the NNN slot set is exactly the contiguous range 1..${N_WRITERS}" \
       "$([ "$RES_CONTIGUOUS" -eq 1 ] && echo 1 || echo 0)" \
       "expected contiguous 1..${N_WRITERS}, got: $RES_ACTUAL_SEQ"

    ok "B[$_label]: Mechanism B (fleet dup-slot detector) reports ZERO duplicates against the produced directory" \
       "$([ -z "$RES_DUP_SLOTS" ] && echo 1 || echo 0)" \
       "expected empty dup-slot report, got: $RES_DUP_SLOTS"
done

# ═══════════════════════════════════════════════════════════════════════════
# PART C [NEGATIVE CONTROL] -- proves the Part B assertion actually bites.
# A hand-built directory with two files deliberately sharing slot k002 (plus
# one clean k001 entry as a non-colliding control) MUST be reported as a
# collision by the exact same _detect_dup_slots function used above. Without
# this, a detector that always reports "clean" would make every Part B
# assertion pass vacuously.
# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s\n' "--- Negative control: hand-built k002/k002 collision must be DETECTED ---"
NEG_DIR="$WORK_DIR/negative-control"
mkdir -p "$NEG_DIR"
: > "$NEG_DIR/k001-clean-entry.md"
: > "$NEG_DIR/k002-foo.md"
: > "$NEG_DIR/k002-bar.md"

NEG_DUP_SLOTS="$(_detect_dup_slots "$NEG_DIR")"

ok "C1 [NEGATIVE CONTROL]: deliberately-colliding k002-foo.md / k002-bar.md IS detected (non-empty report)" \
   "$([ -n "$NEG_DUP_SLOTS" ] && echo 1 || echo 0)" \
   "expected a non-empty collision report for $NEG_DIR, got EMPTY -- the detector cannot distinguish colliding from clean, which would make every Part B pass vacuously"

ok "C2 [NEGATIVE CONTROL]: the collision report correctly names slot k002 and both colliding files" \
   "$(echo "$NEG_DUP_SLOTS" | grep -q 'slot=k002' && echo "$NEG_DUP_SLOTS" | grep -q 'k002-foo.md' && echo "$NEG_DUP_SLOTS" | grep -q 'k002-bar.md' && echo 1 || echo 0)" \
   "expected report to mention slot=k002 and both k002-foo.md + k002-bar.md; got: $NEG_DUP_SLOTS"

ok "C3 [NEGATIVE CONTROL]: the non-colliding k001-clean-entry.md is NOT reported as a collision" \
   "$(echo "$NEG_DUP_SLOTS" | grep -q 'k001' && echo 0 || echo 1)" \
   "k001-clean-entry.md unexpectedly appeared in the collision report: $NEG_DUP_SLOTS"

# ─────────────────────────────────────────────────────────────────────────────
# Non-vacuousness guard + summary.
# ─────────────────────────────────────────────────────────────────────────────
_TOTAL=$((_P0831_PASS + _P0831_FAIL))
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "XACA-0831 alloc-slot-atomicity: Passed: ${_P0831_PASS} / Total: ${_TOTAL}  (Failed: ${_P0831_FAIL})"
echo "──────────────────────────────────────────────────────────────"

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_P0831_PASS} passed, ${_P0831_FAIL} failed"
fi

if [ "$_P0831_FAIL" -gt 0 ] || [ "$_TOTAL" -eq 0 ]; then
    exit 1
fi
exit 0
