//! MiniTables for conformance testing.
//!
//! Hand-coded MiniTables for ConformanceRequest, ConformanceResponse, and
//! related types needed to run conformance tests.

const std = @import("std");
const proto = @import("proto");
const MiniTable = proto.MiniTable;
const MiniTableField = proto.MiniTableField;
const FieldType = proto.FieldType;
const Mode = proto.Mode;
const StringView = proto.StringView;
const RepeatedField = proto.RepeatedField;
const Message = proto.Message;

// Wire format enum values.
pub const WireFormat = enum(i32) {
    UNSPECIFIED = 0,
    PROTOBUF = 1,
    JSON = 2,
    JSPB = 3,
    TEXT_FORMAT = 4,
};

// Test category enum values.
pub const TestCategory = enum(i32) {
    UNSPECIFIED_TEST = 0,
    BINARY_TEST = 1,
    JSON_TEST = 2,
    JSON_IGNORE_UNKNOWN_PARSING_TEST = 3,
    JSPB_TEST = 4,
    TEXT_FORMAT_TEST = 5,
};

// ConformanceRequest message layout.
// Using extern struct to guarantee field ordering matches our expectations.
pub const ConformanceRequest = extern struct {
    // Oneof payload case (0 = none, 1 = protobuf, 2 = json, 7 = jspb, 8 = text).
    payload_case: u32 = 0,
    // Padding for alignment.
    _pad0: u32 = 0,
    // Payload union (only one is valid based on payload_case).
    protobuf_payload: StringView = StringView.empty(), // Field 1.
    json_payload: StringView = StringView.empty(), // Field 2.
    jspb_payload: StringView = StringView.empty(), // Field 7.
    text_payload: StringView = StringView.empty(), // Field 8.
    // Other fields.
    requested_output_format: i32 = 0, // Field 3, enum WireFormat.
    test_category: i32 = 0, // Field 5, enum TestCategory.
    message_type: StringView = StringView.empty(), // Field 4.
    print_unknown_fields: bool = false, // Field 9.

    pub const payload_case_offset = @offsetOf(ConformanceRequest, "payload_case");
    pub const protobuf_payload_offset = @offsetOf(ConformanceRequest, "protobuf_payload");
    pub const json_payload_offset = @offsetOf(ConformanceRequest, "json_payload");
    pub const jspb_payload_offset = @offsetOf(ConformanceRequest, "jspb_payload");
    pub const text_payload_offset = @offsetOf(ConformanceRequest, "text_payload");
    pub const requested_output_format_offset = @offsetOf(ConformanceRequest, "requested_output_format");
    pub const test_category_offset = @offsetOf(ConformanceRequest, "test_category");
    pub const message_type_offset = @offsetOf(ConformanceRequest, "message_type");
    pub const print_unknown_fields_offset = @offsetOf(ConformanceRequest, "print_unknown_fields");
};

// ConformanceResponse message layout.
pub const ConformanceResponse = struct {
    // Oneof result case.
    result_case: u32 = 0,
    _pad0: u32 = 0,
    // Result union fields.
    parse_error: StringView = StringView.empty(), // Field 1.
    runtime_error: StringView = StringView.empty(), // Field 2.
    protobuf_payload: StringView = StringView.empty(), // Field 3.
    json_payload: StringView = StringView.empty(), // Field 4.
    skipped: StringView = StringView.empty(), // Field 5.
    serialize_error: StringView = StringView.empty(), // Field 6.
    jspb_payload: StringView = StringView.empty(), // Field 7.
    text_payload: StringView = StringView.empty(), // Field 8.
    timeout_error: StringView = StringView.empty(), // Field 9.

    pub const result_case_offset = @offsetOf(ConformanceResponse, "result_case");
};

