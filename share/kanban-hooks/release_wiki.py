"""Provider-agnostic wiki library for the release workflow (XACA-1344).

PR 1/3 scope: the WikiProvider interface, the provider-neutral WikiPage
result type, and typed errors. Publish / version-guard / patch-section /
doctor logic (XACA-1344-003..006) drop in below the marked seam; they
consume only this interface, never a concrete provider.

`WikiPage` is deliberately provider-generic so a future `wiki-signal`
approval provider (spec section 9) can call `read` without a new API.
"""
from __future__ import annotations

import abc
import difflib
import html
import re
from dataclasses import dataclass
from typing import List, Optional, Tuple

# ---------------------------------------------------------------- errors


class WikiError(Exception):
    """Base for every wiki failure. Messages never carry credentials."""


class WikiCredentialError(WikiError):
    """Credentials missing, malformed, unsafe, or rejected (401/403)."""


class WikiNotFoundError(WikiError):
    """Page/folder does not exist (404)."""


class WikiConflictError(WikiError):
    """Update refused because the stored version is stale (409)."""


class WikiTransportError(WikiError):
    """Network failure or unexpected HTTP status; carries `status` if any."""

    def __init__(self, message: str, status: Optional[int] = None) -> None:
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------- results


@dataclass(frozen=True)
class WikiAncestor:
    id: str
    title: str = ""


@dataclass(frozen=True)
class WikiPage:
    """Provider-neutral page (or folder) snapshot."""

    id: str
    title: str
    version: int = 0
    body: str = ""
    url: str = ""
    labels: Tuple[str, ...] = ()
    ancestors: Tuple[WikiAncestor, ...] = ()
    kind: str = "page"  # "page" | "folder"
    space: str = ""  # space key when the provider exposes it ("" = unknown)


# ---------------------------------------------------------------- interface


class WikiProvider(abc.ABC):
    """The seven verbs every provider implements (spec section 10.2)."""

    @abc.abstractmethod
    def get_page(self, page_id: str) -> WikiPage:
        """Read body + version + labels + ancestors. WikiNotFoundError if absent."""

    @abc.abstractmethod
    def create_page(
        self, space: str, title: str, body: str, parent_type: str, parent_id: str
    ) -> WikiPage:
        """Create under a parent of `parent_type` ("page" | "folder")."""

    @abc.abstractmethod
    def update_page(
        self, page_id: str, title: str, body: str, current_version: int
    ) -> WikiPage:
        """Write version current_version+1. WikiConflictError if stale."""

    @abc.abstractmethod
    def find_by_title(
        self, space: str, title: str, parent_id: Optional[str] = None
    ) -> List[WikiPage]:
        """Exact-title lookup; [] when nothing matches."""

    @abc.abstractmethod
    def find_by_label(self, space: str, label: str) -> List[WikiPage]:
        """Every page in `space` carrying `label`; [] when none."""

    @abc.abstractmethod
    def add_label(self, page_id: str, label: str) -> None:
        """Attach `label` to a page. Raises a WikiError on any failure."""

    @abc.abstractmethod
    def list_children(self, parent_type: str, parent_id: str) -> List[WikiPage]:
        """Direct children of a page or folder."""

    @abc.abstractmethod
    def get_folder(self, folder_id: str) -> WikiPage:
        """Read a folder (kind == "folder"). WikiNotFoundError if absent."""

    @abc.abstractmethod
    def page_url(self, page_id: str) -> str:
        """Stable browse URL for a page id; no network."""


# ---------------------------------------------------------------- PR 2 errors


class WikiUsageError(WikiError):
    """Caller passed an unusable argument combination (CLI exit 2)."""


class WikiLocationError(WikiError):
    """Configured parent is missing / wrong type, or a created page landed
    outside it. Never carries a body."""


class WikiDuplicateError(WikiError):
    """A page with the target title already exists; adopt it via --page-id
    instead of minting a second page."""

    def __init__(self, message: str, page_id: str = "") -> None:
        super().__init__(message)
        self.page_id = page_id


class WikiIdentityError(WikiError):
    """The page is not the one for this (doc, key): it carries another key's
    kb-wiki label, or none, or the label could not be applied/verified."""


class WikiPatchError(WikiError):
    """patch-section could not proceed safely (heading absent / ambiguous /
    malformed markup). Nothing was written."""


