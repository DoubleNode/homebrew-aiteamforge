#!/bin/bash
# test-xaca-1102-never-upgraded-stamp.sh
#
# XACA-1102: `.installed-version` was written ONLY by `aiteamforge upgrade`,
# never by the installer. A box that was installed and never upgraded had no
# stamp, and every reader fell back to weaker sources (the install-time config
# "version", or brew).
#
# WHY THE EXISTING GATE COULD NOT CATCH IT: XACA-0704's gate builds a box that
# is ONE VERSION BEHIND and runs `upgrade` on it. Upgrade is the only path that
# ever wrote the stamp, so that gate can never fail on "the stamp is absent".
# THIS SUITE'S FIXTURE IS A NEVER-UPGRADED BOX: an installed working dir
# (.aiteamforge-config with a "version", .install-profile, NO .installed-version)
# that has never seen `upgrade`. No fixture here is ever built by running upgrade.
#
# Checks:
#   I1  install path: the REAL stamp block of bin/aiteamforge-setup.sh, run in a
#       sandbox, leaves a stamp EQUAL to the config "version" it is paired with
#   I1b the stamp block sits AFTER the .install-profile write and uses ${VERSION}
#   I1c a failing stamp write is non-fatal for the install (warns, rc 0)
#   B1  backfill: never-upgraded box (config 0.11.6, VERSION file 0.21.15) -> stamp
#       is exactly 0.11.6 (NOT the cellar value), stdout empty, rc 0
#   B1b same with jq absent (grep/sed branch)
#   B2  backfill never overwrites an existing stamp (content AND mtime)
#   B3  backfill with no config / no "version" / garbage version -> no stamp, rc 0
#   G1  get_installed_version: brew masked, no stamp, config version present
#       -> "unknown" (source 3 retired)
#   G2  get_installed_version: with a stamp -> the stamp value
#   C1  CLI entry point (bin/aiteamforge-cli.sh version) seeds the stamp
#   C2  CLI does not invent a stamp when the config has no version
#   D1  doctor check_version_drift, no stamp + no config version -> FAIL text,
#       not the old "run ... upgrade ... to stamp" advice, FAILED_CHECKS=1
#   D2  doctor check_version_drift after backfill (stamp 0.11.6, cellar 0.21.15)
#       -> reports drift (warn), names both versions, FAILED_CHECKS=0
#   D3  stamp == cellar -> pass
#
# Doctor note: check_version_drift (and check_result) are extracted from
# aiteamforge-doctor.sh and driven directly. The full doctor needs a real
# framework tree, tmux, launchctl and brew, none of which a sandboxed test may touch.
# Setup note: bin/aiteamforge-setup.sh is an interactive wizard that installs
# brew dependencies, writes LaunchAgents and touches the real shell profile, so
# it cannot be driven safely in a sandbox. I1 therefore extracts and runs the
# EXACT stamp block from the production script (plus the production
# `"version": "${VERSION}"` config line it is paired with) rather than a copy.
#
# Sandboxed: HOME, AITEAMFORGE_DIR and TMPDIR all point under TEST_TMP_DIR, every
# child runs under `env -i` with a PATH that has no brew. Never touches the real
# $HOME or ~/aiteamforge.

# shellcheck disable=SC2016,SC2329  # single-quoted programs are deliberate (expanded in the child); cleanup runs via trap
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SH="$TAP_ROOT/bin/aiteamforge-setup.sh"
CLI_SH="$TAP_ROOT/bin/aiteamforge-cli.sh"
DOCTOR_SH="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"
IV_LIB="$TAP_ROOT/libexec/lib/installed-version.sh"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
COMMON_LIB="$TAP_ROOT/libexec/lib/common.sh"

for _need in "$SETUP_SH" "$CLI_SH" "$DOCTOR_SH" "$IV_LIB" "$CONFIG_LIB" "$COMMON_LIB"; do
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

# Never let a caller's git/tmux context leak into the fixtures.
unset GIT_DIR GIT_WORK_TREE TMUX TMUX_PANE

