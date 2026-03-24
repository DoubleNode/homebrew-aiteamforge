#!/bin/bash
# Claude Code Agent Tracking Helper Functions
# Source this file in your ~/.zshrc or ~/.bashrc

# Set the current agent
claude_agent() {
    if [ -z "$1" ]; then
        echo "Usage: claude_agent <agent-name>"
        echo "Example: claude_agent ios-developer"
        return 1
    fi

    echo "$1" > ~/.claude/current-agent
    echo "Agent set to: $1"

    # Update iTerm2 badge
    ~/.local/bin/claude-badge-update 2>/dev/null
}

# Clear the current agent (set to idle)
claude_idle() {
    rm -f ~/.claude/current-agent
    echo "Agent cleared - status set to idle"

    # Clear iTerm2 badge
    ~/.local/bin/claude-badge-update 2>/dev/null
}

# Show current agent
claude_status() {
    if [ -f ~/.claude/current-agent ]; then
        echo "Current agent: $(cat ~/.claude/current-agent)"
    else
        echo "No active agent (idle)"
    fi
}

# List available agents
claude_agents() {
    cat << 'EOF'
Available Claude Code Agents:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

iOS Development:
  • data                  - Data refactoring & optimization
  • captain               - Feature planning & architecture
  • geordi                - CI/CD & releases
  • doctor                - Bug fixes & debugging
  • wesley                - UX & SwiftUI design
  • worf                  - Testing & QA
  • counselor             - Documentation

General Development:
  • ios-developer         - Native iOS development
  • frontend-developer    - React/UI components
  • backend-architect     - API & system design
  • debugger              - Error diagnosis
  • code-reviewer         - Code quality review
  • test-automator        - Test suite creation

Language Specialists:
  • python-pro            - Python development
  • typescript-pro        - TypeScript development
  • rust-pro              - Rust development
  • golang-pro            - Go development
  • swift-pro             - Swift development

Infrastructure:
  • devops-troubleshooter - Production debugging
  • performance-engineer  - Performance optimization
  • security-auditor      - Security review
  • database-optimizer    - DB performance

Other:
  • general-purpose       - Multi-step tasks

Usage:
  claude_agent <name>     Set active agent
  claude_idle             Clear agent (set idle)
  claude_status           Show current agent
  claude_agents           Show this list
EOF
}

# Tmux integration - launch the status pane
claude_tmux_pane() {
    if ! command -v tmux &> /dev/null; then
        echo "Error: tmux is not installed"
        return 1
    fi

    if [ -z "$TMUX" ]; then
        echo "Error: Not in a tmux session"
        echo "Start tmux first with: tmux"
        return 1
    fi

    # Create a split pane on the right, 35 columns wide
    tmux split-window -h -l 35 ~/.local/bin/claude-status-display
}

# Export functions (not needed in zsh - functions are automatically available)
# export -f claude_agent
# export -f claude_idle
# export -f claude_status
# export -f claude_agents
# export -f claude_tmux_pane
