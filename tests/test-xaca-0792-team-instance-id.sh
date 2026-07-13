#!/usr/bin/env bash
# test-xaca-0792-team-instance-id.sh
# Regression test for XACA-0792 — `aiteamforge start` must map a configured BASE
# team id to its registry INSTANCE id before looking up an LCARS port.
#
# Bug: `.teams[]` in .aiteamforge-config stores BASE ids ("finance"), while the
# canonical port registry (team-paths.json) keys project-scoped teams by their
# INSTANCE id ("finance-personal"). start_lcars() in
# libexec/commands/aiteamforge-start.sh passed the base id straight to
# aiteamforge_team_lcars_port(), which therefore MISSED the registry and printed
# "No LCARS port allocated for 'finance' — skipping", launching nothing.
#
# The damage is asymmetric and that is what made it user-visible: `aiteamforge
# stop` kills the running server by port/pattern and succeeds, then `start`
# skips the team. Every stop/start cycle (lcars-watch runs one) therefore left
# LCARS DOWN with no path back up. Observed on M4Mini 2026-07-12: finance LCARS
# UI reported "server not found"; the log carried 14 of these skips.
#
# Single-instance teams (academy, ios) were never affected — their base id IS
# their instance id — which is why this hid for so long. It bites exactly the
# project-scoped teams: finance-personal, legal-coparenting, medical-general.
#
# Covers:
#   Case 1 — Unit: base id + project_id resolves to the instance id.
#   Case 2 — Unit: a team with no project_id is returned unchanged (no-op for
#            single-instance teams — guards against over-correction).
#   Case 3 — Unit: project_id is lowercased, matching how the registry and the
#            team startup scripts derive the id.
#   Case 4 — Unit: missing config degrades gracefully to the base id rather than
#            returning empty (an empty id would poison every downstream lookup).
#   Case 5 — Behavioral (the actual regression): against an exact replica of the
#            M4Mini fixture, the RAW base id fails to resolve a port while the
#            mapped instance id resolves to 8361. This is the bug, pinned.
#   Case 6 — Structural (the regression guard): start_lcars() must call
#            get_team_instance_id before aiteamforge_team_lcars_port. Case 5
#            alone would keep passing even if aiteamforge-start.sh never adopted
#            the mapping, because it exercises the helpers directly rather than
#            through start_lcars()'s own resolution logic.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_LIB="$TAP_ROOT/libexec/lib/config.sh"
PATHS_LIB="$TAP_ROOT/libexec/lib/aiteamforge-paths.sh"
START_CMD="$TAP_ROOT/libexec/commands/aiteamforge-start.sh"

export AITEAMFORGE_DIR="$TEST_TMP_DIR/aiteamforge"
mkdir -p "$AITEAMFORGE_DIR"

# shellcheck source=/dev/null
source "$CONFIG_LIB"
# shellcheck source=/dev/null
source "$PATHS_LIB"

# ═══════════════════════════════════════════════════════════════════════════
# Fixtures — an exact replica of the M4Mini install that surfaced the bug.
# ═══════════════════════════════════════════════════════════════════════════

# .aiteamforge-config: teams[] holds the BASE id; the project lives in team_paths.
write_install_config() {
  cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "version": "0.17.6",
  "teams": ["finance", "academy"],
  "team_paths": {
    "finance": {
      "working_dir": "/Users/test/finance/personal",
      "project_id": "personal"
    },
    "academy": {
      "working_dir": "/Users/test/dev-team"
    }
  }
}
EOF
}

# team-paths.json: the registry keys finance by its INSTANCE id.
write_port_registry() {
  export AITEAMFORGE_CONFIG="$TEST_TMP_DIR/team-paths.json"
  cat > "$AITEAMFORGE_CONFIG" <<'EOF'
{
  "schema_version": 2,
  "teams": {
    "academy":          {"team_code": "ACA", "lcars_port": 8203},
    "finance-personal": {"team_code": "FIN", "lcars_port": 8361}
  }
}
EOF
}

write_install_config
write_port_registry

