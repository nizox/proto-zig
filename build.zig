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

    // Check step for fast compilation checking.
    const check_step = b.step("check", "Check if proto-zig compiles");
    check_step.dependOn(&unit_tests.step);
}
