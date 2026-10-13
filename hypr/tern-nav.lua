-- Tern-aware window keys for Omarchy (tern-omarchy).
--
-- Load from ~/.config/hypr/bindings.lua:
--   dofile(os.getenv("HOME") .. "/src/tern-omarchy/hypr/tern-nav.lua")
--
-- On a Tern window these keys are handed to Tern (the chord is injected into it), which acts on
-- its panes and bubbles back with `hyprctl dispatch` where it has nothing to do: at the edge of
-- the tab, on the last pane, when no divider can move. Anywhere else they do what Omarchy's
-- defaults did. Each bind below replaces an Omarchy default, named in its comment.

local TERN_CLASS = "so.stencil.tern"
local HEARTBEATS = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/tern-omarchy/"
-- The plugin rewrites its heartbeat every 2 s; older than this means it isn't running.
local HEARTBEAT_MAX_AGE = 6

-- Whether `window` is a Tern window whose plugin is running (lib/heartbeat.luau). Only those get
-- keys handed over; any other Tern window keeps Omarchy's defaults rather than dead keys.
local function is_tern(window)
  if window == nil or window.class ~= TERN_CLASS then
    return false
  end
  local file = io.open(HEARTBEATS .. tostring(window.pid), "r")
  if not file then
    return false
  end
  local stamp = tonumber(file:read("*l"))
  file:close()
  return stamp ~= nil and os.time() - stamp <= HEARTBEAT_MAX_AGE
end

-- Injects a chord into the focused window; the down/up split mirrors Omarchy's clipboard binds,
-- which work around send_shortcut leaving key state stuck.
local function send(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 30, type = "oneshot" })
end

-- Every bind's function, by its keys, so `hyprctl eval 'tern_nav.press("SUPER + LEFT")'` runs exactly
-- what the key runs (scripts and tests can't press bound keys: virtual keyboards don't trigger binds).
tern_nav = { binds = {}, handles = is_tern }
function tern_nav.press(keys)
  local fn = tern_nav.binds[keys]
  if fn then
    fn()
  end
end

-- Replaces the bind on `keys` with `fn`.
local function bind(keys, description, fn)
  hl.unbind(keys)
  tern_nav.binds[keys] = fn
  o.bind(keys, description, fn)
end

-- Binds `keys`: on Tern, inject `mods + key`; elsewhere run `fallback`.
local function tern_or(keys, description, mods, key, fallback)
  bind(keys, description, function()
    if is_tern(hl.get_active_window()) then
      send(mods, key)
    else
      fallback()
    end
  end)
end

-- `swap`: the letter Tern gets for Super+Shift+arrow, as Super+Ctrl+Shift+letter (Tern's own keys
-- already use Super+Shift+arrows).
local DIRS = {
  { key = "LEFT", dir = "l", name = "left", swap = "A" },
  { key = "RIGHT", dir = "r", name = "right", swap = "D" },
  { key = "UP", dir = "u", name = "above", swap = "W" },
  { key = "DOWN", dir = "d", name = "below", swap = "S" },
}

for _, k in ipairs(DIRS) do
  -- Was: "Focus on <name> window" (hl.dsp.focus). Moving onto Tern also tells it which way you
  -- came in (Super+Ctrl+Shift+arrow), so the pane on that edge gets focus.
  bind("SUPER + " .. k.key, "Focus on " .. k.name .. " window or Tern pane", function()
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

  -- Was: "Swap window <name>" (hl.dsp.window.swap).
  tern_or("SUPER + SHIFT + " .. k.key, "Swap window or Tern pane " .. k.name, "SUPER + CTRL + SHIFT", k.swap, function()
    hl.dispatch(hl.dsp.window.swap({ direction = k.dir }))
  end)
end

-- Was: the eight "Expand/Shrink window …" resize binds on minus (code:20) and equal (code:21).
-- Tern gets them as Super+Ctrl+Shift+letter: H/L width −/+, K/J height −/+, and Y/O, I/U in small
-- steps.
local RESIZE = {
  { keys = "SUPER + code:20", letter = "H", x = -100, y = 0, what = "Narrower" },
  { keys = "SUPER + code:21", letter = "L", x = 100, y = 0, what = "Wider" },
  { keys = "SUPER + SHIFT + code:20", letter = "K", x = 0, y = -100, what = "Shorter" },
  { keys = "SUPER + SHIFT + code:21", letter = "J", x = 0, y = 100, what = "Taller" },
  { keys = "SUPER + ALT + code:20", letter = "Y", x = -25, y = 0, what = "A little narrower" },
  { keys = "SUPER + ALT + code:21", letter = "O", x = 25, y = 0, what = "A little wider" },
  { keys = "SUPER + SHIFT + ALT + code:20", letter = "I", x = 0, y = -25, what = "A little shorter" },
  { keys = "SUPER + SHIFT + ALT + code:21", letter = "U", x = 0, y = 25, what = "A little taller" },
}
for _, r in ipairs(RESIZE) do
  tern_or(r.keys, r.what .. " window or Tern pane", "SUPER + CTRL + SHIFT", r.letter, function()
    hl.dispatch(hl.dsp.window.resize({ x = r.x, y = r.y, relative = true }))
  end)
end

-- Was: "Close window". On Tern: close the focused pane (the window on its session's last pane).
tern_or("SUPER + W", "Close window or Tern pane", "SUPER", "W", function()
  hl.dispatch(hl.dsp.window.close())
end)

-- Was: "Terminal". On Tern: a shell pane beside the focused one, in its directory.
tern_or("SUPER + RETURN", "Terminal, or new Tern pane", "SUPER", "Return", function()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-launch-terminal"))
end)

-- Was: "ChatGPT". On Tern: a new agent block.
tern_or("SUPER + SHIFT + A", "New Tern agent, else ChatGPT", "SUPER + SHIFT", "A", function()
  hl.dispatch(hl.dsp.exec_cmd(o.launch_webapp("https://chatgpt.com")))
end)

-- Was: "Google Photos". On Tern: a new browser block.
tern_or("SUPER + SHIFT + P", "New Tern browser, else Google Photos", "SUPER + SHIFT", "P", function()
  hl.dispatch(hl.dsp.exec_cmd(o.launch_webapp_sole("Google Photos", "https://photos.google.com/")))
end)
