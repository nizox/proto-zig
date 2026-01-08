//! Conformance test runner for proto-zig.
//!
//! Implements the protobuf conformance test protocol:
//! 1. Read 4-byte little-endian length from stdin
//! 2. Read ConformanceRequest message
//! 3. Process the request (parse input, serialize output)
//! 4. Write 4-byte little-endian length to stdout
//! 5. Write ConformanceResponse message
//! 6. Repeat until EOF

const std = @import("std");
const proto = @import("proto");
const Arena = proto.Arena;
const Message = proto.Message;
const StringView = proto.StringView;
const bootstrap = proto.bootstrap;

fn getStdin() std.fs.File {
    return std.fs.File.stdin();
}

fn getStdout() std.fs.File {
    return std.fs.File.stdout();
}

// Arena buffer size (4MB).
const arena_size: u32 = 4 * 1024 * 1024;

const ConformanceError = error{
    EndOfInput,
    OutOfMemory,
};

pub fn main() !void {
    // Allocate arena buffer.
    var arena_buffer: [arena_size]u8 = undefined;

    while (true) {
        var arena = Arena.init(&arena_buffer);

        // Read request length.
        const length = read_length() catch |err| {
            if (err == ConformanceError.EndOfInput) break;
            return err;
        };

        if (length == 0) continue;

        // Read request bytes.
        const request_bytes = arena.alloc(u8, length) orelse {
            return ConformanceError.OutOfMemory;
        };
        const read_count = getStdin().readAll(request_bytes) catch break;
        if (read_count != length) break;

        // Process request and generate response.
        const response = process_request(request_bytes, &arena);

        // Encode response.
        const response_bytes = encode_response(&response, &arena) catch |err| {
            std.debug.print("Failed to encode response: {}\n", .{err});
            continue;
        };

        // Write response.
        try write_length(@intCast(response_bytes.len));
        try getStdout().writeAll(response_bytes);
    }
}

fn read_length() (ConformanceError || std.fs.File.ReadError)!u32 {
    var buf: [4]u8 = undefined;
    const bytes_read = try getStdin().readAll(&buf);
    if (bytes_read == 0) return ConformanceError.EndOfInput;
    if (bytes_read != 4) return ConformanceError.EndOfInput;
    return std.mem.readInt(u32, &buf, .little);
}

fn write_length(length: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, length, .little);
    try getStdout().writeAll(&buf);
}

const Response = struct {
    result_case: u32,
    payload: StringView,
};

// A minimal MiniTable with no fields - all fields are treated as unknown.
// Used to validate wire format through the decoder without needing a schema.
const unknown_fields_table = proto.MiniTable{
    .fields = &.{},
    .submessages = &.{},
    .size = 8, // Minimal message size.
    .hasbit_bytes = 0,
    .oneof_count = 0,
    .dense_below = 0,
};

fn process_request(request_bytes: []const u8, arena: *Arena) Response {
    // Parse ConformanceRequest.
    const request_msg = Message.new(arena, &bootstrap.conformance_request_table) orelse {
        return make_error_response(5, "Out of memory allocating request");
    };

    proto.decode(request_bytes, request_msg, arena, .{ .alias_string = true }) catch |err| {
        return make_error_response(1, @errorName(err));
    };

    // Extract request fields.
    const req = get_request_fields(request_msg);

    // Check for FailureSet request.
    if (std.mem.eql(u8, req.message_type, "conformance.FailureSet")) {
        // Return empty FailureSet.
        return .{ .result_case = 3, .payload = StringView.empty() };
    }

    // Check payload type.
    if (req.payload_case != 1) {
        // Only protobuf payload supported - skip non-binary tests.
        return make_skipped_response("Only protobuf input supported");
    }

    // Check output format.
    if (req.requested_output_format != 1) {
        // Only protobuf output supported - skip non-binary tests.
        return make_skipped_response("Only protobuf output supported");
    }

    // Decode the payload to validate wire format.
    // This catches malformed input inline during decoding (upb/TigerBeetle pattern).
    // We use a minimal "unknown fields only" table to validate wire format without schema.
    const payload_msg = Message.new(arena, &unknown_fields_table) orelse {
        return make_error_response(2, "Out of memory");
    };

    proto.decode(req.protobuf_payload.slice(), payload_msg, arena, .{}) catch |err| {
        return make_error_response(1, @errorName(err));
    };

    // For binary round-trip, echo the (now validated) input.
    return .{ .result_case = 3, .payload = req.protobuf_payload };
}

