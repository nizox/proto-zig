//! Low-level wire format reading primitives.
//!
//! These functions read protobuf wire format values from byte slices.
//! All functions are non-allocating and return the number of bytes consumed.

const std = @import("std");
const assert = std.debug.assert;
const types = @import("types.zig");
const Tag = types.Tag;
const WireType = types.WireType;

/// Result of a read operation.
pub fn ReadResult(comptime T: type) type {
    return struct {
        value: T,
        consumed: usize,
    };
}

/// Errors that can occur during wire format reading.
pub const ReadError = error{
    /// Input is truncated, more bytes expected.
    EndOfStream,

    /// Varint is too long (more than 10 bytes).
    VarintOverflow,

    /// Invalid wire format data.
    Malformed,
};

/// Read a varint from the input.
///
/// Varints use 7 bits per byte with the MSB as a continuation flag.
/// A varint can be at most 10 bytes long (for 64-bit values).
pub fn read_varint(bytes: []const u8) ReadError!ReadResult(u64) {
    if (bytes.len == 0) {
        return error.EndOfStream;
    }

    // Fast path: single byte varint (values 0-127).
    if (bytes[0] < 0x80) {
        return .{ .value = bytes[0], .consumed = 1 };
    }

    return read_varint_slow(bytes);
}

fn read_varint_slow(bytes: []const u8) ReadError!ReadResult(u64) {
    var value: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;

    // Varint is at most 10 bytes for 64-bit values.
    const max_bytes: usize = 10;

    while (i < max_bytes) {
        if (i >= bytes.len) {
            return error.EndOfStream;
        }

        const byte = bytes[i];
        const payload: u64 = @intCast(byte & 0x7F);

        // Check for overflow on last byte.
        if (i == 9 and byte > 0x01) {
            return error.VarintOverflow;
        }

        value |= payload << shift;
        i += 1;

        // MSB clear means this is the last byte.
        if (byte < 0x80) {
            return .{ .value = value, .consumed = i };
        }

        shift += 7;
    }

    return error.VarintOverflow;
}

/// Read a tag (field number + wire type) from the input.
///
/// Tags must fit in 32 bits and be encoded in at most 5 varint bytes.
/// Tags encoded with more than 5 bytes are rejected as overlong.
pub fn read_tag(bytes: []const u8) ReadError!ReadResult(Tag) {
    if (bytes.len == 0) {
        return error.EndOfStream;
    }

    // Fast path: single byte varint (values 0-127).
    if (bytes[0] < 0x80) {
        const tag = Tag.from_raw(bytes[0]);
        return .{ .value = tag, .consumed = 1 };
    }

    return read_tag_slow(bytes);
}

fn read_tag_slow(bytes: []const u8) ReadError!ReadResult(Tag) {
    var value: u32 = 0;
    var shift: u5 = 0;
    var i: usize = 0;

    // Tags are at most 5 bytes for 32-bit values.
    const max_tag_bytes: usize = 5;

    while (i < max_tag_bytes) {
        if (i >= bytes.len) {
            return error.EndOfStream;
        }

        const byte = bytes[i];
        const payload: u32 = @intCast(byte & 0x7F);

        // Check for overflow on 5th byte (can only contribute 4 bits: 4*7 = 28, need 32 total).
        if (i == 4 and byte > 0x0F) {
            return error.VarintOverflow;
        }

        value |= payload << shift;
        i += 1;

        // MSB clear means this is the last byte.
        if (byte < 0x80) {
            const tag = Tag.from_raw(value);
            return .{ .value = tag, .consumed = i };
        }

        shift += 7;
    }

    // Tag required more than 5 bytes - overlong encoding.
    return error.VarintOverflow;
}

/// Read a fixed 32-bit value (little-endian).
pub fn read_fixed32(bytes: []const u8) ReadError!ReadResult(u32) {
    if (bytes.len < 4) {
        return error.EndOfStream;
    }

    const value = std.mem.readInt(u32, bytes[0..4], .little);
    return .{ .value = value, .consumed = 4 };
}

/// Read a fixed 64-bit value (little-endian).
pub fn read_fixed64(bytes: []const u8) ReadError!ReadResult(u64) {
    if (bytes.len < 8) {
        return error.EndOfStream;
    }

    const value = std.mem.readInt(u64, bytes[0..8], .little);
    return .{ .value = value, .consumed = 8 };
}

/// Read a float (IEEE 754 single precision).
pub fn read_float(bytes: []const u8) ReadError!ReadResult(f32) {
    const result = try read_fixed32(bytes);
    return .{ .value = @bitCast(result.value), .consumed = result.consumed };
}

/// Read a double (IEEE 754 double precision).
pub fn read_double(bytes: []const u8) ReadError!ReadResult(f64) {
    const result = try read_fixed64(bytes);
    return .{ .value = @bitCast(result.value), .consumed = result.consumed };
}

/// Read a length-delimited field (string, bytes, embedded message).
///
/// Returns a slice of the input pointing to the field data.
pub fn read_length_delimited(bytes: []const u8) ReadError!ReadResult([]const u8) {
    const len_result = try read_varint(bytes);

    // Check that length doesn't overflow when added to data_start.
    if (len_result.value > bytes.len -| len_result.consumed) {
        return error.EndOfStream;
    }

    const length: usize = @intCast(len_result.value);
    const data_start = len_result.consumed;
    const data_end = data_start + length;

    const data = bytes[data_start..data_end];
    return .{ .value = data, .consumed = data_end };
}

/// Decode a ZigZag-encoded signed 32-bit integer.
pub fn zigzag_decode_32(value: u32) i32 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

