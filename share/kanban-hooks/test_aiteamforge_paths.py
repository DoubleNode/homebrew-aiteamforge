#!/usr/bin/env python3
"""
test_aiteamforge_paths.py — Unit tests for aiteamforge_paths.py helpers.

XACA-0463 (subitem 003): Tests for compute_instance_port allocator.

Run:
    python3 -m unittest kanban-hooks/test_aiteamforge_paths.py -v
    # or from inside kanban-hooks/:
    python3 -m unittest test_aiteamforge_paths -v
"""

import copy
import importlib
import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# All 20 canonical teams with their expected 3-letter codes.
# XACA-0542-015: This table is the parity fixture for the MERGED team-code map
# (build_team_code_map / get_team_code / get_team_from_code).
# XACA-0628: the 9 per-client/project freelance slugs (FSW/FAP/FWS/FLB/VAN/FAS/
# FLA/FLI/BWA) were moved OUT of DEFAULT_TEAMS and now resolve via the per-machine
# overlay (~/.aiteamforge/team-paths.json) — so the parity tests below validate
# the merged (DEFAULT_TEAMS + overlay) result, not DEFAULT_TEAMS alone. On this
# dev machine the overlay supplies those 9 codes; the table stays complete.
# ---------------------------------------------------------------------------
_EXPECTED_TEAM_CODES: dict[str, str] = {
    "academy":                             "ACA",
    "ios":                                 "IOS",
    "android":                             "AND",
    "firebase":                            "FIR",
    "command":                             "CMD",
    "dns":                                 "DNS",
    "freelance-doublenode-starwords":      "FSW",
    "freelance-doublenode-appplanning":    "FAP",
    "freelance-doublenode-workstats":      "FWS",
    "freelance-doublenode-lifeboard":      "FLB",
    "freelance-doublenode-caravan":        "VAN",
    "freelance-doublenode-awaysentry":     "FAS",
    "freelance-liquidstyle-agentbadges-app": "FLA",
    "freelance-liquidstyle-agentbadges-ios": "FLI",
    "freelance-bandwear-android":          "BWA",
    "legal-coparenting":                   "LCP",
    "medical-general":                     "MED",
    "finance-personal":                    "FIN",
    "mainevent":                           "MEV",
    "freelance":                           "FRE",
}

# ---------------------------------------------------------------------------
# Ensure kanban-hooks/ is on the path regardless of invocation directory.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import aiteamforge_paths  # noqa: E402
from aiteamforge_paths import (  # noqa: E402
    build_team_code_map,
    compute_instance_port,
    config_is_structurally_valid,
    get_team_code,
    get_team_from_code,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _team_paths(port_map: dict) -> dict:
    """Build a minimal existing_team_paths dict from {instance: port | None}."""
    teams = {}
    for instance, port in port_map.items():
        teams[instance] = {"lcars_port": port}
    return {"teams": teams}


# Finance band: base=8360, range=10  → [8360, 8370)
FINANCE_BASE = 8360
FINANCE_RANGE = 10

# Freelance band: base=8500, range=100 → [8500, 8600)
FREELANCE_BASE = 8500
FREELANCE_RANGE = 100


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------

class TestComputeInstancePort(unittest.TestCase):
    """Unit tests for compute_instance_port per XACA-0463 / §4.1."""

    # ── 1. Empty state ──────────────────────────────────────────────────────

    def test_compute_port_empty_state(self):
        """Empty team-paths → returns band base (8360 for finance)."""
        result = compute_instance_port("finance", _team_paths({}))
        self.assertEqual(result, FINANCE_BASE)

    # ── 2. Partial fill ────────────────────────────────────────────────────

    def test_compute_port_partial_fill(self):
        """Two ports taken at base and base+1 → returns base+2."""
        existing = _team_paths({
            "finance-personal": FINANCE_BASE,
            "finance-business": FINANCE_BASE + 1,
        })
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 2)

    # ── 3. Mid-band skip ───────────────────────────────────────────────────

    def test_compute_port_skips_taken_port_mid_band(self):
        """Only base+1 is taken; lowest free is still base."""
        existing = _team_paths({"x": FINANCE_BASE + 1})
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE)

    # ── 4. Band exhausted ──────────────────────────────────────────────────

    def test_compute_port_band_exhausted(self):
        """All 10 finance ports taken → raises ValueError with 'exhausted'."""
        port_map = {f"finance-instance{i}": FINANCE_BASE + i for i in range(FINANCE_RANGE)}
        existing = _team_paths(port_map)
        with self.assertRaises(ValueError) as ctx:
            compute_instance_port("finance", existing)
        self.assertIn("exhausted", str(ctx.exception).lower())

    # ── 5. Unknown template ────────────────────────────────────────────────

    def test_compute_port_unknown_template(self):
        """Unknown template 'bogus' → raises ValueError."""
        with self.assertRaises(ValueError) as ctx:
            compute_instance_port("bogus", _team_paths({}))
        msg = str(ctx.exception).lower()
        self.assertTrue(
            "lcars_port_base" in msg or "not found" in msg or "unknown" in msg,
            f"Unexpected error message: {ctx.exception}",
        )

    # ── 6. Tolerant input (instance id passed as template id) ─────────────

    def test_compute_port_tolerates_instance_id_input(self):
        """'finance-personal' (instance id) resolves same band as 'finance'."""
        empty = _team_paths({})
        result_template = compute_instance_port("finance", empty)
        result_instance = compute_instance_port("finance-personal", empty)
        self.assertEqual(result_template, result_instance)

    # ── 7. Cross-template collision ────────────────────────────────────────

    def test_compute_port_honors_cross_template_collision(self):
        """Port 8360 taken by an unrelated team → returns 8361 for finance."""
        existing = _team_paths({"unrelated-team": FINANCE_BASE})
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 1)

    # ── 8. Null port entries ignored ───────────────────────────────────────

    def test_compute_port_ignores_null_port_entries(self):
        """Entries with lcars_port=None do not count as used."""
        existing = _team_paths({
            "a": None,
            "b": FINANCE_BASE,
        })
        result = compute_instance_port("finance", existing)
        self.assertEqual(result, FINANCE_BASE + 1)

    # ── 9. Freelance band size ─────────────────────────────────────────────

    def test_compute_port_freelance_band_size(self):
        """Empty state for freelance → returns 8500 (band base)."""
        result = compute_instance_port("freelance", _team_paths({}))
        self.assertEqual(result, FREELANCE_BASE)

    def test_compute_port_freelance_band_size_fills_10(self):
        """Fill freelance ports 8500..8509 → next is 8510 (band is 100, not 10)."""
        port_map = {f"freelance-client-p{i}": FREELANCE_BASE + i for i in range(10)}
        existing = _team_paths(port_map)
        result = compute_instance_port("freelance", existing)
        self.assertEqual(result, FREELANCE_BASE + 10)

    # ── 10. Input dict not mutated ─────────────────────────────────────────

    def test_compute_port_does_not_mutate_input(self):
        """Purity contract: existing_team_paths dict is unchanged after call."""
        existing = _team_paths({"finance-personal": FINANCE_BASE})
        original = copy.deepcopy(existing)
        compute_instance_port("finance", existing)
        self.assertEqual(existing, original)


# ---------------------------------------------------------------------------
# XACA-0542-015: Team-code registry parity tests
# ---------------------------------------------------------------------------
# These tests lock the parity between build_team_code_map() / get_team_code()
# / get_team_from_code() and the expected codes for all 20 canonical teams.
# Any future drift (new team added to DEFAULT_TEAMS without an entry here, or
# a code changed without updating the other side) will fail these tests.
# ---------------------------------------------------------------------------

