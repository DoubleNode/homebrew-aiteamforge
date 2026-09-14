#!/bin/bash
# test-xaca-1216-flat-persona-deploy.sh
#
# SHELL: deliberately NOT a self-re-exec suite (tests/ci-manifest says the
# XACA-0931 re-exec is a workaround not to be copied). Instead the suite runs
# the shipped installer/upgrade code under WHATEVER bash runs the suite ($BASH),
# so `/bin/bash tests/<this>` exercises Apple bash 3.2 and CI's PATH bash
# exercises 5.x. The template snippet always runs under `zsh -f`.
#
# XACA-1216 (subitems 004 + 005): Space Dock's working dir
# (~/.aiteamforge/spacedock) is NOT a git work tree, so none of the git-aware
# persona deploy modes ever reached it and crew sessions launched there found
# no .claude/agents. The fix wires deploy-worktree-personas.sh --flat-dir into
# three sites, gated by ONE conf flag (TEAM_PERSONA_DEPLOY_MODE="flat-dir"):
#
#   (a) install-team.sh renders the flag into <team>-startup.sh (no leftover
#       {{placeholders}}, for flagged AND unflagged teams)
#   (b) team-startup.sh.template: deploy snippet + health check "Personas",
#       executed under `zsh -f` — OK needs POSITIVE evidence (rc 0 AND every
#       source *.md present in the target), never an rc-0-says-so pass
#   (c) install-team.sh spacedock, end to end in a sandbox
#   (d) aiteamforge-upgrade.sh deploy_flat_team_personas on a pre-provisioned
#       sandbox; a git-repo working dir is refused and counted, fail-soft
#   (e) negative control: the (b)/(c)/(d) assertions FAIL against pre-change
#       copies of the files (`git show <pre-change-ref>:<path>`)
#
# SANDBOX: HOME, AITEAMFORGE_DIR and every working dir live under TEST_TMP_DIR,
# exported BEFORE anything is sourced. TMUX/TMUX_PANE are unset. `brew` is a
# PATH stub (never installs anything). No LaunchAgent is created. The real tap
# tree is only READ (copied into sandbox taps).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Sandbox first — before any source/eval ─────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1216-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
# Canonical path: macOS /var -> /private/var would otherwise make path
# comparisons (installer guards, the deployer's _canon_path) disagree.
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
WORK_DIR="$TEST_TMP_DIR/xaca1216"
mkdir -p "$WORK_DIR"
export HOME="$WORK_DIR/home"
export AITEAMFORGE_DIR="$WORK_DIR/aiteamforge"
mkdir -p "$HOME" "$AITEAMFORGE_DIR"
unset TMUX TMUX_PANE AITEAMFORGE_CONFIG AITEAMFORGE_HOME KB_TEAM KB_TERMINAL \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE TEAM_WORKING_DIR TEAM_PERSONA_DEPLOY_MODE
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ── Framework (standalone or sourced by test-runner.sh) ─────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi
_SKIP_COUNT=0
test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP (not a pass): $_CURRENT_TEST -- $1"; }

# ── Inputs ──────────────────────────────────────────────────────────────────
INSTALL_TEAM_REL="libexec/installers/install-team.sh"
UPGRADE_REL="libexec/commands/aiteamforge-upgrade.sh"
TEMPLATE_REL="share/templates/team-startup.sh.template"
SPACEDOCK_CONF_REL="share/teams/spacedock.conf"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"

# The deployer: prefer the dev-team CANONICAL (this tap is a submodule of it
# in a dev worktree), else the tap mirror (standalone tap clone / CI).
_OUTER_DEPLOYER="$(cd "$TAP_ROOT/.." 2>/dev/null && pwd)/scripts/deploy-worktree-personas.sh"
if [ -f "$_OUTER_DEPLOYER" ]; then
    DEPLOYER_SRC="$_OUTER_DEPLOYER"
else
    DEPLOYER_SRC="$TAP_ROOT/share/scripts/deploy-worktree-personas.sh"
fi
FLAT_DIR_SUPPORTED=false
grep -q -- '--flat-dir' "$DEPLOYER_SRC" 2>/dev/null && FLAT_DIR_SUPPORTED=true

# Pre-change ref for the negative control. 803d92c is tap main immediately
# before XACA-1216's tap commit. HEAD/origin/main are NOT usable here: once this
# change merges they ARE the post-change files and the control goes vacuous.
PRECHANGE_REF="${XACA1216_PRECHANGE_REF:-803d92c}"

for _need in "$TAP_ROOT/$INSTALL_TEAM_REL" "$TAP_ROOT/$UPGRADE_REL" "$TAP_ROOT/$TEMPLATE_REL" \
             "$TAP_ROOT/$SPACEDOCK_CONF_REL" "$PATHS_LIB" "$DEPLOYER_SRC"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done