/// Decode a ZigZag-encoded signed 64-bit integer.
pub fn zigzag_decode_64(value: u64) i64 {
    return @bitCast((value >> 1) ^ (0 -% (value & 1)));
}

/// Skip a field based on its wire type.
///
/// Returns the number of bytes to skip.
pub fn skip_field(bytes: []const u8, wire_type: WireType) ReadError!usize {
    switch (wire_type) {
        .varint => {
            const result = try read_varint(bytes);
            return result.consumed;
        },
        .fixed64 => {
            if (bytes.len < 8) return error.EndOfStream;
            return 8;
        },
        .delimited => {
            const result = try read_length_delimited(bytes);
            return result.consumed;
        },
        .fixed32 => {
            if (bytes.len < 4) return error.EndOfStream;
            return 4;
        },
        .start_group, .end_group => {
            // Groups are deprecated and not supported.
            return error.Malformed;
        },
        _ => return error.Malformed,
    }
}

// Tests.

test "read_varint: single byte" {
    const result = try read_varint(&.{0x00});
    assert(result.value == 0);
    assert(result.consumed == 1);

    const result2 = try read_varint(&.{0x01});
    assert(result2.value == 1);
    assert(result2.consumed == 1);

    const result3 = try read_varint(&.{0x7F});
    assert(result3.value == 127);
    assert(result3.consumed == 1);
}

test "read_varint: multi-byte" {
    // 300 = 0xAC 0x02.
    const result = try read_varint(&.{ 0xAC, 0x02 });
    assert(result.value == 300);
    assert(result.consumed == 2);

    // Example from protobuf docs: 150 = 0x96 0x01.
    const result2 = try read_varint(&.{ 0x96, 0x01 });
    assert(result2.value == 150);
    assert(result2.consumed == 2);
}

test "read_varint: max 64-bit" {
    // Max u64 = 0xFFFFFFFFFFFFFFFF.
    const max_bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    const result = try read_varint(&max_bytes);
    assert(result.value == std.math.maxInt(u64));
    assert(result.consumed == 10);
}

test "read_varint: overflow" {
    // Invalid: 10th byte has high bits set.
    const bad_bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02 };
    const result = read_varint(&bad_bytes);
    assert(result == error.VarintOverflow);
}

test "read_varint: truncated" {
    // Truncated: continuation bit set but no more bytes.
    const result = read_varint(&.{0x80});
    assert(result == error.EndOfStream);
}

test "read_tag: field 1 varint" {
    const result = try read_tag(&.{0x08});
    assert(result.value.field_number == 1);
    assert(result.value.wire_type == .varint);
}

test "read_tag: multi-byte" {
    // Field 150, varint (example from protobuf docs).
    // Tag = 150 << 3 | 0 = 1200 = 0x04B0.
    // Varint encoding: 0xB0 0x09.
    const result = try read_tag(&.{ 0xB0, 0x09 });
    assert(result.value.field_number == 150);
    assert(result.value.wire_type == .varint);
    assert(result.consumed == 2);
}

test "read_tag: max 5 bytes" {
    // Max u32 = 0xFFFFFFFF encoded in 5 bytes.
    const max_bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    const result = try read_tag(&max_bytes);
    assert(result.value.field_number == std.math.maxInt(u29));
    assert(result.consumed == 5);
}

test "read_tag: overlong encoding rejected" {
    // Value 1 encoded with 6 bytes (overlong).
    // Normal: 0x08 (1 byte).
    // Overlong: 0x88 0x80 0x80 0x80 0x80 0x00 (6 bytes).
    const overlong_bytes = [_]u8{ 0x88, 0x80, 0x80, 0x80, 0x80, 0x00 };
    const result = read_tag(&overlong_bytes);
    assert(result == error.VarintOverflow);
}

test "read_tag: 5th byte overflow rejected" {
    // 5th byte with high bits set (would overflow u32).
    const bad_bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F };
    const result = read_tag(&bad_bytes);
    assert(result == error.VarintOverflow);
}

test "read_fixed32" {
    const result = try read_fixed32(&.{ 0x01, 0x02, 0x03, 0x04 });
    assert(result.value == 0x04030201);
    assert(result.consumed == 4);
}

test "read_fixed64" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const result = try read_fixed64(&bytes);
    assert(result.value == 0x0807060504030201);
    assert(result.consumed == 8);
}

test "read_length_delimited: string" {
    // Field with length 5 and data "hello".
    const bytes = [_]u8{ 0x05, 'h', 'e', 'l', 'l', 'o' };
    const result = try read_length_delimited(&bytes);
    assert(std.mem.eql(u8, result.value, "hello"));
    assert(result.consumed == 6);
}

test "zigzag_decode" {
    // 0 -> 0.
    assert(zigzag_decode_32(0) == 0);
    // 1 -> -1.
    assert(zigzag_decode_32(1) == -1);
    // 2 -> 1.
    assert(zigzag_decode_32(2) == 1);
    // 3 -> -2.
    assert(zigzag_decode_32(3) == -2);

    // Same for 64-bit.
    assert(zigzag_decode_64(0) == 0);
    assert(zigzag_decode_64(1) == -1);
    assert(zigzag_decode_64(4294967294) == 2147483647);
}

test "skip_field" {
    // Skip a varint.
    const varint_skip = try skip_field(&.{ 0x96, 0x01 }, .varint);
    assert(varint_skip == 2);

    // Skip a fixed32.
    const fixed32_skip = try skip_field(&.{ 0x00, 0x00, 0x00, 0x00 }, .fixed32);
    assert(fixed32_skip == 4);

    // Skip a delimited field.
    const delim_bytes = [_]u8{ 0x03, 'a', 'b', 'c' };
    const delim_skip = try skip_field(&delim_bytes, .delimited);
    assert(delim_skip == 4);
}
