#!/usr/bin/env python3
"""Tests for the XACA-1161-003 read-time convergence migration.

Every test here runs against a SANDBOXED overlay under a ``TemporaryDirectory``
with ``$AITEAMFORGE_CONFIG`` pointed at it. The live ``~/.aiteamforge/
team-paths.json`` is never a test target — corrupting it has taken the fleet
down before (XACA-0457), and it is host-dependent besides, so anything asserted
about its contents would be an assertion about one machine.

The migration's five contractual properties each get a test, and each test is
written so it can FAIL:

  * strictly additive        — an overlay-only field survives byte-for-byte, and
                               an existing key is never rewritten even when it
                               disagrees with DEFAULT_TEAMS;
  * idempotent               — proved by HASHING the file after two passes, with
                               an accompanying assertion that the first pass
                               actually changed it (otherwise "byte-identical"
                               is vacuously true of a migration that never ran);
  * backup-first             — the backup exists, is readable, equals the
                               pre-migration bytes, and carries the ticket id
                               plus a real timestamp in its NAME (mtime is not
                               trusted for provenance — see K-note in
                               ``_converge_seed_fields_on_disk``);
  * atomic rename            — a simulated ``os.replace`` failure leaves the
                               original intact and no ``.tmp.`` debris;
  * no canonical-and-wrong "repair" — the ``command``-shaped case is left alone.
"""

import copy
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import aiteamforge_paths as ap  # noqa: E402
import aiteamforge_registry as reg  # noqa: E402


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _pick_seed_team():
    """Return (slug, seed_entry) for a DEFAULT_TEAMS team with >= 4 real fields.

    Chosen at RUNTIME from the seed rather than hardcoded. DEFAULT_TEAMS is
    edited by other subitems of this same ticket (006 reconciles seed
    divergences), and a hardcoded slug would turn their edit into a spurious
    failure here. Never pins a count either — the registry is host- and
    time-dependent (a team was provisioned into the live overlay mid-session,
    26 -> 27).
    """
    for slug, entry in sorted(ap.DEFAULT_TEAMS.items()):
        real = [f for f, v in entry.items() if reg.is_declared_value(f, v)]
        if len(real) >= 4:
            return slug, entry
    raise AssertionError("DEFAULT_TEAMS has no team with >= 4 declared fields")


