const std = @import("std");
const afl_kit = @import("afl_kit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options for protoc integration
    const protoc_path = b.option([]const u8, "protoc", "Path to protoc binary") orelse "protoc";
    const protobuf_src = b.option([]const u8, "protobuf-src", "Path to protobuf source directory") orelse "/home/bits/gh/google/protobuf";

    // Main library module.
    const proto_module = b.createModule(.{
        .root_source_file = b.path("src/proto.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Hand-written conformance tables module (using tables.zig until codegen is fixed).
    const conformance_generated_module = b.createModule(.{
        .root_source_file = b.path("src/conformance/tables.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto_module },
        },
    });

    // Unit tests.
    const unit_tests = b.addTest(.{
        .name = "test-proto",
        .root_module = proto_module,
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
                .{ .name = "conformance", .module = conformance_generated_module },
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

    // Codegen tests
    const codegen_module = b.createModule(.{
        .root_source_file = b.path("src/codegen/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto_module },
        },
    });
    const codegen_test = b.addTest(.{
        .name = "test-codegen",
        .root_module = codegen_module,
    });
    test_step.dependOn(&b.addRunArtifact(codegen_test).step);

    const plugin_exe = b.addExecutable(.{
        .name = "protoc-gen-zig-pb",
        .root_module = codegen_module,
    });
    b.installArtifact(plugin_exe);

    // ========================================================================
    // Update Proto Step (Code Generation)
    // ========================================================================
    //
    // Regenerates .proto MiniTables using protoc-gen-zig-pb plugin.
    // Requires: protoc and protobuf source at /home/bits/gh/google/protobuf/
    // Usage: zig build update-proto
    //
    // Note: descriptor.proto is NOT generated because it uses proto2 features
    // (optional keyword, default values). We use hand-coded bootstrap schemas
    // in src/descriptor/bootstrap.zig instead.
    //
    const update_proto_step = b.step("update-proto", "Regenerate .proto MiniTables");
    const install_plugin = b.addInstallArtifact(plugin_exe, .{});
    update_proto_step.dependOn(&install_plugin.step);

    // Generate plugin.proto -> src/generated/plugin.pb.zig
    const plugin_proto_path = b.fmt("{s}/src/google/protobuf/compiler/plugin.proto", .{protobuf_src});
    const gen_plugin = b.addSystemCommand(&.{
        protoc_path,
        b.fmt("--plugin=protoc-gen-zig-pb={s}", .{b.getInstallPath(.bin, "protoc-gen-zig-pb")}),
        "--zig-pb_out=src/generated",
        b.fmt("-I{s}/src", .{protobuf_src}),
        plugin_proto_path,
    });
    gen_plugin.step.dependOn(&install_plugin.step);
    update_proto_step.dependOn(&gen_plugin.step);

    // Generate conformance.proto -> src/generated/conformance.pb.zig
    const conformance_proto_path = b.fmt("{s}/conformance/conformance.proto", .{protobuf_src});
    const gen_conformance = b.addSystemCommand(&.{
        protoc_path,
        b.fmt("--plugin=protoc-gen-zig-pb={s}", .{b.getInstallPath(.bin, "protoc-gen-zig-pb")}),
        "--zig-pb_out=src/generated",
        b.fmt("-I{s}/conformance", .{protobuf_src}),
        b.fmt("-I{s}/src", .{protobuf_src}),
        conformance_proto_path,
    });
    gen_conformance.step.dependOn(&install_plugin.step);
    update_proto_step.dependOn(&gen_conformance.step);

    // ========================================================================
    // Code Generation Integration Tests
    // ========================================================================

    const codegen_test_step = b.step("test-codegen-integration", "Generate and test code from test .proto files");
    codegen_test_step.dependOn(&install_plugin.step);

    // Generate test/protos/test_message.proto -> test/generated/test_message.pb.zig
    const test_proto_path = "test/protos/test_message.proto";
    const gen_test = b.addSystemCommand(&.{
        protoc_path,
        b.fmt("--plugin=protoc-gen-zig-pb={s}", .{b.getInstallPath(.bin, "protoc-gen-zig-pb")}),
        "--zig-pb_out=test/generated",
        "-Itest/protos",
        test_proto_path,
    });
    gen_test.step.dependOn(&install_plugin.step);
    codegen_test_step.dependOn(&gen_test.step);

    // Test that generated code compiles and works
    const codegen_integration_test = b.addTest(.{
        .name = "test-codegen-integration-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/codegen_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });
    codegen_integration_test.step.dependOn(&gen_test.step);
    const run_codegen_test = b.addRunArtifact(codegen_integration_test);
    codegen_test_step.dependOn(&run_codegen_test.step);

    // Add to main test step (optional - only run if generated files exist)
    const codegen_integration_test_optional = b.addTest(.{
        .name = "test-codegen-integration-optional",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/codegen_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(codegen_integration_test_optional).step);

    // ========================================================================
    // Build Checks
    // ========================================================================

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

    // ========================================================================
    // Differential Testing (proto-zig vs upb)
    // ========================================================================
    //
    // Compares proto-zig decode/encode against upb reference implementation.
    // Requires: upb amalgamation built via bazel in protobuf repo.
    // Build upb: cd $protobuf_src && bazelisk build //upb:amalgamation
    //
    // Generated proto-zig MiniTable for test schema
    const test_message_module = b.createModule(.{
        .root_source_file = b.path("src/testing/test_message.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "proto", .module = proto_module },
        },
    });

    const differential_test = b.addTest(.{
        .name = "test-differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/differential_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto", .module = proto_module },
                .{ .name = "test_message", .module = test_message_module },
            },
        }),
    });

    // Link upb amalgamation library and dependencies
    differential_test.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/bazel-bin/upb", .{protobuf_src}) });
    differential_test.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/bazel-bin/third_party/utf8_range", .{protobuf_src}) });
    differential_test.linkSystemLibrary("amalgamation");
    differential_test.linkSystemLibrary("utf8_range");
    differential_test.linkLibC();

    // Add upb include paths
    differential_test.addIncludePath(.{ .cwd_relative = b.fmt("{s}/bazel-bin/upb", .{protobuf_src}) });
    differential_test.addIncludePath(.{ .cwd_relative = protobuf_src });
    differential_test.addIncludePath(.{ .cwd_relative = b.fmt("{s}/third_party/utf8_range", .{protobuf_src}) });

    // Compile generated upb test schema files
    // Add project root so generated includes like "src/testing/test_message.upb_minitable.h" work
    differential_test.addIncludePath(b.path("."));
    // Add src/testing for direct header includes in @cImport
    differential_test.addIncludePath(b.path("src/testing"));
    differential_test.addCSourceFiles(.{
        .files = &.{
            "src/testing/test_message.upb.c",
            "src/testing/test_message.upb_minitable.c",
        },
        .flags = &.{"-std=c99"},
    });

    const run_differential_test = b.addRunArtifact(differential_test);
    const differential_step = b.step("test-differential", "Run differential tests (proto-zig vs upb)");
    differential_step.dependOn(&run_differential_test.step);
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
