# CLAUDE.md

Development guide for proto-zig, a Protocol Buffers implementation in Zig inspired by upb.

## Development Workflow (Mandatory)

Follow this workflow for all changes:

### 1. ADR First

Write an Architecture Decision Record before implementing:

- Create `docs/adr/NNNN-title.md` for new decisions
- Identify which component is modified: library, codegen, conformance tests, fuzz tests
- Derive implementation plan from the ADR
- ADR is a living doc - update when architecture, constraints, or requirements change

### 2. Reference UPB Implementation

Check upb's implementation before proposing a solution:

- Read upb source code in `/home/bits/gh/google/protobuf/upb/`
- Consult upb design docs for architectural decisions
- Understand why upb made specific choices before diverging

### 3. Zig Zen

Keep implementation simple:

- Early return for errors
- Explicit error handling
- No hidden control flow
- Prefer simple over clever

### 4. Tests First

Write tests before implementation:

- Add new test cases for the changed functionality
- Unit tests for pure logic
- Fuzz tests for code processing arbitrary data
- Differential tests for decode/encode changes (compare against upb)
- `zig build test` should run all tests (except slow tests that are using dedicated targets)

### Pre-Commit Checklist

Before writing a jj description:

- [ ] Tests passing (`zig build test`)
- [ ] README.md updated with short changelog entry
- [ ] CLAUDE.md updated if development workflow changed

### Helpful Tips

- Check Zig standard library (`/usr/lib/zig/std/`) to verify usage is correct
- ADR files are in `docs/adr/` as markdown files

## Version Control

This repository uses **jj (Jujutsu)**, not git. Use `jj` commands for all version control operations.

## Build Commands

```bash
zig build              # Build library and conformance runner
zig build test         # Run unit tests
zig build check        # Check compilation without full build
```

## Code Generation

The `protoc-gen-zig-pb` plugin generates MiniTable definitions from .proto files.

```bash
zig build update-proto                           # Generate from .proto files
zig build update-proto -Dprotoc=/path/to/protoc  # Custom protoc binary
zig build test-codegen-integration               # Run codegen integration tests
```

**Generated files:**
- `plugin.proto` → `src/generated/plugin.pb.zig`
- `conformance.proto` → `src/generated/conformance.pb.zig`

**Not generated (hand-coded bootstrap):**
- `descriptor.proto` - Uses proto2 features; see `src/descriptor/bootstrap.zig`

## Conformance Testing

```bash
# Build conformance runner
zig build

# Run against official test suite (requires protobuf repo with bazel)
/path/to/protobuf/bazel-bin/conformance/conformance_test_runner ./zig-out/bin/conformance_zig
```

Current status: 1163/1199 binary tests passing (97%). 36 failures require schema-dependent validation.

## Differential Testing

Compare proto-zig decode/encode against upb reference implementation.

```bash
# Build upb first (requires bazelisk)
cd /home/bits/gh/google/protobuf
bazelisk build //upb:amalgamation //third_party/utf8_range:utf8_range

# Run differential tests
zig build test-differential
```

### Regenerating Test Schema MiniTables

When modifying `src/testing/test_message.proto`, regenerate both proto-zig and upb MiniTables:

```bash
# Build upb protoc plugins (one-time, from protobuf repo)
cd /home/bits/gh/google/protobuf
bazelisk build //upb_generator/c:protoc-gen-upb //upb_generator/minitable:protoc-gen-upb_minitable

# Generate proto-zig MiniTable (from proto-zig repo)
cd /home/bits/gh/nizox/proto-zig
protoc -Isrc/testing --zig-pb_out=src/testing \
  --plugin=protoc-gen-zig-pb=zig-out/bin/protoc-gen-zig-pb \
  src/testing/test_message.proto

# Generate upb MiniTables (from proto-zig repo)
protoc -I. --upb_out=. --upb_minitable_out=. \
  --plugin=protoc-gen-upb=/home/bits/gh/google/protobuf/bazel-bin/upb_generator/c/protoc-gen-upb \
  --plugin=protoc-gen-upb_minitable=/home/bits/gh/google/protobuf/bazel-bin/upb_generator/minitable/protoc-gen-upb_minitable \
  src/testing/test_message.proto
```

