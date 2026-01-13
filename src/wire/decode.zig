//! Protobuf binary wire format decoder.
//!
//! Decodes binary protobuf messages into Message instances using schema
//! information from MiniTable.

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
const reader = @import("reader.zig");
const types = @import("types.zig");
const WireType = types.WireType;
const Tag = types.Tag;

/// Errors that can occur during decoding.
pub const DecodeError = error{
    /// Not enough bytes in input.
    EndOfStream,

    /// Invalid varint encoding.
    VarintOverflow,

    /// Wire format is malformed.
    Malformed,

    /// String is not valid UTF-8.
    BadUtf8,

    /// Exceeded maximum recursion depth.
    MaxDepthExceeded,

    /// Required field is missing.
    MissingRequired,

    /// Arena is out of memory.
    OutOfMemory,

    /// Wire type doesn't match expected type for field.
    WireTypeMismatch,
};

/// Options for decoding.
pub const DecodeOptions = struct {
    /// Maximum recursion depth for nested messages.
    max_depth: u8 = 100,

    /// Validate UTF-8 in string fields.
    check_utf8: bool = true,

    /// Zero-copy mode: strings point into input buffer.
    alias_string: bool = false,
};

/// Decode a binary protobuf message.
///
/// The message must be pre-allocated from the arena. The input buffer must
/// outlive the message if alias_string is true.
pub fn decode(
    input: []const u8,
    msg: *Message,
    arena: *Arena,
    options: DecodeOptions,
) DecodeError!void {
    var decoder = Decoder{
        .input = input,
        .pos = 0,
        .limit = input.len,
        .arena = arena,
        .options = options,
        .depth = 0,
    };

    try decoder.decode_message(msg);
}

