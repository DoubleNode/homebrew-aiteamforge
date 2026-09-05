#!/bin/bash
# launchagents.sh
# Shared LaunchAgent vocabulary for aiteamforge lifecycle commands (XACA-0734).
#
# WHY THIS FILE EXISTS
# ────────────────────
# LaunchAgent render logic used to be duplicated across three places:
#   1. libexec/commands/aiteamforge-upgrade.sh  (_render_launchagent_template)
#   2. libexec/commands/aiteamforge-migrate.sh  (_render_kanban_template)
#   3. libexec/installers/install-kanban.sh     (inline `sed` per installer)
# The XACA-0571-014 SIBLING-DRIFT NOTE in upgrade.sh warned that adding a
# placeholder to a template required updating every renderer or upgraded plists
# would ship with unresolved {{...}} tokens. XACA-0734 needed the same logic in a
# FOURTH place (`aiteamforge doctor --fix`), so rather than add another copy the
# renderer and the plist→template map now live here and are sourced by upgrade.sh
# and doctor.sh. Add a new {{PLACEHOLDER}} in ONE place: the sed chain below.
#
# THE OPT-OUT SENTINEL (the core of XACA-0734)
# ────────────────────────────────────────────
# `aiteamforge upgrade` used to skip any LaunchAgent whose plist was absent from
# ~/Library/LaunchAgents, on the theory that "absent == the user opted out at
# install time". That inference is WRONG, and it fails in the one direction that
# matters: it cannot distinguish
#     (a) "the user deliberately removed this agent"          — respect it
# from
#     (b) "this plist did not exist when this box was installed" — install it
# so every NET-NEW mandatory LaunchAgent was permanently unreachable on every
# already-installed box. Field-confirmed on M1Pro: it had no
# com.aiteamforge.auto-upgrade.plist, and auto-upgrade is the agent that PERFORMS
# upgrades — so the box could never auto-upgrade, and therefore could never
# receive the fix that would have installed the auto-upgrade plist. A self-sealing
# failure; it only got recent fixes because a human upgraded it by hand.
#
# The fix: intent is RECORDED, never INFERRED from disk state. A plist's absence
# means nothing on its own. An agent is only suppressed when its basename appears
# in the opt-out sentinel — a file the user's own uninstall action wrote.
#
# This is the THIRD instance of this bug class in this codebase; it mirrors
# _xaca0673_mandatory_materialize_basenames (shared Python modules) and
# _xaca0771_mandatory_alias_basenames / _xaca0771_mandatory_hook_basenames
# (alias files / claude hooks) in aiteamforge-upgrade.sh.
#
# DEPENDENCIES: lib/common.sh (print_* helpers, _aitf_launchctl) and, optionally,
# lib/constants.sh (KANBAN_BACKUP_INTERVAL_DEFAULT) / lib/config.sh
# (get_working_dir). All are consumed defensively so this file is safe to source
# from a test harness that only stubs the print_* helpers.

# Guard against double-sourcing (readonly errors in subshells)
if [[ -n "${_LAUNCHAGENTS_SH_LOADED:-}" ]]; then
    # shellcheck disable=SC2317
    # SC2317 ("command appears unreachable") is a FALSE POSITIVE here: shellcheck
    # analyses this file standalone, where nothing sets _LAUNCHAGENTS_SH_LOADED, so
    # it concludes the guard body can never run. In reality the body is the entire
    # point — it fires on the SECOND `source` of this lib, which happens whenever a
    # command sources both this file and another lib that also sources it. Keep the
    # disable narrow (this one statement), not file-wide.
    return 0 2>/dev/null || true
fi
_LAUNCHAGENTS_SH_LOADED=1

#──────────────────────────────────────────────────────────────────────────────
# Agent → template map
#──────────────────────────────────────────────────────────────────────────────
# Newline-delimited "plist-basename:template-subpath" pairs. Subpaths resolve
# against ${FRAMEWORK_DIR}/share/templates/. This is the single source of truth
# for "which LaunchAgents does the upgrade path manage, and where does each one's
# template live" — upgrade.sh iterates it, doctor.sh looks up individual entries.
#
# com.aiteamforge.lcars-runatload is intentionally ABSENT: it was retired by
# XACA-0763-005. Legacy installs are torn down by remove_legacy_lcars_runatload_agent
# (lib/common.sh); it must never be re-rendered here.
_xaca0734_launchagent_map() {
  cat <<'EOF'
com.aiteamforge.kanban-backup.plist:kanban/backup-plist.template
com.aiteamforge.lcars-health.plist:kanban/lcars-health-plist.template
com.aiteamforge.auto-upgrade.plist:auto-upgrade/auto-upgrade-launchagent.template.plist
com.aiteamforge.lcars-watch.plist:auto-upgrade/lcars-watch-launchagent.template.plist
com.aiteamforge.cellar-watch.plist:auto-upgrade/cellar-watch-launchagent.template.plist
com.aiteamforge.host-ready.plist:kanban/host-ready-plist.template
EOF
}

# Resolve the template subpath for a plist basename.
# Usage: _xaca0734_launchagent_template_for <plist-basename>
# Echoes the subpath, or nothing (and returns 1) when the agent is unknown.
_xaca0734_launchagent_template_for() {
  local agent="$1"
  local line
  while IFS= read -r line; do
    case "$line" in
      "${agent}:"*) printf '%s\n' "${line#*:}"; return 0 ;;
    esac
  done <<EOF
