//! Protobuf binary wire format encoder.
//!
//! Encodes Message instances into binary protobuf wire format.

const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("../arena.zig").Arena;
const Message = @import("../message.zig").Message;
const StringView = @import("../message.zig").StringView;
const RepeatedField = @import("../message.zig").RepeatedField;
const FieldValue = @import("../message.zig").FieldValue;
const MiniTable = @import("../mini_table.zig").MiniTable;
const MiniTableField = @import("../mini_table.zig").MiniTableField;
const FieldType = @import("../mini_table.zig").FieldType;
const Mode = @import("../mini_table.zig").Mode;
const types = @import("types.zig");
const WireType = types.WireType;
const Tag = types.Tag;

/// Errors that can occur during encoding.
pub const EncodeError = error{
    /// Arena is out of memory.
    OutOfMemory,

    /// Encoded size exceeds maximum (2GB).
    MaxSizeExceeded,
};

/// Options for encoding.
pub const EncodeOptions = struct {
    /// Skip unknown fields in output.
    skip_unknown: bool = false,

    /// Produce deterministic output (sorted maps, etc.).
    deterministic: bool = false,
};

/// Encode a message to binary protobuf wire format.
///
/// Returns a slice pointing to the encoded data in the arena.
pub fn encode(
    msg: *const Message,
    arena: *Arena,
    options: EncodeOptions,
) EncodeError![]const u8 {
    // First pass: calculate size.
    const size = calculate_size(msg, options);

    if (size > max_message_size) {
        return error.MaxSizeExceeded;
    }

    // Handle empty message.
    if (size == 0) {
        return &.{};
    }

    // Allocate buffer.
    const buf = arena.alloc(u8, size) orelse return error.OutOfMemory;

    // Second pass: write data.
    var encoder = Encoder{
        .buf = buf,
        .pos = 0,
        .options = options,
    };

    encoder.encode_message(msg);

    assert(encoder.pos == size);
    return buf;
}

/// Maximum message size (2GB).
const max_message_size: u32 = 0x7FFFFFFF;

/// Calculate the encoded size of a message.
fn calculate_size(msg: *const Message, options: EncodeOptions) u32 {
    var size: u32 = 0;

    // Iterate over fields.
    var iter = msg.table.field_iter();
    while (iter.next()) |field| {
        if (field.mode == .repeated) {
            size += calculate_repeated_size(msg, field, options);
        } else {
            size += calculate_scalar_size(msg, field);
        }
    }

    // Unknown fields.
    if (!options.skip_unknown) {
        if (msg.unknown_fields) |uf| {
            size += @intCast(uf.len);
        }
    }

    return size;
}

fn calculate_scalar_size(msg: *const Message, field: *const MiniTableField) u32 {
    // Check if field is present.
    if (!msg.has_field(field)) {
        return 0;
    }

    const value = msg.get_scalar(field);
    if (value == .none) {
        return 0;
    }

    const tag = Tag{ .field_number = @intCast(field.number), .wire_type = field.wire_type() };
    const tag_size = varint_size(tag.to_raw());

    const value_size: u32 = switch (field.field_type) {
        .TYPE_BOOL => 1,
        .TYPE_INT32, .TYPE_ENUM => varint_size_i32(value.int32_val),
        .TYPE_INT64 => varint_size_i64(value.int64_val),
        .TYPE_UINT32 => varint_size(value.uint32_val),
        .TYPE_UINT64 => varint_size(value.uint64_val),
        .TYPE_SINT32 => varint_size(zigzag_encode_32(value.int32_val)),
        .TYPE_SINT64 => varint_size(zigzag_encode_64(value.int64_val)),
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => 4,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => 8,
        .TYPE_STRING => blk: {
            const len = value.string_val.len;
            break :blk varint_size(len) + len;
        },
        .TYPE_BYTES => blk: {
            const len = value.bytes_val.len;
            break :blk varint_size(len) + len;
        },
        .TYPE_MESSAGE => blk: {
            const sub_size = calculate_size(value.message_val, .{});
            break :blk varint_size(sub_size) + sub_size;
        },
        .TYPE_GROUP => 0,
    };

    return tag_size + value_size;
}

