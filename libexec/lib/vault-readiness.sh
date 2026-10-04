#!/bin/bash
# vault-readiness.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-1225-021: is the vault credential tier actually usable on this box?
#
# WHY THIS EXISTS (XACA-1312 / PR #957, rollout-plan addendum 2026-09-22):
# cc-account-routing.sh resolves a team's Anthropic credential via
# $SCRIPTS_DIR/vault-fetch.sh, always with VAULT_FETCH_NO_AUTO_INSTALL=1 —
# it never installs anything at launch time. vault-fetch.sh exits 127 when
# `node` is not on PATH and 1 when node_modules/libsodium-wrappers is
# missing. Both are UNRECOGNISED exits to the router, which (XACA-0972-019)
# treats them as "vault-configured but faulted" whenever a keypair exists.
# Fail-closed consequences (XACA-1312 U2 / XACA-0977 D3):
#   - routed team (ai.credential = object) WITH its env var  -> launches, warns
#   - routed team WITHOUT its env var                        -> REFUSES
#   - undeclared team (ai.credential absent)                 -> REFUSES
#   - declared-none team (ai.credential = null)              -> launches
# The only thing that provisions libsodium-wrappers is msg-client-deps.sh's
# `npm ci`, which is fail-soft. Before this file, a failed `npm ci` printed a
# two-line note and the vault tier stayed silently off until a launch refused.
#
# WHERE THE FILES LIVE (resolved by measurement, XACA-1225-021): the scripts
# dir is $AITEAMFORGE_DIR/scripts — default $HOME/aiteamforge/scripts, NOT
# ~/.aiteamforge/scripts as the XACA-1312 addendum wrote. install-shell.sh
# calls provision_msg_client_node_deps "$AITEAMFORGE_DIR/scripts";
# aiteamforge-upgrade.sh calls it with "${WORKING_DIR}/scripts"
# (get_working_dir, same default); cc-account-routing.sh resolves
# vault-fetch.sh as a flattened sibling of itself in that same dir. Only the
# vault keypair/cache live under ~/.aiteamforge/. The registry module this file
# reads is the installed copy at <working_dir>/kanban-hooks/ — the sibling of
# scripts/ in both layouts (install-kanban.sh's install_kanban_hooks).
#
# CALLERS:
#   - msg-client-deps.sh  provision_msg_client_node_deps() -> the LOUD warning
#     when node is absent or `npm ci` fails (install AND upgrade paths).
#   - bin/aiteamforge-doctor.sh and libexec/commands/aiteamforge-doctor.sh
#     -> `--check vault-readiness`. TWO doctors on purpose (XACA-0807: both are
#     live, reached by different entrypoints); both render THIS module's output
#     so they cannot drift — the same discipline as vault-drift.sh.
#
# STRICTNESS: callers run `set -euo pipefail` (install-kanban family) or
# `set -eo pipefail` (upgrade, doctors). Every function returns explicitly; no
# function ends on a bare `[[ cond ]] && cmd` (feedback_set_e_last_line_short_
# circuit.md). bash 3.2 safe: no associative arrays, no mapfile, no ${x,,}.
#
# SECRET HYGIENE: the smoke fetch's stdout IS the plaintext credential. It is
# redirected to /dev/null at the call site and never captured into a variable,
# a file, or a pipe. Only the exit code is kept.

