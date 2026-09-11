#!/usr/bin/env python3
"""
aiteamforge_registry.py — THE single Python read path for team registry fields.

XACA-1161-002 — read-path convergence (K830).

Why this module exists
----------------------
The registry has three stores, and they are NOT interchangeable:

  * ``aiteamforge_paths.DEFAULT_TEAMS`` — a named-field Python dict (15 teams,
    12 distinct fields, measured 2026-09-10).
  * ``homebrew-tap/libexec/lib/aiteamforge-paths.sh`` ``_AITEAMFORGE_DEFAULT_TEAMS_DATA``
    — a POSITIONAL 7-column tab table (13 rows x 7 cols, measured 2026-09-10;
    it was 12 until XACA-1068 added ``spacedock``, which is exactly why the
    ROW COUNT is never pinned anywhere — only the COLUMN count is). Its column
    count is a shipped parser contract on every consumer machine and CANNOT
    grow. It can express only 6 of the registry's 17 fields.
  * ``~/.aiteamforge/team-paths.json`` — the per-machine overlay (26 teams,
    17 distinct fields on the authoring host; host-dependent by construction).

K830: when one seed literally cannot represent a field, you cannot fix drift by
mirroring writes into both seeds. You converge on READ — one place decides the
canonical shape, and every seed is normalized through it. This module is that
place for Python. **It deliberately does not parse the shell table**: shell
consumers read the shell table, Python consumers read the Python tiers, and the
two are reconciled by a drift *report* (XACA-1161-007), never by one silently
re-deriving the other.

What it replaces
----------------
Measured on the pre-XACA-1161 tree, six accessors in ``aiteamforge_paths.py``
each implemented a DIFFERENT precedence chain for the same registry:

  ===========================  ==========================  ====================
  accessor                     falls back to DEFAULT_TEAMS  gate
  ===========================  ==========================  ====================
  get_team_kanban_dir          no                          --
  get_team_working_dir         no                          --
  get_team_lcars_port          no                          --
  get_team_code                yes                         truthiness (``if code:``)
  get_team_primary_host        yes                         key presence
  board_less_alias_of          yes                         sentinel membership
  ===========================  ==========================  ====================

That is K501 sibling-heuristic drift inside one file: six sites answering "where
does this field come from?" three different ways. This module answers it once.

Resolution order (the precedence chain)
---------------------------------------
For a field F on team T, tiers are consulted in this order:

  1. **OVERLAY** — ``load_config()["teams"][T]``, the per-machine
     ``team-paths.json``. Wins ties because it is the machine's authoritative
     registry: it is what ``kb-init-team`` writes, what ``kb-port-reconcile``
     reconciles, and what every shell accessor already reads first.

     **K962 — canonical designates which source wins a TIE, not which source is
     currently CORRECT.** This is not a formality. Measured live on the
     authoring host 2026-09-10, the overlay's ``command`` entry carries
     ``kanban_dir`` = a pytest fixture path under ``$TMPDIR`` while
     ``DEFAULT_TEAMS`` carries the real
     ``/Users/Shared/Development/Main Event/dev-team/kanban``. The overlay is
     the canonical side AND the wrong side, simultaneously. This resolver will
     faithfully return the overlay value, because a resolver that "corrects"
     toward whichever tier looks healthier is a mechanism for propagating stale
     data with full confidence. Detecting that divergence is a *reporting*
     job (XACA-1161-007), and the report must not prescribe a direction.

  2. **DEFAULT_TEAMS** — the baked-in Python seed. This is the
     MIGRATION-TOLERANCE tier, and that is its whole justification: an overlay
     written before a field existed (a v1/v2 config with no ``anthropic_*``
     keys, or any overlay predating ``primary_host``) must still resolve. It is
     NOT a "more correct" tier and must never be treated as one.

  3. **DERIVED** — only for fields with an explicitly registered deriver, and
     only when tiers 1 and 2 did not declare the field at all. Exactly ONE
     field has a deriver today: ``working_dir``, computed as
     ``kanban_dir.parent`` — an invariant DEFAULT_TEAMS itself documents.

     **This tier never derives IDENTITY.** No deriver may invent a
     ``team_code``, a slug, or a port. K659 and XACA-1058 are explicit: a
     phantom-derived identity is worse than a ``KeyError``, because callers
     go on to mint item IDs against a code nothing else in the fleet
     recognizes. XACA-1058 deliberately removed one such heuristic; this
     module does not reintroduce that shape. Deriving a path from a *declared
     sibling field* is a different operation from guessing an identity nothing
     declared, and only the former is permitted here.

  4. **ABSENCE** — return ``ABSENT`` (or the caller's ``default``). Never a
     guess, never a phantom.

An unregistered TEAM (present in neither the overlay nor ``DEFAULT_TEAMS``)
raises :class:`UnknownTeamError` from every entry point. It is never resolved
to a default team and never derived. Note this means ``freelance`` and
``medical`` — which exist ONLY in the shell seed — raise here. That is the
correct and honest answer: Python genuinely does not know them, and the two
ways to make them "resolve" are parsing the shell table (re-coupling the seeds,
which K830 forbids) or deriving an identity (which K659 forbids).

Three states, per field — absence is NOT falsiness
--------------------------------------------------
Knowledge S002: *a collected zero or false is DATA, not absence.* Every field
resolves to one of three states, and collapsing the last two is the defect:

  * :attr:`FieldState.DECLARED`        — key present, real value (INCLUDING ``0`` / ``False``)
  * :attr:`FieldState.DECLARED_ABSENT` — key present, value is one of *this field's* absence sentinels
  * :attr:`FieldState.NOT_DECLARED`    — key genuinely absent from every tier

The sentinel set is **per field, never per group** — S002's central
prescription, and this codebase already requires it, in both directions:

  * ``kanban_dir`` / ``working_dir`` / ``alias_of``: ``""`` means absent
    (the pre-existing ``_ABSENT_SENTINELS`` contract, XACA-0727).
  * ``primary_host``: a present ``""`` means "declared unowned" and is
    deliberately NOT overridden by ``DEFAULT_TEAMS`` — XACA-0802-004 documents
    that a blanket ``if not host`` fallback made Python and shell disagree
    about the identical overlay entry.
  * ``anthropic_account_id``: ``""`` is the ordinary declared value on all 15
    seed teams.
  * ``board_less``: ``False`` is DATA. Only a missing key is absence.

A single global sentinel tuple cannot serve those four rules at once, which is
precisely why :class:`FieldSpec` carries its own.

``lcars_port`` is the live proof that this matters. The shell seed's
``medical-general`` row carries the literal string ``"null"`` in column 4 while
``DEFAULT_TEAMS`` carries ``8340`` (both measured 2026-09-10). A positional
table has no way to OMIT a column, so ``"null"`` is the only way it can say
"not declared" — an in-band sentinel that a naive reader turns into the string
``"null"`` or, worse, conflates with a real value.

Import safety
-------------
Importing this module performs NO I/O and reads no config. Every tier is
consulted lazily, inside the call. (Verified by test.)
"""

