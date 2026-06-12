"""Content-based category classifier for TimePad time entries.

EPIC-0039 Child B (XACA-0620) — relocated and generalized from the retired
Bandwear-only ``timeapp_tags.py``.

This module maps a time-entry description to one or more human-readable
**category names** (e.g. "Development", "Research") using keyword heuristics.
It is intentionally a *name* classifier only — it carries NO TimePad tag UUIDs.

Why no UUIDs here (hard rebrand / cutover, XACA-0619):
  The legacy module hardcoded six tag UUIDs issued by the now-retired legacy
  time-tracking database. Those IDs are invalid against timepad.io and
  must never be reintroduced. Under the XACA-0619 schema each team carries a
  single ``tagId`` in ``timepad_config.json``; the dispatcher applies that
  configured tag to the entry. The category name produced here is used only for
  the human-readable description/log label, never as an API tag id.

Heuristic by design — keyword matching, not reasoning. Refine the keyword lists
as the work vocabulary grows.
"""
import re

# Category name -> list of lowercase substrings that imply that category.
# Order matters only for the stable de-duplication in classify_names().
_KEYWORDS = {
    "Development": [
        "fix", "bug", "implement", "build", "feature", "refactor", "lint",
        "test", "unit", "signing", "keystore", "minify", "proguard", "r8",
        "install", "apk", "scanner", "rotation", "version", "checker", "drawer",
        "packageinstaller", "download", "crash", "keyboard", "endpoint",
        "screen", "field", "login", "logout", "scan", "ui ", "viewmodel",
        "repository", "gradle", "manifest", "dispatcher", "hook", "script",
    ],
    "Design": [
        "design", "redesign", "architecture", "architect", "contract",
        "strategy", "mockup", "wireframe", "wire-frame", "ux", "ui/ux",
        "ux/ui", "layout", "prototype", "prototyp", "user flow", "userflow",
        "flowchart", "design system", "figma", "sketch", "theme", "styling",
        "look and feel", "blueprint", "information architecture",
        "api contract", "data model", "schema design", "accessibility",
        "a11y", "material design", "typography", "visual", "diagram",
        "specification",
    ],
    "Research": [
        "research", "investigat", "ingestion", "spike", "first pass",
        "reconcile", "drift", "debug", "explore", "wifi", "evaluat", "analy",
        "proof of concept", "feasibilit", "diagnos", "root cause",
        "experiment", "benchmark", "comparison", "compare", "assess",
        "discovery", "audit", "profil", "reproduce", "troubleshoot", "survey",
        "compatibilit", "vendor", "study", "look into", "figure out",
    ],
    "Admin": [
        "coordinat", "dependenc", "scope", "planning", "document", "backlog",
        "triage", "review",
    ],
    "Meeting": [
        "meeting", "demo", "standup", "scrum", "on-site", "onsite",
    ],
    "Client Call": [
        "stakeholder", "client call", "client meeting", "client sync",
    ],
}


def classify_names(description, coordination=False):
    """Return a stable, de-duplicated list of category names for a description.

    Args:
        description:   The time-entry description text.
        coordination:  When True and no keyword matches, fall back to ["Admin"]
                       (a bare-branch coordination session with no kanban item)
                       instead of ["Development"]. Generalizes the old
                       Bandwear-specific "Bandwear Android — <branch>" heuristic.

    Always returns at least one name.
    """
    text = (description or "").lower()
    names = []
    for name, kws in _KEYWORDS.items():
        if any(kw in text for kw in kws):
            names.append(name)

    if not names:
        names = ["Admin"] if coordination else ["Development"]

    seen, out = set(), []
    for n in names:
        if n not in seen:
            seen.add(n)
            out.append(n)
    return out


def classify_label(description, coordination=False):
    """Return a single comma-joined category label for logging/preview."""
    return ", ".join(classify_names(description, coordination=coordination))
