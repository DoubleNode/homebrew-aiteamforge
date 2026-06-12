#!/usr/bin/env python3
"""
cr-confluence-poller.py — Periodically scans cr-drafted CRs for a team,
detects an appended CR-Proper Confluence link at the bottom of each CR's request
page, and transitions cr-drafted → cr-submitted with full activity logging.

Also runs a second pass (Auto 2, XACA-0294-004) that scans cr-submitted CRs for
approval-readiness signals on their CR-Proper Confluence page, records a
cr_approval_candidate_detected activity event, and (if --auto-approve is set AND
per-team auto_approve_enabled is true) advances the CR to cr-approved.

Per-Team LaunchAgent Scheme (XACA-0350):
    The installer creates one LaunchAgent per team in confluence-credentials.json.
    Each LaunchAgent invokes this daemon with --team <name>, scoping it to that
    team only.  This isolates failures: a bad team config only affects that team's
    poller; the others continue running independently.

    Label:    com.aiteamforge.cr-confluence-poller.<team>
    Plist:    ~/Library/LaunchAgents/com.aiteamforge.cr-confluence-poller.<team>.plist
    Logs:     ~/Library/Logs/aiteamforge/cr-poller/<team>.out.log
              ~/Library/Logs/aiteamforge/cr-poller/<team>.err.log

Auth: REST API with HTTP Basic (email:api_token) read from:
    ~/.config/aiteamforge/confluence-credentials.json

Automations config (optional, for Auto 2 per-team overrides):
    ~/.config/aiteamforge/cr-automations.json
    If missing, all teams use default heuristics and auto_approve_enabled=false.

If the credentials file is missing the daemon logs a warning and exits 1
(global mode) or 0 (with --team — per-team LaunchAgents must not flap-restart).
Likewise, if --team names a team that is not in the credentials file, the daemon
logs a WARNING and exits 0 — same flap-prevention rationale.
MCP tools are NOT used here — they require an LLM session; this daemon is
autonomous and calls Confluence REST directly.

Run modes:
    --once          One-shot scan (used by tests / manual trigger)
    --daemon        Loop forever; sleeps POLL_INTERVAL_SECS between scans
    --interval N    Override POLL_INTERVAL_SECS (default 600 = 10 min)
    --team <name>   Restrict to one team (default: all teams in credentials file)
    --board PATH    Dev-mode: scan this exact board JSON (requires --team).
                    See "Dev-Mode Invocation" below.
    --verbose       Verbose logging
    --dry-run       Detect + log only; no writes
    --auto-approve  Enable automatic cr-submitted → cr-approved transition when an
                    approval signal is detected AND per-team auto_approve_enabled is
                    true in cr-automations.json. OFF by default. See DD2 in
                    XACA-0294_phase4_automations.md — false-positive auto-approvals
                    in CAB workflow are catastrophic; opt-in after a sample period.

Dev-Mode Invocation (XACA-0459 — M3Pro fallback):
    The AITeamForge installer is forbidden on the M3Pro dev machine (per
    CLAUDE.md), which means the per-team launchd agents that normally invoke
    this poller don't exist there. Dev-mode lets the script run directly from
    ~/dev-team/scripts/ against any team's shared kanban tree without touching
    the installer, ~/.config/aiteamforge/, or ~/Library/LaunchAgents/.

    Use cases:
      1. Iterating on detection heuristics during development
      2. One-shot manual scans during incident response when team-machine
         pollers are offline
      3. Validating that a freshly-appended CR-Proper link will be picked up
         before waiting for the next poll cycle on the team machine

    Two override surfaces (both optional, both layer cleanly on top of --once):
      $KB_CR_POLLER_CREDS_FILE  Absolute path to an alternate credentials file.
                                Falls back to ~/.config/aiteamforge/confluence-
                                credentials.json when unset.
      --board PATH              Absolute path to a board JSON file. Bypasses the
                                kanban-helpers.sh lookup. Requires --team so the
                                team↔board mapping is unambiguous.

    Example:
      KB_CR_POLLER_CREDS_FILE=/path/to/dev-creds.json \\
          ./cr-confluence-poller.py --once --team academy \\
          --board /Users/darrenehlers/dev-team/kanban/academy-board.json \\
          --dry-run --verbose

    Dev-mode does NOT install LaunchAgents, write plists, or otherwise touch
    installer-managed paths. It is purely a CLI affordance.

    Read/write parity (XACA-0459-001):
        When --board is set, the poller exports KB_CR_POLLER_BOARD_OVERRIDE_PATH
        into the subprocess env used by the write-path shell heredocs (record
        approval candidate, write cr_proper_url + transition). The heredocs
        resolve `BOARD_FILE` as `${KB_CR_POLLER_BOARD_OVERRIDE_PATH:-$(_kb_get_board_file ...)}`,
        so reads and writes target the same file. Without the override the
        existing `_kb_get_board_file '<team>'` resolution is used unchanged.

Exit codes:
    0 — clean exit (daemon stopped or once completed without errors)
    1 — credentials missing / config error
    2 — fatal error during scan
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

POLL_INTERVAL_SECS = 600  # 10 minutes default
DEFAULT_CREDS_FILE = (
    Path.home() / ".config" / "aiteamforge" / "confluence-credentials.json"
)
AUTOMATIONS_CONFIG_FILE = (
    Path.home() / ".config" / "aiteamforge" / "cr-automations.json"
)
KANBAN_HELPERS = Path.home() / "dev-team" / "kanban-helpers.sh"

# Dev-mode override: $KB_CR_POLLER_CREDS_FILE points at an alternate credentials
# file (XACA-0459). Resolved at call time so tests / CLI invocations can set the
# env var after import. AITeamForge installer / launchd path leaves the env
# unset and falls back to DEFAULT_CREDS_FILE.
CREDS_FILE_ENV = "KB_CR_POLLER_CREDS_FILE"


def _resolve_creds_file() -> Path:
    """Return the credentials file path, honoring $KB_CR_POLLER_CREDS_FILE."""
    override = os.environ.get(CREDS_FILE_ENV, "").strip()
    if override:
        return Path(override).expanduser()
    return DEFAULT_CREDS_FILE

# Confluence page URL patterns — used to confirm a link points to the same site.
CONFLUENCE_URL_PATTERN = re.compile(
    r"https://[^/]+\.atlassian\.net/wiki/(?:spaces|pages)",
    re.IGNORECASE,
)

# IT Connect ticket URL pattern (XACA-0465). cr_proper_url is the D&B change-management
# ticket at itconnect.daveandbusters.com — a SEPARATE system from Confluence.
# Distinct from cr_confluence_url, which is the Confluence DOC page.
ITCONNECT_URL_PATTERN = re.compile(r"^https://itconnect\.daveandbusters\.com/", re.IGNORECASE)

# The CR-Proper link detection heuristic looks at the LAST anchor in the page
# that matches one of these criteria:
#   1. Anchor text contains "CR-Proper" (case-insensitive)
#   2. Anchor href is a Confluence URL and the anchor appears after a heading
#      whose text contains "CR-Proper"
CR_PROPER_TEXT_PATTERN = re.compile(r"cr.?proper", re.IGNORECASE)

# ── Auto 2: approval-signal detection ────────────────────────────────────────

# Default labels that indicate CAB approval when present on a Confluence page.
DEFAULT_APPROVAL_LABELS = frozenset({"approved", "cab-approved"})

# Default heading regex: matches h1/h2/h3 whose text starts with "approved"
# (case-insensitive, optional leading whitespace).
DEFAULT_APPROVAL_HEADING_RE = re.compile(r"(?i)^\s*approved\b")

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────

_verbose = False

# Dev-mode board override populated by main() when --board is passed
# (XACA-0459). Shape: {"team": <str>, "path": <abs str>} or None.
_BOARD_OVERRIDE: dict | None = None


def log(msg: str) -> None:
    """Always-on log line (goes to stderr so launchd captures it separately)."""
    print(f"[cr-confluence-poller] {msg}", file=sys.stderr, flush=True)


def vlog(msg: str) -> None:
    """Verbose-only log line."""
    if _verbose:
        log(msg)


# ─────────────────────────────────────────────────────────────────────────────
# Credentials
# ─────────────────────────────────────────────────────────────────────────────


def load_credentials() -> dict:
    """
    Read the credentials file (default ~/.config/aiteamforge/confluence-credentials.json,
    or $KB_CR_POLLER_CREDS_FILE if set — see XACA-0459 dev-mode notes in module docstring).
    Returns the parsed dict.
    Raises FileNotFoundError if the file is absent (caller handles).
    Raises ValueError if the file is malformed.
    """
    creds_file = _resolve_creds_file()
    if not creds_file.exists():
        raise FileNotFoundError(
            f"Credentials file not found: {creds_file}\n"
            "Create it with your Atlassian email and API token.\n"
            "Schema: { \"teams\": { \"ios\": { \"site\": \"...\", \"email\": \"...\","
            " \"api_token\": \"...\", \"space_key\": \"DPD2\" } }, \"default\": \"ios\" }"
        )

    # Refuse to load when permissions are too open. The file holds plaintext
    # API tokens — group/world readability would expose them to other local
    # accounts. Owner-only (0600) is required.
    mode = creds_file.stat().st_mode & 0o777
    if mode & 0o077:
        try:
            creds_file.chmod(0o600)
            print(
                f"[cr-confluence-poller] WARNING: tightened credentials file mode "
                f"from 0{mode:o} to 0600: {creds_file}",
                file=sys.stderr,
            )
        except OSError as exc:
            raise PermissionError(
                f"Credentials file {creds_file} has unsafe mode 0{mode:o} "
                f"(holds plaintext token); refusing to load. chmod 600 to fix. "
                f"(auto-fix failed: {exc})"
            ) from exc

    try:
        data = json.loads(creds_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Malformed credentials file {creds_file}: {exc}") from exc

    if "teams" not in data or not isinstance(data["teams"], dict):
        raise ValueError(
            f"Credentials file {creds_file} missing required 'teams' dict."
        )
    return data


# ─────────────────────────────────────────────────────────────────────────────
# Automations config — cr-automations.json (optional)
# ─────────────────────────────────────────────────────────────────────────────


def load_automations_config() -> dict:
    """
    Read ~/.config/aiteamforge/cr-automations.json.

    Returns the parsed dict (may be empty if file missing or malformed).
    Never raises — absence or malformed config is treated as "use defaults".

    Expected shape:
    {
      "teams": {
        "ios": {
          "approval_signals": {
            "labels": ["approved", "cab-approved"],
            "heading_regex": "(?i)^\\s*approved\\b"
          },
          "auto_approve_enabled": false
        }
      }
    }
    """
    if not AUTOMATIONS_CONFIG_FILE.exists():
        vlog(
            f"cr-automations.json not found at {AUTOMATIONS_CONFIG_FILE} "
            "— using defaults for all teams (auto_approve_enabled=false)."
        )
        return {}

    try:
        data = json.loads(AUTOMATIONS_CONFIG_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log(
            f"WARNING: cannot parse cr-automations.json ({exc}) "
            "— using defaults for all teams."
        )
        return {}

    if not isinstance(data, dict):
        log("WARNING: cr-automations.json root is not an object — using defaults.")
        return {}

    return data


def get_team_automations_config(automations: dict, team: str) -> dict:
    """
    Return the automations config dict for a specific team, or {} if absent.

    Keys used by callers:
      approval_signals.labels       — list[str], extra labels to match
      approval_signals.heading_regex — str, regex override
      auto_approve_enabled          — bool, whether --auto-approve may transition
    """
    teams_block = automations.get("teams", {})
    if not isinstance(teams_block, dict):
        return {}
    return teams_block.get(team, {})


# ─────────────────────────────────────────────────────────────────────────────
# Board reading — via kanban-helpers.sh + kb-cr.sh subprocess helpers
# ─────────────────────────────────────────────────────────────────────────────


def _poller_env(extra: dict | None = None) -> dict:
    """Build the env dict for write-path subprocess calls.

    When _BOARD_OVERRIDE is set (dev-mode --board), include
    KB_CR_POLLER_BOARD_OVERRIDE_PATH so the shell heredocs honor the override
    via `${{KB_CR_POLLER_BOARD_OVERRIDE_PATH:-$(_kb_get_board_file ...)}}` —
    keeping read and write paths consistent in dev-mode (XACA-0459-001).
    """
    env: dict = {"KB_CR_ACTOR": "poller"}
    if _BOARD_OVERRIDE:
        env["KB_CR_POLLER_BOARD_OVERRIDE_PATH"] = _BOARD_OVERRIDE["path"]
    if extra:
        env.update(extra)
    return env


def _run_shell(cmd: str, env: dict | None = None) -> tuple[int, str, str]:
    """Run cmd in zsh with kanban-helpers sourced. Returns (rc, stdout, stderr).

    zsh (not bash) — kanban-helpers.sh uses zsh-only glob qualifiers like
    `(.DN)`, which bash cannot parse. Matches the shell choice in
    cr-lifecycle-monitor.py for consistency.
    """
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    result = subprocess.run(
        ["zsh", "-c", cmd],
        capture_output=True,
        text=True,
        env=full_env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _board_file_for_team(team: str) -> str | None:
    """Return the absolute board file path for a team, or None on failure.

    Honors the dev-mode override set by main() from --board (XACA-0459): when
    _BOARD_OVERRIDE is populated and the team matches the scoped --team value,
    return the override directly without shelling out to kanban-helpers.sh.
    """
    override = _BOARD_OVERRIDE
    if override and override.get("team") == team:
        return override.get("path")

    cmd = (
        f"source '{KANBAN_HELPERS}' 2>/dev/null && "
        f"_kb_get_board_file '{team}' 2>/dev/null"
    )
    rc, stdout, _stderr = _run_shell(cmd)
    if rc == 0 and stdout:
        return stdout
    return None


def find_cr_drafted_crs(team: str) -> list[dict]:
    """
    Read the team board and return all CR container records whose crState
    is "cr-drafted".

    Each returned dict is the raw CR container object, augmented with a
    '_board_file' key so callers don't need to re-resolve it.
    """
    board_path = _board_file_for_team(team)
    if not board_path or not os.path.isfile(board_path):
        vlog(f"[{team}] Board file not found — skipping team.")
        return []

    try:
        board_data = json.loads(Path(board_path).read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log(f"[{team}] Cannot read board JSON ({exc}) — skipping team.")
        return []

    crs = board_data.get("crs", [])
    drafted = []
    for cr in crs:
        if cr.get("crState") == "cr-drafted":
            cr["_board_file"] = board_path
            drafted.append(cr)

    vlog(f"[{team}] Found {len(drafted)} cr-drafted CR(s) out of {len(crs)} total.")
    return drafted


def find_cr_submitted_crs(team: str) -> list[dict]:
    """
    Read the team board and return all CR container records whose crState
    is "cr-submitted".

    Each returned dict is the raw CR container object, augmented with a
    '_board_file' key so callers don't need to re-resolve it.
    """
    board_path = _board_file_for_team(team)
    if not board_path or not os.path.isfile(board_path):
        vlog(f"[{team}] Board file not found — skipping team.")
        return []

    try:
        board_data = json.loads(Path(board_path).read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log(f"[{team}] Cannot read board JSON ({exc}) — skipping team.")
        return []

    crs = board_data.get("crs", [])
    submitted = []
    for cr in crs:
        if cr.get("crState") == "cr-submitted":
            cr["_board_file"] = board_path
            submitted.append(cr)

    vlog(f"[{team}] Found {len(submitted)} cr-submitted CR(s) out of {len(crs)} total.")
    return submitted


# ─────────────────────────────────────────────────────────────────────────────
# Confluence REST helpers
# ─────────────────────────────────────────────────────────────────────────────


def _confluence_page_id_from_url(url: str) -> str | None:
    """
    Extract the Confluence page ID from a URL.

    Supported patterns:
      - /wiki/spaces/<KEY>/pages/<ID>/...
      - /wiki/pages/<ID>
      - ?pageId=<ID>  (legacy)

    Returns the numeric page ID as a string, or None.
    """
    # Legacy query-param style: ?pageId=12345
    m = re.search(r"[?&]pageId=(\d+)", url)
    if m:
        return m.group(1)

    # Modern path style: /pages/<ID>/...
    m = re.search(r"/pages/(\d+)", url)
    if m:
        return m.group(1)

    return None


def _make_auth_header(email: str, api_token: str) -> str:
    """Return a base64 Basic auth header value."""
    import base64
    creds = f"{email}:{api_token}"
    encoded = base64.b64encode(creds.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def fetch_request_page_content(
    team: str,
    cr_record: dict,
    creds_for_team: dict,
) -> str | None:
    """
    Fetch the storage-format HTML body of the CR's request page.

    cr_record must have a 'cr_doc_link' field pointing to a Confluence page URL.
    If cr_doc_link is absent, a local path, or non-Confluence, returns None.

    Returns the HTML string (storage format) or None on any error.
    """
    cr_id = cr_record.get("crId") or cr_record.get("id", "<unknown>")
    doc_link = cr_record.get("cr_doc_link", "").strip()

    if not doc_link:
        vlog(f"[{team}][{cr_id}] No cr_doc_link — skipping.")
        return None

    # Only handle Confluence URLs — skip local file paths
    if not doc_link.startswith("https://") and not doc_link.startswith("http://"):
        vlog(f"[{team}][{cr_id}] cr_doc_link appears to be a local path — skipping.")
        return None

    page_id = _confluence_page_id_from_url(doc_link)
    if not page_id:
        vlog(
            f"[{team}][{cr_id}] Cannot extract page ID from cr_doc_link: {doc_link}"
        )
        return None

    site = creds_for_team.get("site", "").strip()
    email = creds_for_team.get("email", "").strip()
    api_token = creds_for_team.get("api_token", "").strip()

    if not all([site, email, api_token]):
        log(f"[{team}] Incomplete credentials (site/email/api_token required).")
        return None

    # Confluence Cloud REST v2 — fetch page body in storage format.
    api_url = (
        f"https://{site}/wiki/rest/api/content/{page_id}"
        "?expand=body.storage"
    )
    vlog(f"[{team}][{cr_id}] GET {api_url}")

    req = urllib.request.Request(
        api_url,
        headers={
            "Authorization": _make_auth_header(email, api_token),
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            html = body.get("body", {}).get("storage", {}).get("value", "")
            vlog(f"[{team}][{cr_id}] Fetched {len(html)} chars of page storage HTML.")
            return html
    except urllib.error.HTTPError as exc:
        log(f"[{team}][{cr_id}] HTTP {exc.code} fetching Confluence page {page_id}.")
        return None
    except urllib.error.URLError as exc:
        log(f"[{team}][{cr_id}] URL error fetching Confluence page: {exc.reason}")
        return None
    except (json.JSONDecodeError, KeyError) as exc:
        log(f"[{team}][{cr_id}] Unexpected Confluence response format: {exc}")
        return None


def _fetch_confluence_html_by_url(
    url: str,
    team: str,
    creds_for_team: dict,
    label: str = "",
) -> str | None:
    """
    Fetch the storage-format HTML body of a Confluence page given its URL directly.

    Used by the one-stage fallback path (XACA-0465) when cr_doc_link is absent
    but cr_confluence_url is populated — fetches that URL and hands the HTML to
    extract_cr_proper_link so an IT Connect anchor can be recovered.

    Unlike fetch_request_page_content, this takes an arbitrary Confluence URL
    rather than pulling the URL from a cr_record dict.  The implementation is
    otherwise identical (page-ID extraction + Confluence REST v2 content fetch).

    Returns the HTML string (storage format) or None on any error.
    """
    log_prefix = f"[{team}]" + (f"[{label}]" if label else "")

    if not url or not url.startswith("https://"):
        vlog(f"{log_prefix} _fetch_confluence_html_by_url: not a valid https URL.")
        return None

    page_id = _confluence_page_id_from_url(url)
    if not page_id:
        vlog(f"{log_prefix} _fetch_confluence_html_by_url: cannot extract page ID from {url}")
        return None

    site = creds_for_team.get("site", "").strip()
    email = creds_for_team.get("email", "").strip()
    api_token = creds_for_team.get("api_token", "").strip()

    if not all([site, email, api_token]):
        log(f"{log_prefix} Incomplete credentials (site/email/api_token required).")
        return None

    api_url = (
        f"https://{site}/wiki/rest/api/content/{page_id}"
        "?expand=body.storage"
    )
    vlog(f"{log_prefix} GET {api_url}")

    req = urllib.request.Request(
        api_url,
        headers={
            "Authorization": _make_auth_header(email, api_token),
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            html = body.get("body", {}).get("storage", {}).get("value", "")
            vlog(f"{log_prefix} Fetched {len(html)} chars of page storage HTML.")
            return html
    except urllib.error.HTTPError as exc:
        log(f"{log_prefix} HTTP {exc.code} fetching Confluence page {page_id}.")
        return None
    except urllib.error.URLError as exc:
        log(f"{log_prefix} URL error fetching Confluence page: {exc.reason}")
        return None
    except (json.JSONDecodeError, KeyError) as exc:
        log(f"{log_prefix} Unexpected Confluence response format: {exc}")
        return None


def fetch_cr_proper_page_data(
    team: str,
    cr_record: dict,
    creds_for_team: dict,
) -> dict | None:
    """
    Fetch labels and storage-format HTML body of the CR-Proper page.

    cr_record must have a 'cr_proper_url' field pointing to the Confluence
    CR-Proper page.  If cr_proper_url is absent, empty, non-Confluence, or an
    IT Connect ticket URL (one-stage CRs — itconnect.daveandbusters.com),
    returns None (silently — the Auto 2 scan skips unlinked or non-Confluence CRs).

    Returns a dict:
        {
          "html":   str,           # storage-format HTML body
          "labels": list[str],     # lowercase label names on the page
          "url":    str,           # the cr_proper_url value used
        }
    or None on any error / skip condition.
    """
    cr_id = cr_record.get("crId") or cr_record.get("id", "<unknown>")
    cr_proper_url = cr_record.get("cr_proper_url", "").strip()

    if not cr_proper_url:
        vlog(f"[{team}][{cr_id}] No cr_proper_url — skipping approval-signal scan.")
        return None

    if not cr_proper_url.startswith("https://"):
        vlog(
            f"[{team}][{cr_id}] cr_proper_url does not start with https:// — skipping."
        )
        return None

    if ITCONNECT_URL_PATTERN.match(cr_proper_url):
        vlog(
            f"[{team}][{cr_id}] cr_proper_url is an IT Connect ticket — "
            f"not a Confluence page; skipping approval-signal fetch (XACA-0469)."
        )
        return None

    page_id = _confluence_page_id_from_url(cr_proper_url)
    if not page_id:
        vlog(
            f"[{team}][{cr_id}] Cannot extract page ID from cr_proper_url: "
            f"{cr_proper_url}"
        )
        return None

    site = creds_for_team.get("site", "").strip()
    email = creds_for_team.get("email", "").strip()
    api_token = creds_for_team.get("api_token", "").strip()

    if not all([site, email, api_token]):
        log(f"[{team}] Incomplete credentials (site/email/api_token required).")
        return None

    # Fetch page body (storage format) AND labels in one request via expand.
    api_url = (
        f"https://{site}/wiki/rest/api/content/{page_id}"
        "?expand=body.storage,metadata.labels"
    )
    vlog(f"[{team}][{cr_id}] GET {api_url} (cr-proper approval scan)")

    req = urllib.request.Request(
        api_url,
        headers={
            "Authorization": _make_auth_header(email, api_token),
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            html = body.get("body", {}).get("storage", {}).get("value", "")
            raw_labels = (
                body.get("metadata", {})
                .get("labels", {})
                .get("results", [])
            )
            labels = [
                lbl.get("name", "").lower()
                for lbl in raw_labels
                if isinstance(lbl, dict) and lbl.get("name")
            ]
            vlog(
                f"[{team}][{cr_id}] CR-Proper page: {len(html)} chars, "
                f"labels={labels}"
            )
            return {"html": html, "labels": labels, "url": cr_proper_url}
    except urllib.error.HTTPError as exc:
        log(
            f"[{team}][{cr_id}] HTTP {exc.code} fetching CR-Proper page {page_id}."
        )
        return None
    except urllib.error.URLError as exc:
        log(
            f"[{team}][{cr_id}] URL error fetching CR-Proper page: {exc.reason}"
        )
        return None
    except (json.JSONDecodeError, KeyError) as exc:
        log(
            f"[{team}][{cr_id}] Unexpected Confluence response for CR-Proper: {exc}"
        )
        return None


# ─────────────────────────────────────────────────────────────────────────────
# HTML parsing — CR-Proper link extractor
# ─────────────────────────────────────────────────────────────────────────────


class _AnchorCollector(HTMLParser):
    """
    Collects all <a> elements with their href and text content.

    For each anchor we record:
        { "href": "...", "text": "...", "pos": <sequential index> }

    We also track headings so we can detect anchors that appear AFTER a
    heading whose text contains "CR-Proper".
    """

    def __init__(self) -> None:
        super().__init__()
        self.anchors: list[dict] = []
        self._current_href: str | None = None
        self._current_text_parts: list[str] = []
        self._in_anchor = False
        self._heading_texts: list[str] = []
        self._in_heading = False
        self._current_heading_parts: list[str] = []
        self._tag_depth = 0  # for nested tags inside <a>

    def handle_starttag(self, tag: str, attrs: list) -> None:
        attr_dict = dict(attrs)
        if tag == "a":
            self._in_anchor = True
            self._tag_depth = 0
            self._current_href = attr_dict.get("href", "")
            self._current_text_parts = []
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self._in_heading = True
            self._current_heading_parts = []

    def handle_endtag(self, tag: str) -> None:
        if tag == "a" and self._in_anchor:
            self._in_anchor = False
            text = " ".join(self._current_text_parts).strip()
            self.anchors.append(
                {
                    "href": self._current_href or "",
                    "text": text,
                    "pos": len(self.anchors),
                    # Snapshot: which CR-Proper-related headings came before this anchor
                    "after_cr_proper_heading": any(
                        CR_PROPER_TEXT_PATTERN.search(h) for h in self._heading_texts
                    ),
                }
            )
            self._current_href = None
            self._current_text_parts = []
        elif tag in ("h1", "h2", "h3", "h4", "h5", "h6") and self._in_heading:
            self._in_heading = False
            heading_text = " ".join(self._current_heading_parts).strip()
            self._heading_texts.append(heading_text)
            self._current_heading_parts = []

    def handle_data(self, data: str) -> None:
        if self._in_anchor:
            self._current_text_parts.append(data)
        if self._in_heading:
            self._current_heading_parts.append(data)


def extract_cr_proper_link(page_html: str) -> str | None:
    """
    Parse the Confluence storage HTML and return the URL of an appended
    CR-Proper link, or None if not found.

    Detection heuristic (applied in priority order):
    Rule 0: itconnect.daveandbusters.com anchor (highest); Rule 1: anchor text
    /cr.?proper/i; Rule 2: Confluence URL after cr-proper heading (legacy).

    Rule 0 (XACA-0465): cr_proper_url is the official D&B IT Connect ticket —
        a SEPARATE system from Confluence. Look for the LAST anchor whose href
        matches ITCONNECT_URL_PATTERN.
    Rule 1: Look for the LAST anchor whose text matches /cr.?proper/i — this is
        the canonical pattern when the CAB workflow appends a link with that
        exact label at the bottom of the request page.
    Rule 2: Look for the LAST anchor that:
        a. Has an href pointing to a Confluence page URL (atlassian.net/wiki),
        b. Appears AFTER a heading whose text matches /cr.?proper/i.

    Rationale: Confluence appends content at the bottom, so "last" is the
    safest anchor to pick without hard-coding a section name.  Rule 0 handles
    the standard IT Connect workflow; Rules 1 and 2 remain as fallbacks for
    legacy or customised pages.
    """
    if not page_html:
        return None

    collector = _AnchorCollector()
    try:
        collector.feed(page_html)
    except Exception:
        # HTMLParser is lenient; this should rarely fail
        return None

    anchors = collector.anchors
    if not anchors:
        return None

    # Rule 0 (XACA-0465): IT Connect ticket URL. cr_proper_url is the official D&B
    # change-management ticket — separate system from Confluence. Last itconnect anchor wins.
    for anchor in reversed(anchors):
        href = anchor.get("href", "")
        if ITCONNECT_URL_PATTERN.match(href):
            return href

    # Rule 1: last anchor whose text explicitly matches cr_proper.
    # Require https:// — parity with the manual transition endpoint
    # (server.py validates startswith('https://')); rejects plain http.
    for anchor in reversed(anchors):
        if CR_PROPER_TEXT_PATTERN.search(anchor["text"]):
            href = anchor["href"].strip()
            if href and href.startswith("https://"):
                return href

    # Rule 2: last confluence-URL anchor that appears after a cr-proper heading.
    # CONFLUENCE_URL_PATTERN already anchors on https://, so no extra check.
    for anchor in reversed(anchors):
        if anchor.get("after_cr_proper_heading"):
            href = anchor["href"].strip()
            if href and CONFLUENCE_URL_PATTERN.search(href):
                return href

    return None


# ─────────────────────────────────────────────────────────────────────────────
# Auto 2: approval-signal parser and detector
# ─────────────────────────────────────────────────────────────────────────────


class _ApprovalHeadingParser(HTMLParser):
    """
    Scans storage-format Confluence HTML for approval-signal headings.

    For each h1/h2/h3 we collect:
        { "text": "<heading text>", "next_para": "<text of immediately following <p>>" }

    The "next paragraph" heuristic captures approver names that CAB workflows
    conventionally place immediately after the "Approved" heading.
    """

    def __init__(self) -> None:
        super().__init__()
        self.headings: list[dict] = []
        self._in_heading = False
        self._heading_parts: list[str] = []
        self._after_heading = False  # True until a non-heading, non-whitespace tag
        self._in_para = False
        self._para_parts: list[str] = []
        self._pending_heading: str | None = None  # heading awaiting its next <p>

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in ("h1", "h2", "h3"):
            self._in_heading = True
            self._heading_parts = []
            self._after_heading = False
            self._in_para = False
            self._para_parts = []
            self._pending_heading = None
        elif tag == "p":
            if self._pending_heading is not None:
                self._in_para = True
                self._para_parts = []
        else:
            # Any non-heading, non-para block tag resets "after heading" context
            if tag in ("ul", "ol", "li", "table", "tr", "td", "th",
                       "div", "section", "hr") and self._pending_heading is not None:
                # Close the pending heading with empty next_para
                self.headings.append(
                    {"text": self._pending_heading, "next_para": ""}
                )
                self._pending_heading = None

    def handle_endtag(self, tag: str) -> None:
        if tag in ("h1", "h2", "h3") and self._in_heading:
            self._in_heading = False
            self._pending_heading = " ".join(self._heading_parts).strip()
            self._after_heading = True
        elif tag == "p" and self._in_para:
            self._in_para = False
            next_para = " ".join(self._para_parts).strip()
            self.headings.append(
                {"text": self._pending_heading or "", "next_para": next_para}
            )
            self._pending_heading = None

    def handle_data(self, data: str) -> None:
        if self._in_heading:
            self._heading_parts.append(data)
        elif self._in_para:
            self._para_parts.append(data)


def detect_approval_signal(
    page_data: dict,
    team_automations: dict,
) -> tuple[str, str] | None:
    """
    Apply both approval-signal heuristics to page_data.

    Returns (signal_source, approver_name) on match, or None if no signal found.

    signal_source is one of:
        "label:<label_name>"    — Confluence label match
        "heading:<heading_text>" — heading regex match

    approver_name is extracted from the paragraph immediately after the
    heading (if heading heuristic), or "unknown" (if label heuristic with no
    accompanying heading match).

    Per-team config (from cr-automations.json) may:
        - Add extra labels via approval_signals.labels (merged with defaults)
        - Override the heading regex via approval_signals.heading_regex

    Both heuristics are independent — first match wins (label checked first).
    """
    html = page_data.get("html", "")
    labels = page_data.get("labels", [])

    signals_cfg = team_automations.get("approval_signals", {})

    # ── Heuristic 1: Confluence label match ──────────────────────────────────
    extra_labels = signals_cfg.get("labels", [])
    if not isinstance(extra_labels, list):
        extra_labels = []
    all_approval_labels = DEFAULT_APPROVAL_LABELS | {
        lbl.lower() for lbl in extra_labels if isinstance(lbl, str)
    }

    for label in labels:
        if label in all_approval_labels:
            vlog(f"  Approval signal: label match '{label}'")
            return (f"label:{label}", "unknown")

    # ── Heuristic 2: heading regex match ─────────────────────────────────────
    raw_regex = signals_cfg.get("heading_regex")
    if raw_regex and isinstance(raw_regex, str):
        try:
            heading_re = re.compile(raw_regex)
        except re.error as exc:
            log(
                f"WARNING: invalid approval_signals.heading_regex {raw_regex!r}: "
                f"{exc} — falling back to default."
            )
            heading_re = DEFAULT_APPROVAL_HEADING_RE
    else:
        heading_re = DEFAULT_APPROVAL_HEADING_RE

    if not html:
        return None

    parser = _ApprovalHeadingParser()
    try:
        parser.feed(html)
    except Exception:
        return None

    # Flush any trailing heading that had no following <p> tag
    if parser._pending_heading is not None:
        parser.headings.append(
            {"text": parser._pending_heading, "next_para": ""}
        )
        parser._pending_heading = None

    for entry in parser.headings:
        heading_text = entry.get("text", "")
        if heading_re.search(heading_text):
            next_para = entry.get("next_para", "").strip()
            approver = next_para if next_para else "unknown"
            vlog(
                f"  Approval signal: heading match '{heading_text}', "
                f"approver='{approver}'"
            )
            return (f"heading:{heading_text}", approver)

    return None


# ─────────────────────────────────────────────────────────────────────────────
# Auto 2: record approval candidate + optional auto-approve transition
# ─────────────────────────────────────────────────────────────────────────────


def record_approval_candidate(
    team: str,
    cr_record: dict,
    signal_source: str,
    approver: str,
    page_url: str,
    dry_run: bool,
    auto_approve: bool,
    auto_approve_enabled: bool,
) -> bool:
    """
    On first approval-signal detection for a cr-submitted CR:
      1. Write cr_approval_candidate_at timestamp to the CR container (idempotency).
      2. Record a cr_approval_candidate_detected activity event.
      3. If auto_approve AND auto_approve_enabled: call kb-cr approve.

    Idempotency is checked BEFORE calling this function by the caller reading
    cr_approval_candidate_at from the live record — so this function always
    writes (the caller only calls it when the field is absent).

    Returns True on success, False on any failure.
    """
    cr_id = cr_record.get("crId") or cr_record.get("id", "")
    if not cr_id:
        log(f"[{team}] CR record has no crId — cannot record approval candidate.")
        return False

    if dry_run:
        log(
            f"[{team}][{cr_id}] DRY-RUN: would record cr_approval_candidate_detected "
            f"signal={signal_source!r} approver={approver!r}"
        )
        if auto_approve and auto_approve_enabled:
            log(
                f"[{team}][{cr_id}] DRY-RUN: would call kb-cr approve (auto-approve enabled)"
            )
        return True

    # Escape Confluence-sourced values for shell embedding via shlex.quote.
    # signal_source / approver / page_url come from page content; shlex.quote
    # is the canonical idiom for safely interpolating untrusted strings into
    # POSIX shell commands.
    bash_cmd = f"""
