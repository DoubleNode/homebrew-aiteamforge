"""Tests for the manifest schema serialization."""
from __future__ import annotations

from team_transfer import channels
from team_transfer.manifest import EXACT, FileEntry, Manifest, PRESENT, SCHEMA_VERSION, new_manifest


def test_new_manifest_has_metadata():
    m = new_manifest()
    assert m.schema_version == SCHEMA_VERSION
    assert m.generated_at  # ISO timestamp
    assert m.home  # source HOME path
    assert m.channels == list(channels.ALL_CHANNELS)


def test_round_trip_serialization():
    m = new_manifest()
    fe = FileEntry(
        path="/x/y/z.txt",
        relpath="y/z.txt",
        sha256="a" * 64,
        size=42,
        mtime=1234567.0,
        cls=EXACT,
        channel=channels.GIT,
        domain="git_repo",
    )
    m.add_file("git_repo", fe)
    m.recompute_channel_stats()
    blob = m.to_json()

    m2 = Manifest.from_json(blob)
    assert m2.schema_version == m.schema_version
    assert m2.home == m.home
    assert "git_repo" in m2.domains
    assert len(m2.domains["git_repo"].files) == 1
    fe2 = m2.domains["git_repo"].files[0]
    assert fe2.path == fe.path
    assert fe2.sha256 == fe.sha256
    assert fe2.cls == fe.cls
    assert fe2.channel == fe.channel


def test_recompute_channel_stats_counts_correctly():
    m = new_manifest()
    m.add_file("git_repo", FileEntry(
        path="/a", relpath="a", sha256="x", size=10, mtime=0, cls=EXACT, channel=channels.GIT, domain="git_repo",
    ))
    m.add_file("git_repo", FileEntry(
        path="/b", relpath="b", sha256="y", size=20, mtime=0, cls=EXACT, channel=channels.GIT, domain="git_repo",
    ))
    m.add_file("kanban", FileEntry(
        path="/c", relpath="c", sha256="z", size=100, mtime=0, cls=EXACT, channel=channels.EXPORT, domain="kanban",
    ))
    m.recompute_channel_stats()
    assert m.channel_stats[channels.GIT]["file_count"] == 2
    assert m.channel_stats[channels.GIT]["total_bytes"] == 30
    assert m.channel_stats[channels.EXPORT]["file_count"] == 1
    assert m.channel_stats[channels.EXPORT]["total_bytes"] == 100


def test_collect_untagged_finds_untagged_entries():
    m = new_manifest()
    m.add_file("git_repo", FileEntry(
        path="/orphan", relpath="orphan", sha256=None, size=1, mtime=0, cls=PRESENT, channel=channels.UNTAGGED, domain="git_repo",
    ))
    m.add_file("git_repo", FileEntry(
        path="/known", relpath="known", sha256="x", size=1, mtime=0, cls=EXACT, channel=channels.GIT, domain="git_repo",
    ))
    gaps = m.collect_untagged()
    assert gaps == ["/orphan"]
    assert m.untagged_gaps == ["/orphan"]


# XACA-0586-010: source_team round-trip and legacy default tests

def test_source_team_round_trips_through_json():
    """source_team set on a Manifest survives to_json -> from_json intact."""
    m = new_manifest()
    m.source_team = "finance"
    blob = m.to_json()
    m2 = Manifest.from_json(blob)
    assert m2.source_team == "finance"


def test_source_team_defaults_to_empty_for_legacy_manifests():
    """Legacy manifests (no source_team key) deserialize with source_team == ""."""
    import json
    raw = {
        "schema_version": 2,
        "generated_at": "2026-01-01T00:00:00+00:00",
        "source_hostname": "oldhost",
        "source_user": "user",
        "home": "/Users/user",
        "channels": [],
        "channel_stats": {},
        "untagged_gaps": [],
        "domains": {},
        "teams": {},
        # source_team intentionally absent — simulates a pre-XACA-0586 manifest
    }
    m = Manifest.from_json(json.dumps(raw))
    assert m.source_team == ""


def test_source_team_scope_suffix_round_trips():
    """scope-suffixed team slug (e.g. 'finance-personal') round-trips correctly."""
    m = new_manifest()
    m.source_team = "finance-personal"
    m2 = Manifest.from_json(m.to_json())
    assert m2.source_team == "finance-personal"
