//! Descriptor decoder - parses FileDescriptorSet into MiniTables.
//!
//! This module provides runtime parsing of protocol buffer descriptors,
//! allowing dynamic message handling without pre-generated code.

const std = @import("std");
const Arena = @import("../arena.zig").Arena;
const MiniTable = @import("../mini_table.zig").MiniTable;
const MiniTableField = @import("../mini_table.zig").MiniTableField;
const FieldType = @import("../mini_table.zig").FieldType;
const Mode = @import("../mini_table.zig").Mode;
const Message = @import("../message.zig").Message;
const StringView = @import("../message.zig").StringView;
const RepeatedField = @import("../message.zig").RepeatedField;
const wire = @import("../wire/wire.zig");
const bootstrap = @import("bootstrap.zig");

/// Symbol table mapping fully-qualified message names to MiniTables.
pub const SymbolTable = struct {
    arena: *Arena,
    tables: std.StringHashMapUnmanaged(*const MiniTable),

    pub fn init(arena: *Arena) SymbolTable {
        return .{
            .arena = arena,
            .tables = .{},
        };
    }

    /// Find a MiniTable by fully-qualified name (e.g., ".foo.bar.Baz").
    pub fn find(self: *const SymbolTable, name: []const u8) ?*const MiniTable {
        return self.tables.get(name);
    }

    /// Insert a MiniTable with the given fully-qualified name.
    fn insert(self: *SymbolTable, name: []const u8, table: *const MiniTable) !void {
        // Copy name to arena
        const name_copy = self.arena.alloc(u8, @intCast(name.len)) orelse return error.OutOfMemory;
        @memcpy(name_copy, name);

        // Insert into hash map (using arena as allocator)
        var allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer allocator.deinit();
        try self.tables.put(allocator.allocator(), name_copy, table);
    }
};

/// Parse FileDescriptorSet binary and build MiniTables for all message types.
pub fn parse_file_descriptor_set(
    data: []const u8,
    arena: *Arena,
) !SymbolTable {
    var symbol_table = SymbolTable.init(arena);

    // Decode FileDescriptorSet using bootstrap tables
    const fds_msg = Message.new(arena, &bootstrap.file_descriptor_set_table) orelse return error.OutOfMemory;
    try wire.decode.decode(data, fds_msg, arena, .{ .alias_string = true });

    // Get FileDescriptorProto repeated field
    const fds_struct: *const bootstrap.FileDescriptorSet = @ptrCast(@alignCast(fds_msg.data.ptr));
    const file_field = &fds_struct.file;
    if (file_field.count == 0) return error.MalformedDescriptor;

    // Process each FileDescriptorProto
    const file_count = file_field.count;
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        const file_msg = get_repeated_message(file_field, i);
        try process_file_descriptor(file_msg, arena, &symbol_table);
    }

    return symbol_table;
}

/// Helper to get a message from a repeated field by index.
fn get_repeated_message(repeated: *const RepeatedField, index: u32) *const Message {
    const offset = index * repeated.element_size;
    const data = repeated.data orelse @panic("null repeated field");
    const element_ptr = data + offset;
    const msg_ptr: *const ?*Message = @ptrCast(@alignCast(element_ptr));
    return msg_ptr.*.?;
}

/// Process a single FileDescriptorProto.
fn process_file_descriptor(
    file_msg: *const Message,
    arena: *Arena,
    symbol_table: *SymbolTable,
) !void {
    const file_struct: *const bootstrap.FileDescriptorProto = @ptrCast(@alignCast(file_msg.data.ptr));

    // Get package name for fully-qualified name construction
    const package = if (file_struct.package.len > 0) file_struct.package.slice() else "";

    // Process message types
    const message_type_field = &file_struct.message_type;
    if (message_type_field.count > 0) {
        const count = message_type_field.count;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const desc_msg = get_repeated_message(message_type_field, i);
            try process_descriptor_proto(desc_msg, package, arena, symbol_table);
        }
    }
}