set -euo pipefail
source '{KANBAN_HELPERS}' 2>/dev/null

export KB_TEAM='{team}'
export KB_CR_ACTOR='poller'

# Write cr_approval_candidate_at timestamp
BOARD_FILE="${{KB_CR_POLLER_BOARD_OVERRIDE_PATH:-$(_kb_get_board_file '{team}')}}"
CR_IDX=$(_kb_cr_find_container "$BOARD_FILE" '{cr_id}')
if [[ -z "$CR_IDX" || "$CR_IDX" == "-1" ]]; then
    echo "cr-confluence-poller: CR '{cr_id}' not found in .crs[] on board $BOARD_FILE" >&2
    exit 1
fi

NOW=$(_kb_cr_timestamp)
_kb_jq_update "$BOARD_FILE" \\
    '.crs[$cidx].cr_approval_candidate_at = $ts | .crs[$cidx].updatedAt = $ts | .lastUpdated = $ts' \\
    --argjson cidx "$CR_IDX" \\
    --arg ts "$NOW"
echo "cr-confluence-poller: [{cr_id}] cr_approval_candidate_at written"

# Override _kb_detect_context so kb-cr activity record targets the correct
# board, not the cwd-inferred team. KB_TEAM env is set above but kb-cr
# uses _kb_detect_context (tmux/cwd-based) directly — env var is not consulted.
_kb_detect_context() {{ echo '{team}'; }}
export -f _kb_detect_context 2>/dev/null || true

