///! Field layout calculation for protobuf messages.
///!
///! Computes field offsets, message size, and oneof allocation.
///! Memory layout: [oneof_tags] [oneof_data] [fields_sorted_by_size]
///!
///! Note: Proto3 does not use hasbits (implicit presence). Hasbits are only
///! needed for proto2 or proto3 explicit optional fields, which are not
///! currently supported by the codegen. The hasbit_bytes field in MiniTable
///! is always 0 for generated code but kept for compatibility with hand-coded
///! bootstrap schemas.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const FieldType = proto.FieldType;
const Mode = proto.FieldMode;
const descriptor_parser = @import("descriptor_parser.zig");

const MessageInfo = descriptor_parser.MessageInfo;
const FieldInfo = descriptor_parser.FieldInfo;
const FieldLabel = descriptor_parser.FieldLabel;
const FieldLayout = descriptor_parser.FieldLayout;
const LayoutInfo = descriptor_parser.LayoutInfo;

/// Compute memory layout for a message.
pub fn computeLayout(msg: *MessageInfo, allocator: Allocator) !void {
    // Proto3: no hasbits needed (implicit presence)
    const hasbit_bytes: u16 = 0;

    // Layout structure: [oneof_tags] [oneof_data] [regular_fields]
    var offset: u16 = 0;

    // Align for oneof tags (u32 = 4 bytes)
    if (msg.oneofs.len > 0) {
        offset = std.mem.alignForward(u16, offset, 4);
    }
    const oneof_bytes: u16 = @intCast(msg.oneofs.len * @sizeOf(u32));
    offset += oneof_bytes;

    // Compute oneof shared storage: one slot per oneof sized to fit largest field
    var oneof_offsets: std.ArrayList(u16) = .empty;
    defer oneof_offsets.deinit(allocator);

    for (0..msg.oneofs.len) |oneof_idx| {
        // Find max size and alignment for this oneof
        var max_size: u16 = 0;
        var max_align: u16 = 1;

        for (msg.fields) |field| {
            if (field.oneof_index) |idx| {
                if (idx == oneof_idx) {
                    const size = fieldSize(field.type, field.label);
                    const align_val = fieldAlignment(field.type, field.label);
                    if (size > max_size) max_size = size;
                    if (align_val > max_align) max_align = align_val;
                }
            }
        }

        // Allocate shared storage for this oneof
        offset = std.mem.alignForward(u16, offset, max_align);
        try oneof_offsets.append(allocator, offset);
        offset += max_size;
    }

    // Sort non-oneof fields by size (largest first for optimal packing)
    // Note: A field is "regular" if it has no oneof_index OR if its oneof_index is invalid
    // (protoc sends oneof_index=0 for all fields, even those not in oneofs)
    var regular_fields: std.ArrayList(FieldInfo) = .empty;
    defer regular_fields.deinit(allocator);

    for (msg.fields) |field| {
        const is_valid_oneof = if (field.oneof_index) |idx| idx < msg.oneofs.len else false;
        if (!is_valid_oneof) {
            try regular_fields.append(allocator, field);
        }
    }

    std.mem.sort(FieldInfo, regular_fields.items, {}, compareBySizeDesc);

    // Allocate regular (non-oneof) fields
    var layouts: std.ArrayList(FieldLayout) = .empty;
    errdefer layouts.deinit(allocator);

    for (regular_fields.items) |field| {
        const size = fieldSize(field.type, field.label);
        const align_val = fieldAlignment(field.type, field.label);

        // Align offset
        offset = std.mem.alignForward(u16, offset, align_val);

        try layouts.append(allocator, .{
            .number = field.number,
            .offset = offset,
            .presence = 0, // Proto3: implicit presence
            .submsg_index = 0xFFFF, // Set later in linker
            .field_type = field.type,
            .mode = fieldMode(field),
            .is_packed = field.is_packed and field.label == .repeated,
        });

        offset += size;
    }

    // Add oneof fields with shared offsets
    for (msg.fields) |field| {
        if (field.oneof_index) |oneof_idx| {
            // Validate: oneof_idx must be valid (protoc sends oneof_index=0 for all fields,
            // even those not in oneofs, so we must check against actual oneof count)
            if (oneof_idx >= msg.oneofs.len) {
                // Not a valid oneof - treat as regular field (already added above)
                continue;
            }
            try layouts.append(allocator, .{
                .number = field.number,
                .offset = oneof_offsets.items[oneof_idx], // All fields in oneof share this offset
                .presence = computeOneofPresence(oneof_idx), // Negative encoding for oneof
                .submsg_index = 0xFFFF, // Set later in linker
                .field_type = field.type,
                .mode = fieldMode(field),
                .is_packed = field.is_packed and field.label == .repeated,
            });
        }
    }

    // Re-sort by field number for MiniTable
    std.mem.sort(FieldLayout, layouts.items, {}, compareByNumber);

    // Compute dense_below (largest N where fields 1..N all exist)
    const dense_below = computeDenseBelow(layouts.items);

    // Store layout in message
    msg.layout = LayoutInfo{
        .size = offset,
        .hasbit_bytes = hasbit_bytes,
        .oneof_count = @intCast(msg.oneofs.len),
        .dense_below = dense_below,
        .fields = try layouts.toOwnedSlice(allocator),
    };
}

