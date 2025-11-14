local benchit = require("../benchit")
local fs = require("@std/fs")
local parser = require("@std/syntax/parser")
local luau = require("@lute/luau")
local vm = require("@lute/vm")

-- Read holy.luau once (outside benchmark)
local source = fs.readfiletostring("tests/perf/parsing/holy.src")

-- Benchmark function: takes source string, returns AST
local function parse_holy(src: string)
	return parser.parse(src)
end

-- Benchmark function: C++ parse only, no serialization
local function parse_nosync(src: string)
	return luau.parsenosync(src)
end

local function memory(routine: () -> any)
	vm.gccollect()
	vm.gcstop()
	local before = gcinfo()
	routine()
	local after = gcinfo()
	vm.gcrestart()
	local used = after - before
	vm.gccollect()
	return used
end

-- Run benchmark
print( `Memory used during 1 parse: {memory(function() parse_holy(source) end)} KB\n` )

benchit.configure(1, 15.0, 0.05) -- 5% tolerance to reduce GC noise

benchit.run("parse holy gc-on ", parse_holy, source)

vm.gcstop()
benchit.run("parse holy gc-off", parse_holy, source)
vm.gcrestart()

benchit.run("parse holy no-ast", parse_nosync, source)
