--!strict
-- The internal links the block and the window half talk through: `tern-<plugin id>://VERB?k=v&…`,
-- values percent-encoded (meeting ids carry `:`, local ones file names with spaces).

local Link = {}

Link.SCHEME = "tern-" .. tern.plugin.id .. "://"

function Link.encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function Link.decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- A comma-separated list of encoded ids, and back.
function Link.ids(ids: { string }): string
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, Link.encode(id))
	end
	return table.concat(parts, ",")
end

function Link.split(s: string?): { string }
	local out: { string } = {}
	for part in string.gmatch(s or "", "[^,]+") do
		table.insert(out, Link.decode(part))
	end
	return out
end

function Link.make(verb: string, params: { [string]: string }): string
	local parts: { string } = {}
	for k, v in params do
		table.insert(parts, k .. "=" .. v)
	end
	table.sort(parts)
	return Link.SCHEME .. verb .. "?" .. table.concat(parts, "&")
end

-- The verb and the (still encoded) parameters of a link, or nil when it isn't ours.
function Link.parse(url: string): (string?, { [string]: string })
	if string.sub(url, 1, #Link.SCHEME) ~= Link.SCHEME then
		return nil, {}
	end
	local rest = string.sub(url, #Link.SCHEME + 1)
	local verb = string.match(rest, "^([%w-]+)") or ""
	local q: { [string]: string } = {}
	for k, v in string.gmatch(string.match(rest, "%?(.*)$") or "", "([^&=]+)=([^&]*)") do
		q[k] = v
	end
	return verb, q
end

return Link
