#!/usr/bin/env bash
# test-xaca-0799-restart-symmetry.sh
# Regression test for XACA-0799 — `aiteamforge restart lcars` must START the same
# set of LCARS servers it STOPPED.
#
# THE BUG
# -------
# `aiteamforge restart` is two processes (bin/aiteamforge-cli.sh):
#     aiteamforge-stop.sh "$@"  ;  exec aiteamforge-start.sh "$@"
# They shared no state, and disagreed about the team set:
#   STOP  — stop_lcars() matches `server\.py [0-9]` with NO port. A deliberate
#           kill-all (XACA-0560), so it reaps every LCARS server on the box.
#   START — start_lcars() iterated ONLY `.teams[]` from .aiteamforge-config.
# Teams launched by their own *-startup.sh are absent from `.teams[]`, so a
# restart killed them and never brought them back. Observed on M4Mini at v0.17.7
# (WITH the XACA-0792 fix in place): STOP killed all 8 servers, START relaunched
# only finance-personal; the other 7 stayed down until the 300s lcars-health
# LaunchAgent noticed. Up to 5 minutes of fleet-wide LCARS outage per restart.
#
# THE FIX
# -------
# stop captures the live server set to an atomic, TTL-bounded manifest BEFORE the
# first kill; start unions that manifest with `.teams[]`.
#
# Covers:
#   Case 1 — Port→team reverse map (incl. read-only + unknown-port behavior).
#   Case 2 — Manifest round-trip: capture → serialize → read back.
#   Case 3 — TTL freshness: a stale manifest is ignored, not replayed.
#   Case 4 — THE SYMMETRY CONTRACT: the union covers everything stop killed.
#   Case 5 — No-regression: absent/empty/corrupt manifest ⇒ historical behavior.
#   Case 6 — Structural guards wiring stop.sh / start.sh to the mechanism, and
#            pinning the stop-matcher ≡ capture-matcher equivalence the whole
#            design rests on.
#   Case 7 — Crash safety: capture precedes teardown; writes are atomic.
#   Case 8 — Unmappable ports are recorded, surfaced, and not started.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# This suite depends on the shared runner for BOTH its assert helpers and
# TEST_TMP_DIR. Run bare, every sandboxed path collapses to "/" — the runtime-dir
# cases then attempt `ln` and manifest writes at the filesystem ROOT (harmless as
# an unprivileged user on a read-only /, litter or worse otherwise) while every
# assertion silently no-ops as "command not found". Refuse that shape outright
# rather than let it look like a run that happened.
if [ -z "${TEST_TMP_DIR:-}" ] || ! type test_start >/dev/null 2>&1; then
  echo "ERROR: run via the shared runner — bash tests/test-runner.sh $(basename "$0")" >&2
  echo "       (needs TEST_TMP_DIR + the assert helpers; a bare run writes to /)" >&2
  exit 1
fi

PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"
MANIFEST_LIB="$TAP_ROOT/libexec/lib/lcars-restart-manifest.sh"
STOP_CMD="$TAP_ROOT/libexec/commands/aiteamforge-stop.sh"
START_CMD="$TAP_ROOT/libexec/commands/aiteamforge-start.sh"

export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# Runtime dir redirected into the sandbox — this suite never touches the real
# ~/.aiteamforge/run, and never signals a real process.
export LCARS_RESTART_RUNTIME_DIR="$TEST_TMP_DIR/run"

# shellcheck source=/dev/null
source "$TAP_ROOT/libexec/lib/config.sh"
# shellcheck source=/dev/null
source "$PATHS_LIB"
# shellcheck source=/dev/null
source "$TAP_ROOT/libexec/lib/kanban-paths.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$MANIFEST_LIB"

# NOTE ON THE HARNESS (learned the hard way, see XACA-0792 suite): assert_*
# returns 0 silently on success and only records on FAILURE. A bare assert
# registers a START with no PASS, so a suite of bare asserts reports
# "0 passed / 0 failed" and the runner calls it green. Every assertion below
# MUST pair with an explicit `&& test_pass`.

# ═══════════════════════════════════════════════════════════════════════════
# Fixtures — the M4Mini topology that produced the field report: 8 teams in the
# registry, but only ONE of them (finance) present in .aiteamforge-config's
# .teams[]. The other 7 were started by their own *-startup.sh.
# ═══════════════════════════════════════════════════════════════════════════

