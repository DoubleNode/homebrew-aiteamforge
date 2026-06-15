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
import json
import os
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
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main(verbosity=2)