$(_xaca0734_launchagent_map)
EOF
  return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Mandatory set
#──────────────────────────────────────────────────────────────────────────────
# LaunchAgents whose ABSENCE BREAKS CORE FUNCTION, and which upgrade must
# therefore materialize even when the plist is not on disk (unless the user has
# recorded an explicit opt-out — see the sentinel helpers below).
#
# Keep this set MINIMAL. An agent belongs here only if a box without it is
# meaningfully broken, not merely less convenient. Newline-delimited basenames;
# exact-line membership test.
#
#   com.aiteamforge.auto-upgrade.plist
#       HIGHEST PRIORITY. This is the agent that performs upgrades. Without it a
#       box is permanently stranded on whatever version it happens to have and can
#       never self-heal — including from this very bug. This is the agent M1Pro was
#       missing (XACA-0734-001).
#   com.aiteamforge.lcars-health.plist
#       Keepalive/health for the LCARS server. Without it a crashed cockpit stays
#       down until a human notices.
#   com.aiteamforge.kanban-backup.plist
#       Periodic kanban board backups. Without it board data has no recovery point.
#   com.aiteamforge.host-ready.plist (XACA-1066)
#       Per-host login readiness: restores a machine's configured tmux team
#       sessions and, where recorded, switches to the login window so a second
#       user can reach their own account without ending the owner's session.
#       Added by owner decision on XACA-1066, whose root incident is the SAME
#       "self-sealing, no human present" shape this mandatory set was created
#       for (XACA-0734): after an unattended M4Mini reset, no supported
#       mechanism restored the team tmux sessions and every user-scoped
#       aiteamforge LaunchAgent (including auto-upgrade) stayed down until a
#       human physically logged in. A box without this agent is exactly that
#       box again.
#       WHAT LICENSES MEMBERSHIP HERE, specifically: the script backing this
#       agent (scripts/kb-host-ready.sh) is a COMPLETE NO-OP whenever its
#       config file (~/.aiteamforge/host-ready.json) is absent — verified by
#       filesystem diff (no files created, not even a state file), not by a
#       log-message grep. So materializing the plist fleet-wide costs nothing
#       behaviourally on every box that has not opted in via a config file;
#       the plist itself is inert without one. This is what distinguishes it
#       from lcars-watch/cellar-watch below (excluded for the OPPOSITE
#       reason — they'd add live filesystem watchers to boxes that never had
#       them) and makes the "meaningfully broken, not merely less convenient"
#       bar something this entry actually clears rather than argues past.
#       RunAtLoad only, no KeepAlive — a one-shot per login, not a resident
#       server, so `aiteamforge upgrade`'s mandatory `launchctl load` at
#       upgrade time is guarded INSIDE the script (a login-session stamp +
#       session-age refusal) rather than here, so an upgrade landing mid-day
#       cannot suspend a working session. See XACA-1066-001-design.md §4.5/§7.3
#       for the full reasoning — do not re-derive it from scratch.
#
# DELIBERATE EXCLUSIONS — do not re-litigate these without a reason:
#   com.aiteamforge.lcars-watch.plist / com.aiteamforge.cellar-watch.plist
#       Auto-upgrade ACCELERATORS, not core function. They make an upgrade land
#       sooner (restart LCARS on file change / notice a new Cellar); a box without
#       them still upgrades correctly on the auto-upgrade agent's daily schedule.
#       Materializing them would silently add filesystem watchers to boxes that
#       never had them, which is a behavior change with no correctness payoff.
#   com.aiteamforge.cr-confluence-poller.plist
#       Config-gated and DISABLED BY DEFAULT — _cr_reconcile_disabled_plists
#       (install-kanban.sh) already implements a real, first-class opt-out concept
#       for it. It is not in the upgrade map at all, and force-materializing a
#       poller that most boxes intentionally do not run would be actively wrong.
_xaca0734_mandatory_launchagent_basenames() {
  cat <<'EOF'
com.aiteamforge.auto-upgrade.plist
com.aiteamforge.lcars-health.plist
com.aiteamforge.kanban-backup.plist
com.aiteamforge.host-ready.plist
EOF
}

# True (exit 0) when <plist-basename> is in the mandatory set.
_xaca0734_is_mandatory() {
  local agent="$1"
  case $'\n'"$(_xaca0734_mandatory_launchagent_basenames)"$'\n' in
    *$'\n'"${agent}"$'\n'*) return 0 ;;
  esac
  return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Applicability gate — "does this INSTALL have LaunchAgents at all?"
