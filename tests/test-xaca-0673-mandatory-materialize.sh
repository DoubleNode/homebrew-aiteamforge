#!/bin/bash

# test-xaca-0673-mandatory-materialize.sh
# Regression tests for XACA-0673: update_runtime_helpers must MATERIALISE
# mandatory shared modules on upgrade even when the working-dir target is ABSENT.
#
# REGRESSION INTENT: XACA-0608's update_runtime_helpers refreshes ONLY scripts a
# machine already installed (`[ -f "$target" ] || continue`) — correct for
# optional/layout-specific helpers (CR pollers, station scripts). But it is fatal
# for a BRAND-NEW shared module introduced by a release and imported by an
# ALREADY-INSTALLED script: the importer is refreshed in place (gaining the new
# `import <module>` line) while the module itself is skipped (absent target),
# leaving the consumer with an importer but no module.
#
# Originating incident: iterm2_venv_bootstrap.py (added by XACA-0652, imported by
# iterm-browser.py / iterm2_window_manager.py). M4Mini auto-upgraded to 0.13.4:
# iterm-browser.py was refreshed and now did `import iterm2_venv_bootstrap`, but
# the module was never laid down on disk → `import iterm2` failed → the LCARS web
# cockpit tab failed to create. Same refresh-gap class as XACA-0558 / 0585 / 0608.
#
# Assertions:
#   1. update_runtime_helpers MATERIALISES a mandatory module (iterm2_venv_bootstrap.py)
#      when it is ABSENT from WORKING_DIR/scripts/ but a sibling IS installed.
#   2. The materialised module is valid Python (py_compile) and keeps its exec bit.
#   3. REGRESSION GUARD: an OPTIONAL absent helper (agent-panel-display.sh) is
#      STILL NOT materialised — the XACA-0608 intentional skip is preserved.
#   4. --dry-run does not materialise the mandatory module.
#   5. iterm2_venv_bootstrap.py is registered in the mandatory set (explicit).
#   6. PARITY GUARD (anti-drift): EVERY share/scripts/*.py module that is
#      imported by another shipped .py under share/ MUST appear in the mandatory
#      set. A newly shipped sibling-imported module that is forgotten here fails
#      this test — so the set can never silently drift behind the code.
#
# All filesystem activity is sandboxed to TEST_TMP_DIR.
# NEVER touches real $HOME / ~/.aiteamforge — installer-test safety rule.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# XACA-1240: extracted upgrade/install functions call the shared atomic-write helper.
source "$TAP_ROOT/libexec/lib/atomic-write.sh"
# XACA-1460-004: test-only overrides so the guard can be mutation-proved against a
# COPY of the upgrade script / share tree. Defaults are the real files.
UPGRADE_SH="${XACA0673_UPGRADE_SH:-$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh}"
GUARD_SHARE="${XACA0673_SHARE_DIR:-$TAP_ROOT/share}"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
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
if ! type -t assert_file_exists >/dev/null 2>&1; then
    assert_file_exists() { [ -f "$1" ] || { test_fail "${2:-Expected file to exist: $1}"; return 1; }; }
fi
if ! type -t assert_file_not_exists >/dev/null 2>&1; then
    assert_file_not_exists() { [ ! -f "$1" ] || { test_fail "${2:-Expected file to not exist: $1}"; return 1; }; }
fi
if ! type -t assert_contains >/dev/null 2>&1; then
    assert_contains() { [[ "$1" == *"$2"* ]] || { test_fail "${3:-Expected to find '$2'}"; return 1; }; }
fi

# print_* stubs used by the extracted function.
for _p in print_section print_info print_success print_warning print_error; do
    if ! declare -f "$_p" >/dev/null 2>&1; then eval "${_p}() { :; }"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0673-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Extract the functions under test from upgrade.sh without sourcing the whole
# script (its main body has side effects). Each captured from `name() {` through
# the first column-0 `}`.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}
for _fn in _xaca0608_render_team_script _xaca0608_aux_script_map \
           _xaca0608_aux_scriptdir_basenames _xaca0673_mandatory_materialize_basenames \
           _xaca1143_aux_mandatory_materialize_basenames \
           update_runtime_helpers; do
    _src="$(_extract_fn "$_fn")"
    if [ -z "$_src" ]; then echo "FATAL: could not extract $_fn from upgrade.sh"; exit 1; fi
    eval "$_src"
    declare -f "$_fn" >/dev/null || { echo "FATAL: $_fn not defined after extraction"; exit 1; }