from __future__ import annotations

import enum
from pathlib import Path
from typing import Any, Callable, NamedTuple

import aiteamforge_paths

__all__ = [
    "ABSENT",
    "BoardLessTeamError",
    "FieldDeclaration",
    "FieldSpec",
    "FieldState",
    "Source",
    "UnknownTeamError",
    "alias_of",
    "anthropic_account_id",
    "anthropic_account_nickname",
    "anthropic_api_key_env_var",
    "component_label",
    "copyright_owner",
    "declare_field",
    "field_names",
    "is_absent",
    "is_board_less",
    "is_declared_value",
    "is_registered",
    "kanban_dir",
    "lcars_port",
    "lcars_port_base",
    "lcars_port_range",
    "license_type",
    "notice_template",
    "primary_host",
    "registered_teams",
    "resolve_field",
    "resolve_team",
    "team_code",
    "working_dir",
    "year_start",
]


# ---------------------------------------------------------------------------
# The absence sentinel
# ---------------------------------------------------------------------------

class _Absent:
    """Singleton marking "no value was declared anywhere".

    ``bool(ABSENT)`` deliberately RAISES. That is not pedantry — it is the
    enforcement mechanism for S002. If ABSENT were falsy it would be
    indistinguishable from a declared ``0``/``False``/``""`` at every
    ``if value:`` site, which is the exact collapse this module exists to
    prevent; if it were truthy, ``if value:`` would treat absence as data.
    There is no correct truthiness for it, so asking is a bug and gets a loud
    error instead of a plausible wrong answer.

    Test absence with ``x is ABSENT`` or :func:`is_absent`.
    """

    __slots__ = ()
    _instance: "_Absent | None" = None

    def __new__(cls) -> "_Absent":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __repr__(self) -> str:
        return "ABSENT"

    def __bool__(self):
        raise TypeError(
            "ABSENT has no truth value — a declared 0/False/'' is DATA, not "
            "absence (knowledge S002). Use `x is ABSENT` / is_absent(x), or ask "
            "declare_field() for the three-state answer."
        )


