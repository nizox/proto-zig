//! Compact schema representation for protobuf messages.
//!
//! MiniTable provides a compact binary representation of message schemas,
//! similar to upb's MiniTable. It describes the layout of fields within
//! a message and how to decode/encode them.

const std = @import("std");
const assert = std.debug.assert;
const wire = @import("wire/wire.zig");
const WireType = wire.WireType;

/// Protobuf field types from the descriptor.
pub const FieldType = enum(u8) {
    TYPE_DOUBLE = 1,
    TYPE_FLOAT = 2,
    TYPE_INT64 = 3,
    TYPE_UINT64 = 4,
    TYPE_INT32 = 5,
    TYPE_FIXED64 = 6,
    TYPE_FIXED32 = 7,
    TYPE_BOOL = 8,
    TYPE_STRING = 9,
    TYPE_GROUP = 10, // Deprecated.
    TYPE_MESSAGE = 11,
    TYPE_BYTES = 12,
    TYPE_UINT32 = 13,
    TYPE_ENUM = 14,
    TYPE_SFIXED32 = 15,
    TYPE_SFIXED64 = 16,
    TYPE_SINT32 = 17,
    TYPE_SINT64 = 18,

    /// Returns the wire type for this field type.
    pub fn wire_type(self: FieldType) WireType {
        return switch (self) {
            .TYPE_DOUBLE => .fixed64,
            .TYPE_FLOAT => .fixed32,
            .TYPE_INT64, .TYPE_UINT64, .TYPE_INT32, .TYPE_BOOL => .varint,
            .TYPE_UINT32, .TYPE_ENUM, .TYPE_SINT32, .TYPE_SINT64 => .varint,
            .TYPE_FIXED64, .TYPE_SFIXED64 => .fixed64,
            .TYPE_FIXED32, .TYPE_SFIXED32 => .fixed32,
            .TYPE_STRING, .TYPE_BYTES, .TYPE_MESSAGE => .delimited,
            .TYPE_GROUP => .start_group, // Deprecated.
        };
    }

    /// Returns the size in bytes for fixed-size types, 0 for variable-size.
    pub fn fixed_size(self: FieldType) u8 {
        return switch (self) {
            .TYPE_DOUBLE, .TYPE_FIXED64, .TYPE_SFIXED64 => 8,
            .TYPE_FLOAT, .TYPE_FIXED32, .TYPE_SFIXED32 => 4,
            .TYPE_BOOL => 1,
            else => 0,
        };
    }

    /// Returns true if this is a scalar (non-message, non-repeated) type.
    pub fn is_scalar(self: FieldType) bool {
        return self != .TYPE_MESSAGE and self != .TYPE_GROUP;
    }

    /// Returns true if this type can be packed (repeated primitive fields).
    pub fn is_packable(self: FieldType) bool {
        return switch (self) {
            .TYPE_STRING, .TYPE_BYTES, .TYPE_MESSAGE, .TYPE_GROUP => false,
            else => true,
        };
    }
};

/// Field cardinality mode.
pub const Mode = enum(u2) {
    /// Singular field (optional or implicit presence).
    scalar = 0,

    /// Repeated field (array).
    repeated = 1,

    /// Map field (key-value pairs).
    map = 2,
};

/// Descriptor for a single field within a message.
///
/// This is a compact representation (16 bytes) that contains all information
/// needed to decode/encode a field.
pub const MiniTableField = struct {
    /// Protobuf field number (1-536870911).
    number: u32,

    /// Byte offset of this field within the message data.
    offset: u16,

    /// Presence information:
    /// - > 0: hasbit index (1-based)
    /// - < 0: ~oneof_index (negated, 0-based)
    /// - = 0: no presence tracking (proto3 scalar)
    presence: i16,

    /// Index into submessages array for message/group fields.
    /// Set to max_submsg_index if not a message field.
    submsg_index: u16,

    /// The protobuf field type.
    field_type: FieldType,

    /// Field cardinality (scalar, repeated, map).
    mode: Mode,

    /// Whether repeated field uses packed encoding.
    is_packed: bool,

    /// Indicates whether the field is part of a oneof.
    is_oneof: bool = false,

    /// Maximum submessage index value (indicates not a message field).
    pub const max_submsg_index: u16 = std.math.maxInt(u16);

    /// Returns true if this field has explicit presence tracking.
    pub fn has_presence(self: *const MiniTableField) bool {
        // Proto3 scalars have implicit presence (no hasbit).
        // Proto2 fields and oneof fields have explicit presence.
        return self.presence != 0 or self.is_oneof;
    }

    /// Returns the hasbit index if this field uses hasbits.
    pub fn hasbit_index(self: *const MiniTableField) ?u16 {
        if (self.presence > 0) {
            return @intCast(self.presence - 1);
        }
        return null;
    }

    /// Returns the oneof index if this field is part of a oneof.
    pub fn oneof_index(self: *const MiniTableField) ?u16 {
        if (self.presence < 0) {
            return @intCast(~self.presence);
        }
        return null;
    }

    /// Returns true if this is a message or group field.
    pub fn is_submessage(self: *const MiniTableField) bool {
        return self.field_type == .TYPE_MESSAGE or self.field_type == .TYPE_GROUP;
    }

    /// Returns the expected wire type for this field.
    pub fn wire_type(self: *const MiniTableField) WireType {
        // Packed repeated fields are always delimited.
        if (self.is_packed and self.mode == .repeated) {
            return .delimited;
        }
        return self.field_type.wire_type();
    }
};

