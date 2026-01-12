///! Field layout calculation for protobuf messages.
///!
///! Computes field offsets, message size, and hasbit allocation.
///! Memory layout: [hasbits] [oneof_tags] [fields_sorted_by_size]

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
    // 1. Count hasbits (proto3: only explicit optional fields)
    var hasbit_count: u16 = 0;
    for (msg.fields) |field| {
        if (needsHasbit(field)) hasbit_count += 1;
    }
    const hasbit_bytes = (hasbit_count + 7) / 8;

    // 2. Layout structure: [hasbits] [oneof_tags] [fields]
    var offset: u16 = hasbit_bytes;

    // Align for oneof tags (u32 = 4 bytes)
    offset = std.mem.alignForward(u16, offset, 4);
    const oneof_bytes: u16 = @intCast(msg.oneofs.len * @sizeOf(u32));
    offset += oneof_bytes;

    // 3. Pre-allocate hasbit indices in field order (before sorting)
    var hasbit_map = std.AutoHashMap(u32, i16).init(allocator);
    defer hasbit_map.deinit();

    var hasbit_idx: u16 = 0;
    for (msg.fields) |field| {
        const presence = computePresence(field, &hasbit_idx);
        try hasbit_map.put(field.number, presence);
    }

    // 4. Sort fields by size (largest first for optimal packing)
    const sorted_fields = try allocator.dupe(FieldInfo, msg.fields);
    defer allocator.free(sorted_fields);

    std.mem.sort(FieldInfo, sorted_fields, {}, compareBySizeDesc);

    // 5. Allocate each field with alignment
    var layouts: std.ArrayList(FieldLayout) = .empty;
    errdefer layouts.deinit(allocator);

    for (sorted_fields) |field| {
        const size = fieldSize(field.type, field.label);
        const align_val = fieldAlignment(field.type, field.label);

        // Align offset
        offset = std.mem.alignForward(u16, offset, align_val);

        // Get pre-computed presence
        const presence = hasbit_map.get(field.number) orelse 0;

        // Compute mode
        const mode = fieldMode(field);

        try layouts.append(allocator, .{
            .number = field.number,
            .offset = offset,
            .presence = presence,
            .submsg_index = 0xFFFF, // Set later in linker
            .field_type = field.type,
            .mode = mode,
            .is_packed = field.is_packed and field.label == .repeated,
        });

        offset += size;
    }

    // 6. Re-sort by field number for MiniTable
    std.mem.sort(FieldLayout, layouts.items, {}, compareByNumber);

    // 7. Compute dense_below (largest N where fields 1..N all exist)
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
    // Repeated fields are pointers to RepeatedField
    if (label == .repeated) {
        return @sizeOf(?*anyopaque); // ?*RepeatedField
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

/// Check if a field needs a hasbit for presence tracking.
fn needsHasbit(field: FieldInfo) bool {
    // Repeated fields don't need hasbits
    if (field.label == .repeated) return false;

    // Oneof fields use oneof case tag, not hasbits
    if (field.oneof_index != null) return false;

    // Proto3: only explicit optional fields get hasbits
    // Proto2: all optional (non-required, non-repeated) fields get hasbits
    // For simplicity, we treat proto2 optional as needing hasbits
    // (This could be refined by checking file syntax field)
    if (field.label == .optional) return true;

    // Required fields in proto2 don't need hasbits (always present)
    return false;
}

/// Compute presence encoding for a field.
fn computePresence(field: FieldInfo, hasbit_idx: *u16) i16 {
    if (field.oneof_index) |idx| {
        // Oneof: presence = -1 - oneof_index
        return -1 - @as(i16, @intCast(idx));
    } else if (needsHasbit(field)) {
        // Hasbit: presence = hasbit_index + 1
        const result: i16 = @intCast(hasbit_idx.* + 1);
        hasbit_idx.* += 1;
        return result;
    } else {
        // No presence tracking (repeated, required, or proto3 implicit)
        return 0;
    }
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

/// Check if a field is a map entry (detected via naming convention or options).
fn isMapEntry(_: FieldInfo) bool {
    // TODO: Check if parent message is marked as map_entry
    // For now, assume false
    return false;
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
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_INT32, .repeated));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_STRING, .repeated));
    try testing.expectEqual(@as(u16, 8), fieldSize(.TYPE_MESSAGE, .repeated));
}

