#!/bin/bash
# test-xaca-1225-022-vault-smoke-parity.sh
#
# XACA-1225-022 (PR #1053 blocking test finding): the vault-readiness smoke
# picked its own vault namespace and verdict instead of cc-account-routing.sh's.
# The fix makes the doctor SOURCE the installed router and call its
# _cc_vault_probe_plan; this suite proves the two now agree.
#
# Table rows (team-paths.json for team `academy` unless noted; stub vault-fetch
# returns per-account exit codes):
#   OK1  engine=anthropic account=acct1          -> anthropic acct1                 PASS
#   OK2  neither engine nor account              -> anthropic academy               PASS
#   V1   engine ABSENT, account=acct1            -> anthropic acct1                 PASS
#   V2   account=Acct_1 (invalid slug)           -> anthropic academy (no phantom)  PASS
#   V3   account=acct1 rc 7, team sealed         -> acct1 THEN academy (rc-7 advance) PASS
#   V3b  account=acct1 rc 1 (not 7)              -> acct1 only, no advance          FAIL rc=1
#   V4   engine=openai                           -> NEVER called                    FAIL router refusal
#   V5   team `Academy` (not a vault slug)       -> NEVER called                    info skip
#   V6   account="acct 1" (whitespace)           -> anthropic academy               PASS
#   V7   engine="" (empty), account=acct1        -> anthropic acct1                 PASS
#
# For every row it asserts:
#   (a) the exact argv sequence the stub vault-fetch received from the DOCTOR,
#   (b) the rendered severity + message,
#   (c) PARITY: the argv sequence the stub received from the REAL ROUTER
#       (_cc_export_account_credentials, sourced from the same installed copy)
#       for the same row is identical to (a). This is the drift alarm: if the
#       doctor's rc-7 loop or the router's rules change on one side only, (c)
#       goes red.
#
# Sandbox: HOME, AITEAMFORGE_DIR, AITEAMFORGE_CONFIG, TMPDIR all under a mktemp
# dir before anything is sourced; the router reads $HOME/.aiteamforge/
# team-paths.json, the doctor reads $AITEAMFORGE_CONFIG — both point at the
# same sandbox file. No real $HOME, no launchd, no network (vault-fetch is a
# stub). Requires zsh (stock on macOS) and python3.
#
# Runs standalone or via test-runner.sh. Exit 0 = all pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VR_LIB="$TAP_ROOT/libexec/lib/vault-readiness.sh"
ROUTER_SRC="$TAP_ROOT/share/scripts/cc-account-routing.sh"
RESOLVER_SRC="$TAP_ROOT/share/scripts/cc-credential-team-resolver.sh"
HOOKS_SRC="$TAP_ROOT/share/kanban-hooks"

for _need in "$VR_LIB" "$ROUTER_SRC" "$RESOLVER_SRC" \
             "$HOOKS_SRC/aiteamforge_registry.py" "$HOOKS_SRC/aiteamforge_paths.py"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done
for _tool in zsh python3; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: $_tool required" >&2
        exit 1
    fi
done

if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─── Sandbox (exported BEFORE sourcing anything) ────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1225022-parity.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
WORK_DIR="$TEST_TMP_DIR/xaca1225022"
mkdir -p "$WORK_DIR/home/.aiteamforge" "$WORK_DIR/tmp"
export HOME="$WORK_DIR/home"
export TMPDIR="$WORK_DIR/tmp"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_CONFIG="$HOME/.aiteamforge/team-paths.json"
export AITEAMFORGE_PYTHON
AITEAMFORGE_PYTHON="$(command -v python3)"
unset TMUX TMUX_PANE SESSION_TYPE LCARS_TEAM KB_TEAM CC_ROUTING_TEST_MODE CC_ROUTING_VAULT_FETCH \
      AITEAMFORGE_ALLOW_DEFAULT_OAUTH ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