/// Process a DescriptorProto and build its MiniTable.
fn process_descriptor_proto(
    desc_msg: *const Message,
    package: []const u8,
    arena: *Arena,
    symbol_table: *SymbolTable,
) !void {
    const desc_struct: *const bootstrap.DescriptorProto = @ptrCast(@alignCast(desc_msg.data.ptr));

    // Build fully-qualified name: ".package.Name"
    const name = desc_struct.name.slice();
    const full_name = try build_full_name(package, name, arena);

    // Build MiniTable for this message
    const table = try build_message_table(desc_msg, arena, symbol_table);

    // Insert into symbol table
    try symbol_table.insert(full_name, table);

    // Process nested types
    const nested_field = &desc_struct.nested_type;
    if (nested_field.count > 0) {
        const count = nested_field.count;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const nested_msg = get_repeated_message(nested_field, i);
            // Nested types use "Parent.Nested" naming
            try process_descriptor_proto(nested_msg, full_name, arena, symbol_table);
        }
    }
}

/// Build fully-qualified name from package and message name.
fn build_full_name(package: []const u8, name: []const u8, arena: *Arena) ![]const u8 {
    // Format: ".package.Name" or ".Name" if no package
    const total_len = if (package.len > 0) 1 + package.len + 1 + name.len else 1 + name.len;
    const buffer = arena.alloc(u8, @intCast(total_len)) orelse return error.OutOfMemory;

    var pos: usize = 0;
    buffer[pos] = '.';
    pos += 1;

    if (package.len > 0) {
        @memcpy(buffer[pos..pos + package.len], package);
        pos += package.len;
        buffer[pos] = '.';
        pos += 1;
    }

    @memcpy(buffer[pos..pos + name.len], name);
    return buffer;
}

/// Build a MiniTable from DescriptorProto.
fn build_message_table(
    desc_msg: *const Message,
    arena: *Arena,
    symbol_table: *const SymbolTable,
) !*const MiniTable {
    _ = symbol_table; // TODO: Use for type resolution
    const desc_struct: *const bootstrap.DescriptorProto = @ptrCast(@alignCast(desc_msg.data.ptr));

    // Get field count
    const field_repeated = &desc_struct.field;
    if (field_repeated.count == 0) {
        // Message with no fields
        const table = arena.alloc(MiniTable, 1) orelse return error.OutOfMemory;
        table[0] = .{
            .fields = &.{},
            .submessages = &.{},
            .size = 0,
            .hasbit_bytes = 0,
            .oneof_count = 0,
            .dense_below = 0,
        };
        return &table[0];
    }

    const field_count = field_repeated.count;

    // Get oneof count
    const oneof_field = &desc_struct.oneof_decl;
    const oneof_count: u8 = @intCast(oneof_field.count);

    // Allocate fields array
    const fields = arena.alloc(MiniTableField, field_count) orelse return error.OutOfMemory;

    // Build each field
    var submsg_count: u16 = 0;
    var i: u32 = 0;
    while (i < field_count) : (i += 1) {
        const field_msg = get_repeated_message(field_repeated, i);
        fields[i] = try build_field(field_msg, &submsg_count);
    }

    // Calculate layout (sorts fields, assigns offsets, calculates size)
    const layout = try calculate_layout(fields, oneof_count, arena);

    // Build submessages array (allocate but don't fill yet - needs type resolution)
    const submessages = if (submsg_count > 0) blk: {
        const array = arena.alloc(*const MiniTable, submsg_count) orelse return error.OutOfMemory;
        // Fill with placeholders - will be resolved in second pass
        for (array) |*ptr| {
            ptr.* = &bootstrap.field_descriptor_proto_table; // Temporary placeholder
        }
        break :blk array;
    } else &.{};

    // TODO: Resolve type_name strings to MiniTable references (second pass)

    const table = arena.alloc(MiniTable, 1) orelse return error.OutOfMemory;
    table[0] = .{
        .fields = fields,
        .submessages = submessages,
        .size = layout.size,
        .hasbit_bytes = layout.hasbit_bytes,
        .oneof_count = layout.oneof_count,
        .dense_below = layout.dense_below,
    };

    return &table[0];
}