if ! command -v zsh >/dev/null 2>&1; then
    echo "FATAL: zsh not found — case (b) must run the template snippet under zsh -f" >&2
    exit 1
fi

echo "Deployer under test: $DEPLOYER_SRC (--flat-dir supported: $FLAT_DIR_SUPPORTED)"

# ── Shared helpers ──────────────────────────────────────────────────────────
PERSONA_FIXTURE_DIR="$TAP_ROOT/share/personas/spacedock/agents"
_persona_basenames() { find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sed 's|.*/||' | sort; }
EXPECTED_PERSONAS="$(_persona_basenames "$PERSONA_FIXTURE_DIR")"
EXPECTED_PERSONA_COUNT="$(printf '%s\n' "$EXPECTED_PERSONAS" | grep -c .)"

# Stub `brew` so install-team.sh's dependency step can never install anything.
STUB_BIN="$WORK_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/brew" <<'EOF'
#!/bin/bash
# XACA-1216 test stub: `brew list X` reports installed; anything else refuses.
[ "$1" = "list" ] && exit 0
echo "brew stub: refusing '$*' inside the XACA-1216 sandbox" >&2
exit 1
EOF
chmod +x "$STUB_BIN/brew"

# _extract_between <file> <begin-regex> <end-regex> — inclusive, first match.
_extract_between() {
    awk -v b="$2" -v e="$3" '
      !cap && $0 ~ b { cap=1 }
      cap { print }
      cap && $0 ~ e { exit }
    ' "$1"
}

# _extract_fn <name> <file> — a top-level `name() {` ... `}` function.
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}

# _mk_sandbox_tap <dest> <post|pre>
# A copy of the tap pieces install-team.sh reads, with the deployer under test
# at share/scripts/. `pre` overwrites the four XACA-1216 files with their
# PRECHANGE_REF content. Only spacedock + no other personas are copied (size).
_mk_sandbox_tap() {
    local dest="$1" mode="$2" d rel
    mkdir -p "$dest/share/personas"
    cp -R "$TAP_ROOT/libexec" "$dest/libexec" || return 1
    for d in config scripts teams templates kanban-hooks; do
        [ -d "$TAP_ROOT/share/$d" ] && { cp -R "$TAP_ROOT/share/$d" "$dest/share/$d" || return 1; }
    done
    cp -R "$TAP_ROOT/share/personas/spacedock" "$dest/share/personas/spacedock" || return 1
    [ -f "$TAP_ROOT/VERSION" ] && cp "$TAP_ROOT/VERSION" "$dest/VERSION"
    cp "$DEPLOYER_SRC" "$dest/share/scripts/deploy-worktree-personas.sh" || return 1
    chmod +x "$dest/share/scripts/deploy-worktree-personas.sh"
    if [ "$mode" = "pre" ]; then
        for rel in "$INSTALL_TEAM_REL" "$UPGRADE_REL" "$TEMPLATE_REL" "$SPACEDOCK_CONF_REL"; do
            git -C "$TAP_ROOT" show "${PRECHANGE_REF}:${rel}" > "$dest/$rel" || return 1
        done
        chmod +x "$dest/$INSTALL_TEAM_REL" "$dest/$UPGRADE_REL"
    fi
}

