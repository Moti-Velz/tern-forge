--!strict
-- Normalizes Claude's `GET /api/oauth/usage` and ChatGPT's `GET /backend-api/wham/usage` payloads
-- into a list of quota windows plus extra-usage spend or credits.
--
-- Payload facts (see README): `utilization`/`percent` are 0–100, `resets_at` is ISO-8601 or null.
-- `five_hour`/`seven_day` are the legacy buckets; `limits[]` carries the same windows plus
-- model-scoped weekly caps (`kind = "weekly_scoped"`, `scope.model.display_name`). Unknown
-- codename buckets (`iguana_necktie`, …) carry dollar limits and are shown generically.

local time = require("./time")

local M = {}

local HOUR = 3600
M.HOUR = HOUR
M.WEEK = 7 * 24 * HOUR

export type Window = {
	id: string,
	label: string,
	-- "session" | "weekly" | "scoped" | "other"
	kind: string,
	-- 0–100, nil when the server reports none.
	pct: number?,
	-- Epoch seconds.
	resets_at: number?,
	-- Window length in seconds when known (pace needs it).
	duration: number?,
	-- `limits[].severity` ("normal", "warning", "critical", …) when reported.
	severity: string?,
	-- Whether this is the limit currently binding (`limits[].is_active`).
	active: boolean?,
	-- Dollar buckets: `limit_dollars` / `used_dollars` / `remaining_dollars`.
	dollars: { used: number?, limit: number?, remaining: number? }?,
	locked: string?,
	-- Label-column text when the label doesn't shorten by the Claude rules.
	short: string?,
}

export type Extra = {
	enabled: boolean,
	used: number?,
	limit: number?,
	currency: string,
	pct: number?,
	reason: string?,
}

-- ChatGPT credits: shown only when the account has some or is unlimited.
export type Credits = {
	balance: number?,
	unlimited: boolean,
}

export type Usage = {
	windows: { Window },
	extra: Extra?,
	credits: Credits?,
	-- Plan label the payload itself reports (ChatGPT `plan_type`).
	plan: string?,
}

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function clamp_pct(v: number?): number?
	if v == nil then
		return nil
	end
	return math.clamp(v, 0, 100)
end

local function bucket(raw: any): (number?, number?)
	if type(raw) ~= "table" then
		return nil, nil
	end
	local pct, resets = clamp_pct(num(raw.utilization)), time.parse_iso(raw.resets_at)
	return pct, resets
end

local function scoped_name(scope: any): string?
	if type(scope) ~= "table" or type(scope.model) ~= "table" then
		return nil
	end
	return str(scope.model.display_name)
end

local KNOWN = {
	five_hour = true,
	seven_day = true,
	seven_day_opus = true,
	seven_day_sonnet = true,
	seven_day_oauth_apps = true,
	seven_day_cowork = true,
	limits = true,
	spend = true,
	extra_usage = true,
	seven_day_breakdown = true,
	member_dashboard_available = true,
}

local LEGACY_WEEKLY = {
	{ key = "seven_day_opus", id = "7d:opus", label = "7 days · Opus" },
	{ key = "seven_day_sonnet", id = "7d:sonnet", label = "7 days · Sonnet" },
	{ key = "seven_day_oauth_apps", id = "7d:oauth", label = "7 days · OAuth apps" },
	{ key = "seven_day_cowork", id = "7d:cowork", label = "7 days · Cowork" },
}

local function money(amount: any, exponent: any): number?
	local a, e = num(amount), num(exponent)
	if a == nil then
		return nil
	end
	return a / 10 ^ (e or 2)
end

local function parse_extra(payload: any): Extra?
	local spend = payload.spend
	if type(spend) == "table" then
		local used = if type(spend.used) == "table" then money(spend.used.amount_minor, spend.used.exponent) else nil
		local limit = if type(spend.limit) == "table" then money(spend.limit.amount_minor, spend.limit.exponent) else nil
		local currency = (if type(spend.used) == "table" then str(spend.used.currency) else nil) or "USD"
		local pct = num(spend.percent)
		if pct == nil and used and limit and limit > 0 then
			pct = used / limit * 100
		end
		return {
			enabled = spend.enabled == true,
			used = used,
			limit = if limit and limit > 0 then limit else nil,
			currency = currency,
			pct = clamp_pct(pct),
			reason = str(spend.disabled_reason)
				or (if type(payload.extra_usage) == "table" and payload.extra_usage.user_disabled == true then "user_disabled" else nil),
		}
	end
	local ex = payload.extra_usage
	if type(ex) == "table" then
		local places = num(ex.decimal_places) or 2
		local used, limit = money(ex.used_credits, places), money(ex.monthly_limit, places)
		local pct = num(ex.utilization)
		if pct == nil and used and limit and limit > 0 then
			pct = used / limit * 100
		end
		local reason = str(ex.disabled_reason)
		if reason == nil and ex.user_disabled == true then
			reason = "user_disabled"
		end
		return {
			enabled = ex.is_enabled == true,
			used = used,
			limit = if limit and limit > 0 then limit else nil,
			currency = str(ex.currency) or "USD",
			pct = clamp_pct(pct),
			reason = reason,
		}
	end
	return nil
