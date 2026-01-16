//! Arena allocator for protobuf message allocation.
//!
//! A bump-pointer allocator that can allocate from an initial buffer and/or
//! grow dynamically using a backing allocator. Supports arena fusing for
//! lifetime linking (union-find semantics).

const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

/// Arena allocator for protobuf messages.
///
/// Allocates memory using bump-pointer allocation. Can operate in two modes:
/// 1. With backing allocator: Can grow by allocating new blocks
/// 2. With initial buffer only: Fixed capacity, cannot fuse
///
/// Memory can only be freed all at once via deinit(). Individual allocations
/// cannot be freed.
pub const Arena = struct {
    /// Current allocation pointer (fast path).
    ptr: [*]u8,
    /// End of current block.
    end: [*]u8,

    /// Linked list of allocated blocks (null if none allocated).
    blocks: ?*Block,
    /// Backing allocator for new blocks (null if cannot grow).
    child_allocator: ?std.mem.Allocator,

    /// Union-find parent for fused arenas (null = root).
    fuse_parent: ?*Arena,
    /// Refcount (only valid at root). Starts at 1.
    fuse_refcount: u32,

    /// True if initialized with initial buffer (fuse disabled).
    has_initial_block: bool,

    const alignment: Alignment = .@"8";

    /// Block header for dynamically allocated blocks.
    const Block = struct {
        next: ?*Block,
        size: usize,
        // Data follows after alignment padding.

        fn dataStart(self: *Block) [*]u8 {
            const header_end = @intFromPtr(self) + @sizeOf(Block);
            return @ptrFromInt(alignment.forward(header_end));
        }

        fn dataEnd(self: *Block) [*]u8 {
            return @as([*]u8, @ptrCast(self)) + self.size;
        }
    };

    /// Create arena with backing allocator (can grow, can fuse).
    ///
    /// The arena starts empty and will allocate blocks as needed.
    pub fn init(child_allocator: std.mem.Allocator) Arena {
        // Start with ptr > end to trigger slow path on first allocation.
        return Arena{
            .ptr = @ptrFromInt(alignment.toByteUnits()),
            .end = @ptrFromInt(1),
            .blocks = null,
            .child_allocator = child_allocator,
            .fuse_parent = null,
            .fuse_refcount = 1,
            .has_initial_block = false,
        };
    }

    /// Create arena with initial buffer and optional backing allocator.
    ///
    /// If child_allocator is null, arena cannot grow beyond buffer and cannot fuse.
    /// If child_allocator is provided, arena can grow but still cannot fuse
    /// (initial blocks prevent fusing for lifetime safety).
    pub fn initBuffer(buffer: []u8, child_allocator: ?std.mem.Allocator) Arena {
        assert(buffer.len > 0);

        // Align the start pointer within the buffer.
        const base_addr = @intFromPtr(buffer.ptr);
        const aligned_addr = alignment.forward(base_addr);
        const offset = aligned_addr - base_addr;

        if (offset >= buffer.len) {
            // Buffer too small to even align, treat as empty.
            return Arena{
                .ptr = buffer.ptr + buffer.len,
                .end = buffer.ptr + buffer.len,
                .blocks = null,
                .child_allocator = child_allocator,
                .fuse_parent = null,
                .fuse_refcount = 1,
                .has_initial_block = true,
            };
        }

        return Arena{
            .ptr = buffer.ptr + offset,
            .end = buffer.ptr + buffer.len,
            .blocks = null,
            .child_allocator = child_allocator,
            .fuse_parent = null,
            .fuse_refcount = 1,
            .has_initial_block = true,
        };
    }

    /// Free the arena and all its allocations.
    ///
    /// If the arena is fused with others, decrements the refcount.
    /// Only frees memory when refcount reaches zero.
    /// After deinit, the arena should not be used.
    pub fn deinit(self: *Arena) void {
        const root = self.findRoot();

        // Decrement refcount.
        assert(root.fuse_refcount > 0);
        root.fuse_refcount -= 1;

        if (root.fuse_refcount > 0) {
            // Other arenas still reference this fuse group.
            return;
        }

        // Refcount is zero, free all blocks from the root arena.
        // When fusing, all blocks are transferred to the root, so we only
        // need to free root's blocks.
        root.freeAllBlocks();
    }

    fn freeAllBlocks(self: *Arena) void {
        const allocator = self.child_allocator orelse return;

        var block = self.blocks;
        while (block) |b| {
            const next = b.next;
            const slice = @as([*]u8, @ptrCast(b))[0..b.size];
            allocator.free(slice);
            block = next;
        }
        self.blocks = null;
    }

    /// Allocate memory for `count` items of type T.
    ///
    /// Returns a slice of uninitialized memory, or null if out of memory.
    /// The returned memory is aligned to 8 bytes.
    pub fn alloc(self: *Arena, comptime T: type, count: u32) ?[]T {
        assert(count > 0);
        assert(count <= max_count(T));

        const size = count * @sizeOf(T);
        const ptr = self.allocBytes(size) orelse return null;
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..count];
    }

    fn allocBytes(self: *Arena, size: usize) ?[*]u8 {
        // Fast path: try to allocate from current block.
        const current = @intFromPtr(self.ptr);
        const aligned = alignment.forward(current);
        const end_addr = @intFromPtr(self.end);

        if (aligned <= end_addr and end_addr - aligned >= size) {
            self.ptr = @ptrFromInt(aligned + size);
            return @ptrFromInt(aligned);
        }

        // Slow path: need a new block.
        return self.slowAlloc(size);
    }

    fn slowAlloc(self: *Arena, size: usize) ?[*]u8 {
        const allocator = self.child_allocator orelse return null;

        // Calculate block size: at least 256 bytes, or double the last block,
        // or enough to fit the request.
        const header_overhead = alignment.forward(@sizeOf(Block));
        const min_data_size = if (size > 256) size else 256;
        const last_size = if (self.blocks) |b| b.size else 256;
        const target_size = @max(last_size * 2, min_data_size + header_overhead);

        const block_size = @max(target_size, size + header_overhead);

        const mem = allocator.alloc(u8, block_size) catch return null;
        const block: *Block = @ptrCast(@alignCast(mem.ptr));
        block.size = mem.len;
        block.next = self.blocks;
        self.blocks = block;

        self.ptr = block.dataStart();
        self.end = block.dataEnd();

        // Now allocate from the new block.
        const ptr_addr = @intFromPtr(self.ptr);
        self.ptr = @ptrFromInt(ptr_addr + size);
        return @ptrFromInt(ptr_addr);
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

    /// Link lifetimes of two arenas.
    ///
    /// After fusing, neither arena is freed until both are deinit'd.
    /// Returns false if either arena has an initial block (cannot fuse).
    pub fn fuse(self: *Arena, other: *Arena) bool {
        if (self == other) return true; // Trivial fuse.

        // Cannot fuse arenas with initial blocks.
        if (self.has_initial_block or other.has_initial_block) {
            return false;
        }

        const root1 = self.findRoot();
        const root2 = other.findRoot();

        if (root1 == root2) return true; // Already fused.

        // Always fuse into the root with lower address to avoid cycles.
        const parent = if (@intFromPtr(root1) < @intFromPtr(root2)) root1 else root2;
        const child = if (@intFromPtr(root1) < @intFromPtr(root2)) root2 else root1;

        // Combine refcounts and make child point to parent.
        parent.fuse_refcount += child.fuse_refcount;
        child.fuse_parent = parent;

        // Transfer child's blocks to parent.
        if (child.blocks) |child_blocks| {
            // Find end of child's block list.
            var last = child_blocks;
            while (last.next) |next| {
                last = next;
            }
            // Link child's blocks to parent's block list.
            last.next = parent.blocks;
            parent.blocks = child_blocks;
            child.blocks = null;
        }

        return true;
    }

    /// Check if two arenas are in the same fuse group.
    pub fn isFused(self: *Arena, other: *Arena) bool {
        if (self == other) return true;
        return self.findRoot() == other.findRoot();
    }

    /// Find the root of the fuse tree with path compression.
    fn findRoot(self: *Arena) *Arena {
        var current = self;

        // Find root.
        while (current.fuse_parent) |parent| {
            current = parent;
        }
        const root = current;

        // Path compression: make all nodes point directly to root.
        current = self;
        while (current.fuse_parent) |parent| {
            current.fuse_parent = root;
            current = parent;
        }

        return root;
    }

    /// Returns the number of bytes currently allocated from the current block.
    pub fn bytes_used(self: *const Arena) u32 {
        // This is approximate - just for the current block.
        const end_addr = @intFromPtr(self.end);
        const ptr_addr = @intFromPtr(self.ptr);

        if (self.blocks) |block| {
            const start = @intFromPtr(block.dataStart());
            if (ptr_addr >= start and ptr_addr <= end_addr) {
                return @intCast(ptr_addr - start);
            }
        }
        return 0;
    }

    /// Returns the number of bytes remaining in the current block.
    pub fn bytes_remaining(self: *const Arena) u32 {
        const end_addr = @intFromPtr(self.end);
        const ptr_addr = @intFromPtr(self.ptr);
        if (end_addr >= ptr_addr) {
            return @intCast(end_addr - ptr_addr);
        }
        return 0;
    }

    /// Returns the total capacity of the current block (usable bytes).
    pub fn capacity(self: *const Arena) u32 {
        if (self.blocks) |block| {
            const data_size = @intFromPtr(block.dataEnd()) - @intFromPtr(block.dataStart());
            if (data_size <= std.math.maxInt(u32)) {
                return @intCast(data_size);
            }
        }
        // For initial buffer case.
        const end_addr = @intFromPtr(self.end);
        const ptr_addr = @intFromPtr(self.ptr);
        if (end_addr >= ptr_addr) {
            return @intCast(end_addr - ptr_addr);
        }
        return 0;
    }

    fn max_count(comptime T: type) u32 {
        // Prevent overflow in size calculation.
        return std.math.maxInt(u32) / @sizeOf(T);
    }
};

