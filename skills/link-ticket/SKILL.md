---
name: link-ticket
description: >-
  Link the current Git worktree/branch to a Linear ticket (or unlink it) so Forge's Projects
  panel in Tern shows the ticket badge. Use when the user says to link, attach, associate or set
  a ticket/issue (ENG-123, a linear.app URL) for this worktree, workspace or branch, or when you
  start work on a ticket in a worktree that isn't linked yet.
---

# Link a worktree to a Linear ticket

Forge keeps one ticket per branch in the repository's Git config, under
`branch.<branch>.forge-ticket`. It's local to the repository: it's never pushed and nothing else
uses it. Forge reads it on every refresh. The Projects panel shows the ticket badge next to the
worktree, and clicking the badge opens the issue. Forge doesn't store it anywhere else, and doesn't
write it to Orca or Linear.

## Link

Run this from inside the worktree. `--show-current` names the branch checked out there.

```bash
branch=$(git branch --show-current)
git config "branch.$branch.forge-ticket" ENG-123
```

The value is a Linear identifier (`ENG-123`, team key and number in capitals) or the issue's full
URL (`https://linear.app/acme/issue/ENG-123/...`). Prefer the URL when you have it: it links
correctly even when Forge doesn't know the project's Linear workspace.

## Check or unlink

```bash
git config --get "branch.$(git branch --show-current).forge-ticket"   # prints the link; exit 1 if none
git config --unset "branch.$(git branch --show-current).forge-ticket" # unlink
```

## Rules

- **One ticket per branch.** Setting it again replaces the old link.
- **Detached HEAD:** `git branch --show-current` prints nothing. Stop and tell the user the worktree
  has no branch to link. Don't link `branch..forge-ticket`.
- **Validate:** don't invent ticket ids. Use the id or URL the user gave, or one from the branch
  name, a commit or the issue you were asked to work on. If none is clear, ask.
- **Other worktrees:** to link one you aren't in, run the same command with
  `git -C <worktree path>`, or name the branch directly. All worktrees share one repository config.
- **Showing up:** the badge appears on the panel's next refresh (↻, or within about 15 seconds).
  Nothing else needs to run.
