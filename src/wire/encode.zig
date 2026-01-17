//! Protobuf binary wire format encoder.
//!
//! Encodes Message instances into binary protobuf wire format.

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

/// Default map implementation.
pub const DefaultMap = map_mod.DefaultMap;

/// Maximum message size (2GB).
const max_message_size: u32 = 0x7FFFFFFF;

/// Generic encoder parameterized by map implementation.
///
/// Example usage:
/// ```
/// // Simple: use convenience function
/// const encoded = try proto.encode(msg, &arena, .{});
///
/// // Explicit: create encoder with custom map type
/// const HashMapEncoder = Encoder(std.HashMapUnmanaged);
/// const encoded = try HashMapEncoder.encode(msg, &arena, .{});
/// ```
pub fn Encoder(comptime MapImpl: fn (type, type) type) type {
    return struct {
        const Self = @This();

        /// Encode a message to binary protobuf wire format.
        /// Returns a slice pointing to the encoded data in the arena.
        pub fn encode(
            msg: *const Message,
            arena: *Arena,
            options: EncodeOptions,
        ) EncodeError![]const u8 {
            // First pass: calculate size.
            const size = Self.calculate_size(msg, options);

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
            var state = EncodeState{
                .buf = buf,
                .pos = 0,
                .options = options,
            };

            state.encode_message(msg);

            assert(state.pos == size);
            return buf;
        }

        /// Calculate the encoded size of a message.
        fn calculate_size(msg: *const Message, options: EncodeOptions) u32 {
            var size: u32 = 0;

            var iter = msg.table.field_iter();
            while (iter.next()) |field| {
                if (field.mode == .map) {
                    size += Self.calculate_map_size(msg, field, options);
                } else if (field.mode == .repeated) {
                    size += calculate_repeated_size(msg, field, options);
                } else {
                    size += calculate_scalar_size(msg, field);
                }
            }

            if (!options.skip_unknown) {
                if (msg.unknown_fields) |uf| {
                    size += @intCast(uf.len);
                }
            }

            return size;
        }

        fn calculate_map_size(msg: *const Message, field: *const MiniTableField, options: EncodeOptions) u32 {
            _ = options;

            const map_field = msg.get_map_const(field);
            if (map_field.ptr == null) {
                return 0;
            }

            const tag = Tag{ .field_number = @intCast(field.number), .wire_type = .delimited };
            const tag_size = varint_size(tag.to_raw());

            // Dispatch based on key/value types to get actual map and calculate size.
            return Self.calculate_map_size_typed(map_field, field, tag_size);
        }

        fn calculate_map_size_typed(map_field: *const MapField, field: *const MiniTableField, tag_size: u32) u32 {
            // Get entry table for field layout info.
            const entry_table = field.submsg_index; // We need this to get key/value field info.
            _ = entry_table;

            // Dispatch on key type.
            return switch (map_field.key_type) {
                .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32 => Self.calculate_map_size_key(i32, map_field, tag_size),
                .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => Self.calculate_map_size_key(i64, map_field, tag_size),
                .TYPE_UINT32, .TYPE_FIXED32 => Self.calculate_map_size_key(u32, map_field, tag_size),
                .TYPE_UINT64, .TYPE_FIXED64 => Self.calculate_map_size_key(u64, map_field, tag_size),
                .TYPE_BOOL => Self.calculate_map_size_key(bool, map_field, tag_size),
                .TYPE_STRING => Self.calculate_map_size_key(StringView, map_field, tag_size),
                else => 0,
            };
        }

        fn calculate_map_size_key(comptime K: type, map_field: *const MapField, tag_size: u32) u32 {
            return switch (map_field.value_type) {
                .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_ENUM => Self.calculate_map_size_kv(K, i32, map_field, tag_size),
                .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => Self.calculate_map_size_kv(K, i64, map_field, tag_size),
                .TYPE_UINT32, .TYPE_FIXED32 => Self.calculate_map_size_kv(K, u32, map_field, tag_size),
                .TYPE_UINT64, .TYPE_FIXED64 => Self.calculate_map_size_kv(K, u64, map_field, tag_size),
                .TYPE_BOOL => Self.calculate_map_size_kv(K, bool, map_field, tag_size),
                .TYPE_FLOAT => Self.calculate_map_size_kv(K, f32, map_field, tag_size),
                .TYPE_DOUBLE => Self.calculate_map_size_kv(K, f64, map_field, tag_size),
                .TYPE_STRING, .TYPE_BYTES => Self.calculate_map_size_kv(K, StringView, map_field, tag_size),
                .TYPE_MESSAGE => Self.calculate_map_size_kv(K, *Message, map_field, tag_size),
                else => 0,
            };
        }

        fn calculate_map_size_kv(comptime K: type, comptime V: type, map_field: *const MapField, tag_size: u32) u32 {
            const Map = MapImpl(K, V);
            const map = map_field.getTypedConstOrNull(Map) orelse return 0;

            var total: u32 = 0;
            var iter = map.iterator();
            while (iter.next()) |entry| {
                // Entry: tag(1) + key + tag(2) + value
                const key_size = key_encoded_size(K, entry.key_ptr.*, map_field.key_type);
                const value_size = value_encoded_size(V, entry.value_ptr.*, map_field.value_type);
                const entry_size = key_size + value_size;
                total += tag_size + varint_size(entry_size) + entry_size;
            }

            return total;
        }

        const EncodeState = struct {
            buf: []u8,
            pos: u32,
            options: EncodeOptions,

            fn encode_message(self: *EncodeState, msg: *const Message) void {
                var iter = msg.table.field_iter();
                while (iter.next()) |field| {
                    if (field.mode == .map) {
                        self.encode_map(msg, field);
                    } else if (field.mode == .repeated) {
                        self.encode_repeated(msg, field);
                    } else {
                        self.encode_scalar(msg, field);
                    }
                }

                if (!self.options.skip_unknown) {
                    if (msg.unknown_fields) |uf| {
                        @memcpy(self.buf[self.pos .. self.pos + uf.len], uf);
                        self.pos += @intCast(uf.len);
                    }
                }
            }

            fn encode_map(self: *EncodeState, msg: *const Message, field: *const MiniTableField) void {
                const map_field = msg.get_map_const(field);
                if (map_field.ptr == null) {
                    return;
                }

                // Dispatch based on key type.
                switch (map_field.key_type) {
                    .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32 => self.encode_map_key(i32, map_field, field),
                    .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => self.encode_map_key(i64, map_field, field),
                    .TYPE_UINT32, .TYPE_FIXED32 => self.encode_map_key(u32, map_field, field),
                    .TYPE_UINT64, .TYPE_FIXED64 => self.encode_map_key(u64, map_field, field),
                    .TYPE_BOOL => self.encode_map_key(bool, map_field, field),
                    .TYPE_STRING => self.encode_map_key(StringView, map_field, field),
                    else => {},
                }
            }

            fn encode_map_key(self: *EncodeState, comptime K: type, map_field: *const MapField, field: *const MiniTableField) void {
                switch (map_field.value_type) {
                    .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_ENUM => self.encode_map_kv(K, i32, map_field, field),
                    .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => self.encode_map_kv(K, i64, map_field, field),
                    .TYPE_UINT32, .TYPE_FIXED32 => self.encode_map_kv(K, u32, map_field, field),
                    .TYPE_UINT64, .TYPE_FIXED64 => self.encode_map_kv(K, u64, map_field, field),
                    .TYPE_BOOL => self.encode_map_kv(K, bool, map_field, field),
                    .TYPE_FLOAT => self.encode_map_kv(K, f32, map_field, field),
                    .TYPE_DOUBLE => self.encode_map_kv(K, f64, map_field, field),
                    .TYPE_STRING, .TYPE_BYTES => self.encode_map_kv(K, StringView, map_field, field),
                    .TYPE_MESSAGE => self.encode_map_kv(K, *Message, map_field, field),
                    else => {},
                }
            }

            fn encode_map_kv(self: *EncodeState, comptime K: type, comptime V: type, map_field: *const MapField, field: *const MiniTableField) void {
                const Map = MapImpl(K, V);
                const map = map_field.getTypedConstOrNull(Map) orelse return;

                var iter = map.iterator();
                while (iter.next()) |entry| {
                    // Write field tag (delimited).
                    self.write_tag(field.number, .delimited);

                    // Calculate entry size.
                    const key_size = key_encoded_size(K, entry.key_ptr.*, map_field.key_type);
                    const value_size = value_encoded_size(V, entry.value_ptr.*, map_field.value_type);
                    const entry_size = key_size + value_size;

                    // Write entry length.
                    self.write_varint(entry_size);

                    // Write key (field 1).
                    self.write_key(K, entry.key_ptr.*, map_field.key_type);

                    // Write value (field 2).
                    self.write_value(V, entry.value_ptr.*, map_field.value_type);
                }
            }

            fn write_key(self: *EncodeState, comptime K: type, key: K, key_type: FieldType) void {
                const wire_type = key_type.wire_type();
                self.write_tag(1, wire_type);

                switch (K) {
                    i32 => switch (key_type) {
                        .TYPE_INT32 => self.write_varint_i32(key),
                        .TYPE_SINT32 => self.write_varint(zigzag_encode_32(key)),
                        .TYPE_SFIXED32 => self.write_fixed32(@bitCast(key)),
                        else => {},
                    },
                    i64 => switch (key_type) {
                        .TYPE_INT64 => self.write_varint_i64(key),
                        .TYPE_SINT64 => self.write_varint(zigzag_encode_64(key)),
                        .TYPE_SFIXED64 => self.write_fixed64(@bitCast(key)),
                        else => {},
                    },
                    u32 => switch (key_type) {
                        .TYPE_UINT32 => self.write_varint(key),
                        .TYPE_FIXED32 => self.write_fixed32(key),
                        else => {},
                    },
                    u64 => switch (key_type) {
                        .TYPE_UINT64 => self.write_varint(key),
                        .TYPE_FIXED64 => self.write_fixed64(key),
                        else => {},
                    },
                    bool => self.write_varint(if (key) 1 else 0),
                    StringView => self.write_length_delimited(key.slice()),
                    else => {},
                }
            }

            fn write_value(self: *EncodeState, comptime V: type, value: V, value_type: FieldType) void {
                const wire_type = value_type.wire_type();
                self.write_tag(2, wire_type);

                switch (V) {
                    i32 => switch (value_type) {
                        .TYPE_INT32, .TYPE_ENUM => self.write_varint_i32(value),
                        .TYPE_SINT32 => self.write_varint(zigzag_encode_32(value)),
                        .TYPE_SFIXED32 => self.write_fixed32(@bitCast(value)),
                        else => {},
                    },
                    i64 => switch (value_type) {
                        .TYPE_INT64 => self.write_varint_i64(value),
                        .TYPE_SINT64 => self.write_varint(zigzag_encode_64(value)),
                        .TYPE_SFIXED64 => self.write_fixed64(@bitCast(value)),
                        else => {},
                    },
                    u32 => switch (value_type) {
                        .TYPE_UINT32 => self.write_varint(value),
                        .TYPE_FIXED32 => self.write_fixed32(value),
                        else => {},
                    },
                    u64 => switch (value_type) {
                        .TYPE_UINT64 => self.write_varint(value),
                        .TYPE_FIXED64 => self.write_fixed64(value),
                        else => {},
                    },
                    bool => self.write_varint(if (value) 1 else 0),
                    f32 => self.write_fixed32(@bitCast(value)),
                    f64 => self.write_fixed64(@bitCast(value)),
                    StringView => self.write_length_delimited(value.slice()),
                    *Message => {
                        const sub_size = Self.calculate_size(value, .{});
                        self.write_varint(sub_size);
                        self.encode_message(value);
                    },
                    else => {},
                }
            }

            fn encode_scalar(self: *EncodeState, msg: *const Message, field: *const MiniTableField) void {
                if (!msg.has_field(field)) {
                    return;
                }

                const value = msg.get_scalar(field);
                if (value == .none) {
                    return;
                }

                self.write_tag(field.number, field.wire_type());

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
                        const sub_size = Self.calculate_size(value.message_val, .{});
                        self.write_varint(sub_size);
                        self.encode_message(value.message_val);
                    },
                    .TYPE_GROUP => {},
                }
            }

            fn encode_repeated(self: *EncodeState, msg: *const Message, field: *const MiniTableField) void {
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
                self: *EncodeState,
                repeated: *const RepeatedField,
                field: *const MiniTableField,
            ) void {
                var data_size: u32 = 0;
                var i: u32 = 0;
                while (i < repeated.count) : (i += 1) {
                    data_size += calculate_element_size(repeated, field, i);
                }

                self.write_tag(field.number, .delimited);
                self.write_varint(data_size);

                i = 0;
                while (i < repeated.count) : (i += 1) {
                    self.encode_element(repeated, field, i);
                }
            }

            fn encode_element(
                self: *EncodeState,
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
                            const sub_size = Self.calculate_size(sub_msg, .{});
                            self.write_varint(sub_size);
                            self.encode_message(sub_msg);
                        }
                    },
                    .TYPE_GROUP => {},
                }
            }

            fn write_tag(self: *EncodeState, field_number: u32, wire_type: WireType) void {
                const tag = Tag{ .field_number = @intCast(field_number), .wire_type = wire_type };
                self.write_varint(tag.to_raw());
            }

            fn write_varint(self: *EncodeState, value: u64) void {
                var v = value;
                while (v >= 0x80) {
                    self.buf[self.pos] = @truncate((v & 0x7F) | 0x80);
                    self.pos += 1;
                    v >>= 7;
                }
                self.buf[self.pos] = @truncate(v);
                self.pos += 1;
            }

            fn write_varint_i32(self: *EncodeState, value: i32) void {
                self.write_varint(@bitCast(@as(i64, value)));
            }

            fn write_varint_i64(self: *EncodeState, value: i64) void {
                self.write_varint(@bitCast(value));
            }

            fn write_fixed32(self: *EncodeState, value: u32) void {
                std.mem.writeInt(u32, self.buf[self.pos..][0..4], value, .little);
                self.pos += 4;
            }

            fn write_fixed64(self: *EncodeState, value: u64) void {
                std.mem.writeInt(u64, self.buf[self.pos..][0..8], value, .little);
                self.pos += 8;
            }

            fn write_length_delimited(self: *EncodeState, data: []const u8) void {
                self.write_varint(@intCast(data.len));
                @memcpy(self.buf[self.pos .. self.pos + data.len], data);
                self.pos += @intCast(data.len);
            }
        };
    };
}

