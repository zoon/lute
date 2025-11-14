--!strict
--!optimize 2

-- Copyright (c) 2025 Andrei Zhilin
--
-- This work is hereby released into the public domain.
-- It may be used, copied, modified, and distributed without restriction.

--[=[
A simple benchmarking harness for Luau.
Inspired by Criterion.rs "Quick Mode"

Usage:

```luau
local benchit = require("./benchit")

-- Simple benchmark
local function fib(n: number): number
    if n <= 1 then return n end
    return fib(n - 1) + fib(n - 2)
end

for arg = 20, 30, 2 do
    benchit.run("fibonacci of", fib, arg)
end

-- Measure without printing
local summary = benchit.measure(fib, 25)
print("Time per iteration:", summary.sec_per_iter)

-- Compare multiple approaches
benchit.compare(100, {
    ["approach A"] = function(n) return some_algo(n) end,
    ["approach B"] = function(n) return other_algo(n) end,
})

-- Configure benchmark parameters (defaults: 100us, 5s, 2% rel. stddev)
benchit.configure(1.0, 15.0, 0.05) -- (1s min, 15s max, 5% rel. stddev)
```
--]=]

-- stylua: ignore start

local PRINTER: (msg: string) -> () = print

local m = {}

function m.set_printer(printer: (msg: string) -> ()) PRINTER = printer end
function m.reset_printer() PRINTER = print end

type Fn = (any) -> any

local MIN_BENCH_DURATION = 0.100 -- 100 ms
local MAX_BENCH_DURATION = 5.0 -- seconds
local TARGET_REL_STDDEV = 0.02 -- 2%

local _SINK = nil

local function _barrier()
	-- just some gibberish to prevent optimization
	if _SINK == nil then _SINK = false end
	return _SINK
end

-- Ordinary Least Squares regression through origin: y = kx
-- Returns slope k (seconds per iteration)
local function _ols_slope(iters: { number }, elapsed: { number }): number
	local sum_x2, sum_xy = 0, 0
	for i = 1, #iters do
		local x, y = iters[i], elapsed[i]
		sum_x2 = sum_x2 + x * x
		sum_xy = sum_xy + x * y
	end
	return sum_xy / sum_x2
end

local function _sample(routine: Fn, n: number, param: any)
	local start = os.clock()
	for i = 1, n do
		_SINK = routine(param)
	end
	local dt = os.clock() - start
	return dt, _barrier()
end

local function _bench(fn: Fn, parameter): BenchSummary
	local time_start = os.clock()

	local n = 1
	local total_iter = n
	local t_prev = _sample(fn, n, parameter)

	-- Early exit for extremely long-running benchmarks
	if (os.clock() - time_start) > MAX_BENCH_DURATION then
		-- Synthetic duplicate sample to avoid division issues
		local iters = { n, n }
		local elapsed = { t_prev, t_prev + 1e-6 }
		local per_iter = _ols_slope(iters, elapsed)
		return {
			sec_per_iter = per_iter,
			rel_noise = 0,
			total_iter = total_iter,
			warn = "<timeout>",
		}
	end

	-- Main data collection loop
	while true do
		local t_now = _sample(fn, n * 2, parameter)
		total_iter += (n * 2)
		-- OLS slope through origin from (1,t_prev), (2,t_now): time per block.
		local k = (t_prev + 2.0 * t_now) / 5.0
		local stdev = math.sqrt((t_prev - k) ^ 2 + (t_now - 2.0 * k) ^ 2)
		local elapsed_wall = os.clock() - time_start
		if
			(stdev < TARGET_REL_STDDEV * k and elapsed_wall > MIN_BENCH_DURATION)
			or elapsed_wall > MAX_BENCH_DURATION
		then
			local iters = { n, n * 2 }
			local elapsed = { t_prev, t_now }
			local per_iter = _ols_slope(iters, elapsed)
			-- Residual norm and relative noise
			local rss = 0
			for i = 1, #iters do
				local pred = per_iter * iters[i]
				local r = elapsed[i] - pred
				rss = rss + r * r
			end
			local rel_noise = math.sqrt(rss) / (per_iter * iters[1])
			local timeout = (stdev > TARGET_REL_STDDEV * k)
			local warn = ""
			if timeout then
				warn = "<timeout>"
			elseif rel_noise >= TARGET_REL_STDDEV then
				warn = "<unstable>"
			end
			return {
				sec_per_iter = per_iter,
				rel_noise = rel_noise,
				total_iter = total_iter,
				warn = warn,
			}
		end
		n = n * 2
		t_prev = t_now
	end
