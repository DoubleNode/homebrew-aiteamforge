"""
Bidirectional Sync Service - Synchronizes kanban items with external tickets.

This service provides automatic synchronization between kanban items and
their linked external tickets (JIRA, Monday.com, etc.) using the
IntegrationProvider interface.

Features:
- Iterate ticketLinks array to sync all linked tickets
- Per-link syncEnabled toggle
- Integration ID in all sync logging
- Multi-provider support via IntegrationProvider interface
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any, Callable
from enum import Enum

from .provider import IntegrationProvider, VerifyResult
from .manager import IntegrationManager, get_manager
from .ticket_links import TicketLink, get_ticket_links, add_ticket_link

# Configure logging with integration ID support
logger = logging.getLogger(__name__)


class SyncDirection(Enum):
    """Direction of synchronization."""
    EXTERNAL_TO_KANBAN = "external_to_kanban"  # External ticket -> Kanban item
    KANBAN_TO_EXTERNAL = "kanban_to_external"  # Kanban item -> External ticket
    BIDIRECTIONAL = "bidirectional"  # Both directions


class SyncStatus(Enum):
    """Result status of a sync operation."""
    SUCCESS = "success"
    SKIPPED = "skipped"  # Sync disabled for this link
    NO_CREDENTIALS = "no_credentials"
    NOT_FOUND = "not_found"
    ERROR = "error"
    NO_CHANGES = "no_changes"


@dataclass
class SyncResult:
    """Result of syncing a single ticket link."""
    integration_id: str
    ticket_id: str
    status: SyncStatus
    message: str
    changes: Dict[str, Any] = field(default_factory=dict)
    error: Optional[str] = None
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class ItemSyncResult:
    """Result of syncing all ticket links for a kanban item."""
    item_id: str
    link_results: List[SyncResult] = field(default_factory=list)
    updated_item: Optional[Dict[str, Any]] = None

    @property
    def success_count(self) -> int:
        return sum(1 for r in self.link_results if r.status == SyncStatus.SUCCESS)

    @property
    def error_count(self) -> int:
        return sum(1 for r in self.link_results if r.status == SyncStatus.ERROR)

    @property
    def skipped_count(self) -> int:
        return sum(1 for r in self.link_results if r.status == SyncStatus.SKIPPED)


@dataclass
class TicketLinkConfig:
    """Extended TicketLink with sync configuration."""
    integration_id: str
    ticket_id: str
    sync_enabled: bool = True
    sync_direction: SyncDirection = SyncDirection.EXTERNAL_TO_KANBAN
    last_synced: Optional[str] = None
    sync_error: Optional[str] = None

    @classmethod
    def from_ticket_link(cls, link: TicketLink, link_data: Dict[str, Any]) -> 'TicketLinkConfig':
        """Create from TicketLink with additional sync config from raw data."""
        return cls(
            integration_id=link.integrationId,
            ticket_id=link.ticketId,
            sync_enabled=link_data.get('syncEnabled', True),
            sync_direction=SyncDirection(link_data.get('syncDirection', 'external_to_kanban')),
            last_synced=link_data.get('lastSynced'),
            sync_error=link_data.get('syncError')
        )


class SyncService:
    """
    Bidirectional synchronization service for kanban-ticket integration.

    Uses IntegrationProvider interface to support multiple ticket systems.
    Iterates through ticketLinks array and syncs each link individually.
    """

    def __init__(self, manager: Optional[IntegrationManager] = None):
        """
        Initialize the sync service.

        Args:
            manager: IntegrationManager instance. Uses global manager if None.
        """
        self.manager = manager or get_manager()
        self._status_mapping: Dict[str, Dict[str, str]] = {}  # integration_id -> {ext_status: kanban_status}

    def configure_status_mapping(
        self,
        integration_id: str,
        mapping: Dict[str, str]
    ) -> None:
        """
        Configure status mapping for an integration.

        Maps external ticket statuses to kanban statuses.

        Args:
            integration_id: The integration to configure
            mapping: Dict mapping external status -> kanban status

        Example:
            sync.configure_status_mapping('jira-mainevent', {
                'To Do': 'backlog',
                'In Progress': 'in_progress',
                'Done': 'completed'
            })
        """
        self._status_mapping[integration_id] = mapping
        logger.info(
            f"[{integration_id}] Configured status mapping with {len(mapping)} entries"
        )

    def _get_kanban_status(
        self,
        integration_id: str,
        external_status: str
    ) -> Optional[str]:
        """Map external status to kanban status."""
        mapping = self._status_mapping.get(integration_id, {})
        return mapping.get(external_status)

    def _log_sync(
        self,
        integration_id: str,
        ticket_id: str,
        message: str,
        level: str = 'info'
    ) -> None:
        """Log with integration ID prefix for traceability."""
        log_message = f"[{integration_id}] [{ticket_id}] {message}"
        getattr(logger, level)(log_message)

    def sync_ticket_link(
        self,
        item: Dict[str, Any],
        link_data: Dict[str, Any],
        direction: SyncDirection = SyncDirection.EXTERNAL_TO_KANBAN
    ) -> SyncResult:
        """
        Sync a single ticket link.

        Args:
            item: Kanban item dictionary
            link_data: Raw ticketLink dictionary from the item
            direction: Sync direction

        Returns:
            SyncResult with operation outcome
        """
        integration_id = link_data.get('integrationId', 'unknown')
        ticket_id = link_data.get('ticketId', 'unknown')

        # Check if sync is enabled for this link
        if not link_data.get('syncEnabled', True):
            self._log_sync(integration_id, ticket_id, "Sync disabled, skipping")
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.SKIPPED,
                message="Sync disabled for this link"
            )

        # Get the provider
        provider = self.manager.get_provider(integration_id)
        if not provider:
            self._log_sync(integration_id, ticket_id, "Provider not found", 'warning')
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.ERROR,
                message=f"Integration provider '{integration_id}' not found",
                error="provider_not_found"
            )

        if not provider.has_credentials():
            self._log_sync(integration_id, ticket_id, "No credentials configured", 'warning')
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.NO_CREDENTIALS,
                message=f"Credentials not configured for {provider.name}"
            )

        # Verify/fetch ticket from external system
        self._log_sync(integration_id, ticket_id, "Fetching ticket status...")
        verify_result = provider.verify(ticket_id)

        if not verify_result.valid or not verify_result.exists:
            self._log_sync(integration_id, ticket_id, f"Ticket not found: {verify_result.error}", 'warning')
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.NOT_FOUND,
                message=verify_result.error or "Ticket not found",
                error=verify_result.error
            )

        # Track changes
        changes = {}

        # Sync from external -> kanban
        if direction in (SyncDirection.EXTERNAL_TO_KANBAN, SyncDirection.BIDIRECTIONAL):
            changes.update(self._sync_external_to_kanban(
                item, link_data, verify_result, provider
            ))

        # TODO: Sync from kanban -> external (requires provider.update_ticket method)
        # if direction in (SyncDirection.KANBAN_TO_EXTERNAL, SyncDirection.BIDIRECTIONAL):
        #     changes.update(self._sync_kanban_to_external(item, link_data, provider))

        if changes:
            self._log_sync(integration_id, ticket_id, f"Synced: {changes}")
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.SUCCESS,
                message="Sync completed",
                changes=changes
            )
        else:
            self._log_sync(integration_id, ticket_id, "No changes needed")
            return SyncResult(
                integration_id=integration_id,
                ticket_id=ticket_id,
                status=SyncStatus.NO_CHANGES,
                message="No changes needed"
            )

    def _sync_external_to_kanban(
        self,
        item: Dict[str, Any],
        link_data: Dict[str, Any],
        verify_result: VerifyResult,
        provider: IntegrationProvider
    ) -> Dict[str, Any]:
        """
        Sync data from external ticket to kanban item.

        Updates the ticketLink with latest external data.
        """
        integration_id = link_data.get('integrationId', '')
        changes = {}

        # Update cached ticket data in the link
        if verify_result.summary and link_data.get('summary') != verify_result.summary:
            link_data['summary'] = verify_result.summary
            changes['summary'] = verify_result.summary

        if verify_result.status and link_data.get('status') != verify_result.status:
            link_data['status'] = verify_result.status
            changes['external_status'] = verify_result.status

            # Map to kanban status if configured
            kanban_status = self._get_kanban_status(integration_id, verify_result.status)
            if kanban_status:
                changes['mapped_kanban_status'] = kanban_status

        if verify_result.ticket_type and link_data.get('ticketType') != verify_result.ticket_type:
            link_data['ticketType'] = verify_result.ticket_type
            changes['ticketType'] = verify_result.ticket_type

        if verify_result.url and link_data.get('ticketUrl') != verify_result.url:
            link_data['ticketUrl'] = verify_result.url
            changes['ticketUrl'] = verify_result.url

        # Update sync metadata
        link_data['lastSynced'] = datetime.now(timezone.utc).isoformat()
        link_data.pop('syncError', None)  # Clear any previous error

        return changes

    def sync_item(
        self,
        item: Dict[str, Any],
        direction: SyncDirection = SyncDirection.EXTERNAL_TO_KANBAN
    ) -> ItemSyncResult:
        """
        Sync all ticket links for a kanban item.

        Iterates through the ticketLinks array and syncs each link.

        Args:
            item: Kanban item dictionary
            direction: Sync direction

        Returns:
            ItemSyncResult with all link sync results
        """
        item_id = item.get('id', item.get('itemId', 'unknown'))
        logger.info(f"[SYNC] Starting sync for item {item_id}")

        result = ItemSyncResult(item_id=item_id)

        # Get ticket links (handles both new array and legacy jiraId)
        ticket_links_data = item.get('ticketLinks', [])

        # Also check for legacy jiraId if no ticketLinks
        if not ticket_links_data:
            jira_id = item.get('jiraId') or item.get('jiraKey')
            if jira_id:
                # Create synthetic link data for legacy format
                ticket_links_data = [{
                    'integrationId': 'jira-mainevent',
                    'ticketId': jira_id,
                    'syncEnabled': True
                }]
                logger.info(f"[SYNC] [{item_id}] Using legacy jiraId: {jira_id}")

        if not ticket_links_data:
            logger.info(f"[SYNC] [{item_id}] No ticket links to sync")
            return result

        # Sync each link
        for link_data in ticket_links_data:
            try:
                link_result = self.sync_ticket_link(item, link_data, direction)
                result.link_results.append(link_result)
            except Exception as e:
                integration_id = link_data.get('integrationId', 'unknown')
                ticket_id = link_data.get('ticketId', 'unknown')
                logger.error(f"[{integration_id}] [{ticket_id}] Sync failed: {e}")
                result.link_results.append(SyncResult(
                    integration_id=integration_id,
                    ticket_id=ticket_id,
                    status=SyncStatus.ERROR,
                    message=str(e),
                    error=str(e)
                ))
                # Mark error on the link
                link_data['syncError'] = str(e)
                link_data['lastSynced'] = datetime.now(timezone.utc).isoformat()

        result.updated_item = item
        logger.info(
            f"[SYNC] [{item_id}] Complete: {result.success_count} success, "
            f"{result.error_count} errors, {result.skipped_count} skipped"
        )
        return result

    def sync_board(
        self,
        board_data: Dict[str, Any],
        direction: SyncDirection = SyncDirection.EXTERNAL_TO_KANBAN
    ) -> Dict[str, ItemSyncResult]:
        """
        Sync all items on a kanban board.

        Args:
            board_data: Full board JSON data
            direction: Sync direction

        Returns:
            Dict mapping item IDs to their sync results
        """
        results = {}

        # Collect all items from all columns
        columns = board_data.get('columns', [])
        for column in columns:
            items = column.get('items', [])
            for item in items:
                item_id = item.get('id', item.get('itemId'))
                if item_id:
                    results[item_id] = self.sync_item(item, direction)

        # Also check backlog if present
        backlog = board_data.get('backlog', {})
        backlog_items = backlog.get('items', [])
        for item in backlog_items:
            item_id = item.get('id', item.get('itemId'))
            if item_id:
                results[item_id] = self.sync_item(item, direction)

        logger.info(f"[SYNC] Board sync complete: {len(results)} items processed")
        return results


# Singleton instance
_sync_service: Optional[SyncService] = None


def get_sync_service() -> SyncService:
    """Get the global SyncService instance."""
    global _sync_service
    if _sync_service is None:
        _sync_service = SyncService()
    return _sync_service


def reset_sync_service() -> None:
    """Reset the singleton (for testing)."""
    global _sync_service
    _sync_service = None
