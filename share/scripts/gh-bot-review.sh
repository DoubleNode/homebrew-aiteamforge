#!/usr/bin/env bash
# gh-bot-review.sh — submit a PR review as the ai-security-review-bot GitHub App.
#
# WHY THIS EXISTS: every agent authors PRs under the same GitHub account
# (ehlersd), and GitHub refuses to let an account approve its own PR. Submitting
# the review as a GitHub App gives a distinct reviewer identity, which is what
# makes gate 2 of the three-gate merge flow possible at all.
#
# WHY IT IS A SEPARATE FILE FROM gh-bot-test.sh, and must stay one:
# these are two DIFFERENT GitHub Apps with two different permission sets, two
# config directories, two env-var prefixes and two App ids. Collapsing them into
# one script behind a --bot flag, or factoring the identity handling into a
# shared sourced library, would put one code path in charge of two credentials
# and two entitlements — a mistake in it mis-signs or over-permits BOTH bots at
# once. The duplication below is deliberate and is the cheaper failure mode.
#
# XACA-1160: this is the CANONICAL copy (dev-team/scripts/). It is mirrored to
# homebrew-tap/share/scripts/ by sync-tap.sh. Patch THIS file — a tap-side edit
# without a matching canonical commit reverts on the next forward sync.
#
# Dependencies: curl, openssl, python3. Nothing else — no node, no jq, no gh.
# Portability: must parse and run under stock macOS /bin/bash 3.2 AND under a
# newer PATH bash. No bash-4-only constructs: no associative arrays, no
# case-converting parameter expansions, no read-into-array builtin, no combined
# append-redirect operator.
#
# SECRETS: no key material lives in this file. The App private key is resolved at
# runtime from ~/.config/gh-review-bot/ (mode 0600) and is never printed. That
# 0600 is now CHECKED, not merely documented — a group/other-readable key warns
# on stderr (see warn_if_key_mode_open). Credentials are never passed as curl
# argv either; every Authorization header goes through a 0600 temp file.
#
# Usage:
#   gh-bot-review --pr <N> --event APPROVE|REQUEST_CHANGES|COMMENT \
#                 (--body "text" | --body-file <path>) [--repo owner/name]
#   gh-bot-review --list-installations
#   gh-bot-review --help

set -euo pipefail

CONFIG_DIR="${HOME}/.config/gh-review-bot"
KEY_ENV_VAR="GH_BOT_REVIEW_KEY"

# Test seam, NOT a user-facing option (deliberately absent from --help). Every
# request below is built from this variable so a harness can point the whole
# script at a stub server; one request left on a hardcoded host would let a test
# pass green while the real code path went unexercised.
GH_API_BASE="${GH_BOT_API_BASE:-https://api.github.com}"

# Candidate key filenames, most specific first. There is NO single correct
# default: measured 2026-09-09, this fleet carries private-key.pem on one box and
# a bot-named .pem on another, so a hardcoded default is wrong somewhere by
# construction. Resolution order is in resolve_key_file() below.
KEY_CANDIDATES="private-key.pem
ai-security-review-bot.pem
gh-review-bot.pem
gh-bot-review.pem
app.pem
key.pem"

# Installation is resolved per-repo AFTER the JWT is minted (see below), because a
# GitHub App has a SEPARATE installation id per org. Hardcoding one (this used to
# default to 109498232 = DoubleNode) silently mints a token scoped to the wrong org
# the moment you review a repo in another org — it fails as a 404, which reads like
# a missing PR rather than a scoping problem.
# Set GH_BOT_REVIEW_INSTALLATION_ID to pin one explicitly; empty means auto-resolve.
INSTALLATION_ID="${GH_BOT_REVIEW_INSTALLATION_ID:-}"

APP_ID=""
KEY_FILE=""
PR=""; EVENT=""; BODY=""; BODY_FILE=""; REPO=""; LIST_INSTALLATIONS=false

die() { echo "gh-bot-review: $*" >&2; exit 1; }