#──────────────────────────────────────────────────────────────────────────────
# The mandatory set answers "which agents must a box have?". This answers the
# PRIOR question: "is this a box that is supposed to have any of them?"
#
# WHY THIS EXISTS (XACA-0734 review, BLOCKING 1)
# ─────────────────────────────────────────────
# The first cut of this ticket read the opt-out sentinel and nothing else, which
# reproduced THE VERY BUG THE TICKET EXISTS TO KILL, with the roles reversed.
# The ticket's rule is "intent is RECORDED, never INFERRED". Two whole classes of
# install RECORD, at setup time, that they want no LaunchAgents — and the first
# cut simply did not read the files that intent was recorded in:
#
#   1. COCKPIT PROFILE (bin/aiteamforge-setup.sh:879-883, :1576-1600, :1656-1658)
#      A cockpit box is a thin client: LCARS and kanban run on a REMOTE host.
#      Setup skips feature selection entirely (INSTALL_KANBAN stays "no"), never
#      calls install_kanban_system, explicitly skips its LaunchAgent load block,
#      and writes `.install-profile` = "cockpit" for the stated purpose of letting
#      downstream tools "skip checks for components that are deliberately absent
#      in cockpit mode". bin/aiteamforge-doctor.sh:456 already reports the
#      agent-free state as a PASS.
#      Without this gate, every `aiteamforge upgrade` on a cockpit box would
#      render + `launchctl load` all three mandatory agents — two of which point
#      at ${WORKING_DIR}/lcars-ui and the kanban backup script, neither of which
#      exists there — creating recurring FAILING launchd jobs on a healthy box.
#
#   2. KANBAN DECLINED (bin/aiteamforge-setup.sh:915)
#      A user who answers "no" to "Install LCARS Kanban?" on a normal profile has
#      expressed intent every bit as explicitly as one who edits the sentinel. It
#      IS recorded — setup writes `"lcars_kanban": false` into .aiteamforge-config
#      (:1648). All three mandatory agents are kanban/LCARS infrastructure, so
#      materializing them on a box that declined kanban is the same wrong answer.
#
# WHY MARKERS AND NOT A SENTINEL WRITE
# ────────────────────────────────────
# The obvious alternative — have setup RECORD the three agents into the opt-out
# sentinel when the user declines — was considered and REJECTED. It would have
# setup writing into a file whose PRIMARY population path is the user's own text
# editor, so any later "clear it on an explicit yes" logic risks silently
# stomping a hand-edited opt-out. These two markers are already written by setup
# on every run, already describe exactly this intent, and are READ-ONLY here.
# Nothing in the XACA-0734 code path ever writes them.
#
# THE OPT-BACK-IN PATH IS INTACT (checked, and it is what makes this safe):
# setup.sh's upgrade-hydration block FORCES INSTALL_KANBAN="yes" on any
# non-cockpit re-run ("the shared-component refresh is the point of an upgrade"),
# which reinstalls the kanban system AND rewrites .aiteamforge-config with
# "lcars_kanban": true. So a decliner who changes their mind just re-runs
# `aiteamforge setup` — the marker flips itself and this gate opens. We never have
# to guess, and we never have to clear anything.
#
# FAIL OPEN. A box with NEITHER marker (every pre-existing install, including the
# M1Pro box this ticket was filed for) is APPLICABLE. Absence of a marker is not
# intent — that inference is the original bug. Only an explicit, recorded
# "no LaunchAgents here" closes the gate.
#
# NOTE the gate governs MATERIALIZING an absent agent. It must NOT suppress
# REFRESHING a plist that already exists: if a cockpit box somehow does have a
# plist, keeping its content current is still correct.
#
# Usage: _xaca0734_launchagents_applicable [<working_dir>]
# Returns 0 when this install should have mandatory LaunchAgents, 1 when it is
# recorded as deliberately having none.
_xaca0734_launchagents_applicable() {
  local wd="${1:-}"

  if [ -z "$wd" ]; then
    wd="${WORKING_DIR:-}"
  fi
  if [ -z "$wd" ] && declare -f get_working_dir >/dev/null 2>&1; then
    wd="$(get_working_dir 2>/dev/null || true)"
  fi
  if [ -z "$wd" ]; then
    wd="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  fi

  # Marker 1: cockpit install profile.
  local profile_file="${wd}/.install-profile"
  if [ -f "$profile_file" ] && [ -r "$profile_file" ]; then
    local profile
    profile="$(tr -d '[:space:]' < "$profile_file" 2>/dev/null || true)"
    if [ "$profile" = "cockpit" ]; then
      return 1
    fi
  fi

  # Marker 2: LCARS Kanban explicitly declined at setup.
  #
  # READ THE KEY, NOT THE FILE (XACA-0734-010 / XACA-0734-012).
  # ───────────────────────────────────────────────────────────
  # The first cut of this gate used
  #     grep -qE '"lcars_kanban"[[:space:]]*:[[:space:]]*false' "$config_file"
  # which is a file-WIDE substring match that has no idea what a JSON key is. It is
  # correct against today's schema and one schema change away from being silently
  # catastrophic: ANY second occurrence of that byte pattern anywhere in the file —
  # an audit-history array recording a PAST false, a per-team override block, a
  # stale key someone forgot to delete — closes the gate on a box whose LIVE key is
  # `true`.
  #
  # And it closes it in the ONE DIRECTION THIS GATE MUST NEVER FAIL IN. A
  # false-OPEN materializes an agent someone did not want: visible, annoying,
  # trivially undone with one line in the sentinel. A false-CLOSE suppresses every
  # mandatory agent — including com.aiteamforge.auto-upgrade.plist, the agent that
  # PERFORMS upgrades — while every check still reports the box healthy. That turns
  # this entire ticket into a no-op on exactly the machines it exists to fix, and
  # leaves no symptom to notice. Fail-closed here IS the original XACA-0734 bug
  # wearing a different hat.
  #
  # Note setup also emits the BARE STRING "lcars_kanban" as an element of the
  # "installed_features" ARRAY (bin/aiteamforge-setup.sh:1642, _build_installed_features)
  # in the same file. A key-scoped read cannot confuse an array element with an
  # object key; a substring match is only ever one edit away from doing exactly that.
  #
  # WHY jq: it is the house tool for reading THIS FILE — bin/aiteamforge-doctor.sh
  # (:357, :368) and bin/aiteamforge-setup.sh (:613, the upgrade-hydration path)
  # both parse .aiteamforge-config with it, and `doctor` already reports a missing
  # jq as a hard FAIL. lib/python-env.sh is deliberately NOT sourced here: nothing
  # else in this lib needs an interpreter, and taking on a python dependency to
  # implement a gate whose defining property is "fail open" is backwards.
  #
  # FAIL OPEN ON EVERY DEGRADED INPUT. This is the property that matters, and it is
  # why there is deliberately NO grep fallback when jq is unavailable. Missing file,
  # unreadable file, empty file, truncated or malformed JSON, a non-object root, a
  # missing `features` block, a missing key, or no jq on PATH at all — every one of
  # them resolves to APPLICABLE. The one and only thing that closes this gate is jq
  # successfully parsing the config and finding features.lcars_kanban === false.
  # Falling back to the grep would reinstate the false-CLOSE hazard precisely on the
  # boxes least equipped to tolerate it; a "fallback" that can fail closed is not a
  # fallback, it is the bug with a longer code path.
  local config_file="${wd}/.aiteamforge-config"
  if [ -f "$config_file" ] && [ -r "$config_file" ] && command -v jq >/dev/null 2>&1; then
    local verdict
    # jq's `and` SHORT-CIRCUITS, so `.features` is never indexed on a non-object
    # root (which would be a hard error). Any parse failure exits non-zero with an
    # empty stdout, so `verdict` is "" — which is not "declined" — and we fall
    # through to applicable. `|| true` keeps that path from tripping the caller's
    # `set -e` (install-kanban.sh runs under `set -euo pipefail`).
    verdict="$(jq -r '
        if (type == "object")
           and ((.features | type) == "object")
           and (.features.lcars_kanban == false)
        then "declined"
        else "applicable"
        end
      ' "$config_file" 2>/dev/null || true)"
    if [ "$verdict" = "declined" ]; then
      return 1
    fi
  fi

  return 0
}

