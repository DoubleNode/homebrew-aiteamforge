#!/bin/bash
# test-xaca-0746-kb-knowledge-in-tap.sh
#
# XACA-0746 (subitem 004): the kb-knowledge-* subsystem is now ported into BOTH
# shipped helper files (install_kanban_helpers() prefers kanban-aliases.sh,
# falls back to kanban-helpers.template.sh — see install-kanban.sh:458). Before
# this ticket, a fresh tap install exposed ZERO working kb-knowledge-* commands
# (aliases file had none; the template only had kb-knowledge-search + 5
# privates). This test proves both shipped files now expose the full subsystem
# and that a real add/search/validate round-trip works with no dev-team
# checkout and no tmux context.
#
#   PART A — share/templates/aliases/kanban-aliases.sh (PREFERRED installed file)
#     Asserts all 15 functions are defined (5 public + 8 _kb_knowledge_* private
#     + 2 _kb_validate_* helpers) and exercises a real add -> search -> validate
#     round-trip against a sandboxed KB_KNOWLEDGE_GLOBAL_ROOT.
#
#   PART B — share/templates/kanban/kanban-helpers.template.sh (FALLBACK file)
#     Same 15-function definition assertions (this file already carried search
#     + 5 privates + both validators + _kb_detect_context before XACA-0746; the
#     4 missing publics + 3 missing privates were added by subitem 003).
#
#   PART C — external-dependency degradation
#     The subsystem's only external-tool dependency is `git` (via
#     _kb_knowledge_project_path's `git rev-parse` calls, used to resolve the
#     project-tier path). There is NO python3 dependency anywhere in the
#     kb-knowledge-* block (verified by grepping the 10793-12664 canonical
#     range) — kb-knowledge-validate is pure shell/awk/grep. This part proves
#     the git-absent path degrades gracefully (falls back to a "projects/unknown"
#     path, no crash, no stack trace) rather than the python3 check the original
#     plan doc assumed.
#
# Both files are zsh scripts (shebang #!/bin/zsh) — exercised under zsh, in a
# sandboxed subshell with HOME + KB_KNOWLEDGE_GLOBAL_ROOT pointed at a mktemp
# dir. No real $HOME mutation, no network, no dev-team checkout assumed.
#
# Designed to run standalone (`bash tests/test-xaca-0746-kb-knowledge-in-tap.sh`)
# OR via test-runner.sh (which exports its own test_start/test_pass/test_fail/
# assert_* and a shared TEST_TMP_DIR). Exit 0 = all cases pass, exit 1 = any fail.
#
# Requires: bash, zsh. jq/python3/git are NOT hard requirements of the
# kb-knowledge-* subsystem itself; Part C explicitly simulates git's absence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALIASES_PATH="$TAP_ROOT/share/templates/aliases/kanban-aliases.sh"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

if [ ! -f "$ALIASES_PATH" ]; then
    echo "FATAL: kanban-aliases.sh not found at: $ALIASES_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide no-op-compatible stubs when test-runner.sh has
# not exported the real harness functions, so this file also runs directly.
# (Pattern mirrors test-xaca-0743-four-tier-knowledge.sh.)
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""

    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory: use the runner-supplied TEST_TMP_DIR or create our own.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0746-knowledge-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0746"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Render both shipped files once: substitute install-time placeholders with
# dummy values (mirrors test-xaca-0743's / test-xaca-0649's approach). Neither
# file's kb-knowledge-* functions consume these directly, but the files must
# parse cleanly as a whole when sourced (kanban-aliases.sh in particular has
# other functions that reference {{AITEAMFORGE_DIR}}/{{SHARED_DEV_ROOT}}/etc.).
# ─────────────────────────────────────────────────────────────────────────────
A_RENDERED="$WORK_DIR/kanban-aliases-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$ALIASES_PATH" > "$A_RENDERED"

