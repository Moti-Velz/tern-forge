--!strict
-- The Granola panel's canvas: header, recent meetings (pick to gather, click to preview), and a
-- dock that sends the gathered meetings to an agent. Pure: model in, nodes out.

local context = require("./context")
local ui = tern.ui

local View = {}

export type Model = {
	key: "checking" | "missing" | "ok",
	notes: { any },
	cursor: string?,
	loading: boolean,
	error: string?,
	filter: string?,
	expanded: { [string]: boolean },
	details: { [string]: any },
	detail_errors: { [string]: string },
	picked: { string },
	transcript: boolean,
	busy: string?,
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

function View.visible(m: Model): { any }
	local out = {}
	for _, n in m.notes do
		if View.matches(n, m.filter, m.details[n.id]) then
			table.insert(out, n)
		end
	end
	return out
end

local function attendees(detail: any): string?
	if type(detail.attendees) ~= "table" or #detail.attendees == 0 then
		return nil
	end
	local names: { string } = {}
	for i, u in detail.attendees do
		if i > 6 then
			table.insert(names, string.format("+%d", #detail.attendees - 6))
			break
		end
		table.insert(names, u.name or u.email or "?")
	end
	return table.concat(names, ", ")
end

local function note_node(m: Model, note: any, picked: boolean): Node
	local id: string = note.id
	local open = m.expanded[id] == true
	local title = context.title(note)
	local head = ui.node("row", { key = "head", role = "granola.noteHead" }, {
		button("pick", if picked then "☑" else "☐", "pick=" .. id,
			if picked then "Remove from the gathered context" else "Add to the gathered context",
			if picked then "granola.checkOn" else "granola.check"),
		ui.node("col", {
			key = "label", role = "granola.noteLabel", grow = 1,
			title = if open then "Hide preview" else "Preview " .. title,
			actions = { click = "expand=" .. id },
		}, {
			text("title", title, "granola.noteTitle"),
			text("when", context.when(note.created_at, m.now, m.offset), "granola.muted"),
		}),
	})
	local children = { head }
	if open then
		local body: { Node } = {}
		local detail = m.details[id]
		local err = m.detail_errors[id]
		if err then
			table.insert(body, text("error", err, "granola.error"))
		elseif detail == nil then
			table.insert(body, text("loading", "Loading summary…", "granola.muted"))
		else
			local who = attendees(detail)
			if who then
				table.insert(body, text("who", who, "granola.muted"))
			end
			local summary = detail.summary_markdown or detail.summary_text
			if type(summary) == "string" and string.find(summary, "%S") then
				table.insert(body, ui.node("col", { key = "summary", role = "granola.summary" }, { ui.md(summary) }))
			else
				table.insert(body, text("nosummary", "No summary.", "granola.muted"))
			end
		end
		table.insert(body, ui.node("row", { key = "actions", role = "granola.actions" }, {
			button("send", "Send to agent", "send=" .. id, "Send this meeting to an agent session", "granola.primary"),
			button("copy", "Copy", "copy=" .. id, "Copy this meeting as Markdown"),
			button("open", "Open in Granola", "web=" .. id, "Open the note in Granola"),
		}))
		table.insert(children, ui.node("col", { key = "body", role = "granola.noteBody" }, body))
	end
	return ui.node("col", {
		key = "n" .. id, role = if picked then "granola.notePicked" else "granola.note",
	}, children)
end

function View.render(m: Model): (Node, Node)
	local header = ui.node("row", { key = "header", role = "granola.header" }, {
		text("title", "Granola", "granola.heading", { grow = 1 }),
		button("search", "Filter", "search", "Filter meetings by title or attendee"),
		button("refresh", if m.loading then "…" else "↻", "refresh", "Reload recent meetings", "granola.icon"),
		button("key", "Key", "key", "Set the Granola API key", "granola.icon"),
	})
	local children: { Node } = { header }
	if m.busy then
		table.insert(children, text("busy", m.busy, "granola.busy"))
	end
	if m.error then
		table.insert(children, text("error", m.error, "granola.error"))
	end
	if m.key == "missing" then
		table.insert(children, ui.node("col", { key = "empty", role = "granola.empty" }, {
			text("title", "Connect Granola", "granola.emptyTitle"),
			text("help", "Create a personal API key in the Granola app under Settings › Connectors › API keys "
				.. "(Business or Enterprise plan), then paste it here. It is kept in the system keychain.", "granola.muted"),
			button("setkey", "Set API key", "key", "Paste a Granola API key", "granola.primary"),
		}))
		return ui.node("col", { key = "granola", role = "granola.panel" }, children), ui.node("col", { key = "dock" }, {})
	end
	if m.filter and m.filter ~= "" then
		table.insert(children, ui.node("row", { key = "filter", role = "granola.filter" }, {
			text("label", "Filter: " .. m.filter, "granola.muted", { grow = 1 }),
			button("clear", "✕", "clear-filter", "Show every meeting", "granola.icon"),
		}))
	end
	local picked: { [string]: boolean } = {}
	for _, id in m.picked do
		picked[id] = true
	end
	local shown = View.visible(m)
	local list: { Node } = {}
	for _, n in shown do
		table.insert(list, note_node(m, n, picked[n.id] == true))
	end
	if #shown == 0 and not m.loading and m.key == "ok" and m.error == nil then
		table.insert(list, text("none",
			if #m.notes == 0 then "No summarized meetings yet." else "No loaded meeting matches the filter.",
			"granola.muted"))
	elseif m.loading and #m.notes == 0 then
		table.insert(list, text("loading", "Loading meetings…", "granola.muted"))
	end
	if m.cursor then
		table.insert(list, button("more", if m.loading then "Loading…" else "Load older meetings", "more",
			"Fetch the next page of meetings"))
	end
	table.insert(children, ui.node("col", { key = "list", role = "granola.list" }, list))

	local dock: { Node } = {}
	local count = #m.picked
	if count > 0 then
		table.insert(dock, text("count", if count == 1 then "1 meeting gathered" else tostring(count) .. " meetings gathered",
			"granola.count", { grow = 1 }))
		table.insert(dock, button("send", "Send to agent", "send-picked", "Send the gathered meetings to an agent session", "granola.primary"))
		table.insert(dock, button("copy", "Copy", "copy-picked", "Copy the gathered meetings as Markdown"))
		table.insert(dock, button("clear", "Clear", "clear-picked", "Forget the gathered meetings"))
	else
		table.insert(dock, text("hint", "☐ gathers meetings for an agent", "granola.muted", { grow = 1 }))
	end
	table.insert(dock, button("transcript", if m.transcript then "Transcripts: on" else "Transcripts: off", "transcript",
		if m.transcript then "Send summaries only" else "Also send full transcripts",
		if m.transcript then "granola.toggleOn" else "granola.button"))
	return ui.node("col", { key = "granola", role = "granola.panel" }, children),
		ui.node("row", { key = "dock", role = "granola.dock" }, dock)
end

return View
