//! Shared corpus for fuzzing.
//!
//! Corpus files are embedded at compile time from src/fuzz/corpus/,
//! making them available to all fuzzer modules without runtime I/O.
//! The files in src/fuzz/corpus/ can also be used directly by AFL++ and
//! other external fuzzers.

/// Protobuf message corpus - valid and malformed protobuf messages for testing.
///
/// Loaded from src/fuzz/corpus/:
/// - empty.bin: Empty message
/// - int32_simple.bin: field 1, value 1
/// - int32_150.bin: field 1, value 150
/// - int32_max.bin: field 1, max int32 value
/// - int64_simple.bin: field 2, value 1
/// - string_hello.bin: field 1, string "hello"
/// - bytes_simple.bin: field 1, bytes [1,2,3,4,5]
/// - multi_field.bin: Multiple fields
/// - fixed32_1.bin: field 1 (fixed32), value 1
/// - fixed64_1.bin: field 1 (fixed64), value 1
pub const protobuf = [_][]const u8{
    @embedFile("corpus/empty.bin"),
    @embedFile("corpus/int32_simple.bin"),
    @embedFile("corpus/int32_150.bin"),
    @embedFile("corpus/int32_max.bin"),
    @embedFile("corpus/int64_simple.bin"),
    @embedFile("corpus/string_hello.bin"),
    @embedFile("corpus/bytes_simple.bin"),
    @embedFile("corpus/multi_field.bin"),
    @embedFile("corpus/fixed32_1.bin"),
    @embedFile("corpus/fixed64_1.bin"),
};

/// Varint-specific corpus - includes protobuf corpus plus raw varint test cases.
pub const varint = protobuf ++ [_][]const u8{
    &[_]u8{0x00}, // Single byte varint (0)
    &[_]u8{0x7F}, // Single byte varint (127)
    &[_]u8{0x80}, // Truncated varint
    &[_]u8{0x80, 0x01}, // Two byte varint (128)
    &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }, // Max u64 varint
    &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, // Overflow varint
    &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, // Fixed32 bytes
    &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, // Fixed64 bytes
};
