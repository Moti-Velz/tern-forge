--!strict
-- Block `forge.usage` (from tern-claude-usage by zerx-lab, MIT): subscription quota windows of Claude Pro/Max (5 h, 7 d, per-model
-- weekly, extra usage) and ChatGPT (Codex 5 h / 7 d, credits) for every known login, one provider
-- per tab, refreshed on a timer, with per-account aliases, hiding, ordering and a status-line pin.
-- Launch arguments `login [claude|gpt]` start a login.

local login = require("./lib/login")
local poller = require("./lib/poller")
local view = require("./lib/view")

type State = view.BlockState

local function close_flow(st: State)
	if st.flow then
		login.cancel(st.flow)
		st.flow = nil
	end
end

local function show_provider(st: State, provider: string)
	if provider ~= poller.state.settings.provider then
		st.sel, st.confirm, st.edit = 1, nil, nil
		poller.set_provider(provider)
	end
end

local function next_provider(st: State)
	local list = poller.PROVIDERS
	local idx = table.find(list, poller.state.settings.provider) or 0
	show_provider(st, list[idx % #list + 1])
end

-- Logs in one more account of `provider` (default: the shown tab).
local function start_login(st: State, provider: string?)
	close_flow(st)
	local p = provider or poller.state.settings.provider
	show_provider(st, p)
	local cx = st.cx
	st.flow = login.start(cx, p, function()
		cx:render()
	end, function(id)
		st.flow = nil
		-- The new account appears after the tick reloads the sources; the view selects it then.
		st.want = id
		cx:toast("success", (login.NAME[p] or p) .. " account signed in", "Fetching usage")
		poller.tick(true)
		cx:render()
	end)
end

local function selected(st: State): poller.Entry?
	return view.visible()[st.sel]
end

local function cycle_interval(delta: number)
	local list = poller.INTERVALS
	local cur = poller.state.settings.interval
	local idx = 1
	for i, v in list do
		if v <= cur then
			idx = i
		end
	end
	idx = math.clamp(idx + delta, 1, #list)
	poller.set_setting("interval", list[idx])
	poller.tick(false)
end

-- Settings whose change needs the sources re-read or the schedule re-armed.
local RELOAD = { claude_code = true, codex = true, omp = true, status_line = true, interval = true }

local function toggle(key: string)
	poller.set_setting(key, not (poller.state.settings :: any)[key])
	if RELOAD[key] then
		poller.tick(false)
	end
end

local function set_choice(key: string, value: string)
	if key == "interval" then
		local n = tonumber(value)
		if n and table.find(poller.INTERVALS, n) then
			poller.set_setting("interval", n)
			poller.tick(false)
		end
		return
	end
	local allowed = (poller.CHOICES :: any)[key]
	if allowed and table.find(allowed, value) then
		if key == "provider" then
			poller.set_provider(value)
		else
			poller.set_setting(key, value)
		end
	end
end

local function cycle_layout()
	local list = poller.CHOICES.layout
	local idx = table.find(list, poller.state.settings.layout) or 0
	poller.set_setting("layout", list[idx % #list + 1])
end

local function select_id(st: State, id: string)
	for i, e in view.visible() do
		if e.account.id == id then
			st.sel = i
		end
	end
end

local function start_rename(st: State, e: poller.Entry)
	st.edit = { id = e.account.id, text = poller.pref(e).alias or "" }
end

local function finish_rename(st: State, save: boolean)
	local edit = st.edit
	st.edit = nil
	if save and edit then
		local e = view.entry(edit.id)
		if e then
			poller.set_alias(e, edit.text)
		end
	end
end

local function toggle_hidden(st: State, e: poller.Entry)
	local hide = not poller.pref(e).hidden
	poller.set_hidden(e, hide)
	if hide then
		st.cx:toast("info", "Hidden " .. poller.label(e), "Press a to list hidden accounts, then h to restore one")
	else
		poller.tick(false)
	end
	st.sel = math.max(math.min(st.sel, #view.visible()), 1)
end

local function move(st: State, e: poller.Entry, delta: number)
	if poller.move(e, delta) then
		select_id(st, e.account.id)
	end
end

local function ask_remove(st: State, e: poller.Entry?)
	if e and e.account.kind == "own" then
		st.confirm = e.account.id
	elseif e then
		st.cx:toast("info", "Only accounts signed in through this plugin can be removed", "Sign out of Claude Code / Codex / omp in their own tools, or use h to hide or c / o to turn off the source")
	end
end

-- Typing into a text field: the login paste box or the rename box.
local function text_key(key: Key, input: string, submit: (string) -> (), cancel: () -> ()): (boolean, string)
	if key.name == "escape" then
		cancel()
	elseif key.name == "paste" then
		input = string.gsub(key.text or "", "[\r\n]+", "")
		submit(input)
	elseif key.name == "enter" then
		submit(input)
	elseif key.name == "backspace" then
		input = string.sub(input, 1, (utf8.offset(input, -1) or 1) - 1)
	elseif key.text and #key.text > 0 and not key.ctrl and not key.meta then
		input ..= key.text
	else
		return false, input
	end
	return true, input
end

local function login_key(st: State, key: Key): boolean
	local flow = st.flow
	-- A pasted code is whitespace-free; spaces in it come from line wraps.
	if key.name == "paste" then
		key = { name = "paste", text = string.gsub(key.text or "", "%s+", ""), ctrl = false, alt = false, shift = false, meta = false }
	end
	local handled, input = text_key(key, flow.input, function(text)
		flow.input = text
		login.submit_text(flow, text)
	end, function()
		close_flow(st)
	end)
	if st.flow then
		flow.input = input
	end
	return handled
end

local function edit_key(st: State, key: Key): boolean
	local edit = st.edit :: { id: string, text: string }
	if key.name == "paste" then
		edit.text ..= string.gsub(key.text or "", "[\r\n]+", " ")
		return true
	end
	local handled, input = text_key(key, edit.text, function(text)
		edit.text = text
		finish_rename(st, true)
	end, function()
		finish_rename(st, false)
	end)
	if st.edit then
		edit.text = input
	end
	return handled
end

local function is_key(key: Key, lower: string): boolean
	return key.name == string.upper(lower) or (key.name == lower and key.shift)
end

local usage_block: BlockDef<State> = {
	init = function(cx, args, _saved)
		local st: State = { cx = cx, sel = 1, flow = nil, help = false, settings = false, confirm = nil, want = nil, edit = nil }
		poller.subscribe(cx)
		if args[1] == "login" then
			start_login(st, if args[2] == "gpt" then "gpt" else "claude")
		end
		return st
	end,

	title = view.title,

	view = view.render,

	key = function(st, key, _cx)
		if st.flow and st.flow.phase ~= "starting" and st.flow.phase ~= "exchanging" then
			return login_key(st, key)
		end
		if st.flow and key.name == "escape" then
			close_flow(st)
			return true
		end
		if st.edit then
			return edit_key(st, key)
		end
		local n = #view.visible()
		local name = key.name
		local e = selected(st)
		if is_key(key, "j") then
			if e then
				move(st, e, 1)
			end
		elseif is_key(key, "k") then
			if e then
				move(st, e, -1)
			end
		elseif name == "r" then
			poller.tick(true)
		elseif name == "tab" then
			next_provider(st)
		elseif name == "1" or name == "2" then
			show_provider(st, poller.PROVIDERS[tonumber(name) :: number])
		elseif name == "l" then
			start_login(st)
		elseif name == "j" or name == "down" then
			st.sel = math.min(st.sel + 1, math.max(n, 1))
		elseif name == "k" or name == "up" then
			st.sel = math.max(st.sel - 1, 1)
		elseif name == "e" then
			if e then
				start_rename(st, e)
			end
		elseif name == "p" then
			if e then
				poller.set_pinned(e, not poller.pref(e).pinned)
			end
		elseif name == "h" then
			if e then
				toggle_hidden(st, e)
			end
		elseif name == "a" then
			toggle("show_hidden")
		elseif name == "v" then
			cycle_layout()
		elseif name == "x" or name == "delete" or name == "backspace" then
			ask_remove(st, e)
		elseif name == "enter" and st.confirm then
			poller.remove_own(st.confirm :: string)
			st.confirm = nil
			st.sel = math.max(math.min(st.sel, #view.visible()), 1)
		elseif name == "escape" and (st.confirm or st.settings or st.help) then
			st.confirm = nil
			st.settings, st.help = false, false
		elseif name == "+" or name == "=" then
			cycle_interval(1)
		elseif name == "-" then
			cycle_interval(-1)
		elseif name == "c" then
			toggle(if poller.state.settings.provider == "gpt" then "codex" else "claude_code")
		elseif name == "o" then
			toggle("omp")
		elseif name == "s" then
			toggle("status_line")
		elseif name == "," then
			st.settings = not st.settings
		elseif name == "?" or (name == "/" and key.shift) then
			st.help = not st.help
		else
			return false
		end
		return true
	end,

	event = function(st, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		local target = if type(value) == "string" then view.entry(value) else nil
		if act == "refresh" then
			poller.tick(true)
		elseif act == "login" then
			start_login(st)
		elseif act == "cancel" then
			close_flow(st)
		elseif act == "open_url" and st.flow and st.flow.url then
			cx:open(st.flow.url)
		elseif act == "copy_url" and st.flow and st.flow.url then
			cx:copy(st.flow.url)
			cx:toast("info", "Authorization link copied")
		elseif act == "select" and value then
			select_id(st, value)
		elseif act == "rename" and target then
			start_rename(st, target)
		elseif act == "save_edit" then
			finish_rename(st, true)
		elseif act == "cancel_edit" then
			finish_rename(st, false)
		elseif act == "pin" and target then
			poller.set_pinned(target, not poller.pref(target).pinned)
		elseif act == "hide" and target then
			toggle_hidden(st, target)
		elseif (act == "up" or act == "down") and target then
			move(st, target, if act == "up" then -1 else 1)
		elseif act == "ask_remove" and target then
			ask_remove(st, target)
		elseif act == "remove" and value then
			poller.remove_own(value)
			st.confirm = nil
			st.sel = math.max(math.min(st.sel, #view.visible()), 1)
		elseif act == "keep" then
			st.confirm = nil
		elseif act == "help" then
			st.help = not st.help
		elseif act == "settings" then
			st.settings = not st.settings
		elseif act == "tab" and value then
			show_provider(st, value)
		elseif act == "toggle" and value and type((poller.state.settings :: any)[value]) == "boolean" then
			toggle(value)
		elseif act == "set" and value then
			local k, v = string.match(value, "^([%w_]+):(.+)$")
			if k and v then
				set_choice(k, v)
			end
		end
	end,
}

tern.block.define("usage", usage_block)

poller.start()
