"""Rollback-target resolver for GAMMA entry (XACA-1349-004, spec RELEASE-LIFECYCLE.md 3.2 / 13.3).

Spec 13.3: "A rollback target MUST exist before any production deploy. The engine refuses GAMMA
entry if it cannot determine the current production SHA."

SOURCE OF TRUTH (user decision 2026-10-02): the git production tag. The newest release tag
(`<prefix><n>.<n>[.<n>[.<n>]]`, default prefix `v`) reachable from the production branch
(`releaseConfig.branches.production`, default `master`), resolved with `rev-parse <tag>^{commit}`.
Spec 4.2 makes the PROD close-out tag `v<ver>` point at stageSha.GAMMA, so this IS the SHA that
last shipped. Board history is NEVER consulted.

Config (all optional), read from the board's releaseConfig, platform overriding team overriding default:
  releaseConfig.branches.production              "master"
  releaseConfig.prodTag = {prefix, sort}         prefix "v", sort "version" | "date"
  releaseConfig.platforms.<p>.prodTag = {...}    per-platform override (same shape)
A release spanning platforms whose effective config differs is refused as ambiguous.

Lead override: release.rollbackShaOverride = {sha, reason, by, at}. Honoured ONLY when sha is
40-hex and reason and by are non-empty strings. A PRESENT-but-malformed override refuses; it never
falls through to the tag.

Pure apart from the injectable `lookup(repo_root, branch, prefix, sort)`; `git_prod_tag_lookup` is
the real one. Anything that cannot be determined is a REFUSAL (ok=False), never "no rollback
target, proceed".
"""
import re
import subprocess

DEFAULT_BRANCH = "master"
DEFAULT_PREFIX = "v"
DEFAULT_SORT = "version"
SORTS = {"version": "-v:refname", "date": "-creatordate"}

_SHA40 = re.compile(r"[0-9a-fA-F]{40}")
_SAFE_REF = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}")
_SAFE_PREFIX = re.compile(r"[A-Za-z0-9._/][A-Za-z0-9._/-]{0,31}|")


def override_howto(release_id):
    return ('set a lead override: kb-release rollback-override %s <40-hex-prod-sha> '
            '--reason "<why>" --by <lead>' % (release_id or "<REL-ID>"))


def validate_override(ov):
    """(ok, problem). `ov` is release.rollbackShaOverride (not None)."""
    if not isinstance(ov, dict):
        return False, "rollbackShaOverride is not an object"
    if not isinstance(ov.get("sha"), str) or not _SHA40.fullmatch(ov["sha"]):
        return False, "rollbackShaOverride.sha is not a 40-character hex SHA"
    for k in ("reason", "by"):
        if not isinstance(ov.get(k), str) or not ov[k].strip():
            return False, "rollbackShaOverride.%s is missing or blank" % k
    return True, None


def effective_config(release_config, release):
    """(cfg, problem): {branch, prefix, sort} for this release, or (None, why)."""
    rc = release_config if isinstance(release_config, dict) else {}
    branches = rc.get("branches") if isinstance(rc.get("branches"), dict) else {}
    branch = branches.get("production", DEFAULT_BRANCH)
    team_tag = rc.get("prodTag") if isinstance(rc.get("prodTag"), dict) else {}
    plats = release.get("platforms") if isinstance(release, dict) and isinstance(release.get("platforms"), dict) else {}
    plat_cfg = rc.get("platforms") if isinstance(rc.get("platforms"), dict) else {}
    seen = []
    for p in (list(plats) or [None]):
        pc = plat_cfg.get(p) if p is not None and isinstance(plat_cfg.get(p), dict) else {}
        pt = pc.get("prodTag") if isinstance(pc.get("prodTag"), dict) else {}
        eff = (pt.get("prefix", team_tag.get("prefix", DEFAULT_PREFIX)),
               pt.get("sort", team_tag.get("sort", DEFAULT_SORT)))
        if eff not in seen:
            seen.append(eff)
    if len(seen) > 1:
        return None, ("platforms of this release have different prodTag settings %s; "
                      "cannot pick one production tag" % seen)
    prefix, sort = seen[0]
    if not isinstance(branch, str) or not _SAFE_REF.fullmatch(branch):
        return None, "releaseConfig.branches.production %r is not a usable branch name" % (branch,)
    if not isinstance(prefix, str) or not _SAFE_PREFIX.fullmatch(prefix):
        return None, "prodTag.prefix %r is not usable (letters, digits, . _ / - only)" % (prefix,)
    if sort not in SORTS:
        return None, "prodTag.sort %r is not one of %s" % (sort, sorted(SORTS))
    return {"branch": branch, "prefix": prefix, "sort": sort}, None


