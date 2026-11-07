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

# A `credential.helper = store --file=<path>` names an arbitrary store file.
scan_helper() { # one credential.helper value
    local w nextfile=0 p="" found=0
    set -f
    # shellcheck disable=SC2086  # deliberate word-splitting, globbing disabled
    set -- $1
    set +f
    case "${1:-}" in
        store|git-credential-store) ;;
        *) return ;;
    esac
    shift
    for w in "$@"; do
        if [ "$nextfile" -eq 1 ]; then p="$w"; found=1; nextfile=0; continue; fi
        case "$w" in
            --file=*) p="${w#--file=}"; found=1 ;;
            --file) nextfile=1 ;;
        esac
    done
    if [ "$nextfile" -eq 1 ]; then
        add U GIT-HELPER-UNRESOLVED "-" "credential.helper store has --file with no path; cannot locate the store"
        return
    fi
    [ "$found" -eq 1 ] || return
    case "$p" in
        \'*\'|\"*\") p="${p#?}"; p="${p%?}" ;;
        \'*|\"*)
            add U GIT-HELPER-UNRESOLVED "-" "credential.helper store --file path is quoted in a form this check cannot resolve"
            return ;;
    esac
    case "$p" in
        *'$'*|*'`'*|"")
            add U GIT-HELPER-UNRESOLVED "-" "credential.helper store --file path needs shell expansion; cannot locate the store"
            return ;;
        "~"/*)
            if [ -z "$HOME_DIR" ]; then
                add U GIT-HELPER-UNRESOLVED "-" "credential.helper store --file uses ~ but HOME is unset"
                return
            fi
            p="$HOME_DIR/${p#\~/}" ;;
    esac
    check_cred_file "$p"
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
    HELPERS="$(git config --get-all credential.helper 2>/dev/null)"
    GRC=$?
    case "$GRC" in
        0)
            while IFS= read -r hline; do
                [ -n "$hline" ] && scan_helper "$hline"
            done <<EOF
$HELPERS
EOF
            ;;
        1) ;;
        *) add U GIT-CONFIG-UNREADABLE "-" "git config exited $GRC; cannot confirm there is no custom credential store file" ;;
    esac
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
