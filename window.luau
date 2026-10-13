--!strict
-- Omarchy integration, the vim-tmux-navigator way: Omarchy's window keys act on Tern panes first and
-- bubble up to Hyprland where Tern has nothing to do.
--
-- Hyprland owns the keys (hypr/tern-nav.lua). When Tern is the active window it hands them over
-- (injects the chord into Tern); the handlers below either act on the pane layout or call
-- `hyprctl dispatch` to do what Hyprland would have done. Agent notifications live in
-- lib/agents.luau.

local agents = require("./lib/agents")
local geometry = require("./lib/geometry")
local heartbeat = require("./lib/heartbeat")
local hypr = require("./lib/hypr")

type Dir = geometry.Dir

-- `swap` is the letter Hyprland sends for Super+Shift+arrow (as Super+Ctrl+Shift+letter): Tern's
-- preset already owns Super+Shift+arrows and Super+Alt+Shift+←/→.
local DIRS: { { key: string, dir: Dir, swap: string } } = {
	{ key = "left", dir = "l", swap = "a" },
	{ key = "right", dir = "r", swap = "d" },
	{ key = "up", dir = "u", swap = "w" },
	{ key = "down", dir = "d", swap = "s" },
}

-- The focused pane and its tab's split rectangles; no rectangles in a zoomed tab or for a floating
-- pane, which have no neighbours worth moving to.
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

-- ── Focus: Super+arrows (and the "entered Tern" chord Super+Ctrl+Shift+arrows) ─────────────────

local function focus(cx: WindowCx, dir: Dir)
	local focused, rects = where(cx)
	local target = if focused and rects then geometry.neighbor(rects, focused, dir) else nil
	if target then
		cx.layout:focus(target)
	else
		hypr.dispatch('hl.dsp.focus({ direction = "' .. dir .. '" })')
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
	if geometry.entry({ [focused] = r }, dir, along) == focused then
		return
	end
	local target = geometry.entry(rects, dir, along)
	if target and target ~= focused then
		cx.layout:focus(target)
	end
end

-- ── Swap: Super+Shift+arrows ────────────────────────────────────────────────────────────────

local function swap(cx: WindowCx, dir: Dir)
	local focused, rects = where(cx)
	local target = if focused and rects then geometry.neighbor(rects, focused, dir) else nil
	if focused and target and cx.layout:move(focused, target, "swap") then
		return
	end
	hypr.dispatch('hl.dsp.window.swap({ direction = "' .. dir .. '" })')
end

-- ── Resize: Super(+Shift)(+Alt) + minus/equal ───────────────────────────────────────────────
-- Hyprland hands these over as Super+Ctrl+Shift+letter (H/L width −/+, K/J height −/+; Y/O and
-- I/U the same in small steps), since the minus/equal keys' names vary with the layout. A pane
-- grows or shrinks on whichever side has a divider; with none on that axis the window resizes.

local CELLS_PER_PX = { x = 8 / 100, y = 4 / 100 }

local function resize(cx: WindowCx, dx: number, dy: number)
	local focused = cx.session:focused()
	local moved = false
	if focused then
		local axis = if dx ~= 0 then "x" else "y"
		local delta = if dx ~= 0 then dx else dy
		local cells = math.max(1, math.floor(math.abs(delta) * CELLS_PER_PX[axis] + 0.5)) * (if delta < 0 then -1 else 1)
		local sides: { "right" | "left" | "down" | "up" } = if axis == "x" then { "right", "left" } else { "down", "up" }
		for _, side in sides do
			if cx.layout:resize(focused, side, cells) then
				moved = true
				break
			end
		end
	end
	if not moved then
		hypr.dispatch(string.format("hl.dsp.window.resize({ x = %d, y = %d, relative = true })", dx, dy))
	end
end

local RESIZE: { { key: string, dx: number, dy: number } } = {
	{ key = "h", dx = -100, dy = 0 }, { key = "l", dx = 100, dy = 0 },
	{ key = "k", dx = 0, dy = -100 }, { key = "j", dx = 0, dy = 100 },
	{ key = "y", dx = -25, dy = 0 }, { key = "o", dx = 25, dy = 0 },
	{ key = "i", dx = 0, dy = -25 }, { key = "u", dx = 0, dy = 25 },
}

-- ── New pane: Super+Return ──────────────────────────────────────────────────────────────────
-- A shell beside the focused pane, in its directory, split along its longer side (like Hyprland's
-- dwindle layout does for windows).

local function new_pane(cx: WindowCx)
	local focused, rects = where(cx)
	if focused == nil then
		cx:command("new_tab")
		return
	end
	local info = cx.session:pane(focused)
	local cwd = if info and info.cwd and info.cwd ~= "" then info.cwd else nil
	hypr.active(function(window, c)
		local dir: Dir = "r"
		local r = rects and rects[focused]
		if r and window and type(window.size) == "table" then
			local w, h = r.w * (window.size[1] or 1), r.h * (window.size[2] or 1)
			dir = if w >= h then "r" else "d"
		end
		c.layout:split(focused, if dir == "r" then "right" else "down", { cwd = cwd })
	end)
end

-- ── Close: Super+W ──────────────────────────────────────────────────────────────────────────
-- Tern's own close (which asks before closing a pane with something running); on the session's
-- last pane Hyprland closes the Tern window instead. The session daemon keeps the programs.

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

local function close(cx: WindowCx)
	if session_pane_count(cx) <= 1 then
		hypr.dispatch("hl.dsp.window.close()")
	else
		cx:command("close_pane")
	end
end

-- ── Bindings ────────────────────────────────────────────────────────────────────────────────

for _, d in DIRS do
	local dir = d.dir
	tern.bind("cmd+" .. d.key, function(cx)
		focus(cx, dir)
	end)
	tern.bind("cmd+ctrl+shift+" .. d.key, function(cx)
		enter(cx, dir)
	end)
	tern.bind("cmd+ctrl+shift+" .. d.swap, function(cx)
		swap(cx, dir)
	end)
end
for _, r in RESIZE do
	local dx, dy = r.dx, r.dy
	tern.bind("cmd+ctrl+shift+" .. r.key, function(cx)
		resize(cx, dx, dy)
	end)
end
tern.bind("cmd+enter", new_pane)
tern.bind("cmd+w", close)
-- Super+Shift+A: Tern's own "New agent block" (also Ctrl+Shift+A).
tern.bind("cmd+shift+a", "new_agent_block")
-- Super+Shift+P: Tern's own "New browser block".
tern.bind("cmd+shift+p", "new_browser_block")

agents.start()
heartbeat.start()
