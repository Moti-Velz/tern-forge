--!strict
-- Window half: everything the meetings block (host.luau) can't do itself. It keeps the sources'
-- credentials (API keys in the keychain, the local folder in kv), talks to the sources, pastes
-- meetings into the agent's composer and moves focus. The block asks through `tern-<id>://VERB?…`
-- links (lib/link.luau), claimed here by `route.link`; answers go back as `meetings` action events on
-- the block's pane. Alt+G jumps to the block and back. Carly gets the meetings through the `recent`
-- and `note` exports.

local context = require("./lib/context")
local link = require("./lib/link")
local source = require("./lib/sources/source")

local SOURCES: { source.Def } = {
	require("./lib/sources/granola"),
	require("./lib/sources/fireflies"),
	require("./lib/sources/local"),
	require("./lib/sources/email"),
}
local BY_ID: { [string]: source.Def } = {}
for _, def in SOURCES do
	BY_ID[def.id] = def
end

local KIND = tern.plugin.id .. ".panel"
local LOCAL_DIR = "local-dir"

-- Each source's credential once read: the API key or the folder; nil when not connected.
local creds: { [string]: string? } = {}
local creds_read = false
-- The pane the user last worked in outside the block: where Esc returns, a new agent's directory.
local last_pane: number? = nil
-- The agent block the user last worked in: where gathered meetings go.
local last_agent: number? = nil

-- Meetings loaded so far (newest first, all sources), each source's next-page cursor, and full
-- meetings by id.
local notes: { any } = {}
local cursors: { [string]: string? } = {}
local details: { [string]: any } = {}
-- What the block has gathered, for Carly's context.
local picked: { string } = {}

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function connected(): { source.Def }
	local out: { source.Def } = {}
	for _, def in SOURCES do
		if creds[def.id] then
			table.insert(out, def)
		end
	end
	return out
end

local function block_pane(cx: WindowCx): number?
	for _, p in cx.session:panes() do
		if p.block == KIND then
			return p.pane
		end
	end
	return nil
end

-- Sends an answer to the block in `pane`; a closed block just misses it.
local function answer(cx: WindowCx, pane: number, kind: string, data: any)
	pcall(cx.session.event, cx.session, pane, { ev = "action", act = "meetings", kind = kind, data = tern.json.encode(data) })
end

local function any_cursor(): boolean
	for _, c in cursors do
		if c then
			return true
		end
	end
	return false
end

local function send_state(cx: WindowCx, pane: number, extra: { [string]: any }?)
	local names: { string } = {}
	for _, def in connected() do
		table.insert(names, def.name)
	end
	local data: { [string]: any } = {
		key = if #names > 0 then "ok" else "missing",
		sources = tern.json.array(names),
		notes = tern.json.array(notes),
		more = any_cursor(),
		loading = false,
	}
	for k, v in extra or {} do
		data[k] = v
	end
	answer(cx, pane, "state", data)
end

-- ── Credentials ─────────────────────────────────────────────────────────────

-- Reads every source's credential once (keychain reads are async), then runs `fn`.
local function with_creds(cx: WindowCx, fn: (cx: WindowCx) -> ())
	if creds_read then
		fn(cx)
		return
	end
	local dir = tern.kv.get(LOCAL_DIR)
	creds["local"] = if type(dir) == "string" and dir ~= "" then dir else nil
	local secrets: { source.Def } = {}
	for _, def in SOURCES do
		if def.credential == "secret" then
			table.insert(secrets, def)
		end
	end
	local function step(i: number, c: WindowCx)
		if i > #secrets then
			creds_read = true
			fn(c)
			return
		end
		local def = secrets[i]
		tern.secrets.get(def.secret :: string):next(function(value, err, c2)
			local wcx = (c2 or c) :: WindowCx
			if err then
				wcx:toast("error", "Couldn't read the keychain", err)
			end
			creds[def.id] = if type(value) == "string" and value ~= "" then value else nil
			step(i + 1, wcx)
		end)
	end
	step(1, cx)
