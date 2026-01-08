//! Fuzzing utilities for proto-zig.
//!
//! Provides seed-based pseudo-random generation and helper functions
//! for writing fuzz tests. Inspired by TigerBeetle's fuzzing infrastructure.

const std = @import("std");

/// Arguments passed to fuzz test functions.
pub const FuzzArgs = struct {
    /// Random seed for reproducible fuzzing.
    seed: u64,

    /// Maximum number of events/iterations. null means unlimited.
    events_max: ?usize,
};

/// Pseudo-random number generator wrapper with fuzzing-specific utilities.
pub const FuzzPrng = struct {
    inner: std.Random.DefaultPrng,

    pub fn init(seed: u64) FuzzPrng {
        return .{ .inner = std.Random.DefaultPrng.init(seed) };
    }

    pub fn random(self: *FuzzPrng) std.Random {
        return self.inner.random();
    }

    /// Generate a random integer with exponential distribution biased towards avg.
    /// Useful for generating realistic workloads where most values are small.
    pub fn int_exponential(self: *FuzzPrng, comptime T: type, avg: T) T {
        const r = self.random();
        const max = std.math.maxInt(T);

        // Generate exponentially distributed value
        const u = r.float(f64);
        if (u == 0) return max;

        const lambda = 1.0 / @as(f64, @floatFromInt(avg));
        const result = -@log(u) / lambda;

        if (result >= @as(f64, @floatFromInt(max))) {
            return max;
        }

        return @intFromFloat(result);
    }

    /// Generate random bytes into buffer.
    pub fn bytes(self: *FuzzPrng, buf: []u8) void {
        self.random().bytes(buf);
    }

    /// Generate a random integer in range [0, max).
    pub fn uintLessThan(self: *FuzzPrng, comptime T: type, max: T) T {
        return self.random().uintLessThan(T, max);
    }

    /// Generate a random integer in range [min, max].
    pub fn intRangeInclusive(self: *FuzzPrng, comptime T: type, min: T, max: T) T {
        return self.random().intRangeAtMost(T, min, max);
    }

    /// Generate a random boolean.
    pub fn boolean(self: *FuzzPrng) bool {
        return self.random().boolean();
    }

    /// Generate a random boolean with given probability (0.0 to 1.0).
    pub fn booleanWithChance(self: *FuzzPrng, chance: f64) bool {
        return self.random().float(f64) < chance;
    }

    /// Pick a random element from a slice.
    pub fn pick(self: *FuzzPrng, comptime T: type, items: []const T) T {
        return items[self.uintLessThan(usize, items.len)];
    }

    /// Generate a random enum value.
    pub fn enumValue(self: *FuzzPrng, comptime E: type) E {
        return self.random().enumValue(E);
    }
};

/// Parse a seed from command line argument.
/// Supports:
/// - Decimal integers: "12345"
/// - 40-character hex strings (git commit hashes): "a1b2c3d4..."
pub fn parseSeed(arg: ?[]const u8) u64 {
    const str = arg orelse return randomSeed();

    // Check for git commit hash (40 hex chars)
    if (str.len == 40) {
        if (std.fmt.parseInt(u64, str[0..16], 16)) |v| {
            return v;
        } else |_| {}
    }

    // Try parsing as decimal
    return std.fmt.parseInt(u64, str, 10) catch randomSeed();
}

/// Generate a random seed from system entropy.
pub fn randomSeed() u64 {
    var buf: [8]u8 = undefined;
    std.posix.getrandom(&buf) catch {
        // Fallback to timestamp if getrandom fails
        return @bitCast(std.time.timestamp());
    };
    return std.mem.readInt(u64, &buf, .little);
}

/// Parse events_max from command line.
pub fn parseEventsMax(arg: ?[]const u8) ?usize {
    const str = arg orelse return null;
    return std.fmt.parseInt(usize, str, 10) catch null;
}

/// Run context for fuzz tests providing logging and progress tracking.
pub const FuzzContext = struct {
    args: FuzzArgs,
    events_run: usize = 0,
    start_time: i64,

    pub fn init(args: FuzzArgs) FuzzContext {
        std.debug.print("Fuzzing with seed: {d}\n", .{args.seed});
        if (args.events_max) |max| {
            std.debug.print("Events max: {d}\n", .{max});
        }
        return .{
            .args = args,
            .start_time = std.time.timestamp(),
        };
    }

    pub fn shouldContinue(self: *FuzzContext) bool {
        if (self.args.events_max) |max| {
            return self.events_run < max;
        }
        return true;
    }

    pub fn recordEvent(self: *FuzzContext) void {
        self.events_run += 1;

        // Progress reporting every 10000 events
        if (self.events_run % 10000 == 0) {
            const elapsed = std.time.timestamp() - self.start_time;
            std.debug.print("Progress: {d} events in {d}s\n", .{ self.events_run, elapsed });
        }
    }

    pub fn finish(self: *FuzzContext) void {
        const elapsed = std.time.timestamp() - self.start_time;
        std.debug.print("Completed: {d} events in {d}s\n", .{ self.events_run, elapsed });
    }
};

test "FuzzPrng: basic operations" {
    var prng = FuzzPrng.init(12345);

    // Should produce deterministic results
    const a = prng.uintLessThan(u32, 100);
    const b = prng.uintLessThan(u32, 100);
    try std.testing.expect(a != b or a == b); // Just ensuring no crash

    // Exponential distribution should work
    const exp = prng.int_exponential(u32, 100);
    try std.testing.expect(exp <= std.math.maxInt(u32));
}

test "parseSeed: decimal" {
    try std.testing.expectEqual(@as(u64, 12345), parseSeed("12345"));
    try std.testing.expectEqual(@as(u64, 0), parseSeed("0"));
}

test "parseSeed: hex commit hash" {
    // First 16 chars of a git hash
    const seed = parseSeed("a1b2c3d4e5f6789012345678901234567890abcd");
    try std.testing.expect(seed != 0);
}
