#!/bin/bash
# test-xaca-1599-doctor-plugin-binaries.sh
#
# XACA-1599-016/-017 and the PR-B default-run wiring, for BOTH doctor copies
# (bin/aiteamforge-doctor.sh and libexec/commands/aiteamforge-doctor.sh -- XACA-0807 dual-doctor):
#
#   016  every exit status of `kb-sync-plugins binaries` is worded for ITS cause: 1 = a binary is
#        missing, 3 = cannot verify (NO_HOSTED_TEAMS = "nothing to verify", a warning, not a
#        failure; anything else a failure), 70 = the tool itself crashed (a bug, NOT "binary
#        missing"), anything else = unexpected.
#   017  `--verbose` prints a failing report exactly once (it used to print twice: once through
#        check_result's detail argument, once explicitly).
#   all  check_plugin_binaries is part of the default `all` run in both copies.
#
# Strategy: extract check_result + check_plugin_binaries from each doctor (the XACA-0650 driver
# pattern), run them against a STUB kb-sync-plugins that exits with a chosen status, and assert on
# the rendered lines and the counters. NEGATIVE CONTROL: the same driver run against the
# pre-change function text (git show HEAD) must print the report twice under --verbose and word
# rc 70 as "binary missing", or the assertions above would be vacuous.
#
# Sandboxed: everything lives under a mktemp dir; nothing real is read or written.