# ─── Credential census ──────────────────────────────────────────────────────
#
# aitf_vault_credential_census <kanban_hooks_dir>
#
# Prints one line per team DECLARED IN THIS MACHINE'S team-paths.json:
#   routed <team> <engine_slug|-> <account_slug|->
#   null <team>
#   undeclared <team>
# Returns 0 when the census completed against a structurally valid config,
# 2 when it could not be taken at all (no python, registry module not
# installed, import error, config missing/invalid/unreadable/quarantined).
#
# Reads ONLY through aiteamforge_registry.ai_credential() — the three-state
# accessor (XACA-1184). Never truthiness on raw JSON, never the retired flat
# anthropic_account_* fields (they are inert on disk; the accessor ignores
# them on purpose).
#
# Why on-disk teams only, not registered_teams(): registered_teams() is the
# UNION with the baked-in DEFAULT_TEAMS seed, which names every team in the
# product — almost all of them not installed here, and all of them
# "undeclared" by construction. Counting those would make "an undeclared team
# exists" true on every machine and turn the loud warning into noise nobody
# reads. A team only launches on a box that has it in team-paths.json.
#
# Uses peek_config() (no self-heal, never writes) and passes the resolved
# dict into every ai_credential() call so the file is read exactly once.
aitf_vault_credential_census() {
  local hooks_dir="${1:-}"
  local py="${AITEAMFORGE_PYTHON:-python3}"

  if [ -z "$hooks_dir" ] || [ ! -f "$hooks_dir/aiteamforge_registry.py" ] \
      || [ ! -f "$hooks_dir/aiteamforge_paths.py" ]; then
    return 2
  fi
  if ! command -v "$py" >/dev/null 2>&1; then
    return 2
  fi

  local rc=0
  # -B: never drop __pycache__ into the consumer's installed kanban-hooks/.
  "$py" -B - "$hooks_dir" 2>/dev/null <<'PYEOF' || rc=$?
import sys
sys.path.insert(0, sys.argv[1])
try:
    import aiteamforge_paths as paths
    import aiteamforge_registry as registry
except Exception:
    sys.exit(2)
try:
    peek = paths.peek_config()
except Exception:
    sys.exit(2)
if getattr(peek, "status", None) != "ok" or not isinstance(peek.config, dict):
    sys.exit(2)
cfg = peek.config
teams = cfg.get("teams")
if not isinstance(teams, dict):
    sys.exit(2)
out = []
for team in sorted(teams):
    try:
        cred = registry.ai_credential(team, config=cfg)
    except Exception:
        # An unresolvable team is not a recorded "none" decision: report it
        # as undeclared, the fail-closed reading (it refuses like one).
        out.append("undeclared %s" % team)
        continue
    if cred is registry.ABSENT:
        out.append("undeclared %s" % team)
    elif cred is None:
        out.append("null %s" % team)
    else:
        eng = str(cred.get("engine_slug") or "-")
        acct = str(cred.get("account_slug") or "-")
        out.append("routed %s %s %s" % (team, eng, acct))
sys.stdout.write("".join(line + "\n" for line in out))
PYEOF
  if [ "$rc" -ne 0 ]; then
    return 2
  fi
  return 0
}

# aitf_vault_at_risk_teams <census_text>
#
# Prints the space-separated teams that MAY REFUSE to launch while the vault
# tier is faulted: every undeclared team and every routed team. A routed team
# with its env-var failover key set still launches, but whether that key is
# exported in the user's interactive shell is invisible from an installer or
# doctor process — so routed teams are listed, and the renderers carry the
# "(routed teams only if their env-var key is unset)" caveat instead.
aitf_vault_at_risk_teams() {
  local census="$1" kind team rest list=""
  while read -r kind team rest; do
    [ -n "$kind" ] || continue
    case "$kind" in
      routed|undeclared) list="${list:+$list }$team" ;;
      *) : ;;
    esac
  done <<EOF
$census
EOF
  printf '%s' "$list"
  return 0
}