// MiniTable for ConformanceRequest.
pub const conformance_request_fields = [_]MiniTableField{
    // Field 1: protobuf_payload (bytes), oneof payload.
    .{
        .number = 1,
        .offset = ConformanceRequest.protobuf_payload_offset,
        .presence = -1, // Oneof index 0.
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: json_payload (string), oneof payload.
    .{
        .number = 2,
        .offset = ConformanceRequest.json_payload_offset,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 3: requested_output_format (enum).
    .{
        .number = 3,
        .offset = ConformanceRequest.requested_output_format_offset,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 4: message_type (string).
    .{
        .number = 4,
        .offset = ConformanceRequest.message_type_offset,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 5: test_category (enum).
    .{
        .number = 5,
        .offset = ConformanceRequest.test_category_offset,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 7: jspb_payload (string), oneof payload.
    .{
        .number = 7,
        .offset = ConformanceRequest.jspb_payload_offset,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 8: text_payload (string), oneof payload.
    .{
        .number = 8,
        .offset = ConformanceRequest.text_payload_offset,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 9: print_unknown_fields (bool).
    .{
        .number = 9,
        .offset = ConformanceRequest.print_unknown_fields_offset,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
};

pub const conformance_request_table = MiniTable{
    .fields = &conformance_request_fields,
    .submessages = &.{},
    .size = @sizeOf(ConformanceRequest),
    .hasbit_bytes = 0,
    .oneof_count = 1,
    .dense_below = 5,
};

// MiniTable for ConformanceResponse.
pub const conformance_response_fields = [_]MiniTableField{
    // Field 1: parse_error (string), oneof result.
    .{
        .number = 1,
        .offset = @offsetOf(ConformanceResponse, "parse_error"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 2: runtime_error (string), oneof result.
    .{
        .number = 2,
        .offset = @offsetOf(ConformanceResponse, "runtime_error"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 3: protobuf_payload (bytes), oneof result.
    .{
        .number = 3,
        .offset = @offsetOf(ConformanceResponse, "protobuf_payload"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 4: json_payload (string), oneof result.
    .{
        .number = 4,
        .offset = @offsetOf(ConformanceResponse, "json_payload"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 5: skipped (string), oneof result.
    .{
        .number = 5,
        .offset = @offsetOf(ConformanceResponse, "skipped"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 6: serialize_error (string), oneof result.
    .{
        .number = 6,
        .offset = @offsetOf(ConformanceResponse, "serialize_error"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 7: jspb_payload (string), oneof result.
    .{
        .number = 7,
        .offset = @offsetOf(ConformanceResponse, "jspb_payload"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 8: text_payload (string), oneof result.
    .{
        .number = 8,
        .offset = @offsetOf(ConformanceResponse, "text_payload"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
    // Field 9: timeout_error (string), oneof result.
    .{
        .number = 9,
        .offset = @offsetOf(ConformanceResponse, "timeout_error"),
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
            },
};

pub const conformance_response_table = MiniTable{
    .fields = &conformance_response_fields,
    .submessages = &.{},
    .size = @sizeOf(ConformanceResponse),
    .hasbit_bytes = 0,
    .oneof_count = 1,
    .dense_below = 6,
};

// ============================================================================
// TestAllTypesProto3 - Minimal schema for conformance test validation
// ============================================================================
//
// This is a minimal hand-coded schema containing only the fields needed to
// validate failing conformance tests:
// - Field 18: optional_nested_message (for submessage/group validation tests)
// - Fields 31-42: repeated scalar fields (packed in proto3, for EOF validation)

// NestedMessage for field 18
const nested_message_fields = [_]MiniTableField{
    // Field 1: a (int32)
    .{
        .number = 1,
        .offset = 0,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
};

pub const nested_message_table = MiniTable{
    .fields = &nested_message_fields,
    .submessages = &.{},
    .size = 4,
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 1,
};

// TestAllTypesProto3 fields for canonical encoding conformance tests.
// Fields must be sorted by field number. Layout:
//   Offset 0-3: oneof_case (4 bytes)
//   Offset 4-7: padding
//   Offset 8-15: optional_nested_message (field 18)
//   Offset 16-327: packed repeated fields 31-43 (13 × 24 = 312 bytes)
//   Offset 328-423: repeated string/bytes/message/enum fields 44, 45, 48, 51 (4 × 24 = 96 bytes)
//   Offset 424-759: unpacked repeated fields 89-102 (14 × 24 = 336 bytes)
//   Offset 760-871: scalar fields (112 bytes)
//   Offset 872-887: oneof storage (fields 111-119, 16 bytes)
const test_all_types_proto3_fields = [_]MiniTableField{
    // Field 1: optional_int32
    .{
        .number = 1,
        .offset = 840,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 2: optional_int64
    .{
        .number = 2,
        .offset = 760,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 3: optional_uint32
    .{
        .number = 3,
        .offset = 844,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 4: optional_uint64
    .{
        .number = 4,
        .offset = 768,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 5: optional_sint32
    .{
        .number = 5,
        .offset = 848,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 6: optional_sint64
    .{
        .number = 6,
        .offset = 776,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 7: optional_fixed32
    .{
        .number = 7,
        .offset = 852,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 8: optional_fixed64
    .{
        .number = 8,
        .offset = 784,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 9: optional_sfixed32
    .{
        .number = 9,
        .offset = 856,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 10: optional_sfixed64
    .{
        .number = 10,
        .offset = 792,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 11: optional_float
    .{
        .number = 11,
        .offset = 860,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 12: optional_double
    .{
        .number = 12,
        .offset = 800,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 13: optional_bool
    .{
        .number = 13,
        .offset = 868,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 14: optional_string
    .{
        .number = 14,
        .offset = 808,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 15: optional_bytes
    .{
        .number = 15,
        .offset = 824,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 18: optional_nested_message
    .{
        .number = 18,
        .offset = 8,
        .presence = 0,
        .submsg_index = 0, // Index into submessages array
        .field_type = .TYPE_MESSAGE,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 21: optional_nested_enum
    .{
        .number = 21,
        .offset = 864,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 31: repeated_int32 (packed in proto3)
    .{
        .number = 31,
        .offset = 16,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 32: repeated_int64 (packed in proto3)
    .{
        .number = 32,
        .offset = 40,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT64,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 33: repeated_uint32 (packed in proto3)
    .{
        .number = 33,
        .offset = 64,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT32,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 34: repeated_uint64 (packed in proto3)
    .{
        .number = 34,
        .offset = 88,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 35: repeated_sint32 (packed in proto3)
    .{
        .number = 35,
        .offset = 112,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT32,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 36: repeated_sint64 (packed in proto3)
    .{
        .number = 36,
        .offset = 136,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT64,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 37: repeated_fixed32 (packed in proto3)
    .{
        .number = 37,
        .offset = 160,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED32,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 38: repeated_fixed64 (packed in proto3)
    .{
        .number = 38,
        .offset = 184,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED64,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 39: repeated_sfixed32 (packed in proto3)
    .{
        .number = 39,
        .offset = 208,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED32,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 40: repeated_sfixed64 (packed in proto3)
    .{
        .number = 40,
        .offset = 232,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED64,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 41: repeated_float (packed in proto3)
    .{
        .number = 41,
        .offset = 256,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 42: repeated_double (packed in proto3)
    .{
        .number = 42,
        .offset = 280,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 43: repeated_bool (packed in proto3)
    .{
        .number = 43,
        .offset = 304,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .repeated,
        .is_packed = true,
    },
    // Field 44: repeated_string (not packable)
    .{
        .number = 44,
        .offset = 328,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 45: repeated_bytes (not packable)
    .{
        .number = 45,
        .offset = 352,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 48: repeated_nested_message (not packable)
    .{
        .number = 48,
        .offset = 376,
        .presence = 0,
        .submsg_index = 0, // Uses nested_message_table
        .field_type = .TYPE_MESSAGE,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 51: repeated_nested_enum (packed in proto3)
    .{
        .number = 51,
        .offset = 400,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .repeated,
        .is_packed = true,
    },
    // Fields 89-102: unpacked repeated fields ([packed = false])
    // Start at offset 424 (after fields 44, 45, 48, 51)
    // Field 89: unpacked_int32
    .{
        .number = 89,
        .offset = 424,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT32,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 90: unpacked_int64
    .{
        .number = 90,
        .offset = 448,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_INT64,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 91: unpacked_uint32
    .{
        .number = 91,
        .offset = 472,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT32,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 92: unpacked_uint64
    .{
        .number = 92,
        .offset = 496,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 93: unpacked_sint32
    .{
        .number = 93,
        .offset = 520,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT32,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 94: unpacked_sint64
    .{
        .number = 94,
        .offset = 544,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SINT64,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 95: unpacked_fixed32
    .{
        .number = 95,
        .offset = 568,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED32,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 96: unpacked_fixed64
    .{
        .number = 96,
        .offset = 592,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FIXED64,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 97: unpacked_sfixed32
    .{
        .number = 97,
        .offset = 616,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED32,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 98: unpacked_sfixed64
    .{
        .number = 98,
        .offset = 640,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_SFIXED64,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 99: unpacked_float
    .{
        .number = 99,
        .offset = 664,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 100: unpacked_double
    .{
        .number = 100,
        .offset = 688,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 101: unpacked_bool
    .{
        .number = 101,
        .offset = 712,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .repeated,
        .is_packed = false,
    },
    // Field 102: unpacked_nested_enum
    .{
        .number = 102,
        .offset = 736,
        .presence = 0,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .repeated,
        .is_packed = false,
    },
    // Oneof fields 111-119 share storage at offset 872
    // presence = -1 means oneof_index 0
    // Field 111: oneof_uint32
    .{
        .number = 111,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT32,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 112: oneof_nested_message
    .{
        .number = 112,
        .offset = 872,
        .presence = -1,
        .submsg_index = 0,
        .field_type = .TYPE_MESSAGE,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 113: oneof_string
    .{
        .number = 113,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_STRING,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 114: oneof_bytes
    .{
        .number = 114,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BYTES,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 115: oneof_bool
    .{
        .number = 115,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_BOOL,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 116: oneof_uint64
    .{
        .number = 116,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_UINT64,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 117: oneof_float
    .{
        .number = 117,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_FLOAT,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 118: oneof_double
    .{
        .number = 118,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_DOUBLE,
        .mode = .scalar,
        .is_packed = false,
    },
    // Field 119: oneof_enum
    .{
        .number = 119,
        .offset = 872,
        .presence = -1,
        .submsg_index = MiniTableField.max_submsg_index,
        .field_type = .TYPE_ENUM,
        .mode = .scalar,
        .is_packed = false,
    },
};

const test_all_types_proto3_submessages = [_]*const MiniTable{
    &nested_message_table,
};

pub const test_all_types_proto3_table = MiniTable{
    .fields = &test_all_types_proto3_fields,
    .submessages = &test_all_types_proto3_submessages,
    .size = 888, // oneof_case(4) + pad(4) + msg(8) + packed(312) + string/bytes/msg(96) + unpacked(336) + scalars(112) + oneof(16)
    .hasbit_bytes = 0,
    .oneof_count = 1,
    .dense_below = 0, // Use binary search, not dense lookup
};

// ============================================================================
// TestAllTypesProto2 - Minimal schema for conformance test validation
// ============================================================================
// Proto2 has the same structure as proto3 for the fields we care about

pub const test_all_types_proto2_table = MiniTable{
    .fields = &test_all_types_proto3_fields,
    .submessages = &test_all_types_proto3_submessages,
    .size = 888,
    .hasbit_bytes = 0,
    .oneof_count = 1,
    .dense_below = 0, // Use binary search, not dense lookup
};
