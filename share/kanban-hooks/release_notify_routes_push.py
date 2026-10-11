"""Route push for kb-notify (XACA-1403-002, EPIC-0068 D1). stdlib only, Python 3.9.

Pushes a team's notify.json (v2) routes + optional team notice-type layer to
the Fleet Monitor hub:  PUT <fm>/api/notify/routes/<team>  with the team's own
`fnt_` key (XACA-1488). Callers:

  * `kb-notify routes push`            (operator, and lcars-ui/server.py after a
                                        /api/notify-config write -- XACA-1406)
  * fleet-monitor/client/fleet-reporter.sh (the reporter cron/launchd actually
    runs), throttled there to once per 5 minutes, via
    `kb-notify routes push --team <t> --if-configured`. The throttle only gates
    how often this module is spawned; whether a PUT happens is decided here by
    the content hash + hourly refresh below.

Change detection: sha256 of the canonical JSON payload + the FM URL is stored in
<state dir>/notify-routes-push-<team>.json. A push happens when the hash/URL
differ from the last SUCCESSFUL push, or the last success is older than
REFRESH_SECONDS (1 hour; $KB_NOTIFY_ROUTES_REFRESH overrides) so an FM that lost
its store converges without an operator. `--force` always pushes.

Failures never raise out of push(): they come back as {"ok": False, "error":
<static reason>}. Nothing here prints the key, the key's source, or any alias
destination; the only text taken from the server is its short validation
message, with the key scrubbed. The key is only ever sent over https, or over
plain http to a loopback host (tests / local FM).

FM URL and team key resolution live in ONE place, release_notify_hub.py
(resolve_fm_url / resolve_team_key), shared with the `send --type` hub path.
There is no default URL: with none configured this reports error "no-fm-url"
(a quiet skip under --if-configured). Redirects are refused so the key is never
forwarded. The key must look like an fnt_ team key; that check is local here.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_notify_hub as hub  # noqa: E402 - sibling; the single FM URL / key resolver home
from release_notify_hub import resolve_fm_url, resolve_team_key  # noqa: E402,F401 - re-exported, not redefined

TEAM_RE = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
KEY_PREFIX = "fnt_"
REFRESH_SECONDS = 3600
HTTP_TIMEOUT = 10
V2_TAG = "release-notify/v2"

EXIT_OK, EXIT_FAIL = 0, 1


class RoutesPushError(Exception):
    """Message is a static reason, safe to print."""


KEY_RESOLVER_UNAVAILABLE = "key-resolver-unavailable"


class KeyResolverUnavailable(RoutesPushError):
    """The key resolver itself could not load or crashed: a machine problem, so it is an
    error even under --if-configured (a genuinely unminted key stays a quiet skip)."""


# ---------------------------------------------------------------- resolvers
# resolve_fm_url / resolve_team_key: imported from release_notify_hub (single home).

def _load_validator_module():
    here = Path(__file__).resolve().parent
    for cand in (here.parent / "scripts", here):
        if (cand / "release_config_validate.py").is_file():
            import importlib.util
            name = "release_config_validate"
            mod = sys.modules.get(name)
            if mod is not None:
                return mod
            spec = importlib.util.spec_from_file_location(name, cand / (name + ".py"))
            mod = importlib.util.module_from_spec(spec)
            sys.modules[name] = mod
            try:
                spec.loader.exec_module(mod)
            except BaseException:
                if sys.modules.get(name) is mod:
                    del sys.modules[name]
                raise
            return mod
    raise ImportError("release_config_validate.py not found")


def _team_key(team: str, env=None, secret_resolver: Optional[Callable[[str, str], str]] = None) -> str:
    """The hub module's resolver plus this module's static errors and fnt_ format check."""
    try:
        key = hub.resolve_team_key(team, env, secret_resolver)
    except hub.HubSkip as skip:
        if skip.reason == hub.RESOLVER_UNAVAILABLE:
            raise KeyResolverUnavailable(KEY_RESOLVER_UNAVAILABLE) from None
        raise RoutesPushError("no team notify key available (mint one with the FM admin API and store it as "
                              "$RELEASE_<TEAM>_NOTIFY_KEY or in the vault)") from None
    if not key.startswith(KEY_PREFIX) or not re.match(r"^[A-Za-z0-9_-]+$", key):
        raise RoutesPushError("team notify key is malformed (expected an fnt_ key)")
    return key


# ---------------------------------------------------------------- pusher

def canonical_hash(payload: Any, fm_url: str) -> str:
    blob = json.dumps({"fm": fm_url, "payload": payload}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _scrub(text: str, key: str) -> str:
    out = text.replace(key, "<redacted>") if key else text
    out = re.sub(r"fnt_[A-Za-z0-9_-]+", "<redacted>", out)
    return out[:300]


class RoutesPusher:
    def __init__(self, team: str, *, kanban_dir=None, fm_url: Optional[str] = None, key_resolver=None,
                 state_dir=None, clock: Optional[Callable[[], float]] = None, refresh_seconds: Optional[int] = None,
                 http_timeout: int = HTTP_TIMEOUT, secret_resolver=None, env=None) -> None:
        if not isinstance(team, str) or not TEAM_RE.match(team):
            raise RoutesPushError("invalid team id")
        self.team = team
        self._kanban_dir = Path(kanban_dir) if kanban_dir else None
        self._env = os.environ if env is None else env
        self._fm_url = fm_url
        self._key_resolver = key_resolver
        self._secret_resolver = secret_resolver
        self._state_dir = Path(state_dir) if state_dir else None
        self._clock = clock or time.time
        self._timeout = http_timeout
        if refresh_seconds is None:
            try:
                refresh_seconds = int(self._env.get("KB_NOTIFY_ROUTES_REFRESH", "") or REFRESH_SECONDS)
            except ValueError:
                refresh_seconds = REFRESH_SECONDS
        self.refresh_seconds = max(0, refresh_seconds)

    # -- inputs ------------------------------------------------------------
    def kanban_dir(self) -> Path:
        if self._kanban_dir is None:
            override = (self._env.get("KB_NOTIFY_KANBAN_DIR") or "").strip()
            if override:
                self._kanban_dir = Path(override).expanduser()
            else:
                try:
                    import aiteamforge_paths  # noqa: PLC0415 - sibling in kanban-hooks/
                    self._kanban_dir = Path(aiteamforge_paths.get_team_kanban_dir(self.team))
                except Exception as exc:  # noqa: BLE001
                    raise RoutesPushError("cannot resolve kanban dir for team (%s)" % type(exc).__name__) from None
        return self._kanban_dir

    def state_file(self) -> Path:
        base = self._state_dir
        if base is None:
            override = (self._env.get("KB_NOTIFY_STATE_DIR") or "").strip()
            base = Path(override).expanduser() if override else Path.home() / ".aiteamforge" / "run"
        return base / ("notify-routes-push-%s.json" % self.team)

    def build_payload(self) -> Dict[str, Any]:
        """Load + validate the team's notify.json; refuse (RoutesPushError) before any network use."""
        import release_notify_routing as rr  # noqa: PLC0415 - sibling module
        kdir = self.kanban_dir()
        path = kdir / "config" / "notify.json"
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise RoutesPushError("team has no notify.json") from None
        except (OSError, ValueError) as exc:
            raise RoutesPushError("notify.json unreadable (%s)" % type(exc).__name__) from None
        if not rr.is_v2(config):
            raise RoutesPushError("notify.json is not release-notify/v2; only v2 configs are pushed")
        try:
            catalog = rr.load_catalog(kdir)
            errs = rr.validate_v2_semantics(config, catalog)
        except rr.NoticeRoutingError as exc:
            raise RoutesPushError(str(exc)[:300]) from None
        if errs:
            raise RoutesPushError("notify.json invalid: " + "; ".join(errs)[:300])
        # Full schema validation when jsonschema is available; the hub re-validates structure anyway.
        try:
            validate = _load_validator_module().validate_notify_config
        except Exception:  # noqa: BLE001 - e.g. jsonschema missing on system python
            validate = None
        if validate is not None:
            errors = validate(config)
            if errors:
                raise RoutesPushError("notify.json invalid: " + "; ".join(errors)[:300])
        payload: Dict[str, Any] = {"config": config}
        tpath = rr.team_catalog_path(kdir)
        if tpath.exists():
            try:
                payload["catalog"] = json.loads(tpath.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise RoutesPushError("team notice_types.json unreadable (%s)" % type(exc).__name__) from None
        return payload

    # -- state -------------------------------------------------------------
    def _read_state(self) -> Dict[str, Any]:
        try:
            doc = json.loads(self.state_file().read_text(encoding="utf-8"))
            return doc if isinstance(doc, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write_state(self, digest: str) -> None:
        path = self.state_file()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".nrp-", dir=str(path.parent))
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"hash": digest, "pushedAt": self._clock()}, fh)
            os.chmod(tmp, 0o600)
            os.replace(tmp, str(path))
        except OSError:
            pass  # next run just pushes again; never fail the caller over bookkeeping

    # -- action --------------------------------------------------------------
    def push(self, *, dry_run: bool = False, force: bool = False, if_configured: bool = False) -> Dict[str, Any]:
        res: Dict[str, Any] = {"ok": False, "team": self.team}
        try:
            try:
                payload = self.build_payload()
            except RoutesPushError as exc:
                msg = str(exc)
                if if_configured and (msg.startswith("team has no notify.json") or "not release-notify/v2" in msg):
                    res.update(ok=True, action="skipped", reason="not_configured")
                    return res
                raise
            try:
                fm_url = self._fm_base()
            except RoutesPushError as exc:
                if if_configured and str(exc) == "no-fm-url":
                    res.update(ok=True, action="skipped", reason="no_fm_url")
                    return res
                raise
            digest = canonical_hash(payload, fm_url)
            res["hash"] = digest[:12]
            res["routeTypes"] = len(payload["config"].get("routes") or {})
            state = self._read_state()
            age = self._clock() - float(state.get("pushedAt") or 0) if isinstance(state.get("pushedAt"), (int, float)) else None
            if force:
                reason = "forced"
            elif state.get("hash") != digest:
                reason = "changed"
            elif age is None or age >= self.refresh_seconds or age < 0:
                reason = "refresh"
            else:
                reason = "unchanged"
            if dry_run:
                res.update(ok=True, action="dry-run", wouldPush=(reason != "unchanged"), reason=reason)
                return res
            if reason == "unchanged":
                res.update(ok=True, action="skipped", reason=reason)
                return res
            try:
                key = (self._key_resolver or (lambda t: _team_key(t, self._env, self._secret_resolver)))(self.team)
            except KeyResolverUnavailable:
                raise
            except RoutesPushError:
                if if_configured:
                    res.update(ok=True, action="skipped", reason="no_key")
                    return res
                raise
            except Exception:  # noqa: BLE001 - resolver crashed: machine fault, not an unminted key
                raise KeyResolverUnavailable(KEY_RESOLVER_UNAVAILABLE) from None
            self._put(fm_url, key, payload)
            self._write_state(digest)
            res.update(ok=True, action="pushed", reason=reason)
            return res
        except RoutesPushError as exc:
            res.update(ok=False, action="error", error=str(exc))
            return res
        except Exception as exc:  # noqa: BLE001 - never let an unexpected error break a reporter run
            res.update(ok=False, action="error", error="unexpected error (%s)" % type(exc).__name__)
            return res

    def _fm_base(self) -> str:
        """Validated FM base URL (explicit, else the hub module's resolver). Static errors only:
        "no-fm-url" when nothing is configured (there is no default), else the https rule."""
        try:
            return hub.validate_hub_url(self._fm_url or resolve_fm_url(self._env))
        except hub.HubSkip as skip:
            if skip.reason == "no-url":
                raise RoutesPushError("no-fm-url") from None
            raise RoutesPushError("Fleet Monitor URL must be https (http only for loopback)") from None

    def _put(self, fm_url: str, key: str, payload: Dict[str, Any]) -> None:
        url = "%s/api/notify/routes/%s" % (fm_url, urllib.parse.quote(self.team, safe=""))
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        req = urllib.request.Request(url, data=body, method="PUT", headers={
            "Content-Type": "application/json", "Authorization": "Bearer " + key, "Accept": "application/json"})
        try:
            opener = hub.build_opener_for(url)  # a 3xx surfaces as HTTPError; key never forwarded
            with opener.open(req, timeout=self._timeout) as resp:  # noqa: S310 - scheme checked above
                resp.read(65536)
                if not 200 <= resp.status < 300:
                    raise RoutesPushError("hub answered HTTP %d" % resp.status)
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                doc = json.loads(exc.read(4096).decode("utf-8", "replace"))
                if isinstance(doc, dict):
                    detail = _scrub(str(doc.get("message") or doc.get("error") or ""), key)
            except Exception:  # noqa: BLE001
                detail = ""
            code = exc.code
            if code in (401, 403):
                raise RoutesPushError("hub rejected the team notify key (HTTP %d)" % code) from None
            if code == 503:
                raise RoutesPushError("hub notification store is disabled (HTTP 503)") from None
            raise RoutesPushError("hub refused the routes (HTTP %d)%s" % (code, ": " + detail if detail else "")) from None
        except RoutesPushError:
            raise
        except (urllib.error.URLError, OSError, ValueError):
            raise RoutesPushError("hub unreachable") from None


# ---------------------------------------------------------------- CLI glue

def run_cli(team: str, args, out=None, err=None, pusher_factory=None) -> int:
    """`kb-notify routes push` body. Prints JSON (--json) or one line; returns an exit code."""
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        pusher = (pusher_factory or RoutesPusher)(team)
    except RoutesPushError as exc:
        res = {"ok": False, "team": team, "action": "error", "error": str(exc)}
    else:
        res = pusher.push(dry_run=getattr(args, "dry_run", False), force=getattr(args, "force", False),
                          if_configured=getattr(args, "if_configured", False))
    if getattr(args, "json", False):
        print(json.dumps(res, sort_keys=True), file=out)
    elif res.get("ok"):
        print("kb-notify: routes %s team=%s (%s)" % (res.get("action"), team, res.get("reason", "")), file=out)
    else:
        print("kb-notify: routes push failed team=%s: %s" % (team, res.get("error")), file=err)
    return EXIT_OK if res.get("ok") else EXIT_FAIL