# ─── Smoke-fetch exit-code vocabulary ───────────────────────────────────────
#
# aitf_vault_fetch_rc_verdict <rc>
# Prints "<pass|warn|fail>|<message>" for a vault-fetch.sh exit code. Codes
# per vault-fetch.sh's own header (0 ok, 5 cache-hit, 1 usage/deps, 3
# not-configured, 4 unreachable, 6 decrypt, 7 not-found, 8 no-fleet-url) plus
# 127 from its node precondition.
aitf_vault_fetch_rc_verdict() {
  case "${1:-}" in
    0) printf '%s' "pass|vault-fetch smoke OK (rc=0) — vault tier usable" ;;
    5) printf '%s' "pass|vault-fetch smoke OK (rc=5, fresh cache hit) — vault tier usable" ;;
    127) printf '%s' "fail|vault-fetch smoke rc=127 — node not on PATH; vault tier is OFF" ;;
    1) printf '%s' "fail|vault-fetch smoke rc=1 — libsodium-wrappers missing (or bad arguments); vault tier is OFF" ;;
    # XACA-1318 (open): a LOCKED login Keychain currently also surfaces as 3,
    # because vault-keygen's keychain lookup cannot see the key — a non-GUI /
    # SSH session on a genuinely vault-provisioned box reads as "no keypair".
    3) printf '%s' "warn|vault-fetch smoke rc=3 — not vault-configured (no keypair on this machine), or the login Keychain is locked (non-GUI/SSH session, XACA-1318)" ;;
    4) printf '%s' "warn|vault-fetch smoke rc=4 — vault server unreachable (launches fall back to the stale cache, then fail closed)" ;;
    6) printf '%s' "fail|vault-fetch smoke rc=6 — decrypt failed (wrong/rotated key); re-provision or re-seal" ;;
    7) printf '%s' "warn|vault-fetch smoke rc=7 — no secret sealed for this engine/account on the vault" ;;
    8) printf '%s' "fail|vault-fetch smoke rc=8 — keypair present but no fleet server URL configured" ;;
    *) printf '%s' "fail|vault-fetch smoke rc=${1:-?} — vault-fetch faulted (unrecognised exit; the router fails closed on this)" ;;
  esac
  return 0
}