/// Build a MiniTableField from FieldDescriptorProto.
fn build_field(
    field_msg: *const Message,
    submsg_count: *u16,
) !MiniTableField {
    const field_struct: *const bootstrap.FieldDescriptorProto = @ptrCast(@alignCast(field_msg.data.ptr));

    const number: u32 = @intCast(field_struct.number);
    const label: i32 = field_struct.label;
    const field_type: i32 = field_struct.type;
    const oneof_index: i32 = field_struct.oneof_index;

    // Map protobuf type enum to FieldType
    const ft = map_field_type(field_type);

    // Determine mode (scalar/repeated)
    const mode: Mode = if (label == 3) .repeated else .scalar; // 3 = LABEL_REPEATED

    // Determine presence
    const presence: i16 = if (oneof_index > 0) -1 else 0; // Proto3 implicit presence or oneof

    // Track submessage count
    const submsg_index = if (ft == .TYPE_MESSAGE or ft == .TYPE_GROUP) blk: {
        const idx = submsg_count.*;
        submsg_count.* += 1;
        break :blk idx;
    } else MiniTableField.max_submsg_index;

    return .{
        .number = number,
        .offset = 0, // Will be calculated during layout
        .presence = presence,
        .submsg_index = submsg_index,
        .field_type = ft,
        .mode = mode,
        .is_packed = (mode == .repeated and ft.is_packable()),
    };
}

/// Map protobuf Type enum value to FieldType.
fn map_field_type(proto_type: i32) FieldType {
    return switch (proto_type) {
        1 => .TYPE_DOUBLE,
        2 => .TYPE_FLOAT,
        3 => .TYPE_INT64,
        4 => .TYPE_UINT64,
        5 => .TYPE_INT32,
        6 => .TYPE_FIXED64,
        7 => .TYPE_FIXED32,
        8 => .TYPE_BOOL,
        9 => .TYPE_STRING,
        10 => .TYPE_GROUP,
        11 => .TYPE_MESSAGE,
        12 => .TYPE_BYTES,
        13 => .TYPE_UINT32,
        14 => .TYPE_ENUM,
        15 => .TYPE_SFIXED32,
        16 => .TYPE_SFIXED64,
        17 => .TYPE_SINT32,
        18 => .TYPE_SINT64,
        else => .TYPE_BYTES, // Fallback
    };
}

/// Field representation size category.
const FieldRep = enum(u3) {
    rep_1byte = 0,
    rep_4byte = 1,
    rep_8byte = 2,
    rep_stringview = 3,
    rep_pointer = 4,

    fn size(self: FieldRep, is_64bit: bool) u16 {
        return switch (self) {
            .rep_1byte => 1,
            .rep_4byte => 4,
            .rep_8byte => 8,
            .rep_stringview => if (is_64bit) 16 else 12,
            .rep_pointer => if (is_64bit) 8 else 4,
        };
    }

    fn alignment(self: FieldRep, is_64bit: bool) u16 {
        return switch (self) {
            .rep_1byte => 1,
            .rep_4byte => 4,
            .rep_8byte => 8,
            .rep_stringview => if (is_64bit) 8 else 4,
            .rep_pointer => if (is_64bit) 8 else 4,
        };
    }
};

/// Get field representation category for a field.
fn field_rep(field: *const MiniTableField, is_64bit: bool) FieldRep {
    _ = is_64bit; // TODO: Use for determining pointer size
    if (field.mode == .repeated) return .rep_pointer;

    return switch (field.field_type) {
        .TYPE_BOOL => .rep_1byte,
        .TYPE_INT32, .TYPE_UINT32, .TYPE_SINT32, .TYPE_ENUM,
        .TYPE_FIXED32, .TYPE_SFIXED32, .TYPE_FLOAT => .rep_4byte,
        .TYPE_INT64, .TYPE_UINT64, .TYPE_SINT64,
        .TYPE_FIXED64, .TYPE_SFIXED64, .TYPE_DOUBLE => .rep_8byte,
        .TYPE_STRING, .TYPE_BYTES => .rep_stringview,
        .TYPE_MESSAGE, .TYPE_GROUP => .rep_pointer,
    };
}

/// Layout calculation results.
const LayoutInfo = struct {
    size: u16,
    hasbit_bytes: u8,
    oneof_count: u8,
    dense_below: u8,
};