/// Compute layout recursively for a message and all its nested messages.
pub fn computeLayoutRecursive(msg: *MessageInfo, allocator: Allocator) !void {
    // First, compute layout for all nested messages (depth-first)
    for (msg.nested_messages) |*nested| {
        try computeLayoutRecursive(nested, allocator);
    }

    // Then compute layout for this message
    try computeLayout(msg, allocator);
}

/// Compute size in bytes for a field.
fn fieldSize(ftype: FieldType, label: FieldLabel) u16 {
    // Repeated fields are stored inline as RepeatedField struct
    // RepeatedField: data(?[*]u8=8) + count(u32=4) + capacity(u32=4) + element_size(u16=2) = 18 bytes
    // With 8-byte alignment: 24 bytes
    if (label == .repeated) {
        return 24; // @sizeOf(proto.RepeatedField)
    }

    return switch (ftype) {
        .TYPE_BOOL => 1,
        .TYPE_INT32, .TYPE_UINT32, .TYPE_SINT32, .TYPE_ENUM => 4,
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => 4,
        .TYPE_INT64, .TYPE_UINT64, .TYPE_SINT64 => 8,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => 8,
        .TYPE_STRING, .TYPE_BYTES => 13, // StringView: ptr(8) + len(4) + is_aliased(1)
        .TYPE_MESSAGE => @sizeOf(?*anyopaque), // ?*Message
        .TYPE_GROUP => @sizeOf(?*anyopaque), // Deprecated, treat as message
    };
}

/// Compute alignment requirement for a field.
fn fieldAlignment(ftype: FieldType, label: FieldLabel) u16 {
    // Repeated fields are pointers
    if (label == .repeated) {
        return @alignOf(?*anyopaque);
    }

    return switch (ftype) {
        .TYPE_BOOL => 1,
        .TYPE_INT32, .TYPE_UINT32, .TYPE_SINT32, .TYPE_ENUM => 4,
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => 4,
        .TYPE_INT64, .TYPE_UINT64, .TYPE_SINT64 => 8,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => 8,
        .TYPE_STRING, .TYPE_BYTES => @alignOf([*]const u8), // StringView alignment
        .TYPE_MESSAGE => @alignOf(?*anyopaque),
        .TYPE_GROUP => @alignOf(?*anyopaque),
    };
}

/// Compute presence encoding for a oneof field.
/// Returns negative value: -1 - oneof_index
fn computeOneofPresence(oneof_idx: usize) i16 {
    return -1 - @as(i16, @intCast(oneof_idx));
}

/// Compute field mode (scalar, repeated, map).
fn fieldMode(field: FieldInfo) Mode {
    if (field.is_map_entry) {
        return .map;
    } else if (field.label == .repeated) {
        return .repeated;
    } else {
        return .scalar;
    }
}

/// Compare fields by size (descending) for optimal packing.
fn compareBySizeDesc(_: void, a: FieldInfo, b: FieldInfo) bool {
    const size_a = fieldSize(a.type, a.label);
    const size_b = fieldSize(b.type, b.label);

    // Sort by size descending (largest first)
    if (size_a != size_b) {
        return size_a > size_b;
    }

    // Tie-break by field number (ascending) for stability
    return a.number < b.number;
}