# Human-readable reason the gate is closed, for user-facing messages.
# Only meaningful when _xaca0734_launchagents_applicable returned 1.
#
# ALWAYS NAMES THE WAY BACK IN (XACA-0734-013). Reporting that something is
# suppressed without saying how to un-suppress it is how a user concludes they are
# stuck. This is the same discoverability contract as _xaca0734_print_optout_hint,
# which prints the opt-OUT command at the moment an agent is about to be
# materialized; this is its mirror — the opt-IN path, printed at the moment we
# report that agents are being withheld.
#
# `aiteamforge setup` is a REAL recovery path, not a hopeful suggestion, and the
# whole marker-based design rests on it: setup's upgrade-hydration block forces
# INSTALL_KANBAN="yes" on any non-cockpit re-run and rewrites .aiteamforge-config
# with "lcars_kanban": true (and .install-profile with the chosen profile). So the
# markers this gate reads are exactly the markers setup rewrites — flipping either
# one is a supported, single-command operation. It is the reason this gate never
# has to clear anything itself. See the block comment on
# _xaca0734_launchagents_applicable above.
_xaca0734_launchagents_skip_reason() {
  local wd="${1:-}"

  if [ -z "$wd" ]; then
    wd="${WORKING_DIR:-}"
  fi
  if [ -z "$wd" ] && declare -f get_working_dir >/dev/null 2>&1; then
    wd="$(get_working_dir 2>/dev/null || true)"
  fi
  if [ -z "$wd" ]; then
    wd="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  fi

  local profile_file="${wd}/.install-profile"
  if [ -f "$profile_file" ] && [ -r "$profile_file" ]; then
    local profile
    profile="$(tr -d '[:space:]' < "$profile_file" 2>/dev/null || true)"
    if [ "$profile" = "cockpit" ]; then
      echo "cockpit profile — LCARS and kanban run on a remote host; to run them HERE, re-run: aiteamforge setup"
      return 0
    fi
  fi

  echo "LCARS Kanban was declined at setup (.aiteamforge-config: lcars_kanban=false); to opt back in, re-run: aiteamforge setup"
}

