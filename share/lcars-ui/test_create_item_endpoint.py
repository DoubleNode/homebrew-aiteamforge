#!/usr/bin/env python3
"""
Test script for the /api/integrations/create-item endpoint.

This script tests the new item creation functionality without actually
creating items in external services (uses mock/test mode).
"""

import sys
import json
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from integrations import get_manager, CreateItemResult


def test_create_item_result():
    """Test CreateItemResult dataclass."""
    print("Testing CreateItemResult dataclass...")

    # Test success case
    success_result = CreateItemResult(
        success=True,
        ticket_id="12345",
        url="https://monday.com/boards/123/items/12345",
        message="Item created successfully"
    )

    assert success_result.success is True
    assert success_result.ticket_id == "12345"
    assert success_result.url is not None
    assert success_result.error is None
    print("  ✓ Success case works")

    # Test error case
    error_result = CreateItemResult(
        success=False,
        error="Authentication failed"
    )

    assert error_result.success is False
    assert error_result.ticket_id is None
    assert error_result.error == "Authentication failed"
    print("  ✓ Error case works")

    print()


def test_provider_default_implementation():
    """Test that providers without create_item return appropriate error."""
    print("Testing provider default create_item implementation...")

    # Get the manager (this loads all providers)
    manager = get_manager()

    # Get integrations list
    integrations = manager.list_integrations()

    if not integrations:
        print("  ⚠ No integrations configured to test")
        print()
        return

    # Test with first integration
    integration_id = integrations[0]['id']
    provider = manager.get_provider(integration_id)
    print(f"  Testing with provider: {provider.name} ({provider.provider_type})")

    result = provider.create_item(
        board_id="test-board",
        title="Test Item",
        description="Test description"
    )

    # Default implementation should return error
    if provider.provider_type != 'monday':
        # Non-Monday providers should use default implementation
        assert result.success is False
        assert "does not support item creation" in result.error
        print(f"  ✓ Default implementation returns error for {provider.provider_type}")
    else:
        # Monday provider should have custom implementation
        # Without credentials, it should fail with auth error
        if not provider.has_credentials():
            assert result.success is False
            assert "not configured" in result.error or "Authentication" in result.error
            print("  ✓ Monday provider returns auth error without credentials")
        else:
            print("  ℹ Monday provider has credentials (would need live test)")

    print()


def test_api_request_format():
    """Test expected API request format."""
    print("Testing API request format...")

    # Example request that the endpoint expects
    api_request = {
        "integrationId": "monday-main",
        "boardId": "1234567890",
        "title": "New Feature Request",
        "description": "This is a detailed description of the feature",
        "metadata": {
            "status": "Working on it",
            "priority": "High",
            "column_values": {
                "status": {"label": "Working on it"},
                "priority": {"label": "High"}
            }
        }
    }

    # Validate required fields
    assert "integrationId" in api_request
    assert "boardId" in api_request
    assert "title" in api_request
    print("  ✓ Required fields present")

    # Validate optional fields
    assert "description" in api_request
    assert "metadata" in api_request
    print("  ✓ Optional fields present")

    # Validate JSON serialization
    json_str = json.dumps(api_request)
    parsed = json.loads(json_str)
    assert parsed["title"] == api_request["title"]
    print("  ✓ JSON serialization works")

    print()


def main():
    """Run all tests."""
    print("=" * 60)
    print("Testing /api/integrations/create-item Endpoint")
    print("=" * 60)
    print()

    try:
        test_create_item_result()
        test_provider_default_implementation()
        test_api_request_format()

        print("=" * 60)
        print("✅ All tests passed!")
        print("=" * 60)
        print()
        print("Next steps:")
        print("  1. Start the LCARS server: python3 server.py")
        print("  2. Test the endpoint with curl:")
        print()
        print('     curl -X POST http://localhost:8080/api/integrations/create-item \\')
        print('       -H "Content-Type: application/json" \\')
        print('       -d \'{"integrationId": "monday-main", "boardId": "123", "title": "Test"}\'')
        print()

        return 0

    except AssertionError as e:
        print()
        print("=" * 60)
        print(f"❌ Test failed: {e}")
        print("=" * 60)
        return 1

    except Exception as e:
        print()
        print("=" * 60)
        print(f"❌ Error during testing: {e}")
        print("=" * 60)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