class WikiGuardError(WikiError):
    """Version guard refusal (CLI exit 4). `diff` is a unified diff of the live
    body vs. the body that would have been written; the page is unchanged."""

    def __init__(self, message: str, live_version: int = 0, diff: str = "") -> None:
        super().__init__(message)
        self.live_version = live_version
        self.diff = diff


@dataclass(frozen=True)
class PublishResult:
    page_id: str
    url: str
    version: int
    created: bool = False

    def record(self) -> dict:
        """The keyed-record fields the engine stores (XACA-1348/1349)."""
        return {"pageId": self.page_id, "url": self.url, "version": self.version}


# ---------------------------------------------------------------- version guard


def _diff(live_body: str, new_body: str) -> str:
    return "".join(difflib.unified_diff(
        live_body.splitlines(keepends=True), new_body.splitlines(keepends=True),
        fromfile="live", tofile="rendered"))


def _check_version_arg(name: str, value) -> None:
    if value is None:
        return
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise WikiUsageError(f"{name} must be a non-negative integer")


def check_version_guard(live: WikiPage, new_body: str,
                        stored_version: Optional[int] = None,
                        expect_version: Optional[int] = None) -> None:
    """Refuse (WikiGuardError, never a write) unless the live page is exactly
    at the version the caller last saw. At least one of stored/expect is
    required (WikiUsageError otherwise); if both are given both must hold."""
    _check_version_arg("stored_version", stored_version)
    _check_version_arg("expect_version", expect_version)
    if stored_version is None and expect_version is None:
        raise WikiUsageError("updating an existing page needs --stored-version or --expect-version")
    reason = None
    if expect_version is not None and live.version != expect_version:
        reason = (f"live version {live.version} != expected version {expect_version}; "
                  "page changed since it was read")
    elif stored_version is not None and live.version > stored_version:
        reason = (f"live version {live.version} is newer than stored version "
                  f"{stored_version}; the page was edited outside kb-wiki")
    elif stored_version is not None and live.version < stored_version:
        reason = (f"live version {live.version} is LOWER than stored version "
                  f"{stored_version}; the stored record is wrong or the page was replaced")
    if reason is not None:
        raise WikiGuardError(reason, live.version, _diff(live.body, new_body))


def _apply_label(provider: WikiProvider, page_id: str, label: str) -> None:
    """Fail closed: the label must be applied AND read back."""
    try:
        provider.add_label(page_id, label)
        ok = label in provider.get_page(page_id).labels
    except WikiNotFoundError:
        raise
    except WikiError as exc:
        raise WikiIdentityError(
            f"could not label page {page_id} ({type(exc).__name__}); "
            f"re-run with --page-id {page_id} --adopt") from exc
    if not ok:
        raise WikiIdentityError(
            f"label {label!r} did not stick on page {page_id}; re-run with --page-id {page_id} --adopt")


def _guarded_update(provider: WikiProvider, live: WikiPage, title: str, body: str,
                    stored_version: Optional[int], expect_version: Optional[int],
                    label: Optional[str] = None) -> PublishResult:
    check_version_guard(live, body, stored_version, expect_version)
    if label is not None:
        _apply_label(provider, live.id, label)
    try:
        page = provider.update_page(live.id, title, body, live.version)
    except WikiConflictError as exc:
        # Lost a race between our read and the write: same refusal class.
        diff = ""
        try:
            diff = _diff(provider.get_page(live.id).body, body)
        except WikiError:
            pass
        raise WikiGuardError("update refused: page changed during publish (HTTP 409 conflict)",
                             live.version, diff) from exc
    return PublishResult(page.id, page.url, page.version, created=False)


# ---------------------------------------------------------------- publish


LABEL_PREFIX = "kb-wiki-"
_DOC_TYPES = ("cr", "testing-log", "cr-record")
_KEY_PART = re.compile(r"(REL|CR)-[A-Za-z0-9][A-Za-z0-9._-]*(?![\s\S])")


def identity_label(doc: str, key: str) -> str:
    """Provider-generic identity of the one page for (doc, key):
    `kb-wiki-<doc>-<key lowercased>`, e.g. `kb-wiki-testing-log-rel-5`.
    Lowercase, no spaces, only [a-z0-9._-] (UNCONFIRMED against live
    Confluence: dots in labels). Anything else is a WikiUsageError."""
    if doc not in _DOC_TYPES:
        raise WikiUsageError(f"unknown doc type {doc!r}")
    if not isinstance(key, str) or not _KEY_PART.match(key):
        raise WikiUsageError(f"invalid key {key!r} (expected REL-... or CR-...)")
    return f"{LABEL_PREFIX}{doc}-{key.lower()}"


