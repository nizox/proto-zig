//! Runtime representation of a protobuf message.
//!
//! Message provides a dynamic, reflection-based interface for accessing
//! protobuf message fields. Memory is allocated from an Arena.

const std = @import("std");
const assert = std.debug.assert;
const Arena = @import("arena.zig").Arena;
const MiniTable = @import("mini_table.zig").MiniTable;
const MiniTableField = @import("mini_table.zig").MiniTableField;
const FieldType = @import("mini_table.zig").FieldType;
const Mode = @import("mini_table.zig").Mode;

/// A string or bytes value that may be aliased to the input buffer.
/// Using extern struct to ensure consistent layout in message data.
pub const StringView = extern struct {
    ptr: [*]const u8,
    len: u32,

    /// True if this string points into the original input buffer (zero-copy).
    is_aliased: bool,

    pub fn slice(self: StringView) []const u8 {
        return self.ptr[0..self.len];
    }

    pub fn empty() StringView {
        return .{ .ptr = undefined, .len = 0, .is_aliased = false };
    }

    pub fn from_slice(s: []const u8) StringView {
        return .{
            .ptr = s.ptr,
            .len = @intCast(s.len),
            .is_aliased = false,
        };
    }

    pub fn from_aliased(s: []const u8) StringView {
        return .{
            .ptr = s.ptr,
            .len = @intCast(s.len),
            .is_aliased = true,
        };
    }
};

/// Dynamic array for repeated fields.
pub const RepeatedField = struct {
    /// Pointer to the array data.
    data: ?[*]u8,

    /// Number of elements in the array.
    count: u32,

    /// Allocated capacity in elements.
    capacity: u32,

    /// Size of each element in bytes.
    element_size: u16,

    pub fn empty(element_size: u16) RepeatedField {
        return .{
            .data = null,
            .count = 0,
            .capacity = 0,
            .element_size = element_size,
        };
    }

    /// Get element at index as raw bytes.
    pub fn get_raw(self: *const RepeatedField, index: u32) ?[]u8 {
        if (index >= self.count) {
            return null;
        }
        const offset = index * self.element_size;
        return self.data.?[offset .. offset + self.element_size];
    }

    /// Get element at index as typed pointer.
    pub fn get(self: *const RepeatedField, comptime T: type, index: u32) ?*T {
        assert(@sizeOf(T) == self.element_size);
        const raw = self.get_raw(index) orelse return null;
        return @ptrCast(@alignCast(raw.ptr));
    }
};

/// Tagged union representing any protobuf field value.
pub const FieldValue = union(enum) {
    /// Boolean value.
    bool_val: bool,

    /// 32-bit signed integer (int32, sint32, sfixed32, enum).
    int32_val: i32,

    /// 64-bit signed integer (int64, sint64, sfixed64).
    int64_val: i64,

    /// 32-bit unsigned integer (uint32, fixed32).
    uint32_val: u32,

    /// 64-bit unsigned integer (uint64, fixed64).
    uint64_val: u64,

    /// Single-precision float.
    float_val: f32,

    /// Double-precision float.
    double_val: f64,

    /// String value (may be aliased).
    string_val: StringView,

    /// Bytes value (may be aliased).
    bytes_val: StringView,

    /// Nested message.
    message_val: *Message,

    /// Repeated field.
    repeated_val: *RepeatedField,

    /// No value (field not present).
    none,
};

