-- Host and window halves against a scripted runtime: refresh, 401 retry, 429 backoff, Claude Code
-- and Codex write-back, duplicate accounts, Claude and ChatGPT logins, the block view with its
-- Claude / GPT tabs, several accounts (summary, layouts, aliases, hiding, ordering) and the status
-- segment's modes.

local fake = require("./fake_tern")
local crypto = require("../lib/crypto")

local NOW_MS = os.time() * 1000

local function eq(a: any, b: any, what: string)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2)
	end
end

local function payload(session: number, weekly: number): string
	return string.format(
		[[{"five_hour":{"utilization":%d,"resets_at":"2030-01-01T00:00:00+00:00"},"seven_day":{"utilization":%d,"resets_at":"2030-01-05T00:00:00Z"},"limits":[{"kind":"weekly_scoped","percent":12,"resets_at":"2030-01-05T00:00:00Z","scope":{"model":{"display_name":"Opus"}}}],"spend":{"enabled":true,"used":{"amount_minor":500,"exponent":2,"currency":"USD"},"limit":{"amount_minor":2000,"exponent":2,"currency":"USD"}}}]],
		session,
		weekly
	)
end

local function ok(body: string, headers: any?): any
	return { status = 200, headers = headers or {}, body = body, timed_out = false }
end

local function status(code: number, body: string?, headers: any?): any
	return { status = code, headers = headers or {}, body = body or "{}", timed_out = false }
end

local TOKEN_OK = [[{"access_token":"sk-new","refresh_token":"rt-new","expires_in":28800,"account":{"uuid":"acc-1","email_address":"me@example.com"},"organization":{"uuid":"org-1","name":"Me Org"}}]]
local PROFILE = [[{"account":{"uuid":"acc-1","email":"me@example.com"},"organization":{"uuid":"org-1","name":"Me Org","rate_limit_tier":"default_claude_max_5x"}}]]

-- Every node is a table with a string kind and well-formed children; returns the visible text.
local function walk(node: any, out: { string })
	assert(type(node) == "table" and type(node.k) == "string", "bad node")
	local p = node.p or {}
	for _, key in { "spans", "head", "label", "total" } do
		local s = p[key]
		if type(s) == "table" then
			for _, span in s do
				table.insert(out, if type(span) == "table" then span.t else span)
			end
		elseif type(s) == "string" then
			table.insert(out, s)
		end
	end
	if type(p.text) == "string" then
		table.insert(out, p.text)
	end
	for _, c in node.c or {} do
		walk(c, out)
	end
end

local function render(env: any, st: any, cx: any): string
	local def = env.blocks.usage
	local v = def.view(st, cx)
	local out = {}
	walk(v.main, out)
	if v.dock then
		walk(v.dock, out)
	end
	return table.concat(out, " ")
end

local function base_process(argv: { string }, _opts: any): any
	if argv[1] == "chmod" then
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end
	if argv[1] == "security" then
		return { status = 44, stdout = "", stderr = "not found", timed_out = false }
	end
	return { status = 127, stdout = "", stderr = "nope", timed_out = false }
end

local function own_account(expires: number): string
	return string.format(
		[[{"accounts":[{"id":"own:a","added_at":1,"tokens":{"access":"sk-old","refresh":"rt-old","expires":%d,"account_uuid":"acc-1","org_uuid":"org-1","email":"me@example.com"}}]}]],
		expires
	)
end

local function count(list: { any }, pred: (any) -> boolean): number
	local n = 0
	for _, v in list do
		if pred(v) then
			n += 1
		end
	end
	return n
end

local function is_usage(c: any): boolean
	return string.find(c.url, "/api/oauth/usage", 1, true) ~= nil
end

local function is_token(c: any): boolean
	return string.find(c.url, "/v1/oauth/token", 1, true) ~= nil
end

