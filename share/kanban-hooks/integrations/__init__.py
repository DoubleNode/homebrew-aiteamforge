"""
Integration providers for external services.
Includes secure credential storage and API integrations.
"""

from .credential_store import CredentialStore, get_credential_store

# jira_provider depends on lcars-ui being on sys.path; guard so that
# importing credential_store alone (e.g. in unit tests) still works.
try:
    from .jira_provider import JiraProvider, get_jira_provider
    _jira_available = True
except ImportError:
    _jira_available = False

__all__ = [
    'CredentialStore',
    'get_credential_store',
]
if _jira_available:
    __all__ += ['JiraProvider', 'get_jira_provider']
