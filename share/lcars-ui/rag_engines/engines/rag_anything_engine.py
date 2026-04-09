"""
RAG-Anything Engine Provider - Multimodal asset RAG engine.

RAG-Anything supports ingestion and retrieval across text, images,
tables, audio, and other multimodal content types.
"""

import subprocess
from pathlib import Path
from typing import Dict, Any, Optional

from ..provider import RAGEngineProvider, RAGEngineConfig, RAGEngineStatus, InstallProgress


# RAG-Anything defaults
_DEFAULT_PORT = 9623


class RAGAnythingEngine(RAGEngineProvider):
    """
    RAG engine provider for RAG-Anything.

    RAG-Anything enables multimodal retrieval across diverse content
    types including text documents, images, tables, audio transcripts,
    and mixed-format files — building a unified index across all assets.
    """

    # PyPI package name — used by check_for_updates() and update()
    package_name = "rag-anything"

    def __init__(self, config: RAGEngineConfig):
        """
        Initialize the RAG-Anything engine provider.

        Applies sensible defaults if config values are missing.

        Args:
            config: RAGEngineConfig with RAG-Anything-specific settings
        """
        if not config.port:
            config.port = _DEFAULT_PORT

        super().__init__(config)

    def install(self) -> InstallProgress:
        """
        Install RAG-Anything via pip.

        Four steps: pip install, create data directory, detect version,
        check optional multimodal system dependencies (tesseract, ffmpeg).
        Missing system deps produce a warning but do NOT fail the install.
        """
        # Step 1: Install pip package
        success, output = self._run_pip_install(["rag-anything"])
        if not success:
            return InstallProgress(
                engine_id=self.id, step=1, total_steps=4,
                message="Failed to install rag-anything",
                percent=0.0, error=output
            )

        # Step 2: Create data directory
        if not self._ensure_data_dir():
            return InstallProgress(
                engine_id=self.id, step=2, total_steps=4,
                message="Failed to create data directory",
                percent=25.0, error=f"Could not create {self.data_dir}"
            )

        # Step 3: Detect installed version
        installed, version = self._check_pip_package("rag-anything")
        if installed:
            self.config.version = version

        self.config.status = "installed"

        # Step 4: Check optional multimodal system dependencies (informational only)
        missing_deps = []
        for dep in ("tesseract", "ffmpeg"):
            try:
                result = subprocess.run(
                    ["which", dep],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode != 0:
                    missing_deps.append(dep)
            except (subprocess.TimeoutExpired, OSError):
                missing_deps.append(dep)

        message = f"RAG-Anything installed successfully (v{version or 'unknown'})"
        if missing_deps:
            message += f" — Warning: {'/'.join(missing_deps)} not found — multimodal features may be limited"

        return InstallProgress(
            engine_id=self.id, step=4, total_steps=4,
            message=message,
            percent=100.0, error=None
        )

    def uninstall(self) -> RAGEngineStatus:
        """
        Uninstall RAG-Anything.

        Stops the engine if running, then removes the pip package.
        """
        # Stop if running before uninstalling
        if self.config.status == "running" or self._find_process_pid():
            self.stop()

        success, output = self._run_pip_uninstall(["rag-anything"])
        if not success:
            return RAGEngineStatus(
                engine_id=self.id,
                status="error",
                health="unknown",
                message=f"Failed to uninstall rag-anything: {output}",
                last_check=self._now_iso()
            )

        self.config.status = "not_installed"
        self.config.version = None

        return RAGEngineStatus(
            engine_id=self.id,
            status="not_installed",
            health="unknown",
            message="RAG-Anything uninstalled successfully",
            last_check=self._now_iso()
        )

    def start(self) -> RAGEngineStatus:
        """
        Start the RAG-Anything server process.

        Launches the multimodal RAG API server on the configured port
        and data directory. No-ops if already running.
        """
        # Check if already running
        existing_pid = self._find_process_pid()
        if existing_pid:
            return RAGEngineStatus(
                engine_id=self.id,
                status="running",
                health="healthy",
                message=f"RAG-Anything already running on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port,
                pid=existing_pid
            )

        expanded_data_dir = str(Path(self.config.data_dir).expanduser())
        cmd = [
            self._venv_python(), "-m", "rag_anything", "serve",
            "--port", str(self.config.port),
            "--data-dir", expanded_data_dir
        ]

        pid = self._spawn_server(cmd)
        if pid is None:
            return RAGEngineStatus(
                engine_id=self.id,
                status="error",
                health="unhealthy",
                message=f"Failed to start RAG-Anything on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port
            )

        self.config.status = "running"

        return RAGEngineStatus(
            engine_id=self.id,
            status="running",
            health="unknown",
            message=f"RAG-Anything started on port {self.config.port}",
            last_check=self._now_iso(),
            port=self.config.port,
            pid=pid
        )

    def stop(self) -> RAGEngineStatus:
        """
        Stop the RAG-Anything server process.

        Sends SIGTERM (escalates to SIGKILL if needed) to the process
        running on the configured port.
        """
        self._kill_process()
        self.config.status = "installed"

        return RAGEngineStatus(
            engine_id=self.id,
            status="installed",
            health="unknown",
            message=f"RAG-Anything stopped on port {self.config.port}",
            last_check=self._now_iso()
        )

    def health_check(self) -> RAGEngineStatus:
        """
        Check RAG-Anything server health by probing the port.

        Returns stub status — actual implementation would hit the
        engine's health/status endpoint.
        """
        pid = self._find_process_pid()

        if pid:
            return RAGEngineStatus(
                engine_id=self.id,
                status="running",
                health="healthy",
                message=f"RAG-Anything process detected on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port,
                pid=pid
            )

        return RAGEngineStatus(
            engine_id=self.id,
            status="installed",
            health="unknown",
            message=f"No RAG-Anything process found on port {self.config.port}",
            last_check=self._now_iso(),
            port=self.config.port
        )

    def get_status(self) -> RAGEngineStatus:
        """
        Get current RAG-Anything status without a live health check.

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
        Apply configuration changes to RAG-Anything.

        Updates the in-memory settings dict. Actual on-disk persistence
        is handled by the manager's save_engine() method.

        Args:
            settings: Dict of RAG-Anything-specific settings (e.g., enabled modalities)

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
        Update RAG-Anything to the latest PyPI version.

        Stops the server, upgrades rag-anything, then restarts.

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
            'description': 'Multimodal asset RAG engine supporting text, images, tables, and audio'
        }
