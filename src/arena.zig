//! Arena allocator for protobuf message allocation.
//!
//! A bump-pointer allocator that allocates from a fixed buffer. All memory is
//! freed at once when the arena is reset or destroyed. This follows Tiger Style
//! principles: no dynamic allocation after initialization, fixed upper bounds.

const std = @import("std");
const assert = std.debug.assert;

/// Arena allocator for protobuf messages.
///
/// Allocates memory from a fixed buffer using bump-pointer allocation.
/// Memory can only be freed all at once via reset(). Individual allocations
/// cannot be freed.
pub const Arena = struct {
    buffer: []u8,
    pos: u32,
    base_offset: u32, // Offset to first aligned position.

    const alignment = 8;

    /// Initialize an arena from a pre-allocated buffer.
    ///
    /// The buffer must be provided by the caller and must outlive the arena.
    /// No dynamic allocation occurs.
    pub fn init(buffer: []u8) Arena {
        assert(buffer.len > 0);
        assert(buffer.len <= std.math.maxInt(u32));

        // Calculate offset needed to align the base pointer.
        const base_addr = @intFromPtr(buffer.ptr);
        const aligned_addr = (base_addr + alignment - 1) & ~@as(usize, alignment - 1);
        const base_offset: u32 = @intCast(aligned_addr - base_addr);

        return Arena{
            .buffer = buffer,
            .pos = base_offset,
            .base_offset = base_offset,
        };
    }

    /// Allocate memory for `count` items of type T.
    ///
    /// Returns a slice of uninitialized memory, or null if the arena is full.
    /// The returned memory is aligned to 8 bytes.
    pub fn alloc(self: *Arena, comptime T: type, count: u32) ?[]T {
        assert(count > 0);
        assert(count <= max_count(T));

        const size = count * @sizeOf(T);

        // Calculate aligned position relative to the buffer's actual address.
        const base_addr = @intFromPtr(self.buffer.ptr);
        const current_addr = base_addr + self.pos;
        const aligned_addr = (current_addr + alignment - 1) & ~@as(usize, alignment - 1);
        const aligned_pos: u32 = @intCast(aligned_addr - base_addr);

        // Check for overflow.
        if (aligned_pos > self.buffer.len) {
            return null;
        }

        const end_pos = aligned_pos + size;
        if (end_pos > self.buffer.len) {
            return null;
        }

        self.pos = @intCast(end_pos);
        const ptr: [*]T = @ptrCast(@alignCast(self.buffer.ptr + aligned_pos));
        return ptr[0..count];
    }

    /// Allocate a single item of type T.
    pub fn create(self: *Arena, comptime T: type) ?*T {
        const slice = self.alloc(T, 1) orelse return null;
        return &slice[0];
    }

    /// Allocate and copy bytes into the arena.
    ///
    /// Returns a slice pointing to the copied data, or null if out of memory.
    pub fn dupe(self: *Arena, bytes: []const u8) ?[]u8 {
        if (bytes.len == 0) {
            return &.{};
        }
        assert(bytes.len <= std.math.maxInt(u32));

        const dest = self.alloc(u8, @intCast(bytes.len)) orelse return null;
        @memcpy(dest, bytes);
        return dest;
    }

    /// Reset the arena, freeing all allocations.
    ///
    /// After reset, the arena can be reused. Previously returned pointers
    /// become invalid.
    pub fn reset(self: *Arena) void {
        self.pos = self.base_offset;
    }

    /// Returns the number of bytes currently allocated.
    pub fn bytes_used(self: *const Arena) u32 {
        return self.pos - self.base_offset;
    }

    /// Returns the number of bytes remaining.
    pub fn bytes_remaining(self: *const Arena) u32 {
        assert(self.buffer.len >= self.pos);
        return @intCast(self.buffer.len - self.pos);
    }

    /// Returns the total capacity of the arena (usable bytes).
    pub fn capacity(self: *const Arena) u32 {
        assert(self.buffer.len <= std.math.maxInt(u32));
        return @intCast(self.buffer.len - self.base_offset);
    }

    fn align_forward(pos: u32) u32 {
        return (pos + alignment - 1) & ~@as(u32, alignment - 1);
    }

    fn max_count(comptime T: type) u32 {
        // Prevent overflow in size calculation.
        return std.math.maxInt(u32) / @sizeOf(T);
    }
};

test "Arena: basic allocation" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    // Allocate some integers.
    const ints = arena.alloc(u32, 10) orelse unreachable;
    assert(ints.len == 10);

    // Allocate a struct.
    const TestStruct = struct { a: u64, b: u32 };
    const s = arena.create(TestStruct) orelse unreachable;
    s.* = .{ .a = 42, .b = 7 };
    assert(s.a == 42);
    assert(s.b == 7);

    // Check bytes used increased.
    assert(arena.bytes_used() > 0);
}

test "Arena: dupe bytes" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const original = "hello world";
    const copy = arena.dupe(original) orelse unreachable;

    assert(copy.len == original.len);
    assert(std.mem.eql(u8, copy, original));

    // Modify copy should not affect original.
    copy[0] = 'H';
    assert(original[0] == 'h');
}

test "Arena: reset" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    _ = arena.alloc(u8, 512) orelse unreachable;
    assert(arena.bytes_used() >= 512);

    arena.reset();
    assert(arena.bytes_used() == 0);
    assert(arena.bytes_remaining() == 1024);
}

test "Arena: out of memory" {
    var buffer: [64]u8 = undefined;
    var arena = Arena.init(&buffer);

    // This should fail: requesting more than available.
    const result = arena.alloc(u8, 128);
    assert(result == null);

    // Arena should still be usable.
    const small = arena.alloc(u8, 32);
    assert(small != null);
}

test "Arena: alignment" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    // Allocate 1 byte to misalign.
    _ = arena.alloc(u8, 1);

    // Next allocation should be aligned.
    const aligned = arena.alloc(u64, 1) orelse unreachable;
    const addr = @intFromPtr(aligned.ptr);
    assert(addr % 8 == 0);
}

test "Arena: empty dupe" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.init(&buffer);

    const empty = arena.dupe(&.{}) orelse unreachable;
    assert(empty.len == 0);
}
