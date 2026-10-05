#!/usr/bin/env python3
"""Release branch cut (XACA-1352; spec RELEASE-LIFECYCLE.md 3.2 DEV, 4.2).

Config lives at board `releaseConfig.branches` (every field optional):
    {"integration": "develop", "production": "master", "releasePrefix": "releases/", "mode": "release"}
mode "release" (default): PLANNED->DEV pushes `<releasePrefix><version>` from the integration tip.
mode "trunk" (XACA-1352-015): the release branch IS the integration branch; nothing is cut.

A stage name is NOT special here (iOS legitimately sets integration="DEV"): refs are never
derived from stages and never rejected for looking like one. Malformed config FAILS CLOSED.

Never writes the release record or the board. stdlib only, python 3.9 compatible.

CLI (wrapped by kanban-helpers.sh):
    branches    --board B
    item-branch --board B --item ID
    cut         --board B --release-id REL [--repo DIR] [--dry-run]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULTS = {"integration": "develop", "production": "master", "releasePrefix": "releases/", "mode": "release"}
MODES = ("release", "trunk")
_SAFE_REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}")
_SAFE_PREFIX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,30}/")
_SHA = re.compile(r"[0-9a-f]{40,64}")
# XACA-1352 round 1 (-019): these run under the board write lock, so keep them short and never let git prompt.
LOCAL_TIMEOUT = 10
LS_REMOTE_TIMEOUT = 20
FETCH_TIMEOUT = 20
PUSH_TIMEOUT = 30
_TIMEOUTS = {"ls-remote": LS_REMOTE_TIMEOUT, "fetch": FETCH_TIMEOUT, "push": PUSH_TIMEOUT}


def effective_branches(release_config):
    """The 4 branch fields with defaults filled in; ValueError on any present-but-invalid value."""
    if release_config is None:
        release_config = {}
    if not isinstance(release_config, dict):
        raise ValueError("releaseConfig is not an object")
    if "branches" not in release_config or release_config["branches"] is None:
        return dict(DEFAULTS)
    br = release_config["branches"]
    if not isinstance(br, dict):
        raise ValueError("releaseConfig.branches is not an object")
    out = dict(DEFAULTS)
    for k in ("integration", "production"):
        if k in br:
            v = br[k]
            if not isinstance(v, str) or not _SAFE_REF.fullmatch(v) or ".." in v or v.endswith("/") \
                    or v.endswith(".lock"):
                raise ValueError("releaseConfig.branches.%s %r is not a usable branch name" % (k, v))
            out[k] = v
    if "releasePrefix" in br:
        v = br["releasePrefix"]
        if not isinstance(v, str) or not _SAFE_PREFIX.fullmatch(v) or ".." in v:
            raise ValueError("releaseConfig.branches.releasePrefix %r must be a safe prefix ending in '/'" % (v,))
        out["releasePrefix"] = v
    if "mode" in br:
        if br["mode"] not in MODES:
            raise ValueError("releaseConfig.branches.mode %r is not one of %s" % (br["mode"], list(MODES)))
        out["mode"] = br["mode"]
    unknown = sorted(set(br) - set(DEFAULTS))
    if unknown:
        raise ValueError("releaseConfig.branches has unknown field(s) %s" % unknown)
    return out


def release_version(release):
    """The release's single version; every platform's version must be non-empty and equal."""
    plats = release.get("platforms") if isinstance(release, dict) else None
    if not isinstance(plats, dict) or not plats:
        raise ValueError("release has no platforms; cannot determine its version")
    vers = {}
    for p, cfg in plats.items():
        v = cfg.get("version") if isinstance(cfg, dict) else None
        vers[p] = v.strip() if isinstance(v, str) else ""
    missing = sorted(p for p, v in vers.items() if not v)
    if missing:
        raise ValueError("platform(s) %s have no version; cannot determine the release version" % missing)
    if len(set(vers.values())) != 1:
        raise ValueError("platform versions disagree (%s); a release branch needs ONE version"
                         % ", ".join("%s=%s" % (p, vers[p]) for p in sorted(vers)))
    return next(iter(vers.values()))


def _clean_environ():
    cleaned = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    cleaned["GIT_TERMINAL_PROMPT"] = "0"   # a server started from a terminal must never block on a credential prompt
    return cleaned


class _Git:
    def __init__(self, repo, run):
        self.repo, self.run = str(repo), run

    def __call__(self, *args, ok=(0,)):
        try:
            r = self.run(["git", "-C", self.repo] + list(args), capture_output=True, text=True,
                         stdin=subprocess.DEVNULL, timeout=_TIMEOUTS.get(args[0], LOCAL_TIMEOUT),
                         env=_clean_environ())
        except (OSError, subprocess.SubprocessError) as e:
            raise RuntimeError("git %s failed to run: %s" % (args[0], e))
        if r.returncode not in ok:
            raise RuntimeError("git %s failed (rc %s): %s" % (" ".join(args[:2]), r.returncode,
                                                              (r.stderr or r.stdout or "").strip()))
        return r


def _remote(git):
    lines = (git("remote").stdout or "").split()
    if not lines:
        raise RuntimeError("repository %s has no git remote" % git.repo)
    return lines[0]


def _remote_tip(git, remote, branch):
    out = (git("ls-remote", "--", remote, "refs/heads/" + branch).stdout or "").strip()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "refs/heads/" + branch and _SHA.fullmatch(parts[0]):
            return parts[0]
    return None


def _check_ref(git, branch):
    if branch.startswith("-"):
        raise ValueError("branch %r starts with '-'" % branch)
    git("check-ref-format", "--branch", branch)


def branch_tip(repo_root, branch, *, run=subprocess.run):
    """The tip SHA of `branch` as the REMOTE has it, or None. The cut pushes to the remote only (no local branch),
    and a local `develop` can lag the remote, so no reader may use a local ref (XACA-1352-018). Same remote
    convention as the cut (first `git remote`). Never guesses: an invalid name, no remote, an unreachable remote or
    an absent branch all give None, so callers keep their existing fail-closed "cannot verify" paths."""
    if not isinstance(branch, str):
        return None
    branch = branch.strip()
    if not branch or branch.startswith("-") or not _SAFE_REF.fullmatch(branch):
        return None
    try:
        git = _Git(repo_root, run)
        _check_ref(git, branch)
        return _remote_tip(git, _remote(git), branch)
    except (ValueError, RuntimeError, OSError):
        return None


def cut_release_branch(release, board, repo_root, *, dry_run=False, run=subprocess.run):
    """Cut (or, in trunk mode, resolve) the release branch. Returns {"branch","branchBaseSha"}."""
    cfg = effective_branches((board or {}).get("releaseConfig"))
    git = _Git(repo_root, run)
    remote = _remote(git)
    integ = cfg["integration"]
    integ_sha = _remote_tip(git, remote, integ)
    if not integ_sha:
        raise RuntimeError("integration branch %r not found on remote %r" % (integ, remote))
    if cfg["mode"] == "trunk":
        return {"branch": integ, "branchBaseSha": integ_sha}

    branch = cfg["releasePrefix"] + release_version(release)
    _check_ref(git, branch)
    existing = _remote_tip(git, remote, branch)
    if existing:
        if existing == integ_sha:
            return {"branch": branch, "branchBaseSha": existing}
        if dry_run:
            raise RuntimeError("branch %r already exists at %s (integration is at %s); a dry-run cannot "
                               "verify its history without fetching" % (branch, existing, integ_sha))
        git("fetch", "--", remote, integ, branch)   # objects for BOTH tips, so the ancestry checks cannot rc-128
        if git("merge-base", "--is-ancestor", existing, integ_sha, ok=(0, 1)).returncode != 0:
            if git("merge-base", "--is-ancestor", integ_sha, existing, ok=(0, 1)).returncode == 0:
                raise RuntimeError("branch %r already exists with commits %r lacks (its tip %s is ahead of %s); "
                                   "refusing to reuse it" % (branch, integ, existing, integ_sha))
            if git("merge-base", existing, integ_sha, ok=(0, 1)).returncode == 0:
                raise RuntimeError("branch %r already exists and has diverged from %r (tip %s; %r is at %s); "
                                   "refusing to reuse it" % (branch, integ, existing, integ, integ_sha))
            raise RuntimeError("branch %r exists with unrelated history (tip %s shares no commit with %r)"
                               % (branch, existing, integ))
        return {"branch": branch, "branchBaseSha": existing}
    if dry_run:
        return {"branch": branch, "branchBaseSha": integ_sha}
    git("fetch", "--", remote, integ)
    git("push", "--", remote, "%s:refs/heads/%s" % (integ_sha, branch))
    if _remote_tip(git, remote, branch) != integ_sha:
        raise RuntimeError("pushed %r but the remote tip does not equal %s" % (branch, integ_sha))
    return {"branch": branch, "branchBaseSha": integ_sha}


def team_repo_root(team, kanban_dir=None):
    """Team git working dir (aiteamforge_paths registry), else the kanban dir's parent, else None."""
    try:
        from aiteamforge_paths import get_team_working_dir  # noqa: PLC0415
        root = Path(get_team_working_dir(team))
        if root.is_dir():
            return root
    except Exception:
        pass
    if kanban_dir and Path(kanban_dir).parent.is_dir():
        return Path(kanban_dir).parent
    return None


