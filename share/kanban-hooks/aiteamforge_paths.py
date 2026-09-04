#!/usr/bin/env python3
"""
aiteamforge_paths.py — Canonical team path config loader.

XACA-0168-001 — Wave 1: Config schema + loader module

Design
------
This module is the single source of truth for team → kanban/working directory
mappings.  Previously these lived as hardcoded dicts in 31+ Python and shell
files (TEAM_KANBAN_DIRS in kanban_utils.py, server.py, etc.) and case
statements in kanban-helpers.sh.  This module replaces all of them by loading
from ~/.aiteamforge/team-paths.json (or the path in $AITEAMFORGE_CONFIG).

Config file schema (schema_version 1):
    {
      "schema_version": 1,
      "teams": {
        "<team-id>": {
          "kanban_dir": "/abs/path/to/kanban",
          "working_dir": "/abs/path/to/working",   # parent of kanban_dir
          "lcars_port": 8203                         # optional, int
        },
        ...
      }
    }

XACA-0658: Versioned release-push flow — optional per-team keys (schema_version 2+)
----------------------------------------------------------------------------
The following keys are OPTIONAL and backward-compatible.  Teams that omit them
continue to work exactly as before.  Do NOT bump schema_version when adding
these keys — they are additive extensions.

Key: version_sources (list)
    A list of per-platform version-source entries.  Each entry describes how to
    locate, read, and write the authoritative version string for a given platform.

    [
      {
        "platform":      "ios",                                # required
        "file":          "MainEventApp.xcodeproj/project.pbxproj",  # required, relative to working_dir
        "match_pattern": "MARKETING_VERSION = {version};",    # required; {version} is a placeholder
        "write_pattern": "MARKETING_VERSION = {version};",    # required; {version} replaced with target
        "encoding":      "utf-8",                             # optional, default "utf-8"
        "replace_all":   true                                 # optional, default false
      },
      ...
    ]

    match_pattern / write_pattern: {version} is expanded to a semver capture-
    group regex ([0-9]+\\.[0-9]+(?:\\.[0-9]+)?) for reading, or to the literal
    target version string for writing.

    replace_all: When true (e.g. pbxproj has multiple MARKETING_VERSION lines),
    replace ALL matches.  When false (default), replace first match only.

    If version_sources is absent for a team, the version gate is skipped with a
    stderr warning, preserving backward compatibility.

Key: relnotes_sources (list)
    A list of per-platform relnotes-directory entries.  Each entry specifies
    which directory holds RELNOTES-<ENV>.md files for a given platform.

    [
      {
        "platform": "ios",      # required
        "dir":      "."         # required, relative to working_dir
      },
      ...
    ]

    If relnotes_sources is absent, the RELNOTES promotion step defaults to
    working_dir for each platform.

Key: branch_env_map (object)
    Maps exact branch names to environment stage strings OR per-platform
    environment maps.  Two forms are accepted:

    String form (all-platforms shorthand):
        {
          "develop": "DEV",
          "release/qa": "QA"
        }
    The string value means "promote ALL platforms on the active release to
    this environment."  At read time the normalizer expands it to
    {platform: env} for every platform in the release.

    Object form (per-platform precise):
        {
          "develop": {"ios": "DEV", "android": "DEV"},
          "release/qa": {"ios": "QA", "android": "QA", "firebase": "QA"}
        }
    Each value is an object mapping platform → environment.

    Branch names are matched exactly (no glob support in v1).

    If branch_env_map is absent, branch-push auto-promotion is disabled for
    that team.

    normalize_branch_env(branch_map_value, release_platforms) normalizes either
    form to {platform: env} given the release's platform list.
----------------------------------------------------------------------------

Bootstrap behaviour (when config is missing or corrupt):
    - MISSING (no file at all) → auto-write is opt-in only, via
      $AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE=1 (XACA-0804). Non-interactive
      callers (hooks, subagents, CI, the LCARS server) are overwhelmingly
      read-only, so a read must never write the registry as a side effect.
      Without the opt-in, the missing path silently falls back to
      DEFAULT_TEAMS in-memory — no write, no stderr noise. Interactive TTY
      sessions still get a human-readable "run init" hint.
    - CORRUPT — XACA-1029 CHOSEN SEMANTICS (this replaces the pre-XACA-1029
      "always overwrite in place, unconditionally" behaviour, which twice
      wiped every overlay-only team, most notably the 10 freelance-<client>-
      <project> teams that exist ONLY in the per-machine overlay since
      XACA-0628). load_config() distinguishes TWO structurally different
      corrupt branches, because they carry different information:

        B1 — hard parse failure (json.loads()/read raises). The bytes are
             unusable; NO team set is knowable from them.
        B2 — structural-validity failure (JSON parsed fine, but
             config_is_structurally_valid() rejects it — e.g. no
             schema_version, or an empty/academy-alone "teams" dict). The
             parsed team set IS in hand.

      Both branches apply, in order:
        (a) Retry with bounded backoff. A single failed parse/validate is
            not proof of corruption — it may be a concurrent writer caught
            between the unlink-old and materialize-new steps of an atomic
            replace, or (empirically, XACA-1029) a 0-byte/short read from a
            NON-atomic writer. Retry per `_CORRUPT_READ_RETRY_BACKOFF_SECONDS`
            (a 3-step schedule, ~0.85s worst case — REVIEW ROUND 2 widened
            this from a single 0.1s retry after an independent action-sweep
            proof measured a hard cliff above ~120ms, and R13 established
            real concurrent self-heal bursts on this machine). A success on
            ANY attempt in the schedule means an earlier read was transient —
            proceed normally with the fresh data, no heal.
        (b) Quarantine, never overwrite in place — UNLESS the source has
            nothing worth quarantining (see the B1 suspect carve-out below).
            On confirmed corruption (every attempt in the schedule failed),
            the suspect file is MOVED (os.replace — never copied) to a
            uniquely-named quarantine path (`<name>.bak-<tag>-<timestamp>-
            <pid>-<seq>`) before anything is written to config_path. A move
            cannot race a concurrent reader/writer the way a read-then-copy
            can, so the quarantine file is guaranteed to hold EXACTLY what
            was on disk — the original bytes always survive under the
            quarantine name, never deleted, never truncated in place. The
            pid+sequence-number suffix prevents two self-heals — whether
            concurrent PROCESSES (R13: three within 4 seconds observed) or,
            as important, two quarantine calls from the SAME process within
            one wall-clock second (a real collision hit writing this
            module's own test suite) — from overwriting each other's
            quarantine file.
        (c) Refuse to reseed when it would REMOVE teams — B2 ONLY. B1 has no
            team set to compare against (nothing to refuse with — R1), so on
            B1 the self-heal proceeds to a DEFAULT_TEAMS reseed after
            (a)+(b) — UNLESS the B1 suspect carve-out below applies. On B2,
            before reseeding, load_config() computes
            `lost = teams_keys - set(DEFAULT_TEAMS)` (a SET difference —
            R10: team COUNT is the wrong signal, since a reseed can INCREASE
            the total count while destroying every overlay-only team). If
            `lost` is non-empty, load_config() REFUSES to write: the
            quarantine step still runs, but DEFAULT_TEAMS is never written
            to config_path. The in-memory parsed config is returned AS-IS
            for this process (so a live process does not additionally lose
            in-memory access to data it already had), a CRITICAL line
            naming every lost team id is printed to stderr, and the four
            on-disk self-heal backfill passes below are skipped for this
            call (they would otherwise quietly re-materialize a fresh file
            at config_path, defeating "leave it quarantined for a human to
            inspect"). A human must restore or repair the file manually;
            nothing here writes DEFAULT_TEAMS over recoverable data.
        (d) A quarantine/backup file must never SILENTLY read as empty. Two
            enforcement layers:
              - Since (b) is a rename rather than a read+copy, a quarantine
                file's size is definitionally whatever was really on disk —
                our OWN quarantine step cannot itself truncate it further.
                If that size is below `_MIN_PLAUSIBLE_REGISTRY_BYTES`, the
                quarantine filename is tagged `SUSPECT` and a stderr line
                explains why — loud, not silent.
              - B1 SUSPECT CARVE-OUT (REVIEW ROUND 2, the direct fix for a
                gap the round-1 implementation left open): on B1, after the
                full retry schedule in (a) is exhausted, if the file is ALSO
                implausibly short (`_file_looks_implausibly_short` — 0 bytes
                is the exact signature of the incident this ticket exists to
                fix: 12 zero-byte `.bak-*` files across three separate
                days), load_config() does NOT quarantine it and does NOT
                reseed config_path at all. A 0-byte quarantine copy has zero
                forensic value — it is noise, not evidence — and silently
                replacing a visibly-broken (0-byte, unreadable) registry
                with a schema-valid 15-team DEFAULT_TEAMS file is exactly
                backwards: it hides the loss instead of surfacing it. The
                file is left completely untouched at config_path (still
                loudly broken for the next human or tool that looks at it),
                a CRITICAL line is printed, and the CALLER still receives
                DEFAULT_TEAMS in memory only, so the process keeps working.
                With nothing written to config_path, the NEXT load_config()
                call (this process or a fresh one) takes the MISSING branch
                per XACA-0804 above, which is itself already opt-in-write-
                only. This carve-out applies ONLY when the source is BOTH
                confirmed-corrupt AND implausibly short — a plausibly-sized
                B1 file that is still genuinely unparseable after the full
                retry schedule keeps the round-1 behaviour (quarantine +
                unconditional reseed): there, "recovery is manual, from the
                quarantine file" genuinely holds, because the quarantine
                file actually contains something.

      Deliberately NOT implemented here (see XACA-1029 orchestrator notes
      R16): a "last-known-good" sidecar written on every successful read.
      That would add a write to the READ path, which XACA-0804 already
      established must not happen — and it would not help B1 anyway (B1
      has no in-memory prior state to fall back on within a single call).
      A separate, out-of-process alarm (XACA-1029-006) owns comparing
      against a prior snapshot; this module only ever protects against
      writing DESTRUCTIVE content, it does not attempt to resurrect
      already-lost bytes. This is also why the B1 suspect carve-out above
      cannot "recover" the pre-corruption team set even though it refuses to
      reseed — refusing prevents further, self-inflicted damage; it does
      not undo damage that already happened to the bytes before this
      module ever read them.

Module-level side effects
    NONE.  All I/O happens on first function call, not at import time.
    The config is cached in _CONFIG_CACHE after the first load.

Usage
-----
    from aiteamforge_paths import get_team_kanban_dir, list_teams
    kanban = get_team_kanban_dir("academy")  # -> Path
    teams  = list_teams()                    # -> ["academy", "android", ...]

Consumers still importing TEAM_KANBAN_DIRS directly from kanban_utils should
migrate to this module (Wave 3, XACA-0168-006 onwards).  For now both exist.
"""

from __future__ import annotations

import fcntl
import itertools
import json
import os
import stat
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Config path
# ---------------------------------------------------------------------------

def get_config_path() -> Path:
    """Return the path to team-paths.json, honouring $AITEAMFORGE_CONFIG."""
    override = os.environ.get("AITEAMFORGE_CONFIG", "")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".aiteamforge" / "team-paths.json"


# ---------------------------------------------------------------------------
# Baked-in defaults — the migration baseline.
#
# These MUST match the hardcoded values in:
#   - kanban-hooks/kanban_utils.py  TEAM_KANBAN_DIRS
#   - lcars-ui/server.py            TEAM_KANBAN_DIRS
#   - kanban-helpers.sh             _kb_get_kanban_dir() case statement
#   - kanban-helpers.sh             TEAM_PORTS associative array (lcars_port)
#   - lcars-health-check.sh         LCARS_SERVERS array
#
# If you add a team here, also update the shell DEFAULT_TEAMS heredoc in
# homebrew-tap/libexec/lib/aiteamforge-paths.sh (kept in sync by hand until
# Wave 4 automation lands).
#
# kanban_dir       — absolute path to the live board directory
# working_dir      — parent of kanban_dir (= kanban_dir.parent)
# lcars_port_base  — first port in the template's band (XACA-0463)
# lcars_port_range — inclusive count of ports in band (XACA-0463)
# lcars_port       — DEPRECATED (XACA-0463): per-instance port, derived from
#                    band base at install time and persisted to team-paths.json;
#                    use lcars_port_base + lcars_port_range for band queries.
#                    None means not yet allocated (pre-migration install).
# primary_host     — OPTIONAL (XACA-0802): the ONE fleet host on which this
#                    team's knowledge is authored. Compared case-insensitively
#                    (and with a trailing ".local" stripped) against BOTH
#                    `scutil --get ComputerName` and `hostname -s`, so a single
#                    slug matches either form. ABSENT means "no declared host"
#                    — deliberately not the empty string, because the shell
#                    guard (_kb_knowledge_host_affinity_guard in
#                    kanban-helpers.sh) fails OPEN on absence and an empty
#                    string would be indistinguishable from a host named "".
#                    Populated ONLY for the three PII teams today; the registry
#                    lists every team the fleet knows about, so team membership
#                    alone has never implied ownership — this field is what
#                    makes ownership expressible (XACA-0779 stranded a legal
#                    and a medical entry on M3Pro precisely because it wasn't).
# ---------------------------------------------------------------------------

_HOME = str(Path.home())

