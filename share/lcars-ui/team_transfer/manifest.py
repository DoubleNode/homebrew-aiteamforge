"""Manifest schema (v2): JSON-serialized inventory with per-file channel tagging.

Stdlib-only — the verifier consumes this.
"""
from __future__ import annotations

import json
import os
import socket
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2

# Verification class — how strictly the verifier checks each entry.
EXACT = "exact"     # SHA256 must match
PRESENT = "present" # Path must exist; content may legitimately drift
SCHEMA = "schema"   # Path must exist AND a structural probe must pass (e.g. DB schema_version)
VALID_CLASSES = (EXACT, PRESENT, SCHEMA)


@dataclass
class FileEntry:
    """One cataloged file."""
    path: str            # absolute path on the source machine
    relpath: str         # relative-to-home path (used by verifier for portable checks)
    sha256: str | None   # full-file SHA256 (None if class=present and we chose not to hash)
    size: int            # byte count
    mtime: float         # POSIX mtime
    cls: str             # one of VALID_CLASSES
    channel: str         # one of channels.ALL_CHANNELS (or "untagged" — gap)
    domain: str          # one of git_repo / kanban / devteam / knowledge / claude
    # Optional structural probe payload (e.g., {"schema_version": 3, "tables": [...]})
    probe: dict[str, Any] | None = None


@dataclass
class DomainBlock:
    files: list[FileEntry] = field(default_factory=list)
    stats: dict[str, Any] = field(default_factory=dict)


@dataclass
class Manifest:
    schema_version: int = SCHEMA_VERSION
    generated_at: str = ""
    source_hostname: str = ""
    source_user: str = ""
    source_team: str = ""        # team slug this archive was exported for (e.g. "finance"); base-compared at import to block wrong-team imports
    home: str = ""               # source $HOME — verifier rewrites this to its own $HOME
    channels: list[str] = field(default_factory=list)
    channel_stats: dict[str, dict[str, int]] = field(default_factory=dict)
    untagged_gaps: list[str] = field(default_factory=list)
    # XACA-0954: domain roots a config pointed at that do not exist on this machine.
    # A domain that silently registers an empty block is indistinguishable from a
    # domain that genuinely has no files, which is how an export dropped 105MB and
    # still printed "Zero untagged gaps". Entries are plain dicts (not a dataclass)
    # so _to_jsonable serializes them without a special case.
    # Shape: {"domain": str, "path": str, "reason": str, "config_key": str}
    missing_roots: list[dict[str, str]] = field(default_factory=list)
    domains: dict[str, DomainBlock] = field(default_factory=dict)
    teams: dict[str, dict[str, str]] = field(default_factory=dict)
    # Per-team source layout snapshot: { team_id: {"working_dir": "/abs/path"} }
    # Consumed by the destination's build_import_path_maps() to derive per-team
    # src_wd→dst_wd mappings that handle scope-suffix layout differences
    # (e.g. source ~/finance vs destination ~/finance/personal).

    def to_json(self) -> str:
        return json.dumps(_to_jsonable(self), indent=2, sort_keys=True)

    @classmethod
    def from_json(cls, s: str) -> "Manifest":
        raw = json.loads(s)
        m = cls(
            schema_version=raw.get("schema_version", 1),
            generated_at=raw.get("generated_at", ""),
            source_hostname=raw.get("source_hostname", ""),
            source_user=raw.get("source_user", ""),
            source_team=raw.get("source_team", ""),
            home=raw.get("home", ""),
            channels=raw.get("channels", []),
            channel_stats=raw.get("channel_stats", {}),
            untagged_gaps=raw.get("untagged_gaps", []),
            missing_roots=raw.get("missing_roots", []),
            teams=raw.get("teams", {}),
        )
        for dname, dblock in raw.get("domains", {}).items():
            files = [
                FileEntry(
                    path=f["path"],
                    relpath=f["relpath"],
                    sha256=f.get("sha256"),
                    size=f["size"],
                    mtime=f["mtime"],
                    cls=f["cls"],
                    channel=f["channel"],
                    domain=f["domain"],
                    probe=f.get("probe"),
                )
                for f in dblock.get("files", [])
            ]
            m.domains[dname] = DomainBlock(files=files, stats=dblock.get("stats", {}))
        return m

    def add_file(self, domain: str, entry: FileEntry) -> None:
        self.domains.setdefault(domain, DomainBlock()).files.append(entry)

    def add_missing_root(
        self,
        domain: str,
        path: str,
        reason: str,
        config_key: str = "",
    ) -> None:
        """Record a configured domain root that does not exist on this machine.

        XACA-0954: this is the fail-loud counterpart to a domain returning an
        empty block. The generator surfaces these alongside untagged gaps and
        refuses to print the all-clear line while any are recorded.

        Idempotent on (domain, path) so a re-scan cannot inflate the count.
        """
        key = (domain, str(path))
        for existing in self.missing_roots:
            if (existing.get("domain"), existing.get("path")) == key:
                return
        self.missing_roots.append({
            "domain": domain,
            "path": str(path),
            "reason": reason,
            "config_key": config_key,
        })

    def collect_missing_roots(self) -> list[dict[str, str]]:
        """Return recorded missing roots, sorted for stable output."""
        self.missing_roots.sort(key=lambda r: (r.get("domain", ""), r.get("path", "")))
        return self.missing_roots

    def recompute_channel_stats(self) -> None:
        from .channels import ALL_CHANNELS, UNTAGGED
        stats: dict[str, dict[str, int]] = {c: {"file_count": 0, "total_bytes": 0} for c in ALL_CHANNELS}
        for d in self.domains.values():
            for fe in d.files:
                if fe.channel == UNTAGGED:
                    continue
                bucket = stats.setdefault(fe.channel, {"file_count": 0, "total_bytes": 0})
                bucket["file_count"] += 1
                bucket["total_bytes"] += fe.size
        self.channel_stats = stats

    def collect_untagged(self) -> list[str]:
        from .channels import UNTAGGED
        gaps = []
        for d in self.domains.values():
            for fe in d.files:
                if fe.channel == UNTAGGED:
                    gaps.append(fe.path)
        gaps.sort()
        self.untagged_gaps = gaps
        return gaps