end

local function store(cx: WindowCx, def: source.Def, value: string?, after: (cx: WindowCx) -> ())
	creds[def.id] = value
	cursors[def.id] = nil
	if def.credential == "path" then
		tern.kv.set(LOCAL_DIR, value)
		after(cx)
		return
	end
	tern.secrets.set(def.secret :: string, value):next(function(_r, err, c2)
		local wcx = (c2 or cx) :: WindowCx
		if err then
			wcx:toast("error", "Couldn't store the " .. def.name .. " key", err)
			return
		end
		after(wcx)
	end)
end

-- Picks a source and asks for its key or folder; an empty answer disconnects a connected one.
local function connect(cx: WindowCx, after: (cx: WindowCx) -> ())
	with_creds(cx, function(c)
		local items: { PickItem } = {}
		for _, def in SOURCES do
			local on = creds[def.id] ~= nil
			table.insert(items, {
				label = def.name,
				detail = if on then (if def.credential == "path" then creds[def.id] else "connected")
					else (if def.credential == "path" then "a folder of exports" else (def.needs or "API key")),
				icon = if def.credential == "path" then "folder" else "key",
				current = on,
				source = def.id,
			})
		end
		c:pick({ items = items, placeholder = "Connect a source", icon = "key", action = "connect" }):next(function(item, _err, c2)
			if item == nil then
				return
			end
			local def = BY_ID[item.source]
			local on = creds[def.id] ~= nil
			local hint = def.prompt .. (if on then " (empty disconnects)" else "")
			;(c2 :: WindowCx):prompt({
				value = if def.credential == "path" then creds[def.id] else nil,
				placeholder = hint, action = if def.credential == "path" then "use folder" elseif def.then_prompt then "next" else "save key",
				icon = if def.credential == "path" then "folder" else "key",
			}):next(function(value, _err2, c3)
				local wcx = c3 :: WindowCx
				if value == nil then
					return
				end
				local v = trim(value)
				if v == "" and not on then
					return
				end
				-- A second field (the email password) follows the first; both are stored as one secret.
				if v ~= "" and def.then_prompt then
					wcx:prompt({ placeholder = def.then_prompt, action = "save", icon = "key" }):next(function(second, _e, c5)
						if second == nil or trim(second) == "" then
							return
						end
						local entry = v .. "\n" .. trim(second)
						store(c5 :: WindowCx, def, if def.merge then def.merge(creds[def.id], entry) else entry, function(c4)
							c4:toast("success", if def.merge then def.name .. ": " .. v .. " added" else def.name .. " connected")
							after(c4)
						end)
					end)
					return
				end
				store(wcx, def, if v == "" then nil else v, function(c4)
					c4:toast("success", if v == "" then def.name .. " disconnected" else def.name .. " connected")
					after(c4)
				end)
			end)
		end)
	end)
end

-- ── Requests ────────────────────────────────────────────────────────────────

-- Newest first by actual time (sources write timestamps with different offsets); undated last.
local function by_date(a: any, b: any): boolean
	return (context.epoch(a.created_at) or 0) > (context.epoch(b.created_at) or 0)
end

