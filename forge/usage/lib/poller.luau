--!strict
-- One poller per host VM, shared by every open usage block and the status line.
--
-- Each tick re-reads the credential sources (so Claude Code's and Codex's own refreshes and new
-- logins show up), then fetches each account's usage (Claude `/api/oauth/usage`, ChatGPT
-- `wham/usage`), one after another. It ticks every `settings.interval` seconds while a usage block
-- is open and every `settings.background` seconds otherwise. A 429 backs that account off
-- (Retry-After, else doubling from one minute) and keeps showing the last good data.
--
-- Per-account preferences (kv "prefs", keyed by account identity): an alias, hidden (not shown,
-- not polled, not on the status line), pinned (the status line's account) and a manual order.

local codex = require("./codex")
local creds = require("./creds")
local oauth = require("./oauth")
local stats = require("./stats")
local usage = require("./usage")

local M = {}

export type Sample = { t: number, s: number?, w: number? }

export type Entry = {
	account: creds.Account,
	-- Claude Code's raw credential document, for write-back after a refresh.
	doc: any,
	profile: oauth.Profile?,
	raw: any,
	usage: usage.Usage?,
	-- Epoch seconds the usage data was produced.
	fetched_at: number?,
	-- "api" | "claude-code-cache" | "disk"
	data_source: string?,
	busy: string?,
	error: string?,
	backoff_until: number?,
	backoff_step: number,
	history: { Sample },
	-- Set when another source already shows the same account and organization.
	duplicate_of: string?,
	profile_tried: boolean?,
}

export type Settings = {
	interval: number,
	background: number,
	claude_code: boolean,
	codex: boolean,
	omp: boolean,
	status_line: boolean,
	-- The tab blocks open on and the status line shows: "claude" | "gpt".
	provider: string,
	-- Account list: "auto" (cards up to two accounts, else compact rows) | "cards" | "compact".
	layout: string,
	-- "manual" | "usage" (busiest first) | "reset" (soonest reset first) | "name".
	sort: string,
	-- Status line: "one" (pinned, else first) | "best" (most headroom) | "all".
	status_mode: string,
	-- Status line providers: "tab" (the shown one) | "both".
	status_scope: string,
	-- Card details: pace text, sparklines, per-model and other windows.
	show_pace: boolean,
	show_history: boolean,
	show_scoped: boolean,
	-- Whether hidden accounts are listed (dimmed) so they can be shown again.
	show_hidden: boolean,
}

export type Pref = { alias: string?, hidden: boolean?, pinned: boolean?, order: number? }

local DEFAULTS: Settings = {
	interval = 60,
	background = 300,
	claude_code = true,
	codex = true,
	omp = true,
	status_line = true,
	provider = "claude",
	layout = "auto",
	sort = "manual",
	status_mode = "one",
	status_scope = "tab",
	show_pace = true,
	show_history = true,
	show_scoped = true,
	show_hidden = false,
}
M.PROVIDERS = { "claude", "gpt" }
M.PROVIDER_NAME = { claude = "Claude", gpt = "GPT" }
M.INTERVALS = { 30, 60, 120, 300, 600 }
-- Allowed values of the enumerated settings.
M.CHOICES = {
	provider = M.PROVIDERS,
	layout = { "auto", "cards", "compact" },
	sort = { "manual", "usage", "reset", "name" },
	status_mode = { "one", "best", "all" },
	status_scope = { "tab", "both" },
}
local HISTORY = 48

local state = {
	entries = {} :: { Entry },
	settings = table.clone(DEFAULTS) :: Settings,
	listeners = {} :: { [number]: BlockCx },
	timer = nil :: TimerHandle?,
	next_at = nil :: number?,
	ticking = false,
	started = false,
	last_tick = nil :: number?,
	prefs = {} :: { [string]: Pref },
	-- Bumped on every status publish so the window notices changes within a second.
	rev = 0,
}
M.state = state

-- ── persistence ─────────────────────────────────────────────────────────────

local function cache_path(): string
	return tern.plugin.data .. "/cache.json"
end

local function load_settings()
	local ok, s = pcall(tern.kv.get, "settings")
	if ok and type(s) == "table" then
		for k, v in s do
			local allowed = (M.CHOICES :: any)[k]
			if (DEFAULTS :: any)[k] ~= nil and type(v) == type((DEFAULTS :: any)[k]) and (allowed == nil or table.find(allowed, v)) then
				(state.settings :: any)[k] = v
			end
		end
	end
end

local function load_prefs()
	local ok, p = pcall(tern.kv.get, "prefs")
	if ok and type(p) == "table" then
		for k, v in p do
			if type(k) == "string" and type(v) == "table" then
				state.prefs[k] = v
			end
		end
	end
end

local function save_prefs()
	pcall(tern.kv.set, "prefs", state.prefs)
end

local function save_cache()
	local out: { [string]: any } = {}
	for _, e in state.entries do
		if e.raw ~= nil or e.profile ~= nil then
			out[e.account.id] = {
				raw = e.raw,
				fetched_at = e.fetched_at,
				data_source = e.data_source,
				profile = e.profile,
				history = tern.json.array(e.history),
			}
		end
	end
	pcall(tern.fs.write, cache_path(), tern.json.encode(out))
end

local disk_cache: { [string]: any } = {}
local function load_cache()
	if not tern.fs.exists(cache_path()) then
		return
	end
	local ok, text = pcall(tern.fs.read, cache_path())
	if ok then
		local ok2, doc = pcall(tern.json.decode, text)
		if ok2 and type(doc) == "table" then
			disk_cache = doc
		end
	end
end

-- Compact status for the window half's status line, in kv "status": every shown account's 5 h /
-- 7 d windows in panel order (hidden accounts left out), and how the line picks among them.
local function publish()
	local accounts = {}
	for _, p in M.PROVIDERS do
		for _, e in M.ordered(p, false) do
			if not e.account.problem then
				table.insert(accounts, M.row(e))
			end
		end
	end
	state.rev += 1
	pcall(tern.kv.set, "status", {
		updated = os.time(),
		rev = state.rev,
		accounts = tern.json.array(accounts),
		enabled = state.settings.status_line,
		provider = state.settings.provider,
		mode = state.settings.status_mode,
		scope = state.settings.status_scope,
	})
end

-- Persists a setting; the status line and open blocks follow at once.
function M.set_setting(key: string, value: any)
	(state.settings :: any)[key] = value
	pcall(tern.kv.set, "settings", state.settings)
	publish()
	M.notify()
end

-- ── listeners ───────────────────────────────────────────────────────────────

local function live_panes(): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		live[p.pane] = true
	end
	return live
end

local function has_listeners(): boolean
	local live = live_panes()
	local any = false
	for pane in state.listeners do
		if live[pane] then
			any = true
		else
			state.listeners[pane] = nil
		end
	end
	return any
end

function M.notify()
	local live = live_panes()
	for pane, cx in state.listeners do
		if live[pane] then
			cx:render()
		else
			state.listeners[pane] = nil
		end
	end
end

-- ── labels ──────────────────────────────────────────────────────────────────

-- The account's own name: its email, else what the source calls it.
function M.account_name(e: Entry): string
	local p = e.profile
	local t = e.account.tokens
	local fallback = if e.account.kind == "claude-code" then "Claude Code account" elseif e.account.kind == "codex" then "Codex account" else e.account.id
	return (p and p.email) or (t and t.email) or fallback
end

-- The alias the user gave the account, else its own name.
function M.label(e: Entry): string
	return M.pref(e).alias or M.account_name(e)
end

-- For tight spots (status line, compact rows): the alias, else the email's local part.
function M.short_name(e: Entry): string
	local alias = M.pref(e).alias
	if alias then
		return alias
	end
	local name = M.account_name(e)
	return string.match(name, "^([^@]+)@") or name
end

-- Claude: the live profile wins over tier hints a credential store saved at login time.
-- ChatGPT: the plan the last usage payload reported, else the token's plan claim.
function M.plan(e: Entry): string?
	if e.account.provider == "gpt" then
		local u = e.usage
		return (u and u.plan) or usage.codex_plan(e.account.subscription)
	end
	local p = e.profile
	return usage.plan((p and p.tier) or e.account.tier, e.account.subscription, p and p.org_type)
end

-- The account's compact row: what the status line and the cross-account summary read.
function M.row(e: Entry): stats.Row
	local row: stats.Row = {
		id = e.account.id,
		provider = e.account.provider,
		label = M.label(e),
		name = M.short_name(e),
		plan = M.plan(e),
		error = e.error,
		pinned = if M.pref(e).pinned then true else nil,
	}
	if e.usage then
		for _, w in (e.usage :: usage.Usage).windows do
			if w.id == "5h" then
				row.session = { pct = w.pct, resets_at = w.resets_at }
			elseif w.id == "7d" then
				row.weekly = { pct = w.pct, resets_at = w.resets_at }
			end
		end
		row.fetched_at = e.fetched_at
	end
	return row
end

local function identity(e: Entry): string?
	local p, t = e.profile, e.account.tokens
	local acc = (p and p.account_uuid) or (t and t.account_uuid)
	if not acc then
		return nil
	end
	return e.account.provider .. "|" .. acc .. "|" .. ((p and p.org_uuid) or (t and t.org_uuid) or "")
end

local function mark_duplicates()
	local seen: { [string]: string } = {}
	for _, e in state.entries do
		e.duplicate_of = nil
		local id = identity(e)
		if id then
			if seen[id] then
				e.duplicate_of = seen[id]
			else
				seen[id] = e.account.id
			end
		end
	end
end

-- ── preferences ─────────────────────────────────────────────────────────────

local NO_PREF: Pref = table.freeze({} :: Pref)

-- Preferences follow the account (provider, user, organization), so they survive a source
-- switching logins and apply to whichever source shows it; before the identity is known they
-- sit under the source's account id.
function M.pref(e: Entry): Pref
	local id = identity(e)
	return (if id then state.prefs[id] else nil) or state.prefs[e.account.id] or NO_PREF
end

local function pref_slot(e: Entry): Pref
	local key = identity(e) or e.account.id
	local p: Pref? = state.prefs[key]
	if p == nil then
		local moved: Pref = state.prefs[e.account.id] or {} :: Pref
		state.prefs[e.account.id] = nil
		state.prefs[key] = moved
		return moved
	end
	return p :: Pref
end

local function prefs_changed()
	for k, p in state.prefs do
		if next(p :: any) == nil then
			state.prefs[k] = nil
		end
	end
	save_prefs()
	publish()
	M.notify()
end

function M.set_alias(e: Entry, alias: string?)
	local text = alias and string.match(alias, "^%s*(.-)%s*$")
	pref_slot(e).alias = if text and text ~= "" then text else nil
	prefs_changed()
end

function M.set_hidden(e: Entry, hidden: boolean)
	pref_slot(e).hidden = if hidden then true else nil
	prefs_changed()
end

-- Pins `e` as its provider's status-line account (one per provider), or unpins it.
function M.set_pinned(e: Entry, pinned: boolean)
	for _, o in state.entries do
		if o.account.provider == e.account.provider and M.pref(o).pinned then
			pref_slot(o).pinned = nil
		end
	end
	if pinned then
		pref_slot(e).pinned = true
	end
	prefs_changed()
end

local function first_reset(e: Entry): number?
	local u = e.usage
	if u then
		for _, w in (u :: usage.Usage).windows do
			if (w.id == "5h" or w.id == "7d") and w.resets_at then
				return w.resets_at
			end
		end
	end
	return nil
end

-- One provider's accounts in panel order (`settings.sort`), one per real account; hidden ones
-- only with `with_hidden`.
function M.ordered(provider: string, with_hidden: boolean?): { Entry }
	local list: { Entry } = {}
	local base: { [Entry]: number } = {}
	for i, e in state.entries do
		if not e.duplicate_of and e.account.provider == provider and (with_hidden or not M.pref(e).hidden) then
			table.insert(list, e)
			base[e] = i
		end
	end
	local mode = state.settings.sort
	local key: { [Entry]: any } = {}
	for _, e in list do
		if mode == "usage" then
			key[e] = -(stats.load(M.row(e)) or -1)
		elseif mode == "reset" then
			key[e] = first_reset(e) or math.huge
		elseif mode == "name" then
			key[e] = string.lower(M.label(e))
		else
			key[e] = M.pref(e).order or math.huge
		end
	end
	table.sort(list, function(x, y)
		if key[x] ~= key[y] then
			return key[x] < key[y]
		end
		return base[x] < base[y]
	end)
	return list
end

-- Moves `e` by `delta` places in its provider's list, switching to manual order. False at an end.
function M.move(e: Entry, delta: number): boolean
	local list = M.ordered(e.account.provider, state.settings.show_hidden)
	local i = table.find(list, e)
	local j = if i then i + delta else 0
	if i == nil or j < 1 or j > #list then
		return false
	end
	list[i], list[j] = list[j], list[i]
	for n, o in list do
		pref_slot(o).order = n
	end
	if state.settings.sort ~= "manual" then
		(state.settings :: any).sort = "manual"
		pcall(tern.kv.set, "settings", state.settings)
	end
	prefs_changed()
	return true
end

-- ── data ────────────────────────────────────────────────────────────────────

local function parse_raw(account: creds.Account, raw: any, fetched_at: number): usage.Usage?
	if account.provider == "gpt" then
		return usage.parse_codex(raw, fetched_at)
	end
	return usage.parse(raw)
end

local function record(e: Entry, raw: any, fetched_at: number, source: string)
	local parsed = parse_raw(e.account, raw, fetched_at)
	if not parsed then
		e.error = "Usage response format not recognized"
		return
	end
	e.raw, e.usage, e.fetched_at, e.data_source = raw, parsed, fetched_at, source
	local sample: Sample = { t = fetched_at }
	for _, w in (parsed :: usage.Usage).windows do
		if w.id == "5h" then
			sample.s = w.pct
		elseif w.id == "7d" then
			sample.w = w.pct
		end
	end
	local last = e.history[#e.history]
	if last == nil or fetched_at - last.t >= 1 then
		table.insert(e.history, sample)
		while #e.history > HISTORY do
			table.remove(e.history, 1)
		end
	end
end

local function new_entry(account: creds.Account): Entry
	local e: Entry = { account = account, backoff_step = 0, history = {} }
	local c = disk_cache[account.id]
	if type(c) == "table" then
		e.profile = c.profile
		if type(c.history) == "table" then
			for _, s in c.history do
				if type(s) == "table" and type(s.t) == "number" then
					table.insert(e.history, s)
				end
			end
		end
		if c.raw ~= nil and type(c.fetched_at) == "number" then
			e.raw, e.usage, e.fetched_at, e.data_source = c.raw, parse_raw(account, c.raw, c.fetched_at), c.fetched_at, "disk"
		end
	end
	return e
end

local ORDER = { own = 1, ["claude-code"] = 2, codex = 2, omp = 3 }
local PROVIDER_ORDER = { claude = 1, gpt = 2 }

-- Re-reads every source and merges the accounts into `state.entries`, keeping per-entry state.
function M.reload_accounts(done: () -> ())
	local found: { creds.Account } = creds.own_list()
	local docs: { [string]: any } = {}
	local pending = 3
	local function finish()
		pending -= 1
		if pending > 0 then
			return
		end
		local by_id: { [string]: Entry } = {}
		for _, e in state.entries do
			by_id[e.account.id] = e
		end
		local next_entries: { Entry } = {}
		for _, a in found do
			local e = by_id[a.id] or new_entry(a)
			e.account = a
			if docs[a.id] ~= nil then
				e.doc = docs[a.id]
			end
			table.insert(next_entries, e)
		end
		table.sort(next_entries, function(x, y)
			local px, py = PROVIDER_ORDER[x.account.provider] or 9, PROVIDER_ORDER[y.account.provider] or 9
			if px ~= py then
				return px < py
			end
			local ox, oy = ORDER[x.account.kind] or 9, ORDER[y.account.kind] or 9
			if ox ~= oy then
				return ox < oy
			end
			return x.account.id < y.account.id
		end)
		state.entries = next_entries
		mark_duplicates()
		done()
	end
	if state.settings.claude_code then
		creds.claude_code_load(function(acc, doc)
			if acc then
				table.insert(found, acc)
				docs[acc.id] = doc
			end
			finish()
		end)
	else
		finish()
	end
	if state.settings.codex then
		creds.codex_load(function(acc, doc)
			if acc then
				table.insert(found, acc)
				docs[acc.id] = doc
			end
			finish()
		end)
	else
		finish()
	end
	if state.settings.omp then
		creds.omp_load(function(list)
			for _, a in list do
				table.insert(found, a)
			end
			finish()
		end)
	else
		finish()
	end
end

local function now_ms(): number
	return os.time() * 1000
end

-- Where a CLI's login is re-read before a refresh and written back after it; `refresh` is the
-- provider's token endpoint.
local CLI = {
	["claude-code"] = { load = creds.claude_code_load, save = creds.claude_code_save, refresh = oauth.refresh, name = "Claude Code" },
	codex = { load = creds.codex_load, save = creds.codex_save, refresh = codex.refresh, name = "Codex" },
}

-- Calls `cb(access)` with a usable access token, refreshing it when it's expired (or `force`).
local function ensure_token(e: Entry, force: boolean, cb: (string?, string?) -> ())
	local t = e.account.tokens
	if not t then
		cb(nil, "No token")
		return
	end
	local tokens = t :: oauth.Tokens
	local fresh = tokens.expires == nil or tokens.expires - now_ms() > 60000
	if fresh and not force then
		cb(tokens.access)
		return
	end
	local kind = e.account.kind
	if kind == "omp" then
		cb(nil, "The omp login has expired: sign in again in omp, or press l here to sign in")
		return
	end
	local cli = CLI[kind]
	local refresh = if cli then cli.refresh elseif e.account.provider == "gpt" then codex.refresh else oauth.refresh
	e.busy = "refresh"
	M.notify()
	local function do_refresh(current: oauth.Tokens)
		refresh(current, function(new, err, invalid)
			e.busy = nil
			if not new then
				cb(nil, (if invalid then "Login is no longer valid; sign in again" else "Token refresh failed") .. " (" .. tostring(err) .. ")")
				return
			end
			local fresh_tokens = new :: oauth.Tokens
			e.account.tokens = fresh_tokens
			if not cli then
				creds.own_update(e.account.id, fresh_tokens)
				cb(fresh_tokens.access)
				return
			end
			cli.save(e.account, e.doc, fresh_tokens, function(werr)
				if werr then
					tern.log.warn("forge usage: " .. cli.name .. " write-back failed", werr)
					e.error = werr
				end
				cb(fresh_tokens.access)
			end)
		end)
	end
	if cli then
		-- The CLI may have refreshed on its own since the last read; use that if so.
		cli.load(function(acc, doc)
			if acc and acc.tokens then
				local latest = acc.tokens :: oauth.Tokens
				e.account.tokens, e.doc = latest, doc
				if latest.access ~= tokens.access and (latest.expires == nil or latest.expires - now_ms() > 60000) then
					e.busy = nil
					cb(latest.access)
					return
				end
				do_refresh(latest)
			else
				e.busy = nil
				cb(nil, "Failed to read " .. cli.name .. " login")
			end
		end)
	else
		do_refresh(tokens)
	end
end

local function fetch_profile(e: Entry, access: string, done: () -> ())
	if e.profile_tried or (e.profile and e.profile.tier) then
		done()
		return
	end
	e.profile_tried = true
	oauth.get("/profile", access, function(r, body)
		local p = oauth.profile_from(body)
		if p then
			e.profile = p
			mark_duplicates()
		elseif r.status ~= 200 then
			tern.log.warn("forge usage: profile failed", oauth.describe(r))
		end
		done()
	end)
end

-- ChatGPT has no profile call; the usage payload names the user, the account and the email.
local function codex_profile(e: Entry, body: any)
	if type(body) ~= "table" then
		return
	end
	local t = e.account.tokens
	e.profile = {
		email = (if type(body.email) == "string" then body.email else nil) or (t and t.email),
		account_uuid = (if type(body.user_id) == "string" then body.user_id else nil) or (t and t.account_uuid),
		org_uuid = (if type(body.account_id) == "string" then body.account_id else nil) or (t and t.org_uuid),
	}
	mark_duplicates()
end

-- GET the entry's usage from its provider; `cb(result, body)`.
local function get_usage(e: Entry, access: string, cb: (FetchResult, any) -> ())
	if e.account.provider == "gpt" then
		local t = e.account.tokens
		codex.usage(access, t and t.org_uuid, cb)
	else
		oauth.get("/usage", access, cb)
	end
end

-- Claude Code's own cached usage, when it is newer than ours and belongs to this login.
local function adopt_claude_cache(e: Entry): boolean
	if e.account.kind ~= "claude-code" then
		return false
	end
	local ok, c = pcall(creds.claude_code_cache)
	if not ok or type(c) ~= "table" then
		return false
	end
	local account = c.account
	if type(account) == "table" and e.profile == nil then
		e.profile = {
			email = account.emailAddress,
			name = account.displayName,
			account_uuid = account.accountUuid,
			org_uuid = account.organizationUuid,
			org_name = account.organizationName,
			tier = account.organizationRateLimitTier,
			org_type = account.organizationType,
			billing = account.billingType,
		}
		mark_duplicates()
	end
	if c.usage == nil or type(c.fetched_at) ~= "number" then
		return false
	end
	local who = e.profile and e.profile.account_uuid
	if who and c.account_uuid and c.account_uuid ~= who then
		return false
	end
	if e.fetched_at and c.fetched_at <= (e.fetched_at :: number) then
		return false
	end
	record(e, c.usage, c.fetched_at, "claude-code-cache")
	-- Fresh enough to skip our own request this tick.
	return os.time() - c.fetched_at < state.settings.interval
end

local function backoff(e: Entry, seconds: number?)
	e.backoff_step = math.min(e.backoff_step + 1, 5)
	local wait = seconds or math.min(60 * 2 ^ (e.backoff_step - 1), 900)
	e.backoff_until = os.time() + wait
end

-- Fetches one entry's usage. `force` ignores its backoff.
local function poll_entry(e: Entry, force: boolean, done: () -> ())
	if e.duplicate_of or e.account.problem or e.busy or M.pref(e).hidden then
		done()
		return
	end
	if not force and e.backoff_until and os.time() < (e.backoff_until :: number) then
		done()
		return
	end
	if adopt_claude_cache(e) then
		e.error = nil
		done()
		return
	end
	local retried = false
	local function run(force_refresh: boolean)
		ensure_token(e, force_refresh, function(access, err)
			if not access then
				e.error = err
				e.busy = nil
				backoff(e, 300)
				done()
				return
			end
			e.busy = "fetch"
			M.notify()
			get_usage(e, access :: string, function(r, body)
				e.busy = nil
				if r.status == 200 and body ~= nil then
					e.error, e.backoff_until, e.backoff_step = nil, nil, 0
					record(e, body, os.time(), "api")
					if e.account.provider == "gpt" then
						codex_profile(e, body)
						done()
					else
						fetch_profile(e, access :: string, done)
					end
					return
				end
				if r.status == 401 and not retried and e.account.kind ~= "omp" then
					retried = true
					run(true)
					return
				end
				if r.status == 429 then
					backoff(e, oauth.retry_after(r.headers))
					e.error = "Too many requests (429), paused until " .. os.date("%H:%M:%S", e.backoff_until :: number)
				elseif r.status == 401 then
					backoff(e, 300)
					e.error = "Token invalid (401): " .. oauth.describe(r)
				else
					backoff(e, nil)
					e.error = oauth.describe(r)
				end
				done()
			end)
		end)
	end
	run(false)
end

-- ── scheduling ──────────────────────────────────────────────────────────────

-- Arms the next tick: `interval` while a block is open, `background` while only the status line
-- needs data, none when neither does (the next block to open polls).
local function schedule()
	if state.timer then
		(state.timer :: TimerHandle):cancel()
		state.timer = nil
	end
	local open = has_listeners()
	if not open and not state.settings.status_line then
		state.next_at = nil
		return
	end
	local wait = if open then state.settings.interval else state.settings.background
	state.next_at = os.time() + wait
	state.timer = tern.timer(wait * 1000, function()
		state.timer = nil
		M.tick(false)
	end)
end

-- Reloads the accounts and polls each in turn; `force` ignores backoffs.
function M.tick(force: boolean)
	if state.ticking then
		return
	end
	state.ticking = true
	M.notify()
	M.reload_accounts(function()
		local i = 0
		local function step()
			i += 1
			local e = state.entries[i]
			if not e then
				state.ticking = false
				state.last_tick = os.time()
				save_cache()
				publish()
				schedule()
				M.notify()
				return
			end
			poll_entry(e, force, function()
				M.notify()
				step()
			end)
		end
		step()
	end)
end

function M.subscribe(cx: BlockCx)
	state.listeners[cx.pane] = cx
	-- A block opening switches to the faster interval; poll now when the data is stale.
	if not state.ticking then
		local stale = state.last_tick == nil or os.time() - (state.last_tick :: number) >= state.settings.interval
		if stale then
			M.tick(false)
		else
			schedule()
		end
	end
end

function M.start()
	if state.started then
		return
	end
	state.started = true
	load_settings()
	load_prefs()
	load_cache()
	M.tick(false)
end

function M.remove_own(id: string)
	creds.own_remove(id)
	for i, e in state.entries do
		if e.account.id == id then
			table.remove(state.entries, i)
			break
		end
	end
	mark_duplicates()
	save_cache()
	publish()
	M.notify()
end

-- Switches the shown provider for every open block and the status line, and keeps it as the
-- default for blocks opened later.
function M.set_provider(provider: string)
	if not M.PROVIDER_NAME[provider] or state.settings.provider == provider then
		return
	end
	M.set_setting("provider", provider)
end

return M