-- ── own account: expired token is refreshed, then usage and profile are read ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS - 1000)
	env.process = base_process
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "platform.claude.com/v1/oauth/token", 1, true) then
			local body = env.tern.json.decode(opts.body)
			eq(body.grant_type, "refresh_token", "grant")
			eq(body.refresh_token, "rt-old", "old refresh token sent")
			eq(opts.headers["anthropic-beta"], "oauth-2025-04-20", "refresh beta header")
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			eq(opts.headers.Authorization, "Bearer sk-new", "usage uses refreshed token")
			return ok(payload(42, 18))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()

	local stored = env.tern.json.decode(env.files["/data/accounts.json"])
	eq(stored.accounts[1].tokens.refresh, "rt-new", "rotated refresh token persisted")
	eq(stored.accounts[1].tokens.access, "sk-new", "new access token persisted")
	eq(count(env.calls.process, function(c)
		return c.argv[1] == "chmod" and c.argv[3] == "/data/accounts.json"
	end) >= 1, true, "accounts file chmod 600")

	local s = env.kv.status
	eq(#s.accounts, 1, "status rows")
	eq(s.accounts[1].session.pct, 42, "status session pct")
	eq(s.accounts[1].weekly.pct, 18, "status weekly pct")
	eq(s.accounts[1].plan, "Max 5x", "plan from profile")

	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local text = render(env, st, cx)
	for _, want in { "me@example.com", "Max 5x", "5h", "42%", "7d", "18%", "7d Opus", "12%", "Extra", "$5.00", "/ $20.00" } do
		assert(string.find(text, want, 1, true), "view shows " .. want .. " in: " .. text)
	end
	-- A narrow pane drops the source, pace extras and history but keeps every window.
	cx.cols = 40
	local narrow = render(env, st, cx)
	assert(not string.find(narrow, "Plugin login", 1, true), "narrow drops source: " .. narrow)
	for _, want in { "5h", "42%", "7d Opus", "Extra" } do
		assert(string.find(narrow, want, 1, true), "narrow shows " .. want)
	end
	cx.cols = 100
	eq(env.blocks.usage.title(st), "Claude 5h 42% · 7d 18%", "title")

	-- The window segment reads the same summary.
	-- Forge's window entry registers the formatter; the usage half exports its segments.
	env.status_fn = require("../window").status
	local segs = env.status_fn({ pane = 1, cwd = "", program = "", title = "" })
	assert(segs and string.find(segs[1].text, "5h 42%", 1, true) and string.find(segs[1].text, "7d 18%", 1, true), "status segment")
	eq(segs[1].command, "plugin.forge.usage", "segment opens block")

	-- 's' hides the segment.
	env.blocks.usage.key(st, { name = "s", ctrl = false, alt = false, shift = false, meta = false }, cx)
	env.drain()
	env.advance(16000)
	eq(env.status_fn({ pane = 1, cwd = "", program = "", title = "" }), nil, "segment off")
	print("own refresh: ok")
end

-- ── 401 once: refresh and retry; 429: back off, keep data, force ignores backoff ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600 * 1000)
	env.process = base_process
	local usage_answers = { status(401), ok(payload(10, 5)) }
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return table.remove(usage_answers, 1) or status(429, '{"error":{"type":"rate_limit_error","message":"slow down"}}', { ["retry-after"] = "120" })
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	eq(count(env.calls.fetch, is_token), 1, "one refresh after 401")
	eq(count(env.calls.fetch, is_usage), 2, "usage retried once")

	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	env.drain()
	-- A block opened within the interval reuses the fresh data.
	eq(count(env.calls.fetch, is_usage), 2, "no refetch on open")
	env.advance(61000)
	eq(count(env.calls.fetch, is_usage), 3, "polled at the interval")
	local text = render(env, st, cx)
	assert(string.find(text, "429", 1, true), "429 shown: " .. text)
	assert(string.find(text, "10%", 1, true), "old data kept: " .. text)
	env.advance(61000)
	eq(count(env.calls.fetch, is_usage), 3, "backoff skips the next tick")
	env.blocks.usage.key(st, { name = "r", ctrl = false, alt = false, shift = false, meta = false }, cx)
	env.drain()
	eq(count(env.calls.fetch, is_usage), 4, "r forces a fetch")
	print("401/429: ok")
end