def _owner_of(label: str) -> str:
    """Human name for another page's kb-wiki label: 'key cr-2 (doc cr)'."""
    rest = label[len(LABEL_PREFIX):]
    for doc in sorted(_DOC_TYPES, key=len, reverse=True):
        if rest.startswith(doc + "-"):
            return f"key {rest[len(doc) + 1:]} (doc {doc})"
    return f"label {label}"


def _kbwiki_labels(page: WikiPage) -> List[str]:
    return [l for l in page.labels if l.startswith(LABEL_PREFIX)]


def check_location(live: WikiPage, space: str, parent_id) -> None:
    """Refuse (WikiLocationError, before ANY write) unless `live` sits under the
    doc type's configured parent, is not that parent itself, and (when the
    provider exposes it) is in the configured space."""
    parent_id = str(parent_id)
    if live.id == parent_id:
        raise WikiLocationError(f"page {live.id} IS the configured parent; refusing to overwrite it")
    if live.space and live.space != space:
        raise WikiLocationError(
            f"page {live.id} is in space {live.space!r}, not the configured {space!r}")
    if not any(a.id == parent_id for a in live.ancestors):
        raise WikiLocationError(
            f"page {live.id} is not under the configured parent {parent_id}; "
            "it belongs to a different doc type, tree or space")


def check_identity(live: WikiPage, label: str, adopt: bool = False) -> bool:
    """The live page must carry THIS (doc, key) label. Returns True when the
    label still has to be applied (an unlabelled page with adopt=True). A page
    labelled for any other identity is refused even with adopt."""
    others = [l for l in _kbwiki_labels(live) if l != label]
    if others:
        raise WikiIdentityError(
            f"page {live.id} belongs to {_owner_of(others[0])}, not this record; refusing")
    if label in live.labels:
        return False
    if adopt:
        return True
    raise WikiIdentityError(
        f"page {live.id} carries no {label!r} label (legacy or hand-made page); refusing. "
        "Only if you are certain it is this record's page, re-run with --adopt "
        "(this OVERWRITES its title and body)")


def publish(provider: WikiProvider, space: str, parent_type: str, parent_id,
            title: str, body: str, page_id: Optional[str] = None,
            stored_version: Optional[int] = None,
            expect_version: Optional[int] = None, *,
            label: str, adopt: bool = False) -> PublishResult:
    """Create the one page for a (doc, key), or update the stored one.

    `label` is the (doc, key) identity (see identity_label). Update path
    (page_id given): the page MUST exist (WikiNotFoundError, NEVER a create),
    sit under the configured parent/space, and carry `label`; `adopt=True`
    labels an unlabelled page after those checks (never another key's page).
    Create path: parent must exist with the configured type; no page in the
    space may already carry `label` or the title; the new page is labelled and
    must read back under the parent WITH the label."""
    if not isinstance(title, str) or not title.strip():
        raise WikiUsageError("title must not be empty")
    if parent_type not in ("page", "folder"):
        raise WikiUsageError(f"unsupported parent type: {parent_type!r}")
    if not isinstance(label, str) or not label.startswith(LABEL_PREFIX):
        raise WikiUsageError("label must be an identity_label()")
    parent_id = str(parent_id)
    if page_id is not None:
        live = provider.get_page(page_id)  # missing -> WikiNotFoundError, no create
        check_location(live, space, parent_id)
        needs_label = check_identity(live, label, adopt)
        return _guarded_update(provider, live, title, body, stored_version, expect_version,
                               label if needs_label else None)

    if adopt:
        raise WikiUsageError("--adopt only applies with --page-id")
    if stored_version is not None or expect_version is not None:
        raise WikiUsageError("--stored-version/--expect-version only apply with --page-id")
    try:
        parent = (provider.get_folder(parent_id) if parent_type == "folder"
                  else provider.get_page(parent_id))
    except WikiNotFoundError as exc:
        raise WikiLocationError(f"configured parent {parent_type} {parent_id} does not exist") from exc
    if parent.kind != parent_type:
        raise WikiLocationError(
            f"configured parent {parent_id} is a {parent.kind}, expected {parent_type}")
    # Identity first: the (doc, key) label, searched space-wide. A hit means the
    # page already exists (title changed, record lost): never mint a second one.
    labelled = provider.find_by_label(space, label)
    if len(labelled) == 1:
        raise WikiDuplicateError(
            f"the page for this record already exists (pageId {labelled[0].id}, label {label!r}); "
            f"update it with --page-id {labelled[0].id} and its stored version instead of "
            "creating a second page", labelled[0].id)
    if labelled:
        ids = ", ".join(p.id for p in labelled)
        raise WikiDuplicateError(
            f"{len(labelled)} pages already carry label {label!r} (pageIds {ids}); "
            "resolve the duplicates by hand, nothing was created")
    # Then the title (space-wide: a same-titled page anywhere would make the
    # create fail or duplicate).
    existing = provider.find_by_title(space, title)
    if existing:
        raise _title_refusal(existing, title, label, parent_id)
    try:
        created = provider.create_page(space, title, body, parent_type, parent_id)
    except WikiConflictError as exc:  # a 409 on POST is a name clash, not a version guard
        raise WikiDuplicateError(
            f"create refused (HTTP 409): a page titled {title!r} probably exists; nothing was created") from exc
    _apply_label(provider, created.id, label)  # fail closed, verified on read-back
    back = provider.get_page(created.id)
    if not any(a.id == parent_id for a in back.ancestors):
        raise WikiLocationError(
            f"page {created.id} was created but does not sit under parent {parent_id}; "
            "not recording it (fix or remove it manually)")
    return PublishResult(back.id, back.url, back.version, created=True)


