--!strict
-- Interactive OAuth login for a block, Claude or ChatGPT: PKCE, a one-shot loopback listener
-- (`nc -l <port>`) that catches the browser redirect, and a paste fallback (`code#state` or the
-- redirect URL from the address bar).

local codex = require("./codex")
local creds = require("./creds")
local oauth = require("./oauth")

local M = {}

-- Per provider: the loopback port and redirect, the redirect used when the port is taken (nil
-- when the provider has none: the user then pastes the address-bar URL of the failed loopback
-- page), the authorize page and the code exchange.
type Spec = {
	name: string,
	port: number,
	loopback: string,
	manual: string?,
	authorize: (oauth.Pkce, string) -> string,
	exchange: (code: string, state: string, p: oauth.Pkce, redirect: string, cb: (oauth.Tokens?, string?) -> ()) -> (),
}

local SPECS: { [string]: Spec } = {
	claude = {
		name = "Claude",
		port = oauth.CALLBACK_PORT,
		loopback = oauth.LOOPBACK_REDIRECT,
		manual = oauth.MANUAL_REDIRECT,
		authorize = oauth.authorize_url,
		exchange = oauth.exchange,
	},
	gpt = {
		name = "ChatGPT",
		port = codex.CALLBACK_PORT,
		loopback = codex.REDIRECT,
		manual = nil,
		authorize = codex.authorize_url,
		exchange = function(code, _state, p, redirect, cb)
			codex.exchange(code, p, redirect, cb)
		end,
	},
}
M.NAME = { claude = SPECS.claude.name, gpt = SPECS.gpt.name } :: { [string]: string }

export type Flow = {
	-- "claude" | "gpt"
	provider: string,
	-- "starting" | "waiting" | "exchanging" | "error" | "done" | "cancelled"
	phase: string,
	url: string?,
	redirect: string?,
	pkce: oauth.Pkce?,
	-- Whether the loopback listener is up (the redirect lands here by itself).
	listening: boolean,
	input: string,
	error: string?,
	-- Ends a stale flow's callbacks.
	token: number,
	-- Runs whenever the flow changes.
	changed: () -> (),
	-- Runs with the stored account id after a successful login.
	finished: (string) -> (),
}

local RESPONSE = table.concat({
	"HTTP/1.1 200 OK",
	"Content-Type: text/html; charset=utf-8",
	"Connection: close",
	"",
	"<!doctype html><meta charset=utf-8><title>Subscription usage login</title>"
		.. "<body style='font-family:system-ui;padding:3em;text-align:center'>"
		.. "<h2>Authorization received</h2><p>You can close this page and return to Tern to view subscription usage.</p></body>",
}, "\r\n")

local seq = 0

local function open_browser(url: string, cx: BlockCx)
	local argv = if tern.runtime.os == "macos" then { "open", url } elseif tern.runtime.os == "linux" then { "xdg-open", url } else nil
	if argv then
		local ok = pcall(tern.process.run, argv, { timeout_ms = 10000 }, function(r)
			if r.status ~= 0 then
				cx:open(url)
			end
		end)
		if ok then
			return
		end
	end
	cx:open(url)
end
M.open_browser = open_browser

-- Releases a listener nobody will hit (cancel, or a paste won the race).
local function poke_listener(port: number)
	tern.fetch("http://localhost:" .. port .. "/cancel", { timeout_ms = 2000 }, function(_r) end)
end

local function live(flow: Flow, token: number): boolean
	return flow.token == token and flow.phase ~= "cancelled" and flow.phase ~= "done"
end

function M.submit_code(flow: Flow, code: string, state: string?)
	local p = flow.pkce
	if not p or flow.phase == "exchanging" or not live(flow, flow.token) then
		return
	end
	local pkce = p :: oauth.Pkce
	if state and state ~= pkce.state then
		flow.error = "state mismatch: use the authorization code returned by the page opened for this login"
		flow.changed()
		return
	end
	local spec = SPECS[flow.provider]
	flow.phase, flow.error = "exchanging", nil
	local token = flow.token
	flow.changed()
	spec.exchange(code, pkce.state, pkce, flow.redirect :: string, function(tokens, err)
		if flow.token ~= token or flow.phase ~= "exchanging" then
			return
		end
		if not tokens then
			flow.phase, flow.error = "waiting", "Token exchange failed: " .. tostring(err)
			flow.changed()
			return
		end
		if flow.listening then
			poke_listener(spec.port)
		end
		local id = creds.own_upsert(flow.provider, tokens :: oauth.Tokens)
		flow.phase = "done"
		flow.finished(id)
	end)
end

-- Handles pasted or typed text: submits it when it holds a code.
function M.submit_text(flow: Flow, text: string): boolean
	local code, state = oauth.parse_pasted(text)
	if not code then
		flow.error = "No authorization code found: paste the callback URL from the browser address bar" .. (if SPECS[flow.provider].manual then ", or the code#state shown on the page" else "")
		return false
	end
	M.submit_code(flow, code :: string, state)
	return true
end

-- What the login card tells the user to do while waiting.
function M.hint(flow: Flow): string
	if flow.listening then
		return "Completes automatically after browser authorization; if localhost won't open, paste the address bar URL"
	elseif SPECS[flow.provider].manual then
		return "After authorizing, copy the code#state from the page and paste it here (⌘V)"
	end
	return string.format("Port %d is in use (Codex may be signing in): after authorizing, the browser stops on an unreachable localhost page; paste its address bar URL here (⌘V)", SPECS[flow.provider].port)
end

-- Starts a `provider` login ("claude" | "gpt") and opens the authorize page in the browser.
function M.start(cx: BlockCx, provider: string, changed: () -> (), finished: (string) -> ()): Flow
	seq += 1
	local token = seq
	local spec = SPECS[provider] or SPECS.claude
	local flow: Flow = {
		provider = if SPECS[provider] then provider else "claude",
		phase = "starting",
		listening = false,
		input = "",
		token = token,
		changed = changed,
		finished = finished,
	}

	creds.random_bytes(function(random)
		if not live(flow, token) then
			return
		end
		local p = oauth.pkce(random)
		flow.pkce = p
		local listener_exited = false
		local ok = pcall(tern.process.run, { "nc", "-l", tostring(spec.port) }, { stdin = RESPONSE, timeout_ms = 600000 }, function(r)
			listener_exited = true
			flow.listening = false
			if not live(flow, token) or flow.redirect ~= spec.loopback then
				return
			end
			local code, state, err = oauth.parse_callback_request(r.stdout)
			if code then
				M.submit_code(flow, code :: string, state)
			elseif err then
				flow.error = "Authorization denied: " .. (err :: string)
				flow.changed()
			else
				flow.changed()
			end
		end)
		-- A bind failure (port taken, no nc) exits at once; give it a moment before choosing.
		tern.timer(400, function()
			if not live(flow, token) then
				return
			end
			flow.listening = ok and not listener_exited
			flow.redirect = if flow.listening then spec.loopback else spec.manual or spec.loopback
			flow.url = spec.authorize(p, flow.redirect :: string)
			flow.phase = "waiting"
			open_browser(flow.url :: string, cx)
			flow.changed()
		end)
	end)
	return flow
end

function M.cancel(flow: Flow)
	if flow.listening then
		poke_listener(SPECS[flow.provider].port)
	end
	flow.phase = "cancelled"
	flow.token = -1
end

return M
