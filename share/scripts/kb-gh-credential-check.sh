#!/usr/bin/env bash
# kb-gh-credential-check.sh — detect gh credentials stored in the clear.
#
# XACA-1073-006. When the macOS login keychain cannot be used (for example
# -25308 errSecInteractionNotAllowed), `gh auth login` silently falls back to
# writing the token as a plaintext `oauth_token:` key in hosts.yml. That went
# unnoticed on a FileVault-off machine holding a broad-scope gho_ token. This
# script makes that condition DETECTED and REPORTED instead of silent.
#
# WHAT IT CHECKS (all local; no network unless --scopes is given)
#   1. hosts.yml in the gh config dir, resolved the way gh does:
#        $GH_CONFIG_DIR > $XDG_CONFIG_HOME/gh > $HOME/.config/gh
#      A non-empty `oauth_token:` under any host  -> PLAINTEXT finding.
#      A gho_/ghp_ token                          -> BROAD finding (extra).
#   2. GH_TOKEN / GITHUB_TOKEN / GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN
#      set and non-empty in the environment      -> ENV-TOKEN finding.
#   3. ~/.git-credentials (or $XDG_CONFIG_HOME/git/credentials) mentioning
#      github.com                                -> GIT-CREDENTIALS finding.
#      Also every store file named by an effective git credential.helper (global,
#      URL-scoped, absolute-path git-credential-store, `!` shell helper; XACA-1745).
#      Helpers are resolved by git and classified against an allowlist; a helper
#      form not positively recognised is UNKNOWN, never OK.
#
# NEVER PRINTS A TOKEN. Only the host name, a fixed type label derived from the
# token prefix (gho_ / ghp_ / github_pat_ / other), and set/exists booleans are
# ever emitted. The awk parser emits labels, never a substring of the value.
#
# FAILS CLOSED. An unreadable hosts.yml, or one whose structure this parser is
# not sure about, is UNKNOWN (exit 2), never OK. "No hosts.yml and no gh at all"
# is N-A (exit 0) and says so explicitly.
#
# EXIT CODES
#   0  OK or N-A   nothing found (the output states which, and why)
#   1  PROBLEM     at least one confirmed finding (PLAINTEXT/BROAD/ENV-TOKEN/
#                  GIT-CREDENTIALS)
#   2  UNKNOWN     no confirmed finding, but something could not be checked
#                  (unreadable file, unparseable hosts.yml, --scopes timeout)
#   64 usage error
#
# USAGE
#   scripts/kb-gh-credential-check.sh [--json] [--scopes] [--help]
#     --json    machine-readable output (same exit codes)
#     --scopes  also run `gh auth status` (NETWORK; hard timeout, default 5s,
#               $KB_GH_CRED_SCOPES_TIMEOUT) and report token scopes. A timeout
#               or failure is UNKNOWN, never a pass.
#
# NEVER REMEDIATES. A human decides: rotate the token, move it to a keychain
# that works, or enable disk encryption. See XACA-1073.
#
# bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.

set -u

JSON=0
SCOPES=0
for arg in "$@"; do
    case "$arg" in
        --json) JSON=1 ;;
        --scopes) SCOPES=1 ;;
        -h|--help)
            sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "kb-gh-credential-check: unknown argument: $arg" >&2; exit 64 ;;
    esac
done

HOME_DIR="${HOME:-}"
if [ -n "${GH_CONFIG_DIR:-}" ]; then
    CONFIG_DIR="$GH_CONFIG_DIR"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    CONFIG_DIR="$XDG_CONFIG_HOME/gh"
else
    CONFIG_DIR="$HOME_DIR/.config/gh"
fi
HOSTS_FILE="$CONFIG_DIR/hosts.yml"
# HOME unset/empty AND no override means the real config dir is unknowable:
# "/.config/gh" is a guess, and an absent guess must never read as OK.
NO_BASE=0
if [ -z "${GH_CONFIG_DIR:-}" ] && [ -z "${XDG_CONFIG_HOME:-}" ] && [ -z "$HOME_DIR" ]; then
    NO_BASE=1
fi
TAB="$(printf '\t')"