DEFAULT_TEAMS: dict[str, dict[str, Any]] = {
    # ── Main Event Teams ──────────────────────────────────────────────────
    "academy": {
        "team_code": "ACA",
        "kanban_dir": f"{_HOME}/dev-team/kanban",
        "working_dir": f"{_HOME}/dev-team",
        "lcars_port_base": 8200,
        "lcars_port_range": 10,
        "lcars_port": 8203,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_ACADEMY_API_KEY",
    },
    "ios": {
        "team_code": "IOS",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS",
        "lcars_port_base": 8260,
        "lcars_port_range": 10,
        "lcars_port": 8260,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_IOS_API_KEY",
    },
    "android": {
        "team_code": "AND",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android",
        "lcars_port_base": 8280,
        "lcars_port_range": 10,
        "lcars_port": 8280,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_ANDROID_API_KEY",
    },
    "firebase": {
        "team_code": "FIR",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions",
        "lcars_port_base": 8240,
        "lcars_port_range": 10,
        "lcars_port": 8240,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FIREBASE_API_KEY",
    },
    "command": {
        "team_code": "CMD",
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port_base": 8230,
        "lcars_port_range": 10,
        "lcars_port": 8234,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_COMMAND_API_KEY",
    },
    "dns": {
        "team_code": "DNS",
        "kanban_dir": "/Users/Shared/Development/DNSFramework/kanban",
        "working_dir": "/Users/Shared/Development/DNSFramework",
        "lcars_port_base": 8180,
        "lcars_port_range": 10,
        "lcars_port": 8180,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_DNS_API_KEY",
    },

    # ── Freelance — per-client/project entries (overlay-only, XACA-0628) ──
    # The 9 per-CLIENT/PROJECT freelance slugs (DoubleNode/Liquidstyle/Bandwear)
    # were removed from DEFAULT_TEAMS in XACA-0628 and now live solely in the
    # per-machine overlay (~/.aiteamforge/team-paths.json). build_team_code_map()
    # MERGES overlay team_codes on top of these defaults, so the overlay entries
    # (FSW/FAP/FWS/FLB/VAN/FAS/FLA/FLI/BWA/BWD) supply routing on machines that
    # actually host those client repos. XACA-0643 removed the bare `freelance`
    # (FRE) alias that used to sit here — it is a parameterized template, so a
    # bare key violates the team-id contract (the server dropped it on every
    # read). freelance therefore has NO seeded instance in DEFAULT_TEAMS; its
    # canonical port band lives in `_TEMPLATE_PORT_BANDS` so port allocation
    # still works for freelance-<client>-<project> installs.

    # ── Legal ─────────────────────────────────────────────────────────────
    "legal-coparenting": {
        "team_code": "LCP",
        "kanban_dir": f"{_HOME}/legal/coparenting/kanban",
        "working_dir": f"{_HOME}/legal/coparenting",
        "lcars_port_base": 8320,
        "lcars_port_range": 10,
        "lcars_port": 8320,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_LEGAL_COPARENTING_API_KEY",
        # XACA-0802: PII team — authored on the M4 Mini, nowhere else.
        "primary_host": "darren-m4-mini",
    },

    # ── Medical ───────────────────────────────────────────────────────────
    "medical-general": {
        "team_code": "MED",
        "kanban_dir": f"{_HOME}/medical/general/kanban",
        "working_dir": f"{_HOME}/medical/general",
        "lcars_port_base": 8340,
        "lcars_port_range": 10,
        "lcars_port": 8340,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MEDICAL_GENERAL_API_KEY",
        # XACA-0802: PII team — authored on the M4 Mini, nowhere else.
        "primary_host": "darren-m4-mini",
    },

    # ── Finance ───────────────────────────────────────────────────────────
    "finance-personal": {
        "team_code": "FIN",
        "kanban_dir": f"{_HOME}/finance/personal/kanban",
        "working_dir": f"{_HOME}/finance/personal",
        "lcars_port_base": 8360,
        "lcars_port_range": 10,
        "lcars_port": 8360,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_FINANCE_PERSONAL_API_KEY",
        # XACA-0802: PII team — authored on the M4 Mini, nowhere else.
        "primary_host": "darren-m4-mini",
    },

    # ── Aliases (backward-compat, mirrors kanban_utils.py) ────────────────
    # NOTE (XACA-0463): mainevent moves from 8234 → 8400 to resolve the existing
    # command/mainevent collision. 8234 is in command's band [8230, 8240);
    # mainevent's authoritative band is [8400, 8401) (XACA-0806 narrowed it from
    # [8400, 8410): a board-less alias binds exactly its one fixed port).
    #
    # XACA-0727: mainevent is now a BOARD-LESS alias — it carries NO kanban_dir /
    # working_dir. 'command' is the operative kanban identity for Main Event
    # cross-platform coordination (it owns command-board.json in
    # /Users/Shared/Development/Main Event/dev-team/kanban); mainevent has no
    # board of its own. Previously mainevent DUPLICATED command's kanban_dir, so
    # any kb-* op resolving team 'mainevent' derived a phantom
    # mainevent-board.json (which never existed) and failed. The entry persists
    # ONLY for its port / identity — LCARS port 8400, team_code MEV — used by the
    # mainevent-<project> crew launcher (mainevent-startup.sh). Board-less means
    # get_team_kanban_dir("mainevent") / get_team_working_dir("mainevent") raise a
    # clear KeyError; team-iterating consumers (server.py _build_team_kanban_dirs,
    # kanban-backup.py, kanban_utils.py) skip it via try/except. The hardcoded
    # server.py fallback already omits mainevent, so dynamic + fallback now agree.
    "mainevent": {
        "team_code": "MEV",
        # board-less alias (XACA-0727): intentionally NO kanban_dir / working_dir.
        # XACA-0794: the ABSENCE of kanban_dir is now stated EXPLICITLY rather than
        # left to be inferred from a bare null. JSON carries no comments, so a human
        # reading ~/.aiteamforge/team-paths.json saw only `"kanban_dir": null` and
        # reasonably concluded "corruption" — this misread the design twice (the
        # XACA-0724 gate spec, and XACA-0794 itself, which was filed to DELETE this
        # entry). These two keys make the intent self-documenting in the data:
        #   board_less: true  → owns no kanban board; this is CORRECT, not corrupt.
        #   alias_of: command → the operative kanban identity to use instead.
        # DO NOT DELETE this entry: it is live infrastructure (LCARS port 8400,
        # team_code MEV, mainevent-startup.sh crew launcher, .claude/agents-master/
        # mainevent/ personas). Board-less means kanban_dir/working_dir stay ABSENT.
        "board_less": True,
        "alias_of": "command",
        "lcars_port_base": 8400,
        # range 1 (XACA-0806): a board-less alias binds exactly ONE port (its
        # fixed lcars_port 8400) and is never dynamically allocated via
        # compute_instance_port, so it needs no multi-port band. It was 10
        # ([8400,8410)) from XACA-0463's move off 8234; that width nominally
        # overlapped the per-project band _TEMPLATE_PORT_BANDS["mainevent"] =
        # (8401,19) → [8401,8419) on 8401-8409, violating the team-id-contract
        # "bands MUST NOT overlap" rule. Narrowing to [8400,8401) removes the
        # overlap; inert in practice (nothing allocated in the old 8401-8409 tail).
        "lcars_port_range": 1,
        "lcars_port": 8400,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_API_KEY",
    },

    # ── MainEvent per-project crew instances (XACA-0806) ──────────────────
    # mainevent-startup.sh <PROJECTID> launches an 8-terminal VOY-themed crew
    # against an arbitrary Main Event project directory; each run's LCARS server
    # is addressed by SESSION_PREFIX = "mainevent-<project-lower>" (see
    # LCARS_TEAM_NAME in mainevent/scripts/mainevent-lcars-startup.sh — it is
    # passed to lcars-ui/server.py as LCARS_TEAM for data isolation, so this
    # registry entry's kanban_dir is what that server instance actually renders).
    # These are DELIBERATELY separate registry keys from "ios"/"android"/
    # "firebase"/"command" even though 4 of the 5 point at the SAME physical
    # kanban_dir as those teams — mainevent-startup.sh is an alternate,
    # cross-platform-themed way to open a session against that same board, not
    # a different board. This mirrors the pre-existing bare "mainevent" →
    # 'command' relationship, just via a plain duplicate entry instead of
    # board_less/alias_of (these instances DO own an addressable kanban_dir,
    # unlike the coordination-only bare alias above).
    #
    # Port band [8401, 8419] per _TEMPLATE_PORT_BANDS["mainevent"] above. Only
    # the 5 project directories verified to exist under
    # "/Users/Shared/Development/Main Event/" at registration time are seeded;
    # mainevent-startup.sh's SHELL fallback (resolve_lcars_port_fallback, now
    # rebased to the same [8401, 8419] band) still covers any future PROJECTID
    # run against this launcher that isn't listed here.
    #
    # No component_label/copyright_owner/license_type/notice_template/year_start
    # keys: lcars-ui/server.py's copyright endpoints read those via `.get()` and
    # tolerate absence (renders as an unfilled placeholder); inventing values for
    # a script-driven registration risked recording incorrect licensing metadata.
    "mainevent-dev-team": {
        # DEFAULT_PROJECT in mainevent-connect.sh. Same working_dir/kanban_dir as
        # team "command" (Main Event's dev-team repo IS command's board).
        "team_code": "MDT",
        "kanban_dir": "/Users/Shared/Development/Main Event/dev-team/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/dev-team",
        "lcars_port_base": 8401,
        "lcars_port_range": 19,
        "lcars_port": 8401,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_DEV_TEAM_API_KEY",
    },
    "mainevent-maineventapp-ios": {
        # Same working_dir/kanban_dir as team "ios".
        "team_code": "MAI",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-iOS",
        "lcars_port_base": 8401,
        "lcars_port_range": 19,
        "lcars_port": 8402,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_MAINEVENTAPP_IOS_API_KEY",
    },
    "mainevent-maineventapp-android": {
        # Same working_dir/kanban_dir as team "android". Project uses a
        # /develop worktree; kanban_dir stays at the project ROOT (matches
        # mainevent-startup.sh's dirname($PROJECT_DIR)/kanban derivation when
        # USE_WORKTREE=true — the develop/kanban subdir holds only gitignored
        # per-worktree knowledge, never the live board).
        "team_code": "MAA",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Android",
        "lcars_port_base": 8401,
        "lcars_port_range": 19,
        "lcars_port": 8403,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_MAINEVENTAPP_ANDROID_API_KEY",
    },
    "mainevent-maineventapp-functions": {
        # Same working_dir/kanban_dir as team "firebase". Also has a /develop
        # worktree; see the android entry's note above re: kanban_dir staying
        # at the project root.
        "team_code": "MAF",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventApp-Functions",
        "lcars_port_base": 8401,
        "lcars_port_range": 19,
        "lcars_port": 8404,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_MAINEVENTAPP_FUNCTIONS_API_KEY",
    },
    "mainevent-maineventwrapper-ios": {
        # No existing "ios"-style team owns this dir — MainEventWrapper-iOS is a
        # standalone legacy repo with no sibling team entry to duplicate. Its
        # project directory exists (verified at registration) but has NEVER had
        # a kanban board initialized (no kanban_dir on disk yet, no /develop
        # worktree) — kb_ensure_team_initialized in mainevent-startup.sh will
        # provision kanban_dir on first run, same as any other net-new team.
        "team_code": "MWI",
        "kanban_dir": "/Users/Shared/Development/Main Event/MainEventWrapper-iOS/kanban",
        "working_dir": "/Users/Shared/Development/Main Event/MainEventWrapper-iOS",
        "lcars_port_base": 8401,
        "lcars_port_range": 19,
        "lcars_port": 8405,
        "anthropic_account_id": "",
        "anthropic_account_nickname": "",
        "anthropic_api_key_env_var": "TEAM_MAINEVENT_MAINEVENTWRAPPER_IOS_API_KEY",
    },

    # XACA-0643: bare "medical" and "freelance" aliases REMOVED. They are
    # parameterized templates (medical needs a project; freelance needs
    # client+project) per the team-id contract, so a bare key is a contract
    # violation — lcars-ui/server.py:_filter_contract_violating_teams() already
    # drops them with a loud warning on every read. Seeding them here just
    # produced the warning noise + invalid team-paths.json keys. The concrete
    # instances ("medical-general", "freelance-<client>-<project>") are the
    # only valid forms. "mainevent" stays above: it is NOT parameterized
    # (single instance), so a bare key is legitimate — though board-less as of
    # XACA-0727 (it owns no kanban_dir; 'command' is the operative board).
}

# ---------------------------------------------------------------------------
# Internal config cache
# ---------------------------------------------------------------------------

_CONFIG_CACHE: dict | None = None
_CONFIG_PATH_AT_LOAD: str | None = None  # detect $AITEAMFORGE_CONFIG changes
_A1_BACKFILL_ATTEMPTED: bool = False  # once-per-process guard (XACA-0522)
_CONTRACT_SCRUB_ATTEMPTED: bool = False  # once-per-process guard (XACA-0643)
_BOARD_LESS_BACKFILL_ATTEMPTED: bool = False  # once-per-process guard (XACA-0794)
_PRIMARY_HOST_BACKFILL_ATTEMPTED: bool = False  # once-per-process guard (XACA-0802)

# XACA-1029 (003/004/005): corrupt-config self-heal safety constants. See the
# "Bootstrap behaviour" section of the module docstring for the full contract.
# Module-level (not inline literals) so tests can monkeypatch the schedule to
# near-zero for speed without changing behaviour.
#
# XACA-1029 REVIEW ROUND 2 (Lura Thok): a single-shot 0.1s retry has a hard
# cliff — measured directly by an independent action-sweep proof: an
# unreadable window of 120ms or less recovers cleanly, but 200ms+ declares
# corrupt and fires the destructive reseed path, EVEN THOUGH R13 already
# established this machine sees concurrent self-heal bursts (three within 4
# seconds) and several non-atomic writers still exist outside this module's
# scope (aiteamforge-paths-init.sh, the shell canonical, two bats helpers).
# A >200ms unreadable window under load is not hypothetical. Widened to a
# bounded backoff schedule — each entry is a delay before the NEXT attempt,
# so exhausting the whole schedule costs ~0.85s (capped near 1s total) and
# the happy path (first read succeeds) pays nothing extra.
_CORRUPT_READ_RETRY_BACKOFF_SECONDS: tuple[float, ...] = (0.1, 0.25, 0.5)
# A real team-paths.json is never this small (the smallest real registry —
# a single minimal team entry — is several hundred bytes; the live baseline
# is 13256 bytes for 25 teams). Below this floor, a read is far more likely
# to be a transient/partial view than genuine content (R2).
_MIN_PLAUSIBLE_REGISTRY_BYTES: int = 200
# Monotonic per-process counter appended to quarantine filenames (R13). PID +
# second-resolution timestamp alone can still collide when the SAME process
# quarantines twice in the same wall-clock second (observed directly while
# writing this module's own test suite) — os.replace() onto an existing
# quarantine name would silently clobber the first one, destroying exactly
# the forensic evidence this contract exists to preserve. A counter makes
# every call from this process unique regardless of clock resolution.
_QUARANTINE_SEQ = itertools.count()

SUPPORTED_SCHEMA_VERSION = 3

# Teams that MUST appear in any valid config.  If any are absent the config is
# considered corrupt and load_config() falls back to _bootstrap().  (XACA-0457)
CANONICAL_REQUIRED_TEAMS: frozenset[str] = frozenset({"academy"})


def teams_satisfy_canonical_guard(teams_keys) -> tuple[frozenset, bool]:
    """Canonical-team structural guard — SINGLE SOURCE OF TRUTH (XACA-0647).

    Returns (missing_required, has_non_required) for a set of team-name keys:
      - missing_required: CANONICAL_REQUIRED_TEAMS absent from the set (academy).
      - has_non_required: True iff at least one team beyond the required set exists.

    NOTE (XACA-0705): The validity rule is NOT "not missing_required and has_non_required"
    anymore — see config_is_structurally_valid() for the authoritative predicate.
    The old academy-required rule wrongly clobbered consumer configs that have zero
    academy team (custom-only installs). The canonical corruption signatures remain:
    no schema_version, OR empty teams, OR academy-alone (has_non_required=False).

    Both load_config() (this module) and lcars-ui/server.py's
    _build_team_kanban_dirs() call config_is_structurally_valid() so the validity
    rule cannot drift across the two sites (ends the k501 two-site sibling drift).
    (XACA-0457 / XACA-0647 / XACA-0705)
    """
    teams_keys = set(teams_keys)
    missing_required = CANONICAL_REQUIRED_TEAMS - teams_keys
    has_non_required = bool(teams_keys - CANONICAL_REQUIRED_TEAMS)
    return frozenset(missing_required), has_non_required


def config_is_structurally_valid(teams_keys, has_schema: bool) -> bool:
    """Return True iff a parsed config is structurally sound — SINGLE SOURCE OF
    TRUTH for the load_config() and server.py _build_team_kanban_dirs() guard.

    Valid iff ALL of:
      1. schema_version key is present (has_schema=True)
      2. at least one NON-academy team exists (has_non_required=True)

    Corruption signatures (→ bootstrap / fallback):
      - missing schema_version
      - empty teams dict  (has_non_required=False)
      - academy-alone     (has_non_required=False — same check as empty)

    XACA-0705: The prior rule required academy to be present (missing_required
    must be empty). That wrongly clobbered consumer installs whose team-paths.json
    has only a custom non-academy team (e.g. a freelance-only box). The fix:
    drop the academy-required constraint from the validity test. Academy absence
    is now only a diagnostic hint, not a corruption signal.

    Truth table:
      {custom-instance-team}         → VALID  (consumer fix)
      {academy}                      → corrupt (academy-alone, no non-required)
      {}                             → corrupt (empty)
      {academy, ios, ...}            → VALID  (normal dev box)
      missing schema_version         → corrupt

    SIBLING-DRIFT NOTE: this function is called in EXACTLY TWO places:
      1. kanban-hooks/aiteamforge_paths.py — load_config()
      2. lcars-ui/server.py — _build_team_kanban_dirs()
    Both sites import this function. If you add a third call site, update this
    comment. Never inline the validity logic at a call site. (XACA-0705 / k501)
    """
    _, has_non_required = teams_satisfy_canonical_guard(teams_keys)
    return has_schema and has_non_required


# Templates that REQUIRE one or more parameters (project, or client+project) per
# the team-id contract (docs/architecture/team-id-contract.md §3). A bare key
# like "freelance" or "medical" in a config's "teams" map is a contract
# violation — valid keys are instance ids ("medical-general",
# "freelance-doublenode-starwords"). This is the SINGLE SOURCE OF TRUTH: both
# lcars-ui/server.py and homebrew-tap/libexec/commands/kb-port-fix.py import this
# frozenset (with a literal fallback) so they cannot drift. (XACA-0643)
_PARAMETERIZED_TEMPLATES: frozenset[str] = frozenset({"finance", "legal", "medical", "freelance"})

# Canonical LCARS port band (base, range) for parameterized templates that have
# NO seeded instance in DEFAULT_TEAMS — so _resolve_template_band()'s direct/
# strip-dash/prefix-scan steps can't find a band. freelance is client+project
# only (XACA-0628 purged the client roster; XACA-0643 removed the bare alias),
# yet kb-port-fix still needs its band to renumber freelance-<client>-<project>
# installs. finance/legal/medical resolve via their seeded *-instance entries and
# intentionally are NOT duplicated here (avoids band drift). (XACA-0643)
#
# "mainevent" (XACA-0806): mainevent-startup.sh accepts an ARBITRARY PROJECTID
# (SESSION_PREFIX = "mainevent-<project-lower>"), so per-project instances can
# never all be pre-seeded in DEFAULT_TEAMS — this band is what lets kb-port-fix
# reason about (and eventually renumber) any mainevent-<project> instance, seeded
# or not. Base is 8401, NOT 8400: 8400 is the bare board-less "mainevent" alias's
# own lcars_port (team_code MEV, alias_of "command" — see that entry above) and
# must stay uncollidable with a per-project instance landing at the band's first
# slot. Range 19 gives [8401, 8419], deliberately clear of freelance's band
# [8500, 8600) — the whole point of this ticket was that mainevent per-project
# instances were landing inside freelance's band via a stale 8510/90 shell
# fallback (see mainevent-startup.sh's resolve_lcars_port_fallback call site).
#
# RESOLVED (XACA-0806 subitem 3): unlike freelance, "mainevent" DOES have a
# bare entry in DEFAULT_TEAMS (board-less alias, lcars_port_base 8400 /
# lcars_port_range 1 — narrowed from 10 by XACA-0806's review response so the
# alias band [8400, 8401) no longer overlaps this per-project band).
# _resolve_template_band() used to resolve "mainevent-<anything>" to that bare
# entry's OWN (8400, 1) band via its strip-dash tolerant-lookup step, BEFORE
# this dict was ever consulted — so an UNREGISTERED mainevent-<project> run
# through compute_instance_port() would allocate from the bare alias's
# [8400, 8401) band instead of [8401, 8419] and collide with the alias's own
# port 8400. Fixed by reordering _resolve_template_band() so an explicit
# _TEMPLATE_PORT_BANDS declaration is checked BEFORE the strip-dash heuristic
# (see that function's ORDERING RATIONALE docstring).
#
# RESIDUAL CAVEAT (flagged for follow-up, NOT fixable from a dev-team-only
# change): kb-port-fix.py (homebrew-tap/libexec/commands/ — tap-only, no
# dev-team mirror) computes the template for an existing team-paths.json
# instance id via its OWN `_split_template(iid)` helper (first dash-component
# only) BEFORE calling compute_instance_port(), e.g.
# `compute_instance_port(_split_template("mainevent-someproject"), ...)` ==
# `compute_instance_port("mainevent", ...)`. That pre-strip throws away the
# child suffix this fix relies on — _resolve_template_band("mainevent") alone
# still (correctly, for a literal bare-alias query) returns (8400, 1) at step
# 1's direct match. So kb-port-fix.py's RENUMBERING path (used when an
# existing mainevent-<project> entry collides or has a null port) would still
# misallocate into the bare alias's [8400, 8401) band. The fix belongs in
# kb-port-fix.py itself: pass the FULL iid to compute_instance_port(iid, ...)
# instead of the pre-split base, letting this function's own tolerant
# resolution (steps 1-4 below) disambiguate correctly. Requires a tap-side
# commit; out of reach from this worktree (tap submodule uninitialized here,
# and homebrew-tap/ in the main repo is read-only reference-only per policy).
# The mainevent-startup.sh SHELL fallback (a separate, cksum-based mechanism —
# see resolve_lcars_port_fallback in scripts/lcars-launch-helpers.sh) does NOT
# go through this function at all and is unaffected either way.
_TEMPLATE_PORT_BANDS: dict[str, tuple[int, int]] = {
    "freelance": (8500, 100),
    "mainevent": (8401, 19),
}