#──────────────────────────────────────────────────────────────────────────────
# Opt-out sentinel — a SUPPORTED, USER-EDITABLE FILE. This is the user-facing
# contract this ticket introduces; treat changing its format as a breaking change.
#──────────────────────────────────────────────────────────────────────────────
#
#   Location: ${HOME}/.aiteamforge/launchagents.optout
#             (override for tests via AITF_LAUNCHAGENT_OPTOUT_FILE)
#   Format:   one LaunchAgent plist BASENAME per line, e.g.:
#
#               # I run LCARS on the NAS, not here    <- whole-line comments OK
#               com.aiteamforge.lcars-health.plist
#               com.aiteamforge.auto-upgrade.plist
#
#             Blank lines and `#` comment lines are ignored. Leading/trailing
#             whitespace is trimmed, and a trailing CR (CRLF endings) is tolerated
#             — this file is meant to be edited by a human in a text editor, so it
#             is parsed the way a human would expect (XACA-0734-002).
#   Effect:   `aiteamforge upgrade` will not (re-)materialize a listed agent,
#             and `aiteamforge doctor --fix` will not render+load it either.
#
# THE SUPPORTED WAY TO DECLINE A MANDATORY AGENT IS TO ADD A LINE TO THIS FILE:
#
#     echo "com.aiteamforge.lcars-health.plist" >> ~/.aiteamforge/launchagents.optout
#
# and the supported way to reverse that is to remove the line (by hand, or
# `grep -v` it back out) and re-run `aiteamforge upgrade` or `aiteamforge doctor
# --fix`. `update_launchagents` (aiteamforge-upgrade.sh) and the `keepalive` fix
# (aiteamforge-doctor.sh) both print this exact command whenever they are about
# to materialize a missing mandatory agent — see _xaca0734_print_optout_hint
# below — so the escape hatch is always visible at the moment it becomes
# relevant, without adding a dedicated CLI subcommand for it.
#
# A MISSING SENTINEL FILE IS NORMAL and means "nothing is opted out" — that is
# the state of every existing box, which is exactly why absence-of-plist could
# never be read as intent (that was the XACA-0734 bug).
#
# LIFECYCLE — READ BEFORE WIRING UP A NEW CALLER (XACA-0734 FOLLOW-UP FINDING):
#   _xaca0734_record_optout / _xaca0734_clear_optout are called by
#   uninstall_<x>_launchagent() / install_<x>_launchagent() (install-kanban.sh)
#   respectively — but do not assume that means the sentinel is auto-managed
#   end-to-end. Two things to know:
#
#   1. The ONLY caller of the targeted uninstall_<x>_launchagent() helpers today
#      is the batch uninstall_kanban_system(), and the batch path DOES NOT RECORD
#      — the helpers go through _xaca0734_record_optout_unless_batch, which is a
#      no-op while _XACA0734_BATCH_UNINSTALL=1. So nothing in the product writes
#      this file today: HAND-EDITING IT IS THE PRIMARY (and currently the only)
#      WAY THE SENTINEL GETS POPULATED. Treat every entry in it as something a
#      human typed on purpose, and parse it as forgivingly as such (see
#      _xaca0734_normalize_optout_line). The record path is kept correct for a
#      future targeted single-agent uninstall entry point.
#      (Why the batch must not record: a Ctrl-C mid-teardown would otherwise
#      leave every mandatory agent opted out FOREVER. See BLOCKING 2 in
#      _xaca0734_record_optout_unless_batch.)
#
#   2. install_<x>_launchagent() does NOT auto-clear the opt-out on every call.
#      An earlier version of this fix had it call _xaca0734_clear_optout()
#      unconditionally — on the theory that "installing something is an
#      explicit opt back in". That was wrong: install_kanban_system() (the
#      installers' only caller) runs on EVERY `aiteamforge setup`, including
#      the explicit `reconfigure` path — not just a fresh install — and calls
#      every install_<x>_launchagent() unconditionally regardless of what the
#      user actually asked for. Auto-clearing there meant a user who opted out
#      by hand, then re-ran setup for an unrelated reason (e.g. adding a team),
#      would silently have their opt-out reversed and the agent reinstalled.
#      Each install_<x>_launchagent() now instead CHECKS the sentinel at entry
#      and refuses to install when opted out (see the guard at the top of each
#      one in install-kanban.sh) — opting back in is only ever a deliberate
#      file edit, never a side effect of running setup or upgrade for something
#      else. _xaca0734_clear_optout stays defined as a primitive for a future
#      explicit "reinstall this one agent" affordance, but nothing currently
#      calls it automatically.
_xaca0734_optout_file() {
  echo "${AITF_LAUNCHAGENT_OPTOUT_FILE:-${HOME}/.aiteamforge/launchagents.optout}"
}

# Normalize ONE sentinel line for comparison. Echoes the cleaned entry (which may
# be empty, meaning "this line carries no entry").
#
# WHY (XACA-0734-002): this file is HAND-EDITED — that is its primary population
# path, documented above. So it will, in the field, contain the things hand-edited
# files contain: a trailing \r (edited on/synced from a Windows box, or pasted
# through a tool that rewrites line endings), stray leading/trailing spaces or
# tabs, blank lines, and explanatory `#` comments. A raw [ "$line" = "$agent" ]
# test fails on EVERY one of those, and it fails SILENTLY in the worst direction:
# the entry does not match, so the agent is treated as not-opted-out and gets
# re-materialized — silently reversing an intent the user recorded by hand. That
# is precisely the silent-intent-loss class this whole ticket exists to kill, so
# the parser has to be as forgiving as a human editor is careless.
#
# Deliberately NOT stripping inline trailing comments ("agent.plist # why"):
# a plist basename cannot contain '#', but nothing in the format promises that,
# and guessing at comment syntax mid-line is how you eat a legitimate entry.
# Whole-line comments only.
_xaca0734_normalize_optout_line() {
  local line="${1:-}"

  # Strip a trailing CR first (CRLF line endings).
  line="${line%$'\r'}"
  # Strip leading whitespace (spaces + tabs).
  line="${line#"${line%%[![:space:]]*}"}"
  # Strip trailing whitespace (spaces + tabs).
  line="${line%"${line##*[![:space:]]}"}"

  printf '%s' "$line"
}

# True (exit 0) when a normalized sentinel line carries no entry: blank, or a
# whole-line `#` comment.
_xaca0734_optout_line_is_noise() {
  local norm="${1:-}"
  if [ -z "$norm" ]; then
    return 0
  fi
  case "$norm" in
    \#*) return 0 ;;
  esac
  return 1
}

# True (exit 0) when <plist-basename> has a recorded opt-out.
# Exact-entry membership test AFTER normalization — a substring match would let
# "lcars-health.plist" be shadowed by an unrelated longer entry.
_xaca0734_is_opted_out() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  # Missing sentinel == nothing opted out. This is the common case.
  if [ ! -f "$f" ]; then
    return 1
  fi

  # Unreadable sentinel: we cannot confirm an opt-out, so do not claim one.
  # Guarded explicitly because an unreadable redirect would otherwise abort the
  # caller outright under `set -e`.
  if [ ! -r "$f" ]; then
    return 1
  fi

  local line norm
  while IFS= read -r line || [ -n "$line" ]; do
    norm="$(_xaca0734_normalize_optout_line "$line")"
    if _xaca0734_optout_line_is_noise "$norm"; then
      continue
    fi
    if [ "$norm" = "$agent" ]; then
      return 0
    fi
  done < "$f"
  return 1
}