ABSENT = _Absent()


def is_absent(value: Any) -> bool:
    """Return True iff *value* is the :data:`ABSENT` sentinel (identity check)."""
    return value is ABSENT


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class UnknownTeamError(KeyError):
    """Raised when a team is registered in NO tier.

    Subclasses ``KeyError`` so the existing consumers that already wrap registry
    lookups in ``except KeyError`` (and skip the team) keep working unchanged.
    """


class BoardLessTeamError(KeyError):
    """Raised when a board-less alias is asked for a path it deliberately lacks.

    This is INTENTIONAL, not corruption (XACA-0727 / XACA-0794). Also a
    ``KeyError`` subclass, for the same consumer-compatibility reason.
    """


# ---------------------------------------------------------------------------
# States and sources
# ---------------------------------------------------------------------------

class FieldState(enum.Enum):
    """Which of the three S002 states a field resolved to."""

    DECLARED = "declared"
    DECLARED_ABSENT = "declared_absent"
    NOT_DECLARED = "not_declared"


class Source(enum.Enum):
    """Which tier produced the answer."""

    OVERLAY = "overlay"
    DEFAULT_TEAMS = "default_teams"
    DERIVED = "derived"
    NONE = "none"


class FieldDeclaration(NamedTuple):
    """The full, provenance-carrying answer for one (team, field) pair."""

    team: str
    field: str
    state: FieldState
    value: Any
    source: Source

    @property
    def declared(self) -> bool:
        """True iff a real value was found (``0``/``False`` included)."""
        return self.state is FieldState.DECLARED


# ---------------------------------------------------------------------------
# Field specs — one row per field, NEVER one rule per group (S002)
# ---------------------------------------------------------------------------

def _matches_sentinel(value: Any, sentinels: tuple) -> bool:
    """Type-strict sentinel membership.

    Plain ``value in sentinels`` uses ``==``, under which ``0 == False`` and
    ``1 == True``. A field whose sentinel tuple contained ``0`` would then
    silently swallow ``False``, and vice versa. Comparing types first makes the
    check say what it means.
    """
    for sentinel in sentinels:
        if value is sentinel:
            return True
        if type(value) is type(sentinel) and value == sentinel:
            return True
    return False


class FieldSpec(NamedTuple):
    """The resolution rules for ONE registry field."""

    name: str
    absent_sentinels: tuple
    absent_stops_chain: bool
    deriver: Callable[[str, dict | None], Any] | None
    doc: str


# The three sentinel vocabularies actually in use. Named so a reader can see at
# a glance which fields share a rule and, more importantly, which do not.
#
# _PATHISH: XACA-0727's original contract. A positional shell table cannot omit
#   a column, so it encodes absence in-band as the string "null"; JSON null and
#   "" are the other two spellings the same absence arrives in.
_PATHISH_SENTINELS: tuple = (None, "", "null")
# _NULLISH: "" is a DECLARED value (an operator saying "unowned"/"none
#   configured"), so it is NOT a sentinel. XACA-0802-004 for primary_host.
_NULLISH_SENTINELS: tuple = (None, "null")
# _KEYONLY: only a missing key is absence. For booleans, where False is data.
_KEYONLY_SENTINELS: tuple = (None,)


