#!/usr/bin/env python3
"""
timepad_config.py — TimePad per-team token resolver and accessor API.

XACA-0619 — TimePad: per-team config schema, token security & enable/disable toggle.

Design
------
This module provides the token resolution and fingerprint accessors for TimePad.
Config loading/validation/caching lives in aiteamforge_paths.py (sibling 002).
It is consumed by:
  - aiteamforge_paths.py (loader integration, sibling 002)
  - lcars-ui/server.py (enable-toggle API, sibling 004)
  - downstream hook + UI children (B/C/D/E)

Config file: kanban-hooks/timepad_config.json  (committed schema; runtime copy at
             ~/.aiteamforge/timepad_config.json — not committed to git)
Schema defined in: docs/TIMEPAD_CONFIG.md  (sibling 001)

Token resolution order (mirrors XACA-0279 Anthropic key chain):
  1. Vault live fetch  (fleet-monitor/client/vault-fetch.sh)
  2. Vault offline cache  (~/.aiteamforge/vault-cache/<machine>/<engine>/<account>.plain)
  3. Env-var failover  (TEAM_<CODE>_TIMEPAD_API_KEY in ~/.zshrc.secrets / process.env)

Naming conventions (LOCKED — hard rebrand from TIMEAPP/liquidstyle, XACA-0619):
  env var (per-team):     TEAM_<TEAM_CODE>_TIMEPAD_API_KEY
  env var (global):       TIMEPAD_API_KEY
  vault engine slug:      "timepad"
  vault account slug:     <team-slug>  (e.g. "academy", "mainevent")
  vault key stored as:    TEAM_<TEAM_CODE>_TIMEPAD_API_KEY  (conventional name in vault record)
  secrets file (human):   ~/.timepad-secrets  (shell sourcing convenience; NOT read here)

NOTE on schema shape:
  The config schema (sibling 001) uses a FLAT top-level tokenRef field per team block,
  NOT a nested auth.tokenRef.  The `token_ref` parameter accepted by resolve_timepad_token
  receives the flat top-level tokenRef string value directly.  Any code expecting
  auth.tokenRef is stale and must be updated.

NOTE on plan-doc discrepancy:
  The plan doc (XACA-0619_timeapp_config_security_enable.md) references tokenEnvVar as
  "TIMEAPP_API_KEY_<TEAM>" and vault path as "timeapp/<team>/api-key".  Those names
  were written before the hard-rebrand decision captured in the subitem prompt.  This
  implementation uses the LOCKED naming above.

Security rules (do NOT relax):
  - Resolved token values are NEVER logged, printed, written to disk, or exported.
  - The plaintext token is returned in-memory only and consumed by the caller.
  - The fingerprint accessor returns a masked string only, never the raw value.
  - No token literal ever appears in config JSON, board JSON, or LCARS state.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Vault engine slug — mirrors the "anthropic" engine in XACA-0279.
#: Stored secrets are keyed as engine_slug + account_slug (team slug).
VAULT_ENGINE_SLUG = "timepad"

#: Global (non-per-team) env-var name for a single-team or fallback installation.
TIMEPAD_GLOBAL_ENV_VAR = "TIMEPAD_API_KEY"

#: Location of vault-fetch.sh relative to the dev-team root.
#: This is an absolute resolution attempted at runtime; falls back gracefully.
_VAULT_FETCH_SH_CANDIDATES: list[str] = [
    # Installed tap copy (consumer machines)
    str(Path.home() / ".aiteamforge" / "fleet-monitor" / "client" / "vault-fetch.sh"),
    # Dev-team source (M3Pro / worktree)
    str(Path(__file__).parent.parent / "fleet-monitor" / "client" / "vault-fetch.sh"),
]

#: Vault cache root — mirrors vault-fetch.js DEFAULT_CACHE_DIR.
_VAULT_CACHE_ROOT = Path.home() / ".aiteamforge" / "vault-cache"

#: Vault cache TTL in seconds — mirrors CACHE_TTL_SECONDS in vault-fetch.js (300s).
_VAULT_CACHE_TTL_SECONDS = int(os.environ.get("VAULT_FETCH_CACHE_TTL_SECONDS", "300"))

# ---------------------------------------------------------------------------
# Internal helpers: env-var name derivation
# ---------------------------------------------------------------------------


def env_var_for_team(team_slug: str, team_code: Optional[str] = None) -> str:
    """Return the canonical per-team TIMEPAD env-var name.

    Naming convention (XACA-0619 hard rebrand):
        TEAM_<TEAM_CODE>_TIMEPAD_API_KEY

    The team_code is the uppercase short code stored in team-paths.json
    (e.g. "ACADEMY", "MAINEVENT", "IOS").  When absent it is derived by
    uppercasing the team_slug and replacing hyphens with underscores — same
    derivation used by vault-migrate-env-keys.js for anthropic keys.

    Args:
        team_slug:  Canonical team slug (e.g. "academy", "mainevent").
        team_code:  Optional explicit short code.  When None, derived from slug.

    Returns:
        String env-var name, e.g. "TEAM_ACADEMY_TIMEPAD_API_KEY".
    """
    if not team_code:
        team_code = team_slug.upper().replace("-", "_")
    return f"TEAM_{team_code}_TIMEPAD_API_KEY"


# ---------------------------------------------------------------------------
# Internal helpers: vault-fetch subprocess
# ---------------------------------------------------------------------------


def _vault_fetch_sh_path() -> Optional[str]:
    """Return the first existing vault-fetch.sh path from the candidate list."""
    for candidate in _VAULT_FETCH_SH_CANDIDATES:
        if os.path.isfile(candidate):
            return candidate
    return None


def _machine_slug() -> str:
    """Return a slugified machine hostname, mirroring vault-keygen.js derivation."""
    import re
    hostname = (
        os.environ.get("AITEAMFORGE_MACHINE_ID")
        or subprocess.run(
            ["hostname", "-s"],
            capture_output=True, text=True, timeout=5
        ).stdout.strip()
    )
    # slugify: lowercase, keep [a-z0-9-], collapse runs of invalid chars to "-"
    slug = re.sub(r"[^a-z0-9-]+", "-", hostname.lower()).strip("-") or "localhost"
    return slug


# ---------------------------------------------------------------------------
# Internal helpers: vault cache read (stale offline tier)
# ---------------------------------------------------------------------------


def _read_vault_cache_entry(
    machine_slug: str,
    engine_slug: str,
    account_slug: str,
    ttl_seconds: Optional[int] = None,
) -> Optional[str]:
    """Read a vault cache entry.

    Returns the cached plaintext string if the file exists and is within TTL,
    or None when missing or stale.  Mirrors vault-fetch.js readCacheEntry().

    The stale-offline-cache tier (tier 2 / tier 3 in the resolution chain)
    distinguishes fresh (within TTL) from stale (beyond TTL).  Both tiers are
    returned by this function depending on the caller's intent:
      - Tier 2 (live cache): call with ttl_seconds=_VAULT_CACHE_TTL_SECONDS
      - Tier 3 (stale offline): call with ttl_seconds=None (no TTL check)

    Security: cache files are owned by the user, mode 0600 (written by
    vault-fetch.js).  We read them but never write.

    Args:
        machine_slug:  Slugified machine hostname.
        engine_slug:   Vault engine slug (e.g. "timepad").
        account_slug:  Vault account slug (team slug, e.g. "academy").
        ttl_seconds:   Maximum cache age in seconds; None = no expiry check.

    Returns:
        Cached plaintext string, or None.
    """
    cache_file = _VAULT_CACHE_ROOT / machine_slug / engine_slug / f"{account_slug}.plain"
    if not cache_file.exists():
        return None
    if ttl_seconds is not None:
        import time
        age_seconds = time.time() - cache_file.stat().st_mtime
        if age_seconds > ttl_seconds:
            return None  # stale for TTL-gated read
    try:
        return cache_file.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Token resolution — three-tier chain (XACA-0279 mirror)
# ---------------------------------------------------------------------------


class TimePadTokenResolutionError(Exception):
    """Raised when no token can be resolved through any tier."""


def resolve_timepad_token(
    team_slug: str,
    team_code: Optional[str] = None,
    token_ref: Optional[str] = None,
    *,
    server_url: Optional[str] = None,
    _testing_env: Optional[dict] = None,
    _skip_vault: bool = False,
) -> str:
    """Resolve the TimePad API token for a team through the three-tier chain.

    Resolution order (mirrors XACA-0279 Anthropic key chain):
      Tier 1 — Vault live fetch:
        Calls vault-fetch.sh with engine="timepad", account=<team_slug>.
        Exit codes 0 and 5 both deliver plaintext on stdout (live vs cache-hit).
        On exit 4 (unreachable) or 8 (keypair present but no fleet server URL
        resolved/accepted) falls through to tier 2 — both mean "there is a vault
        here we cannot currently reach", so the cache tiers still apply.
        On exit 3 (no keypair) or 6 (decrypt failed) falls through to tier 3.
      Tier 2 — Vault offline cache (fresh, within TTL):
        Reads ~/$AITEAMFORGE/vault-cache/<machine>/timepad/<team>.plain.
        Returns if within TTL.
      Tier 3 — Env-var failover:
        Reads TEAM_<CODE>_TIMEPAD_API_KEY (per-team) or TIMEPAD_API_KEY (global).
        This tier is the permanent failover; it is NEVER removed.

    The resolved token is returned as a plain string and is intended for
    in-memory use only.  Callers MUST NOT log, print, write to disk, or export
    the returned value.

    Token naming in config (schema, sibling 001):
      The config field `tokenRef` (flat top-level, NOT nested auth.tokenRef)
      stores the env-var name that holds the token (e.g.
      "TEAM_ACADEMY_TIMEPAD_API_KEY").  This function accepts that name as the
      optional `token_ref` argument and uses it as the primary env-var lookup
      name in tier 3.

    Args:
        team_slug:    Canonical team slug (e.g. "academy").
        team_code:    Optional short code (e.g. "ACADEMY").  Derived when None.
        token_ref:    Optional env-var name from config's auth.tokenRef field.
                      When present, it is used as the tier-3 primary lookup.
        server_url:   Override fleet-monitor URL.  When None and $FLEET_MONITOR_URL
                      is unset, NO --server flag is passed and vault-fetch.sh
                      resolves the endpoint itself from fleet-config.json
                      (XACA-0972).  For testing.
        _testing_env: Override os.environ for tier-3 lookup.  For unit tests.
        _skip_vault:  When True, skip the vault tiers (1, 2, 2b) entirely and
                      resolve from the env-var failover only.  Lets hermetic unit
                      tests avoid firing the vault-fetch.sh subprocess (or reading
                      the on-disk vault cache) on machines where they exist.

    Returns:
        The resolved token string (non-empty).

    Raises:
        TimePadTokenResolutionError: when no tier produces a token.
    """
    env = _testing_env if _testing_env is not None else os.environ

    # ── Tier 1: vault live fetch ──────────────────────────────────────────────
    vault_sh = None if _skip_vault else _vault_fetch_sh_path()
    if vault_sh:
        try:
            # XACA-0972: pass --server ONLY when we actually have one. Defaulting
            # to "$FLEET_MONITOR_URL or localhost" here OVERRODE vault-fetch's own
            # resolver, so this call still hard-targeted a dead port even after the
            # resolver landed -- an explicit flag always wins. Omitting it lets
            # vault-fetch resolve .centralServer.apiEndpoint from fleet-config.json
            # and report exit 8 (no-fleet-url) when nothing resolves, instead of
            # a connection-refused that reads as a network fault.
            #
            # Exit 8, NOT exit 3 (XACA-0972-018/-026): vault-fetch checks the
            # keypair BEFORE it resolves the URL, so "no URL" proves a keypair
            # IS present. Exit 3 means the opposite — no keypair at all. An
            # earlier revision of this comment said 3 and was wrong.
            vault_url = server_url or env.get("FLEET_MONITOR_URL") or ""
            vault_cmd = ["bash", vault_sh, VAULT_ENGINE_SLUG, team_slug]
            if vault_url:
                vault_cmd += ["--server", vault_url]
            result = subprocess.run(
                vault_cmd,
                capture_output=True,
                text=True,
                timeout=15,
            )
            # Exit 0 = live fetch ok; exit 5 = fresh cache hit — both deliver stdout.
            if result.returncode in (0, 5):
                token = result.stdout.strip()
                if token:
                    return token  # in-memory only, never written
            # Exit 4 = unreachable (retryable)          → fall through to tier 2
            # Exit 8 = keypair present, no fleet URL      → fall through to tier 2
            # Exit 3 = no keypair; exit 6 = decrypt-failed → fall through to tier 3
            # Any other exit → fall through
            # NB: every non-(0,5) code reaches the tier-2 cache read below, so
            # 3 and 6 are "tier 3" only in the sense that their cache lookups
            # are expected to miss. The distinction is documentary, not control
            # flow — do not "optimise" it into an early jump past tier 2.
        except (subprocess.TimeoutExpired, OSError, subprocess.SubprocessError):
            pass  # vault unavailable — fall through

    # ── Tier 2 + 2b: vault offline cache (skipped entirely when _skip_vault) ─
    if not _skip_vault:
        # Tier 2 — fresh cache (within TTL).
        try:
            machine_slug = _machine_slug()
            cached = _read_vault_cache_entry(
                machine_slug,
                VAULT_ENGINE_SLUG,
                team_slug,
                ttl_seconds=_VAULT_CACHE_TTL_SECONDS,
            )
            if cached:
                return cached  # in-memory only
        except Exception:
            pass  # non-fatal

        # Tier 2b — stale cache (beyond TTL — still preferred over env per
        # XACA-0279: the vault has higher trust than the shell environment).
        try:
            machine_slug = _machine_slug()
            stale = _read_vault_cache_entry(
                machine_slug,
                VAULT_ENGINE_SLUG,
                team_slug,
                ttl_seconds=None,  # no TTL check — accept any age
            )
            if stale:
                return stale  # in-memory only
        except Exception:
            pass  # non-fatal

    # ── Tier 3: env-var failover (permanent, never removed) ──────────────────
    # Priority order:
    #   1. token_ref (the env-var name from the config's flat tokenRef field)
    #   2. per-team: TEAM_<CODE>_TIMEPAD_API_KEY
    #   3. global:   TIMEPAD_API_KEY

    per_team_env_var = token_ref or env_var_for_team(team_slug, team_code)
    for var_name in (per_team_env_var, TIMEPAD_GLOBAL_ENV_VAR):
        value = env.get(var_name, "").strip()
        if value:
            return value  # in-memory only

    raise TimePadTokenResolutionError(
        f"TimePad token for team '{team_slug}' could not be resolved through "
        f"vault (engine={VAULT_ENGINE_SLUG!r}, account={team_slug!r}), "
        f"vault cache, env var {per_team_env_var!r}, or {TIMEPAD_GLOBAL_ENV_VAR!r}. "
        "Set one of these or configure vault secrets."
    )


# ---------------------------------------------------------------------------
# Token fingerprint — masked display (mirrors cc-whoami._ccw_fingerprint)
# ---------------------------------------------------------------------------


def mask_timepad_token(token: str) -> str:
    """Return a masked fingerprint of a TimePad token for safe display.

    Masking scheme (mirrors cc-whoami._ccw_fingerprint):
      "<first-4-chars>****...(sha256:<first-7-chars-of-hash>)"

    For tokens shorter than 8 characters the prefix length is clamped.
    For empty tokens returns "(not set)".

    This function ONLY accepts the resolved token in-memory and NEVER writes
    the masked or unmasked value to disk.  The caller is responsible for not
    logging the raw return value in a context where it could be reconstructed.

    Args:
        token: The resolved plaintext token.

    Returns:
        Masked fingerprint string, e.g. "sk-t****...(sha256:3f4a1b2)".
    """
    if not token:
        return "(not set)"
    sha = hashlib.sha256(token.encode("utf-8")).hexdigest()
    prefix_len = min(4, len(token))
    prefix = token[:prefix_len]
    return f"{prefix}****...(sha256:{sha[:7]})"


def resolve_timepad_token_fingerprint(
    team_slug: str,
    team_code: Optional[str] = None,
    token_ref: Optional[str] = None,
    *,
    server_url: Optional[str] = None,
    _testing_env: Optional[dict] = None,
    _skip_vault: bool = False,
) -> str:
    """Resolve the TimePad token for a team and return its masked fingerprint.

    This is the safe public accessor for use in LCARS displays, logs, and
    diagnostic output.  It resolves the token through the three-tier chain and
    immediately discards the plaintext — the return value is the fingerprint
    only.

    Used directly or re-exported by sibling 005 (accessor API).

    Args:
        team_slug:    Canonical team slug (e.g. "academy").
        team_code:    Optional short code (e.g. "ACADEMY").  Derived when None.
        token_ref:    Optional env-var name from config's auth.tokenRef field.
        server_url:   Override fleet-monitor URL.  For testing.
        _testing_env: Override os.environ for tier-3 lookup.  For unit tests.
        _skip_vault:  When True, skip the vault tiers (hermetic unit tests).

    Returns:
        Masked fingerprint string, or "(not set)" if no token found.
    """
    try:
        token = resolve_timepad_token(
            team_slug,
            team_code=team_code,
            token_ref=token_ref,
            server_url=server_url,
            _testing_env=_testing_env,
            _skip_vault=_skip_vault,
        )
        return mask_timepad_token(token)
    except TimePadTokenResolutionError:
        return "(not set)"


# ---------------------------------------------------------------------------
# Public accessor re-exports (XACA-0619-005)
# ---------------------------------------------------------------------------
# Sibling 005 (aiteamforge_paths.py) owns the authoritative accessor API:
#   get_timepad_team_config(team_slug) — connection config from timepad_config.json
#   is_timepad_enabled(team_slug)      — board-JSON gate at teamConfig.timepadSupport.enabled
#
# This module re-exports them so consumers have ONE import point for all
# TimePad operations (token resolution + config access + enable check).
# Each function delegates to aiteamforge_paths and falls back gracefully
# to safe defaults so importing this module never crashes pre-bootstrap.

def get_timepad_raw_config() -> dict:
    """Return the raw loaded timepad_config.json dict.

    Delegates to aiteamforge_paths.load_timepad_config() when available.
    Returns an empty dict if the loader is not yet importable (pre-002 bootstrap).
    """
    try:
        from aiteamforge_paths import load_timepad_config  # sibling 002
        return load_timepad_config()
    except (ImportError, Exception):
        return {}


def get_timepad_team_config(team_slug: str) -> dict:
    """Return the connection config block for a team from timepad_config.json.

    Public re-export of ``aiteamforge_paths.get_timepad_team_config()``
    (XACA-0619-005), providing a single import point for consumers that want
    both token resolution and config access from this module.

    Returns the dict with fields: apiBaseUrl, tokenRef, clientId, projectId,
    tagId.  Returns an empty dict when the team is absent or config failed to
    load.

    NOTE: This dict does NOT contain an ``enabled`` flag.  The enable gate
    lives in the board JSON; call ``is_timepad_enabled()`` separately.
    """
    try:
        from aiteamforge_paths import get_timepad_team_config as _get_cfg  # sibling 005
        return _get_cfg(team_slug)
    except (ImportError, Exception):
        # Pre-005 bootstrap fallback — read raw from loader or direct dict parse.
        try:
            from aiteamforge_paths import get_timepad_team_config_raw  # sibling 002
            return get_timepad_team_config_raw(team_slug)
        except (ImportError, Exception):
            raw = get_timepad_raw_config()
            return raw.get("teams", {}).get(team_slug, {})


def is_timepad_enabled(team_slug: str) -> bool:
    """Return True iff TimePad is enabled for the given team.

    Delegates to ``aiteamforge_paths.is_timepad_enabled()`` (XACA-0619-005),
    which reads ``teamConfig.timepadSupport.enabled`` from the team's board
    JSON (single source of truth, mirrors crSupport pattern).

    The ``enabled`` field that previously existed in ``timepad_config.json``
    has been removed — this function no longer reads the config file for the
    gate; it reads the board JSON via the authoritative accessor.

    Returns False (safe default — disabled) if the board JSON is unavailable
    or the loader is not yet importable (pre-005 bootstrap).
    """
    try:
        from aiteamforge_paths import is_timepad_enabled as _board_enabled  # sibling 005
        return _board_enabled(team_slug)
    except (ImportError, Exception):
        return False  # safe default — disabled


# ---------------------------------------------------------------------------
# Module self-test (python3 timepad_config.py)
# ---------------------------------------------------------------------------

if __name__ == "__main__":  # pragma: no cover
    import argparse

    parser = argparse.ArgumentParser(
        description="TimePad config module self-test / diagnostic"
    )
    parser.add_argument("team", help="Team slug (e.g. academy)")
    parser.add_argument("--team-code", help="Team short code (e.g. ACADEMY)")
    parser.add_argument("--token-ref", help="Config auth.tokenRef env-var name")
    parser.add_argument(
        "--server", default=None, help="Fleet Monitor URL override"
    )
    args = parser.parse_args()

    print(f"Team slug:          {args.team}")
    print(f"Per-team env var:   {env_var_for_team(args.team, args.team_code)}")
    print(f"Vault engine:       {VAULT_ENGINE_SLUG}")
    print(f"Vault account:      {args.team}")
    print(f"vault-fetch.sh:     {_vault_fetch_sh_path() or '(not found)'}")
    print()

    fingerprint = resolve_timepad_token_fingerprint(
        args.team,
        team_code=args.team_code,
        token_ref=args.token_ref,
        server_url=args.server,
    )
    print(f"Token fingerprint:  {fingerprint}")
    print(f"TimePad enabled:    {is_timepad_enabled(args.team)}")
