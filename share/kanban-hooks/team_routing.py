#!/usr/bin/env python3
"""team_routing.py: does the routing map place a team on ANOTHER machine? (XACA-1857)

~/.aiteamforge/team-machines.json maps <team> -> <machine-slug>. kb-msg-provision
writes it, and Tier-2 kb-msg uses it to pick a destination. Before XACA-1857 two
other consumers never read it:

  * kb-msg send's Tier-1 gate delivered LOCALLY whenever the target team had a
    live tmux session on the sending machine. A stray `academy-lcars` session on
    M4Mini therefore swallowed academy mail meant for ai-sol, and the sender saw
    a success line.
  * lcars-health-check.sh's XACA-1063 host gate fails open on an absent
    primary_host, so it restarted academy on M4Mini (creating that stray
    session) although this map said academy -> ai-sol.

This module is the one place that answers the question for all three callers
(kb-msg send, the health gate, ensure_lcars_tmux_session), so they cannot drift.

FAIL-OPEN CONTRACT: "elsewhere" is reported ONLY on positive evidence. A
missing, unreadable or malformed map, a missing or non-string entry, or an entry
naming ANY identity this machine answers to, all report "not elsewhere".
Callers then keep their pre-XACA-1857 behaviour. This can only ever SUBTRACT a
local delivery or a restart. It never adds one.

THIS MACHINE'S IDENTITIES (a union, so a local team is never misjudged foreign):
  $AITEAMFORGE_MACHINE_ID (kb-msg-provision's override), and the slug of
  socket.gethostname(), plus the slug of each extra name passed with --also
  (the shell callers pass `hostname -s`, `scutil --get ComputerName` and
  `scutil --get LocalHostName`). The slug rule mirrors
  fleet-monitor/client/vault-keygen.js defaultMachineSlug(), which is what
  kb-msg-provision records for this machine's own teams.
  XACA-1688 adds two more, so a hostname rename never makes a machine's own
  teams look foreign: the pinned slug in ~/.aiteamforge/machine-slug, and every
  `hostname` + `aliases` of the config/fleet-systems.json machine that any of the
  identities above already names (registry: $FLEET_SYSTEMS_FILE, else
  <this dir>/../config/fleet-systems.json, else
  ${AITEAMFORGE_DIR:-~/aiteamforge}/config/fleet-systems.json).

CLI:
  team_routing.py owner-elsewhere <team> [--map PATH] [--also NAME ...]
      exit 0 and print the owning slug when the map names another machine;
      exit 1 (prints nothing) otherwise.
  team_routing.py owners-elsewhere <team>... [--map PATH] [--also NAME ...]
      batch form for the 120s health sweep (one fork, not one per team):
      prints "<team> <slug>" for each team the map places elsewhere; exit 0.
  team_routing.py hygiene [--map PATH] [--registry PATH] [--mail-dir DIR]
                          [--also NAME ...]
      REPORT-ONLY consistency findings for `kb-msg doctor` (XACA-1857 fix B),
      one per line, tab-separated "<kind>\\t<team>\\t<detail>". It never writes,
      moves or deletes anything. Kinds:
        stranded-mail        unread mail stored HERE for a team mapped elsewhere
        stranded-broadcasts  broadcast ledger HERE for a team mapped elsewhere
        registry-no-owner    team-paths entry with no primary_host, map says elsewhere
        registry-no-board    team-paths entry whose kanban_dir has no <team>-board.json
      lcars-ports/<team>-* files are deliberately NOT checked: lcars-ports/ is the
      git-tracked FLEET-WIDE port map, so every machine holds every team's files.
      exit 0 always (an unreadable input is simply not reported on).
"""

import argparse
import json
import os
import re
import socket
import sys

MAX_SLUG_LEN = 64  # vault-keygen.js MAX_SLUG_LEN


def default_map_path():
    # $AITEAMFORGE_TEAM_MACHINES redirects the map, so a test suite never reads
    # the live ~/.aiteamforge/team-machines.json of whatever box runs it.
    override = os.environ.get("AITEAMFORGE_TEAM_MACHINES", "").strip()
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".aiteamforge", "team-machines.json")


def machine_slug(name):
    """Port of vault-keygen.js defaultMachineSlug(). Returns "" for an empty name."""
    raw = (name or "").strip().lower()
    if not raw:
        return ""
    slug = re.sub(r"\.local$", "", raw)
    slug = re.sub(r"\..*$", "", slug)
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = slug.strip("-")[:MAX_SLUG_LEN]
    if not slug or not re.match(r"^[a-z]", slug):
        slug = ("m-" + slug).rstrip("-")[:MAX_SLUG_LEN]
    return slug


