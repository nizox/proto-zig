# Proto-Zig Fuzzing Plan

## Strategy Overview

This plan implements a **hybrid fuzzing approach** combining:

1. **TigerBeetle-style seed-based fuzzing** (primary) - Pure Zig, no external dependencies, easy CI integration
2. **Optional AFL++ integration** (secondary) - Coverage-guided mutation for deeper bug finding

The design draws from:
- **upb (Google protobuf)**: Round-trip testing, domain constraints, MiniTable fuzzing
- **TigerBeetle**: Seed-based PRNG, model-based testing, swarm testing, build system integration
- **zig-afl-kit**: AFL++ integration patterns for Zig

## Phase 1: Core Fuzzing Infrastructure

### `src/testing/fuzz.zig` - Fuzzing Utilities Library

Core components:
- `FuzzArgs` struct with seed and events_max
- `random_int_exponential()` for realistic value distribution
- `random_enum_weights()` for swarm testing
- Seed parsing (u64, hex git hash support)
- Memory limiting for leak detection

### `src/fuzz_tests.zig` - Main Fuzzer Dispatcher

Single executable with CLI dispatch pattern:
```zig
pub fn main() !void {
    const args = parseArgs();
    switch (args.fuzzer) {
        .decode => decode_fuzz.main(gpa, args),
        .roundtrip => roundtrip_fuzz.main(gpa, args),
        .varint => varint_fuzz.main(gpa, args),
        .smoke => runSmokeTests(),
    }
}
```

Usage:
```bash
zig build fuzz -- decode 12345      # Run decode fuzzer with seed
zig build fuzz -- smoke             # Run all fuzzers briefly
zig build fuzz -- roundtrip         # Random seed
```

## Phase 2: Fuzz Targets

### Target 1: Decode Fuzzer (`src/fuzz/decode_fuzz.zig`)

**Priority: High**

- Feed arbitrary bytes to `wire.decode()`
- Verify no crashes, OOB access, or hangs
- Test all DecodeError paths are reachable
- Vary decode options: `max_depth`, `check_utf8`, `alias_string`

### Target 2: Encode/Decode Round-Trip (`src/fuzz/roundtrip_fuzz.zig`)

**Priority: High**

- Generate random valid messages using schema
- Encode → Decode → Verify equality
- Test idempotence: `encode(decode(encode(msg))) == encode(msg)`
- Inspired by upb's JSON codec fuzzer

### Target 3: Varint Fuzzer (`src/fuzz/varint_fuzz.zig`)

**Priority: Medium**

- Test edge cases: 0, 127, 128, max values, overflow
- Verify zigzag encoding roundtrips
- Test truncated varint handling

### Target 4: Wire Reader Fuzzer (`src/fuzz/reader_fuzz.zig`)

**Priority: Medium**

- Arbitrary bytes → `read_tag()`, `skip_field()`, `read_varint()`
- Verify graceful handling of malformed input

### Target 5: Message Builder Fuzzer (`src/fuzz/message_fuzz.zig`)

**Priority: Lower**

- Generate random MiniTable schemas
- Build messages with random field values
- Similar to upb's MiniTableFuzzInput approach

## Phase 3: Build System Integration

### `build.zig` Updates

```zig
// Add fuzz executable
const fuzz_exe = b.addExecutable(.{
    .name = "fuzz",
    .root_source_file = b.path("src/fuzz_tests.zig"),
});
fuzz_exe.stack_size = 4 * 1024 * 1024; // 4 MiB for deep recursion

const fuzz_step = b.step("fuzz", "Run fuzz tests");
```

### CI Integration

- Smoke test runs all fuzzers with limited iterations
- `zig build fuzz -- smoke` as CI gate
- Failures block merges

## Phase 4: Model-Based Testing

For roundtrip testing, implement a reference model:

```zig
const Model = struct {
    fields: std.AutoHashMap(u32, FieldValue),

    pub fn apply(self: *Model, op: FuzzOp) void { ... }
    pub fn verify(self: *Model, actual: *Message) bool { ... }
};
```

Operation sequences for testing:
```zig
const FuzzOp = union(enum) {
    set_field: struct { field_num: u32, value: FieldValue },
    clear_field: u32,
    encode_decode_roundtrip,
    partial_decode: struct { bytes_to_truncate: u32 },
};
```

## Phase 5: Optional AFL++ Integration

### `src/fuzz/afl_harness.zig`

For coverage-guided fuzzing campaigns:

```zig
export fn zig_fuzz_init() callconv(.c) void {
    // Initialize arena allocator
}

export fn zig_fuzz_test(buf: [*]u8, len: isize) callconv(.c) void {
    const input = buf[0..@intCast(len)];
    var arena = Arena.init(backing_buffer);
    _ = decode(input, &msg, &arena, .{}) catch return;
}
```

Integration via zig-afl-kit for serious fuzzing campaigns.

## File Structure

```
src/
├── fuzz_tests.zig          # Main dispatcher
├── testing/
│   └── fuzz.zig            # Utilities (random, swarm, args)
└── fuzz/
    ├── decode_fuzz.zig     # Raw bytes → decode
    ├── roundtrip_fuzz.zig  # encode ↔ decode
    ├── varint_fuzz.zig     # Varint edge cases
    ├── reader_fuzz.zig     # Wire reader primitives
    ├── message_fuzz.zig    # Schema + message building
    └── afl_harness.zig     # AFL++ integration (optional)
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Seed-based primary | No external dependencies, reproducible, CI-friendly |
| Single fuzz executable | Follows TigerBeetle pattern, easy management |
| Model-based testing | Catches semantic bugs, not just crashes |
| Swarm testing | Random variant weighting prevents blind spots |
| 4 MiB stack | Handles deep message nesting |
| AFL++ optional | Coverage-guided for intensive campaigns |

## Implementation Priority

1. **High**: Decode fuzzer (catches most parser bugs)
2. **High**: Round-trip fuzzer (catches encode/decode mismatches)
3. **Medium**: Varint/reader fuzzers (low-level primitives)
4. **Medium**: Smoke test CI integration
5. **Lower**: AFL++ integration (for extended campaigns)

## Expected Bug Classes

- Buffer overflows in reader
- Infinite loops on malformed varint
- Stack overflow on deeply nested messages
- UTF-8 validation bypasses
- Memory corruption in repeated field handling
- Inconsistent encode/decode for edge cases