write_install_config() {
  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "0.17.7",
  "teams": ["finance"],
  "team_paths": {
    "finance": {"working_dir": "/Users/test/finance/personal", "project_id": "personal"}
  }
}
EOF
}

write_port_registry() {
  export AITEAMFORGE_CONFIG="$TEST_TMP_DIR/team-paths.json"
  cat > "$AITEAMFORGE_CONFIG" <<'EOF'
{
  "schema_version": 2,
  "teams": {
    "academy":          {"team_code": "ACA", "lcars_port": 8203},
    "ios":              {"team_code": "IOS", "lcars_port": 8201},
    "android":          {"team_code": "AND", "lcars_port": 8202},
    "firebase":         {"team_code": "FIR", "lcars_port": 8204},
    "dns":              {"team_code": "DNS", "lcars_port": 8205},
    "command":          {"team_code": "CMD", "lcars_port": 8206},
    "legal-coparenting":{"team_code": "LCP", "lcars_port": 8320},
    "finance-personal": {"team_code": "FIN", "lcars_port": 8361}
  }
}
EOF
}

write_install_config
write_port_registry

# The 8 ports that were live on M4Mini when the restart fired.
M4MINI_PORTS="8201 8202 8203 8204 8205 8206 8320 8361"

# ═══════════════════════════════════════════════════════════════════════════
# Case 1 — port → team reverse map
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 1a: port 8203 reverse-maps to 'academy'"
assert_equal "academy" "$(lcars_port_to_team 8203)" && test_pass

test_start "XACA-0799 Case 1b: port 8361 reverse-maps to 'finance-personal'"
# The instance id, NOT the base id — this is the id start must launch under.
assert_equal "finance-personal" "$(lcars_port_to_team 8361)" && test_pass

test_start "XACA-0799 Case 1c: port 8320 reverse-maps to 'legal-coparenting'"
assert_equal "legal-coparenting" "$(lcars_port_to_team 8320)" && test_pass

test_start "XACA-0799 Case 1d: an unregistered port maps to nothing (returns 1)"
_c1_rc=0
lcars_port_to_team 9999 >/dev/null 2>&1 || _c1_rc=$?
assert_exit_failure "$_c1_rc" && test_pass

test_start "XACA-0799 Case 1e: reverse map is READ-ONLY (never materializes a registry)"
# aiteamforge_team_lcars_port() writes a default registry on first lookup when
# none exists. `stop` must not create state just by running (the precedent
# aiteamforge-status.sh set in XACA-0792-001).
_ro_dir=$(mktemp -d)
(
  AITEAMFORGE_CONFIG="$_ro_dir/team-paths.json" \
    lcars_port_to_team 8203 >/dev/null 2>&1
) || true
assert_file_not_exists "$_ro_dir/team-paths.json" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 2 — manifest round-trip
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 2a: capture of the 8 live ports writes a manifest"
printf '%s\n' $M4MINI_PORTS | lcars_ports_to_manifest | lcars_restart_manifest_write
assert_file_exists "$(lcars_restart_manifest_path)" && test_pass

test_start "XACA-0799 Case 2b: manifest reads back all 8 teams"
_c2_count=$(lcars_restart_manifest_teams | grep -c .)
assert_equal "8" "$_c2_count" && test_pass

test_start "XACA-0799 Case 2c: manifest names the instance id, not the base id"
_c2_teams=$(lcars_restart_manifest_teams | tr '\n' ' ')
assert_contains "$_c2_teams" "finance-personal" \
  && assert_not_contains "$_c2_teams" "finance " \
  && test_pass

test_start "XACA-0799 Case 2d: manifest carries a written_at stamp"
assert_contains "$(cat "$(lcars_restart_manifest_path)")" "written_at=" && test_pass

test_start "XACA-0799 Case 2e: manifest is owner-only (0600)"
_c2_mode=$(stat -f '%Lp' "$(lcars_restart_manifest_path)" 2>/dev/null \
  || stat -c '%a' "$(lcars_restart_manifest_path)" 2>/dev/null)
assert_equal "600" "$_c2_mode" && test_pass

test_start "XACA-0799 Case 2f: clear removes the manifest"
lcars_restart_manifest_clear
assert_file_not_exists "$(lcars_restart_manifest_path)" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 3 — TTL freshness
# ═══════════════════════════════════════════════════════════════════════════