end

-- stylua: ignore
local function _fmt_time(seconds: number): string
	local ns = seconds * 1e9
	if ns < 1e3 then return string.format("%.2f ns", ns) end; ns /= 1000
	--- @note: use 'us', not 'μs' as it may be different width in some terminals
	if ns < 1e3 then return string.format("%.2f us", ns) end; ns /= 1000
	if ns < 1e3 then return string.format("%.2f ms", ns) end; ns /= 1000
	return string.format("%.2f s", ns)
end

--- Format duration in seconds to human-readable time string.
--- @param seconds number Duration in seconds.
--- @return string Formatted time string (e.g., "12.34 ms", "5.67 us").
function m.fmt_time(seconds: number): string
	return _fmt_time(seconds)
end

-- stylua: ignore
local function _fmt_num(v: number): string
	if math.floor(v) == v then
		local vlg2 = math.log(v, 2)
		if v > 0 and vlg2 == math.floor(vlg2) then
			if v < 1024 then return string.format("%d ", v) end; v /= 1024
			if v < 1024 then return string.format("%dK", v) end; v /= 1024
			if v < 1024 then return string.format("%dM", v) end; v /= 1024
			return string.format("%dG", v)
		else
			return string.format("%d", v)
		end
	end
	return string.format("%g", v)
end

-- stylua: ignore
local function _fmt_table<a...>(tab: {})
	local c = 0; for _ in tab::any do c += 1 end
	return if c == #tab then `array[{c}]` else `table[{c}]`
end

-- stylua: ignore
local function _fmt_fun<a...>(f: (a...)->...any)
	local name, arity, varadic = debug.info(f, "na")
	if name == "" then name = "<function>" end
	return `{name}{if arity == 0 then "" else "/" .. arity::any}{if not varadic then "" else "/..."}`
end

--stylua: ignore
local function _fmt_arg(arg: any): string
	local t = typeof(arg)
	if t == "nil" then return "" end
	if t == "string" then return if #arg > 10 then string.format("%q", arg:sub(1, 7) .. "...") else string.format("%q", arg) end
	if t == "number" then return _fmt_num(arg) end
	if t == "table" then return _fmt_table(arg) end
	if t == "function" then return _fmt_fun(arg) end
	if t == "buffer" then return `buffer[{_fmt_num(buffer.len(arg))}]` end
	return tostring(t).. ":" .. t
end

--- Summary statistics produced by the benchmark.
--- @field sec_per_iter number Estimated seconds per iteration
--- @field rel_noise number Approximate relative standard deviation
--- @field total_iter number Total iterations executed across samples
--- @field warn? string Optional warning marker ("<timeout>" or "<unstable>")
export type BenchSummary = {
	sec_per_iter: number,
	rel_noise: number,
	total_iter: number,
	warn: string,
}

--- Comparison result for a single routine.
--- @field tag string Label for this routine
--- @field summary BenchSummary Benchmark results
export type CompareResult = {
	tag: string,
	summary: BenchSummary,
}

local function fmt_summary(s: BenchSummary): string
	local warn = if s.warn ~= "" then " " .. s.warn else ""
	return string.format(
		"%9s/iter ±%.2f%%%s",
		_fmt_time(s.sec_per_iter),
		s.rel_noise * 100.0,
		warn
	)
end

--- Run a quick benchmark and print a one-line summary.
--- @param tag string Label for the benchmark row.
--- @param routine fun(arg:any):any Function under test; returns are discarded.
--- @param arg? any Optional argument passed to the routine.
function m.run(tag: string, routine: Fn, arg: any?)
	local summary = _bench(routine, arg)
	local arg_fmt = _fmt_arg(arg)
	local label = if arg_fmt ~= "" then tag .. " " .. arg_fmt else tag
	PRINTER(string.format("%-30s %*", label, fmt_summary(summary)))