done

SANDBOX="$TEST_TMP_DIR/xaca0673"
RH_WORKING="$SANDBOX/rh-working"
RH_SCRIPTS="$RH_WORKING/scripts"
mkdir -p "$RH_SCRIPTS"

run_update_runtime_helpers() {
    FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$RH_WORKING" update_runtime_helpers 2>&1
}

MANDATORY_NAME="iterm2_venv_bootstrap.py"
MANDATORY_SRC="$TAP_ROOT/share/scripts/$MANDATORY_NAME"
SIBLING_SRC="$TAP_ROOT/share/scripts/iterm2_window_manager.py"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: mandatory module is MATERIALISED when absent (sibling installed)
# ═══════════════════════════════════════════════════════════════════════════
test_start "update_runtime_helpers materialises an ABSENT mandatory module (iterm2_venv_bootstrap.py)"
if [ -f "$MANDATORY_SRC" ]; then
    # Seed a sibling that IS installed (mirrors the real M4Mini layout: the
    # importer is present and refreshed, but the bootstrap module is absent).
    if [ -f "$SIBLING_SRC" ]; then
        printf '#!/usr/bin/env python3\n# pre-existing sibling\n' > "$RH_SCRIPTS/iterm2_window_manager.py"
        chmod +x "$RH_SCRIPTS/iterm2_window_manager.py"
    fi
    rm -f "$RH_SCRIPTS/$MANDATORY_NAME"   # the brand-new module is NOT yet installed
    FORCE=false DRY_RUN=false run_update_runtime_helpers >/dev/null 2>&1
    assert_file_exists "$RH_SCRIPTS/$MANDATORY_NAME" \
        "Mandatory module must be materialised on upgrade even though its target was absent" \
        && test_pass
else
    test_fail "share/scripts/$MANDATORY_NAME missing — cannot exercise materialisation"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: materialised module is valid Python + keeps exec bit
# ═══════════════════════════════════════════════════════════════════════════
test_start "Materialised mandatory module is valid Python and executable"
if [ -f "$RH_SCRIPTS/$MANDATORY_NAME" ]; then
    if python3 -m py_compile "$RH_SCRIPTS/$MANDATORY_NAME" 2>/dev/null && [ -x "$RH_SCRIPTS/$MANDATORY_NAME" ]; then
        test_pass
    else
        test_fail "Materialised module must compile cleanly and retain its exec bit"
    fi
else
    test_fail "Materialised module absent — cannot validate"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: REGRESSION — an OPTIONAL absent helper is STILL not materialised
# ═══════════════════════════════════════════════════════════════════════════
test_start "Optional absent helper (agent-panel-display.sh) is NOT materialised (XACA-0608 skip preserved)"
rm -f "$RH_SCRIPTS/agent-panel-display.sh"
FORCE=false DRY_RUN=false run_update_runtime_helpers >/dev/null 2>&1
assert_file_not_exists "$RH_SCRIPTS/agent-panel-display.sh" \
    "Optional helpers must still NOT be materialised when absent — only the mandatory set is exempt" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: --dry-run does not materialise the mandatory module
# ═══════════════════════════════════════════════════════════════════════════
test_start "--dry-run does not materialise the mandatory module"
DRY_SCRIPTS="$SANDBOX/dry-working/scripts"
mkdir -p "$DRY_SCRIPTS"
[ -f "$SIBLING_SRC" ] && { printf '#!/usr/bin/env python3\n' > "$DRY_SCRIPTS/iterm2_window_manager.py"; chmod +x "$DRY_SCRIPTS/iterm2_window_manager.py"; }
FRAMEWORK_DIR="$TAP_ROOT" WORKING_DIR="$SANDBOX/dry-working" DRY_RUN=true FORCE=false update_runtime_helpers >/dev/null 2>&1
assert_file_not_exists "$DRY_SCRIPTS/$MANDATORY_NAME" \
    "--dry-run must not write the mandatory module to disk" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: mandatory set explicitly contains iterm2_venv_bootstrap.py
# ═══════════════════════════════════════════════════════════════════════════
test_start "Mandatory set registers iterm2_venv_bootstrap.py"
MANDATORY_SET="$(_xaca0673_mandatory_materialize_basenames)"
assert_contains $'\n'"$MANDATORY_SET"$'\n' $'\n'"$MANDATORY_NAME"$'\n' \
    "iterm2_venv_bootstrap.py must be in the mandatory-materialise set" \
    && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# TEST 6: PARITY GUARD — every sibling-imported shipped module is mandatory.