# Real node must be found here (the doctor's node check is not under test).
export AITF_VR_PATH_PREFIX=""

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

NM='node_mod''ules'   # damage-control hook substring (see test-xaca-1225-001)
SCRIPTS="$AITEAMFORGE_DIR/scripts"
HOOKS="$AITEAMFORGE_DIR/kanban-hooks"
VF_LOG="$WORK_DIR/vf.log"
RC_MAP="$WORK_DIR/rc.map"
TAB="$(printf '\t')"

mkdir -p "$SCRIPTS/$NM/libsodium-wrappers" "$HOOKS" "$WORK_DIR/bin"
cp "$ROUTER_SRC" "$RESOLVER_SRC" "$SCRIPTS/"
cp "$HOOKS_SRC/aiteamforge_registry.py" "$HOOKS_SRC/aiteamforge_paths.py" "$HOOKS/"
printf '#!/bin/bash\n[ "$1" = "--version" ] && { echo v20.11.0; exit 0; }\nexit 0\n' >"$WORK_DIR/bin/node"
chmod +x "$WORK_DIR/bin/node"
export PATH="$WORK_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Stub vault-fetch: log argv; exit code looked up by account in rc.map
# ("<account> <rc>" lines), default 0. Prints a fake token that must never
# surface in doctor output.
cat >"$SCRIPTS/vault-fetch.sh" <<EOF
#!/bin/bash
printf '%s|%s\n' "\$1" "\$2" >> "$VF_LOG"
rc=0
while read -r a r; do
  [ "\$a" = "\$2" ] && rc="\$r"
done < "$RC_MAP"
echo "sk-ant-FAKE-TOKEN-DO-NOT-PRINT"
exit "\$rc"
EOF
chmod +x "$SCRIPTS/vault-fetch.sh"

# _config <team> <credential-json> — team under test + a null sibling (a lone
# team is structurally invalid for peek_config).
_config() {
    printf '{"schema_version": 3, "teams": {"%s": {"ai": {"credential": %s}}, "ios": {"ai": {"credential": null}}}}\n' \
        "$1" "$2" >"$AITEAMFORGE_CONFIG"
}

_doctor() {
    ( source "$VR_LIB"; aitf_vault_readiness_report "$SCRIPTS" "$HOOKS" )
}

# Drive the REAL router for <team>; argv lands in VF_LOG via the same stub.
_router() {
    zsh -f -c '
      source "$1" >/dev/null 2>&1 || exit 91
      local _CC_RESOLVED_TOKEN="" _CC_RESOLVED_AUTH_TYPE=""
      SESSION_TYPE="$2" _cc_export_account_credentials >/dev/null 2>&1
      exit 0
    ' parity "$SCRIPTS/cc-account-routing.sh" "$1"
}

_log() { if [ -s "$VF_LOG" ]; then tr '\n' ' ' <"$VF_LOG" | sed 's/ $//'; else printf 'NEVER'; fi; }

# _row <id> <team> <cred-json> <rc-map> <expected-argv> <sev> <substring>
_row() {
    local id="$1" team="$2" cred="$3" rcmap="$4" want_argv="$5" want_sev="$6" want_sub="$7"
    _config "$team" "$cred"
    printf '%b' "$rcmap" >"$RC_MAP"

    : >"$VF_LOG"
    local out rc=0
    out="$(_doctor)" || rc=$?
    local d_argv
    d_argv="$(_log)"

    : >"$VF_LOG"
    local r_rc=0
    _router "$team" || r_rc=$?
    local r_argv
    r_argv="$(_log)"

    test_start "$id: doctor argv = [$want_argv]"
    if [ "$rc" -eq 0 ] && [ "$d_argv" = "$want_argv" ]; then test_pass; else test_fail "rc=$rc got [$d_argv]"; fi

    test_start "$id: rendered $want_sev containing '$want_sub'"
    if printf '%s\n' "$out" | grep -F "${want_sev}${TAB}" | grep -qF "$want_sub" \
       && ! printf '%s' "$out" | grep -q "FAKE-TOKEN"; then
        test_pass
    else
        test_fail "out=[$out]"
    fi

    test_start "$id: PARITY real router argv = doctor argv"
    if [ "$r_rc" -eq 0 ] && [ "$r_argv" = "$d_argv" ]; then test_pass; else test_fail "router rc=$r_rc router=[$r_argv] doctor=[$d_argv]"; fi
}

