#!/bin/bash
# test-xaca-0743-four-tier-knowledge.sh
#
# XACA-0743 (subitem 003): four-tier kb-knowledge-search() template migration +
# installer provisioning/migration. Covers two independently-shippable pieces:
#
#   PART A — share/templates/kanban/kanban-helpers.template.sh
#     The rendered kb-knowledge-search() function (~line 7528-8004) now searches
#     four tiers (agents/ subjects/ teams/ projects/<slug>) under
#     KB_KNOWLEDGE_GLOBAL_ROOT (default $HOME/knowledge), replacing the old
#     two-tier (--team team-map + <repo>/kanban/knowledge scan) implementation.
#     This is a zsh function (file shebang #!/bin/zsh) — exercised under zsh.
#
#   PART B — libexec/installers/install-kanban.sh
#     install_knowledge_tree() provisions the four-tier directory layout +
#     starter INDEX.md/templates (idempotent, dry-run-aware), and
#     migrate_legacy_repo_knowledge() copies (never moves) pre-XACA-0222
#     <repo>/kanban/knowledge/ content into projects/<repo-slug>/.
#     This is a bash script (set -euo pipefail) — exercised under bash.
#
# Both pieces are sandboxed: every invocation overrides HOME and/or
# KB_KNOWLEDGE_GLOBAL_ROOT to a mktemp directory. Part B additionally pins
# KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS to a sandbox-only path on every call —
# the installer's default search roots include the fixed, non-$HOME-relative
# path /Users/Shared/Development (by design, for consumers whose team repos
# live outside $HOME), so leaving it unset during a test would let
# migrate_legacy_repo_knowledge() scan and copy from this machine's REAL
# project directories. Never omit the override in this file.
#
# Designed to run standalone (`bash tests/test-xaca-0743-four-tier-knowledge.sh`)
# OR via test-runner.sh (which exports its own test_start/test_pass/test_fail/
# assert_* and a shared TEST_TMP_DIR). Exit 0 = all cases pass, exit 1 = any fail.
#
# Requires: bash, zsh, python3 (registry probe inside sourced helpers), jq
# (JSON-validity assertions; soft-skipped with a warning if absent).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi
if [ ! -f "$INSTALLER" ]; then
    echo "FATAL: install-kanban.sh not found at: $INSTALLER" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework: provide no-op-compatible stubs when test-runner.sh has
# not exported the real harness functions, so this file also runs directly.
# (Pattern mirrors test-xaca-0564-kanban-helpers-overwrite-guard.sh.)
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
    TEST_TMP_DIR="$(mktemp -d -t xaca0743-knowledge-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca0743"
mkdir -p "$WORK_DIR"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# PART A — template four-tier kb-knowledge-search() (zsh)
# ═══════════════════════════════════════════════════════════════════════════

# Render the template once: substitute install-time placeholders with dummy
# values (mirrors test-xaca-0649-kanban-dir-resolver.sh's approach). None of
# these are exercised by kb-knowledge-search itself, but the file must parse
# cleanly as a whole when sourced.
A_RENDERED="$WORK_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$WORK_DIR/aiteamforge|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$A_RENDERED"

A_STDOUT_FILE="$WORK_DIR/a-stdout.txt"
A_STDERR_FILE="$WORK_DIR/a-stderr.txt"

# Run kb-knowledge-search in a sandboxed zsh subshell.
# Usage: _kbsearch <home_dir> <global_root> [<cwd>] -- <args...>
_kbsearch() {
    local home_dir="$1" global_root="$2" cwd="$3"
    shift 3
    [ "$1" = "--" ] && shift
    local quoted_args
    quoted_args=$(printf '%q ' "$@")
    env -i \
        HOME="$home_dir" \
        PATH="$PATH" \
        TERM="${TERM:-dumb}" \
        KB_KNOWLEDGE_GLOBAL_ROOT="$global_root" \
        KB_SEARCH_TELEMETRY_DISABLED=1 \
        zsh -c "
            cd '$cwd' 2>/dev/null || cd '$home_dir'
            source '$A_RENDERED' >/dev/null 2>/dev/null
            kb-knowledge-search $quoted_args
        " >"$A_STDOUT_FILE" 2>"$A_STDERR_FILE"
}
_a_stdout() { cat "$A_STDOUT_FILE" 2>/dev/null; }