# Entries are tab-separated "CODE<TAB>HOST<TAB>DETAIL" lines, one list per class.
FINDINGS=""   # confirmed problems
UNKNOWNS=""   # could-not-check items
NOTES=""      # informational (OK / N-A explanations)
add() { # class code host detail
    local line
    line="$2${TAB}$3${TAB}$4"
    case "$1" in
        F) FINDINGS="${FINDINGS}${line}"$'\n' ;;
        U) UNKNOWNS="${UNKNOWNS}${line}"$'\n' ;;
        N) NOTES="${NOTES}${line}"$'\n' ;;
    esac
}

HAVE_GH=0
command -v gh >/dev/null 2>&1 && HAVE_GH=1

# --- path_state: distinguish ABSENT from "could not stat" ---------------------
# `[ -e p ]` is false for BOTH a missing path and one whose parent directory is
# not searchable (EACCES) or is not a directory (ENOTDIR). Reading either as
# "absent" is a fail-open. PRESENT / ABSENT / UNKNOWN: ABSENT is claimed only
# when the deepest existing ancestor is a searchable directory, which is the
# one case where a failed lookup can only mean ENOENT.
path_state() {
    local p="$1" par
    if [ -e "$p" ] || [ -L "$p" ]; then echo PRESENT; return; fi
    par="$(dirname -- "$p")"
    if [ -d "$par" ]; then
        if [ -x "$par" ]; then echo ABSENT; else echo UNKNOWN; fi
        return
    fi
    if [ -e "$par" ] || [ -L "$par" ] || [ "$par" = "$p" ]; then echo UNKNOWN; return; fi
    case "$(path_state "$par")" in
        ABSENT) echo ABSENT ;;
        *) echo UNKNOWN ;;
    esac
}