# NOTE ON THE HARNESS: assert_* returns 0 silently on success and only records on
# FAILURE (via test_fail). A bare `assert_equal` therefore registers a START with
# no PASS, and the suite reports "all passed" on 0 passed / 0 failed — a vacuous
# green. Every assertion below must pair with an explicit `&& test_pass`.

# ═══════════════════════════════════════════════════════════════════════════
# Case 1 — base id + project_id → instance id
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0792 Case 1: 'finance' + project_id 'personal' → 'finance-personal'"
actual=$(get_team_instance_id "finance")
assert_equal "finance-personal" "$actual" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 2 — single-instance team is returned unchanged
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0792 Case 2: 'academy' (no project_id) is unchanged"
actual=$(get_team_instance_id "academy")
assert_equal "academy" "$actual" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 3 — project_id is lowercased
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0792 Case 3: uppercase project_id is lowercased"
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "teams": ["finance"],
  "team_paths": {"finance": {"project_id": "Personal"}}
}
EOF
actual=$(get_team_instance_id "finance")
assert_equal "finance-personal" "$actual" && test_pass
write_install_config  # restore

# ═══════════════════════════════════════════════════════════════════════════
# Case 4 — missing config degrades to the base id (never empty)
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0792 Case 4: missing config → base id, not empty"
mv "$AITEAMFORGE_DIR/.aiteamforge-config" "$AITEAMFORGE_DIR/.aiteamforge-config.bak"
actual=$(get_team_instance_id "finance")
assert_equal "finance" "$actual" && test_pass
mv "$AITEAMFORGE_DIR/.aiteamforge-config.bak" "$AITEAMFORGE_DIR/.aiteamforge-config"

# ═══════════════════════════════════════════════════════════════════════════
# Case 5 — THE REGRESSION: raw base id misses the registry; instance id hits it
# ═══════════════════════════════════════════════════════════════════════════
test_start "XACA-0792 Case 5a: raw base id 'finance' does NOT resolve a port"
# This is the bug's trigger: the id start_lcars() used to pass is simply absent
# from the registry. Pinning it documents WHY the mapping is required.
_c5_rc=0
aiteamforge_team_lcars_port "finance" >/dev/null 2>&1 || _c5_rc=$?
assert_exit_failure "$_c5_rc" && test_pass

test_start "XACA-0792 Case 5b: mapped instance id resolves to port 8361"
instance=$(get_team_instance_id "finance")
mapped_port=$(aiteamforge_team_lcars_port "$instance" 2>/dev/null)
assert_equal "8361" "$mapped_port" && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 6 — STRUCTURAL GUARD: start_lcars() must map before it looks up
# ═══════════════════════════════════════════════════════════════════════════
start_lcars_body=$(awk '/^start_lcars\(\)/,/^}/' "$START_CMD")

test_start "XACA-0792 Case 6a: start_lcars() body was extracted"
assert_not_empty "$start_lcars_body" && test_pass

test_start "XACA-0792 Case 6b: the resolver consults BOTH mappers"
# start_lcars() delegates to aiteamforge_resolve_team_key (Case 7i). The resolver
# is where the candidate order lives, so that is where the guard belongs: it must
# consult the canonical map (get_board_id — the one that saves `legal`) AND the
# project_id derivation (get_team_instance_id — the one that saves custom projects).
# Dropping either one silently strands a class of teams.
resolver_body=$(awk '/^aiteamforge_resolve_team_key\(\)/,/^}/' "$PATHS_LIB")
assert_contains "$resolver_body" "get_board_id" \
  && assert_contains "$resolver_body" "get_team_instance_id" \
  && test_pass

test_start "XACA-0792 Case 6c: the port lookup is not fed the raw base id"
# The lookup must be driven by the resolved candidate, never bare "$team".
assert_not_contains "$start_lcars_body" 'aiteamforge_team_lcars_port "$team"' && test_pass

