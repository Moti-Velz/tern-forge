--!strict
-- Email over IMAP with an app password: Gmail, Fastmail, iCloud, Outlook or any IMAP server. The work
-- happens in email_imap.py (Python standard library), which opens the mailbox read-only and fetches
-- with BODY.PEEK, so nothing is marked as read. Each list item is a thread (Gmail's thread id, else
-- the subject); its details are every message, oldest first, with quoted history removed.
--
-- The credential is "address[ server]\napp password". The server is guessed from the address's
-- domain, or given as `host[:port]` (TLS) or `imap://host:port` (plain, for local servers and tests).

local source = require("./source")

local NAME = "Email"

local HOSTS: { [string]: string } = {
	["gmail.com"] = "imap.gmail.com", ["googlemail.com"] = "imap.gmail.com",
	["fastmail.com"] = "imap.fastmail.com", ["fastmail.fm"] = "imap.fastmail.com",
	["icloud.com"] = "imap.mail.me.com", ["me.com"] = "imap.mail.me.com", ["mac.com"] = "imap.mail.me.com",
	["outlook.com"] = "outlook.office365.com", ["hotmail.com"] = "outlook.office365.com",
	["live.com"] = "outlook.office365.com", ["yahoo.com"] = "imap.mail.yahoo.com",
}

type Account = { user: string, password: string, host: string, port: number, tls: boolean }

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function account(cred: string): (Account?, string?)
	local first, password = string.match(cred, "^([^\n]*)\n(.*)$")
	if not first then
		return nil, "Email credential is incomplete. Connect Email again."
	end
	local user, server = string.match(trim(first :: string), "^(%S+)%s*(%S*)$")
	if not user or not string.find(user, "@") then
		return nil, "Enter an email address, such as you@gmail.com."
	end
	local domain = string.lower(string.match(user, "@(.+)$") or "")
	if server == "" then
		-- Google Workspace and other custom domains: imap.<domain> is a guess; give the server explicitly.
		server = HOSTS[domain] or ("imap." .. domain)
	end
	local tls = true
	local plain = string.match(server :: string, "^imap://(.+)$")
	if plain then
		tls, server = false, plain
	end
	server = string.gsub(server :: string, "^imaps://", "")
	local host, port = string.match(server :: string, "^([^:]+):(%d+)$")
	host = host or server
	local pw = trim(password :: string)
	-- Google shows app passwords in groups of four with spaces; they work without them.
	if host == "imap.gmail.com" then
		pw = string.gsub(pw, "%s+", "")
	end
	return { user = user, password = pw, host = host :: string, port = tonumber(port) or (if tls then 993 else 143), tls = tls }, nil
end

local HELPER = tern.plugin.dir .. "/lib/sources/email_imap.py"

-- The stored credential holds every account: a JSON array of "address[ server]\npassword" strings.
-- A bare "address\npassword" (one account, before there could be several) still reads.
local function accounts(cred: string): { string }
	if string.sub(cred, 1, 1) == "[" then
		local ok, list = pcall(tern.json.decode, cred)
		if ok and type(list) == "table" then
			local out = {}
			for _, a in list do
				if type(a) == "string" then
					table.insert(out, a)
				end
			end
			return out
		end
	end
	return { cred }
end

local function address(acct: string): string
	return string.lower(string.match(acct, "^%s*(%S+)") or "")
end

-- Adds the account in `new`, replacing one with the same address.
local function merge(existing: string?, new: string): string
	local out = {}
	for _, a in (if existing then accounts(existing) else {}) do
		if address(a) ~= address(new) then
			table.insert(out, a)
		end
	end
	table.insert(out, new)
	return tern.json.encode(tern.json.array(out))
end

