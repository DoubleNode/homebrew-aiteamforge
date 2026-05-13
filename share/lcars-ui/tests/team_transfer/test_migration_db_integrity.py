"""Tests for the SQLite integrity probe."""
from __future__ import annotations

import sqlite3
from pathlib import Path

from team_transfer.db_integrity import compare_probes, probe_db


def _make_db(path: Path, schema_version: int = 3, transactions: int = 10) -> None:
    conn = sqlite3.connect(str(path))
    cur = conn.cursor()
    cur.execute("CREATE TABLE schema_version (version INTEGER)")
    cur.execute("INSERT INTO schema_version VALUES (?)", (schema_version,))
    cur.execute("CREATE TABLE transactions (id INTEGER, amount REAL)")
    for i in range(transactions):
        cur.execute("INSERT INTO transactions VALUES (?, ?)", (i, i * 1.5))
    conn.commit()
    conn.close()


def test_probe_returns_present_false_when_missing(tmp_path):
    out = probe_db(tmp_path / "nope.db")
    assert out == {"present": False}


def test_probe_captures_schema_version_and_tables(tmp_path):
    db = tmp_path / "x.db"
    _make_db(db, schema_version=3, transactions=5)
    out = probe_db(db)
    assert out["present"]
    assert out["schema_version"] == 3
    assert "transactions" in out["tables"]
    assert "schema_version" in out["tables"]
    assert out["row_counts"]["transactions"] == 5


def test_compare_passes_when_identical(tmp_path):
    db = tmp_path / "x.db"
    _make_db(db, schema_version=3, transactions=10)
    cap = probe_db(db)
    cur = probe_db(db)
    issues = compare_probes(cap, cur)
    assert issues == []


def test_compare_detects_schema_version_drift(tmp_path):
    db1 = tmp_path / "a.db"
    db2 = tmp_path / "b.db"
    _make_db(db1, schema_version=3, transactions=10)
    _make_db(db2, schema_version=4, transactions=10)
    issues = compare_probes(probe_db(db1), probe_db(db2))
    assert any("schema_version mismatch" in i for i in issues)


def test_compare_detects_missing_tables(tmp_path):
    db1 = tmp_path / "a.db"
    db2 = tmp_path / "b.db"
    _make_db(db1, schema_version=3, transactions=10)
    # b.db lacks the transactions table
    conn = sqlite3.connect(str(db2))
    conn.execute("CREATE TABLE schema_version (version INTEGER)")
    conn.execute("INSERT INTO schema_version VALUES (3)")
    conn.commit()
    conn.close()
    issues = compare_probes(probe_db(db1), probe_db(db2))
    assert any("missing on destination" in i for i in issues)


def test_compare_tolerates_row_growth(tmp_path):
    db1 = tmp_path / "a.db"
    db2 = tmp_path / "b.db"
    _make_db(db1, transactions=10)
    _make_db(db2, transactions=20)  # grew
    issues = compare_probes(probe_db(db1), probe_db(db2))
    assert issues == []


def test_compare_flags_severe_row_loss(tmp_path):
    db1 = tmp_path / "a.db"
    db2 = tmp_path / "b.db"
    _make_db(db1, transactions=100)
    _make_db(db2, transactions=10)  # lost 90%
    issues = compare_probes(probe_db(db1), probe_db(db2))
    assert any("Row count" in i and "dropped" in i for i in issues)


def test_compare_reports_missing_db(tmp_path):
    db = tmp_path / "exists.db"
    _make_db(db)
    cap = probe_db(db)
    issues = compare_probes(cap, {"present": False})
    assert "DB file missing on destination" in issues