# ---------------------------------------------------------------------------
# Board-less alias support (XACA-0727 / XACA-0794)
# ---------------------------------------------------------------------------
#
# A board-less team owns NO kanban board but retains its other identities (LCARS
# port, team_code, crew launcher, personas). "mainevent" is the canonical case:
# 'command' is the operative kanban identity for Main Event coordination.
#
# Absence of kanban_dir/working_dir is representable four ways across the two
# canonical registry seeds (K661 — dual-canonical registry):
#   - key absent            → Python DEFAULT_TEAMS
#   - JSON null             → overlay seeded by the shell heredoc's "null" column
#   - the string "null"     → shell heredoc sentinel, read verbatim
#   - empty string          → defensive
# _ABSENT_SENTINELS normalizes all four so the two seeds cannot drift in meaning.
#
# XACA-0794 adds the EXPLICIT marker (board_less/alias_of). Resolvers check the
# marker FIRST and fall back to sentinel-normalization, so un-migrated overlays
# (which carry a bare null and no marker) keep working unchanged.
_ABSENT_SENTINELS: tuple = (None, "", "null")


def team_is_board_less(entry: dict) -> bool:
    """Return True iff a team entry declares itself board-less (XACA-0794).

    Checks ONLY the explicit marker. Callers that must also honour legacy
    un-migrated overlays combine this with an _ABSENT_SENTINELS check on the
    specific field they need — see get_team_kanban_dir/get_team_working_dir.
    Pure predicate — never mutates, never raises.
    """
    return entry.get("board_less") is True


def board_less_alias_of(team: str, entry: dict) -> str | None:
    """Return the team a board-less alias defers to (e.g. "command"), or None.

    Prefers the entry's explicit alias_of marker; falls back to DEFAULT_TEAMS so
    the guidance still resolves on un-migrated overlays that predate XACA-0794.
    """
    alias = entry.get("alias_of")
    if alias in _ABSENT_SENTINELS:
        alias = DEFAULT_TEAMS.get(team, {}).get("alias_of")
    return alias if alias not in _ABSENT_SENTINELS else None


def _board_less_error(team: str, entry: dict, field: str) -> KeyError:
    """Build the KeyError raised when a board-less alias is asked for a path."""
    alias = board_less_alias_of(team, entry)
    guidance = (
        f"Use '{alias}' instead." if alias
        else "It owns no kanban board of its own."
    )
    return KeyError(
        f"Team '{team}' is a board-less alias (no {field}) — this is intentional, "
        f"NOT corruption. {guidance} See XACA-0727 / XACA-0794."
    )


def _make_default_config() -> dict:
    """Build a config dict from DEFAULT_TEAMS, ready to write as JSON."""
    return {
        "schema_version": SUPPORTED_SCHEMA_VERSION,
        "teams": DEFAULT_TEAMS,
    }


def _write_defaults(config_path: Path) -> None:
    """Write DEFAULT_TEAMS to config_path (non-interactive bootstrap).

    XACA-1029-003/-005: if something still exists at config_path (e.g. this
    is invoked directly rather than via load_config()'s corrupt-quarantine
    step, which already moves the suspect file aside before calling here),
    quarantine it first via the shared helper — MOVE, not read+copy, so the
    forensic trail can never be a truncated/0-byte artifact of a read race
    (see module docstring). When load_config() already quarantined the file,
    config_path.exists() is False here and this is a no-op — no double
    quarantine, no double backup. The actual write goes through
    _atomic_write_json (tmp file + os.replace + fsync) rather than a bare
    write_text (XACA-1029-003).

    XACA-1059 (PR #817 review round): the write-side plausibility floor is
    checked via _reject_if_below_write_floor BEFORE the quarantine step
    above, not just inside _atomic_write_json after it. Quarantine MOVES
    whatever currently exists at config_path aside; if the floor check ran
    only inside _atomic_write_json, a refusal there would arrive AFTER the
    existing registry was already moved out from under config_path, leaving
    it ABSENT (contents only in the quarantine backup) rather than untouched
    — exactly backwards from the fail-closed property this floor exists to
    provide. Checking first means a refused write never reaches the
    quarantine step at all. (In practice this payload is the constant-size
    DEFAULT_TEAMS dict, always well above the floor, so this is currently
    unreachable — but the ordering bug was real and this closes it
    regardless of payload size.) ``except (OSError, ValueError)`` below is a
    second, independent line of defense: even if some future change reorders
    this function, a floor refusal can never again escape as an uncaught
    exception.
    """
    try:
        payload = _make_default_config()
        _reject_if_below_write_floor(payload, resolved=config_path)
        config_path.parent.mkdir(parents=True, exist_ok=True)
        _quarantine_or_snapshot_existing(
            config_path, tag="pre-write-defaults", label="_write_defaults"
        )
        _atomic_write_json(config_path, payload)
    except (OSError, ValueError) as exc:
        print(
            f"[aiteamforge-paths] WARNING: could not write default config to "
            f"{config_path}: {exc}",
            file=sys.stderr,
        )


def _interactive_tty() -> bool:
    """Return True if stdin is a real terminal (interactive session)."""
    try:
        return os.isatty(sys.stdin.fileno())
    except Exception:
        return False


def _bootstrap_write_allowed() -> bool:
    """Return True iff the caller explicitly opted in to a MISSING-config write.

    XACA-0804: a MISSING config used to auto-write on every non-interactive
    read (hooks, subagents, CI, and the LCARS server are overwhelmingly
    non-interactive AND read-only) — a read must never mutate the registry as
    a side effect. The write is now opt-in only, gated on this single env var.
    It is also the shared contract with the shell canonical
    (homebrew-tap/libexec/lib/aiteamforge-paths.sh): the shell side shells out
    to python3 for the actual JSON write, and an env var is what survives that
    handoff (a function argument would not). Exact-string "1" only — any other
    value or unset means no write.
    """
    return os.environ.get("AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE") == "1"


def _bootstrap(config_path: Path, corrupt: bool = False) -> dict:
    """Handle missing/corrupt config.  Returns a usable config dict.

    XACA-0804: MISSING and CORRUPT are gated differently for the disk-write
    decision — see the "Bootstrap behaviour" section of the module docstring.
    `corrupt=True` means config_path existed on disk but failed to parse or
    failed the structural-integrity check (load_config() tracks this); it
    always self-heals, unaffected by AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE.
    `corrupt=False` (the default) means no file existed at all, and the write
    is opt-in only (read-only must not write; opt-in only — XACA-0804).
    """
    if corrupt:
        # CORRUPT: self-heal, NOT gated by the opt-in flag — a broken file is
        # an active defect regardless of who's reading it. XACA-1029: by the
        # time _bootstrap(corrupt=True) is reached, load_config() has already
        # (a) exhausted the retry backoff schedule, (b) quarantined the
        # suspect file (it no longer exists at config_path), and — on B2
        # only — (c) refused this call entirely and returned early if
        # reseeding would remove a known team (see the module docstring's
        # "Bootstrap behaviour" section). REVIEW ROUND 2: a B1 file that is
        # ALSO implausibly short never reaches here at all — that carve-out
        # short-circuits earlier in load_config(), before _bootstrap() is
        # ever called, because there both quarantine AND reseed are refused.
        # Reaching here therefore means either a plausibly-sized B1 (no team
        # set was ever knowable, but the quarantine file holds real bytes) or
        # a B2 reseed that provably loses nothing. The test suites that
        # exercise this path now assert THAT (data-preserving-or-refused)
        # contract, not "unconditional" in the pre-XACA-1029 sense.
        print(
            f"[aiteamforge-paths] Config corrupt at {config_path} — writing defaults (auto-heal)",
            file=sys.stderr,
        )
        _write_defaults(config_path)
        return _make_default_config()

    # MISSING: read-only must not write; opt-in only (XACA-0804).
    if _interactive_tty():
        print(
            f"[aiteamforge-paths] Config not found at {config_path}.\n"
            f"  Run: aiteamforge-paths init\n"
            f"  Falling back to built-in defaults.",
            file=sys.stderr,
        )
    elif _bootstrap_write_allowed():
        print(
            f"[aiteamforge-paths] Config missing — writing defaults to {config_path}",
            file=sys.stderr,
        )
        _write_defaults(config_path)
    # else: non-interactive with no opt-in — silent fallback to DEFAULT_TEAMS,
    # no disk write, no stderr hint (XACA-0804: the non-interactive missing
    # path is overwhelmingly a read-only caller; a read must never write).

    return _make_default_config()


def _available_teams_hint(config: dict) -> str:
    """Return a comma-separated list of team names for error messages."""
    teams = list(config.get("teams", {}).keys())
    # Filter out the non-parameterized alias name to keep the hint shorter.
    # (medical/freelance bare aliases removed in XACA-0643.)
    primary = [t for t in teams if t not in ("mainevent",)]
    return ", ".join(sorted(primary)) or "(none)"


# ---------------------------------------------------------------------------
# XACA-1029 (003/004/005) — corrupt-config self-heal safety machinery.
# See the module docstring's "Bootstrap behaviour" section for the contract
# these implement. Kept together, and factored once, per R3/R12 (this same
# ticket's own investigation): three near-identical read+write_bytes backup
# sites and one bespoke atomic-write reimplementation is exactly the
# sibling-heuristic-drift shape (k501) that produced the original defect.
# ---------------------------------------------------------------------------

def _quarantine_or_snapshot_existing(config_path: Path, *, tag: str, label: str) -> Path | None:
    """MOVE (never copy) whatever currently exists at config_path aside.

    Used both as the "backup snapshot before I overwrite this" step (the
    three sites XACA-1029-003/R3 identified: _write_defaults,
    wizard_hook_create_config, and load_config()'s own corrupt-detection
    branch) and as the "quarantine, don't destroy" step contract part (b)
    requires. Both needs are the same operation: whatever is at config_path
    right now must survive, verbatim, under a new name, before anything else
    touches config_path.

    Why MOVE and not read+write_bytes(): a copy re-reads the source, which
    can land in the middle of some OTHER writer's non-atomic
    open-truncate-write and capture a transiently-empty/partial view — this
    produced the 0-byte ".bak-*" forensic backups from the incident this
    ticket exists to fix (R2/R3). `os.replace()` performs a filesystem
    rename: no read of the source content occurs, so there is no window in
    which our OWN snapshot step can observe (or manufacture) a truncated
    copy. Whatever is really on disk becomes the quarantine file's content,
    byte-for-byte, guaranteed.

    The destination name embeds a timestamp, the pid, AND a per-process
    monotonic sequence number (R13: the real incident showed multiple
    concurrent processes independently hitting the corrupt branch within
    seconds of each other; timestamp+pid alone can STILL collide when the
    SAME process quarantines twice within one wall-clock second — observed
    directly in this module's own test suite — and os.replace() onto an
    existing destination silently clobbers it, the exact forensic-evidence
    loss this contract exists to prevent).

    XACA-0794-009 symlink note: operates on config_path.resolve(), exactly
    like _atomic_write_json. `os.replace()` on a SYMLINK path itself would
    move the link, not its target — leaving the real (corrupt) file
    untouched and un-quarantined while config_path silently goes missing.
    Resolving first means a symlinked config's underlying file is what gets
    quarantined, and the symlink itself is left alone to keep pointing at
    wherever _atomic_write_json subsequently writes the replacement.

    Returns the quarantine path on success, or None if there was nothing to
    quarantine (config_path does not exist) or the move itself failed (rare;
    logged loudly, never raised — callers proceed as if there was nothing to
    snapshot, matching this module's "never raises" contract for callers
    that are themselves best-effort, like _write_defaults).
    """
    if not config_path.exists():
        return None

    resolved = config_path.resolve()

    try:
        size = resolved.stat().st_size
    except OSError:
        size = -1

    suspect = 0 <= size < _MIN_PLAUSIBLE_REGISTRY_BYTES
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    name_tag = f"SUSPECT-{tag}" if suspect else tag
    seq = next(_QUARANTINE_SEQ)
    quarantine_path = resolved.with_name(
        f"{resolved.name}.bak-{name_tag}-{timestamp}-{os.getpid()}-{seq}"
    )

    try:
        os.replace(str(resolved), str(quarantine_path))
    except OSError as exc:
        print(
            f"[aiteamforge-paths] {label}: WARNING: failed to quarantine "
            f"{resolved} to {quarantine_path}: {exc} — proceeding without "
            f"a snapshot",
            file=sys.stderr,
        )
        return None

    if suspect:
        print(
            f"[aiteamforge-paths] {label}: quarantined {config_path} -> "
            f"{quarantine_path} (SUSPECT: only {size} bytes — below the "
            f"{_MIN_PLAUSIBLE_REGISTRY_BYTES}-byte plausibility floor for a "
            f"real registry; likely itself a transient/partial read that the "
            f"retry in (a) did not happen to resolve, per XACA-1029 part d)",
            file=sys.stderr,
        )
    else:
        print(
            f"[aiteamforge-paths] {label}: quarantined {config_path} -> {quarantine_path}",
            file=sys.stderr,
        )
    return quarantine_path


def _file_looks_implausibly_short(config_path: Path) -> bool:
    """R2/review-round-2: cheap size-only discriminator, checked AFTER every
    retry attempt is exhausted. A file below `_MIN_PLAUSIBLE_REGISTRY_BYTES`
    (0 bytes included) that STILL fails to parse/validate after the full
    backoff schedule is not just "corrupt" — it is corrupt in the specific
    way that makes a quarantine-and-reseed response actively harmful (see
    _read_config_with_transient_retry's B1 caller in load_config()): there
    is nothing in it to quarantine that has any forensic value, and
    replacing it with a schema-valid DEFAULT_TEAMS file would make a LOUD,
    visibly-broken registry look silently healthy again.
    """
    try:
        return config_path.stat().st_size < _MIN_PLAUSIBLE_REGISTRY_BYTES
    except OSError:
        return False