**Generated files:**
- `src/testing/test_message.pb.zig` - proto-zig MiniTable
- `src/testing/test_message.upb.h` - upb message accessors
- `src/testing/test_message.upb.c` - upb message implementation
- `src/testing/test_message.upb_minitable.h` - upb MiniTable header
- `src/testing/test_message.upb_minitable.c` - upb MiniTable implementation

See `docs/adr/0001-differential-testing-with-upb.md` for architecture details.

## Fuzzing

### Unified Fuzz Executable

```bash
# Seed-based fuzzing
zig build fuzz -- decode [seed] [--events-max=N]

# Replay crashes
zig build fuzz -- replay-decode < crash.bin

# Smoke test (CI gate)
zig build fuzz -- smoke
```

### Native Zig Fuzzing

```bash
zig build fuzz-native              # Build all native fuzz tests
./zig-out/bin/fuzz-native-decode --fuzz
```

### AFL++ Fuzzing

```bash
zig build afl  # Build instrumented binaries

AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
./zig-out/AFLplusplus/bin/afl-fuzz -i src/fuzz/corpus -o fuzz/output/decode-instr -m none -t 1000 \
    -- ./zig-out/bin/afl-decode-instr
```

### Adding a New Fuzzer

1. Create `src/fuzz/new_fuzzer.zig` with `fuzz()`, `run()`, and `test "fuzz"` functions
2. Register in `src/fuzz_tests.zig` (add to Fuzzer enum and switch statements)
3. Add build target in `build.zig`

## Architecture

### Core Components

| Component | File | Purpose |
|-----------|------|---------|
| Arena | `arena.zig` | Fixed-buffer bump-pointer allocator |
| MiniTable | `mini_table.zig` | Compact schema representation |
| Message | `message.zig` | Runtime message with reflection |
| Wire Reader | `wire/reader.zig` | Low-level varint/fixed reading |
| Decoder | `wire/decode.zig` | Binary → Message |
| Encoder | `wire/encode.zig` | Message → Binary |
| Bootstrap | `descriptor/bootstrap.zig` | Hand-coded descriptor schemas |

### Data Flow

1. Initialize Arena with pre-allocated buffer
2. Create Message using MiniTable schema
3. Decode binary protobuf into Message
4. Access fields via `get_scalar`, `get_string`, `get_repeated`
5. Encode Message back to binary

### Project Structure

```
src/
├── proto.zig              # Root module, public API
├── arena.zig              # Arena allocator
├── message.zig            # Message type and StringView
├── mini_table.zig         # Schema descriptors
├── wire/
│   ├── types.zig          # Wire types enum
│   ├── reader.zig         # Low-level wire reading
│   ├── decode.zig         # Message decoding
│   └── encode.zig         # Message encoding
├── descriptor/
│   ├── decode.zig         # Descriptor parsing
│   └── bootstrap.zig      # Hand-coded schemas
├── codegen/
│   ├── main.zig           # protoc plugin entry
│   ├── generator.zig      # Code generation
│   ├── layout.zig         # Field layout calculation
│   └── linker.zig         # Submessage linking
├── generated/             # Generated MiniTables
├── fuzz/                  # Fuzz test modules
├── fuzz_tests.zig         # Unified fuzzer executable
└── conformance/
    └── main.zig           # Conformance test runner
```

## Design Principles

- **Zero-copy**: StringView optionally aliases input buffer
- **Fixed bounds**: Arena uses fixed buffer, no dynamic allocation after init
- **Runtime reflection**: MiniTable enables generic encode/decode
- **Zig zen**: Follow Zig's design principles

## Known Limitations

- Binary format only (no JSON/text)
- Proto3 only (no proto2 features)
- No proto3 `optional` keyword (use real oneofs)
- No maps (use repeated message with key/value)

## Reference Files

### upb (wire format)
- `/home/bits/gh/google/protobuf/upb/wire/reader.h`
- `/home/bits/gh/google/protobuf/upb/wire/decode.h`
- `/home/bits/gh/google/protobuf/upb/mini_table/field.h`

### Conformance
- `/home/bits/gh/google/protobuf/conformance/conformance.proto`
- `/home/bits/gh/google/protobuf/conformance/conformance_cpp.cc`

### TigerBeetle (Zig patterns)
- `/home/bits/gh/tigerbeetle/tigerbeetle/src/vsr/message_header.zig`
- `/home/bits/gh/tigerbeetle/tigerbeetle/docs/TIGER_STYLE.md`
