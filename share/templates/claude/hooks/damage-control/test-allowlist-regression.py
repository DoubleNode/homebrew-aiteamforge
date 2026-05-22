# /// script
# requires-python = ">=3.8"
# dependencies = ["pyyaml"]
# ///
r"""
Allowlist regression battery for the Bash damage-control firewall (XACA-0550).

Asserts the `check_command` decision (allow vs block) for the allowPatterns
exceptions and, critically, the chaining-smuggle vectors that MUST stay blocked
so the end-anchor / metacharacter-charset hardening can't silently regress
(PR #463: brew allow pattern once ended in `\b` not `$`; rm path once used a
bare `\S+` that swallowed `;reboot`).

Run:
  uv run test-allowlist-regression.py        # exit 0 = all pass, 1 = failure
"""
import importlib.util
import sys
from pathlib import Path

import yaml

_DIR = Path(__file__).parent
spec = importlib.util.spec_from_file_location("bash_tool", _DIR / "bash-tool-damage-control.py")
bash_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bash_tool)
config = yaml.safe_load(open(_DIR / "patterns.yaml")) or {}

# (command, expected_blocked) — True = must block, False = must be allowed.
CASES = [
    # --- Homebrew maintenance: must be ALLOWED ---
    ("brew cleanup node", False),
    ("brew cleanup", False),
    ("brew cleanup --prune=all", False),            # flag with '='
    ("brew uninstall foo bar", False),              # multiple args
    ("brew untap doublenode/aiteamforge", False),   # arg with '/'
    ("rm /opt/homebrew/bin/claude", False),
    ("sudo rm -rf /opt/homebrew/Cellar/node/24.10.0", False),
    ("rm -rf /opt/homebrew/lib/node_modules/@anthropic-ai", False),  # '@','-'
    ("sudo rm -rf /opt/homebrew/Cellar/node/24.10.0 /opt/homebrew/Cellar/node/25.6.1_1", False),
    # --- Absolute-path anchoring: /opt/homebrew/bin is NOT system /bin ---
    ("cp /tmp/x /opt/homebrew/bin/foo", False),
    ("ls -la /opt/homebrew/bin/claude", False),
    # --- Real danger / system paths / secrets: must STILL BLOCK ---
    ("rm -rf /", True),
    ("rm -rf ~", True),
    ("rm /bin/ls", True),
    ("cp /tmp/x /bin/foo", True),
    ("rm /usr/bin/python3", True),
    ("sudo rm -rf /etc", True),
    ("rm ~/.ssh/id_rsa", True),
    ("cat ~/.ssh/id_rsa", True),
    ("git reset --hard", True),
    ("chmod 777 /opt/homebrew/bin/foo", True),
    # --- Whole-prefix nuke must NOT be allowlisted ---
    ("rm -rf /opt/homebrew", True),
    ("rm -rf /opt/homebrew/", True),
    # --- rm allowlist: chaining smuggle (spaces) must NOT slip through ---
    ("rm -rf /opt/homebrew/Cellar/x && rm -rf ~/.ssh", True),
    ("rm -rf /opt/homebrew/Cellar/x ; rm -rf /etc", True),
    ("rm -rf /opt/homebrew/Cellar/x && cat ~/.ssh/id_rsa", True),
    # --- rm allowlist: NO-SPACE metacharacter smuggle (the bare \S+ hole) ---
    ("rm -rf /opt/homebrew/Cellar/x;reboot", True),
    ("rm /opt/homebrew/Cellar/x|cat ~/.ssh/id_rsa", True),
    ("rm /opt/homebrew/Cellar/x&&cat ~/.ssh/id_rsa", True),
    # --- brew allowlist: chaining smuggle (the \b-not-$ defect, PR #463) ---
    ("brew cleanup && rm ~/.ssh/id_rsa", True),
    ("brew cleanup && cat ~/.ssh/id_rsa", True),
    ("brew cleanup && git reset --hard", True),
    ("brew cleanup ; cat ~/.ssh/id_rsa", True),
    ("brew cleanup;rm -rf ~/.ssh", True),
    ("brew cleanup&&cat ~/.ssh/id_rsa", True),
    ("brew cleanup | rm -rf /", True),
]


def main() -> int:
    fails = 0
    for cmd, want_blocked in CASES:
        blocked, _ask, reason = bash_tool.check_command(cmd, config)
        ok = bool(blocked) == want_blocked
        if not ok:
            fails += 1
            want = "BLOCK" if want_blocked else "ALLOW"
            got = "BLOCK" if blocked else "ALLOW"
            print(f"FAIL: want={want} got={got}  {cmd!r}  ({reason})")
    total = len(CASES)
    if fails:
        print(f"{fails} FAILURE(S) of {total}")
        return 1
    print(f"ALL PASS ({total} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