def _title_refusal(existing: List[WikiPage], title: str, label: str, parent_id: str) -> WikiError:
    """Refusal for a same-titled page. Only suggests --page-id when that page is
    this record's own or carries no kb-wiki label; another key's page is named
    as owned and never offered for adoption."""
    for p in existing:
        others = [l for l in _kbwiki_labels(p) if l != label]
        if others:
            return WikiDuplicateError(
                f"a page titled {title!r} already exists (pageId {p.id}) and belongs to "
                f"{_owner_of(others[0])}; refusing. Choose a different title")
    first = existing[0]
    if label in first.labels:
        return WikiDuplicateError(
            f"the page for this record already exists (pageId {first.id}); update it with "
            f"--page-id {first.id} and its stored version", first.id)
    return WikiDuplicateError(
        f"a page titled {title!r} already exists (pageId {first.id}) with no kb-wiki label "
        f"(legacy or hand-made). If you are certain it is this record's page, adopt it with "
        f"--page-id {first.id} --adopt and its version (this OVERWRITES its title and body)",
        first.id)


# ---------------------------------------------------------------- patch-section

_VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
_RAW = frozenset(("pre", "ac:plain-text-body", "ac:plain-text-link-body"))
_TAG_RE = re.compile(r"""<(/?)([A-Za-z][A-Za-z0-9:_.\-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(/?)>""")
_HEADING_NAME = re.compile(r"h([1-6])(?![\s\S])")


def _tokens(body: str) -> list:
    """Split storage-format markup into (kind, start, end, name) tokens.
    kinds: text, cdata (start/end = inner content), open, close, selfclose,
    skip (comment / processing instruction / declaration). Unterminated
    comments/CDATA raise WikiPatchError (fail closed)."""
    out, i, n = [], 0, len(body)
    text_start = 0

    def flush(upto):
        if upto > text_start:
            out.append(("text", text_start, upto, ""))

    while i < n:
        if body[i] != "<":
            i += 1
            continue
        if body.startswith("<!--", i):
            j = body.find("-->", i + 4)
            if j < 0:
                raise WikiPatchError("unterminated comment in page body")
            flush(i)
            out.append(("skip", i, j + 3, ""))
            i = text_start = j + 3
        elif body.startswith("<![CDATA[", i):
            j = body.find("]]>", i + 9)
            if j < 0:
                raise WikiPatchError("unterminated CDATA section in page body")
            flush(i)
            out.append(("cdata", i + 9, j, ""))
            i = text_start = j + 3
        elif body.startswith("<?", i) or body.startswith("<!", i):
            j = body.find("?>" if body.startswith("<?", i) else ">", i + 2)
            if j < 0:
                raise WikiPatchError("unterminated declaration in page body")
            end = j + (2 if body.startswith("<?", i) else 1)
            flush(i)
            out.append(("skip", i, end, ""))
            i = text_start = end
        else:
            m = _TAG_RE.match(body, i)
            if not m:
                i += 1  # a stray '<' is just text
                continue
            flush(i)
            kind = "close" if m.group(1) else ("selfclose" if m.group(4) else "open")
            out.append((kind, i, m.end(), m.group(2).lower()))
            i = text_start = m.end()
    flush(n)
    return out


