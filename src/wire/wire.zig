//! Wire format module for protobuf binary encoding/decoding.

pub const types = @import("types.zig");
pub const reader = @import("reader.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");

pub const WireType = types.WireType;
pub const Tag = types.Tag;

test {
    _ = @import("types.zig");
    _ = @import("reader.zig");
    _ = @import("decode.zig");
    _ = @import("encode.zig");
}