# ── Temp files: credentials NEVER go in the process argument list ────────────
# `ps` exposes every process's full argv to every local user, so passing an
# installation token or an App JWT as `-H "Authorization: ..."` publishes that
# credential for the life of the request (CWE-214). Every credential-bearing
# header is written to a mode-0600 temp file instead and read back with
# `curl -H @file`, which keeps it out of argv entirely.
#
# ONE trap owns ALL of them. A second `trap ... EXIT` REPLACES the first, so
# per-site traps silently leak whichever file was registered earlier — and a
# leaked header file is a leaked credential, not just a stray temp file.
TMP_FILES=""
NEW_TMP_FILE=""
AUTH_HEADER_FILE=""

cleanup_tmp_files() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f"
    done <<CLEANUP_LIST
$TMP_FILES
CLEANUP_LIST
    return 0
}
trap cleanup_tmp_files EXIT
trap 'cleanup_tmp_files; exit 130' INT TERM

# new_tmp_file — create a 0600 temp file and report it in $NEW_TMP_FILE.
# It deliberately does NOT print the path: a command substitution would run this
# in a subshell, the registration below would die with that subshell, and the
# file would never be cleaned up.
new_tmp_file() {
    local old_umask
    old_umask="$(umask)"
    umask 077
    NEW_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/gh-bot-review.XXXXXX")" || {
        umask "$old_umask"
        die "could not create a temp file under ${TMPDIR:-/tmp}"
    }
    umask "$old_umask"
    # Belt and braces: mktemp already creates 0600, but an inherited umask is not
    # the only way a mode can go wrong, and this file holds a live credential.
    chmod 600 "$NEW_TMP_FILE" 2>/dev/null || true
    TMP_FILES="${TMP_FILES}${NEW_TMP_FILE}
"
}

# auth_header_file <header-value> — sets $AUTH_HEADER_FILE to a 0600 file holding
# "Authorization: <value>", to be passed as `curl -H @"$AUTH_HEADER_FILE"`.
auth_header_file() {
    new_tmp_file
    AUTH_HEADER_FILE="$NEW_TMP_FILE"
    printf 'Authorization: %s\n' "$1" > "$AUTH_HEADER_FILE"
}

# ── Key-file permissions: WARN, never refuse ─────────────────────────
# The help text above tells operators to chmod 600 the key, and nothing ever
# checked — so a 0644 key reads as correctly configured right up until someone
# else on the box signs as this App. Report it.
#
# WARN rather than refuse, deliberately: this script IS gate 2 of the three-gate
# merge flow, so a hard failure here would break every currently-working
# consumer at the worst possible moment, over a condition that was tolerated
# yesterday. The warning names the file and the exact remedy, and goes to stderr
# so anything parsing stdout is unaffected.
warn_if_key_mode_open() {
    local mode=""
    [ -n "${KEY_FILE:-}" ] || return 0
    mode="$(python3 -c '
import os, sys
try:
    mode = os.stat(sys.argv[1]).st_mode & 0o777
except OSError:
    sys.exit(0)
if mode & 0o077:
    print("%04o" % mode)
' "$KEY_FILE" 2>/dev/null || true)"
    [ -n "$mode" ] || return 0
    {
        echo "gh-bot-review: WARNING: App private key is group/other readable (mode $mode):"
        echo "    $KEY_FILE"
        echo "  Anyone who can read that path can sign as ai-security-review-bot."
        echo "  Fix it with:  chmod 600 '$KEY_FILE'"
        echo "  Continuing anyway — this is a warning, not a refusal."
    } >&2
    return 0
}

# accept_key_file <path> — EVERY successful resolution funnels through here, so
# a future resolution branch cannot bypass the permission check by forgetting it.
accept_key_file() {
    KEY_FILE="$1"
    warn_if_key_mode_open
}