# Auto-detects future drift: if a new share/scripts/*.py module is imported by
# another shipped script but not added to the mandatory set, this FAILS.
# ═══════════════════════════════════════════════════════════════════════════
test_start "PARITY: every sibling-imported share/scripts module is in the mandatory set"
# XACA-1460-004 widening: importers now include extensionless python-shebang files,
# and references include dynamic loads (quoted exact basename / .py stem literals,
# which catch _find_script("kb-wiki"), _load_script_module("x"),
# spec_from_file_location(..., "x.py"), importlib and subprocess-by-name) in the
# shipped kanban-hooks/ and lcars-ui/ trees. Narrowing (to avoid false positives):
# tests/ dirs and test_* files are skipped; a file never counts as referencing
# itself; dynamic refs are matched only against top-level regular files of
# share/scripts. Static `import X` is matched only for .py stems (a hyphenated
# extensionless script cannot be imported).
# (Python body is written to a file first: bash 3.2 mis-scans quotes/parens inside a
# heredoc nested in $( ), so it must not live inside the command substitution.)
_SCAN_PY="$TEST_TMP_DIR/xaca0673-scan.py"
cat > "$_SCAN_PY" <<'PY'
import os, re, sys
share = sys.argv[1]
sdir = os.path.normpath(os.path.join(share, "scripts"))
files = [f for f in sorted(os.listdir(sdir)) if os.path.isfile(os.path.join(sdir, f))]
names = {}                      # lookup token -> required basename
for f in files:
    names[f] = f
    if f.endswith(".py"):
        names[f[:-3]] = f
def is_py_shebang(path):
    try:
        with open(path, "rb") as fh:
            first = fh.readline(200)
        return first.startswith(b"#!") and b"python" in first
    except Exception:
        return False
# XACA-1460-012: consumer-delivered extensionless SHELL scripts (the extensionless
# entries of the mandatory set, argv[2]) reference siblings by path, e.g.
# WIZARD_PY="${SCRIPT_DIR}/aiteamforge-team-paths-wizard.py". Scan those for exact
# full basenames (path-delimited, not substrings). Dev-only allowlisted scripts
# (kb-tap-release) are not consumer-delivered, so they are never scanned.
consumer_x = {n for n in (sys.argv[2].split("\n") if len(sys.argv) > 2 else []) if n and "." not in n}
imported = set()
for f in files:
    if f not in consumer_x:
        continue
    path = os.path.join(sdir, f)
    if is_py_shebang(path):
        continue                # python scripts are covered by the walk below
    try:
        # Full-line shell comments are dropped: prose mentions ("NEVER invoke
        # auto-upgrade.sh") are not dependencies and were measured as the only noise.
        txt = "\n".join(l for l in open(path, encoding="utf-8", errors="ignore").read().splitlines()
                        if not l.lstrip().startswith("#"))
    except Exception:
        continue
    for base in files:
        if base == f:
            continue
        if re.search(r'(?<![\w.-])' + re.escape(base) + r'(?![\w.-])', txt):
            imported.add(base)
for root, dirs, fnames in os.walk(share):
    if "tests" in os.path.normpath(root).split(os.sep):
        continue
    for fn in fnames:
        path = os.path.normpath(os.path.join(root, fn))
        if fn.startswith("test_"):
            continue
        py = fn.endswith(".py")
        xpy = ("." not in fn) and is_py_shebang(path)
        dyn_tree = any(("/" + t + "/") in path.replace(os.sep, "/") for t in ("kanban-hooks", "lcars-ui"))
        if not (py or xpy):
            continue
        try:
            txt = open(path, encoding="utf-8", errors="ignore").read()
        except Exception:
            continue
        for tok, base in names.items():
            if os.path.normpath(os.path.join(sdir, base)) == path:
                continue
            if base.endswith(".py") and tok == base[:-3] and re.search(
                    rf'(?m)^\s*(import\s+{re.escape(tok)}\b|from\s+{re.escape(tok)}\s+import)', txt):
                imported.add(base)
            if (dyn_tree or xpy) and re.search(r"""["']""" + re.escape(tok) + r"""["']""", txt):
                imported.add(base)
for name in sorted(imported):
    print(name)