def pinned_slug():
    """First line of ~/.aiteamforge/machine-slug, slugified, or "" (XACA-1688)."""
    try:
        with open(os.path.join(os.path.expanduser("~"), ".aiteamforge", "machine-slug")) as fh:
            return machine_slug(fh.readline())
    except OSError:
        return ""


def registry_path():
    override = os.environ.get("FLEET_SYSTEMS_FILE", "").strip()
    if override:
        return override
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "fleet-systems.json")
    if os.path.isfile(here):
        return here
    base = os.environ.get("AITEAMFORGE_DIR") or os.path.join(os.path.expanduser("~"), "aiteamforge")
    return os.path.join(base, "config", "fleet-systems.json")


def registry_aliases(ids, path=None):
    """Every hostname + alias slug of each registry machine that one of `ids` names.

    XACA-1688 compatibility window: after darren-m4-mini is renamed ai-vulcan, the
    registry row {hostname: ai-vulcan, aliases: [darren-m4-mini]} makes a map entry
    that still says darren-m4-mini count as THIS machine. An unreadable or
    wrong-shape registry adds nothing (fail-open, like the map)."""
    try:
        with open(path or registry_path()) as fh:
            machines = json.load(fh).get("machines")
    except (OSError, ValueError, AttributeError):
        return set()
    out = set()
    for m in machines if isinstance(machines, list) else []:
        if not isinstance(m, dict):
            continue
        raw = [m.get("hostname")] + list(m.get("aliases") or [])
        names = {machine_slug(n) for n in raw if isinstance(n, str)} - {""}
        if names & ids:
            out |= names
    return out


def this_machine_ids(also=()):
    ids = set()
    env_id = os.environ.get("AITEAMFORGE_MACHINE_ID", "").strip()
    if env_id:
        ids.add(env_id.lower())
    pin = pinned_slug()
    if pin:
        ids.add(pin)
    names = [socket.gethostname()] + list(also or ())
    for n in names:
        s = machine_slug(n)
        if s:
            ids.add(s)
    return ids | registry_aliases(ids)


def mapped_owner(team, map_path=None):
    """The map's slug for <team>, or None when absent/unreadable/malformed."""
    data = _load_json(map_path or default_map_path())
    if not isinstance(data, dict):
        return None
    owner = data.get(team)
    if not isinstance(owner, str) or not owner.strip():
        return None
    return owner.strip()


def owner_elsewhere(team, map_path=None, also=()):
    """The owning slug when the map positively places <team> on another machine, else None."""
    if not team:
        return None
    owner = mapped_owner(team, map_path)
    if owner is None:
        return None
    ids = this_machine_ids(also)
    if not ids:
        # Cannot say who THIS machine is, so cannot claim anything is foreign.
        return None
    if owner.lower() in ids or machine_slug(owner) in ids:
        return None
    return owner


# ---------------------------------------------------------------------------
# hygiene (XACA-1857 fix B): report-only consistency findings
# ---------------------------------------------------------------------------

_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]")  # msg-store.py's _safe_token rule


def _safe_token(token):
    return _SAFE_RE.sub("_", token or "")


def _load_json(path):
    # RecursionError: a pathologically nested file must read as "unreadable",
    # never crash the caller (XACA-1857 test gate). ValueError covers both
    # bad JSON and UnicodeDecodeError.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError, RecursionError):
        return None


def _jsonl_records(path):
    # errors="replace": one non-UTF-8 byte in one mailbox must not crash the
    # whole hygiene pass and hide every other team's stranded mail behind a
    # [??] row (XACA-1857 test gate). A bad line is skipped, not fatal.
    out = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, RecursionError):
                    continue
                if isinstance(obj, dict):
                    out.append(obj)
    except OSError:
        pass
    return out


def default_registry_path():
    override = os.environ.get("AITEAMFORGE_CONFIG", "").strip()
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".aiteamforge", "team-paths.json")


def default_mail_dir():
    return os.path.join(os.path.expanduser("~"), ".aiteamforge", "mail")


def _elsewhere_map(map_path, also):
    """{team: owner} for every map entry that names another machine."""
    data = _load_json(map_path or default_map_path())
    if not isinstance(data, dict):
        return {}
    ids = this_machine_ids(also)
    if not ids:
        return {}
    out = {}
    for team, owner in data.items():
        if not team or not isinstance(owner, str) or not owner.strip():
            continue
        owner = owner.strip()
        if owner.lower() in ids or machine_slug(owner) in ids:
            continue
        out[team] = owner
    return out


