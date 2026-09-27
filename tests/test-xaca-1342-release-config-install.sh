#!/bin/bash
# test-xaca-1342-release-config-install.sh
#
# XACA-1342-019: regression test for the release-config validator's tap
# INSTALL path. XACA-1342-005 mirrored kb-release-config-validate.sh,
# release_config_validate.py and its three release_config_schemas/*.schema.json
# siblings into share/scripts/ (sync-tap.sh), but nothing copied them into a
# consumer's $AITEAMFORGE_DIR/scripts/ on install, nothing refreshed them on
# upgrade, and the tap's hand-maintained kanban-helpers.template.sh never
# sourced kb-release-config-validate.sh — so on every tap-installed machine
# `kb-release-config-validate` (and its underlying CLI) never loaded, despite
# the files being physically present in the Cellar. Same defect class, and
# the same fix shape, as kb-cr.sh (XACA-0291/0846).
#
# This suite proves the fix end-to-end in a sandbox:
#   1. install_lcars_profile_script() (install-kanban.sh) lays down all 5
#      files at their expected $AITEAMFORGE_DIR/scripts/ paths (same function
#      that installs kb-cr.sh).
#   2. install_kanban_hooks() (install-kanban.sh) lays down aiteamforge_paths.py
#      at $AITEAMFORGE_DIR/kanban-hooks/ — the sibling release_config_validate.py
#      imports it from.
#   3. A fresh zsh that sources the rendered kanban-helpers.template.sh (with
#      AITEAMFORGE_DIR pointed at the sandbox) defines BOTH kb-cr and
#      kb-release-config-validate.
#   4. kb-release-config-validate actually RUNS against the installed layout:
#      once via team-based resolution (no --config-dir — exercises the
#      aiteamforge_paths import + get_team_kanban_dir path) and once via the
#      literal --config-dir invocation this ticket's spec calls out, and in
#      both cases the JSON schema sibling resolves (proven by a real
#      notify.json getting validated, not skipped).
#   5. Negative control: with NOTHING installed under $AITEAMFORGE_DIR/scripts/,
#      sourcing the rendered template does not error and leaves
#      kb-release-config-validate undefined (the file-existence guard degrades
#      gracefully, matching kb-cr.sh's own contract).
#
# All filesystem activity is sandboxed to TEST_TMP_DIR / a synthetic HOME.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.
#
# Run:  bash tests/test-xaca-1342-release-config-install.sh
# Also verified by hand under /bin/bash 3.2 (Apple's shipped bash) — this
# suite uses no bash-4-only syntax (no `declare -A`), so no self-re-exec is
# needed (contrast test-xaca-0931's SELF-TARGETING RE-EXEC, needed only for
# suites that assert 3.x-specific *behavior*; this one does not).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
TEMPLATE_PATH="$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh"

if [ ! -f "$INSTALLER" ]; then
    echo "FATAL: install-kanban.sh not found at: $INSTALLER" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

for _tool in zsh python3 jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH — cannot run this suite." >&2
        exit 1
    fi
done
if ! python3 -c "import jsonschema" >/dev/null 2>&1; then
    echo "FATAL: python3 'jsonschema' module not importable — required by release_config_validate.py." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0788's pattern).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# EXPLICIT pass/fail counters (feedback_tap_test_harness_vacuous_green): a
# suite that runs zero real assertions must not report success.
_P1342_PASS=0
_P1342_FAIL=0
ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _P1342_PASS=$((_P1342_PASS + 1)); test_pass
    else
        _P1342_FAIL=$((_P1342_FAIL + 1)); test_fail "$detail"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox. Real $HOME is stubbed too: install_lcars_profile_script() also
# writes an iTerm2 Dynamic Profile under $HOME/Library/Application
# Support/iTerm2/DynamicProfiles/ — that must land in the sandbox, never the
# real home.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1342-release-config-install.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

export HOME="$TEST_TMP_DIR/home"
mkdir -p "$HOME"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"
export INSTALL_ROOT="$TAP_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# Stub output helpers BEFORE extracting functions — same technique as
# test-xaca-0470-cr-enable.sh: avoids sourcing the whole installer (which has
# top-level side-effect code) while still giving the functions their deps.
# ─────────────────────────────────────────────────────────────────────────────
info()    { :; }
warning() { :; }
success() { :; }
header()  { :; }
error()   { :; }

_extract_fn() {
    # $1 = function name. Capture header line through the first line that is
    # exactly `}` at column 0 (matches every target function's shape here).
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$INSTALLER"
}

for _fn in install_lcars_profile_script install_kanban_hooks; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then
        echo "FATAL: could not extract '$_fn' from install-kanban.sh" >&2
        exit 1
    fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: '$_fn' not defined after extraction" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════════════════════════
# 1/2. Run the real install functions against the sandbox.
# ═══════════════════════════════════════════════════════════════════════════
install_lcars_profile_script >"$TEST_TMP_DIR/install-lcars.log" 2>&1
_LCARS_RC=$?
install_kanban_hooks >"$TEST_TMP_DIR/install-hooks.log" 2>&1
_HOOKS_RC=$?

