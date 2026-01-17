//! Bootstrap MiniTables for descriptor.proto.
//!
//! Hand-coded MiniTables for FileDescriptorSet, FileDescriptorProto,
//! DescriptorProto, and related types needed to parse binary protobuf descriptors.
//!
//! These tables solve the bootstrap problem: we need descriptor tables to parse
//! descriptors, so we hand-code them here.

const std = @import("std");
const MiniTable = @import("../mini_table.zig").MiniTable;
const MiniTableField = @import("../mini_table.zig").MiniTableField;
const FieldType = @import("../mini_table.zig").FieldType;
const Mode = @import("../mini_table.zig").Mode;
const StringView = @import("../message.zig").StringView;
const RepeatedField = @import("../message.zig").RepeatedField;
const Message = @import("../message.zig").Message;

//
// Descriptor MiniTables (for parsing FileDescriptorSet)
//

// google.protobuf.FieldOptions
// Only includes fields needed for packed encoding.
//
// Layout (explicit, hasbit at offset 0):
//   offset 0: hasbits (1 byte)
//   offset 1: is_packed (1 byte, bool)
//   total size: 2 bytes
pub const FieldOptions_size: u16 = 2;
const FO_is_packed: u16 = 1;

pub const field_options_fields = [_]MiniTableField{
    // Field 2: packed (bool)
    .{
        .number = 2,
        .offset = FO_is_packed,
        .presence = 1, // Hasbit index 0 + 1 (track explicit presence)
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
};

pub const field_options_table = MiniTable{
    .fields = &field_options_fields,
    .submessages = &.{},
    .size = FieldOptions_size,
    .hasbit_bytes = 1, // Track packed presence
    .oneof_count = 0,
    .dense_below = 2,
};

// google.protobuf.FieldDescriptorProto
// Only includes fields needed for building MiniTables.
//
// Layout (explicit, hasbit at offset 0):
//   offset 0: hasbits (1 byte)
//   offset 8: name (StringView, 16 bytes aligned)
//   offset 24: number (i32, 4 bytes)
//   offset 28: label (i32, 4 bytes)
//   offset 32: type (i32, 4 bytes)
//   offset 40: type_name (StringView, 16 bytes)
//   offset 56: options (?*Message, 8 bytes)
//   offset 64: oneof_index (i32, 4 bytes)
//   total size: 72 bytes
pub const FieldDescriptorProto_size: u16 = 72;

// Field offsets for FieldDescriptorProto (explicit layout with hasbit at 0)
const FDP_hasbits: u16 = 0;
const FDP_name: u16 = 8;
const FDP_number: u16 = 24;
const FDP_label: u16 = 28;
const FDP_type: u16 = 32;
const FDP_type_name: u16 = 40;
const FDP_options: u16 = 56;
const FDP_oneof_index: u16 = 64;

// Struct for reading decoded FieldDescriptorProto messages.
// Uses extern to guarantee layout matches explicit offsets above.
pub const FieldDescriptorProto = extern struct {
    hasbits: u8 = 0, // Hasbit byte at offset 0
    _pad0: [7]u8 = .{0} ** 7, // Padding to align name at offset 8
    name: StringView = StringView.empty(), // Field 1 at offset 8
    number: i32 = 0, // Field 3 at offset 24
    label: i32 = 0, // Field 4 at offset 28
    type_: i32 = 0, // Field 5 at offset 32
    _pad1: [4]u8 = .{0} ** 4, // Padding to align type_name at offset 40
    type_name: StringView = StringView.empty(), // Field 6 at offset 40
    options: ?*Message = null, // Field 8 at offset 56
    oneof_index: i32 = 0, // Field 9 at offset 64
    _pad2: [4]u8 = .{0} ** 4, // Padding to size 72

    comptime {
        // Verify layout matches explicit offsets
        if (@offsetOf(FieldDescriptorProto, "hasbits") != FDP_hasbits) @compileError("hasbits offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "name") != FDP_name) @compileError("name offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "number") != FDP_number) @compileError("number offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "label") != FDP_label) @compileError("label offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "type_") != FDP_type) @compileError("type offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "type_name") != FDP_type_name) @compileError("type_name offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "options") != FDP_options) @compileError("options offset mismatch");
        if (@offsetOf(FieldDescriptorProto, "oneof_index") != FDP_oneof_index) @compileError("oneof_index offset mismatch");
        if (@sizeOf(FieldDescriptorProto) != FieldDescriptorProto_size) @compileError("size mismatch");
    }

    /// Check if oneof_index has explicit presence (hasbit set).
    pub fn has_oneof_index(self: *const FieldDescriptorProto) bool {
        return (self.hasbits & 1) != 0;
    }
};

