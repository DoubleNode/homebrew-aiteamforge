"""
Code-Graph-RAG Engine Provider - Source code intelligence RAG engine.

Code-Graph-RAG builds knowledge graphs from source code, understanding
symbol relationships, call graphs, and inheritance hierarchies for
code-aware retrieval.
"""

from pathlib import Path
from typing import Dict, Any, Optional

from ..provider import RAGEngineProvider, RAGEngineConfig, RAGEngineStatus, InstallProgress


# Code-Graph-RAG defaults
_DEFAULT_PORT = 9622
_DEFAULT_DATA_DIR = str(Path.home() / "rag-data" / "code-graph")


class CodeGraphRAGEngine(RAGEngineProvider):
    """
    RAG engine provider for Code-Graph-RAG.

    Code-Graph-RAG analyzes source code repositories and builds structured
    knowledge graphs capturing symbol definitions, call relationships,
    imports, and inheritance — enabling precise code-aware queries.
    """

    # PyPI package name — used by check_for_updates() and update()
    package_name = "code-graph-rag"

    def __init__(self, config: RAGEngineConfig):
        """
        Initialize the Code-Graph-RAG engine provider.

        Applies sensible defaults if config values are missing.

        Args:
            config: RAGEngineConfig with Code-Graph-RAG-specific settings
        """
        if not config.port:
            config.port = _DEFAULT_PORT
        if not config.data_dir:
            config.data_dir = _DEFAULT_DATA_DIR

        super().__init__(config)

    def install(self) -> InstallProgress:
        """
        Install Code-Graph-RAG via pip.

        Installs the code-graph-rag package, creates the data directory,
        and detects the installed version.
        """
        # Step 1: pip install
        ok, output = self._run_pip_install(["code-graph-rag"])
        if not ok:
            return InstallProgress(
                engine_id=self.id,
                step=1,
                total_steps=3,
                message="pip install failed",
                percent=0.0,
                error=output
            )

        # Step 2: create data directory
        if not self._ensure_data_dir():
            return InstallProgress(
                engine_id=self.id,
                step=2,
                total_steps=3,
                message="Failed to create data directory",
                percent=66.6,
                error=f"Could not create data directory: {self.config.data_dir}"
            )

        # Step 3: detect installed version
        installed, version = self._check_pip_package("code-graph-rag")
        if installed:
            self.config.status = "installed"
            self.config.version = version
            return InstallProgress(
                engine_id=self.id,
                step=3,
                total_steps=3,
                message=f"Code-Graph-RAG {version or 'unknown version'} installed successfully",
                percent=100.0,
                error=None
            )

        return InstallProgress(
            engine_id=self.id,
            step=3,
            total_steps=3,
            message="Installation completed but package verification failed",
            percent=100.0,
            error="Could not verify installed package via pip show"
        )

    def uninstall(self) -> RAGEngineStatus:
        """
        Uninstall Code-Graph-RAG.

        Stops any running server process first, then removes the pip package.
        """
        # Stop if running
        if self._find_process_pid():
            self._kill_process()

        ok, output = self._run_pip_uninstall(["code-graph-rag"])

        self.config.status = "not_installed"
        self.config.version = None

        if not ok:
            return RAGEngineStatus(
                engine_id=self.id,
                status="not_installed",
                health="unknown",
                message=f"Uninstall encountered an error: {output}",
                last_check=self._now_iso()
            )

        return RAGEngineStatus(
            engine_id=self.id,
            status="not_installed",
            health="unknown",
            message="Code-Graph-RAG uninstalled successfully",
            last_check=self._now_iso()
        )

    def start(self) -> RAGEngineStatus:
        """
        Start the Code-Graph-RAG server process.

        Launches the server subprocess on the configured port using
        the current Python interpreter.
        """
        # Check if already running
        pid = self._find_process_pid()
        if pid:
            return RAGEngineStatus(
                engine_id=self.id,
                status="running",
                health="healthy",
                message=f"Code-Graph-RAG already running on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port,
                pid=pid
            )

        expanded_data_dir = str(Path(self.config.data_dir).expanduser())
        cmd = [
            self._venv_python(), "-m", "code_graph_rag", "serve",
            "--port", str(self.config.port),
            "--data-dir", expanded_data_dir
        ]

        pid = self._spawn_server(cmd)

        if pid is None:
            return RAGEngineStatus(
                engine_id=self.id,
                status="error",
                health="unhealthy",
                message=f"Failed to start Code-Graph-RAG on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port
            )

        self.config.status = "running"

        return RAGEngineStatus(
            engine_id=self.id,
            status="running",
            health="unknown",
            message=f"Code-Graph-RAG started on port {self.config.port}",
            last_check=self._now_iso(),
            port=self.config.port,
            pid=pid
        )

    def stop(self) -> RAGEngineStatus:
        """
        Stop the Code-Graph-RAG server process via SIGTERM.
        """
        self._kill_process()
        self.config.status = "installed"

        return RAGEngineStatus(
            engine_id=self.id,
            status="installed",
            health="unknown",
            message=f"Code-Graph-RAG stopped on port {self.config.port}",
            last_check=self._now_iso()
        )

    def health_check(self) -> RAGEngineStatus:
        """
        Check Code-Graph-RAG server health by probing the port.

        Returns stub status — actual implementation would hit the
        engine's health endpoint.
        """
        pid = self._find_process_pid()

        if pid:
            return RAGEngineStatus(
                engine_id=self.id,
                status="running",
                health="healthy",
                message=f"Code-Graph-RAG process detected on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port,
                pid=pid
            )

        return RAGEngineStatus(
            engine_id=self.id,
            status="installed",
            health="unknown",
            message=f"No Code-Graph-RAG process found on port {self.config.port}",
            last_check=self._now_iso(),
            port=self.config.port
        )

    def get_status(self) -> RAGEngineStatus:
        """
        Get current Code-Graph-RAG status without a live health check.

        Returns status based on config and process detection.
        """
        pid = self._find_process_pid()

        status = "running" if pid else self.config.status
        health = "healthy" if pid else "unknown"

        return RAGEngineStatus(
            engine_id=self.id,
            status=status,
            health=health,
            message=None,
            last_check=self._now_iso(),
            version=self.config.version,
            port=self.config.port,
            pid=pid
        )

    def configure(self, settings: Dict[str, Any]) -> RAGEngineStatus:
        """
        Apply configuration changes to Code-Graph-RAG.

        Updates the in-memory settings dict. Actual on-disk persistence
        is handled by the manager's save_engine() method.

        Args:
            settings: Dict of Code-Graph-RAG-specific settings (e.g., indexed repos)

        Returns:
            RAGEngineStatus after configuration
        """
        self.config.settings.update(settings)

        return RAGEngineStatus(
            engine_id=self.id,
            status=self.config.status,
            health="unknown",
            message="Configuration updated (restart required to apply)",
            last_check=self._now_iso()
        )

    def update(self) -> RAGEngineStatus:
        """
        Update Code-Graph-RAG to the latest PyPI version.

        Stops the server, upgrades code-graph-rag, then restarts.

        Returns:
            RAGEngineStatus reflecting post-update state
        """
        return self._perform_update(self.package_name)

    def to_dict(self) -> Dict[str, Any]:
        """Convert provider info to dictionary for API responses."""
        return {
            'id': self.id,
            'type': self.engine_type,
            'name': self.name,
            'enabled': self.enabled,
            'port': self.port,
            'dataDir': self.data_dir,
            'installPath': self.config.install_path,
            'status': self.config.status,
            'version': self.config.version,
            'settings': self.config.settings,
            'teams': self.config.teams if self.config.teams else None,
            'description': 'Source code intelligence RAG engine with call graph and symbol analysis'
        }