# Record an opt-out for <plist-basename>. Idempotent — never appends twice.
#
# Returns 1 (with a warning) when the sentinel cannot be written. XACA-0734-003:
# the append used to be unguarded while the mkdir above it was `|| true`'d, so
# under install-kanban.sh's `set -euo pipefail` a failed write would abort the
# ENTIRE script mid-uninstall rather than report. Callers that can tolerate a
# failed record should `|| true` it explicitly at the call site, where the
# tradeoff is visible.
_xaca0734_record_optout() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  # Already recorded — nothing to do (dedupe).
  if _xaca0734_is_opted_out "$agent"; then
    return 0
  fi

  local dir
  dir="$(dirname "$f")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    print_warning "Cannot create opt-out sentinel dir: ${dir} — opt-out for ${agent} NOT recorded"
    return 1
  fi

  if ! printf '%s\n' "$agent" >> "$f" 2>/dev/null; then
    print_warning "Cannot write opt-out sentinel: ${f} — opt-out for ${agent} NOT recorded"
    return 1
  fi
}

# Record an opt-out UNLESS we are inside a batch teardown.
#
# WHY THIS EXISTS (XACA-0734 review, BLOCKING 2) — READ BEFORE "SIMPLIFYING"
# ─────────────────────────────────────────────────────────────────────────
# A TARGETED "remove this one agent" is an opt-out: the user said they do not want
# it, and upgrade must respect that. A BATCH teardown (uninstall_kanban_system,
# which calls every uninstall_<x>_launchagent in a row) is NOT: the user said
# "remove the kanban system", which says nothing whatsoever about which agents
# they want if they ever reinstall it.
#
# The first cut recorded unconditionally and then wiped the whole sentinel at the
# END of the batch to undo it. install-kanban.sh runs under `set -euo pipefail`,
# so ANY non-zero exit — or a Ctrl-C, which is a perfectly normal thing to do to
# an uninstall you started by mistake — between the first record and the final
# wipe left the sentinel listing EVERY MANDATORY AGENT. And by this ticket's own
# (correct) design, nothing downstream ever clears it: the installers refuse to
# install an opted-out agent, and upgrade skips it. So:
#
#     uninstall  →  ^C partway through  →  sentinel = {auto-upgrade, ...}
#     reinstall  →  auto-upgrade can never be installed by ANY code path, ever
#
# That is the ORIGINAL SELF-SEALING BUG, resurrected on the uninstall→reinstall
# path — the exact failure this ticket exists to eliminate.
#
# A `trap ... EXIT INT TERM` armed before the first call would also close it, but
# it defends a write that buys nothing: the batch's own wipe means a batch-path
# record is never externally observable anyway. So do not write it at all. The
# fix that removes the hazard beats the fix that cleans up after it.
#
# The flag is set ONLY by uninstall_kanban_system, for the duration of the
# teardown. Any FUTURE targeted single-agent uninstall entry point calls this
# with the flag unset and records normally — which is the behavior we actually want.
_xaca0734_record_optout_unless_batch() {
  local agent="$1"

  if [ "${_XACA0734_BATCH_UNINSTALL:-0}" = "1" ]; then
    return 0
  fi

  _xaca0734_record_optout "$agent"
}

# Clear the opt-out for <plist-basename>. No-op when the sentinel is absent or
# the agent is not listed.
#
# NOT currently auto-invoked by install_<x>_launchagent() — see the LIFECYCLE
# note on the sentinel section above for why that would be actively harmful
# given the current call graph (install_kanban_system runs on every
# `aiteamforge setup`, including reconfigure, not just a fresh install). This
# is kept as a primitive for a future targeted single-agent "reinstall this
# one" affordance. Today, opting back in is a manual sentinel edit.
_xaca0734_clear_optout() {
  local agent="$1"
  local f
  f="$(_xaca0734_optout_file)"

  if [ ! -f "$f" ]; then
    return 0
  fi

  # XACA-0734 review #3: the old implementation was
  #     grep -v -x -F "$agent" "$f" > "$tmp" 2>/dev/null || true
  #     mv "$tmp" "$f"
  # which `mv`s UNCONDITIONALLY. grep exits 1 for "no lines selected" (normal:
  # the sentinel held only this agent) but exits 2 for a REAL error — file
  # unreadable, I/O failure. The `|| true` swallowed both identically, so an
  # unreadable sentinel produced an empty $tmp that was then moved over the
  # original: the user's entire recorded opt-out set, SILENTLY TRUNCATED to
  # nothing. Read the file explicitly and bail before touching it if we cannot.
  if [ ! -r "$f" ]; then
    print_warning "Opt-out sentinel is not readable: ${f} — leaving it untouched"
    return 1
  fi

  local tmp="${f}.tmp.$$"
  if ! : > "$tmp" 2>/dev/null; then
    print_warning "Cannot write next to the opt-out sentinel: ${tmp} — leaving it untouched"
    return 1
  fi

  # Normalized matching, so `clear` can remove an entry that `is_opted_out`
  # can SEE — a CRLF/space-padded line must be clearable, or a user could be
  # stuck opted out of an agent with no way back short of deleting the file.
  # Non-entry lines (blanks, `#` comments) are COPIED THROUGH: this file is
  # hand-maintained, and eating a user's comments is its own small betrayal.
  local line norm
  while IFS= read -r line || [ -n "$line" ]; do
    norm="$(_xaca0734_normalize_optout_line "$line")"
    if ! _xaca0734_optout_line_is_noise "$norm" && [ "$norm" = "$agent" ]; then
      continue
    fi
    if ! printf '%s\n' "$line" >> "$tmp" 2>/dev/null; then
      print_warning "Failed rewriting the opt-out sentinel — leaving ${f} untouched"
      rm -f "$tmp" 2>/dev/null || true
      return 1
    fi
  done < "$f"

  mv "$tmp" "$f"
}

