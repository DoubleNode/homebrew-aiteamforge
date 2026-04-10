#!/usr/bin/env python3
"""
Secure credential storage for integration API tokens.

Uses AES-256-GCM encryption at rest with PBKDF2 key derivation.
Provides secure storage, retrieval, and audit logging for API credentials.

Security Features:
- AES-256-GCM authenticated encryption
- PBKDF2 key derivation with 480,000 iterations (OWASP 2023)
- Random salt per credential store
- Random nonce per save operation
- File permissions restricted to owner (0o600)
- Atomic file writes to prevent corruption
- Audit logging of all credential access
"""

import os
import json
import struct
import logging
import fcntl
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, Any, List

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    CRYPTO_AVAILABLE = True
except ImportError:
    CRYPTO_AVAILABLE = False

# File format constants
MAGIC = b'CRED'
VERSION = 1
SALT_SIZE = 16
NONCE_SIZE = 12
TAG_SIZE = 16  # GCM auth tag is included in ciphertext by cryptography lib
ITERATIONS = 480000  # OWASP 2023 recommendation for PBKDF2-SHA256

# File paths
# Credentials are intentionally centralized (shared across all teams), unlike
# team-specific configs (releases.json, integrations.json, calendar-config.json)
# which live in each team's kanban/config/ directory.
CONFIG_DIR = Path.home() / "dev-team" / "config"
CREDENTIAL_FILE = CONFIG_DIR / "credentials.enc"
LOG_DIR = Path.home() / "dev-team" / "logs" / "credential-access"

# Configure logging
logger = logging.getLogger(__name__)


class CredentialStoreError(Exception):
    """Base exception for credential store errors."""
    pass


class EncryptionError(CredentialStoreError):
    """Raised when encryption/decryption fails."""
    pass


class CredentialNotFoundError(CredentialStoreError):
    """Raised when a credential is not found."""
    pass


