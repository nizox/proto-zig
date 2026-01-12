///! Resolve type references and build submessages arrays for code generation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const FieldType = proto.FieldType;

const descriptor_parser = @import("descriptor_parser.zig");
const MessageInfo = descriptor_parser.MessageInfo;
const FieldInfo = descriptor_parser.FieldInfo;

/// Link all messages across multiple files with cross-file type resolution.
pub fn linkFiles(all_files: []descriptor_parser.FileInfo, allocator: Allocator) !void {
    // Build global symbol table across all files
    var symbols = std.StringHashMap(*MessageInfo).init(allocator);
    defer symbols.deinit();

    for (all_files) |*file| {
        try buildSymbolTable(file.messages, &symbols);
    }

    // Link each file's messages using the global symbol table
    for (all_files) |*file| {
        for (file.messages) |*msg| {
            try linkMessage(msg, &symbols, allocator);
        }
    }
}

/// Link all messages in a file: resolve type references and build submessages arrays.
pub fn linkFile(messages: []MessageInfo, allocator: Allocator) !void {
    // Build symbol table of all messages (including nested)
    var symbols = std.StringHashMap(*MessageInfo).init(allocator);
    defer symbols.deinit();

    try buildSymbolTable(messages, &symbols);

    // Link each message
    for (messages) |*msg| {
        try linkMessage(msg, &symbols, allocator);
    }
}

/// Recursively build symbol table for all messages (including nested).
fn buildSymbolTable(messages: []MessageInfo, symbols: *std.StringHashMap(*MessageInfo)) !void {
    for (messages) |*msg| {
        try symbols.put(msg.full_name, msg);

        // Recurse into nested messages
        if (msg.nested_messages.len > 0) {
            try buildSymbolTable(msg.nested_messages, symbols);
        }
    }
}