usage() {
    cat <<'USAGE'
gh-bot-review.sh — submit a PR review as the ai-security-review-bot GitHub App.

Usage:
  gh-bot-review --pr <N> --event APPROVE|REQUEST_CHANGES|COMMENT \
                (--body "text" | --body-file <path>) [--repo owner/name]
  gh-bot-review --list-installations
  gh-bot-review --help

Options:
  --pr <N>              Pull request number (required to submit a review).
  --event <EVENT>       APPROVE | REQUEST_CHANGES | COMMENT (required to submit).
                        GitHub rejects REQUEST_CHANGES and COMMENT with an empty body.
  --body <text>         Review body.
  --body-file <path>    Review body read from a file. Prefer this for long bodies.
  --repo <owner/name>   Target repository. Derived from the "origin" remote when
                        omitted — note that a repo whose remote is NOT named
                        "origin" (dev-team names its remote "dev-team") will fail
                        that autodetect, so pass --repo there.
  --list-installations  List every org this App is installed on, with installation
                        ids, permissions and events. Walks ALL pages.
  -h, --help            This text. Works without a key present.

Environment overrides:
  GH_BOT_REVIEW_KEY              Absolute authority for the private key path.
                                 Set-but-missing is a hard error, never a silent
                                 fallback to another candidate.
  GH_BOT_REVIEW_APP_ID           Override the App id.
  GH_BOT_REVIEW_INSTALLATION_ID  Pin an installation id; empty = auto-resolve
                                 per-repo via GET /repos/{owner}/{repo}/installation.

Config:
  ~/.config/gh-review-bot/config.json may declare {"appId": N, "privateKeyPath": "..."}.
  Both are honoured, below the env vars and above the filename candidates.

Requires: curl, openssl, python3.
USAGE
}

# ── Read a field from config.json, if there is one ──────────────────────────
# config.json is the SAME file the retired node implementation read, and it is
# where an operator has already recorded which key file this box uses. Honouring
# it means a machine that is correctly configured for the node bot is correctly
# configured for this one, with no migration step. It ranks BELOW the env vars
# (an explicit override must win) and ABOVE filename guessing (a declaration
# beats a guess). A leading ~ is expanded; a declared-but-absent path is not
# fatal on its own, but it IS named in the failure message if nothing else
# resolves, so a typo there cannot hide.
read_config_field() {
    [ -f "$CONFIG_DIR/config.json" ] || return 0
    python3 -c '
import json, sys, os
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)
value = data.get(sys.argv[2])
if value is None:
    sys.exit(0)
value = str(value)
if value.startswith("~"):
    value = os.path.expanduser(value)
print(value)
' "$CONFIG_DIR/config.json" "$1" 2>/dev/null || true
}

