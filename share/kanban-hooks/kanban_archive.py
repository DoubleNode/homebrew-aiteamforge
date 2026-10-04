"""
kanban_archive.py -- single item-ID allocator (XACA-1409, design section 3).

Purpose: ONE place that mints kanban item IDs from Python.  Before this module,
lcars-ui/integrations/import_issue.py computed max(live)+1 and never read or
wrote board['nextId'], so it could mint an ID that the shell `kb-backlog add`
(_kb_generate_id / _kb_validate_next_id in kanban-helpers.sh) also mints.  The
allocator here honours all three floors: nextId, live backlog, and (from E3) the
archive ledger.

Planned growth: E3 adds the archive accessor to this module (ledger reads,
archived-item lookup).  `ledger_max_id` is the single seam it will fill in.

Constraints: stdlib only; must run on /usr/bin/python3 (3.9) -- no `X | Y`
unions, no `match`.  Locking and saving are the CALLER's job.
"""

from typing import Any, Dict, Optional

# Hardcoded prefix fallback (same table import_issue.get_next_item_id used).
_TEAM_PREFIXES = {
    'academy': 'XACA',
    'ios': 'XIOS',
    'android': 'XAND',
    'firebase': 'XFIR',
    'freelance': 'XFRE',
    'mainevent': 'XME',
    'command': 'XCMD',
    'dns': 'XDNS',
    'legal-coparenting': 'XLCP',
}


def resolve_series(board: Optional[Dict[str, Any]], team: Optional[str] = None) -> str:
    """Return the item-ID prefix for a board.

    Rules (identical to the legacy get_next_item_id, pinned by
    tests/test_xaca1163_series_guard.py):
      1. board['series'] if the key is PRESENT -- returned verbatim, even if
         it is "" or None (Ruling 2 / E4: a present-but-bad value is a
         guard-detected drift, not something to paper over here).
      2. else the hardcoded table keyed on team.lower().
      3. else 'XGEN'.
    """
    if board and 'series' in board:
        return board['series']
    return _TEAM_PREFIXES.get((team or '').lower(), 'XGEN')


def ledger_max_id(board: Optional[Dict[str, Any]], series: str) -> int:
    """Highest numeric ID ever issued for `series` according to the archive ledger.

    Returns 0 today: no ledger exists yet.  E3 will return the ledger's
    maxIdBySeries[series] so archived (removed-from-live) IDs are never reissued.
    This is the single seam for that change.
    """
    return 0


def _live_max(board: Optional[Dict[str, Any]], series: str) -> int:
    """Max numeric suffix among live backlog ids of the form '<series>-<digits>'.

    Other prefixes, malformed ids and subitem-shaped ids (XACA-0001-001) are
    ignored.  Note `series + '-'` is evaluated per item, so a None series raises
    TypeError only for a non-empty backlog -- the same legacy behavior the
    series-guard tests document.
    """
    top = 0
    for item in (board or {}).get('backlog', []) or []:
        item_id = item.get('id', '') if isinstance(item, dict) else ''
        if not isinstance(item_id, str):
            continue
        if item_id.startswith(series + '-'):
            suffix = item_id[len(series) + 1:]
            if suffix.isdigit() and suffix.isascii():
                top = max(top, int(suffix))
    return top


def _coerce_next_id(value: Any) -> int:
    try:
        return max(int(value), 1)
    except (TypeError, ValueError):
        return 1


def allocate_item_id(board: Dict[str, Any], team: Optional[str] = None,
                     commit: bool = True) -> str:
    """Allocate the next item ID, e.g. 'XACA-0035'.

    n = max(nextId or 1, live_max + 1, ledger_max_id + 1).

    commit=True  : sets board['nextId'] = n + 1 in place (never decreases it).
    commit=False : pure peek; board is not mutated.

    The CALLER owns locking and persistence: call this under the board lock you
    already hold and save the board afterwards.  This function does no I/O.
    """
    series = resolve_series(board, team)
    n = max(
        _coerce_next_id(board.get('nextId')),
        _live_max(board, series) + 1,
        ledger_max_id(board, series) + 1,
    )
    if commit:
        board['nextId'] = max(_coerce_next_id(board.get('nextId')), n + 1)
    return "{}-{:04d}".format(series, n)