# Rewrite the manifest with a doctored written_at, without touching the body.
forge_manifest_age() {
  local age_secs="$1"
  local m
  m=$(lcars_restart_manifest_path)
  printf '%s\n' $M4MINI_PORTS | lcars_ports_to_manifest | lcars_restart_manifest_write
  local now stamp
  now=$(date +%s)
  stamp=$(( now - age_secs ))
  sed "s/^written_at=.*/written_at=${stamp}/" "$m" > "${m}.tmp" && mv -f "${m}.tmp" "$m"
}

test_start "XACA-0799 Case 3a: a 10-second-old manifest is fresh"
forge_manifest_age 10
assert_exit_success "$(lcars_restart_manifest_is_fresh; echo $?)" && test_pass

test_start "XACA-0799 Case 3b: a 10-second-old manifest yields its 8 teams"
assert_equal "8" "$(lcars_restart_manifest_teams | grep -c .)" && test_pass

test_start "XACA-0799 Case 3c: a 2-hour-old manifest is STALE"
forge_manifest_age 7200
_c3_rc=0
lcars_restart_manifest_is_fresh || _c3_rc=$?
assert_exit_failure "$_c3_rc" && test_pass

test_start "XACA-0799 Case 3d: a stale manifest yields NO teams (not replayed)"
# The crash-safety guarantee: a stop whose start never happened must not
# resurrect a long-dead topology days later.
assert_equal "0" "$(lcars_restart_manifest_teams | grep -c . || true)" && test_pass

test_start "XACA-0799 Case 3e: TTL is configurable (2h manifest fresh under a 3h TTL)"
_c3_rc=0
LCARS_RESTART_MANIFEST_TTL=10800 lcars_restart_manifest_is_fresh || _c3_rc=$?
assert_exit_success "$_c3_rc" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 4 — THE SYMMETRY CONTRACT (the actual regression)
#
# This is the bug, pinned. With .teams[] = ["finance"] and 8 servers running,
# the OLD start set was 1 team and the stop set was 8 — 7 stranded.
# ═══════════════════════════════════════════════════════════════════════════

forge_manifest_age 5   # fresh manifest holding all 8 captured teams

test_start "XACA-0799 Case 4a: the OLD behavior (.teams[] alone) covers only 1 of 8"
# Pinning the defect itself, so the test explains WHY the union is required.
_c4_old=$(get_configured_teams | tr ' ' '\n' | grep -c . || true)
assert_equal "1" "$_c4_old" && test_pass

test_start "XACA-0799 Case 4b: the union covers all 8 teams that were killed"
_c4_union=$(lcars_restart_union_teams "$(get_configured_teams)" | grep -c .)
assert_equal "8" "$_c4_union" && test_pass

test_start "XACA-0799 Case 4c: SYMMETRY — every stopped team is in the start set"
# The contract in one assertion: resolve both sides to instance ids and diff.
# Anything stop killed that start would not relaunch shows up here.
_stopped=$(lcars_restart_manifest_teams | sort)
_starting=$(lcars_restart_union_teams "$(get_configured_teams)" \
  | while IFS= read -r _t; do aiteamforge_resolve_team_key "$_t" 2>/dev/null || echo "$_t"; done \
  | sort -u)
_stranded=$(comm -23 <(echo "$_stopped") <(echo "$_starting"))
assert_empty "$_stranded" && test_pass

test_start "XACA-0799 Case 4d: the configured team is not lost from the union"
# Guards over-correction in the other direction: the manifest must ADD to
# .teams[], never replace it. Asserted against the full instance id — a bare
# "finance" would substring-match "finance-personal" and pass vacuously.
assert_contains "$(lcars_restart_union_teams "$(get_configured_teams)" | tr '\n' ' ')" \
  "finance-personal" && test_pass

test_start "XACA-0799 Case 4e: base id and instance id collapse to ONE start"
# The union legally holds BOTH "finance" (configured base) and "finance-personal"
# (captured instance). They are the SAME server. The union must therefore dedupe
# in resolved-key space and emit it exactly once — otherwise start processes one
# server twice and warns "LCARS already running" during a fresh restart.
_c4_fin=$(lcars_restart_union_teams "$(get_configured_teams)" | grep -c '^finance-personal$')
assert_equal "1" "$_c4_fin" && test_pass

