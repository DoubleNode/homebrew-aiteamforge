#!/bin/bash
# test-xaca-1231-finance-logos.sh
#
# XACA-1231: finance shipped NO tap-side terminal logos at all
# (share/terminals/finance/logos/ did not exist prior to this ticket), so
# every consumer's LCARS 404'd on /images/finance_*_logo.png regardless of
# install method. Two defects, fixed together:
#   1. The tap never shipped share/terminals/finance/logos/*.png (this
#      commit adds the 6 files: finance_{bar,fca,lcars,nagus,vault,workshop}
#      _logo.png).
#   2. dev-team's OWN canonical finance/terminals/logos/*.png (the source
#      these were mirrored from) were 1024x1024 byte-identical copies of
#      their originals/ masters -- unlike every other team's 256x256
#      deployed convention -- so even a correct mirror would have shipped
#      4x-oversized logos. Regenerated via `sips -Z 256` in the outer repo;
#      originals/ masters untouched.
#
# MEASURED baseline (tap commit d1d57eb, this ticket's parent):
#   `git show d1d57eb:share/terminals/finance` -> fatal: path exists on
#   disk but not in d1d57eb (share/terminals/finance did not exist at all).
#   share/personas/finance/ DID exist there (40 files: agents + avatars) --
#   finance was a registered team, just missing its logo asset class.
#
# This suite proves CONSUMER DELIVERY (not just presence in share/), with
# cases that FAIL against the pre-fix baseline:
#   (a) shipped content: exactly 6 PNGs, each 256x256 (dimensions read via
#       a portable IHDR parse -- od -tx1, NOT sips, because tap CI can run
#       on Linux runners where sips does not exist)
#   (b) class guard: every team shipping share/personas/<t>/avatars/*.png
#       also ships share/terminals/<t>/logos/*.png, and every shipped
#       *_logo.png is <=256px on both axes -- so the NEXT team can't repeat
#       either half of this defect silently. Measured over the whole
#       shipped share/ tree; see the printed table.
#   (c) setup delivery: the production copy loop in bin/aiteamforge-setup.sh
#       (same extraction anchors as test-xaca-1212-setup-missing-avatars.sh)
#       lands all 6 files under INSTALL_DIR/finance/terminals/logos,
#       byte-identical to share, when run against the REAL share/ tree.
#   (d) upgrade delivery: update_team_image_assets (same extraction
#       technique as test-xaca-1221-upgrade-image-assets.sh) refreshes all 6
#       into an existing finance/ WORKING_DIR on first run, then reports
#       them current (0 written) on a second run.
#   (e) negative control: the SAME (c)/(d) drills run against the pinned
#       pre-fix baseline (tap ref d1d57eb, share/ tree extracted via
#       `git archive`) must deliver ZERO finance logos -- proving (c)/(d)
#       are not vacuously true.
#
# SHELL: run explicitly under BOTH /bin/bash (3.2) and Homebrew/PATH bash
# (5.x) -- see the file's own "Interpreter under test" line -- and via
# tests/test-runner.sh (manifest-driven, XACA-0707) like every other
# plain-shell suite.
#
# Pre-fix proof (case a/b would fail; c/d/e collapse to a single vacuous
# "zero everywhere" run): check out this file's own tests/ dir against tap
# ref d1d57eb (share/terminals/finance/logos does not exist there at all).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_REF="${XACA1231_PRECHANGE_REF:-d1d57eb}"

echo ""
echo "Interpreter under test: ${BASH:-/bin/sh} (${BASH_VERSION:-unknown})"

# ── Sandbox first ────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1231-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
export TEST_TMP_DIR
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then rm -rf "$TEST_TMP_DIR"; fi; }
trap cleanup EXIT

_next_sandbox() { mktemp -d "$TEST_TMP_DIR/sbx-XXXXXX"; }

