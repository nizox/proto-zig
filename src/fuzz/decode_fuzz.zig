//! Decode fuzzer for proto-zig.
//!
//! Feeds arbitrary bytes to the protobuf decoder to find:
//! - Buffer overflows
//! - Infinite loops on malformed input
//! - Memory corruption
//! - Unhandled error cases
//!
//! Uses a variety of test schemas to exercise different code paths.

const std = @import("std");
const fuzz = @import("../testing/fuzz.zig");
const proto = @import("../proto.zig");

const Arena = proto.Arena;
const Message = proto.Message;
const MiniTable = proto.MiniTable;
const MiniTableField = proto.MiniTableField;
const FieldType = proto.FieldType;
const decode = proto.decode;
const DecodeOptions = proto.DecodeOptions;

/// Run the decode fuzzer.
pub fn run(args: fuzz.FuzzArgs) !void {
    var ctx = fuzz.FuzzContext.init(args);
    var prng = fuzz.FuzzPrng.init(args.seed);

    // Arena buffer for decoding
    var arena_buffer: [64 * 1024]u8 = undefined;

    // Input buffer for fuzz data
    var input_buffer: [4096]u8 = undefined;

    while (ctx.shouldContinue()) {
        // Generate random input
        const input_len = prng.int_exponential(u32, 64);
        const actual_len = @min(input_len, input_buffer.len);
        prng.bytes(input_buffer[0..actual_len]);
        const input = input_buffer[0..actual_len];

        // Pick a random schema
        const schema = prng.pick(*const MiniTable, &test_schemas);

        // Pick random decode options
        const options = DecodeOptions{
            .max_depth = prng.intRangeInclusive(u8, 1, 100),
            .check_utf8 = prng.boolean(),
            .alias_string = prng.boolean(),
        };

        // Reset arena and decode
        var arena = Arena.init(&arena_buffer);
        const msg = Message.new(&arena, schema) orelse continue;

        // Attempt decode - we don't care about errors, just crashes
        _ = decode(input, msg, &arena, options) catch {};

        ctx.recordEvent();
    }

    ctx.finish();
}

// Test schemas covering various field types and configurations.

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
        .offset = 8, // 8-byte aligned for i64
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT64,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 3,
        .offset = 16, // StringView is 16 bytes, 8-byte aligned
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
        .offset = 16,
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
    .size = 32,
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

const test_schemas = [_]*const MiniTable{
    &empty_schema,
    &int32_schema,
    &multi_schema,
    &fixed_schema,
    &signed_schema,
    &repeated_schema,
    &bool_enum_schema,
};

test "decode_fuzz: smoke test" {
    try run(.{
        .seed = 12345,
        .events_max = 100,
    });
}