PY
MANDATORY_SET="$(_xaca0673_mandatory_materialize_basenames)"
MISSING="$(python3 "$_SCAN_PY" "$GUARD_SHARE" "$MANDATORY_SET")"
# Known exceptions (documented follow-ups, NOT silently weakened):
#   kb-cr.sh - referenced by server.py; aux-map-owned (refreshed if present) but not
#   aux-mandatory. Always laid down by install-kanban.sh. XACA-1460 disposition
#   follow-up 3: confirm whether it should be aux-mandatory.
#   register-claude-hook.py - located by kb-msg-provision (extensionless python) via
#   os.path.join; it is a *.py (refreshed if present) and kb-msg-provision degrades
#   to a 'no-registrar' outcome when absent. Surfaced by the XACA-1460-004 widening;
#   follow-up: decide whether it should be 0673-mandatory.
#   lcars-health-check.sh - root-destined aux-map entry (refreshed if present);
#   kb-spacedock probes $HOME/dev-team/ and $AITEAMFORGE_DIR[/scripts]/ for it and
#   reports 'unknown' when absent. Surfaced by the XACA-1460-012 shell-sibling
#   widening; pre-existing, follow-up: decide whether it should be aux-mandatory.
PARITY_KNOWN_EXCEPTIONS=$'kb-cr.sh\nregister-claude-hook.py\nlcars-health-check.sh'
# Consumer datafiles (msg-client.js, vault-keygen.js, ...) have their own refresh
# path (_aitf_consumer_datafiles in libexec/lib/msg-client-deps.sh); extract by text.
_DATAFILES="$(awk '/^_aitf_consumer_datafiles\(\) \{/{f=1;next} f&&/^EOF$/{exit} f&&!/cat <</{print}' "$TAP_ROOT/libexec/lib/msg-client-deps.sh")"
[ -n "$_DATAFILES" ] || { _parity_ok_pre=false; echo "     FAIL-CLOSED: could not extract _aitf_consumer_datafiles" >&2; }
# A reference is covered by 0673 OR the aux-mandatory set (XACA-1143) OR a known exception.
_REAL_COVER="$MANDATORY_SET"$'\n'"$(_xaca1143_aux_mandatory_materialize_basenames)"$'\n'"$_DATAFILES"
MANDATORY_SET="$_REAL_COVER"$'\n'"$PARITY_KNOWN_EXCEPTIONS"
_parity_ok=true
[ "${_parity_ok_pre:-true}" = true ] || _parity_ok=false
# Fail-closed: an empty or collapsed scan (parse failure) must never pass.
# Floor, not equality: measured 15 references on 2026-10-07 (XACA-1460-011), before
# the XACA-1460-012 shell-sibling widening added more.
_ref_count="$(printf '%s\n' "$MISSING" | grep -c .)"
[ "$_ref_count" -ge 12 ] || { _parity_ok=false; echo "     FAIL-CLOSED: importer/reference scan found $_ref_count reference(s) (< 12 floor; expected ~15)" >&2; }
# Stale known exceptions (XACA-1460-011): each must still be referenced AND still
# uncovered, else it silently outlives the follow-up that fixed it — remove it.
while IFS= read -r exc; do
    [ -n "$exc" ] || continue
    case $'\n'"$MISSING"$'\n' in
        *$'\n'"$exc"$'\n'*) : ;;
        *) _parity_ok=false; echo "     STALE-EXCEPTION: '$exc' is no longer referenced by any shipped script — remove it from PARITY_KNOWN_EXCEPTIONS" >&2 ;;
    esac
    case $'\n'"$_REAL_COVER"$'\n' in
        *$'\n'"$exc"$'\n'*) _parity_ok=false; echo "     STALE-EXCEPTION: '$exc' is now covered by a mandatory set — remove it from PARITY_KNOWN_EXCEPTIONS" >&2 ;;
    esac
done <<< "$PARITY_KNOWN_EXCEPTIONS"
while IFS= read -r mod; do
    [ -n "$mod" ] || continue
    case $'\n'"$MANDATORY_SET"$'\n' in
        *$'\n'"$mod"$'\n'*) : ;;
        *) _parity_ok=false; echo "     DRIFT: '$mod' is imported by a shipped script but missing from the mandatory set" >&2 ;;
    esac
done <<< "$MISSING"
if [ "$_parity_ok" = true ]; then
    test_pass
else
    test_fail "Sibling-imported shipped module(s) missing from _xaca0673_mandatory_materialize_basenames — add them"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 7 (XACA-1460): EXTENSIONLESS COVERAGE GUARD.
