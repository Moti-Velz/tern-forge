--!strict
-- What every meeting source implements, and helpers they share. A source turns its service's data
-- into one meeting shape (the one `lib/context.luau` and the block read):
--
--   { id = "<source>:<native id>", source = "<source>", title, created_at (RFC 3339),
--     owner = {name, email}?, attendees = {{name, email}}?, web_url?, folder_membership = {{name}}?,
--     summary_markdown?, private_notes_markdown?, transcript = {{speaker = {name}, text}}? }
--
-- Lists carry the light fields (id, source, title, created_at, owner); `note` fills in the rest.

local Source = {}

export type Page = { notes: { any }, cursor: string? }
export type Done<T> = (result: T?, err: string?, cx: WindowCx) -> ()

export type Def = {
	-- Prefix of its meeting ids and key of its settings.
	id: string,
	-- Display name.
	name: string,
	-- What `connect` asks for: a secret (API key) or a setting (folder path).
	credential: "secret" | "path",
	-- The secret's name in the keychain (credential = "secret").
	secret: string?,
	-- The prompt's hint.
	prompt: string,
	-- A second prompt after the first (its answer is stored after a newline in the same secret).
	then_prompt: string?,
	-- What the connect picker says it needs (default "API key").
	needs: string?,
	-- One page of meetings, newest first; `cursor` continues.
	list: (cred: string, cursor: string?, done: Done<Page>) -> (),
	-- One meeting in full; with `transcript`, also its transcript.
	note: (cred: string, id: string, transcript: boolean, done: Done<any>) -> (),
}

-- The native id behind "<source>:<native id>".
function Source.split(id: string): (string, string)
	local src, rest = string.match(id, "^([%w_-]+):(.*)$")
	return src or "", rest or id
end

-- A readable reason for a failed HTTP exchange with `name`.
function Source.failure(name: string, r: FetchResult, message: string?): string
	if r.error then
		return if r.timed_out then name .. " didn't answer in time" else "Can't reach " .. name .. ": " .. r.error
	elseif r.status == 401 then
		return name .. " rejected the API key (401). Connect it again."
	elseif r.status == 403 then
		return name .. " refused access (403)" .. (if message then ": " .. message else "")
	elseif r.status == 404 then
		return "Not found in " .. name .. " (404)"
	elseif r.status == 429 then
		local wait = r.headers["retry-after"]
		return name .. " rate limit hit (429)" .. (if wait then "; retry in " .. wait .. "s" else "")
	end
	return name .. " error " .. tostring(r.status) .. (if message then ": " .. message else "")
end

-- An RFC 3339 UTC timestamp for epoch milliseconds.
function Source.iso(ms: number): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000)) :: string
end

return Source