/// A protobuf message instance.
///
/// Message data is stored as raw bytes with field offsets defined by the
/// MiniTable schema. Use get_field() and set_field() to access values.
pub const Message = struct {
    /// Raw message data. Layout defined by schema.
    data: []u8,

    /// Message schema (field definitions).
    table: *const MiniTable,

    /// Unknown fields (preserved for round-tripping).
    unknown_fields: ?[]const u8,

    /// Allocate and initialize a new message.
    pub fn new(arena: *Arena, table: *const MiniTable) ?*Message {
        // Allocate message struct.
        const msg = arena.create(Message) orelse return null;

        // Allocate message data.
        const data = arena.alloc(u8, table.size) orelse return null;

        // Zero-initialize all data.
        @memset(data, 0);

        msg.* = .{
            .data = data,
            .table = table,
            .unknown_fields = null,
        };

        return msg;
    }

    /// Get a scalar field value.
    pub fn get_scalar(self: *const Message, field: *const MiniTableField) FieldValue {
        assert(field.mode == .scalar);

        // Check presence for fields with hasbits.
        if (field.hasbit_index()) |hasbit_idx| {
            if (!self.has_hasbit(hasbit_idx)) {
                return .none;
            }
        }

        // Check oneof case.
        if (field.oneof_index()) |oneof_idx| {
            if (!self.has_oneof(oneof_idx, field.number)) {
                return .none;
            }
        }

        return self.read_value(field);
    }

    /// Set a scalar field value.
    pub fn set_scalar(self: *Message, field: *const MiniTableField, value: FieldValue) void {
        assert(field.mode == .scalar);

        // Set hasbit if present.
        if (field.hasbit_index()) |hasbit_idx| {
            self.set_hasbit(hasbit_idx);
        }

        // Set oneof case if present.
        if (field.oneof_index()) |oneof_idx| {
            self.set_oneof(oneof_idx, field.number);
        }

        self.write_value(field, value);
    }

    /// Clear a field (reset to default value).
    pub fn clear_field(self: *Message, field: *const MiniTableField) void {
        // Clear hasbit if present.
        if (field.hasbit_index()) |hasbit_idx| {
            self.clear_hasbit(hasbit_idx);
        }

        // Handle oneof: only clear if this field is the active one.
        if (field.oneof_index()) |oneof_idx| {
            if (!self.has_oneof(oneof_idx, field.number)) {
                return; // Different field is active, nothing to clear
            }
            // Clear the oneof case tag
            self.clear_oneof(oneof_idx);
        }

        // Zero the field data.
        const offset = field.offset;
        const size = self.field_size(field);
        @memset(self.data[offset .. offset + size], 0);
    }

    /// Get a repeated field.
    pub fn get_repeated(self: *Message, field: *const MiniTableField) *RepeatedField {
        assert(field.mode == .repeated or field.mode == .map);
        const ptr = self.field_ptr(field, RepeatedField);
        return ptr;
    }

    /// Check if a field is present.
    pub fn has_field(self: *const Message, field: *const MiniTableField) bool {
        if (field.hasbit_index()) |hasbit_idx| {
            return self.has_hasbit(hasbit_idx);
        }
        if (field.oneof_index()) |oneof_idx| {
            return self.has_oneof(oneof_idx, field.number);
        }
        // Proto3 scalars: check for non-zero value.
        if (field.mode == .scalar) {
            return !self.is_default_value(field);
        }
        // Repeated fields: check count.
        const repeated = self.get_repeated_const(field);
        return repeated.count > 0;
    }

    // Internal methods.

    fn read_value(self: *const Message, field: *const MiniTableField) FieldValue {
        return switch (field.field_type) {
            .TYPE_BOOL => .{ .bool_val = self.field_ptr_const(field, bool).* },
            .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_ENUM => .{
                .int32_val = self.field_ptr_const(field, i32).*,
            },
            .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => .{
                .int64_val = self.field_ptr_const(field, i64).*,
            },
            .TYPE_UINT32, .TYPE_FIXED32 => .{
                .uint32_val = self.field_ptr_const(field, u32).*,
            },
            .TYPE_UINT64, .TYPE_FIXED64 => .{
                .uint64_val = self.field_ptr_const(field, u64).*,
            },
            .TYPE_FLOAT => .{ .float_val = self.field_ptr_const(field, f32).* },
            .TYPE_DOUBLE => .{ .double_val = self.field_ptr_const(field, f64).* },
            .TYPE_STRING => .{ .string_val = self.field_ptr_const(field, StringView).* },
            .TYPE_BYTES => .{ .bytes_val = self.field_ptr_const(field, StringView).* },
            .TYPE_MESSAGE => blk: {
                const msg_ptr = self.field_ptr_const(field, ?*Message).*;
                if (msg_ptr) |msg| {
                    break :blk .{ .message_val = msg };
                }
                break :blk .none;
            },
            .TYPE_GROUP => .none, // Deprecated.
        };
    }

    fn write_value(self: *Message, field: *const MiniTableField, value: FieldValue) void {
        switch (field.field_type) {
            .TYPE_BOOL => self.field_ptr(field, bool).* = value.bool_val,
            .TYPE_INT32, .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_ENUM => {
                self.field_ptr(field, i32).* = value.int32_val;
            },
            .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => {
                self.field_ptr(field, i64).* = value.int64_val;
            },
            .TYPE_UINT32, .TYPE_FIXED32 => self.field_ptr(field, u32).* = value.uint32_val,
            .TYPE_UINT64, .TYPE_FIXED64 => self.field_ptr(field, u64).* = value.uint64_val,
            .TYPE_FLOAT => self.field_ptr(field, f32).* = value.float_val,
            .TYPE_DOUBLE => self.field_ptr(field, f64).* = value.double_val,
            .TYPE_STRING => self.field_ptr(field, StringView).* = value.string_val,
            .TYPE_BYTES => self.field_ptr(field, StringView).* = value.bytes_val,
            .TYPE_MESSAGE => self.field_ptr(field, ?*Message).* = value.message_val,
            .TYPE_GROUP => {}, // Deprecated.
        }
    }

    fn field_ptr(self: *Message, field: *const MiniTableField, comptime T: type) *T {
        const ptr = self.data.ptr + field.offset;
        return @ptrCast(@alignCast(ptr));
    }

    fn field_ptr_const(
        self: *const Message,
        field: *const MiniTableField,
        comptime T: type,
    ) *const T {
        const ptr = self.data.ptr + field.offset;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn get_repeated_const(self: *const Message, field: *const MiniTableField) *const RepeatedField {
        const ptr = self.data.ptr + field.offset;
        return @ptrCast(@alignCast(ptr));
    }

    fn field_size(self: *const Message, field: *const MiniTableField) u16 {
        _ = self;
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

    fn has_hasbit(self: *const Message, index: u16) bool {
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        return (self.data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    fn set_hasbit(self: *Message, index: u16) void {
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        self.data[byte_idx] |= @as(u8, 1) << bit_idx;
    }

    fn clear_hasbit(self: *Message, index: u16) void {
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        self.data[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }

    fn has_oneof(self: *const Message, oneof_idx: u16, field_number: u32) bool {
        // Oneof case is stored as u32 at the oneof offset.
        const case_offset = self.table.hasbit_bytes + oneof_idx * 4;
        const case_ptr: *const u32 = @ptrCast(@alignCast(self.data.ptr + case_offset));
        return case_ptr.* == field_number;
    }

    fn set_oneof(self: *Message, oneof_idx: u16, field_number: u32) void {
        const case_offset = self.table.hasbit_bytes + oneof_idx * 4;
        const case_ptr: *u32 = @ptrCast(@alignCast(self.data.ptr + case_offset));
        case_ptr.* = field_number;
    }

    fn clear_oneof(self: *Message, oneof_idx: u16) void {
        const case_offset = self.table.hasbit_bytes + oneof_idx * 4;
        const case_ptr: *u32 = @ptrCast(@alignCast(self.data.ptr + case_offset));
        case_ptr.* = 0;
    }

    /// Get the field number of the currently active field in a oneof.
    /// Returns 0 if no field is set.
    pub fn which_oneof(self: *const Message, oneof_idx: u16) u32 {
        const case_offset = self.table.hasbit_bytes + oneof_idx * 4;
        const case_ptr: *const u32 = @ptrCast(@alignCast(self.data.ptr + case_offset));
        return case_ptr.*;
    }

    fn is_default_value(self: *const Message, field: *const MiniTableField) bool {
        // For string/bytes, check if length is zero (pointer may be non-null for aliased empty strings).
        if (field.field_type == .TYPE_STRING or field.field_type == .TYPE_BYTES) {
            const sv = self.field_ptr_const(field, StringView);
            return sv.len == 0;
        }

        // For message fields, check if pointer is null.
        if (field.field_type == .TYPE_MESSAGE) {
            const msg_ptr = self.field_ptr_const(field, ?*Message);
            return msg_ptr.* == null;
        }

        // For numeric types, check if all bytes are zero.
        const size = self.field_size(field);
        const field_data = self.data[field.offset .. field.offset + size];
        for (field_data) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }
};

// Tests.

test "Message: basic allocation" {
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

    const msg = Message.new(&arena, &table);
    assert(msg != null);
    assert(msg.?.data.len == 8);
}

test "Message: scalar field access" {
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

    // Set field.
    msg.set_scalar(&fields[0], .{ .int32_val = 42 });

    // Get field.
    const value = msg.get_scalar(&fields[0]);
    assert(value.int32_val == 42);
}

test "StringView" {
    const sv = StringView.from_slice("hello");
    assert(sv.len == 5);
    assert(std.mem.eql(u8, sv.slice(), "hello"));
    assert(!sv.is_aliased);

    const aliased = StringView.from_aliased("world");
    assert(aliased.is_aliased);
}

test "Message: oneof field access" {
    // Oneof with two int32 fields at the same offset
    // Layout: [4 bytes oneof case tag] [4 bytes shared data]
    const fields = [_]MiniTableField{
        .{
            .number = 1,
            .offset = 4, // Shared data offset (after case tag)
            .presence = -1, // Oneof index 0: -1 - 0 = -1
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_INT32,
            .mode = .scalar,
            .is_packed = false,
                    },
        .{
            .number = 2,
            .offset = 4, // Same offset (shared storage)
            .presence = -1, // Same oneof index 0
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_INT32,
            .mode = .scalar,
            .is_packed = false,
                    },
    };

    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 8, // 4 bytes case tag + 4 bytes data
        .hasbit_bytes = 0,
        .oneof_count = 1,
        .dense_below = 2,
    };

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    // Initially no field is set
    assert(msg.which_oneof(0) == 0);
    assert(!msg.has_field(&fields[0]));
    assert(!msg.has_field(&fields[1]));

    // Set field 1
    msg.set_scalar(&fields[0], .{ .int32_val = 42 });
    assert(msg.which_oneof(0) == 1);
    assert(msg.has_field(&fields[0]));
    assert(!msg.has_field(&fields[1]));
    assert(msg.get_scalar(&fields[0]).int32_val == 42);
    assert(msg.get_scalar(&fields[1]) == .none);

    // Set field 2 - should replace field 1
    msg.set_scalar(&fields[1], .{ .int32_val = 123 });
    assert(msg.which_oneof(0) == 2);
    assert(!msg.has_field(&fields[0]));
    assert(msg.has_field(&fields[1]));
    assert(msg.get_scalar(&fields[0]) == .none);
    assert(msg.get_scalar(&fields[1]).int32_val == 123);

    // Clear field 2
    msg.clear_field(&fields[1]);
    assert(msg.which_oneof(0) == 0);
    assert(!msg.has_field(&fields[0]));
    assert(!msg.has_field(&fields[1]));

    // Clearing non-active field should be a no-op
    msg.set_scalar(&fields[0], .{ .int32_val = 999 });
    msg.clear_field(&fields[1]); // field 1 is active, not field 2
    assert(msg.which_oneof(0) == 1); // Still set to field 1
    assert(msg.get_scalar(&fields[0]).int32_val == 999);
}

test "Message: oneof with different types" {
    // Oneof with int32 and string (string is larger)
    // Layout: [4 bytes oneof case tag] [13 bytes shared data (StringView)]
    const fields = [_]MiniTableField{
        .{
            .number = 1,
            .offset = 8, // Shared data offset (aligned to 8 for StringView)
            .presence = -1, // Oneof index 0
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_INT32,
            .mode = .scalar,
            .is_packed = false,
                    },
        .{
            .number = 2,
            .offset = 8, // Same offset (shared storage)
            .presence = -1, // Same oneof index 0
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_STRING,
            .mode = .scalar,
            .is_packed = false,
                    },
    };

    const table = MiniTable{
        .fields = &fields,
        .submessages = &.{},
        .size = 24, // 4 bytes case tag + padding + 13 bytes StringView
        .hasbit_bytes = 0,
        .oneof_count = 1,
        .dense_below = 2,
    };

    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const msg = Message.new(&arena, &table).?;

    // Set string field
    msg.set_scalar(&fields[1], .{ .string_val = StringView.from_slice("hello") });
    assert(msg.which_oneof(0) == 2);
    assert(msg.has_field(&fields[1]));
    assert(!msg.has_field(&fields[0]));
    assert(std.mem.eql(u8, msg.get_scalar(&fields[1]).string_val.slice(), "hello"));

    // Switch to int32 field
    msg.set_scalar(&fields[0], .{ .int32_val = 42 });
    assert(msg.which_oneof(0) == 1);
    assert(msg.has_field(&fields[0]));
    assert(!msg.has_field(&fields[1]));
    assert(msg.get_scalar(&fields[0]).int32_val == 42);
}
