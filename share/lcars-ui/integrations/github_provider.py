"""
GitHubProvider - GitHub Issues integration for LCARS kanban.

Implements IntegrationProvider for GitHub REST API v3.
Supports search, issue verification, and issue import with task list parsing.
"""

import json
import re
import urllib.request
import urllib.error
from typing import Optional, List, Dict, Any, Tuple

from .provider import (
    IntegrationProvider,
    IntegrationConfig,
    SearchResult,
    VerifyResult,
    ConnectionTestResult,
    TicketInfo,
    FetchResult,
    ImportedIssue
)
from .manager import IntegrationManager


class GitHubProvider(IntegrationProvider):
    """
    GitHub Issues integration provider.

    Uses GitHub REST API v3 for search and issue operations.
    Authentication via personal access token (bearer auth).

    Ticket ID formats supported:
    - owner/repo#123 (full format)
    - repo#123 (assumes configured owner)
    - gh:owner/repo#123 (prefixed format)
    - github:owner/repo#123 (prefixed format)
    """

    DEFAULT_TIMEOUT = 10  # seconds
    API_BASE = "https://api.github.com"

    def __init__(self, config: IntegrationConfig):
        super().__init__(config)
        self._api_base = config.base_url or self.API_BASE
        # Default owner from config (e.g., organization name)
        self._default_owner = config.auth_config.get('defaultOwner', '')

    def _make_request(
        self,
        url: str,
        method: str = 'GET',
        timeout: int = DEFAULT_TIMEOUT
    ) -> dict:
        """
        Make an authenticated request to GitHub API.

        Args:
            url: Full URL to request
            method: HTTP method
            timeout: Request timeout in seconds

        Returns:
            Parsed JSON response

        Raises:
            urllib.error.HTTPError: On HTTP errors
            urllib.error.URLError: On network errors
        """
        creds = self.get_credentials()
        token = creds.get('token', '')

        req = urllib.request.Request(url, method=method)

        if token:
            req.add_header('Authorization', f'Bearer {token}')

        req.add_header('Accept', 'application/vnd.github+json')
        req.add_header('X-GitHub-Api-Version', '2022-11-28')
        req.add_header('User-Agent', 'LCARS-Kanban/1.0')

        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode())

    def _parse_issue_id(self, ticket_id: str) -> Tuple[Optional[str], Optional[str], Optional[int]]:
        """
        Parse GitHub issue ID from various formats.

        Supports:
        - owner/repo#123
        - repo#123 (uses default owner)
        - gh:owner/repo#123
        - github:owner/repo#123
        - #123 (uses default owner and repo from config)

        Returns:
            Tuple of (owner, repo, issue_number) or (None, None, None) if invalid
        """
        ticket_id = ticket_id.strip()

        # Remove prefix if present
        if ticket_id.lower().startswith('gh:'):
            ticket_id = ticket_id[3:]
        elif ticket_id.lower().startswith('github:'):
            ticket_id = ticket_id[7:]

        # Pattern: owner/repo#number
        full_pattern = r'^([a-zA-Z0-9_-]+)/([a-zA-Z0-9_.-]+)#(\d+)$'
        match = re.match(full_pattern, ticket_id)
        if match:
            return match.group(1), match.group(2), int(match.group(3))

        # Pattern: repo#number (use default owner)
        short_pattern = r'^([a-zA-Z0-9_.-]+)#(\d+)$'
        match = re.match(short_pattern, ticket_id)
        if match and self._default_owner:
            return self._default_owner, match.group(1), int(match.group(2))

        # Pattern: #number only (use default owner and first project)
        number_pattern = r'^#?(\d+)$'
        match = re.match(number_pattern, ticket_id)
        if match and self._default_owner and self.config.default_projects:
            return self._default_owner, self.config.default_projects[0], int(match.group(1))

        return None, None, None

    def _format_issue_id(self, owner: str, repo: str, number: int) -> str:
        """Format issue ID as owner/repo#number."""
        return f"{owner}/{repo}#{number}"

    def search(self, query: str, max_results: int = 10) -> SearchResult:
        """
        Search GitHub for issues matching query.

        Args:
            query: Search string
            max_results: Max issues to return

        Returns:
            SearchResult with matching issues
        """
        if not query.strip():
            return SearchResult()

        # Build search query
        # Add repo filter if default projects configured
        search_query = query
        if self.config.default_projects and self._default_owner:
            repos = ' '.join(f'repo:{self._default_owner}/{r}' for r in self.config.default_projects)
            search_query = f'{repos} {query}'

        params = f"q={urllib.parse.quote(search_query)}&per_page={max_results}"
        url = f"{self._api_base}/search/issues?{params}"

        try:
            data = self._make_request(url)
            tickets = []

            for item in data.get('items', []):
                # Extract owner/repo from URL
                repo_url = item.get('repository_url', '')
                parts = repo_url.split('/')
                if len(parts) >= 2:
                    owner, repo = parts[-2], parts[-1]
                else:
                    owner, repo = '', ''

                number = item.get('number', 0)
                ticket_id = self._format_issue_id(owner, repo, number)

                tickets.append(TicketInfo(
                    ticket_id=ticket_id,
                    summary=item.get('title'),
                    status='open' if item.get('state') == 'open' else 'closed',
                    ticket_type='issue' if '/issues/' in item.get('html_url', '') else 'pull_request',
                    url=item.get('html_url'),
                    exists=True,
                    raw_data=item
                ))

            return SearchResult(
                tickets=tickets,
                total_count=data.get('total_count', len(tickets))
            )

        except urllib.error.HTTPError as e:
            return SearchResult(error=f"GitHub API error: {e.code}")
        except urllib.error.URLError as e:
            return SearchResult(error=f"Network error: {e.reason}")
        except Exception as e:
            return SearchResult(error=f"Search failed: {str(e)}")

    def verify(self, ticket_id: str) -> VerifyResult:
        """
        Verify a GitHub issue exists.

        Args:
            ticket_id: GitHub issue identifier

        Returns:
            VerifyResult with issue info or error
        """
        owner, repo, number = self._parse_issue_id(ticket_id)

        if not all([owner, repo, number]):
            return VerifyResult(
                valid=False,
                error=f"Invalid GitHub issue format: '{ticket_id}'. Expected owner/repo#123"
            )

        formatted_id = self._format_issue_id(owner, repo, number)

        # If no credentials, accept with format-only validation
        if not self.has_credentials():
            return VerifyResult(
                valid=True,
                ticket_id=formatted_id,
                url=f"https://github.com/{owner}/{repo}/issues/{number}",
                warning="GitHub token not configured - format validated only"
            )

        url = f"{self._api_base}/repos/{owner}/{repo}/issues/{number}"

        try:
            data = self._make_request(url)

            return VerifyResult(
                valid=True,
                ticket_id=formatted_id,
                exists=True,
                summary=data.get('title'),
                status='open' if data.get('state') == 'open' else 'closed',
                ticket_type='issue' if '/issues/' in data.get('html_url', '') else 'pull_request',
                url=data.get('html_url')
            )

        except urllib.error.HTTPError as e:
            if e.code == 404:
                return VerifyResult(
                    valid=False,
                    exists=False,
                    error=f"Issue '{formatted_id}' not found on GitHub"
                )
            elif e.code in (401, 403):
                return VerifyResult(
                    valid=True,
                    ticket_id=formatted_id,
                    url=f"https://github.com/{owner}/{repo}/issues/{number}",
                    warning="Could not verify (auth issue) - format validated only"
                )
            else:
                return VerifyResult(
                    valid=True,
                    ticket_id=formatted_id,
                    url=f"https://github.com/{owner}/{repo}/issues/{number}",
                    warning=f"Could not verify (HTTP {e.code}) - format validated only"
                )

        except urllib.error.URLError:
            return VerifyResult(
                valid=True,
                ticket_id=formatted_id,
                url=f"https://github.com/{owner}/{repo}/issues/{number}",
                warning="Could not verify (network error) - format validated only"
            )

        except Exception as e:
            return VerifyResult(
                valid=False,
                error=f"Verification failed: {str(e)}"
            )

    def test_connection(self) -> ConnectionTestResult:
        """
        Test connection to GitHub.

        Returns:
            ConnectionTestResult
        """
        if not self.has_credentials():
            return ConnectionTestResult(
                success=False,
                message="GitHub token not configured"
            )

        url = f"{self._api_base}/user"

        try:
            data = self._make_request(url)

            return ConnectionTestResult(
                success=True,
                message=f"Connected as {data.get('login', 'Unknown')}",
                details={
                    'user': data.get('login'),
                    'name': data.get('name'),
                    'email': data.get('email')
                }
            )

        except urllib.error.HTTPError as e:
            if e.code == 401:
                return ConnectionTestResult(
                    success=False,
                    message="Authentication failed - check GitHub token"
                )
            elif e.code == 403:
                return ConnectionTestResult(
                    success=False,
                    message="Access denied - check token permissions"
                )
            else:
                return ConnectionTestResult(
                    success=False,
                    message=f"GitHub API error: {e.code}"
                )

        except urllib.error.URLError as e:
            return ConnectionTestResult(
                success=False,
                message=f"Cannot reach GitHub: {e.reason}"
            )

        except Exception as e:
            return ConnectionTestResult(
                success=False,
                message=f"Connection test failed: {str(e)}"
            )

    def get_ticket_url(self, ticket_id: str) -> str:
        """
        Generate the browse URL for a GitHub issue.

        Args:
            ticket_id: The issue identifier

        Returns:
            Full URL to view the issue
        """
        owner, repo, number = self._parse_issue_id(ticket_id)

        if all([owner, repo, number]):
            return f"https://github.com/{owner}/{repo}/issues/{number}"

        # Fallback to browse_url template if configured
        if self.config.browse_url:
            return self.config.browse_url.replace('{ticketId}', ticket_id)

        return ""

    # =========================================================================
    # Import Support Methods
    # =========================================================================

    def fetch_issue(self, ticket_id: str, include_children: bool = True) -> FetchResult:
        """
        Fetch a complete GitHub issue with task list items for import.

        Parses markdown task lists (- [ ] item) from issue body as children.

        Args:
            ticket_id: GitHub issue identifier
            include_children: Whether to parse task lists

        Returns:
            FetchResult with complete issue data
        """
        owner, repo, number = self._parse_issue_id(ticket_id)

        if not all([owner, repo, number]):
            return FetchResult(
                success=False,
                error=f"Invalid GitHub issue format: '{ticket_id}'. Expected owner/repo#123"
            )

        if not self.has_credentials():
            return FetchResult(
                success=False,
                error="GitHub token not configured"
            )

        url = f"{self._api_base}/repos/{owner}/{repo}/issues/{number}"

        try:
            data = self._make_request(url)
            formatted_id = self._format_issue_id(owner, repo, number)

            # Map labels to list of strings
            labels = [label.get('name', '') for label in data.get('labels', [])]

            # Determine priority from labels
            priority = self._detect_priority(labels)

            issue = ImportedIssue(
                ticket_id=formatted_id,
                title=data.get('title', ''),
                description=data.get('body', '') or '',
                status='open' if data.get('state') == 'open' else 'closed',
                issue_type='pull_request' if data.get('pull_request') else 'issue',
                priority=priority,
                url=data.get('html_url', ''),
                assignee=data.get('assignee', {}).get('login') if data.get('assignee') else None,
                labels=labels,
                raw_data=data
            )

            # Parse task lists from body
            if include_children and data.get('body'):
                issue.children = self._parse_task_list(data['body'])

            return FetchResult(success=True, issue=issue)

        except urllib.error.HTTPError as e:
            if e.code == 404:
                return FetchResult(
                    success=False,
                    error=f"Issue '{ticket_id}' not found on GitHub"
                )
            elif e.code in (401, 403):
                return FetchResult(
                    success=False,
                    error="Authentication failed - check GitHub token"
                )
            else:
                return FetchResult(
                    success=False,
                    error=f"GitHub API error: {e.code}"
                )

        except urllib.error.URLError as e:
            return FetchResult(
                success=False,
                error=f"Network error: {e.reason}"
            )

        except Exception as e:
            return FetchResult(
                success=False,
                error=f"Fetch failed: {str(e)}"
            )

    def _parse_task_list(self, body: str) -> List[ImportedIssue]:
        """
        Parse GitHub markdown task lists into children.

        Matches:
        - [ ] Uncompleted task
        - [x] Completed task

        Args:
            body: Issue body markdown

        Returns:
            List of ImportedIssue representing tasks
        """
        children = []
        pattern = r'^[\s]*[-*]\s+\[([ xX])\]\s+(.+)$'

        for match in re.finditer(pattern, body, re.MULTILINE):
            checked = match.group(1).lower() == 'x'
            title = match.group(2).strip()

            # Generate a synthetic ID for the task
            task_num = len(children) + 1
            task_id = f"task-{task_num}"

            children.append(ImportedIssue(
                ticket_id=task_id,
                title=title,
                status='done' if checked else 'todo',
                issue_type='task'
            ))

        return children

    def _detect_priority(self, labels: List[str]) -> str:
        """
        Detect priority from issue labels.

        Args:
            labels: List of label names

        Returns:
            Priority string (high, medium, low)
        """
        labels_lower = [l.lower() for l in labels]

        # Check for priority labels
        priority_keywords = {
            'high': ['priority:high', 'p1', 'urgent', 'critical', 'high-priority'],
            'low': ['priority:low', 'p3', 'low-priority', 'nice-to-have'],
        }

        for priority, keywords in priority_keywords.items():
            for keyword in keywords:
                if any(keyword in label for label in labels_lower):
                    return priority

        return 'medium'


# Register the provider
IntegrationManager.register_provider('github', GitHubProvider)
