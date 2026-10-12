--!strict
-- Window half of Forge's usage panel (from tern-claude-usage by zerx-lab, MIT): palette commands
-- that pop the usage block up as a floating panel (and start a Claude or ChatGPT login), and the
-- status-line segments fed by the host poller's summary in kv "status". Forge's window entry
-- registers the plugin's one status formatter and includes these segments. The segment shows the
-- block's current tab or both providers, and per provider the pinned account (else the first),
-- the one with the most headroom, or every account.

local stats = require("./lib/stats")
local time = require("./lib/time")
local KIND = "forge.usage"

type Summary = {
	updated: number?,
	rev: number?,
	enabled: boolean?,
	provider: string?,
	mode: string?,
	scope: string?,
	accounts: { stats.Row },
}

local summary: Summary? = nil

local function read_summary(): boolean
	local ok, s = pcall(tern.kv.get, "status")
	if not ok or type(s) ~= "table" then
		return false
	end
	local prev = summary :: any
	local changed = prev == nil or prev.updated ~= s.updated or prev.rev ~= s.rev or prev.provider ~= s.provider
	summary = s
	return changed
end

local function pct(w: stats.Win?): string
	if w == nil or w.pct == nil then
		return "—"
	end
	return string.format("%d%%", math.floor((w.pct :: number) + 0.5))
end

local function tone(row: stats.Row): string?
	local worst = stats.load(row) or 0
	if worst >= 85 then
		return "error"
	elseif worst >= 60 then
		return "warn"
	end
	return "muted"
end

-- Claude's segment keeps its bare `5h 42% (2h13m) · 7d 18%`; others are prefixed with their name.
local PREFIX = { claude = "", gpt = "GPT " }
local NAME = { claude = "Claude", gpt = "GPT" }
local PROVIDERS = { "claude", "gpt" }
-- "all" mode: at most this many accounts per provider, then `+N`.
local MAX_ALL = 4

type Segment = { text: string, icon: string?, tone: string?, command: string? }

local function segment(text: string, tone_name: string?): Segment
	return { text = text, icon = "sparkle", tone = tone_name, command = "plugin.forge.usage" }
end

-- `5h 42% (2h13m) · 7d 18%`: the first window present (5 h, else 7 d for plans without one)
-- carries the reset countdown when `countdown`.
local function windows_text(row: stats.Row, now: number, countdown: boolean): string
	local parts: { string } = {}
	for _, item in { { "5h", row.session }, { "7d", row.weekly } } do
		local w: stats.Win? = item[2]
		if w then
			local part = item[1] .. " " .. pct(w)
			local at = w.resets_at
			if countdown and #parts == 0 and at and at > now then
				part ..= " (" .. time.short(at - now) .. ")"
			end
			table.insert(parts, part)
		end
	end
	return table.concat(parts, " · ")
end

local function provider_segments(provider: string, rows: { stats.Row }, mode: string, now: number): { Segment }
	local out: { Segment } = {}
	local picked = stats.pick(rows, mode)
	if mode == "all" then
		for i, row in picked do
			if i > MAX_ALL then
				out[#out].text ..= string.format(" +%d", #picked - MAX_ALL)
				break
			end
			local prefix = if i == 1 then PREFIX[provider] or "" else ""
			if row.session == nil and row.weekly == nil then
				if row.error then
					table.insert(out, segment(prefix .. (row.name or "") .. " ⚠", "error"))
				end
			else
				-- `me 42%/18%`: the 5 h / 7 d use without labels.
				local parts: { string } = {}
				for _, w in { row.session, row.weekly } do
					if w then
						table.insert(parts, pct(w))
					end
				end
				table.insert(out, segment(prefix .. (row.name or "") .. " " .. table.concat(parts, "/"), tone(row)))
			end
		end
		return out
	end
	local row = picked[1]
	if row == nil then
		return out
	end
	if row.session == nil and row.weekly == nil then
		if row.error then
			table.insert(out, segment((NAME[provider] or provider) .. " ⚠", "error"))
		end
		return out
	end
	-- "best" names the account it picked; "one" shows the pinned or first account as before.
	local name = if mode == "best" then (row.name or "") .. " " else ""
	local text = (PREFIX[provider] or "") .. name .. windows_text(row, now, true)
	if #rows > 1 then
		text ..= string.format(" +%d", #rows - 1)
	end
	table.insert(out, segment(text, tone(row)))
	return out
end

local function status(_pane: any): { Segment }?
	local s = summary
	if s == nil or s.enabled == false then
		return nil
	end
	local shown = s.provider or "claude"
	local mode = s.mode or "one"
	local now = os.time()
	local out: { Segment } = {}
	for _, provider in PROVIDERS do
		if s.scope ~= "both" and provider ~= shown then
			continue
		end
		local rows: { stats.Row } = {}
		for _, r in s.accounts do
			if (r.provider or "claude") == provider then
				table.insert(rows, r)
			end
		end
		for _, seg in provider_segments(provider, rows, mode, now) do
			table.insert(out, seg)
		end
	end
	return if #out > 0 then out else nil
end

-- The countdown in the segment moves by the minute; the data by the host's poll.
local last_minute = -1
local function watch()
	local minute = os.time() // 60
	if read_summary() or minute ~= last_minute then
		last_minute = minute
		tern.chrome.refresh()
	end
	tern.timer(15000, watch)
end
read_summary()
tern.timer(1000, watch)

-- The usage block in the focused pane's tab, if any.
local function find_panel(cx: WindowCx): (PaneInfo?, number?)
	local focused = cx.session:focused()
	local here = if focused then cx.session:pane(focused) else nil
	local tab = here and here.tab
	for _, p in cx.session:panes() do
		if p.block == KIND and p.tab == tab then
			return p, focused
		end
	end
	return nil, focused
end

-- Columns the docked panel keeps: wide enough for its bars without crowding the terminal.
local PANEL_COLS = 56

-- Opens the usage block docked beside the focused pane. A tiled block renders at the
-- window's own scale, so its text stays crisp and it gets the tab's full height (a floating
-- picture is scaled and fixed in size).
local function pop_up(cx: WindowCx, focused: number?, args: { string }?)
	local pane = cx:new_block(KIND, args, "beside", { focus = false })
	if pane == nil then
		return
	end
	local info = focused and cx.session:pane(focused)
	local cols = info and (info :: any).cols
	-- The split halves the focused pane; give the extra back to it.
	if type(cols) == "number" and cols > PANEL_COLS then
		cx.layout:resize(pane, "left", PANEL_COLS - cols)
	else
		cx.layout:resize(pane, "left", -20)
	end
end

tern.command({
	id = "usage",
	title = "Subscription usage (Claude / GPT): show or hide the panel",
	icon = "sparkle",
	run = function(cx)
		local panel, focused = find_panel(cx)
		if panel == nil then
			pop_up(cx, focused)
		else
			cx.layout:close(panel.pane)
		end
	end,
})

-- Launch arguments only reach a new block, so an open panel is replaced.
local function login_command(id: string, title: string, provider: string)
	tern.command({
		id = id,
		title = title,
		icon = "sparkle",
		run = function(cx)
			local panel, focused = find_panel(cx)
			if panel then
				cx.layout:close(panel.pane)
			end
			pop_up(cx, focused, { "login", provider })
		end,
	})
end

login_command("usage-login", "Claude usage: sign in to a subscription account (several allowed)", "claude")
login_command("usage-login-gpt", "GPT usage: sign in to a ChatGPT account (several allowed)", "gpt")

return { status = status }
