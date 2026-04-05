#!/usr/bin/env python3
"""init-agent-panel-json.py — Generate lcars-agent-<team>-<agent>.json files

Reads persona .md files for a team and writes per-agent JSON files that the
LCARS agent panel display script (agent-panel-display.sh) reads to show agent
info (name, role, avatar, theme, etc.).

This runs during team startup so the agent panels show real data immediately
instead of "Awaiting agent..." until each agent's banner script fires.

Usage:
    python3 init-agent-panel-json.py <team_id> <aiteamforge_dir>

Args:
    team_id         — e.g. "academy", "ios", "firebase"
    aiteamforge_dir — root of the AITeamForge install (e.g. ~/aiteamforge)

Output:
    <kanban_tmp>/lcars-agent-<team_id>-<terminal_id>.json  (one per agent)
    /tmp/lcars-agent-<team_id>-<terminal_id>.json          (legacy copy for banner scripts)

Exit codes:
    0 — success (all JSON files written)
    1 — usage error or personas directory not found
"""

import json
import os
import re
import sys
import time
from pathlib import Path


# ---------------------------------------------------------------------------
# Team kanban directory mapping (mirrors TEAM_KANBAN_DIRS in kanban_utils.py
# and the case statement in scripts/lcars-tmp-dir.sh).
# All three sources must stay in sync when adding new teams.
# ---------------------------------------------------------------------------
_HOME = Path.home()

TEAM_KANBAN_DIRS: dict[str, Path] = {
    # Core teams
    "academy":    _HOME / "dev-team" / "kanban",
    "ios":        Path("/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban"),
    "android":    Path("/Users/Shared/Development/Main Event/MainEventApp-Android/kanban"),
    "firebase":   Path("/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban"),
    "command":    Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
    "mainevent":  Path("/Users/Shared/Development/Main Event/dev-team/kanban"),
    "dns":        Path("/Users/Shared/Development/DNSFramework/kanban"),

    # Freelance — generic fallback
    "freelance":  _HOME / "dev-team" / "kanban",

    # Freelance — DoubleNode projects
    "freelance-doublenode-starwords":    Path("/Users/Shared/Development/DoubleNode/Starwords/kanban"),
    "freelance-doublenode-appplanning":  Path("/Users/Shared/Development/DoubleNode/appPlanning/kanban"),
    "freelance-doublenode-workstats":    Path("/Users/Shared/Development/DoubleNode/WorkStats/kanban"),
    "freelance-doublenode-lifeboard":    Path("/Users/Shared/Development/DoubleNode/LifeBoard/kanban"),
    "freelance-doublenode-caravan":      Path("/Users/Shared/Development/DoubleNode/Caravan/kanban"),
    "freelance-doublenode-awaysentry":   Path("/Users/Shared/Development/DoubleNode/AwaySentry/kanban"),

    # Freelance — Liquidstyle projects
    "freelance-liquidstyle-agentbadges-app": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban"),
    "freelance-liquidstyle-agentbadges-ios": Path("/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban"),

    # Personal life teams
    "legal-coparenting": _HOME / "legal" / "coparenting" / "kanban",
    "medical":           _HOME / "medical" / "general" / "kanban",
    "medical-general":   _HOME / "medical" / "general" / "kanban",
    "finance-personal":  _HOME / "finance" / "personal" / "kanban",
}

# Default fallback kanban directory (academy's) when team is unknown.
_DEFAULT_KANBAN_DIR: Path = _HOME / "dev-team" / "kanban"


def get_kanban_tmp_dir(team_id: str) -> Path:
    """Return the kanban/tmp/ directory for a team, creating it if needed.

    Mirrors _get_lcars_tmp_dir() in scripts/lcars-tmp-dir.sh and
    get_lcars_tmp_dir() in kanban-hooks/kanban_utils.py.

    Falls back to /tmp/ if the kanban directory cannot be created.
    """
    kanban_dir = TEAM_KANBAN_DIRS.get(team_id, _DEFAULT_KANBAN_DIR)
    tmp_dir = kanban_dir / "tmp"
    try:
        tmp_dir.mkdir(parents=True, exist_ok=True)
        return tmp_dir
    except OSError:
        return Path("/tmp")


