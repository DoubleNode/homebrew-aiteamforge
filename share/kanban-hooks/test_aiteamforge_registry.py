#!/usr/bin/env python3
"""
test_aiteamforge_registry.py — Unit tests for the XACA-1161 read-path resolver.

XACA-1161-002.

Run:
    python3 -m unittest kanban-hooks/test_aiteamforge_registry.py -v
    # or from inside kanban-hooks/:
    python3 -m unittest test_aiteamforge_registry -v

Fixture discipline
------------------
Almost every test drives the resolver through an INJECTED ``config=`` dict and a
patched ``DEFAULT_TEAMS``. The live overlay is deliberately not the subject:
measured during authoring, ``~/.aiteamforge/team-paths.json`` gained a team
(``spacedock``) between two runs twenty minutes apart, because another session
provisioned one. A suite pinned to live values or to a hardcoded team count is
a suite that goes red for reasons that have nothing to do with the code.

The three tests that DO touch the live registry (LiveRegistry*) compute their
expectations at runtime from whatever the registry currently holds, and assert
*shape* — never a fixed count.

S006 corollary: a fixture captured from a healthy machine contains no zeros, no
declared nulls and no missing keys, so it cannot exercise the defects this
module exists to prevent. The fixtures below are hand-authored to contain
exactly those cases.
"""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# ---------------------------------------------------------------------------
# Ensure kanban-hooks/ is importable regardless of invocation directory.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import aiteamforge_paths  # noqa: E402
import aiteamforge_registry as reg  # noqa: E402


# ---------------------------------------------------------------------------
# Hand-authored fixtures — every one of the three S002 states is present.
# ---------------------------------------------------------------------------

def _cfg(teams: dict) -> dict:
    return {"schema_version": 3, "teams": teams}


