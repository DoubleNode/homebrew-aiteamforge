"""
LCARS Integration Providers

Multi-platform ticket tracking integration system.
Supports JIRA, Monday.com, GitHub Issues, Linear, and custom integrations.
Includes bidirectional sync service for status synchronization.
"""

from .provider import (
    IntegrationProvider,
    IntegrationConfig,
    TicketInfo,
    SearchResult,
    VerifyResult,
    ConnectionTestResult,
    CreateItemResult,
    ImportedIssue,
    FetchResult
)
from .manager import IntegrationManager, get_manager
from .ticket_links import (
    TicketLink,
    get_ticket_links,
    add_ticket_link,
    remove_ticket_link,
    clear_ticket_links,
    get_primary_ticket_link,
    has_ticket_link,
    migrate_jira_id_to_ticket_links,
    get_ticket_links_summary
)
from .sync_service import (
    SyncService,
    SyncDirection,
    SyncStatus,
    SyncResult,
    ItemSyncResult,
    get_sync_service,
    reset_sync_service
)

# Import providers to trigger registration
from . import jira_provider
from . import monday_provider
from . import github_provider

__all__ = [
    # Core types
    'IntegrationProvider',
    'IntegrationConfig',
    'IntegrationManager',
    'get_manager',
    'TicketInfo',
    'SearchResult',
    'VerifyResult',
    'ConnectionTestResult',
    'CreateItemResult',
    'ImportedIssue',
    'FetchResult',
    # Ticket links
    'TicketLink',
    'get_ticket_links',
    'add_ticket_link',
    'remove_ticket_link',
    'clear_ticket_links',
    'get_primary_ticket_link',
    'has_ticket_link',
    'migrate_jira_id_to_ticket_links',
    'get_ticket_links_summary',
    # Sync service
    'SyncService',
    'SyncDirection',
    'SyncStatus',
    'SyncResult',
    'ItemSyncResult',
    'get_sync_service',
    'reset_sync_service'
]
