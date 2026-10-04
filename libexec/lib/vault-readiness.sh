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
#
# ONE SET OF ROUTING RULES (XACA-1225-022): the smoke does NOT decide for
# itself which vault-fetch.sh to run, which (engine, account) to ask for, or
# whether the launch would be refused. A hand copy of those rules diverged
# from cc-account-routing.sh in PR #1053 (false "libsodium missing" on an
# invalid account_slug, a false PASS on a non-anthropic engine the router
# refuses, no rc-7 team fallback, ...). Instead the doctor sources the
# INSTALLED cc-account-routing.sh (the copy next to vault-fetch.sh, under
# zsh — the router is zsh-only) and calls its _cc_vault_probe_plan, which is
# built from the router's own _cc_resolve_vault_fetch /
# _cc_is_team_identity_slug / _cc_engine_refusal_reason / _cc_vault_candidates.
# The single rule kept here is the loop the router documents on
# _cc_vault_candidates: try candidates in order, advance ONLY on exit 7.
# tests/test-xaca-1225-022-vault-smoke-parity.sh drives the same input table
# through the real router and through this report and requires identical
# vault-fetch argv, so a drift in that loop goes red too.

# ─── Credential census ──────────────────────────────────────────────────────
#
# aitf_vault_credential_census <kanban_hooks_dir>
#
# Prints one line per team DECLARED IN THIS MACHINE'S team-paths.json, fields
# separated by the ASCII unit separator \037 (XACA-1225-022: a space-joined
# line mis-parsed a slug containing whitespace; \037 is not whitespace, so
# `IFS=$'\037' read` also keeps EMPTY fields, which an empty engine_slug needs):
#   routed<US><team><US><engine_slug><US><account_slug>   (raw values, "" if unset)
#   malformed<US><team>     a credential field is an object/array — the router
#                           cannot read the declaration and REFUSES
#   null<US><team>
#   undeclared<US><team>
# Values are normalised exactly the way cc-account-routing.sh's own reader
# does (cred.get(k, ""), None -> "", non-str -> str(), CR/LF -> space) plus
# \037 -> space, so the router and the doctor see the same strings.
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
US = "\037"

def clean(v):
    # Same normalisation as cc-account-routing.sh's _sanitize().
    if isinstance(v, (dict, list)):
        raise ValueError("not a scalar")
    if v is None:
        v = ""
    elif not isinstance(v, str):
        v = str(v)
    return v.replace("\r", " ").replace("\n", " ").replace(US, " ")