# ---------------------------------------------------------------------------
# Theme (uniform color) lookup table
# Maps character codename → Starfleet uniform department color
# Agents without explicit color default to their team's primary color.
# ---------------------------------------------------------------------------
CHARACTER_THEME = {
    # Academy (Discovery)
    "nahla":     "COMMAND",
    "reno":      "OPERATIONS",
    "emh":       "SCIENCES",
    "thok":      "SCIENCES",

    # iOS (TNG)
    "picard":    "COMMAND",
    "data":      "OPERATIONS",
    "geordi":    "OPERATIONS",
    "worf":      "SECURITY",
    "deanna":    "SCIENCES",
    "beverly":   "SCIENCES",
    "wesley":    "SCIENCES",

    # Android (TOS)
    "kirk":      "COMMAND",
    "spock":     "SCIENCES",
    "scotty":    "OPERATIONS",
    "uhura":     "OPERATIONS",
    "sulu":      "COMMAND",
    "chekov":    "COMMAND",
    "mccoy":     "SCIENCES",

    # Firebase (DS9)
    "sisko":     "COMMAND",
    "kira":      "OPERATIONS",
    "obrien":    "OPERATIONS",
    "dax":       "SCIENCES",
    "bashir":    "SCIENCES",
    "odo":       "SECURITY",
    "quark":     "PROMENADE",

    # Finance (FCA)
    "zek":       "COMMAND",
    "quark-fin": "PROMENADE",
    "nog":       "OPERATIONS",
    "brunt":     "SECURITY",
    "rom":       "OPERATIONS",

    # Command (Starfleet Command)
    "janeway":   "COMMAND",
    "nechayev":  "COMMAND",
    "ross":      "COMMAND",
    "vance":     "COMMAND",
    "paris":     "COMMAND",

    # Freelance (Enterprise)
    "archer":    "COMMAND",
    "tucker":    "OPERATIONS",
    "tpol":      "SCIENCES",
    "phlox":     "SCIENCES",
    "reed":      "SECURITY",
    "sato":      "OPERATIONS",
    "mayweather":"COMMAND",

    # Legal (Boston Legal)
    "crane":     "COMMAND",
    "schmidt":   "COMMAND",
    "chase":     "OPERATIONS",
    "sack":      "COMMAND",
    "shore":     "SCIENCES",
    "espenson":  "SCIENCES",

    # Medical (House MD)
    "house":     "SCIENCES",
    "wilson":    "SCIENCES",
    "cameron":   "SCIENCES",
    "foreman":   "SCIENCES",
    "cuddy":     "COMMAND",
}

# Team-level fallback themes when character codename isn't in the lookup.
TEAM_DEFAULT_THEME = {
    "academy":  "OPERATIONS",
    "ios":      "COMMAND",
    "android":  "COMMAND",
    "firebase": "OPERATIONS",
    "command":  "COMMAND",
    "freelance":"COMMAND",
    "legal":    "COMMAND",
    "medical":  "SCIENCES",
    "finance":  "OPERATIONS",
}

# ---------------------------------------------------------------------------
# AMB handle lookup — maps developer name to AMB handle.
# Populated at runtime from ~/.claude/amb-agents.json if it exists.
# ---------------------------------------------------------------------------

def load_amb_handles() -> dict:
    """Return {developer_name_lower: handle} from ~/.claude/amb-agents.json.

    The dict keys are AMB agent names (lowercased). Lookup is done via
    fuzzy_amb_handle() which handles rank prefix differences like
    "Commander Jett Reno" matching AMB name "Jett Reno".
    """
    config_path = Path.home() / ".claude" / "amb-agents.json"
    if not config_path.exists():
        return {}
    try:
        with open(config_path) as f:
            data = json.load(f)
        # Build name→handle map from agents dict
        result = {}
        for handle, info in data.get("agents", {}).items():
            name = info.get("name", "")
            if name:
                result[name.lower()] = handle
        return result
    except Exception:
        return {}


