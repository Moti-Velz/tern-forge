--!strict
-- `hyprctl` from Tern's window process, which Hyprland started, so the compositor is found through
-- the inherited environment. Dispatchers are Hyprland Lua expressions (`hl.dsp.…`).

local Hypr = {}

Hypr.TERN_CLASS = "so.stencil.tern"

local function run(argv: { string }, done: ((ok: boolean, out: string, cx: WindowCx) -> ())?)
	tern.process.run(argv, { timeout_ms = 2000 }, function(r, cx)
		local ok = r.status == 0
		if not ok then
			tern.log.warn("omarchy: hyprctl failed", table.concat(argv, " "), r.status, r.stderr, r.stdout)
		end
		if done then
			done(ok, r.stdout, cx :: WindowCx)
		end
	end)
end

-- Runs a dispatcher, e.g. `hl.dsp.focus({ direction = "l" })`.
function Hypr.dispatch(expr: string)
	run({ "hyprctl", "dispatch", expr })
end

-- The active window as `hyprctl activewindow -j` reports it (class, size, …); nil when there is none.
function Hypr.active(done: (window: any?, cx: WindowCx) -> ())
	run({ "hyprctl", "activewindow", "-j" }, function(ok, out, cx)
		local parsed, window = pcall(tern.json.decode, out)
		done(if ok and parsed and type(window) == "table" then window else nil, cx)
	end)
end

return Hypr
