--!strict
-- Window half: the Granola panel (a canvas beside the focused pane), palette commands, and the
-- send-to-agent flow. Meetings are gathered with their summaries (and optionally transcripts) into
-- one Markdown document, which goes to an existing agent block or a new one in the focused
-- directory: inline when short, else as a file in the plugin's data directory that the prompt names.
-- Carly gets the same notes through the `recent` and `note` exports.

local api = require("./lib/api")
local context = require("./lib/context")
local view = require("./lib/view")

local TITLE = "Granola"
local ABOUT = "Recent Granola meetings. Preview summaries, gather meetings with ☐, and send them "
	.. "(summaries, optionally transcripts) as context to an agent session."
local SECRET = "api-key"

local api_key: string? = nil
-- The pane the user last worked in, not the panel: the default agent and the new agent's directory.
local last_pane: number? = nil
local panel_pane: number? = nil

local function utc_offset(): number
	local now = os.time()
	return now - os.time(os.date("!*t", now) :: any)
end

local model: view.Model = {
	key = "checking",
	notes = {},
	cursor = nil,
	loading = false,
	error = nil,
	filter = nil,
	expanded = {},
	details = {},
	detail_errors = {},
	picked = {},
	transcript = tern.kv.get("transcript") == true,
	busy = nil,
	now = os.time(),
	offset = utc_offset(),
}

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

-- ── Panel ───────────────────────────────────────────────────────────────────

local function find_panel(cx: WindowCx): number?
	if panel_pane and cx.session:pane(panel_pane) then
		return panel_pane
	end
	panel_pane = nil
	for _, c in cx.canvas:list() do
		if c.owner == tern.plugin.id and c.title == TITLE and cx.session:pane(c.pane) then
			panel_pane = c.pane
			return c.pane
		end
	end
	return nil
end

local function redraw(cx: WindowCx)
	local pane = find_panel(cx)
	if pane == nil then
		return
	end
	model.now = os.time()
	local main, dock = view.render(model)
	local ok, err = pcall(cx.canvas.set, cx.canvas, pane, { view = main, dock = dock })
	if not ok then
		-- A canvas just opened accepts updates once the window lists it.
		tern.log.debug("granola: canvas update deferred", err)
		tern.timer(100, function(cx2)
			if cx2 then
				redraw(cx2)
			end
		end)
	end
end

local function fail(cx: WindowCx, msg: string)
	model.busy = nil
	if find_panel(cx) then
		model.error = msg
		redraw(cx)
	else
		cx:toast("error", "Granola", msg)
	end
end

-- ── API key ─────────────────────────────────────────────────────────────────

local function ask_key(cx: WindowCx, after: ((key: string, cx: WindowCx) -> ())?)
	cx:prompt({ placeholder = "Granola API key (grn_…)", action = "save key", icon = "key" }):next(function(value, _err, cx2)
		local wcx = cx2 :: WindowCx
		if value == nil or trim(value) == "" then
			return
		end
		local key = trim(value)
		tern.secrets.set(SECRET, key):next(function(_r, err, cx3)
			local c = (cx3 or wcx) :: WindowCx
			if err then
				c:toast("error", "Couldn't store the Granola key", err)
				return
			end
			api_key = key
			model.key = "ok"
			model.error = nil
			c:toast("success", "Granola key saved")
			if after then
				after(key, c)
			end
		end)
	end)
end

-- Runs `fn` with the API key, reading the keychain once and asking when there is none.
local function with_key(cx: WindowCx, fn: (key: string, cx: WindowCx) -> ())
	if api_key then
		fn(api_key, cx)
		return
	end
	tern.secrets.get(SECRET):next(function(value, err, cx2)
		local c = (cx2 or cx) :: WindowCx
		if err then
			fail(c, "Couldn't read the keychain: " .. err)
			return
		end
		if type(value) == "string" and value ~= "" then
			api_key = value
			model.key = "ok"
			fn(value, c)
		else
			model.key = "missing"
			redraw(c)
			ask_key(c, fn)
		end
	end)
