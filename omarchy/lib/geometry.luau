--!strict
-- Pure geometry of a Tern tab: pane rectangles in unit space from its split tree, the neighbour in a
-- direction, and the pane on an edge. No `tern` access.

local Geometry = {}

export type Rect = { x: number, y: number, w: number, h: number }
export type Dir = "l" | "r" | "u" | "d"

local EPS = 1e-6

-- Every pane of `tree` with its rectangle inside `area` (default the unit square).
function Geometry.rects(tree: any, area: Rect?): { [number]: Rect }
	local out: { [number]: Rect } = {}
	local function walk(node: any, r: Rect)
		if type(node) ~= "table" then
			return
		end
		if node.pane then
			out[node.pane] = r
			return
		end
		local ratio = if type(node.ratio) == "number" then node.ratio else 0.5
		if node.split == "down" then
			local h1 = r.h * ratio
			walk(node[1], { x = r.x, y = r.y, w = r.w, h = h1 })
			walk(node[2], { x = r.x, y = r.y + h1, w = r.w, h = r.h - h1 })
		else
			local w1 = r.w * ratio
			walk(node[1], { x = r.x, y = r.y, w = w1, h = r.h })
			walk(node[2], { x = r.x + w1, y = r.y, w = r.w - w1, h = r.h })
		end
	end
	walk(tree, area or { x = 0, y = 0, w = 1, h = 1 })
	return out
end

local function overlap(a0: number, a1: number, b0: number, b1: number): number
	return math.max(0, math.min(a1, b1) - math.max(a0, b0))
end

-- The pane next to `from` in `dir`: the nearest one beyond that edge which overlaps it across the
-- other axis; ties go to the larger overlap, then the closer centre. nil at the tab's edge.
function Geometry.neighbor(rects: { [number]: Rect }, from: number, dir: Dir): number?
	local c = rects[from]
	if c == nil then
		return nil
	end
	local best: number? = nil
	local best_gap, best_overlap, best_center = math.huge, -1, math.huge
	for pane, r in rects do
		if pane ~= from then
			local gap, ov, center
			if dir == "l" then
				gap = c.x - (r.x + r.w)
				ov = overlap(c.y, c.y + c.h, r.y, r.y + r.h)
				center = math.abs((c.y + c.h / 2) - (r.y + r.h / 2))
			elseif dir == "r" then
				gap = r.x - (c.x + c.w)
				ov = overlap(c.y, c.y + c.h, r.y, r.y + r.h)
				center = math.abs((c.y + c.h / 2) - (r.y + r.h / 2))
			elseif dir == "u" then
				gap = c.y - (r.y + r.h)
				ov = overlap(c.x, c.x + c.w, r.x, r.x + r.w)
				center = math.abs((c.x + c.w / 2) - (r.x + r.w / 2))
			else
				gap = r.y - (c.y + c.h)
				ov = overlap(c.x, c.x + c.w, r.x, r.x + r.w)
				center = math.abs((c.x + c.w / 2) - (r.x + r.w / 2))
			end
			if gap > -EPS and ov > EPS then
				local better = gap < best_gap - EPS
					or (math.abs(gap - best_gap) <= EPS and (ov > best_overlap + EPS
						or (math.abs(ov - best_overlap) <= EPS and center < best_center)))
				if better then
					best, best_gap, best_overlap, best_center = pane, gap, ov, center
				end
			end
		end
	end
	return best
end

-- Entering the tab while moving in `dir` lands on the opposite edge: moving right enters at the
-- left edge. Of the panes on that edge, the one nearest `along` (0–1 across the other axis).
function Geometry.entry(rects: { [number]: Rect }, dir: Dir, along: number): number?
	local best: number? = nil
	local best_dist = math.huge
	for pane, r in rects do
		local on_edge, lo, hi
		if dir == "r" then
			on_edge, lo, hi = r.x <= EPS, r.y, r.y + r.h
		elseif dir == "l" then
			on_edge, lo, hi = r.x + r.w >= 1 - EPS, r.y, r.y + r.h
		elseif dir == "d" then
			on_edge, lo, hi = r.y <= EPS, r.x, r.x + r.w
		else
			on_edge, lo, hi = r.y + r.h >= 1 - EPS, r.x, r.x + r.w
		end
		if on_edge then
			local dist = if along >= lo and along <= hi then 0 else math.min(math.abs(along - lo), math.abs(along - hi))
			if dist < best_dist or (dist == best_dist and best ~= nil and pane < best) then
				best, best_dist = pane, dist
			end
		end
	end
	return best
end

return Geometry
