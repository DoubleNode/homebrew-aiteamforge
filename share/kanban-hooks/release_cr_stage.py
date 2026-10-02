"""release_cr_stage.py -- the resumable CR-stage orchestrator (XACA-1349-002 / -003; spec RELEASE-LIFECYCLE.md 8.3).

`kb-release cr-stage <REL-ID>` runs the spec 8.3 flow against the team board and stops at the first
thing it cannot do for the lead. Every step first asks "did this already happen?" and skips if so, so a
failure leaves the CR in its last good state and a re-run resumes there.

  step          what it does                                                         done when
  cr            reuse the open linked CR (else kb-cr create + assign-release);       a CR is linked AND
                record release.stageSha.CR = release branch HEAD                     stageSha.CR is set
  draft         facts -> render the team `cr` profile template -> mechanical         CR already published
                validation (the testing-log link is not published yet, so that
                one check waits for the strict pass below)
  approval      STOP unless cr_draft_approved_at is set (the engine never approves   approved / not required
                for the lead; the lead runs `kb-cr approve-draft <CR> --by <lead>`)
  testing-log   kb-wiki publish --doc testing-log; store the handle on the release   release.wikiPages has it
                (links.testingLog on the release AND the CR)
  publish       rebuild facts with the link, STRICT validation, kb-wiki publish      CR state >= cr-published
                --doc cr, store the handle on the CR, then `kb-cr publish --url`
  notify        kb-notify send --to cr-approver --template cr-submitted; a failure   a receipt exists / state
                STOPS here (nothing is submitted)                                    >= cr-submitted
  submit        kb-cr submit; report cr_approval_expected_at                         CR state >= cr-submitted

Page handles live in ``wikiPages: {"<doc>": {"pageId", "url", "version"}}`` -- on the release for
``testing-log``, on the CR for ``cr`` and ``cr-record`` -- written ONLY through get_wiki_handle /
set_wiki_handle below (the cr-record work imports them). kb-wiki never writes the board; this module does,
through kanban_utils.update_board_safely (the locked read-modify-write every other board writer uses).

Everything outside the board file goes through ``Tools`` (kb-cr, kb-wiki, kb-notify, git), so the tests drive
the whole flow with an in-memory fake and the CLI wires ShellTools.

Exit codes: 0 submitted (or already was) | 1 a tool failed (CR left at its last good state; re-run) |
2 usage / config | 3 refused (state conflict: branch moved, ambiguous CRs, held CR, wrong stage) |
5 STOPPED for the lead's draft approval (not an error) | 6 the draft or Testing Log failed validation.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

_HERE = Path(__file__).resolve().parent
for _cand in (_HERE.parent / "scripts", _HERE / "scripts", _HERE):  # repo layout, tap share layout, flat
    if (_cand / "release_profile_resolver.py").is_file():
        if str(_cand) not in sys.path:
            sys.path.insert(0, str(_cand))
        break
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import approval_providers as ap  # noqa: E402


def _load_kanban_utils():
    """The REAL kanban_utils, never a stand-in.

    Several suites (lcars-ui/tests/test_server.py, the XACA-1382 board-cache suites) install a MagicMock
    under ``sys.modules["kanban_utils"]`` at import time and never remove it. Binding that stub would make
    ``update_board_safely`` a truthy no-op: every board write "succeeds" without writing, and the cr-stage
    steps then read back a board that never changed. A real module is a ModuleType with a file behind it;
    anything else is replaced by loading kanban-hooks/kanban_utils.py privately (sys.modules untouched, so
    the stub's owners keep theirs)."""
    import importlib.util  # noqa: PLC0415
    import types  # noqa: PLC0415
    mod = sys.modules.get("kanban_utils")
    if isinstance(mod, types.ModuleType) and getattr(mod, "__file__", None):
        return mod
    if mod is None:
        try:
            import kanban_utils as real  # noqa: PLC0415
            return real
        except ImportError:
            pass
    spec = importlib.util.spec_from_file_location("_release_cr_stage_kanban_utils", str(_HERE / "kanban_utils.py"))
    real = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(real)
    return real


kanban_utils = _load_kanban_utils()
import release_cr_facts as rcf  # noqa: E402
import release_gate  # noqa: E402
import release_template_render as trender  # noqa: E402

RC_OK, RC_FAILED, RC_USAGE, RC_REFUSED, RC_NEEDS_APPROVAL, RC_DRAFT_INVALID = 0, 1, 2, 3, 5, 6

STEPS = ("cr", "draft", "approval", "testing-log", "publish", "notify", "submit")
RETIRED_STATES = ("cr-closed", "cr-rejected")
# The only crStates a REUSED CR may be in (spec 8.1 flow states; held/emergency are refused with their own message).
REUSABLE_STATES = ("cr-drafted", "cr-published", "cr-submitted", "cr-approved", "deployed-prod", "cr-completed")
# crState at or past which a step's work has happened. cr-held / emergency-deployed are refused earlier.
_AT_LEAST_PUBLISHED = ("cr-published", "cr-submitted", "cr-approved", "deployed-prod", "cr-completed", "cr-closed")
_AT_LEAST_SUBMITTED = ("cr-submitted", "cr-approved", "deployed-prod", "cr-completed", "cr-closed")
NOTICE_ALIAS, NOTICE_TEMPLATE = "cr-approver", "cr-submitted"
_CONTENT_REF = re.compile(r"\{\{\s*content\.([A-Za-z0-9_]+)(\??)\s*\}\}")
_CREATED_RE = re.compile(r"Created CR \[([^\]]+)\]")
_TESTING_LINK_RULES = ("link-required-unresolved", "link-required-missing")


class CrStageError(Exception):
    """A step cannot continue. ``rc`` is the CLI exit code; ``step`` names the step."""

    def __init__(self, message: str, rc: int = RC_FAILED, step: str = ""):
        Exception.__init__(self, message)
        self.rc, self.step = rc, step


class ToolError(Exception):
    """An external tool (kb-cr / kb-wiki / kb-notify / git) failed. ``rc`` is its exit code."""

    def __init__(self, message: str, rc: int = 1):
        Exception.__init__(self, message)
        self.rc = rc


# ---------------------------------------------------------------------------------------- board I/O

def read_board(board_file: str) -> Dict[str, Any]:
    with open(board_file, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise CrStageError("board %s is not a JSON object" % board_file, RC_USAGE)
    return data


def update_records(board_file: str, edits: List[Tuple[str, str, Callable[[Dict[str, Any]], None]]]) -> None:
    """Apply ``(collection, record_id, mutator)`` edits in ONE locked read-modify-write. Every record must
    exist (else nothing is written and CrStageError is raised): a silent no-op would let a step believe it
    had recorded state it never did."""
    missing: List[str] = []

    def mutate(board: Dict[str, Any]):
        found = []
        for coll, rid, fn in edits:
            rec = next((r for r in (board.get(coll) or []) if isinstance(r, dict) and r.get("id") == rid), None)
            if rec is None:
                missing.append("%s/%s" % (coll, rid))
            else:
                found.append((rec, fn))
        if missing:
            return None  # skip the write
        for rec, fn in found:
            fn(rec)
        return board

    ok = kanban_utils.update_board_safely(board_file, mutate)
    if missing:
        raise CrStageError("board write refused: record(s) not found: %s" % ", ".join(missing), RC_REFUSED)
    if not ok:
        raise CrStageError("board write failed (%s unreadable or locked)" % board_file, RC_FAILED)


def get_wiki_handle(record: Optional[Dict[str, Any]], doc: str) -> Optional[Dict[str, Any]]:
    """The stored ``wikiPages[doc]`` handle ``{pageId, url, version}`` of a release or CR record, or None.
    A present-but-malformed handle raises: re-publishing "with no page id" over a page that exists would
    be refused by kb-wiki at best and duplicate it at worst."""
    pages = (record or {}).get("wikiPages")
    if pages is None:
        return None
    if not isinstance(pages, dict):
        raise CrStageError("%s.wikiPages is %s, expected an object"
                           % ((record or {}).get("id", "?"), type(pages).__name__), RC_REFUSED)
    h = pages.get(doc)
    if h is None:
        return None
    if (not isinstance(h, dict) or not isinstance(h.get("pageId"), str) or not h["pageId"].strip()
            or not isinstance(h.get("url"), str) or not isinstance(h.get("version"), int)
            or isinstance(h.get("version"), bool)):
        raise CrStageError("%s.wikiPages[%r] is malformed (need string pageId, string url, integer version)"
                           % ((record or {}).get("id", "?"), doc), RC_REFUSED)
    return {"pageId": h["pageId"], "url": h["url"], "version": h["version"]}


def set_wiki_handle(board_file: str, collection: str, record_id: str, doc: str, handle: Dict[str, Any], *,
                    links: Optional[Dict[str, str]] = None,
                    also: Optional[List[Tuple[str, str, Callable[[Dict[str, Any]], None]]]] = None) -> None:
    """Store ``wikiPages[doc] = {pageId, url, version}`` (plus optional ``links.<k> = url`` on the same record,
    plus any ``also`` edits) in one locked write. ``collection`` is "releases" or "crs"."""
    clean = {"pageId": str(handle["pageId"]), "url": str(handle["url"]), "version": int(handle["version"])}
    if not clean["pageId"].strip() or not clean["url"].strip():
        raise CrStageError("refusing to store an empty wiki page handle for %s %s" % (doc, record_id), RC_FAILED)

    def mutate(rec: Dict[str, Any]) -> None:
        pages = rec.get("wikiPages")
        if not isinstance(pages, dict):
            pages = rec["wikiPages"] = {}
        pages[doc] = dict(clean)
        if links:
            lk = rec.get("links")
            if not isinstance(lk, dict):
                lk = rec["links"] = {}
            lk.update(links)

    update_records(board_file, [(collection, record_id, mutate)] + list(also or []))


# ---------------------------------------------------------------------------------------- tools

def _clean_env(extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    env.update(extra or {})
    return env


def _find_script(name: str) -> str:
    override = os.environ.get("KB_%s_BIN" % name.split("-", 1)[-1].upper())
    if override:
        return override
    for cand in (_HERE.parent / "scripts" / name, _HERE / name):
        if cand.is_file():
            return str(cand)
    found = shutil.which(name)
    if found:
        return found
    raise ToolError("cannot find %s (looked next to kanban-hooks/, in scripts/, and on PATH)" % name, 2)


class ShellTools:
    """The real tools: kb-cr (a zsh function, so each call sources kanban-helpers.sh), kb-wiki, kb-notify, git."""

    def __init__(self, team: str, kanban_dir: str, repo_dir: str, helpers: str, *, run: Callable[..., Any] = subprocess.run,
                 terminal: str = "agent"):
        self.team, self.kanban_dir, self.repo_dir, self.helpers = team, kanban_dir, repo_dir, helpers
        self.run, self.terminal = run, terminal

    # -- kb-cr
    def _kb_cr(self, *args: str) -> str:
        if not self.helpers or not os.path.isfile(self.helpers):
            raise ToolError("kanban-helpers.sh not found (%r); pass --helpers" % self.helpers, 2)
        cmd = ["zsh", "-c", 'source "$1" >/dev/null 2>&1 || exit 97; shift; kb-cr "$@"', "kb-cr", self.helpers, *args]
        env = _clean_env({"KB_TEAM": self.team, "KB_TERMINAL": self.terminal, "KB_CR_ACTOR": "kb-release cr-stage"})
        r = self.run(cmd, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            raise ToolError("kb-cr %s failed (exit %d): %s" % (args[0] if args else "", r.returncode,
                                                               ((r.stderr or "") + (r.stdout or "")).strip()[-600:]),
                            r.returncode)
        return r.stdout or ""

    def cr_create(self, title: str, *, platform: str = "", summary: str = "", deploy_window: str = "") -> str:
        args = ["create", title, "--type", "major"]
        for flag, val in (("--platform", platform), ("--summary", summary), ("--deploy-window", deploy_window)):
            if val:
                args += [flag, val]
        m = _CREATED_RE.search(self._kb_cr(*args))
        if not m:
            raise ToolError("kb-cr create succeeded but printed no 'Created CR [<id>]' line", 1)
        return m.group(1)

    def cr_assign_release(self, cr_id: str, release_id: str) -> None:
        self._kb_cr("assign-release", cr_id, release_id)

    def cr_publish(self, cr_id: str, url: str, version: str, title: str) -> None:
        self._kb_cr("publish", cr_id, "--url", url, "--version", version, "--title", title)

    def cr_submit(self, cr_id: str) -> None:
        self._kb_cr("submit", cr_id)

    # -- kb-wiki
    def _wiki(self, args: List[str]) -> Tuple[int, Dict[str, Any]]:
        cmd = [sys.executable, _find_script("kb-wiki"), *args, "--team", self.team, "--json"]
        r = self.run(cmd, capture_output=True, text=True, env=_clean_env())
        out: Dict[str, Any] = {}
        if (r.stdout or "").strip():
            try:
                out = json.loads(r.stdout)
            except ValueError:
                raise ToolError("kb-wiki printed non-JSON on stdout: %s" % r.stdout.strip()[:200], 1)
        if r.returncode == 4:
            return 4, out
        if r.returncode != 0:
            raise ToolError("kb-wiki %s failed (exit %d): %s" % (args[0], r.returncode, (r.stderr or "").strip()[-600:]),
                            r.returncode)
        return 0, out

    def wiki_find(self, doc: str, key: str, title: str) -> List[Dict[str, Any]]:
        _, out = self._wiki(["find", "--doc", doc, "--key", key, "--title", title])
        return list(out.get("matches") or [])

    def wiki_publish(self, doc: str, key: str, title: str, body: str, *, page_id: Optional[str] = None,
                     stored_version: Optional[int] = None) -> Dict[str, Any]:
        with tempfile.TemporaryDirectory(prefix="kb-cr-stage-") as tmp:
            bf = os.path.join(tmp, "body.md")
            with open(bf, "w", encoding="utf-8") as fh:
                fh.write(body)
            args = ["publish", "--doc", doc, "--key", key, "--title", title, "--body-file", bf]
            if page_id:
                args += ["--page-id", page_id, "--stored-version", str(stored_version)]
            rc, out = self._wiki(args)
        if rc == 4:
            raise ToolError("the %s page changed in the wiki since it was last published (version guard); "
                            "refusing to overwrite it: %s" % (doc, out.get("message", "")), 4)
        return out

    # -- kb-notify
    def notify_send(self, alias: str, template: str, ref: str, data: Dict[str, Any]) -> None:
        cmd = [sys.executable, _find_script("kb-notify"), "send", "--to", alias, "--template", template,
               "--data", json.dumps(data), "--ref", ref, "--team", self.team, "--json"]
        r = self.run(cmd, capture_output=True, text=True, env=_clean_env())
        if r.returncode != 0:
            raise ToolError("kb-notify exit %d: %s" % (r.returncode, ((r.stderr or "") + (r.stdout or "")).strip()[-500:]),
                            r.returncode)

    # -- git / activity
    def branch_head(self, release: Dict[str, Any]) -> Optional[str]:
        branch = release.get("branch")
        if not isinstance(branch, str) or not branch.strip() or branch.startswith("-"):
            return None
        try:
            r = self.run(["git", "-C", self.repo_dir, "rev-parse", "--verify", "--quiet", branch.strip() + "^{commit}"],
                         capture_output=True, text=True, timeout=10, env=_clean_env())
        except (OSError, subprocess.SubprocessError):
            return None
        sha = (r.stdout or "").strip()
        return sha if r.returncode == 0 and re.fullmatch(r"[0-9a-fA-F]{7,64}", sha) else None

    def activity(self, board_file: str, cr_id: str) -> List[Dict[str, Any]]:
        path = Path(board_file).parent / "change-requests" / "activity" / ("%s.json" % cr_id)
        if not path.is_file():
            return []
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        ev = doc.get("events") if isinstance(doc, dict) else None
        if not isinstance(ev, list):
            raise CrStageError("activity log %s has no events[] array" % path, RC_REFUSED)
        return ev


# ---------------------------------------------------------------------------------------- orchestrator

def _find(board: Dict[str, Any], coll: str, rid: str) -> Optional[Dict[str, Any]]:
    return next((r for r in (board.get(coll) or []) if isinstance(r, dict) and r.get("id") == rid), None)


def _first_heading(body: str) -> str:
    for line in body.splitlines():
        if line.strip():
            return re.sub(r"^#+\s*", "", line.strip()).strip()
    return ""


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class CrStage:
    """One run of the CR stage for one release. Reads the board fresh at every step (a re-run, or a lead
    running ``kb-cr approve-draft`` between runs, must be seen)."""

    def __init__(self, release_id: str, tools: Any, board_file: str, kanban_dir: str, team: str, *,
                 content: Optional[Dict[str, Any]] = None, only_step: Optional[str] = None,
                 skip_notify: Optional[str] = None, skip_notify_by: Optional[str] = None,
                 now: Optional[Callable[[], datetime]] = None, say: Callable[[str], None] = print,
                 resolve: Optional[Callable[..., Dict[str, Any]]] = None):
        if only_step is not None and only_step not in STEPS:
            raise CrStageError("unknown step %r (steps: %s)" % (only_step, ", ".join(STEPS)), RC_USAGE)
        if skip_notify is not None and (not skip_notify.strip() or not (skip_notify_by or "").strip()):
            raise CrStageError("--skip-notify needs a reason AND --by <lead> (it is the lead's override)", RC_USAGE)
        self.rel_id, self.tools, self.board_file, self.kdir, self.team = release_id, tools, board_file, kanban_dir, team
        self.content_in, self.only = content, only_step
        self.skip_notify, self.skip_by = skip_notify, skip_notify_by
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.say = say
        if resolve is None:
            try:
                import release_profile_resolver as _rpr  # noqa: PLC0415
            except ImportError as exc:  # the resolver validates profiles with jsonschema (absent on a bare /usr/bin/python3)
                raise CrStageError("cannot load the content-profile resolver (%s). Run under a python3 that has "
                                   "jsonschema installed (the same requirement as kb-wiki doctor's validator)" % exc,
                                   RC_USAGE)
            resolve = _rpr.resolve_profile
        self._resolve = resolve
        self.cr_id: Optional[str] = None
        self._profiles: Dict[str, Dict[str, Any]] = {}

    # -- loading ----------------------------------------------------------------------------------
    def _load(self) -> Tuple[Dict[str, Any], Dict[str, Any], Optional[Dict[str, Any]]]:
        board = read_board(self.board_file)
        rel = _find(board, "releases", self.rel_id)
        if rel is None:
            raise CrStageError("release %s not found on %s" % (self.rel_id, self.board_file), RC_USAGE)
        cr = _find(board, "crs", self.cr_id) if self.cr_id else None
        return board, rel, cr

    def _profile(self, kind: str) -> Dict[str, Any]:
        if kind not in self._profiles:
            try:
                self._profiles[kind] = self._resolve(self.team, kind, kanban_dir=self.kdir)
            except Exception as exc:  # noqa: BLE001 -- ProfileResolutionError / validation errors
                raise CrStageError("cannot resolve the %s profile for team %s: %s" % (kind, self.team, exc), RC_USAGE)
            if not self._profiles[kind].get("template"):
                raise CrStageError("the %s profile has no template.md in any tier" % kind, RC_USAGE)
        return self._profiles[kind]

    def _wiki_platform_name(self) -> str:
        try:
            with open(os.path.join(self.kdir, "config", "wiki.json"), "r", encoding="utf-8") as fh:
                v = json.load(fh).get("platformName")
            return v.strip() if isinstance(v, str) else ""
        except (OSError, ValueError, AttributeError):
            return ""

    def _tz(self, board: Dict[str, Any]) -> str:
        prof = (((board.get("teamConfig") or {}).get("crSupport") or {}).get("approval") or {})
        tz = prof.get("tz") if isinstance(prof, dict) else None
        return tz if isinstance(tz, str) and tz else rcf.DEFAULT_TZ

    # -- facts ------------------------------------------------------------------------------------
    def _facts(self, board, rel, cr, *, content=None, testing_url: Optional[str] = None,
               expected_at: Optional[str] = None) -> Dict[str, Any]:
        activity = self.tools.activity(self.board_file, cr["id"]) if cr else None
        pname = self._wiki_platform_name()
        crr = rcf.cr_record_for_facts(cr, release=rel, activity=activity) if cr else None
        if crr is not None and expected_at:
            crr["cr_approval_expected_at"] = expected_at
        relr = rcf.release_record_for_facts(rel, cr=cr, platform_name=pname)
        kw = dict(board=board, content=content, tz=self._tz(board), platform_name=pname, now=self.now(),
                  excluded_from_scope=(self._profile("cr")["profile"].get("excludedFromScope")))
        try:
            if testing_url:
                return rcf.rebuild_after_testing_log_publish(relr, crr, testing_url, **kw)
            return rcf.build_cr_fact_set(relr, crr, **kw)
        except ValueError as exc:  # FactSetError / ExcludedScopeError
            raise CrStageError("cannot assemble the CR facts: %s" % exc, RC_REFUSED)

    # -- run --------------------------------------------------------------------------------------
    def run(self) -> Dict[str, Any]:
        result: Dict[str, Any] = {"release": self.rel_id, "cr": None, "steps": [], "ok": False, "stopped": None,
                                  "expectedApprovalAt": None, "message": ""}
        impl = {"cr": self._step_cr, "draft": self._step_draft, "approval": self._step_approval,
                "testing-log": self._step_testing_log, "publish": self._step_publish,
                "notify": self._step_notify, "submit": self._step_submit}
        stop_at = STEPS.index(self.only) if self.only else len(STEPS) - 1
        for i, name in enumerate(STEPS):
            if i > stop_at:
                break
            try:
                status, detail = impl[name](only=(self.only == name))
            except CrStageError as exc:
                exc.step = exc.step or name
                result["steps"].append({"step": name, "status": "stopped" if exc.rc == RC_NEEDS_APPROVAL else "failed",
                                        "detail": str(exc)})
                result.update(cr=self.cr_id, stopped=name, message=str(exc), rc=exc.rc)
                return result
            except ToolError as exc:
                result["steps"].append({"step": name, "status": "failed", "detail": str(exc)})
                result.update(cr=self.cr_id, stopped=name, message=str(exc), rc=RC_FAILED)
                return result
            result["steps"].append({"step": name, "status": status, "detail": detail})
            self.say("[%s] %s%s" % (name, status, (": " + detail) if detail else ""))
        result["cr"] = self.cr_id
        result["ok"], result["rc"] = True, RC_OK
        if self.only is None or self.only == "submit":
            _board, _rel, cr = self._load()
            exp = ((cr or {}).get("timestamps") or {}).get("cr_approval_expected_at")
            result["expectedApprovalAt"] = exp or None
            result["message"] = ("Expected approval: %s" % exp) if exp else "manual approval, no expected time"
            self.say(result["message"])
        return result

    def status(self) -> List[Dict[str, Any]]:
        """Read-only: which steps are already done (no tool is called, nothing is written)."""
        board, rel, _ = self._load()
        cr = self._open_cr(board, rel)
        self.cr_id = cr["id"] if cr else None
        state = (cr or {}).get("crState")
        has_log = get_wiki_handle(rel, "testing-log") is not None
        notified = bool(cr) and (self._has_receipt(cr) or bool(cr.get("noticeOverride")))
        sha = (rel.get("stageSha") or {}).get("CR")
        approved = bool(((cr or {}).get("timestamps") or {}).get("cr_draft_approved_at"))
        pub = state in _AT_LEAST_PUBLISHED
        done = {"cr": bool(cr) and bool(sha), "draft": pub, "approval": pub or approved,
                "testing-log": has_log, "publish": pub, "notify": state in _AT_LEAST_SUBMITTED or notified,
                "submit": state in _AT_LEAST_SUBMITTED}
        return [{"step": s, "done": bool(done[s])} for s in STEPS]

    # -- step 1 -----------------------------------------------------------------------------------
    def _open_cr(self, board, rel) -> Optional[Dict[str, Any]]:
        try:
            crs, missing = ap._linked_crs(board, rel)  # same linkage rule the gate feed uses
        except Exception as exc:  # noqa: BLE001
            raise CrStageError("cannot read the CRs linked to %s: %s" % (self.rel_id, exc), RC_REFUSED)
        if missing:
            raise CrStageError("release %s links CR(s) that are not on the board: %s"
                               % (self.rel_id, ", ".join(map(str, missing))), RC_REFUSED)
        open_crs = [c for c in crs if c.get("crState") not in RETIRED_STATES]
        if len(open_crs) > 1:
            raise CrStageError("release %s has %d open CRs (%s); close the extras (kb-cr close <CR> --reason ...) so "
                               "exactly one remains" % (self.rel_id, len(open_crs), ", ".join(c["id"] for c in open_crs)),
                               RC_REFUSED)
        return open_crs[0] if open_crs else None

    def _step_cr(self, only: bool = False) -> Tuple[str, str]:
        board, rel, _ = self._load()
        cs = (board.get("teamConfig") or {}).get("crSupport")
        if not (isinstance(cs, dict) and cs.get("enabled") is True):
            raise CrStageError("CR support is not enabled for team %s (teamConfig.crSupport.enabled)" % self.team, RC_REFUSED)
        stage = rel.get("stage") or rel.get("currentStage")
        if stage != "CR":
            raise CrStageError("release %s is at stage %s; the CR stage runs only while it is in CR" % (self.rel_id, stage),
                               RC_REFUSED)
        facts = self._facts(board, rel, None)
        gaps = rcf.missing_cr_title_inputs(facts)
        cr = self._open_cr(board, rel)
        detail = []
        if cr is None:
            if gaps:
                raise CrStageError("cannot create the CR: %s is empty (set the release's briefTitle or name first)"
                                   % ", ".join(gaps), RC_REFUSED)
            f = facts["release"]
            title = "%s: %s %s" % (f["releaseType"], f["platform"], f["briefTitle"])
            cr = self._adopt_orphan(board, title)
            if cr is None:
                plat = (rcf.resolve_release_platform(rel, None, None) if rel.get("platforms") else "").lower()
                tdate = rel.get("targetDate")
                window = tdate if isinstance(tdate, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}(T[0-9:]+Z)?", tdate) else ""
                new_id = self.tools.cr_create(title, platform=plat if plat in ("ios", "android", "firebase", "crossplatform") else "",
                                              summary="", deploy_window=window)
                self.cr_id = new_id
                detail.append("created %s" % new_id)
            else:
                self.cr_id = cr["id"]
                detail.append("adopted unlinked %s" % self.cr_id)
            try:
                self.tools.cr_assign_release(self.cr_id, self.rel_id)
            except ToolError as exc:
                raise CrStageError("CR %s exists but is not linked to %s (%s). Re-run, or link it by hand: "
                                   "kb-cr assign-release %s %s" % (self.cr_id, self.rel_id, exc, self.cr_id, self.rel_id),
                                   RC_FAILED)
        else:
            self.cr_id = cr["id"]
            if cr.get("crState") in ("cr-held",):
                raise CrStageError("CR %s is on hold; resume it (kb-cr resume %s) before running the CR stage"
                                   % (self.cr_id, self.cr_id), RC_REFUSED)
            if cr.get("crState") == "emergency-deployed":
                raise CrStageError("CR %s took the emergency path; the CR stage does not apply" % self.cr_id, RC_REFUSED)
            if cr.get("crState") not in REUSABLE_STATES:  # XACA-1349-007: legacy implementing/deployed-dev, junk, absent
                raise CrStageError("CR %s is in state %r, which the CR stage does not drive (it handles %s). Resolve or "
                                   "close it (kb-cr close <CR> --reason ...) so a CR in a stage-flow state remains"
                                   % (self.cr_id, cr.get("crState"), ", ".join(REUSABLE_STATES)), RC_REFUSED)
            detail.append("reusing %s (%s)" % (self.cr_id, cr.get("crState")))
        # stageSha.CR (the SHA the CR describes; the CR exit gate reads this field)
        board, rel, _ = self._load()
        head = self.tools.branch_head(rel)
        cur = (rel.get("stageSha") or {}).get("CR")
        if cur:
            if not head:
                raise CrStageError("cannot resolve release branch HEAD to verify stageSha.CR (%s); refusing to guess"
                                   % cur[:12], RC_REFUSED)
            if head.lower() != cur.lower():
                raise CrStageError("the release branch moved since the CR was prepared: stageSha.CR is %s, HEAD is %s. "
                                   "The CR describes the old SHA; report it with `kb-release new-sha` / regress "
                                   "(spec 13.2) instead of continuing" % (cur[:12], head[:12]), RC_REFUSED)
        elif not head:
            raise CrStageError("cannot resolve the release branch HEAD (release.branch=%r) to record stageSha.CR"
                               % rel.get("branch"), RC_REFUSED)
        # XACA-1349 QA F1: the CR record carries the SHA its approval was written for (cr_stage_sha).
        # A CR created/adopted in this run, or a still-drafted one nothing has been approved on, is
        # (re)stamped with HEAD. Any other reused CR must already carry a stamp == HEAD: after a
        # regress + new-sha the old CR's approval describes the OLD code, so it is refused, NOT
        # auto-closed (closing the superseded CR is the lead's call, spec 13.2).
        fresh = any(d.startswith(("created", "adopted")) for d in detail)
        crec = next((c for c in (board.get("crs") or []) if isinstance(c, dict) and c.get("id") == self.cr_id), None) or {}
        stamp = ap.cr_stamped_sha(crec)
        stamp_ok = bool(stamp) and stamp.lower() == head.lower()
        restamp = False
        if not stamp_ok and not fresh:
            ts = crec.get("timestamps") or {}
            if crec.get("crState") == "cr-drafted" and not ts.get("cr_draft_approved_at"):
                restamp = True   # nothing approved yet: re-stamping is the simple, safe move
            else:
                raise CrStageError(
                    "CR %s (%s) was prepared for SHA %s but the release is now at %s: it does not "
                    "describe this code. Close it: kb-cr close %s --reason \"superseded by new SHA %s\", then "
                    "re-run cr-stage to create a fresh CR" % (self.cr_id, crec.get("crState"),
                                                              (stamp[:12] if stamp else "<none stamped>"), head[:12],
                                                              self.cr_id, head), RC_REFUSED)
        edits: List[Tuple[str, str, Callable[[Dict[str, Any]], None]]] = []
        if not cur:
            def set_sha(r: Dict[str, Any]) -> None:
                ss = r.get("stageSha")
                if not isinstance(ss, dict):
                    ss = r["stageSha"] = {}
                ss["CR"] = head
            edits.append(("releases", self.rel_id, set_sha))
        if not stamp_ok:
            edits.append(("crs", self.cr_id, lambda r, h=head: r.__setitem__("cr_stage_sha", h)))
        if edits:
            update_records(self.board_file, edits)   # one locked write: stageSha.CR and cr_stage_sha together
            if not cur:
                detail.append("stageSha.CR=%s" % head[:12])
            detail.append("%sed cr_stage_sha=%s" % ("re-stamp" if restamp else "stamp", head[:12]))
        return ("done" if any(d.startswith(("created", "adopted", "stageSha", "stamp", "re-stamp")) for d in detail)
                else "skipped", "; ".join(detail))

    def _adopt_orphan(self, board: Dict[str, Any], title: str) -> Optional[Dict[str, Any]]:
        """A CR a previous run created but never linked (kb-cr create succeeded, assign-release did not):
        v2, still cr-drafted, no release assignment, our exact title. Adopting beats creating a second one."""
        cands = [c for c in (board.get("crs") or []) if isinstance(c, dict) and c.get("title") == title
                 and c.get("crState") == "cr-drafted" and c.get("cr_lifecycle") == "v2"
                 and not (isinstance(c.get("releaseAssignment"), dict) and c["releaseAssignment"].get("releaseId"))]
        if len(cands) > 1:
            raise CrStageError("%d unlinked drafted CRs are titled %r (%s); link or close the extras first"
                               % (len(cands), title, ", ".join(c["id"] for c in cands)), RC_REFUSED)
        return cands[0] if cands else None

    # -- steps 2-3 --------------------------------------------------------------------------------
    def _required_slots(self, template: str) -> List[str]:
        return sorted({m.group(1) for m in _CONTENT_REF.finditer(template) if not m.group(2)})

    def _content(self, cr: Dict[str, Any], template: str) -> Dict[str, Any]:
        stored = cr.get("draftContent") if isinstance(cr.get("draftContent"), dict) else None
        given = self.content_in
        if given is not None:
            if not isinstance(given, dict) or any(not isinstance(v, str) for v in given.values()):
                raise CrStageError("draft content must be a JSON object of string slots", RC_USAGE)
            approved = ((cr.get("timestamps") or {}).get("cr_draft_approved_at"))
            if approved and given != stored:
                raise CrStageError("the draft was approved at %s; its content cannot change now. Ask the lead for a new "
                                   "approval path (a new CR) rather than editing an approved draft" % approved, RC_REFUSED)
            if given != stored:
                update_records(self.board_file, [("crs", cr["id"], lambda r, g=dict(given): r.__setitem__("draftContent", g))])
            stored = given
        slots = self._required_slots(template)
        blank = [s for s in slots if not str((stored or {}).get(s, "")).strip()]
        if stored is None or blank:
            raise CrStageError("the CR draft has no content for: %s. Supply them with --content-file <json> "
                               "(an object keyed by slot name: %s)" % (", ".join(blank or slots), ", ".join(slots)),
                               RC_DRAFT_INVALID)
        return dict(stored)

    def _render_validate(self, kind: str, facts: Dict[str, Any], *, strict: bool, title_hint: str = ""):
        import release_profile_validate as rpv  # noqa: PLC0415
        res = self._profile(kind)
        try:
            body = trender.render(res["template"], facts)
        except trender.TemplateRenderError as exc:
            raise CrStageError("the %s template did not render: %s" % (kind, exc), RC_DRAFT_INVALID)
        title = _first_heading(body) or title_hint
        violations = rpv.validate_draft(body, title, res["profile"], facts=facts)
        if not strict:  # the Testing Log is not published yet: only its own link may be missing
            violations = [v for v in violations
                          if not (v.rule in _TESTING_LINK_RULES and "testingLog" in v.detail)]
        if violations:
            lines = ["  - %s%s: %s" % (v.rule, (" (line %d)" % v.line) if v.line else "", v.detail) for v in violations[:12]]
            raise CrStageError("the %s draft failed validation (%d violation(s)):\n%s" % (kind, len(violations), "\n".join(lines)),
                               RC_DRAFT_INVALID)
        return body, title

    def _step_draft(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if cr and cr.get("crState") in _AT_LEAST_PUBLISHED:
            return "skipped", "CR already published"
        content = self._content(cr, self._profile("cr")["template"])
        board, rel, cr = self._load()
        facts = self._facts(board, rel, cr, content=content)
        body, title = self._render_validate("cr", facts, strict=False)
        out_dir = Path(self.kdir) / "release-drafts"
        out_dir.mkdir(parents=True, exist_ok=True)
        path = out_dir / ("%s.md" % cr["id"])
        path.write_text(body, encoding="utf-8")
        return "done", "draft valid (%s); written to %s" % (title, path)

    # -- step 4 -----------------------------------------------------------------------------------
    def _step_approval(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if cr.get("crState") in _AT_LEAST_PUBLISHED:
            return "skipped", "CR already published"
        approved = (cr.get("timestamps") or {}).get("cr_draft_approved_at")
        cs = (board.get("teamConfig") or {}).get("crSupport") or {}
        required = bool(self._profile("cr")["profile"].get("requireLeadDraftApproval")) or cs.get("requireLeadDraftApproval") is True
        if approved:
            return "done", "draft approved at %s by %s" % (approved, cr.get("cr_draft_approved_by", "?"))
        if not required:
            return "skipped", "this team does not require lead draft approval"
        raise CrStageError(
            "STOPPED for the lead: review the draft at %s and, if it is good, run\n"
            "    kb-cr approve-draft %s --by <lead>\n"
            "then re-run `kb-release cr-stage %s`. For edits, re-run with a changed --content-file first. "
            "The engine never approves a draft on the lead's behalf."
            % (Path(self.kdir) / "release-drafts" / ("%s.md" % cr["id"]), cr["id"], self.rel_id),
            RC_NEEDS_APPROVAL, "approval")

    # -- wiki helper ------------------------------------------------------------------------------
    def _publish_page(self, doc: str, key: str, title: str, body: str, stored: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        handle = stored
        if handle is None:  # a crash between kb-wiki and the board write left a labelled page: adopt, don't re-create
            label = "kb-wiki-%s-%s" % (doc, key.lower())
            hits = [m for m in self.tools.wiki_find(doc, key, title) if label in (m.get("labels") or [])]
            if len(hits) > 1:
                raise CrStageError("%d wiki pages carry the label %s; resolve that in the wiki first" % (len(hits), label), RC_REFUSED)
            if hits:
                m = hits[0]
                handle = {"pageId": str(m["pageId"]), "url": m.get("url", ""), "version": int(m["version"])}
        try:
            if handle:
                out = self.tools.wiki_publish(doc, key, title, body, page_id=handle["pageId"], stored_version=handle["version"])
            else:
                out = self.tools.wiki_publish(doc, key, title, body)
        except ToolError as exc:
            raise CrStageError("%s page publish failed: %s" % (doc, exc), RC_FAILED)
        if not all(k in out for k in ("pageId", "url", "version")):
            raise CrStageError("kb-wiki returned no {pageId,url,version} for the %s page: %r" % (doc, out), RC_FAILED)
        return {"pageId": str(out["pageId"]), "url": str(out["url"]), "version": int(out["version"])}

    # -- step 5 -----------------------------------------------------------------------------------
    def _compose_testing_log(self, facts: Dict[str, Any], rel: Dict[str, Any], tz: str) -> Tuple[str, str]:
        """Render the testing-log template once per stage that has records and splice the per-stage sections
        (the template's `### <stage.name>` block up to the next `##` heading) after the first one."""
        res = self._profile("testing-log")
        views = rcf.build_testing_log_stage_views(rel, tz=tz)
        if not views:
            body, title = self._render_validate("testing-log", facts, strict=True)
            return body, title
        renders = [trender.render(res["template"], rcf.facts_for_stage(facts, v)) for v in views]
        first, names = renders[0], [v["name"] for v in views]

        def block(text: str, name: str) -> Optional[Tuple[int, int]]:
            m = re.search(r"^### %s[ \t]*$" % re.escape(name), text, re.M)
            if not m:
                return None
            nxt = re.search(r"^#{1,2} ", text[m.end():], re.M)
            return m.start(), (m.end() + nxt.start()) if nxt else len(text)

        b0 = block(first, names[0])
        if b0 is None and len(renders) > 1:
            raise CrStageError("the testing-log template has no '### <stage.name>' section to repeat per stage; "
                               "add one or the log would show only one stage", RC_DRAFT_INVALID)
        extra = []
        for text, name in zip(renders[1:], names[1:]):
            b = block(text, name)
            if b is None:
                raise CrStageError("stage %s did not render a '### %s' section" % (name, name), RC_DRAFT_INVALID)
            extra.append(text[b[0]:b[1]].rstrip("\n") + "\n\n")
        body = first if b0 is None else first[:b0[1]].rstrip("\n") + "\n\n" + "".join(extra) + first[b0[1]:]
        import release_profile_validate as rpv  # noqa: PLC0415
        title = _first_heading(body)
        viol = rpv.validate_draft(body, title, res["profile"], facts=facts)
        if viol:
            raise CrStageError("the testing-log draft failed validation (%d): %s"
                               % (len(viol), "; ".join("%s: %s" % (v.rule, v.detail) for v in viol[:6])), RC_DRAFT_INVALID)
        return body, title

    def _step_testing_log(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if get_wiki_handle(rel, "testing-log"):
            return "skipped", "Testing Log already published"
        facts = self._facts(board, rel, cr, content=cr.get("draftContent"))
        body, title = self._compose_testing_log(facts, rel, self._tz(board))
        handle = self._publish_page("testing-log", self.rel_id, title, body, None)
        url = handle["url"]

        def cr_links(r: Dict[str, Any]) -> None:
            lk = r.get("links")
            if not isinstance(lk, dict):
                lk = r["links"] = {}
            lk["testingLog"] = url

        set_wiki_handle(self.board_file, "releases", self.rel_id, "testing-log", handle, links={"testingLog": url},
                        also=[("crs", cr["id"], cr_links)])
        return "done", "published %s (v%d)" % (url, handle["version"])

    # -- step 6 -----------------------------------------------------------------------------------
    def _step_publish(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if cr.get("crState") in _AT_LEAST_PUBLISHED:
            return "skipped", "CR already published"
        if get_wiki_handle(rel, "testing-log") is None:
            raise CrStageError("the Testing Log is not published yet (step testing-log); the CR links to it", RC_REFUSED)
        approved = (cr.get("timestamps") or {}).get("cr_draft_approved_at")
        cs = (board.get("teamConfig") or {}).get("crSupport") or {}
        if not approved and (bool(self._profile("cr")["profile"].get("requireLeadDraftApproval"))
                             or cs.get("requireLeadDraftApproval") is True):
            raise CrStageError("no draft approval on record for %s (kb-cr approve-draft)" % cr["id"], RC_NEEDS_APPROVAL, "approval")
        handle = get_wiki_handle(cr, "cr")
        note = []
        if handle is None:
            url_tl = get_wiki_handle(rel, "testing-log")["url"]
            content = self._content(cr, self._profile("cr")["template"])
            facts = self._facts(board, rel, cr, content=content, testing_url=url_tl)
            body, title = self._render_validate("cr", facts, strict=True)
            handle = self._publish_page("cr", cr["id"], title, body, None)
            set_wiki_handle(self.board_file, "crs", cr["id"], "cr", handle, links={"crRequestPage": handle["url"]})
            note.append("cr page %s (v%d)" % (handle["url"], handle["version"]))
        else:  # resumed after the page was created: the record step still needs the published title
            title = _first_heading(self._render_title(board, rel, cr))
        try:
            self.tools.cr_publish(cr["id"], handle["url"], str(handle["version"]), title)
        except ToolError as exc:
            raise CrStageError("kb-cr publish failed after the CR page was created (%s). The page handle is stored; "
                               "re-run to retry the record step" % exc, RC_FAILED)
        note.append("kb-cr publish")
        return "done", "; ".join(note)

    def _render_title(self, board, rel, cr) -> str:
        """The page title for kb-cr's cr_published_title stamp: the template's own heading, rendered."""
        content = self._content(cr, self._profile("cr")["template"])
        url_tl = (get_wiki_handle(rel, "testing-log") or {}).get("url")
        facts = self._facts(board, rel, cr, content=content, testing_url=url_tl)
        return trender.render(self._profile("cr")["template"], facts)

    # -- step 7 -----------------------------------------------------------------------------------
    @staticmethod
    def _has_receipt(cr: Dict[str, Any]) -> bool:
        return any(isinstance(n, dict) and n.get("alias") == NOTICE_ALIAS and n.get("template") == NOTICE_TEMPLATE
                   and n.get("ok") is True for n in (cr.get("notices") or []))

    def _preview_expected(self, board: Dict[str, Any]) -> str:
        """The expected approval time the notice shows. `kb-cr submit` stamps the authoritative value AFTER the
        notice (spec 8.3 order), so this is the same provider rule run for `now`; '' for a manual team."""
        try:
            provider, prof = ap.board_profile(board)
            if provider.name == "manual":
                return ""
            return provider.compute_expected({"timestamps": {"cr_submitted_at": _iso(self.now())}}, prof) or ""
        except ap.ProviderError as exc:
            raise CrStageError("the team's approval profile is unusable (%s); fix it before notifying the approver" % exc, RC_REFUSED)

    def _step_notify(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if cr.get("crState") in _AT_LEAST_SUBMITTED:
            return "skipped", "CR already submitted"
        if cr.get("crState") not in ("cr-published",):
            raise CrStageError("CR %s is %s; it must be cr-published before the approver is notified" % (cr["id"], cr.get("crState")), RC_REFUSED)
        if self._has_receipt(cr):
            return "skipped", "a successful %s notice receipt is already on the CR" % NOTICE_ALIAS
        if cr.get("noticeOverride"):
            return "skipped", "lead override on record: %s" % cr["noticeOverride"].get("reason", "")
        if self.skip_notify:
            # The override is the LEAD's: --by must be in releaseConfig.leads (the same check the LCARS
            # lead endpoints use, release_gate.actor_is_lead). No leads configured = refused (fail closed).
            ok_lead, why = release_gate.actor_is_lead(self.skip_by, board.get("releaseConfig"))
            if not ok_lead:
                raise CrStageError("--skip-notify refused: %s. Add the lead to releaseConfig.leads on the board "
                                   "(the same list the release lead commands use), or let the notice send "
                                   "normally. Nothing was written." % why, RC_REFUSED)
            ov = {"reason": self.skip_notify.strip(), "by": self.skip_by.strip(), "ts": _iso(self.now())}
            update_records(self.board_file, [("crs", cr["id"], lambda r, o=ov: r.__setitem__("noticeOverride", o))])
            return "done", "notice skipped by lead override (%s: %s)" % (ov["by"], ov["reason"])
        expected = self._preview_expected(board)
        facts = self._facts(board, rel, cr, content=cr.get("draftContent"), expected_at=expected or None,
                            testing_url=(get_wiki_handle(rel, "testing-log") or {}).get("url"))
        data = {"cr": {k: facts["cr"][k] for k in ("id", "title", "scheduledWindow", "approvalExpectedAt")},
                "links": facts["links"],
                "release": {k: facts["release"][k] for k in ("id", "version", "platform")}}
        try:
            self.tools.notify_send(NOTICE_ALIAS, NOTICE_TEMPLATE, cr["id"], data)
        except ToolError as exc:
            if exc.rc == 3:
                raise CrStageError("the %s notice may have been SENT but its receipt could not be written (%s). Check "
                                   "the approver's channel; if it arrived, re-run with --skip-notify \"<reason>\" "
                                   "--by <lead>. Nothing was submitted." % (NOTICE_ALIAS, exc), RC_FAILED)
            raise CrStageError("the %s notice was not delivered (%s). Nothing was submitted; the CR stays cr-published. "
                               "Fix notify.json / the secret and re-run." % (NOTICE_ALIAS, exc), RC_FAILED)
        return "done", "%s notified (%s)" % (NOTICE_ALIAS, NOTICE_TEMPLATE)

    # -- step 8 -----------------------------------------------------------------------------------
    def _step_submit(self, only: bool = False) -> Tuple[str, str]:
        board, rel, cr = self._load()
        if cr.get("crState") in _AT_LEAST_SUBMITTED:
            return "skipped", "CR already %s" % cr["crState"]
        if cr.get("crState") != "cr-published":
            raise CrStageError("CR %s is %s; it must be cr-published to submit" % (cr["id"], cr.get("crState")), RC_REFUSED)
        if not (self._has_receipt(cr) or cr.get("noticeOverride")):
            raise CrStageError("no %s notice receipt (or lead override) on %s; run the notify step first" % (NOTICE_ALIAS, cr["id"]), RC_REFUSED)
        try:
            self.tools.cr_submit(cr["id"])
        except ToolError as exc:
            raise CrStageError("kb-cr submit failed (%s); the CR stays cr-published" % exc, RC_FAILED)
        return "done", "submitted"


# ---------------------------------------------------------------------------------------- CLI

def _locate_board(kanban_dir: str, team: str, release_id: str, explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    cand = os.path.join(kanban_dir, "%s-board.json" % team)
    if os.path.isfile(cand):
        return cand
    import glob  # noqa: PLC0415
    for path in sorted(glob.glob(os.path.join(kanban_dir, "*-board.json"))):
        try:
            if _find(read_board(path), "releases", release_id):
                return path
        except (OSError, ValueError, CrStageError):
            continue
    raise CrStageError("no board under %s holds release %s" % (kanban_dir, release_id), RC_USAGE)


def build_parser() -> argparse.ArgumentParser:
    ap_ = argparse.ArgumentParser(prog="kb-release cr-stage",
                                  description="Resumable CR-stage flow (spec 8.3): reuse/create the CR, draft, lead "
                                              "approval checkpoint, publish Testing Log + CR, notify, submit.")
    ap_.add_argument("release")
    ap_.add_argument("--team", required=True)
    ap_.add_argument("--kanban-dir", required=True)
    ap_.add_argument("--board-file", default=None)
    ap_.add_argument("--repo-dir", default=os.getcwd(), help="git repo holding the release branch (default: cwd)")
    ap_.add_argument("--helpers", default=os.environ.get("KB_HELPERS_PATH", ""), help="path to kanban-helpers.sh")
    ap_.add_argument("--content-file", default=None, help="JSON object of the drafted prose slots (content.*)")
    ap_.add_argument("--step", choices=STEPS, default=None, help="run only through this step (earlier steps still run if not done)")
    ap_.add_argument("--status", action="store_true", help="show which steps are done; change nothing")
    ap_.add_argument("--skip-notify", default=None, metavar="REASON", help="lead override of the approver notice (needs --by)")
    ap_.add_argument("--by", default=None, help="the lead taking responsibility for --skip-notify")
    ap_.add_argument("--json", action="store_true", help="print the result as one JSON line (the last stdout line)")
    return ap_


def main(argv: Optional[List[str]] = None, *, tools: Any = None, resolve: Optional[Callable[..., Any]] = None,
         now: Optional[Callable[[], datetime]] = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        content = None
        if a.content_file:
            with open(a.content_file, "r", encoding="utf-8") as fh:
                content = json.load(fh)
        board_file = _locate_board(a.kanban_dir, a.team, a.release, a.board_file)
        tools = tools or ShellTools(a.team, a.kanban_dir, a.repo_dir, a.helpers)
        say = (lambda s: print(s, file=sys.stderr)) if a.json else print
        stage = CrStage(a.release, tools, board_file, a.kanban_dir, a.team, content=content, only_step=a.step,
                        skip_notify=a.skip_notify, skip_notify_by=a.by, now=now, say=say, resolve=resolve)
        if a.status:
            rows = stage.status()
            if a.json:
                print(json.dumps({"release": a.release, "cr": stage.cr_id, "steps": rows}))
            else:
                for r in rows:
                    print("%-12s %s" % (r["step"], "done" if r["done"] else "pending"))
            return RC_OK
        result = stage.run()
    except (OSError, ValueError) as exc:
        print("kb-release cr-stage: %s" % exc, file=sys.stderr)
        return RC_USAGE
    except CrStageError as exc:
        print("kb-release cr-stage: %s" % exc, file=sys.stderr)
        return exc.rc
    if a.json:
        print(json.dumps(result))
    if not result["ok"]:
        print("kb-release cr-stage: step '%s' stopped:\n%s" % (result["stopped"], result["message"]), file=sys.stderr)
    return result.get("rc", RC_FAILED)


if __name__ == "__main__":
    sys.exit(main())
