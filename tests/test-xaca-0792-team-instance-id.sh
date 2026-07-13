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

test_start "XACA-0792 Case 6b: start_lcars() calls get_team_instance_id"
assert_contains "$start_lcars_body" "get_team_instance_id" && test_pass

test_start "XACA-0792 Case 6c: the port lookup is not fed the raw base id"
# The lookup must be driven by the resolved candidate, never bare "$team".
assert_not_contains "$start_lcars_body" 'aiteamforge_team_lcars_port "$team"' && test_pass
