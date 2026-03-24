"""
ticketLinks Data Model Helpers

Provides utility functions for managing the ticketLinks array on kanban items.
Replaces the single jiraId field with a flexible array of ticket links.
"""

from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any


@dataclass
class TicketLink:
    """A link between a kanban item and an external ticket."""
    integrationId: str
    ticketId: str
    ticketUrl: Optional[str] = None
    summary: Optional[str] = None
    status: Optional[str] = None
    ticketType: Optional[str] = None
    linkedAt: Optional[str] = None
    linkedBy: Optional[str] = None

    def __post_init__(self):
        if not self.linkedAt:
            self.linkedAt = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'TicketLink':
        """Create TicketLink from dictionary."""
        return cls(
            integrationId=data.get('integrationId', ''),
            ticketId=data.get('ticketId', ''),
            ticketUrl=data.get('ticketUrl'),
            summary=data.get('summary'),
            status=data.get('status'),
            ticketType=data.get('ticketType') or data.get('type'),
            linkedAt=data.get('linkedAt'),
            linkedBy=data.get('linkedBy')
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary, excluding None values."""
        result = asdict(self)
        return {k: v for k, v in result.items() if v is not None}


def get_ticket_links(item: Dict[str, Any]) -> List[TicketLink]:
    """
    Get all ticket links from a kanban item.

    Handles both new ticketLinks array and legacy jiraId field.

    Args:
        item: Kanban item dictionary

    Returns:
        List of TicketLink objects
    """
    links = []

    # Check for new ticketLinks array
    if 'ticketLinks' in item and isinstance(item['ticketLinks'], list):
        for link_data in item['ticketLinks']:
            links.append(TicketLink.from_dict(link_data))

    # Check for legacy jiraId (backward compatibility)
    elif 'jiraId' in item or 'jiraKey' in item or 'jira' in item:
        jira_id = item.get('jiraId') or item.get('jiraKey') or item.get('jira')
        if jira_id:
            links.append(TicketLink(
                integrationId='jira-mainevent',  # Default JIRA integration
                ticketId=jira_id,
                ticketUrl=f"https://mainevent.atlassian.net/browse/{jira_id}"
            ))

    return links


def add_ticket_link(item: Dict[str, Any], link: TicketLink) -> Dict[str, Any]:
    """
    Add a ticket link to a kanban item.

    Initializes ticketLinks array if needed. Prevents duplicates.

    Args:
        item: Kanban item dictionary
        link: TicketLink to add

    Returns:
        Updated item dictionary
    """
    if 'ticketLinks' not in item:
        item['ticketLinks'] = []

    # Check for duplicate (same integration + ticketId)
    for existing in item['ticketLinks']:
        if (existing.get('integrationId') == link.integrationId and
            existing.get('ticketId') == link.ticketId):
            # Update existing link instead of adding duplicate
            existing.update(link.to_dict())
            return item

    # Add new link
    item['ticketLinks'].append(link.to_dict())
    return item


def remove_ticket_link(
    item: Dict[str, Any],
    integration_id: str,
    ticket_id: str
) -> Dict[str, Any]:
    """
    Remove a specific ticket link from a kanban item.

    Args:
        item: Kanban item dictionary
        integration_id: Integration ID to match
        ticket_id: Ticket ID to match

    Returns:
        Updated item dictionary
    """
    if 'ticketLinks' not in item:
        return item

    item['ticketLinks'] = [
        link for link in item['ticketLinks']
        if not (link.get('integrationId') == integration_id and
                link.get('ticketId') == ticket_id)
    ]

    return item


def clear_ticket_links(item: Dict[str, Any]) -> Dict[str, Any]:
    """
    Remove all ticket links from a kanban item.

    Args:
        item: Kanban item dictionary

    Returns:
        Updated item dictionary with empty ticketLinks
    """
    item['ticketLinks'] = []
    return item


def get_primary_ticket_link(item: Dict[str, Any]) -> Optional[TicketLink]:
    """
    Get the primary (first) ticket link from an item.

    Useful for backward compatibility when only one link is expected.

    Args:
        item: Kanban item dictionary

    Returns:
        First TicketLink or None
    """
    links = get_ticket_links(item)
    return links[0] if links else None


def has_ticket_link(
    item: Dict[str, Any],
    integration_id: Optional[str] = None,
    ticket_id: Optional[str] = None
) -> bool:
    """
    Check if an item has any ticket links, optionally filtering.

    Args:
        item: Kanban item dictionary
        integration_id: Optional integration ID to filter by
        ticket_id: Optional ticket ID to filter by

    Returns:
        True if matching link(s) exist
    """
    links = get_ticket_links(item)

    if not links:
        return False

    if integration_id is None and ticket_id is None:
        return True

    for link in links:
        if integration_id and link.integrationId != integration_id:
            continue
        if ticket_id and link.ticketId != ticket_id:
            continue
        return True

    return False


def migrate_jira_id_to_ticket_links(
    item: Dict[str, Any],
    default_integration_id: str = 'jira-mainevent',
    preserve_legacy: bool = True
) -> Dict[str, Any]:
    """
    Migrate legacy jiraId field to new ticketLinks array.

    Args:
        item: Kanban item dictionary
        default_integration_id: Integration ID to use for migrated links
        preserve_legacy: If True, keep original jiraId field

    Returns:
        Updated item dictionary
    """
    jira_id = item.get('jiraId') or item.get('jiraKey') or item.get('jira')

    if not jira_id:
        return item

    # Initialize ticketLinks if needed
    if 'ticketLinks' not in item:
        item['ticketLinks'] = []

    # Check if already migrated
    for link in item['ticketLinks']:
        if (link.get('integrationId') == default_integration_id and
            link.get('ticketId') == jira_id):
            # Already migrated
            return item

    # Create link from legacy field
    link = TicketLink(
        integrationId=default_integration_id,
        ticketId=jira_id,
        ticketUrl=f"https://mainevent.atlassian.net/browse/{jira_id}"
    )

    item['ticketLinks'].append(link.to_dict())

    # Optionally remove legacy fields
    if not preserve_legacy:
        item.pop('jiraId', None)
        item.pop('jiraKey', None)
        item.pop('jira', None)

    return item


def get_ticket_links_summary(item: Dict[str, Any]) -> str:
    """
    Get a summary string of all ticket links.

    Useful for display purposes.

    Args:
        item: Kanban item dictionary

    Returns:
        Comma-separated list of ticket IDs
    """
    links = get_ticket_links(item)
    if not links:
        return ""

    return ", ".join(link.ticketId for link in links)
