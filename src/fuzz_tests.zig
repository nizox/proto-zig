//! Proto-zig fuzz test dispatcher.
//!
//! Single executable supporting multiple fuzzing modes:
//! - Seed-based: Deterministic pseudo-random fuzzing
//! - Replay: Reproduce crashes from stdin
//!
//! Usage:
//!   zig build fuzz -- <fuzzer> [seed] [--events-max=N]
//!   zig build fuzz -- replay-<fuzzer> < crash_file
//!   zig build fuzz -- smoke
//!
//! Examples:
//!   zig build fuzz -- decode 12345
//!   zig build fuzz -- replay-decode < crash.bin
//!   zig build fuzz -- smoke

const std = @import("std");
const fuzz = @import("testing/fuzz.zig");

// Unified fuzz test modules
const decode = @import("fuzz/decode.zig");

/// Available fuzz targets and modes.
pub const Fuzzer = enum {
    // Seed-based fuzzing modes
    decode,
    // Replay modes
    replay_decode,
    // Meta modes
    smoke,
    canary,

    pub fn run(self: Fuzzer, args: fuzz.FuzzArgs) anyerror!void {
        switch (self) {
            // Seed-based fuzzing
            .decode => try decode.run(args),
            // Replay modes
            .replay_decode => try runReplay(decode.fuzz),
            // Meta modes
            .smoke => try runSmoke(),
            .canary => return error.CanaryFailed,
        }
    }

    /// Default events_max for smoke tests.
    pub fn smokeEventsMax(self: Fuzzer) usize {
        return switch (self) {
            .decode => 10_000,
            .replay_decode => 0,
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
    const fuzzer_name_raw = args_iter.next() orelse {
        printUsage();
        return error.InvalidArguments;
    };

    // Replace hyphens with underscores for enum parsing (replay-decode -> replay_decode)
    var fuzzer_name_buf: [64]u8 = undefined;
    const fuzzer_name = blk: {
        if (fuzzer_name_raw.len >= fuzzer_name_buf.len) {
            std.debug.print("Fuzzer name too long: {s}\n", .{fuzzer_name_raw});
            return error.InvalidArguments;
        }
        @memcpy(fuzzer_name_buf[0..fuzzer_name_raw.len], fuzzer_name_raw);
        for (fuzzer_name_buf[0..fuzzer_name_raw.len]) |*c| {
            if (c.* == '-') c.* = '_';
        }
        break :blk fuzzer_name_buf[0..fuzzer_name_raw.len];
    };

    const fuzzer = std.meta.stringToEnum(Fuzzer, fuzzer_name) orelse {
        std.debug.print("Unknown fuzzer: {s}\n", .{fuzzer_name_raw});
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

/// Run replay mode - reads crash input from stdin and replays it.
fn runReplay(fuzzFn: fn ([]const u8) anyerror!void) !void {
    std.debug.print("Reading input from stdin...\n", .{});

    var buf: [1024 * 1024]u8 = undefined;
    const len = std.fs.File.stdin().readAll(&buf) catch |err| {
        std.debug.print("Read error: {s}\n", .{@errorName(err)});
        return err;
    };

    if (len == 0) {
        std.debug.print("Error: no input (pipe data to stdin)\n", .{});
        return error.NoInput;
    }

    std.debug.print("Replaying {d} bytes...\n", .{len});
    try fuzzFn(buf[0..len]);
    std.debug.print("Replay completed successfully.\n", .{});
}

fn runSmoke() !void {
    std.debug.print("\n--- Running smoke tests ---\n", .{});

    const fuzzers = [_]Fuzzer{
        .decode,
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
        \\       fuzz replay-<fuzzer> < crash_file
        \\
        \\Seed-based fuzzers:
        \\  decode     - Fuzz the protobuf decoder with arbitrary bytes
        \\
        \\Replay modes:
        \\  replay-decode     - Replay a crash on the decode fuzzer
        \\
        \\Meta modes:
        \\  smoke      - Run all fuzzers briefly (CI gate)
        \\  canary     - Always fails (tests fuzzing infrastructure)
        \\
        \\Options:
        \\  seed            Seed for deterministic fuzzing (default: random)
        \\  --events-max=N  Maximum number of events to run
        \\
        \\Examples:
        \\  fuzz decode 12345
        \\  fuzz replay-decode < crash.bin
        \\  fuzz smoke
        \\
    , .{});
}

test {
    // Reference all fuzz modules for test discovery
    _ = fuzz;
    _ = decode;
}
