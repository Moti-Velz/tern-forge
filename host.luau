--!strict
-- Block `granola.meetings`: the Granola panel as a focusable block driven by the keyboard (and the
-- mouse). It owns the UI state: selection, gathered meetings, list or details screen, filter. The window half owns
-- what only a window can do (the API key in the keychain, Granola requests, pasting into an agent,
-- focus), so the block asks it through `tern-granola://VERB?…` links (`cx:open` → `route.link`) and
-- gets answers back as `granola` action events (`cx.session:event`).

local context = require("./lib/context")
local view = require("./lib/view")

type State = view.State & { cx: BlockCx }

local function utc_offset(): number
	local now = os.time()
	return now - os.time(os.date("!*t", now) :: any)
end

-- Asks the window half for something; `params` values are ids, numbers or flags.
local function request(cx: BlockCx, verb: string, params: { [string]: string }?)
	local parts: { string } = { "pane=" .. tostring(cx.pane) }
	for k, v in params or {} do
		table.insert(parts, k .. "=" .. v)
	end
	cx:open("tern-granola://" .. verb .. "?" .. table.concat(parts, "&"))
end

local function visible(s: State): { any }
	return view.visible(s)
end

local function selected(s: State): any?
	local shown = visible(s)
	if #shown == 0 then
		return nil
	end
	return shown[math.clamp(s.sel, 1, #shown)]
end

-- The details screen needs the selected meeting's details; fetched once, then cached.
local function want_detail(s: State)
	local note = selected(s)
	if s.detail and note and s.details[note.id] == nil and s.detail_errors[note.id] == nil then
		s.detail_errors[note.id] = nil
		request(s.cx, "detail", { id = note.id })
	end
end

local function move(s: State, delta: number)
	local shown = visible(s)
	if #shown == 0 then
		return
	end
	local target = s.sel + delta
	if target > #shown and s.more and not s.loading then
		s.loading = true
		request(s.cx, "load", { more = "1" })
	end
	s.sel = math.clamp(target, 1, #shown)
	want_detail(s)
end

local function toggle_pick(s: State, id: string)
	local idx = table.find(s.picked, id)
	if idx then
		table.remove(s.picked, idx)
	else
		table.insert(s.picked, id)
	end
	request(s.cx, "picked", { ids = table.concat(s.picked, ",") })
end

-- Saved state comes back as decoded JSON, whose arrays are read-only; gathered ids live in a plain
-- table.
local function restore_ids(saved: any): { string }
	local out: { string } = {}
	if type(saved) == "table" and type(saved.picked) == "table" then
		for _, id in saved.picked do
			if type(id) == "string" then
				table.insert(out, id)
			end
		end
	end
	return out
end

-- The gathered meetings, else the selected one.
local function targets(s: State): { string }
	if #s.picked > 0 then
		return table.clone(s.picked)
	end
	local note = selected(s)
	return if note then { note.id } else {}
end

local function attach(s: State)
	local ids = targets(s)
	if #ids == 0 then
		return
	end
	s.busy = "Adding to the agent…"
	request(s.cx, "attach", { ids = table.concat(ids, ","), transcript = if s.transcript then "1" else "0" })
end

local function copy(s: State)
	local ids = targets(s)
	if #ids > 0 then
		request(s.cx, "copy", { ids = table.concat(ids, ","), transcript = if s.transcript then "1" else "0" })
	end
end

local function set_mode(s: State, transcript: boolean)
	s.transcript = transcript
	tern.kv.set("transcript", transcript)
end

local function reload(s: State)
	s.loading = true
	s.error = nil
	request(s.cx, "load", { more = "0" })
end

-- Keys while typing a filter: text appends, backspace deletes, ⏎ keeps it, esc clears it.
local function filter_key(s: State, k: Key): boolean
	if k.name == "enter" then
		s.filtering = false
	elseif k.name == "escape" then
		s.filtering = false
		s.filter = nil
	elseif k.name == "backspace" then
		local f = s.filter or ""
		local last = if f ~= "" then utf8.offset(f, -1) else nil
		s.filter = if last and last > 1 then string.sub(f, 1, last - 1) else nil
	elseif k.name == "up" or k.name == "down" then
		move(s, if k.name == "up" then -1 else 1)
		return true
	elseif k.text and k.text ~= "" and not k.ctrl and not k.meta then
		s.filter = (s.filter or "") .. k.text
	else
		return false
	end
	s.sel = 1
	want_detail(s)
	return true
end

local function on_key(s: State, k: Key, _cx: BlockCx): boolean?
	if s.filtering then
		return filter_key(s, k)
	end
	-- Letters by what they type (Shift+G arrives as name "g", text "G"); other keys by name.
	local name = if k.text and #k.text == 1 and k.text ~= " " and not k.ctrl and not k.alt and not k.meta then k.text else k.name
	if s.key == "missing" then
		if name == "K" or name == "enter" then
			request(s.cx, "key")
		elseif name == "escape" then
			request(s.cx, "back")
		end
		return false
	end
	if name == "down" or name == "j" then
		move(s, 1)
	elseif name == "up" or name == "k" then
		move(s, -1)
	elseif name == "pagedown" then
		move(s, 10)
	elseif name == "pageup" then
		move(s, -10)
	elseif name == "home" or name == "g" then
		s.sel = 1
		want_detail(s)
	elseif name == "end" or name == "G" then
		s.sel = #visible(s)
		want_detail(s)
	elseif name == "space" then
		local note = selected(s)
		if note then
			toggle_pick(s, note.id)
		end
	elseif name == "enter" then
		attach(s)
	elseif (name == "right" or name == "l") and not s.detail then
		s.detail = true
		want_detail(s)
	elseif (name == "left" or name == "h") and s.detail then
		s.detail = false
	elseif name == "tab" then
		set_mode(s, not s.transcript)
	elseif name == "/" then
		s.detail = false
		s.filtering = true
	elseif name == "c" then
		copy(s)
		return false
	elseif name == "o" then
		local note = selected(s)
		if note then
			request(s.cx, "web", { id = note.id })
		end
		return false
	elseif name == "x" then
		s.picked = {}
		request(s.cx, "picked", { ids = "" })
	elseif name == "r" then
		reload(s)
	elseif name == "K" then
		request(s.cx, "key")
		return false
	elseif name == "?" then
		s.help = not s.help
	elseif name == "escape" then
		if s.detail then
			s.detail = false
		elseif s.filter then
			s.filter = nil
		else
			request(s.cx, "back")
			return false
		end
	else
		return false
	end
	return true
end

-- An answer from the window half.
local function on_answer(s: State, kind: string, data: any)
	if kind == "state" then
		s.key = data.key or s.key
		if data.notes then
			s.notes = data.notes
		end
		s.more = data.more == true
		s.loading = data.loading == true
		s.error = data.error
		s.sel = math.clamp(s.sel, 1, math.max(1, #visible(s)))
		want_detail(s)
	elseif kind == "detail" then
		if data.error then
			s.detail_errors[data.id] = data.error
		else
			s.details[data.id] = data.note
		end
	elseif kind == "busy" then
		s.busy = data.text
	elseif kind == "done" then
		s.busy = nil
		if data.clear then
			s.picked = {}
		end
	end
end

local function on_event(s: State, ev: UiEvent, cx: BlockCx)
	if ev.act == "granola" then
		local ok, data = pcall(tern.json.decode, ev.data or "null")
		if ok and type(data) == "table" then
			on_answer(s, ev.kind, data)
		end
		cx:render()
		cx:save()
		return
	end
	local idx = if type(ev.item) == "string" then tonumber(string.match(ev.item, "%.(%d+)$")) else nil
	if ev.ev == "select" and idx then
		s.sel = idx + 1
		want_detail(s)
	elseif ev.ev == "activate" and idx then
		s.sel = idx + 1
		s.detail = true
		want_detail(s)
	elseif ev.act == "details" then
		s.detail = ev.value == "open"
		want_detail(s)
	elseif ev.act == "gather" then
		local note = selected(s)
		if note then
			toggle_pick(s, note.id)
		end
	elseif ev.act == "copy" then
		copy(s)
	elseif ev.act == "web" then
		local note = selected(s)
		if note then
			request(cx, "web", { id = note.id })
		end
	elseif ev.act == "attach" then
		attach(s)
	elseif ev.act == "clear" then
		s.picked = {}
		request(cx, "picked", { ids = "" })
	elseif ev.act == "mode" then
		set_mode(s, ev.value == "transcript")
	elseif ev.act == "reload" then
		reload(s)
	elseif ev.act == "key" then
		request(cx, "key")
	end
	cx:render()
	cx:save()
end

tern.block.define("meetings", {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local s: State = {
			cx = cx,
			key = "checking",
			notes = {},
			more = false,
			loading = true,
			error = nil,
			details = {},
			detail_errors = {},
			sel = 1,
			picked = restore_ids(saved),
			detail = false,
			filter = nil,
			filtering = false,
			transcript = tern.kv.get("transcript") == true,
			busy = nil,
			help = false,
			now = os.time(),
			offset = utc_offset(),
		}
		-- `hello` goes out once the block is up, and again while the window half (still starting, or
		-- in a window that hasn't seen the block yet) hasn't answered with the key state.
		local tries = 0
		local function hello()
			if s.key ~= "checking" or tries >= 20 then
				return
			end
			tries += 1
			request(cx, "hello", { ids = table.concat(s.picked, ",") })
			tern.timer(500, hello)
		end
		tern.timer(0, hello)
		return s
	end,
	title = function(_s: State): string?
		return "Granola"
	end,
	view = function(s: State, cx: BlockCx): BlockView
		s.now = os.time()
		return view.render(s, cx.rows)
	end,
	key = on_key,
	event = on_event,
	save = function(s: State): any
		return { picked = s.picked }
	end,
})
