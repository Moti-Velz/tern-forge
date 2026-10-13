# Changelog

## 3.1.0 (2026-10-12)

### Changed

- **Orca projects appear on their own.** Every repository registered in Orca joins Projects when Tern starts (or Forge reloads) and on ↻. Nothing is asked, and one toast names what was added. Projects only grows: a repository already listed is left as it is. **Add project from Orca** is still in the palette.
- **The Projects panel is a sidebar.** It opens 40 columns wide instead of 30% of the tab, which was over 1000 px on wide screens. The width you drag it to is remembered in columns (`panel-columns`, 20–120), and a panel left open from an older version is narrowed once when Forge loads.

## 3.0.0 (2026-10-12)

The plugin is now called Forge, and it adds subscription usage. This release is breaking: it has a new id, new action names and a new data directory.

### Renamed

- **Breaking: new id, actions and data directory.** The plugin id is `forge`. Actions are now `plugin.forge.*` (for example `plugin.forge.projects`), blocks are `forge.form` and `forge.usage`, and plugin data lives under `plugin-data/forge`.
- **Overseer's KV and settings don't carry over.** Forge doesn't read them, so projects, names, sessions and Ice Box entries need to be set up again.

### Added

- **Subscription usage in the status bar.** Forge's status formatter shows usage first, like `5h 2% (1h56m) · 7d 3%`, with a sparkle icon. It's tinted warn at 60% and error at 85% of the worst window. Clicking it opens the usage panel. A muted **Projects** segment follows and toggles the Projects panel.
- **Usage panel** (block `forge.usage`, docked beside the focused pane rather than floating, so its text renders at full sharpness and nothing is cut off). Shows Claude Pro/Max (5 h, 7 d, per-model weekly, extra usage) and ChatGPT/Codex (5 h, 7 d, credits) for every account. Accounts come from Claude Code and Codex CLI credentials, omp logins, and in-plugin OAuth logins, with aliases, hiding, ordering, pinning to the status bar, compact and card layouts, and a cross-account summary. It polls in the background even when the panel is closed.
- **Usage palette commands.** "Subscription usage (Claude / GPT): show or hide the panel" (`plugin.forge.usage`), "Claude usage: sign in to a subscription account (several allowed)" (`plugin.forge.usage-login`), and "GPT usage: sign in to a ChatGPT account (several allowed)" (`plugin.forge.usage-login-gpt`).
- **Status bar turned on once.** On first load, Forge turns Tern's status bar on and shows a toast. If you turn it off in Preferences, it stays off (kv flag `status-bar-offered`).

Usage is integrated from [tern-claude-usage](https://github.com/zerx-lab/tern-claude-usage) by zerx-lab (MIT), kept in `usage/` with its own LICENSE. The UI is translated to English.

Note: like upstream, usage can write refreshed OAuth tokens back to Claude Code's `~/.claude/.credentials.json` (and Codex's credentials) when it refreshes them.

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