test_start "XACA-0799 Case 4f: the union speaks in resolved INSTANCE ids"
# The raw base id must not survive into the start set — start keys LCARS_TEAM,
# the port lookup, and the session name off whatever this emits. Counted with an
# ANCHORED grep, not assert_not_contains: that helper is a substring test, so
# "finance" would match inside "finance-personal" and the check would be vacuous.
_c4_bare=$(lcars_restart_union_teams "$(get_configured_teams)" | grep -c '^finance$' || true)
assert_equal "0" "$_c4_bare" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 5 — NO REGRESSION: degrade to historical behavior
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 5a: no manifest ⇒ union is exactly .teams[]"
# Resolved, as everywhere else: .teams[] holds "finance", the start set names
# "finance-personal". One entry — the manifest contributed nothing.
lcars_restart_manifest_clear
assert_equal "finance-personal" "$(lcars_restart_union_teams "$(get_configured_teams)" | tr -d '\n')" && test_pass

test_start "XACA-0799 Case 5b: no manifest ⇒ teams reader is silent and succeeds"
_c5_rc=0
_c5_out=$(lcars_restart_manifest_teams) || _c5_rc=$?
assert_exit_success "$_c5_rc" && assert_empty "$_c5_out" && test_pass

test_start "XACA-0799 Case 5c: empty manifest (nothing was running) ⇒ .teams[] only"
: | lcars_restart_manifest_write
assert_equal "finance-personal" "$(lcars_restart_union_teams "$(get_configured_teams)" | tr -d '\n')" && test_pass

test_start "XACA-0799 Case 5d: manifest with no written_at stamp is ignored"
# A truncated/corrupt file must not be trusted as fresh.
printf 'academy\t8203\n' > "$(lcars_restart_manifest_path)"
assert_empty "$(lcars_restart_manifest_teams)" && test_pass

test_start "XACA-0799 Case 5e: non-numeric written_at is ignored"
printf 'written_at=garbage\nacademy\t8203\n' > "$(lcars_restart_manifest_path)"
assert_empty "$(lcars_restart_manifest_teams)" && test_pass

test_start "XACA-0799 Case 5f: comment lines are not mistaken for team ids"
lcars_restart_manifest_clear
printf '%s\n' $M4MINI_PORTS | lcars_ports_to_manifest | lcars_restart_manifest_write
assert_not_contains "$(lcars_restart_manifest_teams)" "#" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 6 — STRUCTURAL GUARDS
#
# Cases 1–5 exercise the library directly. They would ALL keep passing if
# stop.sh/start.sh never adopted it — exactly the trap XACA-0792 Case 6 was
# written to close. These pin the wiring.
# ═══════════════════════════════════════════════════════════════════════════

stop_src=$(cat "$STOP_CMD")
start_src=$(cat "$START_CMD")
stop_lcars_body=$(awk '/^stop_lcars\(\)/,/^}/' "$STOP_CMD")
start_lcars_body=$(awk '/^start_lcars\(\)/,/^}/' "$START_CMD")

test_start "XACA-0799 Case 6a: both function bodies were extracted"
assert_not_empty "$stop_lcars_body" && assert_not_empty "$start_lcars_body" && test_pass

test_start "XACA-0799 Case 6b: stop.sh sources the manifest library"
assert_contains "$stop_src" "lcars-restart-manifest.sh" && test_pass

test_start "XACA-0799 Case 6c: start.sh sources the manifest library"
assert_contains "$start_src" "lcars-restart-manifest.sh" && test_pass

test_start "XACA-0799 Case 6d: stop_lcars() captures the running set"
assert_contains "$stop_lcars_body" "lcars_restart_manifest_capture" && test_pass

test_start "XACA-0799 Case 6e: start_lcars() drives its loop off the UNION"
assert_contains "$start_lcars_body" "lcars_restart_union_teams" && test_pass

test_start "XACA-0799 Case 6f: start_lcars() no longer iterates .teams[] alone"
# The precise line the bug lived on. If someone reinstates it, the union is dead
# code and every restart strands servers again.
assert_not_contains "$start_lcars_body" 'read -ra teams <<< "$teams_str"' && test_pass

manifest_src=$(cat "$MANIFEST_LIB")