-- Lists the first page of every connected source (or, with `more`, the next page of each that has
-- one) and merges them newest first; `done` gets the errors of the sources that failed.
local function list_all(cx: WindowCx, more: boolean, done: (errs: { string }, cx: WindowCx) -> ())
	with_creds(cx, function(c)
		local todo: { source.Def } = {}
		for _, def in connected() do
			if not more or cursors[def.id] then
				table.insert(todo, def)
			end
		end
		if #todo == 0 then
			if not more then
				notes = {}
			end
			done({}, c)
			return
		end
		local pending = #todo
		local got: { any } = if more then notes else {}
		local errs: { string } = {}
		for _, def in todo do
			def.list(creds[def.id] :: string, if more then cursors[def.id] else nil, function(page, err, c2)
				if err or page == nil then
					table.insert(errs, err or (def.name .. " returned nothing"))
					cursors[def.id] = nil
					-- A rejected key is forgotten for this session, so the block asks to connect again.
					if err and string.find(err, "(401)", 1, true) then
						creds[def.id] = nil
					end
				else
					for _, n in page.notes do
						table.insert(got, n)
					end
					cursors[def.id] = page.cursor
				end
				pending -= 1
				if pending == 0 then
					table.sort(got, by_date)
					notes = got
					done(errs, c2)
				end
			end)
		end
	end)
end

