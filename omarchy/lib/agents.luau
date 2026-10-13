--!strict
-- Desktop notifications for agent blocks, through Omarchy's notification daemon: when an agent
-- finishes (done or failed) or starts waiting for your input while you aren't looking at it.
-- Clicking the notification brings Tern forward on that pane (bin/focus-pane).

local hypr = require("./hypr")

local Agents = {}

-- How often agent states are sampled for "waiting for input" (finishes arrive as events).
local POLL_MS = 3000
-- The same pane and kind notify at most once in this window.
local QUIET_S = 10

local states: { [number]: string } = {}
local last_sent: { [string]: number } = {}
-- Tern's executable, for the click action's `tern focus` (filled in at start).
local tern_bin: string? = nil

local function project(path: string?): string
	if type(path) ~= "string" or path == "" then
		return "agent"
	end
	return string.match(path, "([^/]+)/*$") or path
end

-- The agent's last reply as one line of at most 160 characters, markup stripped.
local function gist(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	local s = string.gsub(string.gsub(text, "[%*_`#>]", ""), "%s+", " ")
	s = string.gsub(s, "^%s+", "")
	if utf8.len(s) and (utf8.len(s) :: number) > 160 then
		s = string.sub(s, 1, (utf8.offset(s, 160) :: number) - 1) .. "…"
	end
	return s
end

local function agent(cx: WindowCx, pane: number): AgentBlock?
	for _, a in cx.agents:list() do
		if a.pane == pane then
			return a
		end
	end
	return nil
end

local function send(cx: WindowCx, pane: number, kind: "done" | "failed" | "waiting")
	local key = tostring(pane) .. ":" .. kind
	local now = os.time()
	if last_sent[key] and now - last_sent[key] < QUIET_S then
		return
	end
	-- Not while you're looking: the pane focused in Tern and Tern the active Hyprland window.
	local focused = cx.session:focused() == pane
	hypr.active(function(window, c)
		if focused and window and window.class == hypr.TERN_CLASS then
			return
		end
		last_sent[key] = now
		local a = agent(c, pane)
		local info = c.session:pane(pane)
		local where = project((a and a.cwd) or (info and info.cwd))
		local headline = if kind == "waiting" then "Agent needs you · " .. where
			elseif kind == "failed" then "Agent failed · " .. where
			else "Agent done · " .. where
		local body = gist(a and a.last_message)
		if body == "" then
			body = if kind == "waiting" then "Waiting for your input" else "Turn finished"
		end
		local argv = {
			"omarchy-notification-send", "--app-name", "Tern",
			"-u", if kind == "done" then "low" else "normal",
			headline, body,
		}
		if tern_bin then
			for _, part in { "--exec", tern.plugin.dir .. "/bin/focus-pane", tern_bin, tostring(pane) } do
				table.insert(argv, part)
			end
		end
		tern.process.run(argv, { timeout_ms = 5000 }, function(r, _cx)
			if r.status ~= 0 then
				tern.log.warn("omarchy: notification failed", r.status, r.stderr)
			end
		end)
	end)
end

local function poll(cx: WindowCx)
	local seen: { [number]: boolean } = {}
	for _, a in cx.agents:list() do
		seen[a.pane] = true
		local before = states[a.pane]
		if a.state == "waiting_input" and before ~= nil and before ~= "waiting_input" then
			send(cx, a.pane, "waiting")
		end
		states[a.pane] = a.state
	end
	for pane in states do
		if not seen[pane] then
			states[pane] = nil
		end
	end
end

function Agents.start()
	-- The parent of this shell is Tern's window process; its executable is the `tern` to call back.
	tern.process.run({ "sh", "-c", 'readlink "/proc/$PPID/exe"' }, { timeout_ms = 2000 }, function(r, _cx)
		local path = string.match(r.stdout or "", "^%s*(.-)%s*$")
		if r.status == 0 and path and path ~= "" then
			tern_bin = path
		end
	end)
	tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
		if ev.result == "done" or ev.result == "failed" then
			send(cx, ev.pane, ev.result)
		end
	end)
	local function tick(cx: WindowCx?)
		if cx then
			poll(cx)
		end
		tern.timer(POLL_MS, tick)
	end
	tern.timer(POLL_MS, tick)
end

return Agents