# ═══════════════════════════════════════════════════════════════════════════
# Case 7 — aiteamforge_resolve_team_key across ALL profile-scoped teams
#
# This is the case the first cut of the fix got WRONG (caught in review). Deriving
# the instance id from .team_paths[<base>].project_id alone fixes finance and
# medical ONLY BY COINCIDENCE — their TEAM_DEFAULT_PROJECT ("personal", "general")
# happens to spell the registry suffix. legal's TEAM_DEFAULT_PROJECT is "default",
# which derives "legal-default" — a key that does not exist — so legal's LCARS
# stayed permanently down. The canonical get_board_id map (legal → legal-coparenting)
# is the authority and must be consulted FIRST.
#
# A fixture using project_id "coparenting" for legal would have hidden the bug, so
# these use the REAL shipped defaults from share/teams/<team>.conf.
# ═══════════════════════════════════════════════════════════════════════════
# shellcheck source=../libexec/lib/kanban-paths.sh
source "$TAP_ROOT/libexec/lib/kanban-paths.sh" 2>/dev/null || true

cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "teams": ["finance", "legal", "medical", "academy"],
  "team_paths": {
    "finance": {"project_id": "personal"},
    "legal":   {"project_id": "default"},
    "medical": {"project_id": "general"},
    "academy": {}
  }
}
EOF

cat > "$AITEAMFORGE_CONFIG" <<'EOF'
{
  "schema_version": 2,
  "teams": {
    "academy":           {"team_code": "ACA", "lcars_port": 8203},
    "finance-personal":  {"team_code": "FIN", "lcars_port": 8361},
    "legal-coparenting": {"team_code": "LCP", "lcars_port": 8320},
    "medical-general":   {"team_code": "MED", "lcars_port": 8340}
  }
}
EOF

test_start "XACA-0792 Case 7a: get_board_id is reachable (legal → legal-coparenting)"
assert_equal "legal-coparenting" "$(get_board_id legal)" && test_pass

test_start "XACA-0792 Case 7b: 'legal' resolves despite project_id 'default'"
# THE REVIEW CATCH: project_id-derivation alone yields 'legal-default' → no port.
assert_equal "legal-coparenting" "$(aiteamforge_resolve_team_key legal)" && test_pass

test_start "XACA-0792 Case 7c: 'legal' resolves to port 8320"
assert_equal "8320" "$(aiteamforge_team_lcars_port "$(aiteamforge_resolve_team_key legal)")" && test_pass

test_start "XACA-0792 Case 7d: 'finance' resolves to port 8361"
assert_equal "8361" "$(aiteamforge_team_lcars_port "$(aiteamforge_resolve_team_key finance)")" && test_pass

test_start "XACA-0792 Case 7e: 'medical' resolves to port 8340"
assert_equal "8340" "$(aiteamforge_team_lcars_port "$(aiteamforge_resolve_team_key medical)")" && test_pass

test_start "XACA-0792 Case 7f: 'academy' (single-instance) resolves to port 8203"
assert_equal "8203" "$(aiteamforge_team_lcars_port "$(aiteamforge_resolve_team_key academy)")" && test_pass

test_start "XACA-0792 Case 7g: an unknown team resolves nothing (returns 1)"
_c7_rc=0
aiteamforge_resolve_team_key "nosuchteam" >/dev/null 2>&1 || _c7_rc=$?
assert_exit_failure "$_c7_rc" && test_pass

test_start "XACA-0792 Case 7h: a custom project_id the static map cannot know still resolves"
# Guards candidate #2: get_board_id has no 'freelance' case, so only the
# project_id derivation can resolve this one.
cat > "$AITEAMFORGE_DIR/.aiteamforge-config" <<'EOF'
{
  "teams": ["freelance"],
  "team_paths": {"freelance": {"project_id": "acme"}}
}
EOF
cat > "$AITEAMFORGE_CONFIG" <<'EOF'
{
  "schema_version": 2,
  "teams": {"freelance-acme": {"team_code": "FRL", "lcars_port": 8420}}
}
EOF
assert_equal "freelance-acme" "$(aiteamforge_resolve_team_key freelance)" && test_pass

test_start "XACA-0792 Case 7i: start_lcars() uses the resolver, not a raw derivation"
assert_contains "$start_lcars_body" "aiteamforge_resolve_team_key" && test_pass