/// Descriptor for a protobuf message type.
///
/// Contains field definitions and submessage references needed to
/// decode/encode messages of this type.
pub const MiniTable = struct {
    /// Array of field descriptors, sorted by field number.
    fields: []const MiniTableField,

    /// Array of submessage tables (for message/group fields).
    submessages: []const *const MiniTable,

    /// Total size of the message data in bytes.
    size: u16,

    /// Number of bytes used for hasbits (presence tracking).
    hasbit_bytes: u8,

    /// Number of oneof groups in this message.
    oneof_count: u8,

    /// Field number threshold for dense lookup.
    /// Fields 1..dense_below are stored sequentially in the fields array.
    dense_below: u8,

    /// Look up a field by its field number.
    ///
    /// Returns null if no field with this number exists.
    pub fn field_by_number(self: *const MiniTable, number: u32) ?*const MiniTableField {
        assert(number > 0);

        // Fast path: dense lookup for low field numbers.
        if (number <= self.dense_below and number <= self.fields.len) {
            const idx = number - 1;
            if (self.fields[idx].number == number) {
                return &self.fields[idx];
            }
        }

        // Slow path: binary search.
        return self.binary_search(number);
    }

    fn binary_search(self: *const MiniTable, number: u32) ?*const MiniTableField {
        var left: u32 = 0;
        var right: u32 = @intCast(self.fields.len);

        while (left < right) {
            const mid = left + (right - left) / 2;
            const field = &self.fields[mid];

            if (field.number == number) {
                return field;
            } else if (field.number < number) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        return null;
    }

    /// Iterate over all fields in the message.
    pub fn field_iter(self: *const MiniTable) FieldIterator {
        return .{ .table = self, .index = 0 };
    }

    pub const FieldIterator = struct {
        table: *const MiniTable,
        index: u32,

        pub fn next(self: *FieldIterator) ?*const MiniTableField {
            if (self.index >= self.table.fields.len) {
                return null;
            }
            const field = &self.table.fields[self.index];
            self.index += 1;
            return field;
        }
    };
};

// Tests.

test "FieldType: wire types" {
    assert(FieldType.TYPE_INT32.wire_type() == .varint);
    assert(FieldType.TYPE_INT64.wire_type() == .varint);
    assert(FieldType.TYPE_BOOL.wire_type() == .varint);
    assert(FieldType.TYPE_DOUBLE.wire_type() == .fixed64);
    assert(FieldType.TYPE_FLOAT.wire_type() == .fixed32);
    assert(FieldType.TYPE_STRING.wire_type() == .delimited);
    assert(FieldType.TYPE_MESSAGE.wire_type() == .delimited);
}

test "MiniTableField: presence" {
    // Proto3 scalar: no presence.
    const proto3_field = MiniTableField{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    };
    assert(!proto3_field.has_presence());
    assert(proto3_field.hasbit_index() == null);
    assert(proto3_field.oneof_index() == null);

    // Field with hasbit.
    const hasbit_field = MiniTableField{
        .number = 2,
        .offset = 4,
        .presence = 1, // hasbit index 0.
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    };
    assert(hasbit_field.has_presence());
    assert(hasbit_field.hasbit_index() == 0);

    // Oneof field.
    const oneof_field = MiniTableField{
        .number = 3,
        .offset = 8,
        .presence = -1, // oneof index 0.
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = true,
    };
    assert(oneof_field.has_presence());
    assert(oneof_field.oneof_index() == 0);
}

test "MiniTable: field lookup" {
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
        .{
            .number = 2,
            .offset = 4,
            .presence = 0,
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_STRING,
            .mode = .scalar,
            .is_packed = false,
        },
        .{
            .number = 100,
            .offset = 12,
            .presence = 0,
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_BOOL,
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

    // Dense lookup.
    const f1 = table.field_by_number(1);
    assert(f1 != null);
    assert(f1.?.number == 1);

    const f2 = table.field_by_number(2);
    assert(f2 != null);
    assert(f2.?.number == 2);

    // Binary search.
    const f100 = table.field_by_number(100);
    assert(f100 != null);
    assert(f100.?.number == 100);

    // Not found.
    assert(table.field_by_number(3) == null);
    assert(table.field_by_number(99) == null);
}
