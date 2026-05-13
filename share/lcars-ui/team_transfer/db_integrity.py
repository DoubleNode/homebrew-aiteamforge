"""SQLite integrity probe for team databases.

Captured at generation; validated at verification.
Stdlib-only.
"""
from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any


def probe_db(db_path: Path) -> dict[str, Any]:
    """Return a structural snapshot of the SQLite database.

    Includes schema_version (if present), all user table names, and per-table row counts.
    Tolerates a missing file (returns {"present": False}).
    """
    if not db_path.exists():
        return {"present": False}
    try:
        # Open in URI ro mode to avoid creating WAL/SHM noise.
        uri = f"file:{db_path}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    except sqlite3.Error as e:
        return {"present": True, "error": f"open_failed: {e}"}

    out: dict[str, Any] = {"present": True, "size_bytes": db_path.stat().st_size}
    try:
        cur = conn.cursor()
        # schema_version table (project convention from XFIN-0001+)
        try:
            cur.execute("SELECT version FROM schema_version ORDER BY version DESC LIMIT 1")
            row = cur.fetchone()
            out["schema_version"] = row[0] if row else None
        except sqlite3.Error:
            out["schema_version"] = None

        cur.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name NOT LIKE 'sqlite_%' "
            "ORDER BY name"
        )
        tables = [r[0] for r in cur.fetchall()]
        out["tables"] = tables

        row_counts: dict[str, int] = {}
        for t in tables:
            try:
                cur.execute(f'SELECT COUNT(*) FROM "{t}"')
                row_counts[t] = cur.fetchone()[0]
            except sqlite3.Error as e:
                row_counts[t] = -1  # sentinel: query failed
        out["row_counts"] = row_counts
    finally:
        conn.close()
    return out


def compare_probes(captured: dict[str, Any], current: dict[str, Any], drift_tolerance: float = 0.95) -> list[str]:
    """Return a list of human-readable issues. Empty list = OK.

    drift_tolerance: row counts may drop to (drift_tolerance * captured) — anything lower fails.
    Row count INCREASES are always OK (data grows).
    """
    issues: list[str] = []
    if not current.get("present"):
        return ["DB file missing on destination"]
    if "error" in current:
        issues.append(f"DB open error: {current['error']}")
        return issues

    if captured.get("schema_version") != current.get("schema_version"):
        issues.append(
            f"schema_version mismatch: captured={captured.get('schema_version')!r} "
            f"current={current.get('schema_version')!r}"
        )

    cap_tables = set(captured.get("tables", []))
    cur_tables = set(current.get("tables", []))
    missing = sorted(cap_tables - cur_tables)
    if missing:
        issues.append(f"Tables missing on destination: {missing}")

    cap_counts = captured.get("row_counts", {})
    cur_counts = current.get("row_counts", {})
    for table, cap_n in cap_counts.items():
        if table not in cur_counts:
            continue  # already reported as missing table
        cur_n = cur_counts[table]
        if cur_n == -1:
            issues.append(f"Row count query failed for {table!r}")
            continue
        if cap_n > 0 and cur_n < int(cap_n * drift_tolerance):
            issues.append(
                f"Row count for {table!r} dropped: captured={cap_n} current={cur_n} "
                f"(below {int(drift_tolerance*100)}% tolerance)"
            )
    return issues
