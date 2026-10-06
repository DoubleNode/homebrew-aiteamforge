"""Local (file-backed) WikiProvider for release_wiki (XACA-1370-002). stdlib only.

For teams that must not write to Confluence: documents live as plain files under
a wiki root (the caller passes <team-kanban>/wiki/, which kanban-backup already
covers). Python 3.9 compatible.

ON-DISK LAYOUT (everything below <root>/)::

    .lock                       flock target; held around every read and write
    .next-id                    last id handed out (text integer), under .lock
    pages/<id>/                 <id> is a decimal integer, never derived from a title
        meta.json               CURRENT metadata (commit point of every write):
                                {"id","kind":"page"|"folder","title","space",
                                 "version","parent_type","parent_id",
                                 "ancestors":[{"id","title"}, ...root-first],
                                 "labels":[...], "created","updated"}
        body.html               readable copy of the current body (written last;
                                the AUTHORITATIVE body is versions/<version>.html)
        versions/<n>.html       body of version n (every version is kept)
        versions/<n>.json       {"version","title","updated"} for version n

Folders are pages/<id>/ with kind "folder" and no body/versions (meta.json
only, version 0). create_folder()/ensure_folder() are local-only helpers: the
WikiProvider ABC has no verb to make a folder, and a fresh local tree needs one.

Semantics matched to the Confluence provider / the in-memory fake:
  * ids are numeric strings; a non-numeric id is WikiError (Confluence `_id`).
  * update_page requires current_version == stored version, else
    WikiConflictError; the new version is current_version + 1; prior versions
    stay in versions/. Title may change; ancestors/labels/space are kept.
  * add_label is idempotent and never bumps the version.
  * find_by_title is exact, space-scoped, optionally filtered to pages whose
    LAST ancestor is parent_id. Titles are NOT forced unique (the orchestration
    layer refuses duplicates); titles are only ever stored inside meta.json,
    never used as a path component, so a title cannot traverse out of the root.
  * ancestor titles are refreshed from the live ancestor on every read.
  * page_url is a file:// URL of pages/<id>/body.html (no existence check).
  * Writes are atomic (temp file in the same dir, fsync, os.replace, dir fsync)
    and the whole read-modify-write runs under fcntl.flock(LOCK_EX); reads take
    LOCK_SH so they never see a half-applied update.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_wiki import (  # noqa: E402
    WikiAncestor, WikiConflictError, WikiError, WikiNotFoundError, WikiPage,
    WikiProvider, WikiTransportError,
)

_SPACE_KEY = re.compile(r"[A-Za-z0-9~_-]{1,255}")
_LABEL = re.compile(r"[a-z0-9][a-z0-9._-]{0,254}")
_ID = re.compile(r"[0-9]{1,18}")
FIRST_ID = 1000  # ids start here so they never look like tiny hand-typed numbers


def _read_umask() -> int:
    # os.umask() can only be READ by setting it, which briefly changes the
    # process-wide mask. Doing that per write would race with other threads that
    # create files. Doing it once at import (single-threaded, before any provider
    # exists) and restoring immediately keeps the window negligible and gives the
    # mode a normal open() would have produced: 0o666 & ~umask.
    mask = os.umask(0)
    os.umask(mask)
    return mask


# tempfile.mkstemp() always creates 0600 and os.replace() keeps that mode, so
# without this every page file was 0600 while .lock (opened with 0o644) honoured
# the umask. Files must follow the umask exactly like a plain open() would.
_FILE_MODE = 0o666 & ~_read_umask()


# ---------------------------------------------------------------- file helpers


def _fsync_dir(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _atomic_write(path: Path, data: bytes) -> None:
    """Temp file in the SAME directory + fsync + os.replace. On any failure the
    temp file is removed and `path` keeps its previous content (or stays absent)."""
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as fh:
            os.fchmod(fh.fileno(), _FILE_MODE)
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _fsync_dir(path.parent)


def _meta_shape_ok(meta: dict) -> bool:
    """Every field the verbs index directly must be present and well-typed, so
    a hand-edited or truncated meta.json surfaces as WikiError("corrupt
    metadata") instead of a raw KeyError/TypeError deep inside a scan
    (XACA-1370-014)."""
    version = meta.get("version")
    return (meta.get("kind") in ("page", "folder")
            and isinstance(meta.get("title"), str)
            and isinstance(meta.get("space"), str)
            and isinstance(version, int) and not isinstance(version, bool) and version >= 0
            and isinstance(meta.get("labels", []), list)
            and isinstance(meta.get("ancestors", []), list))


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _id(value, what: str) -> str:
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        value = str(value)
    if isinstance(value, str) and _ID.fullmatch(value):
        return str(int(value))  # canonical: no leading zeros -> one dir per id
    raise WikiError(f"invalid {what} id (must be numeric)")


def _clean_title(title) -> str:
    if (not isinstance(title, str) or not title.strip() or len(title) > 255
            or any(ord(c) < 32 or ord(c) == 127 for c in title)):
        raise WikiError("invalid title (non-empty, <=255 chars, no control characters)")
    return title


def _clean_space(space) -> str:
    if not isinstance(space, str) or not _SPACE_KEY.fullmatch(space):
        raise WikiError("invalid space key")
    return space


# ---------------------------------------------------------------- provider


class LocalProvider(WikiProvider):
    def __init__(self, root):
        self.root = Path(os.path.abspath(os.path.expanduser(str(root))))

    # -- locking / paths
    @contextmanager
    def _locked(self, exclusive: bool, create: bool) -> Iterator[None]:
        lock = self.root / ".lock"
        if create:
            try:
                (self.root / "pages").mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                raise WikiError(f"cannot create wiki root: {exc.strerror or type(exc).__name__}") from exc
        elif not lock.exists():
            yield  # nothing was ever written: reads see an empty wiki
            return
        try:
            fd = os.open(str(lock), (os.O_RDWR | os.O_CREAT) if exclusive else os.O_RDONLY, 0o666)  # kernel applies the umask
        except OSError as exc:
            raise WikiError(f"cannot open wiki lock: {exc.strerror or type(exc).__name__}") from exc
        try:
            fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
            yield
        finally:
            os.close(fd)  # closing releases the flock

    def _dir(self, pid: str) -> Path:
        return self.root / "pages" / pid

    def _read_meta(self, pid: str) -> Optional[dict]:
        path = self._dir(pid) / "meta.json"
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise WikiError(f"cannot read page {pid}: {exc.strerror or type(exc).__name__}") from exc
        try:
            meta = json.loads(raw)
            if not isinstance(meta, dict) or meta.get("id") != pid or not _meta_shape_ok(meta):
                raise ValueError("shape")
            return meta
        except ValueError as exc:
            raise WikiError(f"corrupt metadata for page {pid}") from exc

    def _all_ids(self) -> List[str]:
        try:
            names = os.listdir(str(self.root / "pages"))
        except FileNotFoundError:
            return []
        return sorted((n for n in names if _ID.fullmatch(n)), key=int)

    def _body(self, meta: dict) -> str:
        if meta["kind"] == "folder":
            return ""
        path = self._dir(meta["id"]) / "versions" / f"{meta['version']}.html"
        try:
            return path.read_text(encoding="utf-8")
        except OSError as exc:
            raise WikiError(f"missing body for page {meta['id']} v{meta['version']}") from exc

    def _page(self, meta: dict) -> WikiPage:
        try:
            ancestors = []
            for a in meta.get("ancestors", []):
                live = self._read_meta(a["id"])
                ancestors.append(WikiAncestor(a["id"], live["title"] if live else a.get("title", "")))
            return WikiPage(
                id=meta["id"], title=meta["title"], version=int(meta["version"]),
                body=self._body(meta), url=self.page_url(meta["id"]),
                labels=tuple(meta.get("labels", [])), ancestors=tuple(ancestors),
                kind=meta["kind"], space=meta["space"])
        except (KeyError, TypeError, ValueError) as exc:
            raise WikiError(f"corrupt metadata for page {meta.get('id', '?')}") from exc

    def _get(self, pid, kind: str, what: str) -> dict:
        pid = _id(pid, what)
        meta = self._read_meta(pid)
        if meta is None or meta.get("kind") != kind:
            raise WikiNotFoundError(f"no {kind} {pid}")
        return meta

    def _next_id(self) -> str:
        path = self.root / ".next-id"
        try:
            last = int(path.read_text().strip())
        except (FileNotFoundError, ValueError):
            last = FIRST_ID - 1
        # A numeric but out-of-range counter (negative, or so large the next id
        # would exceed the 18 digits _ID accepts) is as garbled as a non-numeric
        # one: treat it the same way. Otherwise the next create would commit a
        # page whose id every later read rejects, and the bad counter would
        # wedge every following create too.
        if not FIRST_ID - 1 <= last < 10 ** 18 - 1:
            last = FIRST_ID - 1
        # also skip past anything already on disk (a lost/garbled counter)
        ids = self._all_ids()
        if ids:
            last = max(last, int(ids[-1]))
        nxt = last + 1
        if nxt > 10 ** 18 - 1:  # refuse BEFORE writing anything (see above)
            raise WikiError("local wiki id space exhausted")
        _atomic_write(path, str(nxt).encode("ascii"))
        return str(nxt)

    def _write_meta(self, meta: dict) -> None:
        _atomic_write(self._dir(meta["id"]) / "meta.json",
                      (json.dumps(meta, indent=2, sort_keys=True) + "\n").encode("utf-8"))

    def _write_version(self, meta: dict, body: str) -> None:
        d = self._dir(meta["id"])
        v = meta["version"]
        (d / "versions").mkdir(parents=True, exist_ok=True)
        _atomic_write(d / "versions" / f"{v}.html", body.encode("utf-8"))
        _atomic_write(d / "versions" / f"{v}.json", (json.dumps(
            {"version": v, "title": meta["title"], "updated": meta["updated"]},
            sort_keys=True) + "\n").encode("utf-8"))

    # -- provider verbs
    def get_page(self, page_id):
        with self._locked(False, False):
            return self._page(self._get(page_id, "page", "page"))

    def get_folder(self, folder_id):
        with self._locked(False, False):
            return self._page(self._get(folder_id, "folder", "folder"))

    def create_page(self, space, title, body, parent_type, parent_id):
        if parent_type not in ("page", "folder"):
            raise WikiTransportError(f"unsupported parent type: {parent_type}")
        space, title = _clean_space(space), _clean_title(title)
        if not isinstance(body, str):
            raise WikiError("body must be a string")
        with self._locked(True, True):
            parent = self._get(parent_id, parent_type, "parent")
            pid = self._next_id()
            now = _now()
            meta = {"id": pid, "kind": "page", "title": title, "space": space, "version": 1,
                    "parent_type": parent_type, "parent_id": parent["id"],
                    "ancestors": list(parent.get("ancestors", []))
                    + [{"id": parent["id"], "title": parent["title"]}],
                    "labels": [], "created": now, "updated": now}
            self._dir(pid).mkdir(parents=True, exist_ok=True)
            self._write_version(meta, body)
            self._write_meta(meta)  # commit point
            _atomic_write(self._dir(pid) / "body.html", body.encode("utf-8"))
            return self._page(meta)

    def update_page(self, page_id, title, body, current_version):
        title = _clean_title(title)
        if not isinstance(body, str):
            raise WikiError("body must be a string")
        with self._locked(True, True):
            meta = self._get(page_id, "page", "page")
            if (isinstance(current_version, bool) or not isinstance(current_version, int)
                    or current_version != meta["version"]):
                raise WikiConflictError("local wiki version conflict (stored version is not current)")
            meta.update(title=title, version=meta["version"] + 1, updated=_now())
            self._write_version(meta, body)
            self._write_meta(meta)  # commit point
            _atomic_write(self._dir(meta["id"]) / "body.html", body.encode("utf-8"))
            return self._page(meta)

    def find_by_title(self, space, title, parent_id=None):
        pid = _id(parent_id, "parent") if parent_id is not None else None
        with self._locked(False, False):
            out = []
            for i in self._all_ids():
                m = self._read_meta(i)
                if not m or m["kind"] != "page" or m["space"] != space or m["title"] != title:
                    continue
                if pid is not None and m.get("parent_id") != pid:
                    continue
                out.append(self._page(m))
            return out

    def find_by_label(self, space, label):
        if not _SPACE_KEY.fullmatch(space or "") or not _LABEL.fullmatch(label or ""):
            raise WikiError("invalid space key or label")
        with self._locked(False, False):
            out = []
            for i in self._all_ids():
                m = self._read_meta(i)
                if m and m["kind"] == "page" and m["space"] == space and label in m.get("labels", []):
                    out.append(self._page(m))
            return out

    def add_label(self, page_id, label):
        if not _LABEL.fullmatch(label or ""):
            raise WikiError("invalid label")
        with self._locked(True, True):
            meta = self._get(page_id, "page", "page")
            if label not in meta.setdefault("labels", []):
                meta["labels"].append(label)
                self._write_meta(meta)

    def list_children(self, parent_type, parent_id):
        if parent_type not in ("page", "folder"):
            raise WikiTransportError(f"unsupported parent type: {parent_type}")
        pid = _id(parent_id, parent_type)
        with self._locked(False, False):
            return [self._page(m) for m in (self._read_meta(i) for i in self._all_ids())
                    if m and m.get("parent_id") == pid]

    def page_url(self, page_id):
        pid = _id(page_id, "page")
        return (self._dir(pid) / "body.html").as_uri()

    # -- doctor support
    def credential_summary(self):
        return {"source": "local", "host": "local"}  # no credential exists

    def can_write(self, space, parent_type, parent_id):
        """Writable-directory check, never writes. The wiki root need not exist
        yet: the nearest existing ancestor must be writable instead."""
        probe = self.root
        while not probe.exists():
            if probe.parent == probe:
                return False
            probe = probe.parent
        if not (probe.is_dir() and os.access(str(probe), os.W_OK | os.X_OK)):
            return False
        if parent_id is not None and (self.root / "pages").exists():
            try:
                with self._locked(False, False):
                    self._get(parent_id, parent_type, "parent")
            except WikiNotFoundError:
                return False
        return True

    # -- local-only bootstrap helpers (not part of the ABC)
    def create_folder(self, space, title, parent_id=None) -> WikiPage:
        space, title = _clean_space(space), _clean_title(title)
        with self._locked(True, True):
            return self._make_folder(space, title, parent_id)

    def _make_folder(self, space, title, parent_id) -> WikiPage:
        anc, ptype, pid_parent = [], "", ""
        if parent_id is not None:
            p = self._get(parent_id, "folder", "parent")
            anc = list(p.get("ancestors", [])) + [{"id": p["id"], "title": p["title"]}]
            ptype, pid_parent = "folder", p["id"]
        fid = self._next_id()
        now = _now()
        meta = {"id": fid, "kind": "folder", "title": title, "space": space, "version": 0,
                "parent_type": ptype, "parent_id": pid_parent, "ancestors": anc,
                "labels": [], "created": now, "updated": now}
        self._dir(fid).mkdir(parents=True, exist_ok=True)
        self._write_meta(meta)
        return self._page(meta)

    def ensure_folder(self, space, title, parent_id=None) -> WikiPage:
        """Idempotent create_folder: the existing same-titled folder under the
        same parent, else a new one. One exclusive lock, so concurrent callers
        converge on a single folder."""
        space, title = _clean_space(space), _clean_title(title)
        pid = _id(parent_id, "parent") if parent_id is not None else ""
        with self._locked(True, True):
            m = self._scan_folder(space, title, pid)
            return self._page(m) if m else self._make_folder(space, title, parent_id)

    def find_folder(self, space, title, parent_id=None) -> Optional[WikiPage]:
        """Read-only ensure_folder: the same-titled folder under the same
        parent, or None. Takes a shared lock and never creates the root."""
        space, title = _clean_space(space), _clean_title(title)
        pid = _id(parent_id, "parent") if parent_id is not None else ""
        with self._locked(False, False):
            m = self._scan_folder(space, title, pid)
            return self._page(m) if m else None

    def _scan_folder(self, space, title, pid) -> Optional[dict]:
        # Caller holds the lock.
        for i in self._all_ids():
            m = self._read_meta(i)
            if (m and m["kind"] == "folder" and m["space"] == space and m["title"] == title
                    and m.get("parent_id", "") == pid):
                return m
        return None

    def history(self, page_id) -> List[dict]:
        """[{version, title, updated}] oldest first (local-only convenience)."""
        with self._locked(False, False):
            meta = self._get(page_id, "page", "page")
            out = []
            for v in range(1, meta["version"] + 1):
                try:
                    out.append(json.loads((self._dir(meta["id"]) / "versions" / f"{v}.json")
                                          .read_text(encoding="utf-8")))
                except (OSError, ValueError) as exc:
                    raise WikiError(f"missing history for page {meta['id']} v{v}") from exc
            return out

    def get_version_body(self, page_id, version: int) -> str:
        with self._locked(False, False):
            meta = self._get(page_id, "page", "page")
            if (isinstance(version, bool) or not isinstance(version, int)
                    or not 1 <= version <= meta["version"]):
                raise WikiNotFoundError(f"no version {version} of page {meta['id']}")
            try:
                return (self._dir(meta["id"]) / "versions" / f"{version}.html").read_text(encoding="utf-8")
            except OSError as exc:
                raise WikiError(f"missing body for page {meta['id']} v{version}") from exc