def _derive_working_dir(team: str, config: dict | None) -> Any:
    """``working_dir`` = parent of ``kanban_dir`` — the invariant DEFAULT_TEAMS documents.

    Fires ONLY when no tier declared ``working_dir`` at all. Not an identity
    derivation: it reads a *declared sibling field* on the same team rather than
    inventing something nothing declared (K659). Recursion is bounded —
    ``kanban_dir`` has no deriver.
    """
    declaration = declare_field(team, "kanban_dir", config=config)
    if declaration.state is FieldState.DECLARED:
        return str(Path(str(declaration.value)).expanduser().parent)
    return ABSENT


_FIELD_SPECS: dict[str, FieldSpec] = {
    # --- identity ---------------------------------------------------------
    "team_code": FieldSpec(
        "team_code", _PATHISH_SENTINELS, False, None,
        "3-letter item-ID prefix (XACA-0001 -> ACA). absent_stops_chain=False "
        "preserves the pre-existing get_team_code() migration fallback, which "
        "gated on truthiness and so fell through to DEFAULT_TEAMS on an empty "
        "code. NO DERIVER, ever (K659 / XACA-1058).",
    ),
    "alias_of": FieldSpec(
        "alias_of", _PATHISH_SENTINELS, False, None,
        "Slug a board-less alias defers to. absent_stops_chain=False matches "
        "board_less_alias_of(), which falls back to DEFAULT_TEAMS so the "
        "guidance still resolves on overlays predating XACA-0794.",
    ),
    "board_less": FieldSpec(
        "board_less", _KEYONLY_SENTINELS, True, None,
        "Explicit board-less marker (XACA-0794). False is DATA — only a missing "
        "key is absence (S002).",
    ),
    # --- paths ------------------------------------------------------------
    "kanban_dir": FieldSpec(
        "kanban_dir", _PATHISH_SENTINELS, True, None,
        "Absolute path to the team kanban dir. A declared absence STOPS the "
        "chain: board-less is an authoritative statement, not a gap to fill "
        "from another tier (XACA-0727).",
    ),
    "working_dir": FieldSpec(
        "working_dir", _PATHISH_SENTINELS, True, _derive_working_dir,
        "Absolute path to the project root. The one derivable field: "
        "kanban_dir.parent, and only when NO tier declared it.",
    ),
    # --- ports ------------------------------------------------------------
    "lcars_port": FieldSpec(
        "lcars_port", _PATHISH_SENTINELS, True, None,
        "Concrete LCARS port. The shell seed's medical-general row carries the "
        "string 'null' here while DEFAULT_TEAMS carries 8340 — the live "
        "explicit-null-vs-absent case. NO DERIVER: an invented port is the "
        "phantom-identity shape K659 forbids.",
    ),
    "lcars_port_base": FieldSpec(
        "lcars_port_base", _PATHISH_SENTINELS, True, None,
        "First port in the team's band (XACA-0463).",
    ),
    "lcars_port_range": FieldSpec(
        "lcars_port_range", _PATHISH_SENTINELS, True, None,
        "Inclusive width of the port band (XACA-0463).",
    ),
    # --- ownership --------------------------------------------------------
    "primary_host": FieldSpec(
        "primary_host", _NULLISH_SENTINELS, True, None,
        "The ONE fleet host authoring this team's knowledge (XACA-0802). A "
        "present '' is a DECLARED value meaning 'unowned' and must NOT fall "
        "through to DEFAULT_TEAMS — XACA-0802-004 records that doing so made "
        "Python and shell disagree about the identical overlay entry.",
    ),
    # --- Anthropic account routing (XACA-0279) ----------------------------
    "anthropic_account_id": FieldSpec(
        "anthropic_account_id", _NULLISH_SENTINELS, True, None,
        "Per-team Anthropic account id. '' is the ordinary declared value on "
        "all 15 seed teams, so it is DATA, not absence.",
    ),
    "anthropic_account_nickname": FieldSpec(
        "anthropic_account_nickname", _NULLISH_SENTINELS, True, None,
        "Human label for the account. '' is a declared value.",
    ),
    "anthropic_api_key_env_var": FieldSpec(
        "anthropic_api_key_env_var", _NULLISH_SENTINELS, True, None,
        "Env var holding the failover API key. '' is a declared value.",
    ),
    # --- overlay-only licence/NOTICE block (finding F6) -------------------
    # These five live in the overlay and in NEITHER seed. They have no source of
    # origin to reseed from, so a "reseed from canonical" pass would destroy
    # them. They are registered here so they are first-class through the
    # resolver; resolve_team() additionally preserves any field NOT listed in
    # this table at all (see _DEFAULT_SPEC).
    "component_label": FieldSpec(
        "component_label", _PATHISH_SENTINELS, True, None,
        "License/NOTICE component name. OVERLAY-ONLY (F6) — no seed of origin.",
    ),
    "copyright_owner": FieldSpec(
        "copyright_owner", _PATHISH_SENTINELS, True, None,
        "License/NOTICE copyright holder. OVERLAY-ONLY (F6).",
    ),
    "license_type": FieldSpec(
        "license_type", _PATHISH_SENTINELS, True, None,
        "License identifier. OVERLAY-ONLY (F6).",
    ),
    "notice_template": FieldSpec(
        "notice_template", _PATHISH_SENTINELS, True, None,
        "NOTICE template id. OVERLAY-ONLY (F6).",
    ),
    "year_start": FieldSpec(
        "year_start", _PATHISH_SENTINELS, True, None,
        "Copyright start year. OVERLAY-ONLY (F6).",
    ),
}