def _read_config_with_transient_retry(config_path: Path) -> tuple[dict | None, bool]:
    """Read+parse config_path; on failure, retry with bounded backoff before
    declaring it corrupt.

    Implements contract part (a) for branch B1 (hard parse failure — see
    module docstring): a single failed read/parse is not proof of
    corruption. It may be a concurrent writer caught mid-replace, or (R2) a
    short/0-byte read. Only exhausting the FULL backoff schedule
    (`_CORRUPT_READ_RETRY_BACKOFF_SECONDS`) with every attempt still failing
    counts as confirmed corruption.

    XACA-1029 REVIEW ROUND 2: a single 0.1s retry had a measured hard cliff
    — an independent action-sweep proof showed windows above ~120ms firing
    the destructive path even though R13 established real concurrent bursts
    on this machine. The schedule below trades a slightly slower worst case
    (only paid when the file is ACTUALLY failing to parse — the happy path
    is unaffected) for materially wider transient-race coverage.

    Returns (config_or_None, confirmed_corrupt):
      - (dict, False)  — parsed on the first attempt.
      - (dict, False)  — first attempt failed, but a later retry in the
                          schedule succeeded (transient race, not corruption
                          — proceed normally with this freshly re-read data,
                          do NOT self-heal).
      - (None, True)   — every attempt in the schedule failed. Genuinely
                          corrupt (B1). No team set is knowable from these
                          bytes (R1) — the caller decides between quarantine
                          (file is at least plausibly-sized — manual
                          recovery from the quarantine file genuinely holds)
                          and an in-memory-only refusal (file is also
                          implausibly short — see _file_looks_implausibly_short
                          and the module docstring's B1 suspect carve-out).
                          Part (c) cannot apply on B1 either way.
    """
    def _attempt() -> tuple[dict | None, Exception | None]:
        try:
            raw = config_path.read_text(encoding="utf-8")
        except OSError as exc:
            return None, exc
        try:
            return json.loads(raw), None
        except json.JSONDecodeError as exc:
            return None, exc

    cfg, err = _attempt()
    if err is None:
        return cfg, False

    last_err = err
    total_attempts = len(_CORRUPT_READ_RETRY_BACKOFF_SECONDS) + 1
    for i, delay in enumerate(_CORRUPT_READ_RETRY_BACKOFF_SECONDS, start=2):
        print(
            f"[aiteamforge-paths] transient-read suspect at {config_path} "
            f"({last_err}) — retrying (attempt {i}/{total_attempts}) after "
            f"{delay}s before declaring corrupt",
            file=sys.stderr,
        )
        time.sleep(delay)
        cfg, err = _attempt()
        if err is None:
            print(
                f"[aiteamforge-paths] retry succeeded at {config_path} "
                f"(attempt {i}/{total_attempts}) — transient race, not "
                f"corruption; proceeding with the re-read config",
                file=sys.stderr,
            )
            return cfg, False
        last_err = err

    print(
        f"[aiteamforge-paths] all {total_attempts} attempts failed to parse "
        f"{config_path} ({last_err}) — confirmed corrupt",
        file=sys.stderr,
    )
    return None, True


def _reread_and_revalidate_once(config_path: Path) -> dict | None:
    """Bounded-backoff retry for a structurally-invalid-but-parseable read (B2).

    Mirrors _read_config_with_transient_retry's spirit (and its
    _CORRUPT_READ_RETRY_BACKOFF_SECONDS schedule) for the branch where JSON
    parsed fine but config_is_structurally_valid() rejected it (e.g. a
    momentary empty "teams": {} skeleton). XACA-1029-003 routes every writer
    in this module through _atomic_write_json (tmp file + os.replace), so a
    reader should no longer observe such an intermediate shape from THIS
    module's own writers — this retry is defense-in-depth against writers
    outside this module (the shell canonical, a hand-edit, etc).

    Returns the freshly re-read config dict from the FIRST attempt in the
    schedule that both parses AND passes the structural check, else None
    once the whole schedule is exhausted (confirmed corrupt — B2).
    """
    for delay in _CORRUPT_READ_RETRY_BACKOFF_SECONDS:
        time.sleep(delay)
        try:
            raw = config_path.read_text(encoding="utf-8")
            cfg = json.loads(raw)
        except (OSError, json.JSONDecodeError):
            continue
        has_schema = "schema_version" in cfg
        teams_keys = set(cfg.get("teams", {}).keys())
        if config_is_structurally_valid(teams_keys, has_schema):
            return cfg
    return None


# ---------------------------------------------------------------------------
# Public API — load_config and friends
# ---------------------------------------------------------------------------

def load_config() -> dict:
    """Load, validate, and cache the team-paths config.

    On missing config: bootstraps (see _bootstrap) — write is opt-in only via
    AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE=1 (XACA-0804); read-only must not write.
    On unknown schema_version: warns but continues.
    On corrupt JSON (B1) or failed structural-integrity check (B2): see the
    module docstring's "Bootstrap behaviour" section (XACA-1029) for the full
    contract — bounded-backoff retry, quarantine (never overwrite in place,
    unless there's nothing worth quarantining — see the B1 suspect
    carve-out), and on B2 ONLY, refuse the reseed entirely if it would
    remove a team not present in DEFAULT_TEAMS (a set-difference check,
    never a count comparison).

    Returns a dict with at least {"schema_version": int, "teams": dict}.
    Never raises.
    """
    global _CONFIG_CACHE, _CONFIG_PATH_AT_LOAD, _A1_BACKFILL_ATTEMPTED, _CONTRACT_SCRUB_ATTEMPTED
    global _BOARD_LESS_BACKFILL_ATTEMPTED, _PRIMARY_HOST_BACKFILL_ATTEMPTED

    config_path = get_config_path()
    config_path_str = str(config_path)

    # Re-load if env var changed (important for tests)
    if _CONFIG_CACHE is not None and _CONFIG_PATH_AT_LOAD == config_path_str:
        return _CONFIG_CACHE

    config: dict | None = None
    # XACA-0804: captured ONCE, before any bootstrap/backup side effects, so the
    # eventual `config is None` branch can tell MISSING (no file ever existed)
    # apart from CORRUPT (a file existed but failed to parse or failed the
    # structural-integrity check below) — the two are gated differently by
    # _bootstrap()'s `corrupt` param (corrupt always self-heals; missing is
    # opt-in only via AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE).
    _path_existed_at_start = config_path.exists()
    # XACA-1029 part (c): set True only on the B2 refuse path (structurally-
    # invalid read whose reseed would remove known teams). Suppresses the
    # unconditional _bootstrap() reseed AND the four on-disk self-heal
    # backfill passes below — both would otherwise re-materialize a fresh
    # file at config_path, defeating "leave it quarantined for a human."
    _refused_team_loss = False
    # XACA-1029 REVIEW ROUND 2: set True only on the B1 SUSPECT refuse path
    # (confirmed-corrupt AND implausibly short — see _file_looks_implausibly_short).
    # Same suppression as _refused_team_loss, for the same reason: a suspect
    # 0-byte/near-empty file has nothing worth quarantining, and silently
    # replacing it with a schema-valid DEFAULT_TEAMS file would hide a LOUD,
    # visibly-broken registry behind a healthy-looking one.
    _b1_suspect_no_reseed = False

    if config_path.exists():
        # XACA-1029-004(a)/R1 branch B1: a hard parse failure gets a bounded
        # backoff retry before being declared genuinely corrupt. No team set
        # is knowable from unparseable bytes, so part (c) cannot apply here —
        # see module docstring.
        config, confirmed_corrupt_b1 = _read_config_with_transient_retry(config_path)
        if config is None and confirmed_corrupt_b1:
            if _file_looks_implausibly_short(config_path):
                # XACA-1029 REVIEW ROUND 2 (R2, restated): a confirmed-corrupt
                # file that is ALSO implausibly short (0 bytes included) is
                # the exact signature of the incident this ticket exists to
                # fix — 12 zero-byte `.bak-*` files across three separate
                # days. There is nothing in it to quarantine that has any
                # forensic value (a 0-byte quarantine copy of a 0-byte file
                # is not evidence, it is noise), and reseeding config_path
                # with a schema-valid DEFAULT_TEAMS file would make a LOUD,
                # unmistakably-broken registry look silently healthy again —
                # exactly backwards from what a self-heal should do. Leave
                # the file EXACTLY as-is (no quarantine, no write) so it
                # keeps screaming "broken" at the next human or tool that
                # looks at it, and hand this process DEFAULT_TEAMS in memory
                # only, so it keeps functioning without touching disk.
                print(
                    f"[aiteamforge-paths] CRITICAL: {config_path} is confirmed "
                    f"corrupt AND implausibly short "
                    f"(< {_MIN_PLAUSIBLE_REGISTRY_BYTES} bytes) — refusing to "
                    f"quarantine or reseed. A near-empty file has nothing "
                    f"recoverable to preserve, and overwriting it with "
                    f"DEFAULT_TEAMS would silently hide a visibly-broken "
                    f"registry. Returning DEFAULT_TEAMS in memory for THIS "
                    f"process only — no disk write. The file is left "
                    f"untouched at {config_path}; a human must inspect and "
                    f"restore it manually.",
                    file=sys.stderr,
                )
                config = _make_default_config()
                _b1_suspect_no_reseed = True
            else:
                _quarantine_or_snapshot_existing(
                    config_path, tag="corrupt-unparseable", label="corrupt-config (B1)"
                )
                # config stays None -> falls through to the unconditional
                # _bootstrap() reseed below. config_path no longer exists (it
                # was just quarantined), so _write_defaults's own quarantine
                # attempt is a no-op — no double-quarantine, no double backup.
                # The manual-recovery-from-quarantine rationale genuinely
                # holds here: the file was at least plausibly-sized.

    # Schema-integrity check (XACA-0457) — catch partial-write corruption where
    # JSON is technically valid but the config is missing required teams or the
    # schema_version field.  Must run BEFORE the `if config is None` branch so
    # a corrupted-but-parseable file triggers bootstrap, not silent degradation.
    if config is not None:
        has_schema = "schema_version" in config
        teams_keys = set(config.get("teams", {}).keys())
        # XACA-0705: validity rule lives in config_is_structurally_valid() — the
        # single source of truth shared with lcars-ui/server.py (ends k501 drift).
        # Valid iff schema_version present AND at least one non-academy team exists.
        # Academy absence is a diagnostic hint only, NOT a corruption signal (fixes
        # consumer installs that have no academy team in their overlay).
        missing_required, has_non_required = teams_satisfy_canonical_guard(teams_keys)
        if not config_is_structurally_valid(teams_keys, has_schema):
            # XACA-1029-004(a)/R1 branch B2: JSON parsed fine, but the
            # structural predicate rejected it. One bounded retry (defense in
            # depth against non-atomic writers OUTSIDE this module — every
            # writer inside this module is now atomic, XACA-1029-003) before
            # declaring corrupt.
            retried = _reread_and_revalidate_once(config_path)
            if retried is not None:
                print(
                    f"[aiteamforge-paths] retry succeeded at {config_path} — "
                    f"transient structural-invalid read, not corruption; "
                    f"proceeding with the re-read config",
                    file=sys.stderr,
                )
                config = retried
            else:
                print(
                    f"[aiteamforge-paths] WARNING: {config_path} appears corrupt "
                    f"(has_schema_version={has_schema}, missing_required={sorted(missing_required)}, "
                    f"has_non_required_team={has_non_required}) — bootstrapping defaults",
                    file=sys.stderr,
                )

                # XACA-1029-004(c)/R1/R10: on B2 the parsed team set IS known —
                # refuse to reseed if doing so would REMOVE any of them. SET
                # difference, never a count comparison (R10: a reseed can
                # INCREASE the total team count while destroying every
                # overlay-only team).
                reseed_would_lose = teams_keys - set(DEFAULT_TEAMS.keys())
                if reseed_would_lose:
                    quarantine_path = _quarantine_or_snapshot_existing(
                        config_path,
                        tag="REFUSED-teamloss",
                        label="corrupt-config (B2, refused)",
                    )
                    print(
                        f"[aiteamforge-paths] CRITICAL: refusing to reseed "
                        f"{config_path} — doing so would permanently remove "
                        f"{len(reseed_would_lose)} team(s) not present in "
                        f"DEFAULT_TEAMS: {sorted(reseed_would_lose)}. Original "
                        f"quarantined at {quarantine_path}. A human must "
                        f"restore or repair the config manually — no reseed "
                        f"was written.",
                        file=sys.stderr,
                    )
                    _refused_team_loss = True
                    # `config` already holds the parsed (structurally-invalid
                    # by schema only, but DATA-INTACT) dict — return it as-is
                    # for this process rather than discarding it. Falling
                    # through to _bootstrap() would perform, in memory, the
                    # exact data loss we just refused to write to disk.
                    #
                    # XACA-1029-015 (PR #801 review): "structurally invalid"
                    # has TWO triggers (config_is_structurally_valid) — a
                    # missing schema_version is one of them. So the dict we
                    # are about to hand back can legitimately lack that key,
                    # which would contradict this function's own documented
                    # contract ("Returns a dict with at least
                    # {schema_version: int, teams: dict}"). Every caller today
                    # uses .get(), so nothing breaks now — but a future caller
                    # that trusts the docstring would KeyError, and the
                    # refusal path is exactly the rare branch nobody exercises
                    # by hand. Back-fill the key rather than weaken the
                    # contract; the TEAM DATA (the thing we refused to
                    # destroy) is untouched by this.
                    if "schema_version" not in config:
                        config["schema_version"] = SUPPORTED_SCHEMA_VERSION
                        print(
                            f"[aiteamforge-paths] corrupt-config (B2, refused): "
                            f"the preserved config had no schema_version — "
                            f"back-filling {SUPPORTED_SCHEMA_VERSION} IN MEMORY "
                            f"ONLY so the documented return contract holds. "
                            f"{config_path} on disk is unchanged (quarantined); "
                            f"this does not repair the file.",
                            file=sys.stderr,
                        )
                else:
                    _quarantine_or_snapshot_existing(
                        config_path, tag="corrupt-structural", label="corrupt-config (B2)"
                    )
                    config = None

    if config is None and not (_refused_team_loss or _b1_suspect_no_reseed):
        # XACA-0804: corrupt (file existed, failed to load/validate) always
        # self-heals; missing (no file ever existed) is opt-in only. See
        # _bootstrap()'s docstring for the full rationale.
        config = _bootstrap(config_path, corrupt=_path_existed_at_start)

    # Validate schema_version — v1/v2/v3 all load cleanly; warn only for
    # unknown/future versions.  Missing new fields (v1/v2 configs lacking the
    # anthropic_* keys added in v3) are tolerated; downstream consumers that
    # need those fields should use .get() with empty-string defaults.
    _READABLE_SCHEMA_VERSIONS: frozenset[int] = frozenset({1, 2, 3})
    version = config.get("schema_version")
    if version not in _READABLE_SCHEMA_VERSIONS:
        print(
            f"[aiteamforge-paths] WARNING: schema_version={version!r} is not "
            f"recognized (readable: {sorted(_READABLE_SCHEMA_VERSIONS)}). Proceeding anyway.",
            file=sys.stderr,
        )

    # Ensure "teams" is populated — catches both missing key AND empty dict,
    # the latter being the failure mode that produced a silently-empty team map
    # (bug found on 2026-04-22 when corrupt config made every team lookup 404).
    if not config.get("teams"):
        print(
            "[aiteamforge-paths] WARNING: config has no populated 'teams' — using defaults",
            file=sys.stderr,
        )
        config["teams"] = DEFAULT_TEAMS

    # XACA-1029-004(c): none of the four self-heal passes below may run when
    # we just REFUSED to reseed a team-losing B2 corrupt file, OR refused a
    # B1 suspect (implausibly short) corrupt file. In the B2 case config_path
    # was quarantined (moved away); in the B1-suspect case it was left
    # completely untouched. Either way, these passes would otherwise write a
    # FRESH file back to config_path from the in-memory config, silently
    # re-materializing exactly what the refusal was meant to prevent ("leave
    # it quarantined/untouched for a human to inspect"). Deliberately NOT
    # flipping the _ATTEMPTED flags here either: if this same long-lived
    # process calls load_config() again later after a human restores the
    # file, these passes must still be free to run then.
    if not (_refused_team_loss or _b1_suspect_no_reseed):
        # Contract scrub (XACA-0643) — self-heal configs written before XACA-0643,
        # which seeded bare parameterized-template keys ("medical", "freelance").
        # Those keys are contract violations that lcars-ui/server.py drops with a
        # loud warning on every read; removing them here stops the noise on existing
        # machines. Flag-flipped BEFORE the call (same once-per-process discipline
        # as the A.1 backfill below). Runs first so the backfill operates on the
        # already-cleaned team set.
        if not _CONTRACT_SCRUB_ATTEMPTED:
            _CONTRACT_SCRUB_ATTEMPTED = True
            maybe_scrubbed = _scrub_contract_violating_keys_on_disk(config_path, config)
            if maybe_scrubbed is not None:
                config = maybe_scrubbed

        # A.1 backfill (XACA-0522) — flag-flipped BEFORE the call so even a failed
        # disk write doesn't cause a second lock attempt within the same process.
        if not _A1_BACKFILL_ATTEMPTED:
            _A1_BACKFILL_ATTEMPTED = True
            maybe_upgraded = _backfill_a1_fields_on_disk(config_path, config)
            if maybe_upgraded is not None:
                config = maybe_upgraded

        # Board-less marker backfill (XACA-0794) — self-heal overlays whose board-less
        # teams carry a bare `"kanban_dir": null` with no explanation. Runs LAST so it
        # operates on the already-scrubbed + already-backfilled team set. Same
        # once-per-process flag discipline as the two passes above.
        if not _BOARD_LESS_BACKFILL_ATTEMPTED:
            _BOARD_LESS_BACKFILL_ATTEMPTED = True
            maybe_marked = _backfill_board_less_markers_on_disk(config_path, config)
            if maybe_marked is not None:
                config = maybe_marked

        # primary_host backfill (XACA-0802) — the overlay on every existing machine
        # predates the field, so without this pass the shell host-affinity guard
        # would see "no declared host" for the PII teams forever and fail open
        # forever. Runs after the passes above so it operates on the final team set.
        if not _PRIMARY_HOST_BACKFILL_ATTEMPTED:
            _PRIMARY_HOST_BACKFILL_ATTEMPTED = True
            maybe_hosted = _backfill_primary_host_on_disk(config_path, config)
            if maybe_hosted is not None:
                config = maybe_hosted

    _CONFIG_CACHE = config
    _CONFIG_PATH_AT_LOAD = config_path_str
    return _CONFIG_CACHE


