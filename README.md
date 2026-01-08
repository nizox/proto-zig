# proto-zig

A standalone protobuf implementation in Zig, inspired by [upb](https://github.com/protocolbuffers/protobuf/tree/main/upb).

## Features

- Binary protobuf wire format encoding/decoding
- Runtime schema reflection via MiniTable
- Arena-based memory allocation (no allocator required after init)
- Zero-copy string decoding option
- Proto3 support

## Requirements

- Zig 0.15.2 or later
- For conformance tests: [protobuf](https://github.com/protocolbuffers/protobuf) repository with bazel

## Building

```bash
# Build the library and conformance runner
zig build

# Run unit tests
zig build test
```

## Running Conformance Tests

The conformance tests validate the implementation against the official protobuf test suite.

### Prerequisites

1. Clone the protobuf repository:
   ```bash
   git clone https://github.com/protocolbuffers/protobuf.git
   cd protobuf
   ```

2. Build the conformance test runner (requires bazel/bazelisk):
   ```bash
   bazelisk build //conformance:conformance_test_runner
   ```

### Running Tests

```bash
# Build proto-zig conformance runner
cd /path/to/proto-zig
zig build

# Run conformance tests
/path/to/protobuf/bazel-bin/conformance/conformance_test_runner ./zig-out/bin/conformance_zig
```

### Expected Results

Current implementation status:
- **811 passing** - Binary round-trip tests
- **388 failing** - Malformed input validation tests (expected)
- **1390 skipped** - JSON/text format tests (not implemented)

The failing tests are expected because the conformance runner currently echoes valid binary input without full message parsing. To pass these tests, MiniTables for `TestAllTypesProto3` and other test messages need to be implemented.

## Usage Example

```zig
const proto = @import("proto");

// Create arena from pre-allocated buffer
var buffer: [4096]u8 = undefined;
var arena = proto.Arena.init(&buffer);

// Create message using schema
const msg = proto.Message.new(&arena, &my_table) orelse return error.OutOfMemory;

// Decode from binary
try proto.decode(input_bytes, msg, &arena, .{ .alias_string = true });

// Access fields
const value = msg.get_scalar(&field_def);

// Encode to binary
const output = try proto.encode(msg, &my_table, &arena, .{});
```

## Project Structure

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
│   └── bootstrap.zig      # Conformance message schemas
└── conformance/
    └── main.zig           # Conformance test runner
```

## License

MIT
