//! Unified decode fuzzer for proto-zig.
//!
//! Supports three fuzzing modes:
//! 1. Seed-based: Generates pseudo-random inputs for deterministic testing
//! 2. Native: Uses Zig's built-in coverage-guided fuzzing (zig test --fuzz)
//! 3. Replay: Reproduces crashes from raw input via stdin
//!
//! Feeds arbitrary bytes to the protobuf decoder to find:
//! - Buffer overflows
//! - Infinite loops on malformed input
//! - Memory corruption
//! - Unhandled error cases

const std = @import("std");
const fuzz_util = @import("../testing/fuzz.zig");
const proto = @import("proto");
const shared_corpus = @import("corpus.zig");

const Arena = proto.Arena;
const Message = proto.Message;
const MiniTable = proto.MiniTable;
const MiniTableField = proto.MiniTableField;
const decode = proto.decode;
const DecodeOptions = proto.DecodeOptions;

// Arena buffer for decode operations
var arena_buffer: [256 * 1024]u8 = undefined;

/// Core fuzzing function - tests input against all schemas and option variants.
/// Used by native fuzzer, replay mode, and seed-based fuzzing.
pub fn fuzz(input: []const u8) !void {
    // Test with each schema
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

/// Seed-based fuzzing mode - generates random inputs for deterministic testing.
pub fn run(args: fuzz_util.FuzzArgs) !void {
    var ctx = fuzz_util.FuzzContext.init(args);
    var prng = fuzz_util.FuzzPrng.init(args.seed);

    // Input buffer for fuzz data
    var input_buffer: [4096]u8 = undefined;

    while (ctx.shouldContinue()) {
        // Generate random input with exponential size distribution
        const input_len = prng.int_exponential(u32, 64);
        const actual_len = @min(input_len, input_buffer.len);
        prng.bytes(input_buffer[0..actual_len]);
        const input = input_buffer[0..actual_len];

        // Test with all schemas and options
        try fuzz(input);

        ctx.recordEvent();
    }

    ctx.finish();
}

// Native Zig fuzz test entry point for `zig test --fuzz`
test "fuzz" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            try fuzz(input);
        }
    }.testOne, .{
        .corpus = &shared_corpus.protobuf,
    });
}

// Test schemas covering various field types and configurations

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

const fixed_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 8,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED64,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 3,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 4,
        .offset = 24,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .scalar,
        .is_packed = false,
    },
};
const fixed_schema = MiniTable{
    .fields = &fixed_fields,
    .submessages = &.{},
    .size = 32,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 4,
};

const signed_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 8,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT64,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 3,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 4,
        .offset = 24,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED64,
        .mode = .scalar,
        .is_packed = false,
    },
};
const signed_schema = MiniTable{
    .fields = &signed_fields,
    .submessages = &.{},
    .size = 32,
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

const bool_enum_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 4,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 3,
        .offset = 8,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 4,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .scalar,
        .is_packed = false,
    },
};
const bool_enum_schema = MiniTable{
    .fields = &bool_enum_fields,
    .submessages = &.{},
    .size = 24,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 4,
};

pub const test_schemas = [_]*const MiniTable{
    &empty_schema,
    &int32_schema,
    &multi_schema,
    &fixed_schema,
    &signed_schema,
    &repeated_schema,
    &bool_enum_schema,
};

test "decode: smoke test" {
    try run(.{
        .seed = 12345,
        .events_max = 100,
    });
}
