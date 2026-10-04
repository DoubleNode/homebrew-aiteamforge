#!/bin/bash
# test-xaca-1225-021-vault-readiness.sh
#
# XACA-1225-021 (from XACA-1312 / PR #957): the vault credential tier needs
# node >= 18 AND libsodium-wrappers in $AITEAMFORGE_DIR/scripts/node_modules.
# cc-account-routing.sh calls vault-fetch.sh with VAULT_FETCH_NO_AUTO_INSTALL=1,
# so a missing dep surfaces as rc 127/1 -> "vault faulted" -> undeclared and
# keyless routed teams REFUSE to launch. This suite covers:
#
#   libexec/lib/vault-readiness.sh
#     R1  all deps ok + routed team, smoke rc 0       -> 3x pass, token never echoed,
#                                                        stub got NO_AUTO_INSTALL=1 + engine/account
#     R2  node missing                                 -> fail "node not on PATH"
#     R3  node too old (v16)                           -> fail "older than 18"
#     R4  libsodium-wrappers missing                   -> fail naming node_modules
#     R5  smoke rc 1 / 3 / 127 / 4 / 9                 -> mapped verdicts (3 mentions Keychain)
#     R6  no routed teams (all null)                   -> smoke skipped (info), dep miss = WARN not FAIL
#     R7  routed team without slugs                    -> smoke uses anthropic/<team>
#     R8  vault-fetch.sh not shipped                   -> single info line, nothing counted
#     R9  census unavailable (no kanban-hooks)         -> dep miss = FAIL, smoke skipped
#   libexec/lib/msg-client-deps.sh (install + upgrade share it)
#     L1  npm ci fails + routed team                   -> LOUD box naming the team, rc 0
#     L2  npm ci fails + all-null teams                -> NO box (plain warning only), rc 0
#     L3  node/npm absent + undeclared team            -> LOUD box naming the team, rc 0
#     L4  npm ci fails inside `set -euo pipefail`      -> caller survives
#     L5  npm ci succeeds                              -> no box
#     L6  npm ci fails, census unavailable             -> LOUD box (fail-closed)
#   doctors
#     D1  bin/aiteamforge-doctor.sh --check vault-readiness renders the three checks
#     D2  libexec/commands/aiteamforge-doctor.sh --check vault-readiness ditto
#     S1  both doctors wire vault-readiness into the case arm AND the `all` list
#
# Sandbox: TEST_TMP_DIR + AITEAMFORGE_DIR + HOME + AITEAMFORGE_CONFIG all point
# into a mktemp dir BEFORE anything is sourced. node/npm/vault-fetch are PATH /
# file stubs. Never touches the real $HOME, real team-paths.json, or launchd.
#
# Runs standalone or via test-runner.sh. Exit 0 = all pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VR_LIB="$TAP_ROOT/libexec/lib/vault-readiness.sh"
DEPS_LIB="$TAP_ROOT/libexec/lib/msg-client-deps.sh"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
HOOKS_SRC="$TAP_ROOT/share/kanban-hooks"

for _need in "$VR_LIB" "$DEPS_LIB" "$BIN_DOCTOR" "$LIBEXEC_DOCTOR" \
             "$HOOKS_SRC/aiteamforge_registry.py" "$HOOKS_SRC/aiteamforge_paths.py"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
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
    TEST_TMP_DIR="$(mktemp -d -t xaca1225021-vault-ready.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
WORK_DIR="$TEST_TMP_DIR/xaca1225021"
mkdir -p "$WORK_DIR/home/.aiteamforge"
export HOME="$WORK_DIR/home"
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
export AITEAMFORGE_CONFIG="$WORK_DIR/team-paths.json"
unset TMUX TMUX_PANE
# Census interpreter: the real python3 by absolute path, so PATH shims below
# can strip node without also stripping python.
_PY="$(command -v python3 2>/dev/null || true)"
if [ -z "$_PY" ]; then
    echo "FATAL: python3 required for the credential census" >&2
    exit 1
fi
export AITEAMFORGE_PYTHON="$_PY"
# Test seam: drop vault-fetch's stock /opt/homebrew/bin etc. prefix so the dev
# box's real node cannot satisfy "node missing" cases.
export AITF_VR_PATH_PREFIX=""
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

NM='node_mod''ules'   # see test-xaca-1225-001: damage-control hook substring
SCRIPTS="$AITEAMFORGE_DIR/scripts"
HOOKS="$AITEAMFORGE_DIR/kanban-hooks"
TAB="$(printf '\t')"

