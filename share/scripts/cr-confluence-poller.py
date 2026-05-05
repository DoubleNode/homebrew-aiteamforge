#!/usr/bin/env python3
"""
cr-confluence-poller.py — Periodically scans cr-drafted CRs across all teams,
detects an appended CR-Proper Confluence link at the bottom of each CR's request
page, and transitions cr-drafted → cr-submitted with full activity logging.

Auth: REST API with HTTP Basic (email:api_token) read from:
    ~/.config/aiteamforge/confluence-credentials.json

If the credentials file is missing the daemon logs a warning and exits cleanly.
MCP tools are NOT used here — they require an LLM session; this daemon is
autonomous and calls Confluence REST directly.

Run modes:
    --once          One-shot scan (used by tests / manual trigger)
    --daemon        Loop forever; sleeps POLL_INTERVAL_SECS between scans
    --interval N    Override POLL_INTERVAL_SECS (default 600 = 10 min)
    --team <name>   Restrict to one team (default: all teams in credentials file)
    --verbose       Verbose logging
    --dry-run       Detect + log only; no writes

Exit codes:
    0 — clean exit (daemon stopped or once completed without errors)
    1 — credentials missing / config error
    2 — fatal error during scan
"""

import argparse
import json
import os
import re
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
CREDS_FILE = Path.home() / ".config" / "aiteamforge" / "confluence-credentials.json"
KANBAN_HELPERS = Path.home() / "dev-team" / "kanban-helpers.sh"

# Confluence page URL patterns — used to confirm a link points to the same site.
CONFLUENCE_URL_PATTERN = re.compile(
    r"https://[^/]+\.atlassian\.net/wiki/(?:spaces|pages)",
    re.IGNORECASE,
)

# The CR-Proper link detection heuristic looks at the LAST anchor in the page
# that matches one of these criteria:
#   1. Anchor text contains "CR-Proper" (case-insensitive)
#   2. Anchor href is a Confluence URL and the anchor appears after a heading
#      whose text contains "CR-Proper"
CR_PROPER_TEXT_PATTERN = re.compile(r"cr.?proper", re.IGNORECASE)

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────

_verbose = False


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
    Read ~/.config/aiteamforge/confluence-credentials.json.
    Returns the parsed dict.
    Raises FileNotFoundError if the file is absent (caller handles).
    Raises ValueError if the file is malformed.
    """
    if not CREDS_FILE.exists():
        raise FileNotFoundError(
            f"Credentials file not found: {CREDS_FILE}\n"
            "Create it with your Atlassian email and API token.\n"
            "Schema: { \"teams\": { \"ios\": { \"site\": \"...\", \"email\": \"...\","
            " \"api_token\": \"...\", \"space_key\": \"DPD2\" } }, \"default\": \"ios\" }"
        )

    # Refuse to load when permissions are too open. The file holds plaintext
    # API tokens — group/world readability would expose them to other local
    # accounts. Owner-only (0600) is required.
    mode = CREDS_FILE.stat().st_mode & 0o777
    if mode & 0o077:
        try:
            CREDS_FILE.chmod(0o600)
            print(
                f"[cr-confluence-poller] WARNING: tightened credentials file mode "
                f"from 0{mode:o} to 0600: {CREDS_FILE}",
                file=sys.stderr,
            )
        except OSError as exc:
            raise PermissionError(
                f"Credentials file {CREDS_FILE} has unsafe mode 0{mode:o} "
                f"(holds plaintext token); refusing to load. chmod 600 to fix. "
                f"(auto-fix failed: {exc})"
            ) from exc

    try:
        data = json.loads(CREDS_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Malformed credentials file {CREDS_FILE}: {exc}") from exc

    if "teams" not in data or not isinstance(data["teams"], dict):
        raise ValueError(
            f"Credentials file {CREDS_FILE} missing required 'teams' dict."
        )
    return data


# ─────────────────────────────────────────────────────────────────────────────
# Board reading — via kanban-helpers.sh + kb-cr.sh subprocess helpers
# ─────────────────────────────────────────────────────────────────────────────


def _run_shell(cmd: str, env: dict | None = None) -> tuple[int, str, str]:
    """Run cmd in bash with kanban-helpers sourced. Returns (rc, stdout, stderr)."""
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    result = subprocess.run(
        ["bash", "-c", cmd],
        capture_output=True,
        text=True,
        env=full_env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _board_file_for_team(team: str) -> str | None:
    """Return the absolute board file path for a team, or None on failure."""
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
    1. Look for the LAST anchor whose text matches /cr.?proper/i — this is the
       canonical pattern when the CAB workflow appends a link with that exact
       label at the bottom of the request page.
    2. Look for the LAST anchor that:
       a. Has an href pointing to a Confluence page URL (atlassian.net/wiki),
       b. Appears AFTER a heading whose text matches /cr.?proper/i.

    Rationale: Confluence appends content at the bottom, so "last" is the
    safest anchor to pick without hard-coding a section name.  Rule 1 is
    simpler and more reliable; Rule 2 is a fallback for CRs where the anchor
    text was customised (e.g. "Change Request Proper", page title, etc.).
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
BOARD_FILE=$(_kb_get_board_file '{team}')
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

# Transition cr-drafted → cr-submitted
kb-cr submit '{cr_id}'

# Record activity event
kb-cr activity record '{cr_id}' cr_proper_detected \\
    field=cr_proper_url \\
    new_value='{cr_proper_url}'
"""

    rc, stdout, stderr = _run_shell(bash_cmd, env={"KB_CR_ACTOR": "poller"})
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


