#!/usr/bin/env bash
# ci-runner-version.sh - actions/runner version lifecycle on enabled CI hosts (XACA-1443-014).
#
# SOURCEABLE LIBRARY. Sourcing defines functions only: no output, no `exit`, no change to the caller's `set`
# options. Two halves with different privileges:
#
#   WRITER half (ROOT, provision-host.sh only): ci_runner_resolve, ci_runner_verify_file. This is the ONLY code
#   in the CI bundle that asks GitHub which runner is newest. It sends NO credential (no Authorization header,
#   no token): the releases API is public. Nothing else in this file runs curl, gh, sudo, launchctl or limactl.
#
#   READER half (a plain user, no sudo, no network): ci_runner_skew_check (called by ci_provision_skew),
#   ci_runner_assess and ci_status_runner_probe (the XACA-1443-004 hook). They read the provision manifest (root
#   owned, world readable) and runner-pin.conf from the keg. They cannot see inside ci-runner's 700 home (the
#   cached tarballs), so the staged version is judged from the manifest record, not from the disk.
#
# THE POLICY (full reasoning and sources: kanban/plans/XACA-1443/XACA-1443-014_runner_lifecycle.md)
#   * GitHub stops queuing jobs to a runner that is more than 30 days behind the newest release, and refuses to
#     register one below 2.329.0. JIT one-job runners cannot be started with self-update disabled (the setting
#     lives in the server-generated JIT config), so a stale runner does not fail, it self-updates at the worst
#     moment (the job message is skipped while the update downloads). The robust approach is therefore to PRE-STAGE
#     the newest verified tarball: the JIT launch scripts extract the cached tarball for every job.
#   * The tarball is staged by `aiteamforge ci enable` (the printed sudo line) and re-staged by `ci refresh`.
#     There is NO new daemon: `ci status`, the doctor and the upgrade notice say when a refresh is due.
#   * FAIL CLOSED. A tarball is only ever staged if its sha256 matches a digest taken from the GitHub release
#     notes (the version being installed) or from runner-pin.conf (the keg's own pinned fallback). No digest, no
#     staging. A mismatch refuses and deletes the download.
#   * NEVER SILENT. If GitHub cannot be asked, the fallback is announced (CI_RUNNER_NOTICE), recorded in the
#     manifest as source=pinned (or source=kept when an equal or newer runner is already staged: a refresh never
#     downgrades), and `ci status` warns for as long as it stays that way.
#
# MANIFEST record (written by provision-host.sh via ci-provision-version.sh, see there):
#   R <os> <version> <sha256> <source>      os = linux-arm64|osx-arm64   source = latest|explicit|pinned|kept
#   runner_checked_at=<UTC ISO>             when GitHub last confirmed this is the newest release (not hashed)
#
# Portability: /bin/bash 3.2 and bash 5. Public names ci_runner_*, internals _cirv_*.

