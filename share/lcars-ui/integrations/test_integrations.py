#!/usr/bin/env python3

#
#  test_integrations.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Integration Tests for LCARS Multi-Platform Integration System

Run with: python3 -m pytest test_integrations.py -v
Or standalone: python3 test_integrations.py
"""

import unittest
import os
import sys
import json
import tempfile
from pathlib import Path

# Add parent directory for imports when running standalone
sys.path.insert(0, str(Path(__file__).parent.parent))

# Import integration modules using the package
from integrations.provider import IntegrationConfig, IntegrationProvider
from integrations.manager import IntegrationManager
from integrations.ticket_links import (
    TicketLink,
    get_ticket_links,
    add_ticket_link,
    remove_ticket_link,
    migrate_jira_id_to_ticket_links,
    has_ticket_link,
    get_ticket_links_summary
)
from integrations.jira_provider import JiraProvider
from integrations.monday_provider import MondayProvider
from integrations.sync_service import (
    SyncService,
    SyncDirection,
    SyncStatus,
    SyncResult,
    ItemSyncResult,
    TicketLinkConfig
)


class TestIntegrationConfig(unittest.TestCase):
    """Test IntegrationConfig dataclass."""

    def test_from_dict_basic(self):
        """Test creating config from dictionary."""
        data = {
            'id': 'test-jira',
            'type': 'jira',
            'name': 'Test JIRA',
            'enabled': True,
            'baseUrl': 'https://test.atlassian.net',
            'browseUrl': 'https://test.atlassian.net/browse/{ticketId}'
        }
        config = IntegrationConfig.from_dict(data)

        self.assertEqual(config.id, 'test-jira')
        self.assertEqual(config.type, 'jira')
        self.assertEqual(config.name, 'Test JIRA')
        self.assertTrue(config.enabled)
        self.assertEqual(config.base_url, 'https://test.atlassian.net')

    def test_to_dict(self):
        """Test converting config to dictionary."""
        config = IntegrationConfig(
            id='test-id',
            type='jira',
            name='Test',
            base_url='https://example.com'
        )
        data = config.to_dict()

        self.assertEqual(data['id'], 'test-id')
        self.assertEqual(data['type'], 'jira')


class TestTicketLink(unittest.TestCase):
    """Test TicketLink dataclass."""

    def test_create_ticket_link(self):
        """Test creating a ticket link."""
        link = TicketLink(
            integrationId='jira-mainevent',
            ticketId='ME-123'
        )

        self.assertEqual(link.integrationId, 'jira-mainevent')
        self.assertEqual(link.ticketId, 'ME-123')
        self.assertIsNotNone(link.linkedAt)

    def test_from_dict(self):
        """Test creating ticket link from dictionary."""
        data = {
            'integrationId': 'jira-mainevent',
            'ticketId': 'ME-456',
            'summary': 'Test ticket',
            'status': 'Open'
        }
        link = TicketLink.from_dict(data)

        self.assertEqual(link.ticketId, 'ME-456')
        self.assertEqual(link.summary, 'Test ticket')

    def test_to_dict(self):
        """Test converting to dictionary."""
        link = TicketLink(
            integrationId='jira-mainevent',
            ticketId='ME-789',
            summary='Test'
        )
        data = link.to_dict()

        self.assertEqual(data['ticketId'], 'ME-789')
        self.assertIn('linkedAt', data)


class TestTicketLinkHelpers(unittest.TestCase):
    """Test ticket link helper functions."""

    def test_get_ticket_links_from_new_format(self):
        """Test getting links from ticketLinks array."""
        item = {
            'id': 'TEST-001',
            'ticketLinks': [
                {'integrationId': 'jira', 'ticketId': 'ME-123'},
                {'integrationId': 'github', 'ticketId': 'lcars#42'}
            ]
        }
        links = get_ticket_links(item)

        self.assertEqual(len(links), 2)
        self.assertEqual(links[0].ticketId, 'ME-123')
        self.assertEqual(links[1].ticketId, 'lcars#42')

    def test_get_ticket_links_from_legacy_jiraId(self):
        """Test getting links from legacy jiraId field."""
        item = {
            'id': 'TEST-002',
            'jiraId': 'ME-456'
        }
        links = get_ticket_links(item)

        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].ticketId, 'ME-456')

    def test_get_ticket_links_from_legacy_jiraKey(self):
        """Test getting links from legacy jiraKey field."""
        item = {
            'id': 'TEST-003',
            'jiraKey': 'ME-789'
        }
        links = get_ticket_links(item)

        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].ticketId, 'ME-789')

    def test_add_ticket_link(self):
        """Test adding a ticket link."""
        item = {'id': 'TEST-004'}
        link = TicketLink(integrationId='jira', ticketId='ME-111')

        add_ticket_link(item, link)

        self.assertIn('ticketLinks', item)
        self.assertEqual(len(item['ticketLinks']), 1)
        self.assertEqual(item['ticketLinks'][0]['ticketId'], 'ME-111')

    def test_add_ticket_link_no_duplicate(self):
        """Test that duplicates are updated, not added."""
        item = {
            'id': 'TEST-005',
            'ticketLinks': [
                {'integrationId': 'jira', 'ticketId': 'ME-222'}
            ]
        }
        link = TicketLink(
            integrationId='jira',
            ticketId='ME-222',
            summary='Updated summary'
        )

        add_ticket_link(item, link)

        self.assertEqual(len(item['ticketLinks']), 1)
        self.assertEqual(item['ticketLinks'][0]['summary'], 'Updated summary')

    def test_remove_ticket_link(self):
        """Test removing a ticket link."""
        item = {
            'id': 'TEST-006',
            'ticketLinks': [
                {'integrationId': 'jira', 'ticketId': 'ME-333'},
                {'integrationId': 'github', 'ticketId': 'issue#1'}
            ]
        }

        remove_ticket_link(item, 'jira', 'ME-333')

        self.assertEqual(len(item['ticketLinks']), 1)
        self.assertEqual(item['ticketLinks'][0]['ticketId'], 'issue#1')

    def test_has_ticket_link(self):
        """Test checking for ticket links."""
        item = {
            'ticketLinks': [
                {'integrationId': 'jira', 'ticketId': 'ME-444'}
            ]
        }

        self.assertTrue(has_ticket_link(item))
        self.assertTrue(has_ticket_link(item, integration_id='jira'))
        self.assertTrue(has_ticket_link(item, ticket_id='ME-444'))
        self.assertFalse(has_ticket_link(item, integration_id='github'))

    def test_migrate_jira_id_to_ticket_links(self):
        """Test migrating jiraId to ticketLinks."""
        item = {
            'id': 'TEST-007',
            'jiraId': 'ME-555'
        }

        migrate_jira_id_to_ticket_links(item)

        self.assertIn('ticketLinks', item)
        self.assertEqual(len(item['ticketLinks']), 1)
        self.assertEqual(item['ticketLinks'][0]['ticketId'], 'ME-555')
        # Legacy field should be preserved by default
        self.assertIn('jiraId', item)

    def test_migrate_removes_legacy_when_requested(self):
        """Test migration removes legacy fields when requested."""
        item = {
            'id': 'TEST-008',
            'jiraId': 'ME-666'
        }

        migrate_jira_id_to_ticket_links(item, preserve_legacy=False)

        self.assertIn('ticketLinks', item)
        self.assertNotIn('jiraId', item)

    def test_get_ticket_links_summary(self):
        """Test getting summary string."""
        item = {
            'ticketLinks': [
                {'integrationId': 'jira', 'ticketId': 'ME-777'},
                {'integrationId': 'github', 'ticketId': 'issue#99'}
            ]
        }
        summary = get_ticket_links_summary(item)

        self.assertEqual(summary, 'ME-777, issue#99')


class TestJiraProvider(unittest.TestCase):
    """Test JiraProvider functionality."""

    def setUp(self):
        """Set up test provider."""
        config = IntegrationConfig(
            id='test-jira',
            type='jira',
            name='Test JIRA',
            base_url='https://test.atlassian.net',
            browse_url='https://test.atlassian.net/browse/{ticketId}',
            api_version='3',
            ticket_pattern=r'^[A-Z]{1,10}-[0-9]+$',
            auth_config={'type': 'basic', 'userEnvVar': 'TEST_JIRA_USER', 'tokenEnvVar': 'TEST_JIRA_TOKEN'}
        )
        self.provider = JiraProvider(config)

    def test_validate_ticket_format_valid(self):
        """Test valid ticket formats."""
        self.assertTrue(self.provider.validate_ticket_format('ME-123'))
        self.assertTrue(self.provider.validate_ticket_format('ABC-1'))
        self.assertTrue(self.provider.validate_ticket_format('LONGPROJ-99999'))

    def test_validate_ticket_format_invalid(self):
        """Test invalid ticket formats."""
        self.assertFalse(self.provider.validate_ticket_format('me-123'))  # lowercase
        self.assertFalse(self.provider.validate_ticket_format('123-ABC'))  # reversed
        self.assertFalse(self.provider.validate_ticket_format('NOHYPHEN'))  # no hyphen
        self.assertFalse(self.provider.validate_ticket_format(''))  # empty

    def test_get_ticket_url(self):
        """Test URL generation."""
        url = self.provider.get_ticket_url('ME-123')
        self.assertEqual(url, 'https://test.atlassian.net/browse/ME-123')

    def test_has_credentials_false_without_env(self):
        """Test credentials check without env vars."""
        # Clear any test env vars
        os.environ.pop('TEST_JIRA_USER', None)
        os.environ.pop('TEST_JIRA_TOKEN', None)

        # Reset cached credentials
        self.provider._credentials_cached = None

        self.assertFalse(self.provider.has_credentials())


class TestMondayProvider(unittest.TestCase):
    """Test MondayProvider functionality."""

    def setUp(self):
        """Set up test provider."""
        config = IntegrationConfig(
            id='monday-test',
            type='monday',
            name='Test Monday',
            base_url='https://api.monday.com/v2',
            browse_url='https://view.monday.com/pulse/{ticketId}',
            ticket_pattern=r'^(MON-)?[0-9]+$',
            auth_config={'type': 'bearer', 'tokenEnvVar': 'TEST_MONDAY_TOKEN'}
        )
        self.provider = MondayProvider(config)

    def test_parse_item_id_numeric(self):
        """Test parsing numeric item ID."""
        self.assertEqual(self.provider._parse_item_id('1234567890'), 1234567890)

    def test_parse_item_id_prefixed(self):
        """Test parsing MON-prefixed item ID."""
        self.assertEqual(self.provider._parse_item_id('MON-1234567890'), 1234567890)

    def test_parse_item_id_invalid(self):
        """Test parsing invalid item ID."""
        self.assertIsNone(self.provider._parse_item_id('invalid'))
        self.assertIsNone(self.provider._parse_item_id(''))

    def test_get_ticket_url(self):
        """Test URL generation."""
        url = self.provider.get_ticket_url('1234567890')
        self.assertEqual(url, 'https://view.monday.com/pulse/1234567890')

    def test_get_ticket_url_strips_prefix(self):
        """Test URL generation strips MON- prefix."""
        url = self.provider.get_ticket_url('MON-1234567890')
        self.assertEqual(url, 'https://view.monday.com/pulse/1234567890')

    def test_has_credentials_false_without_env(self):
        """Test credentials check without env vars."""
        os.environ.pop('TEST_MONDAY_TOKEN', None)
        self.provider._credentials_cached = None
        self.assertFalse(self.provider.has_credentials())

    def test_validate_ticket_format_numeric(self):
        """Test validating numeric ticket format."""
        self.assertTrue(self.provider.validate_ticket_format('1234567890'))

    def test_validate_ticket_format_prefixed(self):
        """Test validating MON-prefixed ticket format."""
        self.assertTrue(self.provider.validate_ticket_format('MON-1234567890'))

    def test_validate_ticket_format_invalid(self):
        """Test validating invalid ticket format."""
        # Provider pattern allows MON- prefix or just numbers
        self.assertFalse(self.provider.validate_ticket_format('INVALID'))
        self.assertFalse(self.provider.validate_ticket_format('ABC-123'))


class TestMondayProviderStatusMethods(unittest.TestCase):
    """Test MondayProvider status column detection methods."""

    def setUp(self):
        """Set up test provider."""
        config = IntegrationConfig(
            id='monday-status-test',
            type='monday',
            name='Monday Status Test',
            base_url='https://api.monday.com/v2',
            browse_url='https://view.monday.com/pulse/{ticketId}',
            auth_config={'type': 'bearer', 'tokenEnvVar': 'TEST_MONDAY_TOKEN'}
        )
        self.provider = MondayProvider(config)

    def test_sync_status_returns_dict(self):
        """Test that sync_status returns properly structured dict."""
        # Without credentials, should return error dict
        os.environ.pop('TEST_MONDAY_TOKEN', None)
        self.provider._credentials_cached = None

        # Can't test actual sync without credentials, but verify method exists
        self.assertTrue(hasattr(self.provider, 'sync_status'))
        self.assertTrue(callable(self.provider.sync_status))

    def test_get_board_columns_exists(self):
        """Test that get_board_columns method exists."""
        self.assertTrue(hasattr(self.provider, 'get_board_columns'))
        self.assertTrue(callable(self.provider.get_board_columns))

    def test_detect_status_columns_exists(self):
        """Test that detect_status_columns method exists."""
        self.assertTrue(hasattr(self.provider, 'detect_status_columns'))
        self.assertTrue(callable(self.provider.detect_status_columns))

    def test_get_status_column_for_item_exists(self):
        """Test that get_status_column_for_item method exists."""
        self.assertTrue(hasattr(self.provider, 'get_status_column_for_item'))
        self.assertTrue(callable(self.provider.get_status_column_for_item))

    def test_update_item_status_exists(self):
        """Test that update_item_status method exists."""
        self.assertTrue(hasattr(self.provider, 'update_item_status'))
        self.assertTrue(callable(self.provider.update_item_status))

    def test_get_boards_exists(self):
        """Test that get_boards method exists."""
        self.assertTrue(hasattr(self.provider, 'get_boards'))
        self.assertTrue(callable(self.provider.get_boards))

    def test_get_item_exists(self):
        """Test that get_item method exists."""
        self.assertTrue(hasattr(self.provider, 'get_item'))
        self.assertTrue(callable(self.provider.get_item))


class TestSyncService(unittest.TestCase):
    """Test SyncService functionality."""

    def setUp(self):
        """Set up test sync service."""
        self.temp_dir = tempfile.mkdtemp()
        self.config_path = Path(self.temp_dir) / 'integrations.json'

        # Create minimal config
        config_data = {
            'integrations': [
                {
                    'id': 'jira-test',
                    'type': 'jira',
                    'name': 'Test JIRA',
                    'enabled': True,
                    'baseUrl': 'https://test.atlassian.net',
                    'browseUrl': 'https://test.atlassian.net/browse/{ticketId}'
                }
            ]
        }

        with open(self.config_path, 'w') as f:
            json.dump(config_data, f)

        self.manager = IntegrationManager(str(self.config_path))
        self.manager.ensure_loaded()
        self.sync_service = SyncService(self.manager)

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_sync_status_values(self):
        """Test SyncStatus enum values."""
        self.assertEqual(SyncStatus.SUCCESS.value, 'success')
        self.assertEqual(SyncStatus.SKIPPED.value, 'skipped')
        self.assertEqual(SyncStatus.ERROR.value, 'error')

    def test_sync_direction_values(self):
        """Test SyncDirection enum values."""
        self.assertEqual(SyncDirection.EXTERNAL_TO_KANBAN.value, 'external_to_kanban')
        self.assertEqual(SyncDirection.KANBAN_TO_EXTERNAL.value, 'kanban_to_external')
        self.assertEqual(SyncDirection.BIDIRECTIONAL.value, 'bidirectional')

    def test_sync_result_creation(self):
        """Test creating a SyncResult."""
        result = SyncResult(
            integration_id='jira-test',
            ticket_id='ME-123',
            status=SyncStatus.SUCCESS,
            message='Synced successfully'
        )
        self.assertEqual(result.integration_id, 'jira-test')
        self.assertEqual(result.ticket_id, 'ME-123')
        self.assertEqual(result.status, SyncStatus.SUCCESS)

    def test_item_sync_result_counters(self):
        """Test ItemSyncResult counter properties."""
        result = ItemSyncResult(item_id='TEST-001')
        result.link_results = [
            SyncResult('jira', 'ME-1', SyncStatus.SUCCESS, 'ok'),
            SyncResult('jira', 'ME-2', SyncStatus.ERROR, 'fail', error='test'),
            SyncResult('monday', 'MON-1', SyncStatus.SKIPPED, 'skip')
        ]

        self.assertEqual(result.success_count, 1)
        self.assertEqual(result.error_count, 1)
        self.assertEqual(result.skipped_count, 1)

    def test_sync_item_no_links(self):
        """Test syncing item with no ticket links."""
        item = {'id': 'TEST-001', 'title': 'Test Item'}
        result = self.sync_service.sync_item(item)

        self.assertEqual(result.item_id, 'TEST-001')
        self.assertEqual(len(result.link_results), 0)

    def test_sync_item_with_disabled_link(self):
        """Test syncing item with syncEnabled=false."""
        item = {
            'id': 'TEST-002',
            'title': 'Test Item',
            'ticketLinks': [
                {
                    'integrationId': 'jira-test',
                    'ticketId': 'ME-123',
                    'syncEnabled': False
                }
            ]
        }
        result = self.sync_service.sync_item(item)

        self.assertEqual(len(result.link_results), 1)
        self.assertEqual(result.link_results[0].status, SyncStatus.SKIPPED)
        self.assertEqual(result.skipped_count, 1)

    def test_sync_item_legacy_jiraId(self):
        """Test syncing item with legacy jiraId field."""
        item = {
            'id': 'TEST-003',
            'title': 'Legacy Item',
            'jiraId': 'ME-456'
        }
        result = self.sync_service.sync_item(item)

        # Should process the legacy jiraId as a link
        self.assertEqual(len(result.link_results), 1)

    def test_configure_status_mapping(self):
        """Test configuring status mapping."""
        self.sync_service.configure_status_mapping('jira-test', {
            'To Do': 'backlog',
            'In Progress': 'in_progress',
            'Done': 'completed'
        })

        self.assertEqual(
            self.sync_service._get_kanban_status('jira-test', 'In Progress'),
            'in_progress'
        )
        self.assertIsNone(
            self.sync_service._get_kanban_status('jira-test', 'Unknown')
        )

    def test_ticket_link_config_from_ticket_link(self):
        """Test creating TicketLinkConfig from TicketLink."""
        link = TicketLink(
            integrationId='jira-test',
            ticketId='ME-789'
        )
        link_data = {
            'integrationId': 'jira-test',
            'ticketId': 'ME-789',
            'syncEnabled': True,
            'syncDirection': 'bidirectional'
        }

        config = TicketLinkConfig.from_ticket_link(link, link_data)

        self.assertEqual(config.integration_id, 'jira-test')
        self.assertEqual(config.ticket_id, 'ME-789')
        self.assertTrue(config.sync_enabled)
        self.assertEqual(config.sync_direction, SyncDirection.BIDIRECTIONAL)


class TestMultiProviderScenarios(unittest.TestCase):
    """Test scenarios involving multiple integration providers."""

    def setUp(self):
        """Set up multi-provider manager."""
        self.temp_dir = tempfile.mkdtemp()
        self.config_path = Path(self.temp_dir) / 'integrations.json'

        config_data = {
            'integrations': [
                {
                    'id': 'jira-me',
                    'type': 'jira',
                    'name': 'Main Event JIRA',
                    'enabled': True,
                    'baseUrl': 'https://mainevent.atlassian.net',
                    'browseUrl': 'https://mainevent.atlassian.net/browse/{ticketId}',
                    'ticketPattern': '^[A-Z]{1,10}-[0-9]+$'
                },
                {
                    'id': 'monday-pm',
                    'type': 'monday',
                    'name': 'Monday PM Board',
                    'enabled': True,
                    'baseUrl': 'https://api.monday.com/v2',
                    'browseUrl': 'https://view.monday.com/pulse/{ticketId}'
                },
                {
                    'id': 'jira-disabled',
                    'type': 'jira',
                    'name': 'Disabled JIRA',
                    'enabled': False,
                    'baseUrl': 'https://disabled.atlassian.net',
                    'browseUrl': 'https://disabled.atlassian.net/browse/{ticketId}'
                }
            ]
        }

        with open(self.config_path, 'w') as f:
            json.dump(config_data, f)

        self.manager = IntegrationManager(str(self.config_path))
        self.manager.ensure_loaded()

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_multiple_providers_loaded(self):
        """Test that multiple providers are loaded."""
        providers = self.manager.get_all_providers()
        # Only enabled providers
        self.assertEqual(len(providers), 2)

    def test_get_provider_by_type(self):
        """Test getting providers by type."""
        jira_providers = [p for p in self.manager.get_all_providers() if p.config.type == 'jira']
        monday_providers = [p for p in self.manager.get_all_providers() if p.config.type == 'monday']

        self.assertEqual(len(jira_providers), 1)  # Only enabled one
        self.assertEqual(len(monday_providers), 1)

    def test_item_with_multiple_links(self):
        """Test item with links to multiple providers."""
        item = {
            'id': 'MULTI-001',
            'title': 'Multi-linked Item',
            'ticketLinks': [
                {
                    'integrationId': 'jira-me',
                    'ticketId': 'ME-123',
                    'syncEnabled': True
                },
                {
                    'integrationId': 'monday-pm',
                    'ticketId': 'MON-456789',
                    'syncEnabled': True
                }
            ]
        }

        links = get_ticket_links(item)
        self.assertEqual(len(links), 2)

        # Verify both types are represented
        integration_ids = {link.integrationId for link in links}
        self.assertIn('jira-me', integration_ids)
        self.assertIn('monday-pm', integration_ids)

    def test_sync_item_with_multiple_links(self):
        """Test syncing item with multiple provider links."""
        sync_service = SyncService(self.manager)

        item = {
            'id': 'MULTI-002',
            'title': 'Multi-linked Item',
            'ticketLinks': [
                {
                    'integrationId': 'jira-me',
                    'ticketId': 'ME-789',
                    'syncEnabled': True
                },
                {
                    'integrationId': 'monday-pm',
                    'ticketId': 'MON-123456',
                    'syncEnabled': False  # Disabled
                }
            ]
        }

        result = sync_service.sync_item(item)

        # Should have 2 link results
        self.assertEqual(len(result.link_results), 2)

        # One should be skipped (Monday disabled)
        skipped = [r for r in result.link_results if r.status == SyncStatus.SKIPPED]
        self.assertEqual(len(skipped), 1)
        self.assertEqual(skipped[0].integration_id, 'monday-pm')

    def test_list_integrations_api_format(self):
        """Test listing integrations returns correct API format."""
        integrations = self.manager.list_integrations()

        self.assertEqual(len(integrations), 2)

        # Check structure
        for integ in integrations:
            self.assertIn('id', integ)
            self.assertIn('type', integ)
            self.assertIn('name', integ)
            self.assertIn('enabled', integ)
            self.assertTrue(integ['enabled'])  # Only enabled ones

    def test_disabled_provider_not_in_get_all(self):
        """Test that disabled providers are not returned by get_all_providers."""
        all_providers = self.manager.get_all_providers()
        provider_ids = {p.id for p in all_providers}

        self.assertNotIn('jira-disabled', provider_ids)

    def test_get_disabled_provider_by_id_returns_none(self):
        """Test that getting disabled provider by ID returns None."""
        provider = self.manager.get_provider('jira-disabled')
        self.assertIsNone(provider)


class TestKanbanToExternalSync(unittest.TestCase):
    """Tests for the kanban -> external (outbound) sync direction.

    Strategy: register a single fake provider via IntegrationManager so the
    sync_ticket_link plumbing (credential check, verify call, direction dispatch)
    runs exactly as in production.  The fake provider controls what
    update_ticket returns so we can drive every outbound scenario without
    making real network calls.
    """

    # ---------- helpers --------------------------------------------------

    def _make_fake_provider_class(self, update_result, verify_result=None):
        """
        Return a fresh IntegrationProvider subclass that:
        - always has credentials
        - always verifies the ticket as found (summary='External Summary',
          status='In Progress') unless verify_result is overridden
        - returns update_result from update_ticket
        - records each update_ticket call in self.provider.update_calls
        """
        from integrations.provider import (
            IntegrationProvider, IntegrationConfig,
            SearchResult, VerifyResult, ConnectionTestResult,
            UpdateTicketResult,
        )

        _update_result = update_result
        _verify_result = verify_result or VerifyResult(
            valid=True,
            ticket_id='EXT-001',
            exists=True,
            summary='External Summary',
            status='In Progress',
            url='https://fake.example.com/EXT-001',
        )

        class FakeProvider(IntegrationProvider):
            def __init__(self, config):
                super().__init__(config)
                self.update_calls = []

            def has_credentials(self):
                return True

            def search(self, query, max_results=10):
                return SearchResult()

            def verify(self, ticket_id):
                return _verify_result

            def test_connection(self):
                return ConnectionTestResult(success=True, message='ok')

            def update_ticket(self, ticket_id, fields):
                self.update_calls.append({'ticket_id': ticket_id, 'fields': dict(fields)})
                return _update_result

        return FakeProvider

    def _make_manager_with_fake_provider(self, FakeProvider):
        """Create an IntegrationManager that returns FakeProvider for 'fake-int'."""
        config = IntegrationConfig(
            id='fake-int',
            type='fake',
            name='Fake Integration',
            base_url='https://fake.example.com',
            browse_url='https://fake.example.com/{ticketId}',
        )
        manager = IntegrationManager.__new__(IntegrationManager)
        manager._providers = {'fake-int': FakeProvider(config)}
        manager._loaded = True
        manager._config_path = None
        # Patch get_provider to read from our dict
        manager.get_provider = lambda pid: manager._providers.get(pid)
        return manager

    def _make_sync_service(self, update_result, verify_result=None):
        """End-to-end helper: build SyncService backed by a fake provider."""
        FakeProvider = self._make_fake_provider_class(update_result, verify_result)
        manager = self._make_manager_with_fake_provider(FakeProvider)
        svc = SyncService(manager)
        # Expose the fake provider instance for call inspection
        svc._fake_provider = manager._providers['fake-int']
        return svc

    def _make_link_data(self, **overrides):
        """Build a minimal link_data dict for 'fake-int' / 'EXT-001'."""
        base = {
            'integrationId': 'fake-int',
            'ticketId': 'EXT-001',
            'syncEnabled': True,
            'syncDirection': 'kanban_to_external',
        }
        base.update(overrides)
        return base

    # ---------- test 1: happy-path summary push --------------------------

    def test_kanban_to_external_summary_pushed_on_title_change(self):
        """Title differs from cached link summary → update_ticket called with
        summary field → pushed_summary in changes, link_data updated,
        lastSynced set, no syncError."""
        from integrations.provider import UpdateTicketResult

        update_result = UpdateTicketResult(
            success=True,
            updated_fields={'summary': 'New Kanban Title'},
            url='https://fake.example.com/EXT-001',
        )
        svc = self._make_sync_service(update_result)

        item = {'id': 'XACA-001', 'title': 'New Kanban Title', 'status': 'backlog'}
        link_data = self._make_link_data(summary='Old External Summary')

        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # Provider was called
        self.assertEqual(len(svc._fake_provider.update_calls), 1)
        call = svc._fake_provider.update_calls[0]
        self.assertEqual(call['ticket_id'], 'EXT-001')
        self.assertIn('summary', call['fields'])
        self.assertEqual(call['fields']['summary'], 'New Kanban Title')

        # Changes dict has pushed_summary
        self.assertIn('pushed_summary', result.changes)
        self.assertEqual(result.changes['pushed_summary'], 'New Kanban Title')

        # link_data cache updated
        self.assertEqual(link_data['summary'], 'New Kanban Title')
        self.assertIn('lastSynced', link_data)
        self.assertNotIn('syncError', link_data)

        self.assertEqual(result.status, SyncStatus.SUCCESS)

    # ---------- test 2: status push with reverse mapping -----------------

    def test_kanban_to_external_status_pushed_with_reverse_mapping(self):
        """Kanban status reverse-maps to external status → pushed as
        pushed_status in changes."""
        from integrations.provider import UpdateTicketResult

        update_result = UpdateTicketResult(
            success=True,
            updated_fields={'status': 'Done'},
        )
        svc = self._make_sync_service(update_result)
        svc.configure_status_mapping('fake-int', {
            'To Do': 'backlog',
            'In Progress': 'in_progress',
            'Done': 'completed',
        })

        # _get_external_status should invert the map
        ext_status = svc._get_external_status('fake-int', 'completed')
        self.assertEqual(ext_status, 'Done')

        item = {'id': 'XACA-002', 'title': 'Same Title', 'status': 'completed'}
        # Cached link summary matches item title → only status is different
        # Cached external status is 'To Do' → differs from mapped 'Done'
        link_data = self._make_link_data(summary='Same Title', status='To Do')

        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # Provider received status field
        self.assertEqual(len(svc._fake_provider.update_calls), 1)
        self.assertIn('status', svc._fake_provider.update_calls[0]['fields'])
        self.assertEqual(svc._fake_provider.update_calls[0]['fields']['status'], 'Done')

        # pushed_status in changes
        self.assertIn('pushed_status', result.changes)
        self.assertEqual(result.changes['pushed_status'], 'Done')

        self.assertEqual(result.status, SyncStatus.SUCCESS)

    # ---------- test 3: no reverse mapping → status not pushed -----------

    def test_kanban_to_external_no_reverse_mapping_status_not_pushed(self):
        """When _get_external_status returns None, status is NOT included
        in the fields dict sent to update_ticket."""
        from integrations.provider import UpdateTicketResult

        # Return success for summary only
        update_result = UpdateTicketResult(
            success=True,
            updated_fields={'summary': 'Changed Title'},
        )
        svc = self._make_sync_service(update_result)
        # No status mapping configured → _get_external_status returns None

        # Verify the helper returns None
        self.assertIsNone(svc._get_external_status('fake-int', 'in_progress'))

        item = {'id': 'XACA-003', 'title': 'Changed Title', 'status': 'in_progress'}
        link_data = self._make_link_data(summary='Old Title')  # title differs

        svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # update_ticket was called (because summary differs) but without 'status'
        self.assertEqual(len(svc._fake_provider.update_calls), 1)
        self.assertNotIn('status', svc._fake_provider.update_calls[0]['fields'])

    # ---------- test 4: no-op (nothing differs) --------------------------

    def test_kanban_to_external_noop_when_nothing_differs(self):
        """When title and status both match cached link values, update_ticket
        is NOT called and changes is empty."""
        from integrations.provider import UpdateTicketResult

        # Should never be reached, but define for completeness
        update_result = UpdateTicketResult(success=True, updated_fields={})
        svc = self._make_sync_service(update_result)
        svc.configure_status_mapping('fake-int', {
            'In Progress': 'in_progress',
        })

        item = {'id': 'XACA-004', 'title': 'Same Title', 'status': 'in_progress'}
        # Cached values match exactly
        link_data = self._make_link_data(summary='Same Title', status='In Progress')

        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # Provider was NOT called
        self.assertEqual(len(svc._fake_provider.update_calls), 0)
        # No outbound changes in result
        self.assertNotIn('pushed_summary', result.changes)
        self.assertNotIn('pushed_status', result.changes)

    # ---------- test 5: full failure ------------------------------------

    def test_kanban_to_external_full_failure_sets_sync_error(self):
        """Provider returns success=False with empty updated_fields →
        changes empty, link_data['syncError'] set, no raise."""
        from integrations.provider import UpdateTicketResult

        update_result = UpdateTicketResult(
            success=False,
            error='Connection refused',
            updated_fields={},
        )
        svc = self._make_sync_service(update_result)

        item = {'id': 'XACA-005', 'title': 'New Title', 'status': 'backlog'}
        link_data = self._make_link_data(summary='Old Title')

        # Must not raise
        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # Outbound changes are empty (nothing was accepted)
        self.assertNotIn('pushed_summary', result.changes)
        self.assertNotIn('pushed_status', result.changes)

        # syncError recorded on link_data
        self.assertIn('syncError', link_data)
        self.assertIn('Connection refused', link_data['syncError'])

        # link_data summary NOT updated (push failed)
        self.assertEqual(link_data.get('summary'), 'Old Title')

    # ---------- test 6: partial failure (GitHub-style) ------------------

    def test_kanban_to_external_partial_failure_accepted_fields_cached(self):
        """Provider returns success=False but updated_fields has 'summary'
        (e.g. GitHub: summary accepted, status unsupported) →
        pushed_summary + push_error in changes, summary cached,
        syncError set."""
        from integrations.provider import UpdateTicketResult

        update_result = UpdateTicketResult(
            success=False,
            error='Status update not supported',
            updated_fields={'summary': 'Accepted Title'},
        )
        svc = self._make_sync_service(update_result)
        svc.configure_status_mapping('fake-int', {
            'In Progress': 'in_progress',
        })

        item = {'id': 'XACA-006', 'title': 'Accepted Title', 'status': 'in_progress'}
        link_data = self._make_link_data(summary='Old Title', status='To Do')

        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # pushed_summary present (accepted)
        self.assertIn('pushed_summary', result.changes)
        self.assertEqual(result.changes['pushed_summary'], 'Accepted Title')

        # push_error present
        self.assertIn('push_error', result.changes)
        self.assertIn('Status update not supported', result.changes['push_error'])

        # summary cached in link_data
        self.assertEqual(link_data['summary'], 'Accepted Title')

        # syncError set
        self.assertIn('syncError', link_data)
        self.assertIn('Status update not supported', link_data['syncError'])

        # pushed_status NOT present (status was not accepted)
        self.assertNotIn('pushed_status', result.changes)

    # ---------- test 7: syncEnabled=False skips outbound ----------------

    def test_kanban_to_external_sync_enabled_false_skips(self):
        """syncEnabled=False at the link level → provider not called,
        status SKIPPED.  Holds for KANBAN_TO_EXTERNAL direction."""
        from integrations.provider import UpdateTicketResult

        update_result = UpdateTicketResult(success=True, updated_fields={})
        svc = self._make_sync_service(update_result)

        item = {'id': 'XACA-007', 'title': 'Some Title', 'status': 'in_progress'}
        link_data = self._make_link_data(syncEnabled=False)

        result = svc.sync_ticket_link(item, link_data, SyncDirection.KANBAN_TO_EXTERNAL)

        # Provider never called
        self.assertEqual(len(svc._fake_provider.update_calls), 0)
        self.assertEqual(result.status, SyncStatus.SKIPPED)

    # ---------- test 8: BIDIRECTIONAL runs both directions ---------------

    def test_bidirectional_runs_inbound_then_outbound(self):
        """BIDIRECTIONAL direction runs _sync_external_to_kanban FIRST
        (refreshing link_data cache) and then _sync_kanban_to_external.
        Both inbound keys (summary, external_status) and outbound keys
        (pushed_summary, pushed_status) can appear in changes.
        Ordering: inbound runs before outbound so fresh cache is used for
        the diff comparison."""
        from integrations.provider import UpdateTicketResult, VerifyResult

        # External ticket has different summary than kanban item
        verify_result = VerifyResult(
            valid=True,
            ticket_id='EXT-001',
            exists=True,
            summary='External Title',    # different from kanban 'Kanban Title'
            status='In Progress',
            url='https://fake.example.com/EXT-001',
        )
        # After inbound sync, link_data['summary'] becomes 'External Title'.
        # Kanban title is 'Kanban Title' → differs → outbound push triggered.
        update_result = UpdateTicketResult(
            success=True,
            updated_fields={'summary': 'Kanban Title'},
        )
        svc = self._make_sync_service(update_result, verify_result=verify_result)
        svc.configure_status_mapping('fake-int', {
            'In Progress': 'in_progress',
            'Done': 'completed',
        })

        item = {'id': 'XACA-008', 'title': 'Kanban Title', 'status': 'completed'}
        link_data = self._make_link_data(summary='Stale Title', status='To Do')

        result = svc.sync_ticket_link(item, link_data, SyncDirection.BIDIRECTIONAL)

        # Inbound key: external summary fetched
        self.assertIn('summary', result.changes)
        # Inbound key: external status fetched
        self.assertIn('external_status', result.changes)
        self.assertEqual(result.changes['external_status'], 'In Progress')

        # Outbound key: kanban title pushed
        self.assertIn('pushed_summary', result.changes)
        self.assertEqual(result.changes['pushed_summary'], 'Kanban Title')

        # update_ticket was called exactly once (outbound)
        self.assertEqual(len(svc._fake_provider.update_calls), 1)

        self.assertEqual(result.status, SyncStatus.SUCCESS)

    # ---------- test 9: default provider update_ticket returns unsupported

    def test_default_provider_update_ticket_returns_unsupported(self):
        """The base IntegrationProvider.update_ticket returns
        success=False with an error message containing 'does not support'."""
        from integrations.provider import (
            IntegrationProvider, IntegrationConfig,
            SearchResult, VerifyResult, ConnectionTestResult,
        )

        config = IntegrationConfig(
            id='base-test',
            type='fake',
            name='Base Provider',
            base_url='https://example.com',
        )

        class MinimalProvider(IntegrationProvider):
            """Minimal concrete subclass (only implements abstract methods)."""
            def search(self, query, max_results=10):
                return SearchResult()

            def verify(self, ticket_id):
                return VerifyResult(valid=True, ticket_id=ticket_id, exists=True)

            def test_connection(self):
                return ConnectionTestResult(success=True, message='ok')

        provider = MinimalProvider(config)
        result = provider.update_ticket('TICKET-1', {'summary': 'Test'})

        self.assertFalse(result.success)
        self.assertIsNotNone(result.error)
        self.assertIn('does not support', result.error)
        # updated_fields should be empty (nothing was pushed)
        self.assertEqual(result.updated_fields, {})


class TestIntegrationManager(unittest.TestCase):
    """Test IntegrationManager functionality."""

    def setUp(self):
        """Set up test manager with temp config."""
        self.temp_dir = tempfile.mkdtemp()
        self.config_path = Path(self.temp_dir) / 'integrations.json'

        config_data = {
            'integrations': [
                {
                    'id': 'jira-test',
                    'type': 'jira',
                    'name': 'Test JIRA',
                    'enabled': True,
                    'baseUrl': 'https://test.atlassian.net',
                    'browseUrl': 'https://test.atlassian.net/browse/{ticketId}',
                    'apiVersion': '3',
                    'ticketPattern': '^[A-Z]{1,10}-[0-9]+$'
                }
            ]
        }

        with open(self.config_path, 'w') as f:
            json.dump(config_data, f)

        self.manager = IntegrationManager(str(self.config_path))

    def tearDown(self):
        """Clean up temp files."""
        import shutil
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_load_integrations(self):
        """Test loading integrations from config."""
        self.manager.ensure_loaded()

        providers = self.manager.get_all_providers()
        self.assertEqual(len(providers), 1)
        self.assertEqual(providers[0].id, 'jira-test')

    def test_get_provider_by_id(self):
        """Test getting provider by ID."""
        self.manager.ensure_loaded()

        provider = self.manager.get_provider('jira-test')
        self.assertIsNotNone(provider)
        self.assertEqual(provider.name, 'Test JIRA')

    def test_list_integrations(self):
        """Test listing integrations for API."""
        self.manager.ensure_loaded()

        integrations = self.manager.list_integrations()
        self.assertEqual(len(integrations), 1)
        self.assertEqual(integrations[0]['id'], 'jira-test')


def run_tests():
    """Run all tests."""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # Add test classes
    suite.addTests(loader.loadTestsFromTestCase(TestIntegrationConfig))
    suite.addTests(loader.loadTestsFromTestCase(TestTicketLink))
    suite.addTests(loader.loadTestsFromTestCase(TestTicketLinkHelpers))
    suite.addTests(loader.loadTestsFromTestCase(TestJiraProvider))
    suite.addTests(loader.loadTestsFromTestCase(TestMondayProvider))
    suite.addTests(loader.loadTestsFromTestCase(TestMondayProviderStatusMethods))
    suite.addTests(loader.loadTestsFromTestCase(TestSyncService))
    suite.addTests(loader.loadTestsFromTestCase(TestMultiProviderScenarios))
    suite.addTests(loader.loadTestsFromTestCase(TestKanbanToExternalSync))
    suite.addTests(loader.loadTestsFromTestCase(TestIntegrationManager))

    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    return result.wasSuccessful()


if __name__ == '__main__':
    import sys
    success = run_tests()
    sys.exit(0 if success else 1)
