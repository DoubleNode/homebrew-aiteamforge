#!/usr/bin/env python3
"""
kb-team-registry-loss-check.py

Detection-only check for TEAM-ID LOSS in ~/.aiteamforge/team-paths.json.
Written for XACA-1029-006 — a human-visible alarm for the destructive
`load_config()` self-heal bug documented in XACA-1029 (a separate fix,
owned by a parallel agent, is repairing the library itself; this script
only detects and reports).

── WHY SET DIFFERENCE, NOT COUNT (XACA-1029 R10) ────────────────────────────
A team-COUNT regression alarm is UNSOUND. `DEFAULT_TEAMS` in
kanban-hooks/aiteamforge_paths.py has exactly 15 entries and ZERO
freelance-* teams. The reproduced incident took the registry from 12 teams
(10 of them overlay-only) to 15 teams (0 overlay-only) — the COUNT WENT UP
by 3 while 100% of the overlay-only data was permanently destroyed. A count
alarm is silent on precisely the machines most at risk: any overlay holding
fewer than 15 teams, which is the normal shape of a fresh consumer install.

This script alarms on the team-id SET instead:

    lost = previous_ids - current_ids
    if lost: ALARM — name every lost id individually.

Any non-empty `lost` is an alarm regardless of what happened to the total
count. "10 teams lost" is reported as the 10 actual ids, never a bare count.

── WHAT THIS SCRIPT NEVER DOES ──────────────────────────────────────────────
  - It NEVER writes team-paths.json, nor any team-paths.json.bak-* file.
  - It NEVER attempts to repair, reseed, or restore the registry. Detection
    and reporting only — a human decides what to do next.
  - It does NOT hook into aiteamforge_paths.py's load/write path. Per
    XACA-1029 R16 (and consistent with the XACA-0804 principle "a read must
    never write the registry as a side effect"), this alarm keeps its OWN
    snapshot of the team-id set in a sidecar file it owns, entirely outside
    the library and the registry file itself. That sidecar lives beside
    whatever registry this script is pointed at — never inside it.

── DEDUPE (XACA-1029 R13) ───────────────────────────────────────────────────
The underlying defect fires repeatedly and CONCURRENTLY — the incident
showed three independent self-heal firings within 4 seconds (multiple
processes each independently hitting the corrupt branch). A guard that
alarms once per invocation would spam a warning per process. This script
tracks the last-reported condition (kind + signature + timestamp) in a
second sidecar file and only re-emits when the condition is NEW (the lost
set changed) or a cooldown has elapsed since the last time it was reported
(so an unresolved loss still gets a periodic reminder, rather than going
silent forever after the first hit). The whole read-decide-write sequence
is wrapped in a flock'd critical section so concurrent invocations don't
race each other into printing duplicate alarms for the identical event.

── EXIT CODES (meaningful for direct/CI use, mirrors
   scripts/kb-lcars-port-drift-check.sh) ─────────────────────────────────────
  0 = nothing to report right now: first run (bootstrap, nothing to compare
      against yet), no loss detected, or an already-reported condition still
      within its dedupe cooldown.
  1 = FRESH alarm: one or more team ids present in the last known-good
      snapshot are absent from the current registry. Printed report names
      every lost id.
  2 = fail-closed: the registry could not be read or parsed (missing file,
      invalid JSON, or missing/malformed "teams" object), or jq-equivalent
      structural validation failed. The team-id set is UNKNOWN in this case
      — no loss claim is made, but the condition is reported (and deduped
      the same way as a loss alarm).

── ENV OVERRIDES (sandbox / test use) ───────────────────────────────────────
  AITEAMFORGE_CONFIG
      Full path to the registry file to check. This is the SAME override
      kanban-hooks/aiteamforge_paths.py honors (get_config_path()).
      AITEAMFORGE_DIR is NOT a registry override for that library and is
      NOT honored here either — passing it silently does nothing, exactly
      as it does for the library (XACA-1029 R7). Use AITEAMFORGE_CONFIG.
  KB_TEAM_REGISTRY_GUARD_COOLDOWN_SECONDS
      Override the re-alarm cooldown (default 3600 = 1 hour). Tests use a
      small value (or 0) to assert re-firing behaviour without sleeping.

The two sidecar files this script owns live in the SAME DIRECTORY as the
resolved registry path (so pointing AITEAMFORGE_CONFIG at a sandbox fixture
naturally sandboxes the sidecars too — no separate override needed):
  team-registry-last-known-ids.snapshot.json
  team-registry-loss-alarm.state.json
  team-registry-loss-guard.lock            (flock target only, no content)
"""

