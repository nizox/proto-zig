//! Map field support for protobuf.
//!
//! Provides MapField storage type and default map implementation for
//! protocol buffer map fields.

const std = @import("std");
const Allocator = std.mem.Allocator;
const FieldType = @import("mini_table.zig").FieldType;
const StringView = @import("message.zig").StringView;

/// Storage for a map field in message data.
/// The actual map (HashMap, ArrayHashMap, etc.) is heap-allocated via arena.
pub const MapField = struct {
    /// Pointer to arena-allocated map (type depends on decode config).
    /// null if map is empty/not yet allocated.
    ptr: ?*anyopaque,

    /// Key type from MapEntry schema (for encoding/iteration).
    key_type: FieldType,

    /// Value type from MapEntry schema (for encoding/iteration).
    value_type: FieldType,

    /// Initialize an empty map field.
    pub fn empty(key_type: FieldType, value_type: FieldType) MapField {
        return .{
            .ptr = null,
            .key_type = key_type,
            .value_type = value_type,
        };
    }

    /// Cast to the concrete map type used during decoding.
    pub fn getTyped(self: *MapField, comptime Map: type) *Map {
        return @ptrCast(@alignCast(self.ptr.?));
    }

    /// Cast to the concrete map type, returning null if not allocated.
    pub fn getTypedOrNull(self: *MapField, comptime Map: type) ?*Map {
        if (self.ptr) |p| return @ptrCast(@alignCast(p));
        return null;
    }

    /// Cast to const concrete map type used during encoding.
    pub fn getTypedConst(self: *const MapField, comptime Map: type) *const Map {
        return @ptrCast(@alignCast(self.ptr.?));
    }

    /// Cast to const concrete map type, returning null if not allocated.
    pub fn getTypedConstOrNull(self: *const MapField, comptime Map: type) ?*const Map {
        if (self.ptr) |p| return @ptrCast(@alignCast(p));
        return null;
    }
};

/// Hash context for StringView keys.
pub const StringViewContext = struct {
    pub fn hash(self: @This(), key: StringView) u32 {
        _ = self;
        return @truncate(std.hash.Wyhash.hash(0, key.slice()));
    }

    pub fn eql(self: @This(), a: StringView, b: StringView, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

/// Auto context that handles both scalars and StringView.
pub fn MapContext(comptime K: type) type {
    if (K == StringView) {
        return StringViewContext;
    } else {
        return std.array_hash_map.AutoContext(K);
    }
}

/// Check if auto equality is cheap for a type.
fn autoEqlIsCheap(comptime K: type) bool {
    if (K == StringView) {
        return false; // StringView comparison requires slice comparison
    }
    return std.array_hash_map.autoEqlIsCheap(K);
}

/// Default map implementation: ArrayHashMapUnmanaged (preserves insertion order).
/// Use this for most cases - it's arena-friendly and provides deterministic iteration.
pub fn DefaultMap(comptime K: type, comptime V: type) type {
    return std.ArrayHashMapUnmanaged(K, V, MapContext(K), !autoEqlIsCheap(K));
}

/// Alternative: standard HashMapUnmanaged for better performance with large maps.
/// Does not preserve insertion order.
pub fn HashMap(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, MapContext(K), std.builtin.default_max_load_percentage);
}

// Tests

test "MapField: empty initialization" {
    const map_field = MapField.empty(.TYPE_INT32, .TYPE_STRING);
    try std.testing.expectEqual(@as(?*anyopaque, null), map_field.ptr);
    try std.testing.expectEqual(FieldType.TYPE_INT32, map_field.key_type);
    try std.testing.expectEqual(FieldType.TYPE_STRING, map_field.value_type);
}

test "MapField: typed access" {
    var map = DefaultMap(i32, i32){};

    var map_field = MapField{
        .ptr = &map,
        .key_type = .TYPE_INT32,
        .value_type = .TYPE_INT32,
    };

    const typed = map_field.getTyped(DefaultMap(i32, i32));
    try std.testing.expectEqual(&map, typed);
}

test "DefaultMap: i32 -> i32" {
    var map = DefaultMap(i32, i32){};
    defer map.deinit(std.testing.allocator);

    try map.put(std.testing.allocator, 1, 100);
    try map.put(std.testing.allocator, 2, 200);

    try std.testing.expectEqual(@as(?i32, 100), map.get(1));
    try std.testing.expectEqual(@as(?i32, 200), map.get(2));
    try std.testing.expectEqual(@as(?i32, null), map.get(3));
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

test "DefaultMap: i32 -> StringView" {
    var map = DefaultMap(i32, StringView){};
    defer map.deinit(std.testing.allocator);

    try map.put(std.testing.allocator, 1, StringView.from_slice("hello"));
    try map.put(std.testing.allocator, 2, StringView.from_slice("world"));

    const v1 = map.get(1);
    try std.testing.expect(v1 != null);
    try std.testing.expectEqualStrings("hello", v1.?.slice());

    const v2 = map.get(2);
    try std.testing.expect(v2 != null);
    try std.testing.expectEqualStrings("world", v2.?.slice());
}

test "DefaultMap: StringView -> i32" {
    var map = DefaultMap(StringView, i32){};
    defer map.deinit(std.testing.allocator);

    const key1 = StringView.from_slice("one");
    const key2 = StringView.from_slice("two");

    try map.put(std.testing.allocator, key1, 1);
    try map.put(std.testing.allocator, key2, 2);

    try std.testing.expectEqual(@as(?i32, 1), map.get(key1));
    try std.testing.expectEqual(@as(?i32, 2), map.get(key2));
    try std.testing.expectEqual(@as(?i32, null), map.get(StringView.from_slice("three")));
}

test "DefaultMap: StringView -> StringView" {
    var map = DefaultMap(StringView, StringView){};
    defer map.deinit(std.testing.allocator);

    const key1 = StringView.from_slice("key1");
    const val1 = StringView.from_slice("value1");

    try map.put(std.testing.allocator, key1, val1);

    const result = map.get(key1);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("value1", result.?.slice());
}

test "DefaultMap: iteration preserves insertion order" {
    var map = DefaultMap(i32, i32){};
    defer map.deinit(std.testing.allocator);

    try map.put(std.testing.allocator, 3, 300);
    try map.put(std.testing.allocator, 1, 100);
    try map.put(std.testing.allocator, 2, 200);

    var iter = map.iterator();
    var keys: [3]i32 = undefined;
    var i: usize = 0;
    while (iter.next()) |entry| {
        keys[i] = entry.key_ptr.*;
        i += 1;
    }

    // ArrayHashMap preserves insertion order
    try std.testing.expectEqual(@as(i32, 3), keys[0]);
    try std.testing.expectEqual(@as(i32, 1), keys[1]);
    try std.testing.expectEqual(@as(i32, 2), keys[2]);
}