def _word_set(text: str) -> set:
    """Lowercase + strip punctuation, return set of words (length > 1)."""
    # Remove parentheses, dots, commas, apostrophes, etc.
    cleaned = re.sub(r"[^\w\s]", " ", text.lower())
    return {w for w in cleaned.split() if len(w) > 1}


def fuzzy_amb_handle(developer: str, amb_handles: dict) -> str:
    """Look up an AMB handle for a developer name using fuzzy matching.

    Strategy:
      1. Exact match (both lowercased).
      2. All significant words of the AMB name appear in the developer name —
         handles rank prefixes like "Commander Jett Reno" matching "Jett Reno".
      3. All significant words of the developer name appear in the AMB name.

    Punctuation is stripped before comparison so "(EMH Mark I)" matches "EMH".
    Words of length 1 (e.g. roman numerals like "I") are excluded.

    Returns the handle string, or "" if no match found.
    """
    if not developer:
        return ""
    dev_lower = developer.lower()

    # Exact match
    if dev_lower in amb_handles:
        return amb_handles[dev_lower]

    dev_words = _word_set(developer)

    for amb_name, handle in amb_handles.items():
        amb_words = _word_set(amb_name)
        # All AMB words appear in developer name (handles rank prefix cases)
        if amb_words and amb_words.issubset(dev_words):
            return handle
        # All developer words appear in AMB name (covers more verbose AMB names)
        if dev_words and dev_words.issubset(amb_words):
            return handle

    return ""


# ---------------------------------------------------------------------------
# Persona file parsing
# ---------------------------------------------------------------------------

def parse_frontmatter(content: str) -> dict:
    """Parse YAML-ish frontmatter between --- delimiters.

    Returns dict of key: value pairs. Only handles simple string values.
    Stops at the first '---' boundary after the opening one.
    """
    result = {}
    lines = content.splitlines()
    if not lines or lines[0].strip() != "---":
        return result

    in_frontmatter = False
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        if ":" in stripped:
            key, _, val = stripped.partition(":")
            # Handle multi-line values by taking only first line; strip quotes
            val = val.strip().strip('"').strip("'")
            # Only set if key not already seen (first wins)
            if key.strip() not in result:
                result[key.strip()] = val
    return result


def parse_core_identity(content: str) -> dict:
    """Extract Name, Role, Location, and Uniform Color from the identity section.

    Returns dict with keys: developer, role, location, theme (may be empty strings).

    Searches for these section headers (in priority order):
        ## Core Identity   — used in persona .md agent files
        ## Your Identity   — used in system prompt .txt files

    Handles multiple markdown formatting variants:
        **Name:** value         (standard persona field)
        **Character:** value    (used in prompt .txt files — treated as Name)
        **Name**: value         (colon outside bold)
        **Name**:value          (no space)
    """
    result = {"developer": "", "role": "", "location": "", "theme": ""}

    # Try both section header variants; use the first one found.
    section_text = ""
    for header_pattern in (r"^##\s+Core Identity", r"^##\s+Your Identity"):
        core_match = re.search(header_pattern, content, re.MULTILINE)
        if core_match:
            rest = content[core_match.end():]
            next_section = re.search(r"^##\s+", rest, re.MULTILINE)
            section_text = rest[: next_section.start()] if next_section else rest
            break

    if not section_text:
        return result

    # Bold field pattern: **FieldName:** or **FieldName**: (colon inside or outside bold)
    # Followed by optional space and value to end of line
    def find_field(field: str, text: str) -> str:
        pattern = rf"\*\*{re.escape(field)}\*\*:?\s*(.+)"
        m = re.search(pattern, text)
        if m:
            return m.group(1).strip().rstrip("\\").strip()
        # Also try: **Field Name**: (colon outside bold markers)
        pattern2 = rf"\*\*{re.escape(field)}:\*\*\s*(.+)"
        m2 = re.search(pattern2, text)
        if m2:
            return m2.group(1).strip().rstrip("\\").strip()
        return ""

    # **Name:** (persona files) or **Character:** (prompt files) — both map to developer
    result["developer"] = find_field("Name", section_text)
    if not result["developer"]:
        result["developer"] = find_field("Character", section_text)

    result["role"] = find_field("Role", section_text)
    result["location"] = find_field("Location", section_text)

    # Theme from Uniform Color field (Academy-style personas only)
    theme_raw = find_field("Uniform Color", section_text)
    if theme_raw:
        result["theme"] = theme_raw.upper()

    return result


