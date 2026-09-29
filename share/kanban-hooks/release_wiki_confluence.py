"""Confluence provider for release_wiki (XACA-1344-001/002). stdlib only.

v1 REST (/wiki/rest/api/content) for pages; v2 (/wiki/api/v2/folders) for
folders. The HTTP transport is injected so tests never touch the network.
"""
from __future__ import annotations

import base64
import importlib.util
import json
import http.client
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_wiki import (  # noqa: E402
    WikiAncestor, WikiConflictError, WikiError, WikiCredentialError, WikiNotFoundError,
    WikiPage, WikiProvider, WikiResolverUnavailableError, WikiTransportError,
)

CREDS_FILE_ENV = "KB_CR_POLLER_CREDS_FILE"  # same override as the poller
DEFAULT_CREDS_FILE = Path.home() / ".config" / "aiteamforge" / "confluence-credentials.json"
MAX_PAGES = 1000  # pagination cap: hitting it raises, never truncates
EXPAND = "body.storage,version,metadata.labels,ancestors,space"

# transport(method, url, headers, body) -> (status, response_bytes)
Transport = Callable[[str, str, Dict[str, str], Optional[bytes]], Tuple[int, bytes]]

# ---------------------------------------------------------------- credentials


@dataclass(frozen=True)
class ConfluenceCredential:
    email: str
    token: str = field(repr=False)  # never in repr/str
    base_url: str = ""  # https://<tenant>/wiki
    source: str = ""  # "secretRef" | "credentials-file"

    def auth_header(self) -> str:
        raw = f"{self.email}:{self.token}".encode("utf-8")
        return "Basic " + base64.b64encode(raw).decode("ascii")


def _load_secret_module():
    """Locate release_config_validate.py: scripts/ next to kanban-hooks/ (dev
    AND tap share/ layouts), else a flattened sibling of this module."""
    here = Path(__file__).resolve().parent
    for cand in (here.parent / "scripts" / "release_config_validate.py",
                 here / "release_config_validate.py"):
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("release_config_validate", cand)
            mod = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(mod)
            except ImportError as exc:  # e.g. jsonschema missing on system python
                raise WikiResolverUnavailableError(
                    f"cannot load secret resolver ({type(exc).__name__}); "
                    "install jsonschema or use a python that has it") from None
            return mod
    raise WikiCredentialError("release_config_validate.py not found next to this module")


def _resolve_creds_file() -> Path:
    override = os.environ.get(CREDS_FILE_ENV, "").strip()
    return Path(override).expanduser() if override else DEFAULT_CREDS_FILE


def _read_creds_file() -> dict:
    """Adapted from scripts/cr-confluence-poller.py::load_credentials()."""
    creds_file = _resolve_creds_file()
    if not creds_file.exists():
        raise FileNotFoundError(
            f"Credentials file not found: {creds_file}\n"
            "Create it with your Atlassian email and API token.\n"
            "Schema: { \"teams\": { \"ios\": { \"site\": \"...\", \"email\": \"...\","
            " \"api_token\": \"...\", \"space_key\": \"DPD2\" } }, \"default\": \"ios\" }"
        )
    mode = creds_file.stat().st_mode & 0o777
    if mode & 0o077:  # holds a plaintext token: tighten, else refuse
        try:
            creds_file.chmod(0o600)
            print(f"[release-wiki] WARNING: tightened credentials file mode "
                  f"from 0{mode:o} to 0600: {creds_file}", file=sys.stderr)
        except OSError as exc:
            raise PermissionError(
                f"Credentials file {creds_file} has unsafe mode 0{mode:o} "
                f"(holds plaintext token); refusing to load. chmod 600 to fix. "
                f"(auto-fix failed: {exc})"
            ) from exc
    try:
        data = json.loads(creds_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Malformed credentials file {creds_file}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("teams"), dict):
        raise ValueError(f"Credentials file {creds_file} missing required 'teams' dict.")
    return data


def _load_creds_file() -> dict:
    """Poller-parity loader; every failure is a WikiCredentialError carrying the
    poller's exact message text (chained, so the original type stays visible)."""
    try:
        return _read_creds_file()
    except (OSError, ValueError) as exc:  # FileNotFound/Permission/JSON/schema
        raise WikiCredentialError(str(exc)) from exc


def _parse_secret(value: str) -> Tuple[str, str]:
    """`email:token` (first colon) or JSON {"email","api_token"}. Never echoes value."""
    bad = WikiCredentialError(
        "secretRef value must be '<email>:<api_token>' or JSON "
        '{"email":..., "api_token":...}')
    if not isinstance(value, str):  # bytes/int from a resolver: refuse, never coerce
        raise bad
    text = value.strip()
    if text.startswith("{"):
        try:
            obj = json.loads(text)
            email, token = obj["email"], obj["api_token"]
        except (ValueError, KeyError, TypeError):
            raise bad from None
    else:
        email, sep, token = text.partition(":")
        if not sep:
            raise bad
    if not (_nonblank_str(email) and _nonblank_str(token)):
        raise bad
    return email, token


