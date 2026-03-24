#!/usr/bin/env python3
"""
Tests for the external issue import system.

Tests the fetch_issue() functionality for JIRA, GitHub, and Monday.com providers.
"""

import unittest
from unittest.mock import Mock, patch
import json
import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from integrations.provider import (
    IntegrationProvider,
    IntegrationConfig,
    ImportedIssue,
    FetchResult
)
from integrations.jira_provider import JiraProvider
from integrations.github_provider import GitHubProvider
from integrations.monday_provider import MondayProvider


class TestImportedIssue(unittest.TestCase):
    """Test the ImportedIssue dataclass."""

    def test_basic_creation(self):
        """Test creating a basic ImportedIssue."""
        issue = ImportedIssue(
            ticket_id="TEST-123",
            title="Test Issue"
        )
        self.assertEqual(issue.ticket_id, "TEST-123")
        self.assertEqual(issue.title, "Test Issue")
        self.assertEqual(issue.description, "")
        self.assertEqual(issue.children, [])

    def test_with_children(self):
        """Test ImportedIssue with children."""
        child = ImportedIssue(
            ticket_id="TEST-124",
            title="Child Issue",
            status="done"
        )
        parent = ImportedIssue(
            ticket_id="TEST-123",
            title="Parent Issue",
            children=[child]
        )
        self.assertEqual(len(parent.children), 1)
        self.assertEqual(parent.children[0].title, "Child Issue")

    def test_to_dict(self):
        """Test converting ImportedIssue to dictionary."""
        issue = ImportedIssue(
            ticket_id="TEST-123",
            title="Test Issue",
            status="in_progress",
            priority="high"
        )
        d = issue.to_dict()
        self.assertEqual(d['ticketId'], "TEST-123")
        self.assertEqual(d['title'], "Test Issue")
        self.assertEqual(d['status'], "in_progress")
        self.assertEqual(d['priority'], "high")


class TestFetchResult(unittest.TestCase):
    """Test the FetchResult dataclass."""

    def test_success_result(self):
        """Test successful FetchResult."""
        issue = ImportedIssue(ticket_id="TEST-123", title="Test")
        result = FetchResult(success=True, issue=issue)
        self.assertTrue(result.success)
        self.assertIsNotNone(result.issue)
        self.assertIsNone(result.error)

    def test_error_result(self):
        """Test error FetchResult."""
        result = FetchResult(success=False, error="Not found")
        self.assertFalse(result.success)
        self.assertIsNone(result.issue)
        self.assertEqual(result.error, "Not found")

    def test_with_warnings(self):
        """Test FetchResult with warnings."""
        issue = ImportedIssue(ticket_id="TEST-123", title="Test")
        result = FetchResult(
            success=True,
            issue=issue,
            warnings=["Subtask fetch failed"]
        )
        self.assertEqual(len(result.warnings), 1)


class TestJiraProviderFetch(unittest.TestCase):
    """Test JiraProvider fetch_issue()."""

    def setUp(self):
        """Set up test fixtures."""
        self.config = IntegrationConfig(
            id="test-jira",
            type="jira",
            name="Test JIRA",
            base_url="https://test.atlassian.net",
            browse_url="https://test.atlassian.net/browse/{ticketId}",
            ticket_pattern=r'^[A-Z]+-\d+$',
            auth_config={
                'type': 'basic',
                'userEnvVar': 'TEST_JIRA_USER',
                'tokenEnvVar': 'TEST_JIRA_TOKEN'
            }
        )
        self.provider = JiraProvider(self.config)

    def test_invalid_format(self):
        """Test fetch with invalid ticket format."""
        result = self.provider.fetch_issue("invalid")
        self.assertFalse(result.success)
        self.assertIn("Invalid format", result.error)

    def test_no_credentials(self):
        """Test fetch without credentials."""
        result = self.provider.fetch_issue("TEST-123")
        self.assertFalse(result.success)
        self.assertIn("credentials", result.error.lower())

    @patch.object(JiraProvider, '_make_request')
    @patch.object(JiraProvider, 'has_credentials', return_value=True)
    def test_successful_fetch(self, mock_creds, mock_request):
        """Test successful issue fetch."""
        mock_request.return_value = {
            'key': 'TEST-123',
            'fields': {
                'summary': 'Test Issue',
                'description': 'Test description',
                'status': {'name': 'In Progress'},
                'issuetype': {'name': 'Story'},
                'priority': {'name': 'High'},
                'subtasks': []
            }
        }

        result = self.provider.fetch_issue("TEST-123")

        self.assertTrue(result.success)
        self.assertEqual(result.issue.ticket_id, "TEST-123")
        self.assertEqual(result.issue.title, "Test Issue")
        self.assertEqual(result.issue.status, "In Progress")

    @patch.object(JiraProvider, '_make_request')
    @patch.object(JiraProvider, 'has_credentials', return_value=True)
    def test_fetch_with_subtasks(self, mock_creds, mock_request):
        """Test fetching issue with subtasks."""
        # Mock for parent issue
        parent_response = {
            'key': 'TEST-123',
            'fields': {
                'summary': 'Parent Issue',
                'description': '',
                'status': {'name': 'Open'},
                'issuetype': {'name': 'Story'},
                'priority': {'name': 'Medium'},
                'subtasks': [{'key': 'TEST-124'}, {'key': 'TEST-125'}]
            }
        }

        # Mock for subtasks
        subtask_response = {
            'key': 'TEST-124',
            'fields': {
                'summary': 'Subtask 1',
                'description': '',
                'status': {'name': 'Done'},
                'issuetype': {'name': 'Sub-task'},
                'priority': {'name': 'Low'}
            }
        }

        mock_request.side_effect = [parent_response, subtask_response, subtask_response]

        result = self.provider.fetch_issue("TEST-123")

        self.assertTrue(result.success)
        self.assertEqual(len(result.issue.children), 2)