test "Arena: basic allocation with buffer" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.initBuffer(&buffer, std.testing.allocator);
    defer arena.deinit();

    // Allocate some integers.
    const ints = arena.alloc(u32, 10) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 10), ints.len);

    // Allocate a struct.
    const TestStruct = struct { a: u64, b: u32 };
    const s = arena.create(TestStruct) orelse unreachable;
    s.* = .{ .a = 42, .b = 7 };
    try std.testing.expectEqual(@as(u64, 42), s.a);
    try std.testing.expectEqual(@as(u32, 7), s.b);

    // Check bytes used increased (approximate).
    try std.testing.expect(arena.bytes_remaining() < 1024);
}

test "Arena: dupe bytes" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.initBuffer(&buffer, std.testing.allocator);
    defer arena.deinit();

    const original = "hello world";
    const copy = arena.dupe(original) orelse unreachable;

    try std.testing.expectEqual(original.len, copy.len);
    try std.testing.expectEqualStrings(original, copy);

    // Modify copy should not affect original.
    copy[0] = 'H';
    try std.testing.expectEqual(@as(u8, 'h'), original[0]);
}

test "Arena: out of memory with buffer only" {
    var buffer: [64]u8 = undefined;
    // Intentionally no backing allocator to test OOM behavior.
    var arena = Arena.initBuffer(&buffer, null);

    // This should fail: requesting more than available, no backing allocator.
    const result = arena.alloc(u8, 128);
    try std.testing.expect(result == null);

    // Arena should still be usable.
    const small = arena.alloc(u8, 32);
    try std.testing.expect(small != null);
}

