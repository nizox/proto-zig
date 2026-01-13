///! Parse FileDescriptorProto into intermediate representation for code generation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("proto");
const Message = proto.Message;
const RepeatedField = proto.RepeatedField;
const StringView = proto.StringView;
const FieldType = proto.FieldType;
const Mode = proto.FieldMode;
const bootstrap = proto.bootstrap;

/// Represents a parsed .proto file.
pub const FileInfo = struct {
    name: []const u8,
    package: []const u8,
    messages: []MessageInfo,
    enums: []EnumInfo,
    dependencies: [][]const u8,
};

/// Represents a message type.
pub const MessageInfo = struct {
    name: []const u8, // Simple name: "DescriptorProto"
    full_name: []const u8, // Fully-qualified: ".google.protobuf.DescriptorProto"
    fields: []FieldInfo,
    nested_messages: []MessageInfo,
    nested_enums: []EnumInfo,
    oneofs: []OneofInfo,
    is_map_entry: bool = false,

    // Set during layout calculation
    layout: ?LayoutInfo = null,
    // Set during linking
    submessages_array: [][]const u8 = &.{},
};

/// Represents a field in a message.
pub const FieldInfo = struct {
    name: []const u8,
    number: u32,
    label: FieldLabel,
    type: FieldType,
    type_name: []const u8, // For message/enum fields, fully-qualified name
    oneof_index: ?u16 = null,
    is_packed: bool = false,
    is_map_entry: bool = false, // True if this field is part of a map entry

    // Set during linking
    resolved_message: ?*MessageInfo = null,
};

/// Represents an enum type.
pub const EnumInfo = struct {
    name: []const u8,
    full_name: []const u8,
    values: []EnumValueInfo,
};

/// Represents an enum value.
pub const EnumValueInfo = struct {
    name: []const u8,
    number: i32,
};

/// Represents a oneof group.
pub const OneofInfo = struct {
    name: []const u8,
};

/// Field label (proto2/proto3 cardinality).
pub const FieldLabel = enum(i32) {
    optional = 1,
    required = 2,
    repeated = 3,
};

/// Layout information computed for a message.
pub const LayoutInfo = struct {
    size: u16,
    hasbit_bytes: u16,
    oneof_count: u8,
    dense_below: u8,
    fields: []FieldLayout,
};

/// Layout information for a single field.
pub const FieldLayout = struct {
    number: u32,
    offset: u16,
    presence: i16,
    submsg_index: u16,
    field_type: FieldType,
    mode: Mode,
    is_packed: bool,

    /// Returns true if this field is part of a oneof (derived from presence).
    pub fn is_oneof(self: *const FieldLayout) bool {
        return self.presence < 0;
    }
};

// Helper functions for accessing message fields by number

fn getString(msg: *const Message, field_number: u32) []const u8 {
    const field = msg.table.field_by_number(field_number) orelse return "";
    const value = msg.get_scalar(field);
    return switch (value) {
        .string_val => |s| s.slice(),
        else => "",
    };
}

fn getScalar(msg: *const Message, comptime T: type, field_number: u32) ?T {
    const field = msg.table.field_by_number(field_number) orelse return null;
    const value = msg.get_scalar(field);
    return switch (T) {
        i32 => switch (value) {
            .int32_val => |v| v,
            .none => null,  // Field not present
            else => null,
        },
        i64 => switch (value) {
            .int64_val => |v| v,
            .none => null,  // Field not present
            else => null,
        },
        u32 => switch (value) {
            .uint32_val => |v| v,
            .none => null,  // Field not present
            else => null,
        },
        else => @compileError("Unsupported scalar type"),
    };
}

fn getRepeated(msg: *const Message, field_number: u32) ?*const RepeatedField {
    const field = msg.table.field_by_number(field_number) orelse return null;
    const value_ptr = @as([*]u8, @ptrCast(msg.data.ptr)) + field.offset;
    const repeated_ptr = @as(*RepeatedField, @ptrCast(@alignCast(value_ptr)));
    // Return null if count is 0 (empty repeated field)
    if (repeated_ptr.count == 0) return null;
    return repeated_ptr;
}

