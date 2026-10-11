"""Fleet Monitor hub client for kb-notify (XACA-1403-001/-003, EPIC-0068 D1).

Two pieces live here so release_notify.py stays additive:

  * HubProvider: POST /api/notify on Fleet Monitor with the team's own `fnt_`
    notify key (XACA-1488 contract: `Authorization: Bearer fnt_...`, one key per
    team). Stdlib urllib only, one bounded attempt, no retries, no redirects.
  * macos_notify: last-resort local notification via osascript, text passed as
    argv (never interpolated into the script).

WHERE THINGS COME FROM (reuses existing conventions, invents none)
  * FM URL: see resolve_fm_url (KB_NOTIFY_FM_URL, FLEET_MONITOR_URL,
    FLEET_MONITOR_API, then fleet-config.json in ~/.aiteamforge and ~/.dev-team;
    same order as fleet-monitor/client/kanban-reporter.sh; NO default URL).
    This is the single resolver; `kb-notify routes push` imports it from here.
  * Team notify key: $KB_NOTIFY_TEAM_KEY, else the team-bound JIT secret
    resolver (the one NotifyEngine already passes to every provider). Refs in order:
        env:RELEASE_<TEAM>_NOTIFY_KEY
        vault:fleet-monitor/<team>-notify-key
    The resolver enforces team isolation, so a team can only ever read its own.

SECRETS. The key is held in an opaque Target (repr=False) and put only in the
request header. It is never logged, printed, receipted or put in an exception.
No destination ever flows through here (FM owns connections). Every reason code
this module emits is a static string.

HTTP OUTCOME CLASSES (what the engine does with each)
  unreachable   connection error / timeout       -> fallback chain
  server-error  HTTP 5xx                          -> fallback chain
  rejected      HTTP 4xx and 3xx (auth/validation/unknown team/no routes pushed;
                a redirect is refused because it would forward the key)
                                                  -> NOT a fallback trigger; ok:false
  bad-response  HTTP 2xx whose body is not the dispatch JSON
                                                  -> NOT a fallback trigger; ok:false
                (we cannot tell whether FM delivered, so a second send could double-page)
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_notify as rn  # noqa: E402 - sibling; release_notify imports this lazily

HUB_TIMEOUT_SECONDS = 10.0
MACOS_TIMEOUT_SECONDS = 10.0
MAX_RESPONSE_BYTES = 256 * 1024
FLEET_CONFIG_PATHS = (".aiteamforge/fleet-config.json", ".dev-team/fleet-config.json")
ERROR_CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}(?![\s\S])")
MAX_TITLE = 200  # mirrors notify-routes.js validateNotifyBody
MAX_BODY = 4000


# ---------------------------------------------------------------- errors


class HubSkip(rn.NotifyError):
    """Hub path not usable on this machine (no URL / no key / bad URL / not
    registered). Not a failure of delivery: the chain continues. `.reason` is a
    static code."""

    def __init__(self, reason: str) -> None:
        super().__init__("hub skipped (%s)" % reason)
        self.reason = reason


class HubDeliveryError(rn.NotifySendError):
    """The hub attempt failed. `.kind` is unreachable|server-error|rejected|
    bad-response; `.fallback` is True only for unreachable/server-error."""

    def __init__(self, kind: str, reason: str, http_status: Optional[int] = None,
                 error_code: str = "") -> None:
        super().__init__("hub %s (%s)" % (kind, reason))
        self.kind, self.reason, self.http_status, self.error_code = kind, reason, http_status, error_code
        self.fallback = kind in ("unreachable", "server-error")


@dataclass(frozen=True)
class HubOutcome:
    ok: bool
    delivered: int = 0
    failed: int = 0
    suppressed: int = 0
    routed: bool = True
    reason: str = ""  # static code when ok is False
    http_status: int = 200


# ---------------------------------------------------------------- URL resolution


def _loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_hub_url(value: Any) -> str:
    """Return the normalized base URL or raise HubSkip with a static reason.
    https required except for loopback (local dev / tests); no userinfo, query
    or fragment. The value is never echoed."""
    if not isinstance(value, str) or not value.strip():
        raise HubSkip("no-url")
    raw = value.strip().rstrip("/")
    try:
        parsed = urllib.parse.urlsplit(raw)
        host = parsed.hostname
        parsed.port  # noqa: B018 - raises ValueError on a malformed port
    except ValueError:
        raise HubSkip("bad-url") from None
    if parsed.scheme not in ("http", "https") or not host or parsed.username or parsed.password \
            or parsed.query or parsed.fragment:
        raise HubSkip("bad-url")
    if parsed.scheme == "http" and not _loopback(host):
        raise HubSkip("insecure-url")  # the key would cross the network in clear
    return raw


def _base_url(raw: Any) -> str:
    """Strip whitespace, a trailing slash, a trailing /api/status and the slash before it."""
    if not isinstance(raw, str):
        return ""
    val = raw.strip().rstrip("/")
    if val.endswith("/api/status"):
        val = val[:-len("/api/status")]
    return val.rstrip("/")


def resolve_fm_url(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None) -> str:
    """THE Fleet Monitor base URL resolver (hub send and `routes push` both use it).

    First non-empty wins: $KB_NOTIFY_FM_URL, $FLEET_MONITOR_URL, $FLEET_MONITOR_API
    (a trailing /api/status is stripped), then fleet-config.json in ~/.aiteamforge
    and ~/.dev-team reading .fleetMonitorUrl then .centralServer.apiEndpoint. Same
    order as fleet-monitor/client/kanban-reporter.sh. There is NO built-in default
    URL: HubSkip('no-url') when nothing resolves. The winner is validated
    (https, or http on loopback); HubSkip('bad-url'|'insecure-url') otherwise."""
    env = os.environ if env is None else env
    for name in ("KB_NOTIFY_FM_URL", "FLEET_MONITOR_URL", "FLEET_MONITOR_API"):
        val = _base_url(env.get(name))
        if val:
            return validate_hub_url(val)
    base = Path(home) if home is not None else Path.home()
    for rel in FLEET_CONFIG_PATHS:
        try:
            cfg = json.loads((base / rel).read_text(encoding="utf-8"))
            if not isinstance(cfg, dict):
                continue
        except (OSError, ValueError):
            continue  # missing / unreadable: try the next file
        central = cfg.get("centralServer")
        for cand in (cfg.get("fleetMonitorUrl"),
                     central.get("apiEndpoint") if isinstance(central, dict) else None):
            val = _base_url(cand)
            if val:
                return validate_hub_url(val)
    raise HubSkip("no-url")


resolve_hub_url = resolve_fm_url  # earlier name


def resolve_team_key(team: str, env: Optional[Mapping[str, str]] = None,
                     secret_resolver: Optional[Callable[[str, str], str]] = None) -> str:
    """THE team notify key resolver. First hit wins: $KB_NOTIFY_TEAM_KEY, then the
    team-bound refs from key_refs() through `secret_resolver` (default:
    release_config_validate.resolve_secret_ref). HubSkip('no-key') when none
    resolves; resolver exception text is never forwarded. The key's FORMAT is
    the caller's concern (HubProvider.validate_target checks `fnt_`)."""
    env = os.environ if env is None else env
    explicit = (env.get("KB_NOTIFY_TEAM_KEY") or "").strip()
    if explicit:
        return explicit
    if secret_resolver is None:
        try:
            secret_resolver = rn._load_script_module("release_config_validate").resolve_secret_ref
        except Exception:  # noqa: BLE001
            raise HubSkip("no-key") from None
    for ref_name in key_refs(team):
        try:
            value = secret_resolver(ref_name, team)
        except Exception:  # noqa: BLE001 - never forward resolver text; try the next ref
            continue
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise HubSkip("no-key")


