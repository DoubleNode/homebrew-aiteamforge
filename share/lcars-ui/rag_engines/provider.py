"""
RAGEngineProvider - Base class for RAG engine providers.

All RAG engine implementations (LightRAG, Code-Graph-RAG, RAG-Anything)
inherit from this abstract base class and implement the required methods.
"""

import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
import urllib.error
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone


@dataclass
class RAGEngineConfig:
    """Configuration for a RAG engine."""
    id: str
    type: str  # lightrag | code-graph-rag | rag-anything
    name: str
    enabled: bool = True
    install_path: str = ""
    data_dir: str = ""
    port: int = 0
    status: str = "not_installed"  # not_installed | installed | running | error
    version: Optional[str] = None
    settings: Dict[str, Any] = field(default_factory=dict)
    teams: List[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'RAGEngineConfig':
        """Create config from dictionary (JSON)."""
        return cls(
            id=data.get('id', ''),
            type=data.get('type', ''),
            name=data.get('name', ''),
            enabled=data.get('enabled', True),
            install_path=data.get('installPath', ''),
            data_dir=data.get('dataDir', ''),
            port=data.get('port', 0),
            status=data.get('status', 'not_installed'),
            version=data.get('version'),
            settings=data.get('settings', {}),
            teams=data.get('teams', [])
        )

    def to_dict(self) -> Dict[str, Any]:
        """Convert config to dictionary for JSON serialization."""
        return {
            'id': self.id,
            'type': self.type,
            'name': self.name,
            'enabled': self.enabled,
            'installPath': self.install_path,
            'dataDir': self.data_dir,
            'port': self.port,
            'status': self.status,
            'version': self.version,
            'settings': self.settings,
            'teams': self.teams if self.teams else None
        }


@dataclass
class RAGEngineStatus:
    """Runtime status of a RAG engine."""
    engine_id: str
    status: str  # not_installed | installed | running | error
    health: str = "unknown"  # healthy | degraded | unhealthy | unknown
    message: Optional[str] = None
    last_check: Optional[str] = None
    version: Optional[str] = None
    port: Optional[int] = None
    pid: Optional[int] = None
    latest_version: Optional[str] = None
    update_available: bool = False

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'engineId': self.engine_id,
            'status': self.status,
            'health': self.health,
            'message': self.message,
            'lastCheck': self.last_check,
            'version': self.version,
            'port': self.port,
            'pid': self.pid,
            'latestVersion': self.latest_version,
            'updateAvailable': self.update_available
        }


@dataclass
class InstallProgress:
    """Progress report for engine installation."""
    engine_id: str
    step: int
    total_steps: int
    message: str
    percent: float = 0.0
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            'engineId': self.engine_id,
            'step': self.step,
            'totalSteps': self.total_steps,
            'message': self.message,
            'percent': self.percent,
            'error': self.error
        }