def _default_spec(name: str) -> FieldSpec:
    """Spec for a field NOT in the table.

    The registry is SCHEMA-OPEN on purpose. A closed allowlist would silently
    drop any field a future ``kb-init-team`` or a hand-edited overlay
    introduces — which is exactly how the five overlay-only licence fields
    (F6) would have been lost had this table been authored a year earlier.
    Unregistered fields resolve with the conservative path-ish rule.
    """
    return FieldSpec(
        name, _PATHISH_SENTINELS, True, None,
        "Unregistered field — resolved with the conservative default rule. "
        "The registry is schema-open so overlay-only fields are never dropped.",
    )


def spec_for(field: str) -> FieldSpec:
    """Return the :class:`FieldSpec` governing *field* (never raises)."""
    return _FIELD_SPECS.get(field) or _default_spec(field)


def field_names() -> list[str]:
    """Return the sorted names of every field with an explicit spec."""
    return sorted(_FIELD_SPECS)


def is_declared_value(field: str, value: Any) -> bool:
    """Return True iff *value* is a real declared value for *field* (S002).

    The PUBLIC form of the per-field sentinel rule. It exists so that code
    outside this module — notably the read-time convergence migration in
    ``aiteamforge_paths.py`` (XACA-1161-003) — can ask "is this a value or is
    this an absence?" without cloning the sentinel table. A second copy of that
    rule would be K501 sibling-heuristic drift in the exact place the ticket
    exists to remove it, and it would get the answer WRONG in both directions:
    a blanket truthiness test drops ``primary_host: ""`` (a declared "unowned",
    XACA-0802-004) and keeps ``kanban_dir: "null"`` (a positional-table
    absence sentinel, XACA-0727).

    Pure: no I/O, no ``load_config()`` call, safe to import lazily from
    ``aiteamforge_paths`` without creating an import cycle.

    Fields with no explicit spec get the conservative path-ish rule — see
    :func:`_default_spec`.
    """
    return not _matches_sentinel(value, spec_for(field).absent_sentinels)


# ---------------------------------------------------------------------------
# Tier access
# ---------------------------------------------------------------------------