def upgrade_config_to_v3(config: dict) -> dict:
    """Return a copy of *config* with v3 Anthropic account fields back-filled.

    Takes an existing v1 or v2 config dict (or any config missing the three
    new fields) and returns a new dict with:
      - schema_version bumped to 3
      - anthropic_account_id: "" (empty; user fills this in via wizard)
      - anthropic_account_nickname: "" (empty; user fills this in via wizard)
      - anthropic_api_key_env_var: "TEAM_<SLUG_UPPER>_API_KEY" derived from
        the team slug (hyphens replaced with underscores, uppercased)

    This function is a pure transformer — it never touches disk.  It IS now
    called automatically from ``load_config()`` (XACA-0522) via the
    ``_backfill_a1_fields_on_disk`` wrapper, which adds the disk-write half.
    The pure half remains here for unit-testability and for any future
    explicit-invocation path.

    The input config is never mutated; a deep copy is returned.

    Example::

        import copy
        old = load_config()
        new = upgrade_config_to_v3(copy.deepcopy(old))
        # inspect new, then write to disk if user approves
    """
    import copy
    upgraded = copy.deepcopy(config)
    upgraded["schema_version"] = 3

    for slug, entry in upgraded.get("teams", {}).items():
        if "anthropic_account_id" not in entry:
            entry["anthropic_account_id"] = ""
        if "anthropic_account_nickname" not in entry:
            entry["anthropic_account_nickname"] = ""
        if "anthropic_api_key_env_var" not in entry:
            env_var = f"TEAM_{slug.upper().replace('-', '_')}_API_KEY"
            entry["anthropic_api_key_env_var"] = env_var

    return upgraded


def diff_missing_anthropic_fields(config: dict) -> list[tuple[str, list[str]]]:
    """Return [(team_slug, [missing_field_names, ...]), ...] for teams needing backfill.

    Empty list means no migration needed (skip-fast).  The three fields checked
    are ``anthropic_account_id``, ``anthropic_account_nickname``, and
    ``anthropic_api_key_env_var``.

    A field is considered missing only when the KEY is absent from the team
    entry.  An empty-string value is NOT missing and is preserved as-is by the
    subsequent upgrade.
    """
    _FIELDS = ("anthropic_account_id", "anthropic_account_nickname", "anthropic_api_key_env_var")
    result = []
    for slug, entry in sorted(config.get("teams", {}).items()):
        missing = [f for f in _FIELDS if f not in entry]
        if missing:
            result.append((slug, missing))
    return result


# ---------------------------------------------------------------------------
# Shared on-disk rewrite machinery (XACA-0794-008 / -009 / -012)
# ---------------------------------------------------------------------------
#
# THREE self-healing passes rewrite team-paths.json during load_config():
# the A.1 field backfill (XACA-0522), the contract scrub (XACA-0643), and the
# board-less marker backfill (XACA-0794). Each was originally written by cloning
# the previous one, so each carried its own copy of the same lock / TOCTOU /
# backup / atomic-write skeleton — and therefore its own copy of the same three
# defects. That is the k501 sibling-heuristic drift failure mode, and patching
# three copies would only have seeded a fourth.
#
# The skeleton now lives HERE, once. The passes below supply only what actually
# differs between them: a predicate, a transform, a backup tag, and a log label.
# A fourth pass must reuse this driver rather than clone it.


def _reject_if_below_write_floor(data: dict, *, resolved: Path | None = None) -> str:
    """Serialize *data* and raise ValueError if it lands below the write-side
    plausibility floor (``_MIN_PLAUSIBLE_REGISTRY_BYTES``).

    XACA-1059 (PR #817 review round): factored out of ``_atomic_write_json`` so
    callers that must do something IRREVERSIBLE before the write can check the
    floor FIRST. ``_write_defaults`` and ``wizard_hook_create_config`` both call
    ``_quarantine_or_snapshot_existing()`` — which MOVES the existing registry
    aside — immediately before writing. Previously, a floor refusal there
    raised ``ValueError`` past those two callers' ``except OSError`` handlers
    (``ValueError`` is not an ``OSError``) AFTER the quarantine had already
    happened, leaving ``team-paths.json`` ABSENT at the canonical path (its
    contents surviving only in a ``.bak-*`` file) on top of an uncaught
    exception. Checking the floor here, before either caller quarantines
    anything, means a refusal is a true no-op: nothing on disk moves, nothing
    is deleted, and the caller never reaches the quarantine step at all. See
    ``_write_defaults`` / ``wizard_hook_create_config`` for the call sites, and
    ``_atomic_write_json`` below, which still re-runs this same check itself,
    immediately before it writes, as a backstop for any caller that calls it
    directly without going through this pre-check.

    Returns the serialized JSON string on success, so a caller that will need
    it anyway (``_atomic_write_json``) does not have to serialize twice.
    """
    serialized = json.dumps(data, indent=2)
    serialized_bytes = len(serialized.encode("utf-8"))
    if serialized_bytes < _MIN_PLAUSIBLE_REGISTRY_BYTES:
        target_desc = f" {resolved}" if resolved is not None else ""
        print(
            f"[aiteamforge-paths] write-guard: REFUSING to write{target_desc} — "
            f"payload is only {serialized_bytes} bytes, below the "
            f"{_MIN_PLAUSIBLE_REGISTRY_BYTES}-byte plausibility floor for a "
            f"real registry (XACA-1059-006, mirrors the XACA-1029 read-side "
            f"floor — see _MIN_PLAUSIBLE_REGISTRY_BYTES). This would create "
            f"exactly the kind of implausibly-short file XACA-1029 already "
            f"refuses to self-heal from. No write performed; the file on "
            f"disk (if any) is untouched.",
            file=sys.stderr,
        )
        raise ValueError(
            f"refusing to write{target_desc}: payload ({serialized_bytes} bytes) "
            f"is below the {_MIN_PLAUSIBLE_REGISTRY_BYTES}-byte registry "
            f"plausibility floor (XACA-1059-006)"
        )
    return serialized