end

-- ── Loading ─────────────────────────────────────────────────────────────────

local function load(cx: WindowCx, more: boolean)
	if model.loading then
		return
	end
	with_key(cx, function(key, c)
		model.loading = true
		model.error = nil
		redraw(c)
		api.list(key, if more then model.cursor else nil, function(page, err, c2)
			model.loading = false
			if err or page == nil then
				model.error = err
				if err and string.find(err, "401") then
					model.key = "missing"
					api_key = nil
				end
				redraw(c2)
				return
			end
			if more then
				for _, n in page.notes do
					table.insert(model.notes, n)
				end
			else
				model.notes = page.notes
			end
			model.cursor = page.cursor
			redraw(c2)
		end)
	end)
end

local function has_transcript(note: any): boolean
	return type(note) == "table" and type(note.transcript) == "table"
end

-- Fetches the notes `ids` (with transcripts when the toggle says so), one at a time to stay well
-- under Granola's rate limit, reusing what previews already loaded.
local function gather(cx: WindowCx, ids: { string }, done: (notes: { any }, cx: WindowCx) -> ())
	with_key(cx, function(key, c)
		local want_transcript = model.transcript
		local notes: { any } = {}
		local function step(i: number, sc: WindowCx)
			if i > #ids then
				model.busy = nil
				redraw(sc)
				done(notes, sc)
				return
			end
			local id = ids[i]
			local cached = model.details[id]
			if cached and (not want_transcript or has_transcript(cached)) then
				table.insert(notes, cached)
				step(i + 1, sc)
				return
			end
			model.busy = string.format("Fetching %d of %d from Granola…", i, #ids)
			redraw(sc)
			api.note(key, id, want_transcript, function(note, err, c2)
				if err or note == nil then
					fail(c2, err or "Granola returned nothing")
					return
				end
				model.details[id] = note
				table.insert(notes, note)
				step(i + 1, c2)
			end)
		end
		step(1, c)
	end)
end

-- ── Delivery to agents ──────────────────────────────────────────────────────

-- The directory a new agent starts in: the pane the user last worked in, else a terminal or agent
-- beside the panel, else home.
local function focused_cwd(cx: WindowCx): string
	local pane = if last_pane then cx.session:pane(last_pane) else nil
	if pane and pane.cwd and pane.cwd ~= "" then
		return pane.cwd
	end
	local panel = find_panel(cx)
	local tab = if panel then cx.session:tab_of(panel) else nil
	for _, p in cx.session:panes() do
		if p.tab == tab and (p.kind == "terminal" or p.kind == "agent") and p.cwd and p.cwd ~= "" then
			return p.cwd
		end
	end
	return tern.getenv("HOME") or "~"
end

-- An agent's last reply as one plain line of at most 70 characters.
local function gist(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	local s = trim((string.gsub(string.gsub(text, "[%*_`#>]", ""), "%s+", " ")))
	s = (string.gsub(s, "^[-%s]+", ""))
	if utf8.len(s) and (utf8.len(s) :: number) > 70 then
		s = string.sub(s, 1, (utf8.offset(s, 70) :: number) - 1) .. "…"
	end
	return s
end

local STATE_LABEL = { idle = "idle", working = "working", waiting_input = "waiting for you", exited = "exited" }

local function agent_items(cx: WindowCx): { PickItem }
	local items: { PickItem } = {}
	local agents = cx.agents:list()
	table.sort(agents, function(a, b)
		if (a.pane == last_pane) ~= (b.pane == last_pane) then
			return a.pane == last_pane
		end
		return a.pane > b.pane
	end)
	for _, a in agents do
		if a.state ~= "exited" then
			local last = gist(a.last_message)
			local who = if type(a.model) == "string" then a.model elseif type(a.command) == "string" then a.command else "agent"
			table.insert(items, {
				label = basename(a.cwd) .. " · " .. who,
				detail = (STATE_LABEL[a.state] or a.state) .. (if last ~= "" then " — " .. last else ""),
				group = "Agent sessions",
				icon = "sparkle",
				current = a.pane == last_pane,
				pane = a.pane,
			})
		end
	end
	local cwd = focused_cwd(cx)
	table.insert(items, {
		label = "New agent in " .. basename(cwd),
		detail = cwd,
		group = "New",
		icon = "plus",
		cwd = cwd,
	})
	return items
end

-- Writes a long document where the agent can read it; nil when it goes inline.
local function spill(doc: string, titles: { string }): string?
	if #doc <= context.INLINE_LIMIT then
		return nil
	end
	local dir = tern.plugin.data .. "/context"
	tern.fs.mkdir(dir)
	local path = dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. context.slug(titles[1] or "meeting")
		.. (if #titles > 1 then string.format("-and-%d-more", #titles - 1) else "") .. ".md"
	tern.fs.write(path, doc)
	return path
end

local function dispatch(cx: WindowCx, target: any, text: string, count: number)
	local what = if count == 1 then "1 meeting" else tostring(count) .. " meetings"
	if target.cwd then
		local ok, pane = pcall(cx.agents.start, cx.agents, { prompt = text, cwd = target.cwd, how = "split" })
		if not ok then
			cx:toast("error", "Couldn't start an agent", tostring(pane))
			return
		end
		cx:toast("success", "Sent " .. what .. " to a new agent", target.cwd)
		return
	end
	local ok, err = pcall(cx.agents.ask, cx.agents, target.pane, text)
	if not ok then
		cx:toast("error", "Couldn't send to that agent", tostring(err))
		return
	end
	pcall(cx.layout.focus, cx.layout, target.pane)
	cx:toast("success", "Sent " .. what .. " to the agent")
end

local function send(cx: WindowCx, ids: { string })
	if #ids == 0 then
		return
	end
	gather(cx, ids, function(notes, c)
		local doc = context.document(notes, { transcript = model.transcript })
		local titles: { string } = {}
		for _, n in notes do
			table.insert(titles, context.title(n))
		end
		c:pick({
			items = agent_items(c),
			placeholder = "Send " .. (if #notes == 1 then "“" .. titles[1] .. "”" else tostring(#notes) .. " meetings") .. " to…",
			icon = "sparkle",
			action = "send here",
		}):next(function(target, _err, c2)
			if target == nil then
				return
			end
			(c2 :: WindowCx):prompt({
				placeholder = "What should the agent do with it? (empty: read it and wait)",
				action = "send",
				icon = "sparkle",
			}):next(function(instruction, _err2, c3)
				if instruction == nil then
					return
				end
				local wcx = c3 :: WindowCx
				local ok, path = pcall(spill, doc, titles)
				if not ok then
					wcx:toast("error", "Couldn't write the context file", tostring(path))
					return
				end
				dispatch(wcx, target, context.prompt(doc, titles, instruction, path), #notes)
			end)
		end)
	end)
end

local function copy(cx: WindowCx, ids: { string })
	gather(cx, ids, function(notes, c)
		c:copy(context.document(notes, { transcript = model.transcript }))
		c:toast("success", if #notes == 1 then "Copied 1 meeting" else "Copied " .. tostring(#notes) .. " meetings")
	end)
end

-- ── Panel actions ───────────────────────────────────────────────────────────

local function toggle_pick(id: string)
	local idx = table.find(model.picked, id)
	if idx then
		table.remove(model.picked, idx)
	else
		table.insert(model.picked, id)
	end
end

local function expand(cx: WindowCx, id: string)
	model.expanded[id] = not model.expanded[id] or nil
	redraw(cx)
	if model.expanded[id] and model.details[id] == nil then
		model.detail_errors[id] = nil
		with_key(cx, function(key, _c)
			api.note(key, id, false, function(note, err, c2)
				if err then
					model.detail_errors[id] = err
				else
					model.details[id] = note
				end
				redraw(c2)
			end)
		end)
	end
end

local function open_web(cx: WindowCx, id: string)
	local cached = model.details[id]
	if cached and cached.web_url then
		cx:open(cached.web_url)
		return
	end
	with_key(cx, function(key, _c)
		api.note(key, id, false, function(note, err, c2)
			if err or note == nil or type(note.web_url) ~= "string" then
				fail(c2, err or "This note has no web link")
				return
			end
			model.details[id] = note
			c2:open(note.web_url)
		end)
	end)
end

local function filter(cx: WindowCx)
	cx:prompt({ value = model.filter, placeholder = "Filter meetings by title or attendee", action = "filter", icon = "search" })
		:next(function(value, _err, c)
			if value == nil then
				return
			end
			local f = trim(value)
			model.filter = if f == "" then nil else f
			redraw(c :: WindowCx)
		end)
end

local function open_panel(cx: WindowCx)
	model.now = os.time()
	local main, dock = view.render(model)
	local pane, err = cx.canvas:open({ title = TITLE, about = ABOUT, view = main, dock = dock, how = "beside", focus = false })
	if pane == nil then
		cx:toast("error", "Couldn't open the Granola panel", err)
		return
	end
	panel_pane = pane
	if #model.notes == 0 then
		load(cx, false)
	end
end

local function toggle_panel(cx: WindowCx)
	local pane = find_panel(cx)
	if pane then
		cx.layout:close(pane)
		panel_pane = nil
	else
		open_panel(cx)
	end
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx)
	if ev.pane ~= find_panel(cx) then
		return nil
	end
	local act, id = ev.act, ev.value
	if act == "refresh" then
		load(cx, false)
	elseif act == "more" then
		load(cx, true)
	elseif act == "key" then
		ask_key(cx, function(_key, c)
			load(c, false)
		end)
	elseif act == "search" then
		filter(cx)
	elseif act == "clear-filter" then
		model.filter = nil
		redraw(cx)
	elseif act == "transcript" then
		model.transcript = not model.transcript
		tern.kv.set("transcript", model.transcript)
		redraw(cx)
	elseif act == "pick" and id then
		toggle_pick(id)
		redraw(cx)
	elseif act == "expand" and id then
		expand(cx, id)
	elseif act == "send" and id then
		send(cx, { id })
	elseif act == "copy" and id then
		copy(cx, { id })
	elseif act == "web" and id then
		open_web(cx, id)
	elseif act == "send-picked" then
		send(cx, table.clone(model.picked))
	elseif act == "copy-picked" then
		copy(cx, table.clone(model.picked))
	elseif act == "clear-picked" then
		model.picked = {}
		redraw(cx)
	end
	return true
end)

-- ── Palette ─────────────────────────────────────────────────────────────────

tern.command({
	id = "panel",
	title = "Granola: Show or hide meetings",
	icon = "sparkle",
	keys = { "cmd+alt+shift+g" },
	run = toggle_panel,
})

tern.command({
	id = "key",
	title = "Granola: Set API key",
	icon = "key",
	run = function(cx)
		ask_key(cx, function(_key, c)
			load(c, false)
		end)
	end,
})

-- Picks one recent meeting from the palette and sends it, without opening the panel.
tern.command({
	id = "send",
	title = "Granola: Send a meeting to an agent…",
	icon = "sparkle",
	run = function(cx)
		with_key(cx, function(key, c)
			local function choose(pc: WindowCx)
				local items: { PickItem } = {}
				for _, n in model.notes do
					table.insert(items, {
						label = context.title(n),
						detail = context.when(n.created_at, os.time(), model.offset),
						icon = "sparkle",
						id = n.id,
					})
				end
				if #items == 0 then
					pc:toast("info", "No summarized Granola meetings yet")
					return
				end
				pc:pick({ items = items, placeholder = "Send which meeting?", icon = "sparkle", action = "pick meeting" })
					:next(function(item, _err, c2)
						if item then
							send(c2 :: WindowCx, { item.id })
						end
					end)
			end
			if #model.notes > 0 then
				choose(c)
				return
			end
			api.list(key, nil, function(page, err, c2)
				if err or page == nil then
					fail(c2, err or "Granola returned nothing")
					return
				end
				model.notes, model.cursor = page.notes, page.cursor
				redraw(c2)
				choose(c2)
			end)
		end)
	end,
})

-- ── Window events ───────────────────────────────────────────────────────────

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	if ev.pane ~= panel_pane then
		last_pane = ev.pane
	end
end)

-- Reads the key and adopts a panel left open by a restart. `window_start` covers a new window; a
-- plugin reload in a running window gets no `window_start`, so a timer runs it once as well.
local started = false
local function start(cx: WindowCx)
	if started then
		return
	end
	started = true
	local focused = cx.session:focused()
	if focused and focused ~= find_panel(cx) then
		last_pane = focused
	end
	tern.secrets.get(SECRET):next(function(value, _err, cx2)
		if type(value) == "string" and value ~= "" then
			api_key = value
			model.key = "ok"
		else
			model.key = "missing"
		end
		local c = cx2 :: WindowCx
		-- A panel left open by a reload or restart is adopted and filled.
		if c and find_panel(c) then
			if model.key == "ok" then
				load(c, false)
			else
				redraw(c)
			end
		end
	end)
end

tern.on("window_start", start)
tern.timer(0, function(cx)
	if cx then
		start(cx)
	end
end)

-- ── Carly ───────────────────────────────────────────────────────────────────

-- Exports get their arguments first, then `cx` and the call handle.
local function split_args(...: any): ({ any }, ExportCall)
	local args = { ... }
	local call = args[#args]
	return { table.unpack(args, 1, #args - 2) }, call
end

tern.carly.export("recent", {
	sig = "recent() -> { { id: string, title: string, when: string } }",
	doc = "Recent Granola meetings (newest first, up to 30) with note ids for note(id).",
}, function(...)
	local _, call = split_args(...)
	if api_key == nil then
		call:fail("No Granola API key: run “Granola: Set API key” from the palette.")
		return nil
	end
	api.list(api_key, nil, function(page, err, _cx)
		if err or page == nil then
			call:fail(err or "Granola returned nothing")
			return
		end
		local out = {}
		for _, n in page.notes do
			table.insert(out, { id = n.id, title = context.title(n), when = n.created_at or "" })
		end
		call:reply(tern.json.array(out))
	end)
	return call:wait(30000)
end)

tern.carly.export("note", {
	sig = "note(id: string, transcript: boolean?) -> string",
	doc = "One Granola meeting as Markdown: attendees, summary, my notes and, with transcript = true, the transcript.",
}, function(...)
	local args, call = split_args(...)
	local id, transcript = args[1], args[2] == true
	if type(id) ~= "string" then
		call:fail("note(id): id is a Granola note id such as not_1d3tmYTlCICgjy (see recent()).")
		return nil
	end
	if api_key == nil then
		call:fail("No Granola API key: run “Granola: Set API key” from the palette.")
		return nil
	end
	api.note(api_key, id, transcript, function(note, err, _cx)
		if err or note == nil then
			call:fail(err or "Granola returned nothing")
			return
		end
		call:reply(context.note(note, { transcript = transcript }))
	end)
	return call:wait(60000)
end)

-- Tells Carly what the panel has gathered, so “send these to …” has a referent.
tern.carly.context(function(_cx)
	if #model.picked == 0 then
		return nil
	end
	local titles: { string } = {}
	for _, id in model.picked do
		for _, n in model.notes do
			if n.id == id then
				table.insert(titles, context.title(n))
			end
		end
	end
	return "Granola meetings gathered in the panel: " .. table.concat(titles, "; ")
end)