# Extract the pattern actually passed to `pgrep -f` — from CODE, never from the
# surrounding prose.
#
# The first cut of this guard did `assert_contains "$manifest_src" 'server\.py
# [0-9]'` against the whole file, and was VACUOUS: both files carry that literal
# in explanatory comments, so deliberately narrowing the live pgrep call to
# `lcars-ui/server.py` still passed. Verified by breaking it on purpose — the
# suite stayed green, which is exactly the failure mode this repo has been bitten
# by before. Strip comment lines first, then read the pgrep argument.
extract_pgrep_pattern() {
  echo "$1" | grep -v '^[[:space:]]*#' | grep -m1 -o 'pgrep -f "[^"]*"' | sed 's/pgrep -f "//; s/"$//'
}

_stop_pat=$(extract_pgrep_pattern "$stop_lcars_body")
_capture_body=$(awk '/^lcars_running_lcars_ports\(\)/,/^}/' "$MANIFEST_LIB")
_capture_pat=$(extract_pgrep_pattern "$_capture_body")

test_start "XACA-0799 Case 6g-pre: both live pgrep patterns were extracted from code"
assert_not_empty "$_stop_pat" && assert_not_empty "$_capture_pat" && test_pass

test_start "XACA-0799 Case 6g: MATCHER EQUIVALENCE — capture sees what stop kills"
# The single most important structural invariant. stop_lcars()'s kill-all matcher
# and lcars_running_lcars_ports()'s capture matcher must be the SAME pattern, or
# the capture under-reports and the stranding returns silently. Narrowing either
# one without the other is precisely the sibling-matcher drift the XACA-0560-001
# warning in stop_lcars() already cautions against.
assert_equal "$_stop_pat" "$_capture_pat" && test_pass

test_start "XACA-0799 Case 6h: start dedupes on the RESOLVED key"
# Without post-resolution dedupe, "finance" + "finance-personal" double-process.
assert_contains "$start_lcars_body" "_seen_keys" && test_pass

test_start "XACA-0799 Case 6i: manifest is cleared only on a complete restore"
assert_contains "$start_lcars_body" "_restore_complete" \
  && assert_contains "$start_lcars_body" "lcars_restart_manifest_clear" \
  && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 7 — CRASH SAFETY
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 7a: capture happens BEFORE the first kill"
# If the snapshot were taken after the kill loop, a crash mid-teardown would lose
# the record entirely — and pgrep would already be returning fewer servers.
# Compare line offsets within stop_lcars()'s own body.
_cap_line=$(echo "$stop_lcars_body" | grep -n "lcars_restart_manifest_capture" | head -1 | cut -d: -f1)
_kill_line=$(echo "$stop_lcars_body" | grep -n 'if kill "\$pid"' | head -1 | cut -d: -f1)
if [ -n "$_cap_line" ] && [ -n "$_kill_line" ] && [ "$_cap_line" -lt "$_kill_line" ]; then
  _c7_order="before"
else
  _c7_order="after(cap=${_cap_line},kill=${_kill_line})"
fi
assert_equal "before" "$_c7_order" && test_pass

test_start "XACA-0799 Case 7b: the early-return on 'nothing running' is AFTER capture"
# Guards a subtle ordering trap: returning early when pgrep is empty must not
# skip writing the empty manifest, or a stale prior manifest survives and gets
# replayed on the next start.
_empty_ret=$(echo "$stop_lcars_body" | grep -n 'LCARS server not running' | head -1 | cut -d: -f1)
if [ -n "$_cap_line" ] && [ -n "$_empty_ret" ] && [ "$_cap_line" -lt "$_empty_ret" ]; then
  _c7_ret="before"
else
  _c7_ret="after(cap=${_cap_line},ret=${_empty_ret})"
fi
assert_equal "before" "$_c7_ret" && test_pass

test_start "XACA-0799 Case 7c: manifest writes are atomic (temp + rename)"
assert_contains "$manifest_src" "mktemp" && assert_contains "$manifest_src" "mv -f" && test_pass

test_start "XACA-0799 Case 7d: a failed capture cannot abort stop"
# stop.sh runs under `set -eo pipefail`. Losing LCARS to a bookkeeping error
# would be strictly worse than the bug being fixed.
assert_contains "$stop_lcars_body" "print_warning" \
  && assert_contains "$stop_lcars_body" "if lcars_restart_manifest_capture" \
  && test_pass