ok "install_lcars_profile_script exits 0" \
   "$([ "$_LCARS_RC" -eq 0 ] && echo 1 || echo 0)" \
   "rc=$_LCARS_RC log=$(cat "$TEST_TMP_DIR/install-lcars.log")"
ok "install_kanban_hooks exits 0" \
   "$([ "$_HOOKS_RC" -eq 0 ] && echo 1 || echo 0)" \
   "rc=$_HOOKS_RC log=$(cat "$TEST_TMP_DIR/install-hooks.log")"

SCRIPTS_DEST="$AITEAMFORGE_DIR/scripts"

ok "kb-cr.sh installed at scripts/" \
   "$([ -f "$SCRIPTS_DEST/kb-cr.sh" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/kb-cr.sh"
ok "kb-release-config-validate.sh installed at scripts/" \
   "$([ -f "$SCRIPTS_DEST/kb-release-config-validate.sh" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/kb-release-config-validate.sh"
ok "release_config_validate.py installed at scripts/" \
   "$([ -f "$SCRIPTS_DEST/release_config_validate.py" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/release_config_validate.py"
ok "release_config_schemas/notify.schema.json installed" \
   "$([ -f "$SCRIPTS_DEST/release_config_schemas/notify.schema.json" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/release_config_schemas/notify.schema.json"
ok "release_config_schemas/wiki.schema.json installed" \
   "$([ -f "$SCRIPTS_DEST/release_config_schemas/wiki.schema.json" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/release_config_schemas/wiki.schema.json"
ok "release_config_schemas/profile.schema.json installed" \
   "$([ -f "$SCRIPTS_DEST/release_config_schemas/profile.schema.json" ] && echo 1 || echo 0)" \
   "missing: $SCRIPTS_DEST/release_config_schemas/profile.schema.json"
ok "kb-release-config-validate.sh is executable" \
   "$([ -x "$SCRIPTS_DEST/kb-release-config-validate.sh" ] && echo 1 || echo 0)" \
   "not executable: $SCRIPTS_DEST/kb-release-config-validate.sh"
ok "aiteamforge_paths.py installed at kanban-hooks/ (release_config_validate.py's ../kanban-hooks/ import target)" \
   "$([ -f "$AITEAMFORGE_DIR/kanban-hooks/aiteamforge_paths.py" ] && echo 1 || echo 0)" \
   "missing: $AITEAMFORGE_DIR/kanban-hooks/aiteamforge_paths.py"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Render the template with AITEAMFORGE_DIR pointed at the sandbox and
#    source it under zsh — same technique as test-xaca-0788.
# ═══════════════════════════════════════════════════════════════════════════
RENDERED="$TEST_TMP_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR|g; \
     s|{{SHARED_DEV_ROOT}}|$TEST_TMP_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED"

_LEFT=$(grep -c '{{' "$RENDERED" 2>/dev/null)
[ -n "$_LEFT" ] || _LEFT=0
ok "rendered template has no residual {{placeholder}}" \
   "$([ "$_LEFT" -eq 0 ] && echo 1 || echo 0)" \
   "found $_LEFT residual placeholder(s)"

for fn in kb-cr kb-release-config-validate; do
    _defn=$(zsh -c "source '$RENDERED' >/dev/null 2>&1; typeset -f '$fn' >/dev/null 2>&1 && echo DEFINED || echo MISSING")
    ok "'$fn' is DEFINED after sourcing the rendered template (AITEAMFORGE_DIR=sandbox, files installed)" \
       "$([ "$_defn" = "DEFINED" ] && echo 1 || echo 0)" \
       "got: $_defn"
done

# ═══════════════════════════════════════════════════════════════════════════
# 4. Actually RUN kb-release-config-validate against the installed layout.
#    Seed a minimal synthetic team-paths.json (AITEAMFORGE_CONFIG override) so
#    get_team_kanban_dir("academy") resolves into the sandbox. NOTE: "academy"
#    alone is the documented partial-write corruption signature that
#    load_config()'s XACA-0647 guard re-seeds to the full DEFAULT_TEAMS roster
#    (test_corrupt_academy_alone_is_reseeded in kanban-hooks/test_aiteamforge_paths.py)
#    — pairing it with a second team (finance-personal) is the same shape the
#    guard's own test suite asserts is accepted AS WRITTEN, so our sandboxed
#    kanban_dir for academy survives load_config() unmodified.
# ═══════════════════════════════════════════════════════════════════════════
SANDBOX_KANBAN_DIR="$TEST_TMP_DIR/team-data/academy/kanban"
mkdir -p "$SANDBOX_KANBAN_DIR/config"
cat > "$SANDBOX_KANBAN_DIR/config/notify.json" <<'EOF'
{}
EOF

export AITEAMFORGE_CONFIG="$TEST_TMP_DIR/team-paths.json"
cat > "$AITEAMFORGE_CONFIG" <<EOF
{
  "schema_version": 3,
  "teams": {
    "academy": {
      "kanban_dir": "$SANDBOX_KANBAN_DIR",
      "working_dir": "$TEST_TMP_DIR/team-data/academy",
      "lcars_port": 9000
    },
    "finance-personal": {
      "kanban_dir": "$TEST_TMP_DIR/team-data/finance-personal/kanban",
      "working_dir": "$TEST_TMP_DIR/team-data/finance-personal",
      "lcars_port": 9001
    }
  }
}
EOF

