--!strict
-- Pure helpers: dates, speaker labels and the Markdown context document an agent receives.
-- No `tern` access here, so everything is deterministic for a given input.

local Context = {}

export type User = { name: string?, email: string? }
export type Speaker = { source: string?, attribution: string?, diarization_label: string?, name: string? }
export type Line = { speaker: Speaker?, text: string, start_time: string? }
export type Note = {
	id: string,
	source: string?,
	title: string?,
	owner: User?,
	created_at: string?,
	updated_at: string?,
	web_url: string?,
	calendar_event: { event_title: string?, scheduled_start_time: string?, scheduled_end_time: string?, organiser: string? }?,
	attendees: { User }?,
	folder_membership: { { name: string? } }?,
	summary_text: string?,
	summary_markdown: string?,
	private_notes_markdown: string?,
	transcript: { Line }?,
}

-- Seconds since the epoch for an RFC 3339 UTC timestamp (`2026-01-27T15:30:00Z`, optional
-- fraction and `±HH:MM` offset); nil when it doesn't parse.
function Context.epoch(iso: string?): number?
	if type(iso) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	-- Days from civil (Howard Hinnant), so no local-time interpretation leaks in.
	local yy, m, dd = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if m <= 2 then
		yy -= 1
	end
	local era = (if yy >= 0 then yy else yy - 399) // 400
	local yoe = yy - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + dd - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	local t = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)
	local sign, oh, om = string.match(iso, "([+-])(%d%d):?(%d%d)$")
	if sign then
		local off = (tonumber(oh) :: number) * 3600 + (tonumber(om) :: number) * 60
		t += if sign == "+" then -off else off
	end
	return t
end

-- `Today 15:30`, `Yesterday 09:00`, `Mon 14:00` within a week, else `Jan 27 15:30` (`Jan 27 2025` in
-- other years). `now` and `offset` (local minus UTC, seconds) are passed in to keep this pure.
function Context.when(iso: string?, now: number, offset: number): string
	local t = Context.epoch(iso)
	if t == nil then
		return ""
	end
	local lt, ln = t + offset, now + offset
	local day, today = lt // 86400, ln // 86400
	local clock = os.date("!%H:%M", lt)
	if day == today then
		return "Today " .. clock
	elseif day == today - 1 then
		return "Yesterday " .. clock
	elseif day > today - 7 and day < today then
		return os.date("!%a ", lt) .. clock
	elseif os.date("!%Y", lt) == os.date("!%Y", ln) then
		return os.date("!%b %d ", lt) .. clock
	end
	return os.date("!%b %d %Y", lt)
end

function Context.title(note: { title: string? }): string
	local t = note.title
	if type(t) == "string" and string.find(t, "%S") then
		return t
	end
	return "Untitled meeting"
end

local function person(u: User): string
	if u.name and u.name ~= "" and u.email and u.email ~= "" then
		return u.name .. " <" .. u.email .. ">"
	end
	return u.name or u.email or "?"
end

-- Who said a transcript line: the resolved name, else me/them, else the anonymous bucket, else the
-- audio source.
function Context.speaker(sp: Speaker?): string
	if sp == nil then
		return "Speaker"
	end
	if sp.name and sp.name ~= "" then
		return sp.name
	elseif sp.attribution == "me" then
		return "Me"
	elseif sp.attribution == "them" then
		return "Them"
	elseif sp.diarization_label and sp.diarization_label ~= "" then
		return sp.diarization_label
	elseif sp.source == "microphone" then
		return "Me"
	elseif sp.source == "speaker" then
		return "Them"
	end
	return "Speaker"
end

-- Consecutive lines of one speaker merge into one paragraph.
function Context.transcript(lines: { Line }): string
	local out: { string } = {}
	local who: string? = nil
	local buf: { string } = {}
	local function flush()
		if who and #buf > 0 then
			table.insert(out, "**" .. who .. ":** " .. table.concat(buf, " "))
		end
		buf = {}
	end
	for _, l in lines do
		local name = Context.speaker(l.speaker)
		if name ~= who then
			flush()
			who = name
		end
		local text = string.gsub(l.text or "", "%s+", " ")
		if string.find(text, "%S") then
			table.insert(buf, text)
		end
	end
	flush()
	return table.concat(out, "\n\n")
end

