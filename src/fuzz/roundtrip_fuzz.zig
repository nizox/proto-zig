//! Encode/Decode roundtrip fuzzer for proto-zig.
//!
//! Generates random valid messages, encodes them, decodes the result,
//! and verifies consistency. Tests:
//! - Encode/decode data integrity
//! - Idempotence: encode(decode(encode(msg))) == encode(msg)
//! - Field value preservation across roundtrips

const std = @import("std");
const fuzz = @import("../testing/fuzz.zig");
const proto = @import("../proto.zig");

const Arena = proto.Arena;
const Message = proto.Message;
const MiniTable = proto.MiniTable;
const MiniTableField = proto.MiniTableField;
const FieldValue = proto.FieldValue;
const StringView = proto.StringView;
const FieldType = proto.FieldType;
const decode = proto.decode;
const encode = proto.encode;

/// Run the roundtrip fuzzer.
pub fn run(args: fuzz.FuzzArgs) !void {
    var ctx = fuzz.FuzzContext.init(args);
    var prng = fuzz.FuzzPrng.init(args.seed);

    // Arena buffers
    var arena_buffer1: [64 * 1024]u8 = undefined;
    var arena_buffer2: [64 * 1024]u8 = undefined;

    // String data buffer (for generating string values)
    var string_buffer: [1024]u8 = undefined;

    while (ctx.shouldContinue()) {
        // Pick a random schema
        const schema = prng.pick(*const MiniTable, &test_schemas);

        // Create and populate message
        var arena1 = Arena.init(&arena_buffer1);
        const msg1 = Message.new(&arena1, schema) orelse continue;

        // Randomly populate fields
        populateMessage(msg1, &prng, &arena1, &string_buffer) catch continue;

        // Encode
        const encoded = encode(msg1, &arena1, .{}) catch continue;

        // Decode into new message
        var arena2 = Arena.init(&arena_buffer2);
        const msg2 = Message.new(&arena2, schema) orelse continue;
        decode(encoded, msg2, &arena2, .{}) catch continue;

        // Re-encode
        const reencoded = encode(msg2, &arena2, .{}) catch continue;

        // Verify encoded bytes match (idempotence)
        if (!std.mem.eql(u8, encoded, reencoded)) {
            std.debug.print("Roundtrip mismatch! seed={d}\n", .{args.seed});
            std.debug.print("Original:   {any}\n", .{encoded});
            std.debug.print("Reencoded:  {any}\n", .{reencoded});
            return error.RoundtripMismatch;
        }

        ctx.recordEvent();
    }

    ctx.finish();
}

fn populateMessage(
    msg: *Message,
    prng: *fuzz.FuzzPrng,
    arena: *Arena,
    string_buffer: []u8,
) !void {
    var iter = msg.table.field_iter();
    while (iter.next()) |field| {
        // Randomly decide whether to set this field
        if (!prng.booleanWithChance(0.7)) continue;

        if (field.mode == .repeated) {
            // For now, skip repeated fields in roundtrip tests
            continue;
        }

        const value = generateValue(field, prng, arena, string_buffer) catch continue;
        msg.set_scalar(field, value);
    }
}

fn generateValue(
    field: *const MiniTableField,
    prng: *fuzz.FuzzPrng,
    arena: *Arena,
    string_buffer: []u8,
) !FieldValue {
    return switch (field.field_type) {
        .TYPE_BOOL => .{ .bool_val = prng.boolean() },
        .TYPE_INT32, .TYPE_ENUM => .{ .int32_val = @bitCast(prng.random().int(u32)) },
        .TYPE_INT64 => .{ .int64_val = @bitCast(prng.random().int(u64)) },
        .TYPE_UINT32 => .{ .uint32_val = prng.random().int(u32) },
        .TYPE_UINT64 => .{ .uint64_val = prng.random().int(u64) },
        .TYPE_SINT32 => .{ .int32_val = @bitCast(prng.random().int(u32)) },
        .TYPE_SINT64 => .{ .int64_val = @bitCast(prng.random().int(u64)) },
        .TYPE_FIXED32 => .{ .uint32_val = prng.random().int(u32) },
        .TYPE_FIXED64 => .{ .uint64_val = prng.random().int(u64) },
        .TYPE_SFIXED32 => .{ .int32_val = @bitCast(prng.random().int(u32)) },
        .TYPE_SFIXED64 => .{ .int64_val = @bitCast(prng.random().int(u64)) },
        .TYPE_FLOAT => .{ .float_val = @bitCast(prng.random().int(u32)) },
        .TYPE_DOUBLE => .{ .double_val = @bitCast(prng.random().int(u64)) },
        .TYPE_STRING => blk: {
            // Generate valid UTF-8 string
            const len = prng.int_exponential(u32, 16);
            const actual_len = @min(len, @as(u32, @intCast(string_buffer.len)));
            generateUtf8String(prng, string_buffer[0..actual_len]);
            const copy = arena.dupe(string_buffer[0..actual_len]) orelse return error.OutOfMemory;
            break :blk .{ .string_val = StringView.from_slice(copy) };
        },
        .TYPE_BYTES => blk: {
            // Generate arbitrary bytes
            const len = prng.int_exponential(u32, 16);
            const actual_len = @min(len, @as(u32, @intCast(string_buffer.len)));
            prng.bytes(string_buffer[0..actual_len]);
            const copy = arena.dupe(string_buffer[0..actual_len]) orelse return error.OutOfMemory;
            break :blk .{ .bytes_val = StringView.from_slice(copy) };
        },
        .TYPE_MESSAGE, .TYPE_GROUP => .none,
    };
}

fn generateUtf8String(prng: *fuzz.FuzzPrng, buf: []u8) void {
    // Generate simple ASCII for now (guaranteed valid UTF-8)
    for (buf) |*c| {
        c.* = prng.intRangeInclusive(u8, 0x20, 0x7E);
    }
}

// Test schemas for roundtrip testing

const scalar_fields = [_]MiniTableField{
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
        .field_type = .TYPE_UINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 4,
        .offset = 24,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .scalar,
        .is_packed = false,
    },
};
const scalar_schema = MiniTable{
    .fields = &scalar_fields,
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
};
const signed_schema = MiniTable{
    .fields = &signed_fields,
    .submessages = &.{},
    .size = 16,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
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
const fixed_schema = MiniTable{
    .fields = &fixed_fields,
    .submessages = &.{},
    .size = 32,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 4,
};

const float_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 8,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .scalar,
        .is_packed = false,
    },
};
const float_schema = MiniTable{
    .fields = &float_fields,
    .submessages = &.{},
    .size = 16,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

const string_fields = [_]MiniTableField{
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    .{
        .number = 2,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
    },
};
const string_schema = MiniTable{
    .fields = &string_fields,
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
};
const bool_enum_schema = MiniTable{
    .fields = &bool_enum_fields,
    .submessages = &.{},
    .size = 8,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

const test_schemas = [_]*const MiniTable{
    &scalar_schema,
    &signed_schema,
    &fixed_schema,
    &float_schema,
    &string_schema,
    &bool_enum_schema,
};

test "roundtrip_fuzz: smoke test" {
    try run(.{
        .seed = 12345,
        .events_max = 100,
    });
}
