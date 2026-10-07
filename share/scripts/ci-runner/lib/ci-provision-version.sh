#!/usr/bin/env bash
# ci-provision-version.sh - provision manifest + version-skew detection (XACA-1443-013/-015).
#
# SOURCEABLE LIBRARY. Sourcing defines functions only: no output, no `exit`, no change to the
# caller's `set` options. Used by three callers that must agree on the format:
#   * provision-host.sh (ROOT)  writes the manifest after a complete provision        (writer half)
#   * `aiteamforge ci enable|refresh --confirm` and `ci refresh`  (USER) read + compare   (reader half)
#   * aiteamforge-upgrade.sh (USER) prints a notice when an enabled host is behind
#   * XACA-1443-004 (`ci status` / doctor) calls ci_provision_skew
# Nothing here ever runs sudo, launchctl, limactl, curl or gh. The reader half only runs
# `shasum`/`sha256sum`, `sort`, `awk`, `cut`, `dirname`, `basename` and shell tests.
#
# THE MANIFEST  ${CIH_STATE_DIR:-/usr/local/etc/ci-runner}/<host>.provision-manifest  (root:wheel 644)
#   # comment lines
#   schema=1
#   host=<host>
#   provision_version=<first 12 hex of sha256 over the sorted F lines below>
#   provisioned_at=<UTC ISO>
#   F <sha256> <kind> <bundle-relpath> <dest>
# kind:
#   libexec  a root-owned copy on the host (<dest> is a real, world-readable file). The hash is of the
#            SOURCE file provision-host.sh installed; the checker hashes <dest> live as well.
#   guest    a script pushed INTO the VM (<dest> is the path inside the guest). Not observable from here.
#   step     a provisioning script whose bytes ARE the steps (provision-host.sh, create-ci-runner-user.sh);
#            <dest> is `-`. A change to it means plists / VM config / user setup / guest baseline may have
#            changed, so the host must re-converge.
# <bundle-relpath> is relative to $AITEAMFORGE_DIR/scripts/ci-runner (the keg's copy of the bundle).
#
# WHY A CONTENT HASH (not a hand-bumped integer): nothing can forget to bump it. Cost: a comment-only edit
# of provision-host.sh also reads as skew. That is the safe direction: `ci refresh` is idempotent and cheap,
# whereas a forgotten bump would leave an enabled host silently on old plists. See the contract doc.
#
# ci_provision_skew <host> <bundle_dir> [recorded_provision_version]
#   rc 0  in-sync   everything that CAN be observed matches the keg
#   rc 1  skewed    something definitely differs (CI_SKEW_REASONS lists each; also set when only
#                   unseen items remain alongside a definite difference)
#   rc 2  unknown   nothing definitely differs but something could not be read (CI_SKEW_UNSEEN):
#                   NEVER reported as in-sync
#   sets CI_SKEW_STATE (in-sync|skewed|unknown), CI_SKEW_REASONS, CI_SKEW_UNSEEN (newline lists, each line
#   `class: text`), CI_SKEW_RECORDED_VERSION (the manifest's version, empty when unreadable), CI_SKEW_BLIND
#   (fixed text: what this probe can never see).
# WHAT IT CAN SEE (no sudo): the manifest (root-owned 644), the four root-owned copies in /usr/local/libexec
# (644/755), the keg's bundle files. WHAT IT CANNOT: anything inside ci-runner's 700 home (the Lima VM, its
# guest scripts, fleet-config.json) and the loaded state of daemons. Guest drift is therefore judged from the
# record provision-host.sh made when it pushed the scripts, not from the VM.
#
# Portability: /bin/bash 3.2 and bash 5. Public names ci_provision_*, internals _cipv_*.

# sha256 of a file -> 64 hex on stdout, rc 0; any failure -> rc 1 and no output.
_cipv_sha() {
    local o=""
    if command -v shasum >/dev/null 2>&1; then o="$(shasum -a 256 "$1" 2>/dev/null)" || return 1
    elif command -v sha256sum >/dev/null 2>&1; then o="$(sha256sum "$1" 2>/dev/null)" || return 1
    else return 1; fi
    o="${o%% *}"
    case "$o" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#o}" -eq 64 ] || return 1
    printf '%s' "$o"
}

# sha256 of stdin -> 64 hex.
_cipv_sha_stdin() {
    local o=""
    if command -v shasum >/dev/null 2>&1; then o="$(shasum -a 256 2>/dev/null)" || return 1
    elif command -v sha256sum >/dev/null 2>&1; then o="$(sha256sum 2>/dev/null)" || return 1
    else return 1; fi
    o="${o%% *}"
    case "$o" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#o}" -eq 64 ] || return 1
    printf '%s' "$o"
}