# Seed a fresh four-tier fixture tree. Each call gets its own HOME so test
# cases never see each other's fixtures. Uses mktemp (not a counter) for
# uniqueness — a counter incremented inside this function would live in a
# throwaway subshell when called as `X=$(_seed_fixture)` and never advance
# the caller's copy, silently collapsing every "fresh" fixture onto the same
# directory.
_seed_fixture() {
    local home_dir
    home_dir=$(mktemp -d "$WORK_DIR/home-XXXXXX")
    local root="$home_dir/knowledge"
    mkdir -p \
        "$root/agents/picard" \
        "$root/subjects/networking" \
        "$root/teams/academy" \
        "$root/projects/myproj"

    # Each fixture carries: a tier-crossing term ("warp-core", present in
    # agent/subject/team but deliberately NOT in project, so A1's tier-union
    # assertion and A8's project-tier assertion don't collide) plus a unique
    # per-tier marker term for the multi-term OR test (A7).
    cat > "$root/agents/picard/foo.md" <<'EOF'
# Foo Note
tags: [warp-core, propulsion]

The warp-core diagnostic procedure is documented here. zzzagentonlymarker
EOF

    cat > "$root/subjects/networking/bar.md" <<'EOF'
# Bar Note

The networking subsystem references warp-core terminology too. zzzsubjectonlymarker
EOF

    cat > "$root/teams/academy/baz.md" <<'EOF'
# Baz Note

Academy team note mentioning warp-core. zzzteamonlymarker
EOF

    cat > "$root/projects/myproj/qux.md" <<'EOF'
# Qux Note

Project note about warp-core. zzzprojectonlymarker
EOF

    echo "$home_dir"
}

# ── A1: bare-term search finds matches across the agent/subject/team tiers ──
test_start "PartA: bare-term search returns matches across agent/subject/team tiers"
A1_HOME=$(_seed_fixture)
_kbsearch "$A1_HOME" "$A1_HOME/knowledge" "$A1_HOME" -- warp-core --porcelain
A1_OUT="$(_a_stdout)"
A1_AGENT=$(echo "$A1_OUT" | grep -c "^agent	Foo Note")
A1_SUBJECT=$(echo "$A1_OUT" | grep -c "^subject	Bar Note")
A1_TEAM=$(echo "$A1_OUT" | grep -c "^team:academy	Baz Note")
if [ "$A1_AGENT" -eq 1 ] && [ "$A1_SUBJECT" -eq 1 ] && [ "$A1_TEAM" -eq 1 ]; then
    test_pass
else
    test_fail "expected 1 hit per tier (agent/subject/team); got agent=$A1_AGENT subject=$A1_SUBJECT team=$A1_TEAM; output:
$A1_OUT"
fi

# ── A2: --agent scopes to one persona's directory only ──────────────────────
test_start "PartA: --agent picard scopes results to the agent tier only"
A2_HOME=$(_seed_fixture)
_kbsearch "$A2_HOME" "$A2_HOME/knowledge" "$A2_HOME" -- warp-core --agent picard --porcelain
A2_OUT="$(_a_stdout)"
A2_LINES=$(echo "$A2_OUT" | grep -c '^agent:picard	')
A2_OTHER=$(echo "$A2_OUT" | grep -vc '^agent:picard	' || true)
if [ "$A2_LINES" -eq 1 ] && { [ -z "$A2_OUT" ] || [ "$(echo "$A2_OUT" | grep -v '^agent:picard	' | grep -c .)" -eq 0 ]; }; then
    test_pass
else
    test_fail "expected exactly one agent:picard line and nothing else; got:
$A2_OUT"
fi

# ── A3: --team is a backward-compat alias for --agent (identical output) ────
test_start "PartA: --team <name> behaves identically to --agent <name> (alias)"
A3_HOME=$(_seed_fixture)
_kbsearch "$A3_HOME" "$A3_HOME/knowledge" "$A3_HOME" -- warp-core --agent picard --porcelain
A3_AGENT_OUT="$(_a_stdout)"
_kbsearch "$A3_HOME" "$A3_HOME/knowledge" "$A3_HOME" -- warp-core --team picard --porcelain
A3_TEAM_OUT="$(_a_stdout)"
if [ "$A3_AGENT_OUT" = "$A3_TEAM_OUT" ] && [ -n "$A3_AGENT_OUT" ]; then
    test_pass
