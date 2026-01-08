const std = @import("std");
const afl_kit = @import("afl_kit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main library module.
    const proto_module = b.createModule(.{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests.
    const unit_tests = b.addTest(.{
        .name = "test-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proto.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Conformance test runner executable.
    const conformance_exe = b.addExecutable(.{
        .name = "conformance_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });
    b.installArtifact(conformance_exe);

    // Fuzz test executable.
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });
    // 4 MiB stack for deep message nesting during fuzzing.
    fuzz_exe.stack_size = 4 * 1024 * 1024;
    b.installArtifact(fuzz_exe);

    // Fuzz step: build and run with arguments.
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| {
        run_fuzz.addArgs(args);
    }
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // Fuzz unit tests (test the fuzz infrastructure itself).
    const fuzz_unit_tests = b.addTest(.{
        .name = "test-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_unit_tests);
    test_step.dependOn(&run_fuzz_tests.step);

    // Check step for fast compilation checking.
    const check_step = b.step("check", "Check if proto-zig compiles");
    check_step.dependOn(&unit_tests.step);

    // Native Zig fuzz tests (uses Zig's built-in fuzzing, no external dependencies).
    // Each unified fuzzer module contains native fuzzer tests that can be run with --fuzz.
    // Fuzzing: zig build fuzz-native-decode && ./zig-out/bin/fuzz-native-decode --fuzz
    // Replay: zig build fuzz -- replay-decode < crash_file (uses main fuzz executable)
    buildNativeFuzzTest(b, "fuzz-native-decode", "src/fuzz/decode.zig", proto_module, target);

    // Combined fuzz-native step that builds all native fuzz tests.
    const fuzz_native_step = b.step("fuzz-native", "Build native Zig fuzz tests");
    if (b.top_level_steps.get("fuzz-native-decode")) |decode_step| {
        fuzz_native_step.dependOn(&decode_step.step);
    }

    // AFL++ instrumented executables using zig-afl-kit.
    const afl_step = b.step("afl", "Build AFL++ instrumented fuzz executables");
    buildAflInstrumented(b, afl_step, "afl-decode-instr", "src/fuzz/afl_decode.zig", proto_module, target, optimize);
}

fn buildNativeFuzzTest(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    proto_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    // Create modules for fuzzing utilities and corpus
    const fuzz_util_module = b.createModule(.{
        .root_source_file = b.path("src/testing/fuzz.zig"),
    });

    const corpus_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz/corpus.zig"),
    });

    // Native fuzz tests use ReleaseSafe for performance with safety checks.
    const fuzz_test = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
                .{ .name = "../testing/fuzz.zig", .module = fuzz_util_module },
                .{ .name = "corpus.zig", .module = corpus_module },
            },
        }),
    });

    // Enable fuzzing instrumentation.
    fuzz_test.root_module.fuzz = true;

    // Install the fuzz test binary so it can be run manually.
    // Run with: ./zig-out/bin/<name> --cache-dir=.zig-cache
    const install_fuzz = b.addInstallArtifact(fuzz_test, .{});

    const fuzz_step = b.step(name, b.fmt("Build {s} (run: ./zig-out/bin/{s} --cache-dir=.zig-cache)", .{ name, name }));
    fuzz_step.dependOn(&install_fuzz.step);
}

fn buildAflInstrumented(
    b: *std.Build,
    afl_step: *std.Build.Step,
    name: []const u8,
    source: []const u8,
    proto_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Create object file for AFL++ instrumentation.
    // Use ReleaseSafe for performance with safety checks, or Debug for better diagnostics.
    const harness_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;

    const afl_obj = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = harness_optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });

    // Required settings for zig-afl-kit
    afl_obj.root_module.stack_check = false;
    afl_obj.root_module.link_libc = true;

    // Create instrumented executable using AFL++ compiler
    const afl_exe = afl_kit.addInstrumentedExe(b, target, harness_optimize, null, false, afl_obj, &.{}) orelse return;
    const install_exe = b.addInstallBinFile(afl_exe, name);
    afl_step.dependOn(&install_exe.step);
}