const Decoder = struct {
    input: []const u8,
    pos: usize,
    limit: usize, // End boundary for current decode context (packed or full input)
    arena: *Arena,
    options: DecodeOptions,
    depth: u8,

    /// Maximum number of repeated field elements per message to prevent DoS.
    const max_repeated_elements: u32 = 10_000_000;

    fn decode_message(self: *Decoder, msg: *Message) DecodeError!void {
        // Check recursion depth.
        if (self.depth >= self.options.max_depth) {
            return error.MaxDepthExceeded;
        }

        while (self.pos < self.limit) {
            // Read tag.
            const tag_result = reader.read_tag(self.remaining()) catch |err| {
                return self.convert_error(err);
            };
            self.pos += tag_result.consumed;

            const tag = tag_result.value;
            if (!tag.is_valid()) {
                return error.Malformed;
            }

            // Look up field in schema.
            const field = msg.table.field_by_number(tag.field_number);

            if (field) |f| {
                // Known field: decode based on field type.
                try self.decode_field(msg, f, tag.wire_type);
            } else {
                // Unknown field: skip and optionally preserve.
                try self.skip_unknown_field(msg, tag);
            }
        }
    }

    fn decode_field(
        self: *Decoder,
        msg: *Message,
        field: *const MiniTableField,
        wire_type: WireType,
    ) DecodeError!void {
        const expected_wire_type = field.wire_type();
        const native_wire_type = field.field_type.wire_type();

        // Handle packed repeated fields (wire data is packed format).
        // Accept packed encoding regardless of is_packed setting.
        if (field.mode == .repeated and wire_type == .delimited and
            native_wire_type != .delimited)
        {
            return self.decode_packed_repeated(msg, field);
        }

        // Proto3 compatibility: accept unpacked encoding for packed fields.
        // Decoders must accept both packed and unpacked formats.
        if (field.mode == .repeated and field.is_packed and wire_type == native_wire_type) {
            return self.decode_repeated_element(msg, field);
        }

        // Check wire type matches.
        if (wire_type != expected_wire_type) {
            return error.WireTypeMismatch;
        }

        if (field.mode == .repeated) {
            try self.decode_repeated_element(msg, field);
        } else {
            const value = try self.decode_value(field, msg.table);
            msg.set_scalar(field, value);
        }
    }

    fn decode_value(
        self: *Decoder,
        field: *const MiniTableField,
        table: *const MiniTable,
    ) DecodeError!FieldValue {
        return switch (field.field_type) {
            .TYPE_BOOL => blk: {
                const v = try self.read_varint();
                break :blk .{ .bool_val = v != 0 };
            },
            .TYPE_INT32, .TYPE_ENUM => blk: {
                const v = try self.read_varint();
                break :blk .{ .int32_val = @bitCast(@as(u32, @truncate(v))) };
            },
            .TYPE_INT64 => blk: {
                const v = try self.read_varint();
                break :blk .{ .int64_val = @bitCast(v) };
            },
            .TYPE_UINT32 => blk: {
                const v = try self.read_varint();
                break :blk .{ .uint32_val = @truncate(v) };
            },
            .TYPE_UINT64 => blk: {
                const v = try self.read_varint();
                break :blk .{ .uint64_val = v };
            },
            .TYPE_SINT32 => blk: {
                const v = try self.read_varint();
                break :blk .{ .int32_val = reader.zigzag_decode_32(@truncate(v)) };
            },
            .TYPE_SINT64 => blk: {
                const v = try self.read_varint();
                break :blk .{ .int64_val = reader.zigzag_decode_64(v) };
            },
            .TYPE_FIXED32 => blk: {
                const result = reader.read_fixed32(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .uint32_val = result.value };
            },
            .TYPE_FIXED64 => blk: {
                const result = reader.read_fixed64(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .uint64_val = result.value };
            },
            .TYPE_SFIXED32 => blk: {
                const result = reader.read_fixed32(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .int32_val = @bitCast(result.value) };
            },
            .TYPE_SFIXED64 => blk: {
                const result = reader.read_fixed64(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .int64_val = @bitCast(result.value) };
            },
            .TYPE_FLOAT => blk: {
                const result = reader.read_float(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .float_val = result.value };
            },
            .TYPE_DOUBLE => blk: {
                const result = reader.read_double(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                break :blk .{ .double_val = result.value };
            },
            .TYPE_STRING => blk: {
                const sv = try self.decode_string(true);
                break :blk .{ .string_val = sv };
            },
            .TYPE_BYTES => blk: {
                const sv = try self.decode_string(false);
                break :blk .{ .bytes_val = sv };
            },
            .TYPE_MESSAGE => blk: {
                const sub_msg = try self.decode_submessage(field, table);
                break :blk .{ .message_val = sub_msg };
            },
            .TYPE_GROUP => error.Malformed, // Deprecated.
        };
    }

    fn decode_string(self: *Decoder, check_utf8: bool) DecodeError!StringView {
        const result = reader.read_length_delimited(self.remaining()) catch |e| {
            return self.convert_error(e);
        };
        self.pos += result.consumed;

        const data = result.value;

        // Validate UTF-8 if required.
        if (check_utf8 and self.options.check_utf8) {
            if (!std.unicode.utf8ValidateSlice(data)) {
                return error.BadUtf8;
            }
        }

        // Zero-copy or copy to arena.
        if (self.options.alias_string) {
            return StringView.from_aliased(data);
        } else {
            const copy = self.arena.dupe(data) orelse return error.OutOfMemory;
            return StringView.from_slice(copy);
        }
    }

    fn decode_submessage(
        self: *Decoder,
        field: *const MiniTableField,
        parent_table: *const MiniTable,
    ) DecodeError!*Message {
        // Read length.
        const len_result = reader.read_varint(self.remaining()) catch |e| {
            return self.convert_error(e);
        };
        self.pos += len_result.consumed;

        if (len_result.value > self.limit -| self.pos) {
            return error.EndOfStream;
        }
        const length: usize = @intCast(len_result.value);
        const sub_end = self.pos + length;

        // Get submessage table.
        const sub_table = parent_table.submessages[field.submsg_index];

        // Allocate submessage.
        const sub_msg = Message.new(self.arena, sub_table) orelse {
            return error.OutOfMemory;
        };

        // Decode submessage with bounded limit.
        const saved_limit = self.limit;
        const saved_depth = self.depth;

        self.limit = sub_end;
        self.depth += 1;
        defer {
            self.limit = saved_limit;
            self.depth = saved_depth;
        }

        self.decode_message(sub_msg) catch |err| {
            // Convert EndOfStream inside submessage to Malformed
            // since we hit the submessage boundary unexpectedly.
            if (err == error.EndOfStream) return error.Malformed;
            return err;
        };

        // Ensure we consumed exactly the submessage bytes.
        if (self.pos != sub_end) {
            return error.Malformed;
        }

        return sub_msg;
    }

    fn decode_repeated_element(self: *Decoder, msg: *Message, field: *const MiniTableField) DecodeError!void {
        const repeated = msg.get_repeated(field);

        // Ensure capacity.
        if (repeated.count >= repeated.capacity) {
            try self.grow_repeated(repeated, field);
        }

        // Decode element.
        const element_size = repeated.element_size;
        const offset = repeated.count * element_size;
        const element_ptr = repeated.data.?[offset .. offset + element_size];

        switch (field.field_type) {
            .TYPE_BOOL => {
                const v = try self.read_varint();
                element_ptr[0] = if (v != 0) 1 else 0;
            },
            .TYPE_INT32, .TYPE_ENUM, .TYPE_UINT32 => {
                const v = try self.read_varint();
                const ptr: *u32 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = @truncate(v);
            },
            .TYPE_INT64, .TYPE_UINT64 => {
                const v = try self.read_varint();
                const ptr: *u64 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = v;
            },
            .TYPE_SINT32 => {
                const v = try self.read_varint();
                const ptr: *i32 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = reader.zigzag_decode_32(@truncate(v));
            },
            .TYPE_SINT64 => {
                const v = try self.read_varint();
                const ptr: *i64 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = reader.zigzag_decode_64(v);
            },
            .TYPE_FIXED32, .TYPE_SFIXED32 => {
                const result = reader.read_fixed32(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                const ptr: *u32 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = result.value;
            },
            .TYPE_FIXED64, .TYPE_SFIXED64 => {
                const result = reader.read_fixed64(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                const ptr: *u64 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = result.value;
            },
            .TYPE_FLOAT => {
                const result = reader.read_float(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                const ptr: *f32 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = result.value;
            },
            .TYPE_DOUBLE => {
                const result = reader.read_double(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                const ptr: *f64 = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = result.value;
            },
            .TYPE_STRING => {
                const sv = try self.decode_string(true);
                const ptr: *StringView = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = sv;
            },
            .TYPE_BYTES => {
                const sv = try self.decode_string(false);
                const ptr: *StringView = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = sv;
            },
            .TYPE_MESSAGE => {
                const sub_msg = try self.decode_submessage(field, msg.table);
                const ptr: *?*Message = @ptrCast(@alignCast(element_ptr.ptr));
                ptr.* = sub_msg;
            },
            .TYPE_GROUP => return error.Malformed,
        }

        repeated.count += 1;
    }

    fn decode_packed_repeated(
        self: *Decoder,
        msg: *Message,
        field: *const MiniTableField,
    ) DecodeError!void {
        // Read packed data length.
        const len_result = reader.read_varint(self.remaining()) catch |e| {
            return self.convert_error(e);
        };
        self.pos += len_result.consumed;

        if (len_result.value > self.limit -| self.pos) {
            return error.EndOfStream;
        }
        const length: usize = @intCast(len_result.value);
        const end_pos = self.pos + length;

        // Save and set limit for packed boundary validation.
        // This ensures element decodes cannot read past the packed region.
        const saved_limit = self.limit;
        self.limit = end_pos;
        defer self.limit = saved_limit;

        // Decode packed elements.
        while (self.pos < end_pos) {
            self.decode_repeated_element(msg, field) catch |err| {
                // Any error during packed decode means malformed packed data.
                // Convert EndOfStream to Malformed since we hit the packed boundary.
                if (err == error.EndOfStream) return error.Malformed;
                return err;
            };
        }

        // Exact boundary check - pos must equal end_pos after decoding all elements.
        if (self.pos != end_pos) {
            return error.Malformed;
        }
    }

    fn grow_repeated(self: *Decoder, repeated: *RepeatedField, field: *const MiniTableField) DecodeError!void {
        // Initialize element_size on first access (message data is zero-initialized).
        if (repeated.element_size == 0) {
            repeated.element_size = element_size_for_field(field);
        }

        const new_capacity = if (repeated.capacity == 0) 8 else repeated.capacity * 2;

        if (new_capacity > max_repeated_elements) {
            return error.OutOfMemory;
        }

        const new_size = new_capacity * repeated.element_size;
        const new_data = self.arena.alloc(u8, new_size) orelse return error.OutOfMemory;

        // Copy existing data.
        if (repeated.data) |old_data| {
            const old_size = repeated.count * repeated.element_size;
            @memcpy(new_data[0..old_size], old_data[0..old_size]);
        }

        repeated.data = new_data.ptr;
        repeated.capacity = new_capacity;
    }

    fn element_size_for_field(field: *const MiniTableField) u16 {
        return switch (field.field_type) {
            .TYPE_BOOL => 1,
            .TYPE_INT32, .TYPE_UINT32, .TYPE_FLOAT => 4,
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_FIXED32 => 4,
            .TYPE_ENUM => 4,
            .TYPE_INT64, .TYPE_UINT64, .TYPE_DOUBLE => 8,
            .TYPE_SINT64, .TYPE_SFIXED64, .TYPE_FIXED64 => 8,
            .TYPE_STRING, .TYPE_BYTES => @sizeOf(StringView),
            .TYPE_MESSAGE => @sizeOf(?*Message),
            .TYPE_GROUP => 0,
        };
    }

    fn skip_unknown_field(self: *Decoder, msg: *Message, tag: Tag) DecodeError!void {
        _ = msg; // TODO: Preserve unknown fields.

        const skip_bytes = reader.skip_field(self.remaining(), tag.wire_type) catch |e| {
            return self.convert_error(e);
        };
        self.pos += skip_bytes;
    }

    fn read_varint(self: *Decoder) DecodeError!u64 {
        const result = reader.read_varint(self.remaining()) catch |e| {
            return self.convert_error(e);
        };
        self.pos += result.consumed;
        return result.value;
    }

    fn remaining(self: *const Decoder) []const u8 {
        return self.input[self.pos..self.limit];
    }

    fn convert_error(self: *const Decoder, err: reader.ReadError) DecodeError {
        _ = self;
        return switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.VarintOverflow => error.VarintOverflow,
            error.Malformed => error.Malformed,
        };
    }
};

// Tests.

test "decode: empty message" {
    const fields = [_]MiniTableField{};
    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 8,
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 0,
    };

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;
    try decode(&.{}, msg, &arena, .{});
}

test "decode: single int32 field" {
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

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    // Field 1, varint, value 150.
    const input = [_]u8{ 0x08, 0x96, 0x01 };
    try decode(&input, msg, &arena, .{});

    const value = msg.get_scalar(&fields[0]);
    try std.testing.expectEqual(@as(i32, 150), value.int32_val);
}

test "decode: string field" {
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

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    // Field 2, delimited, "testing".
    const input = [_]u8{ 0x12, 0x07, 't', 'e', 's', 't', 'i', 'n', 'g' };
    try decode(&input, msg, &arena, .{});

    const value = msg.get_scalar(&fields[0]);
    try std.testing.expectEqualStrings("testing", value.string_val.slice());
}

test "decode: zero-copy string" {
    const fields = [_]MiniTableField{
        .{
            .number = 1,
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
        .dense_below = 1,
    };

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    const input = [_]u8{ 0x0a, 0x05, 'h', 'e', 'l', 'l', 'o' };
    try decode(&input, msg, &arena, .{ .alias_string = true });

    const value = msg.get_scalar(&fields[0]);
    try std.testing.expect(value.string_val.is_aliased);
    try std.testing.expectEqualStrings("hello", value.string_val.slice());
}

test "decode: unknown field skipped" {
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

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    // Field 1 = 42, then unknown field 99 = 123.
    const input = [_]u8{
        0x08, 0x2a, // field 1, varint 42
        0xf8, 0x06, 0x7b, // field 99, varint 123
    };
    try decode(&input, msg, &arena, .{});

    const value = msg.get_scalar(&fields[0]);
    try std.testing.expectEqual(@as(i32, 42), value.int32_val);
}