pub const field_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = FDP_name,
        .presence = 0, // Proto3 implicit presence
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 3: number (int32)
    .{
        .number = 3,
        .offset = FDP_number,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 4: label (enum, int32)
    .{
        .number = 4,
        .offset = FDP_label,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 5: type (enum, int32)
    .{
        .number = 5,
        .offset = FDP_type,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 6: type_name (string)
    .{
        .number = 6,
        .offset = FDP_type_name,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 8: options (FieldOptions)
    .{
        .number = 8,
        .offset = FDP_options,
        .presence = 0, // Pointer presence (null check)
        .submsg_index = 0, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 9: oneof_index (int32) - has hasbit
    .{
        .number = 9,
        .offset = FDP_oneof_index,
        .presence = 1, // Hasbit index 0 + 1
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
};

pub const field_descriptor_proto_submessages = [_]*const MiniTable{
    &field_options_table,
};

pub const field_descriptor_proto_table = MiniTable{
    .fields = &field_descriptor_proto_fields,
    .submessages = &field_descriptor_proto_submessages,
    .size = FieldDescriptorProto_size,
    .hasbit_bytes = 1, // Track oneof_index presence
    .oneof_count = 0,
    .dense_below = 6,
};

// google.protobuf.OneofDescriptorProto
pub const OneofDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
};

pub const oneof_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(OneofDescriptorProto, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
};

pub const oneof_descriptor_proto_table = MiniTable{
    .fields = &oneof_descriptor_proto_fields,
    .submessages = &.{},
    .size = @sizeOf(OneofDescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};

// google.protobuf.DescriptorProto
pub const DescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    field: RepeatedField = RepeatedField.empty(0), // Field 2, repeated FieldDescriptorProto
    nested_type: RepeatedField = RepeatedField.empty(0), // Field 3, repeated DescriptorProto
    oneof_decl: RepeatedField = RepeatedField.empty(0), // Field 8, repeated OneofDescriptorProto
};

pub const descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(DescriptorProto, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: field (repeated FieldDescriptorProto)
    .{
        .number = 2,
        .offset = @offsetOf(DescriptorProto, "field"),
        .presence = 0,
        .submsg_index = 0, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
    // Field 3: nested_type (repeated DescriptorProto)
    .{
        .number = 3,
        .offset = @offsetOf(DescriptorProto, "nested_type"),
        .presence = 0,
        .submsg_index = 1, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
    // Field 8: oneof_decl (repeated OneofDescriptorProto)
    .{
        .number = 8,
        .offset = @offsetOf(DescriptorProto, "oneof_decl"),
        .presence = 0,
        .submsg_index = 2, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

// Note: This is a var so we can set up the self-reference for nested_type.
// The submessages array has: [0]=FieldDescriptorProto, [1]=DescriptorProto (self), [2]=OneofDescriptorProto
pub var descriptor_proto_table: MiniTable = .{
    .fields = &descriptor_proto_fields,
    .submessages = &[_]*const MiniTable{
        &field_descriptor_proto_table,
        &descriptor_proto_table, // Self-reference (initialized at runtime on first use)
        &oneof_descriptor_proto_table,
    },
    .size = @sizeOf(DescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 3,
};

// google.protobuf.EnumValueDescriptorProto
pub const EnumValueDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    number: i32 = 0, // Field 2
};

pub const enum_value_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(EnumValueDescriptorProto, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: number (int32)
    .{
        .number = 2,
        .offset = @offsetOf(EnumValueDescriptorProto, "number"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
            },
};

pub const enum_value_descriptor_proto_table = MiniTable{
    .fields = &enum_value_descriptor_proto_fields,
    .submessages = &.{},
    .size = @sizeOf(EnumValueDescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

// google.protobuf.EnumDescriptorProto
pub const EnumDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    value: RepeatedField = RepeatedField.empty(0), // Field 2, repeated EnumValueDescriptorProto
};

pub const enum_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(EnumDescriptorProto, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: value (repeated EnumValueDescriptorProto)
    .{
        .number = 2,
        .offset = @offsetOf(EnumDescriptorProto, "value"),
        .presence = 0,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

pub const enum_descriptor_proto_submessages = [_]*const MiniTable{
    &enum_value_descriptor_proto_table,
};

pub const enum_descriptor_proto_table = MiniTable{
    .fields = &enum_descriptor_proto_fields,
    .submessages = &enum_descriptor_proto_submessages,
    .size = @sizeOf(EnumDescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

// google.protobuf.FileDescriptorProto
pub const FileDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    package: StringView = StringView.empty(), // Field 2
    dependency: RepeatedField = RepeatedField.empty(0), // Field 3, repeated string
    message_type: RepeatedField = RepeatedField.empty(0), // Field 4, repeated DescriptorProto
    enum_type: RepeatedField = RepeatedField.empty(0), // Field 5, repeated EnumDescriptorProto
};

pub const file_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(FileDescriptorProto, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: package (string)
    .{
        .number = 2,
        .offset = @offsetOf(FileDescriptorProto, "package"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 3: dependency (repeated string)
    .{
        .number = 3,
        .offset = @offsetOf(FileDescriptorProto, "dependency"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .repeated,
        .is_packed = false,
            },
    // Field 4: message_type (repeated DescriptorProto)
    .{
        .number = 4,
        .offset = @offsetOf(FileDescriptorProto, "message_type"),
        .presence = 0,
        .submsg_index = 0, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
    // Field 5: enum_type (repeated EnumDescriptorProto)
    .{
        .number = 5,
        .offset = @offsetOf(FileDescriptorProto, "enum_type"),
        .presence = 0,
        .submsg_index = 1, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

pub const file_descriptor_proto_submessages = [_]*const MiniTable{
    &descriptor_proto_table,
    &enum_descriptor_proto_table,
};

pub const file_descriptor_proto_table = MiniTable{
    .fields = &file_descriptor_proto_fields,
    .submessages = &file_descriptor_proto_submessages,
    .size = @sizeOf(FileDescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 5,
};

// google.protobuf.FileDescriptorSet
pub const FileDescriptorSet = struct {
    file: RepeatedField = RepeatedField.empty(0), // Field 1, repeated FileDescriptorProto
};

pub const file_descriptor_set_fields = [_]MiniTableField{
    // Field 1: file (repeated FileDescriptorProto)
    .{
        .number = 1,
        .offset = @offsetOf(FileDescriptorSet, "file"),
        .presence = 0,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

pub const file_descriptor_set_submessages = [_]*const MiniTable{
    &file_descriptor_proto_table,
};

pub const file_descriptor_set_table = MiniTable{
    .fields = &file_descriptor_set_fields,
    .submessages = &file_descriptor_set_submessages,
    .size = @sizeOf(FileDescriptorSet),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};

//
// Plugin Protocol MiniTables (for protoc plugin)
//

// google.protobuf.compiler.CodeGeneratorRequest
pub const CodeGeneratorRequest = struct {
    file_to_generate: RepeatedField = RepeatedField.empty(0), // Field 1, repeated string
    parameter: StringView = StringView.empty(), // Field 2
    proto_file: RepeatedField = RepeatedField.empty(0), // Field 15, repeated FileDescriptorProto
};

pub const code_generator_request_fields = [_]MiniTableField{
    // Field 1: file_to_generate (repeated string)
    .{
        .number = 1,
        .offset = @offsetOf(CodeGeneratorRequest, "file_to_generate"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .repeated,
        .is_packed = false,
            },
    // Field 2: parameter (string)
    .{
        .number = 2,
        .offset = @offsetOf(CodeGeneratorRequest, "parameter"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 15: proto_file (repeated FileDescriptorProto)
    .{
        .number = 15,
        .offset = @offsetOf(CodeGeneratorRequest, "proto_file"),
        .presence = 0,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

pub const code_generator_request_submessages = [_]*const MiniTable{
    &file_descriptor_proto_table,
};

pub const code_generator_request_table = MiniTable{
    .fields = &code_generator_request_fields,
    .submessages = &code_generator_request_submessages,
    .size = @sizeOf(CodeGeneratorRequest),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 2,
};

// google.protobuf.compiler.CodeGeneratorResponse.File
pub const CodeGeneratorResponseFile = struct {
    name: StringView = StringView.empty(), // Field 1
    content: StringView = StringView.empty(), // Field 15
};

pub const code_generator_response_file_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(CodeGeneratorResponseFile, "name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 15: content (string)
    .{
        .number = 15,
        .offset = @offsetOf(CodeGeneratorResponseFile, "content"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
};

pub const code_generator_response_file_table = MiniTable{
    .fields = &code_generator_response_file_fields,
    .submessages = &.{},
    .size = @sizeOf(CodeGeneratorResponseFile),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};

// google.protobuf.compiler.CodeGeneratorResponse
pub const CodeGeneratorResponse = struct {
    error_message: StringView = StringView.empty(), // Field 1
    file: RepeatedField = RepeatedField.empty(0), // Field 15, repeated File
};

pub const code_generator_response_fields = [_]MiniTableField{
    // Field 1: error (string)
    .{
        .number = 1,
        .offset = @offsetOf(CodeGeneratorResponse, "error_message"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 15: file (repeated File)
    .{
        .number = 15,
        .offset = @offsetOf(CodeGeneratorResponse, "file"),
        .presence = 0,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
            },
};

pub const code_generator_response_submessages = [_]*const MiniTable{
    &code_generator_response_file_table,
};

pub const code_generator_response_table = MiniTable{
    .fields = &code_generator_response_fields,
    .submessages = &code_generator_response_submessages,
    .size = @sizeOf(CodeGeneratorResponse),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};
