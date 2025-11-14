--!nonstrict
--!optimize 2

local fs = require("@std/fs")
local parser = require("@std/syntax/parser")

local KK = 1024 * 1024

-- Memory estimation constants (bytes)
local SIZEOF = {
	-- Derived from Luau's VM structs (extern/luau/VM/src/lobject.h) via clang -fdump-record-layouts.
	TABLE_BASE = 48, -- sizeof(LuaTable) header
	TABLE_FIELD = 32, -- sizeof(LuaNode) (key + value slot)
	STRING_BASE = 32, -- sizeof(TString) header (includes null terminator slot)
	NUMBER = 0, -- Numbers live inside LuaNode's TValue payload
	BOOLEAN = 0, -- Booleans share the same TValue storage
	ARRAY_SLOT = 16, -- sizeof(TValue) in the array part
}

local args = { ... }
local source_path = args[2] or "tests/perf/parsing/holy.src"
local short_name = source_path:match("([^/\\]+)%.[%w%.]+$")

print(`Reading source from: {source_path}`)
local source = fs.readfiletostring(source_path)

-- Read holy.luau once
local ast = parser.parse(source)

-- Statistics
local stats = {
	nodes = {} :: { [string]: number },
	tokens = 0,
	positions = 0,
	locations = 0,
	trivia = 0,
	arrays = 0,
	total_string_bytes = 0,
	unique_strings = {} :: { [string]: boolean },
}

local function count_string(s: string)
	if not stats.unique_strings[s] then
		stats.unique_strings[s] = true
		stats.total_string_bytes += SIZEOF.STRING_BASE + #s
	end
end

local function estimate_position(pos: any): number
	if type(pos) ~= "table" then
		return 0
	end
	stats.positions += 1
	-- Table with 2 number fields: line, column
	return SIZEOF.TABLE_BASE + 2 * SIZEOF.TABLE_FIELD + 2 * SIZEOF.NUMBER
end

local function estimate_location(loc: any): number
	if type(loc) ~= "table" then
		return 0
	end
	stats.locations += 1
	-- Table with 2 Position fields
	local size = SIZEOF.TABLE_BASE + 2 * SIZEOF.TABLE_FIELD
	size += estimate_position(loc.begin)
	size += estimate_position(loc["end"])
	return size
end

local function estimate_trivia(triv: any): number
	if type(triv) ~= "table" then
		return 0
	end
	stats.trivia += 1
	-- tag, location, text
	local size = SIZEOF.TABLE_BASE + 3 * SIZEOF.TABLE_FIELD
	count_string(triv.tag)
	if triv.text then
		count_string(triv.text)
	end
	size += estimate_location(triv.location)
	return size
end

local function estimate_token(tok: any): number
	if type(tok) ~= "table" or not tok.istoken then
		return 0
	end
	stats.tokens += 1

	-- Token has: leadingtrivia, position, text, trailingtrivia, istoken, possibly tag
	local field_count = 5
	if tok.tag then
		field_count += 1
	end
	local size = SIZEOF.TABLE_BASE + field_count * SIZEOF.TABLE_FIELD

	-- Position
	size += estimate_position(tok.position)

	-- Text (string)
	if tok.text then
		count_string(tok.text)
	end

	-- Leading trivia array
	if tok.leadingtrivia then
		stats.arrays += 1
		size += SIZEOF.TABLE_BASE + #tok.leadingtrivia * SIZEOF.ARRAY_SLOT
		for _, t in tok.leadingtrivia do
			size += estimate_trivia(t)
		end
	end

	-- Trailing trivia array
	if tok.trailingtrivia then
		stats.arrays += 1
		size += SIZEOF.TABLE_BASE + #tok.trailingtrivia * SIZEOF.ARRAY_SLOT
		for _, t in tok.trailingtrivia do
			size += estimate_trivia(t)
		end
	end

	return size
end