def extract_workspace_from_prompt(content: str) -> str:
    """Extract workspace name from the prompt file's opening line.

    Prompt files start with a line like:
        You are operating from the **Chancellor's Office** at Starfleet Academy.
        You are operating from the **Engineering Lab** at Starfleet Academy.
        You are operating from the **Chancellor's Office at Starfleet Academy**.

    Returns the workspace name without any trailing location context
    (e.g. "Chancellor's Office", "Engineering Lab"), or "" if not found.

    Strips trailing " at ..." and " in ..." suffixes from the bold text so that
    prompts that bold the full phrase still produce a clean workspace name.
    """
    # Only check the first non-empty line
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.search(r"\*\*([^*]+)\*\*", line)
        if m:
            workspace = m.group(1).strip()
            # Strip trailing " at ..." or " in ..." (location context)
            workspace = re.sub(r"\s+(at|in)\s+.+$", "", workspace, flags=re.IGNORECASE)
            return workspace.strip()
        break
    return ""


def extract_character_from_filename(filename: str) -> str:
    """Extract character codename from persona filename.

    Pattern: {team}_{character}_{role}_persona.md
    Returns the character segment (e.g. "picard" from "ios_picard_leadfeature_persona.md").
    """
    stem = filename.replace("_persona.md", "").replace(".md", "")
    parts = stem.split("_")
    # parts[0] = team, parts[1] = character, parts[2+] = role
    if len(parts) >= 2:
        return parts[1]
    return ""


def resolve_avatar(
    team_id: str,
    filename_character: str,
    developer: str,
    avatars_dir: Path,
) -> str:
    """Determine the avatar codename for a persona.

    Priority order:
      1. Match filename_character against avatar files in avatars_dir
         (works when persona filename encodes character name: picard, reno, etc.)
      2. Match developer name words against avatar filenames
         (works when filename uses role names: advocate → crane)
      3. Fall back to filename_character (may not match avatar files, but better
         than nothing — display script silently skips missing avatar images)

    Avatar files follow the pattern: {team}_{character}_avatar*.png
    """
    if not avatars_dir.exists():
        return filename_character

    # Build list of (character_codename, avatar_path) from the avatars directory.
    avatar_codenames = []
    for f in sorted(avatars_dir.glob(f"{team_id}_*_avatar*.png")):
        stem = f.stem  # e.g. "ios_picard_avatar_thumb"
        parts = stem.split("_")
        if len(parts) >= 2:
            avatar_codenames.append(parts[1])  # "picard"

    if not avatar_codenames:
        return filename_character

    # 1. Direct match: does filename_character appear in avatar codenames?
    if filename_character in avatar_codenames:
        return filename_character

    # 2. Developer name word match: find an avatar codename that is a word
    #    in the developer's name (e.g. "Denny Crane" → "crane")
    if developer:
        dev_words = _word_set(developer)
        for codename in avatar_codenames:
            if codename in dev_words:
                return codename

    # 3. Fallback — use filename_character even if no avatar file found
    return filename_character


def infer_terminal_desc(terminal_id: str, role: str, workspace: str = "") -> str:
    """Derive a short terminal description from workspace, terminal ID, or role.

    Priority:
      1. workspace — extracted from prompt file first line (e.g. "Engineering Lab")
      2. role first clause — first segment before comma, dash, or newline
      3. terminal_id — capitalised fallback
    """
    if workspace:
        return workspace
    if role:
        # Take first clause before comma, dash, or newline
        short = re.split(r"[,\-\n]", role)[0].strip()
        # Limit to ~30 chars
        if len(short) > 35:
            short = short[:32] + "..."
        return short
    return terminal_id.replace("-", " ").title()


