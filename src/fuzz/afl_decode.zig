//! AFL++ harness library for decode fuzzing using zig-afl-kit.
//!
//! This file exports the functions required by zig-afl-kit for
//! coverage-guided fuzzing with AFL++. It does NOT contain main() -
//! that's provided by afl.c from zig-afl-kit.
//!
//! Exported functions:
//!   - zig_fuzz_init() - Called once at startup
//!   - zig_fuzz_test(buf, len) - Called repeatedly in persistent mode
//!
//! Build instrumented binary:
//!   zig build afl
//!
//! Run with AFL++:
//!   AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
//!   ./zig-out/AFLplusplus/bin/afl-fuzz -i fuzz/corpus -o fuzz/output/decode-instr \
//!   -m none -t 1000 -- ./zig-out/bin/afl-decode-instr

const std = @import("std");
const proto = @import("proto");

const Arena = proto.Arena;
const Message = proto.Message;
const MiniTable = proto.MiniTable;
const MiniTableField = proto.MiniTableField;
const decode = proto.decode;
const DecodeOptions = proto.DecodeOptions;

// Global state for persistent mode
var arena_buffer: [256 * 1024]u8 = undefined;

/// Called once at startup to initialize resources.
/// Required by zig-afl-kit.
export fn zig_fuzz_init() callconv(.c) void {
    // Nothing to initialize - we use stack-allocated buffers
}

/// Called repeatedly with fuzz input.
/// Required by zig-afl-kit.
export fn zig_fuzz_test(buf: [*]u8, len: c_int) callconv(.c) void {
    if (len <= 0) return;

    const input = buf[0..@intCast(len)];

    // Try decoding with each schema
    inline for (test_schemas) |schema| {
        fuzzWithSchema(input, schema);
    }
}

fn fuzzWithSchema(input: []const u8, schema: *const MiniTable) void {
    // Test with various decode options to maximize coverage
    const option_variants = [_]DecodeOptions{
        .{}, // defaults
        .{ .max_depth = 5 },
        .{ .max_depth = 100 },
        .{ .check_utf8 = false },
        .{ .alias_string = true },
    };

    for (option_variants) |options| {
        var arena = Arena.initBuffer(&arena_buffer, null);
        const msg = Message.new(&arena, schema) orelse continue;
        _ = decode(input, msg, &arena, options) catch {};
    }
}

// Test schemas covering various field configurations

const empty_fields = [_]MiniTableField{};
const empty_schema = MiniTable{
    .fields = &empty_fields,
    .submessages = &.{},
    .size = 8,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 0,
};

const int32_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
};
const int32_schema = MiniTable{
    .fields = &int32_fields,
    .submessages = &.{},
    .size = 8,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};

const multi_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 8,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT64,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 3,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 4,
        .offset = 32,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
    },
};
const multi_schema = MiniTable{
    .fields = &multi_fields,
    .submessages = &.{},
    .size = 48,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 4,
};

const repeated_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .repeated,
        .is_packed = true,
    },
    .{
        .number = 2,
        .offset = 24,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .repeated,
        .is_packed = false,
    },
};
const repeated_schema = MiniTable{
    .fields = &repeated_fields,
    .submessages = &.{},
    .size = 48,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

const test_schemas = [_]*const MiniTable{
    &empty_schema,
    &int32_schema,
    &multi_schema,
    &repeated_schema,
};