test_start "XACA-0799 Case 7e: runtime dir is refused when it is a symlink"
_sym_target=$(mktemp -d)
_sym_dir="$TEST_TMP_DIR/symlinked-run"
ln -sfn "$_sym_target" "$_sym_dir"
_c7_rc=0
( LCARS_RESTART_RUNTIME_DIR="$_sym_dir" lcars_restart_manifest_write </dev/null ) >/dev/null 2>&1 || _c7_rc=$?
assert_exit_failure "$_c7_rc" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 8 — unmappable ports are recorded, surfaced, not started
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 8a: an unregistered port is recorded with the '-' sentinel"
printf '8203\n9999\n' | lcars_ports_to_manifest | lcars_restart_manifest_write
assert_contains "$(cat "$(lcars_restart_manifest_path)")" "-	9999" && test_pass

test_start "XACA-0799 Case 8b: the sentinel is NOT offered to start as a team"
# "-" is not a launchable team id; feeding it to start would be a hard error.
assert_not_contains "$(lcars_restart_manifest_teams)" "-" && test_pass

test_start "XACA-0799 Case 8c: unmapped ports are reported for operator visibility"
assert_equal "9999" "$(lcars_restart_manifest_unmapped_ports | tr -d '\n')" && test_pass

test_start "XACA-0799 Case 8d: the mappable port alongside it still restores"
assert_equal "academy" "$(lcars_restart_manifest_teams | tr -d '\n')" && test_pass

test_start "XACA-0799 Case 8e: start_lcars() surfaces unmapped ports"
assert_contains "$start_lcars_body" "lcars_restart_manifest_unmapped_ports" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 9 — non-numeric / junk input is rejected by the port layer
# ═══════════════════════════════════════════════════════════════════════════

test_start "XACA-0799 Case 9a: junk port lines are dropped, not mapped"
_c9=$(printf '8203\nnot-a-port\n\n8361\n' | lcars_ports_to_manifest | grep -c .)
assert_equal "2" "$_c9" && test_pass

test_start "XACA-0799 Case 9b: capture of an empty process list yields an empty manifest"
: | lcars_ports_to_manifest | lcars_restart_manifest_write
assert_equal "0" "$(lcars_restart_manifest_teams | grep -c . || true)" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 10 — portability + extraction guards on the capture layer
# ═══════════════════════════════════════════════════════════════════════════
# Both of these were live defects in the first cut of the manifest library and
# both fail SILENTLY — they produce an empty or wrong manifest while every
# function still exits 0, so `start` restores nothing and the run looks healthy.
# Structural guards, because neither reproduces under bash (the shell the tap
# actually ships) and a behavioral test would therefore pass on this machine
# regardless. Asserted against comment-stripped source: the fixes document the
# broken forms by name, so a whole-file grep matches the PROSE and fails a
# correct implementation.
_mf_code=$(grep -vE '^[[:space:]]*#' "$MANIFEST_LIB")

test_start "XACA-0799 Case 10a: capture does not rely on unquoted word splitting"
# zsh does not word-split unquoted expansions: `for pid in $pids` runs ONCE over
# the whole multi-line PID blob, every ps lookup fails, and the capture returns
# an EMPTY set while exiting 0 — a vacuous success that writes an empty manifest.
assert_not_contains "$_mf_code" 'for pid in $pids' \
  && assert_contains "$_mf_code" 'while IFS= read -r pid' \
  && test_pass

test_start "XACA-0799 Case 10b: the union does not rely on unquoted word splitting"
# Same trap on the configured-teams string: under zsh the whole ".teams[]" value
# resolves as ONE team id and every configured team drops out of the union.
assert_not_contains "$_mf_code" 'for t in $configured' \
  && test_pass

test_start "XACA-0799 Case 10c: port extraction is anchored on server.py"
# A right-to-left "last all-numeric token" scan looks equivalent to anchoring and
# is not: it returns the LAST number on the line, so a trailing numeric argument
# (`server.py 8203 --workers 2`) yields 2 and the manifest records a port no team
# owns. Anchoring immediately after server.py is what actually tolerates flags.
assert_contains "$_mf_code" 'server\.py[[:space:]]' \
  && assert_not_contains "$_mf_code" 'for (i = NF; i >= 1; i--)' \
  && test_pass

test_start "XACA-0799 Case 10d: extraction picks the port, not a trailing numeric arg"
# Behavioral counterpart to 10c, exercised through the same sed the capture uses.
_extract() { printf '%s\n' "$1" | sed -n 's/.*server\.py[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p'; }
assert_equal "8203" "$(_extract 'python3 server.py 8203')" \
  && assert_equal "8203" "$(_extract '/usr/bin/python3 server.py 8203 --workers 2')" \
  && test_pass
