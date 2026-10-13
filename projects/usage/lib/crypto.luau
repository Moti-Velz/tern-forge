--!strict
-- Pure-Luau SHA-256, base64url, hex and URL encoding for OAuth PKCE.
-- The VM has no crypto library; these are small and only hash short strings.

local M = {}

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift

-- SHA-256 of `msg` as 32 raw bytes.
function M.sha256(msg: string): string
	local len = #msg
	local padded = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I4I4", len // 0x20000000, (len * 8) % 0x100000000)
	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)
	for chunk = 1, #padded, 64 do
		for i = 0, 15 do
			w[i + 1] = (string.unpack(">I4", padded, chunk + i * 4))
		end
		for i = 17, 64 do
			local a, b = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(a, 7), rrotate(a, 18), rshift(a, 3))
			local s1 = bxor(rrotate(b, 17), rrotate(b, 19), rshift(b, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 0x100000000
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + K[i] + w[i]) % 0x100000000
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + maj) % 0x100000000
			h, g, f, e = g, f, e, (d + t1) % 0x100000000
			d, c, b, a = c, b, a, (t1 + t2) % 0x100000000
		end
		h0, h1, h2, h3 = (h0 + a) % 0x100000000, (h1 + b) % 0x100000000, (h2 + c) % 0x100000000, (h3 + d) % 0x100000000
		h4, h5, h6, h7 = (h4 + e) % 0x100000000, (h5 + f) % 0x100000000, (h6 + g) % 0x100000000, (h7 + h) % 0x100000000
	end
	return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end

function M.hex(bytes: string): string
	return (string.gsub(bytes, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

-- Raw bytes from a hex string; non-hex characters (spaces, newlines) are skipped.
function M.unhex(text: string): string
	local clean = string.gsub(text, "[^%x]", "")
	return (string.gsub(clean, "%x%x", function(pair)
		return string.char(tonumber(pair, 16) :: number)
	end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- Unpadded base64url (RFC 4648 §5), as PKCE wants.
function M.base64url(bytes: string): string
	local out = table.create(math.ceil(#bytes / 3) * 4)
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		table.insert(out, string.sub(B64, n // 262144 + 1, n // 262144 + 1))
		table.insert(out, string.sub(B64, n // 4096 % 64 + 1, n // 4096 % 64 + 1))
		if b then
			table.insert(out, string.sub(B64, n // 64 % 64 + 1, n // 64 % 64 + 1))
		end
		if c then
			table.insert(out, string.sub(B64, n % 64 + 1, n % 64 + 1))
		end
	end
	return table.concat(out)
end

local B64_INDEX: { [string]: number } = {}
for i = 1, 64 do
	B64_INDEX[string.sub(B64, i, i)] = i - 1
end
B64_INDEX["+"], B64_INDEX["/"] = 62, 63

-- Bytes of base64url or standard base64 text (padding optional), as JWT segments carry.
-- Nil when the text holds other characters.
function M.base64url_decode(text: string): string?
	local clean = string.gsub(text, "=+$", "")
	local out = table.create(#clean * 3 // 4)
	local acc, bits = 0, 0
	for i = 1, #clean do
		local v = B64_INDEX[string.sub(clean, i, i)]
		if v == nil then
			return nil
		end
		acc = bit32.bor(bit32.lshift(acc, 6), v)
		bits += 6
		if bits >= 8 then
			bits -= 8
			table.insert(out, string.char(bit32.band(bit32.rshift(acc, bits), 0xff)))
			acc = bit32.band(acc, bit32.lshift(1, bits) - 1)
		end
	end
	return table.concat(out)
end

-- Percent-encodes everything except RFC 3986 unreserved characters.
function M.urlencode(text: string): string
	return (string.gsub(text, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function M.urldecode(text: string): string
	local plus = string.gsub(text, "+", " ")
	return (string.gsub(plus, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- Parses `a=1&b=2` into a table.
function M.parse_query(query: string): { [string]: string }
	local out: { [string]: string } = {}
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=?(.*)$")
		if k and k ~= "" then
			out[M.urldecode(k)] = M.urldecode(v or "")
		end
	end
	return out
end

-- Fallback randomness when no OS source answered: mixes clocks into math.random.
function M.weak_random_bytes(n: number): string
	math.randomseed(math.floor(os.clock() * 1e6) + os.time())
	local out = table.create(n)
	for i = 1, n do
		out[i] = string.char(math.random(0, 255))
	end
	return table.concat(out)
end

return M