# shellcheck disable=SC2016  # the driver is generated source text: single quotes are intentional
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DOCTOR="$TAP_ROOT/bin/aiteamforge-doctor.sh"
LIBEXEC_DOCTOR="$TAP_ROOT/libexec/commands/aiteamforge-doctor.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
eq()   { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xaca1599-doctor.XXXXXX")" || exit 2
trap 'cd /; case "$WORK" in */xaca1599-doctor.*) /bin/rm -rf -- "$WORK" ;; esac' EXIT

extract_function() { sed -n "/^${2}()/,/^}\$/p" "$1"; }

# make_dirs <flavor>: sandbox with scripts/kb-sync-plugins (stub) and .claude/plugins-manifest.json
make_dirs() {
  D="$WORK/$1-$RANDOM"
  mkdir -p "$D/scripts" "$D/.claude"
  printf '{}\n' >"$D/.claude/plugins-manifest.json"
}

write_stub() { # <rc> <report line...>
  local rc="$1"; shift
  {
    echo '#!/bin/sh'
    printf 'printf "%%s\\n" "%s"\n' "$*"
    echo "exit $rc"
  } >"$D/scripts/kb-sync-plugins"
  chmod +x "$D/scripts/kb-sync-plugins"
}

# run_doctor <flavor> <doctor-file> <verbose true|false> [function-source-override-file]
# Sets OUT and COUNTS ("total passed failed warned").
run_doctor() {
  local flavor="$1" file="$2" verbose="$3" override="${4:-}"
  local fn_result fn_check
  if [ -n "$override" ]; then
    fn_result="$(extract_function "$override" check_result)"
    fn_check="$(extract_function "$override" check_plugin_binaries)"
  else
    fn_result="$(extract_function "$file" check_result)"
    fn_check="$(extract_function "$file" check_plugin_binaries)"
  fi
  {
    echo '#!/bin/bash'
    echo 'set -o pipefail'
    echo "VERBOSE=$verbose"
    echo 'RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""'
    echo 'TOTAL_CHECKS=0; PASSED_CHECKS=0; FAILED_CHECKS=0; WARNING_CHECKS=0'
    # libexec copy: print_* helpers + get_working_dir; bin copy: AITEAMFORGE_DIR
    echo 'print_success() { echo "OK: $*"; }; print_error() { echo "ERR: $*"; }; print_warning() { echo "WARN: $*"; }'
    echo 'print_section() { echo "== $*"; }; print_info() { echo "INFO: $*"; }'
    echo "get_working_dir() { echo \"$D\"; }"
    echo "AITEAMFORGE_DIR=\"$D\""
    echo "$fn_result"
    echo "$fn_check"
    echo 'check_plugin_binaries'
    echo 'echo "COUNTS $TOTAL_CHECKS $PASSED_CHECKS $FAILED_CHECKS $WARNING_CHECKS"'
  } >"$D/driver.sh"
  OUT="$(bash "$D/driver.sh" 2>&1)"
  COUNTS="$(printf '%s\n' "$OUT" | sed -n 's/^COUNTS //p')"
}

count_lines() { printf '%s\n' "$OUT" | grep -c -F -e "$1" || true; }

check_flavor() {
  local flavor="$1" file="$2"
  echo "=== $flavor doctor ==="
  make_dirs "$flavor"

  write_stub 0 "REPORT-MARKER all present"
  run_doctor "$flavor" "$file" false
  eq "$flavor rc0: one pass" "1 1 0 0" "$COUNTS"
  eq "$flavor rc0: report hidden without --verbose" "0" "$(count_lines REPORT-MARKER)"
  run_doctor "$flavor" "$file" true
  eq "$flavor rc0 --verbose: report shown once" "1" "$(count_lines REPORT-MARKER)"

  write_stub 1 "REPORT-MARKER MISSING sourcekit-lsp"
  run_doctor "$flavor" "$file" false
  eq "$flavor rc1: a failure" "1 0 1 0" "$COUNTS"
  eq "$flavor rc1: worded as a missing binary" "1" "$(count_lines 'Required plugin binary missing')"
  eq "$flavor rc1: report shown once" "1" "$(count_lines REPORT-MARKER)"
  run_doctor "$flavor" "$file" true
  eq "$flavor rc1 --verbose: report STILL shown once (XACA-1599-017)" "1" "$(count_lines REPORT-MARKER)"

  write_stub 3 "kb-sync-plugins: ERROR: NO_HOSTED_TEAMS: check --host -- nothing was verified REPORT-MARKER"
  run_doctor "$flavor" "$file" false
  eq "$flavor rc3 NO_HOSTED_TEAMS: a warning, not a failure" "1 0 0 1" "$COUNTS"
  eq "$flavor rc3 NO_HOSTED_TEAMS: worded 'nothing to verify'" "1" "$(count_lines 'nothing to verify')"
  eq "$flavor rc3 NO_HOSTED_TEAMS: not worded as unverifiable-failure" "0" "$(count_lines 'not a pass')"
  run_doctor "$flavor" "$file" true
  eq "$flavor rc3 NO_HOSTED_TEAMS --verbose: report once" "1" "$(count_lines REPORT-MARKER)"

  write_stub 3 "kb-sync-plugins: ERROR: manifest invalid REPORT-MARKER"
  run_doctor "$flavor" "$file" false
  eq "$flavor rc3 other: a failure" "1 0 1 0" "$COUNTS"
  eq "$flavor rc3 other: worded unverifiable, not a pass" "1" "$(count_lines 'unverifiable')"

  write_stub 70 "Traceback (most recent call last): REPORT-MARKER"
  run_doctor "$flavor" "$file" false
  eq "$flavor rc70: a failure" "1 0 1 0" "$COUNTS"
  eq "$flavor rc70: worded as a crash of the tool" "1" "$(count_lines 'crashed')"
  eq "$flavor rc70: NOT worded as a missing binary" "0" "$(count_lines 'binary missing')"

  write_stub 5 "REPORT-MARKER"
  run_doctor "$flavor" "$file" false
  eq "$flavor other rc: a failure" "1 0 1 0" "$COUNTS"
  eq "$flavor other rc: named unexpected with the code" "1" "$(count_lines 'failed unexpectedly (rc=5)')"

  rm "$D/scripts/kb-sync-plugins"
  run_doctor "$flavor" "$file" false
  eq "$flavor missing tool: a failure" "1 0 1 0" "$COUNTS"
  write_stub 0 "x"
  rm "$D/.claude/plugins-manifest.json"
  run_doctor "$flavor" "$file" false
  eq "$flavor missing manifest: a failure" "1 0 1 0" "$COUNTS"

  # part of the default run
  local all_arm
  all_arm="$(sed -n '/^  all)$/,/^    ;;$/p' "$file" | head -40)"
  eq "$flavor: check_plugin_binaries is in the default 'all' run" "1" \
    "$(printf '%s\n' "$all_arm" | grep -c '^    check_plugin_binaries$' || true)"
  eq "$flavor: the old 'opt-in until PR-B' comment is gone" "0" \
    "$(grep -c 'plugin-binaries is opt-in until' "$file" || true)"
}

# Negative control: the PRE-change function (git HEAD) must show both defects on the same driver.
negative_control() {
  local flavor="$1" rel="$2" old
  echo "=== negative control ($flavor, pre-change function) ==="
  old="$WORK/old-$flavor.sh"
  if ! git -C "$TAP_ROOT" show "HEAD:$rel" >"$old" 2>/dev/null || [ ! -s "$old" ]; then
    echo "  SKIP: no HEAD copy of $rel (not a git checkout); the mutation half is not run"
    return
  fi
  if ! grep -q 'XACA-1599-017' "$old"; then
    make_dirs "ctl-$flavor"
    write_stub 1 "REPORT-MARKER MISSING"
    run_doctor "$flavor" "$old" true "$old"
    eq "$flavor pre-change: --verbose printed the failing report TWICE (so the assertion above can fail)" "2" "$(count_lines REPORT-MARKER)"
    write_stub 70 "Traceback REPORT-MARKER"
    run_doctor "$flavor" "$old" false "$old"
    eq "$flavor pre-change: rc 70 fell into the generic arm (no 'crashed' wording)" "0" "$(count_lines 'crashed')"
  else
    echo "  SKIP: HEAD already carries the fix (run before committing to exercise this half)"
  fi
}

check_flavor bin "$BIN_DOCTOR"
check_flavor libexec "$LIBEXEC_DOCTOR"
negative_control bin "bin/aiteamforge-doctor.sh"
negative_control libexec "libexec/commands/aiteamforge-doctor.sh"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