# ── Resolve the App private key without assuming one filename ───────────────
resolve_key_file() {
    local cfg_path=""
    local cfg_note=""
    local found=""
    local count=0
    local candidate=""

    # 1. Env var: absolute authority. If it is set but the file is not there we
    #    fail NAMING THAT PATH. Falling through to a candidate would sign with a
    #    key the operator did not ask for and surface later as an opaque 401 from
    #    GitHub, pointing at everything except the actual mistake.
    if [ -n "${GH_BOT_REVIEW_KEY:-}" ]; then
        if [ ! -f "$GH_BOT_REVIEW_KEY" ]; then
            die "$KEY_ENV_VAR is set but there is no file at that path:
    $GH_BOT_REVIEW_KEY
  Fix the variable, or unset it to fall back to $CONFIG_DIR."
        fi
        accept_key_file "$GH_BOT_REVIEW_KEY"
        return 0
    fi

    # 2. config.json privateKeyPath.
    cfg_path="$(read_config_field privateKeyPath)"
    if [ -n "$cfg_path" ]; then
        if [ -f "$cfg_path" ]; then
            accept_key_file "$cfg_path"
            return 0
        fi
        cfg_note="
  NOTE: $CONFIG_DIR/config.json declares privateKeyPath
    $cfg_path
  but no file is there. Fix that path, or remove the field."
    fi

    # 3. Known candidate filenames in the config dir.
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if [ -f "$CONFIG_DIR/$candidate" ]; then
            found="${found}${CONFIG_DIR}/${candidate}
"
            count=$((count + 1))
        fi
    done <<CANDIDATES
$KEY_CANDIDATES
CANDIDATES

    # 4. Nothing named as expected — accept exactly one key-looking file.
    if [ "$count" -eq 0 ]; then
        for candidate in "$CONFIG_DIR"/*.pem "$CONFIG_DIR"/*.key; do
            [ -f "$candidate" ] || continue
            found="${found}${candidate}
"
            count=$((count + 1))
        done
    fi

    if [ "$count" -eq 1 ]; then
        accept_key_file "$(printf '%s' "$found" | head -1)"
        return 0
    fi

    if [ "$count" -gt 1 ]; then
        # Never silently pick one. Two keys in the directory means two Apps, or a
        # rotation that was never finished; guessing signs as the wrong identity.
        die "found $count candidate private keys in $CONFIG_DIR and cannot choose between them:
$(printf '%s' "$found" | sed 's/^/    /')
  Say which one to use:
    export $KEY_ENV_VAR=<path>
  or record it in $CONFIG_DIR/config.json as privateKeyPath.$cfg_note"
    fi

    die "no App private key found for ai-security-review-bot.
  Looked in $CONFIG_DIR for:
$(printf '%s' "$KEY_CANDIDATES" | sed "s|^|    $CONFIG_DIR/|")
  and for any single *.pem / *.key file there.
  To produce one: GitHub App settings for ai-security-review-bot ->
  Private keys -> Generate a private key, then
    mkdir -p '$CONFIG_DIR'
    mv ~/Downloads/ai-security-review-bot.*.private-key.pem '$CONFIG_DIR/private-key.pem'
    chmod 600 '$CONFIG_DIR/private-key.pem'
  Or point $KEY_ENV_VAR at a key you already have.$cfg_note"
}

# ── Parse arguments ─────────────────────────────────────────────────────────
# A value-taking flag given WITHOUT its value used to die silently: `shift 2`
# with one argument left fails, and `set -e` aborts the script with no message
# and no detail. A truncated automation command ending in `--body-file`
# therefore printed NOTHING AT ALL, which is unattributable — the caller cannot
# tell a usage mistake from a crash from a network failure. Each arm below
# checks for its value first and names the flag that is missing one.
while [ $# -gt 0 ]; do
    case "$1" in
        --pr)                 [ $# -ge 2 ] || die "--pr requires a value (the pull request number)"
                              PR="$2"; shift 2 ;;
        --event)              [ $# -ge 2 ] || die "--event requires a value (APPROVE, REQUEST_CHANGES or COMMENT)"
                              EVENT="$2"; shift 2 ;;
        --body)               [ $# -ge 2 ] || die "--body requires a value (the review text)"
                              BODY="$2"; shift 2 ;;
        --body-file)          [ $# -ge 2 ] || die "--body-file requires a value (a path to the review text)"
                              BODY_FILE="$2"; shift 2 ;;
        --repo)               [ $# -ge 2 ] || die "--repo requires a value (owner/name)"
                              REPO="$2"; shift 2 ;;
        --list-installations) LIST_INSTALLATIONS=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "unknown argument: $1" ;;
    esac
done

# App id: env override, then config.json, then the built-in default.
APP_ID="${GH_BOT_REVIEW_APP_ID:-}"
if [ -z "$APP_ID" ]; then
    APP_ID="$(read_config_field appId)"
fi
[ -n "$APP_ID" ] || APP_ID="2844584"

# ── JWT minting (RS256) ─────────────────────────────────────────────────────
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_jwt() {
    local now header payload signing_input signature
    now="$(date +%s)"
    header='{"alg":"RS256","typ":"JWT"}'
    # iat backdated 60s to tolerate clock skew. GitHub caps exp-iat at 600s and
    # rejects anything over, so we sit at 540s rather than exactly on the limit —
    # landing on the boundary fails if GitHub's clock rounds the other way.
    payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 480))" "$APP_ID")"
    signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
    signature="$(printf '%s' "$signing_input" \
        | openssl dgst -sha256 -sign "$KEY_FILE" -binary \
        | b64url)" || die "failed to sign JWT — is $KEY_FILE a valid RSA private key?"
    printf '%s.%s' "$signing_input" "$signature"
}

# ── --list-installations: EVERY page, or it must not print at all ───────────
# GET /app/installations pages at 30. The retired node implementation called it
# with no pagination at all and printed data.forEach(...), so past 30 installations
# it rendered a TRUNCATED list with no indication it was truncated — a listing that
# quietly omits the org you are looking for is worse than no listing, because it
# reads as proof of absence. This subcommand is what made the original XACA-1160
# diagnosis possible, so it must never lie about completeness.
#
# per_page=100 alone is NOT the fix: it moves the cliff to 101, it does not remove
# it. Termination is decided ONLY by the Link rel="next" header — a full page with
# no next link ends the walk, and a short page WITH a next link does not.
list_installations() {
    local jwt jwt_hdr hdr url page_out parsed n total

    jwt="$(mint_jwt)"
    # The JWT goes in a 0600 file, not in argv (see the temp-file block above).
    auth_header_file "Bearer ${jwt}"
    jwt_hdr="$AUTH_HEADER_FILE"
    new_tmp_file
    hdr="$NEW_TMP_FILE"

    url="${GH_API_BASE}/app/installations?per_page=100"
    total=0

    echo "GitHub App installations (APP_ID=$APP_ID)"
    echo "========================================="

    while [ -n "$url" ]; do
        : > "$hdr"
        page_out="$(curl -sS -D "$hdr" \
            -H @"$jwt_hdr" \
            -H "Accept: application/vnd.github+json" \
            "$url")" || die "request failed: $url"

        # First line of stdout is the entry count for this page; the rest is the
        # rendered listing. Errors go to stderr and exit non-zero, so a failed
        # page can never be mistaken for an empty one.
        parsed="$(printf '%s' "$page_out" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("could not parse the API response as JSON\n")
    sys.exit(1)
if isinstance(data, dict):
    sys.stderr.write("GitHub API error: %s\n" % data.get("message", "unexpected object response"))
    sys.exit(1)
out = ["%d" % len(data)]
for inst in data:
    account = inst.get("account") or {}
    perms = inst.get("permissions") or {}
    events = inst.get("events") or []
    rendered = ", ".join(["%s:%s" % (k, v) for k, v in sorted(perms.items())])
    out.append("  Account:         %s (%s)" % (account.get("login", "?"), account.get("type", "?")))
    out.append("  Installation ID: %s" % inst.get("id", "?"))
    out.append("  Permissions:     %s" % (rendered or "none"))
    out.append("  Events:          %s" % (", ".join(events) or "none"))
    out.append("  ---")
sys.stdout.write("\n".join(out) + "\n")
')" || die "could not read the installation list from GitHub."

        n="$(printf '%s\n' "$parsed" | head -1)"
        printf '%s\n' "$parsed" | tail -n +2
        total=$((total + n))

        # Authoritative next-page pointer. A missing Link header, or a Link header
        # with no rel="next", is the ONLY thing that ends the walk.
        url="$(tr -d '\r' < "$hdr" \
            | grep -i '^link:' \
            | tr ',' '\n' \
            | sed -n 's/.*<\([^>]*\)>; *rel="next".*/\1/p' \
            | head -1 || true)"
    done

    echo "Total installations: $total (all pages walked)"
}

