#!/bin/bash
# Claude Code Agent Aliases
# Quick shortcuts to switch between different agent personas

# Installation directory (substituted during install)
AITEAMFORGE_DIR="{{AITEAMFORGE_DIR}}"

#──────────────────────────────────────────────────────────────────────────────
# Main Agent Switcher Function
#──────────────────────────────────────────────────────────────────────────────

claude_agent() {
    local agent="$1"

    if [ -z "$agent" ]; then
        echo "Usage: claude_agent <agent-name>"
        echo "See claude-help for available agents"
        return 1
    fi

    # Check if update script exists in AITEAMFORGE_DIR
    if [ -f "$AITEAMFORGE_DIR/update_claude_agent.sh" ]; then
        "$AITEAMFORGE_DIR/update_claude_agent.sh" "$agent"
    else
        echo "Agent switcher not installed at: $AITEAMFORGE_DIR/update_claude_agent.sh"
        echo "Run: aiteamforge-setup to install team configurations"
        return 1
    fi
}

#──────────────────────────────────────────────────────────────────────────────
# iOS Team Aliases (TNG)
#──────────────────────────────────────────────────────────────────────────────

claude-geordi() { claude_agent "geordi"; }      # Release engineer
claude-data() { claude_agent "data"; }          # Refactoring specialist
claude-worf() { claude_agent "worf"; }          # Security/Testing
claude-wesley() { claude_agent "wesley"; }      # UX/Interface
claude-doctor() { claude_agent "doctor"; }      # Bug fixes
claude-crusher() { claude_agent "doctor"; }     # Bug fixes (alias)
claude-captain() { claude_agent "captain"; }    # Feature development
claude-picard() { claude_agent "captain"; }     # Feature development (alias)
claude-counselor() { claude_agent "counselor"; } # Documentation
claude-troi() { claude_agent "counselor"; }     # Documentation (alias)

#──────────────────────────────────────────────────────────────────────────────
# Firebase Team Aliases (DS9)
#──────────────────────────────────────────────────────────────────────────────

claude-sisko() { claude_agent "sisko"; }        # Lead feature developer
claude-kira() { claude_agent "kira"; }          # Bug fix developer
claude-odo() { claude_agent "odo"; }            # Lead tester
claude-dax() { claude_agent "dax"; }            # Refactoring specialist
claude-bashir() { claude_agent "bashir"; }      # Documentation expert
claude-obrien() { claude_agent "obrien"; }      # Release engineer
claude-quark() { claude_agent "quark"; }        # UX expert

#──────────────────────────────────────────────────────────────────────────────
# Android Team Aliases (TOS)
#──────────────────────────────────────────────────────────────────────────────

claude-kirk() { claude_agent "kirk"; }          # Lead feature developer
claude-spock() { claude_agent "spock"; }        # Refactoring specialist
claude-mccoy() { claude_agent "mccoy"; }        # Bug fix developer
claude-scotty() { claude_agent "scotty"; }      # Release engineer
claude-uhura() { claude_agent "uhura"; }        # UX expert
claude-chekov() { claude_agent "chekov"; }      # Lead tester
claude-sulu() { claude_agent "sulu"; }          # Documentation expert

#──────────────────────────────────────────────────────────────────────────────
# Freelance Team Aliases (ENT)
#──────────────────────────────────────────────────────────────────────────────

claude-archer() { claude_agent "captain"; }     # Lead feature developer
claude-tucker() { claude_agent "geordi"; }      # Release engineer
claude-trip() { claude_agent "geordi"; }        # Release engineer (alias)
claude-tpol() { claude_agent "data"; }          # Refactoring specialist
claude-phlox() { claude_agent "doctor"; }       # Bug fix developer
claude-reed() { claude_agent "worf"; }          # Security/Testing
claude-sato() { claude_agent "counselor"; }     # Documentation expert
claude-mayweather() { claude_agent "wesley"; }  # UX expert

#──────────────────────────────────────────────────────────────────────────────
# Academy Team Aliases (32nd Century)
#──────────────────────────────────────────────────────────────────────────────

claude-ake() { claude_agent "academy-chancellor"; }     # Strategic leadership
claude-nahla() { claude_agent "academy-chancellor"; }   # Strategic leadership (alias)
claude-reno() { claude_agent "academy-engineer"; }      # Development & infrastructure
claude-emh() { claude_agent "academy-instructor"; }     # Documentation & training
claude-thok() { claude_agent "academy-cadetmaster"; }   # Testing & validation

#──────────────────────────────────────────────────────────────────────────────
# Command Team Aliases (Starfleet Command)
#──────────────────────────────────────────────────────────────────────────────

claude-vance() { claude_agent "command-admiral"; }          # Cross-platform coordination
claude-ross() { claude_agent "command-operations"; }        # Release management
claude-nechayev() { claude_agent "command-strategic"; }     # Architecture & planning
claude-command-janeway() { claude_agent "command-communications"; } # Stakeholder mgmt
claude-command-paris() { claude_agent "command-intelligence"; }     # Analytics

#──────────────────────────────────────────────────────────────────────────────
# MainEvent Team Aliases (Voyager)
#──────────────────────────────────────────────────────────────────────────────

