--!strict
-- Granola public API client (https://docs.granola.ai/introduction): list notes, get one note with
-- its transcript (paging the transcript endpoint when Get Note answers 413), all over `tern.fetch`
-- with the personal API key as a bearer token. Callbacks get the window `cx` `tern.fetch` hands
-- back, so callers can redraw from them.

local Api = {}

-- GRANOLA_API_BASE points the client at another server (a proxy, or a stub in tests).
Api.BASE = tern.getenv("GRANOLA_API_BASE") or "https://public-api.granola.ai"

export type Done<T> = (result: T?, err: string?, cx: WindowCx) -> ()

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

-- A readable reason for a failed exchange.
local function failure(r: FetchResult): string
	if r.error then
		return if r.timed_out then "Granola didn't answer in time" else "Can't reach Granola: " .. r.error
	elseif r.status == 401 then
		return "Granola rejected the API key (401). Set a new one."
	elseif r.status == 403 then
		return "This API key can't access that (403). Check its scopes in Granola › Settings › Connectors."
	elseif r.status == 404 then
		return "Not found (404): notes appear only once Granola has summarized them."
	elseif r.status == 429 then
		local wait = r.headers["retry-after"]
		return "Granola rate limit hit (429)" .. (if wait then "; retry in " .. wait .. "s" else "")
	end
	local msg: string? = nil
	local ok, body = pcall(tern.json.decode, r.body)
	if ok and type(body) == "table" then
		msg = body.message or body.error
		if type(msg) ~= "string" then
			msg = nil
		end
	end
	return "Granola error " .. tostring(r.status) .. (if msg then ": " .. msg else "")
end

local function get(key: string, path: string, params: { [string]: string? }, done: (body: any?, status: number, err: string?, cx: WindowCx) -> ())
	tern.fetch(Api.BASE .. path .. query(params), {
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

export type Page = { notes: { any }, cursor: string? }

-- One page of notes, newest first (page_size at most 30).
function Api.list(key: string, cursor: string?, done: Done<Page>)
	get(key, "/v1/notes", { page_size = "30", cursor = cursor }, function(body, _status, err, cx)
		if err then
			done(nil, err, cx)
			return
		end
		local notes = if type(body.notes) == "table" then body.notes else {}
		local next_cursor = if body.hasMore and type(body.cursor) == "string" then body.cursor else nil
		done({ notes = notes, cursor = next_cursor }, nil, cx)
	end)
end

-- The transcript endpoint's pages, appended to `acc` until the last one.
local function transcript_pages(key: string, id: string, cursor: string?, acc: { any }, done: Done<{ any }>)
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

-- One note with summary, attendees and calendar event; with `transcript`, also the transcript
-- (from the paged endpoint when it is too large to come inline).
function Api.note(key: string, id: string, transcript: boolean, done: Done<any>)
	get(key, "/v1/notes/" .. id, { include = if transcript then "transcript" else nil }, function(body, status, err, cx)
		if status == 413 and transcript then
			get(key, "/v1/notes/" .. id, {}, function(note, _s, err2, cx2)
				if err2 then
					done(nil, err2, cx2)
					return
				end
				transcript_pages(key, id, nil, {}, function(lines, err3, cx3)
					if err3 then
						done(nil, err3, cx3)
						return
					end
					note.transcript = lines
					done(note, nil, cx3)
				end)
			end)
			return
		end
		if err then
			done(nil, err, cx)
			return
		end
		done(body, nil, cx)
	end)
end

return Api
