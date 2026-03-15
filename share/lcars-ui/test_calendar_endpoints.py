#!/usr/bin/env python3
"""
Quick test to verify calendar sync API endpoints are accessible.
This doesn't test actual functionality - just that endpoints exist and respond.
"""

import http.client
import json
import sys

def test_endpoint(method, path, data=None):
    """Test a single endpoint"""
    try:
        conn = http.client.HTTPConnection("localhost", 8080)

        headers = {'Content-Type': 'application/json'}
        body = json.dumps(data) if data else None

        conn.request(method, path, body=body, headers=headers)
        response = conn.getresponse()
        response_data = response.read().decode()

        status_icon = "✓" if response.status < 400 else "✗"
        print(f"{status_icon} {method:6} {path:45} -> {response.status}")

        if response.status >= 400:
            print(f"   Error: {response_data[:100]}")

        conn.close()
        return response.status < 400

    except Exception as e:
        print(f"✗ {method:6} {path:45} -> ERROR: {e}")
        return False

def main():
    print("Testing Calendar Sync API Endpoints")
    print("=" * 80)
    print()
    print("Prerequisites: Server must be running on localhost:8080")
    print()

    tests = [
        # GET endpoints
        ("GET", "/api/calendar/config"),
        ("GET", "/api/calendar/sync/status"),
        ("GET", "/api/calendar/events"),

        # POST endpoints (with minimal data)
        ("POST", "/api/calendar/config", {"config": {"syncEnabled": False}}),
        ("POST", "/api/calendar/connect/apple", {}),
        ("POST", "/api/calendar/connect/google", {}),
        ("POST", "/api/calendar/disconnect/apple", {}),
        ("POST", "/api/calendar/sync/trigger", {}),
    ]

    passed = 0
    failed = 0

    for test in tests:
        method = test[0]
        path = test[1]
        data = test[2] if len(test) > 2 else None

        if test_endpoint(method, path, data):
            passed += 1
        else:
            failed += 1

    print()
    print("=" * 80)
    print(f"Results: {passed} passed, {failed} failed")

    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