def _overlay_teams(config: dict | None) -> dict:
    """Tier 1 — the per-machine overlay's team map.

    Calls ``load_config()`` with NO arguments on purpose: many existing tests
    replace it with ``mock.patch.object(..., return_value=cfg)``, and a mock
    silently ignores keyword arguments. Asking it for pre-layered data would
    make the layering vanish under those mocks without any test failing — a
    malformed check returning the reassuring answer. The layering is done HERE,
    in code that cannot be mocked away.
    """
    if config is None:
        try:
            config = aiteamforge_paths.load_config()
        except Exception:
            return {}
    teams = config.get("teams")
    return teams if isinstance(teams, dict) else {}


def _default_teams() -> dict:
    """Tier 2 — the baked-in Python seed (migration tolerance only)."""
    seed = getattr(aiteamforge_paths, "DEFAULT_TEAMS", None)
    return seed if isinstance(seed, dict) else {}


def _entry(mapping: dict, team: str) -> dict | None:
    """Return ``mapping[team]`` iff it is a usable dict, else None."""
    entry = mapping.get(team)
    return entry if isinstance(entry, dict) else None


def registered_teams(*, config: dict | None = None) -> list[str]:
    """Return the sorted UNION of teams known to the overlay and DEFAULT_TEAMS.

    The union, never either tier alone: measured 2026-09-10 the two Python-side
    tiers each hold slugs the other lacks, and a caller that iterates one of
    them cannot see the other's exclusives.
    """
    return sorted(set(_overlay_teams(config)) | set(_default_teams()))


def is_registered(team: str, *, config: dict | None = None) -> bool:
    """Return True iff *team* is declared in any Python tier."""
    return (
        _entry(_overlay_teams(config), team) is not None
        or _entry(_default_teams(), team) is not None
    )


def _require_entries(team: str, config: dict | None) -> tuple[dict | None, dict | None]:
    """Return ``(overlay_entry, default_entry)`` or raise :class:`UnknownTeamError`.

    RAISES rather than deriving (K659). A phantom-derived team is worse than a
    KeyError: callers go on to mint item IDs against a code nothing else in the
    fleet recognizes, and the damage outlives the lookup that caused it.
    """
    overlay_entry = _entry(_overlay_teams(config), team)
    default_entry = _entry(_default_teams(), team)
    if overlay_entry is None and default_entry is None:
        known = registered_teams(config=config)
        preview = ", ".join(known[:8]) + (" ..." if len(known) > 8 else "")
        raise UnknownTeamError(
            f"Team '{team}' is registered in no Python tier (neither "
            f"{aiteamforge_paths.get_config_path()} nor DEFAULT_TEAMS). "
            f"Known ({len(known)}): {preview} — refusing to derive a value for "
            f"an unregistered team (K659 / XACA-1058). NOTE: 'freelance' and "
            f"'medical' exist ONLY in the shell seed and are expected to land "
            f"here; the Python resolver does not parse the shell table (K830)."
        )
    return overlay_entry, default_entry


# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------

def declare_field(team: str, field: str, *, config: dict | None = None) -> FieldDeclaration:
    """Resolve *field* on *team*, returning the full three-state answer.

    This is the primitive every other accessor is built on — the one place the
    precedence chain is implemented. See the module docstring for the tier
    order and its rationale.

    Raises:
        UnknownTeamError: if *team* is registered in no tier.
    """
    spec = spec_for(field)
    overlay_entry, default_entry = _require_entries(team, config)

    for source, entry in (
        (Source.OVERLAY, overlay_entry),
        (Source.DEFAULT_TEAMS, default_entry),
    ):
        if entry is None or field not in entry:
            # Key genuinely absent at this tier -> consult the next one.
            continue
        value = entry[field]
        if _matches_sentinel(value, spec.absent_sentinels):
            if spec.absent_stops_chain:
                # This tier explicitly said "no value". That is an answer, not
                # a gap, so it wins over anything a lower tier holds.
                return FieldDeclaration(team, field, FieldState.DECLARED_ABSENT, ABSENT, source)
            continue
        return FieldDeclaration(team, field, FieldState.DECLARED, value, source)

    if spec.deriver is not None:
        derived = spec.deriver(team, config)
        if derived is not ABSENT:
            return FieldDeclaration(team, field, FieldState.DECLARED, derived, Source.DERIVED)

    return FieldDeclaration(team, field, FieldState.NOT_DECLARED, ABSENT, Source.NONE)


