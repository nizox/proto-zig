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
/// - bool_false.bin: field 1, bool false
/// - bool_true.bin: field 1, bool true
/// - uint32_42.bin: field 3, uint32 value 42
/// - uint32_max.bin: field 3, max uint32 value
/// - uint64_max.bin: field 4, max uint64 value
/// - sint32_neg1.bin: field 1, sint32 value -1 (zigzag encoded)
/// - sint32_min.bin: field 1, min sint32 value (zigzag encoded)
/// - sint32_max.bin: field 1, max sint32 value (zigzag encoded)
/// - sint64_neg1.bin: field 2, sint64 value -1 (zigzag encoded)
/// - sint64_min.bin: field 2, min sint64 value (zigzag encoded)
/// - sfixed32_neg1.bin: field 3, sfixed32 value -1
/// - sfixed64_neg1.bin: field 4, sfixed64 value -1
/// - float_pi.bin: field 3, float 3.14
/// - float_nan.bin: field 3, float NaN
/// - float_inf.bin: field 3, float +Infinity
/// - float_neg_inf.bin: field 3, float -Infinity
/// - float_neg_zero.bin: field 3, float -0.0
/// - double_e.bin: field 4, double 2.718281828
/// - double_nan.bin: field 4, double NaN
/// - double_inf.bin: field 4, double +Infinity
/// - string_empty.bin: field 3, empty string
/// - string_utf8.bin: field 3, UTF-8 string "Hello 世界"
/// - bytes_empty.bin: field 4, empty bytes
/// - repeated_int32_packed.bin: field 1, packed repeated int32 [1,2,3,150,-1]
/// - repeated_int32_unpacked.bin: field 2, unpacked repeated int32 [1,2,3]
/// - repeated_fixed32_packed.bin: field 1, packed repeated fixed32 [1,2,3]
/// - repeated_double_packed.bin: field 1, packed repeated double [1.0,2.0]
/// - enum_value.bin: field 2, enum value 5
/// - large_field_number.bin: field 536870911, value 1
/// - unknown_field.bin: field 999, value 42 (unknown field)
/// - nested_message.bin: field 1, nested message containing field 1 = 42
/// - duplicate_scalar.bin: field 1 set twice (10, then 20 - last wins)
/// - zero_values.bin: Multiple zero values (int32=0, string="", bool=false)
pub const protobuf = [_][]const u8{
    // Original corpus
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

    // Bool values
    @embedFile("corpus/bool_false.bin"),
    @embedFile("corpus/bool_true.bin"),

    // Unsigned integers
    @embedFile("corpus/uint32_42.bin"),
    @embedFile("corpus/uint32_max.bin"),
    @embedFile("corpus/uint64_max.bin"),

    // Signed integers (zigzag encoded)
    @embedFile("corpus/sint32_neg1.bin"),
    @embedFile("corpus/sint32_min.bin"),
    @embedFile("corpus/sint32_max.bin"),
    @embedFile("corpus/sint64_neg1.bin"),
    @embedFile("corpus/sint64_min.bin"),

    // Signed fixed integers
    @embedFile("corpus/sfixed32_neg1.bin"),
    @embedFile("corpus/sfixed64_neg1.bin"),

    // Float values
    @embedFile("corpus/float_pi.bin"),
    @embedFile("corpus/float_nan.bin"),
    @embedFile("corpus/float_inf.bin"),
    @embedFile("corpus/float_neg_inf.bin"),
    @embedFile("corpus/float_neg_zero.bin"),

    // Double values
    @embedFile("corpus/double_e.bin"),
    @embedFile("corpus/double_nan.bin"),
    @embedFile("corpus/double_inf.bin"),

    // Strings
    @embedFile("corpus/string_empty.bin"),
    @embedFile("corpus/string_utf8.bin"),

    // Bytes
    @embedFile("corpus/bytes_empty.bin"),

    // Repeated fields
    @embedFile("corpus/repeated_int32_packed.bin"),
    @embedFile("corpus/repeated_int32_unpacked.bin"),
    @embedFile("corpus/repeated_fixed32_packed.bin"),
    @embedFile("corpus/repeated_double_packed.bin"),

    // Enum
    @embedFile("corpus/enum_value.bin"),

    // Edge cases
    @embedFile("corpus/large_field_number.bin"),
    @embedFile("corpus/unknown_field.bin"),
    @embedFile("corpus/nested_message.bin"),
    @embedFile("corpus/duplicate_scalar.bin"),
    @embedFile("corpus/zero_values.bin"),
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