# Record activity event
SIGNAL={shlex.quote(signal_source)}
APPROVER={shlex.quote(approver)}
PAGE_URL={shlex.quote(page_url)}
kb-cr activity record '{cr_id}' cr_approval_candidate_detected \\
    "signal=$SIGNAL" \\
    "approver=$APPROVER" \\
    "page_url=$PAGE_URL"
"""

    rc, stdout, stderr = _run_shell(bash_cmd, env=_poller_env())
    if rc != 0:
        log(f"[{team}][{cr_id}] record_approval_candidate failed (rc={rc}):")
        if stdout:
            log(f"  stdout: {stdout[:400]}")
        if stderr:
            log(f"  stderr: {stderr[:400]}")
        return False

    log(
        f"[{team}][{cr_id}] Approval candidate recorded. "
        f"signal={signal_source!r} approver={approver!r}"
    )

    # ── Optional: auto-approve ────────────────────────────────────────────────
    if auto_approve and auto_approve_enabled:
        return _auto_approve_cr(team, cr_id, approver)
    else:
        if auto_approve and not auto_approve_enabled:
            log(
                f"[{team}][{cr_id}] --auto-approve set but auto_approve_enabled=false "
                "in cr-automations.json — manual approval required."
            )
        else:
            log(
                f"[{team}][{cr_id}] Approval candidate detected — "
                "manual approval required (use: kb-cr approve {cr_id})."
            )
    return True


def _auto_approve_cr(team: str, cr_id: str, approver: str) -> bool:
    """
    Call kb-cr approve to transition cr-submitted → cr-approved.

    approver is the name extracted from the Confluence page (or "unknown").
    We pass it as --approver-name; login is not set (no Confluence identity mapping).

    Returns True on success, False on failure.
    """
    # All interpolated values use shlex.quote for shell-safe embedding.
    # approver is from Confluence (untrusted); team and cr_id are from board
    # JSON (controlled), but quoted for defense-in-depth.
    safe_team = shlex.quote(team)
    safe_cr_id = shlex.quote(cr_id)
    safe_approver = shlex.quote(approver)
    bash_cmd = f"""