_cipv_host_ok() {
    case "${1:-}" in ''|[!a-z0-9]*|*[!a-z0-9-]*|*-) return 1 ;; esac
    [ "${#1}" -le 40 ]
}

# bundle-relative path: [A-Za-z0-9._/-], not absolute, no `..` segment, no empty segment.
_cipv_rel_ok() {
    case "${1:-}" in ''|/*|*//*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
    case "/$1/" in */../*|*/./*) return 1 ;; esac
    return 0
}

# destination: `-` or an absolute path of [A-Za-z0-9._/-] without `..`.
_cipv_dest_ok() {
    [ "${1:-}" = "-" ] && return 0
    case "${1:-}" in /?*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9._/-]*|*//*) return 1 ;; esac
    case "/$1/" in */../*|*/./*) return 1 ;; esac
    return 0
}

ci_provision_manifest_path() { # host -> path
    printf '%s/%s.provision-manifest' "${CIH_STATE_DIR:-/usr/local/etc/ci-runner}" "$1"
}

# ---------------------------------------------------------------- writer half (root, provision-host.sh)

# ci_provision_entry <kind> <relpath> <dest> <source-file>
#   Appends one F line to CI_PM_ENTRIES (newline separated). rc 1 (nothing appended) if the file is unreadable.
CI_PM_ENTRIES=""
ci_provision_entry_reset() { CI_PM_ENTRIES=""; }
ci_provision_entry() {
    local kind="$1" rel="$2" dest="$3" src="$4" sha
    case "$kind" in libexec|guest|step) ;; *) return 1 ;; esac
    _cipv_rel_ok "$rel" && _cipv_dest_ok "$dest" || return 1
    sha="$(_cipv_sha "$src")" || return 1
    CI_PM_ENTRIES="${CI_PM_ENTRIES:+${CI_PM_ENTRIES}
}F ${sha} ${kind} ${rel} ${dest}"
    return 0
}

# version of an F-line block (stdin-independent): first 12 hex of sha256 over the sorted lines + final newline.
ci_provision_version_of() { # "<F lines>" -> 12 hex
    local h
    h="$(printf '%s\n' "$1" | LC_ALL=C sort | _cipv_sha_stdin)" || return 1
    printf '%s' "${h%${h#????????????}}"
}

# ci_provision_manifest_render <host> <timestamp>  -> the manifest on stdout. rc 1 when there are no entries.
ci_provision_manifest_render() {
    local host="$1" ts="$2" v
    [ -n "$CI_PM_ENTRIES" ] || return 1
    v="$(ci_provision_version_of "$CI_PM_ENTRIES")" || return 1
    echo "# aiteamforge CI provision manifest v1 - written by provision-host.sh (root). No secrets. Contract: XACA-1443-013."
    echo "schema=1"
    echo "host=${host}"
    echo "provision_version=${v}"
    echo "provisioned_at=${ts}"
    printf '%s\n' "$CI_PM_ENTRIES" | LC_ALL=C sort
}

# ---------------------------------------------------------------- reader half

# ci_provision_manifest_load <host>
#   rc 0 loaded  -> CI_PM_VERSION, CI_PM_AT, CI_PM_FLINES (validated, version re-derived and matched)
#   rc 1 absent  (definite: the directory can be looked into and the file is not there, or the dir is gone)
#   rc 2 cannot tell or invalid -> CI_PM_WHY
CI_PM_VERSION=""; CI_PM_AT=""; CI_PM_FLINES=""; CI_PM_WHY=""
ci_provision_manifest_load() {
    local host="$1" f d line key val schema="" mhost="" ver="" at="" fl="" n=0 tag sha kind rel dest extra
    CI_PM_VERSION=""; CI_PM_AT=""; CI_PM_FLINES=""; CI_PM_WHY=""
    _cipv_host_ok "$host" || { CI_PM_WHY="invalid host name"; return 2; }
    f="$(ci_provision_manifest_path "$host")"; d="${f%/*}"
    if [ ! -e "$f" ]; then
        if [ -d "$d" ] && [ ! -x "$d" ]; then CI_PM_WHY="cannot look into $d"; return 2; fi
        return 1
    fi
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then CI_PM_WHY="$f is not a readable file"; return 2; fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            schema=*) schema="${line#schema=}" ;;
            host=*) mhost="${line#host=}" ;;
            provision_version=*) ver="${line#provision_version=}" ;;
            provisioned_at=*) at="${line#provisioned_at=}" ;;
            'F '*)
                set -- $line
                tag="${1:-}"; sha="${2:-}"; kind="${3:-}"; rel="${4:-}"; dest="${5:-}"; extra="${6:-}"
                [ -z "$extra" ] && [ -n "$dest" ] || { CI_PM_WHY="malformed F line"; return 2; }
                case "$sha" in *[!0-9a-f]*) CI_PM_WHY="malformed F line (hash)"; return 2 ;; esac
                [ "${#sha}" -eq 64 ] || { CI_PM_WHY="malformed F line (hash length)"; return 2; }
                case "$kind" in libexec|guest|step) ;; *) CI_PM_WHY="malformed F line (kind)"; return 2 ;; esac
                _cipv_rel_ok "$rel" || { CI_PM_WHY="malformed F line (path)"; return 2; }
                _cipv_dest_ok "$dest" || { CI_PM_WHY="malformed F line (destination)"; return 2; }
                fl="${fl:+${fl}
}${line}"; n=$((n + 1)) ;;
            *) CI_PM_WHY="unrecognised line"; return 2 ;;
        esac
    done <"$f"
    [ "$schema" = "1" ] || { CI_PM_WHY="unknown schema '${schema}'"; return 2; }
    [ "$mhost" = "$host" ] || { CI_PM_WHY="host mismatch (manifest says '${mhost}')"; return 2; }
    [ "$n" -ge 1 ] || { CI_PM_WHY="no F lines"; return 2; }
    case "$ver" in ''|*[!0-9a-f]*) CI_PM_WHY="bad provision_version"; return 2 ;; esac
    [ "${#ver}" -eq 12 ] || { CI_PM_WHY="bad provision_version length"; return 2; }
    [ "$(ci_provision_version_of "$fl")" = "$ver" ] || { CI_PM_WHY="provision_version does not match its own F lines"; return 2; }
    CI_PM_VERSION="$ver"; CI_PM_AT="$at"; CI_PM_FLINES="$fl"
    return 0
}

_cipv_add() { # var-name line
    eval "$1=\"\${$1:+\${$1}
}\$2\""
}

ci_provision_skew() {
    local host="${1:-}" bundle="${2:-}" recorded="${3:-}" check_rec=0 rc=0 line tag sha kind rel dest keg kegsha instsha d
    [ "$#" -ge 3 ] && check_rec=1     # a 3rd argument (even empty) asks for the state-file record check
    CI_SKEW_STATE="unknown"; CI_SKEW_REASONS=""; CI_SKEW_UNSEEN=""; CI_SKEW_RECORDED_VERSION=""
    CI_SKEW_BLIND="guest copies inside the VM (ci-runner's 700 home) are judged from the record provision-host.sh made when it pushed them, not read; the VM, loaded daemons and plist contents are not inspected"
    if ! _cipv_host_ok "$host"; then _cipv_add CI_SKEW_UNSEEN "state: invalid host name '${host}'"; return 2; fi
    if [ ! -d "$bundle" ] || [ ! -r "$bundle" ]; then _cipv_add CI_SKEW_UNSEEN "keg: bundle directory '${bundle}' is not readable"; return 2; fi

    ci_provision_manifest_load "$host" || rc=$?
    case "$rc" in
        0) ;;
        1) CI_SKEW_STATE="skewed"
           _cipv_add CI_SKEW_REASONS "manifest: none recorded at $(ci_provision_manifest_path "$host") - this host was provisioned before provision versions were recorded (XACA-1443-013)"
           return 1 ;;
        *) _cipv_add CI_SKEW_UNSEEN "manifest: unreadable or invalid (${CI_PM_WHY})"; return 2 ;;
    esac
    CI_SKEW_RECORDED_VERSION="$CI_PM_VERSION"

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        tag="$1"; sha="$2"; kind="$3"; rel="$4"; dest="$5"
        keg="$bundle/$rel"
        if [ ! -e "$keg" ]; then _cipv_add CI_SKEW_UNSEEN "keg: ${rel} is missing from the bundle"; continue; fi
        kegsha="$(_cipv_sha "$keg")" || { _cipv_add CI_SKEW_UNSEEN "keg: cannot read ${rel}"; continue; }
        case "$kind" in
            libexec)
                d="${dest%/*}"
                if [ ! -e "$dest" ]; then
                    if [ -d "$d" ] && [ ! -x "$d" ]; then _cipv_add CI_SKEW_UNSEEN "libexec: cannot look into ${d}"
                    else _cipv_add CI_SKEW_REASONS "libexec: ${dest} is missing"; fi
                    continue
                fi
                instsha="$(_cipv_sha "$dest")" || { _cipv_add CI_SKEW_UNSEEN "libexec: cannot read ${dest}"; continue; }
                [ "$instsha" = "$kegsha" ] || _cipv_add CI_SKEW_REASONS "libexec: ${dest##*/} installed copy differs from the keg (installed ${instsha%${instsha#????????}}, keg ${kegsha%${kegsha#????????}})"
                ;;
            guest)
                [ "$sha" = "$kegsha" ] || _cipv_add CI_SKEW_REASONS "guest: ${dest} was pushed from ${rel} ${sha%${sha#????????}}, keg now has ${kegsha%${kegsha#????????}}"
                ;;
            step)
                [ "$sha" = "$kegsha" ] || _cipv_add CI_SKEW_REASONS "step: ${rel} changed since this host was provisioned (${sha%${sha#????????}} -> ${kegsha%${kegsha#????????}}); plists, VM config or user setup may differ"
                ;;
        esac
    done <<EOF_CIPV
$CI_PM_FLINES
EOF_CIPV

    # The state file's recorded version must be the manifest's (a refresh that was run but not confirmed).
    if [ "$check_rec" = 1 ] && [ -n "$recorded" ] && [ "$recorded" != "$CI_PM_VERSION" ]; then
        _cipv_add CI_SKEW_REASONS "record: the state file records provision_version ${recorded}, the host manifest says ${CI_PM_VERSION}"
    elif [ -z "$recorded" ] && [ "$check_rec" = 1 ]; then
        _cipv_add CI_SKEW_REASONS "record: the state file has no provision_version (host manifest: ${CI_PM_VERSION})"
    fi

    if [ -n "$CI_SKEW_REASONS" ]; then CI_SKEW_STATE="skewed"; return 1; fi
    if [ -n "$CI_SKEW_UNSEEN" ]; then CI_SKEW_STATE="unknown"; return 2; fi
    CI_SKEW_STATE="in-sync"
    return 0
}

