#!/usr/bin/env python3
"""Quick one-off releases: `kb-quick <ITEM-ID>` (XACA-1989).

A quick release is an ordinary type:hotfix release that carries ONE item. It is cut from production
(`hotfix/<ver>`, release_branches._branch_spec), worked by the normal single-ticket `kb-run <ID>` worker, then
shipped by the normal DEV stage tests and `kb-release close-out` (tag, merge production, back-merge integration,
gated promote to PROD). This module never writes the board or git. It holds only the PURE decisions that
kanban-helpers.sh `kb-quick` acts on through the existing kb-release commands:

  check-start   may this item start a quick release? (refusal code + remedy, or the name to create / release to resume)
  status        the derived phase of a quick release (from stage / status / closeOut / the item; nothing is stored)
  check-cancel  may this quick release be cancelled, and where does its item go back to?
  resolve       a REL-ID or ITEM-ID -> the quick release id
  list-open     the ids of every quick release still in flight (derived phase not closed/cancelled)

Bookkeeping lives in release TAGS, because PUT /api/releases/<id> accepts no new keys (spike, XACA-1989-001):
  quick                    marks the release as a quick release
  quick-item:<ITEM-ID>     the one item it carries
  quick-from:<REL-ID>      the item's release before kb-quick moved it ("none" when it had none)

Version: the server already allocates hotfix = last shipped + patch, skipping every open release's version, under the
board write lock (server.py _resolve_default_release_version). kb-quick passes no version. Only the -QF<n> short title
is allocated here; the shell holds a lock around check-start + create so two concurrent calls never pick the same n.

Exit codes (CLI): 0 ok (JSON on stdout) | 2 usage | 3 refused (JSON with code/reason/remedy) | 4 not found.
Stdlib only, python 3.9 compatible.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_branches  # noqa: E402
from orchestrator_state import resolve_item_status  # noqa: E402
from release_schema import is_terminal_release_status  # noqa: E402

TAG = "quick"
ITEM_TAG = "quick-item:"
FROM_TAG = "quick-from:"
NO_FROM = "none"
# An item kb-quick may START from. Anything already in flight, finished or blocked is refused (NOT_TODO).
STARTABLE = ("todo", "backlog", "ready", "planned")
_ID = re.compile(r"[A-Z][A-Z0-9]*-[0-9]+")
_REL = re.compile(r"REL-[A-Za-z0-9-]+")
NAME_TITLE_MAX = 60

RC_OK, RC_USAGE, RC_REFUSED, RC_NOT_FOUND = 0, 2, 3, 4


class Refusal(Exception):
    def __init__(self, code, reason, remedy, rc=RC_REFUSED, **extra):
        super().__init__(reason)
        self.code, self.reason, self.remedy, self.rc, self.extra = code, reason, remedy, rc, extra

    def as_dict(self):
        return dict({"ok": False, "code": self.code, "reason": self.reason, "remedy": self.remedy}, **self.extra)


# ---------------------------------------------------------------------------------------------------------------------
# board readers
# ---------------------------------------------------------------------------------------------------------------------
_SHA40 = re.compile(r"[0-9a-f]{40}")

def releases(board):
    return [r for r in (board.get("releases") or []) if isinstance(r, dict)]


def release_by_id(board, rid):
    return next((r for r in releases(board) if r.get("id") == rid), None)


def item_by_id(board, item_id):
    return next((i for i in (board.get("backlog") or []) if isinstance(i, dict) and i.get("id") == item_id), None)


def is_open(release):
    # The shared terminal set (release_schema, XACA-1859): a quick release retired or archived by kb-release
    # is finished, not open, so it never blocks a new kb-quick for its item.
    return not is_terminal_release_status(release.get("status"))


def quick_info(release):
    """{"item": ID|None, "from": REL-ID|None} for a quick release, else None. "quick-from:none" -> from None."""
    tags = [t for t in (release.get("tags") or []) if isinstance(t, str)]
    if TAG not in tags:
        return None
    item = next((t[len(ITEM_TAG):] for t in tags if t.startswith(ITEM_TAG)), None)
    frm = next((t[len(FROM_TAG):] for t in tags if t.startswith(FROM_TAG)), None)
    return {"item": item or None, "from": None if frm in (None, "", NO_FROM) else frm}


def quick_tags(item_id, from_rel):
    return [TAG, ITEM_TAG + item_id, FROM_TAG + (from_rel or NO_FROM)]


def quick_in_flight(board, release):
    """True for a quick release whose derived phase is not closed/cancelled. Every quick-release "is it still open?"
    question (the listing and kb-quick start) asks this, so they agree with the status line; is_open stays for
    ordinary releases (the DEV train, a cancel's origin)."""
    return quick_info(release) is not None and phase(board, release) not in ("closed", "cancelled")


def open_quick_for_item(board, item_id):
    """The open quick release carrying item_id, else None (the newest when, against the rules, there are several)."""
    hits = [r for r in releases(board)
            if quick_in_flight(board, r) and (quick_info(r) or {}).get("item") == item_id]
    return sorted(hits, key=lambda r: r.get("createdAt") or "")[-1] if hits else None


def _dev_entered(release):
    st = ((release.get("stages") or {}).get("DEV") or {})
    return st.get("enteredAt") or release.get("createdAt") or ""


def current_train(board, fallback_release=None):
    """The short title quick releases are named after: the open, non-hotfix, non-batch release at DEV (the newest DEV
    entry when there are several), else the item's own release, else "Q"."""
    devs = [r for r in releases(board)
            if is_open(r) and r.get("stage") == "DEV" and r.get("type") != "hotfix" and r.get("kind") != "batch"
            and quick_info(r) is None and (r.get("shortTitle") or "").strip()]
    if devs:
        return sorted(devs, key=_dev_entered)[-1]["shortTitle"].strip()
    if fallback_release and (fallback_release.get("shortTitle") or "").strip():
        return fallback_release["shortTitle"].strip()
    return "Q"


def next_short_title(board, train, archived=()):
    """<train>-QF<n>, n = 1 + the highest n any release (open, closed or archived) already uses for this train."""
    pat = re.compile(r"%s-QF([0-9]+)" % re.escape(train))
    used = [int(m.group(1)) for r in list(releases(board)) + [a for a in archived if isinstance(a, dict)]
            for m in [pat.fullmatch((r.get("shortTitle") or "").strip())] if m]
    return "%s-QF%d" % (train, (max(used) if used else 0) + 1)


def release_name(board, short_title, date, title):
    team = (board.get("team") or "").strip().title()   # "Academy R02a-HF1 ..." (the 079 precedent), not teamName
    t = (title or "").strip()
    for prefix in ("Feature:", "Bugfix:", "Fix:", "Chore:", "Hotfix:"):
        if t.startswith(prefix):
            t = t[len(prefix):].strip()
    if len(t) > NAME_TITLE_MAX:
        t = t[:NAME_TITLE_MAX - 3].rstrip() + "..."
    return " ".join(x for x in (team, short_title, date, "-", t) if x)


def item_platform(board, item, from_release):
    """The platform the quick release declares: the item's assignment platform, else the original release's sole
    platform, else "other"."""
    p = ((item.get("releaseAssignment") or {}).get("platform") or "").strip().lower()
    if p:
        return p
    plats = list(((from_release or {}).get("platforms") or {}).keys())
    return plats[0] if len(plats) == 1 else "other"


def branch_refusal(board):
    """The engine's own hotfix refusals (release_branches._branch_spec), checked up front so nothing is created first."""
    try:
        cfg = release_branches.effective_branches(board.get("releaseConfig"))
    except ValueError as e:
        raise Refusal("BRANCH_CONFIG", "releaseConfig.branches is invalid: %s" % e,
                      "fix it with: kb-release branches set ... (see kb-release branches --help)")
    try:
        release_branches._branch_spec(cfg, "hotfix")
    except RuntimeError as e:
        mode = cfg.get("mode")
        remedy = ("client-merge boards cannot run a quick release; assign the item to a release that has a branch "
                  "(kb-release assign <ID> <REL-ID>)" if mode == "client-merge" else
                  "give the board a separate production branch (kb-release branches set production <branch>), or "
                  "assign the item to a release that has a branch")
        raise Refusal("HOTFIX_REFUSED_BY_MODE", str(e), remedy, mode=mode)
    return cfg


def live_subitems(item):
    return [s for s in (item.get("subitems") or []) if isinstance(s, dict) and s.get("status") != "cancelled"]


# ---------------------------------------------------------------------------------------------------------------------
# decisions
# ---------------------------------------------------------------------------------------------------------------------
def phase(board, release):
    """Derived phase of a quick release: cancelled | closed | closing | created | dev | merged."""
    status = (release.get("status") or "").strip().lower()
    if status == "cancelled":
        return "cancelled"
    if is_terminal_release_status(status) or release.get("stage") == "PROD":
        return "closed"   # released, or finished another way (completed/closed/archived/retired)
    if isinstance(release.get("closeOut"), dict):
        return "closing"
    if release.get("stage") in (None, "", "PLANNED") or not release.get("branch"):
        return "created"
    item = item_by_id(board, (quick_info(release) or {}).get("item") or "")
    if item is not None and resolve_item_status(item) == "completed":
        return "merged"
    return "dev"


NEXT = {
    "created": "kb-quick start {item}   (resumes: promotes {rel} to DEV, which cuts its hotfix branch)",
    "dev": "work the item: kb-run {item}   (then: kb-quick finish {rel})",
    "merged": "kb-quick finish {rel}   (DEV build + tests, one confirmation, close-out to PROD)",
    "closing": "kb-quick finish {rel}   (resumes the close-out at its first incomplete step)",
    "closed": "nothing: {rel} is finished (released or retired)",
    "cancelled": "nothing: {rel} was cancelled",
}


def list_open(board):
    """Ids of the quick releases in flight (quick_in_flight), in board order. The shell lists through this, never
    its own status set, so the listing agrees with the status line (stage PROD with a non-terminal status is closed)."""
    return [r.get("id") for r in releases(board) if r.get("id") and quick_in_flight(board, r)]


def status(board, rid):
    rel = release_by_id(board, rid)
    if rel is None:
        raise Refusal("RELEASE_NOT_FOUND", "release %s is not on this board" % rid, "kb-release list", rc=RC_NOT_FOUND)
    q = quick_info(rel)
    if q is None:
        raise Refusal("NOT_QUICK", "%s is not a quick release (no 'quick' tag)" % rid,
                      "use kb-release show %s / kb-run %s for an ordinary release" % (rid, rid))
    ph = phase(board, rel)
    item = item_by_id(board, q["item"] or "")
    return {"ok": True, "release": rid, "shortTitle": rel.get("shortTitle"), "item": q["item"], "from": q["from"],
            "phase": ph, "stage": rel.get("stage"), "status": rel.get("status"), "branch": rel.get("branch"),
            # closed covers every terminal status; shipped says whether it actually reached production
            "shipped": ph == "closed" and (rel.get("stage") == "PROD"
                                           or (rel.get("status") or "").strip().lower() == "released"),
            "branchBaseSha": rel.get("branchBaseSha"), "version": _version(rel),
            "itemStatus": resolve_item_status(item) if item is not None else None,
            "next": NEXT[ph].format(item=q["item"], rel=rid)}


def _version(rel):
    vs = sorted({str(p["version"]) for p in (rel.get("platforms") or {}).values()
                 if isinstance(p, dict) and p.get("version") is not None})
    return vs[0] if len(vs) == 1 else (", ".join(vs) if vs else None)


def check_start(board, item_id, date="", archived=()):
    """-> {"ok": True, "action": "create"|"resume", ...}. Raises Refusal."""
    if not _ID.fullmatch(item_id or ""):
        raise Refusal("USAGE", "not an item id: %r" % item_id, "kb-quick start <ITEM-ID>", rc=RC_USAGE)
    item = item_by_id(board, item_id)
    if item is None:
        raise Refusal("ITEM_NOT_FOUND", "%s is not on this board" % item_id, "kb-backlog list", rc=RC_NOT_FOUND)
    st = resolve_item_status(item)
    existing = open_quick_for_item(board, item_id)
    if existing is not None:
        # One item, one open quick release. A second create is refused; the SAME one resumes while there is still
        # something for `start` to do (promote, or hand the not-yet-finished item to its worker).
        ph = phase(board, existing)
        if ph in ("created", "dev") and st not in ("completed", "cancelled"):
            return {"ok": True, "action": "resume", "release": existing["id"], "phase": ph, "item": item_id,
                    "shortTitle": existing.get("shortTitle"), "from": (quick_info(existing) or {}).get("from")}
        raise Refusal("ALREADY_QUICK", "%s is already in open quick release %s (phase %s)" % (item_id, existing["id"], ph),
                      NEXT[ph].format(item=item_id, rel=existing["id"]), release=existing["id"], phase=ph)
    branch_refusal(board)
    if st not in STARTABLE:
        raise Refusal("NOT_TODO", "%s is %s; kb-quick starts only an item that has not started" % (item_id, st),
                      "finish it in its current release (kb-run %s), or reset it to todo first" % item_id,
                      itemStatus=st)
    if not live_subitems(item):
        raise Refusal("UNPLANNED", "%s has no subitems (it is not planned)" % item_id,
                      "plan it first: /plan-project %s" % item_id)
    from_rid = ((item.get("releaseAssignment") or {}).get("releaseId") or "").strip() or None
    from_rel = release_by_id(board, from_rid) if from_rid else None
    if from_rel is not None and quick_info(from_rel) is not None:
        # Its current release is a closed quick release (an open one was handled above): send a cancel back to where
        # that one came from, never into a closed release.
        from_rid = quick_info(from_rel)["from"]
        from_rel = release_by_id(board, from_rid) if from_rid else None
    train = current_train(board, from_rel)
    short = next_short_title(board, train, archived)
    return {"ok": True, "action": "create", "item": item_id, "from": from_rid, "train": train, "shortTitle": short,
            "name": release_name(board, short, date, item.get("title")),
            "platform": item_platform(board, item, from_rel), "tags": quick_tags(item_id, from_rid),
            "fromHasBranch": bool(from_rel and from_rel.get("branch") and is_open(from_rel))}


def check_cancel(board, rid, branch_tip=""):
    """-> {"ok": True, "release", "item", "from", "branch", "branchBaseSha", "restoreTo"}. Raises Refusal.
    branch_tip = the remote hotfix branch tip the shell read ("" = not read). Refused once anything landed on the
    branch (cancelling then would strand a merged change outside every release), and FAIL CLOSED when a branch is
    recorded but its base or tip is unknown (BRANCH_UNVERIFIABLE)."""
    st = status(board, rid)   # raises for unknown / not quick
    rel = release_by_id(board, rid) or {}
    if st["phase"] in ("closed", "cancelled"):
        raise Refusal("ALREADY_CLOSED", "%s is already %s" % (rid, st["phase"]), "nothing to cancel")
    if st["phase"] == "closing":
        raise Refusal("CLOSE_OUT_STARTED", "%s has started its close-out; it can only be finished" % rid,
                      "kb-quick finish %s" % rid)
    item = item_by_id(board, st["item"] or "")
    if item is not None and (item.get("prMerged") or resolve_item_status(item) == "completed") \
            and ((item.get("releaseAssignment") or {}).get("releaseId") == rid):
        raise Refusal("ITEM_MERGED", "%s's work is merged into %s" % (st["item"], rid),
                      "ship it: kb-quick finish %s (or revert the merge on %s by hand first)" % (rid, rel.get("branch")))
    base = (rel.get("branchBaseSha") or "").lower()
    tip = (branch_tip or "").lower()
    if rel.get("branch"):
        # Fail closed: with a branch recorded, "did anything land?" needs BOTH a base and a read tip. An absent or
        # unreadable branch is not proof that nothing landed (it may have been deleted after a merge).
        if not _SHA40.fullmatch(base):
            raise Refusal("BRANCH_UNVERIFIABLE", "%s records branch %s but no branchBaseSha, so whether anything "
                          "landed on it cannot be checked" % (rid, rel.get("branch")),
                          "inspect %s by hand; to abandon anyway: kb-release edit %s --status cancelled" % (
                              rel.get("branch"), rid))
        if not _SHA40.fullmatch(tip):
            raise Refusal("BRANCH_UNVERIFIABLE", "the remote tip of %s was not read (branch absent or remote "
                          "unreachable)" % rel.get("branch"),
                          "run kb-quick cancel from the team repo with its remote reachable; if %s was deleted on "
                          "purpose and nothing landed, abandon by hand: kb-release edit %s --status cancelled" % (
                              rel.get("branch"), rid))
    if rel.get("branch") and tip != base:
        raise Refusal("BRANCH_MOVED", "%s has commits past its base %s (tip %s)" % (rel.get("branch"), base[:12],
                                                                                     tip[:12]),
                      "ship it (kb-quick finish %s), or reset %s to %s by hand first" % (rid, rel.get("branch"), base[:12]))
    restore = st["from"]
    if restore:
        target = release_by_id(board, restore)
        if target is None or not is_open(target):
            restore = None   # the original release closed meanwhile: leave the item unassigned rather than refuse
    warnings = []
    if item is not None and resolve_item_status(item) not in ("todo", "backlog", "ready", "planned", "cancelled"):
        warnings.append("%s is %s: close its open PR / worktree against %s by hand (cancel leaves that branch in place)"
                        % (st["item"], resolve_item_status(item), rel.get("branch") or "the hotfix branch"))
    return {"ok": True, "release": rid, "item": st["item"], "from": st["from"], "restoreTo": restore,
            "warnings": warnings,
            "branch": rel.get("branch"), "branchBaseSha": rel.get("branchBaseSha"), "phase": st["phase"],
            "itemAssignedHere": bool(item is not None
                                     and (item.get("releaseAssignment") or {}).get("releaseId") == rid)}


def resolve(board, arg):
    """REL-ID -> itself (must be quick); ITEM-ID -> its open quick release, else its newest quick release."""
    if _REL.fullmatch(arg or ""):
        status(board, arg)
        return arg
    if not _ID.fullmatch(arg or ""):
        raise Refusal("USAGE", "not a release or item id: %r" % arg, "kb-quick status <REL-ID|ITEM-ID>", rc=RC_USAGE)
    rel = open_quick_for_item(board, arg)
    if rel is None:
        hits = sorted((r for r in releases(board) if (quick_info(r) or {}).get("item") == arg),
                      key=lambda r: r.get("createdAt") or "")
        rel = hits[-1] if hits else None
    if rel is None:
        raise Refusal("NO_QUICK_RELEASE", "%s has no quick release" % arg, "kb-quick start %s" % arg, rc=RC_NOT_FOUND)
    return rel["id"]


# ---------------------------------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------------------------------
def _load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _archived(path):
    """Archived releases (kanban/releases-archive/<REL-ID>.json, one release per file), so a -QF<n> already used by an
    archived release is never re-issued. Unreadable entries are skipped: naming only, never a gate."""
    if not path or not os.path.isdir(path):
        return ()
    out = []
    for name in sorted(os.listdir(path)):
        if not name.endswith(".json"):
            continue
        try:
            data = _load(os.path.join(path, name))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            out.append(data)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="quick_release.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("check-start")
    p.add_argument("--board", required=True)
    p.add_argument("--item", required=True)
    p.add_argument("--date", default="")
    p.add_argument("--archive", default="")
    for name in ("status", "check-cancel"):
        p = sub.add_parser(name)
        p.add_argument("--board", required=True)
        p.add_argument("--release", required=True)
        if name == "check-cancel":
            p.add_argument("--branch-tip", default="")
    p = sub.add_parser("list-open")
    p.add_argument("--board", required=True)
    p = sub.add_parser("resolve")
    p.add_argument("--board", required=True)
    p.add_argument("--arg", required=True)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return RC_USAGE if e.code else RC_OK
    if not a.cmd:
        ap.print_usage(sys.stderr)
        return RC_USAGE
    try:
        board = _load(a.board)
    except (OSError, ValueError) as e:
        print(json.dumps({"ok": False, "code": "BOARD_UNREADABLE", "reason": str(e), "remedy": "check the board file"}))
        return 1
    try:
        if a.cmd == "check-start":
            out = check_start(board, a.item, a.date, _archived(a.archive))
        elif a.cmd == "status":
            out = status(board, a.release)
        elif a.cmd == "check-cancel":
            out = check_cancel(board, a.release, a.branch_tip)
        elif a.cmd == "list-open":
            out = {"ok": True, "releases": list_open(board)}
        else:
            out = {"ok": True, "release": resolve(board, a.arg)}
    except Refusal as r:
        print(json.dumps(r.as_dict()))
        return r.rc
    print(json.dumps(out))
    return RC_OK


if __name__ == "__main__":
    sys.exit(main())
