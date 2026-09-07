local function read(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()
	return data
end
local function write(path, data)
	local file = assert(io.open(path, "wb"))
	assert(file:write(data))
	assert(file:close())
end
local function u32(data, offset)
	local a,b,c,d = data:byte(offset, offset + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end
local function encode_u32(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256)
end
local packed = assert(read(arg[1]):match("pub const bytes_0.-{(.-)};"))
local bytes = {}
for value in packed:gmatch("%d+") do bytes[#bytes+1] = string.char(tonumber(value)) end
local original = table.concat(bytes)
local source = assert(read(arg[2]):match("const modular.-{(.-)};"))
bytes = {}
for value in source:gmatch("0x%x+") do bytes[#bytes+1] = string.char(tonumber(value)) end
local modular = table.concat(bytes)
assert(#modular == 39)
local pieces, offset, replaced = {}, 1, false
while offset <= #original do
	local size = u32(original, offset)
	assert(size >= 8 and offset + size - 1 <= #original)
	local kind = original:sub(offset + 4, offset + 7)
	if kind == "jxlc" or kind == "jxlp" then
		replaced = true
	else
		pieces[#pieces+1] = original:sub(offset, offset + size - 1)
	end
	offset = offset + size
end
assert(replaced)
pieces[#pieces+1] = encode_u32(#modular + 8) .. "jxlc" .. modular
write(arg[3], original)
write(arg[4], table.concat(pieces))
