"""Transfer-channel resolution.

Every cataloged file is tagged with exactly one channel. A file with no channel rule is
"untagged" and counts as a CRITICAL gap reported at generation time.

Stdlib-only (the verifier imports this).
"""
from __future__ import annotations

import fnmatch
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# Channel identifiers. Order is for display.
GIT = "git"
EXPORT = "export"
SECRETS_EXPORT = "secrets_export"
AITEAMFORGE = "aiteamforge"
ICLOUD_EXCLUDED = "icloud_excluded"
UNTAGGED = "untagged"  # sentinel — never appears in a final manifest

ALL_CHANNELS = (GIT, EXPORT, SECRETS_EXPORT, AITEAMFORGE, ICLOUD_EXCLUDED)

# Packaged default config directory (relative to this file).
_PACKAGE_CONFIG_DIR = Path(__file__).parent / "config"


@dataclass
class ChannelRule:
    """One mapping rule. The first matching rule wins."""
    pattern: str  # glob, matched against the absolute path
    channel: str

    def matches(self, abs_path: str) -> bool:
        return fnmatch.fnmatchcase(abs_path, self.pattern)


@dataclass
class ChannelConfig:
    """Resolved channel configuration. Later overrides win.

    Defaults are baked into the per-team YAML config (lcars-ui/team_transfer/config/<team>.yaml);
    an optional external YAML override file can be layered on top for per-path corrections
    without code changes (see build_config's yaml_overrides parameter).
    """
    rules: list[ChannelRule] = field(default_factory=list)

    def resolve(self, abs_path: str) -> str:
        """Return one of ALL_CHANNELS, or UNTAGGED if no rule matches."""
        # Walk in reverse so later rules (loaded last) take precedence.
        for rule in reversed(self.rules):
            if rule.matches(abs_path):
                return rule.channel
        return UNTAGGED


def load_team_config(team: str, *, config_dir: Path | None = None) -> dict:
    """Load and return the raw team YAML config as a dict.

    Resolution order:
      1. Explicit config_dir/<team>.yaml (if config_dir provided)
      2. Packaged default: team_transfer/config/<team>.yaml
      3. FileNotFoundError

    Tokens in the returned config are NOT yet resolved — call resolve_tokens() or
    default_rules() which handles token substitution.
    """
    candidates: list[Path] = []
    if config_dir is not None:
        candidates.append(Path(config_dir) / f"{team}.yaml")
    candidates.append(_PACKAGE_CONFIG_DIR / f"{team}.yaml")

    for path in candidates:
        if path.exists():
            text = path.read_text(encoding="utf-8")
            return _parse_team_yaml(text)

    searched = ", ".join(str(c) for c in candidates)
    raise FileNotFoundError(f"No team config found for {team!r}. Searched: {searched}")


def default_rules(team_config: dict, home: Path | None = None) -> list[ChannelRule]:
    """Build the baseline channel mapping from a team config dict.

    Reads the 'defaults.rules' list from team_config. Each rule entry has 'pattern'
    and 'channel' keys. Token substitution is applied to the pattern:
      {home}                  — str(home or Path.home())
      {root}                  — team_config['home_relative_root']
      {team}                  — team_config['team']
      {claude_project_dir_name} — team_config.get('claude_project_dir_name', '')

    Order: more-specific patterns AFTER more-general ones (later rules win).
    """
    h = str(home or Path.home())
    tokens = _build_tokens(team_config, h)

    rules: list[ChannelRule] = []
    for entry in team_config.get("defaults", {}).get("rules", []):
        raw_pattern = entry.get("pattern", "")
        channel = entry.get("channel", "")
        if not raw_pattern or not channel:
            continue
        pattern = _substitute(raw_pattern, tokens)
        rules.append(ChannelRule(pattern, channel))

    # icloud_excluded shorthand list
    for glob in team_config.get("defaults", {}).get("icloud_excluded", []):
        pattern = _substitute(glob, tokens)
        rules.append(ChannelRule(pattern, ICLOUD_EXCLUDED))

    return rules