/// Default encoder using ArrayHashMap for maps.
pub const DefaultEncoder = Encoder(DefaultMap);

/// Encode a message to binary protobuf wire format (convenience function).
/// Returns a slice pointing to the encoded data in the arena.
pub fn encode(
    msg: *const Message,
    arena: *Arena,
    options: EncodeOptions,
) EncodeError![]const u8 {
    return DefaultEncoder.encode(msg, arena, options);
}

// Helper functions.

fn key_encoded_size(comptime K: type, key: K, key_type: FieldType) u32 {
    const tag_size: u32 = 1; // Field 1, single byte tag.
    const value_size: u32 = switch (K) {
        i32 => switch (key_type) {
            .TYPE_INT32 => varint_size_i32(key),
            .TYPE_SINT32 => varint_size(zigzag_encode_32(key)),
            .TYPE_SFIXED32 => 4,
            else => 0,
        },
        i64 => switch (key_type) {
            .TYPE_INT64 => varint_size_i64(key),
            .TYPE_SINT64 => varint_size(zigzag_encode_64(key)),
            .TYPE_SFIXED64 => 8,
            else => 0,
        },
        u32 => switch (key_type) {
            .TYPE_UINT32 => varint_size(key),
            .TYPE_FIXED32 => 4,
            else => 0,
        },
        u64 => switch (key_type) {
            .TYPE_UINT64 => varint_size(key),
            .TYPE_FIXED64 => 8,
            else => 0,
        },
        bool => 1,
        StringView => varint_size(key.len) + key.len,
        else => 0,
    };
    return tag_size + value_size;
}

