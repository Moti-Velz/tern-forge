# tern-factory

A software factory for Tern: what to build comes in from meetings and email, gets
worked on by agents in their own worktrees, ships as pull requests, and comes back as feedback.
Every step stays one keystroke from the terminal.

```mermaid
flowchart LR
  M[Meetings and email] -->|context| A[Agent]
  T[Ticket or PR] -->|Forge: one box| W[Worktree + session]
  W --> A
  A --> PR[Pull request]
  PR --> R[Release]
  R -->|feedback| M
```

Each part is its own Tern plugin. Install only what you use; they work alone and get better together.

| Plugin | What it does | Install |
|---|---|---|
| [**Forge**](forge/) | Projects sidebar: repositories, their Git worktrees, a session per worktree, PRs and linked tickets. One box opens or creates a worktree from a branch, a ticket or a PR. Also shows Claude and ChatGPT subscription usage. | `tern plugin install github.com/Moti-Velz/tern-factory/forge` |
| [**Meetings**](meetings/) | Notes, transcripts and email threads from Granola, Fireflies, IMAP or a folder of exports, gathered from the keyboard and pasted into your agent. | `tern plugin install github.com/Moti-Velz/tern-factory/meetings` |
| [**Omarchy**](omarchy/) | Tern on [Omarchy](https://omarchy.org/)/Hyprland: window keys act on Tern panes first and pass to Hyprland at the edge; desktop notifications when agents finish or need you. | `tern plugin install github.com/Moti-Velz/tern-factory/omarchy` |

To hack on them, clone once and link the plugins you want. Linked plugins reload when their source
changes:

```sh
git clone https://github.com/Moti-Velz/tern-factory ~/src/tern-factory
tern plugin link ~/src/tern-factory/forge
tern plugin link ~/src/tern-factory/meetings
```

## How they fit together

Tern plugins can't run each other's commands, so they share plain, documented contracts instead.
Anything else (an agent, a script, Carly) can use the same ones.

| Contract | Owner | Used by |
|---|---|---|
| `git config branch.<branch>.forge-ticket <ENG-123 or Linear URL>` links a branch to its ticket. Repository-local, never pushed. | Forge | Forge's Open box and **Link ticket**, `forge-links`, agents |
| `forge-links list / show / link / unlink KEY`: every worktree with its branch, ticket and PR, by any key (path, branch, ticket, PR number or URL). | [forge/bin/forge-links](forge/bin/forge-links), skill [forge/skills/forge-links](forge/skills/forge-links) | Agents |
| Carly exports `worktrees(key?)` and `link_ticket(key, ticket?)` | Forge | Carly |
| Bracketed paste into the agent's composer (long content goes to a file and is referenced) | Meetings | Any agent in Tern |
| Forge's key, Super+Alt+Shift+P, toggles Projects | Forge | Omarchy's Super+B |

## Layout

Each directory is a complete plugin with its own `plugin.toml`, README, changelog and tests. The
histories of the original repositories (`tern-forge`, `tern-meetings`, `tern-omarchy`) are kept in
full. Plugins are versioned on their own: tags look like `forge-v3.2.0`.

## License

MIT. See [LICENSE](LICENSE). Forge started as a fork of
[Overseer](https://github.com/mmnavarr/overseer) and keeps its original notice in
[forge/LICENSE](forge/LICENSE).
