--!strict
-- A folder of exported meetings: Markdown notes (`.md`), plain text (`.txt`) and captions (`.vtt`,
-- `.srt`), which most recorders and note-takers can export. A file's date comes from a leading
-- `YYYY-MM-DD` (optionally ` HH-MM`) in its name; its title from its first `# ` heading, else the rest
-- of the name. Markdown and prose are the summary; captions and `Name: text` lines are a transcript.

local source = require("./source")

local EXTS = { md = true, markdown = true, txt = true, vtt = true, srt = true }
local MAX_FILES = 300
local MAX_BYTES = 4 * 1024 * 1024

local function trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

local function expand(dir: string): string
	if string.sub(dir, 1, 1) == "~" then
		dir = (tern.getenv("HOME") or "") .. string.sub(dir, 2)
	end
	return (string.gsub(dir, "/+$", ""))
end

local function ext(name: string): string?
	local e = string.match(name, "%.([%w]+)$")
	return if e then string.lower(e) else nil
end

-- Date and title from a file name like `2026-10-12 14-00 Acme call.md`.
local function from_name(name: string): (string?, string)
	local base = string.gsub(name, "%.[%w]+$", "")
	local y, mo, d, rest = string.match(base, "^(%d%d%d%d)-(%d%d)-(%d%d)(.*)$")
	local created: string? = nil
	if y then
		local h, mi, after = string.match(rest, "^[ T_-]?(%d%d)[:.h-]?(%d%d)(.*)$")
		if h and (tonumber(h) :: number) < 24 and (tonumber(mi) :: number) < 60 then
			rest = after
		else
			h, mi = "00", "00"
		end
		-- A time in a file name is local time: the timestamp carries this machine's UTC offset.
		local now = os.time()
		local offset = now - os.time(os.date("!*t", now) :: any)
		local sign = if offset < 0 then "-" else "+"
		offset = math.abs(offset)
		created = string.format("%s-%s-%sT%s:%s:00%s%02d:%02d", y, mo, d, h, mi, sign, offset // 3600, (offset % 3600) // 60)
		base = rest
	end
	local title = trim((string.gsub(base, "[_-]+", " ")))
	return created, if title ~= "" then title else name
end

local function stub(name: string): any
	local created, title = from_name(name)
	return { id = "local:" .. name, source = "local", title = title, created_at = created }
end

local function later(fn: (cx: WindowCx) -> ())
	tern.timer(0, function(cx)
		fn(cx :: WindowCx)
	end)
end

local function list(dir: string, _cursor: string?, done: source.Done<source.Page>)
	local ok, names = pcall(tern.fs.list, expand(dir))
	later(function(cx)
		if not ok then
			done(nil, "Can't read the meetings folder " .. dir .. ": " .. tostring(names), cx)
			return
		end
		local notes = {}
		for _, name in names :: { string } do
			local e = ext(name)
			if e and EXTS[e] and string.sub(name, 1, 1) ~= "." then
				table.insert(notes, stub(name))
			end
		end
		table.sort(notes, function(a, b)
			if (a.created_at or "") ~= (b.created_at or "") then
				return (a.created_at or "") > (b.created_at or "")
			end
			return a.title < b.title
		end)
		while #notes > MAX_FILES do
			table.remove(notes)
		end
		done({ notes = notes, cursor = nil }, nil, cx)
	end)
end

-- Caption cues (`.vtt`, `.srt`) as transcript lines: numbers, timings and headers dropped, `<v Name>`
-- voice tags and `Name:` prefixes as speakers.
local function captions(text: string): { any }
	local lines = {}
	for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local line = trim((string.gsub(raw, "\r", "")))
		if line == "" or line == "WEBVTT" or string.find(line, "^%d+$") or string.find(line, "%-%->")
			or string.find(line, "^NOTE") or string.find(line, "^STYLE") then
			continue
		end
		local who, said = string.match(line, "^<v%.?[^ >]*%s+([^>]+)>(.*)$")
		said = said or line
		said = trim((string.gsub(said, "<[^>]+>", "")))
		if who == nil then
			local w, s = string.match(said, "^([%a][%w%.' ]-):%s+(.+)$")
			if w and #w <= 40 then
				who, said = w, s
			end
		end
		if said ~= "" then
			table.insert(lines, { speaker = { name = who }, text = said })
		end
	end
	return lines
end

-- Plain text reads as a transcript when most of its lines are `Name: text`.
local function dialogue(text: string): { any }?
	local lines, total = {}, 0
	for raw in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local line = trim(raw)
		if line ~= "" then
			total += 1
			local who, said = string.match(line, "^([%a][%w%.' ]-):%s+(.+)$")
			if who and #who <= 40 then
				table.insert(lines, { speaker = { name = who }, text = said })
			end
		end
	end
	return if total >= 3 and #lines >= total * 0.6 then lines else nil
end

local function note(dir: string, name: string, _transcript: boolean, done: source.Done<any>)
	local path = expand(dir) .. "/" .. name
	local ok, text = pcall(tern.fs.read, path, MAX_BYTES)
	later(function(cx)
		if not ok then
			done(nil, "Can't read " .. path .. ": " .. tostring(text), cx)
			return
		end
		local m = stub(name)
		m.web_url = path
		local body = text :: string
		local e = ext(name)
		if e == "vtt" or e == "srt" then
			m.transcript = captions(body)
		else
			local heading, after = string.match(body, "^%s*#%s+([^\n]+)\n?(.*)$")
			if heading then
				m.title = trim(heading)
				body = after
			end
			local spoken = if e == "txt" then dialogue(body) else nil
			if spoken then
				m.transcript = spoken
			else
				m.summary_markdown = trim(body)
			end
		end
		done(m, nil, cx)
	end)
end

local def: source.Def = {
	id = "local",
	name = "Local",
	credential = "path",
	prompt = "Folder of exported meetings (.md, .txt, .vtt, .srt), e.g. ~/Meetings",
	list = list,
	note = note,
}
return def