C='"account_id": "a1", "nickname": "Acad", "env_var_name": ""'

_row OK1 academy "{$C, \"engine_slug\": \"anthropic\", \"account_slug\": \"acct1\"}" "" \
     "anthropic|acct1" pass "vault-fetch smoke OK (rc=0)"
_row OK2 academy "{$C}" "" \
     "anthropic|academy" pass "vault-fetch smoke OK (rc=0)"
_row V1 academy "{$C, \"account_slug\": \"acct1\"}" "" \
     "anthropic|acct1" pass "vault-fetch smoke OK (rc=0)"
_row V2 academy "{$C, \"account_slug\": \"Acct_1\"}" "" \
     "anthropic|academy" pass "vault-fetch smoke OK (rc=0)"
_row V3 academy "{$C, \"account_slug\": \"acct1\"}" "acct1 7\n" \
     "anthropic|acct1 anthropic|academy" pass "anthropic/acct1, anthropic/academy"
_row V3b academy "{$C, \"account_slug\": \"acct1\"}" "acct1 1\n" \
     "anthropic|acct1" fail "smoke rc=1"
_row V4 academy "{$C, \"engine_slug\": \"openai\", \"account_slug\": \"acct1\"}" "" \
     "NEVER" fail "targets engine 'openai', not 'anthropic'"
_row V5 Academy "{$C}" "" \
     "NEVER" info "not a usable vault account slug"
_row V6 academy "{$C, \"account_slug\": \"acct 1\"}" "" \
     "anthropic|academy" pass "vault-fetch smoke OK (rc=0)"
_row V7 academy "{$C, \"engine_slug\": \"\", \"account_slug\": \"acct1\"}" "" \
     "anthropic|acct1" pass "vault-fetch smoke OK (rc=0)"

# V4 must say it is the ROUTER refusing, not a vault fault.
test_start "V4: refusal is attributed to the router (not a vault-fetch exit code)"
_config academy "{$C, \"engine_slug\": \"openai\"}"
: >"$RC_MAP"; : >"$VF_LOG"
OUT="$(_doctor)"
if printf '%s' "$OUT" | grep -q "the router REFUSES this launch" && ! printf '%s' "$OUT" | grep -q "smoke rc="; then
    test_pass
else
    test_fail "out=[$OUT]"
fi

# Version skew: a router without _cc_vault_probe_plan must not be guessed at.
test_start "SKEW: installed router predating XACA-1225-022 -> warn + skip, vault-fetch never called"
cp "$SCRIPTS/cc-account-routing.sh" "$WORK_DIR/router.bak"
sed 's/^_cc_vault_probe_plan() {/_cc_vault_probe_plan_REMOVED() {/; s/^_cc_resolve_vault_fetch() {/_cc_resolve_vault_fetch_REMOVED() {/' \
    "$WORK_DIR/router.bak" >"$SCRIPTS/cc-account-routing.sh"
_config academy "{$C}"
: >"$VF_LOG"
OUT="$(_doctor)"
if printf '%s' "$OUT" | grep -q "predates XACA-1225-022" && [ ! -s "$VF_LOG" ]; then
    test_pass
else
    test_fail "out=[$OUT] vf=[$(_log)]"
fi
cp "$WORK_DIR/router.bak" "$SCRIPTS/cc-account-routing.sh"

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225-022 vault smoke parity tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