end

-- The windows and spend of one usage payload. Nil when `payload` isn't a usage body.
function M.parse(payload: any): Usage?
	if type(payload) ~= "table" then
		return nil
	end
	if payload.five_hour == nil and payload.seven_day == nil and payload.limits == nil and payload.spend == nil and payload.extra_usage == nil then
		return nil
	end
	local windows: { Window } = {}
	local limits: { any } = if type(payload.limits) == "table" then payload.limits else {}

	local function find_limit(kind: string): any
		for _, l in limits do
			if type(l) == "table" and l.kind == kind then
				return l
			end
		end
		return nil
	end

	local function add_main(id: string, label: string, key: string, kind: string, group: string, duration: number)
		local pct, resets = bucket(payload[key])
		local l = find_limit(kind)
		if pct == nil and resets == nil and l then
			pct, resets = clamp_pct(num(l.percent)), time.parse_iso(l.resets_at)
		end
		if pct == nil and resets == nil and l == nil and payload[key] == nil then
			return
		end
		table.insert(windows, {
			id = id,
			label = label,
			kind = group,
			pct = pct,
			resets_at = resets,
			duration = duration,
			severity = if l then str(l.severity) else nil,
			active = if l then l.is_active == true else nil,
		})
	end

	add_main("5h", "5 hours", "five_hour", "session", "session", 5 * HOUR)
	add_main("7d", "7 days · All models", "seven_day", "weekly_all", "weekly", M.WEEK)

	local seen: { [string]: boolean } = {}
	for _, spec in LEGACY_WEEKLY do
		local pct, resets = bucket(payload[spec.key])
		if pct ~= nil or resets ~= nil then
			table.insert(windows, { id = spec.id, label = spec.label, kind = "scoped", pct = pct, resets_at = resets, duration = M.WEEK })
			seen[string.lower(string.match(spec.label, "· (.+)$") or "")] = true
		end
	end

	for i, l in limits do
		if type(l) ~= "table" or type(l.kind) ~= "string" or l.kind == "session" or l.kind == "weekly_all" then
			continue
		end
		local pct, resets = clamp_pct(num(l.percent)), time.parse_iso(l.resets_at)
		if pct == nil and resets == nil then
			continue
		end
		local name = scoped_name(l.scope)
		if l.kind == "weekly_scoped" then
			local label = name or "Model-specific"
			if seen[string.lower(label)] then
				continue
			end
			seen[string.lower(label)] = true
			table.insert(windows, {
				id = "7d:" .. string.lower(label),
				label = "7 days · " .. label,
				kind = "scoped",
				pct = pct,
				resets_at = resets,
				duration = M.WEEK,
				severity = str(l.severity),
				active = l.is_active == true,
			})
		else
			table.insert(windows, {
				id = "limit:" .. l.kind .. ":" .. i,
				label = l.kind .. (if name then " · " .. name else ""),
				kind = "other",
				pct = pct,
				resets_at = resets,
				severity = str(l.severity),
				active = l.is_active == true,
			})
		end
	end

	-- Codename buckets: any other object shaped like a bucket.
	local others: { string } = {}
	for key, value in payload do
		if type(key) == "string" and not KNOWN[key] and type(value) == "table" and (value.utilization ~= nil or value.limit_dollars ~= nil) then
			table.insert(others, key)
		end
	end
	table.sort(others)
	for _, key in others do
		local raw = payload[key]
		local pct, resets = bucket(raw)
		local limit = num(raw.limit_dollars)
		table.insert(windows, {
			id = "bucket:" .. key,
			label = "Other quota · " .. key,
			kind = "other",
			pct = pct,
			resets_at = resets,
			dollars = if limit or num(raw.used_dollars)
				then { used = num(raw.used_dollars), limit = limit, remaining = num(raw.remaining_dollars) }
				else nil,
			locked = str(raw.locked_reason),
		})
	end

	return { windows = windows, extra = parse_extra(payload) }
end

