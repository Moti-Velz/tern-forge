---
name: forge-links
description: >-
  Look up and change how worktrees, branches, Linear tickets and GitHub pull requests are linked
  (Forge's store, shown in Tern's Projects panel). Use when you need the worktree, branch, ticket or
  PR for any one of them you have on hand, for example "which worktree is ENG-123", "what ticket is
  this branch", "where is PR #58", "list my worktrees with their PRs". Also use when asked to link,
  attach or unlink a ticket for a worktree/branch, or when you start work on a ticket in an unlinked
  worktree.
---

# Forge links: worktree ↔ ticket ↔ PR

Each row is one Git worktree. It has a branch, the Linear ticket linked to that branch and the
branch's pull request. Rows cover every project in Forge (the repos in Tern's Projects panel); with
`--repo` they cover just one.

- **Tickets** are stored in Git as `branch.<branch>.forge-ticket`, an id like `ENG-123` or the issue
  URL. The setting is repository-local and never pushed. Forge's panel reads and writes the same
  setting.
- **PRs** come from `gh` by branch. They're looked up, never stored. An open PR wins over older
  closed ones.

Use the `forge-links` command:

```bash
forge-links list [--repo PATH] [--no-prs] [--json]   # every worktree with its ticket and PR
forge-links show KEY [--json]                       # the row(s) KEY names
forge-links link KEY TICKET                         # link KEY's branch to a ticket (ENG-123 or URL)
forge-links unlink KEY                              # remove the link
```

`KEY` is whatever you have:

| You have | Example |
| --- | --- |
| a worktree path, or a path inside it | `.` · `~/Work/repos/app-feature` · `src/main.ts` |
| a branch | `feat/api-keys` |
| a ticket id or Linear URL | `ENG-123` · `https://linear.app/acme/issue/ENG-123/…` |
| a PR number or URL | `58` · `#58` · `https://github.com/acme/app/pull/58` |

A ticket key finds linked branches first, then a branch whose name contains the id. Use `--json`
when you need fields: `project`, `repo`, `worktree`, `branch`, `primary`,
`ticket {id, url, link}` and `pr {number, state, url, title}`. `--no-prs` skips GitHub, which is
faster, but PR keys won't resolve.

## Examples

```bash
forge-links show .                       # this worktree: branch, ticket, PR
forge-links show ENG-123 --json          # where ENG-123 is being worked on
forge-links show 58                      # which worktree/branch PR #58 is
forge-links link . ENG-123               # link the worktree you're in
forge-links link 58 https://linear.app/acme/issue/ENG-123/fix-login
forge-links unlink ENG-123
```

## Rules

- **Don't invent tickets.** Link only an id or URL the user gave, or one from the branch name, a
  commit or the issue you were asked to work on. If none is clear, ask.
- **Ambiguous keys:** if a key matches several worktrees (for example `main` across projects),
  `link` and `unlink` refuse. Pass a path, a PR URL or `--repo`.
- **Detached HEAD:** the worktree has no branch to link. Tell the user rather than working around it.
- **One ticket per branch:** linking again replaces the old link.
- **Without the command** (for example on another machine), the store is plain Git:
  `git config "branch.$(git branch --show-current).forge-ticket" ENG-123`, and `--unset` to remove.
- The Projects panel shows a change on its next refresh (↻, or within about 15 seconds).