class RAGEngineProvider(ABC):
    """
    Abstract base class for RAG engine providers.

    Subclasses must implement:
    - install() - Install the engine
    - uninstall() - Remove the engine
    - start() - Start the engine service
    - stop() - Stop the engine service
    - health_check() - Check engine health
    - get_status() - Get current engine status
    - configure() - Apply configuration changes
    - to_dict() - Serialize provider info for API responses
    """

    def __init__(self, config: RAGEngineConfig):
        """
        Initialize the provider with configuration.

        Args:
            config: RAGEngineConfig instance with engine settings
        """
        self.config = config

    def _rag_data_root(self) -> Path:
        """Derive the rag-data root from this engine's data_dir (its parent)."""
        return Path(self.config.data_dir).expanduser().parent

    def _venv_dir(self) -> Path:
        """Shared venv lives alongside engine data dirs under rag-data/venv."""
        return self._rag_data_root() / "venv"

    def _venv_python(self) -> str:
        """Get the path to the venv Python executable, creating the venv if needed."""
        venv_dir = self._venv_dir()
        venv_python = venv_dir / "bin" / "python3"
        if not venv_python.exists():
            self._ensure_venv()
        return str(venv_python)

    def _ensure_venv(self) -> bool:
        """Create the shared RAG engine venv if it doesn't exist."""
        venv_dir = self._venv_dir()
        if (venv_dir / "bin" / "python3").exists():
            return True
        try:
            venv_dir.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [sys.executable, "-m", "venv", str(venv_dir)],
                capture_output=True,
                text=True,
                timeout=60
            )
            return (venv_dir / "bin" / "python3").exists()
        except (subprocess.TimeoutExpired, OSError):
            return False

    def _now_iso(self) -> str:
        """Get current UTC time as ISO 8601 string."""
        return datetime.now(timezone.utc).isoformat()

    def _find_process_pid(self) -> Optional[int]:
        """Find the PID of a server process running on the configured port."""
        try:
            result = subprocess.run(
                ["lsof", "-ti", f"tcp:{self.config.port}"],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return int(result.stdout.strip().split('\n')[0])
        except (subprocess.TimeoutExpired, ValueError, OSError):
            pass
        return None

    def _run_pip_install(self, packages: List[str]) -> tuple[bool, str]:
        """
        Install pip packages into the RAG engine venv.

        Args:
            packages: List of package names/specs to install

        Returns:
            (True, stdout) on success, (False, stderr) on failure
        """
        try:
            venv_py = self._venv_python()
            result = subprocess.run(
                [venv_py, "-m", "pip", "install"] + packages,
                capture_output=True,
                text=True,
                timeout=300
            )
            if result.returncode == 0:
                return (True, result.stdout)
            return (False, result.stderr)
        except subprocess.TimeoutExpired:
            return (False, "pip install timed out after 300 seconds")

    def _run_pip_uninstall(self, packages: List[str]) -> tuple[bool, str]:
        """
        Uninstall pip packages from the RAG engine venv.

        Args:
            packages: List of package names to uninstall

        Returns:
            (True, stdout) on success, (False, stderr) on failure
        """
        try:
            venv_py = self._venv_python()
            result = subprocess.run(
                [venv_py, "-m", "pip", "uninstall", "-y"] + packages,
                capture_output=True,
                text=True,
                timeout=60
            )
            if result.returncode == 0:
                return (True, result.stdout)
            return (False, result.stderr)
        except subprocess.TimeoutExpired:
            return (False, "pip uninstall timed out after 60 seconds")

    def _ensure_data_dir(self) -> bool:
        """
        Create the engine's data directory if it does not exist.

        Returns:
            True on success, False on OSError
        """
        try:
            Path(self.config.data_dir).expanduser().mkdir(parents=True, exist_ok=True)
            return True
        except OSError:
            return False

    def _check_pip_package(self, package: str) -> tuple[bool, Optional[str]]:
        """
        Check whether a pip package is installed in the RAG engine venv.

        Args:
            package: Package name to check

        Returns:
            (True, version_string) if installed, (False, None) if not installed
        """
        try:
            venv_py = self._venv_python()
            result = subprocess.run(
                [venv_py, "-m", "pip", "show", package],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if line.startswith("Version:"):
                        version = line.split(":", 1)[1].strip()
                        return (True, version)
                return (True, None)
            return (False, None)
        except subprocess.TimeoutExpired:
            return (False, None)

    def _spawn_server(self, cmd: List[str], env: Optional[Dict[str, str]] = None) -> Optional[int]:
        """
        Spawn a background server process.

        Args:
            cmd: Command list to execute
            env: Optional environment variables to merge with os.environ

        Returns:
            Process PID on success, None on failure
        """
        try:
            # Log stderr to a file so startup failures can be diagnosed
            log_dir = self._rag_data_root() / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            log_path = log_dir / f"{self.config.id}-stderr.log"
            stderr_file = open(log_path, "a")

            merged_env = {**os.environ, **env} if env else None
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=stderr_file,
                env=merged_env
            )
            # Close parent's copy of the fd — child process inherited its own
            stderr_file.close()
            return proc.pid
        except OSError:
            return None

    def _kill_process(self) -> bool:
        """
        Kill the server process running on the configured port via SIGTERM.

        Returns:
            True if a process was found and killed, False otherwise
        """
        pid = self._find_process_pid()
        if pid is None:
            return False
        try:
            os.kill(pid, signal.SIGTERM)
            # Verify it's gone after a brief wait
            time.sleep(0.5)
            if self._find_process_pid() is None:
                return True
            # Process still alive — escalate to SIGKILL
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            return True
        except OSError:
            return False

    @property
    def id(self) -> str:
        """Get the engine ID."""
        return self.config.id

    @property
    def name(self) -> str:
        """Get the display name."""
        return self.config.name

    @property
    def engine_type(self) -> str:
        """Get the engine type (lightrag, code-graph-rag, etc.)."""
        return self.config.type

    @property
    def enabled(self) -> bool:
        """Check if this engine is enabled."""
        return self.config.enabled

    @property
    def port(self) -> int:
        """Get the configured port."""
        return self.config.port

    @property
    def data_dir(self) -> str:
        """Get the data directory path."""
        return self.config.data_dir

    def check_pypi_version(self, package_name: str) -> Optional[str]:
        """
        Fetch the latest stable version of a package from PyPI.

        Args:
            package_name: The PyPI package name (e.g. 'lightrag-hku')

        Returns:
            Version string (e.g. '1.2.3') or None on any error
        """
        url = f"https://pypi.org/pypi/{package_name}/json"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "lcars-rag-engine/1.0"})
            with urllib.request.urlopen(req, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
                return data.get("info", {}).get("version")
        except (urllib.error.URLError, urllib.error.HTTPError, OSError, KeyError, ValueError):
            return None

    def check_for_updates(self) -> Dict[str, Any]:
        """
        Compare installed version against latest on PyPI.

        Subclasses should call this with the relevant package name.
        The base implementation delegates to get_status() for current
        version and check_pypi_version() for latest.

        Returns:
            Dict with keys: current_version, latest_version, update_available
        """
        # Use the subclass package_name attribute if available
        package_name = getattr(self, "package_name", None)
        current_version: Optional[str] = self.config.version

        if package_name is None:
            return {
                "current_version": current_version,
                "latest_version": None,
                "update_available": False
            }

        latest_version = self.check_pypi_version(package_name)

        update_available = False
        if current_version and latest_version:
            try:
                from packaging.version import parse as parse_version
                update_available = parse_version(latest_version) > parse_version(current_version)
            except Exception:
                # Fallback to simple string comparison if packaging not available
                update_available = latest_version != current_version

        return {
            "current_version": current_version,
            "latest_version": latest_version,
            "update_available": update_available
        }

    def _perform_update(self, package_name: str) -> 'RAGEngineStatus':
        """
        Stop → pip upgrade → restart.

        Args:
            package_name: The PyPI package name to upgrade (e.g. 'lightrag-hku')

        Returns:
            RAGEngineStatus after the update attempt.  Even if the upgrade
            fails the engine will attempt a restart so it stays available.
        """
        # Step 1: Stop if running
        was_running = bool(self._find_process_pid())
        if was_running:
            self.stop()

        # Step 2: pip install --upgrade
        ok, output = self._run_pip_install(["--upgrade", package_name])

        if not ok:
            # Upgrade failed — try to restart anyway so the engine stays up
            if was_running:
                self.start()
            return RAGEngineStatus(
                engine_id=self.id,
                status=self.config.status,
                health="unknown",
                message=f"Upgrade failed: {output[:200]}",
                last_check=self._now_iso(),
                version=self.config.version,
                port=self.config.port
            )

        # Step 3: Detect new version
        installed, new_version = self._check_pip_package(package_name)
        if installed and new_version:
            self.config.version = new_version

        # Step 4: Restart if it was running before
        if was_running:
            restart_status = self.start()
        else:
            restart_status = RAGEngineStatus(
                engine_id=self.id,
                status="installed",
                health="unknown",
                message=f"Updated to v{self.config.version or 'unknown'} (engine was not running)",
                last_check=self._now_iso(),
                version=self.config.version,
                port=self.config.port
            )

        # Annotate with the new version info
        restart_status.version = self.config.version
        restart_status.message = (
            f"Updated to v{self.config.version or 'unknown'} — {restart_status.message or 'restarted'}"
        )
        return restart_status

    def is_available_for_team(self, team: str) -> bool:
        """
        Check if this engine is available for a specific team.

        Args:
            team: Team identifier

        Returns:
            True if available (no team restriction or team is in list)
        """
        if not self.config.teams:
            return True  # No restriction = available for all

        return team.lower() in [t.lower() for t in self.config.teams]

    @abstractmethod
    def install(self) -> InstallProgress:
        """
        Install the RAG engine.

        Returns:
            InstallProgress with current step info
        """
        pass

    @abstractmethod
    def uninstall(self) -> RAGEngineStatus:
        """
        Uninstall the RAG engine.

        Returns:
            RAGEngineStatus after uninstall
        """
        pass

    @abstractmethod
    def start(self) -> RAGEngineStatus:
        """
        Start the RAG engine service.

        Returns:
            RAGEngineStatus after start attempt
        """
        pass

    @abstractmethod
    def stop(self) -> RAGEngineStatus:
        """
        Stop the RAG engine service.

        Returns:
            RAGEngineStatus after stop attempt
        """
        pass

    @abstractmethod
    def health_check(self) -> RAGEngineStatus:
        """
        Check the health of the running engine.

        Returns:
            RAGEngineStatus with health information
        """
        pass

    @abstractmethod
    def get_status(self) -> RAGEngineStatus:
        """
        Get the current status of the engine (without a live health check).

        Returns:
            RAGEngineStatus based on last known state
        """
        pass

    @abstractmethod
    def configure(self, settings: Dict[str, Any]) -> RAGEngineStatus:
        """
        Apply configuration changes to the engine.

        Args:
            settings: Dict of engine-specific settings to apply

        Returns:
            RAGEngineStatus after configuration
        """
        pass

    @abstractmethod
    def update(self) -> 'RAGEngineStatus':
        """
        Update the engine package to the latest PyPI version.

        Implementations should stop the engine, upgrade the package,
        restart the engine, and return updated status.

        Returns:
            RAGEngineStatus after update attempt
        """
        pass

    def get_content_stats(self) -> Optional[Dict[str, Any]]:
        """
        Fetch content statistics from a running engine.

        Override in subclasses that support content stats.
        Returns None by default (no stats available).
        """
        return None

    @abstractmethod
    def to_dict(self) -> Dict[str, Any]:
        """
        Convert provider info to dictionary for API responses.

        Returns:
            Dict with engine information
        """
        pass

    def __repr__(self) -> str:
        return f"<{self.__class__.__name__} id={self.id} name={self.name}>"
