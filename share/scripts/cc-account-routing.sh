#!/usr/bin/env zsh
# cc-account-routing.sh
#
# XACA-1312 PR 1: credential-routing core, extracted verbatim (pure move, no
# behavior change) from claude_code_cc_aliases.sh's
# _cc_export_account_credentials / _cc_resolve_credential_for_team /
# _cc_run_claude_with_auth and their nested-function dependency closure
# (_cc_write_mode_signal, _cc_machine_slug, _cc_vault_keypair_exists,
# _cc_is_vault_slug, _cc_resolve_emit). See
# kanban/plans/XACA-1312/XACA-1312_001_routing_design.md §1 for the ship
# vector decision and rationale (canonical-source rule, XACA-0340; the
# K501 sibling-heuristic-drift class this avoids).
#
# This file is sourced by:
#   - dev `claude_code_cc_aliases.sh` (this repo), from the repo root, and
#   - (PR 2, not yet wired) the tap-native `cc-aliases.sh` template, from
#     $AITEAMFORGE_DIR/scripts/ on a consumer install.
#
# ZSH ONLY. Measured 45 zsh-specific constructs in the moved body (print
# -u2, ${(P)...}, ${(@f)...}, setopt LOCAL_OPTIONS/local_traps, emulate -L
# zsh, ${(%):-%x}). A bash port would be a second implementation of
# security-sensitive, exit-code-classified logic -- the exact drift this
# extraction exists to avoid. The guard line below is written in POSIX sh so
# it parses (and fails clean, not with a syntax error) under /bin/bash 3.2.
if [ -z "${ZSH_VERSION:-}" ]; then
    echo "cc-account-routing.sh: requires zsh" >&2
    return 1 2>/dev/null || exit 1
fi

# XACA-1312-025 (bot review, PR #957, finding 025): clear the completeness
# sentinel at the TOP of the file, before any function definitions. Without
# this, re-sourcing a truncated/interrupted copy of this file in a shell
# that had PREVIOUSLY sourced a complete core leaves the old
# _CC_ROUTING_CORE_COMPLETE=1 (and the old function bodies) sitting in
# scope: the truncated source only ever ADDS/overwrites definitions, it
# never unsets what a prior complete load already set, so
# _cc_routing_core_complete would wrongly report "complete" against
# stale/mixed function bodies. Clearing it here means a truncated re-source
# always fails closed regardless of what was loaded before it.
typeset -g _CC_ROUTING_CORE_COMPLETE=0

# Self-location, captured ONCE at source time (not re-derived per call --
# see the XACA-1312 comment ahead of _vault_fetch's assignment below for why
# a per-call ${(%):-%x} inside a function is NOT equivalent to this). This
# is the directory containing THIS file, resolved to an absolute, symlink-
# free path.
#
# Dependents (vault-fetch.sh, vault-keygen.js) are resolved from this
# directory via an ordered candidate list at their use sites, not here --
# see §1.2 of the design doc. Do not assume a fixed relationship between
# this directory and the repo root; the candidate lists are what encode
# that, and they differ between the dev and (future) consumer layouts.
typeset -g _CC_ROUTING_CORE_DIR="${${(%):-%x}:A:h}"

# XACA-1313: shared resolver that turns a bare "freelance" team identity
# into the REGISTERED freelance-<client>-<project> instance a credential
# actually lives under. Every freelance startup script hardcodes
# SESSION_TYPE="freelance", but LCARS Settings saves ai.credential under the
# instance slug — so the raw team value below would otherwise never match
# anything and every freelance session would silently launch on default
# OAuth (known since XACA-1184-002; see freelance-banner.sh). The
# implementation lives in its own file, NOT inlined here, because two of
# the other three call sites (cc-whoami.sh, session-account-map-record.sh)
# must not pay for sourcing this whole 1200+ line routing core just to
# reach one function — one implementation, several sourcing sites, per
# scripts/cc-credential-team-resolver.sh's own header.
#
# Probe order: _CC_ROUTING_CORE_DIR (this file's own directory) FIRST. Both
# layouts put the resolver right beside this file -- dev `scripts/`,
# consumer `$AITEAMFORGE_DIR/scripts/` -- so a consumer copy finds its
# sibling without depending on $AITEAMFORGE_DIR being correctly exported at
# source time. The AITEAMFORGE_DIR/dev-team/aiteamforge 3-way list is kept
# only as a fallback for a layout that ever splits the two files apart.
if ! command -v _cc_credential_team >/dev/null 2>&1; then
    for _cc_ctr_f in \
        "${_CC_ROUTING_CORE_DIR}/cc-credential-team-resolver.sh" \
        ${AITEAMFORGE_DIR:+"${AITEAMFORGE_DIR}/scripts/cc-credential-team-resolver.sh"} \
        "${HOME}/dev-team/scripts/cc-credential-team-resolver.sh" \
        "${HOME}/aiteamforge/scripts/cc-credential-team-resolver.sh"; do
        if [[ -n "$_cc_ctr_f" && -f "$_cc_ctr_f" ]]; then
            source "$_cc_ctr_f"
            break
        fi
    done
    unset _cc_ctr_f
fi

