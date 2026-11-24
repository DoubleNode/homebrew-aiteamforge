"""XACA-1736: does the team's version_source file, AT the close-out-bound build, say the release's version?

REL-2026-Q4-070 closed out as tag v1.25.1 at a commit whose VERSION read 1.25.0. kb-release-version-gate compares
VERSION with the release only on the branch-push auto-promote path, and it reads the WORKING TREE. Nothing on the
promote / close-out path compared them at the graded SHA. This module computes the gate-context fact
`version_source` that lcars-ui/server.py (_build_gate_context) and kanban-hooks/release_resume.py hand to
release_gate. Design: docs/release-workflow/closeout-version-source.md.

Pure apart from the injected `read_at_sha(path) -> str | None` (the caller owns git). Never raises.

Fact shape: {"state": "match" | "mismatch" | "unknown" | "skip", "sha": <sha>, "platforms": [row, ...]}
  row = {"platform", "file", "expected", "found", "state"}, where state is match / mismatch / unknown.
  - skip     : no platform of the release has a configured version_source (a team without one, e.g. a
               freelance repo): the check does not apply.
  - match    : every platform WITH a version_source reads exactly its release version at the sha.
  - mismatch : at least one configured platform reads a different version (wins over unknown: the refusal
               then names a concrete fix).
  - unknown  : a configured platform could not be read (config incomplete, sha missing, file absent at the
               sha, pattern did not match, git error). The gate FAILS CLOSED on it.
"""
import os
import re

MATCH, MISMATCH, UNKNOWN, SKIP = "match", "mismatch", "unknown", "skip"
STATES = (MATCH, MISMATCH, UNKNOWN, SKIP)

# Same capture as lcars-ui/server.py _read_release_version_file and kb-release-version-gate Step 3.
_VERSION_CAPTURE = r'([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z0-9.+]+)?)'


def extract_version(text, match_pattern):
    """The version `match_pattern` ('{version}' placeholder) finds in `text`, or None."""
    if not isinstance(text, str) or not isinstance(match_pattern, str) or "{version}" not in match_pattern:
        return None
    regex = re.escape(match_pattern).replace(r'\{version\}', _VERSION_CAPTURE)
    try:
        m = re.search(regex, text)
    except re.error:
        return None
    return m.group(1) if m else None


def version_source_fact(release, sources_for, read_at_sha, sha):
    """-> the fact dict (module docstring). `sources_for(platform) -> list[dict]` returns that platform's configured
    version_sources (the first entry is the one read, the same as the shell gate). `read_at_sha(file) -> str | None`
    returns the file's content at `sha` (None = absent or unreadable). Exceptions from either count as unknown."""
    plats = release.get("platforms") if isinstance(release, dict) else None
    plats = plats if isinstance(plats, dict) else {}
    rows = []
    for name in sorted(plats):
        cfg = plats.get(name)
        try:
            srcs = sources_for(name)
        except Exception:  # noqa: BLE001 -- config unreadable: cannot tell whether the check applies -> unknown
            srcs = None
        if srcs is not None and not isinstance(srcs, list):
            srcs = None   # a dict / number is a malformed config, not "no source": unknown (PR #1407 [Test])
        if srcs is None:
            rows.append({"platform": name, "file": None, "expected": None, "found": None, "state": UNKNOWN})
            continue
        if not srcs:
            continue   # this platform has no version_source: nothing to compare for it
        src = srcs[0] if isinstance(srcs[0], dict) else {}
        expected = cfg.get("version").strip() if isinstance(cfg, dict) and isinstance(cfg.get("version"), str) else ""
        row = {"platform": name, "file": src.get("file"), "expected": expected or None, "found": None,
               "state": UNKNOWN}
        if expected and isinstance(sha, str) and sha and src.get("file") and src.get("match_pattern"):
            try:
                text = read_at_sha(str(src["file"]))
            except Exception:  # noqa: BLE001 -- git error: unknown
                text = None
            found = extract_version(text, src["match_pattern"])
            if found is not None:
                row["found"] = found
                row["state"] = MATCH if found.strip() == expected else MISMATCH
        rows.append(row)
    if not rows:
        state = SKIP
    elif any(r["state"] == MISMATCH for r in rows):
        state = MISMATCH
    elif any(r["state"] == UNKNOWN for r in rows):
        state = UNKNOWN
    else:
        state = MATCH
    return {"state": state, "sha": sha if isinstance(sha, str) else None, "platforms": rows}


def team_fact(release, sha, team, config, repo_root, get_sources, file_at_sha):
    """The fact for `team`, the ONE resolver lcars-ui/server.py (_version_source_fact) and release_resume.py
    (_version_fact) share, so the gate and the resume hint cannot drift. `get_sources(team, platform, config=...)` is
    aiteamforge_paths.get_team_version_sources; `file_at_sha(root, sha, relpath)` is release_branches.file_at_sha.
    A relative version file is resolved against the team's working_dir, then made relative to `repo_root`; a file
    outside the repo (or no repo / working_dir) reads as None, i.e. unknown. Never raises."""
    wd = ((config or {}).get("teams", {}).get(team) or {}).get("working_dir") if isinstance(config, dict) else None

    def read_at_sha(file):
        if repo_root is None:
            return None
        p = os.path.expanduser(str(file))
        if not os.path.isabs(p):
            if not wd:
                return None
            p = os.path.join(os.path.expanduser(str(wd)), p)
        rel = os.path.relpath(os.path.realpath(p), os.path.realpath(str(repo_root)))
        if rel == os.curdir or rel.startswith(os.pardir):
            return None   # outside the team repo: it cannot be read at a commit
        return file_at_sha(str(repo_root), sha, rel.replace(os.sep, "/"))

    return version_source_fact(release, lambda plat: get_sources(team, plat, config=config), read_at_sha, sha)