out = []
for team in sorted(teams):
    tname = clean(team)
    try:
        cred = registry.ai_credential(team, config=cfg)
    except Exception:
        # An unresolvable team is not a recorded "none" decision: report it
        # as undeclared, the fail-closed reading (it refuses like one).
        out.append(US.join(("undeclared", tname)))
        continue
    if cred is registry.ABSENT:
        out.append(US.join(("undeclared", tname)))
    elif cred is None:
        out.append(US.join(("null", tname)))
    else:
        try:
            eng = clean(cred.get("engine_slug", ""))
            acct = clean(cred.get("account_slug", ""))
        except ValueError:
            out.append(US.join(("malformed", tname)))
            continue
        out.append(US.join(("routed", tname, eng, acct)))
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
  while IFS="$(printf '\037')" read -r kind team rest; do
    [ -n "$kind" ] || continue
    case "$kind" in
      routed|undeclared|malformed) list="${list:+$list }$team" ;;
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
# _aitf_vr_router_zsh <routing_sh> <fn> [args...] — source the installed
# cc-account-routing.sh in a clean zsh (-f: no user rc files) and call one of
# its exported planning functions. rc 90 = zsh missing, 91 = the router did
# not source completely, 92 = the router predates XACA-1225-022 (no such fn).
_aitf_vr_router_zsh() {
  local routing="$1"; shift
  if ! command -v zsh >/dev/null 2>&1; then
    return 90
  fi
  zsh -f -c '
    r="$1"; fn="$2"; shift 2
    source "$r" >/dev/null 2>&1 || exit 91
    _cc_routing_core_complete 2>/dev/null || exit 91
    whence -w "$fn" >/dev/null 2>&1 || exit 92
    "$fn" "$@"
  ' aitf-vault-readiness "$routing" "$@"
}

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
#   2. libsodium-wrappers next to the vault-fetch.sh THE ROUTER RUNS — the
#      exact test vault-fetch.sh itself applies before deciding to exit 1.
#      Which vault-fetch.sh that is comes from the router's own
#      _cc_resolve_vault_fetch (dev layout fleet-monitor/client/ first, then
#      the flattened scripts/ copy), not from an assumption here.
#   3. per routed team, the router's plan (_cc_vault_probe_plan):
#        refuse -> FAIL with the router's own refusal message (no fetch)
#        skip   -> info (the router does not use the vault for this team)
#      and ONE vault-fetch smoke — for the first routed team the router would
#      actually fetch for — over the router's candidate list, advancing only
#      on exit 7; rc only, token discarded.
# Severity of 1–2: FAIL when a team depends on the vault tier (any routed or
# undeclared team, or the census could not be taken — fail-closed); WARN when
# every installed team is a recorded null (nothing will refuse).
aitf_vault_readiness_report() {
  local scripts_dir="${1:?aitf_vault_readiness_report: scripts_dir required}"
  local hooks_dir="${2:-$(dirname "$scripts_dir")/kanban-hooks}"
  local tab us
  tab="$(printf '\t')"
  us="$(printf '\037')"
  local routing="$scripts_dir/cc-account-routing.sh"

  # Which vault-fetch.sh does the router run? Ask it. Fall back to the
  # flattened sibling only when the router itself is not installed (then no
  # launch consults the vault and the smoke below is skipped anyway).
  local vfetch="" vf_rc=0 router_state="absent"
  if [ -f "$routing" ]; then
    vfetch="$(_aitf_vr_router_zsh "$routing" _cc_resolve_vault_fetch 2>/dev/null)" || vf_rc=$?
    case "$vf_rc" in
      0) router_state="ok" ;;
      90) router_state="nozsh" ;;
      92) router_state="old" ;;
      *) router_state="broken" ;;
    esac
  fi
  if [ "$router_state" != "ok" ] || [ -z "$vfetch" ]; then
    vfetch="$scripts_dir/vault-fetch.sh"
  fi
  local vf_dir
  vf_dir="$(dirname "$vfetch")"

  if [ ! -f "$vfetch" ]; then
    printf 'info%svault-fetch.sh not installed (%s) — vault readiness not applicable%s\n' "$tab" "$vfetch" "$tab"
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
  if [ -d "$vf_dir/node_modules/libsodium-wrappers" ]; then
    printf 'pass%slibsodium-wrappers installed in %s/node_modules%s\n' "$tab" "$vf_dir" "$tab"
  else
    printf '%s%slibsodium-wrappers missing in %s/node_modules — vault-fetch.sh exits 1, vault tier is OFF%s%s. Fix: (cd "%s" && npm ci --omit=dev)\n' "$sev" "$tab" "$vf_dir" "$tab" "$impact" "$vf_dir"
  fi

  # 3. per-team plan + one smoke.
  if [ "$census_rc" -ne 0 ]; then
    printf 'info%svault-fetch smoke skipped — team credential census unavailable%s\n' "$tab" "$tab"
    return 0
  fi
  case "$router_state" in
    absent) printf 'info%svault-fetch smoke skipped — cc-account-routing.sh not installed in %s (no launch consults the vault)%s\n' "$tab" "$scripts_dir" "$tab"; return 0 ;;
    nozsh)  printf 'warn%svault-fetch smoke skipped — zsh not found (cc-account-routing.sh is zsh-only)%s\n' "$tab" "$tab"; return 0 ;;
    old)    printf 'warn%svault-fetch smoke skipped — installed cc-account-routing.sh predates XACA-1225-022 (no _cc_vault_probe_plan); run: aiteamforge upgrade%s\n' "$tab" "$tab"; return 0 ;;
    broken) printf 'fail%scc-account-routing.sh did not load completely under zsh — every cc launch will fail; run: aiteamforge upgrade%s%s\n' "$tab" "$tab" "$routing"; return 0 ;;
    *) : ;;
  esac

  local kind team eng acct any_routed="" smoked=""
  local plan plan_rc ptag pval p_engine cands c smoke_rc tried
  while IFS="$us" read -r kind team eng acct; do
    case "$kind" in
      malformed)
        printf 'fail%steam %s: ai.credential has an object/array field — the router cannot read it and REFUSES the launch%s\n' "$tab" "$team" "$tab"
        continue ;;
      routed) any_routed=1 ;;
      *) continue ;;
    esac

    plan_rc=0
    plan="$(_aitf_vr_router_zsh "$routing" _cc_vault_probe_plan "$team" "$eng" "$acct" 2>/dev/null)" || plan_rc=$?
    if [ "$plan_rc" -ne 0 ]; then
      printf 'fail%steam %s: could not get the router plan (rc=%s)%s\n' "$tab" "$team" "$plan_rc" "$tab"
      continue
    fi

    p_engine=""; cands=""
    local p_refuse="" p_skip=""
    while IFS="$tab" read -r ptag pval; do
      case "$ptag" in
        refuse) p_refuse="$pval" ;;
        skip) p_skip="$pval" ;;
        engine) p_engine="$pval" ;;
        candidate) cands="${cands}${pval}${us}" ;;
        *) : ;;
      esac
    done <<PLAN
