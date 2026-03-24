"""
IntegrationManager - Manages all configured integration providers.

Handles loading configuration, instantiating providers, and providing
a unified interface for the server to interact with integrations.
"""

import json
import os
from pathlib import Path
from typing import Dict, List, Optional, Type, Any
from .provider import (
    IntegrationProvider,
    IntegrationConfig,
    SearchResult,
    VerifyResult,
    ConnectionTestResult,
    FetchResult,
    ImportedIssue
)


# Team kanban directory mapping (mirrors server.py TEAM_KANBAN_DIRS and kanban-helpers.sh)
# Used to locate team-specific config files in kanban/config/
_TEAM_KANBAN_DIRS = {
    "academy": Path.home() / "aiteamforge" / "kanban",
    "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command": Path("/Users/Shared/Development/Main Event/aiteamforge/kanban"),
    "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
    "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",
    "medical-general": Path.home() / "medical" / "general" / "kanban",
    "finance-personal": Path.home() / "finance" / "personal" / "kanban",
}


class IntegrationManager:
    """
    Manages integration providers and configuration.

    Loads integration config from JSON file or environment,
    instantiates appropriate provider classes, and provides
    a unified interface for searching/verifying across providers.
    """

    # Registry of provider types to their implementation classes
    _provider_registry: Dict[str, Type[IntegrationProvider]] = {}

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the manager.

        Args:
            config_path: Path to integrations.json config file.
                        If None, looks in default locations.
        """
        self._providers: Dict[str, IntegrationProvider] = {}
        self._config_path = config_path
        self._config_data: Dict[str, Any] = {}
        self._loaded = False

    @classmethod
    def register_provider(cls, provider_type: str, provider_class: Type[IntegrationProvider]):
        """
        Register a provider implementation class.

        Args:
            provider_type: Type identifier (e.g., 'jira', 'github')
            provider_class: The provider class to instantiate
        """
        cls._provider_registry[provider_type] = provider_class

    @classmethod
    def get_registered_types(cls) -> List[str]:
        """Get list of registered provider types."""
        return list(cls._provider_registry.keys())

    def _find_config_file(self) -> Optional[Path]:
        """Find the integrations config file in standard locations."""
        # Get team from environment for team-specific config
        lcars_team = os.environ.get("LCARS_TEAM", "freelance")

        # Resolve team kanban directory (fallback to academy)
        kanban_dir = _TEAM_KANBAN_DIRS.get(lcars_team, Path.home() / "aiteamforge" / "kanban")

        search_paths = [
            # Explicit path
            Path(self._config_path) if self._config_path else None,
            # Team kanban config directory (PREFERRED - distributed with board data)
            kanban_dir / 'config' / 'integrations.json',
            # Legacy: Centralized config directory (fallback during migration)
            Path.home() / 'aiteamforge' / 'config' / lcars_team / 'integrations.json',
            # Legacy: Local to lcars-ui
            Path(__file__).parent.parent / 'config' / 'integrations.json',
            # Legacy: Dev team config root
            Path.home() / 'aiteamforge' / 'config' / 'integrations.json',
        ]

        for path in search_paths:
            if path and path.exists():
                return path

        return None

    def ensure_loaded(self) -> bool:
        """
        Ensure integration configuration is loaded (lazy load).

        This method only loads once. If config is already loaded, it returns
        immediately without re-reading the file. Use reload() to force a
        fresh read from disk.

        Returns:
            True if loaded successfully, False otherwise
        """
        if self._loaded:
            return True

        config_file = self._find_config_file()

        if config_file:
            try:
                with open(config_file, 'r') as f:
                    self._config_data = json.load(f)
            except (json.JSONDecodeError, IOError) as e:
                print(f"[IntegrationManager] Failed to load config: {e}")
                self._config_data = {}
        else:
            print("[IntegrationManager] No config file found, using defaults")
            self._config_data = {}

        # Load integrations from config
        integrations = self._config_data.get('integrations', [])

        for int_data in integrations:
            try:
                config = IntegrationConfig.from_dict(int_data)

                if not config.enabled:
                    continue

                provider_type = config.type
                if provider_type not in self._provider_registry:
                    print(f"[IntegrationManager] Unknown provider type: {provider_type}")
                    continue

                provider_class = self._provider_registry[provider_type]
                provider = provider_class(config)
                self._providers[config.id] = provider

            except Exception as e:
                print(f"[IntegrationManager] Failed to load integration: {e}")

        self._loaded = True
        return True

    def get_provider(self, integration_id: str) -> Optional[IntegrationProvider]:
        """
        Get a specific provider by ID.

        Args:
            integration_id: The integration ID

        Returns:
            IntegrationProvider instance or None
        """
        self.ensure_loaded()
        return self._providers.get(integration_id)

    def get_all_providers(self) -> List[IntegrationProvider]:
        """Get all enabled providers."""
        self.ensure_loaded()
        return list(self._providers.values())

    def get_providers_for_team(self, team: str) -> List[IntegrationProvider]:
        """
        Get providers available for a specific team.

        Args:
            team: Team identifier

        Returns:
            List of available providers
        """
        self.ensure_loaded()
        return [p for p in self._providers.values() if p.is_available_for_team(team)]

    def get_providers_by_type(self, provider_type: str) -> List[IntegrationProvider]:
        """
        Get all providers of a specific type.

        Args:
            provider_type: Provider type (e.g., 'jira')

        Returns:
            List of matching providers
        """
        self.ensure_loaded()
        return [p for p in self._providers.values() if p.provider_type == provider_type]

    def search(
        self,
        query: str,
        integration_id: Optional[str] = None,
        team: Optional[str] = None,
        max_results: int = 10
    ) -> Dict[str, SearchResult]:
        """
        Search for tickets across one or all integrations.

        Args:
            query: Search query string
            integration_id: Specific integration to search (None = all)
            team: Filter to team-available integrations
            max_results: Max results per integration

        Returns:
            Dict mapping integration_id to SearchResult
        """
        self.ensure_loaded()
        results = {}

        if integration_id:
            provider = self.get_provider(integration_id)
            if provider and provider.has_credentials():
                results[integration_id] = provider.search(query, max_results)
        else:
            providers = self.get_providers_for_team(team) if team else self.get_all_providers()
            for provider in providers:
                if provider.has_credentials():
                    results[provider.id] = provider.search(query, max_results)

        return results

    def verify(
        self,
        ticket_id: str,
        integration_id: Optional[str] = None
    ) -> Dict[str, VerifyResult]:
        """
        Verify a ticket exists in one or all integrations.

        Args:
            ticket_id: The ticket ID to verify
            integration_id: Specific integration (None = try all matching)

        Returns:
            Dict mapping integration_id to VerifyResult
        """
        self.ensure_loaded()
        results = {}

        if integration_id:
            provider = self.get_provider(integration_id)
            if provider:
                if provider.validate_ticket_format(ticket_id):
                    results[integration_id] = provider.verify(ticket_id)
                else:
                    results[integration_id] = VerifyResult(
                        valid=False,
                        error=f"Invalid format for {provider.name}"
                    )
        else:
            # Try all providers that match the ticket format
            for provider in self.get_all_providers():
                if provider.validate_ticket_format(ticket_id):
                    if provider.has_credentials():
                        results[provider.id] = provider.verify(ticket_id)
                    else:
                        # Format-only validation
                        results[provider.id] = VerifyResult(
                            valid=True,
                            ticket_id=ticket_id,
                            url=provider.get_ticket_url(ticket_id),
                            warning=f"{provider.name} credentials not configured"
                        )

        return results

    def test_connection(self, integration_id: str) -> ConnectionTestResult:
        """
        Test connection to a specific integration.

        Args:
            integration_id: The integration to test

        Returns:
            ConnectionTestResult
        """
        self.ensure_loaded()
        provider = self.get_provider(integration_id)

        if not provider:
            return ConnectionTestResult(
                success=False,
                message=f"Integration not found: {integration_id}"
            )

        if not provider.has_credentials():
            return ConnectionTestResult(
                success=False,
                message=f"Credentials not configured for {provider.name}"
            )

        return provider.test_connection()

    def get_ticket_url(self, ticket_id: str, integration_id: str) -> str:
        """
        Get the browse URL for a ticket.

        Args:
            ticket_id: The ticket ID
            integration_id: The integration ID

        Returns:
            URL string or empty string if not found
        """
        self.ensure_loaded()
        provider = self.get_provider(integration_id)
        if provider:
            return provider.get_ticket_url(ticket_id)
        return ""

    def list_integrations(self) -> List[Dict[str, Any]]:
        """
        Get list of all integrations for API response.

        Returns:
            List of integration info dicts
        """
        self.ensure_loaded()
        return [p.to_dict() for p in self._providers.values()]

    def fetch_issue(
        self,
        ticket_id: str,
        integration_id: Optional[str] = None,
        include_children: bool = True
    ) -> FetchResult:
        """
        Fetch a complete issue for import from an integration.

        If integration_id is not specified, attempts to auto-detect
        the provider based on the ticket_id format.

        Args:
            ticket_id: The ticket ID to fetch
            integration_id: Specific integration to use (None = auto-detect)
            include_children: Whether to fetch subtasks/children

        Returns:
            FetchResult with issue data or error
        """
        self.ensure_loaded()

        provider = None

        if integration_id:
            provider = self.get_provider(integration_id)
            if not provider:
                return FetchResult(
                    success=False,
                    error=f"Integration not found: {integration_id}"
                )
        else:
            # Auto-detect provider based on ticket format
            for p in self.get_all_providers():
                if p.validate_ticket_format(ticket_id):
                    provider = p
                    break

            if not provider:
                return FetchResult(
                    success=False,
                    error=f"Could not detect integration for ticket: {ticket_id}"
                )

        if not provider.has_credentials():
            return FetchResult(
                success=False,
                error=f"Credentials not configured for {provider.name}"
            )

        return provider.fetch_issue(ticket_id, include_children)

    def detect_provider(self, ticket_id: str) -> Optional[IntegrationProvider]:
        """
        Detect which provider handles a ticket ID based on format.

        Args:
            ticket_id: The ticket ID to check

        Returns:
            IntegrationProvider or None if no match
        """
        self.ensure_loaded()

        for provider in self.get_all_providers():
            if provider.validate_ticket_format(ticket_id):
                return provider

        return None

    def reload(self):
        """Force reload of configuration."""
        self._loaded = False
        self._providers.clear()
        self._config_data.clear()
        self.ensure_loaded()


# Global manager instance
_manager: Optional[IntegrationManager] = None


def get_manager() -> IntegrationManager:
    """Get the global IntegrationManager instance."""
    global _manager
    if _manager is None:
        _manager = IntegrationManager()
    return _manager
