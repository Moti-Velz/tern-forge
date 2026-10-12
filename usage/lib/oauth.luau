--!strict
-- Claude subscription OAuth (the public Claude Code client): PKCE authorize URL, code exchange,
-- token refresh, and the `/api/oauth/*` reads (usage, profile).

local crypto = require("./crypto")

local M = {}

M.CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
M.AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
-- Claude Code's current token host first; omp's (api.anthropic.com) as the fallback.
M.TOKEN_URLS = { "https://platform.claude.com/v1/oauth/token", "https://api.anthropic.com/v1/oauth/token" }
M.SCOPES = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
M.CALLBACK_PORT = 54545
M.LOOPBACK_REDIRECT = "http://localhost:54545/callback"
-- Shows `code#state` on a page for the user to paste back.
M.MANUAL_REDIRECT = "https://platform.claude.com/oauth/code/callback"
M.API = "https://api.anthropic.com/api/oauth"
M.BETA = "oauth-2025-04-20"
M.USER_AGENT = "claude-cli/2.1.285 (external, cli)"

export type Tokens = {
	access: string,
	refresh: string?,
	-- Epoch milliseconds.
	expires: number?,
	scopes: { string }?,
	account_uuid: string?,
	email: string?,
	org_uuid: string?,
	org_name: string?,
	-- ChatGPT only: the OpenID token Codex keeps beside the access token.
	id_token: string?,
}

export type Pkce = { verifier: string, challenge: string, state: string }

