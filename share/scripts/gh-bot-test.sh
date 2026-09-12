#!/usr/bin/env bash
# gh-bot-test.sh — post test/build results to a PR as the ds9-tester-bot GitHub App.
#
# WHY A SEPARATE BOT: every agent authors PRs as the same account (ehlersd), and
# GitHub will not let an account review its own PR. Two App identities keep the
# roles legible on the PR timeline — ai-security-review-bot renders a code-review
# verdict, ds9-tester-bot reports what was actually executed.
#
# WHY THIS IS A SEPARATE FILE FROM gh-bot-review.sh, and must stay one:
# SCOPE IS SET BY THE APP'S PERMISSIONS, not by preference. Measured from
# `gh api /apps/ds9-tester-bot`:
#     {"metadata":"read","pull_requests":"write"}
# Note what is ABSENT and what that rules out:
#   - no `checks: write`   -> it CANNOT create check runs. Do not add a code path
#                             that tries; it will 403. Check runs come from CI
#                             (.github/workflows/), which is the right producer.
#   - no `contents: read`  -> it CANNOT read the repo through the API. It reports
#                             results computed locally; it does not inspect code.
# The review bot holds a DIFFERENT App id and a DIFFERENT permission set. Merging
# the two scripts behind a --bot flag, or hoisting the identity handling into a
# shared sourced library, would put one code path in charge of both credentials
# and both entitlements — one mistake there mis-signs or over-permits BOTH bots.
# Both post through the same endpoint (pulls/{n}/reviews) and differ only in
# identity and in what they are entitled to say. The duplication is deliberate.
#
# XACA-1160: this is the CANONICAL copy (dev-team/scripts/). It is mirrored to
# homebrew-tap/share/scripts/ by sync-tap.sh. Patch THIS file — a tap-side edit
# without a matching canonical commit reverts on the next forward sync.
#
# Dependencies: curl, openssl, python3. Nothing else — no Node.js, no jq, no gh.
# Portability: must parse and run under stock macOS /bin/bash 3.2 AND under a
# newer PATH bash. No bash-4-only constructs: no associative arrays, no
# case-converting parameter expansions, no read-into-array builtin, no combined
# append-redirect operator.
#
# SECRETS: no key material lives in this file. The App private key is resolved at
# runtime from ~/.config/gh-tester-bot/ (mode 0600) and is never printed. That
# 0600 is now CHECKED, not merely documented — a group/other-readable key warns
# on stderr (see warn_if_key_mode_open). Credentials are never passed as curl
# argv either; every Authorization header goes through a 0600 temp file.
#
# Usage:
#   gh-bot-test --pr <N> --run                       # run local verification, post it
#   gh-bot-test --pr <N> --body "..."                # post a result you already have
#   gh-bot-test --pr <N> --body-file results.md
#   gh-bot-test --list-installations
#   [--repo owner/name] [--event COMMENT|APPROVE|REQUEST_CHANGES]

set -euo pipefail

CONFIG_DIR="${HOME}/.config/gh-tester-bot"
KEY_ENV_VAR="GH_BOT_TEST_KEY"

# Test seam, NOT a user-facing option (deliberately absent from --help). Every
# request below is built from this variable so a harness can point the whole
# script at a stub server; one request left on a hardcoded host would let a test
# pass green while the real code path went unexercised.
GH_API_BASE="${GH_BOT_API_BASE:-https://api.github.com}"

# Candidate key filenames, most specific first. There is NO single correct
# default: measured 2026-09-09, this fleet carries ds9-tester-bot.pem on one box
# and private-key.pem on another, so a hardcoded default is wrong somewhere by
# construction. Resolution order is in resolve_key_file() below.
KEY_CANDIDATES="private-key.pem
ds9-tester-bot.pem
gh-tester-bot.pem
gh-bot-test.pem
app.pem
key.pem"

# Installation is resolved per-repo AFTER the JWT is minted (see below), because a
# GitHub App has a SEPARATE installation id per org. Hardcoding one (this used to
# default to 112748921 = DoubleNode) silently mints a token scoped to the wrong org
# the moment you post to a repo in another org — it fails as a 404, which reads like
# a missing PR rather than a scoping problem.
# Set GH_BOT_TEST_INSTALLATION_ID to pin one explicitly; empty means auto-resolve.
INSTALLATION_ID="${GH_BOT_TEST_INSTALLATION_ID:-}"