else
    test_fail "--team and --agent diverged.
--agent:
$A3_AGENT_OUT
--team:
$A3_TEAM_OUT"
fi

# ── A4: --tier subject scopes to the subject tier only ──────────────────────
test_start "PartA: --tier subject scopes results to the subject tier only"
A4_HOME=$(_seed_fixture)
_kbsearch "$A4_HOME" "$A4_HOME/knowledge" "$A4_HOME" -- warp-core --tier subject --porcelain
A4_OUT="$(_a_stdout)"
A4_NONSUBJECT=$(echo "$A4_OUT" | grep -v '^subject' | grep -c . || true)
A4_SUBJECT=$(echo "$A4_OUT" | grep -c '^subject	Bar Note')
if [ "$A4_SUBJECT" -eq 1 ] && [ "$A4_NONSUBJECT" -eq 0 ]; then
    test_pass
else
    test_fail "expected only subject-tier output; got:
$A4_OUT"
fi

# ── A5: --porcelain produces parseable 4-column TSV ──────────────────────────
test_start "PartA: --porcelain emits parseable TSV (tier<TAB>title<TAB>tags<TAB>path)"
A5_HOME=$(_seed_fixture)
_kbsearch "$A5_HOME" "$A5_HOME/knowledge" "$A5_HOME" -- warp-core --agent picard --porcelain
A5_OUT="$(_a_stdout)"
A5_COLS=$(echo "$A5_OUT" | head -1 | awk -F'\t' '{print NF}')
A5_PATH=$(echo "$A5_OUT" | head -1 | awk -F'\t' '{print $4}')
if [ "$A5_COLS" -eq 4 ] && [ "$A5_PATH" = "knowledge/agents/picard/foo.md" ]; then
    test_pass
else
    test_fail "expected 4 tab-separated columns with path col4=knowledge/agents/picard/foo.md; got cols=$A5_COLS path='$A5_PATH' line='$A5_OUT'"
fi

# ── A6: --json produces valid, parseable JSON with correct fields ───────────
test_start "PartA: --json emits a valid JSON array (jq-parseable) with expected fields"
A6_HOME=$(_seed_fixture)
_kbsearch "$A6_HOME" "$A6_HOME/knowledge" "$A6_HOME" -- warp-core --agent picard --json
A6_OUT="$(_a_stdout)"
if command -v jq >/dev/null 2>&1; then
    if echo "$A6_OUT" | jq -e 'type == "array" and length == 1 and .[0].tier == "agent:picard" and .[0].title == "Foo Note" and (.[0].path | endswith("agents/picard/foo.md"))' >/dev/null 2>&1; then
        test_pass
    else
        test_fail "JSON did not validate or fields mismatched; got: $A6_OUT"
    fi
else
    echo "     (jq not available — skipping strict validation, doing a basic shape check)"
    case "$A6_OUT" in
        '['*']') test_pass ;;
        *) test_fail "expected a JSON array; got: $A6_OUT" ;;
    esac
fi

# ── A6b: --json emits [] (not empty stdout) on zero results ─────────────────
test_start "PartA: --json emits [] (valid empty array) on zero results"
A6B_HOME=$(_seed_fixture)
_kbsearch "$A6B_HOME" "$A6B_HOME/knowledge" "$A6B_HOME" -- absolutely-no-such-term-xyz --agent picard --json
A6B_OUT="$(_a_stdout)"
if [ "$A6B_OUT" = "[]" ]; then
    test_pass
else
    test_fail "expected literal '[]' on zero results; got: '$A6B_OUT'"
fi

