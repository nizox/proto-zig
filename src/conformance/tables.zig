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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
        .is_oneof = true,
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
