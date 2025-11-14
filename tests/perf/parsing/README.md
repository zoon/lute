# Parsing Performance Benchmark

Benchmarking Luau parser performance on [holy.src](holy.src) (4,795 lines, ~194 KB).

## Critical Finding

**98% of parsing time is AST serialization, not actual parsing.**

The native Luau C++ parser is extremely fast (1.76 ms for 4,795 lines). However, converting the C++ AST to Luau tables still dominates performance (~82 ms).

| Component             | Time     | Percentage |
|-----------------------|----------|------------|
| **C++ parsing**       |  1.76 ms |  2.1%      |
| **AST serialization** | 81.99 ms | 97.9%      |
| **Total**             | 83.75 ms |  100%      |

**Key Metrics:**
- C++ parsing: **2.7M lines/sec** (`luau.parsenosync`)
- Full pipeline: **57K lines/sec** (`parser.parse`)
- Serialization overhead: **47x slowdown**
- Memory: **43 MB per parse** (Luau table creation)

## Quick Start

```bash
# Build release mode (required for accurate benchmarks)
cmake -B build/release -DCMAKE_BUILD_TYPE=Release
ninja -C build/release lute/cli/lute

# Run benchmark
./build/release/lute/cli/lute tests/perf/parsing/parsing.perf.luau
```

## Results (Release Build)

```
Memory used during 1 parse: 43795 KB

parse holy gc-on  "--[[MIT..."  81.56 ms/iter ±0.10%
parse holy gc-off "--[[MIT..."  93.26 ms/iter ±0.67%
parse holy no-ast "--[[MIT..."   1.78 ms/iter ±1.10%
```

**Observations:**
- Release build remains **~4.5x faster** than debug (375 ms -> 84 ms)
- Stopping GC makes each parse **~15% slower** due to heap bloat (~600 MB)
- The raw C++ parser still rivals C/C++ front-ends (< 2 ms for 4.8K LoC)
- Measurements were taken on a relatively old AMD mobile CPU; treat absolute timings accordingly and focus on the relative gaps between rows

### Memory Breakdown (~46 MB measured)

Profiled using [memprofile.luau](memprofile.luau):

| Component                        | Memory  | Percentage | Count      |
|----------------------------------|---------|------------|------------|
| **Positions** (line, column)     | 7.87 MB | 17.0%      | 73,709     |
| **Tokens** (hash nodes)          | 5.99 MB | 13.0%      | 30,219     |
| **Arrays** (array slots)         | 3.06 MB | 6.6%       | 66,762     |
| **Trivia** (comments/whitespace) | 2.99 MB | 6.5%       | 21,745     |
| **Locations** (begin/end)        | 2.32 MB | 5.0%       | 21,745     |
| **AST tables & misc.**           | ~6 MB   | ~13%       | 30,000+    |
| **Strings** (interned)           | 0.04 MB | <0.1%      | 859 unique |

**Top AST node types by count:**
- Expr:local: 8,116 nodes
- Pair (punctuated lists): 7,716 nodes
- AstLocal: 1,525 nodes
- Type:reference: 1,238 nodes
- Expr:call: 1,146 nodes

**Memory efficiency notes:**
- Position objects still dominate (~17%) because every token and node has location metadata
- Trivia arrays (leading/trailing) add another ~7% even if consumers ignore comments
- Strings are interned, so duplication is negligible after the first parse
- Total object count is ~95K (nodes + tokens + metadata), consuming ~46 MB per parse
- The size model is intentionally coarse; treat the ~28 MB estimate as a relative comparison tool rather than an absolute measurement (the remaining gap is Lua heap allocator overhead and other runtime bookkeeping we don't model)

## New APIs

Two APIs were added to enable this benchmark:

### GC Control (`@lute/vm`)

Control garbage collection for cleaner benchmarks:

```luau
local vm = require("@lute/vm")

vm.gcstop()       -- Stop GC
vm.gcrestart()    -- Resume GC
vm.gccollect()    -- Run full GC cycle
vm.gccount()      -- Heap size in KB
vm.gcisrunning()  -- Check if GC active
```


### Parse-Only API (`@lute/luau`)

Measure pure C++ parsing without serialization overhead:

```luau
local luau = require("@lute/luau")

-- Parse without creating Luau AST tables (returns line count only)
local lines = luau.parsenosync(source)
```

**Use cases:**
- Syntax validation without AST manipulation
- Measuring parser algorithm performance
- Comparing with other parsers

## Usage

```luau
local benchit = require("./benchit")
local parser = require("@std/syntax/parser")

-- Configure for GC-heavy workloads
benchit.configure(1, 15, 0.05)  -- min duration, max duration, 5% tolerance

-- Run benchmark
benchit.run("parse", parser.parse, source)

-- Or measure without printing
local result = benchit.measure(parser.parse, source)
print("Time:", result.sec_per_iter * 1000, "ms")
print("Iterations:", result.total_iter)
```

## Recommendations

    **For benchmarking:**
- Use release builds (4.6x faster)
- Use 5% tolerance for GC-heavy workloads (`benchit.configure(1, 15, 0.05)`)
- Pre-warm with `gccollect()` for stable baselines
- Compare same GC states (both with or both without)

## Files

**Test files:**
- [parsing.perf.luau](parsing.perf.luau) - Benchmark implementation
- [memprofile.luau](memprofile.luau) - Memory profiler for AST breakdown
- [holy.src](holy.src) - Test input (4,795 lines)
- [benchit.luau](benchit.luau) - Benchmarking framework

**C++ runtime:**
- [lute/vm/include/lute/vm.h](../../../lute/vm/include/lute/vm.h)
- [lute/vm/src/vm.cpp](../../../lute/vm/src/vm.cpp)
- [lute/luau/include/lute/luau.h](../../../lute/luau/include/lute/luau.h)
- [lute/luau/src/luau.cpp](../../../lute/luau/src/luau.cpp)

**Type definitions:**
- [definitions/vm.luau](../../../definitions/vm.luau)
- [definitions/luau.luau](../../../definitions/luau.luau)

---
## Acknowledgements