local function estimate_node(node: any, visited: { [any]: boolean }): number
	if type(node) ~= "table" then
		return 0
	end

	-- Avoid cycles
	if visited[node] then
		return 0
	end
	visited[node] = true

	-- Check if it's a token first
	if node.istoken then
		return estimate_token(node)
	end

	-- Check if it's a Position object (line, column)
	if node.line and node.column and not node.kind and not node.tag then
		return 0 -- Already counted in estimate_position
	end

	-- Check if it's a Location object (begin, end)
	if node.begin and node["end"] and not node.kind and not node.tag then
		return 0 -- Already counted in estimate_location
	end

	-- Count node type
	local node_tag: string
	if node.kind == "expr" then
		node_tag = "Expr:" .. (node.tag or "unknown")
	elseif node.kind == "stat" then
		node_tag = "Stat:" .. (node.tag or "unknown")
	elseif node.kind == "local" then
		node_tag = "AstLocal"
	elseif node.kind == "type" then
		node_tag = "Type:" .. (node.tag or "unknown")
	elseif node.kind == "typepack" then
		node_tag = "TypePack:" .. (node.tag or "unknown")
	elseif node.kind == "list" or node.kind == "record" or node.kind == "general" then
		node_tag = "TableItem:" .. node.kind
	elseif node.node then
		-- Pair<T, Separator> - used in Punctuated lists
		node_tag = "Pair"
	elseif node.elseifkeyword then
		-- AstElseIfStat or AstElseIfExpr
		node_tag = "ElseIf"
	elseif node.functionkeyword then
		-- AstFunctionBody
		node_tag = "FunctionBody"
	elseif node.name and node.type then
		-- AstTypeFunctionParameter or AstAttribute
		node_tag = if node.colon then "TypeFunctionParam" else "Attribute"
	elseif node.indexeropen and node.indexerclose then
		-- AstTypeTableItemIndexer
		node_tag = "TypeTableIndexer"
	elseif node.key and node.value and (node.kind == nil or type(node.kind) == "string") then
		-- AstTypeTableItemProperty or similar
		node_tag = "TypeTableProperty"
	elseif node.tag then
		node_tag = "tag:" .. node.tag
	else
		node_tag = "other"
	end
	stats.nodes[node_tag] = (stats.nodes[node_tag] or 0) + 1

	-- Estimate this node's table
	local field_count = 0
	for _ in node do
		field_count += 1
	end
	local size = SIZEOF.TABLE_BASE + field_count * SIZEOF.TABLE_FIELD

	-- Recursively estimate all fields
	for key, value in node do
		local vtype = type(value)

		-- Count field key string
		if type(key) == "string" then
			count_string(key)
		end

		if vtype == "table" then
			-- Check for arrays
			if #value > 0 then
				stats.arrays += 1
				size += SIZEOF.TABLE_BASE + #value * SIZEOF.ARRAY_SLOT
				for _, item in value do
					size += estimate_node(item, visited)
				end
			else
				size += estimate_node(value, visited)
			end
		elseif vtype == "string" then
			count_string(value)
		elseif vtype == "number" then
			size += SIZEOF.NUMBER
		elseif vtype == "boolean" then
			size += SIZEOF.BOOLEAN
		end
	end

	return size
end

-- Estimate total memory
local visited = {}
local total_bytes = estimate_node(ast, visited)

-- Add string interning overhead (counted once)
total_bytes += stats.total_string_bytes

-- Print results
print(`=== Memory Profile for '{short_name}' ===\n`)
print(string.format("Total estimated memory: %.2f MB", total_bytes / KK))
print(string.format("Measured memory (gcinfo): %.2f MB\n", gcinfo() / 1024))

print("=== Node Type Counts ===")
local node_types: { { tag: string, count: number } } = {}
for tag, count in stats.nodes do
	table.insert(node_types, { tag = tag, count = count })
end
table.sort(node_types, function(a, b)
	return a.count > b.count
end)

for _, entry in node_types do
	print(string.format("  %-30s %6d", entry.tag, entry.count))
end

print("\n=== Component Counts ===")
print(string.format("  Tokens:                  %6d", stats.tokens))
print(string.format("  Positions:               %6d", stats.positions))
print(string.format("  Locations:               %6d", stats.locations))
print(string.format("  Trivia (comments/ws):    %6d", stats.trivia))
print(string.format("  Arrays:                  %6d", stats.arrays))

print("\n=== String Statistics ===")
local unique_count = 0
for _ in stats.unique_strings do
	unique_count += 1
end
print(string.format("  Unique strings:          %6d", unique_count))
print(string.format("  Total string bytes:      %6d KB", math.floor(stats.total_string_bytes / 1024)))

print("\n=== Estimated Size by Component ===")
local token_size = stats.tokens * (SIZEOF.TABLE_BASE + 5 * SIZEOF.TABLE_FIELD)
local position_size = stats.positions * (SIZEOF.TABLE_BASE + 2 * SIZEOF.TABLE_FIELD + 2 * SIZEOF.NUMBER)
local location_size = stats.locations * (SIZEOF.TABLE_BASE + 2 * SIZEOF.TABLE_FIELD)
local trivia_size = stats.trivia * (SIZEOF.TABLE_BASE + 3 * SIZEOF.TABLE_FIELD)
local array_size = stats.arrays * SIZEOF.TABLE_BASE


print(string.format("  Tokens (base):           %6.2f MB", token_size / KK))
print(string.format("  Positions:               %6.2f MB", position_size / KK))
print(string.format("  Locations:               %6.2f MB", location_size / KK))
print(string.format("  Trivia:                  %6.2f MB", trivia_size / KK))
print(string.format("  Arrays (overhead):       %6.2f MB", array_size / KK))
print(string.format("  Strings (interned):      %6.2f MB", stats.total_string_bytes / KK))

print("\n=== Top 10 Node Types by Rough Estimated Size ===")
-- Estimate size per node type (approximate)
local node_sizes: { { tag: string, count: number, est_size: number } } = {}
for tag, count in stats.nodes do
	-- Rough estimate: 10 fields average per node
	local est_size = count * (SIZEOF.TABLE_BASE + 10 * SIZEOF.TABLE_FIELD)
	table.insert(node_sizes, { tag = tag, count = count, est_size = est_size })
end
table.sort(node_sizes, function(a, b)
	return a.est_size > b.est_size
end)

for i = 1, math.min(10, #node_sizes) do
	local entry = node_sizes[i]
	print(
		string.format(
			"  %-30s %6d nodes x ~%3d bytes ~ %4.2f MB",
			entry.tag,
			entry.count,
			math.round(entry.est_size / entry.count),
			entry.est_size / KK
		)
	)
end
