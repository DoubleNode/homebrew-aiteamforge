"""
Secure credential storage for the kanban hooks.

Named `kanban_credentials` (not `integrations`) so it can never shadow
lcars-ui's `integrations` package when both dirs are on sys.path (XACA-1429).
"""

from .credential_store import CredentialStore, get_credential_store

__all__ = [
    'CredentialStore',
    'get_credential_store',
]
