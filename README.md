# proto-zig

A standalone Protocol Buffers implementation in Zig, inspired by [upb](https://github.com/protocolbuffers/protobuf/tree/main/upb).

> Status: Experimental project. Not production-ready yet. Does not target full compatibility with the protobuf specification. Most of the project is co-authored with Claude.

## Features

- Binary wire format encoding/decoding
- Runtime schema reflection via MiniTable
- Arena-based memory allocation
- Zero-copy string decoding
- Proto3 support
- Code generator plugin (`protoc-gen-zig-pb`)

## Quick Start

```bash
zig build        # Build library
zig build test   # Run tests
```

## Example

Given a proto file:

```protobuf
// person.proto
syntax = "proto3";

message Person {
  string name = 1;
  int32 age = 2;
}
```

Generate the MiniTable definition:

```bash
protoc --plugin=protoc-gen-zig-pb=./zig-out/bin/protoc-gen-zig-pb \
       --zig-pb_out=. person.proto
```

Use the generated schema to decode and encode messages:

```zig
const std = @import("std");
const proto = @import("proto");

// Generated MiniTable (or hand-written for simple cases)
const person = @import("person.pb.zig");

pub fn main() !void {
    // 1. Create arena with fixed buffer (no dynamic allocation)
    var buffer: [4096]u8 = undefined;
    var arena = proto.Arena.initBuffer(&buffer, null);

    // 2. Create message using generated schema
    const msg = proto.Message.new(&arena, &person.person_table) orelse return error.OutOfMemory;

    // 3. Decode binary protobuf data
    const input = [_]u8{
        0x0a, 0x05, 'A', 'l', 'i', 'c', 'e', // field 1: "Alice"
        0x10, 0x1e,                           // field 2: 30
    };
    try proto.decode(&input, msg, &arena, .{});

    // 4. Access fields
    const name = msg.get_scalar(&person.person_table.fields[0]); // StringView
    const age = msg.get_scalar(&person.person_table.fields[1]);  // i32
    std.debug.print("Name: {s}, Age: {d}\n", .{ name.string_val.slice(), age.int32_val });

    // 5. Modify and encode back to binary
    msg.set_scalar(&person.person_table.fields[1], .{ .int32_val = 31 });
    const encoded = try proto.encode(msg, &arena, .{});
    _ = encoded; // Use encoded bytes...
}
```

### Decode Options

```zig
try proto.decode(&input, msg, &arena, .{
    .alias_string = true,  // Zero-copy: strings point into input buffer
    .check_utf8 = true,    // Validate UTF-8 in string fields
    .max_depth = 100,      // Max recursion depth for nested messages
});
```

## Conformance Test Results

Proto-zig passes the official protobuf conformance test suite for binary format:

| Metric | Count |
|--------|-------|
| Successes | 1033 |
| Skipped | 1390 |
| Warnings | 108 |
| Failures | 269 |

**Failure breakdown:**
- Map fields (240): Maps not yet supported, treated as unknown
- Proto2 hasbits (16): Proto2 requires explicit field presence tracking
- Unknown field preservation (4): Unknown fields not preserved on re-encode
- Message merging (4): Repeated message fields should merge, not replace
- MessageSet (3): Proto2 extension feature not supported

## Changelog

### 2026-01-16 - Arena Allocator Refactoring
- Arena now supports backing allocator for dynamic growth (`Arena.init(allocator)`)
- Arena fusing via union-find for lifetime linking (`arena.fuse(other)`)
- API change: `Arena.init(&buffer)` → `Arena.initBuffer(&buffer, null)`
- Initial buffers prevent fusing (for lifetime safety)
- See ADR 0003 for design details

### 2026-01-13 - Canonical Encoding + Conformance Improvements
- Conformance runner now re-encodes messages (canonical output) instead of echoing input
- Fixed `is_default_value()` for string/bytes (check length) and messages (check null)
- Extended TestAllTypesProto3 MiniTable with scalar, oneof, packed, and unpacked fields
- Reduced conformance warnings from 210 to 108 (proto2 hasbit cases remain)

### 2026-01-13 - Differential Testing Infrastructure + Packed Field Support
- Added `zig build test-differential` to compare proto-zig vs upb reference implementation
- upb C library integration via Zig's @cImport FFI
- Fixed BadTag_OverlongVarint validation (1163 → 1165 tests passing)
- Code generator now reads `[packed=...]` option from FieldDescriptorProto

### 2026-01-12 - Code Generator + Oneof Support
- `protoc-gen-zig-pb` plugin generates MiniTable definitions from .proto files
- Proper proto3 oneof handling with shared storage and case tags

### 2026-01-09 - Integer Overflow Fix
- Fixed integer overflow vulnerability in wire format reader (found via AFL++)

### 2026-01-08 - Inline Validation
- Inline validation during decoding (811 → 1163 passing tests)

### 2026-01-07 - Initial Implementation
- Complete wire format decoder/encoder with MiniTable runtime reflection

## License

MIT
