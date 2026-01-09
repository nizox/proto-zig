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

// google.protobuf.FieldDescriptorProto
// Only includes fields needed for building MiniTables.
pub const FieldDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    number: i32 = 0, // Field 3
    label: i32 = 0, // Field 4 (enum Label)
    type: i32 = 0, // Field 5 (enum Type)
    type_name: StringView = StringView.empty(), // Field 6
    oneof_index: i32 = 0, // Field 9
};

pub const field_descriptor_proto_fields = [_]MiniTableField{
    // Field 1: name (string)
    .{
        .number = 1,
        .offset = @offsetOf(FieldDescriptorProto, "name"),
        .presence = 0, // Proto3 implicit presence
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
    // Field 3: number (int32)
    .{
        .number = 3,
        .offset = @offsetOf(FieldDescriptorProto, "number"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
    // Field 4: label (enum, int32)
    .{
        .number = 4,
        .offset = @offsetOf(FieldDescriptorProto, "label"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
    // Field 5: type (enum, int32)
    .{
        .number = 5,
        .offset = @offsetOf(FieldDescriptorProto, "type"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
    // Field 6: type_name (string)
    .{
        .number = 6,
        .offset = @offsetOf(FieldDescriptorProto, "type_name"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
    // Field 9: oneof_index (int32)
    .{
        .number = 9,
        .offset = @offsetOf(FieldDescriptorProto, "oneof_index"),
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
        .is_oneof = false,
    },
};

pub const field_descriptor_proto_table = MiniTable{
    .fields = &field_descriptor_proto_fields,
    .submessages = &.{},
    .size = @sizeOf(FieldDescriptorProto),
    .hasbit_bytes = 0,
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
        .is_oneof = false,
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
    field: ?*RepeatedField = null, // Field 2, repeated FieldDescriptorProto
    nested_type: ?*RepeatedField = null, // Field 3, repeated DescriptorProto
    oneof_decl: ?*RepeatedField = null, // Field 8, repeated OneofDescriptorProto
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
        .is_oneof = false,
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
        .is_oneof = false,
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
        .is_oneof = false,
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
        .is_oneof = false,
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

// google.protobuf.FileDescriptorProto
pub const FileDescriptorProto = struct {
    name: StringView = StringView.empty(), // Field 1
    package: StringView = StringView.empty(), // Field 2
    message_type: ?*RepeatedField = null, // Field 4, repeated DescriptorProto
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
        .is_oneof = false,
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
        .is_oneof = false,
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
        .is_oneof = false,
    },
};

pub const file_descriptor_proto_submessages = [_]*const MiniTable{
    &descriptor_proto_table,
};

pub const file_descriptor_proto_table = MiniTable{
    .fields = &file_descriptor_proto_fields,
    .submessages = &file_descriptor_proto_submessages,
    .size = @sizeOf(FileDescriptorProto),
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 4,
};

// google.protobuf.FileDescriptorSet
pub const FileDescriptorSet = struct {
    file: ?*RepeatedField = null, // Field 1, repeated FileDescriptorProto
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
        .is_oneof = false,
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
