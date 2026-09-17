#!/bin/bash
# test-xaca-1268-upgrade-creates-missing-group.sh
#
# NOTE ON SHELL TARGETING: this suite deliberately does NOT self-re-exec
# under /bin/bash the way test-xaca-0931-persona-deploy-and-parity.sh does.
# That pattern is a documented WORKAROUND for XACA-0865 (test-runner.sh's
# run_test_file() hardcodes an unqualified `bash`, so a suite that must
# verify literal /bin/bash-3.2-only behaviour has no other way to land on
# it) and tests/ci-manifest's own header says explicitly: "the re-exec
# blocks should be removed, not copied into new suites." This suite has no
# assertion that depends on the interpreter being EXACTLY 3.x (unlike
# XACA-0931's TG1, which checks pt_enumerate_targets' bash-3.2-specific
# empty-array quirk) — it exercises product code (update_team_personas and
# its dependents) that must behave identically under any bash the shipped
# tap actually runs on. It is hand-verified under both `/bin/bash` 3.2.57
# and a newer PATH bash before being registered in tests/ci-manifest as a
# plain (non-excluded) plain-shell suite.
#
# Regression tests for XACA-1268: `aiteamforge upgrade` never created a
# persona GROUP source directory (${WORKING_DIR}/<group>/personas/agents) for
# a team that was registered on a machine but never went through
# install-team.sh — measured live as `dns` on M4Mini
# (kanban/plans/XACA-1268/XACA-1268-000-lead-findings.md). This is an
# ENUMERATION fix (XACA-1268-003): update_team_personas() in
# aiteamforge-upgrade.sh gained _xaca1268_hosted_groups() (a two-rail hosted-
# group predicate) plus helpers _xaca1268_load_manifest/_load_registry/
# _expand_path/_dir_state/_has_git_root/_best_conf_team. No new create path
# was added — _xaca0925_refresh_team_personas() already creates the
# destination fresh from the Cellar when missing.
#
# Binding design: kanban/plans/XACA-1268/XACA-1268-002-create-semantics-
# decision.md. Three assertions the ticket requires, all present below:
#   B1  POSITIVE       — a hosted group's dir, deliberately absent, IS
#                         created (T1).
#   B2  NEGATIVE CONTROL — the SAME assertion, run against a CONTENT-
#                         resolved pre-fix version of update_team_personas
#                         and its dependents (the newest commit in this
#                         file's history whose blob lacks
#                         _xaca1268_hosted_groups — resolved by content,
#                         never by position such as HEAD~1, so this suite
#                         stays re-runnable after its own commit and in CI,
#                         where HEAD~1 is unrelated), FAILS — the dir is
#                         NOT created (T2). A test that cannot fail proves
#                         nothing.
#   B3  DOES-NOT-HOST   — `mainevent` (a group shared by ios/android/
#                         firebase/command with NO share/teams/mainevent.conf
#                         of its own — 12 shipped groups, 11 team confs) is
#                         NOT created when nothing on the (simulated) machine
#                         genuinely hosts a consumer of it (T3a), and IS
#                         created when one genuinely does (T3b) — the
#                         contrast proves T3a isn't vacuously "mainevent is
#                         never creatable by this harness".
#
# Fail-closed matrix coverage (XACA-1268-002 §"Fail-closed matrix"), the
# recurring rule this ticket family exists to enforce — "the union is
# legitimately empty" and "the union could not be computed" must NEVER
# collapse into the same signal:
#   T5  manifest absent (row 2)         — Rail 1 off, DISTINCT message,
#                                          Rail 2 unaffected.
#   T6  manifest unparseable (row 3)    — Rail 1 off, a DIFFERENT distinct
#                                          message from T5's.
#   T7  registry absent (row 6)         — BOTH rails off, named warning,
#                                          run does NOT abort (fail-soft).
#   T8  registry unparseable (row 7)    — BOTH rails off, a DIFFERENT
#                                          distinct message from T7's.
#   T9  neither jq nor python3 (row 8)  — BOTH rails off, named warning.
#   T10 unreadable working_dir (row 10) — counted INDETERMINATE, never
#                                          folded into "not hosted".
#   T11 idempotence                     — a second run writes nothing (no
#                                          backup, no cp) once content
#                                          matches the Cellar.
#   T12 --dry-run                       — creates nothing on disk.
#   T13 legitimately-empty (row 13)     — clean sources + empty union print
#                                          an explicit SUCCESS line, never
#                                          silence (the M1Pro/M1Mini steady
#                                          state measured in -002).
#
# All filesystem activity is sandboxed under TEST_TMP_DIR with a fake $HOME
# and a fake AITEAMFORGE_CONFIG (team-paths.json). NEVER touches the real
# $HOME/aiteamforge, ~/.aiteamforge, ~/aiteamforge-backups, or this repo's
# own share/personas — installer-test safety rule (this box must never have
# the tap installed; per-machine sandboxing per CLAUDE.md). This suite only
# READS the real tap tree (libexec/lib/config.sh, libexec/lib/
# persona-targets.sh, and — via `git log`/`git show`, resolved by CONTENT
# rather than by position (see the resolution block below) — a pre-fix
# blob of aiteamforge-upgrade.sh for the negative control) as
# fixture/dependency source; it never writes there.
#
# Extraction is TRANSITIVE (mirrors test-xaca-0925-persona-refresh.sh), not a
# hand-picked function-name list — deliberately, to avoid being the THIRD
# instance of the exact drift this ticket's own -004 dispatch documents as
# the SECOND (test-xaca-0931-persona-deploy-and-parity.sh's _FN_NAMES list
# drifted when update_team_personas gained new callees and had to be
# hand-patched with the six/seven new _xaca1268_* names). A suite that
# re-derives its own extraction list from the real call graph cannot drift
# that way.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
PT_LIB="$TAP_ROOT/libexec/lib/persona-targets.sh"