/// Link a single message: resolve field types and build submessages array.
fn linkMessage(msg: *MessageInfo, symbols: *std.StringHashMap(*MessageInfo), allocator: Allocator) !void {
    // 1. Resolve field type_name -> resolved_message
    for (msg.fields) |*field| {
        if (field.type == .TYPE_MESSAGE) {
            field.resolved_message = symbols.get(field.type_name) orelse {
                std.debug.print("Error: unresolved type '{s}' in message '{s}'\n", .{ field.type_name, msg.full_name });
                return error.UnresolvedType;
            };
        }
    }

    // 2. Build submessages array (unique, ordered by first appearance)
    var submessages: std.ArrayList([]const u8) = .empty;
    errdefer submessages.deinit(allocator);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (msg.fields) |field| {
        if (field.type == .TYPE_MESSAGE) {
            const resolved = field.resolved_message orelse continue;
            const table_name = resolved.full_name;

            if (!seen.contains(table_name)) {
                try submessages.append(allocator, table_name);
                try seen.put(table_name, {});
            }
        }
    }

    msg.submessages_array = try submessages.toOwnedSlice(allocator);

    // 3. Set submsg_index in layout fields
    if (msg.layout) |*layout| {
        for (layout.fields) |*field_layout| {
            if (field_layout.field_type == .TYPE_MESSAGE) {
                // Find corresponding FieldInfo to get resolved_message
                var field_info: ?*const FieldInfo = null;
                for (msg.fields) |*f| {
                    if (f.number == field_layout.number) {
                        field_info = f;
                        break;
                    }
                }

                if (field_info) |fi| {
                    if (fi.resolved_message) |resolved| {
                        // Find index in submessages array
                        const target = resolved.full_name;
                        for (msg.submessages_array, 0..) |submsg, idx| {
                            if (std.mem.eql(u8, submsg, target)) {
                                field_layout.submsg_index = @intCast(idx);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    // 4. Recurse into nested messages
    for (msg.nested_messages) |*nested| {
        try linkMessage(nested, symbols, allocator);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

test "linkFile - simple message with submessage" {
    const allocator = testing.allocator;

    // Create messages
    const inner = MessageInfo{
        .name = "Inner",
        .full_name = ".test.Inner",
        .fields = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var outer_fields = [_]FieldInfo{
        .{
            .name = "inner_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.Inner",
        },
    };

    const outer = MessageInfo{
        .name = "Outer",
        .full_name = ".test.Outer",
        .fields = outer_fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var messages = [_]MessageInfo{ inner, outer };

    // Link
    try linkFile(messages[0..], allocator);
    defer allocator.free(messages[1].submessages_array);

    // Verify resolution
    try expect(messages[1].fields[0].resolved_message != null);
    try expectEqualStrings(".test.Inner", messages[1].fields[0].resolved_message.?.full_name);

    // Verify submessages array
    try expectEqual(@as(usize, 1), messages[1].submessages_array.len);
    try expectEqualStrings(".test.Inner", messages[1].submessages_array[0]);
}

test "linkFile - multiple submessages" {
    const allocator = testing.allocator;

    // Create messages
    const msg_a = MessageInfo{
        .name = "A",
        .full_name = ".test.A",
        .fields = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    const msg_b = MessageInfo{
        .name = "B",
        .full_name = ".test.B",
        .fields = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var outer_fields = [_]FieldInfo{
        .{
            .name = "field_a",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.A",
        },
        .{
            .name = "field_b",
            .number = 2,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.B",
        },
        .{
            .name = "field_a2",
            .number = 3,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.A",
        },
    };

    const outer = MessageInfo{
        .name = "Outer",
        .full_name = ".test.Outer",
        .fields = outer_fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var messages = [_]MessageInfo{ msg_a, msg_b, outer };

    // Link
    try linkFile(messages[0..], allocator);
    defer allocator.free(messages[2].submessages_array);

    // Verify submessages array: A and B (unique, ordered by first appearance)
    try expectEqual(@as(usize, 2), messages[2].submessages_array.len);
    try expectEqualStrings(".test.A", messages[2].submessages_array[0]);
    try expectEqualStrings(".test.B", messages[2].submessages_array[1]);
}

test "linkFile - nested messages" {
    const allocator = testing.allocator;

    // Create nested message
    const nested = MessageInfo{
        .name = "Nested",
        .full_name = ".test.Outer.Nested",
        .fields = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var nested_array = [_]MessageInfo{nested};

    var outer_fields = [_]FieldInfo{
        .{
            .name = "nested_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.Outer.Nested",
        },
    };

    const outer = MessageInfo{
        .name = "Outer",
        .full_name = ".test.Outer",
        .fields = outer_fields[0..],
        .nested_messages = nested_array[0..],
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var messages = [_]MessageInfo{outer};

    // Link
    try linkFile(messages[0..], allocator);
    defer allocator.free(messages[0].submessages_array);

    // Verify nested message is resolved
    try expect(messages[0].fields[0].resolved_message != null);
    try expectEqualStrings(".test.Outer.Nested", messages[0].fields[0].resolved_message.?.full_name);
}

test "linkFile - self-referencing message" {
    const allocator = testing.allocator;

    var msg_fields = [_]FieldInfo{
        .{
            .name = "self_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.Node",
        },
    };

    const node = MessageInfo{
        .name = "Node",
        .full_name = ".test.Node",
        .fields = msg_fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var messages = [_]MessageInfo{node};

    // Link
    try linkFile(messages[0..], allocator);
    defer allocator.free(messages[0].submessages_array);

    // Verify self-reference
    try expect(messages[0].fields[0].resolved_message != null);
    try expectEqualStrings(".test.Node", messages[0].fields[0].resolved_message.?.full_name);

    // Verify submessages array contains self
    try expectEqual(@as(usize, 1), messages[0].submessages_array.len);
    try expectEqualStrings(".test.Node", messages[0].submessages_array[0]);
}

test "linkFile - unresolved type error" {
    const allocator = testing.allocator;

    var msg_fields = [_]FieldInfo{
        .{
            .name = "unknown_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.Unknown",
        },
    };

    const msg = MessageInfo{
        .name = "Test",
        .full_name = ".test.Test",
        .fields = msg_fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var messages = [_]MessageInfo{msg};

    // Should return error
    const result = linkFile(messages[0..], allocator);
    try testing.expectError(error.UnresolvedType, result);
}

test "linkFile - submsg_index set correctly in layout" {
    const allocator = testing.allocator;

    const FieldLayout = descriptor_parser.FieldLayout;
    const LayoutInfo = descriptor_parser.LayoutInfo;

    // Create messages
    const inner = MessageInfo{
        .name = "Inner",
        .full_name = ".test.Inner",
        .fields = &.{},
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
    };

    var outer_fields = [_]FieldInfo{
        .{
            .name = "inner_field",
            .number = 1,
            .label = .optional,
            .type = .TYPE_MESSAGE,
            .type_name = ".test.Inner",
        },
    };

    var layout_fields = [_]FieldLayout{
        .{
            .number = 1,
            .offset = 0,
            .presence = 0,
            .submsg_index = 0xFFFF, // Not yet set
            .field_type = .TYPE_MESSAGE,
            .mode = .scalar,
            .is_packed = false,
        },
    };

    const outer = MessageInfo{
        .name = "Outer",
        .full_name = ".test.Outer",
        .fields = outer_fields[0..],
        .nested_messages = &.{},
        .nested_enums = &.{},
        .oneofs = &.{},
        .layout = LayoutInfo{
            .size = 8,
            .hasbit_bytes = 0,
            .oneof_count = 0,
            .dense_below = 1,
            .fields = layout_fields[0..],
        },
    };

    var messages = [_]MessageInfo{ inner, outer };

    // Link
    try linkFile(messages[0..], allocator);
    defer allocator.free(messages[1].submessages_array);

    // Verify submsg_index was set
    try expectEqual(@as(u16, 0), messages[1].layout.?.fields[0].submsg_index);
}
