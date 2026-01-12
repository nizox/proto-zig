///! Name conversion utilities for protoc code generation.
///!
///! Converts protobuf names (CamelCase, dot-separated) to Zig identifiers (snake_case).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Convert CamelCase to snake_case.
/// Example: "DescriptorProto" -> "descriptor_proto"
pub fn toSnakeCase(allocator: Allocator, camel: []const u8) ![]const u8 {
    if (camel.len == 0) return try allocator.dupe(u8, camel);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var prev_was_lower = false;
    for (camel, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            // Insert underscore before uppercase if:
            // 1. Not at start AND
            // 2. Previous character was lowercase OR next character is lowercase (handles "HTTPServer" -> "http_server")
            if (i > 0 and (prev_was_lower or (i + 1 < camel.len and std.ascii.isLower(camel[i + 1])))) {
                try result.append(allocator, '_');
            }
            try result.append(allocator, std.ascii.toLower(c));
            prev_was_lower = false;
        } else {
            try result.append(allocator, c);
            prev_was_lower = std.ascii.isLower(c);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate MiniTable variable name for a message.
/// Example: "DescriptorProto" -> "descriptor_proto_table"
pub fn messageTableName(allocator: Allocator, message_name: []const u8) ![]const u8 {
    const snake = try toSnakeCase(allocator, message_name);
    defer allocator.free(snake);

    const sanitized = try sanitizeIdentifier(allocator, snake);
    defer allocator.free(sanitized);

    return std.fmt.allocPrint(allocator, "{s}_table", .{sanitized});
}

/// Generate field array variable name for a message.
/// Example: "DescriptorProto" -> "descriptor_proto_fields"
pub fn messageFieldsName(allocator: Allocator, message_name: []const u8) ![]const u8 {
    const snake = try toSnakeCase(allocator, message_name);
    defer allocator.free(snake);

    const sanitized = try sanitizeIdentifier(allocator, snake);
    defer allocator.free(sanitized);

    return std.fmt.allocPrint(allocator, "{s}_fields", .{sanitized});
}

/// Generate submessages array variable name for a message.
/// Example: "DescriptorProto" -> "descriptor_proto_submessages"
pub fn messageSubmessagesName(allocator: Allocator, message_name: []const u8) ![]const u8 {
    const snake = try toSnakeCase(allocator, message_name);
    defer allocator.free(snake);

    const sanitized = try sanitizeIdentifier(allocator, snake);
    defer allocator.free(sanitized);

    return std.fmt.allocPrint(allocator, "{s}_submessages", .{sanitized});
}

/// Generate struct type name for a message.
/// Example: "DescriptorProto" -> "DescriptorProto"
pub fn messageStructName(allocator: Allocator, message_name: []const u8) ![]const u8 {
    return sanitizeIdentifier(allocator, message_name);
}

/// Extract simple name from full message name.
/// Example: ".google.protobuf.DescriptorProto" -> "DescriptorProto"
pub fn extractSimpleName(full_name: []const u8) []const u8 {
    // Strip leading dot
    const name_without_dot = if (full_name.len > 0 and full_name[0] == '.')
        full_name[1..]
    else
        full_name;

    // Extract simple name (after last dot)
    return if (std.mem.lastIndexOf(u8, name_without_dot, ".")) |idx|
        name_without_dot[idx + 1 ..]
    else
        name_without_dot;
}

/// Generate filename for generated .zig file from .proto filename.
/// Example: "google/protobuf/descriptor.proto" -> "descriptor.pb.zig"
pub fn generatedFilename(allocator: Allocator, proto_filename: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(proto_filename);

    // Remove .proto extension
    const stem = if (std.mem.endsWith(u8, basename, ".proto"))
        basename[0 .. basename.len - 6]
    else
        basename;

    return std.fmt.allocPrint(allocator, "{s}.pb.zig", .{stem});
}

/// Sanitize identifier to avoid Zig reserved words.
/// If the identifier is a reserved word, append underscore.
pub fn sanitizeIdentifier(allocator: Allocator, ident: []const u8) ![]const u8 {
    if (isReservedWord(ident)) {
        return std.fmt.allocPrint(allocator, "{s}_", .{ident});
    }
    return allocator.dupe(u8, ident);
}

/// Check if a string is a Zig reserved word.
fn isReservedWord(ident: []const u8) bool {
    const reserved = [_][]const u8{
        "align",      "allowzero", "and",       "anyframe",  "anytype",
        "asm",        "async",     "await",     "break",     "callconv",
        "catch",      "comptime",  "const",     "continue",  "defer",
        "else",       "enum",      "errdefer",  "error",     "export",
        "extern",     "fn",        "for",       "if",        "inline",
        "noalias",    "noinline",  "nosuspend", "opaque",    "or",
        "orelse",     "packed",    "pub",       "resume",    "return",
        "linksection", "struct",   "suspend",   "switch",    "test",
        "threadlocal", "try",      "type",      "union",     "unreachable",
        "usingnamespace", "var",   "volatile",  "while",
    };

    for (reserved) |word| {
        if (std.mem.eql(u8, ident, word)) {
            return true;
        }
    }
    return false;
}

// Tests
test "toSnakeCase - simple" {
    const allocator = std.testing.allocator;

    const result = try toSnakeCase(allocator, "DescriptorProto");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("descriptor_proto", result);
}

test "toSnakeCase - single word" {
    const allocator = std.testing.allocator;

    const result = try toSnakeCase(allocator, "Message");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("message", result);
}

test "toSnakeCase - acronym" {
    const allocator = std.testing.allocator;

    const result = try toSnakeCase(allocator, "HTTPServer");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("http_server", result);
}

test "toSnakeCase - consecutive capitals" {
    const allocator = std.testing.allocator;

    const result = try toSnakeCase(allocator, "IOError");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("io_error", result);
}

test "toSnakeCase - empty" {
    const allocator = std.testing.allocator;

    const result = try toSnakeCase(allocator, "");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "messageTableName" {
    const allocator = std.testing.allocator;

    const result = try messageTableName(allocator, "DescriptorProto");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("descriptor_proto_table", result);
}

test "messageFieldsName" {
    const allocator = std.testing.allocator;

    const result = try messageFieldsName(allocator, "FieldDescriptorProto");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("field_descriptor_proto_fields", result);
}

test "extractSimpleName" {
    try std.testing.expectEqualStrings("DescriptorProto", extractSimpleName(".google.protobuf.DescriptorProto"));
    try std.testing.expectEqualStrings("Node", extractSimpleName(".test.Node"));
    try std.testing.expectEqualStrings("SimpleMessage", extractSimpleName("SimpleMessage"));
    try std.testing.expectEqualStrings("Message", extractSimpleName(".Message"));
}

test "generatedFilename" {
    const allocator = std.testing.allocator;

    {
        const result = try generatedFilename(allocator, "google/protobuf/descriptor.proto");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("descriptor.pb.zig", result);
    }

    {
        const result = try generatedFilename(allocator, "conformance.proto");
        defer allocator.free(result);
        try std.testing.expectEqualStrings("conformance.pb.zig", result);
    }
}

test "sanitizeIdentifier - reserved word" {
    const allocator = std.testing.allocator;

    const result = try sanitizeIdentifier(allocator, "type");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("type_", result);
}

test "sanitizeIdentifier - normal word" {
    const allocator = std.testing.allocator;

    const result = try sanitizeIdentifier(allocator, "message");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("message", result);
}

test "isReservedWord" {
    try std.testing.expect(isReservedWord("type"));
    try std.testing.expect(isReservedWord("const"));
    try std.testing.expect(isReservedWord("fn"));
    try std.testing.expect(!isReservedWord("message"));
    try std.testing.expect(!isReservedWord("field"));
}
