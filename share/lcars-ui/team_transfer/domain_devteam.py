"""Domain 3: Dev-team team infrastructure at ~/dev-team/<team>/.

Personas, scripts, prompts, avatars, terminals, logos. Travels via the AITeamForge
setup channel.

Product root resolution (precedence, first match wins):
  1. explicit `root` argument (existing behaviour — callers/tests that already
     know the exact path).
  2. team_config['product_dir'] -> home / "dev-team" / <product_dir>. This is
     the PREFERRED key: LCARS's team-slug -> on-disk-asset-dir mapping is not
     1:1 (server.py's team_dir_map: medical-general -> medical,
     legal-coparenting -> legal, dns -> dns-framework, freelance-* ->
     freelance, ...), so team_config['team'] alone resolves to a path that
     does not exist for 11 of 17 canonical configs. `product_dir` is a bare
     directory NAME under ~/dev-team/ (e.g. "medical"), not a full path.
  3. team_config['team'] (LEGACY fallback, kept for backward compat with
     configs that have not yet been migrated to product_dir) ->
     home / "dev-team" / <team>.
  4. team_config is None -> home / "dev-team" (existing behaviour).

XACA-0954: a configured root that does not exist on this machine is a
FAIL-LOUD gap, never a silent empty block. Previously a missing root simply
registered an empty DomainBlock and returned 0 — indistinguishable from a
domain that is genuinely empty. That is how a medical-general export moved
~286KB of a ~30MB team and still printed "Zero untagged gaps": the real
product dir (~/dev-team/medical, holding tens of MB of personas/scripts/
avatars) was never found because the code looked for ~/dev-team/medical-general,
which does not exist. Every branch above now calls
manifest.add_missing_root(DOMAIN, path, reason, config_key) when the resolved
root is absent, so the generator can refuse to print an all-clear line while
gaps remain, and a warning is also printed to stderr for anyone watching a
terminal.

Optional config key `persona_dirs`: a list of EXTRA directories to walk in
this domain, in addition to the product root. This exists for layouts where
personas live ABOVE the product root — e.g. medical-general's real persona
tree is ~/medical/personas/ (46 files, avatar variants, terminal logos), one
level above home_relative_root "medical/general", so no channel rule ever
reaches it and the generic walk never discovers it. Entries may use the same
{home}/{root}/{team}/{claude_project_dir_name} placeholder tokens as the rest
of the config — resolved via channels.build_tokens/substitute_tokens (the
SAME mechanism default_rules() uses), not a second hand-rolled substituter.
Each existing entry is walked exactly like the product dir (same FileEntry
shape, PRESENT class, same channel resolution + AITEAMFORGE_PRODUCT safety
net). Each missing entry is recorded via add_missing_root with
config_key="persona_dirs" — same fail-loud rule as the product root. A
persona_dirs entry that is the product root itself, or nested inside it, is
walked once (product-root pass wins) to avoid double-counting files within
this domain's own scan.
"""
from __future__ import annotations

import sys
from pathlib import Path

from .channels import (
    AITEAMFORGE_PRODUCT,
    ChannelConfig,
    UNTAGGED,
    build_tokens,
    substitute_tokens,
)
from .checksum import is_excluded, safe_relpath, sha256_file, walk_files
from .manifest import EXACT, FileEntry, Manifest, PRESENT

DOMAIN = "devteam"


def inventory(
    manifest: Manifest,
    channels: ChannelConfig,
    root: Path | None = None,
    home: Path | None = None,
    team_config: dict | None = None,
) -> None:
    home = home or Path.home()

    devteam_root, root_config_key = _resolve_product_root(root, home, team_config)

    walked_roots: list[Path] = []

    if devteam_root.exists():
        _walk_into(manifest, channels, devteam_root, home)
        walked_roots.append(devteam_root)
    else:
        reason = (
            "configured product dir does not exist; nothing from this domain "
            "will be exported"
        )
        manifest.add_missing_root(DOMAIN, str(devteam_root), reason, root_config_key)
        print(
            f"WARNING [{DOMAIN}]: root does not exist (config_key={root_config_key!r}): "
            f"{devteam_root}",
            file=sys.stderr,
        )

    for extra in _persona_dirs(team_config, home):
        if _covered_by(extra, walked_roots):
            continue
        if extra.exists():
            _walk_into(manifest, channels, extra, home)
            walked_roots.append(extra)
        else:
            reason = (
                "configured persona_dirs entry does not exist; nothing from "
                "this path will be exported"
            )
            manifest.add_missing_root(DOMAIN, str(extra), reason, "persona_dirs")
            print(
                f"WARNING [{DOMAIN}]: persona_dirs entry does not exist: {extra}",
                file=sys.stderr,
            )

    # Always register the domain block, even when nothing was walked, so
    # downstream code indexing manifest.domains['devteam'] does not KeyError.
    # The gap itself is recorded separately via add_missing_root above — an
    # empty block here is no longer, on its own, evidence that the source was
    # actually empty.
    blk = manifest.domains.setdefault(DOMAIN, _empty_block())
    blk.stats = {"file_count": len(blk.files), "root": str(devteam_root)}


def _resolve_product_root(
    root: Path | None,
    home: Path,
    team_config: dict | None,
) -> tuple[Path, str]:
    """Return (resolved_root, config_key_used) per the precedence in the module docstring."""
    if root is not None:
        return root, "root"

    if team_config is not None:
        product_dir = team_config.get("product_dir")
        if product_dir:
            return home / "dev-team" / product_dir, "product_dir"
        team = team_config.get("team", "")
        return home / "dev-team" / team, "team"

    return home / "dev-team", "root"


def _persona_dirs(team_config: dict | None, home: Path) -> list[Path]:
    """Resolve the optional `persona_dirs` config list, with token substitution."""
    if not team_config:
        return []
    raw = team_config.get("persona_dirs") or []
    if not raw:
        return []
    tokens = build_tokens(team_config, str(home))
    out: list[Path] = []
    for entry in raw:
        resolved = substitute_tokens(str(entry), tokens)
        out.append(Path(resolved))
    return out


def _covered_by(candidate: Path, walked_roots: list[Path]) -> bool:
    """True if `candidate` equals or is nested inside an already-walked root."""
    try:
        candidate_r = candidate.resolve()
    except OSError:
        candidate_r = candidate
    for walked in walked_roots:
        try:
            walked_r = walked.resolve()
        except OSError:
            walked_r = walked
        if candidate_r == walked_r:
            return True
        try:
            candidate_r.relative_to(walked_r)
            return True
        except ValueError:
            continue
    return False


def _walk_into(manifest: Manifest, channels: ChannelConfig, walk_root: Path, home: Path) -> None:
    for p in walk_files(walk_root):
        abs_path = str(p)
        ch = channels.resolve(abs_path)
        if ch == UNTAGGED:
            ch = AITEAMFORGE_PRODUCT  # safety net for new files in this tree
        fe = FileEntry(
            path=abs_path,
            relpath=safe_relpath(p, home),
            sha256=None,  # PRESENT class: installer mutates; SHA would false-FAIL
            size=p.stat().st_size,
            mtime=p.stat().st_mtime,
            cls=PRESENT,  # ADR §3.2: aiteamforge_product is PRESENT-only
            channel=ch,
            domain=DOMAIN,
        )
        manifest.add_file(DOMAIN, fe)


def _safe_sha(p: Path) -> str | None:
    try:
        return sha256_file(p)
    except (OSError, PermissionError):
        return None


def _empty_block():
    from .manifest import DomainBlock
    return DomainBlock()