def _build_tokens(team_config: dict, home_str: str) -> dict[str, str]:
    """Build the substitution token dict for a team config."""
    root = team_config.get("home_relative_root", "")
    team = team_config.get("team", "")
    claude_dir = team_config.get("claude_project_dir_name", "")
    return {
        "{home}": home_str,
        "{root}": root,
        "{team}": team,
        "{claude_project_dir_name}": claude_dir,
    }


def _substitute(s: str, tokens: dict[str, str]) -> str:
    for tok, val in tokens.items():
        s = s.replace(tok, val)
    return s


def load_overrides_yaml(yaml_path: Path) -> list[ChannelRule]:
    """Parse the YAML override file. Tolerates absent file (returns empty list).

    Format:
        overrides:
          - pattern: "<glob>"
            channel: "<channel-name>"
        icloud_excluded:
          - "<glob>"
          - "<glob>"

    No PyYAML dependency — we parse the trivial subset we need by hand to keep the
    verifier stdlib-only.
    """
    if not yaml_path.exists():
        return []
    text = yaml_path.read_text(encoding="utf-8")
    return _parse_minimal_yaml_overrides(text)


def _parse_minimal_yaml_overrides(text: str) -> list[ChannelRule]:
    """Parse the limited YAML subset used by the overrides file passed to load_overrides_yaml.

    Two top-level keys: `overrides` (list of {pattern, channel} maps) and
    `icloud_excluded` (list of glob strings). Supports `#` comments and quoted strings.
    No nesting beyond what's documented above.
    """
    rules: list[ChannelRule] = []
    section: str | None = None
    pending_pattern: str | None = None
    pending_channel: str | None = None

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        # Top-level key
        if line and not line.startswith((" ", "\t")) and line.endswith(":"):
            # Flush any pending override pair before changing sections.
            if pending_pattern and pending_channel:
                rules.append(ChannelRule(pending_pattern, pending_channel))
                pending_pattern = pending_channel = None
            section = line[:-1].strip()
            continue

        stripped = line.strip()
        if section == "overrides":
            # Lines look like:  - pattern: "..."   then  channel: "..."
            if stripped.startswith("- pattern:"):
                # A previous unfinished pair? flush.
                if pending_pattern and pending_channel:
                    rules.append(ChannelRule(pending_pattern, pending_channel))
                    pending_pattern = pending_channel = None
                pending_pattern = _yaml_value(stripped[len("- pattern:"):])
            elif stripped.startswith("pattern:"):
                if pending_pattern and pending_channel:
                    rules.append(ChannelRule(pending_pattern, pending_channel))
                    pending_pattern = pending_channel = None
                pending_pattern = _yaml_value(stripped[len("pattern:"):])
            elif stripped.startswith("channel:"):
                pending_channel = _yaml_value(stripped[len("channel:"):])
                if pending_pattern and pending_channel:
                    rules.append(ChannelRule(pending_pattern, pending_channel))
                    pending_pattern = pending_channel = None
        elif section == "icloud_excluded":
            if stripped.startswith("-"):
                pat = _yaml_value(stripped[1:])
                rules.append(ChannelRule(pat, ICLOUD_EXCLUDED))

    # Flush trailing pair.
    if pending_pattern and pending_channel:
        rules.append(ChannelRule(pending_pattern, pending_channel))
    return rules


def _yaml_value(s: str) -> str:
    s = s.strip()
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1]
    return s


