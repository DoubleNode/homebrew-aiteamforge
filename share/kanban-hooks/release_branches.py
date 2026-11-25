#!/usr/bin/env python3
"""Release branch cut (XACA-1352; spec RELEASE-LIFECYCLE.md 3.2 DEV, 4.2).

Config lives at board `releaseConfig.branches` (every field optional):
    {"integration": "develop", "production": "master", "releasePrefix": "releases/", "mode": "release"}
mode "release" (default): PLANNED->DEV pushes `<releasePrefix><version>` from the integration tip.
mode "trunk" (XACA-1352-015): the release branch IS the integration branch; nothing is cut.
mode "client-merge" (XACA-1521): the CUT is identical to "release" (`<releasePrefix><version>` from the integration
tip) and every is-trunk check stays False, so gating is release-mode exact equality. Only the PROD close-out differs:
the client (not us) merges the release branch into production, so tag/mergeProduction/mergeOtherReleases/deleteBranch
are recorded done-as-skipped and mergeIntegration verifies the client's merge (see release_closeout.py).
HOTFIX (XACA-1353-005, spec 4.2 "Hotfix" / 13.5): a release record with type "hotfix" cuts `hotfix/<ver>` from the
PRODUCTION tip instead, in EVERY mode (see cut_release_branch). Same cut code, different (source, prefix).

A stage name is NOT special here (iOS legitimately sets integration="DEV"): refs are never
derived from stages and never rejected for looking like one. Malformed config FAILS CLOSED.

Never writes the release record or the board. stdlib only, python 3.9 compatible.

CLI (wrapped by kanban-helpers.sh):
    branches    --board B
    item-branch --board B --item ID
    cut         --board B --release-id REL [--repo DIR] [--dry-run]
    planned-branch --board B --release-id REL   (what the PLANNED->DEV promote WOULD produce; pure, no git)
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULTS = {"integration": "develop", "production": "master", "releasePrefix": "releases/", "mode": "release"}
MODES = ("release", "trunk", "client-merge")
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


def remote_tag_sha(repo_root, tag, *, run=subprocess.run):
    """XACA-1698: the commit SHA tag `tag` points at, as the REMOTE has it, or None. An annotated tag's peeled
    (`^{}`) line wins over its tag-object line; a lightweight tag has only the direct line. Same convention as
    branch_tip (first remote, ls-remote only, never fetches: the server calls it under the board lock). Any bad
    input, missing remote/tag or git error gives None so callers keep their fail-closed paths."""
    if not isinstance(tag, str):
        return None
    tag = tag.strip()
    if not tag or tag.startswith("-") or not _SAFE_REF.fullmatch(tag):
        return None
    try:
        git = _Git(repo_root, run)
        git("check-ref-format", "refs/tags/" + tag)
        ref = "refs/tags/" + tag
        out = git("ls-remote", "--", _remote(git), ref, ref + "^{}").stdout or ""
    except (ValueError, RuntimeError, OSError):
        return None
    direct = peeled = None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2 or not _SHA.fullmatch(parts[0]):
            continue
        if parts[1] == ref:
            direct = parts[0]
        elif parts[1] == ref + "^{}":
            peeled = parts[0]
    return peeled or direct


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
    (rc 1), i.e. history was rewritten or the build never landed on the branch. Read-only on the local object
    store: if the remote tip commit is not already local this returns None and NEVER fetches (XACA-1446-016: the
    server calls it while holding the board lock; the ls-remote is the only network read)."""
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
            return None   # XACA-1446-016: never fetch (this runs under the board lock); tip not local = cannot verify
        if git("cat-file", "-e", sha + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            return None   # the DEV build is not in this repo at all: cannot verify
        rc = git("merge-base", "--is-ancestor", sha, tip, ok=(0, 1)).returncode
        return rc == 0
    except (ValueError, RuntimeError, OSError):
        return None


def file_at_sha(repo_root, sha, path, *, run=subprocess.run):
    """XACA-1736: the text of `path` (repo-relative, '/'-separated) in commit `sha`, or None. Reads the local
    object store only and NEVER fetches (the server calls it under the board lock): a commit that is not local, a
    path absent at that commit, a path escaping the repo, or any git error gives None, so callers fail closed."""
    if not isinstance(sha, str) or not _SHA.fullmatch(sha) or not isinstance(path, str):
        return None
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    if not path or path.startswith(("/", "-")) or ".." in path.split("/"):
        return None
    try:
        git = _Git(repo_root, run)
        if git("cat-file", "-e", sha + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            return None
        r = git("show", "%s:%s" % (sha, path), ok=(0, 128))
        return r.stdout if r.returncode == 0 else None
    except (ValueError, RuntimeError, OSError):
        return None


_CONFLICT_ENTRY = re.compile(r"(\d{6}) ([0-9a-f]{40,64}) ([123])\t(.+)", re.S)


def _gitlink_contained(git, path, prod_link, build_link):
    """True / False / None: is production's submodule commit an ancestor of the build's, per the submodule's OWN repo?
    None when the submodule cannot answer (not checked out as its own repo, objects missing, any git error)."""
    sub = Path(git.repo) / path
    try:
        if not sub.is_dir():
            return None
        subgit = _Git(sub, git.run)
        top = (subgit("rev-parse", "--show-toplevel").stdout or "").strip()
        # an uninitialised submodule dir is an empty folder INSIDE the superproject: git -C would silently walk up and
        # answer about the superproject, so insist the toplevel is the submodule itself
        if not top or os.path.realpath(top) != os.path.realpath(str(sub)):
            return None
        for oid in (prod_link, build_link):
            if subgit("cat-file", "-e", oid + "^{commit}", ok=(0, 1, 128)).returncode != 0:
                return None
        return subgit("merge-base", "--is-ancestor", prod_link, build_link, ok=(0, 1)).returncode == 0
    except (ValueError, RuntimeError, OSError):
        return None


def _judge_conflicts(git, fields):
    """merge-tree rc 1 -> False for a GENUINE conflict, None when git merely could not evaluate a submodule.
    Parsed from `-z` output (tree OID, then NUL-separated `<mode> <oid> <stage>TAB<path>` entries up to an empty field,
    then the informational messages), never from the human messages: those are localized, advice-laden prose, whereas
    the conflicted-file-info entries are machine-stable. Mode 160000 is the gitlink discriminator.
      * any conflicted path that is not purely a gitlink -> False (production changed a regular file the build also
        changed or lacks; a file<->submodule type conflict counts as regular);
      * only gitlinks conflict (the XACA-1735 hand-merge shape): git conflicts on a gitlink whenever the submodule is
        not checked out / its objects are absent ('Failed to merge submodule X (not checked out)'), even when the
        build's pointer descends from production's, so rc 1 alone proves nothing. Ask the submodule itself: production's
        pointer provably NOT an ancestor of the build's -> False (production's submodule commit is not in the build);
        anything else (cannot answer, or it is an ancestor yet git still conflicted) -> None. There is deliberately no
        True here: with the submodule present git resolves a descending pointer cleanly (rc 0, handled by the caller),
        so a conflict that survives is not something we can vouch for.
    Anything unparsable -> None."""
    entries = {}
    for f in fields[1:]:
        if not f:
            break
        m = _CONFLICT_ENTRY.fullmatch(f)
        if not m:
            return None
        entries.setdefault(m.group(4), {})[m.group(3)] = (m.group(1), m.group(2))
    if not entries:
        return None   # a conflict we cannot enumerate is not a conflict we can judge
    if any(mode != "160000" for st in entries.values() for mode, _ in st.values()):
        return False
    for path, st in entries.items():
        if "2" in st and "3" in st and _gitlink_contained(git, path, st["2"][1], st["3"][1]) is False:
            return False
    return None


def production_contained_in(repo_root, production_branch, sha, *, run=subprocess.run):
    """XACA-1705 (-001/-011): is everything on production's REMOTE tip already IN `sha`'s build? True / False / None.
    CONTENT containment, not just commit ancestry (XACA-1735: a hand-merged production tip can be unreachable from
    integration while integration holds all its content, and the back-merge has not landed):
      True  production tip is an ancestor of / equal to `sha`, OR `git merge-tree --write-tree <tip> <sha>` is clean
            (rc 0) and yields exactly `sha`'s own tree (merging production in changes nothing);
      False ancestry is false and the merge conflicts on a regular file (rc 1) or yields a different tree (production carries a
            change, e.g. a hotfix, that the build lacks);
      None  any uncertainty: bad input, no remote/branch, tip or sha object not local (NEVER fetches, same rule as
            sha_reachable_from_tip: the server calls this under the board lock; ls-remote is the only network read),
            git too old for --write-tree (usage error / rc > 1), unrelated histories, any git error, or a conflict
            that is only a submodule git could not evaluate (not checked out / objects missing); see
            _judge_conflicts.
    Callers must fail closed on None."""
    if not isinstance(production_branch, str) or not isinstance(sha, str) or not _SHA.fullmatch(sha):
        return None
    branch = production_branch.strip()
    if not branch or branch.startswith("-") or not _SAFE_REF.fullmatch(branch):
        return None
    try:
        git = _Git(repo_root, run)
        _check_ref(git, branch)
        tip = _remote_tip(git, _remote(git), branch)
        if not tip:
            return None
        if git("cat-file", "-e", tip + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            return None
        if git("cat-file", "-e", sha + "^{commit}", ok=(0, 1, 128)).returncode != 0:
            return None
        if git("merge-base", "--is-ancestor", tip, sha, ok=(0, 1)).returncode == 0:
            return True
        mt = git("merge-tree", "--write-tree", "-z", tip, sha, ok=(0, 1))   # rc>1 (old git: 129, unrelated: 128) -> None
        fields = (mt.stdout or "").split("\0")
        merged = fields[0].strip()
        want = (git("rev-parse", "--verify", sha + "^{tree}").stdout or "").strip()
        if not _SHA.fullmatch(merged) or not _SHA.fullmatch(want):
            return None
        if mt.returncode == 1:
            return _judge_conflicts(git, fields)
        return merged == want
    except (ValueError, RuntimeError, OSError):
        return None


def subsumed_merge_tree(repo_root, target, source, *, run=subprocess.run):
    """XACA-1735: (tree, why). When merging `source` into `target` CONFLICTS but `target` carries nothing `source`
    lacks, return `source`'s tree so the caller can record the merge with it; else (None, reason) and the caller keeps
    the conflict refusal. Local objects only, never fetches, never writes a ref (merge-tree writes loose objects only).

    The incident (REL-2026-Q3-037, REL-2026-Q4-070): a hand-resolved production merge never flowed back to integration,
    so the two branches keep 2+ merge bases. The recursive virtual base then conflicts on paths where production's
    side is old content (a gitlink git cannot fast-forward without the submodule checked out; a text file whose
    production value was resolved to the release side). Accepted ONLY when both hold:
      1. no conflicted path carries a production-only change. Every commit `rev-list --full-history target ^source
         -- p` lists must be a MERGE whose value at `p` equals one of its REAL parents' values (read separately with
         `rev-list --parents -n1`; the path-limited walk's --parents shows rewritten parents). --full-history drops a
         merge that is TREESAME to a target-side parent, but a match with an EXCLUDED (source-side) parent does not
         count, so a merge that took the source's value (the hand resolution itself) is listed and must be skipped.
         Consequence, on purpose: a target merge that kept an OLDER value from one parent (e.g. an `-s ours`
         resolution) is accepted, because that value came from a parent and holds no new content; the source tree
         wins (pinned by test_judge_accepts_a_production_merge_that_kept_an_older_value). Refused: any NON-merge
         target-only commit on `p` (a hotfix, a revert commit, a deletion) and any merge that wrote a value neither
         parent had;
      2. every NON-conflicted path of the merge-tree result already equals `source`'s tree (a production-only change
         that merges cleanly would otherwise be dropped).
    Anything else (bad input, clean merge, git too old for --write-tree, unparsable output, git errors) -> refuse."""
    if not all(isinstance(x, str) and _SHA.fullmatch(x) for x in (target, source)):
        return None, "target/source must be full commit SHAs"
    try:
        git = _Git(repo_root, run)
        mt = git("merge-tree", "--write-tree", "--name-only", "-z", target, source, ok=(0, 1))
        if mt.returncode == 0:
            return None, "the merge is clean; nothing to accept"
        fields = (mt.stdout or "").split("\0")
        merged = fields[0].strip()
        paths = []
        for f in fields[1:]:
            if not f:
                break
            paths.append(f)
        want = (git("rev-parse", "--verify", source + "^{tree}").stdout or "").strip()
        if not _SHA.fullmatch(merged) or not _SHA.fullmatch(want) or not paths:
            return None, "could not read the merge-tree result"
        paths = sorted(set(paths))
        def at(commit, p):
            r = git("rev-parse", "-q", "--verify", "%s:%s" % (commit, p), ok=(0, 1, 128))
            return (r.stdout or "").strip() if r.returncode == 0 else None

        own = []
        for p in paths:
            out = git("rev-list", "--full-history", target, "^" + source, "--", ":(literal)" + p).stdout or ""
            for c in out.split():
                # the REAL parents (--parents would show history-rewritten ones under a pathspec)
                parents = (git("rev-list", "--parents", "-n1", c).stdout or "").split()[1:]
                if len(parents) > 1 and at(c, p) in {at(q, p) for q in parents}:
                    continue    # a merge that took one side's value verbatim introduces nothing
                own.append("%s (%s)" % (p, c[:12]))
                break
        if own:
            return None, "production carries its own change to conflicted path(s): " + ", ".join(own)
        diff = git("diff-tree", "-r", "-z", "--name-only", merged, want).stdout or ""
        extra = sorted({d for d in diff.split("\0") if d} - set(paths))
        if extra:
            return None, "production carries change(s) the release lacks on non-conflicted path(s): " + ", ".join(extra)
        return want, "conflicted path(s) %s carry no production-only change" % ", ".join(paths)
    except (ValueError, RuntimeError, OSError) as e:
        return None, "cannot evaluate: %s" % e


def _branch_spec(cfg, rtype):
    """(source branch, prefix) the promote uses for `rtype` under `cfg`; prefix None = trunk mode, nothing is cut
    (the release branch IS `source`). RuntimeError for the refused hotfix combination. Shared by cut_release_branch
    and planned_branch_label so the cut and the message about it cannot drift (XACA-1524)."""
    if rtype == "hotfix":
        if cfg["mode"] == "client-merge":
            # XACA-1521-020: the engine never writes to a client-owned repo except the create-only cut of the
            # RELEASE branch; a hotfix branch is cut from production, which the client owns. Refuse, push nothing.
            raise RuntimeError("client-merge mode: hotfix release cut is not supported (the engine never writes to the "
                               "client repo); create the hotfix branch in the client repo by hand, or switch the board "
                               "to mode release")
        if cfg["mode"] == "trunk" and cfg["production"] == cfg["integration"]:
            raise RuntimeError("hotfix release in trunk mode: production and integration are both %r, so a hotfix "
                               "branch cannot be isolated from unreleased trunk work; refusing to cut"
                               % cfg["production"])
        return cfg["production"], HOTFIX_PREFIX
    if cfg["mode"] == "trunk":
        return cfg["integration"], None
    return cfg["integration"], cfg["releasePrefix"]


def planned_branch_label(release, board):
    """Pure (no git) verb phrase for what the PLANNED->DEV promote does to the release branch, for messages that read
    "...the DEV promote <label>" (XACA-1524). Never raises; never guesses a prefix it could not read:
      "cuts dme-release/1.2.3"  ("<ver>" placeholder when the version is absent/inconsistent)
      "cuts hotfix/1.2.3"       hotfix, every mode
      "uses the integration branch develop (trunk mode, nothing is cut)"
      "would be refused (...)"  trunk-mode hotfix with production == integration, or an unknown release type
      "cuts the configured release branch"   releaseConfig.branches is malformed"""
    try:
        cfg = effective_branches((board or {}).get("releaseConfig") if isinstance(board, dict) else None)
    except ValueError:
        return "cuts the configured release branch"
    try:
        rtype = release_type(release)
    except ValueError as e:
        return "would be refused (%s)" % e
    try:
        src, prefix = _branch_spec(cfg, rtype)
    except RuntimeError as e:
        return "would be refused (%s)" % e
    if prefix is None:
        return "uses the integration branch %s (trunk mode, nothing is cut)" % src
    try:
        ver = release_version(release)
    except ValueError:
        ver = "<ver>"
    return "cuts %s%s" % (prefix, ver)


def is_trunk_planned(release, board):
    """True iff the PLANNED->DEV promote for `release` uses the integration branch as the release branch (trunk mode,
    nothing cut). Structural (reads _branch_spec, not the label text); never raises -- any failure is False (XACA-1528)."""
    try:
        cfg = effective_branches((board or {}).get("releaseConfig") if isinstance(board, dict) else None)
        return _branch_spec(cfg, release_type(release))[1] is None
    except (ValueError, RuntimeError):
        return False


def branchless_past_planned(release, board):
    """XACA-1738: True iff `release` is past PLANNED and not PROD, has no recorded branch, is not a trunk-planned
    release (whose branch is the integration branch) and is not an XACA-1834 batch release (branchless by design). The ONE predicate behind both `item-branch`'s refusal and
    release_resume's `branch-missing` row, so they cannot disagree. The stage comes from release_gate.current_stage
    (explicit stage, else stages{}.enteredAt, else legacy platform environment, else PLANNED), the same reader the gate
    and resume use; a raw release["stage"] read misses legacy records. Never raises on a malformed record."""
    if not isinstance(release, dict):
        return False
    if release.get("kind") == "batch":
        # XACA-1834 batch release (release_orchestrator.BATCH_KIND): created at DEV with NO branch by design; its items
        # keep their real releaseAssignment and branch from that release. Not a failed cut (PR #1391 round 2).
        return False
    br = release.get("branch")
    if isinstance(br, str) and br.strip():
        return False
    import release_gate  # noqa: PLC0415 - lazy, keeps this module importable without the gate
    try:
        stage = release_gate.current_stage(release)
    except Exception:  # noqa: BLE001 - an unreadable stage is not "past PLANNED"
        return False
    return stage not in ("PLANNED", "PROD") and not is_trunk_planned(release, board)


def integration_branch_name(board):
    """The configured integration branch for messages, or a generic phrase when releaseConfig is malformed."""
    try:
        return effective_branches((board or {}).get("releaseConfig") if isinstance(board, dict) else None)["integration"]
    except ValueError:
        return "the integration branch"


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
    src, prefix = _branch_spec(cfg, rtype)
    src_sha = _remote_tip(git, remote, src)
    if not src_sha:
        raise RuntimeError("%s branch %r not found on remote %r" % ("production" if hotfix else "integration", src, remote))
    if prefix is None:   # trunk mode, non-hotfix: no cut
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
    """Team git work-tree root, else the kanban dir's parent for an unregistered team, else None.

    XACA-1477: same resolution as server._resolve_team_repo_root (aiteamforge_paths.get_team_repo_root
    looks inside container-layout working dirs). A REGISTERED team whose repo cannot be resolved raises
    ValueError with the reason (the CLI prints it and exits 1); it never reaches the kanban-parent fallback.
    """
    try:
        from aiteamforge_paths import get_team_repo_root  # noqa: PLC0415
        root = Path(get_team_repo_root(team))
        if root.is_dir():
            return root
    except ValueError:
        raise
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
    # XACA-1738: past PLANNED, the promote records the branch (trunk mode: the integration branch). None here means a
    # report-mode promote advanced on a failed cut (or a record predating branch-per-release); falling back to
    # integration would base the release's PRs (and the kb-pick worktree) on unreleased work. Refuse.
    if branchless_past_planned(rel, board):
        import release_gate  # noqa: PLC0415 - lazy: release_gate is the one stage reader (resume uses it too)
        print("error: release %s is at %s but has no recorded branch (its branch cut failed, or it predates "
              "branch-per-release); refusing to fall back to the integration branch. Fix: kb-release plan %s "
              "--reason \"re-cut the branch\", then kb-release promote %s --to DEV"
              % (rid, release_gate.current_stage(rel), rid, rid), file=sys.stderr)
        return 1
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
    p = sub.add_parser("planned-branch")
    p.add_argument("--board", required=True)
    p.add_argument("--release-id", required=True)
    p = sub.add_parser("subsumed-merge")   # XACA-1735: stdout = tree to record the merge with; rc 1 + reason = refuse
    p.add_argument("--repo", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--source", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "item-branch":
            return _cmd_item_branch(a)
        if a.cmd == "subsumed-merge":
            tree, why = subsumed_merge_tree(a.repo, a.target, a.source)
            if tree is None:
                print(why, file=sys.stderr)
                return 1
            print(tree)
            print(why, file=sys.stderr)
            return 0
        board = _load_board(a.board)
        if a.cmd == "branches":
            print(json.dumps(effective_branches(board.get("releaseConfig"))))
            return 0
        rel = _find_release(board, a.release_id)
        if rel is None:
            raise ValueError("release %s not found" % a.release_id)
        if a.cmd == "planned-branch":
            print(planned_branch_label(rel, board))
            return 0
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