/// Compare field layouts by field number (ascending).
fn compareByNumber(_: void, a: FieldLayout, b: FieldLayout) bool {
    return a.number < b.number;
}

/// Compute dense_below: largest N where fields 1..N all exist.
fn computeDenseBelow(fields: []const FieldLayout) u8 {
    if (fields.len == 0) return 0;

    var dense: u32 = 0;
    for (fields) |field| {
        if (field.number == dense + 1) {
            dense += 1;
        } else {
            break;
        }
    }

    // Cap at u8 max
    return if (dense > 255) 255 else @intCast(dense);
}

// Tests

const testing = std.testing;

test "fieldSize - scalars" {
    try testing.expectEqual(@as(u16, 1), fieldSize(.TYPE_BOOL, .optional));
    try testing.expectEqual(@as(u16, 4), fieldSize(.TYPE_INT32, .optional));
    try testing.expectEqual(@as(u16, 4), fieldSize(.TYPE_UINT32, .optional));
    try testing.expectEqual(@as(u16, 4), fieldSize(.TYPE_ENUM, .optional));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_INT64, .optional));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_UINT64, .optional));
    try testing.expectEqual(@as(u16, 4), fieldSize(.TYPE_FLOAT, .optional));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_DOUBLE, .optional));
}

test "fieldSize - strings and messages" {
    try testing.expectEqual(@as(u16, 13), fieldSize(.TYPE_STRING, .optional));
    try testing.expectEqual(@as(u16, 13), fieldSize(.TYPE_BYTES, .optional));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_MESSAGE, .optional));
}

test "fieldSize - repeated" {
    // RepeatedField is stored inline, not as a pointer
    try testing.expectEqual(@as(u16, 24), fieldSize(.TYPE_INT32, .repeated));
    try testing.expectEqual(@as(u16, 24), fieldSize(.TYPE_STRING, .repeated));
    try testing.expectEqual(@as(u16, 24), fieldSize(.TYPE_MESSAGE, .repeated));
}

test "computeOneofPresence" {
    try testing.expectEqual(@as(i16, -1), computeOneofPresence(0)); // -1 - 0 = -1
    try testing.expectEqual(@as(i16, -2), computeOneofPresence(1)); // -1 - 1 = -2
    try testing.expectEqual(@as(i16, -3), computeOneofPresence(2)); // -1 - 2 = -3
}

test "computeDenseBelow" {
    // Empty
    try testing.expectEqual(@as(u8, 0), computeDenseBelow(&.{}));

    // Dense: 1, 2, 3
    {
        const layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 2, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 3), computeDenseBelow(&layouts));
    }

    // Sparse: 1, 3, 5
    {
        const layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 5, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 1), computeDenseBelow(&layouts));
    }

    // Dense then sparse: 1, 2, 3, 100
    {
        const layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 2, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 100, .offset = 12, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 3), computeDenseBelow(&layouts));
    }
}

test "compareBySizeDesc" {
    const field_i64 = FieldInfo{
        .name = "i64_field",
        .number = 1,
        .label = .optional,
        .type = .TYPE_INT64,
        .type_name = "",
    };

    const field_i32 = FieldInfo{
        .name = "i32_field",
        .number = 2,
        .label = .optional,
        .type = .TYPE_INT32,
        .type_name = "",
    };

    const field_bool = FieldInfo{
        .name = "bool_field",
        .number = 3,
        .label = .optional,
        .type = .TYPE_BOOL,
        .type_name = "",
    };

    // i64 (8 bytes) should come before i32 (4 bytes)
    try testing.expect(compareBySizeDesc({}, field_i64, field_i32));
    try testing.expect(!compareBySizeDesc({}, field_i32, field_i64));

    // i32 (4 bytes) should come before bool (1 byte)
    try testing.expect(compareBySizeDesc({}, field_i32, field_bool));
    try testing.expect(!compareBySizeDesc({}, field_bool, field_i32));
}