fn value_encoded_size(comptime V: type, value: V, value_type: FieldType) u32 {
    const tag_size: u32 = 1; // Field 2, single byte tag.
    const data_size: u32 = switch (V) {
        i32 => switch (value_type) {
            .TYPE_INT32, .TYPE_ENUM => varint_size_i32(value),
            .TYPE_SINT32 => varint_size(zigzag_encode_32(value)),
            .TYPE_SFIXED32 => 4,
            else => 0,
        },
        i64 => switch (value_type) {
            .TYPE_INT64 => varint_size_i64(value),
            .TYPE_SINT64 => varint_size(zigzag_encode_64(value)),
            .TYPE_SFIXED64 => 8,
            else => 0,
        },
        u32 => switch (value_type) {
            .TYPE_UINT32 => varint_size(value),
            .TYPE_FIXED32 => 4,
            else => 0,
        },
        u64 => switch (value_type) {
            .TYPE_UINT64 => varint_size(value),
            .TYPE_FIXED64 => 8,
            else => 0,
        },
        bool => 1,
        f32 => 4,
        f64 => 8,
        StringView => varint_size(value.len) + value.len,
        *Message => blk: {
            const sub_size = DefaultEncoder.calculate_size(value, .{});
            break :blk varint_size(sub_size) + sub_size;
        },
        else => 0,
    };
    return tag_size + data_size;
}

fn calculate_scalar_size(msg: *const Message, field: *const MiniTableField) u32 {
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
            const sub_size = DefaultEncoder.calculate_size(value.message_val, .{});
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
        var data_size: u32 = 0;
        var i: u32 = 0;
        while (i < repeated.count) : (i += 1) {
            data_size += calculate_element_size(repeated, field, i);
        }
        return tag_size + varint_size(data_size) + data_size;
    } else {
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
                const sub_size = DefaultEncoder.calculate_size(sub_msg, .{});
                break :blk varint_size(sub_size) + sub_size;
            }
            break :blk 0;
        },
        .TYPE_GROUP => 0,
    };
}

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
