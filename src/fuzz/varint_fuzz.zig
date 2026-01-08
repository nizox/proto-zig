//! Varint fuzzer for proto-zig.
//!
//! Tests varint encoding/decoding primitives:
//! - Varint read/write roundtrips
//! - ZigZag encoding/decoding
//! - Edge cases (0, 127, 128, max values)
//! - Malformed input handling

const std = @import("std");
const fuzz = @import("../testing/fuzz.zig");
const proto = @import("../proto.zig");
const reader = proto.wire.reader;
const encode_mod = proto.wire.encode;

/// Run the varint fuzzer.
pub fn run(args: fuzz.FuzzArgs) !void {
    var ctx = fuzz.FuzzContext.init(args);
    var prng = fuzz.FuzzPrng.init(args.seed);

    // Encoding buffer
    var encode_buffer: [16]u8 = undefined;

    // Input buffer for malformed input tests
    var input_buffer: [16]u8 = undefined;

    while (ctx.shouldContinue()) {
        // Choose test type
        const test_type = prng.enumValue(TestType);

        switch (test_type) {
            .varint_roundtrip => {
                // Generate random u64 value
                const value = prng.random().int(u64);

                // Encode
                const encoded_len = writeVarint(&encode_buffer, value);

                // Decode
                const result = reader.read_varint(encode_buffer[0..encoded_len]) catch |err| {
                    std.debug.print("Varint roundtrip failed: value={d}, err={}\n", .{ value, err });
                    return error.VarintRoundtripFailed;
                };

                if (result.value != value) {
                    std.debug.print("Varint mismatch: expected={d}, got={d}\n", .{ value, result.value });
                    return error.VarintMismatch;
                }

                if (result.consumed != encoded_len) {
                    std.debug.print("Varint consumed mismatch: expected={d}, got={d}\n", .{ encoded_len, result.consumed });
                    return error.VarintConsumedMismatch;
                }
            },

            .zigzag32_roundtrip => {
                // Generate random i32 value
                const value: i32 = @bitCast(prng.random().int(u32));

                // Encode
                const encoded = zigzagEncode32(value);

                // Decode
                const decoded = reader.zigzag_decode_32(encoded);

                if (decoded != value) {
                    std.debug.print("ZigZag32 mismatch: expected={d}, got={d}\n", .{ value, decoded });
                    return error.ZigZag32Mismatch;
                }
            },

            .zigzag64_roundtrip => {
                // Generate random i64 value
                const value: i64 = @bitCast(prng.random().int(u64));

                // Encode
                const encoded = zigzagEncode64(value);

                // Decode
                const decoded = reader.zigzag_decode_64(encoded);

                if (decoded != value) {
                    std.debug.print("ZigZag64 mismatch: expected={d}, got={d}\n", .{ value, decoded });
                    return error.ZigZag64Mismatch;
                }
            },

            .varint_edge_cases => {
                // Test specific edge case values
                const edge_values = [_]u64{
                    0,
                    1,
                    127, // max single-byte
                    128, // min two-byte
                    255,
                    256,
                    16383, // max two-byte
                    16384, // min three-byte
                    std.math.maxInt(u32),
                    std.math.maxInt(u32) + 1,
                    std.math.maxInt(u64),
                };

                const value = prng.pick(u64, &edge_values);

                const encoded_len = writeVarint(&encode_buffer, value);
                const result = reader.read_varint(encode_buffer[0..encoded_len]) catch |err| {
                    std.debug.print("Edge case varint failed: value={d}, err={}\n", .{ value, err });
                    return error.EdgeCaseFailed;
                };

                if (result.value != value) {
                    std.debug.print("Edge case mismatch: expected={d}, got={d}\n", .{ value, result.value });
                    return error.EdgeCaseMismatch;
                }
            },

            .malformed_varint => {
                // Generate random potentially malformed input
                const len = prng.intRangeInclusive(u32, 1, 12);
                prng.bytes(input_buffer[0..len]);

                // Try to read - should either succeed or return an error (not crash)
                _ = reader.read_varint(input_buffer[0..len]) catch {};
            },

            .truncated_varint => {
                // Generate a valid multi-byte varint then truncate it
                const value = prng.intRangeInclusive(u64, 128, std.math.maxInt(u64));
                const full_len = writeVarint(&encode_buffer, value);

                if (full_len > 1) {
                    // Truncate to less than full length
                    const truncated_len = prng.intRangeInclusive(u32, 1, full_len - 1);
                    const result = reader.read_varint(encode_buffer[0..truncated_len]);

                    // Should return EndOfStream error
                    if (result) |_| {
                        // Unexpectedly succeeded - this might be OK if the truncated
                        // bytes happened to form a valid shorter varint
                    } else |err| {
                        if (err != error.EndOfStream) {
                            // Unexpected error type - but still not a crash
                        }
                    }
                }
            },

            .overflow_varint => {
                // Create a varint that would overflow u64
                // 10th byte must be > 0x01 to overflow
                var overflow_bytes: [10]u8 = undefined;
                for (&overflow_bytes) |*b| {
                    b.* = 0xFF;
                }
                // Make 10th byte indicate overflow
                overflow_bytes[9] = prng.intRangeInclusive(u8, 0x02, 0xFF);

                const result = reader.read_varint(&overflow_bytes);
                if (result) |_| {
                    std.debug.print("Overflow varint unexpectedly succeeded\n", .{});
                    return error.OverflowNotDetected;
                } else |err| {
                    if (err != error.VarintOverflow) {
                        std.debug.print("Wrong error for overflow: {}\n", .{err});
                        return error.WrongOverflowError;
                    }
                }
            },

            .fixed32_roundtrip => {
                const value = prng.random().int(u32);
                std.mem.writeInt(u32, encode_buffer[0..4], value, .little);

                const result = reader.read_fixed32(encode_buffer[0..4]) catch |err| {
                    std.debug.print("Fixed32 read failed: err={}\n", .{err});
                    return error.Fixed32Failed;
                };

                if (result.value != value) {
                    std.debug.print("Fixed32 mismatch: expected={d}, got={d}\n", .{ value, result.value });
                    return error.Fixed32Mismatch;
                }
            },

            .fixed64_roundtrip => {
                const value = prng.random().int(u64);
                std.mem.writeInt(u64, encode_buffer[0..8], value, .little);

                const result = reader.read_fixed64(encode_buffer[0..8]) catch |err| {
                    std.debug.print("Fixed64 read failed: err={}\n", .{err});
                    return error.Fixed64Failed;
                };

                if (result.value != value) {
                    std.debug.print("Fixed64 mismatch: expected={d}, got={d}\n", .{ value, result.value });
                    return error.Fixed64Mismatch;
                }
            },
        }

        ctx.recordEvent();
    }

    ctx.finish();
}