def _parse_team_yaml(text: str) -> dict:
    """Parse the team YAML config file into a plain dict.

    Handles the schema used by team_transfer/config/<team>.yaml:
      - Scalar top-level keys (team, home_relative_root, board_filename, etc.)
      - defaults.rules: list of {pattern, channel} maps
      - defaults.icloud_excluded: list of glob strings
      - databases: list of {path, cls} maps
      - overrides: list of {pattern, channel} maps (user-editable slot for per-path corrections)

    No PyYAML dependency — stdlib-only hand parser for the subset we need.
    """
    result: dict = {
        "defaults": {"rules": [], "icloud_excluded": []},
        "databases": [],
        "overrides": [],
    }

    # Stack-based section tracking: section path as list of strings.
    # e.g. ["defaults"] or ["defaults", "rules"] or ["databases"]
    section_path: list[str] = []
    # Whether we're inside a list-item block (collecting key:value pairs into a pending dict).
    pending_item: dict | None = None

    def _flush_item():
        nonlocal pending_item
        if pending_item is None:
            return
        item = pending_item
        pending_item = None
        if section_path == ["defaults", "rules"] and item:
            result["defaults"]["rules"].append(item)
        elif section_path == ["databases"] and item:
            result["databases"].append(item)
        elif section_path == ["overrides"] and item:
            result["overrides"].append(item)

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue

        # Measure indentation.
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        # Top-level scalar or section key (indent == 0, ends with colon or has value).
        if indent == 0:
            _flush_item()
            section_path = []
            if ":" in stripped:
                key, _, val = stripped.partition(":")
                key = key.strip()
                val = val.strip()
                if val:
                    # Scalar value
                    result[key] = _yaml_value(val) if val else val
                else:
                    # Section start
                    section_path = [key]
            continue

        # Indent == 2: section member or nested section.
        if indent == 2:
            if stripped.startswith("- "):
                # List item under a top-level section.
                _flush_item()
                item_val = stripped[2:].strip()
                if ":" in item_val:
                    # Inline dict start: "- pattern: ..."
                    k, _, v = item_val.partition(":")
                    pending_item = {k.strip(): _yaml_value(v.strip())}
                else:
                    # Plain string list item.
                    if section_path == ["defaults"]:
                        pass  # shouldn't happen
                    elif section_path == ["defaults", "icloud_excluded"]:
                        result["defaults"]["icloud_excluded"].append(_yaml_value(item_val))
            elif ":" in stripped:
                key, _, val = stripped.partition(":")
                key = key.strip()
                val = val.strip()
                if val:
                    # Scalar in current section, e.g. "rules:" with no value would not land here
                    # but "icloud_excluded: []" or similar might.
                    if section_path:
                        # Could be a sub-section scalar (e.g. board_filename: ...) — treat as top-level
                        result[key] = _yaml_value(val)
                else:
                    # Sub-section key e.g. "rules:" under "defaults:"
                    if section_path:
                        section_path = [section_path[0], key]
            continue

        # Indent == 4: key inside a list-item dict, OR plain list item under a level-2 section.
        if indent == 4:
            if stripped.startswith("- "):
                _flush_item()
                item_val = stripped[2:].strip()
                if ":" in item_val:
                    k, _, v = item_val.partition(":")
                    pending_item = {k.strip(): _yaml_value(v.strip())}
                else:
                    # Plain string under defaults.icloud_excluded or similar.
                    if section_path[-1:] == ["icloud_excluded"]:
                        result["defaults"]["icloud_excluded"].append(_yaml_value(item_val))
            elif ":" in stripped and pending_item is not None:
                k, _, v = stripped.partition(":")
                pending_item[k.strip()] = _yaml_value(v.strip())
            elif ":" in stripped:
                # Scalar key at indent 4 inside a known list section — add to pending
                pass
            continue

        # Indent == 6: continuation keys inside a list-item dict.
        if indent == 6 and pending_item is not None and ":" in stripped:
            k, _, v = stripped.partition(":")
            pending_item[k.strip()] = _yaml_value(v.strip())

    _flush_item()
    return result


def build_config(
    home: Path | None = None,
    yaml_overrides: Path | None = None,
    team: str | None = None,
    team_config: dict | None = None,
    team_config_dir: Path | None = None,
) -> ChannelConfig:
    """Compose the full rule list: team defaults first, then YAML overrides (which win).

    Args:
        home: Override for Path.home(). Defaults to current user's home.
        yaml_overrides: Path to an optional user-facing YAML override file (overrides: section).
        team: Team name to load packaged defaults for (e.g. 'finance'). If None and
              team_config is None, no defaults are loaded.
        team_config: Pre-loaded team config dict (from load_team_config). Takes precedence
                     over the `team` argument.
        team_config_dir: Optional directory to search for team YAML before package defaults.
    """
    rules: list[ChannelRule] = []

    # Load team config if requested.
    cfg: dict | None = team_config
    if cfg is None and team is not None:
        cfg = load_team_config(team, config_dir=team_config_dir)

    if cfg is not None:
        rules.extend(default_rules(cfg, home=home))

    if yaml_overrides:
        rules.extend(load_overrides_yaml(yaml_overrides))

    return ChannelConfig(rules=rules)
