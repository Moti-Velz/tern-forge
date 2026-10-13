--!strict
-- Tells Hyprland this Tern window has the plugin running: every few seconds the current time goes
-- to $XDG_RUNTIME_DIR/tern-omarchy/<window pid>. hypr/tern-nav.lua hands keys to a Tern window only
-- while its file is fresh, so a window without the plugin (not linked, failed to load, another
-- config) keeps Omarchy's default keys instead of dead ones.

local Heartbeat = {}

local INTERVAL_MS = 2000

local dir = (tern.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/tern-omarchy"
local path: string? = nil

local function beat()
	if path == nil then
		return
	end
	local stamp = tostring(os.time())
	local ok = pcall(function()
		tern.fs.mkdir(dir)
		tern.fs.write(path :: string, stamp)
	end)
	if not ok then
		-- tern.fs may refuse paths outside its allowed places; a shell can always write there.
		tern.process.run({ "sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$3"', "sh", dir, stamp, path :: string },
			{ timeout_ms = 2000 }, function(r, _cx)
				if r.status ~= 0 then
					tern.log.warn("omarchy: heartbeat write failed", r.stderr)
				end
			end)
	end
end

function Heartbeat.start()
	-- The parent of this shell is Tern's window process: the pid Hyprland reports for the window.
	tern.process.run({ "sh", "-c", "echo $PPID" }, { timeout_ms = 2000 }, function(r, _cx)
		local pid = string.match(r.stdout or "", "%d+")
		if r.status == 0 and pid then
			path = dir .. "/" .. pid
			beat()
		end
	end)
	local function tick()
		beat()
		tern.timer(INTERVAL_MS, tick)
	end
	tern.timer(INTERVAL_MS, tick)
end

return Heartbeat
