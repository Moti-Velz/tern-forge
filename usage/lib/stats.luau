--!strict
-- Cross-account figures over the compact rows the poller publishes (one per account of a
-- provider): averages and spare capacity of the 5 h / 7 d windows, how many accounts are usable,
-- the one with the most headroom, the soonest recovery of a used-up account, and the status-line
-- pick. Pure: shared by the block view (host) and the status segment (window).

local M = {}

export type Win = { pct: number?, resets_at: number? }

export type Row = {
	id: string?,
	provider: string?,
	-- Full label (alias, else email) and short name (alias, else the email's local part).
	label: string?,
	name: string?,
	plan: string?,
	error: string?,
	pinned: boolean?,
	session: Win?,
	weekly: Win?,
	fetched_at: number?,
}

export type WinStats = {
	-- Accounts reporting this window.
	n: number,
	avg: number,
	min: number,
	max: number,
	-- Unused share summed over accounts, in whole windows (2.4 = 2.4 accounts' worth left).
	spare: number,
	-- Accounts at 100%.
	full: number,
}

export type Summary = {
	total: number,
	-- Accounts with 5 h / 7 d data.
	with_data: number,
	-- Accounts with data and no window at 100%.
	usable: number,
	errors: number,
	session: WinStats?,
	weekly: WinStats?,
	best: Row?,
	-- The used-up account that frees up first, and when.
	recover: Row?,
	recover_at: number?,
}

-- How close a row is to a limit: the higher of its 5 h / 7 d use. Nil without data.
function M.load(r: Row): number?
	local worst: number? = nil
	for _, w in { r.session, r.weekly } do
		if w and w.pct then
			worst = math.max(worst or 0, w.pct :: number)
		end
	end
	return worst
end

-- The account with the most headroom: lowest load among rows with data, not at 100% and without
-- an error; ties keep the earlier row.
function M.best(rows: { Row }): Row?
	local best: Row?, best_load = nil, math.huge
	for _, r in rows do
		local l = M.load(r)
		if l and l < 100 and not r.error and l < best_load then
			best, best_load = r, l
		end
	end
	return best
end

-- When a used-up row is usable again: the latest reset among its windows at 100%.
local function recovers_at(r: Row, now: number): number?
	local at: number? = nil
	for _, w in { r.session, r.weekly } do
		if w and (w.pct or 0) >= 100 then
			local t = w.resets_at
			if t == nil or t <= now then
				return nil
			end
			at = math.max(at or 0, t :: number)
		end
	end
	return at
end

local function window_stats(rows: { Row }, field: string): WinStats?
	local n, sum, lo, hi, spare, full = 0, 0, math.huge, -math.huge, 0, 0
	for _, r in rows do
		local w: Win? = (r :: any)[field]
		local pct = w and w.pct
		if pct then
			n += 1
			sum += pct
			lo, hi = math.min(lo, pct), math.max(hi, pct)
			spare += math.max(0, 100 - pct) / 100
			if pct >= 100 then
				full += 1
			end
		end
	end
	if n == 0 then
		return nil
	end
	return { n = n, avg = sum / n, min = lo, max = hi, spare = spare, full = full }
end

function M.summarize(rows: { Row }, now: number): Summary
	local s: Summary = {
		total = #rows,
		with_data = 0,
		usable = 0,
		errors = 0,
		session = window_stats(rows, "session"),
		weekly = window_stats(rows, "weekly"),
		best = M.best(rows),
	}
	for _, r in rows do
		if r.error then
			s.errors += 1
		end
		local l = M.load(r)
		if l then
			s.with_data += 1
			if l < 100 then
				s.usable += 1
			else
				local at = recovers_at(r, now)
				if at and (s.recover_at == nil or at < (s.recover_at :: number)) then
					s.recover, s.recover_at = r, at
				end
			end
		end
	end
	return s
end

-- The rows the status line shows for one provider: "one" the pinned row, else the first; "best"
-- the row with the most headroom, else the first; "all" every row.
function M.pick(rows: { Row }, mode: string): { Row }
	if mode == "all" then
		return rows
	end
	local chosen: Row? = nil
	if mode == "best" then
		chosen = M.best(rows)
	else
		for _, r in rows do
			if r.pinned then
				chosen = r
				break
			end
		end
	end
	chosen = chosen or rows[1]
	return if chosen then { chosen :: Row } else {}
end

return M