claude-janeway() { claude_agent "janeway"; }            # Lead feature developer
claude-torres() { claude_agent "torres"; }              # Release engineer & CI/CD
claude-belanna() { claude_agent "torres"; }             # Release engineer (alias)
claude-seven() { claude_agent "seven"; }                # Lead refactoring developer
claude-seven-of-nine() { claude_agent "seven"; }        # Refactoring (alias)
claude-emh-doctor() { claude_agent "doctor"; }          # Bug fix developer
claude-tuvok() { claude_agent "tuvok"; }                # Security & test lead
claude-kim() { claude_agent "kim"; }                    # Documentation lead
claude-harry-kim() { claude_agent "kim"; }              # Documentation (alias)
claude-paris() { claude_agent "paris"; }                # UX/UI developer
claude-tom-paris() { claude_agent "paris"; }            # UX/UI (alias)

#──────────────────────────────────────────────────────────────────────────────
# DNS Framework Team Aliases (Lower Decks)
#──────────────────────────────────────────────────────────────────────────────

claude-mariner() { claude_agent "dns-mariner"; }            # Lead feature developer
claude-tana() { claude_agent "dns-tana"; }                  # Bug fix developer
claude-dr-tana() { claude_agent "dns-tana"; }               # Bug fix (alias)
claude-shaxs() { claude_agent "dns-shaxs"; }                # Lead tester
claude-rutherford() { claude_agent "dns-rutherford"; }      # Release engineer
claude-sam-rutherford() { claude_agent "dns-rutherford"; }  # Release (alias)
claude-tendi() { claude_agent "dns-tendi"; }                # Lead refactoring
claude-boimler() { claude_agent "dns-boimler"; }            # API design expert
claude-brad-boimler() { claude_agent "dns-boimler"; }       # API design (alias)
claude-ransom() { claude_agent "dns-ransom"; }              # Documentation lead
claude-jack-ransom() { claude_agent "dns-ransom"; }         # Documentation (alias)

#──────────────────────────────────────────────────────────────────────────────
# Generic Agent Aliases
#──────────────────────────────────────────────────────────────────────────────

claude-dev() { claude_agent "ios-developer"; }
claude-debug() { claude_agent "debugger"; }
claude-test() { claude_agent "test-automator"; }
claude-review() { claude_agent "code-reviewer"; }
claude-deploy() { claude_agent "deployment-engineer"; }
claude-general() { claude_agent "general-purpose"; }

#──────────────────────────────────────────────────────────────────────────────
# Status Display
#──────────────────────────────────────────────────────────────────────────────

claude-status() {
    echo ""
    echo "🎭 Claude Code Status:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -n "$TMUX" ]; then
        local agent=$(tmux show-options -v @claude_agent 2>/dev/null)
        local worktree=$(tmux show-options -v @current_worktree 2>/dev/null)

        echo "🤖 Agent: ${agent:-none}"
        echo "🌿 Worktree: ${worktree:-none}"

        if [ -n "$CURRENT_WORKTREE" ]; then
            echo "📂 Location: $PWD"
            git branch --show-current 2>/dev/null | sed 's/^/🌱 Branch: /'
        fi
    else
        echo "⚠️  Not running in tmux"
    fi
    echo ""
}

#──────────────────────────────────────────────────────────────────────────────
# Help
#──────────────────────────────────────────────────────────────────────────────

claude-help() {
    echo ""
    echo "🚀 AITeamForge Claude Code Agent Aliases"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "iOS (TNG):       claude-geordi, claude-data, claude-worf, claude-wesley"
    echo "                 claude-doctor, claude-captain, claude-counselor"
    echo ""
    echo "Firebase (DS9):  claude-sisko, claude-kira, claude-odo, claude-dax"
    echo "                 claude-bashir, claude-obrien, claude-quark"
    echo ""
    echo "Android (TOS):   claude-kirk, claude-spock, claude-mccoy, claude-scotty"
    echo "                 claude-uhura, claude-chekov, claude-sulu"
    echo ""
    echo "Freelance (ENT): claude-archer, claude-tucker, claude-tpol, claude-phlox"
    echo "                 claude-reed, claude-sato, claude-mayweather"
    echo ""
    echo "Academy (32nd):  claude-ake, claude-reno, claude-emh, claude-thok"
    echo ""
    echo "Command (DSC):   claude-vance, claude-ross, claude-nechayev"
    echo "                 claude-command-janeway, claude-command-paris"
    echo ""
    echo "MainEvent (VOY): claude-janeway, claude-torres, claude-seven"
    echo "                 claude-emh-doctor, claude-tuvok, claude-kim, claude-paris"
    echo ""
    echo "DNS (LD):        claude-mariner, claude-tana, claude-shaxs, claude-rutherford"
    echo "                 claude-tendi, claude-boimler, claude-ransom"
    echo ""
    echo "Generic:         claude-dev, claude-debug, claude-test, claude-review"
    echo "                 claude-deploy, claude-general"
    echo ""
    echo "Status:          claude-status (show current agent and worktree)"
    echo ""
}

echo "✓ Agent aliases loaded (use 'claude-help' for list)"