for _need in "$UPGRADE_SH" "$CONFIG_LIB" "$PT_LIB"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

if ! command -v git >/dev/null 2>&1; then
    echo "FATAL: git is required by this suite (negative control + git-work-tree fixtures) and was not found" >&2
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
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST -- $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory (runner-supplied or our own). Includes a fake $HOME so
# ~/aiteamforge-backups and ~/.aiteamforge assertions NEVER touch the real
# home directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1268-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
# Isolate TMPDIR too (feedback_shared_tmpdir_leak_counts_are_contaminated) —
# every mktemp call below (including the ones the extracted product code
# itself makes, e.g. backup dirs under HOME) stays under our own tree.
export TMPDIR="$TEST_TMP_DIR"
_xaca1268_cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        chmod -R u+rwx "$TEST_TMP_DIR" 2>/dev/null
        \rm -rf "$TEST_TMP_DIR"
    fi
}
trap _xaca1268_cleanup EXIT

WORK_DIR="$TEST_TMP_DIR/xaca1268"
mkdir -p "$WORK_DIR"
_next_sandbox() { mktemp -d "$WORK_DIR/sbx-XXXXXX"; }

# ─────────────────────────────────────────────────────────────────────────────
# Transitive function extraction — generalised over an arbitrary source file
# so it can build BOTH the current (post-fix) bundle and, for the negative
# control, a bundle from a CONTENT-resolved pre-fix blob of
# aiteamforge-upgrade.sh (never a positional ref like HEAD~1 — see the
# resolution block below for why). Mirrors test-xaca-0925-persona-
# refresh.sh's discovery loop.
# ─────────────────────────────────────────────────────────────────────────────
_extract_fn_from() {
    # _extract_fn_from <src_file> <fn_name>
    awk -v fn="$2" '
      $0 ~ ("^" fn "\\(\\) \\{") { capture=1 }
      capture { print }
      capture && /^}$/ { exit }
    ' "$1"
}

# _build_bundle <src_file> <out_file> <seed_fn> — writes the seed function
# plus every top-level function it (transitively) calls, from <src_file>,
# into <out_file>. Strips full-line comments before call-detection so prose
# that merely NAMES a function does not vacuum it in (XACA-0931 precedent —
# see test-xaca-0925-persona-refresh.sh's own comment on this exact trap).
_build_bundle() {
    local src="$1" out="$2" seed="$3"
    local all_fns
    all_fns="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$src" | sed -E 's/\(\) \{$//')"
    local fn_src
    fn_src="$(_extract_fn_from "$src" "$seed")"
    if [ -z "$fn_src" ]; then
        echo "FATAL: could not extract seed function '$seed' from $src" >&2
        return 1
    fi
    local combined="$fn_src"
    local extracted_names
    extracted_names=$'\n'"${seed}"$'\n'
    local pass=0 added cand helper_src
    while [ "$pass" -lt 8 ]; do
        pass=$((pass + 1))
        added=false
        for cand in $all_fns; do
            case "$extracted_names" in
                *$'\n'"${cand}"$'\n'*) continue ;;
            esac
            if printf '%s\n' "$combined" | sed -E '/^[[:space:]]*#/d' | grep -qE "(^|[^A-Za-z0-9_])${cand}([^A-Za-z0-9_(]|\$)"; then
                helper_src="$(_extract_fn_from "$src" "$cand")"
                [ -z "$helper_src" ] && continue
                combined="${helper_src}"$'\n\n'"${combined}"
                extracted_names="${extracted_names}${cand}"$'\n'
                added=true
            fi
        done
        [ "$added" = true ] || break
    done
    printf '%s\n' "$combined" > "$out"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Build + source the CURRENT (post-fix) bundle into THIS process. config.sh
# and persona-targets.sh are dependency-free libraries — safe to source
# directly, exactly as the real upgrade.sh has them available at call time.
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$CONFIG_LIB"
# shellcheck disable=SC1090
source "$PT_LIB"

EXTRACTED_NEW="$WORK_DIR/extracted-new.sh"
if ! _build_bundle "$UPGRADE_SH" "$EXTRACTED_NEW" update_team_personas; then
    exit 1
