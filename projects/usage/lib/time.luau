--!strict
-- Wall-clock helpers: ISO-8601 parsing to epoch seconds, and Chinese duration text.

local M = {}

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
local function days_from_civil(y: number, m: number, d: number): number
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- Epoch seconds of an ISO-8601 timestamp (`2026-10-03T04:10:00.135558+00:00`, `…Z`); a missing
-- offset counts as UTC. Nil for anything else.
function M.parse_iso(text: any): number?
	if type(text) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s, rest = string.match(text, "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	local frac = 0
	local f = string.match(rest :: string, "^%.(%d+)")
	if f then
		frac = (tonumber("0." .. f) :: number)
		rest = string.sub(rest :: string, #f + 2)
	end
	local offset = 0
	if rest ~= "" and rest ~= "Z" and rest ~= "z" then
		local sign, oh, om = string.match(rest :: string, "^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = ((tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60) * (if sign == "-" then -1 else 1)
	end
	local days = days_from_civil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number) + frac - offset
end

-- `2d 3h`, `3h 12m`, `12m`, `45s`: the two largest units of a non-negative duration.
function M.duration(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	local d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
	if d > 0 then
		return if h > 0 then string.format("%dd %dh", d, h) else string.format("%dd", d)
	elseif h > 0 then
		return if m > 0 then string.format("%dh %dm", h, m) else string.format("%dh", h)
	elseif m > 0 then
		return string.format("%dm", m)
	end
	return string.format("%ds", s)
end

-- Compact form for the status line: `2d3h`, `3h12m`, `12m`.
function M.short(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	local d, h, m = s // 86400, s % 86400 // 3600, s % 3600 // 60
	if d > 0 then
		return string.format("%dd%dh", d, h)
	elseif h > 0 then
		return string.format("%dh%02dm", h, m)
	end
	return string.format("%dm", math.max(m, if s > 0 then 1 else 0))
end

-- Local wall-clock label of epoch `t` relative to `now`: `14:10`, `tomorrow 09:00`, `Wed 20:00`, `10/12 20:00`.
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
function M.clock(t: number, now: number): string
	local hm = os.date("%H:%M", math.floor(t)) :: string
	local day = os.date("*t", math.floor(t)) :: any
	local today = os.date("*t", math.floor(now)) :: any
	local delta_days = math.floor((os.time({ year = day.year, month = day.month, day = day.day, hour = 12 }) - os.time({ year = today.year, month = today.month, day = today.day, hour = 12 })) / 86400 + 0.5)
	if delta_days == 0 then
		return hm
	elseif delta_days == 1 then
		return "tomorrow " .. hm
	elseif delta_days > 1 and delta_days < 7 then
		return WEEKDAYS[day.wday] .. " " .. hm
	end
	return string.format("%d/%d %s", day.month, day.day, hm)
end

return M