# The sweep globs only *.sh / *.py plus an explicit name list, so a shipped
# extensionless share/scripts file with no upgrade path is NEVER refreshed.
# 0673 membership alone reaches nothing for such a file; it must be BOTH an
# explicit sweep token AND in 0673 (precedent XACA-1300 / 1449 / 1460).
# Parsed by text/awk; upgrade.sh is never sourced.
# ═══════════════════════════════════════════════════════════════════════════
# Allowlist: shipped, extensionless, deliberately NOT refreshed on consumers.
#   kb-tap-release - dev-only: needs an outer dev-team checkout + scripts/kb-tap-lock.sh
ALLOW_X="kb-tap-release"
_sorted() { sort -u | sed '/^$/d'; }
SHIPPED_X="$(find "$GUARD_SHARE/scripts" -maxdepth 1 -type f ! -name '*.*' -exec basename {} \; | _sorted)"
_for_line="$(_extract_fn update_runtime_helpers | grep -m1 -E '^[[:space:]]*for src in ')"
SWEEP_X="$(printf '%s\n' "$_for_line" | grep -oE '"\$scripts_source"/[A-Za-z0-9_.-]+' | sed 's#.*/##' | _sorted)"
M0673="$(_xaca0673_mandatory_materialize_basenames | _sorted)"
AUX_X="$(WORKING_DIR=/x _xaca0608_aux_script_map | cut -d'|' -f1 | _sorted)"
_cnt() { if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l | tr -d ' '; else echo 0; fi; }
_in() { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

test_start "GUARD: shipped extensionless share/scripts files have an upgrade path (sweep+0673, aux, or allowlist)"
_g_ok=true
# fail-closed non-vacuity (floors, not equality; |SHIPPED_X| was 16 at time of writing)
[ -n "$_for_line" ] || { _g_ok=false; echo "     FAIL-CLOSED: no 'for src in' line found in update_runtime_helpers" >&2; }
[ "$(_cnt "$SHIPPED_X")" -ge 16 ] || { _g_ok=false; echo "     FAIL-CLOSED: |SHIPPED_X|=$(_cnt "$SHIPPED_X") < 16" >&2; }
[ "$(_cnt "$SWEEP_X")" -ge 7 ]    || { _g_ok=false; echo "     FAIL-CLOSED: |SWEEP_X|=$(_cnt "$SWEEP_X") < 7 (unparseable sweep line?)" >&2; }
[ "$(_cnt "$M0673")" -ge 1 ]      || { _g_ok=false; echo "     FAIL-CLOSED: 0673 set empty" >&2; }
[ "$(_cnt "$AUX_X")" -ge 1 ]      || { _g_ok=false; echo "     FAIL-CLOSED: aux map empty" >&2; }
if [ "$_g_ok" = true ]; then
    # 1. coverage
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        if ! _in "$n" "$SWEEP_X" && ! _in "$n" "$AUX_X" && ! _in "$n" "$ALLOW_X"; then
            _g_ok=false; echo "     UNCOVERED: share/scripts/$n is shipped but never refreshed on upgrade — add it to the update_runtime_helpers 'for src in' line AND _xaca0673_mandatory_materialize_basenames, or allowlist it in this test with a reason" >&2
        fi
    done <<< "$SHIPPED_X"
    # 2. sweep entries must be mandatory-materialised
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        _in "$n" "$M0673" || { _g_ok=false; echo "     SWEEP-NOT-MANDATORY: '$n' is in the sweep line but not in _xaca0673_mandatory_materialize_basenames (never reaches pre-existing boxes)" >&2; }
    done <<< "$SWEEP_X"
    # 3. allowlist hygiene
    for n in $ALLOW_X; do
        _in "$n" "$SHIPPED_X" || { _g_ok=false; echo "     STALE-ALLOWLIST: '$n' is no longer shipped" >&2; }
        if _in "$n" "$SWEEP_X" || _in "$n" "$AUX_X"; then _g_ok=false; echo "     STALE-ALLOWLIST: '$n' is now covered by sweep/aux — remove it from the allowlist" >&2; fi
    done
fi
if [ "$_g_ok" = true ]; then test_pass; else test_fail "extensionless upgrade-path coverage guard failed (see messages above)"; fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 8 (XACA-1460-012): TABLE-DRIVEN ADVERSARIAL INPUTS FOR THE PARITY SCAN.
# Runs the TEST 6 scanner ($_SCAN_PY) against a synthetic share/ so every
# reference form is pinned. Per case: with the sibling NOT mandatory the
# guard must report it (offender); with it mandatory the guard must pass.
# Columns (TAB-separated): label, shebang, body line, sibling, expect(hit|miss),
# consumer(yes|no: is kb-fake in the mandatory set, i.e. consumer-delivered).
# ═══════════════════════════════════════════════════════════════════════════
test_start "PARITY scan: adversarial reference forms (table-driven)"
_ADV="$TEST_TMP_DIR/xaca1460-adv/share"
mkdir -p "$_ADV/scripts"
printf '#!/usr/bin/env python3\n' > "$_ADV/scripts/x.py"
printf '#!/usr/bin/env bash\n'    > "$_ADV/scripts/x.sh"
_adv_ok=true
_adv_n=0
while IFS=$'\t' read -r _lbl _sb _body _sib _exp _cons; do
    [ -n "$_lbl" ] || continue
    _adv_n=$((_adv_n + 1))
    printf '%s\n%s\n' "$_sb" "$_body" > "$_ADV/scripts/kb-fake"
    _mset="probe-only"
    [ "$_cons" = yes ] && _mset="kb-fake"
    _found="$(python3 "$_SCAN_PY" "$_ADV" "$_mset")"
    _hit=no
    case $'\n'"$_found"$'\n' in *$'\n'"$_sib"$'\n'*) _hit=yes ;; esac
    if [ "$_exp" = hit ] && [ "$_hit" != yes ]; then
        _adv_ok=false; echo "     ADV[$_lbl]: '$_sib' NOT detected (guard would pass a missing dependency)" >&2
    elif [ "$_exp" = miss ] && [ "$_hit" = yes ]; then
        _adv_ok=false; echo "     ADV[$_lbl]: '$_sib' detected but must not be (false positive)" >&2
    fi
    # Predicate check: offender iff referenced AND not in the mandatory set.
    if [ "$_hit" = yes ]; then
        for _cover in no yes; do
            _m="$_mset"; [ "$_cover" = yes ] && _m="$_m"$'\n'"$_sib"
            case $'\n'"$_m"$'\n' in *$'\n'"$_sib"$'\n'*) _off=no ;; *) _off=yes ;; esac
            if [ "$_cover" = no ] && [ "$_off" != yes ]; then _adv_ok=false; echo "     ADV[$_lbl]: uncovered '$_sib' not an offender" >&2; fi
            if [ "$_cover" = yes ] && [ "$_off" != no ]; then _adv_ok=false; echo "     ADV[$_lbl]: mandatory '$_sib' still an offender" >&2; fi
        done
    fi