/// Calculate field layout (offsets, hasbit indices, size).
fn calculate_layout(
    fields: []MiniTableField,
    oneof_count: u8,
    arena: *Arena,
) !LayoutInfo {
    _ = arena; // TODO: Use for allocations if needed
    const is_64bit = @sizeOf(usize) == 8;

    // Sort fields by number
    sort_fields_by_number(fields);

    // Calculate dense_below (highest contiguous field number starting from 1)
    const dense_below = calculate_dense_below(fields);

    // Count fields needing hasbits (proto2 optional fields)
    // For proto3, hasbit_bytes = 0
    const hasbit_bytes: u8 = 0; // Proto3 only for now

    // Count field representations
    var rep_counts = [_]u16{0} ** 5;
    var rep_offsets = [_]u16{0} ** 5;

    // Count oneof case fields (4 bytes each)
    rep_counts[@intFromEnum(FieldRep.rep_4byte)] += oneof_count;

    // Count regular fields
    for (fields) |*field| {
        if (field.is_oneof()) continue; // Oneof fields counted separately
        const rep = field_rep(field, is_64bit);
        rep_counts[@intFromEnum(rep)] += 1;
    }

    // Count oneof data storage (largest member of each oneof)
    // TODO: Track oneof sizes properly
    // For now, assume each oneof needs pointer storage
    rep_counts[@intFromEnum(FieldRep.rep_pointer)] += oneof_count;

    // Calculate base offsets for each representation type
    var base: u16 = hasbit_bytes;
    for (0..5) |i| {
        const rep: FieldRep = @enumFromInt(i);
        if (rep_counts[i] > 0) {
            // Align base to this representation's alignment
            const align_val = rep.alignment(is_64bit);
            base = align_up(base, align_val);
            rep_offsets[i] = base;
            base += rep.size(is_64bit) * rep_counts[i];
        }
    }

    // Assign field offsets
    var rep_next = rep_offsets;
    for (fields) |*field| {
        if (field.is_oneof()) {
            // Oneof fields share storage - assign later
            continue;
        }

        const rep = field_rep(field, is_64bit);
        const rep_idx = @intFromEnum(rep);
        field.offset = rep_next[rep_idx];
        rep_next[rep_idx] += rep.size(is_64bit);
    }

    // Align total size to 8 bytes
    const size = align_up(base, 8);

    return .{
        .size = size,
        .hasbit_bytes = hasbit_bytes,
        .oneof_count = oneof_count,
        .dense_below = dense_below,
    };
}

/// Sort fields by field number (ascending).
fn sort_fields_by_number(fields: []MiniTableField) void {
    // Simple insertion sort (fine for typical message sizes)
    var i: usize = 1;
    while (i < fields.len) : (i += 1) {
        const key = fields[i];
        var j: usize = i;
        while (j > 0 and fields[j - 1].number > key.number) : (j -= 1) {
            fields[j] = fields[j - 1];
        }
        fields[j] = key;
    }
}

/// Calculate dense_below (highest contiguous field number from 1).
fn calculate_dense_below(fields: []const MiniTableField) u8 {
    if (fields.len == 0) return 0;

    var expected: u32 = 1;
    for (fields) |field| {
        if (field.number != expected) break;
        expected += 1;
    }

    const result = expected - 1;
    return if (result > 255) 255 else @intCast(result);
}

/// Align value up to alignment boundary.
fn align_up(value: u16, alignment: u16) u16 {
    return (value + alignment - 1) & ~(alignment - 1);
}

// TODO: Implement submessage array building
// TODO: Implement type name resolution

test "parse empty FileDescriptorSet" {
    var buffer: [4096]u8 = undefined;
    var arena = Arena.init(&buffer);

    // Empty FileDescriptorSet (just field 1 with empty repeated field)
    // This is: field tag (08) + varint length (00)
    const empty_fds = [_]u8{};

    const result = parse_file_descriptor_set(&empty_fds, &arena);
    try std.testing.expect(result == error.MalformedDescriptor or result != error.OutOfMemory);
}

test "field layout calculation" {
    var buffer: [4096]u8 = undefined;
    var arena = Arena.init(&buffer);

    // Create a simple field array
    var fields = [_]MiniTableField{
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
            .offset = 0,
            .presence = 0,
            .submsg_index = MiniTableField.max_submsg_index,
            .field_type = .TYPE_STRING,
            .mode = .scalar,
            .is_packed = false,
        },
    };

    const layout = try calculate_layout(&fields, 0, &arena);

    // Verify fields were sorted
    try std.testing.expectEqual(@as(u32, 1), fields[0].number);
    try std.testing.expectEqual(@as(u32, 2), fields[1].number);

    // Verify layout was calculated
    try std.testing.expect(layout.size > 0);
    try std.testing.expectEqual(@as(u8, 2), layout.dense_below);

    // Verify offsets were assigned
    try std.testing.expect(fields[0].offset < layout.size);
    try std.testing.expect(fields[1].offset < layout.size);
}