def scan_team(
    team: str,
    creds_for_team: dict,
    dry_run: bool,
    verbose: bool,
) -> int:
    """
    Scan one team for cr-drafted CRs with a detectable CR-Proper link.
    Returns the number of CRs successfully transitioned.
    """
    vlog(f"[{team}] Scanning for cr-drafted CRs...")

    drafted = find_cr_drafted_crs(team)
    if not drafted:
        vlog(f"[{team}] No cr-drafted CRs found.")
        return 0

    transitioned = 0
    for cr_record in drafted:
        cr_id = cr_record.get("crId") or cr_record.get("id", "<unknown>")
        vlog(f"[{team}][{cr_id}] Checking for CR-Proper link...")

        page_html = fetch_request_page_content(team, cr_record, creds_for_team)
        if page_html is None:
            # Already logged in fetch function
            continue

        cr_proper_url = extract_cr_proper_link(page_html)
        if cr_proper_url is None:
            vlog(f"[{team}][{cr_id}] No CR-Proper link found yet.")
            continue

        log(f"[{team}][{cr_id}] CR-Proper link detected: {cr_proper_url!r}")
        ok = transition_cr(team, cr_record, cr_proper_url, dry_run=dry_run)
        if ok:
            transitioned += 1

    return transitioned


# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────


def main() -> int:
    global _verbose

    parser = argparse.ArgumentParser(
        description=(
            "Confluence poller daemon — scans cr-drafted CRs for appended "
            "CR-Proper links and transitions them to cr-submitted."
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

    args = parser.parse_args()
    _verbose = args.verbose

    # Default to --once if neither mode flag is set
    daemon_mode = args.daemon

    # ── Load credentials ──────────────────────────────────────────────────────
    try:
        creds = load_credentials()
    except FileNotFoundError as exc:
        log(f"WARNING: {exc}")
        log("Exiting cleanly — populate the credentials file and restart.")
        return 1
    except ValueError as exc:
        log(f"ERROR: {exc}")
        return 1

    teams_config: dict = creds.get("teams", {})
    if not teams_config:
        log("ERROR: No teams defined in credentials file.")
        return 1

    # ── Determine teams to scan ───────────────────────────────────────────────
    if args.team:
        if args.team not in teams_config:
            log(
                f"ERROR: Team '{args.team}' not found in credentials file. "
                f"Available: {list(teams_config.keys())}"
            )
            return 1
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
                try:
                    n = scan_team(
                        team=team,
                        creds_for_team=team_creds,
                        dry_run=args.dry_run,
                        verbose=args.verbose,
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
