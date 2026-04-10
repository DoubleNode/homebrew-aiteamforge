#!/usr/bin/env python3
"""
macOS Keychain integration for secure master passphrase storage.

Uses the `security` command-line tool to interact with macOS Keychain.
This provides an additional layer of security by storing the encryption
master key in the system keychain rather than deriving it from machine ID.

Usage:
    from integrations.keychain import KeychainManager

    keychain = KeychainManager()

    # Store passphrase
    keychain.store_passphrase("my-secure-passphrase")

    # Retrieve passphrase
    passphrase = keychain.get_passphrase()

    # Check if passphrase exists
    if keychain.has_passphrase():
        ...

    # Delete passphrase
    keychain.delete_passphrase()

Security Notes:
- Passphrase is stored in the user's login keychain
- Access control is set to allow access only from this application
- Keychain may prompt for user authentication
"""

import os
import subprocess
import logging
from typing import Optional

logger = logging.getLogger(__name__)

# Keychain service and account identifiers
KEYCHAIN_SERVICE = "dev-team.credential-store"
KEYCHAIN_ACCOUNT = "master-passphrase"


class KeychainError(Exception):
    """Raised when a keychain operation fails."""
    pass


class KeychainNotAvailableError(KeychainError):
    """Raised when keychain is not available (non-macOS)."""
    pass


class KeychainManager:
    """
    Manages secure passphrase storage in macOS Keychain.

    Provides methods to store, retrieve, and delete the master passphrase
    used for credential encryption.
    """

    def __init__(
        self,
        service: str = KEYCHAIN_SERVICE,
        account: str = KEYCHAIN_ACCOUNT
    ):
        """
        Initialize KeychainManager.

        Args:
            service: Keychain service name (identifies the application)
            account: Keychain account name (identifies the specific secret)
        """
        self.service = service
        self.account = account
        self._available: Optional[bool] = None

    def is_available(self) -> bool:
        """
        Check if macOS Keychain is available.

        Returns:
            True if on macOS and security command is available
        """
        if self._available is not None:
            return self._available

        # Check if we're on macOS
        import platform
        if platform.system() != "Darwin":
            self._available = False
            return False

        # Check if security command exists
        try:
            result = subprocess.run(
                ["which", "security"],
                capture_output=True,
                timeout=5
            )
            self._available = result.returncode == 0
        except Exception:
            self._available = False

        return self._available

    def store_passphrase(self, passphrase: str) -> bool:
        """
        Store passphrase in macOS Keychain.

        Args:
            passphrase: The passphrase to store

        Returns:
            True if successful

        Raises:
            KeychainNotAvailableError: If keychain is not available
            KeychainError: If storage fails
        """
        if not self.is_available():
            raise KeychainNotAvailableError("macOS Keychain not available")

        try:
            # Use -U flag to update if exists, otherwise add
            result = subprocess.run(
                [
                    "security", "add-generic-password",
                    "-s", self.service,
                    "-a", self.account,
                    "-w", passphrase,
                    "-U"  # Update if exists
                ],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode != 0:
                # Check if it's a duplicate error
                if "already exists" in result.stderr.lower():
                    # Try to delete and re-add
                    self.delete_passphrase()
                    return self.store_passphrase(passphrase)
                raise KeychainError(f"Failed to store passphrase: {result.stderr}")

            logger.info(f"Passphrase stored in Keychain (service: {self.service})")
            return True

        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except Exception as e:
            raise KeychainError(f"Keychain error: {e}")

    def get_passphrase(self) -> Optional[str]:
        """
        Retrieve passphrase from macOS Keychain.

        Returns:
            The passphrase if found, None otherwise

        Raises:
            KeychainNotAvailableError: If keychain is not available
            KeychainError: If retrieval fails (other than not found)
        """
        if not self.is_available():
            raise KeychainNotAvailableError("macOS Keychain not available")

        try:
            result = subprocess.run(
                [
                    "security", "find-generic-password",
                    "-s", self.service,
                    "-a", self.account,
                    "-w"  # Output password only
                ],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                return result.stdout.strip()
            elif "could not be found" in result.stderr.lower():
                return None
            else:
                raise KeychainError(f"Failed to retrieve passphrase: {result.stderr}")

        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except KeychainError:
            raise
        except Exception as e:
            raise KeychainError(f"Keychain error: {e}")

    def has_passphrase(self) -> bool:
        """
        Check if passphrase exists in Keychain.

        Returns:
            True if passphrase exists
        """
        if not self.is_available():
            return False

        try:
            return self.get_passphrase() is not None
        except KeychainError:
            return False

    def delete_passphrase(self) -> bool:
        """
        Delete passphrase from macOS Keychain.

        Returns:
            True if deleted or didn't exist

        Raises:
            KeychainNotAvailableError: If keychain is not available
            KeychainError: If deletion fails
        """
        if not self.is_available():
            raise KeychainNotAvailableError("macOS Keychain not available")

        try:
            result = subprocess.run(
                [
                    "security", "delete-generic-password",
                    "-s", self.service,
                    "-a", self.account
                ],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                logger.info(f"Passphrase deleted from Keychain (service: {self.service})")
                return True
            elif "could not be found" in result.stderr.lower():
                return True  # Already deleted
            else:
                raise KeychainError(f"Failed to delete passphrase: {result.stderr}")

        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except KeychainError:
            raise
        except Exception as e:
            raise KeychainError(f"Keychain error: {e}")


# Singleton instance
_keychain: Optional[KeychainManager] = None


def get_keychain_manager() -> KeychainManager:
    """
    Get or create KeychainManager singleton.

    Returns:
        Shared KeychainManager instance
    """
    global _keychain
    if _keychain is None:
        _keychain = KeychainManager()
    return _keychain


def get_passphrase_from_keychain() -> Optional[str]:
    """
    Convenience function to get passphrase from keychain.

    Returns:
        Passphrase if available and keychain is supported, None otherwise
    """
    try:
        keychain = get_keychain_manager()
        if keychain.is_available():
            return keychain.get_passphrase()
    except KeychainError as e:
        logger.warning(f"Failed to get passphrase from keychain: {e}")
    return None


# CLI for testing
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Keychain Manager CLI")
    subparsers = parser.add_subparsers(dest="command")

    # Check availability
    subparsers.add_parser("check", help="Check if keychain is available")

    # Store passphrase
    store_parser = subparsers.add_parser("store", help="Store passphrase")
    store_parser.add_argument("passphrase", help="Passphrase to store")

    # Get passphrase
    subparsers.add_parser("get", help="Get passphrase")

    # Check if exists
    subparsers.add_parser("has", help="Check if passphrase exists")

    # Delete passphrase
    subparsers.add_parser("delete", help="Delete passphrase")

    args = parser.parse_args()

    try:
        keychain = KeychainManager()

        if args.command == "check":
            if keychain.is_available():
                print("macOS Keychain is available")
            else:
                print("macOS Keychain is NOT available")

        elif args.command == "store":
            keychain.store_passphrase(args.passphrase)
            print("Passphrase stored successfully")

        elif args.command == "get":
            passphrase = keychain.get_passphrase()
            if passphrase:
                print(f"Passphrase: {passphrase}")
            else:
                print("No passphrase found")

        elif args.command == "has":
            if keychain.has_passphrase():
                print("Passphrase exists in Keychain")
            else:
                print("No passphrase in Keychain")

        elif args.command == "delete":
            keychain.delete_passphrase()
            print("Passphrase deleted")

        else:
            parser.print_help()

    except KeychainError as e:
        print(f"Error: {e}")
        exit(1)