# Delete the ENTIRE sentinel. Called ONLY by the full-uninstall path.
# See aiteamforge-uninstall.sh for the rationale — a populated sentinel that
# survives a full uninstall would silently suppress every mandatory agent on the
# next fresh install.
_xaca0734_clear_all_optouts() {
  local f
  f="$(_xaca0734_optout_file)"
  if [ -f "$f" ]; then
    rm -f "$f"
  fi
}

# Print the opt-out escape hatch for <plist-basename>, using the REAL resolved
# sentinel path (never a hardcoded one — respects AITF_LAUNCHAGENT_OPTOUT_FILE
# so tests see the sandboxed path too).
#
# Callers: aiteamforge-upgrade.sh's update_launchagents (when materializing a
# missing mandatory agent — the row-2 case in its decision table) and
# aiteamforge-doctor.sh's `--fix` keepalive remediation. Both call this ONLY on
# the install/materialize path, never on routine refresh — printing it on every
# refresh of an agent the user already has would be noise, and the row-3 skip
# path already reports the opt-out is being honored (no hint needed there).
# Also called under --dry-run, since a would-be install is exactly when the
# hint is useful.
_xaca0734_print_optout_hint() {
  local agent="$1"
  echo "  To permanently opt out instead:"
  echo "    echo \"${agent}\" >> $(_xaca0734_optout_file)"
}

#──────────────────────────────────────────────────────────────────────────────
# Load verification
#──────────────────────────────────────────────────────────────────────────────
# True (exit 0) when <label> is registered with launchd RIGHT NOW.
#
# `launchctl load` returns 0 even when launchd REJECTS the job, so every caller
# that cares whether an agent actually came up has to verify via `launchctl list`
# (the XACA-0651-009 load-verify pattern).
#
# XACA-0734 review #4: the callers used to do `launchctl list | grep -q "$label"`,
# which is wrong twice over:
#   * grep -q takes a REGEX, and every label is full of dots. "com.aiteamforge.
#     lcars-health" happily matches "comXaiteamforgeYlcars-health".
#   * it is a SUBSTRING match on the whole line, so the label
#     "com.aiteamforge.lcars-health" is reported as loaded by an unrelated entry
#     named "com.aiteamforge.lcars-health-check" or ".lcars-health.disabled".
# Both fail toward the SAME wrong answer — claiming an agent registered when it
# did not — which is the one answer a load-verify must never give.
#
# `launchctl list` emits "PID\tStatus\tLabel"; the label is the last field and
# labels never contain whitespace, so an exact match on $NF is precise and needs
# no regex escaping at all.
#
# The read-only `launchctl list` is intentionally NOT routed through
# _aitf_launchctl — see the wrapper's header note in lib/common.sh.
_xaca0734_launchctl_is_loaded() {
  local label="$1"
  launchctl list 2>/dev/null \
    | awk -v want="$label" '$NF == want { found = 1 } END { exit found ? 0 : 1 }'
}

#──────────────────────────────────────────────────────────────────────────────
# Disabled-service detection (XACA-1097)
#──────────────────────────────────────────────────────────────────────────────
# True (exit 0) when <label> is explicitly DISABLED in the caller's gui domain.
#
# `launchctl load`/`bootstrap` both exit 0 AND print "Load failed: 5: Input/output
# error" to stderr when the target service is disabled — a disabled service can
# never be brought up by a load call, no matter how many times it is retried.
# XACA-1097 found four sites that branched on that lying exit code and recorded a
# false PASS ("loaded (auto-fixed)") for a service `launchctl list` never actually
# shows as running. This helper lets every call site check the ACTUAL disabled
# state up front and skip the doomed load attempt entirely.
#
# `launchctl print-disabled "gui/<uid>"` emits one line per service with a known
# disabled/enabled override, shaped like (verbatim, measured on M1Pro):
#         "com.aiteamforge.kanban-backup" => disabled
#         "com.aiteamforge.lcars-health" => disabled
#         "com.aiteamforge.knowledge-sync" => disabled
# Default whitespace-split fields land as $1=label (some emitters quote it,
# some don't — normalize by stripping one leading/trailing `"` before
# comparing), $2=`=>`, $3=`disabled`/`enabled`. Comparing the normalized field
# to the raw label with `==` is an EXACT match on the whole label — never
# substring-grep the raw blob, which would false-positive across
# similarly-named labels (the same class of mistake
# `_xaca0734_launchctl_is_loaded`'s header above already documents for `list`).
#
# Returns 1 (not disabled) for: explicitly enabled, no override recorded at all
# (absent from the list — launchd's default is enabled), or launchctl/id being
# unavailable. Never prints to stdout.
_xaca1097_launchctl_is_disabled() {
  local label="$1"
  local uid
  uid="$(id -u 2>/dev/null)" || return 1
  launchctl print-disabled "gui/${uid}" 2>/dev/null \
    | awk -v want="$label" '
        {
          field = $1
          gsub(/^"|"$/, "", field)
        }
        field == want && $2 == "=>" && $3 == "disabled" { found = 1 }
        END { exit found ? 0 : 1 }
      '
}