_CIRV_LOADING=1
_CIRV_DIR="${BASH_SOURCE[0]:-}"
case "$_CIRV_DIR" in */*) _CIRV_DIR="${_CIRV_DIR%/*}" ;; *) _CIRV_DIR="." ;; esac

# The manifest/skew library supplies _cipv_sha and the R-line loader. It sources this file back at its tail; the
# guard variable stops that from looping.
if ! type _cipv_sha >/dev/null 2>&1 && [ -r "${_CIRV_DIR}/ci-provision-version.sh" ]; then
    # shellcheck source=/dev/null
    . "${_CIRV_DIR}/ci-provision-version.sh"
fi

_cirv_hex64() { case "${1:-}" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }

# X.Y.Z with plain digits (no leading v, no pre-release): the only shape GitHub tags runners with.
ci_runner_semver_ok() {
    case "${1:-}" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    case "$1" in *[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    local IFS=. a b c rest
    # shellcheck disable=SC2034
    read -r a b c rest <<EOF_SV
$1
EOF_SV
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -z "$rest" ] || return 1
    [ "${#a}" -le 6 ] && [ "${#b}" -le 6 ] && [ "${#c}" -le 6 ]
}

# ci_runner_semver_cmp A B -> prints -1 (A<B), 0, 1 (A>B); rc 2 (no output) when either is not X.Y.Z.
ci_runner_semver_cmp() {
    ci_runner_semver_ok "${1:-}" && ci_runner_semver_ok "${2:-}" || return 2
    local IFS=. a1 a2 a3 b1 b2 b3
    read -r a1 a2 a3 <<EOF_A
$1
EOF_A
    read -r b1 b2 b3 <<EOF_B
$2
EOF_B
    a1=$((10#$a1)); a2=$((10#$a2)); a3=$((10#$a3)); b1=$((10#$b1)); b2=$((10#$b2)); b3=$((10#$b3))
    if [ "$a1" -ne "$b1" ]; then [ "$a1" -lt "$b1" ] && echo -1 || echo 1; return 0; fi
    if [ "$a2" -ne "$b2" ]; then [ "$a2" -lt "$b2" ] && echo -1 || echo 1; return 0; fi
    if [ "$a3" -ne "$b3" ]; then [ "$a3" -lt "$b3" ] && echo -1 || echo 1; return 0; fi
    echo 0
}

# key=value from a data file, first match wins, never sourced. rc 1 and no output when the file is unreadable.
_cirv_get() { [ -r "$2" ] || return 1; awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null; }

# ISO UTC `YYYY-MM-DDTHH:MM:SSZ` -> epoch seconds (pure arithmetic: BSD and GNU date disagree on parsing). rc 1 if malformed.
ci_runner_iso_epoch() {
    local s="${1:-}" y m d H M S era yoe mp doy doe days
    case "$s" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
        *) return 1 ;;
    esac
    y=$((10#${s:0:4})); m=$((10#${s:5:2})); d=$((10#${s:8:2}))
    H=$((10#${s:11:2})); M=$((10#${s:14:2})); S=$((10#${s:17:2}))
    [ "$y" -ge 1970 ] && [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 1
    [ "$H" -le 23 ] && [ "$M" -le 59 ] && [ "$S" -le 60 ] || return 1
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$((y / 400)); yoe=$((y - era * 400))
    mp=$(((m + 9) % 12)); doy=$(((153 * mp + 2) / 5 + d - 1))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    days=$((era * 146097 + doe - 719468))
    echo $((days * 86400 + H * 3600 + M * 60 + S))
}

# Seconds since the epoch; CI_RUNNER_NOW_EPOCH overrides it (tests, and nothing else: it is a read-side clock).
ci_runner_now() {
    case "${CI_RUNNER_NOW_EPOCH:-}" in ''|*[!0-9]*) date +%s ;; *) echo "$CI_RUNNER_NOW_EPOCH" ;; esac
}

# ---------------------------------------------------------------- WRITER half (root, provision-host.sh)

# GET a public GitHub URL, no credentials of any kind. Prints the body; rc != 0 on any failure.
_cirv_http_get() {
    curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' "$1" 2>/dev/null
}

# _cirv_parse_release <json> -> sets _CIRV_TAG _CIRV_SHA_L _CIRV_SHA_O (empty when absent/invalid). rc 0 only if all three are valid.
_cirv_parse_release() {
    local j="$1"
    _CIRV_TAG="$(printf '%s' "$j" | grep -o '"tag_name": *"v[0-9][0-9.]*"' | head -n 1 | sed 's/.*"v\([0-9.]*\)"/\1/')"
    _CIRV_SHA_L="$(printf '%s' "$j" | grep -o 'BEGIN SHA linux-arm64 -->[0-9a-f]*' | head -n 1 | sed 's/.*-->//')"
    _CIRV_SHA_O="$(printf '%s' "$j" | grep -o 'BEGIN SHA osx-arm64 -->[0-9a-f]*' | head -n 1 | sed 's/.*-->//')"
    ci_runner_semver_ok "$_CIRV_TAG" && _cirv_hex64 "$_CIRV_SHA_L" && _cirv_hex64 "$_CIRV_SHA_O"
}

# ci_runner_resolve <pin_file> [explicit_version] [kept_version kept_sha_linux kept_sha_osx kept_checked_at]
#   rc 0 resolved. Sets CI_RUNNER_VERSION, CI_RUNNER_SHA_LINUX, CI_RUNNER_SHA_OSX (both verified digests),
#      CI_RUNNER_SOURCE (latest|explicit|pinned|kept), CI_RUNNER_CHECKED_AT (UTC ISO the digest was confirmed by
#      GitHub or by the previous refresh; empty = now) and CI_RUNNER_NOTICE (non-empty = the caller MUST say it loudly).
#   rc 1 refused. CI_RUNNER_WHY says why. Nothing may be staged.
# Order: explicit version -> GitHub latest -> (GitHub unreachable or unparseable) the already-staged runner when it is not
# older than the pin -> the pin. The pin and the kept record are only used when their digests are valid 64-hex.
CI_RUNNER_VERSION=""; CI_RUNNER_SHA_LINUX=""; CI_RUNNER_SHA_OSX=""; CI_RUNNER_SOURCE=""; CI_RUNNER_CHECKED_AT=""
CI_RUNNER_NOTICE=""; CI_RUNNER_WHY=""
ci_runner_resolve() {
    local pin="${1:-}" explicit="${2:-}" kv="${3:-}" ksl="${4:-}" kso="${5:-}" kat="${6:-}"
    local pv="" ps_l="" ps_o="" regmin="" pin_ok=0 kept_ok=0 json why="" c
    CI_RUNNER_VERSION=""; CI_RUNNER_SHA_LINUX=""; CI_RUNNER_SHA_OSX=""; CI_RUNNER_SOURCE=""; CI_RUNNER_CHECKED_AT=""
    CI_RUNNER_NOTICE=""; CI_RUNNER_WHY=""

    pv="$(_cirv_get pin_version "$pin")" || pv=""
    ps_l="$(_cirv_get pin_sha256_linux_arm64 "$pin")" || ps_l=""
    ps_o="$(_cirv_get pin_sha256_osx_arm64 "$pin")" || ps_o=""
    regmin="$(_cirv_get registration_min "$pin")" || regmin=""
    if ci_runner_semver_ok "$pv" && _cirv_hex64 "$ps_l" && _cirv_hex64 "$ps_o"; then pin_ok=1; fi
    ci_runner_semver_ok "$regmin" || regmin=""
    if ci_runner_semver_ok "$kv" && _cirv_hex64 "$ksl" && _cirv_hex64 "$kso"; then kept_ok=1; fi

    if [ -n "$explicit" ]; then
        explicit="${explicit#v}"
        if ! ci_runner_semver_ok "$explicit"; then CI_RUNNER_WHY="RUNNER_VERSION '${explicit}' is not X.Y.Z"; return 1; fi
        if [ -n "$regmin" ]; then
            c="$(ci_runner_semver_cmp "$explicit" "$regmin")"
            if [ "$c" = "-1" ]; then CI_RUNNER_WHY="RUNNER_VERSION ${explicit} is below GitHub's registration minimum ${regmin}"; return 1; fi
        fi
        if [ "$pin_ok" = 1 ] && [ "$explicit" = "$pv" ]; then
            CI_RUNNER_SHA_LINUX="$ps_l"; CI_RUNNER_SHA_OSX="$ps_o"
        else
            if json="$(_cirv_http_get "https://api.github.com/repos/actions/runner/releases/tags/v${explicit}")" && _cirv_parse_release "$json" && [ "$_CIRV_TAG" = "$explicit" ]; then
                CI_RUNNER_SHA_LINUX="$_CIRV_SHA_L"; CI_RUNNER_SHA_OSX="$_CIRV_SHA_O"
            else
                CI_RUNNER_WHY="RUNNER_VERSION ${explicit}: could not read its published sha256 values from GitHub, and it is not the keg's pin (${pv:-none}); refusing to stage an unverifiable runner"
                return 1
            fi
        fi
        CI_RUNNER_VERSION="$explicit"; CI_RUNNER_SOURCE="explicit"
        return 0
    fi

    if json="$(_cirv_http_get "https://api.github.com/repos/actions/runner/releases/latest")" && _cirv_parse_release "$json"; then
        CI_RUNNER_VERSION="$_CIRV_TAG"; CI_RUNNER_SHA_LINUX="$_CIRV_SHA_L"; CI_RUNNER_SHA_OSX="$_CIRV_SHA_O"; CI_RUNNER_SOURCE="latest"
        return 0
    fi
    why="GitHub did not return a usable latest-release record (network down, rate limited, or no sha256 values in the release notes)"

    if [ "$kept_ok" = 1 ] && { [ "$pin_ok" = 0 ] || [ "$(ci_runner_semver_cmp "$kv" "$pv")" != "-1" ]; }; then
        CI_RUNNER_VERSION="$kv"; CI_RUNNER_SHA_LINUX="$ksl"; CI_RUNNER_SHA_OSX="$kso"; CI_RUNNER_SOURCE="kept"; CI_RUNNER_CHECKED_AT="$kat"
        CI_RUNNER_NOTICE="could not check for a newer actions/runner (${why}); KEEPING the runner already staged (${kv}, last confirmed newest ${kat:-at an unknown time}). It is NOT being refreshed: run 'aiteamforge ci refresh --force' again when GitHub is reachable."
        return 0
    fi
    if [ "$pin_ok" = 1 ]; then
        CI_RUNNER_VERSION="$pv"; CI_RUNNER_SHA_LINUX="$ps_l"; CI_RUNNER_SHA_OSX="$ps_o"; CI_RUNNER_SOURCE="pinned"
        CI_RUNNER_NOTICE="could not resolve the latest actions/runner (${why}); using the PINNED FALLBACK ${pv} from this release's runner-pin.conf, verified against the sha256 recorded there. It may be older than GitHub's newest release: 'aiteamforge ci status' will warn until a refresh reaches GitHub."
        return 0
    fi
    CI_RUNNER_WHY="${why}, and the keg's runner-pin.conf has no usable pinned fallback (needs pin_version and two 64-hex sha256 values); refusing to stage an unverifiable runner"
    return 1
}

# ci_runner_verify_file <file> <expected_sha256>
#   rc 0 match. rc 1 MISMATCH (the caller deletes the file). rc 2 cannot verify: the expected value is not 64 hex, the file
#   is unreadable or there is no sha tool. Both non-zero results mean "do not use this file"; an empty expected value is
#   NEVER a pass (the old code skipped verification when the digest could not be read).
ci_runner_verify_file() {
    local f="${1:-}" want="${2:-}" got
    _cirv_hex64 "$want" || return 2
    [ -f "$f" ] && [ -r "$f" ] || return 2
    got="$(_cipv_sha "$f")" || return 2
    [ "$got" = "$want" ] || return 1
    return 0
}

# ---------------------------------------------------------------- READER half (user, no sudo, no network)

# The record in the manifest: ci_runner_manifest_record <host> -> CI_RR_* ; rc 0 loaded, 1 no manifest, 2 unreadable/invalid
# (CI_RR_WHY). Absent R lines (a pre-XACA-1443-014 manifest) is rc 0 with CI_RR_COUNT=0.
CI_RR_LINUX=""; CI_RR_OSX=""; CI_RR_COUNT=0; CI_RR_CHECKED_AT=""; CI_RR_WHY=""
ci_runner_manifest_record() {
    local rc=0 line tag os v sha src
    CI_RR_LINUX=""; CI_RR_OSX=""; CI_RR_COUNT=0; CI_RR_CHECKED_AT=""; CI_RR_WHY=""
    ci_provision_manifest_load "$1" || rc=$?
    case "$rc" in
        0) ;;
        1) CI_RR_WHY="no provision manifest"; return 1 ;;
        *) CI_RR_WHY="${CI_PM_WHY}"; return 2 ;;
    esac
    CI_RR_CHECKED_AT="${CI_PM_RUNNER_CHECKED_AT:-}"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        tag="$1"; os="$2"; v="$3"; sha="$4"; src="$5"
        case "$os" in
            linux-arm64) CI_RR_LINUX="${v} ${sha} ${src}" ;;
            osx-arm64) CI_RR_OSX="${v} ${sha} ${src}" ;;
        esac
        CI_RR_COUNT=$((CI_RR_COUNT + 1))
    done <<EOF_RR
${CI_PM_RLINES:-}
EOF_RR
    return 0
}

# Called by ci_provision_skew after the F lines. Adds DEFINITE keg-vs-host differences only:
#   runner: the manifest records no runner (provisioned before XACA-1443-014)
#   runner: a staged runner is older than the keg's pin_version
# (age / source / registration floor are host-health facts, reported by the probe below, not skew.)
# Uses CI_PM_RLINES from the manifest load that ci_provision_skew just did. Appends via _cipv_add.
ci_runner_skew_check() {
    local bundle="${1:-}" pin pv line os v c
    pin="${bundle}/runner-pin.conf"
    if [ -z "${CI_PM_RLINES:-}" ]; then
        _cipv_add CI_SKEW_REASONS "runner: the manifest records no staged actions/runner version (provisioned before runner versions were recorded, XACA-1443-014)"
        return 0
    fi
    pv="$(_cirv_get pin_version "$pin")" || pv=""
    if ! ci_runner_semver_ok "$pv"; then
        _cipv_add CI_SKEW_UNSEEN "runner: cannot read pin_version from ${pin}"
        return 0
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        os="$2"; v="$3"
        c="$(ci_runner_semver_cmp "$v" "$pv")" || { _cipv_add CI_SKEW_UNSEEN "runner: ${os} version '${v}' is not X.Y.Z"; continue; }
        [ "$c" != "-1" ] || _cipv_add CI_SKEW_REASONS "runner: staged ${os} actions/runner ${v} is older than the ${pv} this release knows about; refresh re-stages the newest verified release"
    done <<EOF_RS
${CI_PM_RLINES}
EOF_RS
    return 0
}

# ci_runner_assess <host> <bundle_dir>
#   Judges the staged runner from the manifest record + the keg's pin file. NEVER reports ok by default: the state
#   starts `unknown` and only becomes `ok` when every observable check passed and nothing was unreadable.
#   rc 0 ok | 1 warn | 2 unknown ; CI_RUNNER_STATE, CI_RUNNER_REASONS (newline list, one fact per line),
#   CI_RUNNER_INFO (what is staged, for an ok report).
CI_RUNNER_STATE="unknown"; CI_RUNNER_REASONS=""; CI_RUNNER_INFO=""
_cirv_note() { CI_RUNNER_REASONS="${CI_RUNNER_REASONS:+${CI_RUNNER_REASONS}
}$1"; }
ci_runner_assess() {
    local host="${1:-}" bundle="${2:-}" pin rc=0 warn=0 unk=0 regmin pv maxd now ts then age_s age_d
    local os rec v sha src c line
    CI_RUNNER_STATE="unknown"; CI_RUNNER_REASONS=""; CI_RUNNER_INFO=""
    pin="${bundle}/runner-pin.conf"

    ci_runner_manifest_record "$host" || rc=$?
    if [ "$rc" != 0 ]; then
        _cirv_note "cannot see the staged actions/runner version: ${CI_RR_WHY}"
        return 2
    fi
    if [ "$CI_RR_COUNT" -eq 0 ]; then
        _cirv_note "cannot see the staged actions/runner version: the provision manifest records none (provisioned before XACA-1443-014); aiteamforge ci refresh records it"
        return 2
    fi

    regmin="$(_cirv_get registration_min "$pin")" || regmin=""
    pv="$(_cirv_get pin_version "$pin")" || pv=""
    maxd="$(_cirv_get max_age_days "$pin")" || maxd=""
    ci_runner_semver_ok "$regmin" || { unk=1; _cirv_note "cannot judge the registration minimum: registration_min unreadable in ${pin}"; regmin=""; }
    ci_runner_semver_ok "$pv" || { unk=1; _cirv_note "cannot compare with the release's known runner: pin_version unreadable in ${pin}"; pv=""; }
    case "$maxd" in ''|*[!0-9]*) unk=1; _cirv_note "cannot judge staleness: max_age_days unreadable in ${pin}"; maxd="" ;; esac

    for os in linux-arm64 osx-arm64; do
        case "$os" in linux-arm64) rec="$CI_RR_LINUX" ;; *) rec="$CI_RR_OSX" ;; esac
        [ -n "$rec" ] || continue
        set -- $rec
        v="$1"; sha="$2"; src="$3"
        CI_RUNNER_INFO="${CI_RUNNER_INFO:+${CI_RUNNER_INFO}; }${os} ${v} (${src})"
        if ! ci_runner_semver_ok "$v"; then unk=1; _cirv_note "${os}: recorded version '${v}' is not X.Y.Z"; continue; fi
        if [ -n "$regmin" ]; then
            c="$(ci_runner_semver_cmp "$v" "$regmin")"
            [ "$c" != "-1" ] || { warn=1; _cirv_note "${os}: staged actions/runner ${v} is BELOW GitHub's registration minimum ${regmin}: new JIT runners are refused"; }
        fi
        case "$src" in
            pinned) warn=1; _cirv_note "${os}: staged ${v} came from the keg's PINNED FALLBACK (GitHub could not be asked at the last provision); it may be behind the newest release" ;;
            kept) warn=1; _cirv_note "${os}: staged ${v} was KEPT because GitHub could not be asked at the last refresh; it is not known to be the newest release" ;;
            latest|explicit) ;;
            *) unk=1; _cirv_note "${os}: unknown source '${src}' in the manifest" ;;
        esac
    done

    ts="${CI_RR_CHECKED_AT}"
    if [ -z "$ts" ] || ! now="$(ci_runner_now)" || ! thn="$(ci_runner_iso_epoch "$ts")"; then
        unk=1; _cirv_note "cannot tell how old the staged runner is: runner_checked_at is missing or malformed in the manifest"
    elif [ -n "$maxd" ]; then
        if [ "$thn" -gt $((now + 86400)) ]; then
            unk=1; _cirv_note "runner_checked_at (${ts}) is in the future: the clock or the manifest is wrong"
        else
            age_s=$((now - thn)); age_d=$((age_s / 86400))
            # exact: "more than max_age_days" is judged in seconds, not in whole days
            if [ "$age_s" -gt $((maxd * 86400)) ]; then
                warn=1; _cirv_note "the staged runner was last confirmed newest ${age_d} days ago (${ts}); GitHub stops queuing jobs to a runner more than 30 days behind a new release. Re-stage it: aiteamforge ci refresh --force"
            fi
        fi
    fi

    if [ "$warn" = 1 ]; then CI_RUNNER_STATE="warn"; return 1; fi
    if [ "$unk" = 1 ]; then CI_RUNNER_STATE="unknown"; return 2; fi
    CI_RUNNER_STATE="ok"
    return 0
}

# The XACA-1443-004 hook: ci_capability_state calls this for enabled/paused hosts. It only warns (warn state, never
# fail: the host works, and a JIT runner self-updates as the safety net). Unknown is a WARN too, never silence.
# Defined only when nothing else has defined it (a caller's own hook wins; also keeps a double include harmless).
if ! type ci_status_runner_probe >/dev/null 2>&1; then
ci_status_runner_probe() {
    local host="${1:-}" aitf="${AITEAMFORGE_DIR:-${HOME:-}/aiteamforge}" bundle rc=0 line
    bundle="${CI_RUNNER_BUNDLE_DIR:-${aitf}/scripts/ci-runner}"
    ci_runner_assess "$host" "$bundle" || rc=$?
    case "$rc" in
        0) _cis_reason "runner: staged actions/runner ${CI_RUNNER_INFO}, confirmed newest within the staleness window" ;;
        1) while IFS= read -r line; do [ -z "$line" ] || _cis_warn "runner: ${line}"; done <<EOF_P1
${CI_RUNNER_REASONS}
EOF_P1
           [ -n "${CI_STATUS_NEXT:-}" ] || CI_STATUS_NEXT="aiteamforge ci refresh --force   (re-stages the newest verified actions/runner)" ;;
        *) while IFS= read -r line; do
               [ -z "$line" ] || { _cis_warn "runner: unknown: ${line}"; _cis_add CI_STATUS_UNSEEN "runner: ${line}"; }
           done <<EOF_P2
${CI_RUNNER_REASONS}
EOF_P2
           [ -n "${CI_STATUS_NEXT:-}" ] || CI_STATUS_NEXT="aiteamforge ci refresh --dry-run   (could not see the staged actions/runner version)" ;;
    esac
    return 0
}
fi

_CIRV_LOADING=0