fn calculate_repeated_size(
    msg: *const Message,
    field: *const MiniTableField,
    options: EncodeOptions,
) u32 {
    _ = options;

    const repeated = msg.get_repeated_const(field);
    if (repeated.count == 0) {
        return 0;
    }

    const rep_tag = Tag{
        .field_number = @intCast(field.number),
        .wire_type = field.wire_type(),
    };
    const tag_size = varint_size(rep_tag.to_raw());

    if (field.is_packed and is_packable(field.field_type)) {
        // Packed: one tag + length + all elements.
        var data_size: u32 = 0;
        var i: u32 = 0;
        while (i < repeated.count) : (i += 1) {
            data_size += calculate_element_size(repeated, field, i);
        }
        return tag_size + varint_size(data_size) + data_size;
    } else {
        // Non-packed: tag + value for each element.
        var total: u32 = 0;
        var i: u32 = 0;
        while (i < repeated.count) : (i += 1) {
            total += tag_size + calculate_element_size(repeated, field, i);
        }
        return total;
    }
}

fn calculate_element_size(
    repeated: *const RepeatedField,
    field: *const MiniTableField,
    index: u32,
) u32 {
    return switch (field.field_type) {
        .TYPE_BOOL => 1,
        .TYPE_INT32, .TYPE_ENUM => blk: {
            const ptr: *const i32 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size_i32(ptr.*);
        },
        .TYPE_INT64 => blk: {
            const ptr: *const i64 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size_i64(ptr.*);
        },
        .TYPE_UINT32 => blk: {
            const ptr: *const u32 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size(ptr.*);
        },
        .TYPE_UINT64 => blk: {
            const ptr: *const u64 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size(ptr.*);
        },
        .TYPE_SINT32 => blk: {
            const ptr: *const i32 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size(zigzag_encode_32(ptr.*));
        },
        .TYPE_SINT64 => blk: {
            const ptr: *const i64 = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size(zigzag_encode_64(ptr.*));
        },
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => 4,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => 8,
        .TYPE_STRING, .TYPE_BYTES => blk: {
            const ptr: *const StringView = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            break :blk varint_size(ptr.len) + ptr.len;
        },
        .TYPE_MESSAGE => blk: {
            const ptr: *const ?*Message = @ptrCast(@alignCast(repeated.get_raw(index).?.ptr));
            if (ptr.*) |sub_msg| {
                const sub_size = calculate_size(sub_msg, .{});
                break :blk varint_size(sub_size) + sub_size;
            }
            break :blk 0;
        },
        .TYPE_GROUP => 0,
    };
}

