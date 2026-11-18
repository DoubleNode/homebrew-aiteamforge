# CLAUDE.md Reference: Recovery Recipes

The global `~/.claude/CLAUDE.md` that AITeamForge installs is re-sent on every
turn of every Claude Code session and subagent, so it holds only the rules.
Recovery recipes that only a failing session needs live here instead
(XACA-1850). This file is installed with the formula, so the path below is
always current after `brew upgrade`:

```bash
cat "$(brew --prefix aiteamforge)/libexec/docs/CLAUDE_MD_REFERENCE.md"
```

The rules themselves (worktree rules, the PR gates, the merge invariants, the
`gh api` + `jq` rule) stay in CLAUDE.md. Nothing in this file overrides them.

## Troubleshooting

### Git

- **Forgot the feature branch:** `git checkout -b feature/my-work` from the current state.
- **Committed to develop by accident:** `git reset --soft HEAD~1`, then branch and recommit.
- **Conflicts:** merge `develop` into your branch, resolve, push.

### PR reviews and merging

- **Bot review "not detected":** query per login and WITH `--paginate` (the endpoint pages at 30):

  ```bash
  gh api --paginate repos/{owner}/{repo}/pulls/<N>/reviews --jq '.[] | select(.user.login == "ds9-tester-bot[bot]")'
  ```

  Run the same query for `ai-security-review-bot[bot]`.
- **Manual merge:** verify APPROVED reviews from BOTH bot logins and that `kb-sweep <ITEM-ID>` shows no `PROTECTED SUBITEMS UNRESOLVED`, then:

  ```bash
  gh pr merge <N> --squash --delete-branch --admin && kb-done
  ```

- **`--delete-branch` fails locally from a worktree** (the branch is checked out elsewhere), but the API merge succeeded. Check `gh pr view <N> --json state`, then `git push <remote> --delete <branch>` if needed.

### Bot commands

- **Bot command not loaded:** run the scripts directly:

  ```bash
  bash ~/.config/gh-review-bot/gh-bot-review.sh ...
  bash ~/.config/gh-tester-bot/gh-bot-test.sh ...
  ```

  Both need org-specific GitHub App setup (key + config in those directories) that this tap does not provision.