def _git(repo_root, *args):
    import os
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    return subprocess.run(["git", "-C", str(repo_root)] + list(args), capture_output=True, text=True,
                          timeout=10, env=env)


def _production_tip(repo_root, branch):
    """The commit that IS production on this clone, or None when the branch exists nowhere (XACA-1349-007).

    A clone's LOCAL production branch is routinely stale (the lead works on develop and production closes
    out on the remote), so reading only `refs/heads/<branch>` named a release two versions back as the
    rollback target. Every copy counts: the local branch and `refs/remotes/<any remote>/<branch>`. The tip
    is the copy that contains all the others; copies that diverge are ambiguous and RAISE (the resolver
    refuses, the lead states the SHA with rollback-override)."""
    refs = ["refs/heads/%s" % branch]
    listed = _git(repo_root, "for-each-ref", "--format=%(refname)", "refs/remotes/*/%s" % branch)
    if listed.returncode == 0:
        refs += [r for r in (listed.stdout or "").split() if not r.endswith("/HEAD")]
    tips = []
    for ref in refs:
        c = _git(repo_root, "rev-parse", "--verify", "--quiet", "%s^{commit}" % ref)
        sha = (c.stdout or "").strip()
        if c.returncode == 0 and _SHA40.fullmatch(sha) and sha not in tips:
            tips.append(sha)
    if not tips:
        return None
    for cand in tips:
        if all(o == cand or _git(repo_root, "merge-base", "--is-ancestor", o, cand).returncode == 0
               for o in tips):
            return cand
    raise RuntimeError("the copies of production branch '%s' diverge (%s); cannot tell which is production"
                       % (branch, ", ".join(t[:10] for t in tips)))


def git_prod_tag_lookup(repo_root, branch, prefix, sort):
    """The real lookup: {"tag", "sha"} for the newest release tag merged into `branch`, or None when
    the branch or every candidate tag is absent. Raises on git failure (the resolver refuses)."""
    tip = _production_tip(repo_root, branch)
    if tip is None:
        return None
    t = _git(repo_root, "tag", "--merged", tip, "--list", prefix + "*", "--sort=" + SORTS[sort])
    if t.returncode != 0:
        raise RuntimeError("git tag failed: %s" % (t.stderr or "").strip()[:200])
    pat = re.compile(r"%s\d+(\.\d+){1,3}" % re.escape(prefix))
    for name in (t.stdout or "").split():
        if pat.fullmatch(name):
            c = _git(repo_root, "rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % name)
            sha = (c.stdout or "").strip()
            if c.returncode == 0 and _SHA40.fullmatch(sha):
                return {"tag": name, "sha": sha.lower()}
    return None


def resolve_rollback(release, release_config, *, lookup=git_prod_tag_lookup, repo_root=None):
    """{"ok": True, "sha", "source"} or {"ok": False, "reason"}. Never raises."""
    rid = release.get("id") if isinstance(release, dict) else None
    howto = override_howto(rid)
    try:
        if isinstance(release, dict) and release.get("rollbackShaOverride") is not None:
            ok, problem = validate_override(release["rollbackShaOverride"])
            if not ok:
                return {"ok": False, "reason": "%s (a malformed override is refused, not ignored); fix it: %s"
                                               % (problem, howto)}
            return {"ok": True, "sha": release["rollbackShaOverride"]["sha"].lower(), "source": "override"}
        cfg, problem = effective_config(release_config, release or {})
        if cfg is None:
            return {"ok": False, "reason": "%s; fix the config or %s" % (problem, howto)}
        if repo_root is None:
            return {"ok": False, "reason": "team git repository not found, cannot read the production tag; %s" % howto}
        found = lookup(repo_root, cfg["branch"], cfg["prefix"], cfg["sort"])
        if not isinstance(found, dict) or not isinstance(found.get("sha"), str) \
                or not _SHA40.fullmatch(found["sha"]) or not isinstance(found.get("tag"), str) or not found["tag"]:
            return {"ok": False, "reason": "no %s<version> tag found on production branch '%s'; %s"
                                           % (cfg["prefix"], cfg["branch"], howto)}
        return {"ok": True, "sha": found["sha"].lower(), "source": "tag:%s" % found["tag"]}
    except Exception as e:  # noqa: BLE001 - fail closed on ANY lookup failure
        return {"ok": False, "reason": "production SHA lookup failed (%s: %s); %s" % (type(e).__name__, e, howto)}
