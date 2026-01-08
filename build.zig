const std = @import("std");

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
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_unit_tests);
    test_step.dependOn(&run_fuzz_tests.step);

    // Check step for fast compilation checking.
    const check_step = b.step("check", "Check if proto-zig compiles");
    check_step.dependOn(&unit_tests.step);
}
