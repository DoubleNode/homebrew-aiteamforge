#!/usr/bin/env python3
"""The living "Release & CR Status" wiki page publisher (XACA-1349-006, reshaped by XACA-1662-002).

Spec: RELEASE-LIFECYCLE.md 12.2 / 12.4 and the XACA-1662 handle-model design. ONE page per release (doc type
``cr-record``, kb-wiki key = the release id), created at PLANNED -> DEV and rewritten after every release stage
change and every Change Request state change. This module is the single renderer, publisher and handle writer;
kb-cr, the LCARS promote endpoint and the backfill all call it.

    release_cr_record_publish.py --board B --team T (--release-id REL | --cr-id CR) --reason <event>
                                 [--mode create-or-update|update-only] [--activity-file F] [--refresh-testing-log]

    --cr-id CR     resolves CR -> releaseAssignment.releaseId (back-compat for ``kb-cr publish-record <CR>``)
    --mode         create-or-update (default) | update-only. A create is SKIPPED while the release is PLANNED.
    --activity-file  legacy: the activity log of --cr-id (the others are read from <board dir>/change-requests/activity)

stdout is ONE JSON object:
    {"status": "published|skipped|failed", "releaseId", "reason"?, "recordMode": "create|update|adopt",
     "handle"?, "testingLog": {"status", "handle"?, "reason"?}, "mirroredCrs": [...], "handleUnstored"?: true,
     "rerun": "kb-cr publish-record <REL-ID>"}
Exit codes:  0 published | 10 skipped (nothing to do: wiki unconfigured, cr-record unmapped, no release, release
still PLANNED, CR support off, update-only with no page) -- a skip is NOT an error | 11 failed.

Order (all under a per-release flock, so a promote racing a CR transition cannot race the version guard):
  1. resolve the handle: the release's own (``wikiPages["cr-record"]``, kb-wiki key = ``handle.key`` else the
     release id), else ADOPT (never duplicate): a labelled new-key page whose handle was lost, then the legacy
     CR-keyed page(s) (adopted WITH ``key`` = that CR's id, so the existing label still matches), then a legacy
     page with no handle on the board, else create with ``--key <release id>``.
  2. CR teams, stage DEV or later: make sure the Testing Log exists (release_cr_stage.publish_testing_log).
  3. render the page (the current CR plus the history of every other linked CR) and kb-wiki publish it.
  4. store the release handle and mirror it to every linked CR in ONE locked board write (set_wiki_handle).
The board lock is never held across a network call.

Never publishes the CR Request page: every kb-wiki call goes through ``_kb_wiki`` which only allows
``_ALLOWED_DOCS``, and kb-wiki itself refuses the cr doc type because KB_WIKI_DENY_DOCS=cr is exported here.

Test hook: KB_CR_RECORD_CONFIG_DIR points at a <kanban>/config dir (wiki.json + profiles) instead of the team
registry lookup; it is also forwarded to kb-wiki as --config-dir.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

EXIT_PUBLISHED, EXIT_SKIPPED, EXIT_FAILED = 0, 10, 11
DOC = "cr-record"
TESTING_LOG_DOC = "testing-log"
_ALLOWED_DOCS = frozenset({DOC, TESTING_LOG_DOC})  # the CR Request ("cr") page is never touched from here
DENY_DOCS_ENV = "KB_WIKI_DENY_DOCS"
LOCK_TIMEOUT_S = 120

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
_RETIRED = ("cr-closed", "cr-rejected")
_STAGES = ("PLANNED", "DEV", "QA", "ALPHA", "BETA", "CR", "GAMMA", "PROD")


class _Skip(Exception):
    pass


class _Fail(Exception):
    def __init__(self, msg: str, **extra: Any):
        Exception.__init__(self, msg)
        self.extra = extra


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


def _activity_path(board_path: str, cr_id: str) -> Path:
    return Path(board_path).parent / "change-requests" / "activity" / ("%s.json" % cr_id)


def _activity_rows(path: Optional[Any]) -> list:
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


# ------------------------------------------------------------------------------------------ board reads

def _find_release(board: Dict[str, Any], rel_id: str) -> Optional[Dict[str, Any]]:
    return next((r for r in board.get("releases") or [] if isinstance(r, dict) and r.get("id") == rel_id), None)


def _stage_of(release: Dict[str, Any]) -> str:
    return str(release.get("stage") or release.get("currentStage") or "")


def _excluded(board: Dict[str, Any]) -> frozenset:
    """teamConfig.migration.excludeCrIds (spec 15.1; shared reader with migrate-cr-legacy-state.py's rule). A
    malformed list is a reported failure, never a guess: the exclusion is a never-touch promise."""
    import cr_exclusions
    try:
        return cr_exclusions.excluded_set(board)
    except cr_exclusions.ConfigError as exc:
        raise _Fail("cannot read the CR exclusion list: %s" % exc) from None


def _cr_support_enabled(board: Dict[str, Any]) -> bool:
    cs = (board.get("teamConfig") or {}).get("crSupport")
    return isinstance(cs, dict) and cs.get("enabled") is True


def _linked(board: Dict[str, Any], release: Dict[str, Any]) -> List[Dict[str, Any]]:
    import approval_providers as ap
    try:
        crs, _missing = ap._linked_crs(board, release)  # the one linkage rule the gate feed also uses
    except Exception as exc:  # noqa: BLE001
        raise _Fail("cannot read the CRs linked to %s: %s" % (release.get("id"), exc)) from None
    return list(crs)


def _is_open(cr: Dict[str, Any]) -> bool:
    from release_cr_stage import is_gamma_held
    return cr.get("crState") not in _RETIRED and not is_gamma_held(cr)


def _current_cr(linked: List[Dict[str, Any]], prefer: Optional[str]) -> Optional[Dict[str, Any]]:
    """The one open CR the status header describes (the _open_cr rule), else None. More than one open CR is a
    state the CR stage refuses; the page must still render, so take the named one, else the latest touched."""
    open_crs = [c for c in linked if _is_open(c)]
    if not open_crs:
        return None
    if prefer:
        for c in open_crs:
            if c.get("id") == prefer:
                return c
    return max(open_crs, key=lambda c: str(c.get("updatedAt") or c.get("createdAt") or ""))


# ------------------------------------------------------------------------------------------ rendering

def render_status(board: Dict[str, Any], release: Dict[str, Any], linked: List[Dict[str, Any]],
                  current: Optional[Dict[str, Any]], team: str, cfg: Path, wiki: Dict[str, Any],
                  board_path: Optional[str] = None, activity_file: Optional[str] = None,
                  now: Optional[datetime] = None) -> Tuple[str, str]:
    """Return (title, body) for the release's living status page."""
    import release_cr_facts as rcf
    import release_profile_resolver as rpr
    import release_template_render as rtr

    resolved = rpr.resolve_profile(team, DOC, kanban_dir=cfg.parent)
    template = resolved.get("template")
    if not template:
        raise _Fail("no cr-record template resolved (team/group/default)")

    tz = ((board.get("teamConfig") or {}).get("crSupport") or {}).get("approval", {}) or {}
    tz = tz.get("tz") if isinstance(tz, dict) else None
    pname = str(wiki.get("platformName") or "")

    def rows_for(cr: Dict[str, Any]) -> list:
        if activity_file and current is not None and cr.get("id") == current.get("id"):
            return _activity_rows(activity_file)
        if board_path:
            return _activity_rows(_activity_path(board_path, str(cr.get("id") or "")))
        return []

    # XACA-1577: adapt the raw board records exactly as the CR stage does. A board CR's approver may be a
    # {login,name} object (and links/timestamps are nested); the template reads flat strings. The adapters deep-copy.
    try:
        def adapt(cr: Dict[str, Any]) -> Dict[str, Any]:
            v = rcf.cr_record_for_facts(cr, release=release)
            v["activity_log"] = rows_for(cr)  # our own rows (created/_VERB), not the adapter's
            return v
        crv = adapt(current) if current is not None else None
        relr = rcf.release_record_for_facts(release, cr=current, platform_name=pname)
        kwargs: Dict[str, Any] = {"platform_name": pname, "linked_crs": [adapt(c) for c in linked]}
        if tz:
            kwargs["tz"] = tz
        if now is not None:
            kwargs["now"] = now
        rel_prepared = rcf.prepare_release_record(relr, board=board)
        facts = rcf.fd.build_fact_set(rel_prepared, crv, **kwargs)
    except ValueError as exc:  # FactSetError: malformed links/timestamps or ambiguous platform
        raise _Fail("cannot assemble the CR facts: %s" % exc) from None
    try:
        rendered = rtr.render(template, facts)
    except Exception as exc:  # noqa: BLE001 -- TemplateRenderError
        raise _Fail("the cr-record template did not render: %s" % exc) from None

    first, _, rest = rendered.partition("\n")
    if not first.startswith("# ") or not first[2:].strip():
        raise _Fail("cr-record template must start with a '# <title>' line")
    return first[2:].strip(), rest.lstrip("\n")


def render_record(board: Dict[str, Any], cr: Dict[str, Any], team: str, cfg: Path, wiki: Dict[str, Any],
                  activity_file: Optional[str]) -> Tuple[str, str]:
    """Back-compat entry (XACA-1577 tests): render the status page of the release ``cr`` belongs to."""
    rel_id = (cr.get("releaseAssignment") or {}).get("releaseId")
    if not rel_id:
        raise _Skip("CR has no releaseAssignment.releaseId (not part of a release)")
    release = _find_release(board, rel_id)
    if release is None:
        raise _Skip("release '%s' is not on this board" % rel_id)
    linked = _linked(board, release)
    if not any(c.get("id") == cr.get("id") for c in linked):
        linked.append(cr)
    return render_status(board, release, linked, cr, team, cfg, wiki, None, activity_file)


# ------------------------------------------------------------------------------------------ kb-wiki

def _kb_wiki_bin() -> list:
    # TEST-ONLY SEAM (XACA-1662-005): KB_CR_RECORD_KB_WIKI=<path to a python script> replaces the kb-wiki that is
    # run, so a test can capture every argv this publisher issues. Honoured ONLY when set and non-empty; unset
    # (every production path) resolves scripts/kb-wiki exactly as before. The override is still run through the
    # allowlist and deny env in _kb_wiki, so it cannot widen what the publisher may write.
    override = os.environ.get("KB_CR_RECORD_KB_WIKI")
    if override:
        return [sys.executable, override]
    cand = _HERE.parent / "scripts" / "kb-wiki"
    if not cand.is_file():
        cand = _HERE / "kb-wiki"
    return [sys.executable, str(cand)] if cand.is_file() else ["kb-wiki"]


def _kb_wiki(argv: List[str], team: str) -> "subprocess.CompletedProcess[str]":
    """THE single kb-wiki call site. Refuses any doc outside _ALLOWED_DOCS (the CR Request page is the
    approver's artifact; a living-page refresh must never write it) and exports KB_WIKI_DENY_DOCS=cr so kb-wiki
    itself refuses it too."""
    doc = argv[argv.index("--doc") + 1] if "--doc" in argv and argv.index("--doc") + 1 < len(argv) else None
    if doc not in _ALLOWED_DOCS:
        raise _Fail("refused: kb-wiki doc %r is not allowed from the status-page publisher" % (doc,))
    cmd = _kb_wiki_bin() + list(argv) + ["--team", team, "--json"]
    if os.environ.get("KB_CR_RECORD_CONFIG_DIR"):
        cmd += ["--config-dir", os.environ["KB_CR_RECORD_CONFIG_DIR"]]
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    env[DENY_DOCS_ENV] = "cr"
    return subprocess.run(cmd, capture_output=True, text=True, env=env)


def _find_labelled(key: str, title: str, team: str, label_doc: str = DOC) -> Optional[Dict[str, Any]]:
    """The page kb-wiki already created for (doc, key) whose handle never reached the board, or None. kb-wiki
    refuses a second create for the same label, so without this a lost handle left the publish failing forever
    (XACA-1349-007). Adopts exactly one labelled match; two is ambiguous."""
    proc = _kb_wiki(["find", "--doc", label_doc, "--key", key, "--title", title], team)
    if proc.returncode != 0:
        why = (proc.stderr or "").strip().splitlines()
        raise _Fail("kb-wiki find exit %d (could not check for an existing page): %s"
                    % (proc.returncode, why[-1] if why else "no detail"))
    try:
        matches = json.loads(proc.stdout).get("matches") or []
    except (ValueError, AttributeError):
        raise _Fail("kb-wiki find printed unparseable output") from None
    label = "kb-wiki-%s-%s" % (label_doc, key.lower())
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


# back-compat name (XACA-1349-007 tests / callers)
def _adopt_labelled_page(cr_id: str, team: str, title: str) -> Optional[Dict[str, Any]]:
    return _find_labelled(cr_id, title, team)


class _TestingLogTools:
    """The slice of CrStage's Tools the Testing Log publish uses, routed through the allowlisted ``_kb_wiki``."""

    def __init__(self, team: str):
        self.team = team

    def activity(self, board_file: str, cr_id: str) -> list:  # not used with cr=None; kept for the interface
        return []

    def _run(self, argv: List[str]) -> Dict[str, Any]:
        from release_cr_stage import ToolError
        proc = _kb_wiki(argv, self.team)
        out: Dict[str, Any] = {}
        if (proc.stdout or "").strip():
            try:
                out = json.loads(proc.stdout)
            except ValueError:
                raise ToolError("kb-wiki printed non-JSON on stdout", 1) from None
        if proc.returncode == 4:
            raise ToolError("the %s page changed in the wiki since it was last published (version guard); "
                            "refusing to overwrite it: %s" % (argv[argv.index("--doc") + 1], out.get("message", "")), 4)
        if proc.returncode != 0:
            raise ToolError("kb-wiki %s failed (exit %d): %s" % (argv[0], proc.returncode,
                                                                 (proc.stderr or "").strip()[-400:]), proc.returncode)
        return out

    def wiki_find(self, doc: str, key: str, title: str) -> List[Dict[str, Any]]:
        return list(self._run(["find", "--doc", doc, "--key", key, "--title", title]).get("matches") or [])

    def wiki_publish(self, doc: str, key: str, title: str, body: str, *, page_id: Optional[str] = None,
                     stored_version: Optional[int] = None, attachments: Optional[list] = None) -> Dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="kb-cr-record-tl-") as tmp:
            bf = os.path.join(tmp, "body.md")
            with open(bf, "w", encoding="utf-8") as fh:
                fh.write(body)
            args = ["publish", "--doc", doc, "--key", key, "--title", title, "--body-file", bf,
                    "--body-format", "markdown"]
            if attachments:
                af = os.path.join(tmp, "attachments.json")
                with open(af, "w", encoding="utf-8") as fh:
                    fh.write(json.dumps(attachments))
                args += ["--attachments-file", af]
            if page_id:
                args += ["--page-id", page_id, "--stored-version", str(stored_version)]
            return self._run(args)