test "computeLayout - simple message" {
    const allocator = testing.allocator;

    // Create a simple message with 3 fields
    var fields = [_]FieldInfo{
        .{
            .name = "id",
            .number = 1,
            .label = .optional,
            .type = .TYPE_INT32,
            .type_name = "",
        },
        .{
            .name = "name",
            .number = 2,
            .label = .optional,
            .type = .TYPE_STRING,
            .type_name = "",
        },
        .{
            .name = "active",
            .number = 3,
            .label = .optional,
            .type = .TYPE_BOOL,
            .type_name = "",
        },
    };

    var msg = MessageInfo{
        .name = "TestMessage",
        .full_name = ".test.TestMessage",
        .fields = fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    try computeLayout(&msg, allocator);
    defer allocator.free(msg.layout.?.fields);

    const layout = msg.layout.?;

    // Check hasbit_bytes: Proto3 has no hasbits
    try testing.expectEqual(@as(u16, 0), layout.hasbit_bytes);

    // Check oneof_count
    try testing.expectEqual(@as(u8, 0), layout.oneof_count);

    // Check dense_below: fields 1, 2, 3 are all present
    try testing.expectEqual(@as(u8, 3), layout.dense_below);

    // Check fields are sorted by number
    try testing.expectEqual(@as(u32, 1), layout.fields[0].number);
    try testing.expectEqual(@as(u32, 2), layout.fields[1].number);
    try testing.expectEqual(@as(u32, 3), layout.fields[2].number);

    // Check presence values (proto3: all 0 for implicit presence)
    try testing.expectEqual(@as(i16, 0), layout.fields[0].presence); // id
    try testing.expectEqual(@as(i16, 0), layout.fields[1].presence); // name
    try testing.expectEqual(@as(i16, 0), layout.fields[2].presence); // active

    // name (field 2) should be at offset 0 (8-byte aligned, no hasbits or oneofs)
    const name_field = blk: {
        for (layout.fields) |f| {
            if (f.number == 2) break :blk f;
        }
        unreachable;
    };
    try testing.expectEqual(@as(u16, 0), name_field.offset);
}

test "computeLayout - message with oneof" {
    const allocator = testing.allocator;

    // Create a message with a oneof containing two fields
    var oneofs = [_]descriptor_parser.OneofInfo{
        .{ .name = "test_oneof" },
    };

    var fields = [_]FieldInfo{
        .{
            .name = "int_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_INT32,
            .type_name = "",
            .oneof_index = 0, // Part of oneof 0
        },
        .{
            .name = "string_field",
            .number = 2,
            .label = .optional,
            .type = .TYPE_STRING,
            .type_name = "",
            .oneof_index = 0, // Part of oneof 0
        },
        .{
            .name = "regular_field",
            .number = 3,
            .label = .optional,
            .type = .TYPE_INT32,
            .type_name = "",
        },
    };

    var msg = MessageInfo{
        .name = "TestOneofMessage",
        .full_name = ".test.TestOneofMessage",
        .fields = fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = oneofs[0..],
    };

    try computeLayout(&msg, allocator);
    defer allocator.free(msg.layout.?.fields);

    const layout = msg.layout.?;

    // Check hasbit_bytes: 0 for proto3
    try testing.expectEqual(@as(u16, 0), layout.hasbit_bytes);

    // Check oneof_count
    try testing.expectEqual(@as(u8, 1), layout.oneof_count);

    // Find the oneof fields
    var int_field: ?FieldLayout = null;
    var string_field: ?FieldLayout = null;
    var regular_field: ?FieldLayout = null;

    for (layout.fields) |f| {
        if (f.number == 1) int_field = f;
        if (f.number == 2) string_field = f;
        if (f.number == 3) regular_field = f;
    }

    // Both oneof fields should have the same offset (shared storage)
    try testing.expectEqual(int_field.?.offset, string_field.?.offset);

    // Both oneof fields should have negative presence (oneof index encoding)
    try testing.expectEqual(@as(i16, -1), int_field.?.presence); // -1 - 0 = -1
    try testing.expectEqual(@as(i16, -1), string_field.?.presence); // -1 - 0 = -1

    // Regular field should have presence = 0 (proto3 implicit)
    try testing.expectEqual(@as(i16, 0), regular_field.?.presence);

    // is_oneof() should derive correctly from presence
    try testing.expect(int_field.?.is_oneof());
    try testing.expect(string_field.?.is_oneof());
    try testing.expect(!regular_field.?.is_oneof());
}