-- ── Claude Code: expired keychain login is refreshed and written back ──
do
	local env = fake.new()
	__fresh(env)
	local doc = string.format(
		[[{"claudeAiOauth":{"accessToken":"cc-old","refreshToken":"cc-rt-old","expiresAt":%d,"scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x","refreshTokenExpiresAt":123},"mcpOAuth":{"keep":"me"}}]],
		NOW_MS - 5000
	)
	local written: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[2] == "find-generic-password" and argv[5] == "-w" then
			eq(argv[4], "Claude Code-credentials", "keychain service")
			return { status = 0, stdout = written or doc, stderr = "", timed_out = false }
		elseif argv[1] == "security" and argv[2] == "find-generic-password" then
			return { status = 0, stdout = '    "acct"<blob>="zero"\n    "svce"<blob>="Claude Code-credentials"\n', stderr = "", timed_out = false }
		elseif argv[1] == "security" and argv[2] == "-i" then
			local acct, hex = string.match(opts.stdin, '^add%-generic%-password %-U %-a "([^"]+)" %-s "Claude Code%-credentials" %-X (%x+)\n$')
			eq(acct, "zero", "write-back uses the item's account")
			written = crypto.unhex(hex :: string)
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			eq(env.tern.json.decode(opts.body).refresh_token, "cc-rt-old", "Claude Code refresh token")
			return ok([[{"access_token":"cc-new","refresh_token":"cc-rt-new","expires_in":28800}]])
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			eq(opts.headers.Authorization, "Bearer cc-new", "usage with refreshed Claude Code token")
			return ok(payload(7, 3))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	assert(written, "keychain written back")
	local saved = env.tern.json.decode(written :: string)
	eq(saved.claudeAiOauth.accessToken, "cc-new", "write-back access")
	eq(saved.claudeAiOauth.refreshToken, "cc-rt-new", "write-back refresh")
	eq(saved.claudeAiOauth.subscriptionType, "max", "other fields kept")
	eq(saved.claudeAiOauth.refreshTokenExpiresAt, 123, "unknown fields kept")
	eq(saved.mcpOAuth.keep, "me", "sibling keys kept")
	eq(env.kv.status.accounts[1].plan, "Max 5x", "live profile tier wins over the keychain's login-time tier")
	eq(env.kv.status.accounts[1].session.pct, 7, "Claude Code usage")

	-- Next tick: the written token is current, so no second refresh.
	env.advance(301000)
	eq(count(env.calls.fetch, is_token), 1, "no second refresh")
	print("claude code write-back: ok")
end

