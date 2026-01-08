# Proto-Zig Fuzzing Plan

## Quick Start

```bash
# Run seed-based fuzzer (deterministic, fast)
zig build fuzz -- decode 12345

# Run smoke tests (all fuzzers, CI gate)
zig build fuzz -- smoke

# Replay a crash
echo -ne '\x08\x96\x01' | zig build fuzz -- replay-decode

# Run native Zig fuzz tests (coverage-guided, no dependencies)
zig build fuzz-native
./zig-out/bin/fuzz-native-decode --cache-dir=.zig-cache

# Run AFL++ instrumented fuzzing (requires LLVM on the system)
zig build afl
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
./zig-out/AFLplusplus/bin/afl-fuzz -i src/fuzz/corpus -o fuzz/output/decode-instr -m none -t 1000 \
    -- ./zig-out/bin/afl-decode-instr
```

## Strategy Overview

This plan implements a **unified fuzzing architecture** combining:

1. **Seed-based fuzzing** (primary) - Pure Zig, no external dependencies, deterministic, CI-friendly
2. **Replay mode** (built-in) - Reproduce crashes from stdin using the same executable
3. **Native Zig fuzzing** (primary) - Built-in `std.testing.fuzz` with coverage guidance
4. **AFL++ integration** (optional) - Coverage-guided mutation using zig-afl-kit for extended campaigns

The design draws from:
- **upb (Google protobuf)**: Round-trip testing, domain constraints, MiniTable fuzzing
- **TigerBeetle**: Seed-based PRNG, model-based testing, swarm testing, build system integration
- **zig-afl-kit**: AFL++ integration patterns for Zig

## Architecture

### Unified Fuzzer Modules

Each fuzzer lives in a single file supporting all three modes:

**`src/fuzz/decode.zig`**
- `fuzz(input: []const u8)` - Core fuzzing function (used by native & replay)
- `run(FuzzArgs)` - Seed-based mode with PRNG
- `test "fuzz"` - Native fuzzer test with coverage instrumentation
- `test_schemas` - Schemas used by all modes

**`src/fuzz/roundtrip.zig`**
- Same structure as decode.zig
- Tests encode/decode consistency and idempotence

**`src/fuzz/varint.zig`**
- Same structure as decode.zig
- Tests low-level varint primitives

**`src/fuzz/corpus.zig`** - Shared corpus
- `corpus.protobuf` - Protobuf message test cases (loaded via @embedFile)
- `corpus.varint` - Varint-specific test cases
- Files loaded from `src/fuzz/corpus/*.bin`

### Main Fuzzer Executable

**`src/fuzz_tests.zig`** - Single executable with CLI dispatch

```zig
pub fn main() !void {
    const args = parseArgs();
    switch (args.fuzzer) {
        // Seed-based modes
        .decode => try decode.run(args),
        .roundtrip => try roundtrip.run(args),
        .varint => try varint.run(args),

        // Replay modes
        .replay_decode => try runReplay(decode.fuzz),
        .replay_roundtrip => try runReplay(roundtrip.fuzz),
        .replay_varint => try runReplay(varint.fuzz),

        // Meta modes
        .smoke => try runSmoke(),
        .canary => return error.CanaryFailed,
    }
}
```

## Usage

### Seed-Based Fuzzing

Deterministic pseudo-random fuzzing for reproducibility:

```bash
# Run decode fuzzer with specific seed
zig build fuzz -- decode 12345

# Run with event limit
zig build fuzz -- roundtrip --events-max=100000

# Random seed (uses system entropy)
zig build fuzz -- varint
```

### Smoke Tests

Quick sanity check for CI:

```bash
# Run all fuzzers briefly
zig build fuzz -- smoke
```

Output:
```
=== Proto-zig Fuzzer ===
Target: smoke

--- Running smoke tests ---

[1/3] decode...
Fuzzing with seed: 12345
Events max: 10000
Completed: 10000 events in 0s
[1/3] decode: OK

[2/3] roundtrip...
[...]
```

### Replay Mode

Reproduce crashes from crashes found by any fuzzer:

```bash
# Replay from file
zig build fuzz -- replay-decode < crash.bin

# Replay inline
echo -ne '\x08\x96\x01' | zig build fuzz -- replay-decode

# Replay AFL++ crash
zig build fuzz -- replay-decode < fuzz/output/decode-instr/default/crashes/id:000000,...
```

### Native Zig Fuzzing

Coverage-guided fuzzing using Zig's built-in fuzzer (recommended for extended fuzzing):

```bash
# Build all native fuzz tests
zig build fuzz-native

# Run decode fuzzer (runs until crash or manual stop)
./zig-out/bin/fuzz-native-decode --cache-dir=.zig-cache

# Run roundtrip fuzzer
./zig-out/bin/fuzz-native-roundtrip --cache-dir=.zig-cache

# Run varint fuzzer
./zig-out/bin/fuzz-native-varint --cache-dir=.zig-cache
```

Native fuzzing uses the initial corpus from `src/fuzz/corpus/*.bin` and mutates it with coverage feedback.

### AFL++ Instrumented Fuzzing

For advanced coverage-guided fuzzing campaigns:

```bash
# Build AFL++ instrumented binaries
zig build afl

# Run decode fuzzer
mkdir -p fuzz/output/decode-instr
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
./zig-out/AFLplusplus/bin/afl-fuzz \
    -i src/fuzz/corpus \
    -o fuzz/output/decode-instr \
    -m none \
    -t 1000 \
    -- ./zig-out/bin/afl-decode-instr

# Run roundtrip fuzzer
mkdir -p fuzz/output/roundtrip-instr
AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
./zig-out/AFLplusplus/bin/afl-fuzz \
    -i src/fuzz/corpus \
    -o fuzz/output/roundtrip-instr \
    -m none \
    -t 1000 \
    -- ./zig-out/bin/afl-roundtrip-instr
```

## Seed Corpus

Corpus files are located in `src/fuzz/corpus/`:

| File | Description |
|------|-------------|
| `empty.bin` | Empty message |
| `int32_simple.bin` | Single int32 field (value 1) |
| `int32_150.bin` | Multi-byte varint (value 150) |
| `int32_max.bin` | Maximum int32 value |
| `int64_simple.bin` | Single int64 field |
| `string_hello.bin` | String field ("hello") |
| `bytes_simple.bin` | Bytes field |
| `multi_field.bin` | Multiple fields |
| `fixed32_1.bin` | Fixed32 field |
| `fixed64_1.bin` | Fixed64 field |

These files are:
- Embedded at compile time via `@embedFile` for native/seed-based fuzzers
- Read at runtime by AFL++ from the same location
- Shared across all fuzzer modes (single source of truth)

## Adding a New Fuzzer

To add a new fuzzer, only **3 steps** are required:

### 1. Create Fuzzer Module

Create `src/fuzz/new_fuzzer.zig`:

```zig
const std = @import("std");
const fuzz_util = @import("../testing/fuzz.zig");
const proto = @import("proto");
const shared_corpus = @import("corpus.zig");

/// Core fuzzing function - used by native fuzzer and replay mode
pub fn fuzz(input: []const u8) !void {
    // Your fuzzing logic here
    _ = input;
}

/// Seed-based fuzzing mode
pub fn run(args: fuzz_util.FuzzArgs) !void {
    var ctx = fuzz_util.FuzzContext.init(args);
    var prng = fuzz_util.FuzzPrng.init(args.seed);

    var input_buffer: [4096]u8 = undefined;

    while (ctx.shouldContinue()) {
        // Generate random input
        const len = prng.int_exponential(u32, 64);
        prng.bytes(input_buffer[0..@min(len, input_buffer.len)]);

        // Test it
        try fuzz(input_buffer[0..@min(len, input_buffer.len)]);

        ctx.recordEvent();
    }

    ctx.finish();
}

/// Native Zig fuzz test
test "fuzz" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            try fuzz(input);
        }
    }.testOne, .{
        .corpus = &shared_corpus.protobuf,
    });
}
```

### 2. Register in Main Dispatcher

Edit `src/fuzz_tests.zig`:

```zig
// Add import
const new_fuzzer = @import("fuzz/new_fuzzer.zig");

// Add to Fuzzer enum
pub const Fuzzer = enum {
    // ... existing fuzzers
    new_fuzzer,
    replay_new_fuzzer,
    // ...
};

// Add to run() switch
pub fn run(self: Fuzzer, args: fuzz.FuzzArgs) anyerror!void {
    switch (self) {
        // ...
        .new_fuzzer => try new_fuzzer.run(args),
        .replay_new_fuzzer => try runReplay(new_fuzzer.fuzz),
        // ...
    }
}

// Add to smokeEventsMax() switch
pub fn smokeEventsMax(self: Fuzzer) usize {
    return switch (self) {
        // ...
        .new_fuzzer => 10_000,
        // ...
    };
}
```

### 3. Add Build Target

Edit `build.zig`:

```zig
// Add native fuzz test
buildNativeFuzzTest(b, "fuzz-native-new-fuzzer", "src/fuzz/new_fuzzer.zig", proto_module, target);

// Add to fuzz-native step
if (b.top_level_steps.get("fuzz-native-new-fuzzer")) |step| {
    fuzz_native_step.dependOn(&step.step);
}
```

That's it! Your new fuzzer now supports:
- Seed-based mode: `zig build fuzz -- new-fuzzer 12345`
- Replay mode: `zig build fuzz -- replay-new-fuzzer < crash.bin`
- Native fuzzing: `./zig-out/bin/fuzz-native-new-fuzzer --fuzz`
- Smoke tests: Automatically included

## File Structure

```
src/
├── fuzz_tests.zig          # Main unified fuzzer executable
├── testing/
│   └── fuzz.zig            # Utilities (PRNG, args, context)
└── fuzz/
    ├── decode.zig          # Unified decode fuzzer (all modes)
    ├── roundtrip.zig       # Unified roundtrip fuzzer (all modes)
    ├── varint.zig          # Unified varint fuzzer (all modes)
    ├── corpus.zig          # Shared corpus definitions
    ├── corpus/             # Corpus files (embedded at compile time)
    │   ├── empty.bin
    │   ├── int32_simple.bin
    │   └── ...
    ├── afl_decode.zig      # AFL++ harness (decode)
    └── afl_roundtrip.zig   # AFL++ harness (roundtrip)

fuzz/
└── output/                 # AFL++ output (crashes, queue)

build.zig                   # Build config with AFL++ integration
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Unified fuzzer modules | Each fuzzer in one file, all modes supported, easy to maintain |
| Single main executable | Seed-based + replay in one binary, simple CLI |
| Shared corpus module | Single source of truth, embedded at compile time |
| @embedFile for corpus | Works across module boundaries, no file I/O at runtime |
| Replay via stdin | Standard pattern, works with any fuzzer output |
| Native Zig fuzzing separate | Requires special compilation (.fuzz = true) |
| AFL++ harnesses separate | Different architecture (persistent mode, C FFI) |
| Hyphen-to-underscore mapping | User-friendly CLI (replay-decode) → Zig-friendly enum (replay_decode) |

## Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| Unified fuzzer architecture | ✅ Complete | decode.zig, roundtrip.zig, varint.zig |
| Seed-based fuzzing | ✅ Complete | Deterministic PRNG-based |
| Replay mode | ✅ Complete | Built into main executable |
| Shared corpus | ✅ Complete | @embedFile from src/fuzz/corpus/ |
| Native Zig fuzzing | ✅ Complete | Using `std.testing.fuzz` |
| AFL++ integration | ✅ Complete | Using zig-afl-kit with persistent mode |
| Smoke test | ✅ Complete | CI-ready |
| Model-based testing | ⏳ Pending | Future enhancement |

## Next Steps

1. **High**: Add smoke test to CI pipeline
2. **High**: Investigate and fix any bugs found by fuzzers
3. **Medium**: Add more corpus files as edge cases are discovered
4. **Medium**: Model-based testing for roundtrip
5. **Lower**: Extended AFL++ campaigns (multi-core, longer runs)