class _SandboxedOverlayTest(unittest.TestCase):
    """Base: a temp overlay at $AITEAMFORGE_CONFIG, caches reset around each test."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="xaca1161-003-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.config_path = Path(self.tmp) / "team-paths.json"

        self._orig_env = os.environ.get("AITEAMFORGE_CONFIG")
        os.environ["AITEAMFORGE_CONFIG"] = str(self.config_path)
        self.addCleanup(self._restore_env)

        self._reset_module_state()
        self.addCleanup(self._reset_module_state)

    def _restore_env(self):
        if self._orig_env is None:
            os.environ.pop("AITEAMFORGE_CONFIG", None)
        else:
            os.environ["AITEAMFORGE_CONFIG"] = self._orig_env

    @staticmethod
    def _reset_module_state():
        ap._CONFIG_CACHE = None
        ap._CONFIG_PATH_AT_LOAD = None
        ap._A1_BACKFILL_ATTEMPTED = False
        ap._CONTRACT_SCRUB_ATTEMPTED = False
        ap._BOARD_LESS_BACKFILL_ATTEMPTED = False
        ap._PRIMARY_HOST_BACKFILL_ATTEMPTED = False
        ap._SEED_CONVERGENCE_ATTEMPTED = False

    def write_overlay(self, teams, schema_version=3):
        payload = {"schema_version": schema_version, "teams": teams}
        self.config_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        # The write-side plausibility floor (XACA-1059) refuses anything under
        # _MIN_PLAUSIBLE_REGISTRY_BYTES. A fixture below it would make every
        # write test fail for a reason unrelated to what it is testing.
        self.assertGreaterEqual(
            len(self.config_path.read_bytes()), ap._MIN_PLAUSIBLE_REGISTRY_BYTES,
            "fixture is below the write-side plausibility floor; enlarge it",
        )
        return payload

    def read_overlay(self):
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def backups(self):
        return sorted(self.config_path.parent.glob(f"{self.config_path.name}.bak-pre-*"))

    def tmp_debris(self):
        return sorted(self.config_path.parent.glob(f"{self.config_path.name}.tmp.*"))


# ---------------------------------------------------------------------------
# The positive case — the migration must actually do something
# ---------------------------------------------------------------------------

class SeedConvergenceDoesWorkTests(_SandboxedOverlayTest):
    """Guard against a vacuously-green suite: prove the pass materializes fields."""

    def test_missing_seed_fields_are_materialized(self):
        slug, seed = _pick_seed_team()
        # An overlay entry carrying ONLY team_code — every other seed field is
        # absent and therefore a convergence candidate.
        stripped = {"team_code": seed.get("team_code", "TST")}
        self.write_overlay({slug: stripped, "filler-team": {"team_code": "FIL",
                                                            "kanban_dir": "/tmp/filler",
                                                            "working_dir": "/tmp"}})

        pending = ap.diff_unconverged_seed_fields(self.read_overlay())
        pending_map = dict(pending)
        self.assertIn(slug, pending_map, f"nothing pending for {slug} — test is vacuous")
        self.assertGreater(len(pending_map[slug]), 0)

        result = ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        self.assertIsNotNone(result, "migration reported skip-fast on an unconverged overlay")

        on_disk = self.read_overlay()["teams"][slug]
        for field in pending_map[slug]:
            with self.subTest(field=field):
                self.assertIn(field, on_disk, f"{field} was not materialized")
                self.assertEqual(on_disk[field], seed[field])

    def test_skip_fast_when_already_converged_writes_nothing(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: copy.deepcopy(seed),
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        before = _sha256(self.config_path)

        self.assertEqual(ap.diff_unconverged_seed_fields(self.read_overlay()), [])
        self.assertIsNone(
            ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay()),
            "skip-fast must return None when there is nothing to converge",
        )
        self.assertEqual(before, _sha256(self.config_path))
        self.assertEqual(self.backups(), [], "skip-fast must not write a backup")


# ---------------------------------------------------------------------------
# Strictly additive
# ---------------------------------------------------------------------------

class StrictlyAdditiveTests(_SandboxedOverlayTest):

    def test_overlay_only_fields_survive_byte_for_byte(self):
        """The five F6 licence fields exist in NEITHER seed — a reseed destroys them."""
        slug, seed = _pick_seed_team()
        overlay_only = {
            "component_label": "Bespoke Component",
            "copyright_owner": "Someone Specific",
            "license_type": "Proprietary",
            "notice_template": "notice-v9",
            "year_start": 2019,
            # A field no spec knows about at all — the registry is schema-open.
            "totally_unknown_future_field": {"nested": [1, 2, 3]},
        }
        entry = {"team_code": seed.get("team_code", "TST")}
        entry.update(overlay_only)
        self.write_overlay({slug: entry, "filler-team": {"team_code": "FIL",
                                                         "kanban_dir": "/tmp/filler",
                                                         "working_dir": "/tmp"}})

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        after = self.read_overlay()["teams"][slug]
        for field, value in overlay_only.items():
            with self.subTest(field=field):
                self.assertIn(field, after, f"{field} was REMOVED by the migration")
                self.assertEqual(after[field], value, f"{field} was REWRITTEN")

    def test_existing_key_is_never_overwritten_even_when_it_disagrees(self):
        """The `command` shape: overlay is the canonical side AND the stale side.

        MEASURED on the authoring host 2026-09-10, the live overlay's `command`
        entry carries kanban_dir/working_dir pointing at a pytest fixture under
        $TMPDIR while DEFAULT_TEAMS carries the real path. That divergence is
        XACA-0939's to repair; this migration must neither fix it nor destroy
        it. Reproduced here as a sandboxed fixture rather than asserted against
        the live file, which is host-dependent.
        """
        slug, seed = _pick_seed_team()
        disagreeing = {
            f: "/var/folders/zz/T/aiteamforge-test.XXXXXX/fake/%s" % f
            for f in ("kanban_dir", "working_dir")
            if f in seed
        }
        self.assertTrue(disagreeing, "picked seed team has no path fields — test is vacuous")
        for f, v in disagreeing.items():
            self.assertNotEqual(v, seed[f], "fixture must actually disagree with the seed")

        entry = {"team_code": seed.get("team_code", "TST")}
        entry.update(disagreeing)
        self.write_overlay({slug: entry, "filler-team": {"team_code": "FIL",
                                                         "kanban_dir": "/tmp/filler",
                                                         "working_dir": "/tmp"}})

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        after = self.read_overlay()["teams"][slug]
        for f, v in disagreeing.items():
            with self.subTest(field=f):
                self.assertEqual(
                    after[f], v,
                    f"{f} was 'repaired' toward DEFAULT_TEAMS — the migration must "
                    f"never prescribe a direction on a canonical-and-wrong value (K962)",
                )

    def test_empty_string_counts_as_present_and_is_not_replaced(self):
        """Key presence, not truthiness: a declared '' must survive."""
        slug, seed = _pick_seed_team()
        field = next((f for f, v in seed.items() if reg.is_declared_value(f, v)
                      and isinstance(v, str) and v), None)
        self.assertIsNotNone(field, "no non-empty string seed field to test with")
        entry = {field: ""}
        self.write_overlay({slug: entry, "filler-team": {"team_code": "FIL",
                                                         "kanban_dir": "/tmp/filler",
                                                         "working_dir": "/tmp"}})

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        self.assertEqual(self.read_overlay()["teams"][slug][field], "")

    def test_roster_is_not_grown(self):
        """A DEFAULT_TEAMS-only team is NOT added to the overlay.

        The fixture deliberately includes ONE unconverged seed team so the
        transform actually RUNS. With a fixture that needs no work the driver
        skip-fasts before the transform, and a roster-growing implementation
        would sail through this test green — verified by mutation M5, which
        went undetected until this fixture was corrected.
        """
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp",
                                            "lcars_port": 9999,
                                            "lcars_port_base": 9999,
                                            "lcars_port_range": 1}})
        before = set(self.read_overlay()["teams"])
        seed_only = set(ap.DEFAULT_TEAMS) - before
        self.assertTrue(seed_only,
                        "every DEFAULT_TEAMS team is already in the fixture — "
                        "this test cannot observe roster growth")

        result = ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        self.assertIsNotNone(result, "the transform never ran — test is vacuous")

        self.assertEqual(set(self.read_overlay()["teams"]), before,
                         "the migration grew the overlay roster")
        self.assertEqual(set(result["teams"]), before,
                         "the migration grew the roster in the returned config")

    def test_unknown_overlay_team_is_untouched(self):
        """A team the seed does not know is neither removed nor modified."""
        entry = {"team_code": "ZZZ", "kanban_dir": "/tmp/zzz", "working_dir": "/tmp",
                 "some_custom_field": True}
        self.write_overlay({"a-team-the-seed-never-heard-of": entry,
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        self.assertEqual(self.read_overlay()["teams"]["a-team-the-seed-never-heard-of"], entry)

    def test_declared_absence_in_the_seed_is_not_propagated(self):
        """A seed sentinel ('null'/None/'') must not be written into the overlay.

        Writing it would convert NOT_DECLARED into DECLARED_ABSENT and stop the
        shell's own fallback chain one tier early (S002).
        """
        slug = "sentinel-fixture-team"
        fake_seed = {slug: {"team_code": "SFX", "kanban_dir": None,
                            "working_dir": "", "lcars_port": "null",
                            "lcars_port_base": 9100}}
        self.write_overlay({slug: {"team_code": "SFX"},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        with mock.patch.object(ap, "DEFAULT_TEAMS", fake_seed):
            pending = dict(ap.diff_unconverged_seed_fields(self.read_overlay()))
            self.assertEqual(pending.get(slug), ["lcars_port_base"],
                             "sentinel-valued seed fields must not be proposed")
            ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        after = self.read_overlay()["teams"][slug]
        self.assertEqual(after, {"team_code": "SFX", "lcars_port_base": 9100})
        for absent_field in ("kanban_dir", "working_dir", "lcars_port"):
            self.assertNotIn(absent_field, after)


# ---------------------------------------------------------------------------
# Idempotence — proved by hash, not by argument
# ---------------------------------------------------------------------------

class IdempotenceTests(_SandboxedOverlayTest):

    def test_second_pass_produces_a_byte_identical_file(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})

        hash_before = _sha256(self.config_path)
        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        hash_pass1 = _sha256(self.config_path)

        # Non-vacuity: if pass 1 changed nothing, "byte-identical after pass 2"
        # would be trivially true of a migration that never runs at all.
        self.assertNotEqual(hash_before, hash_pass1,
                            "pass 1 wrote nothing — the idempotence check would be vacuous")

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        hash_pass2 = _sha256(self.config_path)

        self.assertEqual(hash_pass1, hash_pass2,
                         f"second pass changed the file: {hash_pass1} -> {hash_pass2}")

    def test_transform_is_idempotent_as_a_pure_function(self):
        slug, seed = _pick_seed_team()
        cfg = {"schema_version": 3,
               "teams": {slug: {"team_code": seed.get("team_code", "TST")}}}
        once = ap.apply_seed_convergence(cfg)
        twice = ap.apply_seed_convergence(once)
        self.assertNotEqual(json.dumps(cfg, indent=2), json.dumps(once, indent=2),
                            "transform was a no-op — idempotence check is vacuous")
        self.assertEqual(json.dumps(once, indent=2), json.dumps(twice, indent=2))

    def test_transform_never_mutates_its_input(self):
        slug, seed = _pick_seed_team()
        cfg = {"schema_version": 3,
               "teams": {slug: {"team_code": seed.get("team_code", "TST")}}}
        snapshot = json.dumps(cfg, sort_keys=True)
        ap.apply_seed_convergence(cfg)
        self.assertEqual(json.dumps(cfg, sort_keys=True), snapshot)

    def test_second_pass_is_skip_fast_and_writes_no_second_backup(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())
        self.assertEqual(len(self.backups()), 1)
        self.assertIsNone(ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay()))
        self.assertEqual(len(self.backups()), 1, "a converged overlay must not re-backup")


# ---------------------------------------------------------------------------
# Backup-first
# ---------------------------------------------------------------------------

class BackupTests(_SandboxedOverlayTest):

    def test_backup_is_created_readable_and_equals_the_premigration_bytes(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        original_bytes = self.config_path.read_bytes()

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        found = self.backups()
        self.assertEqual(len(found), 1, f"expected exactly one backup, got {found}")
        backup = found[0]
        self.assertEqual(backup.read_bytes(), original_bytes,
                         "backup does not match the pre-migration file")
        json.loads(backup.read_text(encoding="utf-8"))  # readable as JSON

    def test_backup_name_carries_the_ticket_id_and_a_real_timestamp(self):
        """Provenance must live in the NAME, not the mtime.

        copy2 / cp -p preserve the SOURCE mtime, which INVERTS write attribution
        during forensics. The driver uses write_bytes (fresh inode, fresh
        mtime), and the filename carries the ticket id plus a wall-clock stamp
        so the backup is attributable regardless of what any mtime says.
        """
        import re
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        name = self.backups()[0].name
        self.assertIn("xaca-1161-converge", name,
                      f"backup name lacks the ticket id: {name}")
        self.assertRegex(name, r"\.bak-pre-xaca-1161-converge-\d{8}-\d{6}$",
                         f"backup name lacks a YYYYmmdd-HHMMSS stamp: {name}")

    def test_backup_mtime_is_its_own_not_the_sources(self):
        """Direct check that write_bytes (not copy2) is what created the backup."""
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        # Back-date the source by a day. copy2 would carry this onto the backup.
        old = 1_600_000_000.0
        os.utime(self.config_path, (old, old))

        ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        backup_mtime = self.backups()[0].stat().st_mtime
        self.assertGreater(
            backup_mtime, old + 86400,
            "backup inherited the SOURCE mtime — attribution is inverted "
            "(copy2/cp -p semantics); it must be created with a fresh mtime",
        )


# ---------------------------------------------------------------------------
# Atomic rename
# ---------------------------------------------------------------------------

class AtomicWriteTests(_SandboxedOverlayTest):

    def test_simulated_replace_failure_leaves_no_partial_file(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        original_bytes = self.config_path.read_bytes()

        with mock.patch.object(ap.os, "replace",
                               side_effect=OSError("simulated crash mid-rename")):
            result = ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        # The driver never raises: it degrades to an in-memory transform.
        self.assertIsNotNone(result)
        self.assertEqual(self.config_path.read_bytes(), original_bytes,
                         "the on-disk config was damaged by a failed rename")
        self.assertEqual(self.tmp_debris(), [],
                         "a .tmp.<pid> file was left behind after a failed rename")
        # The in-memory result still carries the converged shape, so the calling
        # process is not left with a stale view just because disk was unwritable.
        self.assertIn("teams", result)

    def test_the_write_goes_through_os_replace_not_truncate_in_place(self):
        """Assert the mechanism, not just the outcome.

        An implementation that opened the target with 'w' and wrote in place
        would satisfy every content assertion above while being exactly the
        crash-unsafe shape XACA-1029 was filed for.
        """
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        real_replace = ap.os.replace
        calls = []

        def _spy(src, dst):
            calls.append((str(src), str(dst)))
            return real_replace(src, dst)

        with mock.patch.object(ap.os, "replace", side_effect=_spy):
            ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay())

        target = str(self.config_path.resolve())
        matching = [c for c in calls if c[1] == target]
        self.assertTrue(matching, f"os.replace was never called onto {target}: {calls}")
        src = matching[0][0]
        self.assertTrue(src.startswith(target + ".tmp."),
                        f"tmp file was not a sibling of the target: {src}")
        # Compare RESOLVED parents: on macOS the temp dir is reachable as both
        # /var/... and /private/var/..., and the driver resolves the target
        # before deriving the tmp name. Comparing one resolved path against one
        # unresolved path fails on a symlink hop, not on the property under test.
        self.assertEqual(str(Path(src).parent.resolve()),
                         str(self.config_path.parent.resolve()),
                         "tmp file must live in the target's own directory "
                         "(os.replace is only atomic within one filesystem)")


# ---------------------------------------------------------------------------
# End to end, through load_config()
# ---------------------------------------------------------------------------

class LoadConfigIntegrationTests(_SandboxedOverlayTest):

    def test_load_config_converges_and_a_second_load_is_byte_identical(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp",
                                            "anthropic_account_id": "",
                                            "anthropic_account_nickname": "",
                                            "anthropic_api_key_env_var": "X"}})
        before = _sha256(self.config_path)

        cfg = ap.load_config()
        after_first = _sha256(self.config_path)
        self.assertNotEqual(before, after_first,
                            "load_config() converged nothing — check is vacuous")
        self.assertIn(slug, cfg["teams"])

        # Reset caches AND the once-per-process flags so the second load really
        # re-runs every pass rather than short-circuiting on the flags.
        self._reset_module_state()
        ap.load_config()
        self.assertEqual(after_first, _sha256(self.config_path),
                         "a second full load_config() was not byte-identical")

    def test_the_migration_runs_at_most_one_write_per_process(self):
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        with mock.patch.object(ap, "_converge_seed_fields_on_disk",
                               wraps=ap._converge_seed_fields_on_disk) as spy:
            ap.load_config()
            ap._CONFIG_CACHE = None
            ap._CONFIG_PATH_AT_LOAD = None
            ap.load_config()
        self.assertEqual(spy.call_count, 1,
                         "the once-per-process guard did not hold")

    def test_import_of_the_registry_failing_skips_the_migration_safely(self):
        """Fail CLOSED: no resolver -> no migration, and the overlay is untouched."""
        slug, seed = _pick_seed_team()
        self.write_overlay({slug: {"team_code": seed.get("team_code", "TST")},
                            "filler-team": {"team_code": "FIL",
                                            "kanban_dir": "/tmp/filler",
                                            "working_dir": "/tmp"}})
        before = _sha256(self.config_path)
        with mock.patch.object(ap, "_registry_field_rule", return_value=None):
            self.assertEqual(ap.diff_unconverged_seed_fields(self.read_overlay()), [])
            self.assertIsNone(
                ap._converge_seed_fields_on_disk(self.config_path, self.read_overlay()))
        self.assertEqual(before, _sha256(self.config_path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