# ── Framework (standalone or sourced by test-runner.sh) ─────────────────
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
# PR #907 review (XACA-1231-013): this used to define test_skip
# UNCONDITIONALLY, which SHADOWED test-runner.sh's own exported test_skip
# (it exports test_start/test_pass/test_fail/test_skip together — see its
# `export -f` line) whenever this suite ran under the runner, not just in
# standalone mode. A skip in the (e) negative control therefore printed a
# line but was invisible to the runner's own SKIP accounting (no "SKIP:"
# marker ever reached TEST_RESULTS_FILE), so a CI run where the control
# never executed still reported fully green. Guard it like the other three
# so the runner's own version wins whenever one is present. As of this fix
# nothing in this suite calls test_skip any more (see (e) below — the
# negative control now always runs, ref or synthesized, never skips), but
# the guard stays as defense-in-depth against a future call site
# reintroducing the same shadowing bug.
if ! type -t test_skip >/dev/null 2>&1; then
    _SKIP_COUNT=0
    test_skip() { _SKIP_COUNT=$((_SKIP_COUNT + 1)); echo "     SKIP (not a pass): $_CURRENT_TEST -- $1"; }
fi

EXPECTED_LOGOS="finance_bar_logo.png finance_fca_logo.png finance_lcars_logo.png finance_nagus_logo.png finance_vault_logo.png finance_workshop_logo.png"