def _to_jsonable(obj: Any) -> Any:
    if isinstance(obj, (Manifest, DomainBlock, FileEntry)):
        d = asdict(obj)
        return _to_jsonable(d)
    if isinstance(obj, dict):
        return {k: _to_jsonable(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_to_jsonable(v) for v in obj]
    return obj


def new_manifest() -> Manifest:
    """Create a manifest pre-populated with source metadata."""
    from .channels import ALL_CHANNELS
    teams_snapshot: dict[str, dict[str, str]] = {}
    try:
        # Import is local + best-effort: manifest must still succeed if
        # aiteamforge_paths is unavailable (tests, partial installs).
        import sys as _sys
        from pathlib import Path as _P
        _hooks = _P(__file__).resolve().parent.parent.parent / "kanban-hooks"
        if str(_hooks) not in _sys.path:
            _sys.path.insert(0, str(_hooks))
        from aiteamforge_paths import load_config as _load_config
        cfg = _load_config()
        for slug, entry in (cfg.get("teams") or {}).items():
            wd = (entry or {}).get("working_dir", "")
            if wd:
                teams_snapshot[slug] = {"working_dir": str(_P(wd).expanduser())}
    except Exception:
        pass
    return Manifest(
        schema_version=SCHEMA_VERSION,
        generated_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        source_hostname=socket.gethostname(),
        source_user=os.environ.get("USER", ""),
        home=str(Path.home()),
        channels=list(ALL_CHANNELS),
        teams=teams_snapshot,
    )
