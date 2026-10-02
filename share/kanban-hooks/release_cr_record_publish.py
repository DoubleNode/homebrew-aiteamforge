#!/usr/bin/env python3
"""cr-record wiki publisher for `kb-cr complete|close|publish-record` (XACA-1349-006).

Spec: RELEASE-LIFECYCLE.md 12.2 and 3.2 GAMMA. This module only RENDERS and PUBLISHES. It never
writes the board: it prints one JSON verdict on stdout and kb-cr stores the handle under the board
lock (kb-cr.sh `_kb_cr_publish_record`).

    release_cr_record_publish.py --board B --cr-id CR-.. --team T --mode create-or-update|update-only
                                 [--activity-file F]

Verdict (stdout, one JSON object) and exit code:
    0   {"status":"published","mode":"create"|"update","handle":{"pageId","url","version"}}
    10  {"status":"skipped","reason":...}   nothing to do: wiki not configured / cr-record not mapped /
                                            CR has no linked release / update-only with no stored page.
                                            A skip is NOT an error.
    11  {"status":"failed","reason":...}    render or provider error. The CR state is untouched.

Storage convention (decided by the lead): ``.crs[].wikiPages["cr-record"] = {pageId,url,version}``.
Read here through release_cr_stage.get_wiki_handle (the single Python accessor); written by kb-cr
under the board lock (shell side, jq).

Body: the team's resolved cr-record template (team > group > default), rendered against
release_cr_facts.build_cr_fact_set(). The template's first line is the page title ("# <title>"), the
rest is the body. No page format is invented here.

Test hook: KB_CR_RECORD_CONFIG_DIR points at a <kanban>/config dir (wiki.json + profiles) instead of
the team registry lookup; it is also forwarded to kb-wiki as --config-dir.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

EXIT_PUBLISHED, EXIT_SKIPPED, EXIT_FAILED = 0, 10, 11
DOC = "cr-record"

_HERE = Path(__file__).resolve().parent
for _cand in (_HERE.parent / "scripts", _HERE / "scripts", _HERE):
    if (_cand / "release_profile_resolver.py").is_file() and str(_cand) not in sys.path:
        sys.path.insert(0, str(_cand))
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

# to_state -> the kb-cr verb that produced it (activity events record states, not verbs)
_VERB = {
    "cr-drafted": "draft", "cr-published": "publish", "cr-submitted": "submit", "cr-approved": "approve",
    "cr-held": "hold", "cr-rejected": "reject", "cr-completed": "complete", "cr-closed": "close",
    "deployed-prod": "deploy-prod", "emergency-deployed": "deploy-emergency",
}


class _Skip(Exception):
    pass


class _Fail(Exception):
    pass


def _emit(status: str, code: int, **kw: Any) -> int:
    print(json.dumps({"status": status, **kw}, sort_keys=True))
    return code


def _load_json(path: Path, what: str) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        raise _Fail("cannot read %s (%s)" % (what, type(exc).__name__)) from None


def _config_dir(team: str) -> Path:
    override = os.environ.get("KB_CR_RECORD_CONFIG_DIR")
    if override:
        return Path(override)
    try:
        import aiteamforge_paths
        return Path(aiteamforge_paths.get_team_kanban_dir(team)) / "config"
    except Exception:  # unknown team / registry unavailable: no wiki to publish to
        raise _Skip("no kanban config dir resolvable for team '%s'" % team) from None


def _wiki_json(cfg: Path) -> Dict[str, Any]:
    p = cfg / "wiki.json"
    if not p.is_file():
        raise _Skip("wiki not configured for this team (no %s)" % p)
    cfg_obj = _load_json(p, "wiki.json")
    if not isinstance(cfg_obj, dict):
        raise _Fail("wiki.json must be a JSON object")
    doc_types = cfg_obj.get("docTypes")
    if not isinstance(doc_types, dict) or DOC not in doc_types:
        raise _Skip("wiki.json does not map doc type '%s'" % DOC)
    return cfg_obj


def _activity_rows(path: Optional[str]) -> list:
    if not path or not Path(path).is_file():
        return []
    log = _load_json(Path(path), "activity log")
    rows, created = [], []
    for ev in (log.get("events") or []) if isinstance(log, dict) else []:
        if not isinstance(ev, dict):
            continue
        to = ev.get("to_state", "")
        if ev.get("type") == "cr_state_changed":
            rows.append({"ts": ev.get("ts"), "to": to, "verb": ev.get("verb") or _VERB.get(to, ""),
                         "actor": ev.get("actor", ""), "note": ev.get("note", "")})
        elif ev.get("type") == "cr_created":
            # spec 12.4: the creation is the first transition (verb "created", to cr-drafted)
            created.append({"ts": ev.get("ts"), "to": to or "cr-drafted", "verb": "created",
                            "actor": ev.get("actor", ""), "note": ev.get("note", "")})
    return created[:1] + rows  # creation always leads, whatever the log order


def render_record(board: Dict[str, Any], cr: Dict[str, Any], team: str, cfg: Path, wiki: Dict[str, Any],
                  activity_file: Optional[str]) -> Tuple[str, str]:
    """Return (title, body) for the cr-record page."""
    import release_cr_facts as rcf
    import release_profile_resolver as rpr
    import release_template_render as rtr

    rel_id = (cr.get("releaseAssignment") or {}).get("releaseId")
    if not rel_id:
        raise _Skip("CR has no releaseAssignment.releaseId (not part of a release)")
    release = next((r for r in board.get("releases") or [] if isinstance(r, dict) and r.get("id") == rel_id), None)
    if release is None:
        raise _Skip("release '%s' is not on this board" % rel_id)

    resolved = rpr.resolve_profile(team, DOC, kanban_dir=cfg.parent)
    template = resolved.get("template")
    if not template:
        raise _Fail("no cr-record template resolved (team/group/default)")

    tz = ((board.get("teamConfig") or {}).get("crSupport") or {}).get("approval", {}) or {}
    tz = tz.get("tz") if isinstance(tz, dict) else None
    crv = dict(cr)
    crv["activity_log"] = _activity_rows(activity_file)
    kwargs: Dict[str, Any] = {"board": board, "platform_name": str(wiki.get("platformName") or "")}
    if tz:
        kwargs["tz"] = tz
    facts = rcf.build_cr_fact_set(release, crv, **kwargs)
    rendered = rtr.render(template, facts)

    first, _, rest = rendered.partition("\n")
    if not first.startswith("# ") or not first[2:].strip():
        raise _Fail("cr-record template must start with a '# <title>' line")
    return first[2:].strip(), rest.lstrip("\n")


def _kb_wiki_bin() -> list:
    cand = _HERE.parent / "scripts" / "kb-wiki"
    if not cand.is_file():
        cand = _HERE / "kb-wiki"
    return [sys.executable, str(cand)] if cand.is_file() else ["kb-wiki"]


def _adopt_labelled_page(cr_id: str, team: str, title: str) -> Optional[Dict[str, Any]]:
    """The page kb-wiki already created for this CR whose handle never reached the board, or None.
    kb-wiki refuses a second create for the same (doc, key) label, so without this a lost handle left
    publish-record failing forever (XACA-1349-007). Adopts exactly one labelled match; two is ambiguous."""
    cmd = _kb_wiki_bin() + ["find", "--doc", DOC, "--key", cr_id, "--title", title, "--team", team, "--json"]
    cfg_override = os.environ.get("KB_CR_RECORD_CONFIG_DIR")
    if cfg_override:
        cmd += ["--config-dir", cfg_override]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        why = (proc.stderr or "").strip().splitlines()
        raise _Fail("kb-wiki find exit %d (could not check for an existing page): %s"
                    % (proc.returncode, why[-1] if why else "no detail"))
    try:
        matches = json.loads(proc.stdout).get("matches") or []
    except (ValueError, AttributeError):
        raise _Fail("kb-wiki find printed unparseable output") from None
    label = "kb-wiki-%s-%s" % (DOC, cr_id.lower())
    hits = [m for m in matches if isinstance(m, dict) and label in (m.get("labels") or [])]
    if len(hits) > 1:
        raise _Fail("%d wiki pages carry the label %s; resolve that in the wiki first" % (len(hits), label))
    if not hits:
        return None
    m = hits[0]
    try:
        return {"pageId": str(m["pageId"]), "url": str(m.get("url", "")), "version": int(m["version"])}
    except (KeyError, TypeError, ValueError):
        raise _Fail("kb-wiki find returned a malformed match for %s" % label) from None


def publish(board_path: str, cr_id: str, team: str, mode: str, activity_file: Optional[str]) -> int:
    try:
        board = _load_json(Path(board_path), "board")
        cr = next((c for c in board.get("crs") or [] if isinstance(c, dict) and c.get("id") == cr_id), None)
        if cr is None:
            raise _Fail("CR '%s' not found on board" % cr_id)
        from release_cr_stage import CrStageError, get_wiki_handle
        try:
            stored = get_wiki_handle(cr, DOC)
        except CrStageError as exc:
            raise _Fail("stored wikiPages.%s is malformed: %s" % (DOC, exc))
        if stored is None and mode == "update-only":
            raise _Skip("no cr-record page was ever published for %s; nothing to re-publish" % cr_id)

        cfg = _config_dir(team)
        wiki = _wiki_json(cfg)
        title, body = render_record(board, cr, team, cfg, wiki, activity_file)

        if stored is None:  # a crash after kb-wiki's create left a labelled page the board forgot
            stored = _adopt_labelled_page(cr_id, team, title)
        with tempfile.TemporaryDirectory(prefix="kb-cr-record-") as tmp:
            bf = Path(tmp) / "body.md"
            bf.write_text(body)
            cmd = _kb_wiki_bin() + ["publish", "--doc", DOC, "--key", cr_id, "--title", title,
                                    "--body-file", str(bf), "--team", team, "--json"]
            if os.environ.get("KB_CR_RECORD_CONFIG_DIR"):
                cmd += ["--config-dir", os.environ["KB_CR_RECORD_CONFIG_DIR"]]
            if stored:
                cmd += ["--page-id", str(stored["pageId"]), "--stored-version", str(stored["version"])]
            proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            if proc.returncode == 4:
                raise _Fail("version guard: the page was edited since version %s; kb-wiki refused to "
                            "overwrite (reconcile by hand, then re-run)" % (stored or {}).get("version"))
            why = (proc.stderr or "").strip().splitlines()
            raise _Fail("kb-wiki publish exit %d: %s" % (proc.returncode, why[-1] if why else "no detail"))
        try:
            handle = json.loads(proc.stdout)
            out = {"pageId": str(handle["pageId"]), "url": str(handle["url"]), "version": int(handle["version"])}
        except (ValueError, KeyError, TypeError):
            raise _Fail("kb-wiki printed an unparseable handle") from None
        return _emit("published", EXIT_PUBLISHED, mode="update" if stored else "create", handle=out)
    except _Skip as exc:
        return _emit("skipped", EXIT_SKIPPED, reason=str(exc))
    except _Fail as exc:
        return _emit("failed", EXIT_FAILED, reason=str(exc))
    except Exception as exc:  # fail closed: any render/facts error is a reported failure, never a crash
        return _emit("failed", EXIT_FAILED, reason="%s: %s" % (type(exc).__name__, str(exc)[:300]))


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--board", required=True)
    ap.add_argument("--cr-id", required=True)
    ap.add_argument("--team", required=True)
    ap.add_argument("--mode", choices=("create-or-update", "update-only"), default="create-or-update")
    ap.add_argument("--activity-file")
    a = ap.parse_args(argv)
    return publish(a.board, a.cr_id, a.team, a.mode, a.activity_file)


if __name__ == "__main__":
    sys.exit(main())
