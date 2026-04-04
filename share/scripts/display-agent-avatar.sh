#!/bin/zsh
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
# Returns:
#   0 - Success
#   1 - Error (invalid arguments)

# Source the shared LCARS tmp dir helper (resolve path relative to this script)
SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/lcars-tmp-dir.sh"

display_agent_avatar() {
    local team="${1}"
    local developer_name="${2//\\/}"

    # Validate required arguments
    if [[ -z "$team" || -z "$developer_name" ]]; then
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

        # iOS team (TNG)
        "ios:Captain Jean-Luc Picard") avatar_codename="picard"; amb_handle="captain-picard" ;;
        "ios:Lt Cmdr Data"|"ios:Lt. Cmdr. Data"|"ios:Lieutenant Commander Data") avatar_codename="data"; amb_handle="lt-cmdr-data" ;;
        "ios:Chief Engineer Geordi La Forge"|"ios:Lieutenant Commander Geordi La Forge") avatar_codename="geordi"; amb_handle="geordi-laforge" ;;
        "ios:Lt Cmdr Worf"|"ios:Lt. Cmdr. Worf"|"ios:Lieutenant Worf") avatar_codename="worf"; amb_handle="batleth" ;;
        "ios:Counselor Deanna Troi") avatar_codename="deanna"; amb_handle="counselor-troi" ;;
        "ios:Dr Beverly Crusher"|"ios:Dr. Beverly Crusher"|"ios:Doctor Beverly Crusher") avatar_codename="beverly"; amb_handle="beverly-crusher" ;;
        "ios:Wesley Crusher") avatar_codename="wesley"; amb_handle="wesley-crusher" ;;

        # Android team (TOS)
        "android:Captain James T. Kirk") avatar_codename="kirk"; amb_handle="kirk" ;;
        "android:Commander Spock") avatar_codename="spock"; amb_handle="spock" ;;
        "android:Chief Engineer Montgomery Scott"|"android:Lieutenant Commander Montgomery Scott") avatar_codename="scotty"; amb_handle="scotty" ;;
        "android:Lt. Nyota Uhura"|"android:Lieutenant Uhura"|"android:Lieutenant Nyota Uhura") avatar_codename="uhura"; amb_handle="uhura" ;;
        "android:Lieutenant Hikaru Sulu") avatar_codename="sulu"; amb_handle="sulu" ;;
        "android:Ensign Pavel Chekov") avatar_codename="chekov"; amb_handle="chekov" ;;
        "android:Dr. Leonard McCoy"|"android:Doctor Leonard McCoy") avatar_codename="mccoy"; amb_handle="mccoy" ;;

        # Firebase team (DS9)
        "firebase:Commander Benjamin Sisko"|"firebase:Captain Benjamin Sisko") avatar_codename="sisko"; amb_handle="captain-sisko" ;;
        "firebase:Major Kira Nerys") avatar_codename="kira"; amb_handle="kira-nerys" ;;
        "firebase:Chief Miles O'Brien"|firebase:"Chief Miles O\'Brien") avatar_codename="obrien"; amb_handle="chief-obrien" ;;
        "firebase:Lt. Commander Jadzia Dax"|"firebase:Lieutenant Jadzia Dax") avatar_codename="dax"; amb_handle="dax" ;;
        "firebase:Dr. Julian Bashir"|"firebase:Doctor Julian Bashir") avatar_codename="bashir"; amb_handle="bashir" ;;
        "firebase:Constable Odo") avatar_codename="odo"; amb_handle="constable-odo" ;;
        "firebase:Quark") avatar_codename="quark"; amb_handle="quark" ;;

        # Finance team (Ferengi Commerce Authority)
        "finance:Grand Nagus Zek") avatar_codename="zek"; amb_handle="grand-nagus-zek" ;;
        "finance:Quark") avatar_codename="quark-fin"; amb_handle="quark-fin" ;;
        "finance:Nog") avatar_codename="nog"; amb_handle="nog" ;;
        "finance:Brunt") avatar_codename="brunt"; amb_handle="brunt-fca" ;;
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

        # Freelance team (Enterprise)
        "freelance:Captain Jonathan Archer") avatar_codename="archer"; amb_handle="captain-archer" ;;
        "freelance:Commander Charles 'Trip' Tucker III") avatar_codename="tucker"; amb_handle="tucker" ;;
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

        *) return 0 ;;
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

    # Derive section label for panel section header (e.g., "CHANCELLOR'S OFFICE").
    # Use TERMINAL_DESCRIPTION workspace name (strip " at ..." suffix) or fall back
    # to the office part of SESSION_LOCATION (after ": ").
    local section_label=""
    if [[ -n "${TERMINAL_DESCRIPTION:-}" ]]; then
        # Strip " at <team name>" suffix if present (e.g. "Chancellor's Office at Starfleet Academy")
        section_label="${TERMINAL_DESCRIPTION%% at *}"
        section_label="${(U)section_label}"
    elif [[ "${SESSION_LOCATION:-}" == *": "* ]]; then
        section_label="${SESSION_LOCATION#*: }"
        section_label="${(U)section_label}"
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
    'section': sys.argv[8],
    'theme': sys.argv[9],
    'avatar': sys.argv[10],
    'worktree': sys.argv[11],
    'amb_handle': sys.argv[12],
    'timestamp': sys.argv[13]
}
json_str = json.dumps(data, indent=4)
with open(sys.argv[14], 'w') as f:
    f.write(json_str)
if len(sys.argv) > 15 and sys.argv[15]:
    with open(sys.argv[15], 'w') as f:
        f.write(json_str)
" \
    "${team}" \
    "${developer_name}" \
    "${SESSION_ROLE:-}" \
    "${SESSION_LOCATION:-}" \
    "${TERMINAL_NAME:-}" \
    "${TERMINAL_DESCRIPTION:-}" \
    "${SESSION_DESCRIPTION:-}" \
    "${section_label}" \
    "${SESSION_THEME:-OPERATIONS}" \
    "${avatar_codename}" \
    "${worktree_info}" \
    "${amb_handle}" \
    "$(date +%s)" \
    "${json_file}" \
    "${TERMINAL_NUMBER:+${tmp_dir}lcars-agent-${session_key}-w${TERMINAL_NUMBER}.json}"

    return 0
}

# If script is executed (not sourced), display avatar with provided arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${(%):-%x}" == "${0}" ]] 2>/dev/null; then
    display_agent_avatar "$@"
fi
