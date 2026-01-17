//! Proto-Zig: A standalone protobuf implementation in Zig.
//!
//! This library provides binary protobuf encoding and decoding with runtime
//! reflection, following the design principles of upb (micro protobuf).
//!
//! Key features:
//! - Zero-copy string decoding (optional)
//! - Arena-based memory allocation
//! - No dynamic allocation after initialization
//! - Compact schema representation (MiniTable)

const std = @import("std");

pub const Arena = @import("arena.zig").Arena;
pub const wire = @import("wire/wire.zig");
pub const MiniTable = @import("mini_table.zig").MiniTable;
pub const MiniTableField = @import("mini_table.zig").MiniTableField;
pub const FieldType = @import("mini_table.zig").FieldType;
pub const FieldMode = @import("mini_table.zig").Mode;
pub const Message = @import("message.zig").Message;
pub const FieldValue = @import("message.zig").FieldValue;
pub const StringView = @import("message.zig").StringView;
pub const RepeatedField = @import("message.zig").RepeatedField;
pub const MapField = @import("message.zig").MapField;

// Map support
pub const map = @import("map.zig");
pub const DefaultMap = map.DefaultMap;
pub const HashMap = map.HashMap;
pub const MapContext = map.MapContext;

pub const bootstrap = @import("descriptor/bootstrap.zig");
pub const descriptor = @import("descriptor/decode.zig");

// Decode/encode convenience functions
pub const decode = wire.decode.decode;
pub const encode = wire.encode.encode;
pub const DecodeError = wire.decode.DecodeError;
pub const EncodeError = wire.encode.EncodeError;
pub const DecodeOptions = wire.decode.DecodeOptions;
pub const EncodeOptions = wire.encode.EncodeOptions;

// Generic encoder/decoder types (for custom map implementations)
pub const Decoder = wire.decode.Decoder;
pub const Encoder = wire.encode.Encoder;
pub const DefaultDecoder = wire.decode.DefaultDecoder;
pub const DefaultEncoder = wire.encode.DefaultEncoder;

// Descriptor parsing
pub const parse_file_descriptor_set = descriptor.parse_file_descriptor_set;
pub const SymbolTable = descriptor.SymbolTable;

test {
    _ = @import("arena.zig");
    _ = @import("wire/wire.zig");
    _ = @import("mini_table.zig");
    _ = @import("message.zig");
    _ = @import("map.zig");
    _ = @import("descriptor/bootstrap.zig");
    _ = @import("descriptor/decode.zig");
}