def _nonblank_str(value) -> bool:
    return isinstance(value, str) and bool(value.strip())


# A scheme-looking prefix ("http:", "https:/x") that is NOT a bare host:port.
_SCHEME_TYPO = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:(?![0-9]+(?:/|(?![\s\S])))")


def _site_to_base(site: str) -> str:
    """Normalize to https://<host>[:port][/path]/wiki. https only (any casing);
    a bare host gets https://; any other scheme is refused (token over cleartext).
    Scheme typos (http:/x, https//x) and whitespace are refused, never guessed at."""
    if not isinstance(site, str):
        raise WikiCredentialError("base URL must be a string")
    raw = site.strip()
    if not raw:
        raise WikiCredentialError("base URL is empty")
    if any(c.isspace() for c in raw):
        raise WikiCredentialError("malformed base URL (whitespace)")
    if "://" not in raw:
        if _SCHEME_TYPO.match(raw) or raw.lower().startswith(("http/", "https/", "http//", "https//")):
            raise WikiCredentialError("malformed base URL (scheme typo)")
        raw = "https://" + raw
    try:
        u = urllib.parse.urlsplit(raw)
        u.port  # validates the port
    except ValueError:
        raise WikiCredentialError("malformed base URL") from None
    if u.scheme.lower() != "https":
        raise WikiCredentialError(f"base URL must use https (got scheme '{u.scheme}')")
    if not u.hostname or u.username is not None:
        raise WikiCredentialError("malformed base URL")
    path = u.path.rstrip("/")
    if not path.endswith("/wiki"):
        path += "/wiki"
    return "https://" + u.netloc.lower() + path


_REF_NAMEABLE = re.compile(r"(vault:[a-z][a-z0-9-]{0,63}/[a-z][a-z0-9-]{0,63}|env:[A-Z][A-Z0-9_]{0,127})")


def load_credential(
    team: str,
    secret_ref: Optional[str] = None,
    base_url: Optional[str] = None,
    resolver: Optional[Callable[[str, str], str]] = None,
    resolution_error: Optional[type] = None,
) -> ConfluenceCredential:
    """secretRef first; on SecretResolutionError fall back to the poller-format file.

    `resolver`/`resolution_error` are test seams; by default both come from
    release_config_validate (resolve_secret_ref / SecretResolutionError).
    """
    if base_url is not None and not isinstance(base_url, str):
        raise WikiCredentialError("baseUrl must be a string")
    if secret_ref:
        if resolver is None:
            mod = _load_secret_module()
            resolver, resolution_error = mod.resolve_secret_ref, mod.SecretResolutionError
        try:
            value = resolver(secret_ref, team)
        except (resolution_error or Exception) as exc:
            value = None  # fall through to the credentials file
            # Name the ref only if it is grammar-shaped (a literal secret pasted
            # into secretRef must never be echoed); never the resolved value.
            shown = secret_ref if _REF_NAMEABLE.fullmatch(secret_ref) else "<malformed>"
            print(f"kb-wiki: secretRef {shown} did not resolve "
                  f"({type(exc).__name__}); using credentials file", file=sys.stderr)
        if value is not None:
            if not base_url:
                raise WikiCredentialError("baseUrl is required with a secretRef credential")
            email, token = _parse_secret(value)
            return ConfluenceCredential(email, token, _site_to_base(base_url), "secretRef")
    data = _load_creds_file()
    # Deliberately NOT honoring the poller's "default" key: kb-wiki writes as
    # the calling team, and borrowing another team's token breaks team
    # isolation (spec 2.2) -- the same rule resolve_secret_ref enforces.
    entry = data["teams"].get(team)
    if not isinstance(entry, dict) or not all(
            _nonblank_str(entry.get(k)) for k in ("site", "email", "api_token")):
        raise WikiCredentialError(f"No complete credentials for team '{team}'")
    return ConfluenceCredential(entry["email"], entry["api_token"],
                                _site_to_base(base_url or entry["site"]), "credentials-file")


# ---------------------------------------------------------------- transport


def urllib_transport(method, url, headers, body):
    """Every failure mode becomes a WikiTransportError (never echoes headers)."""
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, exc.read()
        except (OSError, http.client.HTTPException) as inner:
            raise WikiTransportError(
                f"network error reading HTTP {exc.code} body: {type(inner).__name__}",
                exc.code) from inner
    except urllib.error.URLError as exc:
        raise WikiTransportError(f"network error: {exc.reason}") from exc
    except (OSError, http.client.HTTPException) as exc:  # timeout, reset, RemoteDisconnected
        raise WikiTransportError(f"network error: {type(exc).__name__}") from exc
    except ValueError as exc:  # malformed URL
        raise WikiTransportError("malformed request URL") from exc


