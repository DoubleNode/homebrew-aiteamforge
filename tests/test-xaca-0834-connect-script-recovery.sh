#!/bin/bash
# test-xaca-0834-connect-script-recovery.sh
#
# XACA-0834: `aiteamforge upgrade`'s update_connect_scripts() (shipped by
# XACA-0814) re-rendered a GUESSED connect-script instance instead of the one
# actually installed. The OLD code iterated team CONFIGS, detected
# installedness with an unanchored `${team_id}*-connect.sh` glob, then
# re-rendered using the BARE team id — discarding the instance shape the glob
# had just matched. Three distinct consequences, all reproduced below in the
# NC (negative-control) section against the pre-fix algorithm embedded
# verbatim from tap commit f7557b2:
#   1. A parameterised team with NO client default (freelance,
#      TEAM_REQUIRES_CLIENT_ID=true) could not resolve an instance id from a
#      bare id at all — its connect scripts were never refreshed. Fail-soft
#      swallowed this on the TTY-less nightly auto-upgrade LaunchAgent run;
#      on an INTERACTIVE run install-team.sh's compute_instance_id() instead
#      opens /dev/tty and PROMPTS for a client id mid-upgrade (verified by
#      reading libexec/installers/install-team.sh lines ~236-243 — see S3
#      below, which pins that this code path still exists and is reachable
#      from a bare, flag-less call).
#   2. A parameterised team WITH a default project but no client requirement
#      (finance, TEAM_DEFAULT_PROJECT="personal") resolved the bare call
#      through that default — so an installed `finance-work` was detected by
#      the glob, triggered a refresh, and got RE-RENDERED AS `finance-personal`:
#      active mis-materialisation of a cockpit script this box never asked
#      for, while the real `finance-work` scripts stayed stale forever.
#   3. The unanchored glob `${team_id}*-connect.sh` could false-match a
#      longer team id sharing the same prefix (a `med` template matching
#      `medical-general-connect.sh`) — or, worse, in the other direction, a
#      `medical` template's own glob could pick up a genuinely unrelated
#      `med`-prefixed file. The implementer notes this is LATENT: no two
#      shipped team ids in share/teams/*.conf are prefixes of one another
#      today, so this suite constructs SYNTHETIC `med`/`medical` templates
#      (T3/NC3 below) to exercise it — this is a deliberately hypothetical
#      scenario, not a reproduction of a live collision in the current
#      catalog, and it will stay that way unless a future team id is chosen
#      carelessly. Flagging here so this stays legible as synthetic and
#      doesn't get mistaken for evidence of a live collision.
#
# THE FIX inverts the loop: iterate the RENDERED FILES
# (${WORKING_DIR}/*-connect.sh), recover instance_id="${base%-connect.sh}"
# (the exact inverse of install-team.sh's own filename composition), match
# that instance against the shipped templates using ANCHORED shapes only
# (exact "<team>", or "<team>-<rest>" — never an unanchored substring),
# longest match wins, then decompose the remainder into --client/--project
# mirroring install-team.sh's compute_instance_id() three shapes exactly
# (components are validated ^[a-z0-9_]+$ so they never contain a dash, which
# is what makes the split unambiguous once the template is known).
#
# Assertions in this suite:
#   S1  STRUCTURAL: the function iterates WORKING_DIR/*-connect.sh (rendered
#       files), not share/teams/*.conf (team configs) — the core inversion.
#   S2  STRUCTURAL: install_args is built from --client/--project flags, and
#       the OLD bare "$team_id" --connect-only invocation pattern is gone.
#   S3  STRUCTURAL: install-team.sh's compute_instance_id() still contains
#       the /dev/tty interactive-prompt branch for a missing client id —
#       pins the "would prompt mid-upgrade on an interactive box" claim from
#       the CHANGELOG as a currently-true fact about the installer, not
#       something this suite merely asserts about itself.
#   T1  FREELANCE (Requirement 1): freelance-acme-webapp-connect.sh (client +
#       project) is refreshed under its FULL instance id via
#       --client acme --project webapp — never a bare `freelance` call.
#   T2  FINANCE (Requirement 2): finance-work-connect.sh is refreshed as
#       `finance --project work`; finance-personal-connect.sh is NEVER
#       created as a side effect.
#   T3  MED/MEDICAL (Requirement 3, SYNTHETIC — see note above): with only
#       medical-general-connect.sh on disk and synthetic med.conf +
#       medical.conf templates both present, only `medical --project general`
#       is invoked; `med` (a template whose id is a prefix of "medical") is
#       never invoked and no med-connect.sh is ever materialised.
#   T4  UNMATCHED (Requirement 4): a connect script with no matching template
#       is skipped with a warning, never handed to the installer.
#   T5  LONGEST-MATCH: a dash-bearing template id (ops-west) beats a shorter
#       template sharing its first component (ops) for an instance that
#       anchor-matches both.
#   T6  NULLGLOB-SAFETY: an empty WORKING_DIR (no *-connect.sh files at all)
#       does not crash and invokes the installer zero times, whether or not
#       nullglob is set in the caller's shell.
#   T7  SHAPE-REJECT (project-only): a 3-component instance
#       (finance-acme-work) against a template that takes a bare project is
#       REJECTED with a warning, never silently mis-split into
#       --project acme-work.
#   T8  SHAPE-REJECT (client+project): a 2-component instance
#       (freelance-acme) against a template requiring client+project is
#       REJECTED with a warning, never silently mis-split into
#       --client acme --project acme.
#   T9  EMPTY-INSTANCE (edge case): a file literally named "-connect.sh"
#       (empty instance id after suffix-stripping) is never handed to the
#       installer. Documented finding: this path is a silent `continue`, not
#       even counted in the "skipped" tally — an observability gap, not a
#       correctness bug (see report).
#   NC1/NC2/NC3  NEGATIVE CONTROL: the T1/T2/T3 fixtures replayed against the
#       PRE-FIX algorithm (embedded verbatim from tap commit f7557b2 as
#       _pre_fix_update_connect_scripts, function name only renamed to avoid
#       a symbol collision) reproduce exactly the three defects described
#       above — proving this harness can fail, not just pass.
#
# All filesystem activity is sandboxed under TEST_TMP_DIR with a STUBBED
# install-team.sh that faithfully mirrors compute_instance_id()'s project/
# client resolution (including the TEAM_DEFAULT_PROJECT fallback that the
# real bug depended on) — never touches real $HOME/aiteamforge or the real
# share/teams directory's install-team.sh invocation.
#
# Runs standalone (`bash tests/test-xaca-0834-connect-script-recovery.sh`) OR
# via test-runner.sh. Exit 0 = all pass, exit 1 = any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
INSTALL_TEAM_SH="$TAP_ROOT/libexec/installers/install-team.sh"