B_RENDERED="$WORK_DIR/kanban-helpers-template-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$B_RENDERED"

# The 15-function roster shared by both parts (5 public + 8 _kb_knowledge_*
# private + 2 _kb_validate_* helpers — matches the plan's enumeration).
KB_KNOWLEDGE_PUBLIC_FNS=(
    kb-knowledge-search
    kb-knowledge-add
    kb-knowledge-promote
    kb-knowledge-validate
    kb-knowledge-reindex
)
KB_KNOWLEDGE_PRIVATE_FNS=(
    _kb_knowledge_global_root
    _kb_knowledge_slugify
    _kb_knowledge_yaml_field
    _kb_knowledge_project_path
    _kb_knowledge_project_display_name
    _kb_knowledge_tier_rank
    _kb_knowledge_resolve_ref
    _kb_knowledge_reindex_one
    _kb_validate_name_component
    _kb_validate_subject_path
)

STDOUT_FILE="$WORK_DIR/stdout.txt"
STDERR_FILE="$WORK_DIR/stderr.txt"

# Run a snippet of zsh code, sourcing the given rendered file first, in a
# sandboxed subshell. Usage: _run_zsh <rendered_file> <home_dir> <global_root> <code...>
_run_zsh() {
    local rendered_file="$1" home_dir="$2" global_root="$3"
    shift 3
    env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        KB_KNOWLEDGE_GLOBAL_ROOT="$global_root" \
        KB_SEARCH_TELEMETRY_DISABLED=1 \
        zsh -c "
            cd '$home_dir' 2>/dev/null
            source '$rendered_file' >/dev/null 2>/dev/null
            $*
        " >"$STDOUT_FILE" 2>"$STDERR_FILE"
}
_stdout() { cat "$STDOUT_FILE" 2>/dev/null; }
_stderr() { cat "$STDERR_FILE" 2>/dev/null; }

_next_home() { mktemp -d "$WORK_DIR/home-XXXXXX"; }

