"""Domain 4: Knowledge base.

Scans agent-tier and subject-tier knowledge dirs for the team's personas.

XACA-0954-003: the persona list is REQUIRED from team_config['personas'] — there
is no guessed fallback any more. The old `_LEGACY_FINANCE_PERSONAS` constant
scanned ("quark", "nog", "brunt", "rom", "zek") for every team whose config had
no `personas:` block, which was 17 of 17 canonical configs. Every non-finance
team silently inventoried finance's persona names (or, worse, none of them
resolved and the export just came up empty with no signal). Even for finance,
the fallback pointed at the wrong knowledge root: `~/knowledge/agents/quark` is
the shared/product Quark persona (Firebase/DS9), not finance's own
`~/knowledge-local/agents/quark-fin`. There was no compatibility worth
preserving, so it is gone. `personas` absent from team_config now reports a
missing-root gap via `manifest.add_missing_root()` (fail loud, never guessed);
`personas: []` is a legitimate declaration of "this team has no personas" and
scans nothing without raising a gap.

Knowledge roots (XACA-0954-003): scanned across MULTIPLE roots, since
PII-scoped teams (finance/medical/legal, XACA-0754) keep their personas out of
the shared `~/knowledge/` tree entirely, in `~/knowledge-local/` instead. The
default root set is `[~/knowledge, ~/knowledge-local]`; a caller may override
with a single `knowledge_root` (kept for existing callers) or an explicit list
via `knowledge_roots`. A DEFAULT root that doesn't exist on this machine is not
a gap — most machines have no PII-team knowledge and reporting one would spam
every non-PII export. A root that was EXPLICITLY configured (either kwarg) and
is absent on this machine IS a gap.

- Agent tier:   <root>/agents/<persona>/       (every configured root)
- Subject tier: <root>/subjects/<topic>/       (referenced by persona files, every configured root)
- Project tier: <repo_root>/kanban/knowledge/  (future-use; manifested if present)

Persona files for subject-reference scanning are resolved from
~/dev-team/<product_dir>/personas/agents/ when team_config is provided, where
`product_dir` falls back to team_config['team'] if the `product_dir` key isn't
present yet (it's being added to configs in parallel with this change). A
team may also declare `persona_dirs` in its config: an optional list of extra
directories (supporting the same {home}/{root}/{team} template tokens as
channel rule patterns) to scan for persona files beyond the standard tree —
e.g. medical-general's real persona tree lives at ~/medical/personas/, not
~/dev-team/medical/personas/.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from .channels import USER_STATE, ChannelConfig, UNTAGGED, build_tokens, substitute_tokens
from .checksum import sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest

DOMAIN = "knowledge"


def inventory(
    manifest: Manifest,
    channels: ChannelConfig,
    *,
    knowledge_root: Path | None = None,
    knowledge_roots: list[Path] | None = None,
    repo_root: Path | None = None,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    _home = home or Path.home()
    project_kn = (repo_root or (_home / "finance" / "personal")) / "kanban" / "knowledge"

    # --- Resolve knowledge roots -------------------------------------------------
    # `knowledge_root` (existing kwarg, single override) takes precedence over
    # `knowledge_roots` (new kwarg, explicit list) if both are somehow passed —
    # existing callers (generator.py, tests) only ever pass knowledge_root.
    if knowledge_root is not None:
        roots = [Path(knowledge_root)]
        roots_explicit = True
        roots_config_key = "knowledge_root"
    elif knowledge_roots is not None:
        roots = [Path(r) for r in knowledge_roots]
        roots_explicit = True
        roots_config_key = "knowledge_roots"
    else:
        roots = [_home / "knowledge", _home / "knowledge-local"]
        roots_explicit = False
        roots_config_key = ""

    existing_roots: list[Path] = []
    missing_roots: list[Path] = []
    for root in roots:
        if root.exists():
            existing_roots.append(root)
        else:
            missing_roots.append(root)
            if roots_explicit:
                manifest.add_missing_root(
                    DOMAIN,
                    str(root),
                    "knowledge root was explicitly configured but does not exist on this machine",
                    roots_config_key,
                )
                print(
                    f"[domain_knowledge] WARNING: configured knowledge root missing: {root}",
                    file=sys.stderr,
                )
            # else: a default root missing (e.g. no ~/knowledge-local on this
            # machine) is expected and NOT a gap — don't spam every non-PII export.

    # --- Determine team + product_dir (for the subject-reference scan) ----------
    team = (team_config or {}).get("team", "")
    product_dir = (team_config or {}).get("product_dir") or team

    # --- Determine persona list — REQUIRED, no guessed fallback -----------------
    personas: tuple[str, ...]
    if team_config is not None and "personas" in team_config:
        # Present — may legitimately be an empty list (team has no personas).
        personas = tuple(team_config["personas"])
    else:
        # Absent — fail loud, never guess. Report a gap and scan nothing for
        # this domain's persona-derived tiers; other domains are unaffected.
        personas = ()
        gap_path = str(roots[0]) if roots else str(_home / "knowledge")
        manifest.add_missing_root(
            DOMAIN,
            gap_path,
            "team_config has no 'personas' key — cannot inventory agent-tier knowledge "
            "without an explicit persona list (no guessed fallback)",
            "personas",
        )
        print(
            "[domain_knowledge] WARNING: team_config missing 'personas' key — "
            "skipping agent-tier knowledge scan (no fallback list is scanned).",
            file=sys.stderr,
        )

    seen_paths: set[str] = set()
    personas_not_found: list[str] = []

    # Agent-tier dirs (one per persona; some may not yet exist in a given root).
    for persona in personas:
        found_for_persona = False
        for root in existing_roots:
            agent_dir = root / "agents" / persona
            if agent_dir.exists():
                found_for_persona = True
                for p in walk_files(agent_dir):
                    _emit_dedup(manifest, p, _home, channels, seen_paths)
        if not found_for_persona:
            personas_not_found.append(persona)

    if personas_not_found:
        print(
            "[domain_knowledge] WARNING: personas configured but not found in any "
            f"knowledge root: {sorted(personas_not_found)}",
            file=sys.stderr,
        )

    # Subject-tier dirs that this team's personas reference.
    # Heuristic: scan persona files in ~/dev-team/<product_dir>/personas/agents/
    # (plus any team_config['persona_dirs'] extras) for `subjects/<topic>` references.
    extra_persona_dirs: list[Path] = []
    if team_config and team_config.get("persona_dirs"):
        tokens = build_tokens(team_config, str(_home))
        for raw in team_config["persona_dirs"]:
            extra_persona_dirs.append(Path(substitute_tokens(raw, tokens)))

    referenced_subjects = _scan_referenced_subjects(
        _home, product_dir=product_dir, extra_dirs=extra_persona_dirs,
    )
    for topic in referenced_subjects:
        for root in existing_roots:
            sub_dir = root / "subjects" / topic
            if sub_dir.exists():
                for p in walk_files(sub_dir):
                    _emit_dedup(manifest, p, _home, channels, seen_paths)

    # Project-tier (in-repo).
    if project_kn.exists():
        for p in walk_files(project_kn):
            _emit_dedup(manifest, p, _home, channels, seen_paths)

    # Legacy in-repo TEAM/INDEX.md.
    legacy_team = (repo_root or (_home / "finance" / "personal")) / "knowledge" / "TEAM" / "INDEX.md"
    if legacy_team.exists():
        _emit_dedup(manifest, legacy_team, _home, channels, seen_paths)

    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {
        "file_count": len(blk.files),
        "personas_inventoried": list(personas),
        "personas_not_found": sorted(personas_not_found),
        "subjects_inventoried": sorted(referenced_subjects),
        "knowledge_roots_scanned": [str(r) for r in existing_roots],
        "knowledge_roots_missing": [str(r) for r in missing_roots],
    }


def _scan_referenced_subjects(
    home: Path,
    *,
    product_dir: str = "",
    extra_dirs: list[Path] | None = None,
) -> set[str]:
    """Look in persona files for `subjects/<topic>` references.

    Scans the standard ~/dev-team/<product_dir>/personas/agents/ tree plus any
    `extra_dirs` (from team_config['persona_dirs'], already token-substituted)
    for teams whose real persona tree lives elsewhere.
    """
    out: set[str] = set()
    persona_dirs: list[Path] = []
    if product_dir:
        persona_dirs.append(home / "dev-team" / product_dir / "personas" / "agents")
    persona_dirs.extend(extra_dirs or [])
    if not persona_dirs:
        return out

    pat = re.compile(r"subjects/([a-z0-9_\-]+)/")
    seen: set[str] = set()
    for persona_dir in persona_dirs:
        if not persona_dir.exists():
            continue
        for p in persona_dir.glob("*.md"):
            try:
                resolved = str(p.resolve())
            except OSError:
                resolved = str(p)
            if resolved in seen:
                continue
            seen.add(resolved)
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for m in pat.finditer(text):
                out.add(m.group(1))
    return out


def _emit_dedup(
    manifest: Manifest,
    p: Path,
    home: Path,
    channels: ChannelConfig,
    seen_paths: set[str],
) -> None:
    """Emit a FileEntry unless this absolute path was already emitted.

    Two roots can independently hold a same-named persona dir (e.g. finance's
    `quark-fin` living only in ~/knowledge-local while a differently-scoped
    `quark` lives in ~/knowledge) — those are DISTINCT files at distinct
    absolute paths and both get emitted. The dedup guard only catches the case
    where the exact same absolute path would otherwise be walked/emitted twice
    (e.g. overlapping root configuration), not "same persona name in two
    roots" — that's the entire point of scanning multiple roots.
    """
    try:
        resolved = str(p.resolve())
    except OSError:
        resolved = str(p)
    if resolved in seen_paths:
        return
    seen_paths.add(resolved)
    _emit(manifest, p, home, channels)


def _emit(manifest: Manifest, p: Path, home: Path, channels: ChannelConfig) -> None:
    abs_path = str(p)
    ch = channels.resolve(abs_path)
    if ch == UNTAGGED:
        ch = USER_STATE
    fe = FileEntry(
        path=abs_path,
        relpath=p.relative_to(home).as_posix() if _under(p, home) else p.as_posix(),
        sha256=_safe_sha(p),
        size=p.stat().st_size,
        mtime=p.stat().st_mtime,
        cls=EXACT,
        channel=ch,
        domain=DOMAIN,
    )
    manifest.add_file(DOMAIN, fe)


def _safe_sha(p: Path) -> str | None:
    try:
        return sha256_file(p)
    except (OSError, PermissionError):
        return None


def _under(p: Path, root: Path) -> bool:
    try:
        p.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