def resolve_field(team: str, field: str, *, default: Any = ABSENT,
                  config: dict | None = None) -> Any:
    """Return the resolved VALUE of *field* on *team*, or *default*.

    Convenience wrapper over :func:`declare_field` for callers that do not need
    provenance. Both non-DECLARED states collapse to *default* here — when that
    distinction matters (it does for ``lcars_port``), call
    :func:`declare_field` instead.

    The value is returned AS DECLARED — no coercion. The typed accessors below
    do the coercion, so this stays an honest report of what the registry holds.

    Raises:
        UnknownTeamError: if *team* is registered in no tier.
    """
    declaration = declare_field(team, field, config=config)
    return declaration.value if declaration.declared else default


def resolve_team(team: str, *, config: dict | None = None) -> dict[str, Any]:
    """Return every DECLARED field for *team*, resolved through the chain.

    SCHEMA-OPEN: the key set is the union of every key present on the team in
    either tier, plus any derivable field — not a fixed allowlist. This is what
    preserves the five overlay-only licence fields (``component_label``,
    ``copyright_owner``, ``license_type``, ``notice_template``, ``year_start``),
    which exist in the overlay and in NEITHER seed (finding F6) and so would be
    silently dropped by any normalization built around a closed schema.

    Fields resolving to DECLARED_ABSENT or NOT_DECLARED are OMITTED from the
    result rather than mapped to ``None`` — so a caller can distinguish "no
    value" from "declared None" by key presence, the S002 rule. Use
    :func:`declare_field` for the state of a specific field.

    Raises:
        UnknownTeamError: if *team* is registered in no tier.
    """
    overlay_entry, default_entry = _require_entries(team, config)
    keys: set[str] = set()
    for entry in (overlay_entry, default_entry):
        if entry:
            keys.update(entry)
    keys.update(name for name, spec in _FIELD_SPECS.items() if spec.deriver is not None)

    resolved: dict[str, Any] = {}
    for key in sorted(keys):
        declaration = declare_field(team, key, config=config)
        if declaration.declared:
            resolved[key] = declaration.value
    return resolved


# ---------------------------------------------------------------------------
# Typed accessors — ask for a field by name, get a typed answer
# ---------------------------------------------------------------------------
#
# Each is a thin, greppable wrapper over the resolver. They apply the field's
# type coercion and its documented not-found shape. Where a legacy accessor in
# aiteamforge_paths.py already fixed a return contract (get_team_lcars_port ->
# int | None, get_team_primary_host -> str), these preserve it, so XACA-1161-003
# can swap call sites without changing any caller's expectations. Callers that
# need the three-state truth ask declare_field() directly.

def _coerced_str(team: str, field: str, config: dict | None) -> str:
    value = resolve_field(team, field, default="", config=config)
    return "" if value is None else str(value)


def _coerced_int(team: str, field: str, config: dict | None) -> int | None:
    value = resolve_field(team, field, default=None, config=config)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def team_code(team: str, *, config: dict | None = None) -> str:
    """Return the team's 3-letter code, or ``""`` when none is declared."""
    return _coerced_str(team, "team_code", config).upper()


def alias_of(team: str, *, config: dict | None = None) -> str | None:
    """Return the slug this board-less alias defers to, or None."""
    value = resolve_field(team, "alias_of", default=None, config=config)
    return str(value) if value else None


def is_board_less(team: str, *, config: dict | None = None) -> bool:
    """Return True iff *team* owns no kanban board.

    Marker first (XACA-0794), then the legacy sentinel inference on
    ``kanban_dir`` (XACA-0727) so un-migrated overlays — which carry a bare
    null and no marker — still answer correctly.
    """
    marker = declare_field(team, "board_less", config=config)
    if marker.declared:
        return marker.value is True
    return declare_field(team, "kanban_dir", config=config).state is not FieldState.DECLARED