# ── A7: multi-term OR search returns the union of matches ───────────────────
test_start "PartA: multi-term OR search returns the union of per-term matches"
A7_HOME=$(_seed_fixture)
_kbsearch "$A7_HOME" "$A7_HOME/knowledge" "$A7_HOME" -- zzzagentonlymarker zzzsubjectonlymarker --porcelain
A7_OUT="$(_a_stdout)"
A7_AGENT=$(echo "$A7_OUT" | grep -c '^agent	Foo Note')
A7_SUBJECT=$(echo "$A7_OUT" | grep -c '^subject	Bar Note')
A7_TEAM=$(echo "$A7_OUT" | grep -c '^team:academy	Baz Note')
if [ "$A7_AGENT" -eq 1 ] && [ "$A7_SUBJECT" -eq 1 ] && [ "$A7_TEAM" -eq 0 ]; then
    test_pass
else
    test_fail "expected union of agent(zzzagentonlymarker)+subject(zzzsubjectonlymarker) only, no team hit; got agent=$A7_AGENT subject=$A7_SUBJECT team=$A7_TEAM; output:
$A7_OUT"
fi

# ── A8: --project <slug> scopes to the project tier ──────────────────────────
test_start "PartA: --project myproj scopes results to the project tier"
A8_HOME=$(_seed_fixture)
_kbsearch "$A8_HOME" "$A8_HOME/knowledge" "$A8_HOME" -- warp-core --project myproj --porcelain
A8_OUT="$(_a_stdout)"
A8_PROJECT=$(echo "$A8_OUT" | grep -c '^project:myproj	Qux Note')
A8_NONPROJECT=$(echo "$A8_OUT" | grep -v '^project:myproj' | grep -c . || true)
if [ "$A8_PROJECT" -eq 1 ] && [ "$A8_NONPROJECT" -eq 0 ]; then
    test_pass
else
    test_fail "expected only project:myproj line; got:
$A8_OUT"
fi

# ── A9: structural — old two-tier behavior is gone from the function body ───
# Extract just the kb-knowledge-search() function body (start marker to its
# closing brace at column 0) and assert: (a) no legacy <repo>/kanban/knowledge
# scan, (b) the four canonical tier roots are referenced.
test_start "PartA: kb-knowledge-search() body has no legacy <repo>/kanban/knowledge scan"
A9_BODY=$(awk '/^kb-knowledge-search\(\) \{/{flag=1} flag{print; if(/^}/) exit}' "$TEMPLATE_PATH")
A9_LEGACY_HITS=$(echo "$A9_BODY" | grep -c "kanban/knowledge" || true)
if [ -n "$A9_BODY" ] && [ "$A9_LEGACY_HITS" -eq 0 ]; then
    test_pass
else
    test_fail "expected zero 'kanban/knowledge' references inside kb-knowledge-search(); found $A9_LEGACY_HITS (body length $(echo "$A9_BODY" | wc -l) lines)"
fi

test_start "PartA: kb-knowledge-search() body references all four canonical tier roots"
A9B_ROOT_HITS=$(echo "$A9_BODY" | grep -cE '/(agents|subjects|teams|projects)(/|"|\$)')
if [ -n "$A9_BODY" ] && [ "$A9B_ROOT_HITS" -ge 4 ]; then
    test_pass
else
    test_fail "expected references to agents/subjects/teams/projects tier roots inside the function; found $A9B_ROOT_HITS"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PART B — installer provisioning + migration (bash, sandboxed)
# ═══════════════════════════════════════════════════════════════════════════

B_STDOUT_FILE="$WORK_DIR/b-stdout.txt"
B_STDERR_FILE="$WORK_DIR/b-stderr.txt"