test "Arena: alignment" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.initBuffer(&buffer, std.testing.allocator);
    defer arena.deinit();

    // Allocate 1 byte to misalign.
    _ = arena.alloc(u8, 1);

    // Next allocation should be aligned.
    const aligned = arena.alloc(u64, 1) orelse unreachable;
    const addr = @intFromPtr(aligned.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % 8);
}

test "Arena: empty dupe" {
    var buffer: [1024]u8 = undefined;
    var arena = Arena.initBuffer(&buffer, std.testing.allocator);
    defer arena.deinit();

    const empty = arena.dupe(&.{}) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Arena: init with allocator" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    // Should be able to allocate.
    const data = arena.alloc(u8, 100) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 100), data.len);

    // Should grow and allocate more.
    const more = arena.alloc(u8, 1000) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1000), more.len);
}

test "Arena: dynamic growth" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    // Allocate multiple times to trigger block growth.
    var total: usize = 0;
    for (0..10) |_| {
        const data = arena.alloc(u8, 512) orelse unreachable;
        try std.testing.expectEqual(@as(usize, 512), data.len);
        total += 512;
    }
    try std.testing.expectEqual(@as(usize, 5120), total);
}

test "Arena: cannot fuse with initial block" {
    var buffer1: [256]u8 = undefined;
    var buffer2: [256]u8 = undefined;
    var arena1 = Arena.initBuffer(&buffer1, std.testing.allocator);
    var arena2 = Arena.initBuffer(&buffer2, std.testing.allocator);
    defer arena1.deinit();
    defer arena2.deinit();

    // Should fail: both have initial blocks.
    try std.testing.expect(!arena1.fuse(&arena2));
    try std.testing.expect(!arena1.isFused(&arena2));
}