# _run_install <tap> <team> <home> <aitf> <stdout> <stderr> — prints rc.
_run_install() {
    local tap="$1" team="$2" h="$3" aitf="$4" out="$5" err="$6" rc=0
    mkdir -p "$h/.aiteamforge" "$aitf"
    cp "$TAP_ROOT/share/config/organization.yaml.example" "$h/.aiteamforge/organization.yaml"
    ( unset TEAM_WORKING_DIR TEAM_PERSONA_DEPLOY_MODE AITEAMFORGE_CONFIG AITEAMFORGE_HOME TMUX TMUX_PANE
      export HOME="$h" AITEAMFORGE_DIR="$aitf" PATH="$STUB_BIN:$PATH"
      "$BASH" "$tap/$INSTALL_TEAM_REL" "$team" --install-dir "$aitf" </dev/null >"$out" 2>"$err"
    ) || rc=$?
    printf '%s' "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Interpreter under test: $BASH ($BASH_VERSION)"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (a) render: flag reaches the rendered startup, no leftover placeholders ==="

POST_TAP="$WORK_DIR/tap-post"
if ! _mk_sandbox_tap "$POST_TAP" post; then
    echo "FATAL: could not build post-change sandbox tap" >&2
    exit 1
fi

A_HOME="$(_next_sandbox)/home"; A_AITF="$(dirname "$A_HOME")/aiteamforge"
A_OUT="$WORK_DIR/a-install.out"; A_ERR="$WORK_DIR/a-install.err"
A_RC="$(_run_install "$POST_TAP" spacedock "$A_HOME" "$A_AITF" "$A_OUT" "$A_ERR")"
A_STARTUP="$A_AITF/spacedock-startup.sh"

test_start "A1: install-team.sh spacedock exits 0 and renders spacedock-startup.sh"
if [ "$A_RC" = "0" ] && [ -f "$A_STARTUP" ]; then
    test_pass
else
    test_fail "rc=$A_RC startup_exists=$([ -f "$A_STARTUP" ] && echo yes || echo no); stderr tail: $(tail -5 "$A_ERR" 2>/dev/null)"
fi

test_start "A2: rendered spacedock startup carries TEAM_PERSONA_DEPLOY_MODE=\"flat-dir\""
if grep -qx 'TEAM_PERSONA_DEPLOY_MODE="flat-dir"' "$A_STARTUP" 2>/dev/null; then
    test_pass
else
    test_fail "line not found in $A_STARTUP: $(grep -n 'TEAM_PERSONA_DEPLOY_MODE' "$A_STARTUP" 2>/dev/null | head -3)"
fi

test_start "A3: rendered spacedock startup has no leftover {{PLACEHOLDER}}"
_left="$(grep -n '{{[A-Z_]*}}' "$A_STARTUP" 2>/dev/null)"
if [ -f "$A_STARTUP" ] && [ -z "$_left" ]; then test_pass; else test_fail "leftovers: $_left"; fi

test_start "A4: rendered spacedock startup parses under zsh -n"
if [ -f "$A_STARTUP" ] && zsh -n "$A_STARTUP" 2>"$WORK_DIR/a4.err"; then test_pass; else test_fail "$(cat "$WORK_DIR/a4.err" 2>/dev/null)"; fi

# Unflagged team through the same render: the sed must still substitute the
# placeholder (to ""), or every other team's startup ships a literal {{...}}.
A5_HOME="$(_next_sandbox)/home"; A5_AITF="$(dirname "$A5_HOME")/aiteamforge"
cp "$TAP_ROOT/share/teams/ios.conf" "$POST_TAP/share/teams/ios.conf" 2>/dev/null
A5_RC="$(_run_install "$POST_TAP" ios "$A5_HOME" "$A5_AITF" "$WORK_DIR/a5.out" "$WORK_DIR/a5.err")"
A5_STARTUP="$A5_AITF/ios-startup.sh"
test_start "A5: unflagged team (ios) renders TEAM_PERSONA_DEPLOY_MODE=\"\" with no leftover {{PLACEHOLDER}}"
_left5="$(grep -n '{{[A-Z_]*}}' "$A5_STARTUP" 2>/dev/null)"
if [ "$A5_RC" = "0" ] && grep -qx 'TEAM_PERSONA_DEPLOY_MODE=""' "$A5_STARTUP" 2>/dev/null && [ -z "$_left5" ]; then
    test_pass
else
    test_fail "rc=$A5_RC mode_line=$(grep -n 'TEAM_PERSONA_DEPLOY_MODE=' "$A5_STARTUP" 2>/dev/null | head -1) leftovers=[$_left5] stderr tail: $(tail -3 "$WORK_DIR/a5.err" 2>/dev/null)"
fi

test_start "A6: every template install-team.sh renders through the startup sed has no placeholder the sed leaves behind"
# The startup sed renders $TEAM_STARTUP_SCRIPT.template, team-startup.sh.template
# or team-project-startup.sh.template. {{TEAM_AGENT_WINDOWS_CONFIG}} is the one
# placeholder handled by the python step, not the sed.
# Fixed-string anchors (awk index(), not a regex): the startup render's own
# resolver line opens the block and its `"$STARTUP_TEMPLATE" > ` redirect
# closes it. A regex anchor on `sed -e "s|{{TEAM_ID}}...` is a trap — that
# line also opens the connect and shutdown renders, and a sweep across all
# of them yields a SUPERSET of keys that passes this check vacuously.
_sed_block="$(awk '
  !cap && index($0, "_TEAM_WORKING_DIR_RESOLVED=\"$(if") { cap=1 }
  cap { print }
  cap && index($0, "\"$STARTUP_TEMPLATE\" > ") { exit }
' "$TAP_ROOT/$INSTALL_TEAM_REL")"
_sed_block_lines="$(printf '%s\n' "$_sed_block" | grep -c .)"
_sed_keys="$(printf '%s\n' "$_sed_block" | grep -o '{{[A-Z_]*}}' | sort -u)"
_a6_bad=""
for _tpl in "$TAP_ROOT"/share/templates/*-startup.sh.template; do
    for _ph in $(grep -o '{{[A-Z_]*}}' "$_tpl" | sort -u); do
        [ "$_ph" = "{{TEAM_AGENT_WINDOWS_CONFIG}}" ] && continue
        printf '%s\n' "$_sed_keys" | grep -qxF "$_ph" || _a6_bad="$_a6_bad $(basename "$_tpl"):$_ph"
    done
done
# The block is ~14 lines; a much larger capture means the anchors drifted.
if [ -n "$_sed_keys" ] && [ "$_sed_block_lines" -ge 5 ] && [ "$_sed_block_lines" -le 25 ] \
    && printf '%s\n' "$_sed_block" | grep -qF '"$STARTUP_TEMPLATE" > ' \
    && printf '%s\n' "$_sed_keys" | grep -qxF '{{TEAM_PERSONA_DEPLOY_MODE}}' && [ -z "$_a6_bad" ]; then
    test_pass
else
    test_fail "block_lines=$_sed_block_lines sed keys=[$(echo $_sed_keys)] unsubstituted=[$_a6_bad]"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (b) template snippet + health row under zsh -f ==="

# _b_harness <template> <out-harness> — assemble a runnable zsh script from the
# template's own marked blocks. Returns 1 when either block is missing.
_b_harness() {
    local tpl="$1" out="$2" deploy health
    deploy="$(_extract_between "$tpl" '^# >>> XACA-1216 persona-deploy' '^# <<< XACA-1216 persona-deploy')"
    health="$(_extract_between "$tpl" '^# >>> XACA-1216 persona-health' '^# <<< XACA-1216 persona-health')"
    [ -n "$deploy" ] && [ -n "$health" ] || return 1
    {
        echo 'TEAM_ID="spacedock"'
        echo 'AITEAMFORGE_DIR="$B_AITF"'
        echo 'TEAM_WORKING_DIR="$B_WD"'
        echo 'TEAM_PERSONA_DEPLOY_MODE="$B_MODE"'
        echo '_HEALTH_ERRORS=0'
        printf '%s\n' "$deploy"
        echo 'echo "--- health ---"'
        printf '%s\n' "$health"
        echo 'echo "HEALTH_ERRORS=$_HEALTH_ERRORS"'
        echo 'echo "SNIPPET_COMPLETED"'
    } > "$out"
}

# _b_fixture <kind> — prints "<aitf>\t<wd>"; kind: good-stub|noexec|noop-stub|refuse4-stub|real
_b_fixture() {
    local kind="$1" root aitf wd dwp
    root="$(_next_sandbox)"; aitf="$root/aiteamforge"; wd="$root/home/.aiteamforge/spacedock"
    mkdir -p "$aitf/scripts" "$aitf/spacedock/personas/agents" "$wd"
    cp "$PERSONA_FIXTURE_DIR"/*.md "$aitf/spacedock/personas/agents/"
    dwp="$aitf/scripts/deploy-worktree-personas.sh"
    case "$kind" in
        good-stub|noexec)
            cat > "$dwp" <<'EOF'
#!/bin/bash
# stub: --flat-dir <wd> <team> ... copies S2 personas, exit 0
wd="$2"; team="$3"
mkdir -p "$wd/.claude/agents" && cp "$AITEAMFORGE_DIR/$team/personas/agents/"*.md "$wd/.claude/agents/"
EOF
            ;;
        noop-stub)
            printf '#!/bin/bash\necho "stub: pretending to deploy"\nexit 0\n' > "$dwp" ;;
        refuse4-stub)
            printf '#!/bin/bash\necho "REFUSED: inside a git work tree" >&2\nexit 4\n' > "$dwp" ;;
        real)
            cp "$DEPLOYER_SRC" "$dwp" ;;
    esac
    chmod +x "$dwp"
    [ "$kind" = "noexec" ] && chmod -x "$dwp"
    printf '%s\t%s' "$aitf" "$wd"
}

# _b_run <harness> <kind> <mode> <out> — prints rc; exports fixture paths into the zsh env.
_b_run() {
    local harness="$1" kind="$2" mode="$3" out="$4" fx aitf wd rc=0
    fx="$(_b_fixture "$kind")"; aitf="${fx%%	*}"; wd="${fx#*	}"
    ( export HOME="$(dirname "$(dirname "$wd")")" B_AITF="$aitf" B_WD="$wd" B_MODE="$mode"
      zsh -f "$harness" >"$out" 2>&1 ) || rc=$?
    printf '%s\t%s' "$rc" "$wd"
}

# _b_assert_cases <template> <label-prefix> <expect: post|pre>
_b_assert_cases() {
    local tpl="$1" pfx="$2" expect="$3" harness="$WORK_DIR/${pfx}-harness.zsh" r rc wd out
    test_start "${pfx}0: template carries both marked XACA-1216 blocks (persona-deploy, persona-health)"
    if _b_harness "$tpl" "$harness"; then
        [ "$expect" = post ] && test_pass || test_fail "NEGATIVE CONTROL: pre-change template unexpectedly has the blocks"
    else
        if [ "$expect" = pre ]; then test_pass; return 0; fi
        test_fail "marked blocks not found in $tpl"; return 0
    fi

    out="$WORK_DIR/${pfx}1.out"; r="$(_b_run "$harness" good-stub flat-dir "$out")"; rc="${r%%	*}"; wd="${r#*	}"
    test_start "${pfx}1: happy path (deployer writes every source persona, exit 0) -> Personas OK, no health error"
    if [ "$rc" = "0" ] && grep -q 'Personas *OK' "$out" && grep -q '^HEALTH_ERRORS=0$' "$out" && grep -q SNIPPET_COMPLETED "$out" \
        && [ "$(_persona_basenames "$wd/.claude/agents")" = "$EXPECTED_PERSONAS" ]; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    out="$WORK_DIR/${pfx}2.out"; r="$(_b_run "$harness" noexec flat-dir "$out")"; rc="${r%%	*}"
    test_start "${pfx}2: deployer not executable -> Personas FAIL naming exit 127 + meaning + log path, _HEALTH_ERRORS++, startup not aborted"
    if [ "$rc" = "0" ] && grep -q 'Personas *FAIL.*exit 127.*not executable.*persona-deploy-.*\.log' "$out" \
        && grep -q '^HEALTH_ERRORS=1$' "$out" && grep -q SNIPPET_COMPLETED "$out"; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    out="$WORK_DIR/${pfx}3.out"; r="$(_b_run "$harness" noop-stub flat-dir "$out")"; rc="${r%%	*}"
    test_start "${pfx}3: deployer exits 0 but writes nothing -> Personas FAIL (positive evidence, not rc), _HEALTH_ERRORS++"
    if [ "$rc" = "0" ] && grep -q 'Personas *FAIL' "$out" && ! grep -q 'Personas *OK' "$out" \
        && grep -q '^HEALTH_ERRORS=1$' "$out" && grep -q SNIPPET_COMPLETED "$out"; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    out="$WORK_DIR/${pfx}4.out"; r="$(_b_run "$harness" refuse4-stub flat-dir "$out")"; rc="${r%%	*}"
    test_start "${pfx}4: deployer exit 4 -> Personas FAIL naming exit 4 as git-work-tree refusal + log path"
    if [ "$rc" = "0" ] && grep -q 'Personas *FAIL.*exit 4.*git work tree.*persona-deploy-.*\.log' "$out" \
        && grep -q '^HEALTH_ERRORS=1$' "$out"; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    out="$WORK_DIR/${pfx}5.out"; r="$(_b_run "$harness" good-stub "" "$out")"; rc="${r%%	*}"; wd="${r#*	}"
    test_start "${pfx}5: ungated team (mode \"\") -> deployer never runs, no Personas row, no health error"
    if [ "$rc" = "0" ] && ! grep -q 'Personas' "$out" && grep -q '^HEALTH_ERRORS=0$' "$out" && [ ! -e "$wd/.claude" ]; then
        test_pass
    else
        test_fail "rc=$rc claude_exists=$([ -e "$wd/.claude" ] && echo yes || echo no) out: $(tr '\n' '|' < "$out")"
    fi

    test_start "${pfx}6: happy path with the REAL deployer (--flat-dir) -> Personas OK"
    if [ "$FLAT_DIR_SUPPORTED" != true ]; then
        test_fail "PENDING: $DEPLOYER_SRC has no --flat-dir yet (XACA-1216-003) — not faked"
        return 0
    fi
    out="$WORK_DIR/${pfx}6.out"; r="$(_b_run "$harness" real flat-dir "$out")"; rc="${r%%	*}"; wd="${r#*	}"
    if [ "$rc" = "0" ] && grep -q 'Personas *OK' "$out" && grep -q '^HEALTH_ERRORS=0$' "$out" \
        && [ "$(_persona_basenames "$wd/.claude/agents")" = "$EXPECTED_PERSONAS" ] && [ ! -e "$wd/.git" ]; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi
}

_b_assert_cases "$TAP_ROOT/$TEMPLATE_REL" B post

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (c) install-team.sh spacedock end to end (sandbox) ==="

# Reuses the (a) install run: same sandbox, same tap.
A_WD="$A_HOME/.aiteamforge/spacedock"
test_start "C1: install deployed every spacedock persona into <wd>/.claude/agents"
if [ "$FLAT_DIR_SUPPORTED" != true ]; then
    test_fail "PENDING: deployer lacks --flat-dir (XACA-1216-003) — not faked"
else
    _got="$(_persona_basenames "$A_WD/.claude/agents")"
    if [ "$A_RC" = "0" ] && [ "$_got" = "$EXPECTED_PERSONAS" ] && [ "$EXPECTED_PERSONA_COUNT" = "4" ]; then
        test_pass
    else
        test_fail "rc=$A_RC expected $EXPECTED_PERSONA_COUNT [$(echo $EXPECTED_PERSONAS)] got [$(echo $_got)]; stderr: $(grep -n '🚨' "$A_ERR" | head -3)"
    fi
fi

test_start "C2: install never touched the (sandbox) user-level ~/.claude/agents"
if [ ! -e "$A_HOME/.claude/agents" ]; then test_pass; else test_fail "$A_HOME/.claude/agents exists: $(ls "$A_HOME/.claude/agents")"; fi

test_start "C3: install did not git-init the working dir"
if [ ! -e "$A_WD/.git" ] && ! git -C "$A_WD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    test_pass
else
    test_fail "$A_WD is (inside) a git work tree after install"
fi

test_start "C4: install reports no 🚨 persona-deploy failure"
if [ "$FLAT_DIR_SUPPORTED" != true ]; then
    test_fail "PENDING: deployer lacks --flat-dir (XACA-1216-003) — not faked"
elif ! grep -q 'persona deploy FAILED' "$A_ERR" "$A_OUT" 2>/dev/null; then
    test_pass
else
    test_fail "$(grep -h 'persona deploy FAILED' "$A_ERR" "$A_OUT")"
fi

test_start "C5: install with a deployer that fails -> loud 🚨 naming the exit, install still exits 0"
C5_TAP="$WORK_DIR/tap-c5"
cp -R "$POST_TAP" "$C5_TAP"
printf '#!/bin/bash\necho "stub deploy failure" >&2\nexit 2\n' > "$C5_TAP/share/scripts/deploy-worktree-personas.sh"
C5_HOME="$(_next_sandbox)/home"; C5_AITF="$(dirname "$C5_HOME")/aiteamforge"
C5_RC="$(_run_install "$C5_TAP" spacedock "$C5_HOME" "$C5_AITF" "$WORK_DIR/c5.out" "$WORK_DIR/c5.err")"
if [ "$C5_RC" = "0" ] && grep -q '🚨.*persona deploy FAILED.*exit 2' "$WORK_DIR/c5.err" && [ -f "$C5_AITF/spacedock-startup.sh" ]; then
    test_pass
else
    test_fail "rc=$C5_RC stderr: $(grep -n 'persona' "$WORK_DIR/c5.err" | head -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (d) upgrade: deploy_flat_team_personas on a pre-provisioned sandbox ==="

# _d_build_fns <upgrade.sh> <out> — extract the upgrade functions under test.
_d_build_fns() {
    local up="$1" out="$2" fn src
    : > "$out"
    for fn in deploy_flat_team_personas _xaca1216_team_persona_deploy_mode _xaca0925_valid_team_id; do
        src="$(_extract_fn "$fn" "$up")"
        [ -n "$src" ] || return 1
        printf '%s\n\n' "$src" >> "$out"
    done
}

# _d_fixture — prints root; lays out FRAMEWORK_DIR, WORKING_DIR, HOME, board.
_d_fixture() {
    local root fw wdir h
    root="$(_next_sandbox)"; fw="$root/fw"; wdir="$root/aiteamforge"; h="$root/home"
    mkdir -p "$fw/share/teams" "$wdir/scripts" "$wdir/spacedock/personas/agents" "$h/.aiteamforge/spacedock/kanban"
    cp "$TAP_ROOT/$SPACEDOCK_CONF_REL" "$fw/share/teams/spacedock.conf"
    cp "$TAP_ROOT/share/teams/ios.conf" "$fw/share/teams/ios.conf"          # unflagged
    cp "$PERSONA_FIXTURE_DIR"/*.md "$wdir/spacedock/personas/agents/"
    echo '{"seed":true}' > "$h/.aiteamforge/spacedock/kanban/spacedock-board.json"
    cp "$DEPLOYER_SRC" "$wdir/scripts/deploy-worktree-personas.sh"
    chmod +x "$wdir/scripts/deploy-worktree-personas.sh"
    printf '%s' "$root"
}

# _d_run <fns-file> <root> <out> [team-paths.json] — run under `set -eo pipefail`
# like the real upgrade; prints "<fn-rc>" and writes stub output + globals to out.
_d_run() {
    local fns="$1" root="$2" out="$3" tp="${4:-}" rc=0
    ( set -eo pipefail
      export HOME="$root/home"
      unset AITEAMFORGE_CONFIG
      [ -n "$tp" ] && export AITEAMFORGE_CONFIG="$tp"
      # shellcheck disable=SC1090
      . "$PATHS_LIB"
      for _p in print_section print_info print_success print_warning print_error; do
          eval "${_p}() { printf '%s: %s\n' ${_p} \"\$*\"; }"
      done
      # shellcheck disable=SC1090
      . "$fns"
      FRAMEWORK_DIR="$root/fw"; WORKING_DIR="$root/aiteamforge"; DRY_RUN=false
      UPGRADE_PERSONA_DEPLOY_HAD_WARNINGS=false
      UPGRADE_PERSONA_DEPLOY_WARNING_SUMMARY="prior-step summary"
      deploy_flat_team_personas
      echo "FN_RC=$?"
      echo "HAD_WARNINGS=$UPGRADE_PERSONA_DEPLOY_HAD_WARNINGS"
      echo "WARNING_SUMMARY=$UPGRADE_PERSONA_DEPLOY_WARNING_SUMMARY"
      echo "CONTINUED_PAST_CALL"
    ) >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

_d_assert_cases() {
    local up="$1" pfx="$2" expect="$3" fns="$WORK_DIR/${pfx}-fns.sh" root out rc wd gitwd tp
    test_start "${pfx}0: aiteamforge-upgrade.sh defines deploy_flat_team_personas + its conf-flag reader"
    if _d_build_fns "$up" "$fns"; then
        [ "$expect" = post ] && test_pass || test_fail "NEGATIVE CONTROL: pre-change upgrade unexpectedly defines them"
    else
        if [ "$expect" = pre ]; then test_pass; return 0; fi
        test_fail "extraction failed from $up"; return 0
    fi

    test_start "${pfx}1: run sequence calls deploy_flat_team_personas IMMEDIATELY after deploy_team_personas_to_projects, and never inside update_mandatory_teams"
    local seq_next in_mand
    seq_next="$(awk '/^deploy_team_personas_to_projects$/ { getline; print; exit }' "$up")"
    in_mand="$(_extract_fn update_mandatory_teams "$up" | grep -c 'deploy_flat_team_personas')"
    if [ "$seq_next" = "deploy_flat_team_personas" ] && [ "$in_mand" = "0" ]; then
        test_pass
    else
        test_fail "line after the deploy_team_personas_to_projects call=[$seq_next]; mentions inside update_mandatory_teams=$in_mand"
    fi

    if [ "$FLAT_DIR_SUPPORTED" != true ]; then
        test_start "${pfx}2-${pfx}5: deploy/refuse/uninspectable against the real deployer"
        test_fail "PENDING: deployer lacks --flat-dir (XACA-1216-003) — not faked"
        return 0
    fi

    root="$(_d_fixture)"; out="$WORK_DIR/${pfx}2.out"; rc="$(_d_run "$fns" "$root" "$out")"
    wd="$root/home/.aiteamforge/spacedock"
    test_start "${pfx}2: pre-provisioned spacedock (board present, no .claude) -> personas deployed by upgrade alone, summary counts it, no warning"
    if [ "$rc" = "0" ] && grep -q '^FN_RC=0$' "$out" && grep -q 'CONTINUED_PAST_CALL' "$out" \
        && [ "$(_persona_basenames "$wd/.claude/agents")" = "$EXPECTED_PERSONAS" ] \
        && grep -q '1 target(s): 1 refreshed, 0 refused, 0 failed, 0 uninspectable' "$out" \
        && grep -q '^HAD_WARNINGS=false$' "$out" && [ ! -e "$wd/.git" ] && [ ! -e "$root/home/.claude/agents" ]; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    root="$(_d_fixture)"; gitwd="$root/gitrepo"
    mkdir -p "$gitwd"
    ( cd "$gitwd" && git init -q . ) || echo "FIXTURE ERROR: git init failed in $gitwd" >&2
    tp="$root/team-paths.json"
    printf '{"schema_version": 1, "teams": {"spacedock": {"kanban_dir": "%s", "working_dir": "%s"}}}\n' \
        "$root/home/.aiteamforge/spacedock/kanban" "$gitwd" > "$tp"
    out="$WORK_DIR/${pfx}3.out"; rc="$(_d_run "$fns" "$root" "$out" "$tp")"
    test_start "${pfx}3: registered working dir is a git repo -> refused (rc 4) and counted, HAD_WARNINGS=true, summary appended, fn rc 0, execution continues"
    if [ "$rc" = "0" ] && grep -q '^FN_RC=0$' "$out" && grep -q 'CONTINUED_PAST_CALL' "$out" \
        && grep -q '1 target(s): 0 refreshed, 1 refused, 0 failed, 0 uninspectable' "$out" \
        && grep -q '^HAD_WARNINGS=true$' "$out" && grep -q '^WARNING_SUMMARY=prior-step summary; ' "$out" \
        && [ ! -e "$gitwd/.claude" ]; then
        test_pass
    else
        test_fail "rc=$rc claude_in_repo=$([ -e "$gitwd/.claude" ] && echo yes || echo no) out: $(tr '\n' '|' < "$out")"
    fi

    root="$(_d_fixture)"; mv "$root/home/.aiteamforge/spacedock" "$root/home/.aiteamforge/spacedock-gone"
    out="$WORK_DIR/${pfx}4.out"; rc="$(_d_run "$fns" "$root" "$out")"
    test_start "${pfx}4: registered working dir does not exist -> uninspectable, warned, NOT created"
    if [ "$rc" = "0" ] && grep -q '0 refreshed, 0 refused, 0 failed, 1 uninspectable' "$out" \
        && grep -q '^HAD_WARNINGS=true$' "$out" && [ ! -e "$root/home/.aiteamforge/spacedock" ]; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi

    root="$(_d_fixture)"; mv "$root/aiteamforge/spacedock" "$root/aiteamforge/spacedock-not-provisioned"
    out="$WORK_DIR/${pfx}5.out"; rc="$(_d_run "$fns" "$root" "$out")"
    test_start "${pfx}5: flagged team not provisioned (no S2 source) -> refresh-only: nothing materialized, summary still prints 0 target(s), no warning"
    if [ "$rc" = "0" ] && grep -q '0 target(s): 0 refreshed, 0 refused, 0 failed, 0 uninspectable' "$out" \
        && grep -q '^HAD_WARNINGS=false$' "$out" && [ ! -e "$root/home/.aiteamforge/spacedock/.claude" ] \
        && [ ! -e "$root/aiteamforge/spacedock" ]; then
        test_pass
    else
        test_fail "rc=$rc out: $(tr '\n' '|' < "$out")"
    fi
}

_d_assert_cases "$TAP_ROOT/$UPGRADE_REL" D post

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== (e) negative control: the same assertions against pre-change copies ($PRECHANGE_REF) ==="

if ! git -C "$TAP_ROOT" cat-file -e "${PRECHANGE_REF}^{commit}" 2>/dev/null; then
    test_start "E: negative control"
    test_skip "pre-change ref $PRECHANGE_REF is not in this clone (shallow?) — set XACA1216_PRECHANGE_REF; the control did NOT run"
else
    PRE_TAP="$WORK_DIR/tap-pre"
    if ! _mk_sandbox_tap "$PRE_TAP" pre; then
        echo "FATAL: could not build pre-change sandbox tap" >&2
        exit 1
    fi

    test_start "E0: the pre-change copies really are pre-change (no TEAM_PERSONA_DEPLOY_MODE anywhere)"
    if ! grep -q 'TEAM_PERSONA_DEPLOY_MODE' "$PRE_TAP/$INSTALL_TEAM_REL" "$PRE_TAP/$UPGRADE_REL" "$PRE_TAP/$TEMPLATE_REL" "$PRE_TAP/$SPACEDOCK_CONF_REL"; then
        test_pass
    else
        test_fail "pre-change ref $PRECHANGE_REF already contains the change — the control would be vacuous"
    fi

    # (b) against the pre-change template: the blocks must be absent.
    _b_assert_cases "$PRE_TAP/$TEMPLATE_REL" EB pre

    # (c) against the pre-change installer: no personas reach the working dir.
    E_HOME="$(_next_sandbox)/home"; E_AITF="$(dirname "$E_HOME")/aiteamforge"
    E_RC="$(_run_install "$PRE_TAP" spacedock "$E_HOME" "$E_AITF" "$WORK_DIR/ec.out" "$WORK_DIR/ec.err")"
    test_start "EC1: pre-change install-team.sh spacedock leaves <wd>/.claude/agents without the personas (C1 would fail)"
    _egot="$(_persona_basenames "$E_HOME/.aiteamforge/spacedock/.claude/agents")"
    if [ "$E_RC" = "0" ] && [ "$_egot" != "$EXPECTED_PERSONAS" ]; then
        test_pass
    else
        test_fail "rc=$E_RC personas present=[$(echo $_egot)] — either the install failed (control unusable) or the pre-change installer already deploys"
    fi
    test_start "EC2: pre-change rendered startup has no TEAM_PERSONA_DEPLOY_MODE line (A2 would fail)"
    if [ -f "$E_AITF/spacedock-startup.sh" ] && ! grep -q 'TEAM_PERSONA_DEPLOY_MODE' "$E_AITF/spacedock-startup.sh"; then
        test_pass
    else
        test_fail "startup missing or already carries the flag"
    fi

    # (d) against the pre-change upgrade: the step does not exist.
    _d_assert_cases "$PRE_TAP/$UPGRADE_REL" ED pre
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "${_STANDALONE:-false}" != true ] && [ -n "${TEST_RESULTS_FILE:-}" ] && [ -f "${TEST_RESULTS_FILE}" ]; then
    _x1216_fail_lines="$(grep '^FAIL:' "$TEST_RESULTS_FILE" 2>/dev/null || true)"
    if [ -n "$_x1216_fail_lines" ]; then
        echo "─── XACA-1216 failure detail ───"
        printf '%s\n' "$_x1216_fail_lines"
    fi
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