# Run install_knowledge_tree() in a sandboxed bash subshell.
# Usage: _run_knowledge_tree <home_dir> <global_root> <search_roots> <dry_run> <migrate_flag>
#   search_roots: pass a path that does NOT contain any <repo>/kanban/knowledge
#     fixtures (or simply a nonexistent path) for tests that are not exercising
#     migration, so the default real-machine search roots are NEVER consulted.
# Echoes the subshell's exit code on stdout (caller captures via $(...)).
_run_knowledge_tree() {
    local home_dir="$1" global_root="$2" search_roots="$3" dry_run="${4:-false}" migrate_flag="${5:-1}"
    (
        set -euo pipefail
        export INSTALL_ROOT="$TAP_ROOT"
        export AITEAMFORGE_HOME="$TAP_ROOT"
        export AITEAMFORGE_DIR="$home_dir/aiteamforge"
        export HOME="$home_dir"
        export KB_KNOWLEDGE_GLOBAL_ROOT="$global_root"
        export KB_KNOWLEDGE_MIGRATE_SEARCH_ROOTS="$search_roots"
        export DRY_RUN="$dry_run"
        export KB_KNOWLEDGE_MIGRATE="$migrate_flag"
        export TEAM_WORKING_DIRS_STR=""
        export KANBAN_BACKUP_INTERVAL=900
        mkdir -p "$AITEAMFORGE_DIR"
        source "$INSTALLER" >"$B_STDOUT_FILE" 2>"$B_STDERR_FILE"
        install_knowledge_tree >>"$B_STDOUT_FILE" 2>>"$B_STDERR_FILE"
    )
    echo $?
}
_b_stdout() { cat "$B_STDOUT_FILE" 2>/dev/null; }

# mktemp (not a counter) for uniqueness — see _seed_fixture's comment above
# for why a counter mutated inside `X=$(fn)` command substitution doesn't work.
_next_b_home() {
    mktemp -d "$WORK_DIR/b-home-XXXXXX"
}

# A search-roots path that exists but is guaranteed empty of kanban/knowledge
# fixtures — used by every Part B test that is not specifically exercising
# migration, so install_knowledge_tree()'s internal migrate_legacy_repo_knowledge
# call never falls through to the installer's real-machine default roots.
B_EMPTY_SEARCH_ROOT="$WORK_DIR/no-legacy-repos-here"
mkdir -p "$B_EMPTY_SEARCH_ROOT"

# ── B1: fresh run creates the full four-tier layout + starter INDEX/templates ─
test_start "PartB: fresh install_knowledge_tree creates tier dirs + INDEX.md + templates"
B1_HOME=$(_next_b_home)
B1_ROOT="$B1_HOME/knowledge"
B1_RC=$(_run_knowledge_tree "$B1_HOME" "$B1_ROOT" "$B_EMPTY_SEARCH_ROOT" false 1)
B1_OK=true
for d in agents subjects teams projects templates; do
    [ -d "$B1_ROOT/$d" ] || { B1_OK=false; B1_REASON="missing dir: $d"; }
done
for f in agents/INDEX.md subjects/INDEX.md teams/INDEX.md projects/INDEX.md \
         templates/knowledge_entry_template.md templates/index_template.md templates/project_index_template.md; do
    [ -f "$B1_ROOT/$f" ] || { B1_OK=false; B1_REASON="missing file: $f"; }
done
if [ "$B1_RC" = "0" ] && [ "$B1_OK" = true ]; then
    test_pass
else
    test_fail "rc=$B1_RC ok=$B1_OK reason=${B1_REASON:-n/a}; stderr=$(cat "$B_STDERR_FILE" 2>/dev/null)"
fi

# ── B2: second run is idempotent ─────────────────────────────────────────────
test_start "PartB: second install_knowledge_tree run is idempotent (no errors, reports already-provisioned)"
B2_RC=$(_run_knowledge_tree "$B1_HOME" "$B1_ROOT" "$B_EMPTY_SEARCH_ROOT" false 1)
B2_OUT="$(_b_stdout)"
B2_INDEX_COUNT_AFTER=$(find "$B1_ROOT" -name "INDEX.md" | wc -l | tr -d ' ')
if [ "$B2_RC" = "0" ] && echo "$B2_OUT" | grep -qi "already provisioned" && [ "$B2_INDEX_COUNT_AFTER" -eq 4 ]; then
    test_pass
else
    test_fail "rc=$B2_RC index_count=$B2_INDEX_COUNT_AFTER; stdout_tail=$(echo "$B2_OUT" | tail -5)"
fi

# ── B3: DRY_RUN=true creates nothing ─────────────────────────────────────────
test_start "PartB: DRY_RUN=true creates no files or directories"
B3_HOME=$(_next_b_home)
B3_ROOT="$B3_HOME/knowledge"
B3_RC=$(_run_knowledge_tree "$B3_HOME" "$B3_ROOT" "$B_EMPTY_SEARCH_ROOT" true 1)
if [ "$B3_RC" = "0" ] && [ ! -e "$B3_ROOT" ]; then
    test_pass