# ─── Doctor check ───────────────────────────────────────────────────────────
#
# aitf_vault_readiness_report <scripts_dir> [kanban_hooks_dir]
#
# Emits one line per result on stdout, TAB-separated:
#   <pass|warn|fail|info><TAB><message><TAB><detail>
# The doctors render pass/warn/fail through their own check_result and print
# `info` lines without counting them. Always returns 0.
#
# Checks:
#   1. node on the PATH vault-fetch.sh will see (it prepends the stock brew
#      and system prefixes), version >= 18.
#   2. libsodium-wrappers present in <scripts_dir>/node_modules — the exact
#      test vault-fetch.sh itself applies before deciding to exit 1.
#   3. smoke: ONE routed team's vault-fetch, rc only, token discarded. Skipped
#      (info, not fail) when no team is routed or vault-fetch.sh isn't shipped.
# Severity of 1–2: FAIL when a team depends on the vault tier (any routed or
# undeclared team, or the census could not be taken — fail-closed); WARN when
# every installed team is a recorded null (nothing will refuse).
aitf_vault_readiness_report() {
  local scripts_dir="${1:?aitf_vault_readiness_report: scripts_dir required}"
  local hooks_dir="${2:-$(dirname "$scripts_dir")/kanban-hooks}"
  local tab
  tab="$(printf '\t')"

  if [ ! -f "$scripts_dir/vault-fetch.sh" ]; then
    printf 'info%svault-fetch.sh not installed in %s — vault readiness not applicable%s\n' "$tab" "$scripts_dir" "$tab"
    return 0
  fi

  local census="" census_rc=0
  census="$(aitf_vault_credential_census "$hooks_dir")" || census_rc=$?

  local sev="fail" at_risk=""
  if [ "$census_rc" -eq 0 ]; then
    at_risk="$(aitf_vault_at_risk_teams "$census")"
    if [ -z "$at_risk" ]; then
      sev="warn"
    fi
  fi
  local impact
  if [ "$census_rc" -ne 0 ]; then
    impact="team credential census unavailable (registry/team-paths.json unreadable) — assuming teams depend on the vault"
  elif [ -n "$at_risk" ]; then
    impact="teams that refuse to launch while the vault tier is off (routed teams only if their env-var key is unset): ${at_risk}"
  else
    impact="every installed team is declared ai.credential=null — no launch depends on the vault tier"
  fi

  # 1. node, on the PATH vault-fetch.sh actually builds for itself.
  # AITF_VR_PATH_PREFIX is a TEST SEAM only (the stock prefixes would find the
  # dev box's real node and make "node missing" untestable); production never
  # sets it, and an unset value yields exactly vault-fetch.sh's own prefix.
  local vf_prefix="${AITF_VR_PATH_PREFIX-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
  local vf_path="${vf_prefix:+$vf_prefix:}${PATH:-}"
  local node_bin="" node_ver="" node_major=""
  node_bin="$(PATH="$vf_path" command -v node 2>/dev/null || true)"
  if [ -z "$node_bin" ]; then
    printf '%s%snode not on PATH — vault-fetch.sh exits 127, vault tier is OFF%s%s. Install: brew install node\n' "$sev" "$tab" "$tab" "$impact"
  else
    node_ver="$("$node_bin" --version 2>/dev/null || true)"
    node_major="${node_ver#v}"
    node_major="${node_major%%.*}"
    case "$node_major" in
      ''|*[!0-9]*)
        printf '%s%snode at %s did not report a usable version (%s) — vault-fetch may fail%s%s\n' "$sev" "$tab" "$node_bin" "${node_ver:-none}" "$tab" "$impact"
        ;;
      *)
        if [ "$node_major" -ge 18 ]; then
          printf 'pass%snode %s on vault-fetch PATH (%s)%s\n' "$tab" "$node_ver" "$node_bin" "$tab"
        else
          printf '%s%snode %s is older than 18 — vault-fetch requires Node.js >= 18%s%s. Upgrade: brew upgrade node\n' "$sev" "$tab" "$node_ver" "$tab" "$impact"
        fi
        ;;
    esac
  fi

  # 2. libsodium-wrappers — the same directory test vault-fetch.sh applies.
  if [ -d "$scripts_dir/node_modules/libsodium-wrappers" ]; then
    printf 'pass%slibsodium-wrappers installed in %s/node_modules%s\n' "$tab" "$scripts_dir" "$tab"
  else
    printf '%s%slibsodium-wrappers missing in %s/node_modules — vault-fetch.sh exits 1, vault tier is OFF%s%s. Fix: (cd "%s" && npm ci --omit=dev)\n' "$sev" "$tab" "$scripts_dir" "$tab" "$impact" "$scripts_dir"
  fi

  # 3. smoke — only with a routed team to ask about.
  if [ "$census_rc" -ne 0 ]; then
    printf 'info%svault-fetch smoke skipped — team credential census unavailable%s\n' "$tab" "$tab"
    return 0
  fi
  local kind team eng acct pick_team="" pick_eng="" pick_acct=""
  while read -r kind team eng acct; do
    if [ "$kind" = "routed" ]; then
      pick_team="$team"; pick_eng="$eng"; pick_acct="$acct"
      break
    fi
  done <<EOF
$census
EOF
  if [ -z "$pick_team" ]; then
    printf 'info%svault-fetch smoke skipped — no team has a routed ai.credential%s\n' "$tab" "$tab"
    return 0
  fi
  # Mirror the router's namespace choice (XACA-1184-005): <engine>/<account>
  # when both are declared, else the permanent anthropic/<team> layout.
  if [ "$pick_eng" = "-" ] || [ "$pick_acct" = "-" ]; then
    pick_eng="anthropic"
    pick_acct="$pick_team"
  fi

  # rc captured FIRST, stdout (the token) and stderr both discarded. No pipe:
  # `cmd | tail` would report tail's status (feedback_pipefail_hides_exit_code).
  local smoke_rc=0
  VAULT_FETCH_NO_AUTO_INSTALL=1 "$scripts_dir/vault-fetch.sh" "$pick_eng" "$pick_acct" >/dev/null 2>&1 || smoke_rc=$?

  local verdict v_sev v_msg
  verdict="$(aitf_vault_fetch_rc_verdict "$smoke_rc")"
  v_sev="${verdict%%|*}"
  v_msg="${verdict#*|}"
  printf '%s%s%s%steam %s via %s/%s\n' "$v_sev" "$tab" "$v_msg" "$tab" "$pick_team" "$pick_eng" "$pick_acct"
  return 0
}