fn getMessage(msg: *const Message, field_number: u32) ?*const Message {
    const field = msg.table.field_by_number(field_number) orelse return null;
    const value = msg.get_scalar(field);
    return switch (value) {
        .message_val => |m| m,
        else => null,
    };
}

/// Result of parsing CodeGeneratorRequest.
pub const ParsedRequest = struct {
    files_to_generate: []FileInfo,  // Files to generate code for
    all_files: []FileInfo,           // All files (including dependencies) for symbol resolution
};

/// Parse CodeGeneratorRequest and extract all FileInfo.
/// Returns both files to generate and all files (for cross-file type resolution).
pub fn parseRequest(request: *const Message, allocator: Allocator) !ParsedRequest {
    // Extract file_to_generate (field 1)
    const files_to_generate = getRepeated(request, 1) orelse {
        return ParsedRequest{
            .files_to_generate = &.{},
            .all_files = &.{},
        };
    };

    // Extract proto_file (field 15)
    const proto_files = getRepeated(request, 15) orelse {
        return ParsedRequest{
            .files_to_generate = &.{},
            .all_files = &.{},
        };
    };

    // Parse ALL files (including dependencies) for symbol resolution
    var all_parsed: std.ArrayList(FileInfo) = .empty;
    errdefer all_parsed.deinit(allocator);

    var file_map = std.StringHashMap(usize).init(allocator); // filename -> index in all_parsed
    defer file_map.deinit();

    for (0..proto_files.count) |i| {
        const file_msg_ptr = proto_files.get(*Message, @intCast(i)) orelse continue;
        const file_msg = file_msg_ptr.*;
        const name = getString(file_msg, 1); // name field
        if (name.len == 0) continue;

        const file_info = try parseFileDescriptor(file_msg, allocator);
        const index = all_parsed.items.len;
        try all_parsed.append(allocator, file_info);
        try file_map.put(name, index);
    }

    // Build list of files to generate (subset of all_parsed)
    var to_generate_indices: std.ArrayList(usize) = .empty;
    defer to_generate_indices.deinit(allocator);

    for (0..files_to_generate.count) |i| {
        const filename_sv_ptr = files_to_generate.get(StringView, @intCast(i)) orelse continue;
        const filename = filename_sv_ptr.slice();
        if (filename.len == 0) continue;

        const index = file_map.get(filename) orelse continue;
        try to_generate_indices.append(allocator, index);
    }

    // Build result arrays
    const all_files = try all_parsed.toOwnedSlice(allocator);

    var files_to_gen: std.ArrayList(FileInfo) = .empty;
    errdefer files_to_gen.deinit(allocator);

    for (to_generate_indices.items) |idx| {
        try files_to_gen.append(allocator, all_files[idx]);
    }

    return ParsedRequest{
        .files_to_generate = try files_to_gen.toOwnedSlice(allocator),
        .all_files = all_files,
    };
}

/// Parse a FileDescriptorProto message into FileInfo.
fn parseFileDescriptor(file_msg: *Message, allocator: Allocator) !FileInfo {
    const name = getString(file_msg, 1); // name
    const package = getString(file_msg, 2); // package

    // Parse dependencies (field 3)
    var dependencies: std.ArrayList([]const u8) = .empty;
    errdefer dependencies.deinit(allocator);

    if (getRepeated(file_msg, 3)) |deps| {
        for (0..deps.count) |i| {
            const dep_sv = deps.get(StringView, @intCast(i)) orelse continue;
            const dep_str = dep_sv.slice();
            try dependencies.append(allocator, try allocator.dupe(u8, dep_str));
        }
    }

    // Parse messages (field 4)
    var messages: std.ArrayList(MessageInfo) = .empty;
    errdefer messages.deinit(allocator);

    if (getRepeated(file_msg, 4)) |message_types| {
        for (0..message_types.count) |i| {
            const msg_ptr = message_types.get(*Message, @intCast(i)) orelse continue;
            const msg_info = try parseDescriptorProto(msg_ptr.*, package, "", allocator);
            try messages.append(allocator, msg_info);
        }
    }

    // Parse enums (field 5)
    var enums: std.ArrayList(EnumInfo) = .empty;
    errdefer enums.deinit(allocator);

    if (getRepeated(file_msg, 5)) |enum_types| {
        for (0..enum_types.count) |i| {
            const enum_msg_ptr = enum_types.get(*Message, @intCast(i)) orelse continue;
            const enum_info = try parseEnumDescriptor(enum_msg_ptr.*, package, "", allocator);
            try enums.append(allocator, enum_info);
        }
    }

    return FileInfo{
        .name = try allocator.dupe(u8, name),
        .package = try allocator.dupe(u8, package),
        .messages = try messages.toOwnedSlice(allocator),
        .enums = try enums.toOwnedSlice(allocator),
        .dependencies = try dependencies.toOwnedSlice(allocator),
    };
}

