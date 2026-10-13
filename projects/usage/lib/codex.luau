--!strict
-- ChatGPT subscription (Codex) access: JWT claims of the OAuth tokens, the PKCE login and token
-- refresh against auth.openai.com (the public Codex CLI client), and `GET /backend-api/wham/usage`.
--
-- Token fields map onto the shared `oauth.Tokens`: `account_uuid` is the ChatGPT user id,
-- `org_uuid` the ChatGPT account (workspace) id the usage request names in `ChatGPT-Account-Id`.

local crypto = require("./crypto")
local oauth = require("./oauth")

local M = {}

M.CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
M.TOKEN_URL = "https://auth.openai.com/oauth/token"
M.USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
M.SCOPE = "openid profile email"
M.USER_AGENT = "codex_cli_rs/0.142.5"
M.ORIGINATOR = "codex_cli_rs"
M.AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize"
-- The client only accepts this redirect; there is no page that shows the code for pasting.
M.CALLBACK_PORT = 1455
M.REDIRECT = "http://localhost:1455/auth/callback"
M.LOGIN_SCOPE = "openid profile email offline_access"

local AUTH_CLAIM = "https://api.openai.com/auth"
local PROFILE_CLAIM = "https://api.openai.com/profile"

-- The payload of a JWT, or nil when `jwt` isn't one.
function M.claims(jwt: string?): { [string]: any }?
	if type(jwt) ~= "string" then
		return nil
	end
	local segment = string.match(jwt, "^[^.]+%.([^.]+)%.")
	if not segment then
		return nil
	end
	local raw = crypto.base64url_decode(segment)
	if not raw then
		return nil
	end
	local ok, doc = pcall(tern.json.decode, raw)
	return if ok and type(doc) == "table" then doc else nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- Tokens from the raw strings Codex and omp store, with expiry, user, account and email read from
-- the JWTs. `account_id` (Codex's `tokens.account_id`, omp's `accountId`) wins over the claim.
function M.tokens(access: string, refresh: string?, id_token: string?, account_id: string?): oauth.Tokens
	local a = M.claims(access) or {}
	local i = M.claims(id_token) or {}
	local auth = if type(a[AUTH_CLAIM]) == "table" then a[AUTH_CLAIM] elseif type(i[AUTH_CLAIM]) == "table" then i[AUTH_CLAIM] else {}
	local profile = if type(a[PROFILE_CLAIM]) == "table" then a[PROFILE_CLAIM] else {}
	return {
		access = access,
		refresh = refresh,
		id_token = id_token,
		expires = if type(a.exp) == "number" then a.exp * 1000 else nil,
		account_uuid = str(auth.chatgpt_user_id) or str(auth.user_id),
		org_uuid = account_id or str(auth.chatgpt_account_id),
		email = str(profile.email) or str(i.email),
	}
end

-- The plan type (`plus`, `pro`, `prolite`, …) the tokens were issued for.
function M.plan_claim(t: oauth.Tokens): string?
	for _, jwt in { t.id_token, t.access } do
		local c = M.claims(jwt)
		if c and type(c[AUTH_CLAIM]) == "table" then
			local plan = str(c[AUTH_CLAIM].chatgpt_plan_type)
			if plan then
				return plan
			end
		end
	end
	return nil
end

-- Refreshes `t`. `cb(new, err, invalid)`: `invalid` is true when the server rejected the refresh
-- token itself (expired, reused or revoked: re-login needed), not a transient failure.
function M.refresh(t: oauth.Tokens, cb: (oauth.Tokens?, string?, boolean?) -> ())
	if not t.refresh then
		cb(nil, "No refresh token", true)
		return
	end
	local body = tern.json.encode({
		client_id = M.CLIENT_ID,
		grant_type = "refresh_token",
		refresh_token = t.refresh,
		scope = M.SCOPE,
	})
	local headers = { ["Content-Type"] = "application/json", Accept = "application/json", ["User-Agent"] = M.USER_AGENT }
	tern.fetch(M.TOKEN_URL, { method = "POST", headers = headers, body = body, timeout_ms = 60000 }, function(r)
		if not r.error and r.status >= 200 and r.status < 300 then
			local ok, decoded = pcall(tern.json.decode, r.body)
			local access = if ok and type(decoded) == "table" then str(decoded.access_token) else nil
			if not access then
				cb(nil, "Token response could not be parsed", false)
				return
			end
			-- Refresh tokens rotate; keep the old ones only when the server sent none.
			local new = M.tokens(access :: string, str(decoded.refresh_token) or t.refresh, str(decoded.id_token) or t.id_token, t.org_uuid)
			new.email = new.email or t.email
			new.account_uuid = new.account_uuid or t.account_uuid
			cb(new, nil, nil)
			return
		end
		cb(nil, oauth.describe(r), not r.error and (r.status == 400 or r.status == 401))
	end)
