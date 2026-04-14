"""
RAGEngineManager - Manages all configured RAG engine providers.

Handles loading configuration, instantiating engine providers, and providing
a unified interface for the server to interact with RAG engines.
"""

import json
import os
from pathlib import Path
from typing import Dict, List, Optional, Type, Any
from .provider import (
    RAGEngineProvider,
    RAGEngineConfig,
    RAGEngineStatus,
    InstallProgress
)


# Team kanban directory mapping (mirrors server.py TEAM_KANBAN_DIRS and kanban-helpers.sh)
# Used to locate team-specific config files in kanban/config/
_TEAM_KANBAN_DIRS = {
    "academy": Path.home() / "dev-team" / "kanban",
    "ios": Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android": Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase": Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command": Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
    "dns": Path("/Users/Shared/Development/DNSFramework/kanban"),
    "freelance-doublenode-starwords": Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning": Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats": Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard": Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),
    "legal-coparenting": Path.home() / "legal" / "coparenting" / "kanban",
    "medical-general": Path.home() / "medical" / "general" / "kanban",
    "finance-personal": Path.home() / "finance" / "personal" / "kanban",
}


class RAGEngineManager:
    """
    Manages RAG engine providers and configuration.

    Loads engine config from JSON file, instantiates appropriate provider
    classes, and provides a unified interface for install/start/stop/health
    operations across all configured engines.
    """

    # Registry of engine types to their implementation classes
    _engine_registry: Dict[str, Type[RAGEngineProvider]] = {}

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the manager.

        Args:
            config_path: Path to rag-engines.json config file.
                        If None, looks in default locations.
        """
        self._engines: Dict[str, RAGEngineProvider] = {}
        self._config_path = config_path
        self._config_data: Dict[str, Any] = {}
        self._loaded = False

    @classmethod
    def register_engine(cls, engine_type: str, engine_class: Type[RAGEngineProvider]):
        """
        Register an engine implementation class.

        Args:
            engine_type: Type identifier (e.g., 'lightrag', 'code-graph-rag')
            engine_class: The engine class to instantiate
        """
        cls._engine_registry[engine_type] = engine_class

    @classmethod
    def get_registered_types(cls) -> List[str]:
        """Get list of registered engine types."""
        return list(cls._engine_registry.keys())

    def _find_config_file(self) -> Optional[Path]:
        """Find the rag-engines config file in standard locations."""
        # Get team from environment for team-specific config
        lcars_team = os.environ.get("LCARS_TEAM", "academy")

        # Resolve team kanban directory (fallback to academy)
        kanban_dir = _TEAM_KANBAN_DIRS.get(lcars_team, Path.home() / "dev-team" / "kanban")

        search_paths = [
            # Explicit path
            Path(self._config_path) if self._config_path else None,
            # Team kanban config directory (PREFERRED - distributed with board data)
            kanban_dir / 'config' / 'rag-engines.json',
            # Fallback: centralized config
            Path.home() / 'dev-team' / 'config' / lcars_team / 'rag-engines.json',
            # Fallback: dev team config root
            Path.home() / 'dev-team' / 'config' / 'rag-engines.json',
        ]

        for path in search_paths:
            if path and path.exists():
                return path

        return None

    def ensure_loaded(self) -> None:
        """
        Ensure engine configuration is loaded (lazy load).

        This method only loads once. If config is already loaded, it returns
        immediately without re-reading the file. Use reload() to force a
        fresh read from disk.
        """
        if self._loaded:
            return

        config_file = self._find_config_file()

        if config_file:
            try:
                with open(config_file, 'r') as f:
                    self._config_data = json.load(f)
            except (json.JSONDecodeError, IOError) as e:
                print(f"[RAGEngineManager] Failed to load config: {e}")
                self._config_data = {}
        else:
            print("[RAGEngineManager] No config file found, using defaults")
            self._config_data = {}

        # Load engines from config
        engines = self._config_data.get('engines', [])

        for engine_data in engines:
            try:
                config = RAGEngineConfig.from_dict(engine_data)

                if not config.enabled:
                    continue

                engine_type = config.type
                if engine_type not in self._engine_registry:
                    print(f"[RAGEngineManager] Unknown engine type: {engine_type}")
                    continue

                engine_class = self._engine_registry[engine_type]
                engine = engine_class(config)
                self._engines[config.id] = engine

            except Exception as e:
                print(f"[RAGEngineManager] Failed to load engine: {e}")

        self._loaded = True

    def get_engine(self, engine_id: str) -> Optional[RAGEngineProvider]:
        """
        Get a specific engine by ID.

        Args:
            engine_id: The engine ID

        Returns:
            RAGEngineProvider instance or None
        """
        self.ensure_loaded()
        return self._engines.get(engine_id)

    def list_engines(self) -> List[Dict[str, Any]]:
        """
        Get list of all engines for API response.

        Returns:
            List of engine info dicts
        """
        self.ensure_loaded()
        return [e.to_dict() for e in self._engines.values()]

    def get_all_engines(self) -> List[RAGEngineProvider]:
        """Get all enabled engine providers."""
        self.ensure_loaded()
        return list(self._engines.values())

    def get_engines_for_team(self, team: str) -> List[RAGEngineProvider]:
        """
        Get engines available for a specific team.

        Args:
            team: Team identifier

        Returns:
            List of available engines
        """
        self.ensure_loaded()
        return [e for e in self._engines.values() if e.is_available_for_team(team)]

    def get_engines_by_type(self, engine_type: str) -> List[RAGEngineProvider]:
        """
        Get all engines of a specific type.

        Args:
            engine_type: Engine type (e.g., 'lightrag')

        Returns:
            List of matching engines
        """
        self.ensure_loaded()
        return [e for e in self._engines.values() if e.engine_type == engine_type]

    def save_engine(self, engine_data: Dict[str, Any]) -> bool:
        """
        Save engine configuration to disk.

        Creates or updates an engine entry in the config file.

        Args:
            engine_data: Engine config dict to save

        Returns:
            True if saved successfully, False otherwise
        """
        self.ensure_loaded()

        engine_id = engine_data.get('id', '')
        if not engine_id:
            print("[RAGEngineManager] Cannot save engine without an id")
            return False

        # Update in-memory config data
        engines = self._config_data.get('engines', [])
        existing_index = next(
            (i for i, e in enumerate(engines) if e.get('id') == engine_id),
            None
        )

        if existing_index is not None:
            engines[existing_index] = engine_data
        else:
            engines.append(engine_data)

        self._config_data['engines'] = engines

        # Write to disk
        config_file = self._find_config_file()
        if not config_file:
            # Create default location if no file exists
            lcars_team = os.environ.get("LCARS_TEAM", "academy")
            kanban_dir = _TEAM_KANBAN_DIRS.get(lcars_team, Path.home() / "dev-team" / "kanban")
            config_file = kanban_dir / 'config' / 'rag-engines.json'
            config_file.parent.mkdir(parents=True, exist_ok=True)

        try:
            with open(config_file, 'w') as f:
                json.dump(self._config_data, f, indent=2)
            return True
        except IOError as e:
            print(f"[RAGEngineManager] Failed to save config: {e}")
            return False

    def delete_engine(self, engine_id: str) -> bool:
        """
        Remove an engine from configuration.

        Args:
            engine_id: The engine ID to delete

        Returns:
            True if deleted, False if not found or error
        """
        self.ensure_loaded()

        engines = self._config_data.get('engines', [])
        filtered = [e for e in engines if e.get('id') != engine_id]

        if len(filtered) == len(engines):
            return False  # Not found

        self._config_data['engines'] = filtered
        self._engines.pop(engine_id, None)

        config_file = self._find_config_file()
        if config_file:
            try:
                with open(config_file, 'w') as f:
                    json.dump(self._config_data, f, indent=2)
                return True
            except IOError as e:
                print(f"[RAGEngineManager] Failed to delete engine from config: {e}")
                return False

        return True  # Removed from memory even if no file

    def install_engine(self, engine_id: str) -> InstallProgress:
        """
        Install a specific engine.

        Args:
            engine_id: The engine to install

        Returns:
            InstallProgress with current step info
        """
        self.ensure_loaded()
        engine = self.get_engine(engine_id)

        if not engine:
            return InstallProgress(
                engine_id=engine_id,
                step=0,
                total_steps=1,
                message="Engine not found",
                percent=0.0,
                error=f"Engine not found: {engine_id}"
            )

        result = engine.install()
        if result.error is None:
            engine.config.status = "installed"
            self.save_engine(engine.config.to_dict())
        return result

    def uninstall_engine(self, engine_id: str) -> RAGEngineStatus:
        """
        Uninstall a specific engine.

        Args:
            engine_id: The engine to uninstall

        Returns:
            RAGEngineStatus after uninstall
        """
        self.ensure_loaded()
        engine = self.get_engine(engine_id)

        if not engine:
            return RAGEngineStatus(
                engine_id=engine_id,
                status="error",
                health="unknown",
                message=f"Engine not found: {engine_id}"
            )

        result = engine.uninstall()
        if result.status != "error":
            engine.config.status = "not_installed"
            engine.config.version = None
            self.save_engine(engine.config.to_dict())
        return result

    def start_engine(self, engine_id: str) -> RAGEngineStatus:
        """
        Start a specific engine service.

        Args:
            engine_id: The engine to start

        Returns:
            RAGEngineStatus after start attempt
        """
        self.ensure_loaded()
        engine = self.get_engine(engine_id)

        if not engine:
            return RAGEngineStatus(
                engine_id=engine_id,
                status="error",
                health="unknown",
                message=f"Engine not found: {engine_id}"
            )

        result = engine.start()
        if result.status == "running":
            engine.config.status = "running"
            self.save_engine(engine.config.to_dict())
        return result

    def stop_engine(self, engine_id: str) -> RAGEngineStatus:
        """
        Stop a specific engine service.

        Args:
            engine_id: The engine to stop

        Returns:
            RAGEngineStatus after stop attempt
        """
        self.ensure_loaded()
        engine = self.get_engine(engine_id)

        if not engine:
            return RAGEngineStatus(
                engine_id=engine_id,
                status="error",
                health="unknown",
                message=f"Engine not found: {engine_id}"
            )

        result = engine.stop()
        if result.status != "error":
            engine.config.status = "installed"
            self.save_engine(engine.config.to_dict())
        return result

    def health_check(self, engine_id: Optional[str] = None) -> Dict[str, RAGEngineStatus]:
        """
        Check health of one or all engines.

        Args:
            engine_id: Specific engine to check, or None for all

        Returns:
            Dict mapping engine_id to RAGEngineStatus
        """
        self.ensure_loaded()
        results = {}

        if engine_id:
            engine = self.get_engine(engine_id)
            if engine:
                results[engine_id] = engine.health_check()
            else:
                results[engine_id] = RAGEngineStatus(
                    engine_id=engine_id,
                    status="error",
                    health="unknown",
                    message=f"Engine not found: {engine_id}"
                )
        else:
            for eid, engine in self._engines.items():
                results[eid] = engine.health_check()

        return results

    def reload(self):
        """Force reload of configuration."""
        self._loaded = False
        self._engines.clear()
        self._config_data.clear()
        self.ensure_loaded()


# Global manager instance
_manager: Optional[RAGEngineManager] = None


def get_manager() -> RAGEngineManager:
    """Get the global RAGEngineManager instance."""
    global _manager
    if _manager is None:
        _manager = RAGEngineManager()
    return _manager