$plan
PLAN

    if [ -n "$p_refuse" ]; then
      printf 'fail%steam %s: the router REFUSES this launch: %s%s\n' "$tab" "$team" "$p_refuse" "$tab"
      continue
    fi
    if [ -n "$p_skip" ]; then
      printf 'info%steam %s: %s%s\n' "$tab" "$team" "$p_skip" "$tab"
      continue
    fi
    if [ -n "$smoked" ] || [ -z "$cands" ] || [ -z "$p_engine" ]; then
      continue
    fi
    smoked=1

    # The router's loop rule (documented on _cc_vault_candidates): candidates
    # in order, advance ONLY on exit 7. rc captured FIRST; stdout (the token)
    # and stderr discarded; no pipe (feedback_pipefail_hides_exit_code).
    smoke_rc=255; tried=""
    local rest="$cands"
    while [ -n "$rest" ]; do
      c="${rest%%"$us"*}"
      rest="${rest#*"$us"}"
      tried="${tried:+$tried, }${p_engine}/${c}"
      smoke_rc=0
      VAULT_FETCH_NO_AUTO_INSTALL=1 "$vfetch" "$p_engine" "$c" >/dev/null 2>&1 || smoke_rc=$?
      if [ "$smoke_rc" -ne 7 ]; then
        break
      fi
    done

    local verdict v_sev v_msg
    verdict="$(aitf_vault_fetch_rc_verdict "$smoke_rc")"
    v_sev="${verdict%%|*}"
    v_msg="${verdict#*|}"
    printf '%s%s%s%steam %s via %s\n' "$v_sev" "$tab" "$v_msg" "$tab" "$team" "$tried"
  done <<CENSUS
$census
CENSUS

  if [ -z "$any_routed" ]; then
    printf 'info%svault-fetch smoke skipped — no team has a routed ai.credential%s\n' "$tab" "$tab"
  elif [ -z "$smoked" ]; then
    printf 'info%svault-fetch smoke skipped — the router would not fetch from the vault for any routed team%s\n' "$tab" "$tab"
  fi
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
    while IFS="$(printf '\037')" read -r _k _t _r; do
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
