#!/usr/bin/env zsh
# Display Agent Avatar Panel
# Writes agent data to a temp JSON file for the LCARS agent panel to display
#
# Function: display_agent_avatar
# Arguments:
#   $1 - TEAM (e.g., "academy", "ios", "firebase")
#   $2 - DEVELOPER_NAME (e.g., "Captain Nahla Ake", "Commander Jett Reno")
#
# Environment variables used (set by banner scripts):
#   SESSION_THEME, SESSION_DESCRIPTION, SESSION_LOCATION,
#   SESSION_ROLE, TERMINAL_NAME, TERMINAL_DESCRIPTION
#
# Writes agent data to kanban/tmp/lcars-agent-{team}.json for the LCARS server
# to serve via GET /api/agent-panel (falls back to /tmp/ if unavailable)
#
# An unmapped "<team>:<developer_name>" pair still writes the panel JSON (with
# an empty avatar), warning on stderr only if the team has other arms. It must
# never return early: callers discard output, so a silent skip leaves the panel
# on "waiting" (XACA-1220).
#
# Returns:
#   0 - Success (including the unmapped-avatar case above)
#   1 - Error (invalid arguments — team or developer_name empty, or team /
#       SESSION_CODE containing "/")

# Source the shared LCARS tmp dir helper (resolve path relative to this script).
# Must work whether sourced from zsh or bash — zsh's ${0:A:h} modifier isn't
# valid bash syntax and silently resolves to empty, which used to break this
# helper when legal/finance/etc. bash-shebang scripts sourced it.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # Bash: BASH_SOURCE[0] is this file's path, even when sourced
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # zsh: ${(%):-%N} or ${0:A:h} give the sourced script's path
    SCRIPT_DIR="${0:A:h}"
fi
source "${SCRIPT_DIR}/lcars-tmp-dir.sh"
# Captured now: callers reuse SCRIPT_DIR for their own paths.
_DAA_SELF="${SCRIPT_DIR}/display-agent-avatar.sh"