APP_ID=""
KEY_FILE=""
PR=""; BODY=""; BODY_FILE=""; REPO=""; EVENT="COMMENT"; DO_RUN=false
LIST_INSTALLATIONS=false

die() { echo "gh-bot-test: $*" >&2; exit 1; }

# ── Temp files: credentials NEVER go in the process argument list ────────────
# `ps` exposes every process's full argv to every local user, so passing an
# installation token or an App JWT as `-H "Authorization: ..."` publishes that
# credential for the life of the request (CWE-214). Every credential-bearing
# header is written to a mode-0600 temp file instead and read back with
# `curl -H @file`, which keeps it out of argv entirely.
#
# ONE trap owns ALL of them — including the --run log directory. A second
# `trap ... EXIT` REPLACES the first, so per-site traps silently leak whichever
# file was registered earlier, and a leaked header file is a leaked credential.
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
    # --run's log directory, when there was one.
    if [ -n "${tmp:-}" ]; then
        rm -r -f "$tmp"
    fi
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
    NEW_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/gh-bot-test.XXXXXX")" || {
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
# WARN rather than refuse, deliberately: this script IS gate 1 of the three-gate
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
        echo "gh-bot-test: WARNING: App private key is group/other readable (mode $mode):"
        echo "    $KEY_FILE"
        echo "  Anyone who can read that path can sign as ds9-tester-bot."
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
gh-bot-test.sh — post test/build results to a PR as the ds9-tester-bot GitHub App.

Usage:
  gh-bot-test --pr <N> --run                     # run local verification, post it
  gh-bot-test --pr <N> --body "..."              # post a result you already have
  gh-bot-test --pr <N> --body-file results.md
  gh-bot-test --list-installations
  gh-bot-test --help

Options:
  --pr <N>              Pull request number (required to post).
  --run                 Run this repo's own verification (Debug build, Release
                        build, swiftlint --strict) and post the summary. Requires
                        an .xcodeproj in the working directory; it reports what
                        ran, it does not judge. Cannot be combined with
                        --body/--body-file.
  --body <text>         Result body.
  --body-file <path>    Result body read from a file. Prefer this for long bodies.
  --repo <owner/name>   Target repository. Derived from the "origin" remote when
                        omitted — note that a repo whose remote is NOT named
                        "origin" (dev-team names its remote "dev-team") will fail
                        that autodetect, so pass --repo there.
  --event <EVENT>       COMMENT (default) | APPROVE | REQUEST_CHANGES. The default
                        is COMMENT so a green test run never silently satisfies a
                        required approval — approving is the reviewer's job.
  --list-installations  List every org this App is installed on, with installation
                        ids, permissions and events. Walks ALL pages.
  -h, --help            This text. Works without a key present.

Exit codes:
  0  posted successfully
  1  usage error, configuration error, or GitHub rejected the post
  2  posted successfully, but --run verification FAILED

Environment overrides:
  GH_BOT_TEST_KEY              Absolute authority for the private key path.
                               Set-but-missing is a hard error, never a silent
                               fallback to another candidate.
  GH_BOT_TEST_APP_ID           Override the App id.
  GH_BOT_TEST_INSTALLATION_ID  Pin an installation id; empty = auto-resolve
                               per-repo via GET /repos/{owner}/{repo}/installation.

Config:
  ~/.config/gh-tester-bot/config.json may declare {"appId": N, "privateKeyPath": "..."}.
  Both are honoured, below the env vars and above the filename candidates.

Requires: curl, openssl, python3.
USAGE
}

# ── Read a field from config.json, if there is one ──────────────────────────
# config.json is the SAME file the retired Node implementation read, and it is
# where an operator has already recorded which key file this box uses. Honouring
# it means a machine that is correctly configured for the old bot is correctly
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
    if [ -n "${GH_BOT_TEST_KEY:-}" ]; then
        if [ ! -f "$GH_BOT_TEST_KEY" ]; then
            die "$KEY_ENV_VAR is set but there is no file at that path:
    $GH_BOT_TEST_KEY
  Fix the variable, or unset it to fall back to $CONFIG_DIR."
        fi
        accept_key_file "$GH_BOT_TEST_KEY"
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

    die "no App private key found for ds9-tester-bot.
  Looked in $CONFIG_DIR for:
$(printf '%s' "$KEY_CANDIDATES" | sed "s|^|    $CONFIG_DIR/|")
  and for any single *.pem / *.key file there.
  To produce one: GitHub App settings for ds9-tester-bot ->
  Private keys -> Generate a private key, then
    mkdir -p '$CONFIG_DIR'
    mv ~/Downloads/ds9-tester-bot.*.private-key.pem '$CONFIG_DIR/ds9-tester-bot.pem'
    chmod 600 '$CONFIG_DIR/ds9-tester-bot.pem'
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
        --body)               [ $# -ge 2 ] || die "--body requires a value (the result text)"
                              BODY="$2"; shift 2 ;;
        --body-file)          [ $# -ge 2 ] || die "--body-file requires a value (a path to the result text)"
                              BODY_FILE="$2"; shift 2 ;;
        --repo)               [ $# -ge 2 ] || die "--repo requires a value (owner/name)"
                              REPO="$2"; shift 2 ;;
        --event)              [ $# -ge 2 ] || die "--event requires a value (COMMENT, APPROVE or REQUEST_CHANGES)"
                              EVENT="$2"; shift 2 ;;
        --run)                DO_RUN=true; shift ;;
        --list-installations) LIST_INSTALLATIONS=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    die "unknown argument: $1" ;;
    esac
done

# App id: env override, then config.json, then the built-in default.
APP_ID="${GH_BOT_TEST_APP_ID:-}"
if [ -z "$APP_ID" ]; then
    APP_ID="$(read_config_field appId)"
fi
[ -n "$APP_ID" ] || APP_ID="2960558"

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
# GET /app/installations pages at 30. The retired Node implementation called it
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

# ── Validate arguments ──────────────────────────────────────────────────────
[ -n "$PR" ] || die "--pr is required"
case "$EVENT" in
    COMMENT|APPROVE|REQUEST_CHANGES) ;;
    *) die "invalid --event '$EVENT' (expected COMMENT, APPROVE or REQUEST_CHANGES)" ;;
esac