/// Parse a DescriptorProto message into MessageInfo.
/// parent_path is the fully-qualified parent name (e.g., ".google.protobuf")
fn parseDescriptorProto(
    msg: *const Message,
    package: []const u8,
    parent_path: []const u8,
    allocator: Allocator,
) !MessageInfo {
    const name = getString(msg, 1); // name

    // Build fully-qualified name
    const full_name = if (parent_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, name })
    else if (package.len > 0)
        try std.fmt.allocPrint(allocator, ".{s}.{s}", .{ package, name })
    else
        try std.fmt.allocPrint(allocator, ".{s}", .{name});

    // Parse fields (field 2)
    var fields: std.ArrayList(FieldInfo) = .empty;
    errdefer fields.deinit(allocator);

    if (getRepeated(msg, 2)) |field_list| {
        for (0..field_list.count) |i| {
            const field_msg_ptr = field_list.get(*Message, @intCast(i)) orelse continue;
            const field_info = try parseFieldDescriptor(field_msg_ptr.*, allocator);
            try fields.append(allocator, field_info);
        }
    }

    // Parse nested messages (field 3)
    var nested_messages: std.ArrayList(MessageInfo) = .empty;
    errdefer nested_messages.deinit(allocator);

    if (getRepeated(msg, 3)) |nested_list| {
        for (0..nested_list.count) |i| {
            const nested_msg_ptr = nested_list.get(*Message, @intCast(i)) orelse continue;
            const nested_info = try parseDescriptorProto(nested_msg_ptr.*, package, full_name, allocator);
            try nested_messages.append(allocator, nested_info);
        }
    }

    // Parse oneofs (field 8)
    var oneofs: std.ArrayList(OneofInfo) = .empty;
    errdefer oneofs.deinit(allocator);

    if (getRepeated(msg, 8)) |oneof_list| {
        for (0..oneof_list.count) |i| {
            const oneof_msg_ptr = oneof_list.get(*Message, @intCast(i)) orelse continue;
            const oneof_name = getString(oneof_msg_ptr.*, 1);
            try oneofs.append(allocator, .{ .name = try allocator.dupe(u8, oneof_name) });
        }
    }

    // Parse nested enums (if present in DescriptorProto field 4)
    // Note: Current bootstrap.zig doesn't have this field, so we skip for now
    const nested_enums: []EnumInfo = &.{};

    const oneofs_slice = try oneofs.toOwnedSlice(allocator);
    const fields_slice = try fields.toOwnedSlice(allocator);

    return MessageInfo{
        .name = try allocator.dupe(u8, name),
        .full_name = full_name,
        .fields = fields_slice,
        .nested_messages = try nested_messages.toOwnedSlice(allocator),
        .nested_enums = nested_enums,
        .oneofs = oneofs_slice,
        .is_map_entry = false, // TODO: Check options for map_entry flag
    };
}