import contextlib
import json
import os
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # pragma: no cover - POSIX-only tool, defensive only
    fcntl = None

SNAPSHOT_BASENAME = "team-registry-last-known-ids.snapshot.json"
ALARM_BASENAME = "team-registry-loss-alarm.state.json"
LOCK_BASENAME = "team-registry-loss-guard.lock"

DEFAULT_COOLDOWN_SECONDS = 3600.0


def _registry_path():
    # AITEAMFORGE_CONFIG is the ONLY sandbox override the underlying library
    # honors (get_config_path() in kanban-hooks/aiteamforge_paths.py).
    # AITEAMFORGE_DIR is a different, unrelated override for other tooling
    # and is silently ignored by the library's config path resolution — do
    # not special-case it here either, or a test/sandbox setup that only
    # sets AITEAMFORGE_DIR would silently point this guard at the LIVE
    # registry while believing it was sandboxed (XACA-1029 R7).
    override = os.environ.get("AITEAMFORGE_CONFIG")
    if override:
        return override
    return os.path.expanduser("~/.aiteamforge/team-paths.json")


def _cooldown_seconds():
    raw = os.environ.get("KB_TEAM_REGISTRY_GUARD_COOLDOWN_SECONDS")
    if raw is None or raw == "":
        return DEFAULT_COOLDOWN_SECONDS
    try:
        return float(raw)
    except ValueError:
        return DEFAULT_COOLDOWN_SECONDS


