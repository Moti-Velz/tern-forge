--!strict
-- Window half: everything the Granola block (host.luau) can't do itself. It keeps the API key in the
-- keychain, talks to Granola, pastes meetings into the agent's composer and moves focus. The block
-- asks through `tern-granola://VERB?pane=N&…` links, claimed here by `route.link`; answers go back as
-- `granola` action events on the block's pane. Alt+G jumps to the block and back. Carly gets the
-- notes through the `recent` and `note` exports.

local api = require("./lib/api")
local context = require("./lib/context")

local KIND = "granola.meetings"
local SCHEME = "tern-granola://"
local SECRET = "api-key"

local api_key: string? = nil
-- The pane the user last worked in outside the block: where Esc returns, a new agent's directory.
local last_pane: number? = nil
-- The agent block the user last worked in: where gathered meetings go.
local last_agent: number? = nil

-- Meetings loaded so far (newest first), the next page's cursor, and fetched notes by id.
local notes: { any } = {}
local cursor: string? = nil
local details: { [string]: any } = {}
-- What the block has gathered, for Carly's context.
local picked: { string } = {}

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
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
	pcall(cx.session.event, cx.session, pane, { ev = "action", act = "granola", kind = kind, data = tern.json.encode(data) })
end

local function send_state(cx: WindowCx, pane: number, extra: { [string]: any }?)
	local data: { [string]: any } = {
		key = if api_key then "ok" else "missing",
		notes = tern.json.array(notes),
		more = cursor ~= nil,
		loading = false,
	}
	for k, v in extra or {} do
		data[k] = v
	end
	answer(cx, pane, "state", data)
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
			c:toast("success", "Granola key saved")
			if after then
				after(key, c)
			end
		end)
	end)
end

-- Runs `fn` with the API key, reading the keychain once; nil `key` means there is none.
local function with_key(cx: WindowCx, fn: (key: string?, cx: WindowCx) -> ())
	if api_key then
		fn(api_key, cx)
		return
	end
	tern.secrets.get(SECRET):next(function(value, err, cx2)
		local c = (cx2 or cx) :: WindowCx
		if err then
			c:toast("error", "Couldn't read the keychain", err)
		end
		if type(value) == "string" and value ~= "" then
			api_key = value
		end
		fn(api_key, c)
	end)
end

-- ── Requests ────────────────────────────────────────────────────────────────

local function load(cx: WindowCx, pane: number, more: boolean)
	with_key(cx, function(key, c)
		if key == nil then
			send_state(c, pane)
			return
		end
		api.list(key, if more then cursor else nil, function(page, err, c2)
			if err or page == nil then
				if err and string.find(err, "401") then
					api_key = nil
				end
				send_state(c2, pane, { error = err })
				return
			end
			if more then
				for _, n in page.notes do
					table.insert(notes, n)
				end
			else
				notes = page.notes
			end
			cursor = page.cursor
			send_state(c2, pane)
		end)
	end)
end

local function detail(cx: WindowCx, pane: number, id: string)
	if details[id] then
		answer(cx, pane, "detail", { id = id, note = details[id] })
		return
	end
	with_key(cx, function(key, c)
		if key == nil then
			return
		end
		api.note(key, id, false, function(note, err, c2)
			if err or note == nil then
				answer(c2, pane, "detail", { id = id, error = err or "Granola returned nothing" })
				return
			end
			details[id] = note
			answer(c2, pane, "detail", { id = id, note = note })
		end)
	end)
end

-- Fetches the notes `ids` (with transcripts when asked), one at a time to stay well under Granola's
-- rate limit, reusing what previews already loaded.
local function gather(cx: WindowCx, pane: number?, ids: { string }, transcript: boolean, done: (notes: { any }, cx: WindowCx) -> ())
	with_key(cx, function(key, c)
		if key == nil then
			c:toast("error", "Granola has no API key yet")
			return
		end
		local out: { any } = {}
		local function step(i: number, sc: WindowCx)
			if i > #ids then
				done(out, sc)
				return
			end
			local id = ids[i]
			local cached = details[id]
			if cached and (not transcript or type(cached.transcript) == "table") then
				table.insert(out, cached)
				step(i + 1, sc)
				return
			end
			if pane and #ids > 1 then
				answer(sc, pane, "busy", { text = string.format("Fetching %d of %d…", i, #ids) })
			end
			api.note(key, id, transcript, function(note, err, c2)
				if err or note == nil then
					if pane then
						answer(c2, pane, "done", {})
					end
					c2:toast("error", "Granola", err or "Granola returned nothing")
					return
				end
				details[id] = note
				table.insert(out, note)
				step(i + 1, c2)
			end)
		end
		step(1, c)
	end)
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

local function open_web(cx: WindowCx, id: string)
	if details[id] and details[id].web_url then
		cx:open(details[id].web_url)
		return
	end
	with_key(cx, function(key, c)
		if key == nil then
			return
		end
		api.note(key, id, false, function(note, err, c2)
			if err or note == nil or type(note.web_url) ~= "string" then
				c2:toast("error", "Granola", err or "This note has no web link")
				return
			end
			details[id] = note
			c2:open(note.web_url)
		end)
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

local function split_ids(s: string?): { string }
	local ids: { string } = {}
	for id in string.gmatch(s or "", "[%w_]+") do
		table.insert(ids, id)
	end
	return ids
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	-- The scheme has a `-`, a pattern quantifier, so the verb is cut out by position.
	local verb = string.match(string.sub(link.url, #SCHEME + 1), "^([%w-]+)") or ""
	local q: { [string]: string } = {}
	for k, v in string.gmatch(string.match(link.url, "%?(.*)$") or "", "([^&=]+)=([^&]*)") do
		q[k] = v
	end
	local pane = tonumber(q.pane) or link.pane
	local transcript = q.transcript == "1"
	if verb == "hello" then
		picked = split_ids(q.ids)
		if #notes > 0 and api_key then
			send_state(cx, pane)
		else
			load(cx, pane, false)
		end
	elseif verb == "load" then
		load(cx, pane, q.more == "1")
	elseif verb == "detail" and q.id then
		detail(cx, pane, q.id)
	elseif verb == "attach" then
		attach(cx, pane, split_ids(q.ids), transcript)
	elseif verb == "copy" then
		copy(cx, split_ids(q.ids), transcript)
	elseif verb == "web" and q.id then
		open_web(cx, q.id)
	elseif verb == "picked" then
		picked = split_ids(q.ids)
	elseif verb == "key" then
		ask_key(cx, function(_key, c)
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
	id = "meetings",
	title = "Granola: Meetings (jump in and back)",
	icon = "sparkle",
	keys = { "alt+g" },
	run = toggle,
})

tern.command({
	id = "key",
	title = "Granola: Set API key",
	icon = "key",
	run = function(cx)
		ask_key(cx, function(_key, c)
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
	return if #titles > 0 then "Granola meetings gathered in the panel: " .. table.concat(titles, "; ") else nil
end)
