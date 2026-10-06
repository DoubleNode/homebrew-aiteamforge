#!/usr/bin/env python3
"""Release branch cut (XACA-1352; spec RELEASE-LIFECYCLE.md 3.2 DEV, 4.2).

Config lives at board `releaseConfig.branches` (every field optional):
    {"integration": "develop", "production": "master", "releasePrefix": "releases/", "mode": "release"}
mode "release" (default): PLANNED->DEV pushes `<releasePrefix><version>` from the integration tip.
mode "trunk" (XACA-1352-015): the release branch IS the integration branch; nothing is cut.
HOTFIX (XACA-1353-005, spec 4.2 "Hotfix" / 13.5): a release record with type "hotfix" cuts `hotfix/<ver>` from the
PRODUCTION tip instead, in EVERY mode (see cut_release_branch). Same cut code, different (source, prefix).

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
# Release record `type` (kb-release create validates the same four; the server stores it verbatim, so THIS is the
# fail-closed point for the cut: a typo'd type must not silently cut releases/<ver> from integration).
RELEASE_TYPES = ("feature", "bugfix", "hotfix", "maintenance")
HOTFIX_PREFIX = "hotfix/"   # constant: releaseConfig.branches has no hotfix-prefix field (unknown fields are refused)
_SAFE_REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}")
_SAFE_PREFIX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,30}/")
_SHA = re.compile(r"[0-9a-f]{40,64}")
# XACA-1352 round 1 (-019): keep these short and never let git prompt. XACA-1435: they no longer run under the
# board write lock (handle_promote_release cuts unlocked, then re-validates under the lock), which bounds how long a
# promote takes, not how long other board writers wait.
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


def release_type(release):
    """The release's type; absent/empty = "feature" (the create default). ValueError on an unknown type."""
    t = release.get("type") if isinstance(release, dict) else None
    if t is None or t == "":
        return "feature"
    if not isinstance(t, str) or t not in RELEASE_TYPES:
        raise ValueError("release type %r is not one of %s; refusing to cut a branch for it" % (t, list(RELEASE_TYPES)))
    return t


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


class BranchCreateRace(RuntimeError):
    """XACA-1435: the create-only push was rejected because the branch now EXISTS (another unlocked cut created it).
    Distinct from an ordinary push failure so the caller refuses (retry adopts) instead of treating it as "no branch":
    in report mode a plain cut failure proceeds branchless, which here would strand the winner's branch unrecorded."""


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


def is_trunk_release(release, release_config):
    """XACA-1446-011: True only when this release's branch IS the trunk: mode "trunk", a non-hotfix release, and
    release.branch == the integration branch. A hotfix is cut from production onto its own hotfix/ branch (not
    trunk-moving), and a branch that is not the integration branch is not trunk either, so both keep exact-equality
    gating. Any config/type error answers False (the strict path)."""
    try:
        cfg = effective_branches(release_config)
        if cfg["mode"] != "trunk" or release_type(release) == "hotfix":
            return False
    except ValueError:
        return False
    b = release.get("branch") if isinstance(release, dict) else None
    return isinstance(b, str) and b.strip() == cfg["integration"]


