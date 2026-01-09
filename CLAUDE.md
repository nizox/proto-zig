# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

proto-zig is a standalone Protocol Buffers implementation in Zig, inspired by upb (micro protobuf). It provides binary wire format encoding/decoding with runtime reflection via MiniTable, using arena-based memory allocation without requiring allocators after initialization.

## Version Control

This repository uses jj (Jujutsu) for version control, not git. Use `jj` commands instead of `git` commands.

## Build Commands

```bash
# Build library and conformance runner
zig build

# Run unit tests (includes proto tests and fuzz infrastructure tests)
zig build test

# Check if code compiles without full build
zig build check

# Build conformance test runner
zig build
# Then run with protobuf test suite:
# /path/to/protobuf/bazel-bin/conformance/conformance_test_runner ./zig-out/bin/conformance_zig
```

## Fuzzing

Multiple fuzzing strategies are available:

### Unified Fuzz Executable
```bash
# Seed-based fuzzing (deterministic pseudo-random)
zig build fuzz -- decode [seed] [--events-max=N]
zig build fuzz -- roundtrip [seed] [--events-max=N]
zig build fuzz -- varint [seed] [--events-max=N]

# Replay crashes from stdin
zig build fuzz -- replay-decode < crash.bin
zig build fuzz -- replay-roundtrip < crash.bin
zig build fuzz -- replay-varint < crash.bin

# Run quick smoke test of all fuzzers
zig build fuzz -- smoke
```

### Native Zig Fuzzing
```bash
# Build native fuzz tests (uses Zig's built-in fuzzing)
zig build fuzz-native-decode
zig build fuzz-native-roundtrip
zig build fuzz-native-varint
zig build fuzz-native  # Build all

# Run with --fuzz flag
./zig-out/bin/fuzz-native-decode --fuzz
```

### AFL++ Fuzzing
```bash
# Build AFL++ instrumented executables
zig build afl  # Builds afl-decode-instr and afl-roundtrip-instr
```

## Architecture

### Core Components

**Arena (`arena.zig`)**: Fixed-buffer bump-pointer allocator. All memory allocated at initialization with fixed upper bounds. Memory freed all at once via reset, no individual frees. Follows Tiger Style principles.

**MiniTable (`mini_table.zig`)**: Compact binary representation of message schemas describing field layout, types, and wire encoding. Similar to upb's MiniTable design.

**Message (`message.zig`)**: Runtime representation of protobuf messages with reflection-based field access. Uses StringView for zero-copy string decoding option. Contains RepeatedField for dynamic arrays.

**Wire Protocol (`wire/`)**:
- `types.zig`: Wire type enums and tags
- `reader.zig`: Low-level wire format reading (varints, fixed values)
- `decode.zig`: Message decoder from binary to Message
- `encode.zig`: Message encoder from Message to binary

**Bootstrap (`descriptor/bootstrap.zig`)**: Schema definitions for conformance test messages.

### Data Flow

1. Initialize Arena with pre-allocated buffer
2. Create Message using MiniTable schema
3. Decode binary protobuf into Message via wire.decode
4. Access fields via Message methods (get_scalar, get_string, get_repeated)
5. Encode Message back to binary via wire.encode

### Key Design Principles

- **Zero-copy**: StringView optionally aliases input buffer to avoid string copies
- **Fixed bounds**: Arena uses fixed buffer, no dynamic allocation after init
- **Runtime reflection**: MiniTable enables generic encode/decode without generated code
- **Zig zen**: Follow Zig's design principles for code style and architecture

## Testing Strategy

**Unit tests**: Inline tests throughout modules, run via `zig build test`

**Conformance tests**: Validates against official protobuf test suite. Currently 1163/1199 binary tests passing (97%). 36 failures require schema-dependent validation of packed fields and submessages.

**Fuzz tests**: Multiple fuzzing approaches (seed-based, native Zig, AFL++) test decoder/encoder robustness. Fuzz infrastructure has its own unit tests.

## Known Limitations

- JSON and text format not implemented (1390 conformance tests skipped)
- 36 conformance tests fail due to missing schema validation for packed fields and submessage contents
- Requires MiniTable definitions for message types (bootstrap.zig provides conformance test schemas)