test "Arena: fuse two dynamic arenas" {
    var arena1 = Arena.init(std.testing.allocator);
    var arena2 = Arena.init(std.testing.allocator);

    // Allocate in both.
    _ = arena1.alloc(u8, 100);
    _ = arena2.alloc(u8, 100);

    // Fuse should succeed.
    try std.testing.expect(arena1.fuse(&arena2));
    try std.testing.expect(arena1.isFused(&arena2));

    // Both should share the same root.
    try std.testing.expectEqual(arena1.findRoot(), arena2.findRoot());

    // Only need to deinit once (but deinit both to decrement refcount properly).
    arena1.deinit();
    arena2.deinit();
}

test "Arena: fuse refcount" {
    var arena1 = Arena.init(std.testing.allocator);
    var arena2 = Arena.init(std.testing.allocator);

    _ = arena1.alloc(u8, 100);
    _ = arena2.alloc(u8, 100);

    try std.testing.expect(arena1.fuse(&arena2));

    // Root should have refcount of 2.
    const root = arena1.findRoot();
    try std.testing.expectEqual(@as(u32, 2), root.fuse_refcount);

    // First deinit decrements refcount but doesn't free.
    arena1.deinit();
    try std.testing.expectEqual(@as(u32, 1), root.fuse_refcount);

    // Second deinit frees everything.
    arena2.deinit();
}

test "Arena: fuse is idempotent" {
    var arena1 = Arena.init(std.testing.allocator);
    var arena2 = Arena.init(std.testing.allocator);
    defer arena1.deinit();
    defer arena2.deinit();

    try std.testing.expect(arena1.fuse(&arena2));
    const root = arena1.findRoot();
    const refcount = root.fuse_refcount;

    // Fusing again should be a no-op.
    try std.testing.expect(arena1.fuse(&arena2));
    try std.testing.expectEqual(refcount, root.fuse_refcount);
}

test "Arena: self fuse" {
    var arena = Arena.init(std.testing.allocator);
    defer arena.deinit();

    // Self-fuse should succeed and be a no-op.
    try std.testing.expect(arena.fuse(&arena));
    try std.testing.expectEqual(@as(u32, 1), arena.fuse_refcount);
}

test "Arena: initBuffer with backing allocator allows growth" {
    var buffer: [64]u8 = undefined;
    var arena = Arena.initBuffer(&buffer, std.testing.allocator);
    defer arena.deinit();

    // First allocation fits in buffer.
    const small = arena.alloc(u8, 32);
    try std.testing.expect(small != null);

    // Large allocation should grow.
    const large = arena.alloc(u8, 1000);
    try std.testing.expect(large != null);
}

test "Arena: initBuffer with backing allocator still cannot fuse" {
    var buffer1: [64]u8 = undefined;
    var arena1 = Arena.initBuffer(&buffer1, std.testing.allocator);
    defer arena1.deinit();

    var arena2 = Arena.init(std.testing.allocator);
    defer arena2.deinit();

    // Cannot fuse because arena1 has initial block.
    try std.testing.expect(!arena1.fuse(&arena2));
}
