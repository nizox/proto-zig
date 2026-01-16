# ADR 0003: Arena Allocator Refactoring

## Status

Accepted

## Context

The current arena implementation (`src/arena.zig`) is a simple bump-pointer allocator
that operates on a fixed pre-allocated buffer. While this follows Tiger Style principles
(no dynamic allocation after init), it limits flexibility:

1. **Fixed capacity**: Cannot grow beyond the initial buffer
2. **No lifetime linking**: Cannot link arena lifetimes like upb's `upb_Arena_Fuse()`
3. **Not composable**: Cannot use different backing allocators for different use cases

upb's arena provides:
- Backing allocator abstraction (`upb_alloc*`)
- Dynamic growth via linked list of blocks
- Arena fusing for lifetime management
- Initial block support (with fuse restrictions)

## Decision

Refactor the arena to wrap a `std.mem.Allocator` and support lifetime linking via fuse.

### Design

#### Arena Structure

```zig
pub const Arena = struct {
    /// Backing allocator for new blocks
    child_allocator: std.mem.Allocator,

    /// Current allocation region
    ptr: [*]u8,
    end: [*]u8,

    /// Linked list of allocated blocks
    blocks: ?*Block,

    /// Union-find parent for fused arenas (null = root)
    fuse_parent: ?*Arena,

    /// Refcount (only valid at root)
    fuse_refcount: u32,

    /// True if initialized with initial buffer (fuse disabled)
    has_initial_block: bool,
};

const Block = struct {
    next: ?*Block,
    size: usize,
    // Data follows
};
```

#### Initialization

```zig
/// Create arena with backing allocator (can grow, can fuse)
pub fn init(child_allocator: std.mem.Allocator) Arena

/// Create arena with initial buffer and optional backing allocator
/// If child_allocator is null, arena cannot grow beyond buffer
/// Arenas with initial buffer cannot be fused
pub fn initBuffer(buffer: []u8, child_allocator: ?std.mem.Allocator) Arena
```

#### Fuse Semantics

```zig
/// Link lifetimes of two arenas.
/// After fusing, neither arena is freed until both are deinit'd.
/// Returns false if either arena has an initial block.
pub fn fuse(self: *Arena, other: *Arena) bool
```

Implementation uses union-find:
1. Find roots of both arenas
2. If same root, already fused
3. Make one root point to the other
4. Combine refcounts at new root
5. On `deinit()`, decrement root refcount
6. When refcount reaches 0, free all blocks from all fused arenas

#### Tiger Style Compatibility

For Tiger Style (no dynamic allocation after init), use `FixedBufferAllocator`:

```zig
var buffer: [64 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
var arena = Arena.init(fba.allocator());
```

Or use initial buffer with no backing allocator:

```zig
var buffer: [64 * 1024]u8 = undefined;
var arena = Arena.initBuffer(&buffer, null);
// Cannot fuse, cannot grow
```

### API Summary

| Method | Description |
|--------|-------------|
| `init(allocator)` | Create arena with backing allocator |
| `initBuffer(buf, ?alloc)` | Create with initial buffer |
| `deinit()` | Free arena (respects fuse refcount) |
| `alloc(T, count)` | Allocate memory |
| `create(T)` | Allocate single item |
| `dupe(bytes)` | Copy bytes into arena |
| `fuse(other)` | Link arena lifetimes |
| `isFused(other)` | Check if in same fuse group |

Note: `reset()` is removed - incompatible with fuse semantics. Callers needing reset behavior should deinit and create a new arena.

### Differences from upb

| Feature | upb | proto-zig |
|---------|-----|-----------|
| Thread safety | Atomic refcount, lock-free fuse | Single-threaded |
| Arena refs | `upb_Arena_RefArena()` for one-way refs | Symmetric fuse only |
| Allocator | Custom `upb_alloc` interface | `std.mem.Allocator` |
| Cleanup callbacks | `upb_AllocCleanupFunc` | Not supported |

## Consequences

### Positive

- **Flexibility**: Can use any `std.mem.Allocator` (page allocator, GPA, etc.)
- **Tiger Style**: Use `FixedBufferAllocator` for bounded memory
- **Lifetime linking**: Fuse enables message graphs with shared ownership
- **std compatibility**: Integrates with Zig ecosystem

### Negative

- **Complexity**: More complex than current fixed-buffer design
- **Overhead**: Block headers add memory overhead
- **No reset**: Reset is removed; use deinit + new arena instead

### Migration

Existing code uses `Arena.init(buffer)`. Migration options:

1. **Direct replacement**: `Arena.initBuffer(buffer, null)` - same behavior, no fuse
2. **With growth**: `Arena.initBuffer(buffer, page_allocator)` - can grow beyond buffer
3. **No initial buffer**: `Arena.init(allocator)` - fully dynamic

## References

- upb arena: `/home/bits/gh/google/protobuf/upb/mem/arena.h`
- upb arena impl: `/home/bits/gh/google/protobuf/upb/mem/arena.c`
- Current arena: `src/arena.zig`