if [ ! -f "$UPGRADE_SH" ]; then
    echo "FATAL: required file not found: $UPGRADE_SH" >&2
    exit 1
fi

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

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own).
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca0834-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
cleanup() { if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "${TEST_TMP_DIR:-}" ]; then find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true; fi; }
trap cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca0834"
mkdir -p "$WORK_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# S1 / S2 / S3 — STRUCTURAL assertions against the real, unmodified files.
# ═══════════════════════════════════════════════════════════════════════════
test_start "S1: update_connect_scripts iterates rendered files (WORKING_DIR/*-connect.sh), not team configs"
if grep -qF 'for f in "${WORKING_DIR}"/*-connect.sh; do' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "expected the file-iteration loop 'for f in \"\${WORKING_DIR}\"/*-connect.sh; do' in $UPGRADE_SH — the core XACA-0834 inversion"
fi

test_start "S2: install_args is built from --client/--project; the old bare team_id invocation is gone"
if grep -qF 'install_args+=( --client "$client" )' "$UPGRADE_SH" \
    && grep -qF 'install_args+=( --project "$project" )' "$UPGRADE_SH" \
    && ! grep -qF '"$team_id" --connect-only' "$UPGRADE_SH"; then
    test_pass
else
    test_fail "expected --client/--project flag construction present and the old bare '\"\$team_id\" --connect-only' pattern absent"
fi

test_start "S3: install-team.sh's compute_instance_id still prompts via /dev/tty for a missing client id (pins the interactive-hang claim)"
if [ -f "$INSTALL_TEAM_SH" ] \
    && grep -qF 'exec 9<>/dev/tty' "$INSTALL_TEAM_SH" \
    && grep -qF 'requires a client id' "$INSTALL_TEAM_SH"; then
    test_pass
else
    test_fail "expected install-team.sh to still contain the /dev/tty prompt branch ahead of its 'requires a client id' error — if this was removed, the CHANGELOG's interactive-hang claim needs updating too"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Extract update_connect_scripts() + its helper _connect_script_team_flags()
# from aiteamforge-upgrade.sh (do NOT source the whole script — its main body
# has side effects: is_configured, get_framework_dir, brew checks, the
# upgrade itself).
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn() {
    awk -v fn="$1" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$UPGRADE_SH"
}

FLAGS_FN_SRC="$WORK_DIR/connect_script_team_flags.extracted.sh"
UPD_FN_SRC="$WORK_DIR/update_connect_scripts.extracted.sh"
_extract_fn _connect_script_team_flags > "$FLAGS_FN_SRC"
_extract_fn update_connect_scripts > "$UPD_FN_SRC"

if [ ! -s "$FLAGS_FN_SRC" ] || [ ! -s "$UPD_FN_SRC" ]; then
    echo "FATAL: could not extract update_connect_scripts / _connect_script_team_flags from $UPGRADE_SH" >&2
    if [ "$_STANDALONE" = true ]; then
        echo ""
        echo "XACA-0834 connect-script-recovery tests: ${_PASS_COUNT} passed, $((_FAIL_COUNT + 1)) failed"
    fi
    exit 1
fi

# print_* stubs that ALSO record output so functional tests can grep for
# specific message text (mirrors test-xaca-0814/0799's printf-based stubs).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