def hygiene(map_path=None, registry_path=None, mail_dir=None, also=()):
    """List of (kind, team, detail). Reads only."""
    findings = []
    elsewhere = _elsewhere_map(map_path, also)
    by_token = {_safe_token(t): t for t in elsewhere}

    # 1. Mail stored here for a team the map places elsewhere.
    mail_dir = mail_dir or default_mail_dir()
    try:
        names = sorted(os.listdir(mail_dir))
    except OSError:
        names = []
    for name in names:
        path = os.path.join(mail_dir, name)
        if name.endswith(".broadcasts.jsonl"):
            team = by_token.get(name[: -len(".broadcasts.jsonl")])
            if team:
                n = len(_jsonl_records(path))
                if n:
                    findings.append(("stranded-broadcasts", team,
                                     "%d broadcast record(s) in %s, but the map places '%s' on '%s'"
                                     % (n, path, team, elsewhere[team])))
            continue
        if not name.endswith(".jsonl") or "__" not in name:
            continue
        tok, _, rest = name[: -len(".jsonl")].partition("__")
        team = by_token.get(tok)
        if not team:
            continue
        recs = _jsonl_records(path)
        unread = [r for r in recs if not r.get("read_at")]
        if unread:
            ids = ", ".join(str(r.get("id", "?"))[:8] for r in unread[:5])
            more = "" if len(unread) <= 5 else ", +%d more" % (len(unread) - 5)
            findings.append(("stranded-mail", team,
                             "%d unread for %s:%s in %s (ids %s%s), but the map places '%s' on '%s'"
                             % (len(unread), team, rest, path, ids, more, team, elsewhere[team])))

    # 2. Registry entries that contradict the map, or point at no board.
    reg = _load_json(registry_path or default_registry_path())
    teams = reg.get("teams") if isinstance(reg, dict) else None
    if isinstance(teams, dict):
        for team in sorted(teams):
            entry = teams[team]
            if not isinstance(entry, dict):
                continue
            ph = entry.get("primary_host")
            if (not isinstance(ph, str) or not ph.strip()) and team in elsewhere:
                findings.append(("registry-no-owner", team,
                                 "team-paths entry has no primary_host, but the map places '%s' on '%s'; "
                                 "set primary_host to '%s' or remove the stale entry"
                                 % (team, elsewhere[team], elsewhere[team])))
            kd = entry.get("kanban_dir")
            if isinstance(kd, str) and kd.strip():
                board = os.path.join(os.path.expanduser(kd), "%s-board.json" % team)
                if not os.path.isfile(board):
                    findings.append(("registry-no-board", team,
                                     "kanban_dir %s has no %s-board.json; the entry may be stale" % (kd, team)))

    return findings


def main(argv=None):
    ap = argparse.ArgumentParser(prog="team_routing.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    oe = sub.add_parser("owner-elsewhere", help="exit 0 + print slug if the map places TEAM on another machine")
    oe.add_argument("team")
    oe.add_argument("--map", default=None, help="routing map path (default ~/.aiteamforge/team-machines.json)")
    oe.add_argument("--also", action="append", default=[], help="another name this machine answers to (repeatable)")
    oes = sub.add_parser("owners-elsewhere", help='print "<team> <slug>" for each TEAM the map places elsewhere')
    oes.add_argument("teams", nargs="*")
    oes.add_argument("--map", default=None)
    oes.add_argument("--also", action="append", default=[])
    hy = sub.add_parser("hygiene", help="report-only routing/registry consistency findings")
    hy.add_argument("--map", default=None)
    hy.add_argument("--registry", default=None)
    hy.add_argument("--mail-dir", dest="mail_dir", default=None)
    hy.add_argument("--also", action="append", default=[])
    args = ap.parse_args(argv)

    if args.cmd == "owner-elsewhere":
        owner = owner_elsewhere(args.team, args.map, args.also)
        if owner is None:
            return 1
        print(owner)
        return 0
    if args.cmd == "owners-elsewhere":
        for team in args.teams:
            owner = owner_elsewhere(team, args.map, args.also)
            if owner is not None:
                print("%s %s" % (team, owner))
        return 0
    if args.cmd == "hygiene":
        for kind, team, detail in hygiene(args.map, args.registry, args.mail_dir, args.also):
            print("%s\t%s\t%s" % (kind, team, detail.replace("\t", " ").replace("\n", " ")))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
