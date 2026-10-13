--!strict
-- The Granola block's view: the meeting list (the selection is the keyboard cursor) or one meeting's
-- details screen, and a footer with the gathered count, the mode and the keys. Pure: state in, nodes
-- out.

local context = require("./context")
local ui = tern.ui

local View = {}

export type State = {
	key: "checking" | "missing" | "ok",
	notes: { any },
	more: boolean,
	loading: boolean,
	error: string?,
	details: { [string]: any },
	detail_errors: { [string]: string },
	sel: number,
	picked: { string },
	detail: boolean,
	filter: string?,
	filtering: boolean,
	transcript: boolean,
	busy: string?,
	help: boolean,
	now: number,
	offset: number,
}

local function text(key: string, value: string, role: string, props: { [string]: any }?): Node
	local p: { [string]: any } = props or {}
	p.key, p.text, p.role = key, value, role
	return ui.node("text", p)
end

local function button(key: string, label: string, action: string, title: string, role: string?): Node
	return ui.el("button", {
		key = key, text = label, role = role or "granola.button",
		title = title, aria = title, actions = { click = action },
	})
end

-- Lowercased substring match of the filter against title, owner and attendees.
function View.matches(note: any, filter: string?, detail: any?): boolean
	if filter == nil or filter == "" then
		return true
	end
	local hay = { context.title(note) }
	local owner = note.owner
	if type(owner) == "table" then
		table.insert(hay, owner.name or "")
		table.insert(hay, owner.email or "")
	end
	if detail and type(detail.attendees) == "table" then
		for _, u in detail.attendees do
			table.insert(hay, u.name or "")
			table.insert(hay, u.email or "")
		end
	end
	return string.find(string.lower(table.concat(hay, " ")), string.lower(filter), 1, true) ~= nil
end

function View.visible(s: State): { any }
	local out = {}
	for _, n in s.notes do
		if View.matches(n, s.filter, s.details[n.id]) then
			table.insert(out, n)
		end
	end
	return out
end