def _atomic_write_json(path, obj):
    """Write JSON atomically: tmp file in the SAME directory, fsync, then
    os.replace(). Conforms to the atomic-write pattern already established
    in this repo (kanban-hooks/aiteamforge_paths.py:_atomic_write_json) —
    this is an independent implementation (this script must not import from
    or edit that file, per the XACA-1029-006 file-ownership boundary), but
    matches the same shape deliberately rather than inventing a new one.
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".kb-team-registry-guard-", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def _read_json_or_none(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, ValueError):
        # A corrupt sidecar is OUR bug, not the registry's — treat it as
        # absent (bootstrap fresh) rather than crashing the guard.
        return None


@contextlib.contextmanager
def _locked_critical_section(lock_path):
    """Serialize the read-decide-write sequence across concurrent
    invocations (XACA-1029 R13: the real-world defect fires from several
    concurrent processes within seconds of each other). Best-effort: if
    fcntl is unavailable, proceeds unlocked rather than failing the guard.
    """
    if fcntl is None:
        yield
        return
    directory = os.path.dirname(lock_path) or "."
    os.makedirs(directory, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


def _read_current_ids(registry_path):
    """Returns (sorted_ids, error_message). Exactly one is None."""
    if not os.path.isfile(registry_path):
        return None, "registry file does not exist: {}".format(registry_path)

    try:
        with open(registry_path, "r") as f:
            raw = f.read()
    except OSError as exc:
        return None, "registry file could not be read: {} ({})".format(registry_path, exc)

    try:
        config = json.loads(raw)
    except ValueError as exc:
        return None, "registry is not valid JSON: {} ({})".format(registry_path, exc)

    if not isinstance(config, dict):
        return None, "registry top level is not a JSON object: {}".format(registry_path)

    teams = config.get("teams")
    if not isinstance(teams, dict):
        return None, "registry has no 'teams' object: {}".format(registry_path)

    return sorted(str(k) for k in teams), None


def _should_alarm(alarm_state, kind, signature, cooldown_seconds):
    if alarm_state is None:
        return True
    if alarm_state.get("kind") != kind:
        return True
    if alarm_state.get("signature") != signature:
        return True
    alarmed_at = alarm_state.get("alarmed_at")
    if not isinstance(alarmed_at, (int, float)):
        return True
    return (time.time() - alarmed_at) >= cooldown_seconds


def _record_alarm(alarm_path, kind, signature):
    _atomic_write_json(
        alarm_path,
        {"kind": kind, "signature": signature, "alarmed_at": time.time()},
    )


def _clear_alarm(alarm_path):
    try:
        os.remove(alarm_path)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def main(argv):
    del argv  # no CLI flags yet — env-var driven like its sibling checks

    registry_path = _registry_path()
    state_dir = os.path.dirname(registry_path) or "."
    snapshot_path = os.path.join(state_dir, SNAPSHOT_BASENAME)
    alarm_path = os.path.join(state_dir, ALARM_BASENAME)
    lock_path = os.path.join(state_dir, LOCK_BASENAME)
    cooldown_seconds = _cooldown_seconds()

    with _locked_critical_section(lock_path):
        current_ids, err = _read_current_ids(registry_path)

        if err is not None:
            # B1-shaped condition (per XACA-1029 R1): the bytes are
            # unusable, so the current team-id set is UNKNOWN. We do NOT
            # touch the snapshot (keep the last known-good baseline intact
            # for whenever a successful read resumes), and we do NOT claim
            # any specific ids are lost — that would be inventing data we
            # don't have.
            alarm_state = _read_json_or_none(alarm_path)
            if _should_alarm(alarm_state, kind="unreadable", signature=err, cooldown_seconds=cooldown_seconds):
                print("TEAM REGISTRY UNREADABLE — cannot verify team-id set")
                print("Registry: {}".format(registry_path))
                print("Reason:   {}".format(err))
                print(
                    "This does NOT mean teams were lost — it means this guard "
                    "cannot currently tell. The last known-good team-id "
                    "snapshot has been left untouched."
                )
                _record_alarm(alarm_path, kind="unreadable", signature=err)
                return 2
            return 0

        baseline = _read_json_or_none(snapshot_path)
        baseline_ids = None
        if isinstance(baseline, dict):
            ids = baseline.get("ids")
            if isinstance(ids, list):
                baseline_ids = [str(i) for i in ids]

        if baseline_ids is None:
            # First run (or a corrupt/missing sidecar) — nothing to compare
            # against yet. Bootstrap silently; this is not itself an alarm.
            _atomic_write_json(snapshot_path, {"ids": current_ids, "recorded_at": time.time()})
            _clear_alarm(alarm_path)
            return 0

        lost = sorted(set(baseline_ids) - set(current_ids))

        if not lost:
            # No loss (includes normal growth — new ids present that
            # weren't before). Recovery also lands here: if a prior loss
            # has been resolved, this clears the alarm memory too, so the
            # NEXT loss (even an identical one) is treated as fresh.
            _atomic_write_json(snapshot_path, {"ids": current_ids, "recorded_at": time.time()})
            _clear_alarm(alarm_path)
            return 0

        # Loss detected. Deliberately do NOT update the snapshot here — the
        # old baseline is kept so the loss keeps being visible (via the
        # cooldown re-reminder) for as long as it remains unresolved,
        # rather than the wiped state quietly becoming the new "normal".
        signature = ",".join(lost)
        alarm_state = _read_json_or_none(alarm_path)
        if _should_alarm(alarm_state, kind="loss", signature=signature, cooldown_seconds=cooldown_seconds):
            print("TEAM REGISTRY LOSS DETECTED")
            print("Registry: {}".format(registry_path))
            print("Lost team id(s) ({}): {}".format(len(lost), ", ".join(lost)))
            print(
                "Current team id(s) ({}): {}".format(
                    len(current_ids), ", ".join(current_ids)
                )
            )
            _record_alarm(alarm_path, kind="loss", signature=signature)
            return 1

        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