def infer_location(team_id: str, team_name: str, character: str, parsed_location: str = "") -> str:
    """Derive a display location string from team and character context.

    Formats parsed_location as "{short_team}: {office}" when the location
    follows the pattern "{Team Name} - {Office Name}".

    For example:
        "Starfleet Academy - Chancellor's Office"
        → "Academy: Chancellor's Office"

    Priority:
      1. parsed_location from persona/prompt identity section (**Location:** field)
         — formatted as "{last word of team part}: {office}" when possible
      2. team_name from team .conf
      3. team_id capitalised as last resort
    """
    if parsed_location:
        if " - " in parsed_location:
            parts = parsed_location.split(" - ", 1)
            team_part = parts[0].strip()
            office_part = parts[1].strip()
            # Use the last word of the team part as the short label
            short_team = team_part.split()[-1] if team_part.split() else team_part
            return f"{short_team}: {office_part}"
        return parsed_location
    return team_name if team_name else team_id.title()


def infer_session_desc(team_id: str, terminal_id: str, role: str, frontmatter_desc: str = "") -> str:
    """Build a session description string.

    Base format: "{TEAM} {TERMINAL}" (e.g. "ACADEMY CHANCELLOR").
    If frontmatter_desc follows the pattern "{Title} - {Area, ...}", appends
    the first area segment as an uppercase suffix:
        "Academy Chancellor - Strategic leadership, ..."
        → "ACADEMY CHANCELLOR - STRATEGIC LEADERSHIP"
    """
    team_upper = team_id.upper().replace("-", " ")
    terminal_upper = terminal_id.upper().replace("-", " ")
    base = f"{team_upper} {terminal_upper}"

    if frontmatter_desc and " - " in frontmatter_desc:
        after_dash = frontmatter_desc.split(" - ", 1)[1].strip()
        # Take the first segment before comma or period
        suffix = re.split(r"[,.]", after_dash)[0].strip()
        if suffix:
            return f"{base} - {suffix.upper()}"

    return base


# ---------------------------------------------------------------------------
# Kanban tmp directory resolution
# Mirrors _get_team_kanban_dir_for_tmp() in share/scripts/lcars-tmp-dir.sh
# and TEAM_KANBAN_DIRS in share/kanban-hooks/kanban_utils.py.
# All three must be kept in sync when adding new teams.
# ---------------------------------------------------------------------------

# Map team_id → kanban directory (absolute paths, ~ expanded at runtime)
_TEAM_KANBAN_DIRS = {
    "academy":                                "~/dev-team/kanban",
    "ios":                                    "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban",
    "android":                                "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban",
    "firebase":                               "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban",
    "command":                                "/Users/Shared/Development/Main Event/dev-team/kanban",
    "mainevent":                              "/Users/Shared/Development/Main Event/dev-team/kanban",
    "dns":                                    "/Users/Shared/Development/DNSFramework/kanban",
    "freelance":                              "~/dev-team/kanban",
    "freelance-doublenode-starwords":         "/Users/Shared/Development/DoubleNode/Starwords/kanban",
    "freelance-doublenode-appplanning":       "/Users/Shared/Development/DoubleNode/appPlanning/kanban",
    "freelance-doublenode-workstats":         "/Users/Shared/Development/DoubleNode/WorkStats/kanban",
    "freelance-doublenode-lifeboard":         "/Users/Shared/Development/DoubleNode/LifeBoard/kanban",
    "freelance-doublenode-caravan":           "/Users/Shared/Development/DoubleNode/Caravan/kanban",
    "freelance-doublenode-awaysentry":        "/Users/Shared/Development/DoubleNode/AwaySentry/kanban",
    "freelance-liquidstyle-agentbadges-app":  "/Users/Shared/Development/Liquidstyle/AgentBadges-APP/kanban",
    "freelance-liquidstyle-agentbadges-ios":  "/Users/Shared/Development/Liquidstyle/AgentBadges-IOS/kanban",
    "legal-coparenting":                      "~/legal/coparenting/kanban",
    "finance-personal":                       "~/finance/personal/kanban",
    "medical":                                "~/medical/general/kanban",
    "medical-general":                        "~/medical/general/kanban",
}