# Resolve the Anthropic account credentials for the current team using a tiered
# source chain (vault → sealed cache → env-var). Reads team identity from
# SESSION_TYPE / LCARS_TEAM / KB_TEAM (priority order), then looks up the team
# entry in ~/.aiteamforge/team-paths.json.
#
# Resolution chain (XACA-0539-001, XACA-0539-003):
#   Tier 1 — Vault:        vault-fetch.sh anthropic <team-slug>
#   Tier 2 — Stale cache:  offline cache file read (bypasses TTL) when server
#                           is unreachable (exit 4)
#   Tier 3 — Env-var:      ${(P)env_var_name} from team-paths.json (legacy path)
#
# Sets _CC_RESOLVED_TOKEN and _CC_RESOLVED_AUTH_TYPE (local to the caller's
# scope via nameref-friendly assignment) and exports CLAUDE_ACTIVE_ACCOUNT_ID /
# CLAUDE_ACTIVE_ACCOUNT_NICKNAME. The token itself is NEVER exported to the
# interactive shell — only passed into the claude subshell via
# _cc_run_claude_with_auth (XACA-0977-011).
#
# Also writes ~/.aiteamforge/secret-source-mode/<team>.json with the resolution
# mode (vault|cache|env-failover|env-legacy) for LCARS display. Never writes the
# token there.
#
# XACA-0972-004 — why the "no key anywhere" path writes NO mode signal:
# every one of the four documented modes asserts "a token was resolved from
# tier X"; the field's meaning is WHICH TIER WON, not what happened. There is
# no token on that path, so any value would be a lie in the field's own terms,
# and LCARS renders the value verbatim as "🔐 Account: <nick> [<mode>]" — an
# unknown fifth value would surface as a badge claiming a credential source
# that does not exist. The signal's ABSENCE is also load-bearing diagnostic
# evidence: this directory is created on every successful resolution, so a
# missing ~/.aiteamforge/secret-source-mode/ is the proof that resolution has
# never once succeeded on a machine. That is exactly how XACA-0972 was
# diagnosed. Writing a signal here would destroy that forensic property while
# adding nothing the loud stderr warning does not already say. Do not "fix"
# this by adding a fifth mode without also teaching every LCARS consumer.
#
# Return values:
#   0 — SAFE TO LAUNCH. Either a token resolved (caller reads
#       $_CC_RESOLVED_TOKEN), or this team legitimately has no key anywhere and
#       the caller should launch on default Anthropic OAuth (an empty
#       $_CC_RESOLVED_TOKEN). Both cases announce themselves on stderr.
#   1 — FAIL CLOSED. A credential source that SHOULD have answered could not be
#       reached (vault-configured machine, vault unreachable, no usable
#       fallback). Do NOT launch — an outage must never silently downgrade the
#       session to the wrong account.
#
# Caller MUST declare: local _CC_RESOLVED_TOKEN="" and
# local _CC_RESOLVED_AUTH_TYPE="" before calling this function.
# Caller MUST check return code.
#
# Called from _cc_launch — inherits all cc-* personas automatically.
_cc_export_account_credentials() {
    # XACA-0977-021: the field-splitting below indexes an array literally
    # (_cc_team_fields[1]..[7]). Under `setopt KSH_ARRAYS` (ksh/sh emulation:
    # arrays become 0-indexed and `${#arr}` stops meaning "element count" --
    # verified directly) every one of those literal indices is off by one,
    # silently misreading account_id/nickname/env_var_name/auth_type/
    # engine_slug/sentinel. The old %%/# string split this replaced (XACA-
    # 0977-012/017) was immune because it never indexed an array. `LOCAL_
    # OPTIONS` scopes the option change to this function call ONLY -- the
    # caller's global KSH_ARRAYS setting (if any) is restored on return, so
    # this cannot leak into or depend on the sourcing shell's option state.
    setopt LOCAL_OPTIONS NO_KSH_ARRAYS

    # --- XACA-1312 §3.2/§3.3: central fail-closed handler --------------------
    # A credential source that SHOULD have answered but could not (malformed
    # declaration, unreadable config, non-anthropic engine, vault/env
    # exhausted for a DECLARED route) refuses by printing exactly one
    # "✗ ..." line and returning 1 — the contract _cc_resolve_credential_
    # for_team's parser already depends on (that single "✗ " prefix, see
    # this function's own top-of-file docstring). AITEAMFORGE_ALLOW_
    # DEFAULT_OAUTH=1 (the per-launch escape hatch, §3.3) downgrades every
    # refusal here to default OAuth instead, with an UNSUPPRESSIBLE warning
    # naming the truth: this session bills the machine login, not the
    # declared team account — never silently. Defined first, before any
    # return path below, so every refusal site (including ones that fire
    # before $nickname is ever assigned) can use it. $team is in scope by
    # the time any caller matters; $nickname may still be unset this early
    # — the ${nickname:-...} fallback covers that.
    _cc_fail_closed() {
        local _msg="$1"
        if [[ "${AITEAMFORGE_ALLOW_DEFAULT_OAUTH:-0}" == "1" ]]; then
            print -u2 "⚠ AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 — team '${team}' declared ${nickname:-a credential} but this session bills the MACHINE LOGIN"
            return 0
        fi
        print -u2 -r -- "✗ ${_msg}"
        return 1
    }

    # --- XACA-1312 D2.2: scoped ~/.zshrc.secrets lookup -----------------------
    # Non-interactive / launchd-descended shells never source ~/.zshrc (and
    # so never see an env-var only ever exported from ~/.zshrc.secrets),
    # which is exactly the shape a headless kb-run-* gate launch has on a
    # consumer box. Without this, the new fail-closed tier-3 rule (§3.2)
    # would refuse every such launch on a non-vault machine. Reads ONLY the
    # ONE named variable, in a subshell, so no other secret in the file
    # ever reaches the calling shell's environment — mirrors the exact
    # 0600-enforcement idiom _cc_resolve_credential_for_team already uses
    # for the same file (self-heal an over-permissive mode to 0600; refuse
    # to source, silently, if it cannot be tightened — this is a read path
    # with no operator interaction to report the chmod failure to beyond
    # the one warning line).
    _cc_secrets_file_lookup() {
        local _name="$1"
        # XACA-1312 fix round 1 (bot review, PR #957): defense in depth —
        # this function's own ${(P)_name} below is the second indirection
        # sink (see the caller-side validation ahead of this function's
        # only current call site, a few lines below in this file, for the
        # full rationale and the proof-of-exploit this guards against). A
        # future call site that forwards an unvalidated name must not
        # silently reintroduce the same hole.
        if [[ ! "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            print -u2 "⚠ _cc_secrets_file_lookup: '${_name}' is not a valid shell identifier — refusing to look it up"
            return 0
        fi
        local _f="${HOME}/.zshrc.secrets"
        [[ -f "$_f" ]] || return 0
        local _enforce_msg
        _enforce_msg=$(KB_CC_SF="$_f" python3 -c "
import os, stat, sys
p = os.environ['KB_CC_SF']
try:
    st = os.stat(p)
except OSError as exc:
    print(f'could not stat: {exc}', file=sys.stderr)
    sys.exit(0)
mode = stat.S_IMODE(st.st_mode)
if mode & 0o077:
    try:
        os.chmod(p, 0o600)
        print(f'tightened mode from 0{mode:o} to 0600', file=sys.stderr)
    except OSError as exc:
        print(f'unsafe mode 0{mode:o} could not be tightened to 0600 ({exc})', file=sys.stderr)
        sys.exit(1)
" 2>&1)
        local _enforce_rc=$?
        [[ -n "$_enforce_msg" ]] && print -u2 -r -- "⚠ ${_f}: ${_enforce_msg}"
        [[ "$_enforce_rc" -eq 0 ]] || return 0
        ( source "$_f" >/dev/null 2>&1; print -r -- "${(P)_name}" ) 2>/dev/null
    }

    # --- 1. Resolve team identity ----------------------------------------
    local team="${SESSION_TYPE:-}"
    [[ -z "$team" ]] && team="${LCARS_TEAM:-}"
    [[ -z "$team" ]] && team="${KB_TEAM:-}"
    if [[ -z "$team" ]]; then
        print -u2 "⚠ No team context — using default Anthropic OAuth"
        return 0
    fi

    # XACA-1313: resolve a bare "freelance" identity to its registered
    # instance slug (freelance-<client>-<project>) before anything below
    # uses it as a team-paths.json key. No-op for every other team,
    # including one that is already an instance slug. The slug-safety gate
    # immediately below still applies to WHATEVER this prints — defense in
    # depth, since the resolver's own candidates (tmux session name,
    # .kb-team sentinel contents) are just as operator-controlled as
    # SESSION_TYPE/LCARS_TEAM/KB_TEAM.
    if command -v _cc_credential_team >/dev/null 2>&1; then
        team="$(_cc_credential_team "$team")"
    fi

    # Validate team is a safe slug before it is used as a vault account_slug,
    # interpolated into file paths, or passed to subprocesses (XACA-0539-011).
    # Allowed: leading alphanumeric, then [A-Za-z0-9_-]. Anything else (quotes,
    # spaces, $, ;, newlines, path separators) is rejected — closes the
    # shell/command-injection surface from operator-controlled SESSION_TYPE /
    # LCARS_TEAM / KB_TEAM env vars.
    if [[ -n "${team//[A-Za-z0-9_-]/}" || "$team" != [A-Za-z0-9]* ]]; then
        print -u2 "⚠ Team identity '${team}' is not a valid slug — using default Anthropic OAuth"
        return 0
    fi

    # --- 2. Read team-paths.json -----------------------------------------
    local team_json="${HOME}/.aiteamforge/team-paths.json"
    if [[ ! -f "$team_json" ]]; then
        # XACA-1312 §3.2: no config file at all means there is no
        # declaration to honor OR fail on — default, but say so (dim, once
        # per launch) rather than the pre-1312 total silence, so an
        # operator can tell "undeclared" apart from "declared and
        # unreadable" (the latter now refuses — see the python-subprocess
        # guards below).
        print -u2 $'\e[2m'"ℹ No ${team_json} — using default Anthropic OAuth"$'\e[0m'
        return 0
    fi

    # Pass team + path to python3 via the environment, NOT via string
    # interpolation into the -c program (XACA-0539-011 defense-in-depth: even
    # though $team is slug-validated above, env passing keeps the program text
    # static and injection-proof regardless of future call sites).
    local team_data
    team_data=$(KB_CC_TEAM="$team" KB_CC_JSON="$team_json" python3 -c "
import json, os

def _sanitize(v):
    # account_id and nickname are unbounded free text (XACA-0282-012 S1.2,
    # up to 200 chars of anything an operator types into a config editor).
    # A literal CR/LF inside one of those values would forge a fake field
    # boundary in the newline-delimited transport below (XACA-0977-012/017)
    # -- collapse both to a single space so no value, whatever it contains,
    # can ever inject one. This must run BEFORE the join, not after the
    # shell splits: once a bogus boundary exists, splitting cannot undo it.
    #
    # XACA-0977 BLOCKING A: must be TOTAL over every JSON scalar type, not
    # just str/None. A config value that is an int/float/bool (a numeric
    # account_id, say) used to hit '(v or '').replace(...)' -- 'or' short-
    # circuits a non-empty non-string through untouched, so .replace() then
    # raised AttributeError. That exception was swallowed by the outer
    # except-pass below, which means NO output at all, which the shell side
    # (mis)read as 'python3 absent / JSON malformed' -- silently discarding
    # a value that would have resolved under the pre-XACA-0977-012 '|'.join
    # transport (str()-coerced implicitly by print(..., sep='|')). Verified
    # by raising this directly. A dict/list, in contrast, IS malformed
    # config for a field that must be a scalar -- deliberately re-raise so
    # it lands in the same 'no output produced' bucket as a JSON parse
    # failure, never silently coerced to an empty field.
    if isinstance(v, (dict, list)):
        raise ValueError('credential field is an object/array, not a scalar')
    if v is None:
        v = ''
    elif not isinstance(v, str):
        v = str(v)
    return v.replace(chr(13), ' ').replace(chr(10), ' ')

try:
    cfg = json.load(open(os.environ['KB_CC_JSON']))
    t = cfg.get('teams', {}).get(os.environ['KB_CC_TEAM'], {})
    # XACA-0282-012 shape (I5). ai.credential is an object -> use it.
    # ABSENT (key not present in ai, or ai itself absent) and null (declared
    # 'no team credential') BOTH -> empty fields. XACA-1184-002 removed the
    # legacy anthropic_account_id/_nickname/_api_key_env_var fallback that
    # used to distinguish them: the retired trio is promoted into
    # ai.credential by load_config()'s one-time on-disk lift, and a reader
    # that still consulted the trio made that lift unobservable and blocked
    # XACA-1184-009's deletion of the keys from disk. The absent-vs-null
    # distinction is still load-bearing, but on the WRITER side only -- the
    # lift gates on '\"credential\" in ai' so it never overwrites a recorded
    # 'null' decision. For a READER both states mean the same thing: no team
    # credential, fall through to the tiers below. (The sibling half of this
    # subitem, ccusage_collector.py, collapses them identically.)
    # XACA-0977-027 (round 4): plain .get(key, '') -- NEVER '.get(key) or
    # ''' -- so the default fires ONLY when the key is truly ABSENT, never
    # when it is present but falsy (0, False, 0.0, {}, [], ''). _sanitize()
    # above already documents itself as TOTAL over every JSON scalar type
    # and deliberately re-raises on dict/list, but 'x or default' short-
    # circuits BEFORE _sanitize ever runs: an empty dict/list is falsy, so
    # 'cred.get(\"account_id\") or \"\"' silently became '' without ever
    # calling _sanitize({}) -- the re-raise this field exists to guarantee
    # never fired for exactly the malformed-empty-object/array shape it was
    # written to catch. The same short-circuit also discarded a legitimate
    # scalar-but-falsy value (e.g. numeric account_id 0, or auth_type set
    # to JSON false) as if the field were unconfigured, rather than letting
    # _sanitize() coerce it to "0"/"False" per its own documented contract.
    # '.get(key, \"\")' restores totality: every present value, falsy or
    # not, reaches _sanitize() and is judged there -- the one and only
    # place that decision is made.
    ai_block = t.get('ai')
    if isinstance(ai_block, dict) and 'credential' in ai_block:
        cred = ai_block['credential']
        # XACA-1312 cred_state: distinguish a DECLARED route (object, maybe
        # {}) from a recorded 'no credential' decision (null) from a
        # malformed value (present but neither) -- collapsing all three to
        # the same empty fields (the pre-XACA-1312 shape) cannot tell
        # 'nothing to honor' apart from 'an operator declared a route that
        # cannot be resolved', which is exactly the distinction the shell
        # side's fail-closed behavior needs (design doc §3.1).
        if cred is None:
            cred_state = 'null'
            cred = {}
        elif isinstance(cred, dict):
            cred_state = 'object'
        else:
            cred_state = 'invalid'
            cred = {}
        account_id = cred.get('account_id', '')
        nickname = cred.get('nickname', '')
        env_var_name = cred.get('env_var_name', '')
        auth_type = cred.get('auth_type', '')
        engine_slug = cred.get('engine_slug', '')
        # XACA-1184-005: the vault account namespace. vault-fetch.sh takes
        # <engine_slug> <account_slug>, and Fleet Monitor's UI seals under
        # <engine_slug>/<account_slug> while vault-migrate-env-keys.js seals
        # under anthropic/<team>. Reading only the latter is why the launcher
        # could not see anything the UI sealed (XACA-0282-012 §7 Q3).
        account_slug = cred.get('account_slug', '')
    else:
        # ABSENT credential. This arm MUST assign every name the join below
        # reads -- all SEVEN now (XACA-1312 added cred_state alongside the
        # six from XACA-1184-005). Deleting the arm rather than emptying it
        # is a known silent fail-open (XACA-0977 BLOCKING A): an unassigned
        # name raises NameError at the print, the bare 'except Exception:
        # pass' below swallows it, python emits NOTHING, and the shell's
        # '[[ -z \"\$team_data\" ]]' guard -- which now REFUSES rather than
        # defaulting (XACA-1312 §3.2: a declaration may exist and cannot be
        # read) -- would wrongly refuse every genuinely-undeclared team.
        # Seven empty/absent fields plus the 'OK' sentinel is instead a
        # SUCCESSFUL read of 'nothing declared', which is exactly the
        # existing credential-null path and is handled correctly downstream.
        #
        # An un-lifted team is NOT cut off from vault: tier 1 keys on the team
        # slug, not on env_var_name, so it still runs. Only tier 3 (the
        # env-var failover, which needs env_var_name) goes dead for such a
        # team -- intended under XACA-1184 (vault-only until lifted), and
        # recorded here so it is not rediscovered as a bug later. The 26
        # un-lifted teams' env_var_name values were backfill-invented
        # TEAM_<SLUG>_API_KEY placeholders with no value behind them
        # (XACA-0282-012 F2), so nothing resolvable is lost.
        cred_state = 'absent'
        account_id = ''
        nickname = ''
        env_var_name = ''
        auth_type = ''
        engine_slug = ''
        account_slug = ''
    # Newline-delimited, NOT '|'-delimited (XACA-0977-012/017 fix): '|' is
    # ordinary free text in nickname/account_id, and a value containing one
    # (e.g. nickname 'Darren | Max') previously shifted the fixed %%/#
    # split -- env_var_name landed in auth_type's slot, engine_slug became
    # '|', and the engine guard then fired on that bogus non-'anthropic'
    # slug and silently dropped a token that HAD resolved (a billing
    # downgrade to default OAuth). Every field is sanitized above so a
    # newline can never occur INSIDE a value -- it only ever appears as the
    # boundary '\n'.join() inserts between fields, so the shell-side split
    # below always sees exactly 7 data elements plus the sentinel (XACA-1312
    # added cred_state as the 7th).
    #
    # XACA-0977 BLOCKING A: a trailing sentinel ('OK') is appended so the
    # shell side can tell 'ran successfully and every field is legitimately
    # empty' apart from 'produced no output at all'. Seven empty fields alone
    # join to a string of pure newlines, and \$(...) strips ALL trailing
    # newlines -- so that payload collapses to the exact same '' the shell
    # sees when this whole try/except raised before ever printing (python3
    # absent, JSON malformed, an unsupported credential shape). XACA-1312:
    # that collapse now means REFUSE, not default -- see the shell-side
    # comment at the '[[ -z \"\$team_data\" ]]' guard below. cred_state is
    # what lets the shell side tell 'genuinely absent/null' (default) apart
    # from 'present but the wrong shape' (invalid -> refuse) without
    # repeating this classification a second time. The sentinel is a
    # non-empty tail element, so at least one non-newline byte always
    # survives trailing-newline stripping when (and only when) this print
    # actually ran.
    fields = [_sanitize(v) for v in
              (account_id, nickname, env_var_name, auth_type, engine_slug,
               account_slug, cred_state)]
    print('\n'.join(fields + ['OK']))
except Exception:
    pass
" 2>/dev/null) || {
        # XACA-1312 §3.2: python3 crashed/missing outright (nonzero exit from
        # the subprocess itself, distinct from the in-band 'no output'
        # case below). The file EXISTS (checked above) so a declaration may
        # be sitting in it unread -- refuse rather than silently default.
        _cc_fail_closed "Cannot read ${team_json} for team '${team}' — python3 is unavailable or crashed. Fix python3, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
        return $?
    }

    if [[ -z "$team_data" ]]; then
        # python3 ran but produced no output: the try/except above swallowed
        # an exception before the sentinel could print (malformed JSON, an
        # unsupported credential field shape via _sanitize's re-raise, ...).
        # XACA-1312 §3.2: the file EXISTS, so this is "unreadable", not
        # "nothing declared" -- refuse (was: silently default, pre-1312).
        _cc_fail_closed "Cannot read ${team_json} for team '${team}' — JSON malformed or unreadable. Fix the file, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
        return $?
    fi

    # Eight newline-separated fields (XACA-0282-012 §2.5, transport fixed by
    # XACA-0977-012/017, sentinel added by XACA-0977 BLOCKING A, cred_state
    # added by XACA-1312 §3.1): account_id / nickname / env_var_name /
    # auth_type / engine_slug / account_slug / cred_state / 'OK'.
    # ${(@f)...} splits on the newlines python inserted between already-
    # sanitized fields, so a delimiter collision is structurally impossible
    # rather than merely unlikely.
    #
    # The trailing 'OK' is what distinguishes "ran to completion with seven
    # legitimately-empty fields" from "produced no output at all" -- see the
    # python-side comment above. A short array or a corrupted/missing
    # sentinel means the payload never completed (truncated, or some other
    # future failure mode) -- XACA-1312: treat that as REFUSE (a
    # declaration may exist and this read cannot be trusted), never as "no
    # data produced = default".
    local -a _cc_team_fields
    _cc_team_fields=("${(@f)team_data}")
    if [[ "${#_cc_team_fields[@]}" -ne 8 || "${_cc_team_fields[8]}" != "OK" ]]; then
        _cc_fail_closed "Cannot read ${team_json} for team '${team}' — truncated response from python3. Set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login if this persists."
        return $?
    fi
    local account_id="${_cc_team_fields[1]:-}"
    local nickname="${_cc_team_fields[2]:-}"
    local env_var_name="${_cc_team_fields[3]:-}"
    local auth_type="${_cc_team_fields[4]:-}"
    local engine_slug="${_cc_team_fields[5]:-}"
    local account_slug="${_cc_team_fields[6]:-}"
    local cred_state="${_cc_team_fields[7]:-}"

    # XACA-1312 §3.2: a PRESENT-BUT-MALFORMED declaration (ai.credential is
    # neither an object nor null — e.g. a bare string) refuses outright,
    # before any metadata is exported and before the engine guard or any
    # vault/env tier runs. There is no reasonable route to attempt.
    if [[ "$cred_state" == "invalid" ]]; then
        _cc_fail_closed "Team '${team}'s ai.credential is malformed (present but not an object or null) — cannot resolve a route. Fix teams.${team}.ai.credential in ${team_json}."
        return $?
    fi

    # Export non-secret account metadata now — these are safe for the interactive
    # shell and are read by statusline/LCARS regardless of which token tier wins.
    export CLAUDE_ACTIVE_ACCOUNT_ID="$account_id"
    export CLAUDE_ACTIVE_ACCOUNT_NICKNAME="$nickname"

    # Expose the resolved auth_type to the caller (XACA-0977-011). Caller must
    # declare `local _CC_RESOLVED_AUTH_TYPE=""` before calling, mirroring the
    # existing _CC_RESOLVED_TOKEN contract. Empty string (absent auth_type —
    # the universal case today, M3: 0 of 27 teams carry an `ai` block) is
    # meaningful: the type→variable helper (_cc_run_claude_with_auth) treats
    # it as "default", i.e. ANTHROPIC_AUTH_TOKEN (XACA-0977 D7 Part 1).
    _CC_RESOLVED_AUTH_TYPE="$auth_type"

    # --- Engine guard (XACA-0282-012 §2.5) ----------------------------------
    # Every tier below (vault, cache, env-var) is Anthropic-specific — the
    # vault fetch a few lines down resolves to the "anthropic" secret
    # store path. A non-empty engine_slug that isn't "anthropic" names a
    # credential for a different provider; injecting it into claude would be
    # silently wrong (a future gateway/OpenAI key reaching claude as an
    # Anthropic token). Print one line and let claude use its own login.
    # XACA-0283's dispatcher replaces this guard.
    if [[ -n "$engine_slug" && "$engine_slug" != "anthropic" ]]; then
        # XACA-1312 §3.2: only cred_state=object can ever produce a non-empty
        # engine_slug here (absent/null both force every credential field to
        # ''), so this is by construction a DECLARED, non-anthropic route —
        # refuse rather than silently fall back to claude's own login.
        _cc_fail_closed "Team '${team}' ai.credential targets engine '${engine_slug}', not 'anthropic' — claude cannot use it. Route this team to an anthropic credential, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
        return $?
    fi

    # --- Helper: write launcher mode signal for LCARS (XACA-0539-003) -------
    # Writes ~/.aiteamforge/secret-source-mode/<team>.json.
    # mode values: vault | cache | env-failover | env-legacy
    # NEVER writes the token. Safe to call from any tier.
    _cc_write_mode_signal() {
        local _mode="$1"
        local _signal_dir="${HOME}/.aiteamforge/secret-source-mode"
        mkdir -p "$_signal_dir" 2>/dev/null || return 0
        local _ts
        _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
        # Build the JSON with python3's json encoder so team/nickname values are
        # properly escaped (XACA-0539-012). A printf/sprintf template breaks if a
        # nickname contains a quote or backslash, producing malformed JSON that
        # LCARS consumers can't parse. ($team is slug-validated, so the filename
        # is safe; nickname is the realistic source of stray quotes.)
        KB_CC_TEAM="$team" KB_CC_MODE="$_mode" KB_CC_NICK="$nickname" KB_CC_TS="$_ts" \
            python3 -c "
import json, os
rec = {
    'team': os.environ.get('KB_CC_TEAM', ''),
    'mode': os.environ.get('KB_CC_MODE', ''),
    'account_nickname': os.environ.get('KB_CC_NICK', ''),
    'at': os.environ.get('KB_CC_TS', ''),
}
print(json.dumps(rec))
" > "${_signal_dir}/${team}.json" 2>/dev/null || true
    }

    # --- 3. Tier 1 — Vault fetch -----------------------------------------
    # XACA-1312: this used to re-derive "this script's directory" on every
    # call via ${(%):-%x}, which was correct ONLY because the function was
    # defined directly in the top-level sourced file. ${(%):-%x} inside a
    # zsh function reports the file the function was DEFINED in, not the
    # file that called it -- measured directly (a function sourced from
    # libdir/lib.sh and invoked from a caller in a different directory still
    # reports libdir, never the caller's directory). Moving these functions
    # into scripts/cc-account-routing.sh would silently repoint every
    # relative lookup at scripts/ instead of the repo root.
    #
    # Fix: _CC_ROUTING_CORE_DIR is captured ONCE, at SOURCE time, at the top
    # of cc-account-routing.sh (this file), and reused here. Candidate order
    # covers both known layouts without editing this code when a new one
    # ships:
    #   1. CC_ROUTING_VAULT_FETCH — test-only path override, HONORED ONLY
    #      when CC_ROUTING_TEST_MODE=1 is ALSO set (XACA-1312-012). Gating
    #      on a second, explicit marker closes the risk of a stray
    #      CC_ROUTING_VAULT_FETCH left set in a real operator's shell (a
    #      copy-pasted test snippet, a forgotten export) silently
    #      redirecting a PRODUCTION launch's vault fetch to an arbitrary
    #      path -- the marker is what makes "this is a test" an explicit,
    #      two-variable decision rather than inferred from one variable's
    #      mere presence. Prints one stderr notice when it fires, so an
    #      accidental hit in a real shell is visible rather than silently
    #      changing behavior.
    #   2. "$_CC_ROUTING_CORE_DIR/../fleet-monitor/client/vault-fetch.sh" —
    #      dev layout (this file lives in <repo-root>/scripts/).
    #   3. "$_CC_ROUTING_CORE_DIR/vault-fetch.sh" — flattened consumer
    #      layout (XACA-1312: vault-fetch.sh/.js now ship here, U1).
    local _vault_fetch=""
    if [[ -n "${CC_ROUTING_VAULT_FETCH:-}" && "${CC_ROUTING_TEST_MODE:-0}" == "1" ]]; then
        _vault_fetch="$CC_ROUTING_VAULT_FETCH"
        print -u2 "ℹ CC_ROUTING_TEST_MODE=1 — vault-fetch path overridden via CC_ROUTING_VAULT_FETCH=${_vault_fetch}"
    elif [[ -e "${_CC_ROUTING_CORE_DIR}/../fleet-monitor/client/vault-fetch.sh" ]]; then
        _vault_fetch="${_CC_ROUTING_CORE_DIR}/../fleet-monitor/client/vault-fetch.sh"
    else
        _vault_fetch="${_CC_ROUTING_CORE_DIR}/vault-fetch.sh"
    fi

    # --- Helper: derive this machine's vault slug -----------------------------
    # SINGLE SOURCE OF TRUTH: ask vault-keygen.js, which OWNS defaultMachineSlug().
    # Do not re-derive it here.
    #
    # XACA-0972 round 3. A hand-rolled "mirror" lived here and diverged in
    # production. On macOS socket.gethostname() returns the mDNS name
    # ("Darren-M3Pro.local"); the old snippet mapped the dot to a dash and
    # produced "darren-m3pro-local", while defaultMachineSlug() strips ".local"
    # and any remaining domain and produces "darren-m3pro". The Keychain entry
    # and the vault cache both live under the JS slug, so every shell-side probe
    # MISSED on a machine that demonstrably has a keypair -- the keypair check
    # then reported "not configured" and routed to default OAuth, i.e. fail-OPEN,
    # the exact outcome that check exists to prevent.
    #
    # The tests could not catch it: they computed the expected slug from a COPY
    # of the same snippet under test, so fixtures were planted at the same wrong
    # slug and passed. A mirror that is verified against itself proves nothing.
    #
    # Precedent for this shape: _kb_msg_this_machine in kanban-helpers.sh.
    # The python path below is a LAST-RESORT fallback for a box with no node; it
    # now performs the same .local/domain strip, but it is still a copy and must
    # be kept in step with the JS if that ever changes.
    _cc_machine_slug() {
        # XACA-1312: same self-location fix as _vault_fetch above, applied to
        # vault-keygen.js (no test-only override needed here; §1.2 of the
        # design covers only the vault-fetch seam).
        local _kg
        if [[ -e "${_CC_ROUTING_CORE_DIR}/../fleet-monitor/client/vault-keygen.js" ]]; then
            _kg="${_CC_ROUTING_CORE_DIR}/../fleet-monitor/client/vault-keygen.js"
        else
            _kg="${_CC_ROUTING_CORE_DIR}/vault-keygen.js"
        fi
        if [[ -f "$_kg" ]] && command -v node >/dev/null 2>&1; then
            local _slug
            _slug=$(node -e "process.stdout.write(require('$_kg').defaultMachineSlug())" 2>/dev/null) || _slug=""
            if [[ -n "$_slug" ]]; then
                printf '%s' "$_slug"
                return 0
            fi
        fi
        python3 -c "
import re, socket
h = socket.gethostname().lower()
h = re.sub(r'\\.local$', '', h)   # strip the mDNS suffix, as defaultMachineSlug does
h = re.sub(r'\\..*$', '', h)      # strip any remaining domain
h = re.sub(r'[^a-z0-9]+', '-', h)
h = re.sub(r'-+', '-', h).strip('-')
# Must start with a letter per SLUG_RE
if not h or not h[0].isalpha():
    h = 'm-' + h
print(h[:64])
" 2>/dev/null || true
    }

    # --- Helper: does a vault keypair exist on this machine? (XACA-0972-019) ---
    # Checks the same two backends privateKeyExists() in vault-keygen.js checks:
    # macOS Keychain generic-password (service com.aiteamforge.vault, account
    # <slug>) when `security` is available, else the 0600 fallback file at
    # ~/.aiteamforge/vault/<slug>.key.
    #
    # It is only as correct as the SLUG it is handed -- see _cc_machine_slug
    # above, which must come from defaultMachineSlug(). An earlier revision of
    # this comment claimed the two matched "EXACTLY" while the slug derivations
    # had in fact diverged, so the claim read as verification when nothing had
    # been verified. State what is checked; do not assert equivalence.
    #
    # `security find-generic-password` WITHOUT -w reads ATTRIBUTES ONLY, never
    # the secret data, so it does not raise a Keychain authorization prompt —
    # this is the same call vault-keygen's own idempotence guard already makes
    # on every run, so it is established, shipping behaviour and not a new risk.
    #
    # WHY THIS EXISTS: "is this machine vault-configured?" used to be INFERRED
    # FROM THE EXIT CODE, which is circular — an exit code we do not recognise
    # then means "not vault-configured", i.e. the least safe reading of the
    # least understood signal. This probe breaks the circularity with a cheap,
    # independent fact.
    _cc_vault_keypair_exists() {
        local _slug="$1"
        [[ -z "$_slug" ]] && return 1
        if command -v security >/dev/null 2>&1; then
            security find-generic-password -s "com.aiteamforge.vault" -a "$_slug" >/dev/null 2>&1 && return 0
        fi
        [[ -f "${HOME}/.aiteamforge/vault/${_slug}.key" ]] && return 0
        return 1
    }

    local _vault_token=""
    local _vault_exit=255
    local _vault_configured=0   # 0 = unknown/no, 1 = yes (has keypair)
    # XACA-0972-004: distinguishes "vault answered: no such secret" (exit 7)
    # from "vault could not be reached" (exit 4). Both leave the token
    # unresolved, but they demand OPPOSITE end-states — see Tier 3 below.
    local _vault_not_found=0
    # XACA-0972-018: may this failure fall back to a STALE cache entry? This is a
    # SEPARATE axis from retryability. Codes 4 (server down) and 8 (no fleet URL)
    # both mean "this machine has a vault it cannot currently reach", so both
    # qualify. Code 7 must NOT (the secret was deliberately removed) and code 3
    # is not a vault machine at all. Kept as an explicit flag rather than a
    # growing `[[ $x -eq 4 || $x -eq 8 || ... ]]` condition, so each new code has
    # to state its own intent at the point it is classified.
    local _vault_cache_ok=0
    # Human-readable reason for a fail-closed message. "Vault inaccessible" is
    # wrong for exit 8 — it sends an operator to check a server that is fine.
    local _vault_fault="vault inaccessible"
    local _machine_slug
    _machine_slug="$(_cc_machine_slug)"

    # --- XACA-1184-005: which (engine, account) pair(s) to ask the vault for ---
    #
    # THE DEFECT: both call sites below asked for `anthropic <team>`, but two
    # independent writers seal into DIFFERENT account namespaces —
    # vault-migrate-env-keys.js under anthropic/<team>, Fleet Monitor's UI under
    # <engine_slug>/<account_slug> (XACA-0282-012 §7 Q3). A team routed through
    # the UI was therefore unreachable from `cc`: the launcher was asking a
    # question whose answer could only ever live in the other half of the
    # namespace.
    #
    # THE TEAM-KEY FALLBACK IS PERMANENT, NOT A DEPRECATION PATH. The migrator
    # keeps writing anthropic/<team> and is not scheduled to stop, so a team with
    # no account_slug is CORRECTLY served there — it is a live, supported layout,
    # not a legacy remnant. Do NOT attach a deprecation warning, a "legacy key"
    # notice, or any other per-launch nag to this arm: it would fire on a
    # correctly-configured machine, every launch, forever.
    #
    # VALIDATE BEFORE THE SUBPROCESS, AND NOTE WHY IT IS NOT MERELY HYGIENE.
    # These slugs come from a hand-editable JSON file and are interpolated into
    # both a subprocess argument and a cache path. But there is a second, sharper
    # reason: vault-fetch.js REJECTS a malformed slug with exit 1 — and exit 1 is
    # also what the wrapper returns when libsodium-wrappers is missing under
    # VAULT_FETCH_NO_AUTO_INSTALL=1 (which is how this function always invokes
    # it). Those two conditions are indistinguishable by exit code alone. Letting
    # a bad slug reach the subprocess would manufacture a phantom
    # missing-dependency signal, and the `*)` arm below would then fail CLOSED on
    # a machine whose only actual fault is a typo in a config file. Validating
    # here keeps exit 1 meaning exactly one thing.
    #
    # Pattern is vault-fetch.js's own canonical SLUG_RE (/^[a-z][a-z0-9-]*$/,
    # MAX_SLUG_LEN 64), mirroring server-side vault-store.js SLUG_RE and
    # engines-routes.js ACCOUNT_SLUG_RE. Kept in step with that file by hand;
    # it is a copy, and a copy verified against itself would prove nothing.
    _cc_is_vault_slug() {
        local _s="$1"
        [[ -n "$_s" && ${#_s} -le 64 && "$_s" == [a-z]* && -z "${_s//[a-z0-9-]/}" ]]
    }

    # The engine guard above already returned unless engine_slug is empty or
    # exactly "anthropic", so this is "anthropic" in every reachable case; it is
    # written as a variable so the cache path and the fetch cannot drift apart.
    local _vault_engine="${engine_slug:-anthropic}"

    # Candidate account slugs, most specific first. Only exit 7 advances past
    # the first (see the loop below).
    local -a _vault_accounts
    _vault_accounts=()

    # Decided BEFORE the account_slug arm below so its message can tell the truth
    # about what happens next. When both slugs are bad, an unconditional "using
    # the team vault key" would promise a fallback the very next line retracts.
    local _team_slug_ok=0
    if _cc_is_vault_slug "$team"; then
        _team_slug_ok=1
    fi

    if [[ -n "$account_slug" ]]; then
        if _cc_is_vault_slug "$account_slug"; then
            _vault_accounts+=("$account_slug")
        else
            # Declared but unusable. Say so once — this is a real configuration
            # fault an operator must fix, NOT the routine no-account_slug case
            # (which is silent, because it is correct).
            #
            # XACA-1184-021: state the remedy, echo the offending value, and name
            # the file it lives in. The message used to say only that the slug was
            # invalid, which told an operator that something was wrong and nothing
            # about what to type instead — its siblings all end with an actionable
            # clause ("Seal a key with vault-put to fix."), and this one must too.
            # The SLUG is a config field, not a secret, so echoing it is safe and
            # is the difference between a two-minute fix and a hunt.
            if [[ "$_team_slug_ok" -eq 1 ]]; then
                print -u2 "⚠ Team '${team}' has an invalid ai.credential account_slug '${account_slug}' — ignoring it and using the team vault key"
            else
                print -u2 "⚠ Team '${team}' has an invalid ai.credential account_slug '${account_slug}' — ignoring it"
            fi
            print -u2 "⚠ A valid slug starts with a lowercase letter, then lowercase letters, digits or hyphens, max 64 chars. Fix teams.${team}.ai.credential.account_slug in ~/.aiteamforge/team-paths.json."
        fi
    fi
    # Permanent fallback: the migrator's namespace. Skipped only when it would
    # duplicate the account-keyed attempt (asking the identical question twice
    # would double the launch latency and log the same 404 twice).
    #
    # XACA-1184-017: the fallback candidate is validated with the SAME predicate
    # as the account-keyed one. It was not, and the two guards do not agree: the
    # team guard at the top of this function admits [A-Za-z0-9_-], so 'Academy',
    # 'acct_1' and '9team' all reach here and are then rejected by vault-fetch.js's
    # own SLUG_RE with exit 1 — which is ALSO what the wrapper returns for a
    # missing libsodium-wrappers. That reintroduces exactly the exit-1 ambiguity
    # the account_slug validation above exists to remove, letting a config typo
    # manufacture a phantom missing-dependency signal. Latent today (MEASURED: 0
    # of 27 live slugs offend), which is why it is worth closing now rather than
    # during the incident that finds it.
    #
    # When the team slug itself fails, the candidate is SKIPPED rather than
    # sanitised or passed through. Sanitising would silently ask the vault about
    # a DIFFERENT account than the one configured — the wrong-account-billed
    # failure this whole ticket is about — and passing it through is the exit-1
    # ambiguity above. Skipping can leave the list empty, and an empty list means
    # the vault tier is not attempted at all: control falls through to the env-var
    # tier with _vault_configured=0, which is the same state as "vault-fetch.sh is
    # not installed" and is already handled correctly downstream. That is the
    # honest answer — we have no well-formed key to ask for.
    if [[ "$_team_slug_ok" -eq 1 ]]; then
        if [[ "${#_vault_accounts[@]}" -eq 0 || "${_vault_accounts[1]}" != "$team" ]]; then
            _vault_accounts+=("$team")
        fi
    elif [[ "${#_vault_accounts[@]}" -eq 0 ]]; then
        # No usable candidate in either namespace. Only warn here — when a valid
        # account_slug was queued the team-key fallback is a silent optimisation
        # whose absence changes nothing the operator can act on.
        print -u2 "⚠ Team identity '${team}' is not a usable vault account slug — skipping the vault and falling back to the env-var tier"
        print -u2 "⚠ A valid slug starts with a lowercase letter, then lowercase letters, digits or hyphens, max 64 chars. Rename the team, or seal this team's key under a valid slug with vault-put."
    fi

    # Which pair actually produced the final result — the cache tier below MUST
    # read the entry for the pair that was really asked for, never a hardcoded
    # one. vault-fetch.js lays its cache out as <machine>/<engine>/<account>.plain
    # (cachePath()), so a hardcoded anthropic/<team> path would serve the
    # MIGRATOR-sealed token back after an account-keyed fetch had asked a
    # different question — a stale team-keyed token silently shadowing a fresh
    # account-keyed one, billing the wrong account intermittently.
    local _vault_account="$team"

    # XACA-1184-017: an EMPTY candidate list must skip the tier, not enter it.
    # The loop below would iterate zero times and leave _vault_exit at its 255
    # initialiser, which the classifier's `*)` arm reads as an unrecognised
    # vault-fetch failure and reports as such — inventing a vault fault out of a
    # config typo. Not entering the block leaves _vault_configured=0, which is
    # byte-for-byte the "vault-fetch.sh is not installed" state the code below
    # already handles.
    if [[ -x "$_vault_fetch" && "${#_vault_accounts[@]}" -gt 0 ]]; then
        # XACA-0972-017: CAPTURE stderr rather than discarding it. The comment
        # here used to claim stderr passed through while the code sent it to
        # /dev/null, so the actionable "no fleet server URL is configured"
        # message never reached the operator from the `cc` path at all — which
        # defeated the point of writing it.
        #
        # It is captured rather than simply un-suppressed because on a NORMAL
        # non-vault machine vault-fetch legitimately prints "No private key found
        # for machine slug ..." on every single launch. That is why the
        # suppression existed. So: capture always, replay only for the exit codes
        # where the operator must actually DO something (see the case below).
        local _vault_err_file _vault_stderr=""

        # XACA-0972-030: the window between mktemp and the removal below is
        # INTERRUPTIBLE, and this is interactive code -- `cc` is what a human
        # types, and Ctrl-C during a slow or hung vault fetch is the single most
        # likely way to leave this function early. Without a trap that file stays
        # in the shared temp dir forever, one per interrupted launch.
        #
        # SCOPING IS THE WHOLE DIFFICULTY, because this function is sourced into
        # the user's INTERACTIVE shell. A bare `trap ... EXIT` there would (a)
        # overwrite whatever trap the user or their framework already installed
        # and (b) survive the function. `local_traps` makes every trap set below
        # revert to its previous disposition when this function returns -- so a
        # pre-existing user trap is restored, not destroyed -- and
        # `local_options` keeps the setopt itself from leaking. Both are zsh
        # features; this file is zsh-only (`print -u2`, `local_options`).
        #
        # Only four dispositions are touched, and only while the file exists:
        #   EXIT / HUP / TERM -> remove the file, then continue as before.
        #   INT               -> remove the file, restore the DEFAULT handler and
        #                        re-raise, so Ctrl-C still aborts. Catching INT
        #                        and returning normally would SWALLOW the user's
        #                        interrupt (measured: a zsh string trap resumes
        #                        execution after the handler), which is a worse
        #                        bug than the leak it fixes.
        #
        # Verified: a zsh EXIT trap's own exit status does NOT overwrite the
        # function's return value, so the fail-closed `return 1` further down is
        # unaffected by anything the cleanup does.
        setopt local_options local_traps

        # XACA-1184-005: try each candidate account slug in turn. ONLY exit 7
        # advances to the next one, and that restriction is the whole safety
        # property of this loop:
        #
        #   * 7 is the ONE code that means "the vault was reached and
        #     authoritatively answered: no secret exists for this pair". Asking
        #     the other namespace is then a genuinely new question with a
        #     possibly different answer.
        #   * 4 (unreachable) and 8 (no fleet URL) mean the vault could not be
        #     ASKED. Re-asking under a different account slug cannot succeed, and
        #     treating either as absence is the fail-OPEN that XACA-0972-004
        #     exists to prevent — it would silently downgrade the billed account
        #     during an outage.
        #   * 3 means this is not a vault machine at all.
        #   * 1 is missing-dependency OR usage error, and 6 is a decrypt failure.
        #     Neither says anything about the OTHER namespace, and a second call
        #     would fail identically. A missing dependency in particular must
        #     never be allowed to read as "this team has no secret".
        #
        # So: break on everything except 7. The loop ending naturally on its last
        # candidate leaves that candidate's exit code as the final verdict, which
        # the case below classifies exactly as it did when there was one call.
        local _cand
        for _cand in "${_vault_accounts[@]}"; do
            _vault_account="$_cand"
            _vault_err_file="$(mktemp "${TMPDIR:-/tmp}/cc-vault-err.XXXXXX" 2>/dev/null)"
            if [[ -n "$_vault_err_file" ]]; then
                trap '[[ -n "$_vault_err_file" ]] && command rm -- "$_vault_err_file" 2>/dev/null; :' EXIT HUP TERM
                trap '[[ -n "$_vault_err_file" ]] && command rm -- "$_vault_err_file" 2>/dev/null; trap - INT; kill -INT $$' INT

                _vault_token=$(VAULT_FETCH_NO_AUTO_INSTALL=1 "$_vault_fetch" "$_vault_engine" "$_cand" 2>"$_vault_err_file")
                _vault_exit=$?
                _vault_stderr="$(cat "$_vault_err_file" 2>/dev/null)"

                command rm -- "$_vault_err_file" 2>/dev/null
                # Blank it BEFORE clearing the traps: if anything below re-enters a
                # handler, the guard above makes it a no-op rather than a second
                # removal of a name that may since have been reused.
                _vault_err_file=""
                trap - EXIT HUP TERM INT
            else
                # mktemp unavailable: prefer losing the diagnostics to breaking launch.
                _vault_token=$(VAULT_FETCH_NO_AUTO_INSTALL=1 "$_vault_fetch" "$_vault_engine" "$_cand" 2>/dev/null)
                _vault_exit=$?
                _vault_stderr=""
            fi
            [[ "$_vault_exit" -eq 7 ]] || break
        done

        case $_vault_exit in
            0|5)
                # Exit 0 = live fetch; exit 5 = fresh cache hit. Both = success.
                # This machine IS vault-configured.
                _vault_configured=1
                if [[ -n "$_vault_token" ]]; then
                    # NOTE (XACA-0539-013): _CC_RESOLVED_TOKEN is NOT declared
                    # `local` in this function. It is declared `local` in the
                    # CALLER (_cc_launch). Under zsh/bash dynamic scoping, this
                    # assignment writes into the caller's local, so the resolved
                    # token returns to _cc_launch without being exported to the
                    # shell environment. Do NOT add `local _CC_RESOLVED_TOKEN`
                    # here — that would shadow the caller's var and silently drop
                    # the token. Same applies to every assignment to it below.
                    _CC_RESOLVED_TOKEN="$_vault_token"
                    local _mode_label="vault"
                    [[ "$_vault_exit" -eq 5 ]] && _mode_label="cache"
                    _cc_write_mode_signal "$_mode_label"
                    if [[ -n "$nickname" ]]; then
                        print -u2 $'\e[2m'"🔐 Account: ${nickname} [${_mode_label}]"$'\e[0m'
                    fi
                    return 0
                fi
                # Vault returned exit 0/5 but empty stdout — treat as unreachable.
                # NOTE (XACA-0972 round 3): this reassignment is INERT for the
                # cache tier, which now gates on the explicit _vault_cache_ok
                # flag rather than on _vault_exit. Set the flag too, so this
                # branch actually reaches the stale cache the comment implies.
                _vault_exit=4
                _vault_cache_ok=1
                ;;
            3)
                # Not configured — no keypair on this machine. Legacy path is the
                # intended model; no warning, and deliberately NO stderr replay:
                # this is the routine case whose "No private key found for machine
                # slug ..." line would otherwise print on every launch.
                _vault_configured=0
                ;;
            4)
                # Server unreachable. This machine is vault-configured but offline.
                # Fall through to stale-cache tier below.
                _vault_configured=1
                _vault_cache_ok=1
                _vault_fault="vault inaccessible"
                ;;
            8)
                # XACA-0972-018: keypair EXISTS but no fleet server URL could be
                # resolved (or the configured one was rejected as unsafe).
                #
                # This is NOT exit 3. vault-fetch checks the keypair BEFORE it
                # resolves the URL, so reaching code 8 proves a keypair is
                # present. Treating it as 3 said "this machine has no vault" and
                # dropped a vault-provisioned machine out of the stale-cache tier
                # it used to reach — before XACA-0972 an unset URL produced a
                # localhost connection-refused, i.e. exit 4, i.e. stale cache.
                # Same treatment as 4: cache-eligible, and FAIL CLOSED if nothing
                # else yields a token. A vault machine with no URL is
                # MISCONFIGURED, not "this team has no key" — it must never be
                # routed to the quiet default-OAuth path.
                _vault_configured=1
                _vault_cache_ok=1
                _vault_fault="no fleet server URL is configured"
                if [[ -n "$_vault_stderr" ]]; then
                    print -u2 -r -- "$_vault_stderr"
                fi
                ;;
            7)
                if [[ -n "$_vault_stderr" ]]; then
                    print -u2 -r -- "$_vault_stderr"
                fi
                # XACA-0972-004: definitive HTTP 404 — the vault was reached and
                # authoritatively answered "no secret exists for this
                # engine/account". The machine IS vault-configured (that was
                # never in doubt); this specific team simply has no key sealed.
                # Non-retryable: retrying or serving stale plaintext cannot
                # conjure a secret that does not exist.
                _vault_configured=1
                _vault_not_found=1
                ;;
            6)
                # Decrypt failed — wrong/rotated key. Non-retryable; warn and
                # fall through to env-var.
                _vault_configured=1
                _vault_fault="vault key cannot decrypt this secret"
                if [[ -n "$_vault_stderr" ]]; then
                    print -u2 -r -- "$_vault_stderr"
                fi
                print -u2 "⚠ vault: decrypt failed for team '${team}' — re-provision/re-seal needed"
                ;;
            *)
                # XACA-0972-019: an exit code we do not recognise (1, 2, a crash,
                # a future code). This used to set _vault_configured=0, i.e. route
                # to DEFAULT OAUTH — the least safe reading of the least
                # understood signal, and circular besides: "is this machine
                # vault-configured?" was being inferred FROM the exit code it was
                # supposed to help interpret.
                #
                # Break the circularity with an independent fact. If a keypair is
                # actually present, this IS a vault machine having an unexplained
                # problem, so fail closed rather than silently downgrading the
                # account a session bills to. If there is genuinely no keypair,
                # the old reading was right and the legacy path still applies.
                if _cc_vault_keypair_exists "$_machine_slug"; then
                    _vault_configured=1
                    _vault_cache_ok=1
                    _vault_fault="vault-fetch failed with unexpected exit ${_vault_exit}"
                    if [[ -n "$_vault_stderr" ]]; then
                        print -u2 -r -- "$_vault_stderr"
                    fi
                    print -u2 "⚠ vault-fetch exited ${_vault_exit} (unrecognised) but a vault keypair EXISTS on this machine — treating as vault-configured, not as 'no vault'."
                else
                    _vault_configured=0
                fi
                ;;
        esac
    fi
    # If vault-fetch.sh not found at all, _vault_configured stays 0 (not configured).

    # --- 4. Tier 2 — Stale cache (offline fallback for vault-configured machines) ---
    # Only attempt when the machine IS vault-configured (exit 4 path above).
    #
    # XACA-0972-004 — exit 7 is DELIBERATELY NOT in this guard, and must not be
    # added to it. A definitive 404 means the secret was deleted or never
    # sealed; serving stale cached plaintext there would resurrect a key the
    # operator intentionally removed, silently re-authorizing a revoked
    # credential. Exit 4 (server down) keeps its cache fallback — a transient
    # outage is precisely the case this cache exists for.
    # vault-fetch's built-in cache only serves FRESH entries (within TTL). For the
    # offline-only scenario we read the cache file directly, bypassing TTL — any
    # cached plaintext is better than failing when the server is unreachable.
    # XACA-0972-018: gated on the explicit _vault_cache_ok flag, which exit 8
    # now sets alongside exit 4. Exit 7 still never sets it.
    if [[ "$_vault_configured" -eq 1 && "$_vault_cache_ok" -eq 1 ]]; then
        if [[ -n "$_machine_slug" ]]; then
            # XACA-1184-005: keyed to the pair actually fetched, NOT a hardcoded
            # anthropic/<team>. vault-fetch.js's cachePath() is
            # <machine>/<engine>/<account>.plain, so hardcoding the team key here
            # would read the MIGRATOR-sealed entry back even when the fetch above
            # asked the account-keyed question — a stale team-keyed token
            # shadowing a fresh account-keyed one. Silent, intermittent, and it
            # bills the wrong account.
            #
            # Only exit 4/8/unknown reach this tier, and all three break the loop
            # on their first candidate, so _vault_account names the pair whose
            # fetch actually failed. Reading any OTHER pair's cache here would be
            # serving a different account's token.
            local _cache_file="${HOME}/.aiteamforge/vault-cache/${_machine_slug}/${_vault_engine}/${_vault_account}.plain"
            if [[ -f "$_cache_file" && -r "$_cache_file" ]]; then
                local _stale_token
                _stale_token=$(cat "$_cache_file" 2>/dev/null) || _stale_token=""
                if [[ -n "$_stale_token" ]]; then
                    _CC_RESOLVED_TOKEN="$_stale_token"
                    _cc_write_mode_signal "cache"
                    print -u2 "⚠ ${_vault_fault} — using stale cache for team '${team}'"
                    if [[ -n "$nickname" ]]; then
                        print -u2 $'\e[2m'"🔐 Account: ${nickname} [stale-cache]"$'\e[0m'
                    fi
                    return 0
                fi
            fi
        fi
        # Stale cache miss — vault-configured machine falling to env-var is a failover.
        print -u2 "⚠ ${_vault_fault} and no cache for team '${team}' — falling back to env-var"
    fi

    # --- 5. Tier 3 — Env-var failover (legacy model, NEVER retired) -----------
    #
    # XACA-1312 §3.2: which OUTCOME an unresolved source produces now depends
    # on cred_state, not just on which vault/env signal fired. A DECLARED
    # route (cred_state=object) that cannot be honored REFUSES — an operator
    # asked for a specific account and it could not be reached. An
    # UNDECLARED team (absent/null) falling through these same tiers (vault
    # tier 1 keys on the team slug regardless of ai.credential, so it still
    # runs for these teams — see the python-side comment above) has nothing
    # to refuse ON; there was no request to fail. The one exception,
    # UNCHANGED from before this ticket (XACA-0977 D3, "the single most
    # important negative clause in the contract" — see this file's own
    # Case6a/6b-style regression coverage): a vault-configured machine whose
    # vault is genuinely UNREACHABLE with no cache/env fallback refuses for
    # cred_state=absent (an un-lifted, legacy-shape team) exactly as it did
    # pre-XACA-1312 — an outage must never silently downgrade billing for a
    # team that vault tier 1 is still actively trying to route.
    #
    # XACA-1312 fix round 1 (bot review, PR #957; rollout plan
    # XACA-1312_005_rollout_plan.md §6.2) narrows this ONE further: null —
    # and ONLY null, not absent — is exempted from that outage refusal.
    # §6.2 explicitly sells setting ai.credential to `null` as reverting a
    # team to default-OAuth "with no refusal risk", and is explicit that
    # this is a DIFFERENT, more deliberate state than plain absent (its own
    # words: deleting the key instead "re-arms the XACA-1184 legacy lift" —
    # i.e. absent and null are NOT interchangeable for this purpose). An
    # operator reaching for that documented escape hatch during an incident
    # (e.g. because they suspect the vault is the problem) must not be
    # refused BY the vault they are explicitly routing around. absent keeps
    # the pre-existing D3 behavior unchanged — it was never part of §6.2's
    # promise, and un-lifted teams are the exact case D3 exists to protect.
    if [[ -z "$env_var_name" ]]; then
        if [[ "$_vault_not_found" -eq 1 ]]; then
            # XACA-0972-004: the vault was REACHED and said "no such secret".
            if [[ "$cred_state" == "object" ]]; then
                _cc_fail_closed "Team '${team}' declared credential '${nickname:-<unnamed>}' but the vault has no secret sealed for it (HTTP 404, vault IS reachable) and no env-var is configured. Seal a key with vault-put, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
                return $?
            fi
            if [[ "$cred_state" == "absent" ]]; then
                print -u2 "⚠ Team '${team}' declares no ai.credential (undeclared) — using machine login"
            fi
            # cred_state == null: a recorded "no team credential" decision —
            # quiet, not a nag (XACA-1312 §3.2).
            return 0
        fi
        if [[ "$_vault_configured" -eq 1 ]]; then
            if [[ "$cred_state" == "null" ]]; then
                # XACA-1312 fix round 1 (§6.2): the documented no-refusal-
                # risk rollback state — quiet, same shape as the 404 branch
                # above's null case.
                return 0
            fi
            if [[ "$cred_state" == "object" ]]; then
                # Vault machine, vault genuinely UNREACHABLE, no env-var
                # configured, and cred_state IS object — an operator
                # declared a specific route and it could not be reached.
                # Fail closed. XACA-0972-018: name the ACTUAL fault. For
                # exit 8 this reads "no fleet server URL is configured",
                # not "vault inaccessible" — the latter sends an operator
                # to check a server that is fine.
                _cc_fail_closed "No token source available for team '${team}' — ${_vault_fault} and no env-var configured"
                return $?
            fi
            # cred_state == absent: XACA-0977 D3, unchanged — an un-lifted
            # team is still actively vault-routed by tier 1 above, so an
            # outage here refuses exactly as it did pre-XACA-1312.
            _cc_fail_closed "No token source available for team '${team}' — ${_vault_fault} and no env-var configured"
            return $?
        fi
        # Non-vault machine with no env-var configured.
        if [[ "$cred_state" == "object" ]]; then
            _cc_fail_closed "Team '${team}' declared credential '${nickname:-<unnamed>}' with no env_var_name and this machine has no vault. Set ai.credential.env_var_name in ${team_json}, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
            return $?
        fi
        if [[ "$cred_state" == "absent" ]]; then
            print -u2 "⚠ Team '${team}' declares no ai.credential (undeclared) — using machine login"
        fi
        return 0
    fi

    # XACA-1312 fix round 1 (bot review, PR #957): env_var_name comes from
    # team-paths.json (an operator-editable config file, not a fixed
    # constant), and zsh's ${(P)...} indirection EVALUATES a subscript
    # embedded in the name it's given — verified: with
    # n='path[$(touch /tmp/sentinel)1]', `${(P)n}` runs the command
    # substitution. _cc_secrets_file_lookup indexes an associative array by
    # the same untrusted string a few lines down, so it is a second sink,
    # not just this one. Validate BEFORE either sink is reached: a
    # non-identifier value here can only come from a hand-edited or
    # corrupted team-paths.json, never from a legitimate declaration, so
    # this is the same "present but the wrong shape" bucket cred_state=
    # invalid already refuses for a malformed ai.credential as a whole.
    if [[ ! "$env_var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        _cc_fail_closed "Team '${team}' ai.credential.env_var_name '${env_var_name}' is not a valid shell identifier — refusing to treat it as a credential source. Fix teams.${team}.ai.credential.env_var_name in ${team_json}, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
        return $?
    fi

    # env_var_name is declared here, which by construction means
    # cred_state == "object" (absent/null both force it empty above). Try
    # the shell environment first, then — XACA-1312 D2.2 — a SCOPED read of
    # ~/.zshrc.secrets for that one variable, so a non-interactive /
    # launchd-descended shell that never sourced ~/.zshrc is not refused
    # for a secret that legitimately exists on this machine.
    local _env_token="${(P)env_var_name}"
    local _env_mode_label="env-legacy"
    if [[ -z "$_env_token" ]]; then
        _env_token="$(_cc_secrets_file_lookup "$env_var_name")"
        [[ -n "$_env_token" ]] && _env_mode_label="env-secrets-file"
    fi

    if [[ -z "$_env_token" ]]; then
        if [[ "$_vault_not_found" -eq 1 ]]; then
            # XACA-1312 §3.2: vault reached and definitively empty for this
            # team, AND the declared env-var holds nothing anywhere checked
            # (shell env or ~/.zshrc.secrets). This IS the consumer failure
            # mode the ticket exists for — refuse (was: default + loud ⚠).
            _cc_fail_closed "Team '${team}' declared credential '${nickname:-<unnamed>}' but the vault has no secret sealed for it (HTTP 404, vault IS reachable) and env-var '${env_var_name}' is empty (checked the shell environment and ~/.zshrc.secrets). Seal a key with vault-put, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
            return $?
        fi
        if [[ "$_vault_configured" -eq 1 ]]; then
            # Vault-configured machine: vault genuinely UNREACHABLE AND
            # env-var is empty everywhere checked. Fail closed — unchanged
            # from before this ticket.
            _cc_fail_closed "${_vault_fault} and env-var '${env_var_name}' is empty for team '${team}' — no token available"
            return $?
        fi
        # Non-vault machine: declared env-var is empty everywhere checked.
        # XACA-1312 §3.2: this IS the consumer failure mode the ticket
        # exists for — refuse (was: default + ⚠).
        _cc_fail_closed "Team '${team}' declared credential '${nickname:-<unnamed>}' but env-var '${env_var_name}' is empty (checked the shell environment and ~/.zshrc.secrets) and this machine has no vault. Set the variable, or set AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1 to launch on the machine login."
        return $?
    fi

    # Token resolved via env-var (shell environment or the D2.2 secrets-file lookup).
    _CC_RESOLVED_TOKEN="$_env_token"
    if [[ "$_vault_configured" -eq 1 ]]; then
        # Vault machine falling to env-var = warn (degraded state).
        # XACA-0972-004: name the ACTUAL reason. Saying "vault inaccessible" on
        # the exit-7 route would re-conflate "no secret sealed" with "server
        # down" — the exact confusion this subitem exists to remove — and would
        # send an operator chasing a phantom outage.
        _cc_write_mode_signal "env-failover"
        if [[ "$_vault_not_found" -eq 1 ]]; then
            print -u2 "⚠ Using env-var fallback for team '${team}' (no key sealed in vault; server is reachable)"
        else
            print -u2 "⚠ Using env-var fallback for team '${team}' (${_vault_fault})"
        fi
    else
        # Non-vault machine using env-var = normal/expected legacy model
        # (env-legacy), or the D2.2 secrets-file lookup (env-secrets-file).
        _cc_write_mode_signal "$_env_mode_label"
    fi

    if [[ -n "$nickname" ]]; then
        print -u2 $'\e[2m'"🔐 Account: ${nickname}"$'\e[0m'
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════
# XACA-1312: shared launch-site helpers (design doc §1.1, §4, §5)
# ═══════════════════════════════════════════════════════════════
#
# One gated computation, used by every launch site (dev _cc_launch/cc/ccc,
# tap _cc_launch/cc/ccc, scripts/kb-cr.sh) instead of each duplicating the
# pre-clear + gate + export dance that used to live only in dev _cc_launch
# and dev ccc — the exact K501 sibling-heuristic-drift shape this ticket's
# design doc calls out (see its §1 rationale).

# _cc_route_prepare
#
# Pre-clears the four CLAUDE_{ACTIVE,BILLED}_ACCOUNT_{ID,NICKNAME} exports,
# calls _cc_export_account_credentials, gates the BILLED pair on whether a
# token actually resolved (XACA-0977 BLOCKING B — CLAUDE_ACTIVE_ACCOUNT_ID/
# _NICKNAME are exported BEFORE the engine guard and before any vault/
# cache/env-var tier runs, so a team can have real metadata while no token
# ever resolves), exports CLAUDE_BILLED_ACCOUNT_ID/_NICKNAME, and returns
# the chain's own rc UNCHANGED:
#   0 — safe to launch (a token resolved, OR this is legitimately default
#       OAuth). Caller reads $_CC_RESOLVED_TOKEN / $_CC_RESOLVED_AUTH_TYPE
#       (may be empty) and $_CC_BILLED_ID / $_CC_BILLED_NICKNAME.
#   1 — REFUSED. _cc_export_account_credentials has already printed its one
#       "✗ ..." line (or, under AITEAMFORGE_ALLOW_DEFAULT_OAUTH=1, this rc
#       cannot occur — every refusal becomes 0 + a loud override warning
#       instead). Caller MUST NOT launch claude and MUST NOT bill anything.
#
# Caller contract (same dynamic-scope shape _cc_export_account_credentials
# itself already documents): declare, BEFORE calling,
#   local _CC_RESOLVED_TOKEN="" _CC_RESOLVED_AUTH_TYPE=""
#   local _CC_BILLED_ID="" _CC_BILLED_NICKNAME=""
# This function does NOT `local`-declare any of the four itself — doing so
# would shadow the caller's locals under zsh dynamic scoping and silently
# drop the resolved token/gated identity, exactly the failure mode
# documented at _cc_export_account_credentials' own tier-1 success path.
_cc_route_prepare() {
    export CLAUDE_ACTIVE_ACCOUNT_ID=""
    export CLAUDE_ACTIVE_ACCOUNT_NICKNAME=""
    export CLAUDE_BILLED_ACCOUNT_ID=""
    export CLAUDE_BILLED_ACCOUNT_NICKNAME=""
    _CC_BILLED_ID=""
    _CC_BILLED_NICKNAME=""

    _cc_export_account_credentials
    local _cc_rp_rc=$?

    if [[ $_cc_rp_rc -eq 1 ]]; then
        return 1
    fi

    _CC_BILLED_ID="${CLAUDE_ACTIVE_ACCOUNT_ID:-}"
    _CC_BILLED_NICKNAME="${CLAUDE_ACTIVE_ACCOUNT_NICKNAME:-}"
    if [[ -z "$_CC_RESOLVED_TOKEN" ]]; then
        _CC_BILLED_ID=""
        _CC_BILLED_NICKNAME=""
    fi
    export CLAUDE_BILLED_ACCOUNT_ID="$_CC_BILLED_ID"
    export CLAUDE_BILLED_ACCOUNT_NICKNAME="$_CC_BILLED_NICKNAME"
    return 0
}

# _cc_probe_has_session_id
#
# XACA-1300-027: feature-detect `claude --help`'s --session-id support ONCE
# per shell, memoized into a global, instead of every launch site (persona
# _cc_launch, cc()'s two fallback branches — in both dev
# claude_code_cc_aliases.sh and the tap cc-aliases.sh copy) independently
# forking `claude --help`. In cc()'s no-team-context fallback specifically,
# callers should also use this BEFORE deciding whether to invoke
# session-account-map-headless.sh at all: that script's own top-of-file
# check re-probes the identical thing and, when unsupported, silently no-ops
# (exit 0, no stdout) — so skipping the call in that case changes no
# observable behavior, only saves a whole extra fork+exec of a second
# script on every gate launch.
#
# Returns 0 (true, --session-id supported) or 1 (false). Memoizes ONLY a
# POSITIVE result into the global _CC_HAS_SESSION_ID ("1") so later calls
# in the SAME shell are free once claude is known to support --session-id.
#
# XACA-1300-031 (PR #962 test-gate advisory): round 1 also cached a
# NEGATIVE result ("0") for the shell's whole lifetime. Before this
# function existed, every launch site ran its own fresh `claude --help`
# probe, so one transient failure (claude mid-upgrade, a flaky exec, a
# momentarily broken PATH) cost that one launch and nothing more — the
# NEXT launch probed again and could succeed. Caching "0" regressed that:
# a single bad probe permanently disabled --session-id pinning AND every
# session-account-map row for the rest of the shell's life, silently, with
# no way to recover short of opening a new shell. Only a confirmed "1" is
# ever trustworthy to skip re-probing (claude does not un-ship a flag); a
# "0"/unset result always re-probes on the next call, same cost as
# pre-XACA-1300-027 for the failure case, free for the steady-state
# (supported) case this optimization actually targets.
_cc_probe_has_session_id() {
    if [[ "${_CC_HAS_SESSION_ID:-}" != "1" ]]; then
        if claude --help 2>/dev/null | grep -q -- "--session-id"; then
            _CC_HAS_SESSION_ID=1
        else
            _CC_HAS_SESSION_ID=0
        fi
    fi
    [[ "$_CC_HAS_SESSION_ID" == "1" ]]
}

# _cc_fb_wants_pinned_sid <args...>
#
# XACA-1300-028: cc()'s fallback branches (no persona/team-routed launch)
# used to pin --session-id only when cc() got NO arguments at all, so
# `cc -p "prompt"` (print/non-interactive mode) wrote NO
# session-account-map row while `printf … | cc` (the kb-run-* gate pattern,
# also zero arguments) did. True when it is safe AND useful to pin one:
# either no arguments at all (the existing, always-safe case), or every
# argument is either the print flag (-p/--print) or a flag this function
# KNOWS is session-identity-neutral.
#
# XACA-1300-029 (PR #962 review, BLOCKING): round 1 shipped a DENYLIST
# (reject --session-id/--resume/-r/--continue/-c, pin otherwise) — wrong
# CLASS of check. claude has other resume-class flags a denylist will
# always be one release behind on (--from-pr, --from-pr=N, --teleport,
# --teleport=S), plus attached short-flag value forms (-rID) that never
# matched the exact-token entries `-r`/`-c` at all. Any of those slipped a
# stray --session-id onto a caller-managed resume/teleport/PR-linked
# launch — `cc -p -rID` didn't just mis-record, it made claude itself
# reject the command ("--session-id can only be used with --continue or
# --resume if --fork-session"). Inverted to an ALLOWLIST: pin only when
# -p/--print is present and EVERY OTHER argument is either a non-flag
# positional (the prompt) or one of the handful of flags below, verified
# session-identity-neutral against `claude --help` (checked live 2026-09,
# not recalled — re-check if claude's CLI changes):
#   --model <value>              (--model=value or --model value)
#   --output-format <value>      (print-only output shaping)
#   --permission-mode <value>    (permission handling, not session identity)
#   --append-system-prompt <value>
#   --verbose                    (boolean, no value)
# ANY other flag — --resume, -r (bare or with an attached value like
# -rID), --continue, -c, --session-id, --from-pr, --from-pr=N, --teleport,
# --teleport=S, a combined short-flag bundle like -pc/-pr/-cp, or anything
# not on this list at all — fails CLOSED to "no pin", which is exactly the
# pre-XACA-1300-028 behavior (safe: cc() still launches, just unrecorded,
# same as before this whole ticket). A combined bundle never separately
# matches `-p`/`--print` as its own token, so it naturally falls through
# to "no pin" without needing a special case — documented here rather than
# silently relying on it: -pc/-pr/-cp/etc. never pin.
#
# Value-taking flags in "bare" form (no `=`) unconditionally consume the
# NEXT token as their value — exactly like the real CLI parser — without
# re-examining it against this allowlist (a value can legitimately look
# like anything). A value-taking flag with nothing following it is
# malformed input; that fails closed too (no pin), never a crash.
_cc_fb_wants_pinned_sid() {
    (( $# == 0 )) && return 0
    local -a _cc_fb_args
    _cc_fb_args=("$@")
    local _cc_fb_saw_print=""
    local -i _cc_fb_i=1
    while (( _cc_fb_i <= $#_cc_fb_args )); do
        local _cc_fb_tok="${_cc_fb_args[_cc_fb_i]}"
        case "$_cc_fb_tok" in
            -p|--print)
                _cc_fb_saw_print=1
                ;;
            --model|--output-format|--permission-mode|--append-system-prompt)
                (( _cc_fb_i++ ))
                (( _cc_fb_i > $#_cc_fb_args )) && return 1
                ;;
            --model=*|--output-format=*|--permission-mode=*|--append-system-prompt=*)
                ;;
            --verbose)
                ;;
            -*)
                # Every resume/session-identity flag this function must
                # reject, every attached-value short form (-rID), every
                # combined short-flag bundle (-pc/-pr/-cp), and anything
                # simply not on the allowlist above — one fail-closed arm.
                return 1
                ;;
            *)
                # Non-flag positional: the prompt text itself.
                ;;
        esac
        (( _cc_fb_i++ ))
    done
    [[ -n "$_cc_fb_saw_print" ]]
}

# _cc_record_session_account <session_id> <billed_id> <billed_nickname>
#
# Resolves session-account-map-record.sh NEXT TO THE CORE
# ($_CC_ROUTING_CORE_DIR/session-account-map-record.sh), which exists in
# both layouts this file ships to: dev scripts/ and a consumer's
# $AITEAMFORGE_DIR/scripts/ (sync-tap.sh flattens all three chain files —
# headless.sh / record.sh / session-account-map.py — into share/scripts/,
# XACA-1300-014). Replaces every launcher's own hardcoded
# $HOME/dev-team/scripts/session-account-map-record.sh, which is wrong on a
# consumer by construction and is the D3 correction in the design doc's §0
# corrections table: the headless recorder's own rule 1 would mis-record a
# routed launch, because _cc_run_claude_with_auth puts the token only into
# claude's CHILD environment — a helper run in the launcher's own shell
# sees no credential var and records default OAuth regardless of what was
# actually billed. Call this with the GATED identity instead.
#
# Silent no-op when the recorder is absent or session_id is empty — same
# fail-soft contract every existing call site already had. Never aborts a
# launch.
#
# XACA-1312 round 2 (fix-round-1 review finding "wrong account recorded"):
# every call site reads $_billed_id / $_billed_nickname straight from
# _cc_route_prepare's $_CC_BILLED_ID / $_CC_BILLED_NICKNAME, which
# _cc_route_prepare ZEROES whenever $_CC_RESOLVED_TOKEN is empty (no team
# route token — cred_state absent/null, or the missing-core override). But
# "no route token" is NOT the same fact as "default OAuth" —
# _cc_run_claude_with_auth's own empty-token branch runs plain `claude
# "$@"`, which INHERITS whatever ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY /
# CLAUDE_CODE_OAUTH_TOKEN / Bedrock / Vertex switch the calling shell
# already carried (e.g. an agent shell's own credential). Recording that as
# account_resolved:true/default-OAuth is a WRONG billing record: it claims
# "this ran on the machine login" when it actually ran on an inherited,
# unidentified credential. Mirror
# session-account-map-headless.sh's rule 1 vs rule 3 exactly instead of
# collapsing both into "resolved, default OAuth":
#   billed_id/nickname non-empty  → rule 2, a real gated route: record it
#                                    (unchanged from before this fix).
#   both empty, NO credential var
#     present in this shell        → rule 1: genuinely default OAuth,
#                                     record account_resolved=true, "".
#   both empty, a credential var
#     IS present in this shell     → rule 3: an inherited, ungated
#                                     credential — record
#                                     account_resolved=false (unknown
#                                     account), never "true, default OAuth".
# The rule-3 branch must OMIT --account-id (not pass it as "") so the shim
# never sets its ACCOUNT_ID_EXPLICIT flag — passing --account-id "" always
# forces account_resolved=true, per session-account-map-record.sh's own
# contract. It also scrubs CLAUDE_ACTIVE_ACCOUNT_ID/_NICKNAME for the call
# only: those are UNGATED metadata (exported before any token tier runs —
# XACA-0977-013/015) that the shim falls back to reading when --account-id
# is omitted, and they can be non-empty even when no token ever resolved.
_cc_record_session_account() {
    local _sid="$1"
    local _billed_id="$2"
    local _billed_nickname="$3"
    [[ -z "$_sid" ]] && return 0
    local _recorder="${_CC_ROUTING_CORE_DIR}/session-account-map-record.sh"
    [[ -x "$_recorder" ]] || return 0

    if [[ -n "$_billed_id" || -n "$_billed_nickname" ]]; then
        "$_recorder" "$_sid" \
            --account-id "$_billed_id" \
            --account-nickname "$_billed_nickname" 2>/dev/null || true
        return 0
    fi

    local _cred_present=0
    [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]] && _cred_present=1
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && _cred_present=1
    [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && _cred_present=1
    [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]] && _cred_present=1
    [[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ]] && _cred_present=1

    if [[ "$_cred_present" -eq 0 ]]; then
        # rule 1: no credential anywhere in this shell → genuinely default
        # OAuth, resolved.
        "$_recorder" "$_sid" \
            --account-id "" \
            --account-nickname "" 2>/dev/null || true
    else
        # rule 3: an inherited credential with no gated billed pair —
        # unknown account. Omit --account-id; scrub the ungated metadata
        # pair for this call only so the shim's own fallback can't stamp a
        # stray value onto a record we are explicitly marking unresolved.
        CLAUDE_ACTIVE_ACCOUNT_ID="" CLAUDE_ACTIVE_ACCOUNT_NICKNAME="" \
            "$_recorder" "$_sid" 2>/dev/null || true
    fi
}

# _cc_resume_account_guard <session_id> <resolved_account_id> <force 0|1>
#
# XACA-0977 D1/D2 cross-account resume guard, extracted so dev ccc and tap
# ccc share ONE implementation (design doc §1.1, §5) instead of a second
# hand-copy that can silently diverge. Looks up the account a session was
# recorded under via session-account-map.py, resolved NEXT TO THE CORE
# ($_CC_ROUTING_CORE_DIR/session-account-map.py — the dev-only hardcode
# this replaces is what made the guard unusable on a consumer at all). The
# guard applies only when a record is FOUND and (account_id is non-empty OR
# account_resolved is true) — round-6 three-state rationale: NOTFOUND never
# applies; FOUND with a non-empty account_id always applies; FOUND with an
# empty account_id applies only when account_resolved is true (a real,
# deliberate "billed to default OAuth" decision), never when the field is
# merely absent/false (a pre-round-4 record whose writer never gated at
# all — treat exactly like NOTFOUND).
#
# Returns:
#   0 — ok to resume: no record, no mismatch, or force=1. On a genuine
#       mismatch overridden by force, this function ALSO prints the dim
#       "--force: resuming cross-account" notice itself, so callers never
#       have to re-derive whether a real override just happened.
#   1 — BLOCKED. This function has ALREADY printed the full cross-account
#       warning; the caller's only remaining job is `return 1` (no claude
#       launch, no billing).
_cc_resume_account_guard() {
    local _session_id="$1"
    local _resolved_account_id="$2"
    local _force="${3:-0}"

    local _team="${SESSION_TYPE:-${LCARS_TEAM:-${KB_TEAM:-}}}"
    local _resume_record_found="" _resume_account_id="" _resume_account_resolved="0"
    local _map_py="${_CC_ROUTING_CORE_DIR}/session-account-map.py"
    if [[ -f "$_map_py" ]]; then
        local _resume_lookup
        _resume_lookup=$(python3 "$_map_py" lookup \
            --session-id "$_session_id" 2>/dev/null \
            | python3 -c \
"import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('NOTFOUND||0')
else:
    aid = d.get('account_id', '')
    resolved = bool(d.get('account_resolved', False))
    print('FOUND|' + aid + '|' + ('1' if resolved else '0'))" \
            2>/dev/null) || _resume_lookup=""
        # Pipe-safe split — see the identical idiom in dev ccc: account_id is
        # unbounded free text and may itself contain "|".
        _resume_record_found="${_resume_lookup%%|*}"
        local _resume_rest="${_resume_lookup#*|}"
        _resume_account_resolved="${_resume_rest##*|}"
        _resume_account_id="${_resume_rest%|*}"
    fi

    local _guard_applies=0
    if [[ "$_resume_record_found" == "FOUND" ]]; then
        if [[ -n "$_resume_account_id" || "$_resume_account_resolved" == "1" ]]; then
            _guard_applies=1
        fi
    fi

    if (( _guard_applies )) && [[ "$_resume_account_id" != "$_resolved_account_id" ]]; then
        if (( ! _force )); then
            print -u2 $'\e[33m'"⚠ Cross-account resume detected"$'\e[0m'
            print -u2 "  Session $_session_id was recorded under account: ${_resume_account_id:-default OAuth}"
            print -u2 "  This shell resolves to:                    ${_resolved_account_id:-(none)}   [team: ${_team:-<none>}]"
            print -u2 "  Resuming here bills tokens to ${_resolved_account_id:-default OAuth}, not ${_resume_account_id:-default OAuth}."
            print -u2 "  To bill the original account: set the owning team's context (SESSION_TYPE / LCARS_TEAM / KB_TEAM) and run ccc there."
            print -u2 "  To accept billing to the current account: ccc --force"
            return 1
        fi
        print -u2 $'\e[2m'"  --force: resuming cross-account; billed to ${_resolved_account_id:-default OAuth}."$'\e[0m'
    fi
    return 0
}

# _cc_resume_context_warning <session_id>
#
# XACA-1303-002: never-blocking cost warning printed before a `ccc` resume
# reloads a large prior transcript into context. A resumed session replays
# its ENTIRE prior context before the first new turn — the trigger was 4
# Firebase sessions resumed 2026-09-21 that each started around 156K
# tokens. This is advisory only: it is a SEPARATE, optional concern from
# _cc_resume_account_guard above (which blocks on a real mismatch), and it
# must NEVER prevent a resume — every failure mode below (bad session id,
# no transcript, no python3, malformed JSON, no usage lines) is silent and
# returns 0. See docs/token-budget.md for the dedup rule this reuses
# (design: kanban/plans/XACA-1300/XACA-1300-001_schema.md) — usage repeats
# per content block sharing one message.id, so only the LAST assistant
# usage record in the transcript is read, never summed.
#
# Threshold is the named constant below, overridable via
# CC_RESUME_CONTEXT_WARN_TOKENS (non-numeric override falls back to the
# default; 0 disables the warning entirely).
_cc_resume_context_warning() {
    local _session_id="$1"
    [[ -z "$_session_id" ]] && return 0

    # Validate shape BEFORE it touches a glob: real session ids are UUIDs
    # (hex + hyphens). Anything else — '/', glob metacharacters, etc. —
    # is untrusted input and is skipped rather than risking an escape out
    # of projects/*/<id>.jsonl. Same idiom as the shell-identifier checks
    # elsewhere in this file (e.g. _cc_secrets_file_lookup above).
    if [[ ! "$_session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
        return 0
    fi

    # Named constant + env override (XACA-1303-002 design).
    local _CC_RESUME_CONTEXT_WARN_DEFAULT=100000
    local _threshold="${CC_RESUME_CONTEXT_WARN_TOKENS:-$_CC_RESUME_CONTEXT_WARN_DEFAULT}"
    if [[ ! "$_threshold" =~ ^[0-9]+$ ]]; then
        _threshold="$_CC_RESUME_CONTEXT_WARN_DEFAULT"
    fi
    (( _threshold == 0 )) && return 0

    command -v python3 >/dev/null 2>&1 || return 0

    local _config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # UUIDs are unique across projects — no need to re-derive the cwd
    # slug the transcript lives under, just glob for it directly.
    # `setopt localoptions nullglob` (scoped to this function only) means
    # no match -> empty array, never a "no matches found" abort — the
    # zsh-glob-qualifier form `(N)` glued onto the pattern does the same
    # thing but is NOT `bash -n`-parseable (it trips the required syntax
    # check on this file), so this is the portable-to-parse equivalent.
    setopt localoptions nullglob
    local -a _cc_rcw_matches
    _cc_rcw_matches=("${_config_dir}"/projects/*/"${_session_id}".jsonl)
    (( ${#_cc_rcw_matches[@]} == 0 )) && return 0
    local _transcript="${_cc_rcw_matches[1]}"
    [[ -r "$_transcript" ]] || return 0

    # Read only the tail — the check itself must cost nothing noticeable.
    # Walk in reverse, take the LAST assistant usage record's total
    # context (input + cache_read + cache_creation); never sum — usage
    # repeats per content block for the same message.id (see kb-token-report).
    local _context_tokens
    _context_tokens=$(tail -n 200 -- "$_transcript" 2>/dev/null | python3 -c '
import json, sys

for line in reversed(sys.stdin.readlines()):
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if rec.get("type") != "assistant":
        continue
    msg = rec.get("message")
    if not isinstance(msg, dict):
        continue
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        continue
    try:
        total = (int(usage.get("input_tokens", 0) or 0)
                 + int(usage.get("cache_read_input_tokens", 0) or 0)
                 + int(usage.get("cache_creation_input_tokens", 0) or 0))
    except (TypeError, ValueError):
        continue
    print(total)
    break
' 2>/dev/null)

    [[ "$_context_tokens" =~ ^[0-9]+$ ]] || return 0
    (( _context_tokens >= _threshold )) || return 0

    local _cc_rcw_kdisplay=$(( _context_tokens / 1000 ))
    local _cc_rcw_id8="${_session_id[1,8]}"
    print -u2 "ccc: ⚠ resuming session ${_cc_rcw_id8} reloads ~${_cc_rcw_kdisplay}K tokens of context before your first turn."
    print -u2 "ccc:   Starting a new phase of work? A fresh session is cheaper — run kb-recover for the resume manifest, then start with cc."
    print -u2 "ccc:   (threshold CC_RESUME_CONTEXT_WARN_TOKENS=${_threshold}; set 0 to silence. See docs/token-budget.md)"
    return 0
}

# ═══════════════════════════════════════════════════════════════
# XACA-1246-003: LCARS credential resolver (non-interactive, resolve-only)
# ═══════════════════════════════════════════════════════════════
#
# _cc_resolve_credential_for_team <team> <presence|value>
#
# A thin, non-interactive wrapper around _cc_export_account_credentials
# above, called by lcars-ui/server.py AT REQUEST TIME so a launchd-spawned
# LCARS server -- whose process environment is frozen at `exec` and
# therefore can never see CLAUDE_ACCT_* (XACA-1246-001) -- can still answer
# "does team X have a working credential" and "what is it" without ever
# injecting a secret into any long-lived process environment.
#
# Full design: kanban/plans/XACA-1246/XACA-1246-002-secret-delivery-decision.md
# This implements design §9 point 1 EXACTLY: _cc_export_account_credentials
# is called UNCHANGED. There is no second implementation of the vault/
# cache/env-var tier chain here -- every future fix to that function (exit-
# code classification, cache gating, slug validation, the KSH_ARRAYS guard,
# ...) is inherited for free. See k501-sibling-heuristic-drift-pattern.
#
# --- stdout contract (and ONLY stdout carries structured output) ---------
#   line 1: a single-line JSON object --
#     {"available": bool, "mode": "vault"|"cache"|"env-failover"|
#      "env-legacy"|null, "fault": <str>|null, "chain_rc": 0|1}
#   `mode` is non-null only when available is true.
#   `fault` carries a LOCAL diagnosis this function itself made (currently:
#   only the secrets-file permission-enforcement failing); it is null
#   whenever the chain's own rc=0 (design §6.1: rc 0 = "no key anywhere",
#   quiet) or when this function found no local fault of its own.
#   `chain_rc` is the raw return code of _cc_export_account_credentials (0
#   or 1) so the caller can apply design §6.1's direct rc mapping WITHOUT
#   this function re-deriving or duplicating that judgment call, and can
#   pull the chain's own human-readable reason from this process's STDERR
#   on chain_rc=1: every rc=1 exit in _cc_export_account_credentials is
#   preceded by exactly one line prefixed "✗ " (tier 3, the two `return 1`
#   sites), and nothing else this function or the chain ever prints uses
#   that prefix.
#
#   In "value" mode, when available is true, stdout continues AFTER line 1
#   with a sentinel line and then the raw token as the remainder of stdout
#   to EOF (never a fixed-width "next line", so a token containing its own
#   embedded newline still round-trips intact):
#     ===AITF-CRED-TOKEN===
#     <token, verbatim, to EOF>
#
# --- channel discipline (approval condition 6) ----------------------------
# The token is NEVER printed to stderr, NEVER logged, NEVER included in the
# JSON record. Diagnostic banners from the wrapped chain (nickname, tier
# warnings, the chain_rc=1 "✗ ..." line) go to stderr exactly as
# _cc_export_account_credentials always emits them. The caller MUST capture
# that stream and must never let it reach an HTTP response or a log file
# verbatim -- extracting the single "✗ " line for the fault field is fine
# (it is operator-facing diagnostic text with no secret in it by
# construction), printing the whole captured blob is not.
_cc_resolve_credential_for_team() {
    emulate -L zsh
    setopt LOCAL_OPTIONS NO_KSH_ARRAYS

    local team="$1"
    local mode="$2"
    local _sentinel="===AITF-CRED-TOKEN==="

    # Emits the line-1 JSON record. Nested so it becomes a global function
    # the same way _cc_write_mode_signal does inside the function above --
    # harmless, this name is new and cannot collide.
    _cc_resolve_emit() {
        # $1=available(0/1) $2=mode(may be empty) $3=fault(may be empty) $4=chain_rc
        KB_CC_AVAIL="$1" KB_CC_MODE="$2" KB_CC_FAULT="$3" KB_CC_RC="$4" python3 -c "
import json, os
def _n(v):
    return v if v else None
print(json.dumps({
    'available': os.environ.get('KB_CC_AVAIL') == '1',
    'mode': _n(os.environ.get('KB_CC_MODE', '')),
    'fault': _n(os.environ.get('KB_CC_FAULT', '')),
    'chain_rc': int(os.environ.get('KB_CC_RC', '0') or '0'),
}))
" 2>/dev/null && return 0
        # python3 missing/broken -- hand-build a minimal record rather than
        # print nothing. Every value reaching this point is either a fixed
        # literal owned by this file (mode is chain vocabulary; fault is one
        # of this function's own English sentences) -- none can contain a
        # double-quote, so this manual quoting is safe.
        printf '{"available":%s,"mode":%s,"fault":%s,"chain_rc":%s}\n' \
            "$([[ "$1" == 1 ]] && print -n true || print -n false)" \
            "$([[ -n "$2" ]] && print -n "\"$2\"" || print -n null)" \
            "$([[ -n "$3" ]] && print -n "\"$3\"" || print -n null)" \
            "${4:-0}"
    }

    if [[ "$mode" != "presence" && "$mode" != "value" ]]; then
        print -u2 "_cc_resolve_credential_for_team: mode must be 'presence' or 'value', got '${mode}'"
        return 2
    fi

    # Team slug: identical predicate to _cc_export_account_credentials' own
    # gate above (XACA-0539-011). Defense-in-depth only -- server.py
    # validates the same shape BEFORE ever invoking this subprocess
    # (XACA-1246-003 approval condition 1).
    if [[ -z "$team" || -n "${team//[A-Za-z0-9_-]/}" || "$team" != [A-Za-z0-9]* ]]; then
        _cc_resolve_emit 0 "" "invalid team identity" 0
        return 0
    fi

    # Force resolution for the REQUESTED team, never whatever this process
    # happened to inherit. LCARS answers for any of 27 teams from ONE server
    # process (design §2 a-2) -- this subprocess may inherit the SERVER's
    # own LCARS_TEAM from its parent environment, which is a different
    # question than "what team was asked for in THIS query."
    unset SESSION_TYPE LCARS_TEAM 2>/dev/null
    export KB_TEAM="$team"

    # --- Enforce ~/.zshrc.secrets mode, then source it (design §3.3 ob. 1) ---
    # Mirrors scripts/cr-confluence-poller.py:206-245 (load_credentials):
    # mask 0o077, self-heal to 0600, refuse to source if it cannot be
    # tightened. Delegated to python3 (already a hard dependency of the
    # chain this wraps) rather than zsh's `zstat`/platform `stat`, which has
    # no portable flag syntax across BSD (macOS) and GNU -- os.stat/
    # os.chmod need none.
    local _secrets_file="${HOME}/.zshrc.secrets"
    local _secrets_fault=""
    if [[ -f "$_secrets_file" ]]; then
        local _enforce_msg
        _enforce_msg=$(KB_CC_SECRETS_FILE="$_secrets_file" python3 -c "
import os, stat, sys
p = os.environ['KB_CC_SECRETS_FILE']
try:
    st = os.stat(p)
except OSError as exc:
    print(f'could not stat: {exc}', file=sys.stderr)
    sys.exit(0)
mode = stat.S_IMODE(st.st_mode)
if mode & 0o077:
    try:
        os.chmod(p, 0o600)
        print(f'tightened mode from 0{mode:o} to 0600', file=sys.stderr)
    except OSError as exc:
        print(f'unsafe mode 0{mode:o} could not be tightened to 0600 ({exc})', file=sys.stderr)
        sys.exit(1)
" 2>&1)
        local _enforce_rc=$?
        [[ -n "$_enforce_msg" ]] && print -u2 -r -- "⚠ ${_secrets_file}: ${_enforce_msg}"
        if [[ "$_enforce_rc" -eq 0 ]]; then
            source "$_secrets_file" 2>/dev/null
        else
            _secrets_fault="secrets file has unsafe permissions and could not be tightened — not sourced"
        fi
    fi
    # No `else` branch: a missing secrets file is the routine "nothing to
    # override" case, same as home-scripts/.zshrc:8-9's own `[ -f ... ] &&
    # source` -- silent, not a fault.

    # --- Snapshot the mode-signal file BEFORE calling the chain (design
    # §3.3 ob. 2 / §6.3): a QUERY must never overwrite the record of which
    # tier won the LAST REAL `cc` launch. _cc_export_account_credentials
    # unconditionally (re)writes this file on every successful resolution
    # and cannot be told not to without editing the wrapped function -- so
    # snapshot before, and (only when a token actually resolves -- the only
    # condition under which the chain's three success paths ever touch the
    # file) read the `mode` field it just wrote -- THE ONLY place the chain
    # exposes which tier won -- then restore the file to its pre-call state.
    local _mode_signal_file="${HOME}/.aiteamforge/secret-source-mode/${team}.json"
    local _pre_exists=0
    local _pre_content=""
    if [[ -f "$_mode_signal_file" ]]; then
        _pre_exists=1
        _pre_content=$(cat "$_mode_signal_file" 2>/dev/null)
    fi

    # --- Call the chain, UNCHANGED. Dynamic-scope contract (XACA-0539-013):
    # _CC_RESOLVED_TOKEN / _CC_RESOLVED_AUTH_TYPE must be `local` HERE, not
    # inside _cc_export_account_credentials, or the assignment is silently
    # dropped -- see the NOTE at that function's tier-1 success path.
    local _CC_RESOLVED_TOKEN=""
    local _CC_RESOLVED_AUTH_TYPE=""
    _cc_export_account_credentials
    local _cc_rc=$?

    local _resolved_mode=""
    if [[ -n "$_CC_RESOLVED_TOKEN" ]]; then
        if [[ -f "$_mode_signal_file" ]]; then
            _resolved_mode=$(KB_CC_SIGNAL_FILE="$_mode_signal_file" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['KB_CC_SIGNAL_FILE']))
    print(d.get('mode','') or '')
except Exception:
    pass
" 2>/dev/null)
        fi
        # ACCEPTED NARROW RACE: a genuine `cc` launch for this exact team,
        # landing inside this call's own window (bounded by the caller's
        # subprocess timeout), would have its real write clobbered by this
        # restore. Splitting HOME/secrets sourcing further apart to close
        # that window would mean editing _cc_export_account_credentials
        # itself, which is exactly the k501 sibling-drift risk design
        # §7.4/§7.8 reject.
        if [[ "$_pre_exists" -eq 1 ]]; then
            printf '%s' "$_pre_content" > "$_mode_signal_file" 2>/dev/null || true
        else
            command rm -f "$_mode_signal_file" 2>/dev/null || true
        fi
    fi

    # fault: only a LOCAL diagnosis (currently: secrets-mode enforcement).
    # The chain_rc=1 case is intentionally left to the caller (design §6.1
    # "map them directly; do not re-derive them") -- it reads the "✗ ..."
    # line from OUR stderr, which the chain already wrote.
    local _fault=""
    if [[ -z "$_CC_RESOLVED_TOKEN" && -n "$_secrets_fault" ]]; then
        _fault="$_secrets_fault"
    fi

    _cc_resolve_emit \
        "$([[ -n "$_CC_RESOLVED_TOKEN" ]] && print -n 1 || print -n 0)" \
        "$_resolved_mode" \
        "$_fault" \
        "$_cc_rc"

    if [[ "$mode" == "value" && -n "$_CC_RESOLVED_TOKEN" ]]; then
        print -r -- "$_sentinel"
        print -r -- "$_CC_RESOLVED_TOKEN"
    fi

    unset _CC_RESOLVED_TOKEN
    return 0
}

# ═══════════════════════════════════════════════════════════════
# XACA-0977-011: shared auth-env helper (XACA-1178 D3/D4, build site —
# XACA-1178-002/003 were cancelled 2026-09-12; this is the one place that
# helper is built). ONE function, THREE call sites (_cc_launch's launch,
# ccc's --resume, ccc's --continue) — a second copy is the exact
# sibling-heuristic-drift failure that lets `cc` and `ccc` silently bill the
# same session to different accounts.
#
# Maps a resolved auth_type to exactly one Claude credential variable and
# clears the other two from claude's child environment. XACA-1178 R2:
# clearing is LOAD-BEARING, not hygiene — measured precedence is
# ANTHROPIC_AUTH_TOKEN > ANTHROPIC_API_KEY > CLAUDE_CODE_OAUTH_TOKEN, so an
# uncleared competitor (e.g. a stray exported ANTHROPIC_API_KEY) can
# silently outrank the intended variable and bill the wrong account.
#
#   auth_type      | variable SET      | variables REMOVED
#   ----------------|--------------------|------------------------------
#   oauth_token     | CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY
#   api_key         | ANTHROPIC_API_KEY       | ANTHROPIC_AUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN
#   gateway_token   | ANTHROPIC_AUTH_TOKEN    | ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN
#
# THE DEFAULT (XACA-0977 D7, user decision 2026-09-12): an absent/empty
# auth_type resolves to gateway_token, i.e. ANTHROPIC_AUTH_TOKEN — the
# byte-identical, measured-working invocation every team gets today (M3:
# 0 of 27 teams carry an `ai` block, so this is the universal case).
#
# DEFERRED, NOT FORGOTTEN: XACA-0282-012 §1.2 specifies token-prefix
# sniffing (sk-ant-oat → oauth_token, sk-ant-api → api_key) as the fallback
# for an absent auth_type. That is intentionally NOT implemented here —
# user decision 2026-09-12. Reason: academy is the only team on the fleet
# with live account routing today, its token IS a Max (oauth) token, and
# prefix inference would move it from the highest-precedence variable
# (ANTHROPIC_AUTH_TOKEN) to the lowest (CLAUDE_CODE_OAUTH_TOKEN) in the very
# session doing this work. Do not add prefix sniffing without a separate,
# deliberate decision that re-checks that risk.
#
# NON-NEGOTIABLE: the token must NEVER enter argv. `env VAR=<token> claude`
# is forbidden — the token would be visible in `ps` for the process's
# lifetime. This uses a `( … )` subshell that unsets the three competitor
# variables and then uses zsh's `VAR=value cmd` prefix form inside that
# subshell, so neither the interactive shell nor argv ever carries the
# token, and the unsets never escape to the caller's shell. A `( … )`
# subshell run in the foreground (no trailing `&`) does not redirect stdin,
# so TTY detection for claude's interactive prompt is preserved.
#
# Args: $1 = resolved token (may be empty → default OAuth, nothing injected
#            or unset); $2 = auth_type (may be empty); remaining args are
#            passed through to `claude` verbatim.
# Returns claude's exit status. Never echoes/prints the token.
_cc_run_claude_with_auth() {
    local _cc_token="$1"
    local _cc_auth_type="$2"
    shift 2

    if [[ -z "$_cc_token" ]]; then
        claude "$@"
        return $?
    fi

    local _cc_var
    case "$_cc_auth_type" in
        oauth_token)      _cc_var="CLAUDE_CODE_OAUTH_TOKEN" ;;
        api_key)          _cc_var="ANTHROPIC_API_KEY" ;;
        gateway_token|"") _cc_var="ANTHROPIC_AUTH_TOKEN" ;;
        *)
            print -u2 "⚠ Unrecognized auth_type '${_cc_auth_type}' — defaulting to ANTHROPIC_AUTH_TOKEN"
            _cc_var="ANTHROPIC_AUTH_TOKEN"
            ;;
    esac

    (
        unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
        case "$_cc_var" in
            CLAUDE_CODE_OAUTH_TOKEN) CLAUDE_CODE_OAUTH_TOKEN="$_cc_token" claude "$@" ;;
            ANTHROPIC_API_KEY)       ANTHROPIC_API_KEY="$_cc_token" claude "$@" ;;
            ANTHROPIC_AUTH_TOKEN)    ANTHROPIC_AUTH_TOKEN="$_cc_token" claude "$@" ;;
            *)
                # XACA-0977-014: unreachable today (the case above always
                # assigns one of the three names above via its own *) arm),
                # but a fail-open shape regardless — an unmatched value here
                # would previously run NOTHING, hit the end of the case with
                # no injection and no claude invocation, and the subshell
                # would exit 0, letting `ccc` proceed straight to
                # _cc_save_session / the map record / kb-clear as if a real
                # session had run. Mirror the outer case's loud style, but
                # fail instead of silently defaulting: this arm means the two
                # cases have desynced, which is a bug in this function, not a
                # recoverable credential state.
                print -u2 "✗ Internal error: _cc_run_claude_with_auth got an unrecognized injection variable '${_cc_var}' — refusing to launch claude with no credential binding"
                exit 1
                ;;
        esac
    )
}

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1312 fix round 3 (bot review, PR #957, finding 022): core-completeness
# gate. A truncated/mid-parse-error source of this file (an interrupted
# upgrade copy, a syntax error) can define an EARLY function like
# _cc_route_prepare without ever reaching a LATER one like
# _cc_run_claude_with_auth. A consumer that only checked "does
# _cc_route_prepare exist" treated that half-loaded state as "core fully
# loaded", resolved a real token via _cc_route_prepare, then handed it to
# the consumer's own fallback shim for the function that never got defined
# -- silently dropping the token and launching on the machine login while
# the banner/recorder still claimed the team account (round-2 finding).
#
# _cc_routing_core_complete is the ONE completeness gate every consumer
# (cc-aliases.sh, kb-cr.sh) must use instead of checking any single
# function's presence. It is deliberately declared at the very end of this
# file, after every function the core defines, and paired with the
# sentinel below: a truncated/broken source can fail to reach this point at
# all, in which case `command -v _cc_routing_core_complete` itself already
# reports "not loaded" without needing to be called. Consumers must
# therefore always gate as:
#     if command -v _cc_routing_core_complete >/dev/null 2>&1 && _cc_routing_core_complete; then
# never a bare `command -v` on one function.
typeset -ga _CC_ROUTING_CORE_REQUIRED_FUNCS=(
    _cc_route_prepare
    _cc_run_claude_with_auth
    _cc_record_session_account
    _cc_resume_account_guard
)
_cc_routing_core_complete() {
    [[ "${_CC_ROUTING_CORE_COMPLETE:-0}" == "1" ]] || return 1
    local _cc_req_fn
    for _cc_req_fn in "${_CC_ROUTING_CORE_REQUIRED_FUNCS[@]}"; do
        command -v "$_cc_req_fn" >/dev/null 2>&1 || return 1
    done
    return 0
}
# Sentinel: set ONLY if every statement above this line in the file parsed
# and ran. A truncated file (e.g. `head -n <N>` mid-function, or a syntax
# error partway through) never reaches this assignment, so
# _cc_routing_core_complete's first check already fails fail-closed even in
# the (should-be-impossible) case where every individual `command -v` above
# happened to pass anyway. Belt and braces, not redundancy.
typeset -g _CC_ROUTING_CORE_COMPLETE=1