set -euo pipefail
source '{KANBAN_HELPERS}' 2>/dev/null
export KB_TEAM={safe_team}
export KB_CR_ACTOR='poller'

# Override _kb_detect_context so kb-cr approve targets the correct board,
# not the cwd-inferred team. KB_TEAM is set above, but kb-cr uses
# _kb_detect_context (tmux/cwd-based) directly — env var is not consulted.
_kb_detect_context() {{ echo {safe_team}; }}
export -f _kb_detect_context 2>/dev/null || true

APPROVER_NAME={safe_approver}
if [[ "$APPROVER_NAME" == "unknown" ]]; then
    kb-cr approve {safe_cr_id}
else
    kb-cr approve {safe_cr_id} --approver-name "$APPROVER_NAME"
fi
"""
    rc, stdout, stderr = _run_shell(bash_cmd, env=_poller_env())
    if rc != 0:
        log(f"[{team}][{cr_id}] auto-approve failed (rc={rc}):")
        if stdout:
            log(f"  stdout: {stdout[:400]}")
        if stderr:
            log(f"  stderr: {stderr[:400]}")
        return False

    log(
        f"[{team}][{cr_id}] AUTO-APPROVED: cr-submitted → cr-approved. "
        f"approver={approver!r}"
    )
    return True


# ─────────────────────────────────────────────────────────────────────────────
# Transition helper — delegates ALL writes to kb-cr shell subprocess
# ─────────────────────────────────────────────────────────────────────────────


def transition_cr(
    team: str,
    cr_record: dict,
    cr_proper_url: str,
    dry_run: bool,
) -> bool:
    """
    For a cr-drafted CR whose CR-Proper link has been detected:
      1. Write cr_proper_url to the CR container record
      2. Transition crState cr-drafted → cr-submitted via kb-cr submit
      3. Append a cr_proper_detected activity event

    All writes go through kb-cr shell subcommands for atomicity.

    DECISION: `kb-cr field set` does not exist as a subcommand. Looking at
    kb-cr.sh, the pattern for writing a single field to a CR container is
    _kb_jq_update with a .crs[$cidx].<field> = $value filter, mirroring how
    _kb_cr_write_state and _kb_cr_lifecycle_advance work. Rather than inventing
    a new CLI subcommand, we write cr_proper_url directly via an inline bash
    block that uses _kb_jq_update — the same helper all other kb-cr writes use.
    This keeps the write atomic (Perl flock) and consistent with the rest of
    kb-cr.sh. The command also bumps .lastUpdated so LCARS picks up the change.

    Returns True on success, False on any failure.
    """
    cr_id = cr_record.get("crId") or cr_record.get("id", "")
    if not cr_id:
        log(f"[{team}] CR record has no crId — cannot transition.")
        return False

    if dry_run:
        log(
            f"[{team}][{cr_id}] DRY-RUN: would write cr_proper_url={cr_proper_url!r}"
            " and transition cr-drafted → cr-submitted"
        )
        return True

    # Build a single bash command that:
    #   a) sources kanban-helpers (which sources kb-cr.sh)
    #   b) writes cr_proper_url atomically via _kb_jq_update
    #   c) submits the CR (cr-drafted → cr-submitted via kb-cr submit)
    #   d) records the cr_proper_detected activity event
    #
    # We pass KB_CR_ACTOR=poller so activity log entries are attributed correctly.
    #
    # Notes on the _kb_jq_update call:
    #   - _kb_cr_find_container returns the numeric index into .crs[]
    #   - We then use that index with _kb_jq_update to set cr_proper_url
    #   - This mirrors how _kb_cr_lifecycle_advance writes timestamps
    bash_cmd = f"""