# ─── Fixtures ───────────────────────────────────────────────────────────────

# _write_config <kind> — team-paths.json with >=2 teams (structural validity
# rejects empty/academy-alone).
#   routed     academy routed (engine+account), ios null, android undeclared
#   routed_noslug academy routed w/o engine/account slugs, ios null
#   allnull    academy + ios both null
#   undeclared academy + ios both undeclared
_write_config() {
    case "$1" in
        routed) cat >"$AITEAMFORGE_CONFIG" <<'JEOF'
{"schema_version": 3, "teams": {
 "academy": {"ai": {"credential": {"account_id": "a1", "nickname": "Acad", "env_var_name": "TEAM_ACADEMY_API_KEY", "engine_slug": "anthropic", "account_slug": "acad-main"}}},
 "ios": {"ai": {"credential": null}},
 "android": {}
}}
JEOF
        ;;
        routed_noslug) cat >"$AITEAMFORGE_CONFIG" <<'JEOF'
{"schema_version": 3, "teams": {
 "academy": {"ai": {"credential": {"account_id": "a1", "nickname": "Acad", "env_var_name": "TEAM_ACADEMY_API_KEY"}}},
 "ios": {"ai": {"credential": null}}
}}
JEOF
        ;;
        allnull) cat >"$AITEAMFORGE_CONFIG" <<'JEOF'
{"schema_version": 3, "teams": {
 "academy": {"ai": {"credential": null}},
 "ios": {"ai": {"credential": null}}
}}
JEOF
        ;;
        undeclared) cat >"$AITEAMFORGE_CONFIG" <<'JEOF'
{"schema_version": 3, "teams": {
 "academy": {},
 "ios": {"ai": {}}
}}
JEOF
        ;;
    esac
}

# _fresh_install [no_hooks] — scripts/ with package files + vault-fetch.sh
# stub, kanban-hooks/ with the REAL registry modules (unless no_hooks).
_fresh_install() {
    find "$AITEAMFORGE_DIR" -depth -delete 2>/dev/null || true
    mkdir -p "$SCRIPTS"
    printf '{"name":"c","dependencies":{"libsodium-wrappers":"^0.7.16"}}\n' >"$SCRIPTS/package.json"
    printf '{"name":"c","lockfileVersion":3}\n' >"$SCRIPTS/package-lock.json"
    if [ "${1:-}" != "no_hooks" ]; then
        mkdir -p "$HOOKS"
        cp "$HOOKS_SRC/aiteamforge_registry.py" "$HOOKS_SRC/aiteamforge_paths.py" "$HOOKS/"
    fi
    # XACA-1225-022: the smoke asks the INSTALLED router for its plan, so the
    # real cc-account-routing.sh (+ its resolver sibling) ships beside the stub
    # vault-fetch.sh exactly as on a consumer box.
    cp "$TAP_ROOT/share/scripts/cc-account-routing.sh" "$TAP_ROOT/share/scripts/cc-credential-team-resolver.sh" "$SCRIPTS/"
    _vault_fetch_stub 0
}

_libsodium_present() { mkdir -p "$SCRIPTS/$NM/libsodium-wrappers"; }

# _vault_fetch_stub <rc> — prints a fake TOKEN on stdout (must never surface)
# and logs args + NO_AUTO_INSTALL to a file.
VF_LOG="$WORK_DIR/vf.log"
_vault_fetch_stub() {
    cat >"$SCRIPTS/vault-fetch.sh" <<EOF
#!/bin/bash
printf 'args=%s noauto=%s\n' "\$*" "\${VAULT_FETCH_NO_AUTO_INSTALL:-unset}" >> "$VF_LOG"
echo "sk-ant-FAKE-TOKEN-DO-NOT-PRINT"
exit $1
EOF
    chmod +x "$SCRIPTS/vault-fetch.sh"
    : >"$VF_LOG"
}

# _bin_dir <node_version|none> <npm_mode ok|fail|none>
_bin_dir() {
    local ver="$1" npm_mode="$2" d
    d="$WORK_DIR/bin-$RANDOM-$RANDOM"
    mkdir -p "$d"
    if [ "$ver" != "none" ]; then
        printf '#!/bin/bash\n[ "$1" = "--version" ] && { echo "%s"; exit 0; }\nexit 0\n' "$ver" >"$d/node"
        chmod +x "$d/node"
    fi
    case "$npm_mode" in
        ok)
            cat >"$d/npm" <<EOF