def get_kanban_tmp_dir(team_id: str) -> Path:
    """Return the per-team kanban/tmp/ directory path, creating it if needed.

    Falls back to /tmp/ when the team is unknown or the directory cannot be
    created (e.g. on a machine where the team's repo is not checked out).

    Mirrors _get_lcars_tmp_dir() in share/scripts/lcars-tmp-dir.sh.
    """
    raw = _TEAM_KANBAN_DIRS.get(team_id, "")
    if not raw:
        return Path("/tmp")

    kanban_dir = Path(raw).expanduser()
    tmp_dir = kanban_dir / "tmp"
    try:
        tmp_dir.mkdir(parents=True, exist_ok=True)
        return tmp_dir
    except Exception:
        return Path("/tmp")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <team_id> <aiteamforge_dir>", file=sys.stderr)
        sys.exit(1)

    team_id = sys.argv[1].lower()
    aiteamforge_dir = Path(sys.argv[2]).expanduser()

    # Persona files may be in either of two layouts:
    #   Installed layout:  {AITEAMFORGE_DIR}/{team_id}/personas/agents/
    #   Share layout:      {AITEAMFORGE_DIR}/personas/{team_id}/agents/
    # Check both; prefer installed layout (more specific).
    personas_dir_installed = aiteamforge_dir / team_id / "personas" / "agents"
    personas_dir_share = aiteamforge_dir / "personas" / team_id / "agents"

    if personas_dir_installed.exists():
        personas_dir = personas_dir_installed
        avatars_dir = aiteamforge_dir / team_id / "personas" / "avatars"
        prompts_dir = aiteamforge_dir / team_id / "personas" / "prompts"
    elif personas_dir_share.exists():
        personas_dir = personas_dir_share
        avatars_dir = aiteamforge_dir / "personas" / team_id / "avatars"
        prompts_dir = aiteamforge_dir / "personas" / team_id / "prompts"
    else:
        print(
            f"Warning: Personas directory not found for team '{team_id}'\n"
            f"  Checked: {personas_dir_installed}\n"
            f"  Checked: {personas_dir_share}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Also check for prompts in the installed scripts/prompts/ location
    prompts_dir_scripts = aiteamforge_dir / team_id / "scripts" / "prompts"
    if not prompts_dir.exists() and prompts_dir_scripts.exists():
        prompts_dir = prompts_dir_scripts

    # Load team conf to get team name (best-effort)
    # Conf may be in share/teams/ or {AITEAMFORGE_DIR}/teams/
    team_name = team_id.title()
    for conf_candidate in [
        aiteamforge_dir / "teams" / f"{team_id}.conf",
        aiteamforge_dir / team_id / f"{team_id}.conf",
    ]:
        if conf_candidate.exists():
            try:
                conf_text = conf_candidate.read_text()
                m = re.search(r'^TEAM_NAME="([^"]+)"', conf_text, re.MULTILINE)
                if m:
                    team_name = m.group(1)
            except Exception:
                pass
            break

    # Load AMB handles
    amb_handles = load_amb_handles()

    # Find all persona files
    persona_files = sorted(personas_dir.glob("*_persona.md"))
    if not persona_files:
        print(f"Warning: No persona files found in {personas_dir}", file=sys.stderr)
        sys.exit(1)

    # Resolve the kanban/tmp/ output directory for this team.
    # agent-panel-display.sh reads from this directory (via lcars-tmp-dir.sh),
    # so we must write here instead of /tmp/ to avoid the panel showing stale data.
    # Falls back to /tmp/ when the kanban directory doesn't exist on this machine.
    kanban_tmp_dir = get_kanban_tmp_dir(team_id)

    timestamp = str(int(time.time()))
    written = 0

    for pfile in persona_files:
        try:
            content = pfile.read_text()
        except Exception as e:
            print(f"Warning: Cannot read {pfile}: {e}", file=sys.stderr)
            continue

        # Parse frontmatter for terminal_id (name field)
        frontmatter = parse_frontmatter(content)
        terminal_id = frontmatter.get("name", "").strip()
        if not terminal_id:
            print(f"Warning: No 'name' field in frontmatter of {pfile.name}", file=sys.stderr)
            continue

        # Extract initial character hint from filename (used as avatar fallback)
        filename_character = extract_character_from_filename(pfile.name)
        if not filename_character:
            print(f"Warning: Cannot extract character from filename {pfile.name}", file=sys.stderr)
            continue

        # Parse developer name, role, location, theme from the identity section.
        # Persona .md files use ## Core Identity + **Name:** fields.
        # System prompt .txt files use ## Your Identity + **Character:** fields.
        identity = parse_core_identity(content)
        developer = identity["developer"]
        role = identity["role"]
        parsed_location = identity["location"]
        theme = identity["theme"]

        # Workspace name extracted from prompt file opening line (e.g. "Engineering Lab").
        # Used as terminal_desc when available; populated below when the prompt is read.
        workspace = ""

        # If the persona .md file doesn't have complete identity data, try the
        # corresponding prompt .txt file in the prompts directory.  Prompt files
        # use ## Your Identity / **Character:** and carry richer location data.
        # Always read the prompt file when it exists so workspace can be extracted.
        if prompts_dir.exists():
            # Resolve the prompt file for this persona. Prompt filenames may use
            # terminal_id (e.g. academy-chancellor-prompt.txt), character name
            # (e.g. academy-reno-prompt.txt), or a role label (e.g.
            # academy-engineering-prompt.txt). Try named candidates first; fall back
            # to scanning all prompt files and matching on the **Character:** field.
            prompt_candidates = [
                prompts_dir / f"{team_id}-{terminal_id}-prompt.txt",
                prompts_dir / f"{team_id}-{filename_character}-prompt.txt",
            ]

            resolved_prompt: Path | None = None
            # Check explicit candidates first
            for pc in prompt_candidates:
                if pc.exists():
                    resolved_prompt = pc
                    break

            # If no explicit match, scan all prompt files and find the one whose
            # ## Your Identity **Character:** value matches our developer name.
            # This handles role-named files like academy-engineering-prompt.txt.
            # Uses fuzzy word-overlap matching so slight name variations
            # (e.g. "The Doctor (EMH Mark I)" vs "The Doctor (Emergency...)") match.
            if resolved_prompt is None and developer:
                dev_words = _word_set(developer)
                for pf in sorted(prompts_dir.glob(f"{team_id}-*-prompt.txt")):
                    if pf in prompt_candidates:
                        continue
                    try:
                        pf_content = pf.read_text()
                        pf_identity = parse_core_identity(pf_content)
                        pf_dev = pf_identity.get("developer", "")
                        if not pf_dev:
                            continue
                        pf_words = _word_set(pf_dev)
                        # Match if significant words of one name are a subset of the other,
                        # OR if the intersection of words covers at least half of the shorter set.
                        # The second condition handles names like "The Doctor (EMH Mark I)"
                        # vs "The Doctor (Emergency Medical Hologram)" where neither is a
                        # full subset but both share distinctive words ("doctor").
                        common = dev_words & pf_words
                        shorter = min(len(dev_words), len(pf_words))
                        match = (
                            (dev_words and dev_words.issubset(pf_words)) or
                            (pf_words and pf_words.issubset(dev_words)) or
                            (shorter > 0 and len(common) >= max(1, shorter // 2))
                        )
                        if match:
                            resolved_prompt = pf
                            break
                    except Exception:
                        continue

            if resolved_prompt is not None:
                try:
                    prompt_content = resolved_prompt.read_text()
                    prompt_identity = parse_core_identity(prompt_content)
                    if not developer:
                        developer = prompt_identity["developer"]
                    if not role:
                        role = prompt_identity["role"]
                    if not parsed_location:
                        parsed_location = prompt_identity["location"]
                    if not theme and prompt_identity["theme"]:
                        theme = prompt_identity["theme"]
                    # Extract workspace name from the prompt's opening line
                    workspace = extract_workspace_from_prompt(prompt_content)
                except Exception as e:
                    print(f"Warning: Cannot read prompt {resolved_prompt}: {e}", file=sys.stderr)

        # Resolve the definitive avatar codename (may differ from filename for role-named files)
        character = resolve_avatar(team_id, filename_character, developer, avatars_dir)

        # Fall back to character/team theme lookup if persona doesn't have Uniform Color
        if not theme:
            theme = CHARACTER_THEME.get(character, TEAM_DEFAULT_THEME.get(team_id, "OPERATIONS"))

        # Derive optional fields
        # terminal_desc: workspace name from prompt opening line (e.g. "Engineering Lab"),
        #   falling back to role first clause or terminal_id.
        # location: formatted as "{short_team}: {office}" from parsed_location.
        # session_desc: "{TEAM} {TERMINAL} - {AREA}" using frontmatter description suffix.
        # section: uppercase workspace name for panel section header (e.g. "CHANCELLOR'S OFFICE").
        frontmatter_desc = frontmatter.get("description", "")
        terminal_desc = infer_terminal_desc(terminal_id, role, workspace)
        location = infer_location(team_id, team_name, character, parsed_location)
        session_desc = infer_session_desc(team_id, terminal_id, role, frontmatter_desc)

        # Derive section label: workspace name in uppercase (panel section header).
        # Priority: workspace from prompt opening line → office part of location → empty.
        section = ""
        if workspace:
            section = workspace.upper()
        elif location and ": " in location:
            section = location.split(": ", 1)[1].upper()

        # Look up AMB handle by developer name (fuzzy — handles rank prefix differences)
        amb_handle = fuzzy_amb_handle(developer, amb_handles)

        # Build JSON data
        data = {
            "team":         team_id,
            "developer":    developer,
            "role":         role,
            "location":     location,
            "terminal":     terminal_id,
            "terminal_desc": terminal_desc,
            "session_desc": session_desc,
            "section":      section,
            "theme":        theme,
            "avatar":       character,
            "worktree":     "",
            "amb_handle":   amb_handle,
            "timestamp":    timestamp,
        }

        # Write to <kanban_tmp>/lcars-agent-<team>-<terminal_id>.json
        # This is the canonical location that agent-panel-display.sh reads.
        kanban_tmp = get_kanban_tmp_dir(team_id)
        out_path = kanban_tmp / f"lcars-agent-{team_id}-{terminal_id}.json"

        # Also write a legacy copy to /tmp/ for banner scripts that still read
        # from /tmp/lcars-agent-<team>-<agent>.json during session startup.
        legacy_path = Path(f"/tmp/lcars-agent-{team_id}-{terminal_id}.json")

        json_str = json.dumps(data, indent=4)
        success = False
        try:
            out_path.write_text(json_str)
            print(f"  Wrote {out_path}")
            success = True
        except Exception as e:
            print(f"Warning: Cannot write {out_path}: {e}", file=sys.stderr)

        try:
            legacy_path.write_text(json_str)
        except Exception:
            pass  # Legacy /tmp/ write is best-effort; don't fail if it errors

        if success:
            written += 1

    if written == 0:
        print(f"Warning: No agent JSON files written for team '{team_id}'", file=sys.stderr)
        sys.exit(1)

    kanban_tmp = get_kanban_tmp_dir(team_id)
    print(f"  Agent panel JSON: {written} file(s) initialized for '{team_id}' → {kanban_tmp}")


if __name__ == "__main__":
    main()