# ─── Install/upgrade LOUD warning ───────────────────────────────────────────
#
# aitf_vault_tier_loud_warning <scripts_dir> <reason>
#
# Called by provision_msg_client_node_deps() when node/npm is absent or
# `npm ci` failed. Prints a boxed warning to stderr naming the consequence,
# the teams that will refuse, and the remedy — or stays quiet. Always returns
# 0 (loud, NOT fatal: install/upgrade must never abort over this).
#
# CONDITION (XACA-1225-021 judgment): loud UNLESS the census POSITIVELY shows
# that every team installed on this box is a recorded ai.credential=null.
#   - routed team present     -> loud (refuses without its env-var key)
#   - undeclared team present -> loud (XACA-0977 D3: absent refuses on a
#                                faulted vault, same as a routed team without
#                                a key; the subitem's original "routed only"
#                                wording would miss these)
#   - census unavailable, or zero teams on disk -> loud. Fail-closed: on a
#     fresh install kanban-hooks/ and team-paths.json may not exist yet when
#     install-shell.sh runs, and every team added later starts undeclared.
#     The quiet branch requires positive evidence, never absence of evidence
#     (feedback_malformed_check_returns_reassuring_result.md).
# Keypair presence is deliberately NOT a condition: the upgrade runs
# provision_msg_routing (which generates the keypair) right after this step,
# so "no keypair yet" is exactly the moment before the vault switches on.
aitf_vault_tier_loud_warning() {
  local scripts_dir="${1:-}" reason="${2:-kb-msg client dependency install failed}"
  local hooks_dir
  hooks_dir="$(dirname "$scripts_dir")/kanban-hooks"

  local census="" census_rc=0 at_risk="" any_team=""
  census="$(aitf_vault_credential_census "$hooks_dir")" || census_rc=$?
  if [ "$census_rc" -eq 0 ]; then
    at_risk="$(aitf_vault_at_risk_teams "$census")"
    # read-loop, not `printf | awk '...exit'`: an early-exiting reader can
    # SIGPIPE the writer, which pipefail + set -e turns into an abort of the
    # CALLING installer (XACA-1404 SIGPIPE class).
    local _k _t _r
    while read -r _k _t _r; do
      if [ -n "$_t" ]; then any_team="$_t"; break; fi
    done <<EOF
$census
EOF
    if [ -z "$at_risk" ] && [ -n "$any_team" ]; then
      return 0
    fi
  fi

  local who
  if [ "$census_rc" -ne 0 ]; then
    who="could not read team credentials (team-paths.json/registry not available yet) — assume EVERY team without an env-var key"
  elif [ -z "$any_team" ]; then
    who="no teams in team-paths.json yet — every team added later starts undeclared and will refuse"
  else
    who="$at_risk"
  fi

  {
    echo ""
    echo "################################################################################"
    echo "##  WARNING: VAULT CREDENTIAL TIER IS OFF ON THIS MACHINE (XACA-1225-021)"
    echo "##"
    echo "##  Cause:  ${reason}"
    echo "##  vault-fetch needs node >= 18 AND libsodium-wrappers in:"
    echo "##          ${scripts_dir}/node_modules"
    echo "##"
    echo "##  Effect: cc treats the vault as FAULTED and fails closed. These teams will"
    echo "##          REFUSE TO LAUNCH (routed teams only if their env-var key is unset):"
    echo "##          ${who}"
    echo "##"
    echo "##  Fix:    (cd \"${scripts_dir}\" && npm ci --omit=dev)"
    echo "##  Verify: aiteamforge doctor --check vault-readiness"
    echo "##  (Install continues — this is a warning, not a failure.)"
    echo "################################################################################"
    echo ""
  } >&2
  return 0
}