set -euo pipefail
source '{KANBAN_HELPERS}' 2>/dev/null

# Resolve team context so _kb_cr_board_preamble and kb-cr submit work
export KB_TEAM='{team}'
export KB_CR_ACTOR='poller'

# Find CR container index
BOARD_FILE="${{KB_CR_POLLER_BOARD_OVERRIDE_PATH:-$(_kb_get_board_file '{team}')}}"
CR_IDX=$(_kb_cr_find_container "$BOARD_FILE" '{cr_id}')
if [[ -z "$CR_IDX" || "$CR_IDX" == "-1" ]]; then
    echo "cr-confluence-poller: CR '{cr_id}' not found in .crs[] on board $BOARD_FILE" >&2
    exit 1
fi

# Write cr_proper_url atomically (mirrors _kb_cr_write_state pattern)
NOW=$(_kb_cr_timestamp)
_kb_jq_update "$BOARD_FILE" \\
    '.crs[$cidx].cr_proper_url = $url | .crs[$cidx].updatedAt = $now | .lastUpdated = $now' \\
    --argjson cidx "$CR_IDX" \\
    --arg url '{cr_proper_url}' \\
    --arg now "$NOW"
echo "cr-confluence-poller: [{cr_id}] cr_proper_url written"

# Override _kb_detect_context so kb-cr submit targets the correct board,
# not the cwd-inferred team (which would be 'academy' on M3Pro).
_kb_detect_context() {{ echo '{team}'; }}
export -f _kb_detect_context 2>/dev/null || true