-- `5h`, `7d`, `90m`: a window length for the label column.
local function span_text(seconds: number): string
	if seconds % 86400 == 0 then
		return string.format("%dd", seconds // 86400)
	elseif seconds % HOUR == 0 then
		return string.format("%dh", seconds // HOUR)
	end
	return string.format("%dm", math.max(1, seconds // 60))
end

local SPAN_LABEL = { [5 * HOUR] = "5 hours", [M.WEEK] = "7 days" }

-- The windows of one wham `rate_limit` object (`primary_window`, `secondary_window`). Which slot
-- holds which length varies by plan (free and some paid plans only have a 7-day primary), so
-- windows are named by `limit_window_seconds` and listed shortest first.
local function codex_windows(rate: any, now: number, group: string?): { Window }
	local out: { Window } = {}
	if type(rate) ~= "table" then
		return out
	end
	for _, slot in { "primary_window", "secondary_window" } do
		local w = rate[slot]
		if type(w) ~= "table" then
			continue
		end
		local pct = clamp_pct(num(w.used_percent))
		local resets = num(w.reset_at) or (if num(w.reset_after_seconds) then now + (w.reset_after_seconds :: number) else nil)
		local seconds = num(w.limit_window_seconds)
		if pct == nil and resets == nil then
			continue
		end
		local span = if seconds then span_text(seconds) else slot
		local label = if seconds and SPAN_LABEL[seconds] then SPAN_LABEL[seconds] else span
		local main = group == nil and (seconds == 5 * HOUR or seconds == M.WEEK)
		table.insert(out, {
			id = if group then group .. ":" .. span else span,
			label = if group then label .. " · " .. group else label,
			kind = if main and seconds == 5 * HOUR then "session" elseif main then "weekly" elseif group then "scoped" else "other",
			pct = pct,
			resets_at = resets,
			duration = seconds,
			short = if group then span .. " " .. group else span,
		})
	end
	table.sort(out, function(a, b)
		return (a.duration or math.huge) < (b.duration or math.huge)
	end)
	return out
end

local CODEX_PLANS = {
	free = "Free",
	go = "Go",
	plus = "Plus",
	pro = "Pro",
	prolite = "Pro Lite",
	team = "Team",
	business = "Business",
	enterprise = "Enterprise",
	edu = "Edu",
}

-- Plan label of a ChatGPT `plan_type`.
function M.codex_plan(plan_type: string?): string?
	if plan_type == nil or plan_type == "" then
		return nil
	end
	local p = plan_type :: string
	return CODEX_PLANS[p] or (string.upper(string.sub(p, 1, 1)) .. string.sub(p, 2))
end

-- The windows and credits of one wham/usage payload; `now` resolves relative resets. Nil when
-- `payload` isn't a usage body.
function M.parse_codex(payload: any, now: number): Usage?
	if type(payload) ~= "table" or (payload.rate_limit == nil and payload.plan_type == nil and payload.credits == nil) then
		return nil
	end
	local windows = codex_windows(payload.rate_limit, now, nil)
	for _, w in codex_windows(payload.code_review_rate_limit, now, "Review") do
		table.insert(windows, w)
	end
	if type(payload.additional_rate_limits) == "table" then
		for _, extra in payload.additional_rate_limits do
			if type(extra) == "table" then
				local name = str(extra.limit_name) or str(extra.metered_feature) or "Other"
				for _, w in codex_windows(extra.rate_limit, now, name) do
					table.insert(windows, w)
				end
			end
		end
	end
	local credits: Credits? = nil
	local c = payload.credits
	if type(c) == "table" then
		local balance = num(c.balance) or (if type(c.balance) == "string" then tonumber(c.balance) else nil)
		if c.unlimited == true or c.has_credits == true or (balance and balance > 0) then
			credits = { balance = balance, unlimited = c.unlimited == true }
		end
	end
	return { windows = windows, credits = credits, plan = M.codex_plan(str(payload.plan_type)) }
end

export type Pace = {
	-- Fraction of the window already elapsed, 0–1.
	elapsed: number,
	-- Projected utilization at reset at the current average rate (may exceed 100).
	projected: number?,
	-- Seconds from now until 100% at the current average rate, when that is before the reset.
	exhaust_in: number?,
	-- Usage minus the even-pace share of the window (positive = ahead of pace).
	delta: number,
}

-- How the window's usage compares with spending it evenly until `resets_at`.
function M.pace(w: Window, now: number): Pace?
	if w.pct == nil or w.resets_at == nil or w.duration == nil then
		return nil
	end
	local duration = w.duration :: number
	local remaining = math.max(0, (w.resets_at :: number) - now)
	local spent = duration - remaining
	if spent <= 0 or remaining > duration then
		return nil
	end
	local pct = w.pct :: number
	local elapsed = spent / duration
	local rate = pct / spent
	local out: Pace = { elapsed = elapsed, delta = pct - elapsed * 100, projected = nil, exhaust_in = nil }
	if pct > 0 then
		out.projected = pct + rate * remaining
		if pct < 100 then
			local t = (100 - pct) / rate
			if t < remaining then
				out.exhaust_in = t
			end
		end
	end
	return out
end

-- Tone of a utilization percent: success below 60, warning below 85, else error.
function M.tone(pct: number?): string
	if pct == nil then
		return "muted"
	elseif pct >= 85 then
		return "error"
	elseif pct >= 60 then
		return "warning"
	end
	return "success"
end

-- Plan label from a rate-limit tier or subscription type.
local TIERS = {
	default_claude_free = "Free",
	default_claude_ai = "Pro",
	default_claude_max_5x = "Max 5x",
	default_claude_max_20x = "Max 20x",
}
function M.plan(tier: string?, subscription: string?, org_type: string?): string?
	if tier and TIERS[tier] then
		return TIERS[tier]
	end
	local s = subscription or org_type
	if s == nil then
		return nil
	end
	s = string.gsub(s, "^claude_", "")
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

return M
