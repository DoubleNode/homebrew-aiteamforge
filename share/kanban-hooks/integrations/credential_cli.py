#!/usr/bin/env python3
"""
Command-line interface for credential store operations.

Designed to be called by Node.js server for credential API endpoints.
All output is JSON for easy parsing.

Usage:
    credential_cli.py get <integration_id>     # Returns credential (for internal use only)
    credential_cli.py set <integration_id>     # Reads JSON from stdin
    credential_cli.py delete <integration_id>  # Delete credential
    credential_cli.py verify <integration_id>  # Check if exists (no values returned)
    credential_cli.py list                     # List all integration IDs
    credential_cli.py info <integration_id>    # Get non-sensitive info
"""

import os
import sys
import json

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from integrations.credential_store import get_credential_store, CredentialStoreError


def output(success, data=None, error=None):
    """Output JSON response and exit."""
    result = {"success": success}
    if data is not None:
        result["data"] = data
    if error is not None:
        result["error"] = error
    print(json.dumps(result))
    sys.exit(0 if success else 1)


def cmd_get(integration_id):
    """Get credential (for internal use - returns sensitive data)."""
    try:
        store = get_credential_store()
        cred = store.get_credential(integration_id)
        if cred:
            output(True, cred)
        else:
            output(False, error=f"Credential not found: {integration_id}")
    except CredentialStoreError as e:
        output(False, error=str(e))


def cmd_set(integration_id):
    """Set credential from JSON stdin."""
    try:
        # Read JSON from stdin
        input_data = sys.stdin.read()
        if not input_data:
            output(False, error="No input provided")
            return

        data = json.loads(input_data)
        cred_type = data.get("type")
        if not cred_type:
            output(False, error="Missing 'type' field")
            return

        # Extract credential fields
        fields = {k: v for k, v in data.items() if k != "type"}

        store = get_credential_store()
        success = store.set_credential(integration_id, cred_type, **fields)

        if success:
            output(True, {"message": f"Credential stored: {integration_id}"})
        else:
            output(False, error="Failed to store credential")

    except json.JSONDecodeError as e:
        output(False, error=f"Invalid JSON: {e}")
    except CredentialStoreError as e:
        output(False, error=str(e))


def cmd_delete(integration_id):
    """Delete credential."""
    try:
        store = get_credential_store()

        if not store.has_credential(integration_id):
            output(False, error=f"Credential not found: {integration_id}")
            return

        success = store.delete_credential(integration_id)
        if success:
            output(True, {"message": f"Credential deleted: {integration_id}"})
        else:
            output(False, error="Failed to delete credential")

    except CredentialStoreError as e:
        output(False, error=str(e))


def cmd_verify(integration_id):
    """Verify credential exists (no values returned)."""
    try:
        store = get_credential_store()
        exists = store.has_credential(integration_id)
        output(True, {"exists": exists, "integration_id": integration_id})
    except CredentialStoreError as e:
        output(False, error=str(e))


def cmd_list():
    """List all integration IDs."""
    try:
        store = get_credential_store()
        integrations = store.list_integrations()
        output(True, {"integrations": integrations})
    except CredentialStoreError as e:
        output(False, error=str(e))


def cmd_info(integration_id):
    """Get non-sensitive info about credential."""
    try:
        store = get_credential_store()
        info = store.get_integration_info(integration_id)
        if info:
            output(True, info)
        else:
            output(False, error=f"Credential not found: {integration_id}")
    except CredentialStoreError as e:
        output(False, error=str(e))


def main():
    if len(sys.argv) < 2:
        output(False, error="Usage: credential_cli.py <command> [args]")
        return

    command = sys.argv[1]

    if command == "list":
        cmd_list()
    elif command in ("get", "set", "delete", "verify", "info"):
        if len(sys.argv) < 3:
            output(False, error=f"Missing integration_id for '{command}' command")
            return
        integration_id = sys.argv[2]

        if command == "get":
            cmd_get(integration_id)
        elif command == "set":
            cmd_set(integration_id)
        elif command == "delete":
            cmd_delete(integration_id)
        elif command == "verify":
            cmd_verify(integration_id)
        elif command == "info":
            cmd_info(integration_id)
    else:
        output(False, error=f"Unknown command: {command}")


if __name__ == "__main__":
    main()