# ------------------------------------------------------------------------------------------ lock

@contextlib.contextmanager
def _release_lock(board_path: str, rel_id: str):
    d = Path(board_path).parent / "change-requests"
    d.mkdir(parents=True, exist_ok=True)
    safe = "".join(ch if ch.isalnum() or ch in "-._" else "_" for ch in rel_id)
    fh = open(d / (".cr-record-%s.lock" % safe), "a+")
    try:
        deadline = time.monotonic() + LOCK_TIMEOUT_S
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise _Fail("timed out waiting for the cr-record lock of %s (another refresh is running)" % rel_id)
                time.sleep(0.2)
        yield
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        finally:
            fh.close()


# ------------------------------------------------------------------------------------------ handle resolution

def _handle_of(rec: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    from release_cr_stage import CrStageError, get_wiki_handle
    try:
        return get_wiki_handle(rec, DOC)
    except CrStageError as exc:
        raise _Fail("stored wikiPages.%s of %s is malformed: %s" % (DOC, rec.get("id"), exc)) from None


def _resolve_handle(release: Dict[str, Any], linked: List[Dict[str, Any]], current: Optional[Dict[str, Any]],
                    title: str, team: str, platform_version: str) -> Tuple[Optional[Dict[str, Any]], str, str]:
    """-> (handle or None, kb-wiki key, recordMode). The adopt-don't-duplicate order of design 017 section 3."""
    rel_id = str(release["id"])
    stored = _handle_of(release)
    if stored is not None:
        return stored, stored.get("key") or rel_id, "update"
    # 1. a new-key page whose handle was lost (crash between kb-wiki and the board write)
    hit = _find_labelled(rel_id, title, team)
    if hit:
        return hit, rel_id, "adopt"
    handles = [(c, _handle_of(c)) for c in linked]
    handles = [(c, h) for c, h in handles if h is not None]
    # 1b. a CR mirror that already names this release: the release handle was lost, the page key is the release id
    for c, h in handles:
        if h.get("releaseId") == rel_id:
            return {k: h[k] for k in ("pageId", "url", "version")}, rel_id, "adopt"
    # 2. legacy CR-keyed pages that DO have a handle on a CR (no releaseId = written before this design)
    legacy = [(c, h) for c, h in handles if not h.get("releaseId")]
    if legacy:
        pages: Dict[str, List[Tuple[Dict[str, Any], Dict[str, Any]]]] = {}
        for c, h in legacy:
            pages.setdefault(h["pageId"], []).append((c, h))
        if len(pages) == 1:
            owner, h = next(iter(pages.values()))[0]
        else:  # the current CR's page, else the most recently touched
            cur_id = (current or {}).get("id")
            pick = next((p for p in legacy if p[0].get("id") == cur_id), None) \
                or max(legacy, key=lambda p: str(p[0].get("updatedAt") or ""))
            owner, h = pick
        return dict(h, key=str(owner["id"])), str(owner["id"]), "adopt"
    # 3. a legacy page with no handle on the board: the old title, CR key
    legacy_title_base = "v%s - %s - " % (platform_version, rel_id)
    for c in ([current] if current else []) + [c for c in linked if c is not current]:
        found = _find_labelled(str(c["id"]), legacy_title_base + str(c["id"]), team)
        if found:
            return dict(found, key=str(c["id"])), str(c["id"]), "adopt"
    return None, rel_id, "create"


# ------------------------------------------------------------------------------------------ the refresh

def _mirror_edit(rel_id: str, handle: Dict[str, Any], release_page_ids: set):
    """The closure that writes the CR-side mirror under the board lock. A CR handle that points at a DIFFERENT
    page and carries no releaseId is a frozen legacy record and is never overwritten (design 017 section 1)."""
    mirror = dict(handle, releaseId=rel_id)

    def edit(cr: Dict[str, Any]) -> None:
        pages = cr.get("wikiPages")
        if not isinstance(pages, dict):
            pages = cr["wikiPages"] = {}
        cur = pages.get(DOC)
        if cur is not None:
            if not isinstance(cur, dict):
                return
            owner = cur.get("releaseId")
            if owner:
                if owner != rel_id:
                    return
            elif str(cur.get("pageId")) not in release_page_ids:
                return
        pages[DOC] = dict(mirror)
    return edit


def refresh(board_path: str, team: str, *, release_id: Optional[str] = None, cr_id: Optional[str] = None,
            reason: str = "", mode: str = "create-or-update", activity_file: Optional[str] = None,
            refresh_testing_log: bool = False, now: Optional[datetime] = None) -> Tuple[int, Dict[str, Any]]:
    """Run one refresh. Returns (exit code, verdict dict). Never raises."""
    verdict: Dict[str, Any] = {}
    rel_label = release_id or ""
    try:
        board = _load_json(Path(board_path), "board")
        if release_id is None:
            cr = next((c for c in board.get("crs") or [] if isinstance(c, dict) and c.get("id") == cr_id), None)
            if cr is None:
                raise _Fail("CR '%s' not found on board" % cr_id)
            if cr_id in _excluded(board):  # spec 15.1: finishes on its current path; no page, no mirror, no wiki call
                verdict["releaseId"] = str((cr.get("releaseAssignment") or {}).get("releaseId") or "")
                raise _Skip("CR %s is listed in teamConfig.migration.excludeCrIds (spec 15.1); excluded CRs are "
                            "never published or mirrored" % cr_id)
            release_id = (cr.get("releaseAssignment") or {}).get("releaseId")
            if not release_id:
                raise _Skip("CR has no releaseAssignment.releaseId (not part of a release)")
        rel_label = str(release_id)
        verdict["releaseId"] = rel_label
        verdict["rerun"] = "kb-cr publish-record %s" % rel_label
        if reason:
            verdict["event"] = reason
        release = _find_release(board, rel_label)
        if release is None:
            raise _Skip("release '%s' is not on this board" % rel_label)

        # XACA-1662-021: NO process-global env write here. The deny is injected per call by _kb_wiki (env=), the
        # ONLY kb-wiki call site (nested CrStage tools route through it too); the old global write leaked into
        # every in-process caller ("doc 'cr' is denied" in unrelated suites).
        cfg = _config_dir(team)
        wiki = _wiki_json(cfg)
        with _release_lock(board_path, rel_label):
            board = _load_json(Path(board_path), "board")  # fresh, now that we hold the lock
            release = _find_release(board, rel_label)
            if release is None:
                raise _Skip("release '%s' is not on this board" % rel_label)
            return _refresh_locked(board_path, board, release, team, cfg, wiki, cr_id, mode, activity_file,
                                   refresh_testing_log, now, verdict)
    except _Skip as exc:
        verdict.update(status="skipped", reason=str(exc))
        return EXIT_SKIPPED, verdict
    except _Fail as exc:
        verdict.update(status="failed", reason=str(exc), **exc.extra)
        return EXIT_FAILED, verdict
    except Exception as exc:  # fail closed: any render/facts error is a reported failure, never a crash
        verdict.update(status="failed", reason="%s: %s" % (type(exc).__name__, str(exc)[:300]))
        return EXIT_FAILED, verdict


def _refresh_locked(board_path, board, release, team, cfg, wiki, cr_id, mode, activity_file, refresh_testing_log,
                    now, verdict) -> Tuple[int, Dict[str, Any]]:
    from release_cr_stage import CrStageError, ToolError, get_wiki_handle, publish_testing_log, set_wiki_handle
    rel_id = str(release["id"])
    stage = _stage_of(release)
    linked = _linked(board, release)
    stored = _handle_of(release)
    if stored is None and mode == "update-only":
        raise _Skip("no cr-record page was ever published for %s; nothing to re-publish" % rel_id)
    excluded = _excluded(board)  # spec 15.1: listed on the page, but never mirrored onto (handles are not written)
    cr_team = _cr_support_enabled(board)
    if not cr_team and not linked:
        raise _Skip("CR support is not enabled for this team and %s has no linked CR" % rel_id)
    if stored is None and stage not in _STAGES[1:]:
        raise _Skip("release %s is %s; the status page is created at PLANNED -> DEV"
                    % (rel_id, stage or "at no known stage"))

    # --- Testing Log (CR teams, DEV or later): exists before the status page links it
    tl: Dict[str, Any] = {"status": "skipped"}
    tl_failed = False
    if cr_team and stage in _STAGES[1:] and TESTING_LOG_DOC in (wiki.get("docTypes") or {}):
        try:
            have = get_wiki_handle(release, TESTING_LOG_DOC)
            if have is None or refresh_testing_log:
                res = publish_testing_log(board_path, rel_id, team, str(cfg.parent), _TestingLogTools(team),
                                          update=bool(have),
                                          mirror_cr_ids=[str(c["id"]) for c in linked
                                                 if c.get("id") and str(c["id"]) not in excluded])
                tl = {"status": res["action"], "handle": res["handle"]}
            else:
                tl = {"status": "present", "handle": have}
        except (CrStageError, ToolError, _Fail) as exc:
            tl, tl_failed = {"status": "failed", "reason": str(exc)[:400]}, True
        board = _load_json(Path(board_path), "board")  # the log's handle/links are now on the board
        release = _find_release(board, rel_id) or release
        linked = _linked(board, release)
    elif cr_team and stage in _STAGES[1:]:
        tl = {"status": "skipped", "reason": "wiki.json does not map doc type 'testing-log'"}
    verdict["testingLog"] = tl

    current = _current_cr(linked, cr_id)
    title, body = render_status(board, release, linked, current, team, cfg, wiki, board_path, activity_file, now)
    pv = str(release.get("version") or "")
    if not pv:
        import release_cr_facts as rcf
        pv = str(rcf.release_record_for_facts(release, cr=current, platform_name=str(wiki.get("platformName") or ""))
                 .get("version") or "")
    # spec 15.1: an excluded CR's own (legacy) page is its own; it is never ADOPTED as the release page
    adoptable = [c for c in linked if str(c.get("id")) not in excluded]
    adopt_cur = current if current is not None and str(current.get("id")) not in excluded else None
    handle, key, rmode = _resolve_handle(release, adoptable, adopt_cur, title, team, pv)
    if handle is None and mode == "update-only":
        raise _Skip("no cr-record page was ever published for %s; nothing to re-publish" % rel_id)

    with tempfile.TemporaryDirectory(prefix="kb-cr-record-") as tmp:
        bf = Path(tmp) / "body.md"
        bf.write_text(body)
        argv = ["publish", "--doc", DOC, "--key", key, "--title", title, "--body-file", str(bf),
                "--body-format", "markdown"]
        if handle:
            argv += ["--page-id", str(handle["pageId"]), "--stored-version", str(handle["version"])]
        proc = _kb_wiki(argv, team)
    if proc.returncode != 0:
        if proc.returncode == 4:
            raise _Fail("version guard: the page was edited since version %s; kb-wiki refused to overwrite it "
                        "(reconcile by hand with kb-wiki publish --expect-version <live>, then re-run)"
                        % (handle or {}).get("version"), recordMode=rmode, testingLog=tl)
        why = (proc.stderr or "").strip().splitlines()
        raise _Fail("kb-wiki publish exit %d: %s" % (proc.returncode, why[-1] if why else "no detail"),
                    recordMode=rmode, testingLog=tl)
    try:
        out = json.loads(proc.stdout)
        new_handle = {"pageId": str(out["pageId"]), "url": str(out["url"]), "version": int(out["version"])}
    except (ValueError, KeyError, TypeError):
        raise _Fail("kb-wiki printed an unparseable handle", recordMode=rmode, testingLog=tl) from None
    if key != rel_id:
        new_handle["key"] = key
    page_ids = {new_handle["pageId"]} | ({str(handle["pageId"])} if handle else set())
    mirror_ids = [str(c["id"]) for c in linked if c.get("id") and str(c["id"]) not in excluded]
    try:
        set_wiki_handle(board_path, "releases", rel_id, DOC, new_handle, links={"crRecord": new_handle["url"]},
                        also=[("crs", cid, _mirror_edit(rel_id, new_handle, page_ids)) for cid in mirror_ids])
    except Exception as exc:  # noqa: BLE001
        raise _Fail("the page WAS published (%s v%d) but its handle could not be stored on the board: %s. "
                    "Do NOT re-run (a second create is refused); store the handle by hand."
                    % (new_handle["url"], new_handle["version"], exc), recordMode=rmode, testingLog=tl,
                    handle=new_handle, handleUnstored=True) from None
    verdict.update(recordMode=rmode, handle=new_handle, mirroredCrs=mirror_ids)
    if tl_failed:
        verdict.update(status="failed", reason="the status page was published, but the Testing Log was not: %s"
                       % tl.get("reason", ""))
        return EXIT_FAILED, verdict
    verdict["status"] = "published"
    return EXIT_PUBLISHED, verdict


def publish(board_path: str, cr_id: str, team: str, mode: str, activity_file: Optional[str]) -> int:
    """Back-compat CLI shim (``--cr-id``): refresh the release the CR belongs to, print the verdict."""
    code, v = refresh(board_path, team, cr_id=cr_id, mode=mode, activity_file=activity_file)
    print(json.dumps(v, sort_keys=True))
    return code


def main(argv: Optional[list] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--board", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--release-id")
    g.add_argument("--cr-id")
    ap.add_argument("--team", required=True)
    ap.add_argument("--reason", default="")
    ap.add_argument("--mode", choices=("create-or-update", "update-only"), default="create-or-update")
    ap.add_argument("--activity-file")
    ap.add_argument("--refresh-testing-log", action="store_true",
                    help="also re-publish an EXISTING Testing Log (stage-boundary refresh; off by default)")
    a = ap.parse_args(argv)
    code, verdict = refresh(a.board, a.team, release_id=a.release_id, cr_id=a.cr_id, reason=a.reason, mode=a.mode,
                            activity_file=a.activity_file, refresh_testing_log=a.refresh_testing_log)
    print(json.dumps(verdict, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