# Transition cr-drafted → cr-submitted
kb-cr submit '{cr_id}'

# Record activity event
kb-cr activity record '{cr_id}' cr_proper_detected \\
    field=cr_proper_url \\
    new_value='{cr_proper_url}'
"""

    rc, stdout, stderr = _run_shell(bash_cmd, env=_poller_env())
    if rc != 0:
        log(f"[{team}][{cr_id}] Transition failed (rc={rc}):")
        if stdout:
            log(f"  stdout: {stdout[:400]}")
        if stderr:
            log(f"  stderr: {stderr[:400]}")
        return False

    log(f"[{team}][{cr_id}] cr-drafted → cr-submitted. cr_proper_url={cr_proper_url!r}")
    if stdout:
        vlog(f"[{team}][{cr_id}] shell output: {stdout[:200]}")
    return True


# ─────────────────────────────────────────────────────────────────────────────
# Per-team scan orchestration
# ─────────────────────────────────────────────────────────────────────────────


def scan_team_approval(
    team: str,
    creds_for_team: dict,
    team_automations: dict,
    dry_run: bool,
    auto_approve: bool,
) -> int:
    """
    Auto 2: Scan one team for cr-submitted CRs with an approval signal on the
    CR-Proper Confluence page.

    Idempotency: skips CRs that already have cr_approval_candidate_at set
    (first-detection only; field persists until the CR leaves cr-submitted).

    IT Connect cr_proper_url values (one-stage CRs — itconnect.daveandbusters.com)
    are silently skipped — approval-signal scanning over IT Connect is not
    implemented (Phase 2, gated on IT Connect API access). Manual approval required
    for those CRs.

    Returns the number of CRs for which a candidate event was recorded.
    """
    vlog(f"[{team}] Scanning cr-submitted CRs for approval signals...")

    auto_approve_enabled: bool = bool(
        team_automations.get("auto_approve_enabled", False)
    )

    submitted = find_cr_submitted_crs(team)
    if not submitted:
        vlog(f"[{team}] No cr-submitted CRs found.")
        return 0

    detected = 0
    for cr_record in submitted:
        cr_id = cr_record.get("crId") or cr_record.get("id", "<unknown>")

        # Idempotency check: skip if already recorded in this cr-submitted window
        if cr_record.get("cr_approval_candidate_at"):
            vlog(
                f"[{team}][{cr_id}] cr_approval_candidate_at already set "
                f"({cr_record['cr_approval_candidate_at']}) — skipping."
            )
            continue

        cr_proper_url = cr_record.get("cr_proper_url", "").strip()
        if not cr_proper_url:
            vlog(
                f"[{team}][{cr_id}] No cr_proper_url — CR-Proper page not linked yet. "
                "Skipping approval scan."
            )
            continue

        if ITCONNECT_URL_PATTERN.match(cr_proper_url):
            # XACA-0469 Phase 1: cr_proper_url is an IT Connect ticket
            # (one-stage CR, separate platform from Confluence). Approval-signal
            # scanning over IT Connect is not implemented (Phase 2, gated on
            # IT Connect API access). Silent-skip — manual approval required.
            log(
                f"[{team}][{cr_id}] cr_proper_url is an IT Connect ticket "
                f"({cr_proper_url}) — itconnect approval-signal scan not "
                f"implemented; manual approval required (XACA-0469 Phase 1)."
            )
            continue

        vlog(f"[{team}][{cr_id}] Fetching CR-Proper page for approval signals...")
        page_data = fetch_cr_proper_page_data(team, cr_record, creds_for_team)
        if page_data is None:
            continue

        result = detect_approval_signal(page_data, team_automations)
        if result is None:
            vlog(f"[{team}][{cr_id}] No approval signal found on CR-Proper page.")
            continue

        signal_source, approver = result
        log(
            f"[{team}][{cr_id}] Approval signal detected: "
            f"signal={signal_source!r} approver={approver!r}"
        )

        ok = record_approval_candidate(
            team=team,
            cr_record=cr_record,
            signal_source=signal_source,
            approver=approver,
            page_url=cr_proper_url,
            dry_run=dry_run,
            auto_approve=auto_approve,
            auto_approve_enabled=auto_approve_enabled,
        )
        if ok:
            detected += 1

    return detected


def scan_team(
    team: str,
    creds_for_team: dict,
    team_automations: dict,
    dry_run: bool,
    verbose: bool,
    auto_approve: bool,
) -> int:
    """
    Scan one team for cr-drafted CRs with a detectable CR-Proper link (Pass 1),
    then scan cr-submitted CRs for approval signals (Pass 2 — Auto 2).

    Returns the total number of CRs acted on (transitions + candidate recordings).
    """
    vlog(f"[{team}] Scanning for cr-drafted CRs...")

    # ── Pass 1: cr-drafted → cr-submitted ────────────────────────────────────
    drafted = find_cr_drafted_crs(team)
    transitioned = 0
    if drafted:
        for cr_record in drafted:
            cr_id = cr_record.get("crId") or cr_record.get("id", "<unknown>")
            vlog(f"[{team}][{cr_id}] Checking for CR-Proper link...")

            page_html = fetch_request_page_content(team, cr_record, creds_for_team)
            if page_html is None:
                # XACA-0465: cr_doc_link absent. If cr_confluence_url is populated (one-stage
                # publish), fetch THAT page and re-run extract_cr_proper_link on it. Only
                # transition when an itconnect URL is recovered. Never substitute
                # cr_confluence_url for cr_proper_url — they are different systems
                # (Confluence DOC vs. IT Connect ticket).
                fallback_confluence_url = (cr_record.get("cr_confluence_url") or "").strip()
                if fallback_confluence_url:
                    log(
                        f"[{team}][{cr_id}] [one-stage] cr_doc_link missing, fetching "
                        f"cr_confluence_url ({fallback_confluence_url})"
                    )
                    fallback_html = _fetch_confluence_html_by_url(
                        fallback_confluence_url, team, creds_for_team, label=cr_id
                    )
                    if fallback_html:
                        recovered = extract_cr_proper_link(fallback_html)
                        if recovered:
                            log(f"[{team}][{cr_id}] [one-stage] recovered cr_proper_url={recovered}")
                            ok = transition_cr(team, cr_record, recovered, dry_run=dry_run)
                            if ok:
                                transitioned += 1
                        else:
                            log(
                                f"[{team}][{cr_id}] [one-stage] no itconnect anchor in "
                                f"cr_confluence_url page — leaving as cr-drafted"
                            )
                    else:
                        log(f"[{team}][{cr_id}] [one-stage] failed to fetch cr_confluence_url page")
                continue

            cr_proper_url = extract_cr_proper_link(page_html)
            if cr_proper_url is None:
                vlog(f"[{team}][{cr_id}] No CR-Proper link found yet.")
                continue

            log(f"[{team}][{cr_id}] CR-Proper link detected: {cr_proper_url!r}")
            ok = transition_cr(team, cr_record, cr_proper_url, dry_run=dry_run)
            if ok:
                transitioned += 1
    else:
        vlog(f"[{team}] No cr-drafted CRs found.")

    # ── Pass 2: cr-submitted approval-signal scan (Auto 2) ───────────────────
    detected = scan_team_approval(
        team=team,
        creds_for_team=creds_for_team,
        team_automations=team_automations,
        dry_run=dry_run,
        auto_approve=auto_approve,
    )

    return transitioned + detected


# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────


def main() -> int:
    global _verbose

    parser = argparse.ArgumentParser(
        description=(
            "Confluence poller daemon — scans cr-drafted CRs for appended "
            "CR-Proper links and transitions them to cr-submitted. "
            "Also scans cr-submitted CRs for approval signals (Auto 2)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--once",
        action="store_true",
        help="Run one scan then exit (default if neither --once nor --daemon given).",
    )
    mode_group.add_argument(
        "--daemon",
        action="store_true",
        help="Loop forever, sleeping --interval seconds between scans.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=POLL_INTERVAL_SECS,
        metavar="N",
        help=f"Seconds between daemon scans (default: {POLL_INTERVAL_SECS}).",
    )
    parser.add_argument(
        "--team",
        metavar="NAME",
        help="Restrict scan to this team (default: all teams in credentials file).",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Verbose log output.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect and log only — no writes to board or activity log.",
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        default=False,
        help=(
            "Enable automatic cr-submitted → cr-approved transition when an "
            "approval signal is detected on the CR-Proper page. "
            "OFF by default — false-positive auto-approvals in CAB workflow are "
            "catastrophic. Per-team auto_approve_enabled must ALSO be true in "
            "cr-automations.json. See operator runbook before enabling."
        ),
    )
    parser.add_argument(
        "--board",
        metavar="PATH",
        help=(
            "Dev-mode override (XACA-0459): scan this exact board JSON file "
            "instead of resolving via kanban-helpers.sh. Requires --team. "
            "Use for one-shot scans from ~/dev-team/scripts/ when the "
            "AITeamForge installer / per-team launchd agent is unavailable "
            "(e.g. M3Pro, where the installer is forbidden). Combine with "
            "$KB_CR_POLLER_CREDS_FILE to point at a non-default creds file."
        ),
    )

    args = parser.parse_args()
    _verbose = args.verbose

    # ── Dev-mode --board validation (XACA-0459) ───────────────────────────────
    if args.board:
        if not args.team:
            log("ERROR: --board requires --team (board file is single-team).")
            return 1
        # .resolve() canonicalizes relative paths to absolute (XACA-0459-002),
        # matching the docstring's "absolute path" guidance and ensuring writes
        # via KB_CR_POLLER_BOARD_OVERRIDE_PATH receive the same value the user
        # sees in the "Dev-mode board override active" log line.
        board_path = Path(args.board).expanduser().resolve()
        if not board_path.is_file():
            log(f"ERROR: --board path is not a readable file: {board_path}")
            return 1
        global _BOARD_OVERRIDE
        _BOARD_OVERRIDE = {"team": args.team, "path": str(board_path)}
        log(
            f"Dev-mode board override active: team={args.team} "
            f"path={board_path}"
        )

    # Default to --once if neither mode flag is set
    daemon_mode = args.daemon

    # ── Load automations config (optional) ────────────────────────────────────
    automations_config = load_automations_config()
    if args.auto_approve:
        log(
            "WARNING: --auto-approve is set. CRs will be transitioned to "
            "cr-approved automatically when a signal is detected AND the per-team "
            "auto_approve_enabled is true in cr-automations.json."
        )

    # ── Load credentials ──────────────────────────────────────────────────────
    try:
        creds = load_credentials()
    except FileNotFoundError as exc:
        log(f"WARNING: {exc}")
        if args.team:
            # Per-team daemon: credentials file deleted/missing after install.
            # Exit 0 so launchd doesn't flap-restart every interval.
            log(
                f"Exiting cleanly — credentials absent; team '{args.team}' "
                "daemon will idle until the file is restored."
            )
            return 0
        log("Exiting cleanly — populate the credentials file and restart.")
        return 1
    except ValueError as exc:
        log(f"ERROR: {exc}")
        return 1

    teams_config: dict = creds.get("teams", {})
    if not teams_config:
        if args.team:
            # Per-team daemon: credentials removed the teams block after install.
            # Warn cleanly so launchd doesn't flap-restart this agent.
            log(
                f"WARNING: No teams defined in credentials file — "
                f"team '{args.team}' not available. Exiting cleanly."
            )
            return 0
        log("ERROR: No teams defined in credentials file.")
        return 1

    # ── Determine teams to scan ───────────────────────────────────────────────
    if args.team:
        if args.team not in teams_config:
            # Per-team daemon: user removed this team from credentials after the
            # LaunchAgent was installed. Warn and exit 0 so launchd treats this
            # as a normal completion rather than flap-restarting every interval.
            log(
                f"WARNING: Team '{args.team}' not found in credentials file "
                f"(available: {list(teams_config.keys())}). "
                "Exiting cleanly — remove the plist or re-add the team to credentials."
            )
            return 0
        teams_to_scan = [args.team]
    else:
        teams_to_scan = list(teams_config.keys())

    if args.dry_run:
        log("DRY-RUN mode enabled — no writes will occur.")

    interval = args.interval
    log(
        f"Starting {'daemon' if daemon_mode else 'one-shot'} scan "
        f"for teams: {teams_to_scan}"
    )

    # ── Scan loop ─────────────────────────────────────────────────────────────
    try:
        while True:
            total_transitioned = 0
            for team in teams_to_scan:
                team_creds = teams_config[team]
                team_automations = get_team_automations_config(automations_config, team)
                try:
                    n = scan_team(
                        team=team,
                        creds_for_team=team_creds,
                        team_automations=team_automations,
                        dry_run=args.dry_run,
                        verbose=args.verbose,
                        auto_approve=args.auto_approve,
                    )
                    total_transitioned += n
                except Exception as exc:  # noqa: BLE001
                    log(f"[{team}] Unexpected error during scan: {exc}")
                    # Continue with next team; don't abort entire run

            if total_transitioned:
                log(f"Scan complete. Transitioned {total_transitioned} CR(s).")
            else:
                vlog("Scan complete. No CRs transitioned this cycle.")

            if not daemon_mode:
                break

            vlog(f"Sleeping {interval}s until next scan...")
            time.sleep(interval)

    except KeyboardInterrupt:
        log("Interrupted — shutting down.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