if [ "$LIST_INSTALLATIONS" = true ]; then
    resolve_key_file
    list_installations
    exit 0
fi

# ── Validate review arguments ───────────────────────────────────────────────
[ -n "$PR" ]    || die "--pr is required"
[ -n "$EVENT" ] || die "--event is required (APPROVE | REQUEST_CHANGES | COMMENT)"
case "$EVENT" in
    APPROVE|REQUEST_CHANGES|COMMENT) ;;
    *) die "invalid --event '$EVENT' (expected APPROVE, REQUEST_CHANGES or COMMENT)" ;;
esac

if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || die "--body-file not found: $BODY_FILE"
    BODY="$(cat "$BODY_FILE")"
fi
# GitHub rejects REQUEST_CHANGES and COMMENT with an empty body.
if [ -z "$BODY" ] && [ "$EVENT" != "APPROVE" ]; then
    die "--body or --body-file is required for $EVENT"
fi

# Derive owner/repo from the current git remote unless told otherwise.
if [ -z "$REPO" ]; then
    origin="$(git remote get-url origin 2>/dev/null || true)"
    [ -n "$origin" ] || die "not in a git repo with an 'origin' remote; pass --repo owner/name"
    REPO="$(printf '%s' "$origin" \
        | sed -E 's#^git@github\.com:#|#; s#^https?://[^/]*/#|#' \
        | sed -E 's#^\|##; s#\.git$##')"
    case "$REPO" in
        */*) ;;
        *) die "could not parse owner/repo from origin: $origin" ;;
    esac
fi

resolve_key_file
jwt="$(mint_jwt)"
# The JWT goes in a 0600 file, not in argv (see the temp-file block above).
auth_header_file "Bearer ${jwt}"
jwt_header_file="$AUTH_HEADER_FILE"

# ── Resolve which installation covers this repo ─────────────────────────────
# One API call answers it exactly (GET /repos/{owner}/{repo}/installation), which
# beats enumerating /app/installations and matching by org name. Skipped when the
# caller pinned one via the env var above.
if [ -z "$INSTALLATION_ID" ]; then
    INSTALLATION_ID="$(curl -sS \
        -H @"$jwt_header_file" \
        -H "Accept: application/vnd.github+json" \
        "${GH_API_BASE}/repos/${REPO}/installation" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or "")')"

    [ -n "$INSTALLATION_ID" ] || die "APP_ID=$APP_ID is not installed on ${REPO%%/*}.
  Install the app on that org/user, or pin an installation with GH_BOT_REVIEW_INSTALLATION_ID=<id>.
  Run 'gh-bot-review --list-installations' to see every org it IS installed on."
fi

token="$(curl -sS -X POST \
    -H @"$jwt_header_file" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API_BASE}/app/installations/${INSTALLATION_ID}/access_tokens" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or "")')"

[ -n "$token" ] || die "could not obtain an installation token.
  Check that APP_ID=$APP_ID and INSTALLATION_ID=$INSTALLATION_ID match the key in $KEY_FILE."

# ── Submit the review ───────────────────────────────────────────────────────
# Body is passed via a file to avoid any shell quoting/expansion of its content.
new_tmp_file
payload_file="$NEW_TMP_FILE"
python3 -c '
import json,sys
json.dump({"event": sys.argv[1], "body": sys.argv[2]}, open(sys.argv[3], "w"))
' "$EVENT" "$BODY" "$payload_file"

# Installation token in a 0600 file, not in argv.
auth_header_file "token ${token}"
token_header_file="$AUTH_HEADER_FILE"

response="$(curl -sS -w '\n%{http_code}' -X POST \
    -H @"$token_header_file" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API_BASE}/repos/${REPO}/pulls/${PR}/reviews" \
    -d @"$payload_file")"

status="$(printf '%s' "$response" | tail -n1)"
body_out="$(printf '%s' "$response" | sed '$d')"

if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    # NOTE: do not use escaped double quotes inside an f-string expression here.
    # Inside this single-quoted shell string they reach Python literally as \" and
    # raise SyntaxError — which fires AFTER the review has already posted, so it
    # looks like a failed submission when the submission actually succeeded.
    printf '%s' "$body_out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
state = d.get("state", "?")
url = d.get("html_url", "?")
who = (d.get("user") or {}).get("login", "?")
print("OK %s on %s" % (state, url))
print("  reviewer: %s" % who)
'
else
    echo "gh-bot-review: GitHub returned HTTP $status" >&2
    printf '%s\n' "$body_out" >&2
    exit 1
fi