local function call(cred: string, req: { [string]: any }, done: (res: any?, err: string?, cx: WindowCx) -> ())
	local acct, aerr = account(cred)
	if acct == nil then
		tern.timer(0, function(cx)
			done(nil, aerr, cx :: WindowCx)
		end)
		return
	end
	for k, v in acct :: any do
		req[k] = v
	end
	local ok, err = pcall(tern.process.run, { "python3", HELPER }, { stdin = tern.json.encode(req), timeout_ms = 90000 }, function(r, cx)
		local wcx = cx :: WindowCx
		if r.timed_out then
			done(nil, "The mail server didn't answer in time", wcx)
			return
		end
		local okj, body = pcall(tern.json.decode, r.stdout)
		if not okj or type(body) ~= "table" then
			local why = trim(r.stderr ~= "" and r.stderr or r.stdout)
			done(nil, "Email helper failed: " .. string.sub(why, -300), wcx)
			return
		end
		if body.error then
			done(nil, body.error, wcx)
			return
		end
		done(body, nil, wcx)
	end)
	if not ok then
		tern.timer(0, function(cx)
			done(nil, "Email needs python3 on PATH: " .. tostring(err), cx :: WindowCx)
		end)
	end
end

-- Decoded JSON is read-only; meetings get fresh tables without JSON nulls.
local function meeting(n: any): any
	local m = {}
	for k, v in n do
		if v ~= tern.json.null then
			m[k] = v
		end
	end
	return m
end

-- Every account's threads, merged; the cursor is a JSON object of each account's own cursor.
local function list(cred: string, cursor: string?, done: source.Done<source.Page>)
	local accts = accounts(cred)
	local prev: { [string]: any } = {}
	if cursor then
		local ok, c = pcall(tern.json.decode, cursor)
		if ok and type(c) == "table" then
			prev = c
		end
	end
	local todo = {}
	for _, a in accts do
		if cursor == nil or type(prev[address(a)]) == "string" then
			table.insert(todo, a)
		end
	end
	local notes, nexts, errs, pending = {}, {}, {}, #todo
	local any_next = false
	if pending == 0 then
		tern.timer(0, function(cx)
			done({ notes = {}, cursor = nil }, nil, cx :: WindowCx)
		end)
		return
	end
	for _, a in todo do
		local addr = address(a)
		call(a, { op = "list", cursor = if cursor then prev[addr] else nil }, function(res, err, cx)
			if err then
				table.insert(errs, addr .. ": " .. err)
			else
				for _, n in res.notes or {} do
					local m = meeting(n)
					-- The id names the account so details are fetched from the right mailbox.
					m.id = "email:" .. addr .. "|" .. string.gsub(m.id, "^email:", "")
					m.account = addr
					table.insert(notes, m)
				end
				if type(res.cursor) == "string" then
					nexts[addr] = res.cursor
					any_next = true
				end
			end
			pending -= 1
			if pending == 0 then
				if #notes == 0 and #errs > 0 then
					done(nil, table.concat(errs, " · "), cx)
					return
				end
				done({ notes = notes, cursor = if any_next then tern.json.encode(nexts) else nil }, nil, cx)
			end
		end)
	end
end

local function note(cred: string, id: string, _transcript: boolean, done: source.Done<any>)
	local addr, rest = string.match(id, "^(.-)|(.*)$")
	local acct = accounts(cred)[1]
	for _, a in accounts(cred) do
		if addr and address(a) == addr then
			acct = a
		end
	end
	local uids = {}
	for uid in string.gmatch(rest or id, "%d+") do
		table.insert(uids, tonumber(uid))
	end
	call(acct, { op = "thread", uids = tern.json.array(uids) }, function(res, err, cx)
		if err then
			done(nil, err, cx)
			return
		end
		local m = meeting(res.note)
		m.id = "email:" .. (addr or address(acct)) .. "|" .. string.gsub(m.id, "^email:", "")
		m.account = addr or address(acct)
		done(m, nil, cx)
	end)
end

local def: source.Def = {
	id = "email",
	name = NAME,
	credential = "secret",
	secret = "email-account",
	needs = "address + app password",
	prompt = "Email address to add (Google Workspace and other domains: add the server after a space, e.g. you@acme.com imap.gmail.com)",
	then_prompt = "App password (Gmail: myaccount.google.com/apppasswords, needs 2-step verification)",
	merge = merge,
	list = list,
	note = note,
}
return def