# 4a. Team-based resolution (no --config-dir): exercises the aiteamforge_paths
# import (../kanban-hooks/ sibling) AND get_team_kanban_dir() AND schema
# resolution (notify.json is present, so validate_notify_config() actually
# runs _load_schema("notify.schema.json") — not skipped).
_OUT_A="$TEST_TMP_DIR/cli-run-a.out"
zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-release-config-validate academy --all" \
    >"$_OUT_A" 2>&1
_RC_A=$?
ok "kb-release-config-validate academy --all (team-based resolution) does not report an import/path failure" \
   "$(grep -qi 'cannot find kanban-hooks\|ModuleNotFoundError\|Traceback\|command not found' "$_OUT_A" && echo 0 || echo 1)" \
   "rc=$_RC_A output: $(cat "$_OUT_A")"
ok "kb-release-config-validate academy --all validated notify.json against the installed schema (not skipped)" \
   "$(grep -q 'notify.json' "$_OUT_A" && echo 1 || echo 0)" \
   "output: $(cat "$_OUT_A")"

# 4b. Literal --config-dir invocation per the ticket's own spec wording.
_OUT_B="$TEST_TMP_DIR/cli-run-b.out"
zsh -c "source '$RENDERED' >/dev/null 2>&1; kb-release-config-validate academy --all --config-dir '$SANDBOX_KANBAN_DIR/config'" \
    >"$_OUT_B" 2>&1
_RC_B=$?
ok "kb-release-config-validate academy --all --config-dir <sandbox>/kanban/config runs cleanly" \
   "$(grep -qi 'cannot find kanban-hooks\|ModuleNotFoundError\|Traceback\|command not found' "$_OUT_B" && echo 0 || echo 1)" \
   "rc=$_RC_B output: $(cat "$_OUT_B")"
ok "kb-release-config-validate --config-dir run also validated notify.json against the installed schema" \
   "$(grep -q 'notify.json' "$_OUT_B" && echo 1 || echo 0)" \
   "output: $(cat "$_OUT_B")"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Negative control: nothing installed under a DIFFERENT sandbox ->
#    sourcing the rendered template must not error, and the function must be
#    undefined (file-existence guard degrades gracefully, same contract as
#    kb-cr.sh).
# ═══════════════════════════════════════════════════════════════════════════
EMPTY_AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge-empty"
mkdir -p "$EMPTY_AITEAMFORGE_DIR"
RENDERED_EMPTY="$TEST_TMP_DIR/kanban-helpers-rendered-empty.sh"
sed "s|{{AITEAMFORGE_DIR}}|$EMPTY_AITEAMFORGE_DIR|g; \
     s|{{SHARED_DEV_ROOT}}|$TEST_TMP_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED_EMPTY"

# NOTE: the guard blocks in the template reference the LIVE shell variable
# ${AITEAMFORGE_DIR} at runtime (not a {{...}} placeholder baked in by sed —
# same as the real installed kanban-helpers.sh, which reads it from the
# environment). The outer test process still has AITEAMFORGE_DIR exported to
# the FILLED sandbox from section 1/2/3 above, so this invocation must
# override it explicitly to the empty sandbox or the guard would resolve
# against the wrong directory and this negative control would be vacuous.
_EMPTY_SOURCE_RC_AND_DEFN=$(AITEAMFORGE_DIR="$EMPTY_AITEAMFORGE_DIR" zsh -c "source '$RENDERED_EMPTY' >/dev/null 2>&1; echo \"rc=\$?\"; typeset -f kb-release-config-validate >/dev/null 2>&1 && echo DEFINED || echo MISSING")
ok "sourcing the rendered template with NOTHING installed does not error, and leaves kb-release-config-validate undefined" \
   "$(echo "$_EMPTY_SOURCE_RC_AND_DEFN" | grep -q '^rc=0$' && echo "$_EMPTY_SOURCE_RC_AND_DEFN" | grep -q '^MISSING$' && echo 1 || echo 0)" \
   "got: $_EMPTY_SOURCE_RC_AND_DEFN"

# ─────────────────────────────────────────────────────────────────────────────
# Summary — explicit real assertion count (defeats vacuous-green).
# ─────────────────────────────────────────────────────────────────────────────
_TOTAL=$((_P1342_PASS + _P1342_FAIL))
echo ""
echo "──────────────────────────────────────────────────────────────"
echo "XACA-1342-019 release-config-install: Passed: ${_P1342_PASS} / Total: ${_TOTAL}  (Failed: ${_P1342_FAIL})"
echo "──────────────────────────────────────────────────────────────"

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_P1342_PASS} passed, ${_P1342_FAIL} failed"
fi

if [ "$_P1342_FAIL" -gt 0 ] || [ "$_TOTAL" -eq 0 ]; then
    exit 1
fi
exit 0