const Encoder = struct {
    buf: []u8,
    pos: u32,
    options: EncodeOptions,

    fn encode_message(self: *Encoder, msg: *const Message) void {
        // Encode fields.
        var iter = msg.table.field_iter();
        while (iter.next()) |field| {
            if (field.mode == .repeated) {
                self.encode_repeated(msg, field);
            } else {
                self.encode_scalar(msg, field);
            }
        }

        // Encode unknown fields.
        if (!self.options.skip_unknown) {
            if (msg.unknown_fields) |uf| {
                @memcpy(self.buf[self.pos .. self.pos + uf.len], uf);
                self.pos += @intCast(uf.len);
            }
        }
    }

    fn encode_scalar(self: *Encoder, msg: *const Message, field: *const MiniTableField) void {
        if (!msg.has_field(field)) {
            return;
        }

        const value = msg.get_scalar(field);
        if (value == .none) {
            return;
        }

        // Write tag.
        self.write_tag(field.number, field.wire_type());

        // Write value.
        switch (field.field_type) {
            .TYPE_BOOL => self.write_varint(if (value.bool_val) 1 else 0),
            .TYPE_INT32, .TYPE_ENUM => self.write_varint_i32(value.int32_val),
            .TYPE_INT64 => self.write_varint_i64(value.int64_val),
            .TYPE_UINT32 => self.write_varint(value.uint32_val),
            .TYPE_UINT64 => self.write_varint(value.uint64_val),
            .TYPE_SINT32 => self.write_varint(zigzag_encode_32(value.int32_val)),
            .TYPE_SINT64 => self.write_varint(zigzag_encode_64(value.int64_val)),
            .TYPE_FIXED32 => self.write_fixed32(value.uint32_val),
            .TYPE_SFIXED32 => self.write_fixed32(@bitCast(value.int32_val)),
            .TYPE_FIXED64 => self.write_fixed64(value.uint64_val),
            .TYPE_SFIXED64 => self.write_fixed64(@bitCast(value.int64_val)),
            .TYPE_FLOAT => self.write_fixed32(@bitCast(value.float_val)),
            .TYPE_DOUBLE => self.write_fixed64(@bitCast(value.double_val)),
            .TYPE_STRING => self.write_length_delimited(value.string_val.slice()),
            .TYPE_BYTES => self.write_length_delimited(value.bytes_val.slice()),
            .TYPE_MESSAGE => {
                const sub_size = calculate_size(value.message_val, .{});
                self.write_varint(sub_size);
                self.encode_message(value.message_val);
            },
            .TYPE_GROUP => {},
        }
    }

    fn encode_repeated(self: *Encoder, msg: *const Message, field: *const MiniTableField) void {
        const repeated = msg.get_repeated_const(field);
        if (repeated.count == 0) {
            return;
        }

        if (field.is_packed and is_packable(field.field_type)) {
            self.encode_packed(repeated, field);
        } else {
            var i: u32 = 0;
            while (i < repeated.count) : (i += 1) {
                self.write_tag(field.number, field.wire_type());
                self.encode_element(repeated, field, i);
            }
        }
    }

    fn encode_packed(
        self: *Encoder,
        repeated: *const RepeatedField,
        field: *const MiniTableField,
    ) void {
        // Calculate packed data size.
        var data_size: u32 = 0;
        var i: u32 = 0;
        while (i < repeated.count) : (i += 1) {
            data_size += calculate_element_size(repeated, field, i);
        }

        // Write tag + length.
        self.write_tag(field.number, .delimited);
        self.write_varint(data_size);

        // Write elements.
        i = 0;
        while (i < repeated.count) : (i += 1) {
            self.encode_element(repeated, field, i);
        }
    }

    fn encode_element(
        self: *Encoder,
        repeated: *const RepeatedField,
        field: *const MiniTableField,
        index: u32,
    ) void {
        const raw = repeated.get_raw(index).?;

        switch (field.field_type) {
            .TYPE_BOOL => self.write_varint(raw[0]),
            .TYPE_INT32, .TYPE_ENUM => {
                const ptr: *const i32 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint_i32(ptr.*);
            },
            .TYPE_INT64 => {
                const ptr: *const i64 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint_i64(ptr.*);
            },
            .TYPE_UINT32 => {
                const ptr: *const u32 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint(ptr.*);
            },
            .TYPE_UINT64 => {
                const ptr: *const u64 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint(ptr.*);
            },
            .TYPE_SINT32 => {
                const ptr: *const i32 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint(zigzag_encode_32(ptr.*));
            },
            .TYPE_SINT64 => {
                const ptr: *const i64 = @ptrCast(@alignCast(raw.ptr));
                self.write_varint(zigzag_encode_64(ptr.*));
            },
            .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => {
                const ptr: *const u32 = @ptrCast(@alignCast(raw.ptr));
                self.write_fixed32(ptr.*);
            },
            .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => {
                const ptr: *const u64 = @ptrCast(@alignCast(raw.ptr));
                self.write_fixed64(ptr.*);
            },
            .TYPE_STRING, .TYPE_BYTES => {
                const ptr: *const StringView = @ptrCast(@alignCast(raw.ptr));
                self.write_length_delimited(ptr.slice());
            },
            .TYPE_MESSAGE => {
                const ptr: *const ?*Message = @ptrCast(@alignCast(raw.ptr));
                if (ptr.*) |sub_msg| {
                    const sub_size = calculate_size(sub_msg, .{});
                    self.write_varint(sub_size);
                    self.encode_message(sub_msg);
                }
            },
            .TYPE_GROUP => {},
        }
    }

    fn write_tag(self: *Encoder, field_number: u32, wire_type: WireType) void {
        const tag = Tag{ .field_number = @intCast(field_number), .wire_type = wire_type };
        self.write_varint(tag.to_raw());
    }

    fn write_varint(self: *Encoder, value: u64) void {
        var v = value;
        while (v >= 0x80) {
            self.buf[self.pos] = @truncate((v & 0x7F) | 0x80);
            self.pos += 1;
            v >>= 7;
        }
        self.buf[self.pos] = @truncate(v);
        self.pos += 1;
    }

    fn write_varint_i32(self: *Encoder, value: i32) void {
        // Negative values are sign-extended to 64 bits.
        self.write_varint(@bitCast(@as(i64, value)));
    }

    fn write_varint_i64(self: *Encoder, value: i64) void {
        self.write_varint(@bitCast(value));
    }

    fn write_fixed32(self: *Encoder, value: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    fn write_fixed64(self: *Encoder, value: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], value, .little);
        self.pos += 8;
    }

    fn write_length_delimited(self: *Encoder, data: []const u8) void {
        self.write_varint(@intCast(data.len));
        @memcpy(self.buf[self.pos .. self.pos + data.len], data);
        self.pos += @intCast(data.len);
    }
};