#──────────────────────────────────────────────────────────────────────────────
# Renderer (moved here from aiteamforge-upgrade.sh by XACA-0734)
#──────────────────────────────────────────────────────────────────────────────
# Render a LaunchAgent template to a destination path.
# Applies the FULL substitution map to every template — harmless extras are what
# prevent the sibling-drift bugs described in this file's header.
# Usage: _render_launchagent_template <template_path> <dest_path>
# Returns: 0 on success, 1 if the template is not found.
#
# Resolves the aiteamforge working dir from WORKING_DIR when set (upgrade.sh sets
# it), else get_working_dir() (doctor.sh's context), else the documented default.
_render_launchagent_template() {
  local template="$1"
  local dest="$2"

  if [ ! -f "$template" ]; then
    print_warning "LaunchAgent template not found: $template"
    return 1
  fi

  local working_dir="${WORKING_DIR:-}"
  if [ -z "$working_dir" ]; then
    if declare -f get_working_dir >/dev/null 2>&1; then
      working_dir="$(get_working_dir)"
    else
      working_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    fi
  fi

  local kanban_backup_interval="${KANBAN_BACKUP_INTERVAL:-${KANBAN_BACKUP_INTERVAL_DEFAULT:-900}}"

  local python3_path
  # NOTE: PYTHON3_PATH is re-resolved on every render — PATH changes between
  # install and upgrade will silently re-pin the plist interpreter. See XACA-0510.
  python3_path="$(command -v python3 2>/dev/null || echo "/usr/bin/python3")"

  # XACA-0571: resolve aiteamforge binary for the LCARS watch plist.
  local aiteamforge_bin
  aiteamforge_bin="$(command -v aiteamforge 2>/dev/null || echo "/opt/homebrew/bin/aiteamforge")"

  # XACA-0578: resolve Homebrew prefix for cellar-watch plist ({{BREW_CELLAR_DIR}}).
  local brew_prefix
  brew_prefix="$(command -v brew &>/dev/null && brew --prefix 2>/dev/null || echo "/opt/homebrew")"

  sed -e "s|{{USER_HOME}}|$HOME|g" \
      -e "s|{{HOME_DIR}}|$HOME|g" \
      -e "s|{{AITEAMFORGE_DIR}}|${working_dir}|g" \
      -e "s|{{BACKUP_INTERVAL}}|${kanban_backup_interval}|g" \
      -e "s|{{PYTHON3_PATH}}|${python3_path}|g" \
      -e "s|{{AUTO_UPGRADE_SCRIPT}}|${working_dir}/scripts/auto-upgrade.sh|g" \
      -e "s|{{LOG_DIR}}|${working_dir}/logs|g" \
      -e "s|{{LCARS_UI_DIR}}|${working_dir}/lcars-ui|g" \
      -e "s|{{AITEAMFORGE_BIN}}|${aiteamforge_bin}|g" \
      -e "s|{{CELLAR_WATCH_TRIGGER}}|${working_dir}/scripts/cellar-watch-trigger.sh|g" \
      -e "s|{{BREW_CELLAR_DIR}}|${brew_prefix}/Cellar/aiteamforge|g" \
      "$template" > "$dest"
}

# Render + load a single mandatory LaunchAgent from its template.
# Used by `aiteamforge doctor --fix` as the backstop when a mandatory plist is
# missing entirely (upgrade is the primary path; doctor catches boxes that have
# not upgraded yet).
#
# Usage: _xaca0734_render_and_load_launchagent <agent> <framework_dir> [<launchagents_dir>]
# Returns 0 when the agent is rendered AND registered with launchd; 1 otherwise.
# Callers distinguish "render failed" from "rendered but did not register" by
# testing for the plist on disk afterward.
#
# `launchctl load` returns 0 even when the job is REJECTED, so registration is
# verified via `launchctl list` (the XACA-0651-009 load-verify pattern). The
# read-only `launchctl list` is intentionally NOT routed through _aitf_launchctl
# — see the wrapper's header note in lib/common.sh.
_xaca0734_render_and_load_launchagent() {
  local agent="$1"
  local framework_dir="$2"
  local launchagents_dir="${3:-${LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}}"

  local subpath
  if ! subpath="$(_xaca0734_launchagent_template_for "$agent")"; then
    print_warning "Unknown LaunchAgent (not in the XACA-0734 map): ${agent}"
    return 1
  fi

  local template="${framework_dir}/share/templates/${subpath}"
  local dest="${launchagents_dir}/${agent}"

  mkdir -p "$launchagents_dir" 2>/dev/null || true

  if ! _render_launchagent_template "$template" "$dest"; then
    return 1
  fi

  _aitf_launchctl unload "$dest" 2>/dev/null || true
  _aitf_launchctl load "$dest" 2>/dev/null || true

  local label="${agent%.plist}"
  if _xaca0734_launchctl_is_loaded "$label"; then
    return 0
  fi
  return 1
}