# ── Optionally run the repo's verification and build the report ─────────────
if [ "$DO_RUN" = true ]; then
    if [ -n "$BODY" ] || [ -n "$BODY_FILE" ]; then
        die "--run cannot be combined with --body/--body-file"
    fi

    # Glob directly rather than parsing ls: an unmatched glob stays literal and
    # the -d test rejects it, so this needs no 2>/dev/null and no word splitting.
    PROJECT=""
    for xcodeproj in ./*.xcodeproj; do
        [ -d "$xcodeproj" ] || continue
        PROJECT="$xcodeproj"
        break
    done
    [ -n "$PROJECT" ] || die "no .xcodeproj in $(pwd) — run from the repo root, or
  pass --body/--body-file with results you produced yourself. --run only knows how
  to drive an Xcode project; every other stack reports through --body-file."
    SCHEME="$(basename "$PROJECT" .xcodeproj)"

    # A machine whose xcode-select points at CommandLineTools has no xcodebuild
    # AND no sourcekitd, so swiftlint dies too. Surface that as a setup error
    # rather than reporting it to the PR as a test failure.
    if ! xcodebuild -version >/dev/null 2>&1; then
        die "xcodebuild unavailable. Point DEVELOPER_DIR at an Xcode install, e.g.
  export DEVELOPER_DIR=\"/Applications/Xcode.app/Contents/Developer\"
(quote it — the path may contain a space)."
    fi

    # No per-site trap: cleanup_tmp_files (registered at the top) already removes
    # $tmp. A trap here would REPLACE that one and leak every credential header
    # file registered before it.
    tmp="$(mktemp -d)"
    LINES=()
    overall="passed"

    run_step() {                    # run_step <label> <cmd...>
        local label="$1"; shift
        local slug
        local log
        slug="$(echo "$label" | tr -c 'A-Za-z0-9' '_')"
        log="$tmp/$slug.log"
        # Capture the real exit status: $? after a pipe is the LAST command's.
        if "$@" >"$log" 2>&1; then
            LINES[${#LINES[@]}]="| $label | pass |"
        else
            LINES[${#LINES[@]}]="| $label | **fail** |"
            overall="failed"
            # shellcheck disable=SC2016
            # SC2016 fires on the backticks in the markdown fence below. They are
            # literal markdown, not command substitution, and MUST NOT be expanded.
            printf '\n<details><summary>%s — last 30 lines</summary>\n\n```\n%s\n```\n</details>\n' \
                "$label" "$(tail -30 "$log")" >> "$tmp/details.md"
        fi
    }

    echo "running verification for $SCHEME ..." >&2
    for cfg in Debug Release; do
        run_step "Build ($cfg)" xcodebuild build \
            -project "$PROJECT" -scheme "$SCHEME" \
            -destination 'generic/platform=iOS Simulator' \
            -configuration "$cfg" \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    done
    if command -v swiftlint >/dev/null 2>&1; then
        run_step "SwiftLint (--strict)" swiftlint lint --strict
    else
        LINES[${#LINES[@]}]="| SwiftLint | not installed — skipped |"
    fi

    {
        if [ "$overall" = "passed" ]; then
            echo "### Local verification passed"
        else
            echo "### Local verification FAILED"
        fi
        echo
        echo "| Step | Result |"
        echo "|------|--------|"
        # Guarded rather than bare "${LINES[@]}": under set -u, bash 3.2 treats an
        # empty array expansion as an unbound variable and aborts.
        if [ "${#LINES[@]}" -gt 0 ]; then
            printf '%s\n' "${LINES[@]}"
        fi
        echo
        echo "_Run on \`$(hostname -s)\` · $(xcodebuild -version 2>/dev/null | tr '\n' ' ')_"
        if [ -f "$tmp/details.md" ]; then
            cat "$tmp/details.md"
        fi
        echo
        echo "<sub>Posted by \`ds9-tester-bot\`. This reports what ran locally; it is not a code review.</sub>"
    } > "$tmp/body.md"

    BODY_FILE="$tmp/body.md"
fi

if [ -n "$BODY_FILE" ]; then
    [ -f "$BODY_FILE" ] || die "--body-file not found: $BODY_FILE"
    BODY="$(cat "$BODY_FILE")"
fi
[ -n "$BODY" ] || die "nothing to post — pass --run, --body or --body-file"

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
        -H @"$jwt_header_file" -H "Accept: application/vnd.github+json" \
        "${GH_API_BASE}/repos/${REPO}/installation" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id") or "")')"

    [ -n "$INSTALLATION_ID" ] || die "APP_ID=$APP_ID is not installed on ${REPO%%/*}.
  Install the app on that org/user, or pin an installation with GH_BOT_TEST_INSTALLATION_ID=<id>.
  Run 'gh-bot-test --list-installations' to see every org it IS installed on."
fi

token="$(curl -sS -X POST \
    -H @"$jwt_header_file" -H "Accept: application/vnd.github+json" \
    "${GH_API_BASE}/app/installations/${INSTALLATION_ID}/access_tokens" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token") or "")')"
[ -n "$token" ] || die "could not obtain an installation token.
  Check APP_ID=$APP_ID and INSTALLATION_ID=$INSTALLATION_ID match the key in $KEY_FILE."

# ── Post ───────────────────────────────────────────────────────────────────
# Both the payload file and the --run log directory are cleaned by the single
# cleanup_tmp_files trap registered at the top of this script.
new_tmp_file
payload_file="$NEW_TMP_FILE"
python3 -c 'import json,sys; json.dump({"event":sys.argv[1],"body":sys.argv[2]}, open(sys.argv[3],"w"))' \
    "$EVENT" "$BODY" "$payload_file"

# Installation token in a 0600 file, not in argv.
auth_header_file "token ${token}"
token_header_file="$AUTH_HEADER_FILE"

response="$(curl -sS -w '\n%{http_code}' -X POST \
    -H @"$token_header_file" -H "Accept: application/vnd.github+json" \
    "${GH_API_BASE}/repos/${REPO}/pulls/${PR}/reviews" -d @"$payload_file")"

status="$(printf '%s' "$response" | tail -n1)"
body_out="$(printf '%s' "$response" | sed '$d')"

if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    # Plain %-formatting, not an f-string: escaped double quotes inside an
    # f-string expression arrive at Python as \" and raise SyntaxError — after
    # the post has already succeeded, which reads as a failure that never was.
    printf '%s' "$body_out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
who = (d.get("user") or {}).get("login", "?")
print("OK posted as %s -> %s" % (who, d.get("html_url", "?")))
'
    # Exit non-zero when the run itself failed, so callers and CI can branch on it
    # even though the post to GitHub succeeded.
    if [ "$DO_RUN" = true ] && [ "${overall:-passed}" = "failed" ]; then
        echo "gh-bot-test: verification FAILED (result posted)" >&2
        exit 2
    fi
else
    echo "gh-bot-test: GitHub returned HTTP $status" >&2
    printf '%s\n' "$body_out" >&2
    exit 1
fi