# Assert every function in KB_KNOWLEDGE_PUBLIC_FNS + KB_KNOWLEDGE_PRIVATE_FNS
# is defined after sourcing the given rendered file. Usage:
#   _assert_all_defined <label> <rendered_file>
_assert_all_defined() {
    local label="$1" rendered_file="$2"
    local home_dir global_root
    home_dir=$(_next_home)
    global_root="$home_dir/knowledge"

    local fn missing=()
    for fn in "${KB_KNOWLEDGE_PUBLIC_FNS[@]}" "${KB_KNOWLEDGE_PRIVATE_FNS[@]}"; do
        _run_zsh "$rendered_file" "$home_dir" "$global_root" "typeset -f $fn >/dev/null 2>&1 && echo DEFINED || echo MISSING"
        if [ "$(_stdout | tr -d '[:space:]')" != "DEFINED" ]; then
            missing+=("$fn")
        fi
    done

    test_start "$label: all 15 kb-knowledge functions (5 public + 8 private + 2 validators) are defined"
    if [ ${#missing[@]} -eq 0 ]; then
        test_pass
    else
        test_fail "missing: ${missing[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PART A — kanban-aliases.sh (PREFERRED installed file)
# ═══════════════════════════════════════════════════════════════════════════

_assert_all_defined "PartA(aliases)" "$A_RENDERED"

# ── A2: kb-knowledge-add scaffolds an agent-tier entry with no dev-team checkout ──
test_start "PartA(aliases): kb-knowledge-add creates a scaffold entry (agent tier)"
A2_HOME=$(_next_home)
A2_ROOT="$A2_HOME/knowledge"
_run_zsh "$A_RENDERED" "$A2_HOME" "$A2_ROOT" \
    "kb-knowledge-add agent testpersona 'sandbox round trip entry'"
A2_FILE=$(find "$A2_ROOT/agents/testpersona" -maxdepth 1 -name 'k001-*.md' 2>/dev/null | head -1)
if [ -n "$A2_FILE" ] && [ -f "$A2_FILE" ] && grep -q '^tier: agent' "$A2_FILE" && grep -q '^agent: testpersona' "$A2_FILE"; then
    test_pass
else
    test_fail "expected a k001-*.md file under $A2_ROOT/agents/testpersona with tier:agent + agent:testpersona frontmatter; stdout=$(_stdout) stderr=$(_stderr) found='$A2_FILE'"
fi

# ── A3: kb-knowledge-search finds the entry just added ──────────────────────
test_start "PartA(aliases): kb-knowledge-search finds the freshly-added entry"
_run_zsh "$A_RENDERED" "$A2_HOME" "$A2_ROOT" \
    "kb-knowledge-search 'round trip' --agent testpersona --porcelain"
A3_OUT="$(_stdout)"
if echo "$A3_OUT" | grep -q '^agent:testpersona'; then
    test_pass
else
    test_fail "expected an agent:testpersona porcelain line; got: $A3_OUT (stderr=$(_stderr))"
fi

# ── A4: kb-knowledge-validate runs clean (no errors) against the fixture ────
test_start "PartA(aliases): kb-knowledge-validate passes against the fixture (rc=0, 0 errors)"
_run_zsh "$A_RENDERED" "$A2_HOME" "$A2_ROOT" \
    "kb-knowledge-validate --quiet; echo RC=\$?"
A4_OUT="$(_stdout)"
A4_RC=$(echo "$A4_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$A4_RC" = "0" ] && ! echo "$A4_OUT" | grep -q '\[FAIL\]'; then
    test_pass
else
    test_fail "expected rc=0 and no [FAIL] lines; got rc=$A4_RC; output: $A4_OUT"
fi

# ── A5: kb-knowledge-reindex regenerates INDEX.md for the agent tier dir ────
test_start "PartA(aliases): kb-knowledge-reindex regenerates INDEX.md (already ran once via kb-knowledge-add; re-run explicitly)"
_run_zsh "$A_RENDERED" "$A2_HOME" "$A2_ROOT" \
    "kb-knowledge-reindex --dir '$A2_ROOT/agents/testpersona'"
if [ -f "$A2_ROOT/agents/testpersona/INDEX.md" ] && grep -q 'K001' "$A2_ROOT/agents/testpersona/INDEX.md"; then
    test_pass
else
    test_fail "expected INDEX.md with a K001 entry; stdout=$(_stdout) stderr=$(_stderr)"
fi

# ── A6: kb-knowledge-promote (dry-run) prints a plan without --confirm ──────
test_start "PartA(aliases): kb-knowledge-promote dry-run (no --confirm) prints a plan, makes no changes"
_run_zsh "$A_RENDERED" "$A2_HOME" "$A2_ROOT" \
    "kb-knowledge-promote agents:testpersona:k001 subjects:testsubject"
A6_OUT="$(_stdout)"
if echo "$A6_OUT" | grep -q "PROMOTION PLAN" && echo "$A6_OUT" | grep -qi "Dry-run only"; then
    test_pass
else
    test_fail "expected a dry-run promotion plan; got: $A6_OUT (stderr=$(_stderr))"
fi

# ── A7: no tmux / $TMUX_PANE / ~/dev-team dependency in the ported block ────
# Structural check: extract the source text of the aliases-file port (from the
# XACA-0746 section marker to kb-help()'s opening line) and assert it contains
# no $TMUX_PANE / _kb_detect_context / literal ~/dev-team or $HOME/dev-team
# references. _kb_get_team (this file's own context-safe team resolver) is the
# only team-resolution call allowed inside the ported block.
test_start "PartA(aliases): ported block has no TMUX_PANE/dev-team/tmux-detect-context coupling"
A7_BLOCK=$(awk '/^# Knowledge System Helpers \(XACA-0746/{flag=1} flag{print} /^kb-help\(\) \{/{exit}' "$ALIASES_PATH")
# Two-stage filter to isolate CODE (not documentation prose) before matching:
#   1. Drop full-line comments (^\s*#) — removes both the copied-verbatim
#      canonical prose (which historically explains _kb_detect_context/tmux
#      resolution order) and this port's own section-header comment.
#   2. Drop any remaining line carrying the XACA-0746 marker — catches the one
#      inline trailing comment on a real code line (the _kb_log_dir adaptation)
#      that documents what was avoided in its comment tail.
# A blanket `sed 's/#.*//'` is NOT safe here instead of stage 1: zsh parameter
# expansions in this block use bare `#`/`##` for prefix removal
# (e.g. `${var#pattern}`), so stripping everything after the first `#` would
# corrupt those into false negatives. Only a LIVE reference in real code
# (an actual call/path use, surviving both filters) should fail this test.
A7_CODE=$(echo "$A7_BLOCK" | grep -vE '^\s*#' | grep -v 'XACA-0746')
A7_BAD=0
echo "$A7_CODE" | grep -q 'TMUX_PANE' && A7_BAD=1
echo "$A7_CODE" | grep -q '_kb_detect_context' && A7_BAD=1
echo "$A7_CODE" | grep -qE '\$HOME/dev-team|~/dev-team' && A7_BAD=1
if [ -n "$A7_BLOCK" ] && [ "$A7_BAD" -eq 0 ]; then
    test_pass
else
    test_fail "found a forbidden tmux/dev-team coupling in the ported aliases-file block (or block was empty); offending code lines: $(echo "$A7_CODE" | grep -E 'TMUX_PANE|_kb_detect_context|\$HOME/dev-team|~/dev-team')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART B — kanban-helpers.template.sh (FALLBACK file)
# ═══════════════════════════════════════════════════════════════════════════

_assert_all_defined "PartB(template)" "$B_RENDERED"

# ── B2: same add -> search -> validate round trip against the fallback file ──
test_start "PartB(template): kb-knowledge-add + kb-knowledge-search round trip"
B2_HOME=$(_next_home)
B2_ROOT="$B2_HOME/knowledge"
_run_zsh "$B_RENDERED" "$B2_HOME" "$B2_ROOT" \
    "kb-knowledge-add subject testsubject 'template fallback round trip'; kb-knowledge-search 'fallback round trip' --subject testsubject --porcelain"
B2_OUT="$(_stdout)"
if echo "$B2_OUT" | grep -q '^subject:testsubject'; then
    test_pass
else
    test_fail "expected a subject:testsubject porcelain line; got: $B2_OUT (stderr=$(_stderr))"
fi

# ── B3: kb-knowledge-validate passes against the fixture ────────────────────
test_start "PartB(template): kb-knowledge-validate passes (rc=0, 0 errors)"
_run_zsh "$B_RENDERED" "$B2_HOME" "$B2_ROOT" \
    "kb-knowledge-validate --quiet; echo RC=\$?"
B3_OUT="$(_stdout)"
B3_RC=$(echo "$B3_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
if [ "$B3_RC" = "0" ] && ! echo "$B3_OUT" | grep -q '\[FAIL\]'; then
    test_pass
else
    test_fail "expected rc=0 and no [FAIL] lines; got rc=$B3_RC; output: $B3_OUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART C — external-dependency degradation (git-absent; NOT python3)
#
# XACA-0746 recon note: the plan doc's risk section named python3 as an
# external dependency of kb-knowledge-validate. That does not hold up under
# inspection — grepping the full canonical 10793-12664 line range for
# "python3" returns zero hits. The subsystem's only external-tool touchpoint
# is `git` (via _kb_knowledge_project_path's `git rev-parse --git-common-dir` /
# `--show-toplevel` calls, used to resolve the project-tier path). This part
# tests THAT dependency's graceful degradation instead of a python3 path that
# doesn't exist in this code.
# ═══════════════════════════════════════════════════════════════════════════

# Simulate "git absent" by shadowing `git` with a zsh function that returns 127
# (the shell's own "command not found" exit code) AFTER sourcing the aliases
# file. This is more surgical than stripping git's PATH directory: on macOS,
# /usr/bin/git (the Xcode CLT shim) shares a directory with find/grep/awk/sed —
# excluding that whole directory to hide git also hides the tools
# kb-knowledge-search itself depends on, producing a false "0 results" failure
# that looks like a git-absence bug but is actually a broken test harness
# (caught while writing this test — see retro notes). Shadowing the single
# command name leaves every other utility on PATH untouched.
test_start "PartC: kb-knowledge-search runs cleanly (no crash) when git is absent"
C1_HOME=$(_next_home)
C1_ROOT="$C1_HOME/knowledge"
mkdir -p "$C1_ROOT/agents/nogit"
cat > "$C1_ROOT/agents/nogit/k001-note.md" <<'EOF'
---
id: k001-note
tier: agent
agent: nogit
date: 2026-07-06
tags: []
---

# K001: Note

Body text.
EOF
env -i \
    HOME="$C1_HOME" \
    PATH="$PATH" \
    TERM="${TERM:-dumb}" \
    KB_KNOWLEDGE_GLOBAL_ROOT="$C1_ROOT" \
    KB_SEARCH_TELEMETRY_DISABLED=1 \
    zsh -c "
        cd '$C1_HOME' 2>/dev/null
        source '$A_RENDERED' >/dev/null 2>/dev/null
        git() { return 127; }
        kb-knowledge-search note --agent nogit --porcelain
        echo RC=\$?
    " >"$STDOUT_FILE" 2>"$STDERR_FILE"
C1_OUT="$(_stdout)"
C1_ERR="$(_stderr)"
C1_RC=$(echo "$C1_OUT" | grep -oE 'RC=[0-9]+' | tail -1 | cut -d= -f2)
# Graceful degradation bar: search still finds the agent-tier entry (project-tier
# resolution failing doesn't block agent-tier search), exits 0, and neither
# stream contains a raw "command not found" leak or a shell stack trace.
if [ "$C1_RC" = "0" ] && echo "$C1_OUT" | grep -q '^agent:nogit' \
   && ! echo "$C1_OUT$C1_ERR" | grep -qi "command not found" \
   && ! echo "$C1_OUT$C1_ERR" | grep -qi "traceback"; then
    test_pass
else
    test_fail "expected rc=0, an agent:nogit hit, and no 'command not found'/traceback leak; rc=$C1_RC stdout=$C1_OUT stderr=$C1_ERR"
fi

test_start "PartC: _kb_knowledge_project_path falls back to projects/unknown when git is absent (no crash)"
C2_HOME=$(_next_home)
C2_ROOT="$C2_HOME/knowledge"
env -i \
    HOME="$C2_HOME" \
    PATH="$PATH" \
    TERM="${TERM:-dumb}" \
    KB_KNOWLEDGE_GLOBAL_ROOT="$C2_ROOT" \
    zsh -c "
        cd '$C2_HOME' 2>/dev/null
        source '$A_RENDERED' >/dev/null 2>/dev/null
        git() { return 127; }
        _kb_knowledge_project_path
        echo RC=\$?
    " >"$STDOUT_FILE" 2>"$STDERR_FILE"
C2_OUT="$(_stdout)"
C2_ERR="$(_stderr)"
if echo "$C2_OUT" | grep -q "${C2_ROOT}/projects/unknown" \
   && ! echo "$C2_OUT$C2_ERR" | grep -qi "command not found"; then
    test_pass
else
    test_fail "expected fallback path '${C2_ROOT}/projects/unknown' with no 'command not found' leak; stdout=$C2_OUT stderr=$C2_ERR"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only — test-runner.sh tallies pass/fail from output).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    if [ "$_FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
fi
exit 0