class TestGitHubProviderFetch(unittest.TestCase):
    """Test GitHubProvider fetch_issue()."""

    def setUp(self):
        """Set up test fixtures."""
        self.config = IntegrationConfig(
            id="test-github",
            type="github",
            name="Test GitHub",
            base_url="https://api.github.com",
            browse_url="https://github.com/{owner}/{repo}/issues/{number}",
            auth_config={
                'type': 'bearer',
                'tokenEnvVar': 'TEST_GITHUB_TOKEN',
                'defaultOwner': 'testorg'
            }
        )
        self.provider = GitHubProvider(self.config)

    def test_parse_issue_id_full(self):
        """Test parsing full issue ID."""
        owner, repo, number = self.provider._parse_issue_id("owner/repo#123")
        self.assertEqual(owner, "owner")
        self.assertEqual(repo, "repo")
        self.assertEqual(number, 123)

    def test_parse_issue_id_prefixed(self):
        """Test parsing prefixed issue ID."""
        owner, repo, number = self.provider._parse_issue_id("gh:owner/repo#456")
        self.assertEqual(owner, "owner")
        self.assertEqual(repo, "repo")
        self.assertEqual(number, 456)

    def test_parse_task_list(self):
        """Test parsing markdown task list."""
        body = """
        ## Tasks
        - [ ] Uncompleted task
        - [x] Completed task
        - [ ] Another task
        """
        children = self.provider._parse_task_list(body)
        self.assertEqual(len(children), 3)
        self.assertEqual(children[0].status, "todo")
        self.assertEqual(children[1].status, "done")

    def test_invalid_format(self):
        """Test fetch with invalid format."""
        result = self.provider.fetch_issue("invalid")
        self.assertFalse(result.success)
        self.assertIn("Invalid", result.error)


class TestMondayProviderFetch(unittest.TestCase):
    """Test MondayProvider fetch_issue()."""

    def setUp(self):
        """Set up test fixtures."""
        self.config = IntegrationConfig(
            id="test-monday",
            type="monday",
            name="Test Monday",
            base_url="https://api.monday.com/v2",
            browse_url="https://view.monday.com/pulse/{ticketId}",
            auth_config={
                'type': 'api-key',
                'tokenEnvVar': 'TEST_MONDAY_TOKEN'
            }
        )
        self.provider = MondayProvider(self.config)

    def test_parse_item_id_numeric(self):
        """Test parsing numeric item ID."""
        item_id = self.provider._parse_item_id("1234567890")
        self.assertEqual(item_id, 1234567890)

    def test_parse_item_id_prefixed(self):
        """Test parsing prefixed item ID."""
        item_id = self.provider._parse_item_id("MON-1234567890")
        self.assertEqual(item_id, 1234567890)

    def test_parse_item_id_with_mon_prefix(self):
        """Test parsing with mon: prefix."""
        item_id = self.provider._parse_item_id("mon:1234567890")
        self.assertEqual(item_id, 1234567890)

    def test_invalid_format(self):
        """Test fetch with invalid format."""
        result = self.provider.fetch_issue("invalid")
        self.assertFalse(result.success)
        self.assertIn("Invalid", result.error)


class TestStatusMapping(unittest.TestCase):
    """Test status mapping functions."""

    def test_map_done_statuses(self):
        """Test mapping of done statuses."""
        from integrations.import_issue import map_status_to_kanban

        done_statuses = ['done', 'Done', 'DONE', 'closed', 'Closed', 'complete', 'Completed', 'resolved']
        for status in done_statuses:
            self.assertEqual(map_status_to_kanban(status), 'done', f"Failed for {status}")

    def test_map_in_progress_statuses(self):
        """Test mapping of in progress statuses."""
        from integrations.import_issue import map_status_to_kanban

        in_progress = ['in progress', 'In Progress', 'active', 'working', 'open']
        for status in in_progress:
            self.assertEqual(map_status_to_kanban(status), 'in_progress', f"Failed for {status}")

    def test_map_blocked_statuses(self):
        """Test mapping of blocked statuses."""
        from integrations.import_issue import map_status_to_kanban

        blocked = ['blocked', 'Blocked', 'on hold', 'waiting']
        for status in blocked:
            self.assertEqual(map_status_to_kanban(status), 'blocked', f"Failed for {status}")

    def test_map_default_to_todo(self):
        """Test unmapped statuses default to todo."""
        from integrations.import_issue import map_status_to_kanban

        self.assertEqual(map_status_to_kanban('unknown'), 'todo')
        self.assertEqual(map_status_to_kanban('new'), 'todo')


if __name__ == '__main__':
    unittest.main()