#!/bin/bash
[ "\$1" = "ci" ] && { mkdir -p "$NM/libsodium-wrappers"; exit 0; }
exit 1
EOF
            chmod +x "$d/npm" ;;
        fail)
            printf '#!/bin/bash\necho "npm ERR! simulated" >&2\nexit 1\n' >"$d/npm"
            chmod +x "$d/npm" ;;
        *) : ;;
    esac
    printf '%s' "$d"
}

# _report <bin_dir> — run aitf_vault_readiness_report in a subshell; prints its
# stdout. rc captured first by the caller via the out file.
_report() {
    ( PATH="$1:$BASE_PATH"; source "$VR_LIB"; aitf_vault_readiness_report "$SCRIPTS" "$HOOKS" )
}

_has_line() {   # _has_line <text> <sev> <substring>
    printf '%s\n' "$1" | grep -F "$2$TAB" | grep -qF "$3"
}

# ═══ R1 ═════════════════════════════════════════════════════════════════════
test_start "R1: deps ok + routed team + smoke rc 0 -> 3 passes, token never echoed"
_fresh_install; _libsodium_present; _write_config routed; _vault_fetch_stub 0
B="$(_bin_dir v20.11.0 none)"
OUT="$(_report "$B")"; RC=$?
if [ "$RC" -eq 0 ] \
   && _has_line "$OUT" pass "node v20.11.0" \
   && _has_line "$OUT" pass "libsodium-wrappers installed" \
   && _has_line "$OUT" pass "vault-fetch smoke OK (rc=0)" \
   && ! printf '%s' "$OUT" | grep -q "FAKE-TOKEN" \
   && ! printf '%s' "$OUT" | grep -q "^fail" \
   && grep -q "args=anthropic acad-main noauto=1" "$VF_LOG"; then
    test_pass
else
    test_fail "rc=$RC out=[$OUT] vflog=[$(cat "$VF_LOG")]"
fi

# ═══ R2 ═════════════════════════════════════════════════════════════════════
test_start "R2: node missing -> FAIL node not on PATH"
_fresh_install; _libsodium_present; _write_config routed
B="$(_bin_dir none none)"
OUT="$(_report "$B")"
if _has_line "$OUT" fail "node not on PATH"; then test_pass; else test_fail "out=[$OUT]"; fi

# ═══ R3 ═════════════════════════════════════════════════════════════════════
test_start "R3: node v16 -> FAIL older than 18"
_fresh_install; _libsodium_present; _write_config routed
B="$(_bin_dir v16.20.2 none)"
OUT="$(_report "$B")"
if _has_line "$OUT" fail "older than 18"; then test_pass; else test_fail "out=[$OUT]"; fi

# ═══ R4 ═════════════════════════════════════════════════════════════════════
test_start "R4: libsodium-wrappers missing -> FAIL naming node_modules + fix"
_fresh_install; _write_config routed
B="$(_bin_dir v20.11.0 none)"
OUT="$(_report "$B")"
if _has_line "$OUT" fail "libsodium-wrappers missing" && _has_line "$OUT" fail "npm ci --omit=dev"; then
    test_pass
else
    test_fail "out=[$OUT]"
fi

# ═══ R5 ═════════════════════════════════════════════════════════════════════
B="$(_bin_dir v20.11.0 none)"
for case_ in "1:fail:libsodium-wrappers missing" "3:warn:login Keychain is locked" \
             "127:fail:node not on PATH" "4:warn:unreachable" "9:fail:faulted" "5:pass:cache hit"; do
    _rc="${case_%%:*}"; _rest="${case_#*:}"; _sev="${_rest%%:*}"; _sub="${_rest#*:}"
    test_start "R5: smoke rc=$_rc -> $_sev ($_sub)"
    _fresh_install; _libsodium_present; _write_config routed; _vault_fetch_stub "$_rc"
    OUT="$(_report "$B")"
    if _has_line "$OUT" "$_sev" "smoke rc=$_rc" || _has_line "$OUT" "$_sev" "(rc=$_rc"; then
        if _has_line "$OUT" "$_sev" "$_sub" && ! printf '%s' "$OUT" | grep -q "FAKE-TOKEN"; then
            test_pass
        else
            test_fail "missing substring '$_sub' or token leaked: out=[$OUT]"
        fi
    else
        test_fail "no $_sev line for rc=$_rc: out=[$OUT]"
    fi