class ResolutionOrderTests(unittest.TestCase):
    """Tier order: OVERLAY -> DEFAULT_TEAMS -> DERIVED -> ABSENT."""

    def test_overlay_wins_over_default_teams(self):
        cfg = _cfg({"alpha": {"team_code": "OVR"}})
        defaults = {"alpha": {"team_code": "DEF"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("alpha", "team_code", config=cfg)
        self.assertEqual(d.value, "OVR")
        self.assertIs(d.source, reg.Source.OVERLAY)
        self.assertIs(d.state, reg.FieldState.DECLARED)

    def test_default_teams_used_when_overlay_lacks_the_key(self):
        """Migration tolerance: an overlay predating a field still resolves."""
        cfg = _cfg({"alpha": {"kanban_dir": "/tmp/a/kanban"}})
        defaults = {"alpha": {"anthropic_api_key_env_var": "TEAM_ALPHA_API_KEY"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("alpha", "anthropic_api_key_env_var", config=cfg)
        self.assertEqual(d.value, "TEAM_ALPHA_API_KEY")
        self.assertIs(d.source, reg.Source.DEFAULT_TEAMS)

    def test_default_teams_supplies_a_team_the_overlay_never_heard_of(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        defaults = {"beta": {"team_code": "BET"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            self.assertEqual(reg.team_code("beta", config=cfg), "BET")
            self.assertIn("beta", reg.registered_teams(config=cfg))

    def test_derived_tier_fires_only_when_no_tier_declared_the_field(self):
        cfg = _cfg({"alpha": {"kanban_dir": "/srv/projects/alpha/kanban"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            d = reg.declare_field("alpha", "working_dir", config=cfg)
        self.assertIs(d.source, reg.Source.DERIVED)
        self.assertEqual(d.value, "/srv/projects/alpha")

    def test_declared_working_dir_beats_the_deriver(self):
        cfg = _cfg({"alpha": {
            "kanban_dir": "/srv/projects/alpha/kanban",
            "working_dir": "/somewhere/else",
        }})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            d = reg.declare_field("alpha", "working_dir", config=cfg)
        self.assertIs(d.source, reg.Source.OVERLAY)
        self.assertEqual(d.value, "/somewhere/else")

    def test_absence_is_the_last_tier(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            d = reg.declare_field("alpha", "license_type", config=cfg)
        self.assertIs(d.state, reg.FieldState.NOT_DECLARED)
        self.assertIs(d.value, reg.ABSENT)
        self.assertIs(d.source, reg.Source.NONE)

    def test_no_deriver_may_invent_an_identity(self):
        """K659 / XACA-1058: team_code and lcars_port must have NO deriver."""
        for field in ("team_code", "lcars_port", "lcars_port_base", "lcars_port_range"):
            with self.subTest(field=field):
                self.assertIsNone(reg.spec_for(field).deriver)

    def test_working_dir_is_the_only_registered_deriver(self):
        derivers = [n for n, s in reg._FIELD_SPECS.items() if s.deriver is not None]
        self.assertEqual(derivers, ["working_dir"])


class ExplicitNullVersusAbsentTests(unittest.TestCase):
    """S002 — a declared null/0/False is DATA, not absence."""

    def test_declared_null_is_distinguishable_from_a_missing_key(self):
        cfg = _cfg({
            "declared": {"lcars_port": None},
            "missing": {"team_code": "MIS"},
        })
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            declared = reg.declare_field("declared", "lcars_port", config=cfg)
            missing = reg.declare_field("missing", "lcars_port", config=cfg)
        self.assertIs(declared.state, reg.FieldState.DECLARED_ABSENT)
        self.assertIs(missing.state, reg.FieldState.NOT_DECLARED)
        self.assertIsNot(declared.state, missing.state)

    def test_shell_seed_string_null_is_an_absence_sentinel(self):
        """The positional table cannot omit a column; 'null' is its only 'absent'."""
        cfg = _cfg({"medicalish": {"lcars_port": "null"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            d = reg.declare_field("medicalish", "lcars_port", config=cfg)
        self.assertIs(d.state, reg.FieldState.DECLARED_ABSENT)
        self.assertIsNot(d.value, "null")

    def test_medical_general_shape_declared_null_beats_a_seed_value(self):
        """The live divergence: shell says null, DEFAULT_TEAMS says 8340.

        An overlay seeded from the shell table carries the null. Because
        lcars_port's spec sets absent_stops_chain=True, that declared absence
        is an ANSWER and wins over the seed's 8340 — it does not fall through.
        """
        cfg = _cfg({"medical-general": {"lcars_port": None}})
        defaults = {"medical-general": {"lcars_port": 8340}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("medical-general", "lcars_port", config=cfg)
            self.assertIs(d.state, reg.FieldState.DECLARED_ABSENT)
            self.assertIs(d.source, reg.Source.OVERLAY)
            self.assertIsNone(reg.lcars_port("medical-general", config=cfg))

    def test_zero_is_data_not_absence(self):
        cfg = _cfg({"alpha": {"lcars_port": 0, "year_start": 0}})
        defaults = {"alpha": {"lcars_port": 8340}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            port = reg.declare_field("alpha", "lcars_port", config=cfg)
            year = reg.declare_field("alpha", "year_start", config=cfg)
        self.assertIs(port.state, reg.FieldState.DECLARED)
        self.assertEqual(port.value, 0)
        self.assertIs(year.state, reg.FieldState.DECLARED)
        self.assertEqual(year.value, 0)

    def test_false_is_data_not_absence(self):
        cfg = _cfg({"alpha": {"board_less": False, "kanban_dir": "/tmp/a/kanban"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            d = reg.declare_field("alpha", "board_less", config=cfg)
            self.assertIs(d.state, reg.FieldState.DECLARED)
            self.assertIs(d.value, False)
            self.assertFalse(reg.is_board_less("alpha", config=cfg))

    def test_primary_host_empty_string_is_a_declared_value(self):
        """XACA-0802-004: a present '' means 'unowned', and must NOT fall through."""
        cfg = _cfg({"alpha": {"primary_host": ""}})
        defaults = {"alpha": {"primary_host": "Darren-M3Pro"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("alpha", "primary_host", config=cfg)
            self.assertIs(d.state, reg.FieldState.DECLARED)
            self.assertEqual(d.value, "")
            self.assertEqual(reg.primary_host("alpha", config=cfg), "")

    def test_primary_host_absent_key_does_fall_through(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        defaults = {"alpha": {"primary_host": "Darren-M3Pro"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            self.assertEqual(reg.primary_host("alpha", config=cfg), "Darren-M3Pro")

    def test_ai_empty_string_is_a_declared_value_and_stops_the_chain(self):
        """XACA-1184: the ``ai`` block replaced the ``anthropic_*`` trio, and it
        does NOT inherit that trio's sentinel vocabulary.

        The retired ``anthropic_account_id`` was _NULLISH — a present ``""``
        meant "declared, deliberately blank" and stopped the chain. ``ai`` is
        _KEYONLY, so ``""`` is not a sentinel for a DIFFERENT reason: it is
        CORRUPTION in a field that is supposed to hold a structured block. Both
        rules produce DECLARED here, so this test pins the consequence that
        actually distinguishes them — the accessor must SEE the corruption and
        warn rather than silently falling through to the seed's real block,
        which would resolve a live credential for a team whose overlay says
        something is wrong (XACA-1178-016/024).
        """
        cfg = _cfg({"alpha": {"ai": ""}})
        defaults = {"alpha": {"ai": {"credential": {"account_id": "acct-from-seed"}}}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("alpha", "ai", config=cfg)
            self.assertIs(d.state, reg.FieldState.DECLARED)
            self.assertEqual(d.value, "")
            self.assertIs(d.source, reg.Source.OVERLAY)
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertIs(reg.ai_credential("alpha", config=cfg), reg.ABSENT)
        self.assertIn("not a dict", err.getvalue())

    def test_pathish_empty_string_IS_absence_and_stops_the_chain(self):
        cfg = _cfg({"alpha": {"kanban_dir": ""}})
        defaults = {"alpha": {"kanban_dir": "/real/path/kanban"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            d = reg.declare_field("alpha", "kanban_dir", config=cfg)
            self.assertIs(d.state, reg.FieldState.DECLARED_ABSENT)
            with self.assertRaises(reg.BoardLessTeamError):
                reg.kanban_dir("alpha", config=cfg)

    def test_per_field_sentinels_really_do_differ(self):
        """Meta-test: prove the specs are not all the same tuple.

        If a refactor collapsed them to one global rule, every S002 test above
        could still pass by coincidence on the fields that share a vocabulary.
        This asserts the distinction exists at all.
        """
        self.assertIn("", reg.spec_for("kanban_dir").absent_sentinels)
        self.assertNotIn("", reg.spec_for("primary_host").absent_sentinels)
        self.assertEqual(reg.spec_for("board_less").absent_sentinels, (None,))
        # XACA-1184: `ai` replaced anthropic_account_id in this meta-test, and
        # it is the sharpest case in the table — three DISTINCT vocabularies
        # have to be visible here or the test is not doing its job.
        self.assertEqual(reg.spec_for("ai").absent_sentinels, (None,))
        self.assertNotIn("null", reg.spec_for("ai").absent_sentinels)
        self.assertIn("null", reg.spec_for("primary_host").absent_sentinels)
        self.assertNotEqual(
            reg.spec_for("ai").absent_sentinels,
            reg.spec_for("primary_host").absent_sentinels,
            "ai must not inherit primary_host's _NULLISH tuple — the string "
            "'null' in a structured block is corruption to warn about, not an "
            "in-band absence to swallow",
        )
        self.assertNotEqual(
            reg.spec_for("ai").absent_sentinels,
            reg.spec_for("kanban_dir").absent_sentinels,
        )

    def test_sentinel_matcher_is_type_strict(self):
        """Meta-test: `==` coercion between bool and int must not fire.

        The sentinel tuples in use today ((None, "", "null") etc.) contain no
        numeric member, so a LOOSE `value in sentinels` would behave
        identically on them — an earlier version of this test passed against a
        deliberately non-strict matcher for exactly that reason, and was
        therefore testing nothing. The cases below are the only ones where
        strict and loose actually diverge: in Python `0 == False` and
        `1 == True`.
        """
        # The divergent cases — loose equality would return True for all four.
        self.assertFalse(reg._matches_sentinel(False, (0,)))
        self.assertFalse(reg._matches_sentinel(0, (False,)))
        self.assertFalse(reg._matches_sentinel(True, (1,)))
        self.assertFalse(reg._matches_sentinel(1, (True,)))
        # Same type, same value -> still a match.
        self.assertTrue(reg._matches_sentinel(False, (False,)))
        self.assertTrue(reg._matches_sentinel(0, (0,)))
        # The vocabularies actually in use behave as documented.
        self.assertFalse(reg._matches_sentinel(0, (None, "")))
        self.assertFalse(reg._matches_sentinel(False, (None, "")))
        self.assertTrue(reg._matches_sentinel(None, (None, "")))
        self.assertTrue(reg._matches_sentinel("", (None, "")))
        self.assertFalse(reg._matches_sentinel("real", (None, "")))


class AbsentSentinelTests(unittest.TestCase):

    def test_absent_is_a_singleton(self):
        self.assertIs(reg._Absent(), reg.ABSENT)

    def test_absent_has_no_truth_value(self):
        """Neither truthy nor falsy — asking is the S002 bug, so it raises."""
        with self.assertRaises(TypeError):
            bool(reg.ABSENT)
        with self.assertRaises(TypeError):
            if reg.ABSENT:  # pragma: no cover - the raise is the point
                pass

    def test_is_absent_helper(self):
        self.assertTrue(reg.is_absent(reg.ABSENT))
        self.assertFalse(reg.is_absent(0))
        self.assertFalse(reg.is_absent(False))
        self.assertFalse(reg.is_absent(""))
        self.assertFalse(reg.is_absent(None))

    def test_repr_is_readable(self):
        self.assertEqual(repr(reg.ABSENT), "ABSENT")


class UnregisteredTeamTests(unittest.TestCase):
    """K659: raise, never derive."""

    def _empty(self):
        return mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {})

    def test_declare_field_raises(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        with self._empty(), self.assertRaises(reg.UnknownTeamError):
            reg.declare_field("ghost", "team_code", config=cfg)

    def test_every_entry_point_raises(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        entry_points = [
            lambda: reg.resolve_field("ghost", "team_code", config=cfg),
            lambda: reg.resolve_team("ghost", config=cfg),
            lambda: reg.team_code("ghost", config=cfg),
            lambda: reg.kanban_dir("ghost", config=cfg),
            lambda: reg.working_dir("ghost", config=cfg),
            lambda: reg.lcars_port("ghost", config=cfg),
            lambda: reg.primary_host("ghost", config=cfg),
            lambda: reg.is_board_less("ghost", config=cfg),
            lambda: reg.alias_of("ghost", config=cfg),
            lambda: reg.license_type("ghost", config=cfg),
            lambda: reg.year_start("ghost", config=cfg),
        ]
        with self._empty():
            for i, call in enumerate(entry_points):
                with self.subTest(entry_point=i):
                    with self.assertRaises(reg.UnknownTeamError):
                        call()

    def test_a_default_supplied_value_is_NOT_a_substitute_for_raising(self):
        """`default=` must not turn an unregistered TEAM into a soft answer."""
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        with self._empty(), self.assertRaises(reg.UnknownTeamError):
            reg.resolve_field("ghost", "team_code", default="XXX", config=cfg)

    def test_unknown_team_error_is_a_keyerror(self):
        """Consumers already wrapping registry lookups in `except KeyError` keep working."""
        self.assertTrue(issubclass(reg.UnknownTeamError, KeyError))
        self.assertTrue(issubclass(reg.BoardLessTeamError, KeyError))

    def test_error_message_names_the_team_and_the_known_set(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        with self._empty():
            with self.assertRaises(reg.UnknownTeamError) as ctx:
                reg.team_code("ghost", config=cfg)
        message = str(ctx.exception)
        self.assertIn("ghost", message)
        self.assertIn("alpha", message)

    def test_is_registered_is_the_non_raising_probe(self):
        cfg = _cfg({"alpha": {"team_code": "ALP"}})
        with self._empty():
            self.assertTrue(reg.is_registered("alpha", config=cfg))
            self.assertFalse(reg.is_registered("ghost", config=cfg))


class OverlayOnlyFieldPreservationTests(unittest.TestCase):
    """Finding F6: five fields exist in the overlay and in NEITHER seed."""

    OVERLAY_ONLY = ("component_label", "copyright_owner", "license_type",
                    "notice_template", "year_start")

    def test_overlay_only_fields_survive_resolution(self):
        cfg = _cfg({"alpha": {
            "kanban_dir": "/tmp/alpha/kanban",
            "component_label": "Alpha Component",
            "copyright_owner": "DoubleNode LLC",
            "license_type": "Apache-2.0",
            "notice_template": "standard",
            "year_start": 2019,
        }})
        defaults = {"alpha": {"kanban_dir": "/tmp/alpha/kanban"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            resolved = reg.resolve_team("alpha", config=cfg)
        for field in self.OVERLAY_ONLY:
            with self.subTest(field=field):
                self.assertIn(field, resolved)
        self.assertEqual(resolved["license_type"], "Apache-2.0")
        self.assertEqual(resolved["year_start"], 2019)

    def test_a_field_in_NO_spec_table_still_survives(self):
        """Schema-open: an unregistered field must not be silently dropped.

        This is the exact hazard that would have destroyed the five licence
        fields had this table been authored before they existed.
        """
        cfg = _cfg({"alpha": {"kanban_dir": "/tmp/a/kanban",
                              "a_field_invented_tomorrow": "keep me"}})
        self.assertNotIn("a_field_invented_tomorrow", reg._FIELD_SPECS)
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            resolved = reg.resolve_team("alpha", config=cfg)
            self.assertEqual(resolved["a_field_invented_tomorrow"], "keep me")
            self.assertEqual(
                reg.resolve_field("alpha", "a_field_invented_tomorrow", config=cfg),
                "keep me",
            )

    def test_resolve_team_omits_undeclared_fields_rather_than_nulling_them(self):
        cfg = _cfg({"alpha": {"kanban_dir": "/tmp/a/kanban", "lcars_port": None}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            resolved = reg.resolve_team("alpha", config=cfg)
        self.assertNotIn("lcars_port", resolved)
        self.assertNotIn("license_type", resolved)
        self.assertIn("kanban_dir", resolved)


class FallThroughSpecTests(unittest.TestCase):
    """The two fields whose declared-absence does NOT stop the chain."""

    def test_team_code_empty_falls_through_to_default_teams(self):
        """Preserves the pre-existing get_team_code() truthiness fallback."""
        cfg = _cfg({"alpha": {"team_code": ""}})
        defaults = {"alpha": {"team_code": "ALP"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            self.assertEqual(reg.team_code("alpha", config=cfg), "ALP")

    def test_alias_of_empty_falls_through_to_default_teams(self):
        """Matches board_less_alias_of()'s un-migrated-overlay fallback."""
        cfg = _cfg({"mainevent": {"alias_of": None, "board_less": True}})
        defaults = {"mainevent": {"alias_of": "command", "board_less": True}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            self.assertEqual(reg.alias_of("mainevent", config=cfg), "command")

    def test_the_two_fall_through_fields_are_exactly_these(self):
        fall_through = sorted(
            n for n, s in reg._FIELD_SPECS.items() if not s.absent_stops_chain
        )
        self.assertEqual(fall_through, ["alias_of", "team_code"])


class BoardLessTests(unittest.TestCase):

    def test_marker_first(self):
        cfg = _cfg({"mainevent": {"board_less": True, "alias_of": "command",
                                  "kanban_dir": "/stale/duplicate/kanban"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            self.assertTrue(reg.is_board_less("mainevent", config=cfg))
            with self.assertRaises(reg.BoardLessTeamError) as ctx:
                reg.kanban_dir("mainevent", config=cfg)
        self.assertIn("command", str(ctx.exception))

    def test_sentinel_fallback_for_unmigrated_overlays(self):
        """A bare null with no marker still resolves as board-less."""
        cfg = _cfg({"mainevent": {"kanban_dir": None}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            self.assertTrue(reg.is_board_less("mainevent", config=cfg))
            with self.assertRaises(reg.BoardLessTeamError):
                reg.working_dir("mainevent", config=cfg)

    def test_normal_team_is_not_board_less(self):
        cfg = _cfg({"alpha": {"kanban_dir": "/tmp/alpha/kanban"}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            self.assertFalse(reg.is_board_less("alpha", config=cfg))
            self.assertEqual(reg.kanban_dir("alpha", config=cfg), Path("/tmp/alpha/kanban"))
            self.assertEqual(reg.working_dir("alpha", config=cfg), Path("/tmp/alpha"))


class ImportPurityTests(unittest.TestCase):

    def test_importing_the_module_performs_no_config_io(self):
        """Import must not read, create, or bootstrap a config file."""
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "never-created.json"
            script = (
                "import os, sys\n"
                f"sys.path.insert(0, {str(_HERE)!r})\n"
                f"os.environ['AITEAMFORGE_CONFIG'] = {str(target)!r}\n"
                "os.environ['AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE'] = '1'\n"
                "import aiteamforge_registry\n"
                f"print('EXISTS' if os.path.exists({str(target)!r}) else 'ABSENT')\n"
            )
            out = subprocess.run([sys.executable, "-c", script],
                                 capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertEqual(out.stdout.strip(), "ABSENT", out.stdout + out.stderr)

    def test_module_exports_what_it_advertises(self):
        for name in reg.__all__:
            with self.subTest(name=name):
                self.assertTrue(hasattr(reg, name), f"__all__ names missing attr {name}")


class LayerDefaultTeamsTests(unittest.TestCase):
    """load_config(include_defaults=True) — team-level union, never a field merge."""

    def test_adds_default_only_teams(self):
        defaults = {"alpha": {"team_code": "ALP"}, "beta": {"team_code": "BET"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            layered = aiteamforge_paths.layer_default_teams({"alpha": {"team_code": "OVR"}})
        self.assertEqual(sorted(layered), ["alpha", "beta"])

    def test_overlay_entry_is_kept_VERBATIM_not_field_merged(self):
        """A field merge here would be a second precedence rule (K501)."""
        defaults = {"alpha": {"team_code": "ALP", "lcars_port": 8203}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            layered = aiteamforge_paths.layer_default_teams({"alpha": {"team_code": "OVR"}})
        self.assertEqual(layered["alpha"], {"team_code": "OVR"})
        self.assertNotIn("lcars_port", layered["alpha"])

    def test_does_not_mutate_its_input(self):
        original = {"alpha": {"team_code": "OVR"}}
        defaults = {"beta": {"team_code": "BET"}}
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults):
            aiteamforge_paths.layer_default_teams(original)
        self.assertEqual(original, {"alpha": {"team_code": "OVR"}})

    def test_load_config_default_arg_is_unchanged_behaviour(self):
        plain = aiteamforge_paths.load_config()
        again = aiteamforge_paths.load_config()
        self.assertIs(plain, again, "default load_config() must still return the cache")

    def test_load_config_include_defaults_does_not_poison_the_cache(self):
        plain_before = aiteamforge_paths.load_config()
        union = aiteamforge_paths.load_config(include_defaults=True)
        plain_after = aiteamforge_paths.load_config()
        self.assertIs(plain_before, plain_after)
        self.assertIsNot(union, plain_after)
        self.assertGreaterEqual(len(union["teams"]), len(plain_after["teams"]))


# ---------------------------------------------------------------------------
# Live-registry tests. Expectations are COMPUTED at runtime, never pinned.
# ---------------------------------------------------------------------------

def _shell_seed_slugs() -> set[str]:
    """Parse the shell positional table by EXECUTING it (the authoritative method)."""
    repo = _HERE.parent
    seed = repo / "homebrew-tap" / "libexec" / "lib" / "aiteamforge-paths.sh"
    if not seed.is_file():
        return set()
    out = subprocess.run(
        ["bash", "-c",
         f"source {seed} >/dev/null 2>&1; _AITEAMFORGE_DEFAULT_TEAMS_DATA"],
        capture_output=True, text=True,
    )
    return {line.split("\t")[0] for line in out.stdout.split("\n") if line.strip()}


class LiveRegistryUnionTests(unittest.TestCase):
    """Every slug in the three-store union resolves to a DOCUMENTED outcome."""

    @classmethod
    def setUpClass(cls):
        cls.python_tiers = set(reg.registered_teams())
        cls.shell_only = _shell_seed_slugs() - cls.python_tiers
        cls.union = cls.python_tiers | _shell_seed_slugs()

    def test_the_shell_seed_was_actually_read(self):
        """Guard: an empty parse would make the next test vacuously green."""
        self.assertGreater(len(_shell_seed_slugs()), 0,
                           "shell seed parsed to zero rows — the check cannot fire")

    def test_every_union_slug_has_a_deterministic_outcome(self):
        """Python-registered slugs resolve; shell-only slugs raise UnknownTeamError.

        No slug may raise anything else, and none may crash. `freelance` and
        `medical` live ONLY in the shell seed, so raising is the CORRECT answer
        for them — the alternatives are parsing the shell table (re-coupling
        the seeds, K830) or deriving an identity (K659).
        """
        resolved, raised = [], []
        for slug in sorted(self.union):
            try:
                fields = reg.resolve_team(slug)
                reg.team_code(slug)
                reg.lcars_port(slug)
                reg.primary_host(slug)
                reg.is_board_less(slug)
                self.assertIsInstance(fields, dict)
                resolved.append(slug)
            except reg.UnknownTeamError:
                raised.append(slug)
            except Exception as exc:  # noqa: BLE001 - any other error is a failure
                self.fail(f"{slug}: unexpected {type(exc).__name__}: {exc}")
        self.assertEqual(sorted(raised), sorted(self.shell_only),
                         "only shell-only slugs may raise UnknownTeamError")
        self.assertEqual(len(resolved) + len(raised), len(self.union))
        print(f"\n    [union] {len(self.union)} slugs: "
              f"{len(resolved)} resolved, {len(raised)} raised "
              f"UnknownTeamError ({', '.join(raised) or 'none'})")

    def test_board_less_teams_raise_only_the_board_less_error(self):
        for slug in sorted(self.python_tiers):
            if reg.is_board_less(slug):
                with self.subTest(slug=slug):
                    with self.assertRaises(reg.BoardLessTeamError):
                        reg.kanban_dir(slug)


class LiveParityWithLegacyAccessorsTests(unittest.TestCase):
    """The resolver must agree with the accessors XACA-1161-003 will replace.

    Parity is asserted only where the legacy accessor has a defined answer.
    Where they DISAGREE by design, the disagreement is asserted explicitly so
    003 inherits a documented expectation rather than a surprise.
    """

    def test_the_registry_is_non_empty(self):
        """Guard: every parity test below loops over registered_teams().

        An empty list makes all four of them vacuously green — a broken
        registry and a perfectly-agreeing one would be indistinguishable.
        """
        self.assertGreater(len(reg.registered_teams()), 0,
                           "registered_teams() is empty — the parity tests cannot fire")

    def test_team_code_parity(self):
        for slug in reg.registered_teams():
            with self.subTest(slug=slug):
                self.assertEqual(reg.team_code(slug),
                                 aiteamforge_paths.get_team_code(slug))

    def test_lcars_port_parity(self):
        for slug in reg.registered_teams():
            with self.subTest(slug=slug):
                self.assertEqual(reg.lcars_port(slug),
                                 aiteamforge_paths.get_team_lcars_port(slug))

    def test_primary_host_parity(self):
        for slug in reg.registered_teams():
            with self.subTest(slug=slug):
                self.assertEqual(reg.primary_host(slug),
                                 aiteamforge_paths.get_team_primary_host(slug))

    def test_kanban_dir_parity_including_the_board_less_raise(self):
        for slug in reg.registered_teams():
            with self.subTest(slug=slug):
                try:
                    legacy = aiteamforge_paths.get_team_kanban_dir(slug)
                except KeyError:
                    legacy = None
                try:
                    new = reg.kanban_dir(slug)
                except KeyError:
                    new = None
                self.assertEqual(new, legacy)


# ---------------------------------------------------------------------------
# XACA-1184 — ai_credential()'s THREE states
# ---------------------------------------------------------------------------

def _captured_stderr():
    """Return a (contextmanager, buffer) pair for asserting on warnings."""
    buf = io.StringIO()
    return contextlib.redirect_stderr(buf), buf


class AiCredentialThreeStateTests(unittest.TestCase):
    """XACA-1184: ``ai_credential()`` resolves THREE answers, never two.

    The whole point of the accessor is that it refuses to collapse
    "nobody decided" into "decided: none". Every test here asserts a state is
    DISTINGUISHABLE from the other two, not merely that it is falsy — an
    assertion phrased as ``assertFalse(...)`` would pass for all three and
    prove nothing (registry S002).
    """

    def _resolve(self, entry, defaults=None):
        cfg = _cfg({"alpha": entry})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", defaults or {}):
            return reg.ai_credential("alpha", config=cfg)

    # -- state 1: undeclared -------------------------------------------------

    def test_no_ai_block_at_all_is_absent(self):
        self.assertIs(self._resolve({"team_code": "ALP"}), reg.ABSENT)

    def test_ai_block_without_a_credential_key_is_absent(self):
        """A block exists (a future `cli` key, say) but records no decision."""
        self.assertIs(self._resolve({"ai": {"cli": "claude"}}), reg.ABSENT)

    def test_explicit_outer_null_ai_is_absent_and_stops_the_chain(self):
        """`ai: null` is the OUTER null — no block. It must NOT inherit the
        seed's block: credentials are per-machine (absent_stops_chain=True)."""
        result = self._resolve(
            {"ai": None},
            defaults={"alpha": {"ai": {"credential": {"account_id": "from-seed"}}}},
        )
        self.assertIs(result, reg.ABSENT)

    # -- state 2: declared "no team credential" ------------------------------

    def test_inner_null_credential_is_none_not_absent(self):
        """`ai.credential: null` is a RECORDED DECISION, not a gap.

        This is the assertion the whole _KEYONLY sentinel choice exists to
        make possible: if `ai`'s tuple had copied primary_host's _NULLISH, the
        resolver would still return the block here (the inner null is not the
        one being matched) — but the pair of tests below is what proves the
        two nulls stay one level apart and mean opposite things.
        """
        result = self._resolve({"ai": {"credential": None}})
        self.assertIsNone(result)
        self.assertIsNot(result, reg.ABSENT)

    def test_the_two_nulls_are_one_level_apart_and_resolve_differently(self):
        """The single most important distinction in this accessor."""
        outer = self._resolve({"ai": None})
        inner = self._resolve({"ai": {"credential": None}})
        self.assertIs(outer, reg.ABSENT)
        self.assertIsNone(inner)
        self.assertIsNot(outer, inner)

    def test_a_declared_none_does_not_fall_through_to_the_seed(self):
        """An operator who recorded "no team credential" must not silently get
        the baked seed's account instead."""
        result = self._resolve(
            {"ai": {"credential": None}},
            defaults={"alpha": {"ai": {"credential": {"account_id": "from-seed"}}}},
        )
        self.assertIsNone(result)

    # -- state 3: a routed account ------------------------------------------

    def test_dict_credential_returns_the_recorded_keys(self):
        credential = {
            "engine_slug": "anthropic",
            "account_slug": "max-me2",
            "account_id": "acct-1",
            "nickname": "ME (Max)",
            "env_var_name": "TEAM_ALPHA_API_KEY",
            "auth_type": "oauth_token",
        }
        result = self._resolve({"ai": {"credential": credential}})
        self.assertEqual(result, credential)

    def test_the_returned_dict_is_a_copy_the_caller_cannot_poison(self):
        """load_config() caches, so a live reference would let one caller
        rewrite the credential for every later reader in the process."""
        cfg = _cfg({"alpha": {"ai": {"credential": {"account_id": "acct-1"}}}})
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            first = reg.ai_credential("alpha", config=cfg)
            first["account_id"] = "MUTATED"
            second = reg.ai_credential("alpha", config=cfg)
        self.assertEqual(second["account_id"], "acct-1")
        self.assertEqual(cfg["teams"]["alpha"]["ai"]["credential"]["account_id"], "acct-1")

    def test_an_empty_dict_credential_is_a_dict_not_absence(self):
        """`{}` is a (degenerate) routed record, not a non-declaration. It must
        stay tellable apart from both other states."""
        result = self._resolve({"ai": {"credential": {}}})
        self.assertEqual(result, {})
        self.assertIsNotNone(result)
        self.assertIsNot(result, reg.ABSENT)

    # -- corruption: warns, reads as ABSENT, never raises --------------------

    def test_non_dict_ai_block_warns_and_reads_as_absent(self):
        for bogus in ("", "null", "some-string", 42, [], ["a"], 0, False, True):
            with self.subTest(ai=repr(bogus)):
                redirect, buf = _captured_stderr()
                with redirect:
                    result = self._resolve({"ai": bogus})
                if bogus is None:
                    continue
                self.assertIs(result, reg.ABSENT)
                self.assertIn("not a dict", buf.getvalue(),
                              f"a {type(bogus).__name__} 'ai' block must WARN, "
                              "not self-heal without a trace (XACA-1178-024)")

    def test_non_dict_non_null_credential_warns_and_reads_as_absent(self):
        for bogus in ("", "null", "acct-1", 42, [], ["a"], 0, False, True):
            with self.subTest(credential=repr(bogus)):
                redirect, buf = _captured_stderr()
                with redirect:
                    result = self._resolve({"ai": {"credential": bogus}})
                self.assertIs(result, reg.ABSENT)
                self.assertIn("not a dict or null", buf.getvalue())

    def test_corrupt_input_never_raises(self):
        """13 call sites would get an opaque TypeError from a JSON typo."""
        for entry in ({"ai": "x"}, {"ai": 1}, {"ai": []},
                      {"ai": {"credential": "x"}}, {"ai": {"credential": []}},
                      {"ai": {"credential": 0}}):
            with self.subTest(entry=repr(entry)):
                redirect, _buf = _captured_stderr()
                with redirect:
                    try:
                        self._resolve(entry)
                    except Exception as exc:  # noqa: BLE001 — that is the point
                        self.fail(f"ai_credential raised {exc!r} on {entry!r}")

    def test_an_unknown_team_still_raises(self):
        """Corruption resolves to ABSENT; an unregistered team is a real error
        and must NOT be flattened into the same answer."""
        with mock.patch.object(aiteamforge_paths, "DEFAULT_TEAMS", {}):
            with self.assertRaises(reg.UnknownTeamError):
                reg.ai_credential("no-such-team", config=_cfg({"alpha": {}}))

    # -- the sentinel itself -------------------------------------------------

    def test_absent_is_not_usable_as_a_boolean(self):
        """`if ai_credential(t):` must be a hard error, not a silent false —
        it is the exact shape that flattens the three states into two."""
        with self.assertRaises(TypeError):
            bool(self._resolve({"team_code": "ALP"}))

    def test_is_absent_helper_agrees_with_identity(self):
        self.assertTrue(reg.is_absent(self._resolve({"team_code": "ALP"})))
        self.assertFalse(reg.is_absent(self._resolve({"ai": {"credential": None}})))
        self.assertFalse(reg.is_absent(self._resolve({"ai": {"credential": {"a": 1}}})))

    # -- no legacy fallback --------------------------------------------------

    def test_the_legacy_trio_is_NOT_read_as_a_fallback(self):
        """XACA-1184: reading the trio here would make the one-time on-disk
        lift unobservable — every team would answer correctly whether or not
        the migration ever ran, and the retirement would silently never
        complete. The lift is aiteamforge_paths', not this module's."""
        result = self._resolve({
            "anthropic_account_id": "acct-legacy",
            "anthropic_account_nickname": "Legacy Nick",
            "anthropic_api_key_env_var": "TEAM_ALPHA_API_KEY",
        })
        self.assertIs(result, reg.ABSENT)

    def test_the_legacy_trio_does_not_leak_into_a_lifted_credential(self):
        """Belt and braces: even beside a real `ai.credential`, the trio must
        contribute nothing — the returned dict is the block's, verbatim."""
        result = self._resolve({
            "anthropic_account_id": "acct-legacy",
            "anthropic_api_key_env_var": "STALE_VAR",
            "ai": {"credential": {"account_id": "acct-current"}},
        })
        self.assertEqual(result, {"account_id": "acct-current"})


class RetiredLegacyAccessorTests(unittest.TestCase):
    """XACA-1184: the trio is gone from the registry's PUBLIC surface.

    Asserted as a test rather than as a grep somebody ran once — a
    reintroduced accessor is exactly the regression this ticket is retiring,
    and a one-off grep cannot notice it coming back.
    """

    RETIRED = (
        "anthropic_account_id",
        "anthropic_account_nickname",
        "anthropic_api_key_env_var",
    )

    def test_no_retired_accessor_functions_remain(self):
        for name in self.RETIRED:
            with self.subTest(name=name):
                self.assertFalse(
                    hasattr(reg, name),
                    f"aiteamforge_registry.{name}() was retired by XACA-1184; "
                    "readers use ai_credential()",
                )

    def test_no_retired_field_specs_remain(self):
        registered = reg.field_names()
        for name in self.RETIRED:
            with self.subTest(name=name):
                self.assertNotIn(name, registered)

    def test_the_ai_field_replaced_them_in_the_spec_table(self):
        """Negative control: proves the assertions above are not vacuously
        green because the spec table itself failed to load."""
        self.assertIn("ai", reg.field_names())
        self.assertGreater(len(reg.field_names()), 10)

    def test_ai_credential_is_exported(self):
        self.assertIn("ai_credential", reg.__all__)
        for name in self.RETIRED:
            with self.subTest(name=name):
                self.assertNotIn(name, reg.__all__)


if __name__ == "__main__":
    unittest.main(verbosity=2)