-- PKCE material from 64 random bytes: 48 for the verifier, 16 for the state.
function M.pkce(random: string): Pkce
	assert(#random >= 64, "pkce needs 64 random bytes")
	local verifier = crypto.base64url(string.sub(random, 1, 48))
	return {
		verifier = verifier,
		challenge = crypto.base64url(crypto.sha256(verifier)),
		state = crypto.hex(string.sub(random, 49, 64)),
	}
end

function M.authorize_url(p: Pkce, redirect: string): string
	local q = {
		{ "code", "true" },
		{ "client_id", M.CLIENT_ID },
		{ "response_type", "code" },
		{ "redirect_uri", redirect },
		{ "scope", M.SCOPES },
		{ "code_challenge", p.challenge },
		{ "code_challenge_method", "S256" },
		{ "state", p.state },
	}
	local parts = table.create(#q)
	for i, kv in q do
		parts[i] = kv[1] .. "=" .. crypto.urlencode(kv[2])
	end
	return M.AUTHORIZE_URL .. "?" .. table.concat(parts, "&")
end

-- What the user pasted (`code#state`, a redirect URL with `?code=…&state=…`, or a bare code)
-- as code and state. Nil when no code is in it.
function M.parse_pasted(text: string): (string?, string?)
	local t = string.match(text, "^%s*(.-)%s*$") or ""
	if t == "" then
		return nil, nil
	end
	local query = string.match(t, "%?([^#]*)")
	if query then
		local q = crypto.parse_query(query)
		if q.code and q.code ~= "" then
			return q.code, q.state
		end
		return nil, nil
	end
	local code, state = string.match(t, "^([^#%s]+)#([^#%s]+)$")
	if code then
		return code, state
	end
	if string.match(t, "^[%w%-%._~]+$") then
		return t, nil
	end
	return nil, nil
end

-- The code and state from a raw HTTP request (`GET /callback?code=…&state=… HTTP/1.1`).
function M.parse_callback_request(raw: string): (string?, string?, string?)
	local target = string.match(raw, "^%u+ (%S+) HTTP")
	if not target then
		return nil, nil, nil
	end
	local query = string.match(target, "%?(.*)$") or ""
	local q = crypto.parse_query(query)
	return q.code, q.state, q.error_description or q.error
end

local function token_from(body: any, previous: Tokens?): Tokens?
	if type(body) ~= "table" or type(body.access_token) ~= "string" then
		return nil
	end
	local account = if type(body.account) == "table" then body.account else {}
	local org = if type(body.organization) == "table" then body.organization else {}
	local expires_in = if type(body.expires_in) == "number" then body.expires_in else nil
	local scopes: { string }? = nil
	if type(body.scope) == "string" then
		local list: { string } = {}
		for s in string.gmatch(body.scope, "%S+") do
			table.insert(list, s)
		end
		scopes = list
	end
	return {
		access = body.access_token,
		-- Refresh tokens rotate; keep the old one only when the server sent none.
		refresh = if type(body.refresh_token) == "string" then body.refresh_token elseif previous then previous.refresh else nil,
		expires = if expires_in then os.time() * 1000 + expires_in * 1000 else nil,
		scopes = scopes or (if previous then previous.scopes else nil),
		account_uuid = account.uuid or (if previous then previous.account_uuid else nil),
		email = account.email_address or account.email or (if previous then previous.email else nil),
		org_uuid = org.uuid or (if previous then previous.org_uuid else nil),
		org_name = org.name or (if previous then previous.org_name else nil),
	}
end
M.token_from = token_from

-- Error text of a failed OAuth/API response.
function M.describe(r: FetchResult): string
	if r.error then
		return if r.timed_out then "Request timed out" else "Network error: " .. r.error
	end
	local ok, body = pcall(tern.json.decode, r.body)
	local detail: string? = nil
	if ok and type(body) == "table" then
		if type(body.error) == "table" then
			detail = body.error.message or body.error.type
		elseif type(body.error) == "string" then
			detail = body.error_description or body.error
		end
	end
	return "HTTP " .. r.status .. (if detail then ": " .. tostring(detail) else "")
end

-- POSTs `body` to the token endpoints in order, moving on after network errors, 403/404 and 5xx.
local function post_token(body: { [string]: any }, headers: { [string]: string }, previous: Tokens?, cb: (Tokens?, string?, boolean?) -> ())
	local encoded = tern.json.encode(body)
	local i = 0
	local last_err = "No token endpoint available"
	local function attempt()
		i += 1
		local url = M.TOKEN_URLS[i]
		if not url then
			cb(nil, last_err, false)
			return
		end
		local h: { [string]: string } = { ["Content-Type"] = "application/json", Accept = "application/json" }
		for k, v in headers do
			h[k] = v
		end
		tern.fetch(url, { method = "POST", headers = h, body = encoded, timeout_ms = 60000 }, function(r)
			if not r.error and r.status >= 200 and r.status < 300 then
				local ok, decoded = pcall(tern.json.decode, r.body)
				local tokens = if ok then token_from(decoded, previous) else nil
				if tokens then
					cb(tokens, nil, nil)
				else
					cb(nil, "Token response could not be parsed", false)
				end
				return
			end
			last_err = M.describe(r)
			-- 400/401 is a definitive answer (bad code, expired or reused refresh token).
			local definitive = not r.error and (r.status == 400 or r.status == 401)
			if definitive then
				cb(nil, last_err, true)
			else
				attempt()
			end
		end)
	end
	attempt()
end

-- Exchanges an authorization code. `cb(tokens, err)`.
function M.exchange(code: string, state: string, p: Pkce, redirect: string, cb: (Tokens?, string?) -> ())
	post_token({
		grant_type = "authorization_code",
		client_id = M.CLIENT_ID,
		code = code,
		redirect_uri = redirect,
		code_verifier = p.verifier,
		state = state,
	}, {}, nil, function(t, err)
		cb(t, err)
	end)
end

-- Refreshes `tokens`. `cb(new, err, invalid)`: `invalid` is true when the server rejected the
-- refresh token itself (re-login needed), not a transient failure.
function M.refresh(tokens: Tokens, cb: (Tokens?, string?, boolean?) -> ())
	if not tokens.refresh then
		cb(nil, "No refresh token", true)
		return
	end
	post_token({
		grant_type = "refresh_token",
		client_id = M.CLIENT_ID,
		refresh_token = tokens.refresh,
	}, { ["anthropic-beta"] = M.BETA }, tokens, cb)
end

local function api_headers(access: string): { [string]: string }
	return {
		Authorization = "Bearer " .. access,
		["anthropic-beta"] = M.BETA,
		Accept = "application/json",
		["Content-Type"] = "application/json",
		["User-Agent"] = M.USER_AGENT,
	}
end

-- GET `/api/oauth/<path>`; `cb(result, decoded_body_or_nil)`.
function M.get(path: string, access: string, cb: (FetchResult, any) -> ())
	tern.fetch(M.API .. path, { headers = api_headers(access), timeout_ms = 20000 }, function(r)
		local body: any = nil
		if not r.error and r.status >= 200 and r.status < 300 then
			local ok, decoded = pcall(tern.json.decode, r.body)
			body = if ok then decoded else nil
		end
		cb(r, body)
	end)
end

-- Seconds to wait from a `Retry-After` header (seconds or an HTTP date), or nil.
function M.retry_after(headers: { [string]: string }): number?
	local v = headers["retry-after"]
	if not v then
		return nil
	end
	local n = tonumber(v)
	if n then
		return math.max(0, n)
	end
	return nil
end

-- Account fields of a `/api/oauth/profile` body.
export type Profile = {
	email: string?,
	name: string?,
	account_uuid: string?,
	org_uuid: string?,
	org_name: string?,
	tier: string?,
	org_type: string?,
	billing: string?,
	status: string?,
}

function M.profile_from(body: any): Profile?
	if type(body) ~= "table" then
		return nil
	end
	local account = if type(body.account) == "table" then body.account else body
	local org = if type(body.organization) == "table" then body.organization else {}
	return {
		email = account.email or account.email_address,
		name = account.display_name or account.full_name,
		account_uuid = account.uuid,
		org_uuid = org.uuid,
		org_name = org.name,
		tier = org.rate_limit_tier,
		org_type = org.organization_type,
		billing = org.billing_type or body.billing_type,
		status = org.subscription_status or body.subscription_status,
	}
end

return M
