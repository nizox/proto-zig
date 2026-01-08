//! Protobuf wire format types.
//!
//! The wire format uses a tag-length-value encoding where each field is
//! prefixed by a tag containing the field number and wire type.

const std = @import("std");
const assert = std.debug.assert;

/// Wire types define how field data is encoded on the wire.
pub const WireType = enum(u3) {
    /// Variable-length integer (int32, int64, uint32, uint64, sint32, sint64,
    /// bool, enum). Uses 1-10 bytes.
    varint = 0,

    /// Fixed 64-bit value (fixed64, sfixed64, double). Always 8 bytes.
    fixed64 = 1,

    /// Length-delimited (string, bytes, embedded messages, packed repeated).
    /// Prefixed by varint length.
    delimited = 2,

    /// Start group (deprecated). Do not use.
    start_group = 3,

    /// End group (deprecated). Do not use.
    end_group = 4,

    /// Fixed 32-bit value (fixed32, sfixed32, float). Always 4 bytes.
    fixed32 = 5,

    // Wire types 6 and 7 are reserved/invalid.
    _,
};

/// A protobuf field tag containing field number and wire type.
///
/// Tag = (field_number << 3) | wire_type
pub const Tag = struct {
    field_number: u29,
    wire_type: WireType,

    /// Maximum valid field number per protobuf spec.
    pub const max_field_number: u29 = (1 << 29) - 1;

    /// Reserved field number range start (19000).
    pub const reserved_range_start: u29 = 19000;

    /// Reserved field number range end (19999).
    pub const reserved_range_end: u29 = 19999;

    /// Decode a tag from a raw u32 value.
    pub fn from_raw(raw: u32) Tag {
        return Tag{
            .field_number = @intCast(raw >> 3),
            .wire_type = @enumFromInt(@as(u3, @truncate(raw))),
        };
    }

    /// Encode tag to raw u32 value.
    pub fn to_raw(self: Tag) u32 {
        return (@as(u32, self.field_number) << 3) | @intFromEnum(self.wire_type);
    }

    /// Check if the tag is valid.
    pub fn is_valid(self: Tag) bool {
        // Field number must be >= 1.
        if (self.field_number == 0) {
            return false;
        }

        // Wire type must be known.
        const wt = @intFromEnum(self.wire_type);
        if (wt > 5) {
            return false;
        }

        return true;
    }

    /// Check if field number is in reserved range.
    pub fn is_reserved(self: Tag) bool {
        return self.field_number >= reserved_range_start and
            self.field_number <= reserved_range_end;
    }
};

test "Tag: encoding and decoding" {
    // Field 1, varint.
    const tag1 = Tag{ .field_number = 1, .wire_type = .varint };
    assert(tag1.to_raw() == 0x08);
    assert(Tag.from_raw(0x08).field_number == 1);
    assert(Tag.from_raw(0x08).wire_type == .varint);

    // Field 2, delimited.
    const tag2 = Tag{ .field_number = 2, .wire_type = .delimited };
    assert(tag2.to_raw() == 0x12);

    // Field 150, varint (example from protobuf docs).
    const tag150 = Tag{ .field_number = 150, .wire_type = .varint };
    assert(tag150.to_raw() == 0x04b0);
}

test "Tag: validity" {
    // Valid tags.
    assert((Tag{ .field_number = 1, .wire_type = .varint }).is_valid());
    assert((Tag{ .field_number = 536870911, .wire_type = .fixed64 }).is_valid());

    // Invalid: field number 0.
    assert(!(Tag{ .field_number = 0, .wire_type = .varint }).is_valid());

    // Invalid: unknown wire type.
    assert(!(Tag{ .field_number = 1, .wire_type = @enumFromInt(6) }).is_valid());
    assert(!(Tag{ .field_number = 1, .wire_type = @enumFromInt(7) }).is_valid());
}

test "Tag: reserved range" {
    assert((Tag{ .field_number = 19000, .wire_type = .varint }).is_reserved());
    assert((Tag{ .field_number = 19999, .wire_type = .varint }).is_reserved());
    assert(!(Tag{ .field_number = 18999, .wire_type = .varint }).is_reserved());
    assert(!(Tag{ .field_number = 20000, .wire_type = .varint }).is_reserved());
}
