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

# Characters that cannot be represented on a single `security -i` command
# line at all (it is a line-oriented reader: a raw newline/CR ends the
# command early, and a NUL cannot round-trip through a text pipe). Verified
# empirically: an embedded newline splits the fed command into two lines,
# the add fails cleanly (nonzero exit, no item written), and nothing else
# in this module can make that safe -- so it is rejected up front instead
# of being attempted. Every other character tested (spaces, `"`, `\`, `$`,
# backtick, `'`, a leading `-`, empty string, non-ASCII) round-trips
# correctly through _quote_for_security_stdin below.
_UNSAFE_SECRET_CHARS = ("\n", "\r", "\x00")

# `security -i` reads at most ~4095 bytes per input line (MEASURED, PR #905
# review). A longer line is NOT rejected: the first chunk runs as a command
# with its open quote accepted -- storing a TRUNCATED value -- and the tail
# runs as further `security` commands, with the exit status taken from the
# last chunk. The whole encoded command line is therefore capped well below
# that limit and refused before `security` is ever invoked, so no truncated
# write happens and the already-exists retry (which deletes first) is never
# reached for an over-long value.
_MAX_SECURITY_COMMAND_BYTES = 4000


class KeychainError(Exception):
    """Raised when a keychain operation fails."""
    pass


class KeychainNotAvailableError(KeychainError):
    """Raised when keychain is not available (non-macOS)."""
    pass


def _reject_unsafe_secret_chars(value: str) -> None:
    """
    Refuse a passphrase that cannot be safely represented on a single
    `security -i` command line, with a fixed message that never includes
    the value itself.
    """
    if any(ch in value for ch in _UNSAFE_SECRET_CHARS):
        raise KeychainError(
            "Passphrase contains characters (newline, carriage return, or "
            "NUL) that cannot be safely stored via this keychain channel"
        )


