# Changelog

## 2.1.0 (2026-10-12)

Worktrunk is now optional. Each project uses one of three worktree backends, picked automatically: Orca, Worktrunk or plain Git.

### Added

- **Orca backend.** When Orca's CLI is found and Orca has the project registered, worktrees are created and removed through Orca, so they show in Orca's app. Orca picks the directory and branch name and runs its own setup.
- **Plain Git backend.** Without Orca or Worktrunk, worktrees are created with `git worktree add` beside the primary checkout, and the repo's `orca.yaml` setup and archive scripts run.
- **Add project from Orca.** A palette command lists Orca's registered repositories that aren't in Projects yet. It appears only when Orca's CLI is found.
- **Orca details on rows.** For Orca-registered projects, the hover shows Orca's board status and comment, Orca's display name is used when you haven't named the row, and Orca's linked Linear issue can supply the ticket badge when the branch has no ticket id.
- **Linux.** The panel works on Linux (tested on Wayland with Tern 0.8.3). The folder picker uses zenity, else kdialog, else a typed path prompt (`~` expands); cancel is silent.
- **Clearer create form.** The New worktree form says what will run.

### Changed

- **Worktrunk is optional.** Each project uses Orca when available, then Worktrunk when `wt` is on PATH, then plain Git. The choice is rechecked at most once a minute and on ↻.
- **Listing reads git directly** for the Git and Orca backends. Worktrunk still uses `wt list`. Bare and prunable worktrees are skipped.
- **Only Orca may delete a branch.** Worktrunk and plain Git always keep it; Orca may delete it when it can prove it merged, under its own policy.
- **Tests cover every backend.** Removal-safety tests run for plain Git and, when `wt` is installed, for Worktrunk.

### Upgrading

Nothing to do. If Orca's CLI is installed and has a project registered, new worktrees for that project go through Orca. Other projects use Worktrunk when `wt` is on PATH, and plain Git otherwise.

### Trade-offs

The Orca backend needs Orca running. A project registered in Orca while Orca is closed falls back to Worktrunk or plain Git, and Orca then hides those worktrees as external.

## 2.0.0 (2026-10-09)

The Projects panel is now one panel per window that follows you, instead of one panel per worktree session.

### Changed

- **The panel follows you.** It sits on the left of whichever tab you're looking at, in any session, and comes along when you switch tabs, open a tab or open a worktree. Before, each worktree session had its own panel beside its first terminal, and a new tab started without one.
- **Your width travels with it.** Drag the panel's edge once; every tab uses that width, and it's remembered across restarts. It starts at 30% of the tab.
- **Forms follow too.** New worktree, Rename, Change base branch and Set Linear workspace still open in the panel's place, and now move with it.
- **The shortcut shows or hides.** <kbd>⌘</kbd><kbd>⌥</kbd><kbd>⇧</kbd><kbd>P</kbd> shows and focuses the panel, or hides it when it already has focus. The command is now **Show or hide Projects**. A hidden panel stays hidden in new tabs until you show it again.
- **Opening a worktree no longer opens a panel in its session.** The one panel moves there instead.
- **Closing the last terminal in a tab** closes the tab as Tern normally does; the panel moves to the tab shown next.
- **Close session** (from Overseer) moves the panel out of the session first. If Tern closes the session holding the panel, Overseer reopens the panel in the next tab you see, unless you had closed it yourself.

### Upgrading

Nothing to do. The first time 2.0 runs, it keeps one of the panels you already had open and closes the others.

### Trade-offs

Tern plugins can't add a window-level sidebar, so the panel is a regular pane that moves between tabs. Each switch briefly animates, and resizes the terminals in the tab you leave and the tab you arrive in. In a tab split top-and-bottom, the panel sits beside the top half.

## 1.10.2 (2026-10-08)

- Slightly smaller type across the panel and forms, a smaller **Projects** heading, and no divider under the header.

## 1.10.1 (2026-10-08)

- First public release: projects and Worktrunk worktrees with a Tern session per worktree, agent activity, pull request and Linear ticket badges, background creation and deletion, Ice Box, ticket worktrees from Carly, and Visualize PR.
- Ticket links use Linear's official logo mark.