def _norm(text: str) -> str:
    return " ".join(text.split())


def _headings(body: str, tokens: list) -> list:
    """[(level, open_start, close_end, text, close_token_index)] for real headings only: never
    inside a raw/code region, CDATA or comment (those are not tag tokens)."""
    found, raw, k = [], 0, 0
    while k < len(tokens):
        kind, start, end, name = tokens[k]
        if kind == "open" and name in _RAW:
            raw += 1
        elif kind == "close" and name in _RAW:
            raw = max(0, raw - 1)
        elif kind == "open" and raw == 0 and _HEADING_NAME.match(name):
            parts, j = [], k + 1
            while j < len(tokens) and not (tokens[j][0] == "close" and tokens[j][3] == name):
                t = tokens[j]
                if t[0] == "open" and _HEADING_NAME.match(t[3]):
                    raise WikiPatchError("malformed page body: unclosed heading")
                if t[0] == "text":
                    parts.append(html.unescape(body[t[1]:t[2]]))
                elif t[0] == "cdata":
                    parts.append(body[t[1]:t[2]])
                j += 1
            if j >= len(tokens):
                raise WikiPatchError("malformed page body: unclosed heading")
            found.append((int(name[1]), start, tokens[j][2], _norm("".join(parts)), j))
            k = j
        k += 1
    return found


def _require_balanced(fragment: str, what: str) -> None:
    stack = []
    for kind, _s, _e, name in _tokens(fragment):
        if kind == "open" and name not in _VOID:
            stack.append(name)
        elif kind == "close":
            if not stack or stack.pop() != name:
                raise WikiPatchError(f"{what} is not well-nested markup; refusing to splice it")
    if stack:
        raise WikiPatchError(f"{what} is not well-nested markup; refusing to splice it")


def replace_section(body: str, heading: str, new_content: str) -> str:
    """Return `body` with only the content under `heading` replaced: from the
    end of the heading element to the next heading of the same or higher level,
    the close of the element enclosing the heading (layout cell, macro body...),
    or end of body, whichever comes first. Every other character is untouched.
    WikiPatchError if the heading is absent, ambiguous, the replacement would
    contain a heading of the same or higher level, or the splice would break
    the markup."""
    want = _norm(heading)
    if not want:
        raise WikiUsageError("heading must not be empty")
    tokens = _tokens(body)
    heads = _headings(body, tokens)
    hits = [i for i, h in enumerate(heads) if h[3] == want]
    if not hits:
        raise WikiPatchError(f"heading not found: {want!r}")
    if len(hits) > 1:
        raise WikiPatchError(f"heading is ambiguous ({len(hits)} matches): {want!r}")
    level, _open, start, _text, close_idx = heads[hits[0]]
    end = next((h[1] for h in heads[hits[0] + 1:] if h[0] <= level), len(body))
    depth = 0
    for kind, tstart, _tend, name in tokens[close_idx + 1:]:
        if tstart >= end:
            break
        if kind == "open" and name not in _VOID:
            depth += 1
        elif kind == "close":
            if depth == 0:  # closes the element enclosing the heading
                end = tstart
                break
            depth -= 1
    for h in _headings(new_content, _tokens(new_content)):
        if h[0] <= level:
            raise WikiPatchError(
                f"replacement content contains an h{h[0]} heading, which would duplicate or "
                f"split the h{level} section {want!r}; only deeper headings are allowed")
    _require_balanced(body[start:end], "existing section")
    _require_balanced(new_content, "replacement content")
    return body[:start] + new_content + body[end:]


def patch_section(provider: WikiProvider, page_id: str, heading: str, new_content: str,
                  stored_version: Optional[int] = None,
                  expect_version: Optional[int] = None, *,
                  space: str, parent_id, label: str) -> PublishResult:
    """Replace one section of an existing page under the same guards as an
    update-publish: location (under the doc's parent/space, not the parent),
    identity (carries this (doc, key) label; no adopt here), version. A missing
    page raises WikiNotFoundError; nothing is ever created."""
    _check_version_arg("stored_version", stored_version)
    _check_version_arg("expect_version", expect_version)
    if stored_version is None and expect_version is None:
        raise WikiUsageError("patch-section needs --stored-version or --expect-version")
    live = provider.get_page(page_id)
    check_location(live, space, parent_id)
    check_identity(live, label, adopt=False)
    patched = replace_section(live.body, heading, new_content)
    return _guarded_update(provider, live, live.title, patched, stored_version, expect_version)