class TestTeamCodeParity(unittest.TestCase):
    """XACA-0542-015: Parity regression for team_code registry coverage."""

    # ── build_team_code_map coverage ──────────────────────────────────────

    def test_build_team_code_map_all_20_teams_present(self):
        """build_team_code_map() must contain an entry for all 20 canonical teams."""
        code_map = build_team_code_map()  # {code -> team_id}
        # Invert for easy lookup: {team_id -> code}
        team_to_code = {team_id: code for code, team_id in code_map.items()}
        missing = [t for t in _EXPECTED_TEAM_CODES if t not in team_to_code]
        self.assertEqual(
            missing, [],
            f"build_team_code_map() is missing teams: {missing}",
        )

    def test_build_team_code_map_correct_codes(self):
        """build_team_code_map() must map every team to its canonical 3-letter code."""
        code_map = build_team_code_map()  # {code -> team_id}
        team_to_code = {team_id: code for code, team_id in code_map.items()}
        mismatches = []
        for team, expected_code in _EXPECTED_TEAM_CODES.items():
            actual_code = team_to_code.get(team, "")
            if actual_code.upper() != expected_code.upper():
                mismatches.append(f"{team}: expected {expected_code}, got {actual_code}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_build_team_code_map_xfre_present(self):
        """XFRE (freelance) must appear in build_team_code_map() — was absent in pre-XACA-0542 hardcoded dict."""
        code_map = build_team_code_map()
        self.assertIn(
            "FRE", code_map,
            "build_team_code_map() missing FRE (freelance); XFRE→freelance routing broken",
        )
        self.assertEqual(code_map["FRE"], "freelance")

    def test_build_team_code_map_xmed_present(self):
        """XMED (medical-general) must appear in build_team_code_map() — was absent in pre-XACA-0542 hardcoded dict."""
        code_map = build_team_code_map()
        self.assertIn(
            "MED", code_map,
            "build_team_code_map() missing MED (medical-general); XMED→medical-general routing broken",
        )
        self.assertEqual(code_map["MED"], "medical-general")

    # ── get_team_code forward lookup ──────────────────────────────────────

    def test_get_team_code_all_20_teams(self):
        """get_team_code() must return the correct 3-letter code for each of the 20 canonical teams."""
        mismatches = []
        for team, expected_code in _EXPECTED_TEAM_CODES.items():
            actual = get_team_code(team)
            if actual.upper() != expected_code.upper():
                mismatches.append(f"get_team_code({team!r}) -> {actual!r}, want {expected_code!r}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_get_team_code_unknown_returns_empty(self):
        """get_team_code() returns '' for an unregistered team."""
        result = get_team_code("nonexistent-team-xyz")
        self.assertEqual(result, "")

    # ── get_team_from_code reverse lookup ────────────────────────────────

    def test_get_team_from_code_all_20_codes(self):
        """get_team_from_code() must return the correct team_id for each of the 20 canonical codes."""
        mismatches = []
        for team, code in _EXPECTED_TEAM_CODES.items():
            actual = get_team_from_code(code)
            if actual != team:
                mismatches.append(f"get_team_from_code({code!r}) -> {actual!r}, want {team!r}")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_get_team_from_code_case_insensitive(self):
        """get_team_from_code() must work with lowercase code input."""
        result = get_team_from_code("aca")
        self.assertEqual(result, "academy")

    def test_get_team_from_code_unknown_returns_empty(self):
        """get_team_from_code() returns '' for an unknown code."""
        result = get_team_from_code("ZZZ")
        self.assertEqual(result, "")

    # ── bidirectional roundtrip ───────────────────────────────────────────

    def test_roundtrip_team_code_to_team(self):
        """get_team_code(team) → code → get_team_from_code(code) must round-trip for all 20 teams."""
        mismatches = []
        for team in _EXPECTED_TEAM_CODES:
            code = get_team_code(team)
            round_tripped = get_team_from_code(code)
            if round_tripped != team:
                mismatches.append(
                    f"Roundtrip failed: {team!r} -> code={code!r} -> {round_tripped!r}"
                )
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    # ── _ITEM_PREFIX_TO_TEAM parity ───────────────────────────────────────

    def test_item_prefix_to_team_includes_xfre_and_xmed(self):
        """_ITEM_PREFIX_TO_TEAM must include XFRE and XMED added by XACA-0542 registry derivation."""
        # We derive the map the same way server.py does — via build_team_code_map.
        code_map = build_team_code_map()
        item_prefix_map = {f"X{code}": team_id for code, team_id in code_map.items()}
        self.assertIn(
            "XFRE", item_prefix_map,
            "XFRE missing from _ITEM_PREFIX_TO_TEAM equivalent; freelance items won't route",
        )
        self.assertEqual(item_prefix_map["XFRE"], "freelance")
        self.assertIn(
            "XMED", item_prefix_map,
            "XMED missing from _ITEM_PREFIX_TO_TEAM equivalent; medical-general items won't route",
        )
        self.assertEqual(item_prefix_map["XMED"], "medical-general")

    def test_item_prefix_to_team_all_20_entries(self):
        """_ITEM_PREFIX_TO_TEAM must include X<code> prefixes for all 20 canonical teams."""
        code_map = build_team_code_map()
        item_prefix_map = {f"X{code}": team_id for code, team_id in code_map.items()}
        missing = []
        for team, code in _EXPECTED_TEAM_CODES.items():
            prefix = f"X{code}"
            if prefix not in item_prefix_map:
                missing.append(f"{prefix} ({team})")
            elif item_prefix_map[prefix] != team:
                missing.append(
                    f"{prefix}: expected {team!r}, got {item_prefix_map[prefix]!r}"
                )
        self.assertEqual(missing, [], f"_ITEM_PREFIX_TO_TEAM parity failures: {missing}")


# ---------------------------------------------------------------------------
# XACA-0628: build_team_code_map() MERGE semantics.
#
# Locks the behavioural contract that the map = DEFAULT_TEAMS team_codes with
# live-config (team-paths.json) team_codes overlaid ON TOP:
#   - no overlay codes  → identical to the DEFAULT_TEAMS-derived map (regression)
#   - overlay-only slug  → additive (per-project freelance code with no
#                          DEFAULT_TEAMS entry, e.g. BWD → ...bandwear-dashboard)
#   - overlay collision  → live wins
#   - non-freelance teams unaffected
# ---------------------------------------------------------------------------

import unittest.mock as mock  # noqa: E402

from aiteamforge_paths import DEFAULT_TEAMS  # noqa: E402


def _default_teams_code_map() -> dict:
    """The map build_team_code_map() must produce from DEFAULT_TEAMS alone."""
    return {
        entry["team_code"].upper(): team_id
        for team_id, entry in DEFAULT_TEAMS.items()
        if entry.get("team_code")
    }


class TestBuildTeamCodeMapMerge(unittest.TestCase):
    """XACA-0628: build_team_code_map() merges overlay on top of DEFAULT_TEAMS.

    The overlay is injected by patching load_config() to return a synthetic
    team-paths.json dict. We patch rather than write a fixture file so the
    loader's schema-integrity self-heal (academy + any other team guard,
    XACA-0457/0647) can't silently bootstrap DEFAULT_TEAMS over our overlay — the
    test target is the merge logic in build_team_code_map(), not the loader.
    """

    def _patch_overlay(self, teams: dict):
        """Patch load_config() to return {schema_version, teams} for the test
        body. Returns the patcher context manager (use with `with`)."""
        cfg = {"schema_version": 1, "teams": teams}
        return mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg)

    def test_no_overlay_codes_identical_to_default_teams(self):
        """Overlay carrying NO team_codes → map identical to DEFAULT_TEAMS map.

        Mirrors TODAY's live overlay (all 21 teams present, zero team_code
        fields). Proves the merge change is regression-identical to the
        previous exclusive-or behaviour in the current production state.
        """
        # Build an overlay that mentions every team but supplies no team_code.
        codeless = {team_id: {"kanban_dir": "/x"} for team_id in DEFAULT_TEAMS}
        with self._patch_overlay(codeless):
            result = build_team_code_map()
        self.assertEqual(
            result, _default_teams_code_map(),
            "With no overlay team_codes the map must equal the DEFAULT_TEAMS-derived map",
        )

    def test_overlay_only_slug_routes_with_no_default_teams_entry(self):
        """An overlay-only slug (no DEFAULT_TEAMS entry) with a team_code is
        additive — XBWD acceptance criterion."""
        self.assertNotIn(
            "freelance-bandwear-dashboard", DEFAULT_TEAMS,
            "Fixture invalid: dashboard slug must NOT exist in DEFAULT_TEAMS",
        )
        self.assertNotIn(
            "BWD", _default_teams_code_map(),
            "Fixture invalid: BWD must not already be a DEFAULT_TEAMS code",
        )
        with self._patch_overlay({
            "freelance-bandwear-dashboard": {"team_code": "BWD"},
        }):
            result = build_team_code_map()
        self.assertIn("BWD", result, "Overlay-only code BWD must be in the map")
        self.assertEqual(result["BWD"], "freelance-bandwear-dashboard")
        # And every DEFAULT_TEAMS code is still present (merge, not replace).
        for code in _default_teams_code_map():
            self.assertIn(
                code, result,
                f"DEFAULT_TEAMS code {code} dropped — merge regressed to exclusive-or",
            )

    def test_overlay_freelance_code_absent_from_default_teams_routes(self):
        """A freelance code present in overlay but absent from DEFAULT_TEAMS
        (the 006 scenario) still routes via the overlay."""
        # Simulate post-006: DEFAULT_TEAMS no longer has this slug, overlay does.
        self.assertNotIn("freelance-newclient-portal", DEFAULT_TEAMS)
        with self._patch_overlay({
            "freelance-newclient-portal": {"team_code": "FNP"},
        }):
            result = build_team_code_map()
        self.assertEqual(result.get("FNP"), "freelance-newclient-portal")

    def test_overlay_wins_on_conflict(self):
        """When overlay supplies a team_code that collides with a DEFAULT_TEAMS
        code, the overlay value wins (live config is authoritative)."""
        with self._patch_overlay({
            "academy-reassigned": {"team_code": "ACA"},
        }):
            result = build_team_code_map()
        self.assertEqual(
            result["ACA"], "academy-reassigned",
            "Overlay must win on team_code conflict",
        )

    def test_non_freelance_teams_unaffected(self):
        """Adding an overlay-only freelance slug must not perturb the
        non-freelance team routing."""
        with self._patch_overlay({
            "freelance-bandwear-dashboard": {"team_code": "BWD"},
        }):
            result = build_team_code_map()
        for team in (
            "academy", "ios", "firebase", "dns", "command",
            "mainevent", "legal-coparenting", "finance-personal",
        ):
            code = DEFAULT_TEAMS[team]["team_code"].upper()
            self.assertEqual(
                result.get(code), team,
                f"Non-freelance team {team} ({code}) routing changed unexpectedly",
            )

    def test_loader_unavailable_falls_back_to_default_teams(self):
        """If load_config raises, the DEFAULT_TEAMS base is preserved."""
        with mock.patch.object(
            aiteamforge_paths, "load_config", side_effect=RuntimeError("boom")
        ):
            result = build_team_code_map()
        self.assertEqual(
            result, _default_teams_code_map(),
            "Loader failure must still yield the DEFAULT_TEAMS-derived map",
        )


# ---------------------------------------------------------------------------
# XACA-0647: Canonical-guard regression tests for load_config() corruption check.
#
# Before XACA-0647 the guard required at least one platform team
# (ios/android/firebase/dns) beyond academy. That wrongly re-seeded
# personal-only machines (e.g. academy + finance-personal) with the full
# Main Event roster. The fix: a config is corrupt ONLY if it lacks
# schema_version, OR is missing academy, OR has NO team beyond academy
# (academy-alone / empty). Any non-academy team — platform OR personal —
# is sufficient.
# ---------------------------------------------------------------------------

def _reset_module_cache():
    """Reset all module-level caches in aiteamforge_paths so load_config()
    performs a fresh read on the next call."""
    aiteamforge_paths._CONFIG_CACHE = None
    aiteamforge_paths._CONFIG_PATH_AT_LOAD = None
    aiteamforge_paths._A1_BACKFILL_ATTEMPTED = False
    aiteamforge_paths._CONTRACT_SCRUB_ATTEMPTED = False
    aiteamforge_paths._BOARD_LESS_BACKFILL_ATTEMPTED = False  # XACA-0794


def _minimal_team_entry(slug: str) -> dict:
    """Return a minimal valid team entry dict sufficient for load_config()."""
    return {
        "kanban_dir": f"/tmp/{slug}/kanban",
        "working_dir": f"/tmp/{slug}",
        "lcars_port": 9000,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": f"TEAM_{slug.upper().replace('-', '_')}_API_KEY",
    }


class TestLoadConfigCanonicalGuardXACA0647(unittest.TestCase):
    """XACA-0647: Regression tests for the load_config() corruption guard.

    Each test writes a synthetic config to a temp file, points
    AITEAMFORGE_CONFIG at it, and verifies whether load_config() preserves
    the config as-is (valid) or re-seeds it with DEFAULT_TEAMS (corrupt).
    """

    def setUp(self):
        """Create a temp dir and reset module caches before each test."""
        self._tmp = tempfile.mkdtemp(prefix="xaca0647_test_")
        self._config_path = os.path.join(self._tmp, "team-paths.json")
        _reset_module_cache()
        # Stash any existing AITEAMFORGE_CONFIG so we can restore it.
        self._orig_env = os.environ.get("AITEAMFORGE_CONFIG")
        os.environ["AITEAMFORGE_CONFIG"] = self._config_path

    def tearDown(self):
        """Reset module caches and restore env after each test."""
        _reset_module_cache()
        if self._orig_env is None:
            os.environ.pop("AITEAMFORGE_CONFIG", None)
        else:
            os.environ["AITEAMFORGE_CONFIG"] = self._orig_env
        # Clean up temp files (non-fatal on Windows).
        import shutil
        try:
            shutil.rmtree(self._tmp)
        except OSError:
            pass

    def _write_config(self, teams: dict, schema_version: int = 3) -> None:
        """Write a synthetic config JSON to the temp file."""
        cfg = {"schema_version": schema_version, "teams": teams}
        with open(self._config_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)

    # ── VALID personal-only configs (must NOT be re-seeded) ─────────────────

    def test_valid_academy_plus_finance_personal_not_reseeded(self):
        """academy + finance-personal is a valid personal-only config.

        The guard must accept it as-is — load_config() must return exactly
        {academy, finance-personal} and must NOT expand it to the Main Event
        roster (e.g. must not inject 'ios').
        """
        self._write_config({
            "academy": _minimal_team_entry("academy"),
            "finance-personal": _minimal_team_entry("finance-personal"),
        })

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn(
            "finance-personal", teams,
            "finance-personal must be preserved in a valid personal-only config",
        )
        self.assertNotIn(
            "ios", teams,
            "ios must NOT be injected into a valid personal-only config (re-seed guard)",
        )
        # Ensure the team set is exactly what we wrote — no silent expansion.
        self.assertEqual(
            set(teams.keys()), {"academy", "finance-personal"},
            "load_config() must not add or remove teams from a valid personal-only config",
        )

    def test_valid_academy_plus_medical_general_not_reseeded(self):
        """academy + medical-general is a valid personal-only config (no platform team)."""
        self._write_config({
            "academy": _minimal_team_entry("academy"),
            "medical-general": _minimal_team_entry("medical-general"),
        })

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn("medical-general", teams)
        self.assertNotIn(
            "ios", teams,
            "ios must NOT be injected into a valid academy+medical-general config",
        )
        self.assertEqual(set(teams.keys()), {"academy", "medical-general"})

    def test_valid_academy_plus_legal_coparenting_not_reseeded(self):
        """academy + legal-coparenting is a valid personal-only config."""
        self._write_config({
            "academy": _minimal_team_entry("academy"),
            "legal-coparenting": _minimal_team_entry("legal-coparenting"),
        })

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn("legal-coparenting", teams)
        self.assertNotIn(
            "android", teams,
            "android must NOT be injected into a valid academy+legal-coparenting config",
        )
        self.assertEqual(set(teams.keys()), {"academy", "legal-coparenting"})

    # ── CORRUPT configs (must trigger bootstrap → DEFAULT_TEAMS) ─────────────

    def test_corrupt_academy_alone_is_reseeded(self):
        """academy as the ONLY team is the partial-write corruption signature.

        load_config() must detect this and bootstrap → DEFAULT_TEAMS which
        includes 'ios' (and all other canonical teams).
        """
        self._write_config({"academy": _minimal_team_entry("academy")})

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn(
            "ios", teams,
            "academy-alone config must be re-seeded with DEFAULT_TEAMS (ios expected)",
        )
        # DEFAULT_TEAMS has many more teams than just academy.
        self.assertGreater(
            len(teams), 1,
            "Re-seeded config must contain more than one team (full DEFAULT_TEAMS)",
        )

    def test_corrupt_empty_teams_is_reseeded(self):
        """Empty teams dict is corrupt — load_config() must bootstrap DEFAULT_TEAMS."""
        self._write_config({})

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn(
            "ios", teams,
            "Empty-teams config must be re-seeded with DEFAULT_TEAMS (ios expected)",
        )
        self.assertGreater(len(teams), 1)

    def test_custom_team_only_no_academy_is_preserved(self):
        """XACA-0705 regression: a config with a custom non-academy team but NO
        academy must be treated as VALID and preserved as-is, NOT overwritten with
        DEFAULT_TEAMS.

        This is the consumer-install bug: a fresh consumer box whose team-paths.json
        contains only a custom entry (e.g. freelance-myproject) had its config
        clobbered by DEFAULT_TEAMS because the prior guard required academy to be
        present. The fix: drop the academy-required constraint from the validity
        test; academy-alone / empty is still the corruption signal.

        Pre-fix behaviour (BUG): load_config() treated missing_required={academy}
        as corrupt → bootstrapped DEFAULT_TEAMS → custom entry discarded.
        Post-fix behaviour (EXPECTED): config is valid → preserved exactly as-is.
        """
        self._write_config({"freelance-myproject-portal": _minimal_team_entry("freelance-myproject-portal")})

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        # The custom team must survive — the file was NOT overwritten.
        self.assertIn(
            "freelance-myproject-portal", teams,
            "XACA-0705: custom-only config (no academy) must be preserved — not re-seeded",
        )
        # DEFAULT_TEAMS must NOT have been merged in — ios is a reliable canary.
        self.assertNotIn(
            "ios", teams,
            "XACA-0705: DEFAULT_TEAMS (ios) must NOT be injected into a custom-only config",
        )
        # Exactly the team we wrote — no silent expansion.
        self.assertEqual(
            set(teams.keys()), {"freelance-myproject-portal"},
            "XACA-0705: load_config() must preserve the exact team set from a custom-only config",
        )

        # Verify the file on disk was also NOT overwritten.
        import json as _json
        with open(self._config_path, encoding="utf-8") as fh:
            on_disk = _json.load(fh)
        self.assertIn(
            "freelance-myproject-portal", on_disk.get("teams", {}),
            "XACA-0705: team-paths.json must not have been overwritten on disk",
        )
        self.assertNotIn(
            "ios", on_disk.get("teams", {}),
            "XACA-0705: DEFAULT_TEAMS must not appear in the on-disk file",
        )

    def test_corrupt_missing_academy_FORMERLY_reseeded_now_valid(self):
        """XACA-0705: a config with finance-personal but NO academy is now VALID.

        PRIOR BEHAVIOUR (pre-XACA-0705 — this encoded the BUG):
            load_config() treated "missing academy" as corrupt and bootstrapped
            DEFAULT_TEAMS, discarding the custom entry. The old test was:
                test_corrupt_missing_academy_is_reseeded
            It expected ios to appear and was intentionally testing the bug.

        NEW BEHAVIOUR (XACA-0705 fix):
            A config with ANY non-academy team is valid. Academy absence is a
            diagnostic hint only; it is NOT a corruption signal. load_config()
            must preserve the config exactly as written.
        """
        self._write_config({"finance-personal": _minimal_team_entry("finance-personal")})

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        # finance-personal must be preserved — NOT replaced by DEFAULT_TEAMS.
        self.assertIn(
            "finance-personal", teams,
            "XACA-0705: finance-personal-only config must be preserved (no academy required)",
        )
        # DEFAULT_TEAMS must NOT have been injected.
        self.assertNotIn(
            "ios", teams,
            "XACA-0705: ios must NOT appear — this config is now valid, not corrupt",
        )
        self.assertEqual(
            set(teams.keys()), {"finance-personal"},
            "XACA-0705: load_config() must not add or remove teams from a finance-personal-only config",
        )

    def test_corrupt_missing_schema_version_is_reseeded(self):
        """A config without schema_version (partial-write) is corrupt and re-seeded."""
        # Write raw JSON without schema_version — bypass _write_config's wrapper.
        cfg = {
            "teams": {
                "academy": _minimal_team_entry("academy"),
                "ios": _minimal_team_entry("ios"),
            }
        }
        with open(self._config_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        # After bootstrap the result must be DEFAULT_TEAMS (schema_version restored).
        self.assertEqual(
            result.get("schema_version"), aiteamforge_paths.SUPPORTED_SCHEMA_VERSION,
            "Bootstrapped config must carry SUPPORTED_SCHEMA_VERSION",
        )
        self.assertIn("ios", teams)

    # ── VALID single non-personal team configs (XACA-0647 Task 005) ─────────

    def test_valid_academy_plus_command_not_reseeded(self):
        """academy + command (single non-personal team) is a valid config.

        The guard must accept it as-is — ios must NOT be injected and the
        team set must be exactly {academy, command}.
        """
        self._write_config({
            "academy": _minimal_team_entry("academy"),
            "command": _minimal_team_entry("command"),
        })

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn(
            "command", teams,
            "command must be preserved in a valid academy+command config",
        )
        self.assertNotIn(
            "ios", teams,
            "ios must NOT be injected into a valid academy+command config",
        )
        self.assertEqual(
            set(teams.keys()), {"academy", "command"},
            "load_config() must not add or remove teams from a valid academy+command config",
        )

    def test_valid_academy_plus_mainevent_not_reseeded(self):
        """academy + mainevent (single-instance alias team) is a valid config.

        The guard must accept it as-is — ios must NOT be injected and the
        team set must be exactly {academy, mainevent}.
        """
        self._write_config({
            "academy": _minimal_team_entry("academy"),
            "mainevent": _minimal_team_entry("mainevent"),
        })

        result = aiteamforge_paths.load_config()
        teams = result["teams"]

        self.assertIn(
            "mainevent", teams,
            "mainevent must be preserved in a valid academy+mainevent config",
        )
        self.assertNotIn(
            "ios", teams,
            "ios must NOT be injected into a valid academy+mainevent config",
        )
        self.assertEqual(
            set(teams.keys()), {"academy", "mainevent"},
            "load_config() must not add or remove teams from a valid academy+mainevent config",
        )


# ---------------------------------------------------------------------------
# Direct unit tests for teams_satisfy_canonical_guard (XACA-0647 Task 005)
# ---------------------------------------------------------------------------

class TestTeamsSatisfyCanonicalGuard(unittest.TestCase):
    """Unit tests for the teams_satisfy_canonical_guard() helper.

    Verifies the four boundary cases: valid (academy + other), academy-alone,
    empty set, and missing-academy-but-has-other.
    """

    def setUp(self):
        from aiteamforge_paths import teams_satisfy_canonical_guard
        self._guard = teams_satisfy_canonical_guard

    def test_academy_plus_finance_personal_is_valid(self):
        """academy + finance-personal: no missing required, has non-required."""
        missing, has_other = self._guard({"academy", "finance-personal"})
        self.assertEqual(missing, frozenset(), "No required teams should be missing")
        self.assertTrue(has_other, "finance-personal should count as a non-required team")

    def test_academy_alone_has_no_non_required(self):
        """academy alone: no missing required but has_non_required is False."""
        missing, has_other = self._guard({"academy"})
        self.assertEqual(missing, frozenset(), "academy is present — nothing missing")
        self.assertFalse(has_other, "academy-alone should yield has_non_required=False")

    def test_empty_set_missing_required_and_no_non_required(self):
        """Empty set: academy is missing AND has_non_required is False."""
        missing, has_other = self._guard(set())
        self.assertEqual(missing, frozenset({"academy"}), "academy must be flagged as missing")
        self.assertFalse(has_other, "Empty set yields has_non_required=False")

    def test_finance_personal_only_missing_academy(self):
        """finance-personal only: academy is missing but has_non_required is True.

        Note (XACA-0705): teams_satisfy_canonical_guard() still returns
        missing_required={academy} for this case — the raw guard hasn't changed.
        What changed is that config_is_structurally_valid() no longer treats
        missing_required as a corruption signal. The guard's return values remain
        available for diagnostic logging.
        """
        missing, has_other = self._guard({"finance-personal"})
        self.assertEqual(missing, frozenset({"academy"}), "academy must be flagged as missing")
        self.assertTrue(has_other, "finance-personal counts as a non-required team")


# ---------------------------------------------------------------------------
# XACA-0705: config_is_structurally_valid() unit tests
#
# Locks the truth table for the shared predicate that encodes the validity rule
# used by BOTH load_config() and server.py _build_team_kanban_dirs().
#
# Truth table (per XACA-0705 spec):
#   {custom-instance-team}          has_schema=True  → VALID
#   {academy}                       has_schema=True  → corrupt
#   {}                              has_schema=True  → corrupt
#   {academy, ios, ...}             has_schema=True  → VALID
#   missing schema_version          has_schema=False → corrupt
# ---------------------------------------------------------------------------

class TestConfigIsStructurallyValid(unittest.TestCase):
    """XACA-0705: Unit tests for config_is_structurally_valid() truth table."""

    def test_custom_only_no_academy_with_schema_is_valid(self):
        """A custom-only config (no academy) with schema_version is VALID.

        This is the core consumer-install fix: a config with only a custom
        non-default team must NOT be treated as corrupt.
        """
        self.assertTrue(
            config_is_structurally_valid({"freelance-myproject-portal"}, has_schema=True),
            "Custom-only config (no academy) must be VALID",
        )

    def test_academy_alone_is_corrupt(self):
        """academy as the only team → corrupt (academy-alone corruption signature)."""
        self.assertFalse(
            config_is_structurally_valid({"academy"}, has_schema=True),
            "academy-alone must be corrupt",
        )

    def test_empty_teams_is_corrupt(self):
        """Empty teams → corrupt."""
        self.assertFalse(
            config_is_structurally_valid(set(), has_schema=True),
            "Empty teams must be corrupt",
        )

    def test_academy_plus_other_is_valid(self):
        """Normal dev box (academy + ios + ...) is VALID — unchanged from pre-XACA-0705."""
        self.assertTrue(
            config_is_structurally_valid({"academy", "ios", "firebase"}, has_schema=True),
            "Normal dev config (academy + ios + firebase) must be VALID",
        )

    def test_missing_schema_version_is_corrupt(self):
        """Missing schema_version (has_schema=False) → corrupt even with teams present."""
        self.assertFalse(
            config_is_structurally_valid({"academy", "ios"}, has_schema=False),
            "Missing schema_version must be corrupt",
        )

    def test_finance_personal_only_is_valid(self):
        """finance-personal only (no academy) with schema_version is VALID (XACA-0705)."""
        self.assertTrue(
            config_is_structurally_valid({"finance-personal"}, has_schema=True),
            "finance-personal-only config must be VALID after XACA-0705",
        )


# ---------------------------------------------------------------------------
# XACA-0794-005: Regression tests LOCKING the board-less alias contract.
#
# "mainevent" is a DELIBERATE board-less alias (XACA-0727): it owns no kanban
# board of its own — 'command' is the operative kanban identity for Main Event
# cross-platform coordination. Its absent kanban_dir/working_dir is CORRECT BY
# DESIGN, not corruption. This premise has already been misread THREE times
# (the XACA-0724 gate spec, XACA-0794 itself which was filed to delete this
# entry, and would-be "cleanup" #4 if these tests didn't exist). These tests
# make a fourth misread structurally impossible to land silently.
#
# All tests here use tmp dirs / mock.patch.object(aiteamforge_paths,
# "load_config", ...) — never the real ~/.aiteamforge/team-paths.json. Reading
# (let alone writing) the real overlay from a unit test risks tripping the
# board-less-marker self-heal write path inside load_config() on a live
# developer machine.
# ---------------------------------------------------------------------------


def _mainevent_overlay_config(mainevent_entry: dict | None = None) -> dict:
    """Build a minimal synthetic {schema_version, teams} config containing
    academy + command + a mainevent entry (defaults to the real DEFAULT_TEAMS
    shape, deep-copied so callers can't mutate the module-level constant)."""
    return {
        "schema_version": 3,
        "teams": {
            "academy": _minimal_team_entry("academy"),
            "command": _minimal_team_entry("command"),
            "mainevent": (
                copy.deepcopy(mainevent_entry)
                if mainevent_entry is not None
                else copy.deepcopy(DEFAULT_TEAMS["mainevent"])
            ),
        },
    }


class TestMainEventBoardLessContract(unittest.TestCase):
    """Items 1-3, 5: the DEFAULT_TEAMS shape and accessor-raise contract."""

    # ── 1. Key ABSENCE (not just falsy value) ───────────────────────────────

    def test_mainevent_exists_in_default_teams(self):
        self.assertIn("mainevent", DEFAULT_TEAMS)

    def test_mainevent_default_teams_no_kanban_dir_key(self):
        """The key itself must be absent — a bare `None` value is a DIFFERENT
        (legacy, pre-XACA-0794) shape covered separately below."""
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertNotIn(
            "kanban_dir", entry,
            "board-less DEFAULT_TEAMS entry must have NO kanban_dir key at all",
        )

    def test_mainevent_default_teams_no_working_dir_key(self):
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertNotIn(
            "working_dir", entry,
            "board-less DEFAULT_TEAMS entry must have NO working_dir key at all",
        )

    # ── 2. Explicit markers ──────────────────────────────────────────────────

    def test_mainevent_board_less_marker_is_true(self):
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertIs(
            entry.get("board_less"), True,
            "board_less must be the Python bool True, not a truthy stand-in",
        )

    def test_mainevent_alias_of_is_command(self):
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertEqual(entry.get("alias_of"), "command")

    # ── 3. Accessor raise contract ───────────────────────────────────────────

    def test_get_team_kanban_dir_mainevent_raises_keyerror_mentions_alias(self):
        cfg = _mainevent_overlay_config()
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            with self.assertRaises(KeyError) as ctx:
                aiteamforge_paths.get_team_kanban_dir("mainevent")
        msg = str(ctx.exception)
        self.assertIn("mainevent", msg)
        self.assertIn("command", msg, "error message must name the alias target")

    def test_get_team_working_dir_mainevent_raises_keyerror_mentions_alias(self):
        cfg = _mainevent_overlay_config()
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            with self.assertRaises(KeyError) as ctx:
                aiteamforge_paths.get_team_working_dir("mainevent")
        msg = str(ctx.exception)
        self.assertIn("mainevent", msg)
        self.assertIn("command", msg, "error message must name the alias target")

    # ── 5. Identity preserved (team_code / lcars_port) ──────────────────────

    def test_mainevent_team_code_is_mev(self):
        self.assertEqual(DEFAULT_TEAMS["mainevent"]["team_code"], "MEV")

    def test_mainevent_lcars_port_is_8400_in_authoritative_band(self):
        """XACA-0463 moved mainevent off 8234 to 8400 to end the collision with
        command's band [8230, 8240). XACA-0806 narrowed the band from [8400,8410)
        to [8400,8401) (range 10→1): a board-less alias binds exactly one port,
        and the old width overlapped the per-project band [8401,8419)."""
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertEqual(entry["lcars_port"], 8400)
        self.assertEqual(entry["lcars_port_base"], 8400)
        self.assertEqual(entry["lcars_port_range"], 1)
        self.assertTrue(
            entry["lcars_port_base"] <= entry["lcars_port"] < entry["lcars_port_base"] + entry["lcars_port_range"],
            "lcars_port must fall inside mainevent's own declared band",
        )
        # And it must NOT collide with command's band [8230, 8240).
        cmd = DEFAULT_TEAMS["command"]
        self.assertFalse(
            cmd["lcars_port_base"] <= entry["lcars_port"] < cmd["lcars_port_base"] + cmd["lcars_port_range"],
            "mainevent's port must not fall inside command's band (the XACA-0463 collision)",
        )

    def test_get_team_lcars_port_mainevent_returns_8400(self):
        """get_team_lcars_port() is NOT board-less-gated — a board-less alias
        still resolves its own port (it has an identity; it just has no board)."""
        cfg = _mainevent_overlay_config()
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            self.assertEqual(aiteamforge_paths.get_team_lcars_port("mainevent"), 8400)


# ---------------------------------------------------------------------------
# Item 4: legacy (pre-XACA-0794) un-migrated overlay shapes must still raise
# the same clear KeyError. Guards tap-seeded consumer boxes that haven't run
# the board-less-marker backfill yet.
#
# All three shapes below carry NO board_less/alias_of markers — they simulate
# an overlay written before XACA-0794 existed. load_config() is mocked
# directly (rather than routed through a real config file + the self-heal
# backfill) specifically so these tests isolate the SENTINEL FALLBACK branch
# in get_team_kanban_dir()/get_team_working_dir(), independent of whether the
# auto-migration already ran.
# ---------------------------------------------------------------------------

# Mirrors aiteamforge_paths._ABSENT_SENTINELS exactly (module constant is not
# imported here so a future accidental edit to the sentinel tuple is visible
# as a NEW test failure rather than silently tracking the change).
_LEGACY_ABSENT_SHAPES = (None, "", "null")


class TestBoardLessLegacyFallback(unittest.TestCase):
    """Item 4: un-migrated (pre-XACA-0794) overlay shapes still raise cleanly."""

    def _legacy_entry(self, shape):
        """A pre-XACA-0794 mainevent entry: no board_less/alias_of markers,
        kanban_dir/working_dir set to one of the three legacy 'absent' shapes."""
        return {
            "team_code": "MEV",
            "kanban_dir": shape,
            "working_dir": shape,
            "lcars_port": 8400,
            "anthropic_account_id": "",
            "anthropic_account_nickname": "",
            "anthropic_api_key_env_var": "TEAM_MAINEVENT_API_KEY",
            # Deliberately NO board_less / alias_of keys.
        }

    def test_legacy_kanban_dir_shapes_all_raise_keyerror(self):
        for shape in _LEGACY_ABSENT_SHAPES:
            with self.subTest(kanban_dir=repr(shape)):
                cfg = _mainevent_overlay_config(self._legacy_entry(shape))
                with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
                    with self.assertRaises(KeyError) as ctx:
                        aiteamforge_paths.get_team_kanban_dir("mainevent")
                self.assertIn("command", str(ctx.exception))

    def test_legacy_working_dir_shapes_all_raise_keyerror(self):
        for shape in _LEGACY_ABSENT_SHAPES:
            with self.subTest(working_dir=repr(shape)):
                cfg = _mainevent_overlay_config(self._legacy_entry(shape))
                with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
                    with self.assertRaises(KeyError) as ctx:
                        aiteamforge_paths.get_team_working_dir("mainevent")
                self.assertIn("command", str(ctx.exception))

    def test_legacy_entry_is_not_board_less_by_marker(self):
        """Sanity check on the fixture itself: the legacy entry has no marker,
        so team_is_board_less() is False and the KeyError above MUST be coming
        from the sentinel-normalization fallback, not the marker-first branch."""
        entry = self._legacy_entry(None)
        self.assertFalse(aiteamforge_paths.team_is_board_less(entry))


# ---------------------------------------------------------------------------
# Item 8: the board_less invariant itself — board_less=True must win even if
# a kanban_dir value is (erroneously) re-added to the entry. This is the
# guard against a future "cleanup" that re-populates kanban_dir on mainevent
# without also clearing board_less: the marker must be authoritative, not the
# value, so a stale/phantom path can never silently resolve.
# ---------------------------------------------------------------------------

class TestBoardLessInvariantWinsOverStaleValue(unittest.TestCase):
    """Item 8: board_less=True must override a re-added kanban_dir/working_dir."""

    def test_board_less_true_with_kanban_dir_value_still_raises(self):
        entry = {
            "team_code": "MEV",
            "board_less": True,
            "alias_of": "command",
            # Erroneously re-added a real-looking path alongside the marker.
            "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
            "lcars_port": 8400,
        }
        cfg = _mainevent_overlay_config(entry)
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            with self.assertRaises(KeyError) as ctx:
                aiteamforge_paths.get_team_kanban_dir("mainevent")
        self.assertIn("command", str(ctx.exception))

    def test_board_less_true_with_working_dir_value_still_raises(self):
        entry = {
            "team_code": "MEV",
            "board_less": True,
            "alias_of": "command",
            "working_dir": "/Users/Shared/Development/Main Event/dev-team",
            "lcars_port": 8400,
        }
        cfg = _mainevent_overlay_config(entry)
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            with self.assertRaises(KeyError) as ctx:
                aiteamforge_paths.get_team_working_dir("mainevent")
        self.assertIn("command", str(ctx.exception))


# ---------------------------------------------------------------------------
# Item 6: team-iterating consumers must skip the board-less alias cleanly
# rather than crashing (or, worse, silently collapsing their ENTIRE dynamic
# map to a hardcoded fallback because one KeyError escaped a bare comprehension
# — the exact bug XACA-0727 fixed in lcars-ui/server.py).
#
# build_team_code_map() never touches kanban_dir so it can't crash on
# mainevent by construction; it's exercised here only as a fast smoke check.
# The real coverage is server.py:_build_team_kanban_dirs() and
# kanban-backup.py:_get_team_kanban_dirs(), both loaded from their actual
# source files (hyphenated kanban-backup.py via importlib.util, mirroring the
# existing test_timepad_track_0620.py pattern) and exercised with their
# imported accessor names monkeypatched directly on the loaded module — never
# touching the real aiteamforge_paths.load_config() / real overlay file.
# ---------------------------------------------------------------------------

_REPO_ROOT = _HERE.parent


def _fake_iteration_fixture():
    """A minimal {list_teams, get_team_kanban_dir} pair simulating a config
    with academy + command + mainevent (board-less), for monkeypatching onto
    server.py / kanban-backup.py."""
    def fake_list_teams():
        return ["academy", "command", "mainevent"]

    def fake_get_team_kanban_dir(team):
        if team == "mainevent":
            raise aiteamforge_paths._board_less_error(
                "mainevent", DEFAULT_TEAMS["mainevent"], "kanban_dir"
            )
        return Path(f"/tmp/xaca0794-fixture/{team}/kanban")

    return fake_list_teams, fake_get_team_kanban_dir


class TestBuildTeamCodeMapSurvivesMainEvent(unittest.TestCase):
    """Fast smoke check: build_team_code_map() never raises on mainevent and
    still routes it (board-less teams keep their identity/code — only the
    board-path accessors are gated)."""

    def test_build_team_code_map_does_not_raise_and_includes_mainevent(self):
        cfg = _mainevent_overlay_config()
        with mock.patch.object(aiteamforge_paths, "load_config", return_value=cfg):
            result = build_team_code_map()  # must not raise
        self.assertEqual(result.get("MEV"), "mainevent")


class TestServerBuildTeamKanbanDirsSkipsBoardLess(unittest.TestCase):
    """Item 6: lcars-ui/server.py:_build_team_kanban_dirs() must skip
    mainevent without raising and without collapsing the whole map."""

    _server_mod = None
    _import_error = None

    @classmethod
    def setUpClass(cls):
        server_path = _REPO_ROOT / "lcars-ui" / "server.py"
        try:
            spec = importlib.util.spec_from_file_location(
                "xaca0794_server_under_test", str(server_path)
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            cls._server_mod = mod
        except Exception as exc:  # pragma: no cover - environment-dependent
            cls._import_error = exc

    def setUp(self):
        if self._server_mod is None:
            self.skipTest(f"lcars-ui/server.py could not be imported: {self._import_error!r}")

    def test_build_team_kanban_dirs_skips_mainevent_no_raise(self):
        fake_list_teams, fake_get_team_kanban_dir = _fake_iteration_fixture()
        fake_cfg = {
            "schema_version": 3,
            "teams": {"academy": {}, "command": {}, "mainevent": {}},
        }
        mod = self._server_mod
        with mock.patch.object(mod, "list_teams", fake_list_teams), \
             mock.patch.object(mod, "get_team_kanban_dir", fake_get_team_kanban_dir), \
             mock.patch.object(mod, "_aiteamforge_load_config", lambda: fake_cfg):
            result = mod._build_team_kanban_dirs()  # must not raise
        self.assertNotIn("mainevent", result, "board-less alias must be skipped, not crash the map")
        self.assertIn("academy", result)
        self.assertIn("command", result)


class TestKanbanBackupSkipsBoardLess(unittest.TestCase):
    """Item 6: kanban-backup.py:_get_team_kanban_dirs() must skip mainevent
    without raising. kanban-backup.py has a hyphenated filename, so it is
    loaded via importlib.util.spec_from_file_location (same pattern as
    test_timepad_track_0620.py's _load_dispatcher())."""

    _backup_mod = None
    _import_error = None

    @classmethod
    def setUpClass(cls):
        backup_path = _REPO_ROOT / "kanban-backup.py"
        try:
            spec = importlib.util.spec_from_file_location(
                "xaca0794_kanban_backup_under_test", str(backup_path)
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            cls._backup_mod = mod
        except Exception as exc:  # pragma: no cover - environment-dependent
            cls._import_error = exc

    def setUp(self):
        if self._backup_mod is None:
            self.skipTest(f"kanban-backup.py could not be imported: {self._import_error!r}")

    def test_get_team_kanban_dirs_skips_mainevent_no_raise(self):
        fake_list_teams, fake_get_team_kanban_dir = _fake_iteration_fixture()
        mod = self._backup_mod
        with mock.patch.object(mod, "list_teams", fake_list_teams), \
             mock.patch.object(mod, "get_team_kanban_dir", fake_get_team_kanban_dir):
            result = mod._get_team_kanban_dirs()  # must not raise
        self.assertNotIn("mainevent", result, "board-less alias must be skipped, not crash the map")
        self.assertIn("academy", result)
        self.assertIn("command", result)


# ---------------------------------------------------------------------------
# Item 7: _backfill_board_less_markers_on_disk() / apply_board_less_markers()
# must be STRICTLY ADDITIVE and IDEMPOTENT:
#   - a customized board-less team's other fields survive byte-for-byte
#   - other teams are untouched
#   - a second run is a byte-identical no-op
# ---------------------------------------------------------------------------

def _customized_mainevent_entry() -> dict:
    """A mainevent entry with several fields customized away from
    DEFAULT_TEAMS, simulating a real per-machine overlay a user has hand-tuned
    (custom port, custom Anthropic account, custom copyright-style extra
    fields the backfill has never heard of)."""
    return {
        "team_code": "MEV",
        "kanban_dir": None,
        "working_dir": None,
        "lcars_port": 8499,  # customized away from the 8400 default
        "anthropic_account_id": "custom-acct-id-123",
        "anthropic_account_nickname": "Custom MainEvent Account",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_API_KEY",
        "copyright_holder": "Custom Holder LLC",  # arbitrary unknown-to-backfill field
        "copyright_year_start": 2024,
        # Deliberately NO board_less / alias_of — pre-XACA-0794 shape.
    }


class TestApplyBoardLessMarkersPure(unittest.TestCase):
    """Item 7 (pure-function half): apply_board_less_markers() in isolation,
    no disk I/O involved."""

    def test_apply_board_less_markers_is_additive(self):
        original = {
            "schema_version": 3,
            "teams": {
                "academy": _minimal_team_entry("academy"),
                "mainevent": _customized_mainevent_entry(),
            },
        }
        upgraded = aiteamforge_paths.apply_board_less_markers(original)
        me = upgraded["teams"]["mainevent"]

        self.assertIs(me["board_less"], True)
        self.assertEqual(me["alias_of"], "command")

        # Every customized field must survive byte-for-byte.
        original_me = original["teams"]["mainevent"]
        for key in original_me:
            self.assertEqual(
                me[key], original_me[key],
                f"Field {key!r} must be preserved unchanged by the backfill",
            )

        # academy (a non-board-less team) must be completely untouched.
        self.assertEqual(upgraded["teams"]["academy"], original["teams"]["academy"])

    def test_apply_board_less_markers_does_not_mutate_input(self):
        original = {
            "schema_version": 3,
            "teams": {"mainevent": _customized_mainevent_entry()},
        }
        snapshot = copy.deepcopy(original)
        aiteamforge_paths.apply_board_less_markers(original)
        self.assertEqual(original, snapshot, "Input config must not be mutated (pure function contract)")

    def test_apply_board_less_markers_second_run_is_idempotent(self):
        original = {
            "schema_version": 3,
            "teams": {
                "academy": _minimal_team_entry("academy"),
                "mainevent": _customized_mainevent_entry(),
            },
        }
        once = aiteamforge_paths.apply_board_less_markers(original)
        twice = aiteamforge_paths.apply_board_less_markers(once)
        self.assertEqual(once, twice, "Second run over an already-migrated config must be a no-op")


class TestBoardLessBackfillOnDiskAdditiveIdempotent(unittest.TestCase):
    """Item 7 (disk half): _backfill_board_less_markers_on_disk(), driven
    through the real load_config() self-heal path against a temp config file
    — never the real ~/.aiteamforge/team-paths.json."""

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="xaca0794_backfill_test_")
        self._config_path = os.path.join(self._tmp, "team-paths.json")
        _reset_module_cache()
        self._orig_env = os.environ.get("AITEAMFORGE_CONFIG")
        os.environ["AITEAMFORGE_CONFIG"] = self._config_path

    def tearDown(self):
        _reset_module_cache()
        if self._orig_env is None:
            os.environ.pop("AITEAMFORGE_CONFIG", None)
        else:
            os.environ["AITEAMFORGE_CONFIG"] = self._orig_env
        try:
            shutil.rmtree(self._tmp)
        except OSError:
            pass

    def _write_legacy_config(self) -> dict:
        cfg = {
            "schema_version": 3,
            "teams": {
                "academy": _minimal_team_entry("academy"),
                "command": _minimal_team_entry("command"),
                "mainevent": _customized_mainevent_entry(),
            },
        }
        with open(self._config_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
        return cfg

    def test_backfill_on_disk_preserves_customized_fields(self):
        original = self._write_legacy_config()

        result = aiteamforge_paths.load_config()  # triggers the on-disk backfill
        me = result["teams"]["mainevent"]

        self.assertIs(me.get("board_less"), True)
        self.assertEqual(me.get("alias_of"), "command")
        for key in original["teams"]["mainevent"]:
            self.assertEqual(
                me[key], original["teams"]["mainevent"][key],
                f"Field {key!r} must survive the on-disk backfill unchanged",
            )
        # academy / command untouched.
        self.assertEqual(result["teams"]["academy"], original["teams"]["academy"])
        self.assertEqual(result["teams"]["command"], original["teams"]["command"])

    def test_backfill_on_disk_second_run_is_byte_identical_noop(self):
        self._write_legacy_config()

        aiteamforge_paths.load_config()  # first pass: performs the on-disk backfill
        with open(self._config_path, encoding="utf-8") as fh:
            after_first = fh.read()

        _reset_module_cache()  # force a fresh read + backfill-check cycle
        aiteamforge_paths.load_config()  # second pass: must be a no-op
        with open(self._config_path, encoding="utf-8") as fh:
            after_second = fh.read()

        self.assertEqual(
            after_first, after_second,
            "A second backfill pass over an already-migrated config must not touch the file again",
        )


# ---------------------------------------------------------------------------
# Small direct-unit coverage of the board-less predicate helpers themselves,
# so a future edit to their matching semantics (e.g. accepting a truthy
# non-True value, or dropping the DEFAULT_TEAMS alias_of fallback) shows up
# as a failing test here rather than only downstream.
# ---------------------------------------------------------------------------

class TestBoardLessHelperPredicates(unittest.TestCase):

    def test_team_is_board_less_true_for_explicit_marker(self):
        self.assertTrue(aiteamforge_paths.team_is_board_less({"board_less": True}))

    def test_team_is_board_less_false_when_key_absent(self):
        self.assertFalse(aiteamforge_paths.team_is_board_less({}))

    def test_team_is_board_less_false_for_truthy_non_true_value(self):
        """Guards against a stringly-typed 'true' (e.g. JSON round-tripped
        through a shell layer) being silently accepted as the marker."""
        self.assertFalse(aiteamforge_paths.team_is_board_less({"board_less": "true"}))
        self.assertFalse(aiteamforge_paths.team_is_board_less({"board_less": 1}))

    def test_board_less_alias_of_uses_explicit_value_when_present(self):
        self.assertEqual(
            aiteamforge_paths.board_less_alias_of("mainevent", {"alias_of": "command"}),
            "command",
        )

    def test_board_less_alias_of_falls_back_to_default_teams(self):
        """An entry with no explicit alias_of still resolves via DEFAULT_TEAMS
        — this is what keeps the legacy (un-migrated) fallback's error message
        helpful even before the marker backfill has run."""
        self.assertEqual(
            aiteamforge_paths.board_less_alias_of("mainevent", {}),
            "command",
        )

    def test_board_less_alias_of_none_for_non_alias_team(self):
        self.assertIsNone(aiteamforge_paths.board_less_alias_of("academy", {}))


# ---------------------------------------------------------------------------
# XACA-0794-008 / -009 / -012: the SHARED on-disk rewrite helper.
#
# All three self-heal passes (A.1 backfill, contract scrub, board-less markers)
# now route through _rewrite_config_on_disk / _atomic_write_json. These tests pin
# the three properties that were broken in all three cloned copies, and they drive
# the real load_config() self-heal path against a temp config — never the real
# ~/.aiteamforge/team-paths.json.
#
# Each property is asserted against MORE THAN ONE pass where practical, because the
# whole point of the refactor is that the passes no longer have independent write
# paths that could regress separately.
# ---------------------------------------------------------------------------

class TestSharedOnDiskRewriteContract(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="xaca0794_rewrite_test_")
        self._config_path = os.path.join(self._tmp, "team-paths.json")
        _reset_module_cache()
        self._orig_env = os.environ.get("AITEAMFORGE_CONFIG")
        os.environ["AITEAMFORGE_CONFIG"] = self._config_path

    def tearDown(self):
        _reset_module_cache()
        if self._orig_env is None:
            os.environ.pop("AITEAMFORGE_CONFIG", None)
        else:
            os.environ["AITEAMFORGE_CONFIG"] = self._orig_env
        try:
            shutil.rmtree(self._tmp)
        except OSError:
            pass

    def _write_config(self, path=None, *, with_scrub_violation=False) -> dict:
        """A config that still needs the board-less backfill (mainevent lacks markers).

        with_scrub_violation additionally seeds a bare "freelance" key, which makes
        the CONTRACT SCRUB pass fire too — letting a test prove the property holds
        for a pre-existing pass, not just the new one.
        """
        teams = {
            "academy": _minimal_team_entry("academy"),
            "command": _minimal_team_entry("command"),
            "mainevent": _customized_mainevent_entry(),
        }
        if with_scrub_violation:
            teams["freelance"] = _minimal_team_entry("freelance")
        cfg = {"schema_version": 3, "teams": teams}
        with open(path or self._config_path, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
        return cfg

    def _assert_rewrite_happened(self, path=None):
        with open(path or self._config_path, encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertIs(
            on_disk["teams"]["mainevent"].get("board_less"), True,
            "precondition: the self-heal pass must actually have rewritten the file",
        )

    # -- XACA-0794-008: file mode ------------------------------------------

    def test_rewrite_preserves_0600_mode(self):
        """A 0600 config must not silently widen to 0644 on self-heal.

        The tmp file was created under the process umask and os.replace() carried
        that mode onto the config. team-paths.json holds per-team Anthropic account
        ids and API-key env-var names, so this was a real permission regression.
        """
        self._write_config()
        os.chmod(self._config_path, 0o600)

        aiteamforge_paths.load_config()  # triggers the on-disk backfill

        self._assert_rewrite_happened()
        mode = stat.S_IMODE(os.stat(self._config_path).st_mode)
        self.assertEqual(
            mode, 0o600,
            f"config mode must survive the rewrite; got {oct(mode)} (expected 0o600)",
        )

    def test_rewrite_preserves_0640_mode_through_contract_scrub(self):
        """Same property, exercised through a PRE-EXISTING pass (the contract scrub),
        proving the fix is central rather than local to the new board-less pass."""
        self._write_config(with_scrub_violation=True)
        os.chmod(self._config_path, 0o640)

        result = aiteamforge_paths.load_config()

        self.assertNotIn(
            "freelance", result["teams"],
            "precondition: the contract scrub must actually have fired",
        )
        mode = stat.S_IMODE(os.stat(self._config_path).st_mode)
        self.assertEqual(mode, 0o640, f"got {oct(mode)} (expected 0o640)")

    # -- XACA-0794-009: symlinked config ------------------------------------

    def test_rewrite_through_symlink_keeps_symlink_and_updates_target(self):
        """os.replace(tmp, link) would replace the LINK with a regular file and
        orphan the real target. The write must follow the link."""
        real_path = os.path.join(self._tmp, "real-team-paths.json")
        self._write_config(path=real_path)
        os.symlink(real_path, self._config_path)

        aiteamforge_paths.load_config()  # triggers the on-disk backfill

        # The config path must STILL be a symlink...
        self.assertTrue(
            os.path.islink(self._config_path),
            "the symlink was replaced by a regular file — the real target is orphaned",
        )
        self.assertEqual(os.path.realpath(self._config_path), os.path.realpath(real_path))

        # ...and the REAL file behind it must carry the update.
        with open(real_path, encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertIs(
            on_disk["teams"]["mainevent"].get("board_less"), True,
            "the symlink target did not receive the rewrite",
        )

    def test_rewrite_through_symlink_preserves_target_mode(self):
        """008 and 009 must hold TOGETHER: the mode preserved is the real file's."""
        real_path = os.path.join(self._tmp, "real-team-paths.json")
        self._write_config(path=real_path)
        os.chmod(real_path, 0o600)
        os.symlink(real_path, self._config_path)

        aiteamforge_paths.load_config()

        self.assertTrue(os.path.islink(self._config_path))
        mode = stat.S_IMODE(os.stat(real_path).st_mode)
        self.assertEqual(mode, 0o600, f"got {oct(mode)} (expected 0o600)")

    def test_no_tmp_files_left_behind(self):
        """The atomic write must not litter .tmp.<pid> files next to the config."""
        self._write_config()
        aiteamforge_paths.load_config()

        leftovers = [n for n in os.listdir(self._tmp) if ".tmp." in n]
        self.assertEqual(leftovers, [], f"tmp files left behind: {leftovers}")

    # -- XACA-0794-012: lock file identity ----------------------------------

    def test_lock_file_is_not_unlinked_under_the_held_lock(self):
        """The passes used to unlink the lock file while STILL holding the flock, so a
        racing process could create a fresh lock inode and both would 'hold' the lock.
        The lock must survive the rewrite — a lock's job is to have a stable identity.
        """
        self._write_config()
        aiteamforge_paths.load_config()  # triggers the on-disk backfill

        self._assert_rewrite_happened()
        lock_path = os.path.join(self._tmp, "team-paths.json.lock")
        self.assertTrue(
            os.path.exists(lock_path),
            "lock file was unlinked — mutual exclusion is not guaranteed against a racing process",
        )

    def test_lock_is_taken_on_the_resolved_path_not_the_symlink(self):
        """Two processes reaching the same config, one via a symlink and one via the
        real path, must contend for the SAME lock inode."""
        real_path = os.path.join(self._tmp, "real-team-paths.json")
        self._write_config(path=real_path)
        os.symlink(real_path, self._config_path)

        aiteamforge_paths.load_config()

        self.assertTrue(
            os.path.exists(os.path.join(self._tmp, "real-team-paths.json.lock")),
            "lock must be taken on the resolved target, not on the symlink name",
        )

    # -- the self-heal itself still works ------------------------------------

    def test_rewrite_is_still_idempotent_after_refactor(self):
        """Guard against the refactor breaking the skip-fast no-op property."""
        self._write_config()
        aiteamforge_paths.load_config()
        with open(self._config_path, encoding="utf-8") as fh:
            after_first = fh.read()

        _reset_module_cache()
        aiteamforge_paths.load_config()
        with open(self._config_path, encoding="utf-8") as fh:
            after_second = fh.read()

        self.assertEqual(after_first, after_second)


# ---------------------------------------------------------------------------
# XACA-0794-011: shell/Python parity for the board-less alias fallback.
#
# _kb_board_less_alias_of() returned 0 with EMPTY output when an overlay carried
# board_less=true but no alias_of, so the caller's error message lost its "use
# 'command' instead" guidance. Python's board_less_alias_of() falls back to
# DEFAULT_TEAMS in exactly that case. These tests pin the two halves together by
# actually SOURCING kanban-helpers.sh under zsh and calling the function.
# ---------------------------------------------------------------------------

class TestShellBoardLessAliasFallbackParity(unittest.TestCase):

    HELPERS = Path(__file__).resolve().parent.parent / "kanban-helpers.sh"

    def setUp(self):
        if shutil.which("zsh") is None:
            self.skipTest("zsh not available")
        if not self.HELPERS.is_file():
            self.skipTest(f"kanban-helpers.sh not found at {self.HELPERS}")
        self._tmp = tempfile.mkdtemp(prefix="xaca0794_shellparity_")

    def tearDown(self):
        try:
            shutil.rmtree(self._tmp)
        except OSError:
            pass

    def _run_alias_of(self, overlay: dict, team: str = "mainevent"):
        """Source kanban-helpers.sh under zsh against a temp overlay and echo
        _kb_board_less_alias_of's stdout + exit status."""
        import subprocess

        cfg_path = os.path.join(self._tmp, "team-paths.json")
        with open(cfg_path, "w", encoding="utf-8") as fh:
            json.dump(overlay, fh, indent=2)

        script = (
            f'export AITEAMFORGE_CONFIG="{cfg_path}"\n'
            'export KB_TEAM=academy KB_TERMINAL=agent\n'
            f'source "{self.HELPERS}" >/dev/null 2>&1\n'
            f'_out=$(_kb_board_less_alias_of "{team}"); _rc=$?\n'
            'printf "%s|%s" "$_out" "$_rc"\n'
        )
        proc = subprocess.run(
            ["zsh", "-c", script], capture_output=True, text=True, timeout=120,
        )
        out, _, rc = proc.stdout.rpartition("|")
        return out.strip(), rc.strip()

    def _overlay(self, mainevent_entry: dict) -> dict:
        return {
            "schema_version": 3,
            "teams": {
                "academy": _minimal_team_entry("academy"),
                "command": _minimal_team_entry("command"),
                "mainevent": mainevent_entry,
            },
        }

    def test_alias_falls_back_to_builtin_when_overlay_omits_alias_of(self):
        """THE BUG: board_less=true with NO alias_of used to yield empty output."""
        entry = {"team_code": "MEV", "board_less": True}  # no alias_of
        out, rc = self._run_alias_of(self._overlay(entry))

        self.assertEqual(rc, "0", "board-less team must still be reported as board-less")
        self.assertEqual(
            out, "command",
            "shell must fall back to the built-in DEFAULT_TEAMS alias like Python's "
            "board_less_alias_of() does — otherwise the error message loses the alias target",
        )
        # Parity: Python agrees on the same overlay entry.
        self.assertEqual(aiteamforge_paths.board_less_alias_of("mainevent", entry), "command")

    def test_alias_falls_back_when_overlay_alias_of_is_null(self):
        """A JSON null alias_of is one of the _ABSENT_SENTINELS — same fallback."""
        entry = {"team_code": "MEV", "board_less": True, "alias_of": None}
        out, rc = self._run_alias_of(self._overlay(entry))

        self.assertEqual(rc, "0")
        self.assertEqual(out, "command")
        self.assertEqual(aiteamforge_paths.board_less_alias_of("mainevent", entry), "command")

    def test_explicit_overlay_alias_of_still_wins(self):
        """The marker remains authoritative when it DOES carry a target."""
        entry = {"team_code": "MEV", "board_less": True, "alias_of": "command"}
        out, rc = self._run_alias_of(self._overlay(entry))

        self.assertEqual(rc, "0")
        self.assertEqual(out, "command")

    def test_non_board_less_team_returns_nonzero(self):
        """A normal team must NOT be reported as a board-less alias."""
        out, rc = self._run_alias_of(
            self._overlay(_customized_mainevent_entry()), team="academy",
        )
        self.assertEqual(rc, "1")
        self.assertEqual(out, "")


# ---------------------------------------------------------------------------
# XACA-0806: mainevent per-project port registration + the explicit-band-
# beats-heuristic ordering fix in _resolve_template_band().
#
# Ticket recap: mainevent-startup.sh's shell fallback previously allocated
# per-project LCARS ports from [8510, 8599] — squatting inside freelance's
# canonical band [8500, 8600). Subitem 2 registered 5 seeded mainevent-<project>
# instances and declared _TEMPLATE_PORT_BANDS["mainevent"] = (8401, 19).
# Subitem 3 fixed a shadowing bug: _resolve_template_band() used to run its
# strip-dash tolerant lookup BEFORE consulting _TEMPLATE_PORT_BANDS, so an
# UNSEEDED "mainevent-<project>" would resolve to the bare "mainevent" alias's
# OWN band (8400, 1) instead of the per-project band (8401, 19) — silently
# donating the board-less alias's port to an arbitrary per-project child.
# ---------------------------------------------------------------------------

class TestMainEventPortBandRegression(unittest.TestCase):
    """Locks the XACA-0806 subitem-3 fix and its surrounding invariants.

    See module docstring block above for the ticket recap.
    """

    # ── (a) THE regression test for the shadowing bug ──────────────────────

    def test_resolve_template_band_unseeded_mainevent_uses_per_project_band(self):
        """_resolve_template_band('mainevent-<unseeded>') MUST return (8401, 19),
        the per-project band — NOT (8400, 1), the bare board-less alias's own
        band.

        THE TRAP this guards against: "mainevent" has a bare entry in
        DEFAULT_TEAMS (the board-less alias, lcars_port_base=8400,
        lcars_port_range=1 — see that entry above). _resolve_template_band()
        also has an explicit _TEMPLATE_PORT_BANDS["mainevent"] = (8401, 19)
        declaration for per-project children. Before XACA-0806 subitem 3, the
        function's strip-dash tolerant-lookup step ran BEFORE the explicit-band
        step, so an instance id that only matched via strip-dash (i.e. anything
        NOT already a seeded key in DEFAULT_TEAMS) would find the bare
        "mainevent" entry FIRST and return its (8400, 1) band instead — a
        silent donation of the alias's own port range to an arbitrary
        per-project instance.

        DO NOT "simplify" _resolve_template_band()'s step ordering back to
        strip-dash-before-explicit-band as a cleanup — that ordering IS the
        bug this test exists to catch. The explicit _TEMPLATE_PORT_BANDS
        declaration must be checked before the heuristic derivation for any
        template (like mainevent) that has BOTH a bare DEFAULT_TEAMS entry AND
        a separate _TEMPLATE_PORT_BANDS entry for its instances.

        "<unseeded>" here means a project name deliberately absent from the 5
        seeded mainevent-* keys in DEFAULT_TEAMS (mainevent-dev-team,
        mainevent-maineventapp-ios/-android/-functions,
        mainevent-maineventwrapper-ios) — the pathological case this bug
        actually affected. A seeded key would hit step 1 (direct match) and
        never reach the ordering this test is about.
        """
        self.assertNotIn(
            "mainevent-somefutureproject", DEFAULT_TEAMS,
            "test fixture must be an unseeded instance id, or this test "
            "exercises step 1 (direct match) instead of the ordering fix",
        )
        result = aiteamforge_paths._resolve_template_band("mainevent-somefutureproject")
        self.assertEqual(
            result, (8401, 19),
            "unseeded 'mainevent-<project>' must resolve via the explicit "
            "_TEMPLATE_PORT_BANDS declaration (8401, 19), not the bare alias's "
            "own band (8400, 1) via strip-dash shadowing",
        )

    # ── (b) explicit-band-beats-heuristic must NOT regress templates that ──
    # ── intentionally resolve via seeded *-instance entries instead of a ───
    # ── _TEMPLATE_PORT_BANDS declaration ────────────────────────────────────

    def test_finance_legal_medical_absent_from_template_port_bands(self):
        """finance/legal/medical are DELIBERATELY absent from
        _TEMPLATE_PORT_BANDS (XACA-0643) — they resolve via their seeded
        *-instance entries in DEFAULT_TEAMS instead. If a future edit adds
        them there by mistake, this documents the intentional absence so the
        change is caught and reviewed, not silently accepted."""
        for base_template in ("finance", "legal", "medical"):
            self.assertNotIn(
                base_template, aiteamforge_paths._TEMPLATE_PORT_BANDS,
                f"'{base_template}' must stay OUT of _TEMPLATE_PORT_BANDS — "
                "it resolves via its seeded *-instance entry, not a declared band",
            )

    def test_finance_legal_medical_bands_unaffected_by_reordering(self):
        """The explicit-band-before-strip-dash reordering (XACA-0806 subitem 3)
        must be a no-op for templates with NO _TEMPLATE_PORT_BANDS entry: the
        explicit-band step simply misses and falls through to strip-dash
        exactly as before the reorder. Assert the resolved bands explicitly."""
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("finance-personal"), (8360, 10),
        )
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("legal-coparenting"), (8320, 10),
        )
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("medical-general"), (8340, 10),
        )

    def test_freelance_band_unaffected_by_reordering(self):
        """freelance IS in _TEMPLATE_PORT_BANDS (8500, 100) and has NO bare
        DEFAULT_TEAMS entry — the reordering must not change its resolution,
        whether queried by base template id or by an (unseeded) instance id."""
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("freelance"), (8500, 100),
        )
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("freelance-someclient-someproject"),
            (8500, 100),
        )

    # ── (c) no mainevent instance collides with the bare alias's 8400; all ─
    # ── 5 registered instances fall inside [8401, 8419] ─────────────────────

    _SEEDED_MAINEVENT_INSTANCES = (
        "mainevent-dev-team",
        "mainevent-maineventapp-ios",
        "mainevent-maineventapp-android",
        "mainevent-maineventapp-functions",
        "mainevent-maineventwrapper-ios",
    )

    def test_five_seeded_mainevent_instances_present(self):
        """Fixture sanity: all 5 instances subitem 2 registered are still
        present in DEFAULT_TEAMS (guards against an instance being silently
        dropped without this test noticing)."""
        for instance in self._SEEDED_MAINEVENT_INSTANCES:
            self.assertIn(instance, DEFAULT_TEAMS, f"{instance} missing from DEFAULT_TEAMS")

    def test_seeded_mainevent_instance_ports_fall_inside_own_band(self):
        """Every seeded mainevent-<project> instance's lcars_port must fall
        inside [8401, 8419) — mainevent's per-project band — and NONE may
        equal 8400, the bare board-less alias's own port."""
        band_base, band_range = aiteamforge_paths._TEMPLATE_PORT_BANDS["mainevent"]
        self.assertEqual((band_base, band_range), (8401, 19))
        for instance in self._SEEDED_MAINEVENT_INSTANCES:
            port = DEFAULT_TEAMS[instance]["lcars_port"]
            self.assertNotEqual(
                port, 8400,
                f"{instance}'s port must not collide with the bare 'mainevent' "
                "alias's own port 8400",
            )
            self.assertTrue(
                band_base <= port < band_base + band_range,
                f"{instance}'s port {port} must fall inside [{band_base}, "
                f"{band_base + band_range}) — its own declared band",
            )

    def test_seeded_mainevent_instance_ports_are_unique(self):
        """No two seeded mainevent instances may share a port (would be a
        silent double-allocation within DEFAULT_TEAMS itself)."""
        ports = [DEFAULT_TEAMS[i]["lcars_port"] for i in self._SEEDED_MAINEVENT_INSTANCES]
        self.assertEqual(
            len(ports), len(set(ports)),
            f"duplicate lcars_port among seeded mainevent instances: {ports}",
        )

    # ── (d) the bare mainevent entry is untouched by this ticket ───────────

    def test_bare_mainevent_still_resolves_to_8400(self):
        """The bare board-less 'mainevent' alias entry itself must still
        resolve to port 8400 — this ticket only changed how UNSEEDED
        per-project instances resolve, not the alias's own identity. Its band
        is now [8400,8401) (range narrowed 10→1 by XACA-0806 to stop the
        nominal overlap with the per-project band [8401,8419))."""
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertEqual(entry["lcars_port"], 8400)
        self.assertEqual(entry["lcars_port_base"], 8400)
        self.assertEqual(entry["lcars_port_range"], 1)
        # Direct-key lookup (step 1) must win for the bare key itself, same as
        # before this ticket — it must NOT be redirected to the per-project band.
        self.assertEqual(
            aiteamforge_paths._resolve_template_band("mainevent"), (8400, 1),
        )

    def test_bare_mainevent_still_board_less_alias_of_command(self):
        """The bare 'mainevent' entry's board_less/alias_of markers (XACA-0727/
        XACA-0794) are untouched by this ticket."""
        entry = DEFAULT_TEAMS["mainevent"]
        self.assertTrue(entry.get("board_less"))
        self.assertEqual(entry.get("alias_of"), "command")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