_SPACE_KEY = re.compile(r"[A-Za-z0-9~_-]{1,255}")
_LABEL = re.compile(r"[a-z0-9][a-z0-9._-]{0,254}")


def _id(value, what: str) -> str:
    """Numeric ids only (str of ASCII digits, or a positive int); else WikiError."""
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return str(value)
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return value
    raise WikiError(f"invalid {what} id (must be numeric)")


# ---------------------------------------------------------------- provider


class ConfluenceProvider(WikiProvider):
    def __init__(self, cred: ConfluenceCredential, transport: Optional[Transport] = None):
        self.cred = cred
        self._transport = transport or urllib_transport

    def _call(self, method: str, path: str, payload: Any = None) -> Any:
        headers = {"Authorization": self.cred.auth_header(),
                   "Accept": "application/json", "Content-Type": "application/json"}
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        status, raw = self._transport(method, self.cred.base_url + path, headers, body)
        route = path.split("?")[0]
        if status in (401, 403):
            raise WikiCredentialError(f"Confluence rejected credentials (HTTP {status})")
        if status == 404:
            raise WikiNotFoundError(f"Confluence 404 for {route}")
        if status == 409:
            raise WikiConflictError("Confluence version conflict (HTTP 409)")
        if not 200 <= status < 300:
            raise WikiTransportError(f"Confluence HTTP {status} for {method} {route}", status)
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError as exc:
            raise WikiTransportError("Confluence returned non-JSON body", status) from exc
        if not isinstance(data, dict):
            raise WikiTransportError("Confluence returned an unexpected JSON shape", status)
        return data

    def _next_path(self, link: Any) -> str:
        """Turn a server-supplied `_links.next` into a path relative to base_url.
        Absolute links must be https on the SAME host (the Basic-auth header
        rides every request). v1 next is base-relative; v2 next may carry the
        /wiki context prefix (unconfirmed live), so both are accepted."""
        if not isinstance(link, str) or not link:
            raise WikiTransportError("malformed pagination link")
        try:
            u = urllib.parse.urlsplit(link)
            base = urllib.parse.urlsplit(self.cred.base_url)
        except ValueError:
            raise WikiTransportError("malformed pagination link") from None
        if u.scheme or u.netloc:
            if u.scheme.lower() != "https" or u.netloc.lower() != base.netloc.lower():
                raise WikiTransportError("refusing pagination link to a different host")
        path = u.path
        if not path.startswith("/"):
            raise WikiTransportError("malformed pagination link")
        if path == base.path or path.startswith(base.path + "/"):
            path = path[len(base.path):]
        return path + ("?" + u.query if u.query else "")

    def _collect(self, path: str) -> list:
        """GET a collection, following _links.next until absent. Fail closed:
        exceeding MAX_PAGES raises instead of returning a partial list."""
        results: list = []
        for _ in range(MAX_PAGES):
            data = self._call("GET", path)
            chunk = data.get("results", [])
            if not isinstance(chunk, list):
                raise WikiTransportError("Confluence returned an unexpected results shape")
            results.extend(chunk)
            links = data.get("_links")
            nxt = links.get("next") if isinstance(links, dict) else None
            if not nxt:
                return results
            path = self._next_path(nxt)
        raise WikiTransportError(f"pagination exceeded {MAX_PAGES} pages; refusing a partial result")

    def _page(self, d: dict, kind: str = "page") -> WikiPage:
        try:
            pid = str(d.get("id", ""))
            webui = (d.get("_links") or {}).get("webui", "")
            labels = ((d.get("metadata") or {}).get("labels") or {}).get("results") or []
            return WikiPage(
                id=pid, title=d.get("title", ""),
                version=int(((d.get("version") or {}).get("number")) or 0),
                body=((d.get("body") or {}).get("storage") or {}).get("value", ""),
                url=self.cred.base_url + webui if webui else self.page_url(pid),
                labels=tuple(x.get("name", "") for x in labels),
                ancestors=tuple(WikiAncestor(str(a.get("id", "")), a.get("title", ""))
                                for a in d.get("ancestors") or []),
                kind=kind, space=str((d.get("space") or {}).get("key", "")))
        except (AttributeError, TypeError, ValueError) as exc:
            raise WikiTransportError("Confluence returned an unexpected page shape") from exc

    # v1 pages
    def get_page(self, page_id):
        return self._page(self._call("GET", f"/rest/api/content/{_id(page_id, 'page')}?expand={EXPAND}"))

    def create_page(self, space, title, body, parent_type, parent_id):
        if parent_type not in ("page", "folder"):
            raise WikiTransportError(f"unsupported parent type: {parent_type}")
        # UNCONFIRMED against live Confluence (verify in XACA-1344-008): a
        # folder-typed parent passed via v1 `ancestors`. Page parents are proven.
        payload = {"type": "page", "title": title, "space": {"key": space},
                   "ancestors": [{"id": _id(parent_id, "parent")}],
                   "body": {"storage": {"value": body, "representation": "storage"}}}
        return self._page(self._call("POST", f"/rest/api/content?expand={EXPAND}", payload))

    def update_page(self, page_id, title, body, current_version):
        payload = {"type": "page", "title": title,
                   "version": {"number": current_version + 1},
                   "body": {"storage": {"value": body, "representation": "storage"}}}
        return self._page(self._call("PUT", f"/rest/api/content/{_id(page_id, 'page')}?expand={EXPAND}",
                                     payload))

    def find_by_title(self, space, title, parent_id=None):
        pid = _id(parent_id, "parent") if parent_id is not None else None
        q = urllib.parse.urlencode({"spaceKey": space, "title": title, "type": "page",
                                    "expand": EXPAND})
        # Gather EVERY page of results first; only then filter by parent.
        pages = [self._page(r) for r in self._collect(f"/rest/api/content?{q}")]
        if pid is not None:
            pages = [p for p in pages if p.ancestors and p.ancestors[-1].id == pid]
        return pages

    # identity labels (kb-wiki-<doc>-<key>)
    def find_by_label(self, space, label):
        if not _SPACE_KEY.fullmatch(space or "") or not _LABEL.fullmatch(label or ""):
            raise WikiError("invalid space key or label")
        # UNCONFIRMED against live Confluence (XACA-1344-008): CQL through the v1
        # content search endpoint; both values are regex-validated above.
        cql = f'label = "{label}" AND space = "{space}" AND type = page'
        q = urllib.parse.urlencode({"cql": cql, "expand": EXPAND})
        return [self._page(r) for r in self._collect(f"/rest/api/content/search?{q}")]

    def add_label(self, page_id, label):
        if not _LABEL.fullmatch(label or ""):
            raise WikiError("invalid label")
        # UNCONFIRMED against live Confluence (XACA-1344-008): v1 label POST.
        self._call("POST", f"/rest/api/content/{_id(page_id, 'page')}/label",
                   [{"prefix": "global", "name": label}])

    # v2 folders
    def get_folder(self, folder_id):
        return self._page(self._call("GET", f"/api/v2/folders/{_id(folder_id, 'folder')}"),
                          kind="folder")

    def list_children(self, parent_type, parent_id):
        if parent_type not in ("page", "folder"):
            raise WikiTransportError(f"unsupported parent type: {parent_type}")
        pid = _id(parent_id, parent_type)
        if parent_type == "folder":
            # UNCONFIRMED endpoint name (v2 direct-children); verify live in 008.
            rows = self._collect(f"/api/v2/folders/{pid}/direct-children")
            return [self._page(r, kind=r.get("type", "page") if isinstance(r, dict) else "page")
                    for r in rows]
        return [self._page(r) for r in
                self._collect(f"/rest/api/content/{pid}/child/page?expand=version")]

    def page_url(self, page_id):
        return f"{self.cred.base_url}/pages/viewpage.action?pageId={page_id}"

    # doctor support (XACA-1344-006)
    def credential_summary(self):
        host = urllib.parse.urlsplit(self.cred.base_url).hostname or ""
        return {"source": self.cred.source, "host": host}

    def can_write(self, space, parent_type, parent_id):
        """Read-only permission probe; nothing is created. Asks the SPACE which
        operations the current user holds. v1 `content/{id}?expand=operations`
        describes operations ON that page (update/delete), not creating a child,
        so it cannot answer this. UNCONFIRMED against live Confluence
        (XACA-1344-008): that `GET /rest/api/space/{key}?expand=operations`
        returns [{"operation": "create", "targetType": "page"}, ...] for the
        caller. True only on an explicit create/page entry; False only for a
        non-empty, well-formed list without one; anything else is None."""
        if not (isinstance(space, str) and re.fullmatch(r"[A-Za-z0-9~][A-Za-z0-9_.~-]{0,254}", space)):
            raise WikiError("invalid space key")
        data = self._call("GET", f"/rest/api/space/{urllib.parse.quote(space, safe='')}?expand=operations")
        ops = data.get("operations")
        if not isinstance(ops, list) or not ops or not all(isinstance(o, dict) for o in ops):
            return None
        return any(o.get("operation") == "create" and o.get("targetType") == "page" for o in ops)
