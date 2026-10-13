--!strict
-- Granola (https://docs.granola.ai/introduction): list notes, get one note with its transcript
-- (paging the transcript endpoint when Get Note answers 413). Personal API key as a bearer token.
-- Granola's note shape is the plugin's meeting shape already; ids just gain the `granola:` prefix.

local source = require("./source")

local NAME = "Granola"
-- GRANOLA_API_BASE points the client at another server (a proxy, or a stub in tests).
local BASE = tern.getenv("GRANOLA_API_BASE") or "https://public-api.granola.ai"

local function query(params: { [string]: string? }): string
	local parts: { string } = {}
	for k, v in params do
		if v ~= nil and v ~= "" then
			local enc = string.gsub(v, "[^%w%-%._~]", function(c)
				return string.format("%%%02X", string.byte(c))
			end)
			table.insert(parts, k .. "=" .. enc)
		end
	end
	table.sort(parts)
	return if #parts > 0 then "?" .. table.concat(parts, "&") else ""
end

local function failure(r: FetchResult): string
	if r.status == 403 then
		return "This Granola API key can't access that (403). Check its scopes in Granola › Settings › Connectors."
	elseif r.status == 404 then
		return "Not found in Granola (404): notes appear only once Granola has summarized them."
	end
	local msg: string? = nil
	local ok, body = pcall(tern.json.decode, r.body)
	if ok and type(body) == "table" and type(body.message) == "string" then
		msg = body.message
	end
	return source.failure(NAME, r, msg)
end

local function get(key: string, path: string, params: { [string]: string? }, done: (body: any?, status: number, err: string?, cx: WindowCx) -> ())
	tern.fetch(BASE .. path .. query(params), {
		headers = { Authorization = "Bearer " .. key, Accept = "application/json" },
		timeout_ms = 30000,
	}, function(r, cx)
		local wcx = cx :: WindowCx
		if r.error or r.status < 200 or r.status >= 300 then
			done(nil, r.status, failure(r), wcx)
			return
		end
		local ok, body = pcall(tern.json.decode, r.body)
		if not ok then
			done(nil, r.status, "Granola sent a reply that isn't JSON", wcx)
			return
		end
		done(body, r.status, nil, wcx)
	end)
end

-- Decoded JSON is read-only; a meeting gets a fresh table with the prefixed id.
local function meeting(n: any): any
	local m = table.clone(n)
	m.id = "granola:" .. tostring(n.id)
	m.source = "granola"
	return m
end

local function list(key: string, cursor: string?, done: source.Done<source.Page>)
	get(key, "/v1/notes", { page_size = "30", cursor = cursor }, function(body, _status, err, cx)
		if err then
			done(nil, err, cx)
			return
		end
		local notes = {}
		for _, n in (if type(body.notes) == "table" then body.notes else {}) do
			table.insert(notes, meeting(n))
		end
		local next_cursor = if body.hasMore and type(body.cursor) == "string" then body.cursor else nil
		done({ notes = notes, cursor = next_cursor }, nil, cx)
	end)
end

-- The transcript endpoint's pages, appended to `acc` until the last one.
local function transcript_pages(key: string, id: string, cursor: string?, acc: { any }, done: source.Done<{ any }>)
	get(key, "/v1/notes/" .. id .. "/transcript", { page_size = "100", cursor = cursor }, function(body, _status, err, cx)
		if err then
			done(nil, err, cx)
			return
		end
		for _, line in (if type(body.transcript) == "table" then body.transcript else {}) do
			table.insert(acc, line)
		end
		if body.hasMore and type(body.cursor) == "string" then
			transcript_pages(key, id, body.cursor, acc, done)
		else
			done(acc, nil, cx)
		end
	end)
end

local function note(key: string, id: string, transcript: boolean, done: source.Done<any>)
	get(key, "/v1/notes/" .. id, { include = if transcript then "transcript" else nil }, function(body, status, err, cx)
		if status == 413 and transcript then
			get(key, "/v1/notes/" .. id, {}, function(n, _s, err2, cx2)
				if err2 then
					done(nil, err2, cx2)
					return
				end
				transcript_pages(key, id, nil, {}, function(lines, err3, cx3)
					if err3 then
						done(nil, err3, cx3)
						return
					end
					local m = meeting(n)
					m.transcript = lines
					done(m, nil, cx3)
				end)
			end)
			return
		end
		if err then
			done(nil, err, cx)
			return
		end
		done(meeting(body), nil, cx)
	end)
end

local def: source.Def = {
	id = "granola",
	name = NAME,
	credential = "secret",
	-- The name the key had before there were other sources, so existing installs keep it.
	secret = "api-key",
	prompt = "Granola API key (grn_…), from Granola › Settings › Connectors › API keys",
	list = list,
	note = note,
}
return def