# ----------------------------------------------------------------------------- CLI

def _load_board(path):
    with open(path, encoding="utf-8") as f:
        b = json.load(f)
    if not isinstance(b, dict):
        raise ValueError("board is not an object")
    return b


def _find_release(board, rid):
    for r in board.get("releases") or []:
        if isinstance(r, dict) and r.get("id") == rid:
            return r
    return None


def _find_item(board, item_id):
    """The top-level item for `item_id`, which may itself be a subitem id (resolved via its parent)."""
    backlog = [i for i in (board.get("backlog") or []) if isinstance(i, dict)]
    for it in backlog:
        if it.get("id") == item_id:
            return it
    for it in backlog:
        for s in it.get("subitems") or []:
            if isinstance(s, dict) and s.get("id") == item_id:
                return it
    return None


def _valid_ref_format(branch):
    try:
        r = subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=LOCAL_TIMEOUT, env=_clean_environ())
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def _cmd_item_branch(a):
    board = _load_board(a.board)
    item = _find_item(board, a.item)
    if item is None:
        print("error: item %s not found" % a.item, file=sys.stderr)
        return 1
    ra = item.get("releaseAssignment")
    rid = ra.get("releaseId") if isinstance(ra, dict) else None
    if not rid:
        return 0
    rel = _find_release(board, rid)
    if rel is None:
        print("warning: %s references release %s which does not exist" % (item.get("id"), rid), file=sys.stderr)
        return 0
    br = rel.get("branch")
    if isinstance(br, str) and br.strip():
        br = br.strip()
        if br.startswith("-") or not _SAFE_REF.fullmatch(br) or not _valid_ref_format(br):
            print("error: release %s has an unusable branch %r" % (rid, br), file=sys.stderr)
            return 1
        print(br)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="release_branches.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("branches")
    p.add_argument("--board", required=True)
    p = sub.add_parser("item-branch")
    p.add_argument("--board", required=True)
    p.add_argument("--item", required=True)
    p = sub.add_parser("cut")
    p.add_argument("--board", required=True)
    p.add_argument("--release-id", required=True)
    p.add_argument("--repo")
    p.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "item-branch":
            return _cmd_item_branch(a)
        board = _load_board(a.board)
        if a.cmd == "branches":
            print(json.dumps(effective_branches(board.get("releaseConfig"))))
            return 0
        rel = _find_release(board, a.release_id)
        if rel is None:
            raise ValueError("release %s not found" % a.release_id)
        repo = a.repo or team_repo_root(board.get("team"), Path(a.board).resolve().parent)
        if not repo:
            raise RuntimeError("cannot resolve the team repo root; pass --repo")
        print(json.dumps(cut_release_branch(rel, board, repo, dry_run=a.dry_run)))
        return 0
    except (ValueError, RuntimeError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