display_agent_avatar() {
    local team="${1}"
    local developer_name="${2//\\/}"

    # Validate required arguments
    if [[ -z "$team" || -z "$developer_name" ]]; then
        return 1
    fi
    # team / SESSION_CODE become part of the panel file name
    if [[ "$team" == */* || "${SESSION_CODE:-}" == */* ]]; then
        return 1
    fi

    # Map developer names to avatar codenames
    local avatar_codename=""
    local amb_handle=""

    case "${team}:${developer_name}" in
        # Academy team (32nd Century / Discovery)
        "academy:Captain Nahla Ake") avatar_codename="nahla"; amb_handle="nahla-ake" ;;
        "academy:Commander Jett Reno") avatar_codename="reno"; amb_handle="jett-reno" ;;
        "academy:Lura Thok"|"academy:Cadet Master Thok"|"academy:Thok") avatar_codename="thok"; amb_handle="lura-thok" ;;
        "academy:The Doctor (EMH)"|"academy:EMH Training Officer"|"academy:Emergency Medical Hologram") avatar_codename="emh"; amb_handle="the-doctor-emh" ;;
        # Persona **Name:** forms the tap installer embeds (XACA-1220). The
        # "Scotty"/"Bones"/"Trip" quotes arrive stripped (unescaped embedding).
        "academy:The Doctor (EMH Mark I)") avatar_codename="emh"; amb_handle="the-doctor-emh" ;;
        "academy:Lal") ;;  # no avatar image yet: panel shows initials, no warning

        # iOS team (TNG)
        "ios:Captain Jean-Luc Picard") avatar_codename="picard"; amb_handle="captain-picard" ;;
        "ios:Lt Cmdr Data"|"ios:Lt. Cmdr. Data"|"ios:Lieutenant Commander Data") avatar_codename="data"; amb_handle="lt-cmdr-data" ;;
        "ios:Chief Engineer Geordi La Forge"|"ios:Lieutenant Commander Geordi La Forge") avatar_codename="geordi"; amb_handle="geordi-laforge" ;;
        "ios:Lt Cmdr Worf"|"ios:Lt. Cmdr. Worf"|"ios:Lieutenant Worf") avatar_codename="worf"; amb_handle="batleth" ;;
        "ios:Counselor Deanna Troi") avatar_codename="deanna"; amb_handle="counselor-troi" ;;
        "ios:Dr Beverly Crusher"|"ios:Dr. Beverly Crusher"|"ios:Doctor Beverly Crusher") avatar_codename="beverly"; amb_handle="beverly-crusher" ;;
        "ios:Wesley Crusher") avatar_codename="wesley"; amb_handle="wesley-crusher" ;;
        "ios:Jean-Luc Picard") avatar_codename="picard"; amb_handle="captain-picard" ;;
        "ios:Data") avatar_codename="data"; amb_handle="lt-cmdr-data" ;;
        "ios:Geordi La Forge") avatar_codename="geordi"; amb_handle="geordi-laforge" ;;
        "ios:Worf") avatar_codename="worf"; amb_handle="batleth" ;;
        "ios:Deanna Troi") avatar_codename="deanna"; amb_handle="counselor-troi" ;;
        "ios:Beverly Crusher") avatar_codename="beverly"; amb_handle="beverly-crusher" ;;

        # Android team (TOS)
        "android:Captain James T. Kirk") avatar_codename="kirk"; amb_handle="kirk" ;;
        "android:Commander Spock") avatar_codename="spock"; amb_handle="spock" ;;
        "android:Chief Engineer Montgomery Scott"|"android:Lieutenant Commander Montgomery Scott") avatar_codename="scotty"; amb_handle="scotty" ;;
        "android:Lt. Nyota Uhura"|"android:Lieutenant Uhura"|"android:Lieutenant Nyota Uhura") avatar_codename="uhura"; amb_handle="uhura" ;;
        "android:Lieutenant Hikaru Sulu") avatar_codename="sulu"; amb_handle="sulu" ;;
        "android:Ensign Pavel Chekov") avatar_codename="chekov"; amb_handle="chekov" ;;
        "android:Dr. Leonard McCoy"|"android:Doctor Leonard McCoy") avatar_codename="mccoy"; amb_handle="mccoy" ;;
        android:Montgomery\ *Scotty*\ Scott) avatar_codename="scotty"; amb_handle="scotty" ;;
        android:Dr.\ Leonard\ *Bones*\ McCoy) avatar_codename="mccoy"; amb_handle="mccoy" ;;

        # Firebase team (DS9)
        "firebase:Commander Benjamin Sisko"|"firebase:Captain Benjamin Sisko") avatar_codename="sisko"; amb_handle="captain-sisko" ;;
        "firebase:Major Kira Nerys") avatar_codename="kira"; amb_handle="kira-nerys" ;;
        "firebase:Chief Miles O'Brien"|firebase:"Chief Miles O\'Brien") avatar_codename="obrien"; amb_handle="chief-obrien" ;;
        "firebase:Lt. Commander Jadzia Dax"|"firebase:Lieutenant Jadzia Dax") avatar_codename="dax"; amb_handle="dax" ;;
        "firebase:Dr. Julian Bashir"|"firebase:Doctor Julian Bashir") avatar_codename="bashir"; amb_handle="bashir" ;;
        "firebase:Constable Odo") avatar_codename="odo"; amb_handle="constable-odo" ;;
        "firebase:Quark") avatar_codename="quark"; amb_handle="quark" ;;
        "firebase:Benjamin Sisko") avatar_codename="sisko"; amb_handle="captain-sisko" ;;
        "firebase:Kira Nerys") avatar_codename="kira"; amb_handle="kira-nerys" ;;
        "firebase:Miles Edward O'Brien") avatar_codename="obrien"; amb_handle="chief-obrien" ;;
        "firebase:Jadzia Dax") avatar_codename="dax"; amb_handle="dax" ;;
        "firebase:Julian Bashir") avatar_codename="bashir"; amb_handle="bashir" ;;
        "firebase:Odo") avatar_codename="odo"; amb_handle="constable-odo" ;;

        # Finance team (Ferengi Commerce Authority)
        "finance:Grand Nagus Zek") avatar_codename="zek"; amb_handle="grand-nagus-zek" ;;
        "finance:Quark") avatar_codename="quark-fin"; amb_handle="quark-fin" ;;
        "finance:Nog") avatar_codename="nog"; amb_handle="nog" ;;
        "finance:Brunt") avatar_codename="brunt"; amb_handle="brunt-fca" ;;
        "finance:Brunt, FCA (Ferengi Commerce Authority)") avatar_codename="brunt"; amb_handle="brunt-fca" ;;
        "finance:Rom") avatar_codename="rom"; amb_handle="rom" ;;

        # Command team (Starfleet Command)
        "command:Admiral Kathryn Janeway") avatar_codename="janeway" ;;
        "command:Admiral Alynna Nechayev") avatar_codename="nechayev" ;;
        "command:Admiral William Ross") avatar_codename="ross" ;;
        "command:Admiral Charles Vance") avatar_codename="vance" ;;
        "command:Admiral Owen Paris"|"command:Lieutenant Tom Paris") avatar_codename="paris" ;;

        # MainEvent team (Voyager)
        "mainevent:Captain Kathryn Janeway") avatar_codename="janeway" ;;
        "mainevent:Commander Chakotay") avatar_codename="chakotay" ;;
        "mainevent:Lieutenant B'Elanna Torres") avatar_codename="torres" ;;
        "mainevent:Lieutenant Tom Paris") avatar_codename="paris" ;;
        "mainevent:Ensign Harry Kim") avatar_codename="kim" ;;
        "mainevent:Seven of Nine") avatar_codename="seven" ;;
        "mainevent:Lieutenant Commander Tuvok") avatar_codename="tuvok" ;;
        "mainevent:The Doctor") avatar_codename="doctor" ;;

        # DNS Framework team (Lower Decks)
        "dns:Beckett Mariner") avatar_codename="mariner" ;;
        "dns:D'Vana Tendi") avatar_codename="tendi" ;;
        "dns:Sam Rutherford") avatar_codename="rutherford" ;;
        "dns:Brad Boimler") avatar_codename="boimler" ;;
        "dns:Dr. T'Ana") avatar_codename="tana" ;;
        "dns:Lt. Shaxs") avatar_codename="shaxs" ;;
        "dns:Commander Ransom") avatar_codename="ransom" ;;
        "dns:Lieutenant Shaxs") avatar_codename="shaxs" ;;
        "dns:Commander Jack Ransom") avatar_codename="ransom" ;;

        # Freelance team (Enterprise)
        "freelance:Captain Jonathan Archer") avatar_codename="archer"; amb_handle="captain-archer" ;;
        "freelance:Commander Charles 'Trip' Tucker III") avatar_codename="tucker"; amb_handle="tucker" ;;
        freelance:Commander\ Charles\ *Trip*\ Tucker\ III) avatar_codename="tucker"; amb_handle="tucker" ;;
        "freelance:Sub-Commander T'Pol") avatar_codename="tpol"; amb_handle="tpol" ;;
        "freelance:Dr. Phlox") avatar_codename="phlox"; amb_handle="phlox" ;;
        "freelance:Lieutenant Malcolm Reed") avatar_codename="reed"; amb_handle="reed" ;;
        "freelance:Ensign Hoshi Sato") avatar_codename="sato"; amb_handle="sato" ;;
        "freelance:Ensign Travis Mayweather") avatar_codename="mayweather"; amb_handle="travis-mayweather" ;;

        # Legal team (Boston Legal)
        "legal:Denny Crane") avatar_codename="crane" ;;
        "legal:Shirley Schmidt") avatar_codename="schmidt" ;;
        "legal:Brad Chase") avatar_codename="chase" ;;
        "legal:Carl Sack") avatar_codename="sack" ;;
        "legal:Alan Shore") avatar_codename="shore" ;;
        "legal:Jerry Espenson") avatar_codename="espenson" ;;

        # Medical team (House MD)
        "medical:Dr. Gregory House") avatar_codename="house" ;;
        "medical:Dr. James Wilson") avatar_codename="wilson" ;;
        "medical:Dr. Allison Cameron") avatar_codename="cameron" ;;
        "medical:Dr. Robert Chase") avatar_codename="chase" ;;
        "medical:Dr. Eric Foreman") avatar_codename="foreman" ;;
        "medical:Dr. Lisa Cuddy") avatar_codename="cuddy" ;;

        # Space Dock team. Codenames must match the shipped
        # spacedock_<codename>_avatar.png files (no hyphens: serve_image regex).
        # No amb_handle: these are distinct crew from the ios/android/firebase
        # personas that own captain-sisko/geordi-laforge/spock/scotty.
        "spacedock:Captain Benjamin Sisko") avatar_codename="sisko" ;;
        "spacedock:Geordi La Forge") avatar_codename="geordi" ;;
        "spacedock:Spock") avatar_codename="spock" ;;
        # Glob: the installer embeds the persona's double quotes unescaped, so
        # this arrives as `Montgomery Scotty Scott`, `Montgomery 'Scotty' Scott`
        # or `Montgomery "Scotty" Scott` depending on the generating path.
        spacedock:Montgomery\ *Scotty*\ Scott) avatar_codename="scotty" ;;

        *)
            # Never return early (XACA-1220): write the panel with an empty
            # avatar, which agent-panel.html renders as initials. Warn only for
            # a team that has arms here (a missing station); a custom consumer
            # team has none and would otherwise warn on every banner launch.
            case "$team" in
                *[!a-z0-9_-]*) ;;
                *)
                    if grep -Eq "^[[:space:]]*\"?${team}:" "${_DAA_SELF:-}" 2>/dev/null; then
                        echo "display_agent_avatar: no avatar mapping for '${team}:${developer_name}' — panel will show initials (add an arm in scripts/display-agent-avatar.sh)" >&2
                    fi
                    ;;
            esac
            ;;
    esac

    # Validate AMB handle — only include if agent is registered in centralized config
    if [[ -n "$amb_handle" ]]; then
        local amb_registered
        amb_registered=$(python3 -c "
import json, sys
try:
    with open('$HOME/.claude/amb-agents.json') as f:
        data = json.load(f)
    handle = sys.argv[1]
    if handle in data.get('agents', {}):
        print('yes')
    else:
        print('no')
except:
    print('no')
" "$amb_handle" 2>/dev/null)
        if [[ "$amb_registered" != "yes" ]]; then
            amb_handle=""  # Not registered, clear handle
        fi
    fi

    # Get worktree info if available
    local worktree_info=""
    if command -v wt-current &> /dev/null; then
        worktree_info=$(wt-current short 2>/dev/null || echo "develop")
    fi

    # XACA-0279: Resolve the AI account identity for the agent panel JSON.
    # Prefer env vars set by _cc_export_account_credentials (cc/ccc/kb-run entry points).
    # Fall back to the team registry so banner-fresh terminals (before cc is invoked)
    # still carry account context. Downstream consumers (agent-panel.html, fleet-monitor)
    # treat empty strings as "no account configured — using default OAuth".
    #
    # XACA-1184-002: the fallback now reads teams.<slug>.ai.credential through the
    # shared resolver in scripts/team-account-display.sh (which delegates to
    # kanban-hooks/aiteamforge_registry.ai_credential) rather than parsing
    # team-paths.json inline for the retired anthropic_* trio. Only a routed
    # account ("set") populates the fields; undeclared, declared-none and an
    # unresolvable slug all leave them empty, which is the same JSON payload the
    # legacy read produced for those cases.
    #
    # NOTE: this file SHIPS to the tap (share/scripts/), so the resolver has to be
    # reachable on a consumer too. If it is not, this degrades to empty strings —
    # the documented "no account configured" payload — never an error.
    local account_id="${CLAUDE_ACTIVE_ACCOUNT_ID:-}"
    local account_nickname="${CLAUDE_ACTIVE_ACCOUNT_NICKNAME:-}"
    if [[ -z "$account_nickname" || -z "$account_id" ]]; then
        if ! command -v atf_team_account_fields >/dev/null 2>&1; then
            local _daa_helper
            for _daa_helper in "${AITEAMFORGE_DIR:-}/scripts/team-account-display.sh" \
                               "${HOME}/dev-team/scripts/team-account-display.sh" \
                               "${HOME}/aiteamforge/scripts/team-account-display.sh"; do
                if [[ -n "$_daa_helper" && -f "$_daa_helper" ]]; then
                    source "$_daa_helper"
                    break
                fi
            done
        fi
        if command -v atf_team_account_fields >/dev/null 2>&1; then
            local _account_fields
            _account_fields=$(atf_team_account_fields "$team" 2>/dev/null)
            if [[ "$_account_fields" == set\|* ]]; then
                local _daa_rest="${_account_fields#*|}"   # account_id|nickname|env_var
                if [[ -z "$account_id" ]]; then
                    account_id="${_daa_rest%%|*}"
                fi
                local _daa_nick="${_daa_rest#*|}"         # nickname|env_var
                if [[ -z "$account_nickname" ]]; then
                    account_nickname="${_daa_nick%%|*}"
                fi
            fi
        fi
    fi

    # Write agent data as JSON to per-session temp file
    # Uses Python for proper JSON escaping (handles apostrophes, special chars)
    # SESSION_CODE is set by the banner script (e.g., "academy-chancellor")
    local session_key="${SESSION_CODE:-${team}}"
    local tmp_dir
    tmp_dir=$(_get_lcars_tmp_dir "${session_key}")
    local json_file="${tmp_dir}lcars-agent-${session_key}.json"
    python3 -c "
import json, sys
data = {
    'team': sys.argv[1],
    'developer': sys.argv[2],
    'role': sys.argv[3],
    'location': sys.argv[4],
    'terminal': sys.argv[5],
    'terminal_desc': sys.argv[6],
    'session_desc': sys.argv[7],
    'theme': sys.argv[8],
    'avatar': sys.argv[9],
    'worktree': sys.argv[10],
    'amb_handle': sys.argv[11],
    'hostname': sys.argv[12],
    'timestamp': sys.argv[13],
    # XACA-0279: Anthropic account routing fields. Empty string = no account
    # configured; consumers should treat this as 'fall back to default OAuth'.
    'account_id': sys.argv[14],
    'account_nickname': sys.argv[15],
}
json_str = json.dumps(data, indent=4)
with open(sys.argv[16], 'w') as f:
    f.write(json_str)
if len(sys.argv) > 17 and sys.argv[17]:
    with open(sys.argv[17], 'w') as f:
        f.write(json_str)
" \
    "${team}" \
    "${developer_name}" \
    "${SESSION_ROLE:-}" \
    "${SESSION_LOCATION:-}" \
    "${TERMINAL_NAME:-}" \
    "${TERMINAL_DESCRIPTION:-}" \
    "${SESSION_DESCRIPTION:-}" \
    "${SESSION_THEME:-OPERATIONS}" \
    "${avatar_codename}" \
    "${worktree_info}" \
    "${amb_handle}" \
    "$(hostname -s 2>/dev/null || hostname)" \
    "$(date +%s)" \
    "${account_id}" \
    "${account_nickname}" \
    "${json_file}" \
    "${TERMINAL_NUMBER:+${tmp_dir}lcars-agent-${session_key}-w${TERMINAL_NUMBER}.json}"

    return 0
}

# If script is executed (not sourced), display avatar with provided arguments.
# zsh rebinds $0 to the sourced file, so the old `%x == $0` test was always true
# when a banner sourced this with its own positional args bound (XACA-1220).
# ZSH_EVAL_CONTEXT is exactly "toplevel" only for a directly executed script.
if [ -n "${ZSH_VERSION:-}" ]; then
    if [ "${ZSH_EVAL_CONTEXT:-}" = "toplevel" ]; then
        display_agent_avatar "$@"
    fi
elif [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    display_agent_avatar "$@"
fi