# ---------------------------------------------------------------- upgrade notice (user, never sudo)

# ci_provision_upgrade_notice <aiteamforge_dir> [bundle_dir]
#   bundle_dir defaults to <aiteamforge_dir>/scripts/ci-runner; the state file is <aiteamforge_dir>/.aiteamforge-ci-state
#   (the name lives HERE so the upgrade script never spells a path that reads like an enable reference).
#   Silent unless the state file says `enabled`. For a skewed host prints one paragraph naming
#   `aiteamforge ci refresh`; for an unverifiable one a shorter note saying so (never silence on unknown).
#   Always rc 0: it must never block an upgrade. Never runs sudo or touches the host.
ci_provision_upgrade_notice() {
    local dir="${1:-}" sf bundle="${2:-}" st host rec rc=0 first
    [ -n "$dir" ] || return 0
    sf="${dir}/.aiteamforge-ci-state"
    [ -n "$bundle" ] || bundle="${dir}/scripts/ci-runner"
    [ -f "$sf" ] && [ -r "$sf" ] || return 0
    st="$(awk -F= '$1=="state"{sub(/^[^=]*=/,"");print;exit}' "$sf" 2>/dev/null)"
    [ "$st" = "enabled" ] || return 0
    host="$(awk -F= '$1=="host"{sub(/^[^=]*=/,"");print;exit}' "$sf" 2>/dev/null)"
    rec="$(awk -F= '$1=="provision_version"{sub(/^[^=]*=/,"");print;exit}' "$sf" 2>/dev/null)"
    ci_provision_skew "$host" "$bundle" "$rec" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1)
            first="$(printf '%s\n' "$CI_SKEW_REASONS" | sed -n '1p')"
            echo
            if [ -z "$(printf '%s\n' "$CI_SKEW_REASONS" | grep -v '^record:')" ]; then
                echo "CI host '${host}' matches this release, but the state file's recorded provision version is stale (${first}). Run: aiteamforge ci refresh --confirm"
            else
                echo "CI host '${host}' is behind this release: the provisioning bundle changed since the host was last provisioned (${first})."
                echo "Nothing was changed on the host. To bring it up to date run: aiteamforge ci refresh   (it prints ONE sudo command for you to read and run, then confirm with: aiteamforge ci refresh --confirm)"
            fi
            ;;
        *)
            first="$(printf '%s\n' "$CI_SKEW_UNSEEN" | sed -n '1p')"
            echo
            echo "CI host '${host}': could not verify that it matches this release (${first}). Nothing was changed. Run: aiteamforge ci refresh --dry-run"
            ;;
    esac
    return 0
}