end

-- The authorize page of a Codex-style login; `prompt=login` lets the user pick another account
-- than the one the browser is signed in to.
function M.authorize_url(p: oauth.Pkce, redirect: string): string
	local q = {
		{ "response_type", "code" },
		{ "client_id", M.CLIENT_ID },
		{ "redirect_uri", redirect },
		{ "scope", M.LOGIN_SCOPE },
		{ "code_challenge", p.challenge },
		{ "code_challenge_method", "S256" },
		{ "id_token_add_organizations", "true" },
		{ "codex_cli_simplified_flow", "true" },
		{ "state", p.state },
		{ "originator", M.ORIGINATOR },
		{ "prompt", "login" },
	}
	local parts = table.create(#q)
	for i, kv in q do
		parts[i] = kv[1] .. "=" .. crypto.urlencode(kv[2])
	end
	return M.AUTHORIZE_URL .. "?" .. table.concat(parts, "&")
end

-- Exchanges an authorization code (form-encoded, as the Codex CLI does). `cb(tokens, err)`.
function M.exchange(code: string, p: oauth.Pkce, redirect: string, cb: (oauth.Tokens?, string?) -> ())
	local fields = {
		{ "grant_type", "authorization_code" },
		{ "code", code },
		{ "redirect_uri", redirect },
		{ "client_id", M.CLIENT_ID },
		{ "code_verifier", p.verifier },
	}
	local parts = table.create(#fields)
	for i, kv in fields do
		parts[i] = kv[1] .. "=" .. crypto.urlencode(kv[2])
	end
	local headers = { ["Content-Type"] = "application/x-www-form-urlencoded", Accept = "application/json", ["User-Agent"] = M.USER_AGENT }
	tern.fetch(M.TOKEN_URL, { method = "POST", headers = headers, body = table.concat(parts, "&"), timeout_ms = 60000 }, function(r)
		if r.error or r.status < 200 or r.status >= 300 then
			cb(nil, oauth.describe(r))
			return
		end
		local ok, decoded = pcall(tern.json.decode, r.body)
		local access = if ok and type(decoded) == "table" then str(decoded.access_token) else nil
		if not access then
			cb(nil, "Token response could not be parsed")
			return
		end
		local t = M.tokens(access :: string, str(decoded.refresh_token), str(decoded.id_token), nil)
		if t.expires == nil and type(decoded.expires_in) == "number" then
			t.expires = os.time() * 1000 + decoded.expires_in * 1000
		end
		cb(t, nil)
	end)
end

-- GET the usage of the ChatGPT account `account_id`; `cb(result, decoded_body_or_nil)`.
function M.usage(access: string, account_id: string?, cb: (FetchResult, any) -> ())
	local headers: { [string]: string } = {
		Authorization = "Bearer " .. access,
		Accept = "application/json",
		["User-Agent"] = M.USER_AGENT,
		originator = M.ORIGINATOR,
	}
	if account_id then
		headers["ChatGPT-Account-Id"] = account_id
	end
	tern.fetch(M.USAGE_URL, { headers = headers, timeout_ms = 20000 }, function(r)
		local body: any = nil
		if not r.error and r.status >= 200 and r.status < 300 then
			local ok, decoded = pcall(tern.json.decode, r.body)
			body = if ok then decoded else nil
		end
		cb(r, body)
	end)
end

return M