def key_refs(team: str) -> List[str]:
    return ["env:RELEASE_%s_NOTIFY_KEY" % team.upper().replace("-", "_"),
            "vault:fleet-monitor/%s-notify-key" % team]


# ---------------------------------------------------------------- transport


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401 - urllib hook
        return None  # surfaces the 3xx as HTTPError; the key is never forwarded


def build_opener_for(url: str) -> urllib.request.OpenerDirector:
    """No-redirect opener. A loopback URL bypasses HTTP(S)_PROXY entirely: urllib
    would otherwise hand the Bearer key to whatever proxy the environment names.
    Remote https hosts keep the proxy settings."""
    handlers: List[Any] = [_NoRedirect]
    try:
        host = urllib.parse.urlsplit(url).hostname or ""
    except ValueError:
        host = ""
    if _loopback(host):
        handlers.append(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(*handlers)


def _default_post(url: str, body: bytes, headers: Mapping[str, str], timeout: float):
    """(status, body_bytes). Raises OSError-family on transport failure."""
    req = urllib.request.Request(url, data=body, headers=dict(headers), method="POST")
    opener = build_opener_for(url)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read(MAX_RESPONSE_BYTES)
    except urllib.error.HTTPError as err:
        try:
            data = err.read(MAX_RESPONSE_BYTES)
        except Exception:  # noqa: BLE001
            data = b""
        return err.code, data


# ---------------------------------------------------------------- provider


class HubProvider(rn.NotifyProvider):
    """Delivers a typed notice through Fleet Monitor. `alias` is the notice
    type (there is no per-alias destination: FM resolves the connections).

    Target.options carries team/type/title/severity/ref/url (none are secrets);
    Target.secret is the team notify key. The message body is message.text."""

    name = "hub"

    def __init__(self, *, post: Optional[Callable] = None, url_resolver: Optional[Callable[[], str]] = None,
                 timeout: float = HUB_TIMEOUT_SECONDS) -> None:
        self._post = post or _default_post
        self._url_resolver = url_resolver or resolve_fm_url
        self._timeout = timeout

    # -- interface ---------------------------------------------------------
    def resolve_target(self, alias: str, session_ctx: rn.SessionContext, *, title: str = "",
                       severity: str = "", ref: Optional[str] = None) -> rn.Target:
        url = validate_hub_url(self._url_resolver())  # HubSkip on none/bad
        ctx_resolve = session_ctx.resolve_secret

        def _bound(ref: str, team: str) -> str:
            if ctx_resolve is None:
                raise HubSkip("no-key")
            return ctx_resolve(ref)
        key = resolve_team_key(session_ctx.team, secret_resolver=_bound)
        opts = {"url": url, "team": session_ctx.team, "type": alias, "title": title}
        if severity:
            opts["severity"] = severity
        if ref:
            opts["ref"] = ref
        return rn.Target(provider=self.name, alias=alias, secret=key, options=opts)

    def validate_target(self, target: rn.Target) -> None:
        if not target.secret.startswith("fnt_"):
            raise HubSkip("bad-key")  # FM only honors `fnt_` team keys on /api/notify

    def deliver(self, target: rn.Target, message: rn.NoticeMessage) -> HubOutcome:
        """One POST. HubDeliveryError (kind/fallback) on every non-success."""
        o = target.options
        payload: Dict[str, Any] = {
            "team": o["team"], "type": o["type"],
            "title": (o.get("title") or "%s: %s" % (o["team"], o["type"]))[:MAX_TITLE],
            "body": (message.text or "")[:MAX_BODY],
        }
        for k in ("severity", "ref"):
            if o.get(k):
                payload[k] = o[k]
        headers = {"Content-Type": "application/json", "Accept": "application/json",
                   "Authorization": "Bearer " + target.secret}
        try:
            status, raw = self._post(o["url"] + "/api/notify", json.dumps(payload).encode("utf-8"),
                                     headers, self._timeout)
        except (OSError, ValueError, urllib.error.URLError):  # incl. timeout, refused, DNS, TLS
            raise HubDeliveryError("unreachable", "connection-failed") from None
        except Exception:  # noqa: BLE001 - foreign transport failure: type is not even recorded
            raise HubDeliveryError("unreachable", "transport-error") from None

        if status >= 500:
            raise HubDeliveryError("server-error", "http-%d" % status, status)
        if status >= 300 or status < 200:
            raise HubDeliveryError("rejected", "http-%d" % status, status, _error_code(raw))
        try:
            doc = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            doc = None
        if not isinstance(doc, dict) or not isinstance(doc.get("ok"), bool) or "routed" not in doc:
            raise HubDeliveryError("bad-response", "unparseable-2xx", status)
        delivered, failed, suppressed = (_count(doc.get(k)) for k in ("delivered", "failed", "suppressed"))
        routed = bool(doc.get("routed"))
        if doc["ok"] and delivered > 0:
            return HubOutcome(True, delivered, failed, suppressed, routed, "", status)
        if routed and failed == 0 and suppressed > 0:
            # FM chose not to send (quiet hours / dedupe / rate limit / severity gate): by design, not a failure.
            return HubOutcome(True, delivered, failed, suppressed, routed, "", status)
        reason = "no-route" if not routed else ("all-connections-failed" if failed else "nothing-delivered")
        return HubOutcome(False, delivered, failed, suppressed, routed, reason, status)

    def send(self, target: rn.Target, message: rn.NoticeMessage) -> rn.SendResult:
        outcome = self.deliver(target, message)
        if not outcome.ok:
            raise rn.NotifySendError("hub delivered nothing (%s)" % outcome.reason)
        return rn.SendResult()


def _count(value: Any) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def _error_code(raw: bytes) -> str:
    """The server's fixed error code (e.g. 'unauthorized', 'not_found') only; its
    free-text message is dropped."""
    try:
        code = json.loads(raw.decode("utf-8")).get("error")
    except (ValueError, UnicodeDecodeError, AttributeError):
        return ""
    return code if isinstance(code, str) and ERROR_CODE_RE.match(code) else ""


# ---------------------------------------------------------------- macOS fallback


def _run(argv: List[str], timeout: float) -> int:
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=timeout, check=False).returncode


# title and body arrive as argv items, so no user text is ever part of the script source
_OSASCRIPT = ["on run argv", "display notification (item 2 of argv) with title (item 1 of argv)", "end run"]


def macos_notify(title: str, body: str, *, runner: Optional[Callable[[List[str], float], int]] = None,
                 platform: Optional[str] = None, which: Optional[Callable[[str], Optional[str]]] = None) -> str:
    """Show a macOS notification. Returns '' on success or a static reason code
    ('not-darwin', 'no-osascript', 'osascript-failed', 'osascript-timeout')."""
    if (platform or sys.platform) != "darwin":
        return "not-darwin"
    exe = (which or shutil.which)("osascript")
    if not exe:
        return "no-osascript"
    argv = [exe]
    for line in _OSASCRIPT:
        argv += ["-e", line]
    # "--" ends osascript option parsing: a title like "-x" or "--help" would otherwise be read as a flag
    argv += ["--", title[:120] or "Notice", body[:400]]
    try:
        rc = (runner or _run)(argv, MACOS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return "osascript-timeout"
    except Exception:  # noqa: BLE001
        return "osascript-failed"
    return "" if rc == 0 else "osascript-failed"