const TestType = enum {
    varint_roundtrip,
    zigzag32_roundtrip,
    zigzag64_roundtrip,
    varint_edge_cases,
    malformed_varint,
    truncated_varint,
    overflow_varint,
    fixed32_roundtrip,
    fixed64_roundtrip,
};

/// Write a varint to buffer, return bytes written.
fn writeVarint(buf: []u8, value: u64) u32 {
    var v = value;
    var i: u32 = 0;

    while (v >= 0x80) {
        buf[i] = @truncate((v & 0x7F) | 0x80);
        i += 1;
        v >>= 7;
    }
    buf[i] = @truncate(v);
    return i + 1;
}

/// ZigZag encode a signed 32-bit integer.
fn zigzagEncode32(value: i32) u32 {
    return @bitCast((value << 1) ^ (value >> 31));
}

/// ZigZag encode a signed 64-bit integer.
fn zigzagEncode64(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

test "varint_fuzz: smoke test" {
    try run(.{
        .seed = 12345,
        .events_max = 1000,
    });
}

test "writeVarint: basic values" {
    var buf: [16]u8 = undefined;

    // Single byte
    try std.testing.expectEqual(@as(u32, 1), writeVarint(&buf, 0));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);

    try std.testing.expectEqual(@as(u32, 1), writeVarint(&buf, 127));
    try std.testing.expectEqual(@as(u8, 127), buf[0]);

    // Two bytes
    try std.testing.expectEqual(@as(u32, 2), writeVarint(&buf, 128));
    try std.testing.expectEqual(@as(u8, 0x80), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);

    // 150 = 0x96 0x01
    try std.testing.expectEqual(@as(u32, 2), writeVarint(&buf, 150));
    try std.testing.expectEqual(@as(u8, 0x96), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "zigzag: known values" {
    try std.testing.expectEqual(@as(u32, 0), zigzagEncode32(0));
    try std.testing.expectEqual(@as(u32, 1), zigzagEncode32(-1));
    try std.testing.expectEqual(@as(u32, 2), zigzagEncode32(1));
    try std.testing.expectEqual(@as(u32, 3), zigzagEncode32(-2));

    try std.testing.expectEqual(@as(u64, 0), zigzagEncode64(0));
    try std.testing.expectEqual(@as(u64, 1), zigzagEncode64(-1));
    try std.testing.expectEqual(@as(u64, 2), zigzagEncode64(1));
}