done <<'TABLE'
SCRIPT_DIR-braced-py	#!/usr/bin/env bash	WIZARD_PY="${SCRIPT_DIR}/x.py"	x.py	hit	yes
SCRIPT_DIR-bare-sh	#!/usr/bin/env bash	H="$SCRIPT_DIR/x.sh"	x.sh	hit	yes
dirname-0-py	#!/bin/sh	python3 "$(dirname "$0")/x.py"	x.py	hit	yes
source-sh	#!/usr/bin/env bash	source "$DIR/x.sh"	x.sh	hit	yes
dot-source-sh	#!/usr/bin/env bash	. "$DIR/x.sh"	x.sh	hit	yes
single-quoted	#!/usr/bin/env bash	f='x.py'	x.py	hit	yes
double-quoted	#!/usr/bin/env bash	f="x.py"	x.py	hit	yes
commented-out	#!/usr/bin/env bash	# source "$DIR/x.sh"	x.sh	miss	yes
indented-comment	#!/usr/bin/env bash	    # NEVER invoke x.sh here	x.sh	miss	yes
substring-only	#!/usr/bin/env bash	f="$DIR/prefix-x.sh.bak"	x.sh	miss	yes
python-shebang	#!/usr/bin/env python3	p = os.path.join(d, "x.py")	x.py	hit	no
dev-only-shell	#!/usr/bin/env bash	source "$DIR/x.sh"	x.sh	miss	no
TABLE
[ "$_adv_n" -ge 12 ] || { _adv_ok=false; echo "     FAIL-CLOSED: adversarial table ran $_adv_n case(s), expected 12" >&2; }
if [ "$_adv_ok" = true ]; then test_pass; else test_fail "PARITY scan adversarial table failed (see ADV[...] above)"; fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
