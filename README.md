# Omarchy Nav for Tern

One set of keys for Tern panes and Hyprland windows on Omarchy, like vim-tmux-navigator.
**Super+arrows** move between the panes of the current Tern tab. At the tab's edge the move bubbles
up to Hyprland and focus goes to the next window. Coming into Tern from another window lands on the
pane on the edge you came in through.

## How it works

- **Hyprland** (`hypr/tern-nav.lua`) replaces Omarchy's Super+arrow focus binds with Lua binds. If
  the active window is Tern (class `so.stencil.tern`), the bind injects Super+arrow into Tern.
  Otherwise it moves focus as before. If that move lands on Tern, it also injects
  Super+Ctrl+Shift+arrow, the "entered" chord.
- **Tern** (`window.luau`) works out the pane rectangles from the tab's split tree (`lib/geometry.luau`).
  It focuses the neighbour in that direction, or, when there is none, runs
  `hyprctl dispatch 'hl.dsp.focus({ direction = "l" })'` so Hyprland moves on from Tern. A zoomed
  tab or a floating pane always bubbles. On the "entered" chord it keeps the focused pane if it is
  on the near edge, else focuses the edge pane closest to it.

## Install

```sh
tern plugin link ~/src/tern-omarchy-nav
```

Then load the Hyprland side from `~/.config/hypr/bindings.lua`:

```lua
dofile(os.getenv("HOME") .. "/src/tern-omarchy-nav/hypr/tern-nav.lua")
```

Validate it with `hyprctl reload && hyprctl configerrors`. To go back to Omarchy's plain focus
binds, remove that line.

## Keys

| Key | Where | Does |
| --- | --- | --- |
| Super+← → ↑ ↓ | everywhere | Next Tern pane in that direction, else the next window |
| Super+W | everywhere | In Tern: close the focused pane with Tern's normal close, which asks first if something is running. On the session's last pane it closes the Tern window instead; the session daemon keeps your programs. Elsewhere: close the window |
| Super+Shift+A | everywhere | In Tern: new agent block beside the focused pane (Tern's "New agent block"). Elsewhere: ChatGPT, as before |
| Super+Ctrl+Shift+arrow | Tern only, sent by Hyprland | Internal "focus entered Tern" signal; you don't press it |

Super+Alt+←/→ are taken by Tern's preset keys, so they couldn't be used for the "entered" signal.