def _atomic_write_json(target: Path, data: dict) -> None:
    """Atomically rewrite *target* with *data*, preserving file mode and symlink identity.

    XACA-0794-009 (symlink): the write follows the link and replaces the RESOLVED
    target. ``os.replace(tmp, link_path)`` would silently swap the symlink itself
    for a regular file and orphan the real file it pointed at — a config a user
    deliberately symlinked (e.g. into a dotfiles repo) would stop tracking.

    XACA-0794-008 (mode): the tmp file is created under the process umask, so it
    lands at whatever the umask dictates (commonly 0644) regardless of what the
    original was. team-paths.json carries per-team Anthropic account ids and
    API-key env-var names, so a 0600 config silently widening to 0644 on the next
    self-heal is a real permission regression. Copy the original's mode onto the
    tmp file BEFORE the replace, so the mode change is atomic with the content.

    The tmp file is created in the resolved target's own directory — os.replace()
    is only atomic within a single filesystem.

    XACA-1059-006 (write-side plausibility floor): mirrors the read-side floor
    XACA-1029 established (``_MIN_PLAUSIBLE_REGISTRY_BYTES`` /
    ``_file_looks_implausibly_short``, same threshold, same module). That floor
    stops a READER from self-healing from a suspiciously-short file; this stops
    a WRITER from ever producing one in the first place, regardless of which
    caller or in-memory transform produced too-small a payload. Checked against
    the SERIALIZED size actually about to be written — before any tmp file is
    created and before the existing target is touched — so a refusal here can
    never truncate, partially write, or otherwise disturb whatever is already
    on disk. Fails CLOSED: raises, same as every other failure path in this
    function. Most callers treat a raised exception as "degrade to an
    in-memory transform, do not touch disk" (see _rewrite_config_on_disk);
    ``_write_defaults`` and ``wizard_hook_create_config`` additionally
    pre-check via ``_reject_if_below_write_floor`` BEFORE they quarantine an
    existing file, specifically so this floor is never the reason an existing
    registry gets moved aside for a write that was always going to be refused
    — see that function's docstring.

    XACA-1059 (directory fsync): the file's own fsync above only makes its
    CONTENTS durable; the os.replace() rename that makes those contents
    visible at ``resolved``'s path is a separate directory-metadata change
    that needs its own fsync to survive a power loss between the replace and
    whatever unrelated event next syncs that directory.

    Raises ValueError on the plausibility floor (see
    ``_reject_if_below_write_floor``) or OSError on any I/O failure (callers
    degrade to an in-memory transform).
    """
    resolved = target.resolve()

    serialized = _reject_if_below_write_floor(data, resolved=resolved)

    # Capture the mode we must restore. A missing original is not fatal — we simply
    # have no mode to preserve and let the umask stand.
    try:
        orig_mode: int | None = stat.S_IMODE(os.stat(resolved).st_mode)
    except OSError:
        orig_mode = None

    # with_name (not with_suffix): a symlink may resolve to a file whose name has a
    # different suffix, and with_suffix would clobber it.
    tmp_path = resolved.with_name(f"{resolved.name}.tmp.{os.getpid()}")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(serialized)
            f.flush()
            os.fsync(f.fileno())
        if orig_mode is not None:
            os.chmod(tmp_path, orig_mode)
        os.replace(str(tmp_path), str(resolved))
        try:
            dir_fd = os.open(str(resolved.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass  # best-effort — the rename itself already succeeded
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def _rewrite_config_on_disk(
    config_path: Path,
    current: dict,
    *,
    label: str,
    backup_tag: str,
    needs_change: Any,
    transform: Any,
    describe: Any = None,
) -> dict | None:
    """Snapshot, lock, transform, and atomically rewrite the config. Never raises.

    The single owner of the self-heal write path. Parameters:
      label        — human name for log lines ("A.1 backfill").
      backup_tag   — backup filename infix ("a1-backfill").
      needs_change — (cfg) -> truthy when this pass has work to do. Called on the
                     in-memory config for skip-fast AND on the re-read config for
                     TOCTOU defense.
      transform    — (cfg) -> a transformed COPY (must not mutate its input).
      describe     — optional (cfg) -> list[str] of per-change detail log lines.

    Returns the transformed config on success (disk write) or on any degraded path
    (snapshot failure, lost race, write failure) so the calling process always sees
    the corrected shape even when disk could not be updated.
    Returns None only on skip-fast: nothing to do, no lock, no backup, no write.
    """
    if not needs_change(current):
        return None

    try:
        # Lock the RESOLVED path so a process reaching the config through a symlink
        # and one reaching the real file take the SAME lock inode.
        resolved = config_path.resolve()
        lock_file = resolved.with_name(f"{resolved.name}.lock")

        # XACA-0794-012: open with "a" (never truncate) and NEVER unlink. The three
        # passes used to `lock_file.unlink()` in the finally while STILL holding the
        # flock. A racing process blocked on that same path would then be holding a
        # lock on an inode that is no longer reachable by name; the next arrival
        # creates a FRESH inode and acquires it immediately, so two processes both
        # believe they hold the lock. Harmless today (the transforms are additive,
        # re-read under the lock, and idempotent — worst case a redundant write),
        # but it is not a property to leave load-bearing. The lock file is tiny and
        # persistent by design: a lock's whole job is to have a stable identity.
        with open(lock_file, "a") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                # TOCTOU defense — re-read under the lock in case another process raced.
                try:
                    reread = json.loads(resolved.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    reread = current

                if not needs_change(reread):
                    # Someone else won the race. The in-memory `current` is stale, but
                    # this process must still SEE the corrected shape, so return the
                    # transformed in-memory form rather than None.
                    return transform(current)

                timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                backup_path = resolved.with_name(
                    f"{resolved.name}.bak-pre-{backup_tag}-{timestamp}"
                )
                try:
                    backup_path.write_bytes(resolved.read_bytes())
                except OSError as exc:
                    print(
                        f"[aiteamforge-paths] {label}: snapshot failed ({exc}) — aborting disk write",
                        file=sys.stderr,
                    )
                    return transform(current)

                transformed = transform(reread)
                _atomic_write_json(resolved, transformed)

                if describe is not None:
                    for line in describe(current):
                        print(f"[aiteamforge-paths] {label}: {line}", file=sys.stderr)
                print(
                    f"[aiteamforge-paths] {label}: snapshot={backup_path}",
                    file=sys.stderr,
                )
                return transformed
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                # Intentionally NO unlink — see XACA-0794-012 note above.
    except Exception as exc:
        print(
            f"[aiteamforge-paths] {label}: disk write failed ({exc}) — "
            f"degrading to in-memory transform",
            file=sys.stderr,
        )
        return transform(current)


def _backfill_a1_fields_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, upgrade, and atomically write the config if any team lacks A.1 fields.

    Returns the upgraded config dict on success (disk write or in-memory fallback).
    Returns None only when no fields are missing (skip-fast — no lock, no backup, no write).
    Never raises. Write mechanics live in _rewrite_config_on_disk.
    """
    return _rewrite_config_on_disk(
        config_path,
        current,
        label="A.1 backfill",
        backup_tag="a1-backfill",
        needs_change=diff_missing_anthropic_fields,
        transform=upgrade_config_to_v3,
        describe=lambda cfg: [
            f"team={slug} fields={fields}"
            for slug, fields in diff_missing_anthropic_fields(cfg)
        ],
    )


def _find_contract_violating_keys(config: dict) -> list[str]:
    """Return bare parameterized-template keys present in config['teams'].

    A key is a violation when its first '-'-segment is a parameterized template
    AND the whole key equals that segment (no '-instance' suffix), e.g.
    "medical" or "freelance". Pure predicate — never mutates, never raises.
    Mirrors lcars-ui/server.py:_filter_contract_violating_teams() logic. (XACA-0643)
    """
    out = []
    for key in config.get("teams", {}):
        first = key.split("-", 1)[0]
        if first in _PARAMETERIZED_TEMPLATES and key == first:
            out.append(key)
    return out


def _scrub_contract_violating_keys_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, drop bare parameterized-template keys, atomically rewrite.

    Self-heals configs written before XACA-0643 (which seeded bare "medical"/
    "freelance"). Returns the cleaned config dict when a change is made, or None
    when there is nothing to scrub (skip-fast — no lock, no backup, no write).
    Never raises. Write mechanics live in _rewrite_config_on_disk.
    """
    def _clean(cfg: dict) -> dict:
        import copy
        out = copy.deepcopy(cfg)
        teams = out.get("teams", {})
        for k in _find_contract_violating_keys(cfg):
            teams.pop(k, None)
        return out

    return _rewrite_config_on_disk(
        config_path,
        current,
        label="contract scrub",
        backup_tag="contract-scrub",
        needs_change=_find_contract_violating_keys,
        transform=_clean,
        describe=lambda cfg: [
            f"removed bare parameterized-template keys "
            f"{sorted(_find_contract_violating_keys(cfg))} from {config_path} "
            f"(team-id contract violation)"
        ],
    )


def diff_missing_board_less_markers(config: dict) -> list[tuple[str, str | None]]:
    """Return [(team_slug, alias_of), ...] for teams needing the XACA-0794 markers.

    A team needs the markers when DEFAULT_TEAMS declares it board-less but the
    live overlay entry does NOT carry the explicit `board_less` key — i.e. an
    overlay seeded before XACA-0794 (or by the shell heredoc, whose positional
    tab-table has no column for named markers and writes only a bare null).

    DEFAULT_TEAMS is the authority for WHICH teams are board-less; the overlay is
    never trusted to invent board-less-ness. Empty list = already migrated
    (skip-fast). Pure predicate — never mutates, never raises.
    """
    board_less_defaults = {
        slug: entry.get("alias_of")
        for slug, entry in DEFAULT_TEAMS.items()
        if entry.get("board_less") is True
    }
    result: list[tuple[str, str | None]] = []
    for slug, entry in sorted(config.get("teams", {}).items()):
        if slug not in board_less_defaults:
            continue
        if not isinstance(entry, dict):
            continue
        if "board_less" in entry:
            continue  # already migrated
        result.append((slug, board_less_defaults[slug]))
    return result


def apply_board_less_markers(config: dict) -> dict:
    """Return a copy of *config* with board_less/alias_of markers backfilled.

    STRICTLY ADDITIVE — the whole point of XACA-0794 is to make an existing null
    self-explanatory, not to restructure the overlay:
      - Adds ONLY `board_less` and `alias_of`, and ONLY to teams DEFAULT_TEAMS
        declares board-less.
      - Never touches any other team, and never touches any other field on the
        board-less team (lcars_port, anthropic_account_id, team_code, and any
        user customization are preserved byte-for-byte).
      - Deliberately does NOT delete a legacy `"kanban_dir": null`. Deleting it
        would converge the on-disk shape with DEFAULT_TEAMS, but it is not worth
        the risk: a key-presence consumer would then behave differently for
        explicit-null vs absent-key. (One such consumer exists — see
        scripts/aiteamforge-paths-init.sh, fixed in this same change.) The null
        is harmless once the marker sits beside it, because every resolver
        normalizes absent == null == "null" == "" via _ABSENT_SENTINELS.
      - Also neutralizes pre-XACA-0727 overlays that still carry a STALE DUPLICATE
        of command's kanban_dir on mainevent: the marker is checked first, so the
        phantom mainevent-board.json derivation stays dead.

    Idempotent: re-running on an already-migrated config is a no-op.
    The input config is never mutated; a deep copy is returned.
    """
    import copy
    upgraded = copy.deepcopy(config)
    teams = upgraded.get("teams", {})
    for slug, alias in diff_missing_board_less_markers(config):
        entry = teams.get(slug)
        if not isinstance(entry, dict):
            continue
        entry["board_less"] = True
        if alias:
            entry["alias_of"] = alias
    return upgraded


def _backfill_board_less_markers_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, add board_less/alias_of markers, atomically rewrite (XACA-0794).

    Self-heals overlays written before XACA-0794 — including those seeded by the
    shell heredoc, whose positional tab-table cannot express named markers. That
    is what closes the K661 dual-canonical drift WITHOUT requiring the two seeds
    to stay in lockstep forever: whichever seed wrote the overlay, the first
    Python read converges it onto the marker shape.

    Returns the upgraded config when a change is made, or None when there is
    nothing to do (skip-fast — no lock, no backup, no write). Never raises.
    Write mechanics live in _rewrite_config_on_disk — this pass deliberately owns
    NO copy of the lock / TOCTOU / backup / atomic-write skeleton.
    """
    return _rewrite_config_on_disk(
        config_path,
        current,
        label="board-less markers",
        backup_tag="board-less-markers",
        needs_change=diff_missing_board_less_markers,
        transform=apply_board_less_markers,
        describe=lambda cfg: [
            f"team={slug} board_less=true alias_of={alias!r} (XACA-0794 — the null "
            f"kanban_dir is intentional, not corruption)"
            for slug, alias in diff_missing_board_less_markers(cfg)
        ],
    )


def diff_missing_primary_host(config: dict) -> list[tuple[str, str]]:
    """Return [(team_slug, primary_host), ...] for teams needing the XACA-0802 field.

    A team needs the field when DEFAULT_TEAMS declares a non-empty `primary_host`
    but the live overlay entry does not carry the key at all. DEFAULT_TEAMS is the
    authority for WHICH host owns a team; the overlay is never trusted to invent
    or contradict ownership, but a hand-set overlay value IS respected (key
    present → skipped), so an operator who moves a team to another box is not
    fought by the loader on every read.

    Empty list = already migrated (skip-fast). Pure predicate — never mutates,
    never raises.
    """
    host_defaults = {
        slug: str(entry.get("primary_host") or "")
        for slug, entry in DEFAULT_TEAMS.items()
        if entry.get("primary_host")
    }
    result: list[tuple[str, str]] = []
    for slug, entry in sorted(config.get("teams", {}).items()):
        if slug not in host_defaults:
            continue
        if not isinstance(entry, dict):
            continue
        if "primary_host" in entry:
            continue  # already migrated, or deliberately overridden
        result.append((slug, host_defaults[slug]))
    return result


def apply_primary_host(config: dict) -> dict:
    """Return a copy of *config* with `primary_host` backfilled (XACA-0802).

    STRICTLY ADDITIVE, mirroring apply_board_less_markers:
      - Adds ONLY `primary_host`, and ONLY to teams DEFAULT_TEAMS declares a host
        for (today: the three PII teams).
      - Never touches any other team and never touches any other field.
      - Never overwrites an existing `primary_host`, even an empty one — key
        presence is the migration marker, and an operator's explicit value wins.

    Idempotent: re-running on an already-migrated config is a no-op. The input
    config is never mutated; a deep copy is returned.
    """
    import copy
    upgraded = copy.deepcopy(config)
    teams = upgraded.get("teams", {})
    for slug, host in diff_missing_primary_host(config):
        entry = teams.get(slug)
        if not isinstance(entry, dict):
            continue
        entry["primary_host"] = host
    return upgraded


def _backfill_primary_host_on_disk(config_path: Path, current: dict) -> dict | None:
    """Snapshot, lock, add `primary_host`, atomically rewrite (XACA-0802).

    Self-heals overlays written before XACA-0802 — i.e. every overlay in the
    fleet at the time this shipped. Without it the field would exist only in
    Python's DEFAULT_TEAMS, which the SHELL guard never reads: kanban-helpers.sh
    reads the on-disk overlay, so a team's host affinity is only enforceable once
    the value is materialized there.

    Returns the upgraded config when a change is made, or None when there is
    nothing to do (skip-fast — no lock, no backup, no write). Never raises. Write
    mechanics live in _rewrite_config_on_disk — this pass owns no copy of the
    lock / TOCTOU / backup / atomic-write skeleton.
    """
    return _rewrite_config_on_disk(
        config_path,
        current,
        label="primary-host affinity",
        backup_tag="primary-host",
        needs_change=diff_missing_primary_host,
        transform=apply_primary_host,
        describe=lambda cfg: [
            f"team={slug} primary_host={host!r} (XACA-0802 — knowledge for this "
            f"team is authored on that host only)"
            for slug, host in diff_missing_primary_host(cfg)
        ],
    )


# ---------------------------------------------------------------------------
# Team accessor functions
# ---------------------------------------------------------------------------

def list_teams() -> list[str]:
    """Return all team IDs defined in the config."""
    config = load_config()
    return list(config["teams"].keys())


def get_team_kanban_dir(team: str) -> Path:
    """Return the kanban directory Path for the given team.

    Raises KeyError with a helpful message if the team is not found, or if the
    team is a board-less alias (e.g. "mainevent" — XACA-0727 — which has no
    kanban board of its own; use "command" for Main Event coordination).
    Team-iterating consumers catch this KeyError and skip the team.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    # XACA-0794: prefer the EXPLICIT board_less marker; XACA-0727: fall back to
    # sentinel-normalization (missing key / JSON null / "null" / "") so overlays
    # written before the marker existed keep raising the same clear KeyError.
    # Marker-first also repairs pre-XACA-0727 overlays that still carry a stale
    # DUPLICATE of command's kanban_dir: the marker wins, so we raise instead of
    # deriving the phantom mainevent-board.json that XACA-0727 was filed to kill.
    _kd = entry.get("kanban_dir")
    if team_is_board_less(entry) or _kd in _ABSENT_SENTINELS:
        raise _board_less_error(team, entry, "kanban_dir")
    return Path(_kd).expanduser()


def get_team_memory_dir(team: str) -> Path | None:
    """Return the Claude auto-memory directory for the given team, or None.

    Claude Code encodes the project working directory as a directory name
    under ``~/.claude/projects/`` by replacing every ``/`` with ``-`` and
    prepending a ``-`` (so the leading ``/`` of an absolute path becomes a
    leading ``-``).  For example::

        /Users/darrenehlers/dev-team
        ->  -Users-darrenehlers-dev-team
        /Users/Shared/Development/Main Event/MainEventApp-iOS-DEV
        ->  -Users-Shared-Development-Main-Event-MainEventApp-iOS-DEV

    However, spaces in path components are also replaced with ``-``, so
    ``Main Event`` becomes ``Main-Event``.  The resulting slug is the name
    of the project directory, and the memory subdirectory lives inside it.

    Derivation strategy (in order):
      1. Derive the encoded slug from the team's ``working_dir``.
      2. Probe ``~/.claude/projects/<slug>/memory/`` for existence.
      3. If the derived slug doesn't exist, scan ``~/.claude/projects/``
         for a directory whose name starts with the derived slug (handles
         the ``-develop`` / ``-DEV`` suffix variants Claude Code appends
         when the working-dir checkout has a branch suffix).
      4. If no match exists, return ``None`` (memory dir absent — team has
         never been opened in Claude Code, or has no memory yet).

    Notes:
      - The function never raises for a missing team — it returns ``None``.
      - The function never creates the directory; it is read-only.
      - The team must exist in the config; otherwise ``KeyError`` is raised
        (consistent with ``get_team_kanban_dir``).

    Raises:
        KeyError: if the team is not found in the config.

    Returns:
        Path to the memory directory, or ``None`` if it does not exist.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    # Board-less alias (e.g. "mainevent"): no working_dir, so no derivable memory
    # dir. Marker-first (XACA-0794), sentinel fallback (XACA-0727). Consistent
    # with get_team_kanban_dir / get_team_working_dir.
    _wd = entry.get("working_dir")
    if team_is_board_less(entry) or _wd in _ABSENT_SENTINELS:
        raise _board_less_error(team, entry, "working_dir")

    working_dir = Path(_wd).expanduser()

    # Encode the working_dir path as Claude Code does:
    #   1. Replace spaces with hyphens (spaces in dir names map to -)
    #   2. Replace / with -  (each path separator becomes -)
    #   3. The result already starts with - because abs path starts with /
    encoded = working_dir.as_posix().replace(" ", "-").replace("/", "-")
    # encoded now looks like: -Users-darrenehlers-dev-team

    projects_root = Path.home() / ".claude" / "projects"

    # Strategy 1: exact match
    exact = projects_root / encoded / "memory"
    if exact.is_dir():
        return exact

    # Strategy 2: prefix scan — handles -DEV, -develop, and other suffixes
    # that Claude Code appends when the working dir itself has a branch suffix
    # or when the user opened a subdirectory.
    try:
        for candidate in sorted(projects_root.iterdir()):
            if not candidate.is_dir():
                continue
            if candidate.name == encoded or candidate.name.startswith(encoded + "-"):
                mem = candidate / "memory"
                if mem.is_dir():
                    return mem
    except OSError:
        pass

    # No memory directory found for this team
    return None


def get_team_working_dir(team: str) -> Path:
    """Return the working directory Path for the given team.

    The working_dir is the parent of kanban_dir (the project root).

    Raises KeyError with a helpful message if the team is not found, or if the
    team is a board-less alias (e.g. "mainevent" — XACA-0727 — which has no
    working_dir of its own). Team-iterating consumers catch this and skip.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    # XACA-0794 marker-first / XACA-0727 sentinel fallback — see get_team_kanban_dir.
    _wd = entry.get("working_dir")
    if team_is_board_less(entry) or _wd in _ABSENT_SENTINELS:
        raise _board_less_error(team, entry, "working_dir")
    return Path(_wd).expanduser()


def get_team_lcars_port(team: str) -> int | None:
    """Return the LCARS port for the given team, or None if not applicable.

    Raises KeyError with a helpful message if the team is not found.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    port = entry.get("lcars_port")
    return int(port) if port is not None else None


def get_team_primary_host(team: str) -> str:
    """Return the team's declared primary host, or "" when none is declared (XACA-0802).

    "" means "unowned / not yet declared", which every consumer must treat as
    fail-OPEN — the registry lists all 20 teams on every machine, so absence has
    always been the normal case and must never be read as "this host is wrong".

    KEY PRESENCE IS THE CONTRACT (XACA-0802-004). `diff_missing_primary_host` /
    `apply_primary_host` deliberately treat a present key — INCLUDING an empty
    one — as "the operator has spoken", and never overwrite it. This accessor
    must read the overlay by exactly that rule, because the shell-side guard
    (`_kb_team_primary_host` in kanban-helpers.sh) does: it reads
    `.teams[$t].primary_host // ""` and an empty value makes
    `_kb_knowledge_host_affinity_guard` fail OPEN. A blanket `if not host`
    fallback to DEFAULT_TEAMS made the two sides disagree about the identical
    overlay entry — Python insisting a host owned the team while the shell read
    it as undeclared. The DEFAULT_TEAMS fallback therefore fires ONLY when the
    key is genuinely absent (an overlay predating the backfill pass, or one the
    backfill could not rewrite), which is the migration-tolerance case
    get_team_code has and the only case the fallback was ever meant to serve.

    Raises KeyError with a helpful message if the team is not found.
    """
    config = load_config()
    entry = config["teams"].get(team)
    if entry is None:
        hint = _available_teams_hint(config)
        raise KeyError(
            f"Team '{team}' not found. Available: {hint} — "
            f"edit {get_config_path()} or run `aiteamforge-paths init`."
        )
    if "primary_host" in entry:
        host = entry.get("primary_host")
    else:
        host = DEFAULT_TEAMS.get(team, {}).get("primary_host")
    return str(host) if host else ""


# ---------------------------------------------------------------------------
# XACA-0542: Team-code registry accessors
# ---------------------------------------------------------------------------
# team_code is the 3-letter code (e.g. "ACA", "IOS") stored in each team
# entry in DEFAULT_TEAMS.  These accessors allow consumers to derive the
# code<->team mapping from the registry instead of maintaining parallel
# hardcoded dicts / case statements.
#
# Aliases (entries without team_code) are intentionally skipped in the
# reverse-lookup to avoid ambiguous code→team resolution.


def get_team_code(team: str) -> str:
    """Return the 3-letter team code for the given team id, or "" if unknown.

    Lookup strategy (in priority order):
    1. Live config (team-paths.json overlaid on DEFAULT_TEAMS) if team_code present.
    2. DEFAULT_TEAMS directly — covers migration case where live config doesn't
       yet have team_code fields (pre-XACA-0542 installs).
    Returns "" for aliases (entries with no team_code field).
    """
    # 1. Live config
    try:
        config = load_config()
        entry = config["teams"].get(team)
        if entry is not None:
            code = entry.get("team_code", "")
            if code:
                return code
    except Exception:
        pass
    # 2. DEFAULT_TEAMS fallback (loader unavailable OR live config lacks team_code)
    entry = DEFAULT_TEAMS.get(team)
    if entry is not None:
        return entry.get("team_code", "")
    return ""


def get_team_from_code(code: str) -> str:
    """Return the team id for the given 3-letter code, or "" if unknown.

    Lookup strategy (in priority order):
    1. Live config (team-paths.json overlaid on DEFAULT_TEAMS) if team_code present.
    2. DEFAULT_TEAMS directly — covers migration case where live config doesn't
       yet have team_code fields (pre-XACA-0542 installs).
    Skips alias entries (entries with no team_code field) to avoid ambiguity.
    """
    code_upper = code.upper()
    # 1. Live config
    try:
        config = load_config()
        for team_id, entry in config["teams"].items():
            if entry.get("team_code", "").upper() == code_upper:
                return team_id
    except Exception:
        pass
    # 2. DEFAULT_TEAMS fallback (loader unavailable OR live config lacks team_code)
    for team_id, entry in DEFAULT_TEAMS.items():
        if entry.get("team_code", "").upper() == code_upper:
            return team_id
    return ""


def build_team_code_map() -> dict[str, str]:
    """Return a mapping of {3-letter-code: team-id} derived from the registry.

    Merge strategy (team-paths.json overlaid on DEFAULT_TEAMS — XACA-0628):
    1. Start from DEFAULT_TEAMS team_codes (the always-present base).
    2. Overlay live-config (team-paths.json) team_codes ON TOP — live wins on
       conflict, and overlay-only slugs (per-project freelance codes that have
       NO DEFAULT_TEAMS entry, e.g. freelance-bandwear-dashboard → BWD) are
       additive.
    3. Only include entries with a non-empty team_code field.

    Why a MERGE (not exclusive-or): the previous exclusive-or only fell back to
    DEFAULT_TEAMS when the live config yielded *zero* team_codes. Once any
    overlay entry carries a team_code (e.g. per-project freelance codes), that
    fallback was skipped and every non-overlay team (academy/ios/…) silently
    dropped out of the map. Merging keeps the DEFAULT_TEAMS base intact while
    layering per-project overlay codes on top.

    With TODAY's overlay (no overlay team_codes) the result is identical to the
    DEFAULT_TEAMS-derived map — regression-safe.

    This is the authoritative source for the code->team mapping.
    Consumers that previously maintained hardcoded _TEAM_CODE_MAP dicts
    should use this function instead. (XACA-0542, XACA-0628)
    """
    result: dict[str, str] = {}
    # 1. Base: DEFAULT_TEAMS team_codes (always present, even if the loader is
    #    entirely unavailable).
    for team_id, entry in DEFAULT_TEAMS.items():
        code = entry.get("team_code", "")
        if code:
            result[code.upper()] = team_id
    # 2. Overlay: live-config team_codes on top (live wins on conflict; adds
    #    overlay-only per-project slugs that have no DEFAULT_TEAMS entry).
    try:
        config = load_config()
        for team_id, entry in config["teams"].items():
            code = entry.get("team_code", "")
            if code:
                result[code.upper()] = team_id
    except Exception:
        # Loader unavailable → keep the DEFAULT_TEAMS base built in step 1.
        pass
    return result


def _resolve_template_band(template_id: str) -> tuple[int, int]:
    """Return (lcars_port_base, lcars_port_range) for *template_id*.

    Lookup strategy (in order):
    1. Direct key match in DEFAULT_TEAMS. Covers both a bare template queried
       by its own name (e.g. "mainevent" → its own board-less-alias entry)
       and a fully-seeded instance queried by its own name (e.g.
       "mainevent-dev-team", "finance-personal").
    2. Explicit band declaration: an exact or base-template hit in
       _TEMPLATE_PORT_BANDS. Checked BEFORE any heuristic derivation because
       an explicit declaration is authoritative — it exists precisely to
       state "this template's band is X", and a human/registry author who
       wrote that entry did so to be trusted over a guess. (XACA-0806,
       subitem 3 — see rationale below.)
    3. Tolerant input: if template_id contains a dash, strip to first
       dash-separated component (base template) and retry direct lookup
       (handles "finance-personal" → "finance").
    4. Prefix scan: search DEFAULT_TEAMS for any key that starts with
       "<template_id>-" and inherit its band. This handles pure template
       ids like "finance" that only appear as "finance-personal" in
       DEFAULT_TEAMS.

    Raises:
        ValueError: if no matching entry or the entry has no band declared.

    ORDERING RATIONALE (XACA-0806 subitem 3 — fixes the shadowing bug flagged
    where _TEMPLATE_PORT_BANDS is defined above):
    Step 3 (strip-dash) used to run BEFORE the explicit-band lookup. That is
    fine for freelance (no bare DEFAULT_TEAMS entry exists for it, so step 3
    always misses and falls through) but wrong for mainevent: mainevent DOES
    have a bare DEFAULT_TEAMS entry (board-less alias, lcars_port_base 8400 /
    range 1 — see that entry's comment). For an UNSEEDED instance like
    "mainevent-somefutureproject", step 1 misses (no direct key), and the old
    step-2 strip-dash tolerant lookup would find the bare "mainevent" entry
    and return ITS band (8400, 1) — silently donating the board-less alias's
    own port band to an arbitrary per-project child, even though the whole
    point of _TEMPLATE_PORT_BANDS["mainevent"] = (8401, 19) is to give
    per-project instances a DIFFERENT, non-colliding band.
        The general rule that fixes this without special-casing the string
    "mainevent": an explicit band declaration in _TEMPLATE_PORT_BANDS is
    authoritative for a given base template and must be checked before any
    heuristic (strip-dash / prefix-scan) derivation is allowed to substitute
    a *different* entry's band. This generalizes correctly to any future
    template that, like mainevent, has both a bare DEFAULT_TEAMS entry AND a
    separate _TEMPLATE_PORT_BANDS declaration for its per-instance children.
        This reordering is safe for the templates that intentionally have NO
    _TEMPLATE_PORT_BANDS entry (finance, legal, medical): the explicit-band
    step below simply misses for them (returns None) and falls through
    unchanged to steps 3/4 exactly as before. It is also safe for exact
    lookups of "mainevent" itself and of any already-seeded
    "mainevent-<instance>" key (mainevent-dev-team, etc.) — those are direct
    DEFAULT_TEAMS hits at step 1, which still runs FIRST and returns before
    step 2 is ever consulted.
    """
    # 1. Direct lookup.
    entry = DEFAULT_TEAMS.get(template_id)

    # 2. Explicit band declaration wins over any heuristic derivation below.
    #    Must run before step 3's strip-dash lookup — see ORDERING RATIONALE.
    if entry is None:
        base_template = template_id.split("-")[0] if "-" in template_id else template_id
        band = _TEMPLATE_PORT_BANDS.get(template_id) or _TEMPLATE_PORT_BANDS.get(base_template)
        if band is not None:
            return int(band[0]), int(band[1])

    # 3. Tolerant input: instance id passed; strip to base template.
    if entry is None and "-" in template_id:
        base_template = template_id.split("-")[0]
        entry = DEFAULT_TEAMS.get(base_template)

    # 4. Prefix scan: template id exists only as part of instance keys.
    if entry is None:
        prefix = template_id + "-"
        for key, candidate in DEFAULT_TEAMS.items():
            if key.startswith(prefix) and candidate.get("lcars_port_base") is not None:
                entry = candidate
                break

    if entry is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_base declared "
            f"(not found in DEFAULT_TEAMS directly, by stripping dashes, "
            f"via prefix scan, or in _TEMPLATE_PORT_BANDS)."
        )

    base = entry.get("lcars_port_base")
    band_range = entry.get("lcars_port_range")
    if base is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_base declared."
        )
    if band_range is None:
        raise ValueError(
            f"Template '{template_id}' has no lcars_port_range declared."
        )
    return int(base), int(band_range)


def compute_instance_port(template_id: str, existing_team_paths: dict) -> int:
    """Allocate the lowest free port in the template's band.

    Per XACA-0463 / team-id-contract §4.1: each template owns a port band
    declared as TEAM_LCARS_PORT_BASE + TEAM_LCARS_PORT_RANGE. The lowest
    port in the half-open interval [base, base+range) that is NOT already
    used by any entry in existing_team_paths["teams"][*]["lcars_port"] is
    returned. Cross-template collisions are honored (a port owned by
    another template is still considered taken).

    Args:
        template_id: A template id (e.g. "finance", "freelance"). MUST
            match a key in DEFAULT_TEAMS *with* lcars_port_base set, OR
            be derivable via splitting on '-' and taking the first segment
            (tolerant input: "finance-personal" resolves to "finance").
        existing_team_paths: The parsed contents of team-paths.json,
            shape {"teams": {"<instance>": {"lcars_port": int | None, ...}}}.

    Returns:
        The chosen port (int).

    Raises:
        ValueError: template unknown, band not declared, or band exhausted.
    """
    base, band_range = _resolve_template_band(template_id)

    # Collect every port already in use, across ALL templates.
    used_ports: set[int] = {
        int(entry["lcars_port"])
        for entry in existing_team_paths.get("teams", {}).values()
        if entry.get("lcars_port") is not None
    }

    for port in range(base, base + band_range):
        if port not in used_ports:
            return port

    # Band fully exhausted.
    used_in_band = [p for p in used_ports if base <= p < base + band_range]
    raise ValueError(
        f"Port band exhausted for template '{template_id}': "
        f"band [{base}, {base + band_range}), "
        f"{len(used_in_band)} of {band_range} used. "
        f"Extend TEAM_LCARS_PORT_RANGE in <template>.conf and rerun."
    )


# ---------------------------------------------------------------------------
# XACA-0579: Import preflight path-map derivation
# ---------------------------------------------------------------------------

# Subdirectory name under $HOME on a tap-installed AITeamForge machine.
_TAP_SUBDIR = "aiteamforge"
# Subdirectory name under $HOME on a dev-team monorepo machine (the source of
# truth for development; never installed alongside the tap — see CLAUDE.md).
_DEV_SUBDIR = "dev-team"


def build_import_path_maps(manifest: dict) -> list[str]:
    """Derive --path-map SRC=DST strings for the import-preflight verifier.

    The verifier runs on the *destination* machine against a manifest generated
    on the *source* machine.  When the two machines have different directory
    layouts (e.g. M3Pro dev-team monorepo vs M1Pro tap-install), absolute paths
    in the manifest will not exist at their literal locations on the destination.
    This function derives the minimal set of prefix mappings needed to bridge
    the gap so the verifier can resolve source paths to destination equivalents.

    Layout detection strategy
    -------------------------
    1.  Check whether the destination machine has the tap install root
        (``~/aiteamforge/``) present on disk or holds a ``.installed-version``
        sentinel inside it.  This is the canonical tap-install indicator and
        does NOT require any team working_dir to live under ``~/aiteamforge/``
        — many real machines route teams to canonical home paths (e.g.
        ``~/finance/personal``, ``~/academy``) while still being tap-installs.
        The previous approach (XACA-0579) walked team working_dirs looking for
        an ``~/aiteamforge/`` prefix — this failed for every M1Pro layout
        where teams live at their canonical home paths.

    2.  Examine the source home prefix from ``manifest["home"]``.  The source
        machine is ALWAYS assumed to be a DEV-TEAM machine (monorepo layout) when
        the destination is a tap install — this is the only migration scenario
        that crosses layout boundaries in this codebase.  If both src and dst are
        dev-team machines, their working_dirs share the same relative structure
        under home; only a home-prefix rewrite is needed (handled by the verifier
        natively when ``src_home != dst_home``), so no explicit --path-map is
        required.

    3.  Emit two classes of mappings:

        a.  Shared-infra mapping: ``<src_home>/dev-team → <dst_home>/aiteamforge``.
            Covers lcars-ui/, kanban-hooks/, scripts/, etc.

        b.  Per-team mappings derived from ``manifest["teams"]`` (source layout
            snapshot) and local config (destination layout).  For each team where
            ``src_wd != dst_wd``, emit ``"src_wd=dst_wd"``.  Handles scope-suffix
            drift (e.g. source ``~/finance`` vs destination ``~/finance/personal``).

        All mappings are de-duplicated and sorted longest-src-prefix first so
        the verifier's first-match-wins logic picks the most specific mapping.

    Concrete example (M3Pro → M1Pro, scope-suffix drift):
        Manifest["teams"]["finance"]["working_dir"]: /Users/darrenehlers/finance
        Destination config:  working_dir = /Users/darrenehlers/finance/personal
        Emitted mappings:
            /Users/darrenehlers/finance=/Users/darrenehlers/finance/personal  (per-team)
            /Users/darrenehlers/dev-team=/Users/darrenehlers/aiteamforge      (shared-infra)

    Cross-user example (M3Pro → M1Pro, different username):
        Destination has:  ~/aiteamforge/.installed-version  (tap indicator)
        Manifest has:     home = /Users/developer
        Emitted mapping:  /Users/developer/dev-team=/Users/alice/aiteamforge
        (home-prefix rewrite handles the user part; tap-vs-devteam handled here)

    Args:
        manifest: The parsed manifest dict (from json.loads of manifest.json).
                  Must contain at least ``home`` (str).

    Returns:
        List of ``"SRC=DST"`` strings to pass as ``--path-map`` arguments.
        Empty list if no mapping is needed (same-layout machines or no config).

    Never raises.
    """
    try:
        # XACA-0580-012: strip whitespace BEFORE rstrip("/"); a whitespace-only
        # "home" must fail the early-exit check, otherwise a garbage manifest
        # could produce a bogus path-map on a tap-install destination.
        src_home = manifest.get("home", "").strip().rstrip("/")
        if not src_home:
            return []

        dst_home = str(Path.home()).rstrip("/")

        dst_aiteamforge_root = dst_home + "/" + _TAP_SUBDIR
        src_devteam_root = src_home + "/" + _DEV_SUBDIR

        config = load_config()

        # Tap-install detection: check for the canonical tap install root, which
        # exists IFF this machine has the homebrew tap installed.  Team working_dirs
        # are NOT required to live under ~/aiteamforge/ — many real machines route
        # teams to canonical home paths (e.g. ~/finance/personal, ~/academy) while
        # still being tap-installs.  Heuristic-on-team-paths was the XACA-0579 bug.
        dst_aiteamforge_dir = Path(dst_aiteamforge_root)
        tap_install_detected = (
            dst_aiteamforge_dir.is_dir()
            or (dst_aiteamforge_dir / ".installed-version").exists()
        )

        if not tap_install_detected:
            # Destination is a dev-team monorepo or unknown layout.
            # The verifier's built-in home-prefix rewrite handles cross-user cases.
            return []

        # Destination is a tap install.  Build path mappings:
        #   1. Shared-infra: <src_home>/dev-team → <dst_home>/aiteamforge
        #      Covers lcars-ui/, kanban-hooks/, scripts/, etc.
        #   2. Per-team: src_wd → dst_wd for teams where layout differs between
        #      source (manifest snapshot) and destination (local config).
        #      Handles scope-suffix drift (e.g. ~/finance vs ~/finance/personal).
        shared_infra_map = f"{src_devteam_root}={dst_aiteamforge_root}"

        mappings: list[str] = [shared_infra_map]

        # Per-team mappings from manifest teams snapshot vs local config.
        manifest_teams: dict = manifest.get("teams") or {}
        local_teams: dict = config.get("teams") or {}
        seen: set[str] = {shared_infra_map}

        for slug, src_entry in manifest_teams.items():
            src_wd = (src_entry or {}).get("working_dir", "").rstrip("/")
            if not src_wd:
                continue
            # XACA-0581: teams whose source working_dir IS the dev-team root
            # (e.g. academy, freelance) are already covered by shared_infra_map.
            # Emitting a per-team map keyed on the same src prefix collides with
            # it — identical prefix length means the verifier's longest-first sort
            # falls back to stable insertion order, and the per-team map would
            # mis-route dev-team paths into a team subdir (e.g. ~/academy) instead
            # of ~/aiteamforge. Skip them; shared-infra is the correct mapping.
            if src_wd == src_devteam_root:
                continue
            dst_entry = local_teams.get(slug) or {}
            dst_wd_raw = (dst_entry or {}).get("working_dir", "")
            if not dst_wd_raw:
                continue
            dst_wd = str(Path(dst_wd_raw).expanduser()).rstrip("/")
            if not dst_wd or src_wd == dst_wd:
                continue
            mapping = f"{src_wd}={dst_wd}"
            if mapping not in seen:
                seen.add(mapping)
                mappings.append(mapping)

        # Sort longest src prefix first — verifier uses first-match-wins so the
        # most specific (per-team) mapping must precede the generic shared-infra one.
        mappings.sort(key=lambda m: len(m.split("=", 1)[0]), reverse=True)
        return mappings

    except Exception as exc:
        print(
            f"[aiteamforge-paths] build_import_path_maps: error deriving path maps: {exc}",
            file=sys.stderr,
        )
        return []


# ---------------------------------------------------------------------------
# Wizard hook (for subitem 002 — interactive setup wizard)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Export / backup exclusion rules — XACA-0168-017
#
# These are the canonical exclusion patterns for kanban directory backups.
# kanban-backup.py imports these instead of defining them inline.
# ---------------------------------------------------------------------------

#: File suffixes excluded from backup archives and delta-hash computation.
EXPORT_EXCLUSION_SUFFIXES: frozenset[str] = frozenset({".lock"})

#: Exact filenames excluded from backup archives and delta-hash computation.
EXPORT_EXCLUSION_NAMES: frozenset[str] = frozenset({".DS_Store", "firebase-debug.log"})

#: Glob-style patterns excluded from backup archives and delta-hash computation.
#: Matched with Path.match() against each candidate file path.
EXPORT_EXCLUSION_PATTERNS: tuple[str, ...] = ("*-debug.log",)


def is_excluded_from_export(filepath: "Path") -> bool:  # type: ignore[name-defined]
    """Return True if *filepath* should be excluded from backup/export.

    Checks EXPORT_EXCLUSION_SUFFIXES, EXPORT_EXCLUSION_NAMES, and
    EXPORT_EXCLUSION_PATTERNS in order.  Import Path from pathlib before use.
    """
    name = filepath.name
    if name in EXPORT_EXCLUSION_NAMES:
        return True
    if filepath.suffix in EXPORT_EXCLUSION_SUFFIXES:
        return True
    for pattern in EXPORT_EXCLUSION_PATTERNS:
        if filepath.match(pattern):
            return True
    return False


# ---------------------------------------------------------------------------
# XACA-0658: Versioned release-push flow — version-source config accessors
# ---------------------------------------------------------------------------


def get_team_version_sources(team_id: str, platform: str | None = None) -> list[dict]:
    """Return the version_sources list for *team_id*, optionally filtered by platform.

    Args:
        team_id:  Team slug (e.g. "ios", "android").
        platform: If given, return only entries whose ``platform`` field matches
                  (case-sensitive).  If None, return all entries.

    Returns:
        List of version-source dicts (may be empty if key is absent or no match).
        Each dict has at minimum: platform, file, match_pattern, write_pattern.
        Optional fields: encoding (default "utf-8"), replace_all (default False).

    Never raises — missing team or missing key returns an empty list.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    sources = entry.get("version_sources", [])
    if not isinstance(sources, list):
        return []
    if platform is not None:
        sources = [s for s in sources if isinstance(s, dict) and s.get("platform") == platform]
    return [s for s in sources if isinstance(s, dict)]


def get_team_branch_env_map(team_id: str) -> dict:
    """Return the raw branch_env_map for *team_id*.

    The map values are either strings (all-platforms shorthand) or dicts
    (per-platform).  Use normalize_branch_env() to resolve a specific branch
    and platform list to a {platform: env} dict.

    Returns:
        dict — the raw branch_env_map (may be empty if key is absent).

    Never raises — missing team or missing key returns an empty dict.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    raw = entry.get("branch_env_map", {})
    if not isinstance(raw, dict):
        return {}
    return raw


def get_team_relnotes_sources(team_id: str, platform: str | None = None) -> list[dict]:
    """Return the relnotes_sources list for *team_id*, optionally filtered by platform.

    Args:
        team_id:  Team slug.
        platform: If given, return only entries whose ``platform`` field matches.

    Returns:
        List of relnotes-source dicts (may be empty if key is absent or no match).
        Each dict has at minimum: platform, dir (relative to working_dir).

    Never raises — missing team or missing key returns an empty list.
    """
    config = load_config()
    entry = config.get("teams", {}).get(team_id, {})
    sources = entry.get("relnotes_sources", [])
    if not isinstance(sources, list):
        return []
    if platform is not None:
        sources = [s for s in sources if isinstance(s, dict) and s.get("platform") == platform]
    return [s for s in sources if isinstance(s, dict)]


def normalize_branch_env(branch_map_value: str | dict, release_platforms: list[str]) -> dict[str, str]:
    """Normalize a branch_env_map value to a {platform: env} dict.

    Handles both forms:
      - String value: ``"DEV"`` → ``{p: "DEV" for p in release_platforms}``
      - Object value: ``{"ios": "DEV", "android": "DEV"}`` → returned as-is
        (filtered to only keys present in release_platforms).

    Args:
        branch_map_value: The value from branch_env_map for a specific branch
                          key.  Either a string or a dict.
        release_platforms: List of platform strings from the active release
                           (e.g. ["ios", "android"]).  Used to expand the
                           string form to all platforms.

    Returns:
        dict mapping platform → environment string.
        Empty dict if branch_map_value is neither a str nor a dict.

    Never raises.
    """
    if isinstance(branch_map_value, str):
        env = branch_map_value
        return {p: env for p in release_platforms}
    if isinstance(branch_map_value, dict):
        return {p: v for p, v in branch_map_value.items()
                if p in release_platforms and isinstance(v, str)}
    return {}


# ---------------------------------------------------------------------------
# TimePad config loader — XACA-0619-002
# ---------------------------------------------------------------------------
# Loads, validates, and caches kanban-hooks/timepad_config.json.
#
# Config file location (in priority order):
#   1. $AITEAMFORGE_TIMEPAD_CONFIG env var (override for tests)
#   2. ~/.aiteamforge/timepad_config.json  (runtime user copy)
#   3. <dev-team-root>/kanban-hooks/timepad_config.json  (source/fallback)
#
# The schema ships with all UUID fields set to the placeholder
# "<fetch-from-timepad.io>" — a valid-but-unconfigured marker.  The loader
# does NOT crash on placeholders; callers use timepad_team_has_placeholders()
# to distinguish configured from unconfigured teams.
#
# Security rules (never relax):
#   - tokenRef must be an env-var reference NAME only — never a raw token value.
#   - Any value that looks like a raw token (starts with "tp_", "sk-", or is
#     longer than 80 chars) is rejected.
#   - liquidstyle references in apiBaseUrl or tokenRef are hard-rejected
#     (hard cutover; these UUIDs are from a retired database).
# ---------------------------------------------------------------------------

_TIMEPAD_CONFIG_CACHE: dict | None = None
_TIMEPAD_CONFIG_PATH_AT_LOAD: str | None = None  # detect env-var changes

#: Placeholder string used in the shipped schema for unconfigured UUID fields.
TIMEPAD_PLACEHOLDER = "<fetch-from-timepad.io>"

#: UUID fields in each team block that may carry TIMEPAD_PLACEHOLDER.
_TIMEPAD_UUID_FIELDS = ("clientId", "projectId", "tagId")

#: Pattern fragments that look like raw token values — reject if found in tokenRef.
_TIMEPAD_RAW_TOKEN_PREFIXES = ("tp_", "sk-", "Bearer ", "token ", "apikey ")


def get_timepad_config_path() -> Path:
    """Return the path to timepad_config.json, honouring $AITEAMFORGE_TIMEPAD_CONFIG.

    Search order:
      1. $AITEAMFORGE_TIMEPAD_CONFIG env var (explicit override — tests use this)
      2. ~/.aiteamforge/timepad_config.json  (runtime user copy)
      3. <this-file's-dir>/timepad_config.json  (dev-team source fallback)
    """
    override = os.environ.get("AITEAMFORGE_TIMEPAD_CONFIG", "")
    if override:
        return Path(override).expanduser()
    user_copy = Path.home() / ".aiteamforge" / "timepad_config.json"
    if user_copy.exists():
        return user_copy
    # Fallback: sibling in kanban-hooks/ (dev-team source tree)
    return Path(__file__).parent / "timepad_config.json"


def _validate_timepad_team_block(team_slug: str, block: Any) -> list[str]:
    """Validate a single per-team block from timepad_config.json.

    Returns a list of error strings (empty = valid).  Does NOT raise.

    Validation rules:
      - block must be a dict
      - apiBaseUrl must be a non-empty string starting with "https://"
      - apiBaseUrl must NOT contain "liquidstyle" (hard cutover)
      - tokenRef must be a non-empty string
      - tokenRef must NOT start with a raw-token-looking prefix
      - tokenRef must NOT be longer than 80 chars (env-var names don't get that long)
      - tokenRef must NOT contain "liquidstyle"
      - UUID fields (clientId, projectId, tagId) must be strings
      - UUID fields may be the TIMEPAD_PLACEHOLDER sentinel (valid-but-unconfigured)

    Note: the `enabled` field is intentionally NOT validated here (XACA-0619-005).
    The enable gate lives in the board JSON at teamConfig.timepadSupport.enabled
    (single source of truth, mirrors crSupport pattern).  A stale `enabled` field
    in a config block is silently ignored — callers use is_timepad_enabled().
    """
    errors: list[str] = []
    if not isinstance(block, dict):
        errors.append(f"teams.{team_slug}: block must be a dict, got {type(block).__name__}")
        return errors  # can't check sub-fields if block isn't a dict

    # apiBaseUrl — must be non-empty https:// URL, no liquidstyle
    api_base = block.get("apiBaseUrl", "")
    if not isinstance(api_base, str) or not api_base:
        errors.append(f"teams.{team_slug}.apiBaseUrl: must be a non-empty string")
    elif not api_base.startswith("https://"):
        errors.append(
            f"teams.{team_slug}.apiBaseUrl: must start with 'https://', got {api_base!r}"
        )
    elif "liquidstyle" in api_base.lower():
        errors.append(
            f"teams.{team_slug}.apiBaseUrl: contains 'liquidstyle' — hard cutover; "
            "this is a retired host.  Update to 'https://timepad.io/api'."
        )

    # tokenRef — name reference only, never a raw token
    token_ref = block.get("tokenRef", "")
    if not isinstance(token_ref, str) or not token_ref:
        errors.append(f"teams.{team_slug}.tokenRef: must be a non-empty string")
    else:
        if "liquidstyle" in token_ref.lower():
            errors.append(
                f"teams.{team_slug}.tokenRef: contains 'liquidstyle' — "
                "stale credential reference.  Use TIMEPAD_API_KEY or "
                "TEAM_<CODE>_TIMEPAD_API_KEY."
            )
        for prefix in _TIMEPAD_RAW_TOKEN_PREFIXES:
            if token_ref.lower().startswith(prefix.lower()):
                errors.append(
                    f"teams.{team_slug}.tokenRef: looks like a raw token value "
                    f"(starts with {prefix!r}) — store only the env-var/vault key NAME"
                )
                break
        if len(token_ref) > 80:
            errors.append(
                f"teams.{team_slug}.tokenRef: suspiciously long ({len(token_ref)} chars) "
                "— env-var names don't exceed 80 chars; check if a raw token was stored"
            )

    # UUID fields — must be strings (placeholder or real)
    for field in _TIMEPAD_UUID_FIELDS:
        val = block.get(field)
        if not isinstance(val, str):
            errors.append(
                f"teams.{team_slug}.{field}: must be a string, "
                f"got {type(val).__name__!r} ({val!r})"
            )

    return errors


def load_timepad_config() -> dict:
    """Load, validate, and cache the TimePad per-team config.

    Returns the parsed dict from timepad_config.json.  On missing file, JSON
    parse errors, or hard validation failures the error is printed to stderr and
    an empty-teams dict ``{"_schemaVersion": 1, "teams": {}}`` is returned so
    callers degrade gracefully.

    Soft validation failures (individual team block errors) are printed to
    stderr but do NOT prevent the config from loading — the offending team
    block is left in the result so callers can inspect it.  Callers that need
    a clean team block should check the validation errors via
    ``validate_timepad_config(config)``.

    Caching: result is cached until ``bust_timepad_config_cache()`` is called
    or ``$AITEAMFORGE_TIMEPAD_CONFIG`` changes between calls (test-isolation).

    Never raises.
    """
    global _TIMEPAD_CONFIG_CACHE, _TIMEPAD_CONFIG_PATH_AT_LOAD

    config_path = get_timepad_config_path()
    config_path_str = str(config_path)

    # Re-load if env var changed (important for tests)
    if _TIMEPAD_CONFIG_CACHE is not None and _TIMEPAD_CONFIG_PATH_AT_LOAD == config_path_str:
        return _TIMEPAD_CONFIG_CACHE

    _empty: dict = {"_schemaVersion": 1, "teams": {}}

    if not config_path.exists():
        print(
            f"[aiteamforge-paths] WARNING: timepad_config.json not found at {config_path} "
            "— TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    try:
        raw = config_path.read_text(encoding="utf-8")
        config = json.loads(raw)
    except (json.JSONDecodeError, OSError) as exc:
        print(
            f"[aiteamforge-paths] WARNING: could not parse timepad_config.json "
            f"at {config_path}: {exc} — TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    if not isinstance(config, dict):
        print(
            f"[aiteamforge-paths] WARNING: timepad_config.json root must be a dict — "
            "TimePad integration unavailable",
            file=sys.stderr,
        )
        _TIMEPAD_CONFIG_CACHE = _empty
        _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
        return _TIMEPAD_CONFIG_CACHE

    # Run per-team validation — emit warnings but don't discard the config.
    errors = validate_timepad_config(config)
    for err in errors:
        print(f"[aiteamforge-paths] TIMEPAD CONFIG WARNING: {err}", file=sys.stderr)

    _TIMEPAD_CONFIG_CACHE = config
    _TIMEPAD_CONFIG_PATH_AT_LOAD = config_path_str
    return _TIMEPAD_CONFIG_CACHE


def validate_timepad_config(config: dict) -> list[str]:
    """Validate all team blocks in a parsed timepad_config.json dict.

    Returns a list of error strings (empty = all clean).  Suitable for use in
    tests and for callers that want to surface validation errors explicitly.

    Does NOT check whether UUID fields are still placeholders — that's a
    "not yet configured" state, not an error.  Use timepad_team_has_placeholders()
    for that check.

    Args:
        config: Parsed dict from timepad_config.json (not a file path).

    Returns:
        List of human-readable error strings.  Empty list = config is valid.
    """
    errors: list[str] = []
    teams = config.get("teams", {})
    if not isinstance(teams, dict):
        errors.append("'teams' must be a dict")
        return errors
    for slug, block in teams.items():
        errors.extend(_validate_timepad_team_block(slug, block))
    return errors


def get_timepad_team_config_raw(team_slug: str) -> dict:
    """Return the raw config block for a team from timepad_config.json.

    Returns an empty dict if the team is not present or the config failed to load.
    Does not raise.

    This is the low-level accessor.  Sibling 005 (accessor API) wraps this with
    board-JSON enable-flag merging.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        Per-team config dict, or {} if absent.
    """
    config = load_timepad_config()
    return config.get("teams", {}).get(team_slug, {})


def timepad_team_has_placeholders(team_slug: str) -> bool:
    """Return True iff any UUID field for the team still holds the placeholder sentinel.

    A placeholder indicates the team is valid-but-unconfigured — the UUIDs must
    be fetched from timepad.io before TimePad operations will work.

    Returns True also when the team block is absent (treat as unconfigured).

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        True if any of clientId / projectId / tagId equals TIMEPAD_PLACEHOLDER,
        or if the team block is missing; False if all three are set to non-placeholder
        strings.
    """
    block = get_timepad_team_config_raw(team_slug)
    if not block:
        return True  # absent = unconfigured
    return any(
        block.get(field) == TIMEPAD_PLACEHOLDER
        for field in _TIMEPAD_UUID_FIELDS
    )


def bust_timepad_config_cache() -> None:
    """Invalidate the TimePad config cache.

    The next call to load_timepad_config() will re-read from disk.
    Intended for use in tests and for callers that write a new config to disk
    and need the cache to reflect the new content immediately.
    """
    global _TIMEPAD_CONFIG_CACHE, _TIMEPAD_CONFIG_PATH_AT_LOAD
    _TIMEPAD_CONFIG_CACHE = None
    _TIMEPAD_CONFIG_PATH_AT_LOAD = None


# ---------------------------------------------------------------------------
# Public accessor API (XACA-0619-005) — consumed by hooks + LCARS
# ---------------------------------------------------------------------------
# Design decision (locked by Opus lead, XACA-0619-005):
#   - get_timepad_team_config() returns only the *connection* config block from
#     timepad_config.json (apiBaseUrl, tokenRef, clientId, projectId, tagId).
#     It does NOT merge the enabled flag — config (connection) and enabled (gate)
#     are intentionally separate.
#   - is_timepad_enabled() reads the *gate* from the board JSON at
#     teamConfig.timepadSupport.enabled (single source of truth, mirrors crSupport).
#   - Consumers call both when they need to check if integration is active.
#
# This separation prevents drift: the board JSON toggle is the only place to
# flip the feature on or off; the config JSON is connection-only config.


def get_timepad_team_config(team_slug: str) -> dict:
    """Return the connection config block for a team from timepad_config.json.

    Public accessor for hook + LCARS consumers (XACA-0619-005).  Wraps
    ``get_timepad_team_config_raw()`` with an explicit public contract.

    Returns the dict with fields: apiBaseUrl, tokenRef, clientId, projectId,
    tagId.  Returns an empty dict when the team is absent or config failed to
    load.

    NOTE: This dict does NOT contain an ``enabled`` flag.  The enable gate lives
    in the board JSON at ``teamConfig.timepadSupport.enabled`` and is read by
    ``is_timepad_enabled()``.  Keep config (connection) and enabled (gate)
    separate — callers that need both call each function independently.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        Per-team connection config dict, or {} if absent / load failure.
    """
    return get_timepad_team_config_raw(team_slug)


def is_timepad_enabled(team_slug: str) -> bool:
    """Return True iff TimePad is enabled for the given team.

    Reads ``teamConfig.timepadSupport.enabled`` from the team's board JSON
    (``<kanban_dir>/<team>-board.json``).  This is the single source of truth
    for the enable/disable gate, mirroring the ``teamConfig.crSupport.enabled``
    pattern already used by the CR workflow.

    Key path: board_data["teamConfig"]["timepadSupport"]["enabled"]
    Default:  False (disabled) at every level of the chain.

    The ``enabled`` field that previously existed in ``timepad_config.json`` has
    been removed (XACA-0619-005) to eliminate the duplicate source.  This
    function is the only place that reads the gate.

    Args:
        team_slug: Canonical team slug (e.g. "academy", "mainevent").

    Returns:
        True if the board JSON declares timepadSupport.enabled = true,
        False in all other cases (key absent, board missing, parse error, etc.).
    """
    try:
        kanban_dir = get_team_kanban_dir(team_slug)
        board_file = kanban_dir / f"{team_slug}-board.json"
        if not board_file.exists():
            return False
        board_data = json.loads(board_file.read_text(encoding="utf-8"))
        # Mirror the server.py pattern (XACA-0333-006):
        #   board_data.get('teamConfig') or {}  — guards against explicit null
        team_config = board_data.get("teamConfig") or {}
        return bool(
            team_config.get("timepadSupport", {}).get("enabled", False)
        )
    except Exception:
        return False  # safe default — disabled


def wizard_hook_create_config(teams_dict: dict, force: bool = False) -> bool:
    """Create or overwrite the config file with the provided teams_dict.

    Called by the interactive setup wizard (XACA-0168-002) after collecting
    team paths from the user.

    Args:
        teams_dict: dict mapping team IDs to {"kanban_dir", "working_dir",
                    "lcars_port"} entries.
        force:      If True, overwrite an existing config file.

    Returns:
        True on success, False on failure.
    """
    global _CONFIG_CACHE, _CONFIG_PATH_AT_LOAD

    config_path = get_config_path()
    if config_path.exists() and not force:
        print(
            f"[aiteamforge-paths] Config already exists at {config_path}. "
            "Pass force=True to overwrite.",
            file=sys.stderr,
        )
        return False

    config = {
        "schema_version": SUPPORTED_SCHEMA_VERSION,
        "teams": teams_dict,
    }
    try:
        # XACA-1059 (PR #817 review round): check the write-side plausibility
        # floor BEFORE the quarantine step below — see _write_defaults's
        # docstring for why the ordering matters (quarantine MOVES the
        # existing registry aside; a refusal that only fired after that step
        # would leave the registry ABSENT instead of untouched). Measured
        # reachable here: an empty teams_dict serializes to 40 bytes, a
        # single small team to 135 — both under the floor, and force=True
        # makes this reachable against an already-populated live registry.
        _reject_if_below_write_floor(config, resolved=config_path)
        config_path.parent.mkdir(parents=True, exist_ok=True)
        # XACA-1029-003/-005: quarantine (MOVE, never read+copy) whatever
        # exists before overwriting, then write atomically. See
        # _quarantine_or_snapshot_existing's docstring for why a move is
        # required rather than the old read+write_bytes copy.
        _quarantine_or_snapshot_existing(
            config_path, tag="pre-wizard-overwrite", label="wizard_hook_create_config"
        )
        _atomic_write_json(config_path, config)
        # Invalidate cache so the next load_config() re-reads the file
        _CONFIG_CACHE = None
        _CONFIG_PATH_AT_LOAD = None
        return True
    except (OSError, ValueError) as exc:
        print(
            f"[aiteamforge-paths] ERROR: could not write config: {exc}",
            file=sys.stderr,
        )
        return False