def _quote_for_security_stdin(value: str) -> str:
    """
    Quote a value for embedding in a `security -i` command line.

    `security -i` reads commands from stdin and tokenizes each line with a
    simple shell-like reader: an unquoted run of characters is one token,
    and inside a double-quoted token the only two characters that need
    escaping are backslash and the double-quote itself. Verified
    empirically on this Mac against a throwaway keychain (never the real
    login keychain, never a real secret) -- round-tripped correctly:
    spaces, `"`, `\\`, `$`, backtick, `'`, punctuation, a leading `-`,
    the empty string, and non-ASCII/Unicode content. A raw newline/CR/NUL
    cannot be represented this way at all -- see _reject_unsafe_secret_chars,
    which every caller of this function runs first for secret values.
    """
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


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

        # Never put the passphrase on argv: `security add-generic-password
        # -w <value>` places <value> directly on the child process's
        # command line, which any other local process can read for the
        # life of the call (e.g. `ps -ef` / /proc). Reject anything that
        # cannot be safely carried over the replacement channel before
        # attempting it.
        _reject_unsafe_secret_chars(passphrase)

        return self._store_passphrase_once(passphrase, allow_retry=True)

    def _store_passphrase_once(self, passphrase: str, allow_retry: bool) -> bool:
        """
        Single attempt to store `passphrase` via `security -i`, the
        interactive command reader. The whole add-generic-password command
        -- passphrase included -- is written to the child's stdin instead
        of being passed as an argv element, so it never appears in argv for
        any other local process to observe.

        `allow_retry` bounds the "item already exists" recovery to exactly
        one retry (delete then a single non-recursive re-attempt), never
        unbounded recursion. In practice `-U` (update if exists) already
        makes a repeat add succeed in place -- verified empirically, a
        second `-U` add over an existing item returns 0 and updates the
        value with no "already exists" error -- so this path is defensive
        only, for an edge case (e.g. multiple matching items) where `-U`
        alone doesn't cover it.
        """
        cmd = (
            "add-generic-password "
            f"-a {_quote_for_security_stdin(self.account)} "
            f"-s {_quote_for_security_stdin(self.service)} "
            f"-w {_quote_for_security_stdin(passphrase)} "
            "-U\n"  # Update if exists
        )

        # Checked on every attempt, BEFORE subprocess.run -- so the retry
        # path's delete_passphrase() can never run for a value that cannot
        # be written whole.
        if len(cmd.encode("utf-8")) > _MAX_SECURITY_COMMAND_BYTES:
            raise KeychainError(
                "Passphrase is too long to store safely via this keychain channel"
            )

        try:
            result = subprocess.run(
                ["security", "-i"],
                input=cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except Exception as e:
            # Never format the exception itself into the message -- on some
            # platforms an exception like this can carry the failed
            # command's argv (e.g. FileNotFoundError from a missing
            # executable). The passphrase is never on argv here, but keep
            # this fixed regardless so no future subprocess call on this
            # path can leak one.
            raise KeychainError(f"Keychain error: {type(e).__name__}")

        if result.returncode == 0:
            logger.info(f"Passphrase stored in Keychain (service: {self.service})")
            return True

        # Never surface `security`'s raw stderr in a raised message or log:
        # it echoes back the command's structure (service/account/flags,
        # not proven secret-bearing here, but not worth trusting either).
        # Classify into fixed, sanitized failure-class strings instead.
        stderr_text = (result.stderr or "").lower()

        if "-25308" in stderr_text or "user interaction is not allowed" in stderr_text:
            raise KeychainError(
                "Keychain is locked or unavailable for interaction; "
                "unlock it and try again"
            )

        if allow_retry and ("already exists" in stderr_text or "-25299" in stderr_text):
            self.delete_passphrase()
            return self._store_passphrase_once(passphrase, allow_retry=False)

        raise KeychainError(
            f"Failed to store passphrase (security exited with status {result.returncode})"
        )

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
                # `-w` prints the secret to this process's stdout by
                # design (that's how retrieval works) -- it must never be
                # echoed back into an exception or log message, only
                # returned to the caller, as below.
                return result.stdout.strip()
            elif "could not be found" in result.stderr.lower():
                return None
            else:
                # Fixed, sanitized message -- never format `security`'s raw
                # stderr here. This query never sends the secret, so stderr
                # isn't proven secret-bearing, but there's no reason to
                # trust it either.
                raise KeychainError(
                    f"Failed to retrieve passphrase (security exited with status {result.returncode})"
                )

        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except KeychainError:
            raise
        except Exception as e:
            raise KeychainError(f"Keychain error: {type(e).__name__}")

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
                raise KeychainError(
                    f"Failed to delete passphrase (security exited with status {result.returncode})"
                )

        except subprocess.TimeoutExpired:
            raise KeychainError("Keychain operation timed out")
        except KeychainError:
            raise
        except Exception as e:
            raise KeychainError(f"Keychain error: {type(e).__name__}")


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

    # Store passphrase. The passphrase is deliberately NOT a positional
    # argument (XACA-1224): argv is visible to every local process via `ps`.
    # It is read from the terminal without echo, or from stdin when piped.
    subparsers.add_parser(
        "store",
        help="Store passphrase (prompted without echo, or read from stdin when piped)",
    )

    # Get passphrase
    get_parser = subparsers.add_parser(
        "get", help="Check for the stored passphrase (--show prints it)"
    )
    get_parser.add_argument(
        "--show",
        action="store_true",
        help="Print the passphrase itself to stdout",
    )

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
            import getpass
            import sys

            if sys.stdin.isatty():
                passphrase = getpass.getpass("Passphrase: ")
            else:
                passphrase = sys.stdin.readline().rstrip("\r\n")
            if not passphrase:
                print("Error: no passphrase provided")
                exit(1)
            keychain.store_passphrase(passphrase)
            print("Passphrase stored successfully")

        elif args.command == "get":
            passphrase = keychain.get_passphrase()
            if not passphrase:
                print("No passphrase found")
            elif args.show:
                print(passphrase)
            else:
                print("Passphrase found (use --show to print it)")

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
