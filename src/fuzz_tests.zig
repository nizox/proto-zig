//! Proto-zig fuzz test dispatcher.
//!
//! Single executable that dispatches to individual fuzz tests based on
//! command-line arguments. Follows the TigerBeetle fuzzing pattern.
//!
//! Usage:
//!   zig build fuzz -- <fuzzer> [seed] [--events-max=N]
//!   zig build fuzz -- smoke
//!
//! Examples:
//!   zig build fuzz -- decode 12345
//!   zig build fuzz -- roundtrip --events-max=10000
//!   zig build fuzz -- smoke

const std = @import("std");
const fuzz = @import("testing/fuzz.zig");

// Fuzz test modules
const decode_fuzz = @import("fuzz/decode_fuzz.zig");
const roundtrip_fuzz = @import("fuzz/roundtrip_fuzz.zig");
const varint_fuzz = @import("fuzz/varint_fuzz.zig");

/// Available fuzz targets.
pub const Fuzzer = enum {
    decode,
    roundtrip,
    varint,
    smoke,
    canary,

    pub fn run(self: Fuzzer, args: fuzz.FuzzArgs) anyerror!void {
        switch (self) {
            .decode => try decode_fuzz.run(args),
            .roundtrip => try roundtrip_fuzz.run(args),
            .varint => try varint_fuzz.run(args),
            .smoke => try runSmoke(),
            .canary => return error.CanaryFailed,
        }
    }

    /// Default events_max for smoke tests.
    pub fn smokeEventsMax(self: Fuzzer) usize {
        return switch (self) {
            .decode => 10_000,
            .roundtrip => 5_000,
            .varint => 50_000,
            .smoke => 0,
            .canary => 1,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try parseArgs();

    std.debug.print("\n=== Proto-zig Fuzzer ===\n", .{});
    std.debug.print("Target: {s}\n", .{@tagName(args.fuzzer)});

    try args.fuzzer.run(args.fuzz_args);

    std.debug.print("=== Fuzzing completed successfully ===\n\n", .{});
}

const ParsedArgs = struct {
    fuzzer: Fuzzer,
    fuzz_args: fuzz.FuzzArgs,
};

fn parseArgs() !ParsedArgs {
    var args_iter = std.process.args();
    _ = args_iter.skip(); // Skip executable name

    // Parse fuzzer name
    const fuzzer_name = args_iter.next() orelse {
        printUsage();
        return error.InvalidArguments;
    };

    const fuzzer = std.meta.stringToEnum(Fuzzer, fuzzer_name) orelse {
        std.debug.print("Unknown fuzzer: {s}\n", .{fuzzer_name});
        printUsage();
        return error.InvalidArguments;
    };

    // Parse remaining arguments
    var seed: ?u64 = null;
    var events_max: ?usize = null;

    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--events-max=")) {
            const value = arg["--events-max=".len..];
            events_max = std.fmt.parseInt(usize, value, 10) catch {
                std.debug.print("Invalid events-max value: {s}\n", .{value});
                return error.InvalidArguments;
            };
        } else {
            // Assume it's a seed
            seed = fuzz.parseSeed(arg);
        }
    }

    return .{
        .fuzzer = fuzzer,
        .fuzz_args = .{
            .seed = seed orelse fuzz.randomSeed(),
            .events_max = events_max,
        },
    };
}

fn runSmoke() !void {
    std.debug.print("\n--- Running smoke tests ---\n", .{});

    const fuzzers = [_]Fuzzer{
        .decode,
        .roundtrip,
        .varint,
    };

    const base_seed = fuzz.randomSeed();

    for (fuzzers, 0..) |fuzzer, i| {
        std.debug.print("\n[{d}/{d}] {s}...\n", .{ i + 1, fuzzers.len, @tagName(fuzzer) });

        const args = fuzz.FuzzArgs{
            .seed = base_seed +% i,
            .events_max = fuzzer.smokeEventsMax(),
        };

        try fuzzer.run(args);
        std.debug.print("[{d}/{d}] {s}: OK\n", .{ i + 1, fuzzers.len, @tagName(fuzzer) });
    }

    std.debug.print("\n--- All smoke tests passed ---\n", .{});
}

fn printUsage() void {
    std.debug.print(
        \\
        \\Usage: fuzz <fuzzer> [seed] [--events-max=N]
        \\
        \\Fuzzers:
        \\  decode     - Fuzz the protobuf decoder with arbitrary bytes
        \\  roundtrip  - Fuzz encode/decode roundtrip consistency
        \\  varint     - Fuzz varint encoding/decoding
        \\  smoke      - Run all fuzzers briefly (CI gate)
        \\  canary     - Always fails (tests fuzzing infrastructure)
        \\
        \\Options:
        \\  seed            Seed for deterministic fuzzing (default: random)
        \\  --events-max=N  Maximum number of events to run
        \\
        \\Examples:
        \\  fuzz decode 12345
        \\  fuzz roundtrip --events-max=10000
        \\  fuzz smoke
        \\
    , .{});
}

test {
    // Reference all fuzz modules for test discovery
    _ = fuzz;
    _ = decode_fuzz;
    _ = roundtrip_fuzz;
    _ = varint_fuzz;
}