-- Shifts headings so the shallowest becomes level `top`, nesting them under the note's own heading.
local function nest(md: string, top: number): string
	local lines = "\n" .. md
	local shallowest = math.huge
	for h in string.gmatch(lines, "\n(#+) ") do
		shallowest = math.min(shallowest, #h)
	end
	if shallowest == math.huge or shallowest >= top then
		return md
	end
	local prefix = string.rep("#", top - shallowest)
	return (string.gsub(lines, "\n(#+) ", function(h)
		return "\n" .. prefix .. h .. " "
	end)):sub(2)
end

-- Display names of the meeting sources.
Context.SOURCES = { granola = "Granola", fireflies = "Fireflies", ["local"] = "Local file", email = "Email" }

-- One note as a Markdown section headed `## title`.
function Context.note(note: Note, opts: { transcript: boolean }): string
	local out: { string } = { "## " .. Context.title(note), "" }
	local meta: { string } = {}
	local ev = note.calendar_event
	local start = (ev and ev.scheduled_start_time) or note.created_at
	if start then
		table.insert(meta, "- When: " .. start)
	end
	if note.attendees and #note.attendees > 0 then
		local names: { string } = {}
		for _, u in note.attendees do
			table.insert(names, person(u))
		end
		table.insert(meta, "- Attendees: " .. table.concat(names, ", "))
	elseif note.owner then
		table.insert(meta, "- Owner: " .. person(note.owner))
	end
	if note.folder_membership and #note.folder_membership > 0 then
		local names: { string } = {}
		for _, f in note.folder_membership do
			if f.name then
				table.insert(names, f.name)
			end
		end
		if #names > 0 then
			table.insert(meta, "- Folders: " .. table.concat(names, ", "))
		end
	end
	local from = Context.SOURCES[note.source or "granola"] or note.source or "?"
	if note.web_url then
		table.insert(meta, "- Source: " .. from .. " — " .. note.web_url)
	else
		table.insert(meta, "- Source: " .. from)
	end
	table.insert(meta, "- Id: " .. note.id)
	table.insert(out, table.concat(meta, "\n"))
	local summary = note.summary_markdown or note.summary_text
	if summary and string.find(summary, "%S") then
		table.insert(out, "")
		table.insert(out, if note.source == "email" then "### Thread" else "### Summary")
		table.insert(out, "")
		table.insert(out, nest(summary, 4))
	end
	local mine = note.private_notes_markdown
	if mine and string.find(mine, "%S") then
		table.insert(out, "")
		table.insert(out, "### My notes")
		table.insert(out, "")
		table.insert(out, nest(mine, 4))
	end
	-- Captions and dialogue files have no summary; their transcript is all there is, so it always goes.
	local has_summary = (summary and string.find(summary, "%S")) or (mine and string.find(mine, "%S"))
	if (opts.transcript or not has_summary) and note.transcript and #note.transcript > 0 then
		table.insert(out, "")
		table.insert(out, "### Transcript")
		table.insert(out, "")
		table.insert(out, Context.transcript(note.transcript))
	end
	return table.concat(out, "\n")
end

-- `a`, `a and b`, `a, b and c`.
local function joined(items: { string }): string
	if #items <= 1 then
		return items[1] or ""
	end
	return table.concat(items, ", ", 1, #items - 1) .. " and " .. items[#items]
end

-- The whole context document for several notes, oldest meeting first so the story reads in order.
function Context.document(notes: { Note }, opts: { transcript: boolean }): string
	local sorted = table.clone(notes)
	table.sort(sorted, function(a, b)
		return (Context.epoch(a.created_at) or 0) < (Context.epoch(b.created_at) or 0)
	end)
	local froms: { string } = {}
	for _, n in sorted do
		local name = if n.source == "local" then "local files" else Context.SOURCES[n.source or "granola"] or n.source
		if name and not table.find(froms, name) then
			table.insert(froms, name)
		end
	end
	local parts: { string } = {
		"# Context" .. (if #froms > 0 then " from " .. joined(froms) else ""),
		"",
		if #sorted == 1 then "1 item." else tostring(#sorted) .. " items, oldest first.",
	}
	for _, n in sorted do
		table.insert(parts, "")
		table.insert(parts, Context.note(n, opts))
	end
	return table.concat(parts, "\n") .. "\n"
end

-- A file-name-safe slug of a title, at most 40 characters.
function Context.slug(s: string): string
	local slug = string.gsub(string.lower(s), "[^%w]+", "-")
	slug = string.gsub(slug, "^-+", "")
	slug = string.sub(slug, 1, 40)
	slug = string.gsub(slug, "-+$", "")
	return if slug == "" then "meeting" else slug
end

-- Documents up to this size go inline into the agent's composer; longer ones are written to a
-- local file the attachment names, so transcripts don't flood the composer.
Context.INLINE_LIMIT = 6000

-- What lands in the agent's composer: the document inline, or a pointer to `path`. It ends with a
-- blank line so your question follows it.
function Context.attachment(doc: string, titles: { string }, path: string?): string
	if path then
		return "Context (" .. table.concat(titles, "; ") .. "): read `" .. path .. "`\n\n"
	end
	return "<context>\n\n" .. doc .. "\n</context>\n\n"
end

-- Appended when a new agent has to be started with the context as its first prompt.
Context.WAIT = "Read this meeting context. Reply with a three-line recap, then wait for my instructions."

return Context