local function attendees(detail: any, max: number): string?
	if type(detail) ~= "table" or type(detail.attendees) ~= "table" or #detail.attendees == 0 then
		return nil
	end
	local names: { string } = {}
	for i, u in detail.attendees do
		if i > max then
			table.insert(names, string.format("+%d", #detail.attendees - max))
			break
		end
		table.insert(names, u.name or u.email or "?")
	end
	return table.concat(names, ", ")
end

-- The details screen: one meeting, with its people, actions and full summary.
local function detail_screen(s: State, note: any, pos: number, total: number, picked: boolean): { Node }
	local id: string = note.id
	local detail = s.details[id]
	local meta = context.when(note.created_at, s.now, s.offset)
	if detail and type(detail.folder_membership) == "table" and #detail.folder_membership > 0 then
		meta ..= " · " .. (detail.folder_membership[1].name or "")
	end
	local out: { Node } = {
		ui.node("row", { key = "crumb", role = "granola.header" }, {
			button("back", "← Meetings", "details=close", "Back to the list (← or esc)", "granola.icon"),
			text("pos", string.format("%d of %d", pos, total), "granola.muted", { grow = 1 }),
			if picked then text("picked", "✓ gathered", "granola.count") else text("picked", "", "granola.muted"),
		}),
		text("title", context.title(note), "granola.detailTitle"),
		text("meta", meta, "granola.muted"),
	}
	local who = attendees(detail, 12)
	if who then
		table.insert(out, text("who", who, "granola.muted"))
	end
	table.insert(out, ui.node("row", { key = "actions", role = "granola.actions" }, {
		button("gather", if picked then "Release" else "Gather", "gather",
			if picked then "Remove from the gathered meetings (space)" else "Gather this meeting (space)"),
		button("attach", "Add to agent", "attach", "Add to the agent (⏎)", "granola.primary"),
		button("copy", "Copy", "copy", "Copy as Markdown (c)"),
		button("web", "Open in Granola", "web", "Open in Granola (o)"),
	}))
	local body: { Node } = {}
	if s.detail_errors[id] then
		table.insert(body, text("error", s.detail_errors[id], "granola.error"))
	elseif detail == nil then
		table.insert(body, text("loading", "Loading summary…", "granola.muted"))
	else
		local summary = detail.summary_markdown or detail.summary_text
		if type(summary) == "string" and string.find(summary, "%S") then
			table.insert(body, ui.md(summary))
		else
			table.insert(body, text("nosummary", "No summary.", "granola.muted"))
		end
	end
	table.insert(out, ui.node("col", { key = "body", role = "granola.detailBody" }, body))
	return out
end

local LIST_KEYS = {
	{ "↑↓", "move" }, { "→", "details" }, { "space", "gather" }, { "⏎", "add to agent" },
	{ "tab", "mode" }, { "/", "filter" }, { "?", "more keys" },
}
local DETAIL_KEYS = {
	{ "←", "back" }, { "↑↓", "prev / next" }, { "space", "gather" }, { "⏎", "add to agent" },
	{ "tab", "mode" }, { "c", "copy" }, { "o", "open in Granola" },
}
local MORE_KEYS = {
	{ "j k", "move" }, { "h l", "back / details" }, { "g G", "top / bottom" },
	{ "c", "copy as Markdown" }, { "o", "open in Granola" }, { "x", "clear gathered" },
	{ "r", "reload" }, { "K", "set API key" }, { "esc", "back / to the agent" },
}

local function key_hints(list: { { string } }, key: string): Node
	local spans: { any } = {}
	for i, k in list do
		if i > 1 then
			table.insert(spans, ui.span("  ", "muted"))
		end
		table.insert(spans, ui.span(k[1], "key"))
		table.insert(spans, ui.span(" " .. k[2], "muted"))
	end
	local node = ui.text(spans)
	local p: { [string]: any } = node.p or {}
	p.key, p.role = key, "granola.keys"
	node.p = p
	return node
end

function View.render(s: State, rows: number): BlockView
	local header: { Node } = {
		text("title", "Granola", "granola.heading", { grow = 1 }),
	}
	if s.loading then
		table.insert(header, text("loading", "loading…", "granola.muted"))
	end
	table.insert(header, button("reload", "↻", "reload", "Reload meetings (r)", "granola.icon"))
	local main: { Node } = { ui.node("row", { key = "header", role = "granola.header" }, header) }

	if s.key == "missing" then
		table.insert(main, ui.node("col", { key = "empty", role = "granola.empty" }, {
			text("title", "Connect Granola", "granola.emptyTitle"),
			text("help", "Create a personal API key in Granola under Settings › Connectors › API keys "
				.. "(Business or Enterprise plan). It is kept in the system keychain.", "granola.muted"),
			button("setkey", "Set API key (K)", "key", "Paste a Granola API key", "granola.primary"),
		}))
		return { main = ui.col(main) }
	end
	if s.error then
		table.insert(main, text("error", s.error, "granola.error"))
	end
	if s.filtering or (s.filter and s.filter ~= "") then
		table.insert(main, ui.node("row", { key = "filter", role = "granola.filter" }, {
			text("label", "/ " .. (s.filter or "") .. (if s.filtering then "▏" else ""), "granola.filterText", { grow = 1 }),
			text("hint", if s.filtering then "⏎ done · esc clear" else "esc clears", "granola.muted"),
		}))
	end

	local shown = View.visible(s)
	local picked: { [string]: boolean } = {}
	for _, id in s.picked do
		picked[id] = true
	end
	local cur = math.clamp(s.sel, 1, math.max(1, #shown))
	if s.detail and #shown > 0 then
		main = detail_screen(s, shown[cur], cur, #shown, picked[shown[cur].id] == true)
	elseif #shown == 0 then
		table.insert(main, text("none",
			if s.loading then "Loading meetings…"
				elseif #s.notes == 0 then "No summarized meetings yet."
				else "No meeting matches the filter.",
			"granola.muted"))
	else
		local items: { any } = {}
		for i, n in shown do
			local detail = context.when(n.created_at, s.now, s.offset)
			local who = attendees(s.details[n.id], 3)
			if who then
				detail ..= " · " .. who
			end
			table.insert(items, {
				-- The cursor is spelled out: the list's own selection highlight is faint in some themes.
				label = (if i == cur then "▸ " else "  ") .. context.title(n),
				detail = detail,
				value = if picked[n.id] then "✓ gathered" else nil,
				tone = if picked[n.id] then "accent" else nil,
			})
		end
		-- The list fills the block and keeps the selection in view.
		local list = ui.list(items)
		local p: { [string]: any } = list.p or {}
		p.key = "list"
		p.selected = cur - 1 -- zero-based, like the `item` of its select events
		p.max = { lines = math.max(4, rows - 8) }
		p.actions = { select = "select", activate = "activate" }
		list.p = p
		table.insert(main, list)
		if s.more then
			table.insert(main, text("more", "↓ past the last meeting loads older ones", "granola.muted"))
		end
	end

	local count = #s.picked
	local status: { Node } = {
		text("count", if count == 0 then "nothing gathered"
			elseif count == 1 then "1 gathered" else tostring(count) .. " gathered",
			if count > 0 then "granola.count" else "granola.muted"),
	}
	if s.busy then
		table.insert(status, text("busy", s.busy, "granola.busy"))
	end
	table.insert(status, ui.node("row", { key = "spacer", grow = 1 }, {}))
	if count > 0 then
		table.insert(status, button("attach", "Add to agent", "attach", "Add the gathered meetings to the agent (⏎)", "granola.primary"))
		table.insert(status, button("clear", "Clear", "clear", "Forget the gathered meetings (x)"))
	end
	table.insert(status, ui.node("row", { key = "mode", role = "granola.segment" }, {
		button("synthesis", "Synthesis", "mode=synthesis", "Send the AI summary and your notes (tab)",
			if s.transcript then "granola.segmentOff" else "granola.segmentOn"),
		button("transcript", "Full transcript", "mode=transcript", "Also send the full transcript (tab)",
			if s.transcript then "granola.segmentOn" else "granola.segmentOff"),
	}))
	local dock: { Node } = {
		ui.node("row", { key = "status", role = "granola.status" }, status),
		key_hints(if s.detail then DETAIL_KEYS else LIST_KEYS, "keys"),
	}
	if s.help then
		table.insert(dock, key_hints(MORE_KEYS, "more"))
	end
	return { main = ui.col(main), dock = ui.node("col", { key = "dock", role = "granola.dock" }, dock) }
end

return View
