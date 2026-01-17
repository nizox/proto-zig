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
const MapField = @import("../message.zig").MapField;
const FieldValue = @import("../message.zig").FieldValue;
const MiniTable = @import("../mini_table.zig").MiniTable;
const MiniTableField = @import("../mini_table.zig").MiniTableField;
const FieldType = @import("../mini_table.zig").FieldType;
const Mode = @import("../mini_table.zig").Mode;
const map_mod = @import("../map.zig");
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

/// Default map implementation: ArrayHashMapUnmanaged (preserves insertion order).
pub const DefaultMap = map_mod.DefaultMap;

/// Generic decoder parameterized by map implementation.
/// Create once, decode multiple messages.
///
/// Example usage:
/// ```
/// // Simple: use DefaultDecoder
/// var decoder = DefaultDecoder.init(&arena);
/// try decoder.decode(data, msg, .{});
///
/// // Custom: use a different map type
/// const HashMapDecoder = Decoder(std.HashMapUnmanaged);
/// var decoder = HashMapDecoder.init(&arena);
/// try decoder.decode(data, msg, .{});
/// ```
pub fn Decoder(comptime MapImpl: fn (type, type) type) type {
    return struct {
        arena: *Arena,

        const Self = @This();

        pub fn init(arena: *Arena) Self {
            return .{ .arena = arena };
        }

        /// Decode binary protobuf into message.
        pub fn decode(
            self: *Self,
            input: []const u8,
            msg: *Message,
            options: DecodeOptions,
        ) DecodeError!void {
            var state = DecodeState{
                .input = input,
                .pos = 0,
                .limit = input.len,
                .arena = self.arena,
                .options = options,
                .depth = 0,
            };

            try state.decode_message(msg);
        }

        /// Internal decode state.
        const DecodeState = struct {
            input: []const u8,
            pos: usize,
            limit: usize,
            arena: *Arena,
            options: DecodeOptions,
            depth: u8,

            /// Maximum number of repeated field elements per message to prevent DoS.
            const max_repeated_elements: u32 = 10_000_000;

            fn decode_message(self: *DecodeState, msg: *Message) DecodeError!void {
                if (self.depth >= self.options.max_depth) {
                    return error.MaxDepthExceeded;
                }

                while (self.pos < self.limit) {
                    const tag_result = reader.read_tag(self.remaining()) catch |err| {
                        return self.convert_error(err);
                    };
                    self.pos += tag_result.consumed;

                    const tag = tag_result.value;
                    if (!tag.is_valid()) {
                        return error.Malformed;
                    }

                    const field = msg.table.field_by_number(tag.field_number);

                    if (field) |f| {
                        try self.decode_field(msg, f, tag.wire_type);
                    } else {
                        try self.skip_unknown_field(msg, tag);
                    }
                }
            }

            fn decode_field(
                self: *DecodeState,
                msg: *Message,
                field: *const MiniTableField,
                wire_type: WireType,
            ) DecodeError!void {
                const expected_wire_type = field.wire_type();
                const native_wire_type = field.field_type.wire_type();

                // Handle map fields (wire format is repeated submessage).
                if (field.mode == .map) {
                    if (wire_type != .delimited) {
                        return error.WireTypeMismatch;
                    }
                    return self.decode_map_entry(msg, field);
                }

                // Handle packed repeated fields.
                if (field.mode == .repeated and wire_type == .delimited and
                    native_wire_type != .delimited)
                {
                    return self.decode_packed_repeated(msg, field);
                }

                // Proto3 compatibility: accept unpacked encoding for packed fields.
                if (field.mode == .repeated and field.is_packed and wire_type == native_wire_type) {
                    return self.decode_repeated_element(msg, field);
                }

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

            fn decode_map_entry(
                self: *DecodeState,
                msg: *Message,
                field: *const MiniTableField,
            ) DecodeError!void {
                // Read entry length.
                const len_result = reader.read_varint(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += len_result.consumed;

                if (len_result.value > self.limit -| self.pos) {
                    return error.EndOfStream;
                }
                const length: usize = @intCast(len_result.value);
                const entry_end = self.pos + length;

                // Get map entry table (submessage with key=1, value=2).
                const entry_table = msg.table.submessages[field.submsg_index];
                const key_field = entry_table.field_by_number(1) orelse return error.Malformed;
                const value_field = entry_table.field_by_number(2) orelse return error.Malformed;

                // Allocate temporary entry message.
                const entry_msg = Message.new(self.arena, entry_table) orelse {
                    return error.OutOfMemory;
                };

                // Decode entry with bounded limit.
                const saved_limit = self.limit;
                const saved_depth = self.depth;

                self.limit = entry_end;
                self.depth += 1;
                defer {
                    self.limit = saved_limit;
                    self.depth = saved_depth;
                }

                self.decode_message(entry_msg) catch |err| {
                    if (err == error.EndOfStream) return error.Malformed;
                    return err;
                };

                if (self.pos != entry_end) {
                    return error.Malformed;
                }

                // Get map field and ensure map is allocated.
                const map_field = msg.get_map(field);

                // Insert into map based on key/value types.
                try self.insert_map_entry(map_field, entry_msg, key_field, value_field);
            }

            fn insert_map_entry(
                self: *DecodeState,
                map_field: *MapField,
                entry_msg: *const Message,
                key_field: *const MiniTableField,
                value_field: *const MiniTableField,
            ) DecodeError!void {
                // Dispatch based on key type.
                switch (key_field.field_type) {
                    .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32 => {
                        try self.insert_map_entry_key(i32, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => {
                        try self.insert_map_entry_key(i64, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_UINT32, .TYPE_FIXED32 => {
                        try self.insert_map_entry_key(u32, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_UINT64, .TYPE_FIXED64 => {
                        try self.insert_map_entry_key(u64, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_BOOL => {
                        try self.insert_map_entry_key(bool, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_STRING => {
                        try self.insert_map_entry_key(StringView, map_field, entry_msg, key_field, value_field);
                    },
                    else => return error.Malformed, // Invalid key type for map.
                }
            }

            fn insert_map_entry_key(
                self: *DecodeState,
                comptime K: type,
                map_field: *MapField,
                entry_msg: *const Message,
                key_field: *const MiniTableField,
                value_field: *const MiniTableField,
            ) DecodeError!void {
                // Dispatch based on value type.
                switch (value_field.field_type) {
                    .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_ENUM => {
                        try self.insert_map_entry_typed(K, i32, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => {
                        try self.insert_map_entry_typed(K, i64, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_UINT32, .TYPE_FIXED32 => {
                        try self.insert_map_entry_typed(K, u32, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_UINT64, .TYPE_FIXED64 => {
                        try self.insert_map_entry_typed(K, u64, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_BOOL => {
                        try self.insert_map_entry_typed(K, bool, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_FLOAT => {
                        try self.insert_map_entry_typed(K, f32, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_DOUBLE => {
                        try self.insert_map_entry_typed(K, f64, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_STRING, .TYPE_BYTES => {
                        try self.insert_map_entry_typed(K, StringView, map_field, entry_msg, key_field, value_field);
                    },
                    .TYPE_MESSAGE => {
                        try self.insert_map_entry_typed(K, *Message, map_field, entry_msg, key_field, value_field);
                    },
                    else => return error.Malformed,
                }
            }

            fn insert_map_entry_typed(
                self: *DecodeState,
                comptime K: type,
                comptime V: type,
                map_field: *MapField,
                entry_msg: *const Message,
                key_field: *const MiniTableField,
                value_field: *const MiniTableField,
            ) DecodeError!void {
                const Map = MapImpl(K, V);

                // Allocate map on first use.
                if (map_field.ptr == null) {
                    const map_ptr = self.arena.create(Map) orelse return error.OutOfMemory;
                    map_ptr.* = .{};
                    map_field.ptr = map_ptr;
                    map_field.key_type = key_field.field_type;
                    map_field.value_type = value_field.field_type;
                }

                const map = map_field.getTyped(Map);

                // Extract key (use default for missing fields).
                const key = self.extract_map_key(K, entry_msg, key_field);

                // Extract value (use default for missing fields).
                const value = try self.extract_map_value(V, entry_msg, value_field);

                // Insert into map.
                map.put(self.arena.allocator(), key, value) catch return error.OutOfMemory;
            }

            fn extract_map_key(self: *DecodeState, comptime K: type, entry_msg: *const Message, key_field: *const MiniTableField) K {
                _ = self;
                const field_value = entry_msg.get_scalar(key_field);
                // For missing fields with no hasbit, get_scalar returns the raw memory value.
                // Since messages are zero-initialized, this gives us the correct default.
                return switch (K) {
                    i32 => field_value.int32_val,
                    i64 => field_value.int64_val,
                    u32 => field_value.uint32_val,
                    u64 => field_value.uint64_val,
                    bool => field_value.bool_val,
                    StringView => field_value.string_val,
                    else => @compileError("Unsupported map key type"),
                };
            }

            fn extract_map_value(self: *DecodeState, comptime V: type, entry_msg: *const Message, value_field: *const MiniTableField) DecodeError!V {
                const field_value = entry_msg.get_scalar(value_field);
                return switch (V) {
                    i32 => field_value.int32_val,
                    i64 => field_value.int64_val,
                    u32 => field_value.uint32_val,
                    u64 => field_value.uint64_val,
                    bool => field_value.bool_val,
                    f32 => field_value.float_val,
                    f64 => field_value.double_val,
                    StringView => switch (field_value) {
                        .string_val => |sv| sv,
                        .bytes_val => |sv| sv,
                        else => StringView.empty(),
                    },
                    *Message => switch (field_value) {
                        .message_val => |msg| msg,
                        .none => {
                            // Missing message value - create empty default message.
                            // Get the value message's MiniTable from the entry table.
                            const value_table = entry_msg.table.submessages[value_field.submsg_index];
                            const empty_msg = Message.new(self.arena, value_table) orelse return error.OutOfMemory;
                            return empty_msg;
                        },
                        else => unreachable,
                    },
                    else => @compileError("Unsupported map value type"),
                };
            }

            fn decode_value(
                self: *DecodeState,
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
                    .TYPE_GROUP => error.Malformed,
                };
            }

            fn decode_string(self: *DecodeState, check_utf8: bool) DecodeError!StringView {
                const result = reader.read_length_delimited(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;

                const data = result.value;

                if (check_utf8 and self.options.check_utf8) {
                    if (!std.unicode.utf8ValidateSlice(data)) {
                        return error.BadUtf8;
                    }
                }

                if (self.options.alias_string) {
                    return StringView.from_aliased(data);
                } else {
                    const copy = self.arena.dupe(data) orelse return error.OutOfMemory;
                    return StringView.from_slice(copy);
                }
            }

            fn decode_submessage(
                self: *DecodeState,
                field: *const MiniTableField,
                parent_table: *const MiniTable,
            ) DecodeError!*Message {
                const len_result = reader.read_varint(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += len_result.consumed;

                if (len_result.value > self.limit -| self.pos) {
                    return error.EndOfStream;
                }
                const length: usize = @intCast(len_result.value);
                const sub_end = self.pos + length;

                const sub_table = parent_table.submessages[field.submsg_index];

                const sub_msg = Message.new(self.arena, sub_table) orelse {
                    return error.OutOfMemory;
                };

                const saved_limit = self.limit;
                const saved_depth = self.depth;

                self.limit = sub_end;
                self.depth += 1;
                defer {
                    self.limit = saved_limit;
                    self.depth = saved_depth;
                }

                self.decode_message(sub_msg) catch |err| {
                    if (err == error.EndOfStream) return error.Malformed;
                    return err;
                };

                if (self.pos != sub_end) {
                    return error.Malformed;
                }

                return sub_msg;
            }

            fn decode_repeated_element(self: *DecodeState, msg: *Message, field: *const MiniTableField) DecodeError!void {
                const repeated = msg.get_repeated(field);

                if (repeated.count >= repeated.capacity) {
                    try self.grow_repeated(repeated, field);
                }

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
                self: *DecodeState,
                msg: *Message,
                field: *const MiniTableField,
            ) DecodeError!void {
                const len_result = reader.read_varint(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += len_result.consumed;

                if (len_result.value > self.limit -| self.pos) {
                    return error.EndOfStream;
                }
                const length: usize = @intCast(len_result.value);
                const end_pos = self.pos + length;

                const saved_limit = self.limit;
                self.limit = end_pos;
                defer self.limit = saved_limit;

                while (self.pos < end_pos) {
                    self.decode_repeated_element(msg, field) catch |err| {
                        if (err == error.EndOfStream) return error.Malformed;
                        return err;
                    };
                }

                if (self.pos != end_pos) {
                    return error.Malformed;
                }
            }

            fn grow_repeated(self: *DecodeState, repeated: *RepeatedField, field: *const MiniTableField) DecodeError!void {
                if (repeated.element_size == 0) {
                    repeated.element_size = element_size_for_field(field);
                }

                const new_capacity = if (repeated.capacity == 0) 8 else repeated.capacity * 2;

                if (new_capacity > max_repeated_elements) {
                    return error.OutOfMemory;
                }

                const new_size = new_capacity * repeated.element_size;
                const new_data = self.arena.alloc(u8, new_size) orelse return error.OutOfMemory;

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

            fn skip_unknown_field(self: *DecodeState, msg: *Message, tag: Tag) DecodeError!void {
                _ = msg;

                const skip_bytes = reader.skip_field(self.remaining(), tag.wire_type) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += skip_bytes;
            }

            fn read_varint(self: *DecodeState) DecodeError!u64 {
                const result = reader.read_varint(self.remaining()) catch |e| {
                    return self.convert_error(e);
                };
                self.pos += result.consumed;
                return result.value;
            }

            fn remaining(self: *const DecodeState) []const u8 {
                return self.input[self.pos..self.limit];
            }

            fn convert_error(self: *const DecodeState, err: reader.ReadError) DecodeError {
                _ = self;
                return switch (err) {
                    error.EndOfStream => error.EndOfStream,
                    error.VarintOverflow => error.VarintOverflow,
                    error.Malformed => error.Malformed,
                };
            }
        };
    };
}

/// Default decoder using ArrayHashMap for maps.
pub const DefaultDecoder = Decoder(DefaultMap);

/// Decode a binary protobuf message (convenience function).
///
/// The message must be pre-allocated from the arena. The input buffer must
/// outlive the message if alias_string is true.
pub fn decode(
    input: []const u8,
    msg: *Message,
    arena: *Arena,
    options: DecodeOptions,
) DecodeError!void {
    var decoder = DefaultDecoder.init(arena);
    return decoder.decode(input, msg, options);
}

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

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

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

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

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

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

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

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

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

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

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

test "decode: map field int32->string" {
    // Map entry message: { key: int32 = 1, value: string = 2 }
    const entry_fields = [_]MiniTableField{
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
            .offset = 8, // After i32 + padding
            .presence = 0,
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_STRING,
            .mode = .scalar,
            .is_packed = false,
        },
    };

    const entry_table = MiniTable{
        .fields = &entry_fields,
        .submessages = &.{},
        .size = 24, // i32 + padding + StringView
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 2,
    };

    // Parent message with map field
    const map_field = MiniTableField{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE, // Maps are messages on the wire
        .mode = .map,
        .is_packed = false,
    };

    const fields = [_]MiniTableField{map_field};
    const submessages = [_]*const MiniTable{&entry_table};

    const table = MiniTable{
        .fields = &fields,
        .submessages = &submessages,
        .size = @sizeOf(MapField),
        .hasbit_bytes = 0,
        .oneof_count = 0,
        .dense_below = 1,
    };

    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    const msg = Message.new(&arena, &table).?;

    // Encode: field 1 (map), entry with key=42, value="hello"
    // Entry: key (field 1, varint) = 08 2a, value (field 2, string) = 12 05 "hello"
    // Entry length: 2 + 7 = 9 bytes
    // Map field: tag 0a (field 1, delimited), length 09, entry bytes
    const input = [_]u8{
        0x0a, 0x09, // field 1, delimited, length 9
        0x08, 0x2a, // key field 1, varint 42
        0x12, 0x05, 'h', 'e', 'l', 'l', 'o', // value field 2, string "hello"
    };

    try decode(&input, msg, &arena, .{});

    const map_field_ptr = msg.get_map(&map_field);
    try std.testing.expect(map_field_ptr.ptr != null);

    const map = map_field_ptr.getTyped(DefaultMap(i32, StringView));
    try std.testing.expectEqual(@as(usize, 1), map.count());

    const value = map.get(42);
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("hello", value.?.slice());
}

test "decode: Decoder struct reusable" {
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

    // Create decoder once, use multiple times
    var decoder = DefaultDecoder.init(&arena);

    const msg1 = Message.new(&arena, &table).?;
    const input1 = [_]u8{ 0x08, 0x2a }; // field 1 = 42
    try decoder.decode(&input1, msg1, .{});
    try std.testing.expectEqual(@as(i32, 42), msg1.get_scalar(&fields[0]).int32_val);

    const msg2 = Message.new(&arena, &table).?;
    const input2 = [_]u8{ 0x08, 0x63 }; // field 1 = 99
    try decoder.decode(&input2, msg2, .{});
    try std.testing.expectEqual(@as(i32, 99), msg2.get_scalar(&fields[0]).int32_val);
}
