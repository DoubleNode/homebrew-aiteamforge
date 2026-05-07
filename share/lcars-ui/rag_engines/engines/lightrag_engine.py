#
#  lightrag_engine.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
LightRAG Engine Provider - Text knowledge graph RAG engine.

LightRAG builds knowledge graphs from text documents and supports
graph-based retrieval for nuanced, context-aware queries.
"""

import os
from pathlib import Path
from typing import Dict, Any, Optional

from ..provider import RAGEngineProvider, RAGEngineConfig, RAGEngineStatus, InstallProgress


# LightRAG defaults
_DEFAULT_PORT = 9621
_DEFAULT_DATA_DIR = str(Path.home() / "rag-data" / "lightrag")


class LightRAGEngine(RAGEngineProvider):
    """
    RAG engine provider for LightRAG.

    LightRAG uses knowledge graphs to represent relationships between
    concepts extracted from text, enabling richer retrieval than
    simple vector similarity.

    Reference: https://github.com/HKUDS/LightRAG
    """

    # PyPI package name — used by check_for_updates() and update()
    package_name = "lightrag-hku"

    def __init__(self, config: RAGEngineConfig):
        """
        Initialize the LightRAG engine provider.

        Applies sensible defaults if config values are missing.

        Args:
            config: RAGEngineConfig with LightRAG-specific settings
        """
        # Apply defaults if not set in config
        if not config.port:
            config.port = _DEFAULT_PORT
        if not config.data_dir:
            config.data_dir = _DEFAULT_DATA_DIR

        super().__init__(config)

    def install(self) -> InstallProgress:
        """
        Install LightRAG via pip.

        Three steps: pip install, create data directory, detect installed version.
        """
        # Step 1: Install pip package (with API server extras)
        success, output = self._run_pip_install(["lightrag-hku[api]"])
        if not success:
            return InstallProgress(
                engine_id=self.id, step=1, total_steps=3,
                message="Failed to install lightrag-hku",
                percent=0.0, error=output
            )

        # Step 2: Create data directory
        if not self._ensure_data_dir():
            return InstallProgress(
                engine_id=self.id, step=2, total_steps=3,
                message="Failed to create data directory",
                percent=33.3, error=f"Could not create {self.data_dir}"
            )

        # Step 3: Detect installed version
        installed, version = self._check_pip_package("lightrag-hku")
        if installed:
            self.config.version = version

        self.config.status = "installed"

        return InstallProgress(
            engine_id=self.id, step=3, total_steps=3,
            message=f"LightRAG installed successfully (v{version or 'unknown'})",
            percent=100.0, error=None
        )

    def uninstall(self) -> RAGEngineStatus:
        """
        Uninstall LightRAG. Stops the process first if running.
        """
        # Stop if running
        pid = self._find_process_pid()
        if pid:
            self._kill_process()

        success, output = self._run_pip_uninstall(["lightrag-hku"])
        if not success:
            return RAGEngineStatus(
                engine_id=self.id, status="error", health="unknown",
                message=f"Failed to uninstall: {output}",
                last_check=self._now_iso()
            )

        self.config.status = "not_installed"
        self.config.version = None

        return RAGEngineStatus(
            engine_id=self.id, status="not_installed", health="unknown",
            message="LightRAG uninstalled successfully",
            last_check=self._now_iso()
        )

    def start(self) -> RAGEngineStatus:
        """
        Start the LightRAG API server subprocess.
        """
        # Check if already running
        existing_pid = self._find_process_pid()
        if existing_pid:
            return RAGEngineStatus(
                engine_id=self.id, status="running", health="healthy",
                message=f"LightRAG already running (PID {existing_pid})",
                last_check=self._now_iso(), port=self.config.port, pid=existing_pid
            )

        # Build start command — use the venv's lightrag-server entry point
        venv_bin = str(Path(self._venv_python()).parent)
        data_dir = str(Path(self.config.data_dir).expanduser())
        cmd = [
            os.path.join(venv_bin, "lightrag-server"),
            "--port", str(self.config.port),
            "--working-dir", data_dir
        ]

        pid = self._spawn_server(cmd)
        if pid is None:
            return RAGEngineStatus(
                engine_id=self.id, status="error", health="unhealthy",
                message="Failed to start LightRAG server",
                last_check=self._now_iso(), port=self.config.port
            )

        self.config.status = "running"

        return RAGEngineStatus(
            engine_id=self.id, status="running", health="healthy",
            message=f"LightRAG started on port {self.config.port} (PID {pid})",
            last_check=self._now_iso(), port=self.config.port, pid=pid
        )

    def stop(self) -> RAGEngineStatus:
        """
        Stop the LightRAG server process.
        """
        killed = self._kill_process()

        if not killed:
            # No process found — might already be stopped
            self.config.status = "installed"
            return RAGEngineStatus(
                engine_id=self.id, status="installed", health="unknown",
                message="No LightRAG process found to stop",
                last_check=self._now_iso(), port=self.config.port
            )

        self.config.status = "installed"

        return RAGEngineStatus(
            engine_id=self.id, status="installed", health="unknown",
            message="LightRAG stopped successfully",
            last_check=self._now_iso(), port=self.config.port
        )

    def health_check(self) -> RAGEngineStatus:
        """
        Check LightRAG server health by probing the API endpoint.

        Returns stub status — actual implementation would hit
        http://localhost:{port}/health or similar endpoint.
        """
        pid = self._find_process_pid()

        if pid:
            return RAGEngineStatus(
                engine_id=self.id,
                status="running",
                health="healthy",
                message=f"LightRAG process detected on port {self.config.port}",
                last_check=self._now_iso(),
                port=self.config.port,
                pid=pid
            )

        return RAGEngineStatus(
            engine_id=self.id,
            status="installed",
            health="unknown",
            message=f"No LightRAG process found on port {self.config.port}",
            last_check=self._now_iso(),
            port=self.config.port
        )

    def get_status(self) -> RAGEngineStatus:
        """
        Get current LightRAG status without a live health check.

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
        Apply configuration changes to LightRAG.

        Updates the in-memory settings dict. Actual on-disk persistence
        is handled by the manager's save_engine() method.

        Args:
            settings: Dict of LightRAG-specific settings

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
        Update LightRAG to the latest PyPI version.

        Stops the server, upgrades lightrag-hku, then restarts.

        Returns:
            RAGEngineStatus reflecting post-update state
        """
        return self._perform_update(self.package_name)

    def get_content_stats(self) -> Optional[Dict[str, Any]]:
        """Fetch document/chunk stats from the running LightRAG API."""
        import urllib.request
        import json

        pid = self._find_process_pid()
        if not pid:
            return None

        try:
            url = f"http://localhost:{self.port}/documents"
            req = urllib.request.Request(url, headers={"User-Agent": "lcars-rag/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))

            statuses = data.get("statuses", {})
            stats = {}
            total_docs = 0
            total_chunks = 0
            for status_name, docs in statuses.items():
                count = len(docs)
                chunks = sum(d.get("chunks_count", 0) for d in docs)
                stats[status_name] = {"documents": count, "chunks": chunks}
                total_docs += count
                total_chunks += chunks

            stats["total"] = {"documents": total_docs, "chunks": total_chunks}
            return stats
        except Exception:
            return None

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
            'description': 'Text knowledge graph RAG engine with graph-based retrieval'
        }