# shellcheck disable=SC1090
source "$FLAGS_FN_SRC"
# shellcheck disable=SC1090
source "$UPD_FN_SRC"
declare -f _connect_script_team_flags >/dev/null || { echo "FATAL: _connect_script_team_flags not defined after extraction"; exit 1; }
declare -f update_connect_scripts >/dev/null || { echo "FATAL: update_connect_scripts not defined after extraction"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# NEGATIVE-CONTROL FIXTURE: the PRE-FIX algorithm, embedded verbatim from tap
# commit f7557b2 (the XACA-0814 commit, immediately before XACA-0834's fix in
# eea25b8). Only the function NAME is renamed (to avoid colliding with the
# real one sourced above) — body is byte-identical to what shipped. This is a
# SYNTHESIZED pre-fix copy (XACA-0799 convention), not a live `git show`
# dependency, so this suite never depends on tap git history staying
# reachable at a specific SHA.
# ─────────────────────────────────────────────────────────────────────────────
_pre_fix_update_connect_scripts() {
  print_section "Updating Team Connect/Disconnect Scripts"

  local teams_conf_dir="${FRAMEWORK_DIR}/share/teams"
  local installer="${LIBEXEC_DIR}/installers/install-team.sh"

  if [ ! -d "$teams_conf_dir" ]; then
    print_warning "Team configs not found ($teams_conf_dir) — skipping connect-script refresh"
    return 0
  fi
  if [ ! -f "$installer" ]; then
    print_warning "install-team.sh not found ($installer) — skipping connect-script refresh"
    return 0
  fi

  local updated=0
  local failed=0
  local conf team_id found f

  for conf in "$teams_conf_dir"/*.conf; do
    [ -f "$conf" ] || continue
    team_id="$(basename "$conf" .conf)"

    # Refresh only if this machine already rendered connect scripts for this
    # team (never materialise cockpit scripts for a team this box never set
    # up). INSTANCE_ID always begins with team_id (bare or project-augmented,
    # XACA-0485), so this glob catches both shapes.
    found=false
    for f in "${WORKING_DIR}/${team_id}"*-connect.sh; do
      [ -f "$f" ] || continue
      found=true
      break
    done
    [ "$found" = true ] || continue

    if [ "$DRY_RUN" = true ]; then
      echo "Would re-render ${team_id} connect/disconnect scripts"
      updated=$((updated + 1))
      continue
    fi

    print_info "Refreshing ${team_id} connect/disconnect scripts..."
    if ( AITEAMFORGE_DIR="${WORKING_DIR}" bash "$installer" "$team_id" --connect-only --install-dir "${WORKING_DIR}" 2>&1 | sed 's/^/    /' ); then
      print_success "Refreshed ${team_id} connect/disconnect scripts"
      updated=$((updated + 1))
    else
      print_warning "Failed to refresh ${team_id} connect/disconnect scripts (continuing)"
      failed=$((failed + 1))
    fi
  done

  if [ $((updated + failed)) -eq 0 ]; then
    print_success "No installed team connect scripts to refresh"
  elif [ "$DRY_RUN" = true ]; then
    print_success "Would refresh ${updated} team connect/disconnect script set(s)"
  elif [ "$failed" -gt 0 ]; then
    print_warning "Refreshed ${updated} team connect/disconnect script set(s); ${failed} failed (non-fatal)"
  else
    print_success "Refreshed ${updated} team connect/disconnect script set(s)"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Stubbed install-team.sh --connect-only. Faithfully mirrors the REAL
# install-team.sh's compute_instance_id() project/client resolution
# (including the TEAM_DEFAULT_PROJECT fallback the actual finance bug
# depended on) by sourcing the SAME sandboxed conf file the caller used, so
# this suite tests round-trip fidelity — not just "was the installer called"
# — the rendered filename must match what was really on disk pre-refresh.
# Records every invocation ("team|client=...|project=...") to STUB_CALL_LOG.
# Honors STUB_FAIL (models a single team's render failing) and requires
# STUB_TEAMS_CONF_DIR (points at the same teams_conf_dir sandbox as the
# caller). Never prompts interactively — mirrors the real installer's
# non-interactive (no /dev/tty) behavior, which is what an unattended
# nightly auto-upgrade LaunchAgent run actually gets.
# ─────────────────────────────────────────────────────────────────────────────
STUB_LIBEXEC="$WORK_DIR/stub-libexec"
mkdir -p "$STUB_LIBEXEC/installers"
STUB_INSTALLER="$STUB_LIBEXEC/installers/install-team.sh"
cat > "$STUB_INSTALLER" <<'STUB'
#!/bin/bash
set -eu
TEAM="$1"; shift
CONNECT_ONLY=false
INSTALL_DIR=""
ARG_PROJECT=""
ARG_CLIENT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --connect-only) CONNECT_ONLY=true; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --project) ARG_PROJECT="$2"; shift 2 ;;
        --client) ARG_CLIENT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
: "${STUB_CALL_LOG:?STUB_CALL_LOG must be set}"
: "${STUB_TEAMS_CONF_DIR:?STUB_TEAMS_CONF_DIR must be set}"
echo "${TEAM}|client=${ARG_CLIENT}|project=${ARG_PROJECT}" >> "$STUB_CALL_LOG"
if [ "$CONNECT_ONLY" != "true" ]; then
    echo "stub install-team.sh: only --connect-only is supported by this stub" >&2
    exit 1
fi
if [ "${STUB_FAIL:-false}" = "true" ]; then
    echo "stub install-team.sh: simulated failure for $TEAM" >&2
    exit 1
fi

TEAM_HAS_PROJECTS=false
TEAM_REQUIRES_CLIENT_ID=false
TEAM_DEFAULT_PROJECT=""
CONF="$STUB_TEAMS_CONF_DIR/${TEAM}.conf"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

# Mirror the real compute_instance_id()'s resolution order EXACTLY, minus
# the /dev/tty interactive prompt (this stub always behaves like the
# non-interactive nightly LaunchAgent run — the common/production case).
if [ "$TEAM_HAS_PROJECTS" != "true" ]; then
    if [ -n "$ARG_CLIENT" ] || [ -n "$ARG_PROJECT" ]; then
        echo "stub: Error: Template '${TEAM}' takes no parameters (TEAM_HAS_PROJECTS=false)" >&2
        exit 1
    fi
    INSTANCE_ID="$TEAM"
else
    RESOLVED_PROJECT="${ARG_PROJECT:-$TEAM_DEFAULT_PROJECT}"
    if [ -z "$RESOLVED_PROJECT" ]; then
        echo "stub: Error: Template '${TEAM}' requires a project (TEAM_HAS_PROJECTS=true)" >&2
        exit 1
    fi
    if [ "$TEAM_REQUIRES_CLIENT_ID" = "true" ]; then
        if [ -z "$ARG_CLIENT" ]; then
            echo "stub: Error: Template '${TEAM}' requires a client id (TEAM_REQUIRES_CLIENT_ID=true); non-interactive, no /dev/tty available" >&2
            exit 1
        fi
        INSTANCE_ID="${TEAM}-${ARG_CLIENT}-${RESOLVED_PROJECT}"
    else
        INSTANCE_ID="${TEAM}-${RESOLVED_PROJECT}"
    fi
fi

mkdir -p "$INSTALL_DIR"
echo "connect-rendered-for-${INSTANCE_ID}-$$" > "${INSTALL_DIR}/${INSTANCE_ID}-connect.sh"
echo "disconnect-rendered-for-${INSTANCE_ID}-$$" > "${INSTALL_DIR}/${INSTANCE_ID}-disconnect.sh"
chmod +x "${INSTALL_DIR}/${INSTANCE_ID}-connect.sh" "${INSTALL_DIR}/${INSTANCE_ID}-disconnect.sh"
echo "stub install-team.sh: rendered ${INSTANCE_ID} connect/disconnect scripts"
exit 0
STUB
chmod +x "$STUB_INSTALLER"

_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ═══════════════════════════════════════════════════════════════════════════
# T1 — FREELANCE (Requirement 1): full instance id, correct --client/--project.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1: freelance-acme-webapp-connect.sh refreshed via --client acme --project webapp (not a bare freelance call)"
T1_FRAMEWORK="$(_next_sandbox)"
T1_WORKING="$(_next_sandbox)"
mkdir -p "$T1_FRAMEWORK/share/teams"
cat > "$T1_FRAMEWORK/share/teams/freelance.conf" <<'CONF'
TEAM_ID="freelance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="true"
TEAM_DEFAULT_PROJECT="default"
CONF
echo "stale-freelance-acme-webapp-connect" > "$T1_WORKING/freelance-acme-webapp-connect.sh"
echo "stale-freelance-acme-webapp-disconnect" > "$T1_WORKING/freelance-acme-webapp-disconnect.sh"

_install_print_stubs
T1_CALL_LOG="$WORK_DIR/t1-calls.txt"; : > "$T1_CALL_LOG"
STUB_CALL_LOG="$T1_CALL_LOG" STUB_TEAMS_CONF_DIR="$T1_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T1_FRAMEWORK" WORKING_DIR="$T1_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
T1_AFTER="$(cat "$T1_WORKING/freelance-acme-webapp-connect.sh" 2>/dev/null)"
if grep -qF "freelance|client=acme|project=webapp" "$T1_CALL_LOG" \
    && [[ "$T1_AFTER" == connect-rendered-for-freelance-acme-webapp-* ]] \
    && [ -f "$T1_WORKING/freelance-acme-webapp-disconnect.sh" ]; then
    test_pass
else
    test_fail "expected 'freelance|client=acme|project=webapp' call + refreshed content; call_log=$(cat "$T1_CALL_LOG"); after=$T1_AFTER"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — FINANCE (Requirement 2): finance-work refreshed in place; finance-
# personal is never spuriously created.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2: finance-work-connect.sh refreshed as 'finance --project work'; finance-personal never materialised"
T2_FRAMEWORK="$(_next_sandbox)"
T2_WORKING="$(_next_sandbox)"
mkdir -p "$T2_FRAMEWORK/share/teams"
cat > "$T2_FRAMEWORK/share/teams/finance.conf" <<'CONF'
TEAM_ID="finance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="personal"
CONF
echo "stale-finance-work-connect" > "$T2_WORKING/finance-work-connect.sh"
echo "stale-finance-work-disconnect" > "$T2_WORKING/finance-work-disconnect.sh"

_install_print_stubs
T2_CALL_LOG="$WORK_DIR/t2-calls.txt"; : > "$T2_CALL_LOG"
STUB_CALL_LOG="$T2_CALL_LOG" STUB_TEAMS_CONF_DIR="$T2_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T2_FRAMEWORK" WORKING_DIR="$T2_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
T2_AFTER="$(cat "$T2_WORKING/finance-work-connect.sh" 2>/dev/null)"
if grep -qF "finance|client=|project=work" "$T2_CALL_LOG" \
    && [[ "$T2_AFTER" == connect-rendered-for-finance-work-* ]] \
    && [ ! -f "$T2_WORKING/finance-personal-connect.sh" ]; then
    test_pass
else
    test_fail "expected 'finance|client=|project=work' call, finance-work refreshed, no finance-personal; call_log=$(cat "$T2_CALL_LOG"); after=$T2_AFTER; personal_exists=$([ -f "$T2_WORKING/finance-personal-connect.sh" ] && echo yes || echo no)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3 — MED/MEDICAL (Requirement 3, SYNTHETIC): only medical-general-connect.sh
# is on disk; med.conf + medical.conf both present as templates ("med" is a
# prefix of "medical"). Only medical is invoked; med is never touched.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3 [SYNTHETIC]: med/medical templates don't cross-match; only medical-general is refreshed, med is never invoked or materialised"
T3_FRAMEWORK="$(_next_sandbox)"
T3_WORKING="$(_next_sandbox)"
mkdir -p "$T3_FRAMEWORK/share/teams"
# SYNTHETIC — no real shipped team id is a prefix of another today (this is
# the implementer's own stated latent-defect condition). "med" here is a
# constructed template that does NOT exist in share/teams/*.conf; it exists
# only inside this test's sandboxed FRAMEWORK_DIR to exercise the collision.
cat > "$T3_FRAMEWORK/share/teams/med.conf" <<'CONF'
TEAM_ID="med"
TEAM_HAS_PROJECTS="false"
CONF
cat > "$T3_FRAMEWORK/share/teams/medical.conf" <<'CONF'
TEAM_ID="medical"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="general"
CONF
echo "stale-medical-general-connect" > "$T3_WORKING/medical-general-connect.sh"
echo "stale-medical-general-disconnect" > "$T3_WORKING/medical-general-disconnect.sh"
# Deliberately no med-connect.sh — "med" was never installed on this box.

_install_print_stubs
T3_CALL_LOG="$WORK_DIR/t3-calls.txt"; : > "$T3_CALL_LOG"
STUB_CALL_LOG="$T3_CALL_LOG" STUB_TEAMS_CONF_DIR="$T3_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T3_FRAMEWORK" WORKING_DIR="$T3_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if grep -qF "medical|client=|project=general" "$T3_CALL_LOG" \
    && ! grep -qE '^med\|' "$T3_CALL_LOG" \
    && [ ! -f "$T3_WORKING/med-connect.sh" ]; then
    test_pass
else
    test_fail "expected only 'medical|client=|project=general', no 'med|' call, no med-connect.sh materialised; call_log=$(cat "$T3_CALL_LOG"); med_exists=$([ -f "$T3_WORKING/med-connect.sh" ] && echo yes || echo no)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T4 — UNMATCHED (Requirement 4): no template matches -> skipped, not
# handed to the installer.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T4: an unmatched connect script (no template) is skipped with a warning, never drives an installer call"
T4_FRAMEWORK="$(_next_sandbox)"
T4_WORKING="$(_next_sandbox)"
mkdir -p "$T4_FRAMEWORK/share/teams"
cat > "$T4_FRAMEWORK/share/teams/academy.conf" <<'CONF'
TEAM_ID="academy"
TEAM_HAS_PROJECTS="false"
CONF
echo "orphaned-connect-content" > "$T4_WORKING/ghost-team-connect.sh"

_install_print_stubs
T4_CALL_LOG="$WORK_DIR/t4-calls.txt"; : > "$T4_CALL_LOG"
STUB_CALL_LOG="$T4_CALL_LOG" STUB_TEAMS_CONF_DIR="$T4_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T4_FRAMEWORK" WORKING_DIR="$T4_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if [ ! -s "$T4_CALL_LOG" ] \
    && grep -qF "ghost-team" "$_STUB_LOG" \
    && grep -qi "no team template matches" "$_STUB_LOG" \
    && grep -qi "Skipped 1 unrecognised" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected installer never invoked + skip warning naming ghost-team + skipped-count message; call_log=$(cat "$T4_CALL_LOG" 2>/dev/null); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5 — LONGEST-MATCH: a dash-bearing template (ops-west) must beat a shorter
# template sharing its first component (ops) for an instance anchor-matching
# both shapes.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5: longest-match — ops-west-project1 resolves to template 'ops-west', not the shorter 'ops'"
T5_FRAMEWORK="$(_next_sandbox)"
T5_WORKING="$(_next_sandbox)"
mkdir -p "$T5_FRAMEWORK/share/teams"
cat > "$T5_FRAMEWORK/share/teams/ops.conf" <<'CONF'
TEAM_ID="ops"
TEAM_HAS_PROJECTS="false"
CONF
cat > "$T5_FRAMEWORK/share/teams/ops-west.conf" <<'CONF'
TEAM_ID="ops-west"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="fallback"
CONF
echo "stale-ops-west-project1-connect" > "$T5_WORKING/ops-west-project1-connect.sh"
echo "stale-ops-west-project1-disconnect" > "$T5_WORKING/ops-west-project1-disconnect.sh"

_install_print_stubs
T5_CALL_LOG="$WORK_DIR/t5-calls.txt"; : > "$T5_CALL_LOG"
STUB_CALL_LOG="$T5_CALL_LOG" STUB_TEAMS_CONF_DIR="$T5_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T5_FRAMEWORK" WORKING_DIR="$T5_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if grep -qF "ops-west|client=|project=project1" "$T5_CALL_LOG" \
    && ! grep -qE '^ops\|' "$T5_CALL_LOG" \
    && ! grep -qi "takes no parameters" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected 'ops-west|client=|project=project1', no 'ops|' call, no 'takes no parameters' warning; call_log=$(cat "$T5_CALL_LOG"); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T6 — NULLGLOB-SAFETY: an empty WORKING_DIR must not crash regardless of the
# caller's nullglob setting, and must invoke the installer zero times. Run
# inside a subshell with the file's own `set -eo pipefail` (no -u) to match
# the real caller context exactly.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T6: empty WORKING_DIR (no *-connect.sh at all) is safe under both nullglob states"
T6_FRAMEWORK="$(_next_sandbox)"
T6_WORKING="$(_next_sandbox)"
mkdir -p "$T6_FRAMEWORK/share/teams"
cat > "$T6_FRAMEWORK/share/teams/academy.conf" <<'CONF'
TEAM_ID="academy"
TEAM_HAS_PROJECTS="false"
CONF
# T6_WORKING deliberately left empty — no *-connect.sh files.

T6_OK=true
for T6_NULLGLOB_MODE in unset set; do
    _install_print_stubs
    T6_CALL_LOG="$WORK_DIR/t6-calls-${T6_NULLGLOB_MODE}.txt"; : > "$T6_CALL_LOG"
    T6_RC=0
    (
        set -eo pipefail   # upgrade.sh's exact options — deliberately WITHOUT -u
        if [ "$T6_NULLGLOB_MODE" = "set" ]; then shopt -s nullglob; fi
        STUB_CALL_LOG="$T6_CALL_LOG" STUB_TEAMS_CONF_DIR="$T6_FRAMEWORK/share/teams" STUB_FAIL=false \
        FRAMEWORK_DIR="$T6_FRAMEWORK" WORKING_DIR="$T6_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
            update_connect_scripts
        echo "SURVIVED_${T6_NULLGLOB_MODE}"
    ) >"$WORK_DIR/t6-stdout-${T6_NULLGLOB_MODE}.log" 2>&1 || T6_RC=$?
    if [ "$T6_RC" != "0" ] || ! grep -q "SURVIVED_${T6_NULLGLOB_MODE}" "$WORK_DIR/t6-stdout-${T6_NULLGLOB_MODE}.log" || [ -s "$T6_CALL_LOG" ]; then
        T6_OK=false
        T6_FAIL_DETAIL="mode=$T6_NULLGLOB_MODE rc=$T6_RC stdout=$(cat "$WORK_DIR/t6-stdout-${T6_NULLGLOB_MODE}.log") call_log=$(cat "$T6_CALL_LOG" 2>/dev/null)"
    fi
done
if [ "$T6_OK" = true ]; then
    test_pass
else
    test_fail "empty WORKING_DIR must survive with zero installer calls in both nullglob states; ${T6_FAIL_DETAIL:-}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7 — SHAPE-REJECT (project-only): a 3-component instance against a
# template that takes a bare project must be rejected, not silently
# mis-split into --project <2-component-string-with-a-dash>.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7: finance-acme-work (3 components) against project-only finance template is rejected, not mis-split"
T7_FRAMEWORK="$(_next_sandbox)"
T7_WORKING="$(_next_sandbox)"
mkdir -p "$T7_FRAMEWORK/share/teams"
cat > "$T7_FRAMEWORK/share/teams/finance.conf" <<'CONF'
TEAM_ID="finance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="personal"
CONF
echo "stale-finance-acme-work-connect" > "$T7_WORKING/finance-acme-work-connect.sh"

_install_print_stubs
T7_CALL_LOG="$WORK_DIR/t7-calls.txt"; : > "$T7_CALL_LOG"
STUB_CALL_LOG="$T7_CALL_LOG" STUB_TEAMS_CONF_DIR="$T7_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T7_FRAMEWORK" WORKING_DIR="$T7_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if [ ! -s "$T7_CALL_LOG" ] && grep -qi "contains a dash" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected the installer never invoked + a 'contains a dash' skip warning; call_log=$(cat "$T7_CALL_LOG" 2>/dev/null); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T8 — SHAPE-REJECT (client+project): a 2-component instance against a
# template requiring client+project must be rejected, not silently
# mis-split into --client X --project X (duplicating the single component).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T8: freelance-acme (2 components) against client+project freelance template is rejected, not mis-split"
T8_FRAMEWORK="$(_next_sandbox)"
T8_WORKING="$(_next_sandbox)"
mkdir -p "$T8_FRAMEWORK/share/teams"
cat > "$T8_FRAMEWORK/share/teams/freelance.conf" <<'CONF'
TEAM_ID="freelance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="true"
TEAM_DEFAULT_PROJECT="default"
CONF
echo "stale-freelance-acme-connect" > "$T8_WORKING/freelance-acme-connect.sh"

_install_print_stubs
T8_CALL_LOG="$WORK_DIR/t8-calls.txt"; : > "$T8_CALL_LOG"
STUB_CALL_LOG="$T8_CALL_LOG" STUB_TEAMS_CONF_DIR="$T8_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T8_FRAMEWORK" WORKING_DIR="$T8_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if [ ! -s "$T8_CALL_LOG" ] && grep -qi "cannot split" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected the installer never invoked + a 'cannot split' skip warning; call_log=$(cat "$T8_CALL_LOG" 2>/dev/null); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — EMPTY-INSTANCE edge case: a file literally named "-connect.sh" yields
# an empty instance id after suffix-stripping. Documented FINDING: this is a
# silent `continue` in the source (never reaches the warning branch), so it
# is not even counted in the "skipped" tally — an observability gap, not a
# correctness bug (the installer is still never invoked on it).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9 [FINDING]: a literal '-connect.sh' file (empty instance id) is never handed to the installer, but is also silently uncounted"
T9_FRAMEWORK="$(_next_sandbox)"
T9_WORKING="$(_next_sandbox)"
mkdir -p "$T9_FRAMEWORK/share/teams"
cat > "$T9_FRAMEWORK/share/teams/academy.conf" <<'CONF'
TEAM_ID="academy"
TEAM_HAS_PROJECTS="false"
CONF
: > "$T9_WORKING/-connect.sh"

_install_print_stubs
T9_CALL_LOG="$WORK_DIR/t9-calls.txt"; : > "$T9_CALL_LOG"
STUB_CALL_LOG="$T9_CALL_LOG" STUB_TEAMS_CONF_DIR="$T9_FRAMEWORK/share/teams" STUB_FAIL=false \
FRAMEWORK_DIR="$T9_FRAMEWORK" WORKING_DIR="$T9_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
    update_connect_scripts >/dev/null 2>&1
if [ ! -s "$T9_CALL_LOG" ] \
    && grep -qi "No installed team connect scripts to refresh" "$_STUB_LOG" \
    && ! grep -qi "skipped" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected installer never invoked, 'No installed team connect scripts to refresh' (i.e. NOT counted as skipped either); call_log=$(cat "$T9_CALL_LOG" 2>/dev/null); stub_log=$(cat "$_STUB_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# NC1/NC2/NC3 — NEGATIVE CONTROL: replay the T1/T2/T3 fixtures against the
# PRE-FIX algorithm (_pre_fix_update_connect_scripts, embedded above verbatim
# from tap commit f7557b2). A "PASS" here means the pre-fix code reproduced
# the DEFECT it should reproduce — proving this harness actually discriminates
# between the buggy and fixed implementations, not just that the new code
# looks reasonable in isolation.
# ═══════════════════════════════════════════════════════════════════════════
test_start "NC1 [negative control]: pre-fix code NEVER refreshes freelance-acme-webapp (bare call fails, no client resolvable non-interactively)"
NC1_FRAMEWORK="$(_next_sandbox)"
NC1_WORKING="$(_next_sandbox)"
mkdir -p "$NC1_FRAMEWORK/share/teams"
cat > "$NC1_FRAMEWORK/share/teams/freelance.conf" <<'CONF'
TEAM_ID="freelance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="true"
TEAM_DEFAULT_PROJECT="default"
CONF
echo "stale-freelance-acme-webapp-connect" > "$NC1_WORKING/freelance-acme-webapp-connect.sh"
NC1_BEFORE="$(cat "$NC1_WORKING/freelance-acme-webapp-connect.sh")"

_install_print_stubs
NC1_CALL_LOG="$WORK_DIR/nc1-calls.txt"; : > "$NC1_CALL_LOG"
# Wrap in the file's OWN `set -eo pipefail` (no -u) — exactly the global
# option state active when the real upgrade.sh calls this function directly
# (not in a subshell). WITHOUT this wrapping, the pre-fix code's
# `installer | sed` pipeline's exit status collapses to sed's (always 0),
# so a failing install-team.sh call would be misreported as a SUCCESS by
# this harness — a false negative-control result discovered while writing
# this suite (see report). Matching the real option state is what makes the
# pre-fix code's own fail-soft branch actually fire here.
(
    set -eo pipefail
    STUB_CALL_LOG="$NC1_CALL_LOG" STUB_TEAMS_CONF_DIR="$NC1_FRAMEWORK/share/teams" STUB_FAIL=false \
    FRAMEWORK_DIR="$NC1_FRAMEWORK" WORKING_DIR="$NC1_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        _pre_fix_update_connect_scripts
) >/dev/null 2>&1
NC1_AFTER="$(cat "$NC1_WORKING/freelance-acme-webapp-connect.sh" 2>/dev/null)"
if grep -qF "freelance|client=|project=" "$NC1_CALL_LOG" \
    && [ "$NC1_AFTER" = "$NC1_BEFORE" ] \
    && grep -qi "Failed to refresh freelance connect/disconnect scripts" "$_STUB_LOG"; then
    test_pass
else
    test_fail "expected pre-fix code to call bare 'freelance' (no client/project) and FAIL, leaving content unchanged — if this now succeeds, the negative control no longer discriminates; call_log=$(cat "$NC1_CALL_LOG"); before=$NC1_BEFORE after=$NC1_AFTER; stub_log=$(cat "$_STUB_LOG")"
fi

test_start "NC2 [negative control]: pre-fix code mis-materialises finance-personal while leaving finance-work stale"
NC2_FRAMEWORK="$(_next_sandbox)"
NC2_WORKING="$(_next_sandbox)"
mkdir -p "$NC2_FRAMEWORK/share/teams"
cat > "$NC2_FRAMEWORK/share/teams/finance.conf" <<'CONF'
TEAM_ID="finance"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="personal"
CONF
echo "stale-finance-work-connect" > "$NC2_WORKING/finance-work-connect.sh"
NC2_BEFORE="$(cat "$NC2_WORKING/finance-work-connect.sh")"

_install_print_stubs
NC2_CALL_LOG="$WORK_DIR/nc2-calls.txt"; : > "$NC2_CALL_LOG"
(
    set -eo pipefail
    STUB_CALL_LOG="$NC2_CALL_LOG" STUB_TEAMS_CONF_DIR="$NC2_FRAMEWORK/share/teams" STUB_FAIL=false \
    FRAMEWORK_DIR="$NC2_FRAMEWORK" WORKING_DIR="$NC2_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        _pre_fix_update_connect_scripts
) >/dev/null 2>&1
NC2_AFTER="$(cat "$NC2_WORKING/finance-work-connect.sh" 2>/dev/null)"
if [ -f "$NC2_WORKING/finance-personal-connect.sh" ] \
    && [ "$NC2_AFTER" = "$NC2_BEFORE" ]; then
    test_pass
else
    test_fail "expected pre-fix code to spuriously CREATE finance-personal-connect.sh while leaving finance-work-connect.sh untouched/stale — if finance-personal was not created, the negative control no longer discriminates; personal_exists=$([ -f "$NC2_WORKING/finance-personal-connect.sh" ] && echo yes || echo no); work_before=$NC2_BEFORE work_after=$NC2_AFTER"
fi

test_start "NC3 [negative control, SYNTHETIC]: pre-fix unanchored glob false-matches 'med' against medical-general-connect.sh, materialising a med-connect.sh this box never installed"
NC3_FRAMEWORK="$(_next_sandbox)"
NC3_WORKING="$(_next_sandbox)"
mkdir -p "$NC3_FRAMEWORK/share/teams"
cat > "$NC3_FRAMEWORK/share/teams/med.conf" <<'CONF'
TEAM_ID="med"
TEAM_HAS_PROJECTS="false"
CONF
cat > "$NC3_FRAMEWORK/share/teams/medical.conf" <<'CONF'
TEAM_ID="medical"
TEAM_HAS_PROJECTS="true"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_DEFAULT_PROJECT="general"
CONF
echo "stale-medical-general-connect" > "$NC3_WORKING/medical-general-connect.sh"
# Deliberately no med-connect.sh — "med" was never installed on this box.

_install_print_stubs
NC3_CALL_LOG="$WORK_DIR/nc3-calls.txt"; : > "$NC3_CALL_LOG"
(
    set -eo pipefail
    STUB_CALL_LOG="$NC3_CALL_LOG" STUB_TEAMS_CONF_DIR="$NC3_FRAMEWORK/share/teams" STUB_FAIL=false \
    FRAMEWORK_DIR="$NC3_FRAMEWORK" WORKING_DIR="$NC3_WORKING" LIBEXEC_DIR="$STUB_LIBEXEC" DRY_RUN=false \
        _pre_fix_update_connect_scripts
) >/dev/null 2>&1
if [ -f "$NC3_WORKING/med-connect.sh" ] && grep -qE '^med\|' "$NC3_CALL_LOG"; then
    test_pass
else
    test_fail "expected pre-fix code's unanchored '\${team_id}*-connect.sh' glob to false-match medical-general-connect.sh for team_id=med, spuriously materialising med-connect.sh — if this did not happen, the negative control no longer discriminates; med_exists=$([ -f "$NC3_WORKING/med-connect.sh" ] && echo yes || echo no); call_log=$(cat "$NC3_CALL_LOG")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone only; test-runner.sh owns totals when sourced by it).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "XACA-0834 connect-script-recovery tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