else
    test_fail "rc=$B3_RC; expected $B3_ROOT to not exist; $([ -e "$B3_ROOT" ] && find "$B3_ROOT")"
fi

# ── B4: migration copies legacy <repo>/kanban/knowledge/ into projects/<slug>/ ─
test_start "PartB: migration copies legacy repo knowledge into projects/<slug>/ without deleting source"
B4_HOME=$(_next_b_home)
B4_ROOT="$B4_HOME/knowledge"
B4_REPOS="$B4_HOME/repos"
mkdir -p "$B4_REPOS/somerepo/kanban/knowledge"
echo "legacy note v1" > "$B4_REPOS/somerepo/kanban/knowledge/note.md"
B4_RC=$(_run_knowledge_tree "$B4_HOME" "$B4_ROOT" "$B4_REPOS" false 1)
B4_DEST="$B4_ROOT/projects/somerepo/note.md"
B4_SRC_INTACT=false
[ -f "$B4_REPOS/somerepo/kanban/knowledge/note.md" ] && B4_SRC_INTACT=true
B4_DEST_CONTENT=""
[ -f "$B4_DEST" ] && B4_DEST_CONTENT="$(cat "$B4_DEST")"
if [ "$B4_RC" = "0" ] && [ "$B4_SRC_INTACT" = true ] && [ "$B4_DEST_CONTENT" = "legacy note v1" ]; then
    test_pass
else
    test_fail "rc=$B4_RC src_intact=$B4_SRC_INTACT dest_content='$B4_DEST_CONTENT'"
fi

# ── B5: re-running migration does not duplicate / does not overwrite existing ─
test_start "PartB: re-running migration skips existing files (no overwrite) but picks up new ones"
echo "legacy note v2 MODIFIED" > "$B4_REPOS/somerepo/kanban/knowledge/note.md"
echo "brand new file" > "$B4_REPOS/somerepo/kanban/knowledge/note2.md"
B5_RC=$(_run_knowledge_tree "$B4_HOME" "$B4_ROOT" "$B4_REPOS" false 1)
B5_OUT="$(_b_stdout)"
B5_NOTE_CONTENT="$(cat "$B4_ROOT/projects/somerepo/note.md" 2>/dev/null)"
B5_NOTE2_PRESENT=false
[ -f "$B4_ROOT/projects/somerepo/note2.md" ] && B5_NOTE2_PRESENT=true
if [ "$B5_RC" = "0" ] && [ "$B5_NOTE_CONTENT" = "legacy note v1" ] && [ "$B5_NOTE2_PRESENT" = true ] \
   && echo "$B5_OUT" | grep -q "skipped 1 existing"; then
    test_pass
else
    test_fail "rc=$B5_RC note_content='$B5_NOTE_CONTENT' (want unchanged 'legacy note v1') note2_present=$B5_NOTE2_PRESENT; stdout_tail=$(echo "$B5_OUT" | tail -8)"
fi

# ── B6: KB_KNOWLEDGE_MIGRATE=0 skips migration entirely ─────────────────────
test_start "PartB: KB_KNOWLEDGE_MIGRATE=0 skips migration entirely"
B6_HOME=$(_next_b_home)
B6_ROOT="$B6_HOME/knowledge"
B6_REPOS="$B6_HOME/repos"
mkdir -p "$B6_REPOS/otherrepo/kanban/knowledge"
echo "should not migrate" > "$B6_REPOS/otherrepo/kanban/knowledge/note.md"
B6_RC=$(_run_knowledge_tree "$B6_HOME" "$B6_ROOT" "$B6_REPOS" false 0)
B6_OUT="$(_b_stdout)"
if [ "$B6_RC" = "0" ] && [ ! -e "$B6_ROOT/projects/otherrepo" ] && echo "$B6_OUT" | grep -qi "migration disabled"; then
    test_pass
else
    test_fail "rc=$B6_RC dest_exists=$([ -e "$B6_ROOT/projects/otherrepo" ] && echo yes || echo no); stdout_tail=$(echo "$B6_OUT" | tail -5)"
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