fi
# shellcheck disable=SC1090
source "$EXTRACTED_NEW"
declare -f update_team_personas >/dev/null || { echo "FATAL: update_team_personas not defined after extraction" >&2; exit 1; }
declare -f _xaca1268_hosted_groups >/dev/null || { echo "FATAL: _xaca1268_hosted_groups not defined after extraction -- XACA-1268-003 not present in $UPGRADE_SH?" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Build the PRE-FIX bundle — used ONLY by T2's negative control, and ONLY
# ever run in a separate `bash` subprocess (see _run_utp_old below), never
# sourced into THIS process: its function names collide with the ones just
# sourced above (update_team_personas, _xaca0925_refresh_team_personas,
# ...) and a second `source` here would silently shadow the fix under test
# for every subsequent positive test.
#
# Resolved by CONTENT, not by position (`HEAD~1`). `HEAD~1` is only
# "pre-fix" at the instant this suite is first authored on top of -003 --
# the moment THIS suite's own commit lands, `HEAD~1` becomes -003 itself
# (the fix), and in CI `HEAD` is a PR merge commit with an unrelated
# `HEAD~1` entirely. A position-based control is therefore not re-runnable
# even once, which is the XACA-1254 failure (a suite that cannot run) in a
# new costume. Instead, walk this file's own history
# (`git log -- libexec/commands/aiteamforge-upgrade.sh`) and take the
# NEWEST commit whose blob does NOT contain the _xaca1268_hosted_groups
# marker -- true regardless of how many commits land on top of this suite
# afterward. FAILS CLOSED: an empty history walk (shallow clone) or a
# history where every reachable revision already carries the fix both
# FATAL with a specific, distinguishable reason -- never silently skip into
# a green. `git show <ref>:<path>` must be run from INSIDE homebrew-tap/
# (TAP_ROOT) -- the outer repo reads a submodule path as empty.
# ─────────────────────────────────────────────────────────────────────────────
UPGRADE_SH_OLD="$WORK_DIR/upgrade-old.sh"
UPGRADE_SH_OLD_SHA=""
_UPGRADE_SH_HISTORY="$(git -C "$TAP_ROOT" log --format=%H -- libexec/commands/aiteamforge-upgrade.sh 2>"$WORK_DIR/git-log-old.log")"
if [ -z "$_UPGRADE_SH_HISTORY" ]; then
    echo "FATAL: could not enumerate aiteamforge-upgrade.sh's git history for the negative control (git log returned nothing) -- $(cat "$WORK_DIR/git-log-old.log" 2>/dev/null). A shallow/truncated clone would show exactly this shape; the negative control needs full history to find a genuinely pre-fix blob and refuses to guess." >&2
    exit 1
fi
for _sha_iter in $_UPGRADE_SH_HISTORY; do
    if ! git -C "$TAP_ROOT" show "${_sha_iter}:libexec/commands/aiteamforge-upgrade.sh" > "$WORK_DIR/candidate-old.sh" 2>"$WORK_DIR/git-show-candidate.log"; then
        continue   # unreadable blob at this SHA -- keep walking rather than aborting on one bad revision
    fi
    if ! grep -q '_xaca1268_hosted_groups' "$WORK_DIR/candidate-old.sh"; then
        UPGRADE_SH_OLD_SHA="$_sha_iter"
        cp "$WORK_DIR/candidate-old.sh" "$UPGRADE_SH_OLD"
        break
    fi
done
if [ -z "$UPGRADE_SH_OLD_SHA" ]; then
    echo "FATAL: could not find any commit in aiteamforge-upgrade.sh's reachable history whose blob lacks _xaca1268_hosted_groups -- either history is truncated (shallow clone) or every reachable revision already contains the XACA-1268-003 fix. The negative control (T2) needs a genuinely pre-fix blob; refusing to run rather than report a vacuous pass." >&2
    exit 1
fi
# Keep this check even though the loop above already enforces it -- cheap
# defense-in-depth against a future refactor of the loop breaking the
# invariant silently.
if grep -q '_xaca1268_hosted_groups' "$UPGRADE_SH_OLD"; then
    echo "FATAL: internal error -- resolved pre-fix blob ${UPGRADE_SH_OLD_SHA} still contains _xaca1268_hosted_groups after the content-based scan; this should be unreachable." >&2
    exit 1
fi
EXTRACTED_OLD="$WORK_DIR/extracted-old.sh"
if ! _build_bundle "$UPGRADE_SH_OLD" "$EXTRACTED_OLD" update_team_personas; then
    exit 1
fi

# print_* stubs that record output so tests can grep for specific warning
# text (mirrors test-xaca-0771/0925/0931's printf-based stubs).
_STUB_LOG="$WORK_DIR/stub-output.log"
_install_print_stubs() {
    : > "$_STUB_LOG"
    for _p in print_section print_info print_success print_warning print_error; do
        eval "${_p}() { printf '%s\n' \"\$*\" >> \"\$_STUB_LOG\"; }"
    done
}
_install_print_stubs

# ─────────────────────────────────────────────────────────────────────────────
# Fixture builders
# ─────────────────────────────────────────────────────────────────────────────

# _seed_framework_group <fw_dir> <group> <basename> <content> [<basename> <content> ...]
_seed_framework_group() {
    local fw="$1" group="$2"; shift 2
    mkdir -p "${fw}/share/personas/${group}/agents"
    while [ $# -ge 2 ]; do
        printf '%s\n' "$2" > "${fw}/share/personas/${group}/agents/$1"
        shift 2
    done
}

# _seed_team_conf <fw_dir> <team_basename> — content is irrelevant to
# _xaca1268_best_conf_team (only the *.conf basename is read); an empty file
# is deliberately used so this fixture can never be confused with the
# richer TEAM_WORKING_DIR-bearing confs pt_enumerate_targets reads.
_seed_team_conf() {
    local fw="$1" team="$2"
    mkdir -p "${fw}/share/teams"
    : > "${fw}/share/teams/${team}.conf"
}

# _seed_manifest <fw_dir> <team> <space-separated-groups> [<team> <groups> ...]
_seed_manifest() {
    local fw="$1"; shift
    mkdir -p "${fw}/share/scripts"
    local json='{"deployments":[' first=true team groups garr g gfirst
    while [ $# -ge 2 ]; do
        team="$1"; groups="$2"; shift 2
        [ "$first" = true ] || json="${json},"
        first=false
        garr="[" gfirst=true
        for g in $groups; do
            [ "$gfirst" = true ] || garr="${garr},"
            gfirst=false
            garr="${garr}\"${g}\""
        done
        garr="${garr}]"
        json="${json}{\"team\":\"${team}\",\"groups\":${garr}}"
    done
    json="${json}]}"
    printf '%s' "$json" > "${fw}/share/scripts/personas-manifest.json"
}

# _seed_registry <reg_path> [<slug> <working_dir> <kanban_dir> ...]
_seed_registry() {
    local path="$1"; shift
    mkdir -p "$(dirname "$path")"
    local json='{"teams":{' first=true slug wd kd
    while [ $# -ge 3 ]; do
        slug="$1"; wd="$2"; kd="$3"; shift 3
        [ "$first" = true ] || json="${json},"
        first=false
        json="${json}\"${slug}\":{\"working_dir\":\"${wd}\",\"kanban_dir\":\"${kd}\"}"
    done
    json="${json}}}"
    printf '%s' "$json" > "$path"
}

# _mk_git_repo <dir> — a real, minimal git work tree at <dir>.
_mk_git_repo() {
    local d="$1"
    mkdir -p "$d"
    local out
    if ! out=$( cd "$d" && git init -q . && git config user.email t@t.test && git config user.name t 2>&1 ); then
        echo "FIXTURE ERROR: git init failed in ${d}: ${out}" >&2
        return 1
    fi
    return 0
}

# _mk_no_tool_path <dest_bin_dir> <excluded_name> [<excluded_name> ...]
# Symlinks every real PATH entry's executables into dest_bin_dir EXCEPT the
# named tools, so PATH=<dest_bin_dir> simulates that tool's absence while
# bash/git/mkdir/cp/cmp/awk/sed/... stay resolvable. Mirrors
# test-xaca-0931-persona-deploy-and-parity.sh's TE1 python3-hiding
# technique, generalised to an arbitrary exclusion list.
_mk_no_tool_path() {
    local dest="$1"; shift
    mkdir -p "$dest"
    local OLD_IFS="$IFS"
    IFS=':'
    local d f b excluded match
    for d in $PATH; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            [ -e "$f" ] || continue
            b="$(basename "$f")"
            match=false
            for excluded in "$@"; do
                [ "$b" = "$excluded" ] && { match=true; break; }
            done
            [ "$match" = true ] && continue
            [ -e "$dest/$b" ] || ln -sf "$f" "$dest/$b" 2>/dev/null
        done
    done
    IFS="$OLD_IFS"
}

# Invoke update_team_personas() (CURRENT/post-fix bundle, already sourced
# into this process) in the real script's execution regime (set -eo
# pipefail) inside a subshell so a bug under test can never abort this
# suite. Writes combined stdout+stderr to <logfile>; returns the subshell's
# exit code.
_run_utp() {
    local home="$1" fw="$2" wd="$3" reg="$4" dry="$5" logfile="$6"
    _install_print_stubs
    (
        set -eo pipefail
        HOME="$home" AITEAMFORGE_DIR="$wd" FRAMEWORK_DIR="$fw" WORKING_DIR="$wd" \
        AITEAMFORGE_CONFIG="$reg" DRY_RUN="$dry" FORCE=false \
        update_team_personas
    ) >"$logfile" 2>&1
}

# Invoke update_team_personas() from the content-resolved pre-fix bundle —
# in a genuinely SEPARATE bash process (never sourced into this one; see the
# comment above EXTRACTED_OLD) so its function definitions cannot collide
# with the current/post-fix ones already sourced here.
_run_utp_old() {
    local home="$1" fw="$2" wd="$3" reg="$4" dry="$5" logfile="$6"
    local runner="$WORK_DIR/run-old-utp.sh"
    {
        printf '%s\n' '#!/bin/bash'
        printf '%s\n' 'set -eo pipefail'
        printf 'source %q\n' "$CONFIG_LIB"
        printf 'source %q\n' "$PT_LIB"
        printf 'source %q\n' "$EXTRACTED_OLD"
        printf '%s\n' 'for _p in print_section print_info print_success print_warning print_error; do'
        printf '%s\n' '  eval "${_p}() { printf '"'"'%s\n'"'"' \"\$*\" >> \"\$_STUB_LOG\"; }"'
        printf '%s\n' 'done'
        printf '%s\n' 'update_team_personas'
    } > "$runner"
    (
        HOME="$home" AITEAMFORGE_DIR="$wd" FRAMEWORK_DIR="$fw" WORKING_DIR="$wd" \
        AITEAMFORGE_CONFIG="$reg" DRY_RUN="$dry" FORCE=false _STUB_LOG="$_STUB_LOG" \
        bash "$runner"
    ) >"$logfile" 2>&1
}

echo "=== XACA-1268: hosted-group enumeration in update_team_personas() ==="

# ═══════════════════════════════════════════════════════════════════════════
# T1 — POSITIVE: a hosted group's source dir, deliberately absent, IS created
# ═══════════════════════════════════════════════════════════════════════════
test_start "T1 (POSITIVE): dns hosted-but-unprovisioned -> WORKING_DIR/dns/personas/agents is CREATED"
T1_FW="$(_next_sandbox)"; T1_WD="$(_next_sandbox)"; T1_HOME="$(_next_sandbox)"
T1_PROJ="$(_next_sandbox)"; T1_KANBAN="$(_next_sandbox)"
T1_REG="$T1_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T1_FW" dns dns_char_role_persona.md "DNS PERSONA CONTENT V1"
_seed_team_conf "$T1_FW" dns
_seed_manifest "$T1_FW" dns dns
_mk_git_repo "$T1_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T1_REG" dns "$T1_PROJ" "$T1_KANBAN"
if [ -e "$T1_WD/dns/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: $T1_WD/dns/personas/agents already exists -- test would be vacuous"
else
    T1_LOG="$WORK_DIR/t1.log"
    _run_utp "$T1_HOME" "$T1_FW" "$T1_WD" "$T1_REG" false "$T1_LOG"
    T1_RC=$?
    if [ "$T1_RC" -eq 0 ] \
        && [ -f "$T1_WD/dns/personas/agents/dns_char_role_persona.md" ] \
        && cmp -s "$T1_FW/share/personas/dns/agents/dns_char_role_persona.md" "$T1_WD/dns/personas/agents/dns_char_role_persona.md"; then
        test_pass
    else
        test_fail "expected WORKING_DIR/dns/personas/agents to be created with Cellar content; rc=$T1_RC log=$(cat "$T1_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T2 — NEGATIVE CONTROL: the SAME T1 fixture, run against the CONTENT-
# resolved pre-fix commit's update_team_personas (the newest commit whose
# blob lacks _xaca1268_hosted_groups — see the resolution block above),
# must FAIL to create the dir. A test that cannot fail proves nothing
# (feedback_negctrl_seed_placement_and_self_satisfying_anchor).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T2 (NEGATIVE CONTROL): the T1 assertion FAILS against the content-resolved pre-fix update_team_personas (${UPGRADE_SH_OLD_SHA})"
T2_FW="$(_next_sandbox)"; T2_WD="$(_next_sandbox)"; T2_HOME="$(_next_sandbox)"
T2_PROJ="$(_next_sandbox)"; T2_KANBAN="$(_next_sandbox)"
T2_REG="$T2_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T2_FW" dns dns_char_role_persona.md "DNS PERSONA CONTENT V1"
_seed_team_conf "$T2_FW" dns
_seed_manifest "$T2_FW" dns dns
_mk_git_repo "$T2_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T2_REG" dns "$T2_PROJ" "$T2_KANBAN"
if [ -e "$T2_WD/dns/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: $T2_WD/dns/personas/agents already exists -- test would be vacuous"
else
    T2_LOG="$WORK_DIR/t2.log"
    _run_utp_old "$T2_HOME" "$T2_FW" "$T2_WD" "$T2_REG" false "$T2_LOG"
    T2_RC=$?
    if [ ! -e "$T2_WD/dns/personas/agents" ]; then
        test_pass
        echo "     (negative control confirmed -- verbatim pre-fix run against ${UPGRADE_SH_OLD_SHA}, rc=$T2_RC:)" >&2
        sed 's/^/       /' "$T2_LOG" >&2
        echo "       [dir $T2_WD/dns/personas/agents does not exist after the pre-fix run]" >&2
    else
        test_fail "the PRE-FIX code created $T2_WD/dns/personas/agents too -- the negative control does not discriminate; this test proves nothing until it does. rc=$T2_RC log=$(cat "$T2_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3a — DOES-NOT-HOST: `mainevent` (shared group, no team conf of its own)
# is NOT created when the only registered team (firebase-shaped: registered,
# kanban_dir present, working_dir present but NOT a real git work tree --
# the "decommissioned-but-not-deregistered" signature from -002's firebase/
# M4Mini adjudication) does not genuinely host a Rail-1 consumer.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3a (DOES-NOT-HOST): mainevent is NOT created for a registered-but-not-git-hosted firebase-shaped team"
T3A_FW="$(_next_sandbox)"; T3A_WD="$(_next_sandbox)"; T3A_HOME="$(_next_sandbox)"
T3A_PROJ="$(_next_sandbox)"; T3A_KANBAN="$(_next_sandbox)"
T3A_REG="$T3A_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T3A_FW" firebase firebase_x.md "FIREBASE CONTENT"
_seed_framework_group "$T3A_FW" mainevent mainevent_x.md "MAINEVENT CONTENT"
_seed_team_conf "$T3A_FW" firebase
# Deliberately NO mainevent.conf -- matches the real shipped tree (12 groups,
# 11 team confs, no mainevent conf; XACA-1268-000 lead-findings §5/§9).
_seed_manifest "$T3A_FW" firebase "firebase mainevent"
# working_dir EXISTS but is NOT a git repo (mkdir only, no git init) --
# Rail 1 (_xaca1268_has_git_root) must read this as not-hosted.
mkdir -p "$T3A_PROJ"
_seed_registry "$T3A_REG" firebase "$T3A_PROJ" "$T3A_KANBAN"
if [ -e "$T3A_WD/mainevent/personas/agents" ] || [ -e "$T3A_WD/firebase/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: target dir(s) already exist -- test would be vacuous"
else
    T3A_LOG="$WORK_DIR/t3a.log"
    _run_utp "$T3A_HOME" "$T3A_FW" "$T3A_WD" "$T3A_REG" false "$T3A_LOG"
    if [ -d "$T3A_WD/firebase/personas/agents" ] && [ ! -e "$T3A_WD/mainevent/personas/agents" ]; then
        test_pass
    else
        test_fail "expected firebase/personas/agents created (Rail 2, proves the run executed) AND mainevent/personas/agents absent; firebase exists=$([ -d "$T3A_WD/firebase/personas/agents" ] && echo yes || echo no) mainevent exists=$([ -e "$T3A_WD/mainevent/personas/agents" ] && echo yes || echo no) log=$(cat "$T3A_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T3b — CONTRAST: the SAME shared `mainevent` group IS created when a
# genuine Rail-1 consumer (ios-shaped: real git work tree at working_dir,
# real kanban_dir) is registered instead -- proves T3a's absence is the
# predicate discriminating correctly, not "mainevent can never be created
# by this harness" (which would make T3a vacuous).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T3b (CONTRAST): mainevent IS created for a genuinely git-hosted ios-shaped team"
T3B_FW="$(_next_sandbox)"; T3B_WD="$(_next_sandbox)"; T3B_HOME="$(_next_sandbox)"
T3B_PROJ="$(_next_sandbox)"; T3B_KANBAN="$(_next_sandbox)"
T3B_REG="$T3B_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T3B_FW" ios ios_x.md "IOS CONTENT"
_seed_framework_group "$T3B_FW" mainevent mainevent_x.md "MAINEVENT CONTENT"
_seed_team_conf "$T3B_FW" ios
_seed_manifest "$T3B_FW" ios "ios mainevent"
_mk_git_repo "$T3B_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T3B_REG" ios "$T3B_PROJ" "$T3B_KANBAN"
if [ -e "$T3B_WD/mainevent/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: mainevent/personas/agents already exists -- test would be vacuous"
else
    T3B_LOG="$WORK_DIR/t3b.log"
    _run_utp "$T3B_HOME" "$T3B_FW" "$T3B_WD" "$T3B_REG" false "$T3B_LOG"
    if [ -d "$T3B_WD/mainevent/personas/agents" ]; then
        test_pass
    else
        test_fail "expected mainevent/personas/agents to be created via Rail 1 (ios's manifest row includes mainevent); log=$(cat "$T3B_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T5/T6 — fail-closed matrix rows 2/3: manifest absent vs. unparseable must
# print DIFFERENT, distinguishable messages, and Rail 2 (manifest-
# independent) must still create a team's own group either way.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T5 (matrix row 2): personas-manifest.json ABSENT -> Rail 1 off (named, distinct message), Rail 2 unaffected"
T5_FW="$(_next_sandbox)"; T5_WD="$(_next_sandbox)"; T5_HOME="$(_next_sandbox)"
T5_PROJ="$(_next_sandbox)"; T5_KANBAN="$(_next_sandbox)"
T5_REG="$T5_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T5_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T5_FW" dns
# Deliberately do NOT call _seed_manifest -- share/scripts/personas-manifest.json
# stays absent (models a Cellar predating XACA-1261).
_mk_git_repo "$T5_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T5_REG" dns "$T5_PROJ" "$T5_KANBAN"
T5_LOG="$WORK_DIR/t5.log"
_run_utp "$T5_HOME" "$T5_FW" "$T5_WD" "$T5_REG" false "$T5_LOG"
T5_MSG="$(grep -i "personas-manifest.json" "$_STUB_LOG" | grep -i "XACA-1268" || true)"
if [ -d "$T5_WD/dns/personas/agents" ] && printf '%s' "$T5_MSG" | grep -qi "predates XACA-1261"; then
    test_pass
else
    test_fail "expected dns still created via Rail 2 AND a warning naming the absent manifest ('predates XACA-1261'); dns created=$([ -d "$T5_WD/dns/personas/agents" ] && echo yes || echo no) msg=[$T5_MSG] log=$(cat "$T5_LOG")"
fi
T5_MANIFEST_MSG="$T5_MSG"

test_start "T6 (matrix row 3): personas-manifest.json UNPARSEABLE -> Rail 1 off, message DISTINCT from T5's (absent) case"
T6_FW="$(_next_sandbox)"; T6_WD="$(_next_sandbox)"; T6_HOME="$(_next_sandbox)"
T6_PROJ="$(_next_sandbox)"; T6_KANBAN="$(_next_sandbox)"
T6_REG="$T6_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T6_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T6_FW" dns
mkdir -p "$T6_FW/share/scripts"
printf '{this is not valid json' > "$T6_FW/share/scripts/personas-manifest.json"
_mk_git_repo "$T6_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T6_REG" dns "$T6_PROJ" "$T6_KANBAN"
T6_LOG="$WORK_DIR/t6.log"
_run_utp "$T6_HOME" "$T6_FW" "$T6_WD" "$T6_REG" false "$T6_LOG"
T6_MSG="$(grep -i "personas-manifest.json" "$_STUB_LOG" | grep -i "XACA-1268" || true)"
if [ -d "$T6_WD/dns/personas/agents" ] \
    && printf '%s' "$T6_MSG" | grep -qi "does not parse as JSON" \
    && [ "$T6_MSG" != "$T5_MANIFEST_MSG" ]; then
    test_pass
else
    test_fail "expected dns still created via Rail 2 AND a DIFFERENT warning ('does not parse as JSON') from T5's; dns created=$([ -d "$T6_WD/dns/personas/agents" ] && echo yes || echo no) msg=[$T6_MSG] T5msg=[$T5_MANIFEST_MSG] log=$(cat "$T6_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T7/T8 — fail-closed matrix rows 6/7: registry absent vs. unparseable
# disable BOTH rails, with DIFFERENT distinct messages, and the run must
# NOT abort (fail-soft house convention).
# ═══════════════════════════════════════════════════════════════════════════
test_start "T7 (matrix row 6): team-paths.json ABSENT -> BOTH rails off, named warning, run does not abort"
T7_FW="$(_next_sandbox)"; T7_WD="$(_next_sandbox)"; T7_HOME="$(_next_sandbox)"
T7_REG="$T7_HOME/.aiteamforge/team-paths.json"   # deliberately never written
_seed_framework_group "$T7_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T7_FW" dns
_seed_manifest "$T7_FW" dns dns
T7_LOG="$WORK_DIR/t7.log"
_run_utp "$T7_HOME" "$T7_FW" "$T7_WD" "$T7_REG" false "$T7_LOG"
T7_RC=$?
T7_MSG="$(grep -i "team-paths.json\|registry" "$_STUB_LOG" | grep -i "XACA-1268" || true)"
if [ "$T7_RC" -eq 0 ] && [ ! -e "$T7_WD/dns/personas/agents" ] && printf '%s' "$T7_MSG" | grep -qi "not found"; then
    test_pass
else
    test_fail "expected rc=0 (no abort), no group created, warning naming the absent registry; rc=$T7_RC dns created=$([ -e "$T7_WD/dns/personas/agents" ] && echo yes || echo no) msg=[$T7_MSG] log=$(cat "$T7_LOG")"
fi
T7_REGISTRY_MSG="$T7_MSG"

test_start "T8 (matrix row 7): team-paths.json UNPARSEABLE -> BOTH rails off, message DISTINCT from T7's (absent) case"
T8_FW="$(_next_sandbox)"; T8_WD="$(_next_sandbox)"; T8_HOME="$(_next_sandbox)"
T8_REG="$T8_HOME/.aiteamforge/team-paths.json"
mkdir -p "$(dirname "$T8_REG")"
printf '{not valid json either' > "$T8_REG"
_seed_framework_group "$T8_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T8_FW" dns
_seed_manifest "$T8_FW" dns dns
T8_LOG="$WORK_DIR/t8.log"
_run_utp "$T8_HOME" "$T8_FW" "$T8_WD" "$T8_REG" false "$T8_LOG"
T8_RC=$?
T8_MSG="$(grep -i "team-paths.json\|registry" "$_STUB_LOG" | grep -i "XACA-1268" || true)"
if [ "$T8_RC" -eq 0 ] && [ ! -e "$T8_WD/dns/personas/agents" ] \
    && printf '%s' "$T8_MSG" | grep -qi "does not parse as JSON" \
    && [ "$T8_MSG" != "$T7_REGISTRY_MSG" ]; then
    test_pass
else
    test_fail "expected rc=0 (no abort), no group created, a DIFFERENT warning ('does not parse as JSON') from T7's; rc=$T8_RC dns created=$([ -e "$T8_WD/dns/personas/agents" ] && echo yes || echo no) msg=[$T8_MSG] T7msg=[$T7_REGISTRY_MSG] log=$(cat "$T8_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T9 — matrix row 8: neither jq nor python3 available -> BOTH rails off.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T9 (matrix row 8): neither jq nor python3 on PATH -> BOTH rails off, named warning, no group created"
T9_FW="$(_next_sandbox)"; T9_WD="$(_next_sandbox)"; T9_HOME="$(_next_sandbox)"
T9_PROJ="$(_next_sandbox)"; T9_KANBAN="$(_next_sandbox)"
T9_REG="$T9_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T9_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T9_FW" dns
_seed_manifest "$T9_FW" dns dns
_mk_git_repo "$T9_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T9_REG" dns "$T9_PROJ" "$T9_KANBAN"
T9_NO_TOOL_BIN="$WORK_DIR/no-jq-no-py-bin"
_mk_no_tool_path "$T9_NO_TOOL_BIN" jq python3 python
T9_LOG="$WORK_DIR/t9.log"
_install_print_stubs
(
    set -eo pipefail
    HOME="$T9_HOME" AITEAMFORGE_DIR="$T9_WD" FRAMEWORK_DIR="$T9_FW" WORKING_DIR="$T9_WD" \
    AITEAMFORGE_CONFIG="$T9_REG" DRY_RUN=false FORCE=false PATH="$T9_NO_TOOL_BIN" \
    update_team_personas
) >"$T9_LOG" 2>&1
T9_RC=$?
T9_MSG="$(grep -i "jq nor python3" "$_STUB_LOG" || true)"
if [ "$T9_RC" -eq 0 ] && [ ! -e "$T9_WD/dns/personas/agents" ] && [ -n "$T9_MSG" ]; then
    test_pass
else
    test_fail "expected rc=0, no group created, a 'neither jq nor python3' warning; rc=$T9_RC dns created=$([ -e "$T9_WD/dns/personas/agents" ] && echo yes || echo no) msg=[$T9_MSG] log=$(cat "$T9_LOG")"
fi

# ═══════════════════════════════════════════════════════════════════════════
# T10 — matrix row 10: an unreadable (permission-denied) working_dir is
# counted INDETERMINATE, never folded into "not hosted".
# ═══════════════════════════════════════════════════════════════════════════
test_start "T10 (matrix row 10): unreadable working_dir -> INDETERMINATE (never silently 'not hosted')"
T10_FW="$(_next_sandbox)"; T10_WD="$(_next_sandbox)"; T10_HOME="$(_next_sandbox)"
T10_PROJ="$(_next_sandbox)"; T10_KANBAN="$(_next_sandbox)"
T10_REG="$T10_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T10_FW" secret secret_x.md "SECRET CONTENT"
_seed_team_conf "$T10_FW" secret
_seed_manifest "$T10_FW" secret secret
mkdir -p "$T10_PROJ"
chmod 000 "$T10_PROJ"
_seed_registry "$T10_REG" secret "$T10_PROJ" "$T10_KANBAN"
T10_LOG="$WORK_DIR/t10.log"
_run_utp "$T10_HOME" "$T10_FW" "$T10_WD" "$T10_REG" false "$T10_LOG"
T10_MSG="$(grep -i "permission denied" "$_STUB_LOG" | grep -i "indeterminate" || true)"
T10_SUMMARY_MSG="$(grep -i "could not be classified as hosted/not-hosted" "$_STUB_LOG" || true)"
chmod 700 "$T10_PROJ" 2>/dev/null || true
if [ -n "$T10_MSG" ] && [ -n "$T10_SUMMARY_MSG" ] && [ ! -e "$T10_WD/secret/personas/agents" ]; then
    test_pass
else
    test_fail "expected an 'indeterminate'/'permission denied' warning AND the run-summary indeterminate-count line, and no group silently created; detail_msg=[$T10_MSG] summary_msg=[$T10_SUMMARY_MSG] created=$([ -e "$T10_WD/secret/personas/agents" ] && echo yes || echo no) log=$(cat "$T10_LOG")"
fi

# Direct-call corroboration: _XACA1268_INDETERMINATE itself must be >= 1
# (not just warning TEXT) -- calls the extracted predicate directly, exactly
# as test-xaca-0925-persona-refresh.sh calls its helper directly to inspect
# globals the wrapper doesn't otherwise expose.
test_start "T10b: _xaca1268_hosted_groups() itself sets _XACA1268_INDETERMINATE >= 1 for the same fixture"
(
    FRAMEWORK_DIR="$T10_FW" AITEAMFORGE_CONFIG="$T10_REG" HOME="$T10_HOME"
    chmod 000 "$T10_PROJ" 2>/dev/null
    _install_print_stubs
    _xaca1268_hosted_groups
    _rc_indet="${_XACA1268_INDETERMINATE:-0}"
    chmod 700 "$T10_PROJ" 2>/dev/null || true
    if [ "$_rc_indet" -ge 1 ]; then
        test_pass
    else
        test_fail "expected _XACA1268_INDETERMINATE >= 1, got [$_rc_indet]"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════
# T11 — idempotence: a second run against unchanged content writes nothing
# (no backup, no cp) -- _xaca0925_refresh_team_personas' cmp-based any_diff
# gate is pre-existing code this suite exercises through the new enumeration
# path, not new logic this suite introduces.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T11: a second run after a create is a true no-op (no backup dir, content unchanged)"
T11_FW="$(_next_sandbox)"; T11_WD="$(_next_sandbox)"; T11_HOME="$(_next_sandbox)"
T11_PROJ="$(_next_sandbox)"; T11_KANBAN="$(_next_sandbox)"
T11_REG="$T11_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T11_FW" dns dns_x.md "DNS CONTENT STABLE"
_seed_team_conf "$T11_FW" dns
_seed_manifest "$T11_FW" dns dns
_mk_git_repo "$T11_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T11_REG" dns "$T11_PROJ" "$T11_KANBAN"
T11_LOG1="$WORK_DIR/t11-run1.log"
_run_utp "$T11_HOME" "$T11_FW" "$T11_WD" "$T11_REG" false "$T11_LOG1"
if [ ! -d "$T11_WD/dns/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: first run did not create the dir; log=$(cat "$T11_LOG1")"
else
    T11_BACKUP_ROOT="$T11_HOME/aiteamforge-backups/personas/dns"
    T11_LOG2="$WORK_DIR/t11-run2.log"
    _run_utp "$T11_HOME" "$T11_FW" "$T11_WD" "$T11_REG" false "$T11_LOG2"
    if [ -f "$T11_WD/dns/personas/agents/dns_x.md" ] \
        && cmp -s "$T11_FW/share/personas/dns/agents/dns_x.md" "$T11_WD/dns/personas/agents/dns_x.md" \
        && [ ! -d "$T11_BACKUP_ROOT" ] \
        && grep -qi "up to date" "$_STUB_LOG"; then
        test_pass
    else
        test_fail "expected 2nd run to be a true no-op (content unchanged, no backup dir, 'up to date' summary); backup_dir_exists=$([ -d "$T11_BACKUP_ROOT" ] && echo yes || echo no) stub_log=$(cat "$_STUB_LOG") log2=$(cat "$T11_LOG2")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T12 — --dry-run creates nothing.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T12: DRY_RUN=true creates nothing on disk"
T12_FW="$(_next_sandbox)"; T12_WD="$(_next_sandbox)"; T12_HOME="$(_next_sandbox)"
T12_PROJ="$(_next_sandbox)"; T12_KANBAN="$(_next_sandbox)"
T12_REG="$T12_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T12_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T12_FW" dns
_seed_manifest "$T12_FW" dns dns
_mk_git_repo "$T12_PROJ" || test_fail "fixture: git init failed"
_seed_registry "$T12_REG" dns "$T12_PROJ" "$T12_KANBAN"
if [ -e "$T12_WD/dns/personas/agents" ]; then
    test_fail "PRECONDITION FAILED: dir already exists -- test would be vacuous"
else
    T12_LOG="$WORK_DIR/t12.log"
    _run_utp "$T12_HOME" "$T12_FW" "$T12_WD" "$T12_REG" true "$T12_LOG"
    if [ ! -e "$T12_WD/dns/personas/agents" ] && grep -qi "would update" "$_STUB_LOG"; then
        test_pass
    else
        test_fail "expected DRY_RUN to create nothing but still preview 'Would update'; created=$([ -e "$T12_WD/dns/personas/agents" ] && echo yes || echo no) stub_log=$(cat "$_STUB_LOG") log=$(cat "$T12_LOG")"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# T13 — matrix row 13: a genuinely empty union with clean sources prints an
# explicit SUCCESS line -- never silence, which would be indistinguishable
# from the step not having run at all. This is the measured M1Pro/M1Mini
# steady state from -002.
# ═══════════════════════════════════════════════════════════════════════════
test_start "T13 (matrix row 13): clean sources + empty union -> explicit success line, not silence"
T13_FW="$(_next_sandbox)"; T13_WD="$(_next_sandbox)"; T13_HOME="$(_next_sandbox)"
T13_REG="$T13_HOME/.aiteamforge/team-paths.json"
_seed_framework_group "$T13_FW" dns dns_x.md "DNS CONTENT"
_seed_team_conf "$T13_FW" dns
_seed_manifest "$T13_FW" dns dns
_seed_registry "$T13_REG"   # zero teams -- {"teams":{}}
T13_LOG="$WORK_DIR/t13.log"
_run_utp "$T13_HOME" "$T13_FW" "$T13_WD" "$T13_REG" false "$T13_LOG"
T13_MSG="$(grep -i "hosted-group check clean" "$_STUB_LOG" || true)"
if [ -n "$T13_MSG" ] && [ ! -e "$T13_WD/dns/personas/agents" ]; then
    test_pass
else
    test_fail "expected an explicit 'hosted-group check clean' success line and no group created; msg=[$T13_MSG] log=$(cat "$T13_LOG")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (standalone mode only -- test-runner.sh prints its own).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -eq 0 ]
    exit $?
fi