if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1102-stamp.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() {
    if [ -n "${W:-}" ] && [ -d "${W:-}" ]; then
        find "$W" -depth -delete 2>/dev/null || true
    fi
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Sandbox BEFORE anything is sourced.
export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
# A FRESH per-run dir even under a caller-supplied TEST_TMP_DIR: fixtures from a
# previous run in the same dir must not leak in (XACA-1102-020). Nothing the
# caller owns is deleted; our own subdir is removed on exit.
W="$(mktemp -d "$TEST_TMP_DIR/xaca1102.XXXXXX")"
SANDBOX_HOME="$W/home"
mkdir -p "$SANDBOX_HOME" "$W/tmp"

# Bash under test: whichever bash runs this suite (so each bash version tests itself).
BASHBIN="${BASH:-/bin/bash}"

# PATH with the tools the code under test needs and NO brew.
NOBREW_BIN="$W/bin-nobrew"
NOJQ_BIN="$W/bin-nobrew-nojq"
mkdir -p "$NOBREW_BIN" "$NOJQ_BIN"
for _t in tr sed grep head cat rm awk dirname basename mktemp mv chmod mkdir touch stat date ln cut sort wc env; do
    _p="$(command -v "$_t" 2>/dev/null)"
    case "$_p" in /*) ln -sf "$_p" "$NOBREW_BIN/$_t"; ln -sf "$_p" "$NOJQ_BIN/$_t" ;; esac
done
_jq="$(command -v jq 2>/dev/null)"
case "$_jq" in /*) ln -sf "$_jq" "$NOBREW_BIN/jq" ;; esac
if [ -e "$NOBREW_BIN/brew" ] || [ -e "$NOJQ_BIN/brew" ] || [ -e "$NOJQ_BIN/jq" ]; then
    echo "FATAL: masked PATH is not masked" >&2
    exit 1
fi

_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# Run a bash program in a hermetic child. $1 = PATH dir, $2 = AITEAMFORGE_DIR,
# rest = bash -c program (read args via env: XA/XB/XC...). Extra env passed by
# caller as exported XV_* variables is forwarded explicitly below.
_run() {
    local pathdir="$1" adir="$2" prog="$3"
    env -i HOME="$SANDBOX_HOME" TMPDIR="$W/tmp" PATH="$pathdir" \
        AITEAMFORGE_DIR="$adir" AITEAMFORGE_HOME="${XV_HOME:-$TAP_ROOT}" \
        XV_VERSION="${XV_VERSION:-}" XV_TAP="$TAP_ROOT" XV_BLOCK="${XV_BLOCK:-}" \
        XV_DOCTOR="$DOCTOR_SH" \
        "$BASHBIN" -c "$prog"
}

# A NEVER-UPGRADED installed working dir: config with "version", .install-profile,
# NO .installed-version. $1 = dir, $2 = config version ("" = no version key).
mk_never_upgraded() {
    local dir="$1" ver="$2"
    mkdir -p "$dir"
    if [ -n "$ver" ]; then
        printf '{\n  "version": "%s",\n  "install_dir": "%s",\n  "install_profile": "full"\n}\n' "$ver" "$dir" > "$dir/.aiteamforge-config"
    else
        printf '{\n  "install_dir": "%s",\n  "install_profile": "full"\n}\n' "$dir" > "$dir/.aiteamforge-config"
    fi
    printf '%s\n' "full" > "$dir/.install-profile"
}

# A fake framework (the "cellar") whose VERSION differs from the install-time one.
FAKE_FW="$W/cellar/libexec"
mkdir -p "$FAKE_FW/libexec/lib"
ln -sf "$IV_LIB" "$FAKE_FW/libexec/lib/installed-version.sh"
printf '0.21.15\n' > "$FAKE_FW/VERSION"

_extract_fn() {
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}

BACKFILL_PROG='. "$XV_TAP/libexec/lib/installed-version.sh"; aitf_backfill_installed_version'

# ═══════════════════════════════════════════════════════════════════════════
# I1 — install path (real stamp block extracted from the setup script)
# ═══════════════════════════════════════════════════════════════════════════
STAMP_BLOCK="$(awk '
  /^# XACA-1102: stamp the installed version/ { cap=1 }
  cap && /^# ═/ { exit }
  cap { print }
' "$SETUP_SH")"
CFG_LINE="$(grep -m1 '^  "version": "\${VERSION}",$' "$SETUP_SH")"
FIND_VERSION_FN="$(grep -m1 '^_find_version()' "$SETUP_SH")"

test_start "I1: installer stamp block leaves .installed-version EQUAL to the config \"version\" (never-upgraded install)"
if [ -z "$STAMP_BLOCK" ] || [ -z "$CFG_LINE" ] || [ -z "$FIND_VERSION_FN" ]; then
    test_fail "could not extract the stamp block / config version line / _find_version from aiteamforge-setup.sh (block=${#STAMP_BLOCK} cfg=${#CFG_LINE} fn=${#FIND_VERSION_FN})"
else
    I1_DIR="$W/i1/aiteamforge"
    mkdir -p "$I1_DIR"
    {
        printf '%s\n' "$FIND_VERSION_FN" 'VERSION="$(_find_version)"' 'INSTALL_DIR="$AITEAMFORGE_DIR"' "GREEN=''; YELLOW=''; NC=''"
        # The production config line, expanded by the production ${VERSION}.
        printf '%s\n' 'cat > "${INSTALL_DIR}/.aiteamforge-config" <<CFGEOF' '{' "$CFG_LINE" '  "install_dir": "x"' '}' 'CFGEOF'
        printf '%s\n' 'printf "%s\n" full > "${INSTALL_DIR}/.install-profile"'
        printf '%s\n' "$STAMP_BLOCK"
    } > "$W/i1-block.sh"
    _out="$(XV_HOME="$FAKE_FW" XV_BLOCK="$W/i1-block.sh" _run "$NOBREW_BIN" "$I1_DIR" '. "$XV_BLOCK"' 2>&1)"
    _rc=$?
    _cfgv="$(jq -r '.version' "$I1_DIR/.aiteamforge-config" 2>/dev/null)"
    _stamp="$(cat "$I1_DIR/.installed-version" 2>/dev/null)"
    if [ "$_rc" -ne 0 ]; then
        test_fail "stamp block exited $_rc: $_out"
    elif [ "$_cfgv" != "0.21.15" ]; then
        test_fail "config version expected 0.21.15 (from fake framework VERSION), got '$_cfgv': $_out"
    elif [ "$_stamp" != "0.21.15" ]; then
        test_fail "stamp expected exactly '0.21.15' (== config version '$_cfgv'), got '$_stamp': $_out"
    else
        test_pass
    fi
fi

test_start "I1b: stamp block follows the .install-profile write and is keyed on \${VERSION}"
_l_prof="$(grep -n '^printf .%s\\n. "\${INSTALL_PROFILE}" > "\${INSTALL_DIR}/.install-profile"' "$SETUP_SH" | head -1 | cut -d: -f1)"
_l_stamp="$(grep -n 'aitf_write_installed_version "\${INSTALL_DIR}" "\${VERSION}"' "$SETUP_SH" | head -1 | cut -d: -f1)"
if [ -z "$_l_prof" ] || [ -z "$_l_stamp" ]; then
    test_fail "anchor missing in setup script (install-profile line='$_l_prof', stamp call line='$_l_stamp')"
elif [ "$_l_stamp" -le "$_l_prof" ]; then
    test_fail "stamp call (line $_l_stamp) is not after the .install-profile write (line $_l_prof)"
else
    test_pass
fi

test_start "I1c: a failing stamp write does not fail the install (warns on stderr, rc 0)"
if [ -z "$STAMP_BLOCK" ]; then
    test_fail "stamp block not extracted"
else
    {
        printf '%s\n' 'set -e' 'VERSION=0.21.15' "INSTALL_DIR=\"$W/i1c/does-not-exist\"" "GREEN=''; YELLOW=''; NC=''"
        printf '%s\n' "$STAMP_BLOCK" 'echo REACHED_END'
    } > "$W/i1c-block.sh"
    _out="$(XV_HOME="$FAKE_FW" XV_BLOCK="$W/i1c-block.sh" _run "$NOBREW_BIN" "$W/i1c" '. "$XV_BLOCK"' 2>&1)"
    _rc=$?
    if [ "$_rc" -ne 0 ] || [[ "$_out" != *REACHED_END* ]]; then
        test_fail "install aborted (rc=$_rc): $_out"
    elif [[ "$_out" != *"Could not write .installed-version"* ]]; then
        test_fail "no warning emitted for failed stamp write: $_out"
    elif [ -e "$W/i1c/does-not-exist/.installed-version" ]; then
        test_fail "stamp exists in a directory that should not exist"
    else
        test_pass
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# B — backfill
# ═══════════════════════════════════════════════════════════════════════════
test_start "B1: backfill on a never-upgraded box seeds the CONFIG version (0.11.6), not the cellar VERSION (0.21.15); stdout empty"
B1_DIR="$W/b1/aiteamforge"
mk_never_upgraded "$B1_DIR" "0.11.6"
if [ -e "$B1_DIR/.installed-version" ]; then
    test_fail "fixture is not never-upgraded: stamp already present"
else
    _so="$W/b1.out"; _se="$W/b1.err"
    XV_HOME="$FAKE_FW" _run "$NOBREW_BIN" "$B1_DIR" "$BACKFILL_PROG" >"$_so" 2>"$_se"
    _rc=$?
    _stamp="$(cat "$B1_DIR/.installed-version" 2>/dev/null)"
    if [ "$_rc" -ne 0 ]; then
        test_fail "backfill rc=$_rc"
    elif [ "$_stamp" != "0.11.6" ]; then
        test_fail "stamp expected '0.11.6', got '$_stamp' (cellar VERSION is '$(cat "$FAKE_FW/VERSION")')"
    elif [ -s "$_so" ]; then
        test_fail "backfill wrote to stdout: $(cat "$_so")"
    else
        test_pass
    fi
fi

test_start "B1b: same seed through the non-jq (grep/sed) branch"
B1B_DIR="$W/b1b/aiteamforge"
mk_never_upgraded "$B1B_DIR" "0.11.6"
_so="$W/b1b.out"
XV_HOME="$FAKE_FW" _run "$NOJQ_BIN" "$B1B_DIR" "$BACKFILL_PROG" >"$_so" 2>/dev/null
_rc=$?
_stamp="$(cat "$B1B_DIR/.installed-version" 2>/dev/null)"
if [ "$_rc" -ne 0 ] || [ "$_stamp" != "0.11.6" ] || [ -s "$_so" ]; then
    test_fail "rc=$_rc stamp='$_stamp' stdout='$(cat "$_so")' (expected rc 0, '0.11.6', empty stdout)"
else
    test_pass
fi

test_start "B2: backfill never overwrites an existing stamp (content 0.20.0 and mtime unchanged)"
B2_DIR="$W/b2/aiteamforge"
mk_never_upgraded "$B2_DIR" "0.11.6"
printf '0.20.0\n' > "$B2_DIR/.installed-version"
touch -t 202001010000 "$B2_DIR/.installed-version"
_m0="$(_mtime "$B2_DIR/.installed-version")"
_rc=0; _run "$NOBREW_BIN" "$B2_DIR" "$BACKFILL_PROG" >/dev/null 2>&1 || _rc=$?
_stamp="$(cat "$B2_DIR/.installed-version")"
_m1="$(_mtime "$B2_DIR/.installed-version")"
if [ "$_rc" -ne 0 ]; then
    test_fail "backfill rc=$_rc"
elif [ "$_stamp" != "0.20.0" ]; then
    test_fail "existing stamp overwritten: expected '0.20.0', got '$_stamp'"
elif [ "$_m0" != "$_m1" ]; then
    test_fail "stamp mtime changed ($_m0 -> $_m1): file was rewritten"
else
    test_pass
fi

test_start "B3: backfill with no config / no version key / invalid version writes NO stamp and returns 0"
_b3_bad=""
# (a) no config at all
mkdir -p "$W/b3a/aiteamforge"
# (b) config without version
mk_never_upgraded "$W/b3b/aiteamforge" ""
# (c) config with a non-version token
mk_never_upgraded "$W/b3c/aiteamforge" "not-a-version"
# (d) config with an empty version string
mk_never_upgraded "$W/b3d/aiteamforge" "x"; printf '{ "version": "" }\n' > "$W/b3d/aiteamforge/.aiteamforge-config"
for _c in b3a b3b b3c b3d; do
    _rc=0; _so="$(_run "$NOBREW_BIN" "$W/$_c/aiteamforge" "$BACKFILL_PROG" 2>/dev/null)" || _rc=$?
    if [ "$_rc" -ne 0 ]; then _b3_bad="$_b3_bad $_c:rc=$_rc"; fi
    if [ -e "$W/$_c/aiteamforge/.installed-version" ]; then _b3_bad="$_b3_bad $_c:stamp='$(cat "$W/$_c/aiteamforge/.installed-version")'"; fi
    if [ -n "$_so" ]; then _b3_bad="$_b3_bad $_c:stdout='$_so'"; fi
done
if [ -n "$_b3_bad" ]; then
    test_fail "unexpected:$_b3_bad"
else
    test_pass
fi

WRITE_PROG='. "$XV_TAP/libexec/lib/installed-version.sh"; aitf_write_installed_version "$AITEAMFORGE_DIR" "$XV_VERSION"'

test_start "W1: writer REJECTS embedded whitespace/newlines instead of squashing them (0.1.0<NL>0.2.0 must not become 0.1.00.2.0)"
_w1_bad=""
for _case in multiline space; do
    _d="$W/w1-$_case/aiteamforge"; mkdir -p "$_d"
    case "$_case" in
        multiline) _v="$(printf '0.1.0\n0.2.0')" ;;
        space)     _v="0.1.0 0.2.0" ;;
    esac
    _rc=0; XV_VERSION="$_v" _run "$NOBREW_BIN" "$_d" "$WRITE_PROG" >/dev/null 2>&1 || _rc=$?
    [ "$_rc" -eq 0 ] && _w1_bad="$_w1_bad $_case:accepted(rc=0)"
    [ -e "$_d/.installed-version" ] && _w1_bad="$_w1_bad $_case:wrote='$(tr '\n' '|' < "$_d/.installed-version")'"
done
# Surrounding whitespace is still trimmed (not a regression of the accept path).
_d="$W/w1-pad/aiteamforge"; mkdir -p "$_d"
_rc=0; XV_VERSION="$(printf '  0.20.3_1 \n')" _run "$NOBREW_BIN" "$_d" "$WRITE_PROG" >/dev/null 2>&1 || _rc=$?
_got="$(cat "$_d/.installed-version" 2>/dev/null)"
[ "$_rc" -ne 0 ] || [ "$_got" != "0.20.3_1" ] && _w1_bad="$_w1_bad padded:rc=$_rc,got='$_got'"
if [ -n "$_w1_bad" ]; then test_fail "unexpected:$_w1_bad"; else test_pass; fi

test_start "W2: writer refuses a DIRECTORY at the stamp path (mv would move the temp file into it), leaves no temp file"
_d="$W/w2/aiteamforge"; mkdir -p "$_d/.installed-version"
_rc=0; XV_VERSION="0.21.15" _run "$NOBREW_BIN" "$_d" "$WRITE_PROG" >/dev/null 2>&1 || _rc=$?
_inside="$(ls -A "$_d/.installed-version")"
_tmps=0; for _f in "$_d"/.installed-version.*; do [ -e "$_f" ] && _tmps=$((_tmps + 1)); done
if [ "$_rc" -eq 0 ]; then
    test_fail "writer returned 0 with a directory at the stamp path"
elif [ -n "$_inside" ] || [ "$_tmps" != "0" ]; then
    test_fail "writer left files behind: inside='$_inside' temps=$_tmps"
else
    test_pass
fi

test_start "B4: backfill REPAIRS a zero-byte or whitespace-only stamp (empty / lone newline / spaces) from the config version (0.11.6)"
B4_DIR="$W/b4/aiteamforge"
mk_never_upgraded "$B4_DIR" "0.11.6"
_b4_bad=""
for _case in empty newline spaces; do
    case "$_case" in
        empty)   : > "$B4_DIR/.installed-version" ;;
        newline) printf '\n' > "$B4_DIR/.installed-version" ;;
        spaces)  printf '  \t \n\n' > "$B4_DIR/.installed-version" ;;
    esac
    _rc=0; _run "$NOBREW_BIN" "$B4_DIR" "$BACKFILL_PROG" >/dev/null 2>&1 || _rc=$?
    _stamp="$(cat "$B4_DIR/.installed-version")"
    if [ "$_rc" -ne 0 ] || [ "$_stamp" != "0.11.6" ]; then _b4_bad="$_b4_bad $_case:rc=$_rc,stamp='$_stamp'"; fi
done
if [ -n "$_b4_bad" ]; then
    test_fail "zero-byte/whitespace-only stamp not repaired to 0.11.6:$_b4_bad"
else
    test_pass
fi

test_start "B5: backfill FAILS CLOSED on an unreadable stamp (mode 000 / 200 / symlink to unreadable): content untouched, no stderr; dangling symlink IS repaired"
_b5_bad=""
for _case in mode000 mode200 link-unreadable dangling; do
    _d="$W/b5-$_case/aiteamforge"; mk_never_upgraded "$_d" "0.11.6"
    _s="$_d/.installed-version"
    case "$_case" in
        mode000) printf '0.20.0\n' > "$_s"; chmod 000 "$_s" ;;
        mode200) printf '0.20.0\n' > "$_s"; chmod 200 "$_s" ;;
        link-unreadable) printf '0.20.0\n' > "$_d/real-stamp"; chmod 000 "$_d/real-stamp"; ln -s "$_d/real-stamp" "$_s" ;;
        dangling) ln -s "$_d/no-such-target" "$_s" ;;
    esac
    _rc=0; _err="$(_run "$NOBREW_BIN" "$_d" "$BACKFILL_PROG" 2>&1 >/dev/null)" || _rc=$?
    case "$_case" in
        mode000|mode200) chmod 644 "$_s"; _want="0.20.0"; _got="$(cat "$_s")" ;;
        link-unreadable) chmod 644 "$_d/real-stamp"; _want="0.20.0"; _got="$(cat "$_d/real-stamp")"
                         [ -L "$_s" ] || _b5_bad="$_b5_bad $_case:symlink-replaced" ;;
        dangling) _want="0.11.6"; _got="$(cat "$_s" 2>/dev/null)"
                  [ -L "$_s" ] && _b5_bad="$_b5_bad $_case:still-a-dangling-link" ;;
    esac
    [ "$_rc" -ne 0 ] && _b5_bad="$_b5_bad $_case:rc=$_rc"
    [ "$_got" != "$_want" ] && _b5_bad="$_b5_bad $_case:want='$_want',got='$_got'"
    case "$_case" in
        dangling) [[ "$_err" == *"stamped working-dir version 0.11.6"* ]] || _b5_bad="$_b5_bad $_case:no-seed-note" ;;
        *) [ -n "$_err" ] && _b5_bad="$_b5_bad $_case:stderr='$_err'" ;;
    esac
done
if [ -n "$_b5_bad" ]; then
    test_fail "unexpected:$_b5_bad"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# G — get_installed_version (source 3, the config fallback, is retired)
# ═══════════════════════════════════════════════════════════════════════════
GIV_PROG='. "$XV_TAP/libexec/lib/config.sh"; get_installed_version'

test_start "G1: get_installed_version, brew masked, NO stamp, config version 0.11.6 present -> \"unknown\""
G1_DIR="$W/g1/aiteamforge"
mk_never_upgraded "$G1_DIR" "0.11.6"
_out="$(_run "$NOBREW_BIN" "$G1_DIR" "$GIV_PROG" 2>/dev/null)"
if [ "$_out" != "unknown" ]; then
    test_fail "expected 'unknown', got '$_out' (config fallback is back?)"
else
    test_pass
fi

test_start "G2: get_installed_version with a stamp returns the stamp (0.20.0), not the config version (0.11.6)"
G2_DIR="$W/g2/aiteamforge"
mk_never_upgraded "$G2_DIR" "0.11.6"
printf '0.20.0\n' > "$G2_DIR/.installed-version"
_out="$(_run "$NOBREW_BIN" "$G2_DIR" "$GIV_PROG" 2>/dev/null)"
if [ "$_out" != "0.20.0" ]; then
    test_fail "expected '0.20.0', got '$_out'"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# C — CLI entry point
# ═══════════════════════════════════════════════════════════════════════════
test_start "C1: bin/aiteamforge-cli.sh version on a never-upgraded box seeds the stamp from the config (0.11.6)"
C1_DIR="$W/c1/aiteamforge"
mk_never_upgraded "$C1_DIR" "0.11.6"
if [ -e "$C1_DIR/.installed-version" ]; then
    test_fail "fixture is not never-upgraded"
else
    _out="$(XV_HOME="$TAP_ROOT" _run "$NOBREW_BIN" "$C1_DIR" "$BASHBIN"' "$XV_TAP/bin/aiteamforge-cli.sh" version' 2>&1)"
    _rc=$?
    _stamp="$(cat "$C1_DIR/.installed-version" 2>/dev/null)"
    if [ "$_rc" -ne 0 ]; then
        test_fail "CLI exited $_rc: $_out"
    elif [ "$_stamp" != "0.11.6" ]; then
        test_fail "stamp expected '0.11.6', got '$_stamp'. CLI output: $_out"
    else
        test_pass
    fi
fi

test_start "C2: CLI on a box whose config has no version leaves the stamp absent and still succeeds"
C2_DIR="$W/c2/aiteamforge"
mk_never_upgraded "$C2_DIR" ""
_out="$(XV_HOME="$TAP_ROOT" _run "$NOBREW_BIN" "$C2_DIR" "$BASHBIN"' "$XV_TAP/bin/aiteamforge-cli.sh" version' 2>&1)"
_rc=$?
if [ "$_rc" -ne 0 ]; then
    test_fail "CLI exited $_rc: $_out"
elif [ -e "$C2_DIR/.installed-version" ]; then
    test_fail "CLI invented a stamp: '$(cat "$C2_DIR/.installed-version")'"
else
    test_pass
fi

# ═══════════════════════════════════════════════════════════════════════════
# D — doctor check_version_drift (extracted and driven directly)
# ═══════════════════════════════════════════════════════════════════════════
DRIFT_FN="$(_extract_fn "$DOCTOR_SH" check_version_drift)"
RESULT_FN="$(_extract_fn "$DOCTOR_SH" check_result)"

# Runs check_version_drift against $1 (AITEAMFORGE_DIR). $2 = "backfill" to run
# the real backfill first, exactly as doctor does at startup.
run_drift() {
    local dir="$1" mode="${2:-}" pre=""
    [ "$mode" = "backfill" ] && pre='aitf_backfill_installed_version >/dev/null 2>&1 || true'
    {
        printf '%s\n' '. "$XV_TAP/libexec/lib/common.sh"' '. "$XV_TAP/libexec/lib/config.sh"'
        printf '%s\n' 'VERBOSE=false; TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0'
        printf '%s\n' "$RESULT_FN" "$DRIFT_FN" "$pre" 'check_version_drift'
        printf '%s\n' 'echo "COUNTS pass=$PASSED_CHECKS fail=$FAILED_CHECKS warn=$WARNING_CHECKS"'
    } > "$W/drift-block.sh"
    XV_HOME="$FAKE_FW" XV_BLOCK="$W/drift-block.sh" _run "$NOBREW_BIN" "$dir" '. "$XV_BLOCK"' 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'
}

test_start "D0: check_version_drift / check_result extracted from doctor"
if [ -z "$DRIFT_FN" ] || [ -z "$RESULT_FN" ]; then
    test_fail "extraction failed (drift=${#DRIFT_FN} result=${#RESULT_FN})"
else
    test_pass
fi

test_start "D1: no stamp and no config version -> FAIL text, old upgrade advice gone, FAILED_CHECKS=1"
D1_DIR="$W/d1/aiteamforge"
mk_never_upgraded "$D1_DIR" ""
_out="$(run_drift "$D1_DIR")"
if [[ "$_out" != *"Working-dir version stamp missing: provisioning did not write"* ]]; then
    test_fail "FAIL text absent. Output: $_out"
elif [[ "$_out" != *"COUNTS pass=0 fail=1 warn=0"* ]]; then
    test_fail "expected exactly one fail and no warn/pass. Output: $_out"
elif [[ "$_out" == *"/../VERSION"* ]] || [[ "$_out" == *"cat "*"VERSION)"* ]]; then
    test_fail "repair hint still suggests stamping the Cellar VERSION (hides drift). Output: $_out"
elif [[ "$_out" == *"to refresh and stamp"* ]] || [[ "$_out" == *"Cannot determine working-dir version"* ]] || [[ "$_out" == *"config-fallback"* ]]; then
    test_fail "old warn/advice text still present. Output: $_out"
else
    test_pass
fi

test_start "D2: doctor's OWN check backfills a never-upgraded box (0.11.6, cellar 0.21.15), SAYS so, then reports drift (warn), no fail"
D2_DIR="$W/d2/aiteamforge"
mk_never_upgraded "$D2_DIR" "0.11.6"
_out="$(run_drift "$D2_DIR")"
if [ "$(cat "$D2_DIR/.installed-version" 2>/dev/null)" != "0.11.6" ]; then
    test_fail "check_version_drift did not backfill the stamp to 0.11.6 (got '$(cat "$D2_DIR/.installed-version" 2>/dev/null)'). Output: $_out"
elif [[ "$_out" != *"stamped working-dir version 0.11.6"* ]]; then
    test_fail "backfill was silent: the seed must be reported. Output: $_out"
elif [[ "$_out" != *"Cellar v0.21.15 BUT working-dir v0.11.6"* ]]; then
    test_fail "drift message missing/incorrect. Output: $_out"
elif [[ "$_out" != *"COUNTS pass=0 fail=0 warn=1"* ]]; then
    test_fail "expected exactly one warn. Output: $_out"
else
    test_pass
fi

test_start "D3: stamp equal to cellar (0.21.15) -> pass"
D3_DIR="$W/d3/aiteamforge"
mk_never_upgraded "$D3_DIR" "0.11.6"
printf '0.21.15\n' > "$D3_DIR/.installed-version"
_out="$(run_drift "$D3_DIR")"
if [[ "$_out" != *"Cellar v0.21.15 matches working-dir v0.21.15"* ]] || [[ "$_out" != *"COUNTS pass=1 fail=0 warn=0"* ]]; then
    test_fail "Output: $_out"
else
    test_pass
fi

test_start "D4: zero-byte stamp and no config version -> FAIL says 'present but empty', not 'missing'"
D4_DIR="$W/d4/aiteamforge"
mk_never_upgraded "$D4_DIR" ""
: > "$D4_DIR/.installed-version"
_out="$(run_drift "$D4_DIR")"
if [[ "$_out" != *"stamp present but empty"* ]] || [[ "$_out" != *"COUNTS pass=0 fail=1 warn=0"* ]]; then
    test_fail "Output: $_out"
else
    test_pass
fi

test_start "D5: 'aiteamforge doctor --help' does NOT write the stamp (backfill is scoped to the check path)"
D5_DIR="$W/d5/aiteamforge"
mk_never_upgraded "$D5_DIR" "0.11.6"
_rc=0; _out="$(_run "$NOBREW_BIN" "$D5_DIR" '"$0" "$XV_DOCTOR" --help' 2>&1)" || _rc=$?
if [ -e "$D5_DIR/.installed-version" ]; then
    test_fail "doctor --help wrote a stamp ('$(cat "$D5_DIR/.installed-version")')"
elif [[ "$_out" != *"sage"* ]]; then
    test_fail "doctor --help did not print usage (rc=$_rc) — the test did not reach the arg parser: $_out"
else
    test_pass
fi

if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-1102 never-upgraded stamp tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed — this is a vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