test "needsHasbit" {
    // Optional field needs hasbit
    try testing.expect(needsHasbit(.{
        .name = "field",
        .number = 1,
        .label = .optional,
        .type = .TYPE_INT32,
        .type_name = "",
    }));

    // Repeated field doesn't need hasbit
    try testing.expect(!needsHasbit(.{
        .name = "field",
        .number = 1,
        .label = .repeated,
        .type = .TYPE_INT32,
        .type_name = "",
    }));

    // Oneof field doesn't need hasbit
    try testing.expect(!needsHasbit(.{
        .name = "field",
        .number = 1,
        .label = .optional,
        .type = .TYPE_INT32,
        .type_name = "",
        .oneof_index = 0,
    }));
}

test "computePresence" {
    var hasbit_idx: u16 = 0;

    // Optional field gets hasbit
    const presence1 = computePresence(.{
        .name = "field1",
        .number = 1,
        .label = .optional,
        .type = .TYPE_INT32,
        .type_name = "",
    }, &hasbit_idx);
    try testing.expectEqual(@as(i16, 1), presence1); // hasbit_index=0, so presence=1
    try testing.expectEqual(@as(u16, 1), hasbit_idx);

    // Another optional field
    const presence2 = computePresence(.{
        .name = "field2",
        .number = 2,
        .label = .optional,
        .type = .TYPE_STRING,
        .type_name = "",
    }, &hasbit_idx);
    try testing.expectEqual(@as(i16, 2), presence2); // hasbit_index=1, so presence=2
    try testing.expectEqual(@as(u16, 2), hasbit_idx);

    // Oneof field gets negative encoding
    const presence3 = computePresence(.{
        .name = "field3",
        .number = 3,
        .label = .optional,
        .type = .TYPE_INT32,
        .type_name = "",
        .oneof_index = 0,
    }, &hasbit_idx);
    try testing.expectEqual(@as(i16, -1), presence3); // -1 - 0 = -1

    // Repeated field gets 0
    const presence4 = computePresence(.{
        .name = "field4",
        .number = 4,
        .label = .repeated,
        .type = .TYPE_INT32,
        .type_name = "",
    }, &hasbit_idx);
    try testing.expectEqual(@as(i16, 0), presence4);
    try testing.expectEqual(@as(u16, 2), hasbit_idx); // Unchanged
}

test "computeDenseBelow" {
    const allocator = testing.allocator;

    // Empty
    try testing.expectEqual(@as(u8, 0), computeDenseBelow(&.{}));

    // Dense: 1, 2, 3
    {
        var layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 2, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 3), computeDenseBelow(&layouts));
    }

    // Sparse: 1, 3, 5
    {
        var layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 5, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 1), computeDenseBelow(&layouts));
    }

    // Dense then sparse: 1, 2, 3, 100
    {
        var layouts = [_]FieldLayout{
            .{ .number = 1, .offset = 0, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 2, .offset = 4, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 3, .offset = 8, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
            .{ .number = 100, .offset = 12, .presence = 0, .submsg_index = 0xFFFF, .field_type = .TYPE_INT32, .mode = .scalar, .is_packed = false },
        };
        try testing.expectEqual(@as(u8, 3), computeDenseBelow(&layouts));
    }

    _ = allocator; // Suppress unused warning
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

    // Check hasbit_bytes: 3 optional fields = 3 hasbits = 1 byte
    try testing.expectEqual(@as(u16, 1), layout.hasbit_bytes);

    // Check oneof_count
    try testing.expectEqual(@as(u8, 0), layout.oneof_count);

    // Check dense_below: fields 1, 2, 3 are all present
    try testing.expectEqual(@as(u8, 3), layout.dense_below);

    // Check fields are sorted by number
    try testing.expectEqual(@as(u32, 1), layout.fields[0].number);
    try testing.expectEqual(@as(u32, 2), layout.fields[1].number);
    try testing.expectEqual(@as(u32, 3), layout.fields[2].number);

    // Check presence values (hasbit indices)
    try testing.expectEqual(@as(i16, 1), layout.fields[0].presence); // id
    try testing.expectEqual(@as(i16, 2), layout.fields[1].presence); // name
    try testing.expectEqual(@as(i16, 3), layout.fields[2].presence); // active

    // Check that fields are laid out with proper alignment
    // Layout: [1 byte hasbits] [padding to 8-byte] [name: StringView 13 bytes] [id: i32 4 bytes] [active: bool 1 byte]
    // StringView comes first (13 bytes, 8-byte aligned)
    // Then i32 (4 bytes, 4-byte aligned)
    // Then bool (1 byte, 1-byte aligned)

    // After hasbits (1 byte), align to 8 for StringView
    // name (field 2) should be at offset 8
    const name_field = blk: {
        for (layout.fields) |f| {
            if (f.number == 2) break :blk f;
        }
        unreachable;
    };
    try testing.expectEqual(@as(u16, 8), name_field.offset);
}