def _board_less_error(team: str, field: str, config: dict | None) -> BoardLessTeamError:
    alias = alias_of(team, config=config)
    guidance = f"Use '{alias}' instead." if alias else "It owns no kanban board of its own."
    return BoardLessTeamError(
        f"Team '{team}' is a board-less alias (no {field}) — this is "
        f"intentional, NOT corruption. {guidance} See XACA-0727 / XACA-0794."
    )


def kanban_dir(team: str, *, config: dict | None = None) -> Path:
    """Return the team's kanban directory.

    Raises:
        UnknownTeamError: team registered in no tier.
        BoardLessTeamError: team is a board-less alias.
    """
    declaration = declare_field(team, "kanban_dir", config=config)
    if not declaration.declared or is_board_less(team, config=config):
        raise _board_less_error(team, "kanban_dir", config)
    return Path(str(declaration.value)).expanduser()


def working_dir(team: str, *, config: dict | None = None) -> Path:
    """Return the team's working (project root) directory.

    Raises:
        UnknownTeamError: team registered in no tier.
        BoardLessTeamError: team is a board-less alias.
    """
    declaration = declare_field(team, "working_dir", config=config)
    if not declaration.declared or is_board_less(team, config=config):
        raise _board_less_error(team, "working_dir", config)
    return Path(str(declaration.value)).expanduser()


def lcars_port(team: str, *, config: dict | None = None) -> int | None:
    """Return the team's concrete LCARS port, or None when undeclared.

    None collapses DECLARED_ABSENT and NOT_DECLARED, matching the legacy
    ``get_team_lcars_port`` contract. Callers that must tell a declared null
    from a missing key — the ``medical-general`` case — use
    ``declare_field(team, "lcars_port")``.
    """
    return _coerced_int(team, "lcars_port", config)


def lcars_port_base(team: str, *, config: dict | None = None) -> int | None:
    """Return the first port of the team's band, or None."""
    return _coerced_int(team, "lcars_port_base", config)


def lcars_port_range(team: str, *, config: dict | None = None) -> int | None:
    """Return the width of the team's port band, or None."""
    return _coerced_int(team, "lcars_port_range", config)


def primary_host(team: str, *, config: dict | None = None) -> str:
    """Return the team's declared primary host, or ``""`` when undeclared.

    ``""`` means "unowned / not declared", which every consumer must treat as
    fail-OPEN (XACA-0802).
    """
    return _coerced_str(team, "primary_host", config)


def anthropic_account_id(team: str, *, config: dict | None = None) -> str:
    """Return the team's Anthropic account id, or ``""`` (XACA-0279)."""
    return _coerced_str(team, "anthropic_account_id", config)


def anthropic_account_nickname(team: str, *, config: dict | None = None) -> str:
    """Return the human label for the team's Anthropic account, or ``""``."""
    return _coerced_str(team, "anthropic_account_nickname", config)


def anthropic_api_key_env_var(team: str, *, config: dict | None = None) -> str:
    """Return the env var holding the team's failover API key, or ``""``."""
    return _coerced_str(team, "anthropic_api_key_env_var", config)


def component_label(team: str, *, config: dict | None = None) -> str:
    """Return the licence/NOTICE component name, or ``""`` (overlay-only, F6)."""
    return _coerced_str(team, "component_label", config)


def copyright_owner(team: str, *, config: dict | None = None) -> str:
    """Return the licence/NOTICE copyright holder, or ``""`` (overlay-only, F6)."""
    return _coerced_str(team, "copyright_owner", config)


def license_type(team: str, *, config: dict | None = None) -> str:
    """Return the licence identifier, or ``""`` (overlay-only, F6)."""
    return _coerced_str(team, "license_type", config)


def notice_template(team: str, *, config: dict | None = None) -> str:
    """Return the NOTICE template id, or ``""`` (overlay-only, F6)."""
    return _coerced_str(team, "notice_template", config)


def year_start(team: str, *, config: dict | None = None) -> int | None:
    """Return the copyright start year, or None (overlay-only, F6)."""
    return _coerced_int(team, "year_start", config)