# ── Portable PNG IHDR dimension reader — od, NOT sips (tap CI runs Linux
# runners too). PNG signature is 8 bytes; the first chunk is always IHDR:
# bytes 8-11 = chunk length, 12-15 = "IHDR", 16-19 = width (big-endian
# uint32), 20-23 = height. Prints "WIDTHxHEIGHT" or nothing on failure. ──
_png_dims() {
    local f="$1" magic hex w h
    magic="$(od -An -tx1 -N 8 "$f" 2>/dev/null | tr -d ' \n')"
    [ "$magic" = "89504e470d0a1a0a" ] || return 1
    hex="$(od -An -tx1 -j 16 -N 8 "$f" 2>/dev/null | tr -d ' \n')"
    [ "${#hex}" -eq 16 ] || return 1
    w=$((16#${hex:0:8}))
    h=$((16#${hex:8:8}))
    printf '%dx%d' "$w" "$h"
}

# ── Setup-loop extraction (identical anchors to test-xaca-1212) ─────────
SETUP_SH="${SETUP_SH:-$TAP_ROOT/bin/aiteamforge-setup.sh}"
_build_setup_loop() {
    local out="$1"
    awk '
        /^_personas_copied=0$/ { p=1 }
        p { print }
        p && /^\[ \$_logos_copied -gt 0 \]/ { exit }
    ' "$SETUP_SH" > "$out"
    grep -q '^for team_id in "\${SELECTED_TEAMS\[@\]}"; do$' "$out" \
        && grep -q 'share/personas/\${team_id}/avatars/' "$out" \
        && grep -q '^\[ \$_logos_copied -gt 0 \]' "$out" && "${BASH:-/bin/bash}" -n "$out"
}

# _run_setup_loop <AITEAMFORGE_HOME> <INSTALL_DIR> <team...> — runs the
# extracted production loop under set -eo pipefail, matching aiteamforge-setup.sh.
_run_setup_loop() {
    local home="$1" install="$2"; shift 2
    "${BASH:-/bin/bash}" -c '
        set -eo pipefail
        AITEAMFORGE_HOME="$1"; INSTALL_DIR="$2"; INSTALL_PROFILE=full
        GREEN=""; NC=""
        shift 2
        SELECTED_TEAMS=("$@")
        . "'"$SETUP_LOOP_FILE"'"
        echo "LOOP_COMPLETED personas=$_personas_copied logos=$_logos_copied"
    ' _ "$home" "$install" "$@"
}

# ── Upgrade-function extraction (identical anchors/technique to
# test-xaca-1221) ─────────────────────────────────────────────────────────
UPGRADE_ABS="${UPGRADE_SH:-$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh}"
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$2"
}
_build_upgrade_fns() {
    local out="$1" fn src
    : > "$out"
    for fn in update_team_image_assets _xaca0925_valid_team_id; do
        src="$(_extract_fn "$fn" "$UPGRADE_ABS")"
        [ -n "$src" ] || return 1
        printf '%s\n\n' "$src" >> "$out"
    done
}

# _run_upgrade_fn <FRAMEWORK_DIR> <WORKING_DIR> <out> [dry]
_run_upgrade_fn() {
    local fw="$1" wd="$2" out="$3" dry="${4:-false}" rc=0
    ( set -eo pipefail
      for _p in print_section print_info print_success print_warning print_error; do
          eval "${_p}() { printf '%s: %s\n' ${_p} \"\$*\"; }"
      done
      # shellcheck disable=SC1090
      . "$UPGRADE_FNS_FILE"
      FRAMEWORK_DIR="$fw"
      WORKING_DIR="$wd"
      DRY_RUN="$dry"
      update_team_image_assets
      echo "FN_RC=$?"
      echo "CONTINUED_PAST_CALL"
    ) >"$out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "=== (a) shipped content: exactly 6 finance logos, each 256x256 ==="

LOGO_DIR="$TAP_ROOT/share/terminals/finance/logos"
test_start "A1: share/terminals/finance/logos exists"
if [ -d "$LOGO_DIR" ]; then test_pass; else test_fail "missing: $LOGO_DIR"; fi

_shipped="$(ls "$LOGO_DIR"/*.png 2>/dev/null | xargs -n1 basename 2>/dev/null | sort | tr '\n' ' ')"
_expected_sorted="$(printf '%s\n' $EXPECTED_LOGOS | sort | tr '\n' ' ')"
test_start "A2: exactly the 6 expected finance logo filenames are shipped (no more, no fewer)"
if [ "$_shipped" = "$_expected_sorted" ]; then
    test_pass
else
    test_fail "shipped=[$_shipped] expected=[$_expected_sorted]"
fi

_bad_dims=""
for f in $EXPECTED_LOGOS; do
    d="$(_png_dims "$LOGO_DIR/$f" 2>/dev/null)"
    [ "$d" = "256x256" ] || _bad_dims="${_bad_dims}${_bad_dims:+, }$f=[${d:-unreadable}]"
done
test_start "A3: all 6 shipped finance logos are exactly 256x256 (portable IHDR read, no sips)"
if [ -z "$_bad_dims" ]; then test_pass; else test_fail "wrong dims: $_bad_dims"; fi

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "=== (b) class guard: avatars-imply-logos + <=256px, measured across ALL shipped teams ==="

echo "     team           avatars  logos  logo_dims_ok"
_pairing_violations=""
_size_violations=""
for d in "$TAP_ROOT"/share/personas/*/; do
    t="$(basename "$d")"
    n_av=$(ls "$d/avatars/"*.png 2>/dev/null | wc -l | tr -d ' ')
    n_lg=$(ls "$TAP_ROOT/share/terminals/$t/logos/"*.png 2>/dev/null | wc -l | tr -d ' ')
    dims_ok="n/a"
    if [ "$n_lg" -gt 0 ]; then
        dims_ok="yes"
        for f in "$TAP_ROOT/share/terminals/$t/logos/"*.png; do
            dd="$(_png_dims "$f" 2>/dev/null)"
            w="${dd%x*}"; h="${dd#*x}"
            if [ -z "$dd" ] || [ "$w" -gt 256 ] 2>/dev/null || [ "$h" -gt 256 ] 2>/dev/null; then
                dims_ok="NO ($f=${dd:-unreadable})"
                _size_violations="${_size_violations}${_size_violations:+, }$t:$(basename "$f")=${dd:-unreadable}"
            fi
        done
    fi
    # A team shipping neither avatars nor logos has nothing to pair; label it
    # from the measurement rather than a hard-coded team list (XACA-1232
    # started shipping dns assets while this test was in flight, which made a
    # hard-coded "dns ships neither" row print a false claim).
    _note=""
    [ "$n_av" -eq 0 ] && [ "$n_lg" -eq 0 ] && _note="  (ships neither -- nothing to pair)"
    printf "     %-14s %-8s %-6s %s%s\n" "$t" "$n_av" "$n_lg" "$dims_ok" "$_note"
    if [ "$n_av" -gt 0 ] && [ "$n_lg" -eq 0 ]; then
        # Explicit allowlist point (XACA-1231): as of this measurement, no
        # team ships avatars without also shipping logos. Add an entry here
        # with a reason (never a silent skip) if that ever legitimately
        # changes -- e.g.:
        #   case "$t" in
        #     someteam) continue ;;  # reason: <ticket>, <why>
        #   esac
        _pairing_violations="${_pairing_violations}${_pairing_violations:+, }$t (avatars=$n_av logos=0)"
    fi
done

test_start "B1: every team shipping persona avatars also ships terminal logos (no silent gap)"
if [ -z "$_pairing_violations" ]; then
    test_pass
else
    test_fail "teams with avatars but zero logos: $_pairing_violations"
fi

test_start "B2: every shipped *_logo.png is <=256px on both axes"
if [ -z "$_size_violations" ]; then
    test_pass
else
    test_fail "oversized logos: $_size_violations"
fi

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "=== (c) setup delivery: production copy loop, REAL share/ tree, team=finance ==="

SETUP_LOOP_FILE="$TEST_TMP_DIR/copy-loop.sh"
_build_setup_loop "$SETUP_LOOP_FILE"; r=$?
test_start "C0: extracted the production persona/logo copy loop ($(grep -c . "$SETUP_LOOP_FILE" 2>/dev/null) lines)"
if [ "$r" -eq 0 ]; then test_pass; else test_fail "anchors missing — loop empty or truncated"; fi

INSTALL_C="$(_next_sandbox)"
OUT_C="$TEST_TMP_DIR/setup-c.out"
_run_setup_loop "$TAP_ROOT" "$INSTALL_C" finance > "$OUT_C" 2>&1
RC_C=$?

test_start "C1: setup loop completes against the real share/ tree for team=finance"
if [ "$RC_C" -eq 0 ] && grep -q 'LOOP_COMPLETED personas=1 logos=1' "$OUT_C"; then
    test_pass
else
    test_fail "rc=$RC_C out=[$(tr '\n' '|' < "$OUT_C")]"
fi

_missing=""; _mismatch=""
for f in $EXPECTED_LOGOS; do
    dst="$INSTALL_C/finance/terminals/logos/$f"
    src="$LOGO_DIR/$f"
    if [ ! -f "$dst" ]; then
        _missing="${_missing}${_missing:+, }$f"
    elif ! cmp -s "$src" "$dst"; then
        _mismatch="${_mismatch}${_mismatch:+, }$f"
    fi
done
test_start "C2: all 6 finance logos land in INSTALL_DIR/finance/terminals/logos, byte-identical to share"
if [ -z "$_missing" ] && [ -z "$_mismatch" ]; then
    test_pass
else
    test_fail "missing=[$_missing] mismatched=[$_mismatch]"
fi

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "=== (d) upgrade delivery: update_team_image_assets, existing finance/ WORKING_DIR ==="

UPGRADE_FNS_FILE="$TEST_TMP_DIR/upgrade-fns.sh"
_build_upgrade_fns "$UPGRADE_FNS_FILE"; r=$?
test_start "D0: extracted update_team_image_assets / _xaca0925_valid_team_id from aiteamforge-upgrade.sh"
if [ "$r" -eq 0 ]; then test_pass; else test_fail "could not extract from $UPGRADE_ABS"; fi

# Scoped FRAMEWORK_DIR: real finance logo BYTES (cp -p from the clone, not
# fixture placeholders), but WITHOUT finance's 30 persona avatars in the
# source tree -- avatar delivery is XACA-1221's own suite's scope; scoping
# here keeps the written/current counts exactly attributable to the 6 logo
# files this ticket is about, rather than diluted by an unrelated asset
# class that happens to share the same team.
ROOT_D="$(_next_sandbox)"
mkdir -p "$ROOT_D/fw/share/terminals/finance/logos" "$ROOT_D/aiteamforge/finance"
cp -p "$LOGO_DIR"/*.png "$ROOT_D/fw/share/terminals/finance/logos/"

OUT_D1="$TEST_TMP_DIR/upgrade-d1.out"
RC_D1="$(_run_upgrade_fn "$ROOT_D/fw" "$ROOT_D/aiteamforge" "$OUT_D1")"

# update_team_image_assets counts WRITTEN per (file, destination) pair, not
# per file -- each of the 6 logos has 2 destinations (per-team dir + flat
# avatars pool), matching test-xaca-1221's own documented convention
# ("2 files * 2 destinations ... = 4 written for teamA"). 6 files * 2 = 12.
test_start "D1: first run against a real-bytes FRAMEWORK_DIR writes all 6 logos to both destinations (1 team, 12 written, 0 current, 0 failed)"
if [ "$RC_D1" = "0" ] && grep -q '^FN_RC=0$' "$OUT_D1" \
    && grep -q '^print_success: Team image assets: 1 team(s): 12 written, 0 current, 0 failed$' "$OUT_D1"; then
    test_pass
else
    test_fail "rc=$RC_D1 out=[$(tr '\n' '|' < "$OUT_D1")]"
fi

_missing=""; _mismatch=""
for f in $EXPECTED_LOGOS; do
    for dst in "$ROOT_D/aiteamforge/finance/terminals/logos/$f" "$ROOT_D/aiteamforge/avatars/$f"; do
        if [ ! -f "$dst" ]; then
            _missing="${_missing}${_missing:+, }$dst"
        elif ! cmp -s "$LOGO_DIR/$f" "$dst"; then
            _mismatch="${_mismatch}${_mismatch:+, }$dst"
        fi
    done
done
test_start "D2: all 6 logos written to BOTH the per-team dir and the flat avatars pool, byte-identical to share"
if [ -z "$_missing" ] && [ -z "$_mismatch" ]; then
    test_pass
else
    test_fail "missing=[$_missing] mismatched=[$_mismatch]"
fi

OUT_D2="$TEST_TMP_DIR/upgrade-d2.out"
RC_D2="$(_run_upgrade_fn "$ROOT_D/fw" "$ROOT_D/aiteamforge" "$OUT_D2")"
test_start "D3: second run on an already-refreshed root reports them current (0 written, 12 current, 0 failed)"
if [ "$RC_D2" = "0" ] && grep -q '^print_success: Team image assets: 1 team(s): 0 written, 12 current, 0 failed$' "$OUT_D2"; then
    test_pass
else
    test_fail "rc=$RC_D2 out=[$(tr '\n' '|' < "$OUT_D2")]"
fi

# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "=== (e) negative control: pre-fix baseline ($BASELINE_REF) delivers ZERO finance logos ==="

# PR #907 review (XACA-1231-013): E0-E3 used to SKIP entirely when
# BASELINE_REF was unreachable -- exactly the case on tap CI's depth-1
# checkout (d1d57eb is not fetched), where the skip (compounded by the
# test_skip-shadowing bug fixed above) made the whole suite report green
# with the negative control never having run at all. The control must
# ALWAYS execute. When the pinned ref IS reachable (a full/deep local
# clone), use it -- git history is the strongest evidence. When it is NOT
# (shallow CI checkout, or an override pointing nowhere), SYNTHESIZE the
# pre-fix baseline instead of skipping: the measured pre-fix state is
# exactly "share/terminals/finance does not exist" (confirmed when the ref
# WAS reachable: `git show d1d57eb:share/terminals/finance` ->
# "fatal: path exists on disk but not in d1d57eb" -- finance had personas
# there already, just no terminal-logo asset class), so a synthesized
# baseline is built by copying the ENTIRE current share/ tree (files AND
# dirs -- an earlier draft of this fix globbed only `share/*/`, which
# silently dropped share/CHANGELOG.md and share/requirements.txt, two real
# top-level FILES under share/; caught by an independent post-hoc diff
# against the real tree, not by this suite's own assertions, since neither
# missing file affects (c)/(d)'s finance-scoped checks -- worth fixing
# anyway so "synthesized" means the whole tree, not just what this ticket
# happens to touch) and then relocating (never deleting) share/terminals/
# finance out of the copy with `mv`, so nothing needs `rm -rf`.
BASELINE_DIR="$TEST_TMP_DIR/baseline"
mkdir -p "$BASELINE_DIR/share"
BASELINE_MODE=""

test_start "E0: pre-fix negative-control baseline is available AND populated (ref or synthesized -- this must never skip)"
_e0_rc=0
if git -C "$TAP_ROOT" cat-file -e "${BASELINE_REF}^{commit}" 2>/dev/null; then
    BASELINE_MODE="ref:$BASELINE_REF"
    # Capture the archive's own status: under a plain pipe only tar's exit
    # would be seen, and an empty/failed archive would leave an empty
    # baseline that makes E1/E3 pass for the wrong reason (PR #907 review
    # round 2, XACA-1231-015).
    git -C "$TAP_ROOT" archive -o "$TEST_TMP_DIR/baseline.tar" "$BASELINE_REF" share || _e0_rc=$?
    [ "$_e0_rc" -eq 0 ] && { tar -x -C "$BASELINE_DIR" -f "$TEST_TMP_DIR/baseline.tar" || _e0_rc=$?; }
else
    BASELINE_MODE="synthesized (ref $BASELINE_REF unreachable in this clone -- shallow/depth-1 checkout?)"
    cp -R "$TAP_ROOT/share/." "$BASELINE_DIR/share/" || _e0_rc=$?
    if [ "$_e0_rc" -eq 0 ] && [ -d "$BASELINE_DIR/share/terminals/finance" ]; then
        mkdir -p "$TEST_TMP_DIR/synth-excluded"
        mv "$BASELINE_DIR/share/terminals/finance" "$TEST_TMP_DIR/synth-excluded/finance-terminals" || _e0_rc=$?
    fi
fi
# Positive anchors: both held at the pre-fix ref (d1d57eb) and hold in any
# synthesized baseline -- another team's logos and finance's own personas.
# An empty or half-extracted baseline cannot satisfy them.
if [ "$_e0_rc" -ne 0 ]; then
    test_fail "baseline build failed (rc=$_e0_rc, mode: $BASELINE_MODE)"
elif ! ls "$BASELINE_DIR/share/terminals/academy/logos/"*.png >/dev/null 2>&1; then
    test_fail "baseline has no share/terminals/academy/logos/*.png -- not a real share/ tree (mode: $BASELINE_MODE)"
elif ! ls "$BASELINE_DIR/share/personas/finance/avatars/"*.png >/dev/null 2>&1; then
    test_fail "baseline has no share/personas/finance/avatars/*.png -- not a real share/ tree (mode: $BASELINE_MODE)"
else
    test_pass
fi
echo "     E0 mode: $BASELINE_MODE"

{
    test_start "E1: baseline share/ tree does NOT already ship finance logos (control must not be vacuous)"
    if [ -d "$BASELINE_DIR/share/terminals/finance/logos" ] \
        && ls "$BASELINE_DIR/share/terminals/finance/logos/"*.png >/dev/null 2>&1; then
        test_fail "NEGATIVE CONTROL VACUOUS: baseline ($BASELINE_MODE) already ships finance logos -- point XACA1231_PRECHANGE_REF at an earlier ref"
    else
        test_pass
    fi

    # (c)-equivalent against the baseline tree. SELECTED_TEAMS includes
    # "academy" (which DOES ship logos in the baseline) alongside finance --
    # not to test academy, but because the production loop's own tail line
    # (`[ $_logos_copied -gt 0 ] && echo ...`) is the LAST statement of the
    # sourced file: if finance were the ONLY selected team, _logos_copied
    # stays 0, that line's exit status is 1, and under `set -eo pipefail`
    # that trips errexit on exit from the sourced script (same class as the
    # XACA-1212 gotcha these two suites already guard, just via the
    # tail-line-under-set–e shape rather than an unguarded glob) -- a
    # single-team-with-zero-logos SELECTED_TEAMS is not a real installer
    # scenario (every real install selects the full team set, which always
    # has at least one team with logos) and is purely an artifact of scoping
    # this drill to one team, not a finding about production code.
    INSTALL_E="$(_next_sandbox)"
    OUT_E="$TEST_TMP_DIR/setup-e.out"
    _run_setup_loop "$BASELINE_DIR" "$INSTALL_E" finance academy > "$OUT_E" 2>&1
    RC_E=$?
    _e2_finance_logos="$(find "$INSTALL_E/finance/terminals/logos" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
    # MEASURED (universal, pre-existing convention -- NOT a XACA-1231 defect):
    # every team's terminal-logo basename collides 1:1 with a persona-avatar
    # basename of the same name (9/10 teams with logos, 100% overlap;
    # `finance_lcars_logo.png` is both a persona avatar filename AND a
    # terminal logo filename, same as every other team). The flat pool is a
    # single shared namespace by basename, so it can legitimately already
    # contain a "finance_bar_logo.png" etc. at baseline -- sourced from the
    # PERSONA avatar, never a terminal logo (baseline ships no finance
    # terminal logos at all). The correct negative-control assertion is
    # therefore content-based: no pool file may carry the TERMINAL LOGO
    # bytes, not "the pool contains zero files with these names".
    _e2_pool_leak=""
    for f in $EXPECTED_LOGOS; do
        poolf="$INSTALL_E/avatars/$f"
        [ -f "$poolf" ] && cmp -s "$poolf" "$LOGO_DIR/$f" && _e2_pool_leak="${_e2_pool_leak}${_e2_pool_leak:+, }$f"
    done
    test_start "E2: setup loop against the baseline share/ tree delivers ZERO finance TERMINAL logos (academy included so the loop's own tail line doesn't short-circuit)"
    if [ "$RC_E" -eq 0 ] && grep -q 'LOOP_COMPLETED' "$OUT_E" \
        && [ "$_e2_finance_logos" = "0" ] && [ -z "$_e2_pool_leak" ] \
        && [ -f "$INSTALL_E/academy/terminals/logos/academy_lcars_logo.png" ]; then
        test_pass
    else
        test_fail "rc=$RC_E finance_logos=$_e2_finance_logos pool_terminal_logo_bytes_leaked=[$_e2_pool_leak] academy_landed=$([ -f "$INSTALL_E/academy/terminals/logos/academy_lcars_logo.png" ] && echo yes || echo no) out=[$(tr '\n' '|' < "$OUT_E")]"
    fi

    # (d)-equivalent against the baseline tree
    ROOT_E2="$(_next_sandbox)"
    mkdir -p "$ROOT_E2/fw/share" "$ROOT_E2/aiteamforge/finance"
    cp -R "$BASELINE_DIR/share/." "$ROOT_E2/fw/share/"
    OUT_E2="$TEST_TMP_DIR/upgrade-e.out"
    RC_E2="$(_run_upgrade_fn "$ROOT_E2/fw" "$ROOT_E2/aiteamforge" "$OUT_E2")"
    _e3_finance_logos="$(find "$ROOT_E2/aiteamforge/finance/terminals/logos" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
    # Same collision-aware content check as E2 above.
    _e3_pool_leak=""
    for f in $EXPECTED_LOGOS; do
        poolf="$ROOT_E2/aiteamforge/avatars/$f"
        [ -f "$poolf" ] && cmp -s "$poolf" "$LOGO_DIR/$f" && _e3_pool_leak="${_e3_pool_leak}${_e3_pool_leak:+, }$f"
    done
    test_start "E3: upgrade fn against the baseline FRAMEWORK_DIR delivers ZERO finance TERMINAL logos"
    if [ "$RC_E2" = "0" ] && [ "$_e3_finance_logos" = "0" ] && [ -z "$_e3_pool_leak" ]; then
        test_pass
    else
        test_fail "rc=$RC_E2 finance_logos=$_e3_finance_logos pool_terminal_logo_bytes_leaked=[$_e3_pool_leak] out=[$(tr '\n' '|' < "$OUT_E2")]"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
if [ "${_STANDALONE:-false}" != true ] && [ -n "${TEST_RESULTS_FILE:-}" ] && [ -f "${TEST_RESULTS_FILE}" ]; then
    _x1231_fail_lines="$(grep '^FAIL:' "$TEST_RESULTS_FILE" 2>/dev/null || true)"
    if [ -n "$_x1231_fail_lines" ]; then
        echo "─── XACA-1231 failure detail ───"
        printf '%s\n' "$_x1231_fail_lines"
    fi
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed, ${_SKIP_COUNT} skipped"
    [ "$_FAIL_COUNT" -eq 0 ]
fi
