-- Tern-aware Super+arrow focus for Omarchy (tern-omarchy-nav).
--
-- Load from ~/.config/hypr/bindings.lua:
--   dofile(os.getenv("HOME") .. "/src/tern-omarchy-nav/hypr/tern-nav.lua")
--
-- Super+arrow on a Tern window is handed to Tern, which moves between its panes and bubbles back
-- with `hyprctl dispatch` at its edge. Anywhere else Hyprland moves focus as usual, and when that
-- lands on Tern it tells Tern which way you came in (Super+Ctrl+Shift+arrow), so the pane on that edge
-- gets focus.

local TERN_CLASS = "so.stencil.tern"

local KEYS = {
  { key = "LEFT", dir = "l", name = "left" },
  { key = "RIGHT", dir = "r", name = "right" },
  { key = "UP", dir = "u", name = "above" },
  { key = "DOWN", dir = "d", name = "below" },
}

local function is_tern(window)
  return window ~= nil and window.class == TERN_CLASS
end

-- Injects a chord into the focused window; the down/up split mirrors Omarchy's clipboard binds,
-- which work around send_shortcut leaving key state stuck.
local function send(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 30, type = "oneshot" })
end

for _, k in ipairs(KEYS) do
  -- Was: Omarchy's plain "Focus on <name> window" (hl.dsp.focus).
  hl.unbind("SUPER + " .. k.key)
  o.bind("SUPER + " .. k.key, "Focus on " .. k.name .. " window or Tern pane", function()
    local before = hl.get_active_window()
    if is_tern(before) then
      send("SUPER", k.key)
      return
    end
    hl.dispatch(hl.dsp.focus({ direction = k.dir }))
    local after = hl.get_active_window()
    if is_tern(after) and (before == nil or after.address ~= before.address) then
      send("SUPER + CTRL + SHIFT", k.key)
    end
  end)
end

-- Super+W on Tern closes the focused pane (Tern bubbles back to close the window when it is the
-- session's last pane); anywhere else it closes the window as before.
-- Was: Omarchy's "Close window" (hl.dsp.window.close).
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window or Tern pane", function()
  if is_tern(hl.get_active_window()) then
    send("SUPER", "W")
  else
    hl.dispatch(hl.dsp.window.close())
  end
end)

-- Super+Shift+A on Tern opens a new agent block beside the focused pane; anywhere else it still
-- opens ChatGPT. Was: Omarchy's "ChatGPT" web app.
hl.unbind("SUPER + SHIFT + A")
o.bind("SUPER + SHIFT + A", "New Tern agent, else ChatGPT", function()
  if is_tern(hl.get_active_window()) then
    send("SUPER + SHIFT", "A")
  else
    hl.dispatch(hl.dsp.exec_cmd(o.launch_webapp("https://chatgpt.com")))
  end
end)