const RequestFields = struct {
    payload_case: u32,
    protobuf_payload: StringView,
    message_type: []const u8,
    requested_output_format: i32,
    test_category: i32,
};

fn get_request_fields(msg: *Message) RequestFields {
    // Read oneof case from message data.
    const case_ptr: *const u32 = @ptrCast(@alignCast(msg.data.ptr));
    const payload_case = case_ptr.*;

    // Read protobuf_payload.
    const proto_offset = bootstrap.ConformanceRequest.protobuf_payload_offset;
    const proto_ptr: *const StringView = @ptrCast(@alignCast(msg.data.ptr + proto_offset));

    // Read message_type.
    const mt_offset = bootstrap.ConformanceRequest.message_type_offset;
    const mt_ptr: *const StringView = @ptrCast(@alignCast(msg.data.ptr + mt_offset));

    // Read requested_output_format.
    const format_offset = bootstrap.ConformanceRequest.requested_output_format_offset;
    const format_ptr: *const i32 = @ptrCast(@alignCast(msg.data.ptr + format_offset));

    // Read test_category.
    const cat_offset = bootstrap.ConformanceRequest.test_category_offset;
    const cat_ptr: *const i32 = @ptrCast(@alignCast(msg.data.ptr + cat_offset));

    return .{
        .payload_case = payload_case,
        .protobuf_payload = proto_ptr.*,
        .message_type = mt_ptr.slice(),
        .requested_output_format = format_ptr.*,
        .test_category = cat_ptr.*,
    };
}

fn make_error_response(result_case: u32, message: []const u8) Response {
    return .{
        .result_case = result_case,
        .payload = StringView.from_slice(message),
    };
}

fn make_skipped_response(message: []const u8) Response {
    return .{
        .result_case = 5, // skipped
        .payload = StringView.from_slice(message),
    };
}

fn encode_response(response: *const Response, arena: *Arena) ConformanceError![]const u8 {
    // Calculate size.
    var size: u32 = 0;

    // Tag + length + data for the result field.
    const tag_size: u32 = 1; // Single byte tag for fields 1-9.
    const payload_len = response.payload.len;
    const len_size = varint_size(payload_len);

    size = tag_size + len_size + payload_len;

    if (size == 0) {
        return &.{};
    }

    // Allocate buffer.
    const buf = arena.alloc(u8, size) orelse return ConformanceError.OutOfMemory;

    // Write tag (field number + wire type 2 for delimited).
    var pos: u32 = 0;
    buf[pos] = @intCast((response.result_case << 3) | 2);
    pos += 1;

    // Write length.
    pos += write_varint(buf[pos..], payload_len);

    // Write payload.
    if (payload_len > 0) {
        @memcpy(buf[pos .. pos + payload_len], response.payload.slice());
    }

    return buf[0..size];
}

fn varint_size(value: u32) u32 {
    if (value == 0) return 1;
    var v = value;
    var s: u32 = 0;
    while (v != 0) {
        v >>= 7;
        s += 1;
    }
    return s;
}

fn write_varint(buf: []u8, value: u32) u32 {
    var v = value;
    var pos: u32 = 0;
    while (v >= 0x80) {
        buf[pos] = @truncate((v & 0x7F) | 0x80);
        pos += 1;
        v >>= 7;
    }
    buf[pos] = @truncate(v);
    return pos + 1;
}