// Helper functions.

fn varint_size(value: u64) u32 {
    if (value == 0) return 1;

    var v = value;
    var size: u32 = 0;
    while (v != 0) {
        v >>= 7;
        size += 1;
    }
    return size;
}

fn varint_size_i32(value: i32) u32 {
    // Negative values are sign-extended to 10 bytes.
    if (value < 0) {
        return 10;
    }
    return varint_size(@intCast(value));
}

fn varint_size_i64(value: i64) u32 {
    return varint_size(@bitCast(value));
}

fn zigzag_encode_32(value: i32) u32 {
    return @bitCast((value << 1) ^ (value >> 31));
}

fn zigzag_encode_64(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

fn is_packable(field_type: FieldType) bool {
    return switch (field_type) {
        .TYPE_BOOL, .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => true,
        .TYPE_SINT32, .TYPE_SINT64, .TYPE_ENUM => true,
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => true,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => true,
        .TYPE_STRING, .TYPE_BYTES, .TYPE_MESSAGE, .TYPE_GROUP => false,
    };
}

fn get_repeated_const(msg: *const Message, field: *const MiniTableField) *const RepeatedField {
    const ptr = msg.data.ptr + field.offset;
    return @ptrCast(@alignCast(ptr));
}

// Tests.

test "encode: empty message" {
    const fields = [_]MiniTableField{};
    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 8,
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 0,
    };

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    const msg = Message.new(&arena, &table).?;
    const encoded = try encode(msg, &arena, .{});

    try std.testing.expectEqual(@as(usize, 0), encoded.len);
}

test "encode: single int32 field" {
    const fields = [_]MiniTableField{
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

    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 8,
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 1,
    };

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    const msg = Message.new(&arena, &table).?;
    msg.set_scalar(&fields[0], .{ .int32_val = 150 });

    const encoded = try encode(msg, &arena, .{});

    // Field 1, varint, value 150.
    try std.testing.expectEqualSlices(u8, &.{ 0x08, 0x96, 0x01 }, encoded);
}

test "encode: string field" {
    const fields = [_]MiniTableField{
        .{
            .number = 2,
            .offset = 0,
            .presence = 0,
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_STRING,
            .mode = .scalar,
            .is_packed = false,
        },
    };

    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 16,
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 2,
    };

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    const msg = Message.new(&arena, &table).?;
    msg.set_scalar(&fields[0], .{ .string_val = StringView.from_slice("testing") });

    const encoded = try encode(msg, &arena, .{});

    // Field 2, delimited, "testing".
    const expected = [_]u8{ 0x12, 0x07, 't', 'e', 's', 't', 'i', 'n', 'g' };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "varint_size" {
    try std.testing.expectEqual(@as(u32, 1), varint_size(0));
    try std.testing.expectEqual(@as(u32, 1), varint_size(127));
    try std.testing.expectEqual(@as(u32, 2), varint_size(128));
    try std.testing.expectEqual(@as(u32, 2), varint_size(300));
    try std.testing.expectEqual(@as(u32, 10), varint_size(std.math.maxInt(u64)));
}

test "zigzag_encode" {
    try std.testing.expectEqual(@as(u32, 0), zigzag_encode_32(0));
    try std.testing.expectEqual(@as(u32, 1), zigzag_encode_32(-1));
    try std.testing.expectEqual(@as(u32, 2), zigzag_encode_32(1));
    try std.testing.expectEqual(@as(u32, 3), zigzag_encode_32(-2));
}
