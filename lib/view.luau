--!strict
-- The meetings block's view: the meeting list (the selection is the keyboard cursor) or one meeting's
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
	-- Which list shows: meetings (Granola, Fireflies, local files) or email threads.
	tab: "meetings" | "email",
	picked: { string },
	detail: boolean,
	filter: string?,
	filtering: boolean,
	transcript: boolean,
	busy: string?,
	help: boolean,
	-- Display names of the connected sources.
	sources: { string },
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
		key = key, text = label, role = role or "meetings.button",
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
		local in_tab = (n.source == "email") == (s.tab == "email")
		if in_tab and View.matches(n, s.filter, s.details[n.id] or n) then
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
	local from = context.SOURCES[note.source or ""]
	if from then
		meta ..= " · " .. from
	end
	if detail and type(detail.folder_membership) == "table" and #detail.folder_membership > 0 then
		meta ..= " · " .. (detail.folder_membership[1].name or "")
	end
	local out: { Node } = {
		ui.node("row", { key = "crumb", role = "meetings.header" }, {
			button("back", "← Meetings", "details=close", "Back to the list (← or esc)", "meetings.icon"),
			text("pos", string.format("%d of %d", pos, total), "meetings.muted", { grow = 1 }),
			if picked then text("picked", "✓ gathered", "meetings.count") else text("picked", "", "meetings.muted"),
		}),
		text("title", context.title(detail or note), "meetings.detailTitle"),
		text("meta", meta, "meetings.muted"),
	}
	local who = attendees(detail, 12)
	if who then
		table.insert(out, text("who", who, "meetings.muted"))
	end
	table.insert(out, ui.node("row", { key = "actions", role = "meetings.actions" }, {
		button("gather", if picked then "Release" else "Gather", "gather",
			if picked then "Remove from the gathered meetings (space)" else "Gather this meeting (space)"),
		button("attach", "Add to agent", "attach", "Add to the agent (⏎)", "meetings.primary"),
		button("copy", "Copy", "copy", "Copy as Markdown (c)"),
		button("web", if note.source == "local" then "Open file" elseif note.source == "email" then "Open in Gmail" else "Open in " .. (from or "source"), "web",
			"Open where it lives (o)"),
	}))
	local body: { Node } = {}
	if s.detail_errors[id] then
		table.insert(body, text("error", s.detail_errors[id], "meetings.error"))
	elseif detail == nil then
		table.insert(body, text("loading", "Loading summary…", "meetings.muted"))
	else
		local summary = detail.summary_markdown or detail.summary_text
		if type(summary) == "string" and string.find(summary, "%S") then
			table.insert(body, ui.md(summary))
		elseif type(detail.transcript) == "table" and #detail.transcript > 0 then
			-- Captions and dialogue files: the start of the transcript stands in for a summary.
			local lines = table.move(detail.transcript, 1, math.min(40, #detail.transcript), 1, {})
			table.insert(body, ui.md(context.transcript(lines)
				.. (if #detail.transcript > 40 then string.format("\n\n*… %d more lines*", #detail.transcript - 40) else "")))
		else
			table.insert(body, text("nosummary", "No summary.", "meetings.muted"))
		end
	end
	table.insert(out, ui.node("col", { key = "body", role = "meetings.detailBody" }, body))
	return out
end

local LIST_KEYS = {
	{ "↑↓", "move" }, { "→", "details" }, { "space", "gather" }, { "⏎", "add to agent" },
	{ "tab", "meetings / email" }, { "t", "mode" }, { "/", "filter" }, { "?", "more keys" },
}
local DETAIL_KEYS = {
	{ "←", "back" }, { "↑↓", "prev / next" }, { "space", "gather" }, { "⏎", "add to agent" },
	{ "t", "mode" }, { "c", "copy" }, { "o", "open" },
}
local MORE_KEYS = {
	{ "j k", "move" }, { "h l", "back / details" }, { "g G", "top / bottom" }, { "1 2", "meetings / email" },
	{ "c", "copy as Markdown" }, { "o", "open in its app / file" }, { "x", "clear gathered" },
	{ "r", "reload" }, { "K", "connect a source" }, { "esc", "back / to the agent" },
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
	p.key, p.role = key, "meetings.keys"
	node.p = p
	return node
end

function View.render(s: State, rows: number): BlockView
	local counts = { meetings = 0, email = 0 }
	for _, n in s.notes do
		local t = if n.source == "email" then "email" else "meetings"
		counts[t] += 1
	end
	local function tab_button(id: "meetings" | "email", label: string, keyn: string): Node
		return button("tab_" .. id, label .. (if counts[id] > 0 then " " .. tostring(counts[id]) else ""),
			"tab=" .. id, label .. " (" .. keyn .. ", or tab to switch)",
			if s.tab == id then "meetings.tabOn" else "meetings.tabOff")
	end
	local header: { Node } = {
		ui.node("row", { key = "tabs", role = "meetings.tabs", grow = 1 }, {
			tab_button("meetings", "Meetings", "1"),
			tab_button("email", "Email", "2"),
		}),
	}
	if s.loading then
		table.insert(header, text("loading", "loading…", "meetings.muted"))
	end
	table.insert(header, button("reload", "↻", "reload", "Reload (r)", "meetings.icon"))
	local main: { Node } = { ui.node("row", { key = "header", role = "meetings.header" }, header) }

	if s.key == "missing" then
		table.insert(main, ui.node("col", { key = "empty", role = "meetings.empty" }, {
			text("title", "Connect a source", "meetings.emptyTitle"),
			text("help", "Granola or Fireflies with an API key, email over IMAP with an app password (kept in the "
				.. "system keychain), or a folder of exported notes and transcripts (.md, .txt, .vtt, .srt).", "meetings.muted"),
			button("setkey", "Connect (K)", "key", "Connect Granola, Fireflies, email or a local folder", "meetings.primary"),
		}))
		return { main = ui.col(main) }
	end
	if s.error then
		table.insert(main, text("error", s.error, "meetings.error"))
	end
	if s.filtering or (s.filter and s.filter ~= "") then
		table.insert(main, ui.node("row", { key = "filter", role = "meetings.filter" }, {
			text("label", "/ " .. (s.filter or "") .. (if s.filtering then "▏" else ""), "meetings.filterText", { grow = 1 }),
			text("hint", if s.filtering then "⏎ done · esc clear" else "esc clears", "meetings.muted"),
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
		local email_on = table.find(s.sources, "Email") ~= nil
		table.insert(main, text("none",
			if s.loading then "Loading…"
				elseif s.tab == "email" and not email_on then "Connect email with K: your address and an app password. Nothing is marked as read."
				elseif s.filter and s.filter ~= "" then "Nothing matches the filter."
				elseif s.tab == "email" then "No email threads in the last 45 days."
				else "No meetings yet.",
			"meetings.muted"))
	else
		local items: { any } = {}
		local seen: { [string]: boolean } = {}
		local tab_sources = 0
		for _, n in shown do
			if n.source and not seen[n.source] then
				seen[n.source] = true
				tab_sources += 1
			end
		end
		for i, n in shown do
			local parts: { string } = {}
			local when = context.when(n.created_at, s.now, s.offset)
			if when ~= "" then
				table.insert(parts, when)
			end
			local from = context.SOURCES[n.source or ""]
			if s.tab == "meetings" and tab_sources > 1 and from then
				table.insert(parts, from)
			end
			local who = attendees(s.details[n.id] or (if n.attendees then n else nil), 3)
			if who then
				table.insert(parts, who)
			end
			local detail = table.concat(parts, " · ")
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
			table.insert(main, text("more", "↓ past the last meeting loads older ones", "meetings.muted"))
		end
	end

	local count = #s.picked
	local status: { Node } = {
		text("count", if count == 0 then "nothing gathered"
			elseif count == 1 then "1 gathered" else tostring(count) .. " gathered",
			if count > 0 then "meetings.count" else "meetings.muted"),
	}
	if s.busy then
		table.insert(status, text("busy", s.busy, "meetings.busy"))
	end
	table.insert(status, ui.node("row", { key = "spacer", grow = 1 }, {}))
	if count > 0 then
		table.insert(status, button("attach", "Add to agent", "attach", "Add the gathered meetings to the agent (⏎)", "meetings.primary"))
		table.insert(status, button("clear", "Clear", "clear", "Forget the gathered meetings (x)"))
	end
	table.insert(status, ui.node("row", { key = "mode", role = "meetings.segment" }, {
		button("synthesis", "Synthesis", "mode=synthesis", "Send the AI summary and your notes (tab)",
			if s.transcript then "meetings.segmentOff" else "meetings.segmentOn"),
		button("transcript", "Full transcript", "mode=transcript", "Also send the full transcript (tab)",
			if s.transcript then "meetings.segmentOn" else "meetings.segmentOff"),
	}))
	local dock: { Node } = {
		ui.node("row", { key = "status", role = "meetings.status" }, status),
		key_hints(if s.detail and #shown > 0 then DETAIL_KEYS else LIST_KEYS, "keys"),
	}
	if s.help then
		table.insert(dock, key_hints(MORE_KEYS, "more"))
	end
	return { main = ui.col(main), dock = ui.node("col", { key = "dock", role = "meetings.dock" }, dock) }
end

return View