local function load(cx: WindowCx, pane: number, more: boolean)
	list_all(cx, more, function(errs, c)
		send_state(c, pane, { error = if #errs > 0 then table.concat(errs, " · ") else nil })
	end)
end

-- One meeting in full from its source (cached unless a transcript is wanted and missing).
local function fetch(cx: WindowCx, id: string, transcript: boolean, done: source.Done<any>)
	local cached = details[id]
	if cached and (not transcript or type(cached.transcript) == "table") then
		done(cached, nil, cx)
		return
	end
	with_creds(cx, function(c)
		local src, native = source.split(id)
		local def = BY_ID[src]
		if def == nil or creds[src] == nil then
			done(nil, (if def then def.name else src) .. " isn't connected", c)
			return
		end
		def.note(creds[src] :: string, native, transcript, function(note, err, c2)
			if note then
				details[id] = note
			end
			done(note, err, c2)
		end)
	end)
end

local function detail(cx: WindowCx, pane: number, id: string)
	fetch(cx, id, false, function(note, err, c)
		answer(c, pane, "detail", { id = id, note = note, error = if note then nil else (err or "Nothing came back") })
	end)
end

-- Fetches the meetings `ids` (with transcripts when asked) one at a time, to stay well under the
-- sources' rate limits.
local function gather(cx: WindowCx, pane: number?, ids: { string }, transcript: boolean, done: (notes: { any }, cx: WindowCx) -> ())
	local out: { any } = {}
	local function step(i: number, sc: WindowCx)
		if i > #ids then
			done(out, sc)
			return
		end
		if pane and #ids > 1 then
			answer(sc, pane, "busy", { text = string.format("Fetching %d of %d…", i, #ids) })
		end
		fetch(sc, ids[i], transcript, function(note, err, c2)
			if note == nil then
				if pane then
					answer(c2, pane, "done", {})
				end
				c2:toast("error", "Meetings", err or "Nothing came back")
				return
			end
			table.insert(out, note)
			step(i + 1, c2)
		end)
	end
	step(1, cx)
end

-- ── Delivery to agents ──────────────────────────────────────────────────────

-- The directory a new agent starts in: the pane the user last worked in, else home.
local function work_cwd(cx: WindowCx): string
	local pane = if last_pane then cx.session:pane(last_pane) else nil
	if pane and pane.cwd and pane.cwd ~= "" then
		return pane.cwd
	end
	return tern.getenv("HOME") or "~"
end

-- The agent to attach to: the one you last worked in, else the newest agent in the block's tab;
-- nil when there is none (a new one starts).
local function target_agent(cx: WindowCx, near: number?): number?
	local live: { [number]: boolean } = {}
	for _, a in cx.agents:list() do
		if a.state ~= "exited" then
			live[a.pane] = true
		end
	end
	if last_agent and live[last_agent] and cx.session:pane(last_agent) then
		return last_agent
	end
	local tab = if near then cx.session:tab_of(near) else nil
	local best: number? = nil
	for _, p in cx.session:panes() do
		if live[p.pane] and p.tab == tab and (best == nil or p.pane > best) then
			best = p.pane
		end
	end
	return best
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

-- Bracketed paste: the agent's composer takes the context as one paste and doesn't submit it.
local PASTE_START, PASTE_END = "\27[200~", "\27[201~"

-- Puts the meetings into the agent's composer, ready for your question, and focuses it; with no
-- agent around, starts one in the directory you were working in.
local function attach(cx: WindowCx, pane: number?, ids: { string }, transcript: boolean)
	gather(cx, pane, ids, transcript, function(got, c)
		local doc = context.document(got, { transcript = transcript })
		local titles: { string } = {}
		for _, n in got do
			table.insert(titles, context.title(n))
		end
		local ok, path = pcall(spill, doc, titles)
		if not ok then
			if pane then
				answer(c, pane, "done", {})
			end
			c:toast("error", "Couldn't write the context file", tostring(path))
			return
		end
		local text = context.attachment(doc, titles, path)
		local what = if #got == 1 then "“" .. titles[1] .. "”" else tostring(#got) .. " meetings"
		local agent = target_agent(c, pane)
		if agent == nil then
			local cwd = work_cwd(c)
			local started, err = pcall(c.agents.start, c.agents, {
				prompt = text .. "\n\n" .. context.WAIT, cwd = cwd, how = "split",
			})
			if pane then
				answer(c, pane, "done", { clear = started })
			end
			if started then
				c:toast("success", "Started an agent with " .. what, cwd)
			else
				c:toast("error", "Couldn't start an agent", tostring(err))
			end
			return
		end
		c:run(agent, PASTE_START .. text .. PASTE_END)
		pcall(c.layout.focus, c.layout, agent)
		if pane then
			answer(c, pane, "done", { clear = true })
		end
		local how = if path then "as a file" elseif transcript then "with transcripts" else "as synthesis"
		c:toast("success", "Added " .. what .. " " .. how, "Type your question and send")
	end)
end

local function copy(cx: WindowCx, ids: { string }, transcript: boolean)
	gather(cx, nil, ids, transcript, function(got, c)
		c:copy(context.document(got, { transcript = transcript }))
		c:toast("success", if #got == 1 then "Copied 1 meeting" else "Copied " .. tostring(#got) .. " meetings")
	end)
end

-- Opens the meeting where it lives: its web page, or the file for local meetings.
local function open_web(cx: WindowCx, id: string)
	fetch(cx, id, false, function(note, err, c)
		if note == nil or type(note.web_url) ~= "string" then
			c:toast("error", "Meetings", err or "This meeting has no link")
			return
		end
		c:open(note.web_url)
	end)
end

-- Back to where you were before the block: the agent, else the last pane, else another pane in the
-- block's tab (after a plugin reload nothing is remembered yet).
local function go_back(cx: WindowCx)
	local block = block_pane(cx)
	local target = target_agent(cx, block)
	if target == nil and last_pane and cx.session:pane(last_pane) then
		target = last_pane
	end
	if target == nil and block then
		local tab = cx.session:tab_of(block)
		for _, p in cx.session:panes() do
			if p.tab == tab and p.pane ~= block then
				target = p.pane
				break
			end
		end
	end
	if target then
		pcall(cx.layout.focus, cx.layout, target)
	end
end

tern.route.link(function(req: LinkRequest, cx: WindowCx): RouteDecision?
	local verb, q = link.parse(req.url)
	if verb == nil then
		return nil
	end
	local pane = tonumber(q.pane) or req.pane
	local transcript = q.transcript == "1"
	local id = if q.id then link.decode(q.id) else nil
	if verb == "hello" then
		picked = link.split(q.ids)
		if #notes > 0 and creds_read then
			send_state(cx, pane)
		else
			load(cx, pane, false)
		end
	elseif verb == "load" then
		load(cx, pane, q.more == "1")
	elseif verb == "detail" and id then
		detail(cx, pane, id)
	elseif verb == "attach" then
		attach(cx, pane, link.split(q.ids), transcript)
	elseif verb == "copy" then
		copy(cx, link.split(q.ids), transcript)
	elseif verb == "web" and id then
		open_web(cx, id)
	elseif verb == "picked" then
		picked = link.split(q.ids)
	elseif verb == "key" then
		connect(cx, function(c)
			load(c, pane, false)
		end)
	elseif verb == "back" then
		go_back(cx)
	end
	return { handled = true }
end)

-- ── Palette ─────────────────────────────────────────────────────────────────

-- Alt+G: into the meetings block (opening it beside you the first time), and from it back to the
-- agent.
local function toggle(cx: WindowCx)
	local pane = block_pane(cx)
	if pane and cx.session:focused() == pane then
		go_back(cx)
	elseif pane then
		cx.layout:focus(pane)
	else
		cx:new_block(KIND, {}, "beside")
	end
end

tern.command({
	id = "toggle",
	title = "Meetings: Jump in and back",
	icon = "sparkle",
	keys = { "alt+g" },
	run = toggle,
})

tern.command({
	id = "connect",
	title = "Meetings: Connect a source (Granola, Fireflies, email, local folder)",
	icon = "key",
	run = function(cx)
		connect(cx, function(c)
			local pane = block_pane(c)
			if pane then
				load(c, pane, false)
			end
		end)
	end,
})

-- ── Window events ───────────────────────────────────────────────────────────

local function remember(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if info == nil or info.block == KIND then
		return
	end
	last_pane = pane
	if info.kind == "agent" then
		last_agent = pane
	end
end

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	remember(cx, ev.pane)
end)

tern.on("window_start", function(cx: WindowCx)
	local focused = cx.session:focused()
	if focused then
		remember(cx, focused)
	end
end)

-- ── Carly ───────────────────────────────────────────────────────────────────

-- Exports get their arguments first, then `cx` and the call handle.
local function split_args(...: any): ({ any }, WindowCx, ExportCall)
	local args = { ... }
	return { table.unpack(args, 1, #args - 2) }, args[#args - 1], args[#args]
end

tern.carly.export("recent", {
	sig = "recent() -> { { id: string, title: string, when: string, source: string } }",
	doc = "Recent meetings from every connected source (Granola, Fireflies, local folder), newest first, with ids for note(id).",
}, function(...)
	local _, cx, call = split_args(...)
	list_all(cx, false, function(errs, _c)
		if #notes == 0 and #errs > 0 then
			call:fail(table.concat(errs, " · "))
			return
		end
		local out = {}
		for i, n in notes do
			if i > 30 then
				break
			end
			table.insert(out, { id = n.id, title = context.title(n), when = n.created_at or "", source = n.source })
		end
		call:reply(tern.json.array(out))
	end)
	return call:wait(30000)
end)

tern.carly.export("note", {
	sig = "note(id: string, transcript: boolean?) -> string",
	doc = "One meeting as Markdown: attendees, summary, notes and, with transcript = true, the transcript.",
}, function(...)
	local args, cx, call = split_args(...)
	local id, transcript = args[1], args[2] == true
	if type(id) ~= "string" then
		call:fail("note(id): id is a meeting id from recent(), such as fireflies:abc123.")
		return nil
	end
	fetch(cx, id, transcript, function(note, err, _c)
		if note == nil then
			call:fail(err or "Nothing came back")
			return
		end
		call:reply(context.note(note, { transcript = transcript }))
	end)
	return call:wait(60000)
end)

-- Tells Carly what the block has gathered, so “add these to …” has a referent.
tern.carly.context(function(_cx)
	if #picked == 0 then
		return nil
	end
	local titles: { string } = {}
	for _, id in picked do
		for _, n in notes do
			if n.id == id then
				table.insert(titles, context.title(n))
			end
		end
	end
	return if #titles > 0 then "Meetings gathered in the panel: " .. table.concat(titles, "; ") else nil
end)