/// Parse a FieldDescriptorProto message into FieldInfo.
fn parseFieldDescriptor(field_msg: *const Message, allocator: Allocator) !FieldInfo {
    const name = getString(field_msg, 1); // name
    const number = getScalar(field_msg, i32, 3) orelse 0; // number
    const label = getScalar(field_msg, i32, 4) orelse 1; // label
    const type_int = getScalar(field_msg, i32, 5) orelse 0; // type
    const type_name = getString(field_msg, 6); // type_name
    // Note: protoc sends oneof_index=0 for ALL fields, even those not in oneofs.
    // We need to validate the index against the actual oneof count later.
    // For now, just capture the raw value if present.
    const oneof_index_raw = getScalar(field_msg, i32, 9); // oneof_index

    const field_type: FieldType = @enumFromInt(@as(u8, @intCast(type_int)));
    const field_label: FieldLabel = @enumFromInt(label);

    // Determine packed encoding based on options and proto3 defaults.
    // Proto3: repeated scalars are packed by default unless [packed=false].
    const is_packed = determineIsPacked(field_msg, field_type, field_label);

    // Convert to u16, will be validated against oneof_count during layout
    const oneof_idx: ?u16 = if (oneof_index_raw) |idx| @intCast(idx) else null;

    return FieldInfo{
        .name = try allocator.dupe(u8, name),
        .number = @intCast(number),
        .label = field_label,
        .type = field_type,
        .type_name = try allocator.dupe(u8, type_name),
        .oneof_index = oneof_idx,
        .is_packed = is_packed,
    };
}

/// Determine if a field should use packed encoding.
/// Proto3 semantics: repeated scalars are packed by default.
/// Explicit [packed=false] option disables packing.
fn determineIsPacked(field_msg: *const Message, field_type: FieldType, field_label: FieldLabel) bool {
    // Only repeated fields can be packed
    if (field_label != .repeated) return false;

    // Only scalar types (not string, bytes, message, group) can be packed
    if (!field_type.is_packable()) return false;

    // Check for explicit packed option in FieldOptions (field 8)
    const options_msg = getMessage(field_msg, 8) orelse {
        // No options: proto3 default is packed=true for repeated scalars
        return true;
    };

    // Read packed field (field 2) from FieldOptions
    // Check hasbit to see if packed was explicitly set
    const hasbits_ptr = @as([*]const u8, @ptrCast(options_msg.data.ptr));
    const hasbit_byte = hasbits_ptr[0];
    const packed_explicitly_set = (hasbit_byte & 1) != 0; // Hasbit index 0

    if (packed_explicitly_set) {
        // Explicit value: read the packed field
        const packed_field = options_msg.table.field_by_number(2) orelse return true;
        const value = options_msg.get_scalar(packed_field);
        return switch (value) {
            .bool_val => |b| b,
            else => true, // Fallback to proto3 default
        };
    }

    // No explicit packed option: proto3 default is packed=true
    return true;
}

/// Parse an EnumDescriptorProto message into EnumInfo.
fn parseEnumDescriptor(
    enum_msg: *const Message,
    package: []const u8,
    parent_path: []const u8,
    allocator: Allocator,
) !EnumInfo {
    const name = getString(enum_msg, 1); // name

    // Build fully-qualified name
    const full_name = if (parent_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, name })
    else if (package.len > 0)
        try std.fmt.allocPrint(allocator, ".{s}.{s}", .{ package, name })
    else
        try std.fmt.allocPrint(allocator, ".{s}", .{name});

    // Parse values (field 2)
    var values: std.ArrayList(EnumValueInfo) = .empty;
    errdefer values.deinit(allocator);

    if (getRepeated(enum_msg, 2)) |value_list| {
        for (0..value_list.count) |i| {
            const value_msg_ptr = value_list.get(*Message, @intCast(i)) orelse continue;
            const value_name = getString(value_msg_ptr.*, 1);
            const value_number = getScalar(value_msg_ptr.*, i32, 2) orelse 0;

            try values.append(allocator, .{
                .name = try allocator.dupe(u8, value_name),
                .number = value_number,
            });
        }
    }

    return EnumInfo{
        .name = try allocator.dupe(u8, name),
        .full_name = full_name,
        .values = try values.toOwnedSlice(allocator),
    };
}
