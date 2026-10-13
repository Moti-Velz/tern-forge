--!strict
-- Fireflies.ai (https://docs.fireflies.ai): GraphQL at /graphql with an API key as a bearer token.
-- `transcripts(limit, skip)` lists meetings, `transcript(id)` gives one with its AI summary and,
-- when asked, its sentences. Free plans allow 500 requests a day, so lists ask only for light fields
-- and sentences are fetched only for Full transcript.

local source = require("./source")

local NAME = "Fireflies"
-- FIREFLIES_API_BASE points the client at another server (a proxy, or a stub in tests).
local URL = (tern.getenv("FIREFLIES_API_BASE") or "https://api.fireflies.ai") .. "/graphql"
local PAGE = 30

local ATTENDEES = "meeting_attendees { displayName name email }"
local LIST = "query Meetings($limit: Int, $skip: Int) { transcripts(limit: $limit, skip: $skip) { "
	.. "id title date dateString organizer_email " .. ATTENDEES .. " } }"
local DETAIL = "id title date dateString transcript_url organizer_email " .. ATTENDEES
	.. " summary { overview shorthand_bullet action_items topics_discussed }"
local NOTE = "query Meeting($id: String!) { transcript(id: $id) { " .. DETAIL .. " } }"
local NOTE_WITH_SENTENCES = "query Meeting($id: String!) { transcript(id: $id) { " .. DETAIL
	.. " sentences { speaker_name text } } }"

-- Posts a GraphQL query; `done` gets `data` or a readable error (GraphQL errors arrive with HTTP 200
-- and carry their status in `extensions`).
local function graphql(key: string, q: string, vars: { [string]: any }, done: (data: any?, err: string?, cx: WindowCx) -> ())
	tern.fetch(URL, {
		method = "POST",
		headers = { Authorization = "Bearer " .. key, ["Content-Type"] = "application/json", Accept = "application/json" },
		body = tern.json.encode({ query = q, variables = vars }),
		timeout_ms = 30000,
	}, function(r, cx)
		local wcx = cx :: WindowCx
		local ok, body = pcall(tern.json.decode, r.body)
		local first = if ok and type(body) == "table" and type(body.errors) == "table" then body.errors[1] else nil
		if r.error or r.status < 200 or r.status >= 300 or first then
			local status = r.status
			local msg: string? = nil
			if type(first) == "table" then
				msg = if type(first.message) == "string" then first.message else nil
				local ext = first.extensions
				if type(ext) == "table" and type(ext.status) == "number" then
					status = ext.status
				end
			end
			if r.error == nil and status == 200 then
				done(nil, NAME .. ": " .. (msg or "request failed"), wcx)
			else
				done(nil, source.failure(NAME, {
					status = status, headers = r.headers, body = r.body, error = r.error, timed_out = r.timed_out,
				}, msg), wcx)
			end
			return
		end
		if not ok or type(body) ~= "table" then
			done(nil, NAME .. " sent a reply that isn't JSON", wcx)
			return
		end
		done(body.data, nil, wcx)
	end)
end

local function str(v: any): string?
	return if type(v) == "string" and string.find(v, "%S") then v else nil
end

-- A Fireflies transcript as a meeting.
local function meeting(t: any): any
	local m: { [string]: any } = {
		id = "fireflies:" .. tostring(t.id),
		source = "fireflies",
		title = t.title,
		created_at = str(t.dateString) or (if type(t.date) == "number" then source.iso(t.date) else nil),
		web_url = str(t.transcript_url),
	}
	if str(t.organizer_email) then
		m.owner = { email = t.organizer_email }
	end
	if type(t.meeting_attendees) == "table" then
		local people = {}
		for _, a in t.meeting_attendees do
			local name = str(a.displayName) or str(a.name)
			if name or str(a.email) then
				table.insert(people, { name = name, email = str(a.email) })
			end
		end
		m.attendees = people
	end
	local s = t.summary
	if type(s) == "table" then
		local parts: { string } = {}
		for _, sec in { { "Overview", s.overview }, { "Key points", s.shorthand_bullet }, { "Action items", s.action_items } } do
			if str(sec[2]) then
				table.insert(parts, "## " .. sec[1] .. "\n\n" .. sec[2])
			end
		end
		if type(s.topics_discussed) == "table" and #s.topics_discussed > 0 then
			local topics: { string } = {}
			for _, topic in s.topics_discussed do
				table.insert(topics, "- " .. tostring(topic))
			end
			table.insert(parts, "## Topics\n\n" .. table.concat(topics, "\n"))
		end
		m.summary_markdown = if #parts > 0 then table.concat(parts, "\n\n") else nil
	end
	if type(t.sentences) == "table" then
		local lines = {}
		for _, sen in t.sentences do
			table.insert(lines, { speaker = { name = str(sen.speaker_name) }, text = sen.text or "" })
		end
		m.transcript = lines
	end
	return m
end

local function list(key: string, cursor: string?, done: source.Done<source.Page>)
	local skip = tonumber(cursor) or 0
	graphql(key, LIST, { limit = PAGE, skip = skip }, function(data, err, cx)
		if err then
			done(nil, err, cx)
			return
		end
		local notes = {}
		local got = if type(data) == "table" and type(data.transcripts) == "table" then data.transcripts else {}
		for _, t in got do
			table.insert(notes, meeting(t))
		end
		done({ notes = notes, cursor = if #got >= PAGE then tostring(skip + PAGE) else nil }, nil, cx)
	end)
end

local function note(key: string, id: string, transcript: boolean, done: source.Done<any>)
	graphql(key, if transcript then NOTE_WITH_SENTENCES else NOTE, { id = id }, function(data, err, cx)
		if err or type(data) ~= "table" or type(data.transcript) ~= "table" then
			done(nil, err or "Not found in Fireflies", cx)
			return
		end
		done(meeting(data.transcript), nil, cx)
	end)
end

local def: source.Def = {
	id = "fireflies",
	name = NAME,
	credential = "secret",
	secret = "fireflies-key",
	prompt = "Fireflies API key, from app.fireflies.ai › Integrations › Fireflies API",
	list = list,
	note = note,
}
return def
