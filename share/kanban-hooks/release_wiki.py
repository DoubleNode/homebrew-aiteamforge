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
    def list_children(self, parent_type: str, parent_id: str) -> List[WikiPage]:
        """Direct children of a page or folder."""

    @abc.abstractmethod
    def get_folder(self, folder_id: str) -> WikiPage:
        """Read a folder (kind == "folder"). WikiNotFoundError if absent."""

    @abc.abstractmethod
    def page_url(self, page_id: str) -> str:
        """Stable browse URL for a page id; no network."""


# ---- seam: publish / version guard / patch-section / doctor (PR 2) land here.
