--!strict
-- Seamless focus between Tern panes and Hyprland windows, the vim-tmux-navigator way.
--
-- Hyprland owns Super+arrows (see hypr/tern-nav.lua). When Tern is the active window it hands the
-- key over: Tern moves to the pane in that direction, or, at the edge of the tab, bubbles the move
-- back up with `hyprctl dispatch`. When Hyprland moves focus *into* Tern it sends the "entered"
-- chord, and Tern focuses the pane on the edge you came in through.

local geometry = require("./lib/geometry")

type Dir = geometry.Dir

local DIRS: { { key: string, dir: Dir } } = {
	{ key = "left", dir = "l" },
	{ key = "right", dir = "r" },
	{ key = "up", dir = "u" },
	{ key = "down", dir = "d" },
}

-- Chords Hyprland injects (with Super physically held): move, and "focus just entered Tern".
local MOVE_MODS = "cmd"
local ENTER_MODS = "cmd+ctrl+shift"

-- Hands the move to Hyprland. The window half runs in Tern's window process, which Hyprland
-- started, so `hyprctl` finds the compositor through the inherited environment.
local function bubble(dir: Dir)
	tern.process.run({ "hyprctl", "dispatch", 'hl.dsp.focus({ direction = "' .. dir .. '" })' }, { timeout_ms = 2000 },
		function(r, _cx)
			if r.status ~= 0 then
				tern.log.warn("omarchy-nav: hyprctl failed", r.status, r.stderr, r.stdout)
			end
		end)
end

-- The focused pane, its tab's split rectangles, and whether the tab can be navigated (a zoomed
-- tab or a floating pane has no meaningful neighbours).
local function where(cx: WindowCx): (number?, { [number]: geometry.Rect }?)
	local focused = cx.session:focused()
	if focused == nil then
		return nil, nil
	end
	local tab = cx.session:tab_of(focused)
	local layout = if tab then cx.session:layout(tab) else nil
	if layout == nil or layout.zoomed then
		return focused, nil
	end
	local rects = geometry.rects(layout.root)
	if rects[focused] == nil then
		return focused, nil
	end
	return focused, rects
end

local function move(cx: WindowCx, dir: Dir)
	local focused, rects = where(cx)
	local target = if focused and rects then geometry.neighbor(rects, focused, dir) else nil
	if target then
		cx.layout:focus(target)
	else
		bubble(dir)
	end
end

-- Entering while moving `dir`: stay on the focused pane if it is on that edge already (you are
-- coming back to where you left), else take the edge pane nearest it.
local function enter(cx: WindowCx, dir: Dir)
	local focused, rects = where(cx)
	if focused == nil or rects == nil then
		return
	end
	local r = rects[focused]
	local along = if dir == "l" or dir == "r" then r.y + r.h / 2 else r.x + r.w / 2
	local target = geometry.entry(rects, dir, along)
	if target and target ~= focused then
		local same_edge = geometry.entry({ [focused] = r }, dir, along) == focused
		if not same_edge then
			cx.layout:focus(target)
		end
	end
end

for _, d in DIRS do
	local dir = d.dir
	tern.bind(MOVE_MODS .. "+" .. d.key, function(cx)
		move(cx, dir)
	end)
	tern.bind(ENTER_MODS .. "+" .. d.key, function(cx)
		enter(cx, dir)
	end)
end

-- Super+W, handed over by Hyprland: close the focused pane through Tern's own close (which asks
-- before closing a pane with something running), or, when it is the session's last pane, bubble
-- up and let Hyprland close the Tern window. The session daemon keeps the programs either way.
local function session_pane_count(cx: WindowCx): number
	local tabs: { [number]: boolean } = {}
	for _, s in cx.session:sessions() do
		if s.current then
			for _, t in s.tabs do
				tabs[t] = true
			end
		end
	end
	local n = 0
	for _, p in cx.session:panes() do
		if p.tab and tabs[p.tab] and not p.parked then
			n += 1
		end
	end
	return n
end

tern.bind("cmd+w", function(cx)
	if session_pane_count(cx) <= 1 then
		tern.process.run({ "hyprctl", "dispatch", "hl.dsp.window.close()" }, { timeout_ms = 2000 }, function(r, _cx)
			if r.status ~= 0 then
				tern.log.warn("omarchy-nav: hyprctl failed", r.status, r.stderr, r.stdout)
			end
		end)
	else
		cx:command("close_pane")
	end
end)

-- Super+Shift+A, handed over by Hyprland: Tern's own "New agent block" (also Ctrl+Shift+A).
tern.bind("cmd+shift+a", "new_agent_block")