end

--- Measure a benchmark without printing results.
--- @param routine fun(arg:any):any Function under test.
--- @param arg? any Optional argument passed to the routine.
--- @return BenchSummary Summary of timing results.
function m.measure(routine: Fn, arg: any?): BenchSummary
	return _bench(routine, arg)
end

--- @deprecated alias for backward compatibility
m.sample = m.measure

--- Configure benchmark timing parameters.
--- @param min_duration? number Minimum benchmark duration in seconds (default: 0.1).
--- @param max_duration? number Maximum benchmark duration in seconds (default: 5.0).
--- @param target_rel_stddev? number Target relative standard deviation (default: 0.02).
function m.configure(min_duration: number?, max_duration: number?, target_rel_stddev: number?)
	if min_duration then MIN_BENCH_DURATION = min_duration end
	if max_duration then MAX_BENCH_DURATION = max_duration end
	if target_rel_stddev then TARGET_REL_STDDEV = target_rel_stddev end
end

--- Get current benchmark configuration.
--- @return number min_duration Minimum benchmark duration in seconds.
--- @return number max_duration Maximum benchmark duration in seconds.
--- @return number target_rel_stddev Target relative standard deviation.
function m.get_config(): (number, number, number)
	return MIN_BENCH_DURATION, MAX_BENCH_DURATION, TARGET_REL_STDDEV
end

--- Measure and compare multiple routines without printing.
--- @param arg? any Argument passed to all routines.
--- @param routines {[string]: Fn} Table mapping tags to routines.
--- @return {CompareResult} Array of results sorted by speed (fastest first).
function m.measure_compare(arg: any?, routines: { [string]: Fn }): { CompareResult }
	-- Validate input
	if type(routines) ~= "table" then
		error(`Expected routines to be a table, got {type(routines)}`, 2)
	end

	-- Collect benchmark results
	local results: { CompareResult } = {}
	for tag, routine in routines do
		if type(routine) ~= "function" then
			error(`Expected routine for "{tag}" to be a function, got {type(routine)}`, 2)
		end
		local summary = _bench(routine, arg)
		table.insert(results, { tag = tag, summary = summary })
	end

	-- Sort by speed (fastest first)
	table.sort(results, function(a: any, b: any) return a.summary.sec_per_iter < b.summary.sec_per_iter end)

	return results
end

--- Compare multiple routines with the same argument and print results.
--- @param arg? any Argument passed to all routines.
--- @param routines {[string]: Fn} Table mapping tags to routines.
function m.compare(arg: any?, routines: { [string]: Fn })
	local results = m.measure_compare(arg, routines)

	-- Handle edge cases
	if #results == 0 then
		PRINTER("No routines to compare")
		return
	end

	if #results == 1 then
		local result = results[1]
		local arg_fmt = _fmt_arg(arg)
		local label = if arg_fmt ~= "" then result.tag .. " " .. arg_fmt else result.tag
		PRINTER(string.format("%-30s %*", label, fmt_summary(result.summary)))
		return
	end

	-- Print header
	local arg_fmt = _fmt_arg(arg)
	local header = if arg_fmt ~= "" then `Comparing with {arg_fmt}:` else "Comparing:"
	PRINTER(header)

	-- Print results with comparison
	local baseline = results[1].summary.sec_per_iter
	for i, result in results do
		local tag = result.tag
		local summary = result.summary
		local time_str = fmt_summary(summary)

		if i == 1 then
			-- Fastest is baseline
			PRINTER(string.format("  %-30s %* [baseline]", tag, time_str))
		else
			-- Show relative performance
			local ratio = summary.sec_per_iter / baseline
			local rel_str = string.format("(%.2fx slower)", ratio)
			PRINTER(string.format("  %-30s %* %s", tag, time_str, rel_str))
		end
	end
end
-- stylua: ignore end

return m