-- ── Claude Code's own fresh cache is used instead of a request ──
do
	local env = fake.new()
	__fresh(env)
	local doc = string.format([[{"claudeAiOauth":{"accessToken":"cc","refreshToken":"rt","expiresAt":%d}}]], NOW_MS + 3600000)
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[5] == "-w" then
			return { status = 0, stdout = doc, stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.files["/home/test/.claude.json"] = string.format(
		[[{"oauthAccount":{"accountUuid":"acc-9","emailAddress":"cc@example.com","organizationRateLimitTier":"default_claude_ai"},"cachedUsageUtilization":{"fetchedAtMs":%d,"accountUuid":"acc-9","utilization":%s}}]],
		NOW_MS - 5000,
		payload(55, 30)
	)
	env.fetch = function(url: string, _opts: any): any
		error("no request expected: " .. url)
	end
	require("../host")
	env.drain()
	local row = env.kv.status.accounts[1]
	eq(row.label, "cc@example.com", "label from oauthAccount")
	eq(row.plan, "Pro", "plan from oauthAccount")
	eq(row.session.pct, 55, "cached usage adopted")
	print("claude code cache: ok")
end

-- ── the same account from two sources shows once ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600000)
	local doc = string.format([[{"claudeAiOauth":{"accessToken":"cc","refreshToken":"rt","expiresAt":%d}}]], NOW_MS + 3600000)
	env.files["/home/test/.claude.json"] = [[{"oauthAccount":{"accountUuid":"acc-1","organizationUuid":"org-1","emailAddress":"me@example.com"}}]]
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "security" and argv[5] == "-w" then
			return { status = 0, stdout = doc, stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(1, 1))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	env.advance(301000)
	eq(#env.kv.status.accounts, 1, "deduplicated")
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	assert(string.find(render(env, st, cx), "1 other source(s) point to the same account", 1, true), "duplicate note")
	print("dedupe: ok")
end

-- ── login through the loopback listener ──
do
	local env = fake.new()
	__fresh(env)
	local opened: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "od" then
			return { status = 0, stdout = string.rep("ab ", 64), stderr = "", timed_out = false }
		elseif argv[1] == "nc" then
			eq(argv[3], "54545", "listener port")
			assert(string.find(opts.stdin, "HTTP/1.1 200 OK", 1, true), "listener answers")
			return "pending"
		elseif argv[1] == "open" then
			opened = argv[2]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	local exchanged: any = nil
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			exchanged = env.tern.json.decode(opts.body)
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(20, 10))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, { "login" }, nil)
	env.advance(500)
	assert(opened and string.find(opened :: string, "^https://claude%.ai/oauth/authorize%?"), "browser opened: " .. tostring(opened))
	assert(string.find(opened :: string, "redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback", 1, true), "loopback redirect")
	assert(string.find(render(env, st, cx), "Completes automatically", 1, true), "listening hint")
	local state = string.match(opened :: string, "[?&]state=([%x]+)")
	env.pending.nc({ status = 0, stdout = "GET /callback?code=THE-CODE&state=" .. state .. " HTTP/1.1\r\nHost: localhost\r\n\r\n", stderr = "", timed_out = false })
	env.drain()
	assert(exchanged, "code exchanged")
	eq(exchanged.grant_type, "authorization_code", "exchange grant")
	eq(exchanged.code, "THE-CODE", "exchange code")
	eq(exchanged.state, state, "exchange state")
	eq(exchanged.redirect_uri, "http://localhost:54545/callback", "exchange redirect")
	eq(exchanged.client_id, "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "client id")
	local challenge = string.match(opened :: string, "code_challenge=([%w%-_]+)")
	eq(crypto.base64url(crypto.sha256(exchanged.code_verifier)), challenge, "verifier matches challenge")
	eq(st.flow, nil, "flow closed")
	eq(env.toasts[#env.toasts].level, "success", "success toast")
	local stored = env.tern.json.decode(env.files["/data/accounts.json"])
	eq(stored.accounts[1].tokens.email, "me@example.com", "account stored")
	eq(env.kv.status.accounts[1].session.pct, 20, "new account polled")
	print("login loopback: ok")
end

-- ── login by pasting code#state when the port is taken ──
do
	local env = fake.new()
	__fresh(env)
	local opened: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "od" then
			return { status = 0, stdout = string.rep("cd ", 64), stderr = "", timed_out = false }
		elseif argv[1] == "nc" then
			return { status = 1, stdout = "", stderr = "Address already in use", timed_out = false }
		elseif argv[1] == "open" then
			opened = argv[2]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	local exchanged: any = nil
	env.fetch = function(url: string, opts: any): any
		if string.find(url, "/v1/oauth/token", 1, true) then
			exchanged = env.tern.json.decode(opts.body)
			if string.find(url, "platform.claude.com", 1, true) then
				return { status = 0, headers = {}, body = "", error = "connection refused", timed_out = false }
			end
			return ok(TOKEN_OK)
		elseif string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(20, 10))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(PROFILE)
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string, text: string?)
		return env.blocks.usage.key(st, { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	key("l")
	env.advance(500)
	assert(opened and string.find(opened :: string, "redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback", 1, true), "manual redirect")
	assert(string.find(render(env, st, cx), "code#state", 1, true), "paste hint")
	local state = string.match(opened :: string, "[?&]state=([%x]+)")
	-- A wrong state is refused without a request.
	key("paste", "CODE#deadbeef")
	env.drain()
	eq(exchanged, nil, "wrong state not exchanged")
	assert(string.find(render(env, st, cx), "state mismatch", 1, true), "state error shown")
	key("paste", " CODE2#" .. state .. "\n")
	env.drain()
	assert(exchanged, "pasted code exchanged")
	eq(exchanged.code, "CODE2", "pasted code")
	eq(exchanged.redirect_uri, "https://platform.claude.com/oauth/code/callback", "manual redirect in exchange")
	eq(count(env.calls.fetch, is_token), 2, "token endpoint fallback")
	eq(st.flow, nil, "flow done")
	eq(#env.kv.status.accounts, 1, "account added")
	print("login paste: ok")
end

-- ── removing an own account needs confirmation ──
do
	local env = fake.new()
	__fresh(env)
	env.files["/data/accounts.json"] = own_account(NOW_MS + 3600000)
	env.process = base_process
	env.fetch = function(url: string, _opts: any): any
		if string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(1, 1))
		end
		return ok(PROFILE)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string)
		return env.blocks.usage.key(st, { name = name, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	key("x")
	assert(string.find(render(env, st, cx), "Remove this login", 1, true), "confirm shown")
	key("enter")
	eq(#env.tern.json.decode(env.files["/data/accounts.json"]).accounts, 0, "removed")
	eq(key("q"), false, "unused key returns false")
	print("remove: ok")
end

-- ChatGPT access tokens are JWTs; the plugin reads expiry, user, account, plan and email from them.
local function gpt_token(env: any, exp: number, user: string, plan: string): string
	local claims = {
		exp = exp,
		["https://api.openai.com/auth"] = { chatgpt_user_id = user, chatgpt_account_id = "acct-1", chatgpt_plan_type = plan },
		["https://api.openai.com/profile"] = { email = user .. "@example.com" },
	}
	return "eyJhbGciOiJub25lIn0." .. crypto.base64url(env.tern.json.encode(claims)) .. ".sig"
end

local function gpt_usage(session: number, weekly: number): string
	local now = os.time()
	return string.format(
		[[{"user_id":"user-1","account_id":"acct-1","email":"user-1@example.com","plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":%d,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":%d},"secondary_window":{"used_percent":%d,"limit_window_seconds":604800,"reset_at":%d}},"code_review_rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":%d}},"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"}}]],
		session,
		now + 3600,
		weekly,
		now + 3 * 86400,
		now + 3 * 86400
	)
end

local function is_wham(c: any): boolean
	return c.url == "https://chatgpt.com/backend-api/wham/usage"
end

-- ── Codex CLI: expired login is refreshed and written back; the GPT tab shows it ──
do
	local env = fake.new()
	__fresh(env)
	local auth = "/home/test/.codex/auth.json"
	env.files[auth] = env.tern.json.encode({
		auth_mode = "chatgpt",
		tokens = { access_token = gpt_token(env, os.time() - 10, "user-1", "plus"), refresh_token = "crt-old", id_token = "idt-old", account_id = "acct-1" },
		last_refresh = "2026-01-01T00:00:00Z",
	})
	env.process = base_process
	local new_access = gpt_token(env, os.time() + 86400, "user-1", "plus")
	env.fetch = function(url: string, opts: any): any
		if url == "https://auth.openai.com/oauth/token" then
			local body = env.tern.json.decode(opts.body)
			eq(body.grant_type, "refresh_token", "codex grant")
			eq(body.refresh_token, "crt-old", "codex refresh token sent")
			eq(body.client_id, "app_EMoamEEZ73f0CkXaXp7hrann", "codex client id")
			return ok(env.tern.json.encode({ access_token = new_access, refresh_token = "crt-new", id_token = "idt-new" }))
		elseif is_wham({ url = url }) then
			eq(opts.headers.Authorization, "Bearer " .. new_access, "wham uses the refreshed token")
			eq(opts.headers["ChatGPT-Account-Id"], "acct-1", "wham names the account")
			return ok(gpt_usage(12, 30))
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()

	local saved = env.tern.json.decode(env.files[auth])
	eq(saved.tokens.access_token, new_access, "write-back access")
	eq(saved.tokens.refresh_token, "crt-new", "write-back rotated refresh")
	eq(saved.tokens.id_token, "idt-new", "write-back id token")
	eq(saved.tokens.account_id, "acct-1", "account id kept")
	eq(saved.auth_mode, "chatgpt", "other fields kept")
	assert(saved.last_refresh ~= "2026-01-01T00:00:00Z", "last_refresh bumped")
	eq(count(env.calls.process, function(c)
		return c.argv[1] == "chmod" and c.argv[3] == auth
	end), 1, "auth.json stays 600")

	local s = env.kv.status
	eq(s.provider, "claude", "Claude is the default tab")
	eq(#s.accounts, 1, "one GPT row")
	eq(s.accounts[1].provider, "gpt", "row provider")
	eq(s.accounts[1].plan, "Plus", "plan from the payload")
	eq(s.accounts[1].session.pct, 12, "gpt 5h")
	eq(s.accounts[1].weekly.pct, 30, "gpt 7d")

	-- The status line shows the chosen provider only: nothing while Claude has no account.
	env.status_fn = require("../window").status
	local pane = { pane = 1, cwd = "", program = "", title = "" }
	eq(env.status_fn(pane), nil, "no Claude account, no segment")

	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string)
		return env.blocks.usage.key(st, { name = name, ctrl = false, alt = false, shift = false, meta = false }, cx)
	end
	env.drain()
	assert(string.find(render(env, st, cx), "No Claude account yet", 1, true), "Claude tab empty")
	eq(key("tab"), true, "Tab switches")
	eq(env.kv.settings.provider, "gpt", "tab choice persisted as the default")
	eq(env.kv.status.provider, "gpt", "status follows the tab")
	local text = render(env, st, cx)
	for _, want in { "user-1@example.com", "Plus", "Codex CLI", "5h", "12%", "7d", "30%", "7d Review", "Balance", "12.5" } do
		assert(string.find(text, want, 1, true), "GPT tab shows " .. want .. " in: " .. text)
	end
	assert(not string.find(text, "account yet", 1, true), "GPT tab not empty")
	eq(env.blocks.usage.title(st), "GPT 5h 12% · 7d 30%", "title follows the tab")
	env.advance(16000)
	local segs = env.status_fn(pane)
	assert(segs and string.find(segs[1].text, "^GPT 5h 12%% %(") and string.find(segs[1].text, "· 7d 30%", 1, true), "GPT segment: " .. tostring(segs and segs[1].text))

	-- 'c' on the GPT tab toggles the Codex source, not Claude Code.
	key("c")
	env.drain()
	eq(env.kv.settings.codex, false, "codex source off")
	eq(env.kv.settings.claude_code, true, "claude code untouched")
	assert(string.find(render(env, st, cx), "No GPT account yet", 1, true), "GPT tab empty without the source")

	-- A clicked tab switches back.
	env.blocks.usage.event(st, { ev = "action", act = "tab", value = "claude" }, cx)
	eq(env.kv.status.provider, "claude", "click switches")
	print("codex refresh + tabs: ok")
end

-- ── omp ChatGPT rows: same account as Codex shows once; an expired omp row isn't refreshed ──
do
	local env = fake.new()
	__fresh(env)
	env.kv.settings = { provider = "gpt" }
	env.files["/home/test/.codex/auth.json"] = env.tern.json.encode({
		tokens = { access_token = gpt_token(env, os.time() + 86400, "user-1", "plus"), refresh_token = "crt", account_id = "acct-1" },
	})
	env.files["/home/test/.omp/agent/agent.db"] = "sqlite"
	local rows = env.tern.json.encode({
		{ id = 5, provider = "openai-codex", data = env.tern.json.encode({ access = gpt_token(env, os.time() + 86400, "user-1", "plus"), refresh = "r", expires = NOW_MS + 86400000, accountId = "acct-1", email = "user-1@example.com" }) },
		{ id = 6, provider = "openai-codex", data = env.tern.json.encode({ access = gpt_token(env, os.time() - 10, "user-2", "pro"), refresh = "r2", expires = NOW_MS - 10000, accountId = "acct-1", email = "user-2@example.com" }) },
	})
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "sqlite3" then
			assert(string.find(argv[5], "'openai-codex'", 1, true), "omp query reads ChatGPT rows")
			return { status = 0, stdout = rows, stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	env.fetch = function(url: string, _opts: any): any
		if is_wham({ url = url }) then
			return ok(gpt_usage(1, 2))
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	eq(count(env.calls.fetch, is_wham), 1, "duplicate account fetched once, expired omp row not at all")
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local text = render(env, st, cx)
	assert(string.find(text, "1 other source(s) point to the same account", 1, true), "duplicate note: " .. text)
	assert(string.find(text, "The omp login has expired: sign in again in omp", 1, true), "expired omp row: " .. text)
	assert(string.find(text, "Pro", 1, true), "plan from the token claim before any usage")
	print("omp gpt: ok")
end

-- ── ChatGPT login through the loopback listener; the new account refreshes against OpenAI ──
do
	local env = fake.new()
	__fresh(env)
	env.kv.settings = { provider = "gpt" }
	local opened: string? = nil
	env.process = function(argv: { string }, opts: any): any
		if argv[1] == "od" then
			return { status = 0, stdout = string.rep("5a ", 64), stderr = "", timed_out = false }
		elseif argv[1] == "nc" then
			eq(argv[3], "1455", "Codex listener port")
			return "pending"
		elseif argv[1] == "open" then
			opened = argv[2]
			return { status = 0, stdout = "", stderr = "", timed_out = false }
		end
		return base_process(argv, opts)
	end
	local exchange_body: string? = nil
	local refresh_body: any = nil
	local fresh = gpt_token(env, os.time() + 86400, "user-9", "pro")
	env.fetch = function(url: string, opts: any): any
		if url == "https://auth.openai.com/oauth/token" then
			if opts.headers["Content-Type"] == "application/x-www-form-urlencoded" then
				exchange_body = opts.body
				-- An access token that is already stale: the first poll must refresh it.
				return ok(env.tern.json.encode({ access_token = gpt_token(env, os.time() - 10, "user-9", "pro"), refresh_token = "grt-1", id_token = "gid-1" }))
			end
			refresh_body = env.tern.json.decode(opts.body)
			return ok(env.tern.json.encode({ access_token = fresh, refresh_token = "grt-2" }))
		elseif is_wham({ url = url }) then
			eq(opts.headers.Authorization, "Bearer " .. fresh, "wham with the refreshed own token")
			return ok(gpt_usage(33, 44))
		end
		error("unexpected fetch " .. url)
	end
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	assert(string.find(render(env, st, cx), "Press l to sign in to a ChatGPT account", 1, true), "GPT empty state offers login")
	env.blocks.usage.key(st, { name = "l", ctrl = false, alt = false, shift = false, meta = false }, cx)
	env.advance(500)
	eq(st.flow.provider, "gpt", "l on the GPT tab logs in to ChatGPT")
	assert(opened and string.find(opened :: string, "^https://auth%.openai%.com/oauth/authorize%?"), "OpenAI authorize page: " .. tostring(opened))
	assert(string.find(opened :: string, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback", 1, true), "Codex redirect")
	assert(string.find(opened :: string, "prompt=login", 1, true), "account chooser forced")
	local state = string.match(opened :: string, "[?&]state=([%x]+)")
	env.pending.nc({ status = 0, stdout = "GET /auth/callback?code=G-CODE&state=" .. state .. " HTTP/1.1\r\n\r\n", stderr = "", timed_out = false })
	env.drain()
	assert(exchange_body, "code exchanged")
	assert(string.find(exchange_body :: string, "grant_type=authorization_code", 1, true), "form grant")
	assert(string.find(exchange_body :: string, "code=G-CODE", 1, true), "form code")
	assert(string.find(exchange_body :: string, "code_verifier=", 1, true), "form verifier")
	assert(refresh_body, "stale own GPT token refreshed")
	eq(refresh_body.refresh_token, "grt-1", "OpenAI refresh with the stored token")
	local stored = env.tern.json.decode(env.files["/data/accounts.json"])
	eq(stored.accounts[1].provider, "gpt", "own row remembers its provider")
	eq(stored.accounts[1].tokens.refresh, "grt-2", "rotated GPT refresh token persisted")
	local row = env.kv.status.accounts[1]
	eq(row.provider, "gpt", "status row provider")
	eq(row.session.pct, 33, "own GPT usage polled")
	eq(env.toasts[#env.toasts].text, "ChatGPT account signed in", "toast names ChatGPT")
	print("gpt login: ok")
end

-- Three Claude accounts with different usage (a busy, b idle, c used up) plus one ChatGPT login.
local function multi_env(): any
	local env = fake.new()
	__fresh(env)
	local rows = {}
	for _, n in { "a", "b", "c" } do
		table.insert(rows, { id = "own:" .. n, added_at = 1, tokens = { access = "sk-" .. n, refresh = "rt-" .. n, expires = NOW_MS + 3600000, account_uuid = "acc-" .. n, org_uuid = "org-" .. n, email = n .. "@example.com" } })
	end
	env.files["/data/accounts.json"] = env.tern.json.encode({ accounts = rows })
	env.files["/home/test/.codex/auth.json"] = env.tern.json.encode({
		tokens = { access_token = gpt_token(env, os.time() + 86400, "user-1", "plus"), refresh_token = "crt", account_id = "acct-1" },
	})
	env.process = base_process
	local load = { ["sk-a"] = { 90, 50 }, ["sk-b"] = { 10, 20 }, ["sk-c"] = { 100, 40 } }
	env.fetch = function(url: string, opts: any): any
		local who = string.match(opts.headers.Authorization or "", "^Bearer (.+)$") or ""
		local n = string.match(who, "^sk%-(%a)$")
		if string.find(url, "/api/oauth/usage", 1, true) then
			return ok(payload(load[who][1], load[who][2]))
		elseif string.find(url, "/api/oauth/profile", 1, true) then
			return ok(string.format([[{"account":{"uuid":"acc-%s","email":"%s@example.com"},"organization":{"uuid":"org-%s","rate_limit_tier":"default_claude_max_5x"}}]], n, n, n))
		elseif is_wham({ url = url }) then
			return ok(gpt_usage(12, 30))
		end
		error("unexpected fetch " .. url)
	end
	return env
end

local function status_texts(env: any): { string }
	env.advance(16000)
	local out = {}
	for _, seg in env.status_fn({ pane = 1, cwd = "", program = "", title = "" }) or {} do
		table.insert(out, seg.text)
	end
	return out
end

-- ── several accounts: summary, compact layout, status-line modes and scope ──
do
	local env = multi_env()
	require("../host")
	env.status_fn = require("../window").status
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string, shift: boolean?)
		return env.blocks.usage.key(st, { name = name, ctrl = false, alt = false, shift = shift == true, meta = false }, cx)
	end
	local function act(name: string, value: string?)
		env.blocks.usage.event(st, { ev = "action", act = name, value = value }, cx)
	end

	-- Auto layout: three accounts get compact rows, the summary and the selected account's card.
	local text = render(env, st, cx)
	for _, want in { "Summary", "Usable 2/3", "Most free", "Soonest recovery", "j/k to select" } do
		assert(string.find(text, want, 1, true), "multi view shows " .. want .. " in: " .. text)
	end
	local v = env.blocks.usage.view(st, cx)
	local list = nil
	for _, c in v.main.c do
		if c.p and c.p.key == "list" then
			list = c
		end
	end
	assert(list and #list.c == 3, "one compact row per account")

	-- "one": the first account, with the count of the others.
	local segs = status_texts(env)
	eq(#segs, 1, "one segment")
	assert(string.find(segs[1], "^5h 90%% %(") and string.find(segs[1], "+2$"), "first account: " .. segs[1])
	-- Pinning b moves the segment to it.
	key("j")
	key("p")
	assert(string.find(status_texts(env)[1], "^5h 10%%"), "pinned account on the status line")
	-- "best": the account with the most headroom, named.
	act("set", "status_mode:best")
	assert(string.find(status_texts(env)[1], "^b 5h 10%%"), "best account: " .. status_texts(env)[1])
	-- "all": one segment per account; "both" adds ChatGPT's.
	act("set", "status_mode:all")
	segs = status_texts(env)
	eq(#segs, 3, "every Claude account")
	eq(segs[2], "b 10%/20%", "compact per-account segment")
	act("set", "status_scope:both")
	segs = status_texts(env)
	eq(#segs, 4, "both providers")
	eq(segs[4], "GPT user-1 12%/30%", "GPT segment in both scope")
	print("multi summary + status: ok")
end

-- ── per-account preferences: rename, hide, move, sort, cards layout ──
do
	local env = multi_env()
	require("../host")
	env.drain()
	local cx = env.cx(1)
	local st = env.blocks.usage.init(cx, {}, nil)
	local function key(name: string, opts: any?)
		local o = opts or {}
		return env.blocks.usage.key(st, { name = name, text = o.text, ctrl = false, alt = false, shift = o.shift == true, meta = false }, cx)
	end
	local function names(): string
		local out = {}
		for _, r in env.kv.status.accounts do
			if r.provider == "claude" then
				table.insert(out, r.name)
			end
		end
		return table.concat(out, ",")
	end
	eq(names(), "a,b,c", "source order")

	-- Rename b: the alias shows in the panel and on the status line, keyed by the account.
	key("j")
	key("e")
	assert(string.find(render(env, st, cx), "Rename", 1, true), "rename box")
	key("W", { text = "W" })
	key("o", { text = "o" })
	key("backspace")
	key("paste", { text = "ork" })
	key("enter")
	eq(st.edit, nil, "rename closed")
	eq(names(), "a,Work,c", "alias published")
	eq(env.kv.prefs["claude|acc-b|org-b"].alias, "Work", "alias stored under the account identity")
	assert(string.find(render(env, st, cx), "Work", 1, true), "alias shown")
	-- Clearing the alias restores the email.
	key("e")
	for _ = 1, 4 do
		key("backspace")
	end
	key("enter")
	eq(names(), "a,b,c", "alias cleared")

	-- Sort by usage; moving an account then switches to manual order, starting from the one shown.
	env.blocks.usage.event(st, { ev = "action", act = "set", value = "sort:usage" }, cx)
	eq(names(), "c,a,b", "busiest first")
	env.blocks.usage.event(st, { ev = "action", act = "select", value = "own:b" }, cx)
	eq(st.sel, 3, "click selects")
	key("K", { shift = true })
	eq(names(), "c,b,a", "moved up")
	eq(env.kv.settings.sort, "manual", "manual order")
	eq(st.sel, 2, "selection follows the moved account")

	-- Hide a: off the status line, the summary and the polling; listed again with a.
	env.blocks.usage.event(st, { ev = "action", act = "hide", value = "own:a" }, cx)
	eq(names(), "c,b", "hidden account left off the status line")
	local before = count(env.calls.fetch, function(c)
		return is_usage(c) and c.opts.headers.Authorization == "Bearer sk-a"
	end)
	key("r")
	env.drain()
	eq(count(env.calls.fetch, function(c)
		return is_usage(c) and c.opts.headers.Authorization == "Bearer sk-a"
	end), before, "hidden account not polled")
	local text = render(env, st, cx)
	assert(string.find(text, "1 account(s) hidden", 1, true), "hidden note: " .. text)
	assert(not string.find(text, "a@example.com", 1, true), "hidden account not listed")
	key("a")
	assert(string.find(render(env, st, cx), "Hidden", 1, true), "hidden account listed on demand")
	env.blocks.usage.event(st, { ev = "action", act = "hide", value = "own:a" }, cx)
	env.drain()
	eq(names(), "c,b,a", "unhidden account back in its place")

	-- Explicit cards layout; a wide pane puts the cards side by side.
	env.blocks.usage.event(st, { ev = "action", act = "set", value = "layout:cards" }, cx)
	cx.cols = 130
	local v = env.blocks.usage.view(st, cx)
	local grid = nil
	for _, c in v.main.c do
		if c.p and c.p.key == "grid" then
			grid = c
		end
	end
	assert(grid and #grid.c == 3, "three cards in the grid")
	key("v")
	eq(env.kv.settings.layout, "compact", "v cycles the layout")
	print("prefs + layouts: ok")
end