# --- 1. hosts.yml ------------------------------------------------------------
# awk emits ONLY: "TOKEN<TAB>host<TAB>label<TAB>broad(0|1)" or "UNSURE<TAB>reason".
# `label` is chosen from a fixed set by prefix; no byte of the value is output.
#
# ALLOWLIST PARSER. gh writes exactly: a top-level `host:` line, then indented
# `key: value` lines (and nested `users:` / `<name>:` mapping keys). Inside a
# host block every line must match that shape; ANY line the parser does not
# positively understand (quoted/escaped keys, sequences, flow collections,
# continuation lines, block scalars, tabs, ...) is UNSURE, never skipped. This
# replaces a denylist that kept missing new YAML spellings of the same value.
parse_hosts() {
    LC_ALL=C awk '
    function clean_host(h) { gsub(/["\047]/, "", h); gsub(/[^A-Za-z0-9._:-]/, "?", h); return h }
    function classify(v) {
        if (v ~ /^gho_/)             { label = "gho_ (OAuth token)"; broad = 1 }
        else if (v ~ /^ghp_/)        { label = "ghp_ (classic PAT)"; broad = 1 }
        else if (v ~ /^github_pat_/) { label = "github_pat_ (fine-grained PAT)"; broad = 0 }
        else if (v ~ /^gh[usr]_/)    { label = "ghu_/ghs_/ghr_ (app/server token)"; broad = 0 }
        else                         { label = "unrecognized prefix"; broad = 0 }
    }
    function unsure(r) { print "UNSURE\t" r }
    BEGIN { host = ""; content = 0; hosts = 0; pend = 0; pend_ind = 0 }
    { sub(/\r$/, "") }   # CRLF files: strip the CR before any pattern sees the line
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    /^(---|\.\.\.)[ \t]*$/ { pend = 0; next }
    {
        content++
        line = $0
        if (line ~ /^[^ ]/) {
            pend = 0
            if (line ~ /^[^ \t:#][^:]*:[ \t]*(#.*)?$/) {
                h = line; sub(/:[ \t]*(#.*)?$/, "", h)
                host = clean_host(h); hosts++
                if (host == "oauth_token") { unsure("top-level key named oauth_token"); host = "" }
                next
            }
            unsure("unexpected top-level line")
            next
        }
        if (host == "") { unsure("indented content outside any host entry"); next }
        ind = match(line, /[^ ]/) - 1
        if (pend && ind > pend_ind) { pend = 0; unsure("oauth_token value on a continuation line"); next }
        pend = 0
        if (line !~ /^ +[A-Za-z0-9_.-]+:( .*)?$/) { unsure("line is not a plain key: value form"); next }
        key = line; sub(/^ +/, "", key); sub(/:.*$/, "", key)
        key_of_line = key
        v = line; sub(/^ +[A-Za-z0-9_.-]+:/, "", v); sub(/^ +/, "", v)
        # The gh multi-account keyring layout writes `users:` / `  <name>: {}`
        # (XACA-1073-020). An EMPTY flow mapping holds no scalar, so it cannot
        # carry a token; accept exactly `{}` (optional trailing comment) for any
        # key other than oauth_token. Non-empty flow collections stay UNSURE.
        if (key_of_line != "oauth_token" && v ~ /^\{[ ]*\}[ \t]*(#.*)?$/) next
        if (v ~ /^[|>[{]/) { unsure("block scalar or flow collection value"); next }
        if (key != "oauth_token") next
        # ---- oauth_token value forms
        q = substr(v, 1, 1)
        if (q == "\"" || q == "\047") {
            rest = substr(v, 2); i = index(rest, q)
            if (i == 0) { unsure("unterminated quoted oauth_token"); next }
            inner = substr(rest, 1, i - 1); tail = substr(rest, i + 1)
            if (tail !~ /^[ ]*(#.*)?$/) { unsure("trailing content after quoted oauth_token"); next }
            if (q == "\"" && inner ~ /\\/) { unsure("escape sequence in quoted oauth_token"); next }
            if (inner == "") next
            classify(inner)
            print "TOKEN\t" host "\t" label "\t" broad
            next
        }
        if (v ~ /^#/) v = ""
        else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
        if (v ~ /^[&*!%@`?:-]/ && v != "") { unsure("unsupported YAML value form for oauth_token"); next }
        if (v == "") { pend = 1; pend_ind = ind; next }
        if (v == "null" || v == "Null" || v == "NULL" || v == "~") next
        classify(v)
        print "TOKEN\t" host "\t" label "\t" broad
    }
    END { if (content > 0 && hosts == 0) unsure("no host entries recognised") }
    ' "$1" 2>/dev/null
}

HOSTS_STATE="UNKNOWN"
[ "$NO_BASE" -eq 1 ] || HOSTS_STATE="$(path_state "$HOSTS_FILE")"
if [ "$NO_BASE" -eq 1 ]; then
    add U HOSTS-UNLOCATABLE "-" "HOME, GH_CONFIG_DIR and XDG_CONFIG_HOME are all unset; cannot locate the gh config dir, so cannot confirm there is no plaintext token"
elif [ "$HOSTS_STATE" = "UNKNOWN" ]; then
    add U HOSTS-UNSTATABLE "-" "cannot stat $HOSTS_FILE (parent not searchable or not a directory); cannot confirm there is no plaintext token"
elif [ "$HOSTS_STATE" = "PRESENT" ]; then
    if [ ! -f "$HOSTS_FILE" ] || [ ! -r "$HOSTS_FILE" ]; then
        add U HOSTS-UNREADABLE "-" "$HOSTS_FILE exists but is not a readable file; cannot confirm there is no plaintext token"
    else
        PARSED="$(parse_hosts "$HOSTS_FILE")"
        PRC=$?
        if [ "$PRC" -ne 0 ]; then
            add U HOSTS-UNPARSEABLE "-" "parser failed on $HOSTS_FILE"
        else
            TOKEN_SEEN=0
            while IFS="$TAB" read -r kind a b c; do
                case "$kind" in
                    TOKEN)
                        TOKEN_SEEN=1
                        add F PLAINTEXT "$a" "oauth_token stored in plaintext in hosts.yml; type $b"
                        if [ "$c" = "1" ]; then
                            add F BROAD "$a" "$b is a broad-scope token (OAuth/classic PAT)"
                        fi
                        ;;
                    UNSURE)
                        add U HOSTS-UNPARSEABLE "-" "$a in $HOSTS_FILE; cannot confirm there is no plaintext token"
                        ;;
                esac
            done <<EOF
$PARSED
EOF
            if [ "$TOKEN_SEEN" -eq 0 ] && [ -z "$UNKNOWNS" ]; then
                add N HOSTS-OK "-" "hosts.yml present, no oauth_token key found (token, if any, is in the keyring)"
            fi
        fi
    fi
else
    if [ "$HAVE_GH" -eq 1 ]; then
        add N HOSTS-ABSENT "-" "gh is installed but $HOSTS_FILE does not exist: no plaintext token on disk"
    else
        add N NOT-APPLICABLE "-" "N-A: gh is not installed and $HOSTS_FILE does not exist"
    fi
fi

# --- 2. environment tokens (set/unset only; value never reaches output) ------
for var in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        add F ENV-TOKEN "-" "$var is set in the environment"
    fi
done
val=""

# --- 3. git credential store -------------------------------------------------
CRED_SEEN="|"
check_cred_file() { # path
    local gc="$1" st rc
    case "$CRED_SEEN" in *"|$gc|"*) return ;; esac
    CRED_SEEN="${CRED_SEEN}${gc}|"
    st="$(path_state "$gc")"
    case "$st" in
        ABSENT) return ;;
        UNKNOWN)
            add U GIT-CREDENTIALS-UNSTATABLE "-" "cannot stat $gc (parent not searchable or not a directory); cannot confirm it has no github.com entry"
            return ;;
    esac
    if [ ! -f "$gc" ] || [ ! -r "$gc" ]; then
        add U GIT-CREDENTIALS-UNREADABLE "-" "$gc exists but is not readable; cannot confirm it has no github.com entry"
        return
    fi
    grep -qi 'github\.com' "$gc" 2>/dev/null; rc=$?
    case "$rc" in
        0) add F GIT-CREDENTIALS "github.com" "$gc contains a github.com entry (plaintext credential store)" ;;
        1) ;;
        *) add U GIT-CREDENTIALS-UNREADABLE "-" "grep failed on $gc; cannot confirm it has no github.com entry" ;;
    esac
}

# --- git credential.helper resolution + allowlist (XACA-1745) -----------------
# A store helper can be configured in more ways than the default paths and a
# global `store --file=<p>`: URL-scoped (`[credential "https://github.com"]`), an
# absolute path to git-credential-store, or a `!` shell helper. Instead of
# hand-parsing config files, git resolves the list and an ALLOWLIST classifies
# each value; anything not positively understood is UNKNOWN (rc 2), never OK.
#
# RESOLUTION (git's own semantics, measured against git 2.56):
#   * `git config --get-urlmatch credential.helper <url>` is LAST-WINS (it returns
#     one value), but git's credential code builds a LIST: every matching
#     `credential.helper` and `credential.<url>.helper` is appended in config
#     order, and an EMPTY value resets the list. So the list comes from
#     `git config -z --get-regexp` (config order, all scopes), and
#     --get-urlmatch is used ONLY as git's own "does this scope match" oracle,
#     run against a one-entry scratch config. A scope that does not match but
#     names github.com anywhere (user@host, path-scoped) is still kept: over-
#     reporting is the safe direction. Only the empty-value reset of an
#     APPLICABLE entry clears the list.
#   * A helper VALUE is never printed (an inline `!` helper can embed a token);
#     findings name only the ordinal of the helper.
CRED_HELPERS=()

# scope_applies <subsection> [strict] -> 0 when helpers under credential.<subsection>
# can apply to https://github.com. 2 = could not decide (scratch file failed).
# Default mode OVER-reports: any scope naming github.com anywhere counts, so extra
# helpers stay in view. STRICT mode (used for empty-value RESETS) trusts only git's
# own scope match (--get-urlmatch), because a reset that git does not apply must
# not clear the list. Measured against git 2.56 with `git credential fill`: a blank
# helper under https://gist.github.com, https://someone@github.com (URL with no
# user), https://notgithub.com, https://github.com.evil.example or
# https://ghe.example.com/github.com does NOT clear a global helper for
# https://github.com, while https://*.com, https://github.com:443 and
# https://GitHub.COM do. (A bare `github.com` scope also resets in git but is not
# a URL for --get-urlmatch; it is left un-reset here, the over-reporting side.)
scope_applies() {
    local sub="$1" strict="${2:-}" f lc
    if [ -z "$strict" ]; then
        lc="$(printf '%s' "$sub" | tr '[:upper:]' '[:lower:]')"
        case "$lc" in *github.com*) return 0 ;; esac
    fi
    f="$(mktemp 2>/dev/null)" || return 2
    git config --file "$f" "credential.$sub.helper" x >/dev/null 2>&1 || { rm -f "$f"; return 2; }
    git config --file "$f" --get-urlmatch credential.helper https://github.com >/dev/null 2>&1
    local rc=$?
    rm -f "$f"
    case "$rc" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

# resolve_cred_helpers -> fills CRED_HELPERS (effective list, reset applied).
# Returns 0 ok, 1 could not resolve (UNKNOWN already recorded).
resolve_cred_helpers() {
    local out grc rec key val sub app
    CRED_HELPERS=()
    out="$(mktemp 2>/dev/null)" || {
        add U GIT-CONFIG-UNREADABLE "-" "could not create temp file to read git credential.helper settings; cannot confirm there is no custom credential store"
        return 1
    }
    git config -z --get-regexp '^credential\.(.+\.)?helper$' >"$out" 2>/dev/null
    grc=$?
    case "$grc" in
        0) ;;
        1) rm -f "$out"; return 0 ;;
        *)
            rm -f "$out"
            add U GIT-CONFIG-UNREADABLE "-" "git config exited $grc; cannot confirm there is no custom credential store file"
            return 1 ;;
    esac
    while IFS= read -r -d '' rec; do
        case "$rec" in
            *$'\n'*) key="${rec%%$'\n'*}"; val="${rec#*$'\n'}" ;;
            *) add U GIT-HELPER-UNKNOWN "-" "a credential.helper entry has no value; cannot classify it"; continue ;;
        esac
        key="${key#credential.}"
        if [ "$key" = "helper" ]; then
            app=0
        else
            sub="${key%.helper}"
            # A reset must match git's own scope test; a non-empty helper only needs
            # to plausibly apply (over-report).
            if [ -z "$val" ]; then scope_applies "$sub" strict; app=$?; else scope_applies "$sub"; app=$?; fi
            case "$app" in
                1) continue ;;
                2) add U GIT-CONFIG-UNREADABLE "-" "could not test whether a URL-scoped credential.helper applies to github.com; cannot confirm there is no custom credential store"
                   continue ;;
            esac
        fi
        if [ -z "$val" ]; then
            CRED_HELPERS=()      # git: an empty helper resets the list
        else
            CRED_HELPERS[${#CRED_HELPERS[@]}]="$val"
        fi
    done <"$out"
    rm -f "$out"
    return 0
}

# classify_helper <value> -> sets CLS = SAFE | STORE | UNRESOLVED | UNKNOWN
# (STORE: CLS_PATH is the explicit --file path or "" for the default stores;
#  UNRESOLVED: CLS_WHY says why the store cannot be located.)
# ALLOWLIST. known-safe: osxkeychain, manager, manager-core, cache, and `gh auth
# git-credential` (bare via `!`, or by absolute path). known-store: store,
# git-credential-store, or an absolute path ending in git-credential-store, with
# only --file[=]<p> arguments, optionally behind a `!`. Everything else: UNKNOWN.
classify_helper() {
    local v="$1" bang=0 w nextfile=0 p="" first rest sepword=0 quoted=0
    CLS=UNKNOWN; CLS_PATH=""; CLS_WHY=""
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in '!'*) bang=1; v="${v#!}"; v="${v#"${v%%[![:space:]]*}"}" ;; esac
    if [ "$bang" -eq 0 ]; then
        case "$v" in
            osxkeychain|manager|manager-core|cache) CLS=SAFE; return ;;
        esac
        if [[ "$v" =~ ^/([A-Za-z0-9._+@/-]*/)?git-credential-osxkeychain$ ]]; then CLS=SAFE; return; fi
        if [[ "$v" =~ ^cache\ --timeout(=|\ )[0-9]+$ ]]; then CLS=SAFE; return; fi
        if [[ "$v" =~ ^/([A-Za-z0-9._+@/-]*/)?gh\ auth\ git-credential$ ]]; then CLS=SAFE; return; fi
    else
        if [[ "$v" =~ ^(/[A-Za-z0-9._+@/-]*/)?gh\ auth\ git-credential$ ]]; then CLS=SAFE; return; fi
    fi
    set -f
    # shellcheck disable=SC2086  # deliberate word-splitting, globbing disabled
    set -- $v
    set +f
    first="${1:-}"
    # `!git credential-store ...` is the same helper spelled as a shell command.
    if [ "$bang" -eq 1 ] && [ "$first" = git ] && [ "${2:-}" = credential-store ]; then
        shift; first="git-credential-store"; set -- "$first" "${@:2}"
    fi
    case "$first" in
        store) [ "$bang" -eq 0 ] || return ;;
        git-credential-store) ;;
        /*/git-credential-store) ;;
        *) return ;;
    esac
    # From here the value is a store helper; any form we cannot resolve is UNRESOLVED.
    case "$v" in
        *'$'*|*'`'*) CLS=UNRESOLVED; CLS_WHY="a credential store helper path needs shell expansion; cannot locate the store"; return ;;
        *\;*|*\|*|*\&*|*\<*|*\>*|*\(*|*\)*|*\{*|*\}*|*\\*) return ;;
    esac
    shift
    for w in "$@"; do
        if [ "$nextfile" -eq 1 ]; then p="$w"; nextfile=0; sepword=1; continue; fi
        case "$w" in
            --file=*) p="${w#--file=}"; sepword=0 ;;
            --file) nextfile=1 ;;
            *) return ;;   # an argument git-credential-store does not take
        esac
    done
    if [ "$nextfile" -eq 1 ]; then
        CLS=UNRESOLVED; CLS_WHY="credential store helper has --file with no path; cannot locate the store"; return
    fi
    case "$p" in
        \'*\'|\"*\") [ "${#p}" -ge 2 ] && { p="${p#?}"; p="${p%?}"; quoted=1; } ;;
        \'*|\"*|*\'*|*\"*)
            CLS=UNRESOLVED; CLS_WHY="credential store --file path is quoted in a form this check cannot resolve"; return ;;
    esac
    # git runs the helper through sh -c (measured, git 2.56):
    #  * an UNQUOTED separate-word path is glob-expanded (* ? [) and can find a real
    #    file this check would look for literally -> UNRESOLVED. An attached
    #    --file=<p> word is never globbed (the pattern would need a directory named
    #    "--file=" in git's cwd) and a quoted path is literal, so those stay literal.
    #  * ~ is expanded only by an unquoted separate word. An attached --file=~/x or a
    #    quoted "~/x" reaches git as a literal relative path (./~/x) -> UNRESOLVED.
    #  * brace expansion does not happen under sh (and { } already fail closed above).
    if [ "$sepword" -eq 1 ] && [ "$quoted" -eq 0 ]; then
        case "$p" in
            *'*'*|*'?'*|*'['*)
                CLS=UNRESOLVED; CLS_WHY="credential store --file path contains a shell glob character (*, ?, [) that sh expands; cannot locate the store"; return ;;
        esac
    fi
    case "$p" in
        "~"|"~"/*)
            if [ "$sepword" -eq 0 ] || [ "$quoted" -eq 1 ]; then
                CLS=UNRESOLVED; CLS_WHY="credential store --file=~ is not tilde-expanded by sh (attached or quoted), so git reads a path relative to its working directory; cannot locate the store"; return
            fi ;;
    esac
    case "$p" in
        "") ;;
        "~"/*)
            if [ -z "$HOME_DIR" ]; then
                CLS=UNRESOLVED; CLS_WHY="credential store --file uses ~ but HOME is unset"; return
            fi
            p="$HOME_DIR/${p#\~/}" ;;
        /*) ;;
        *) CLS=UNRESOLVED; CLS_WHY="credential store --file path is relative or uses ~user; cannot locate the store"; return ;;
    esac
    CLS=STORE; CLS_PATH="$p"
}

if [ -z "$HOME_DIR" ]; then
    # Without HOME the default store locations are unknowable; probing under / would
    # report a clean result about a path nobody uses.
    add U GIT-CREDENTIALS-UNLOCATABLE "-" "HOME is unset; cannot locate the git credential store, so cannot confirm there is no github.com entry"
else
    check_cred_file "$HOME_DIR/.git-credentials"
fi
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    check_cred_file "$XDG_CONFIG_HOME/git/credentials"
elif [ -n "$HOME_DIR" ]; then
    check_cred_file "$HOME_DIR/.config/git/credentials"
fi
if command -v git >/dev/null 2>&1; then
    if resolve_cred_helpers; then
        hi=0
        while [ "$hi" -lt "${#CRED_HELPERS[@]}" ]; do
            classify_helper "${CRED_HELPERS[$hi]}"
            hi=$((hi + 1))
            case "$CLS" in
                SAFE) ;;
                STORE) [ -z "$CLS_PATH" ] || check_cred_file "$CLS_PATH" ;;
                UNRESOLVED) add U GIT-HELPER-UNRESOLVED "-" "credential.helper #$hi: $CLS_WHY" ;;
                *) add U GIT-HELPER-UNKNOWN "-" "credential.helper #$hi is not a form this check recognises (value not shown); cannot confirm it does not write a plaintext store" ;;
            esac
        done
    fi
else
    add U GIT-CONFIG-UNREADABLE "-" "git is not installed; cannot read credential.helper, so cannot confirm there is no custom credential store"
fi

# --- 4. optional scopes (network, bounded) -----------------------------------
if [ "$SCOPES" -eq 1 ]; then
    if [ "$HAVE_GH" -ne 1 ]; then
        add U SCOPES-UNKNOWN "-" "--scopes requested but gh is not installed"
    else
        TMPF="$(mktemp 2>/dev/null)" || TMPF=""
        if [ -z "$TMPF" ]; then
            add U SCOPES-UNKNOWN "-" "could not create temp file for gh auth status"
        else
            gh auth status >"$TMPF" 2>&1 </dev/null &
            GPID=$!
            LIMIT="${KB_GH_CRED_SCOPES_TIMEOUT:-5}"
            n=0; max=$((LIMIT * 10))
            while kill -0 "$GPID" 2>/dev/null && [ "$n" -lt "$max" ]; do
                sleep 0.1; n=$((n + 1))
            done
            if kill -0 "$GPID" 2>/dev/null; then
                kill "$GPID" 2>/dev/null; wait "$GPID" 2>/dev/null
                add U SCOPES-UNKNOWN "-" "gh auth status timed out after ${LIMIT}s"
            else
                wait "$GPID" 2>/dev/null
                # Only the "Token scopes:" line is kept; it lists scope names, not secrets.
                SCOPES_LINE="$(grep -i 'token scopes' "$TMPF" | head -n 1 | sed 's/^[ -]*//' | tr -cd "A-Za-z0-9_:,. '-")"
                if [ -z "$SCOPES_LINE" ]; then
                    add U SCOPES-UNKNOWN "-" "gh auth status gave no token-scopes line"
                else
                    add N SCOPES "-" "$SCOPES_LINE"
                fi
            fi
            rm -f "$TMPF"
        fi
    fi
fi

# --- verdict -----------------------------------------------------------------
if [ -n "$FINDINGS" ]; then
    STATUS="PROBLEM"; RC=1
elif [ -n "$UNKNOWNS" ]; then
    STATUS="UNKNOWN"; RC=2
else
    STATUS="OK"; RC=0
    case "$NOTES" in *NOT-APPLICABLE*) STATUS="N-A" ;; esac
fi

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
emit_json_list() { # lines
    local first=1 code host detail
    printf '['
    while IFS="$TAB" read -r code host detail; do
        [ -z "$code" ] && continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"code":"%s","host":"%s","detail":"%s"}' "$code" "$(json_str "$host")" "$(json_str "$detail")"
    done <<EOF
$1
EOF
    printf ']'
}
print_list() { # label lines
    local code host detail
    while IFS="$TAB" read -r code host detail; do
        [ -z "$code" ] && continue
        if [ "$host" = "-" ]; then
            printf '  %s %s: %s\n' "$1" "$code" "$detail"
        else
            printf '  %s %s host=%s: %s\n' "$1" "$code" "$host" "$detail"
        fi
    done <<EOF
$2
EOF
}

if [ "$JSON" -eq 1 ]; then
    printf '{"status":"%s","exit_code":%d,"config_dir":"%s","hosts_file":"%s","findings":' \
        "$STATUS" "$RC" "$(json_str "$CONFIG_DIR")" "$(json_str "$HOSTS_FILE")"
    emit_json_list "$FINDINGS"
    printf ',"unknown":'
    emit_json_list "$UNKNOWNS"
    printf ',"notes":'
    emit_json_list "$NOTES"
    printf '}\n'
else
    echo "gh credential check: $STATUS"
    echo "  config dir: $CONFIG_DIR"
    print_list "FOUND  " "$FINDINGS"
    print_list "UNKNOWN" "$UNKNOWNS"
    print_list "note   " "$NOTES"
fi
exit "$RC"