class CredentialStore:
    """
    Secure encrypted credential storage.

    Provides AES-256-GCM encrypted storage for integration API credentials.
    Supports multiple integrations, each identified by a short ID (e.g., "ME", "MON").

    Usage:
        store = CredentialStore()
        store.set_credential("ME", "jira", endpoint="...", user="...", token="...")
        cred = store.get_credential("ME")
    """

    def __init__(self, passphrase: Optional[str] = None, use_keychain: bool = True):
        """
        Initialize credential store.

        Args:
            passphrase: Optional user passphrase for key derivation.
                       Falls back to keychain or machine identifier if not provided.
            use_keychain: If True, try to use macOS Keychain for passphrase storage
        """
        if not CRYPTO_AVAILABLE:
            raise CredentialStoreError(
                "cryptography library not installed. "
                "Run: pip install cryptography"
            )

        self._key: Optional[bytes] = None
        self._salt: Optional[bytes] = None
        self._data: Optional[Dict] = None
        self._passphrase = passphrase
        self._use_keychain = use_keychain
        self._loaded = False

        # Try to get passphrase from keychain if not provided
        if self._passphrase is None and self._use_keychain:
            self._passphrase = self._get_passphrase_from_keychain()

    def _get_passphrase_from_keychain(self) -> Optional[str]:
        """
        Try to get passphrase from macOS Keychain.

        Returns:
            Passphrase if available, None otherwise
        """
        try:
            from integrations.keychain import get_passphrase_from_keychain
            return get_passphrase_from_keychain()
        except ImportError:
            return None
        except Exception as e:
            logger.debug(f"Could not get passphrase from keychain: {e}")
            return None

    def store_passphrase_in_keychain(self, passphrase: str) -> bool:
        """
        Store passphrase in macOS Keychain for future use.

        Args:
            passphrase: The passphrase to store

        Returns:
            True if successful, False otherwise
        """
        try:
            from integrations.keychain import get_keychain_manager
            keychain = get_keychain_manager()
            if keychain.is_available():
                keychain.store_passphrase(passphrase)
                self._passphrase = passphrase
                return True
        except Exception as e:
            logger.warning(f"Could not store passphrase in keychain: {e}")
        return False

    def clear_passphrase_from_keychain(self) -> bool:
        """
        Remove passphrase from macOS Keychain.

        Returns:
            True if successful, False otherwise
        """
        try:
            from integrations.keychain import get_keychain_manager
            keychain = get_keychain_manager()
            if keychain.is_available():
                keychain.delete_passphrase()
                return True
        except Exception as e:
            logger.warning(f"Could not clear passphrase from keychain: {e}")
        return False

    def _get_machine_id(self) -> str:
        """
        Get machine-specific identifier for key derivation fallback.

        Uses macOS IOPlatformUUID as the primary identifier.
        Falls back to username + UID if not available.

        Returns:
            Machine-specific string for key derivation.
        """
        import subprocess
        try:
            result = subprocess.run(
                ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
                capture_output=True,
                text=True,
                timeout=5
            )
            for line in result.stdout.split('\n'):
                if "IOPlatformUUID" in line:
                    # Extract UUID from line like: "IOPlatformUUID" = "XXXXXXXX-..."
                    parts = line.split('"')
                    if len(parts) >= 4:
                        return parts[-2]
        except Exception:
            pass

        # Fallback: username + UID (less secure but functional)
        return f"{os.environ.get('USER', 'default')}:{os.getuid()}"

    def _derive_key(self, salt: bytes) -> bytes:
        """
        Derive encryption key from passphrase using PBKDF2.

        Args:
            salt: Random salt for key derivation.

        Returns:
            32-byte (256-bit) encryption key.
        """
        passphrase = self._passphrase or self._get_machine_id()

        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,  # 256 bits
            salt=salt,
            iterations=ITERATIONS,
        )
        return kdf.derive(passphrase.encode('utf-8'))

    def _load(self) -> bool:
        """
        Load and decrypt credentials from file.

        Returns:
            True if successful, False otherwise.
        """
        if not CREDENTIAL_FILE.exists():
            # No file yet - initialize empty store
            self._data = {
                "version": "1.0",
                "lastUpdated": datetime.utcnow().isoformat() + "Z",
                "credentials": {}
            }
            self._loaded = True
            return True

        lock_file = str(CREDENTIAL_FILE) + ".lock"

        try:
            # Ensure lock file exists
            Path(lock_file).touch(exist_ok=True)

            with open(lock_file, 'r') as lock:
                # Shared lock for reading
                fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
                try:
                    with open(CREDENTIAL_FILE, 'rb') as f:
                        # Read and validate header
                        magic = f.read(4)
                        if magic != MAGIC:
                            raise EncryptionError("Invalid credential file format")

                        version_byte = f.read(1)
                        if len(version_byte) != 1:
                            raise EncryptionError("Truncated credential file")

                        version = struct.unpack('B', version_byte)[0]
                        if version != VERSION:
                            raise EncryptionError(f"Unsupported version: {version}")

                        self._salt = f.read(SALT_SIZE)
                        if len(self._salt) != SALT_SIZE:
                            raise EncryptionError("Truncated credential file (salt)")

                        nonce = f.read(NONCE_SIZE)
                        if len(nonce) != NONCE_SIZE:
                            raise EncryptionError("Truncated credential file (nonce)")

                        # Rest is encrypted data (includes GCM tag)
                        encrypted = f.read()
                        if len(encrypted) < TAG_SIZE:
                            raise EncryptionError("Truncated credential file (data)")

                        # Derive key and decrypt
                        self._key = self._derive_key(self._salt)
                        aesgcm = AESGCM(self._key)

                        try:
                            decrypted = aesgcm.decrypt(nonce, encrypted, None)
                        except Exception as e:
                            raise EncryptionError(
                                "Decryption failed - wrong passphrase or corrupted file"
                            ) from e

                        self._data = json.loads(decrypted.decode('utf-8'))
                        self._loaded = True
                        return True

                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except EncryptionError:
            raise
        except Exception as e:
            logger.error(f"Failed to load credentials: {e}")
            return False

    def _save(self) -> bool:
        """
        Encrypt and save credentials to file atomically.

        Uses temp file + atomic rename pattern for safety.
        Sets file permissions to 0o600 (owner read/write only).

        Returns:
            True if successful, False otherwise.
        """
        if self._data is None:
            return False

        lock_file = str(CREDENTIAL_FILE) + ".lock"
        tmp_file = str(CREDENTIAL_FILE) + ".tmp"

        try:
            # Ensure directories exist
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)

            # Ensure lock file exists
            Path(lock_file).touch(exist_ok=True)

            with open(lock_file, 'r+') as lock:
                # Exclusive lock for writing
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    # Generate new salt if needed
                    if self._salt is None:
                        self._salt = os.urandom(SALT_SIZE)

                    # Derive key
                    self._key = self._derive_key(self._salt)

                    # Generate random nonce (MUST be unique per encryption)
                    nonce = os.urandom(NONCE_SIZE)

                    # Encrypt data
                    aesgcm = AESGCM(self._key)
                    plaintext = json.dumps(self._data, indent=2).encode('utf-8')
                    encrypted = aesgcm.encrypt(nonce, plaintext, None)

                    # Write to temp file first
                    with open(tmp_file, 'wb') as f:
                        f.write(MAGIC)
                        f.write(struct.pack('B', VERSION))
                        f.write(self._salt)
                        f.write(nonce)
                        f.write(encrypted)
                        f.flush()
                        os.fsync(f.fileno())

                    # Set restrictive permissions before atomic rename
                    os.chmod(tmp_file, 0o600)

                    # Atomic rename
                    os.rename(tmp_file, CREDENTIAL_FILE)
                    return True

                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            logger.error(f"Failed to save credentials: {e}")
            # Clean up temp file
            try:
                if os.path.exists(tmp_file):
                    os.remove(tmp_file)
            except Exception:
                pass
            return False

    def _log_access(self, integration_id: str, action: str) -> None:
        """
        Log credential access for audit trail.

        Args:
            integration_id: ID of the integration accessed.
            action: Type of access (read, write, delete).
        """
        try:
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            log_file = LOG_DIR / "access.log"

            entry = {
                "timestamp": datetime.utcnow().isoformat() + "Z",
                "integration": integration_id,
                "action": action,
                "pid": os.getpid(),
                "user": os.environ.get("USER", "unknown")
            }

            # Append atomically with file locking
            lock_file = str(log_file) + ".lock"
            Path(lock_file).touch(exist_ok=True)

            with open(lock_file, 'r+') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    with open(log_file, 'a') as f:
                        f.write(json.dumps(entry) + "\n")
                        f.flush()
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

        except Exception as e:
            # Don't fail the operation if logging fails
            logger.warning(f"Failed to log credential access: {e}")

    def _ensure_loaded(self) -> bool:
        """Ensure credentials are loaded from disk."""
        if not self._loaded:
            return self._load()
        return True

    def get_credential(self, integration_id: str) -> Optional[Dict[str, Any]]:
        """
        Get credentials for an integration.

        Args:
            integration_id: Short ID of the integration (e.g., "ME", "MON").

        Returns:
            Dictionary with credential data, or None if not found.
        """
        if not self._ensure_loaded():
            return None

        cred = self._data.get("credentials", {}).get(integration_id)
        if cred:
            self._log_access(integration_id, "read")
            # Update last used timestamp
            cred["lastUsed"] = datetime.utcnow().isoformat() + "Z"
            self._save()  # Save updated lastUsed
            return cred.copy()  # Return copy to prevent external modification
        return None

    def set_credential(
        self,
        integration_id: str,
        cred_type: str,
        **kwargs
    ) -> bool:
        """
        Store credentials for an integration.

        Args:
            integration_id: Short ID of the integration (e.g., "ME", "MON").
            cred_type: Type of integration ("jira", "monday", etc.).
            **kwargs: Credential fields (e.g., endpoint, user, token).

        Returns:
            True if successful, False otherwise.
        """
        if not self._ensure_loaded():
            return False

        # Build credential object
        cred = {
            "type": cred_type,
            "addedAt": datetime.utcnow().isoformat() + "Z",
            "lastUsed": None,
            **kwargs
        }

        # Store credential
        if "credentials" not in self._data:
            self._data["credentials"] = {}
        self._data["credentials"][integration_id] = cred
        self._data["lastUpdated"] = datetime.utcnow().isoformat() + "Z"

        self._log_access(integration_id, "write")
        return self._save()

    def delete_credential(self, integration_id: str) -> bool:
        """
        Delete credentials for an integration.

        Args:
            integration_id: Short ID of the integration to delete.

        Returns:
            True if deleted, False if not found or error.
        """
        if not self._ensure_loaded():
            return False

        if integration_id in self._data.get("credentials", {}):
            del self._data["credentials"][integration_id]
            self._data["lastUpdated"] = datetime.utcnow().isoformat() + "Z"
            self._log_access(integration_id, "delete")
            return self._save()

        return False

    def list_integrations(self) -> List[str]:
        """
        List all integration IDs with stored credentials.

        Returns:
            List of integration IDs.
        """
        if not self._ensure_loaded():
            return []
        return list(self._data.get("credentials", {}).keys())

    def has_credential(self, integration_id: str) -> bool:
        """
        Check if credentials exist for an integration.

        Args:
            integration_id: Short ID of the integration.

        Returns:
            True if credentials exist, False otherwise.
        """
        if not self._ensure_loaded():
            return False
        return integration_id in self._data.get("credentials", {})

    def get_integration_info(self, integration_id: str) -> Optional[Dict[str, Any]]:
        """
        Get non-sensitive info about an integration.

        Returns type, addedAt, lastUsed but NOT the actual credentials.
        Useful for UI display without exposing secrets.

        Args:
            integration_id: Short ID of the integration.

        Returns:
            Dictionary with non-sensitive info, or None if not found.
        """
        if not self._ensure_loaded():
            return None

        cred = self._data.get("credentials", {}).get(integration_id)
        if cred:
            return {
                "type": cred.get("type"),
                "addedAt": cred.get("addedAt"),
                "lastUsed": cred.get("lastUsed"),
                "hasEndpoint": "endpoint" in cred,
                "hasUser": "user" in cred,
                "hasToken": "token" in cred
            }
        return None

    def verify_passphrase(self) -> bool:
        """
        Verify the current passphrase can decrypt the store.

        Returns:
            True if passphrase is correct (or no store exists yet).
        """
        try:
            return self._load()
        except EncryptionError:
            return False


# Singleton instance
_store: Optional[CredentialStore] = None


def get_credential_store(passphrase: Optional[str] = None) -> CredentialStore:
    """
    Get or create CredentialStore singleton.

    Args:
        passphrase: Optional passphrase for first initialization.

    Returns:
        Shared CredentialStore instance.
    """
    global _store
    if _store is None:
        _store = CredentialStore(passphrase)
    return _store


def reset_credential_store() -> None:
    """Reset the singleton instance. Used primarily for testing."""
    global _store
    _store = None