def sha_reachable_from_tip(repo_root, branch, sha, *, run=subprocess.run):
    """XACA-1446-011: is `sha` an ancestor of (or equal to) `branch`'s REMOTE tip (the same remote-tip reading as
    branch_tip, XACA-1352-018)? True / False / None. None = cannot tell (bad input, no remote, unreachable remote,
    objects unavailable, any git error): callers fail closed. False only when git answered "not an ancestor"
    (rc 1), i.e. history was rewritten or the build never landed on the branch. If the tip commit is not in the
    local object store it is fetched (objects only, no ref is created or moved)."""
    if not isinstance(branch, str) or not isinstance(sha, str) or not _SHA.fullmatch(sha):
        return None
    branch = branch.strip()
    if not branch or branch.startswith("-") or not _SAFE_REF.fullmatch(branch):
        return None
    try:
        git = _Git(repo_root, run)
        _check_ref(git, branch)
        remote = _remote(git)
        tip = _remote_tip(git, remote, branch)
        if not tip:
            return None
        if git("cat-file", "-e", tip + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            git("fetch", "--quiet", "--no-tags", "--", remote, "refs/heads/" + branch)
            git("cat-file", "-e", tip + "^{commit}")
        if git("cat-file", "-e", sha + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            return None   # the DEV build is not in this repo at all: cannot verify
        rc = git("merge-base", "--is-ancestor", sha, tip, ok=(0, 1)).returncode
        return rc == 0
    except (ValueError, RuntimeError, OSError):
        return None


def cut_release_branch(release, board, repo_root, *, dry_run=False, run=subprocess.run):
    """Cut (or, in trunk mode, resolve) the release branch. Returns {"branch","branchBaseSha"}.

    One implementation, parameterised by (source branch, prefix, label):
      feature/bugfix/maintenance: source = integration, prefix = releasePrefix (trunk mode: no cut, integration).
      hotfix: source = PRODUCTION, prefix = hotfix/, in every mode. In trunk mode the release branch is normally
        the integration branch, but a hotfix must be isolated from unreleased trunk work -- cutting it from
        production is the whole point of a hotfix (spec 13.5). If production == integration in trunk mode there
        is nothing to isolate it from, so that combination is refused with a reason instead of silently
        collapsing the hotfix onto the trunk."""
    cfg = effective_branches((board or {}).get("releaseConfig"))
    rtype = release_type(release)
    git = _Git(repo_root, run)
    remote = _remote(git)
    hotfix = rtype == "hotfix"
    if hotfix:
        if cfg["mode"] == "trunk" and cfg["production"] == cfg["integration"]:
            raise RuntimeError("hotfix release in trunk mode: production and integration are both %r, so a hotfix "
                               "branch cannot be isolated from unreleased trunk work; refusing to cut"
                               % cfg["production"])
        src, prefix = cfg["production"], HOTFIX_PREFIX
    else:
        src, prefix = cfg["integration"], cfg["releasePrefix"]
    src_sha = _remote_tip(git, remote, src)
    if not src_sha:
        raise RuntimeError("%s branch %r not found on remote %r" % ("production" if hotfix else "integration", src, remote))
    if cfg["mode"] == "trunk" and not hotfix:
        return {"branch": src, "branchBaseSha": src_sha}

    branch = prefix + release_version(release)
    _check_ref(git, branch)
    existing = _remote_tip(git, remote, branch)
    if existing:
        if existing == src_sha:
            return {"branch": branch, "branchBaseSha": existing}
        if dry_run:
            raise RuntimeError("branch %r already exists at %s (%s is at %s); a dry-run cannot "
                               "verify its history without fetching" % (branch, existing, src, src_sha))
        git("fetch", "--", remote, src, branch)   # objects for BOTH tips, so the ancestry checks cannot rc-128
        if git("merge-base", "--is-ancestor", existing, src_sha, ok=(0, 1)).returncode != 0:
            if git("merge-base", "--is-ancestor", src_sha, existing, ok=(0, 1)).returncode == 0:
                raise RuntimeError("branch %r already exists with commits %r lacks (its tip %s is ahead of %s); "
                                   "refusing to reuse it" % (branch, src, existing, src_sha))
            if git("merge-base", existing, src_sha, ok=(0, 1)).returncode == 0:
                raise RuntimeError("branch %r already exists and has diverged from %r (tip %s; %r is at %s); "
                                   "refusing to reuse it" % (branch, src, existing, src, src_sha))
            raise RuntimeError("branch %r exists with unrelated history (tip %s shares no commit with %r)"
                               % (branch, existing, src))
        return {"branch": branch, "branchBaseSha": existing}
    if dry_run:
        return {"branch": branch, "branchBaseSha": src_sha}
    git("fetch", "--", remote, src)
    # XACA-1435: create-only. The cut runs with no board lock held, so two promotes can both find the branch
    # absent; a plain push would let the second fast-forward it past the base the first records. An empty lease
    # value means "the ref must not exist": the loser is rejected (fail closed) and its retry adopts the branch.
    try:
        git("push", "--force-with-lease=refs/heads/%s:" % branch, "--", remote,
            "%s:refs/heads/%s" % (src_sha, branch))
    except RuntimeError as e:
        try:
            raced = _remote_tip(git, remote, branch)
        except RuntimeError:
            raced = None   # cannot tell: an ordinary push failure (fail closed as before)
        if raced:
            raise BranchCreateRace("branch %r was not created by this cut: it was created concurrently at %s; "
                                   "retry the promote to adopt it" % (branch, raced))
        raise RuntimeError("branch %r was not created by this cut (push failed; retry the promote): %s"
                           % (branch, e))
    if _remote_tip(git, remote, branch) != src_sha:
        raise RuntimeError("pushed %r but the remote tip does not equal %s" % (branch, src_sha))
    return {"branch": branch, "branchBaseSha": src_sha}


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