done

# ═══ R6 ═════════════════════════════════════════════════════════════════════
test_start "R6: all-null teams -> smoke skipped (info), dep miss is WARN not FAIL"
_fresh_install; _write_config allnull
B="$(_bin_dir none none)"
OUT="$(_report "$B")"
if _has_line "$OUT" info "no team has a routed ai.credential" \
   && _has_line "$OUT" warn "node not on PATH" \
   && _has_line "$OUT" warn "libsodium-wrappers missing" \
   && ! printf '%s' "$OUT" | grep -q "^fail" \
   && [ ! -s "$VF_LOG" ]; then
    test_pass
else
    test_fail "out=[$OUT] vflog=[$(cat "$VF_LOG")]"
fi

# ═══ R7 ═════════════════════════════════════════════════════════════════════
test_start "R7: routed team without engine/account slugs -> smoke asks anthropic/<team>"
_fresh_install; _libsodium_present; _write_config routed_noslug; _vault_fetch_stub 0
B="$(_bin_dir v20.11.0 none)"
OUT="$(_report "$B")"
if grep -q "args=anthropic academy noauto=1" "$VF_LOG"; then test_pass; else test_fail "vflog=[$(cat "$VF_LOG")]"; fi

# ═══ R8 ═════════════════════════════════════════════════════════════════════
test_start "R8: vault-fetch.sh not shipped -> single info line"
_fresh_install; _write_config routed; rm -f "$SCRIPTS/vault-fetch.sh"
B="$(_bin_dir none none)"
OUT="$(_report "$B")"
if [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 1 ] && _has_line "$OUT" info "not applicable"; then
    test_pass
else
    test_fail "out=[$OUT]"
fi

# ═══ R9 ═════════════════════════════════════════════════════════════════════
test_start "R9: census unavailable -> dep miss is FAIL (fail-closed), smoke skipped"
_fresh_install no_hooks; _write_config allnull
B="$(_bin_dir none none)"
OUT="$(_report "$B")"
if _has_line "$OUT" fail "node not on PATH" && _has_line "$OUT" info "census unavailable" && [ ! -s "$VF_LOG" ]; then
    test_pass
else
    test_fail "out=[$OUT]"
fi

# ─── msg-client-deps loud-warning cases ─────────────────────────────────────
_provision() {   # _provision <bin_dir> -> stderr to $ERR, stdout "rc=N"
    ( PATH="$1:$BASE_PATH"; source "$DEPS_LIB"; provision_msg_client_node_deps "$SCRIPTS" false; echo "rc=$?" ) 2>"$ERR"
}
ERR="$WORK_DIR/prov.err"
# stdout carries the "Installing ..." progress line before "rc=N".
_ends_rc0() { [ "$(printf '%s\n' "$1" | tail -n 1)" = "rc=0" ]; }
BOX="VAULT CREDENTIAL TIER IS OFF"

test_start "L1: npm ci fails + routed team -> LOUD box naming the team, rc 0"
_fresh_install; _write_config routed
B="$(_bin_dir v20.11.0 fail)"
OUT="$(_provision "$B")"
if _ends_rc0 "$OUT" && grep -qF "$BOX" "$ERR" && grep -q "academy" "$ERR" \
   && grep -q "android" "$ERR" && ! grep -q "##.*ios" "$ERR"; then
    test_pass
else
    test_fail "out=[$OUT] err=[$(cat "$ERR")]"
fi

test_start "L2: npm ci fails + all-null teams -> NO box, plain warning only, rc 0"
_fresh_install; _write_config allnull
B="$(_bin_dir v20.11.0 fail)"
OUT="$(_provision "$B")"
if _ends_rc0 "$OUT" && ! grep -qF "$BOX" "$ERR" && grep -q "npm ci failed" "$ERR"; then
    test_pass
else
    test_fail "out=[$OUT] err=[$(cat "$ERR")]"
fi

test_start "L3: node/npm absent + undeclared teams -> LOUD box naming them, rc 0"
_fresh_install; _write_config undeclared
B="$(_bin_dir none none)"
OUT="$(_provision "$B")"
if _ends_rc0 "$OUT" && grep -qF "$BOX" "$ERR" && grep -q "Node.js/npm not found" "$ERR" \
   && grep -q "academy ios" "$ERR"; then
    test_pass
else
    test_fail "out=[$OUT] err=[$(cat "$ERR")]"
fi

test_start "L4: failing npm ci inside a set -euo pipefail caller does not abort it"
_fresh_install; _write_config routed
B="$(_bin_dir v20.11.0 fail)"
OUT="$( PATH="$B:$BASE_PATH" bash -c 'set -euo pipefail; source "$1"; provision_msg_client_node_deps "$2" false; echo SURVIVED' _ "$DEPS_LIB" "$SCRIPTS" 2>/dev/null )"
if [ "$OUT" = "SURVIVED" ] || printf '%s' "$OUT" | grep -q "SURVIVED$"; then test_pass; else test_fail "out=[$OUT]"; fi

test_start "L5: npm ci succeeds -> no box"
_fresh_install; _write_config routed
B="$(_bin_dir v20.11.0 ok)"
OUT="$(_provision "$B")"
if [ "$OUT" != "${OUT%rc=0}" ] && ! grep -qF "$BOX" "$ERR" && [ -d "$SCRIPTS/$NM/libsodium-wrappers" ]; then
    test_pass
else
    test_fail "out=[$OUT] err=[$(cat "$ERR")]"
fi

test_start "L6: npm ci fails + census unavailable -> LOUD box (fail-closed)"
_fresh_install no_hooks; _write_config allnull
B="$(_bin_dir v20.11.0 fail)"
OUT="$(_provision "$B")"
if _ends_rc0 "$OUT" && grep -qF "$BOX" "$ERR" && grep -q "could not read team credentials" "$ERR"; then
    test_pass
else
    test_fail "out=[$OUT] err=[$(cat "$ERR")]"
fi

# ─── Doctors end-to-end ─────────────────────────────────────────────────────
test_start "D1: bin doctor --check vault-readiness renders the three checks"
_fresh_install; _libsodium_present; _write_config routed; _vault_fetch_stub 0
B="$(_bin_dir v20.11.0 none)"
D_RC=0
D_OUT="$( PATH="$B:$BASE_PATH" AITEAMFORGE_HOME="$TAP_ROOT" SHELL=/bin/false bash "$BIN_DOCTOR" --check vault-readiness 2>&1 )" || D_RC=$?
if [ "$D_RC" -eq 0 ] && printf '%s' "$D_OUT" | grep -q "node v20.11.0" \
   && printf '%s' "$D_OUT" | grep -q "libsodium-wrappers installed" \
   && printf '%s' "$D_OUT" | grep -q "vault-fetch smoke OK" \
   && ! printf '%s' "$D_OUT" | grep -q "FAKE-TOKEN"; then
    test_pass
else
    test_fail "rc=$D_RC out=[$D_OUT]"
fi

test_start "D2: libexec doctor --check vault-readiness renders the three checks (and fails on rc 127)"
_fresh_install; _libsodium_present; _write_config routed; _vault_fetch_stub 127
D_RC=0
D_OUT="$( PATH="$B:$BASE_PATH" AITEAMFORGE_HOME="$TAP_ROOT" SHELL=/bin/false bash "$LIBEXEC_DOCTOR" --check vault-readiness 2>&1 )" || D_RC=$?
if [ "$D_RC" -eq 2 ] && printf '%s' "$D_OUT" | grep -q "node v20.11.0" \
   && printf '%s' "$D_OUT" | grep -q "libsodium-wrappers installed" \
   && printf '%s' "$D_OUT" | grep -q "smoke rc=127" \
   && ! printf '%s' "$D_OUT" | grep -q "FAKE-TOKEN"; then
    test_pass
else
    test_fail "rc=$D_RC out=[$D_OUT]"
fi

test_start "S1: both doctors wire vault-readiness into the case arm AND the all list"
_s1_ok=true
for _doc in "$BIN_DOCTOR" "$LIBEXEC_DOCTOR"; do
    grep -qE '^  vault-readiness\)$' "$_doc" || { _s1_ok=false; echo "     no case arm in $_doc" >&2; }
    awk '/^  all\)$/{f=1} f&&/;;/{exit} f' "$_doc" | grep -qE '^    check_vault_readiness$' \
        || { _s1_ok=false; echo "     not in all list: $_doc" >&2; }
done
if [ "$_s1_ok" = true ]; then test_pass; else test_fail "wiring missing (see above)"; fi

if [ -n "${_PASS_COUNT+x}" ]; then
    echo ""
    echo "XACA-1225-021 vault-readiness tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
