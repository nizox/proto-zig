///! Protoc plugin for generating Zig MiniTable definitions from .proto files.
///!
///! This plugin implements the protoc plugin protocol (google.protobuf.compiler.plugin.proto):
///! - Reads CodeGeneratorRequest from stdin (binary protobuf)
///! - Generates .zig files with MiniTable definitions
///! - Writes CodeGeneratorResponse to stdout (binary protobuf)
const std = @import("std");
const proto = @import("proto");
const Arena = proto.Arena;
const Message = proto.Message;
const StringView = proto.StringView;
const RepeatedField = proto.RepeatedField;
const decode = proto.decode;
const encode = proto.encode;
const bootstrap = proto.bootstrap;
const descriptor_parser = @import("descriptor_parser.zig");
const layout = @import("layout.zig");
const linker = @import("linker.zig");
const generator = @import("generator.zig");

pub fn main() !void {
    // Setup allocators
    // GPA for both arena buffer and code generation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Allocate arena buffer on heap (16MB would exceed stack limit)
    const arena_buffer = try allocator.alloc(u8, 16 * 1024 * 1024);
    defer allocator.free(arena_buffer);
    var arena = Arena.initBuffer(arena_buffer, null);

    // Read CodeGeneratorRequest from stdin
    const stdin = std.fs.File.stdin();
    const input = stdin.readToEndAlloc(allocator, 10_000_000) catch |err| {
        std.debug.print("Error reading stdin: {}\n", .{err});
        return err;
    };
    defer allocator.free(input);

    std.debug.print("Read {} bytes from stdin\n", .{input.len});

    // Decode CodeGeneratorRequest using bootstrap tables
    const request_msg = Message.new(&arena, &bootstrap.code_generator_request_table) orelse {
        std.debug.print("Error: failed to allocate request message\n", .{});
        return error.OutOfMemory;
    };

    std.debug.print("Allocated request message, decoding...\n", .{});

    decode(input, request_msg, &arena, .{ .alias_string = true }) catch |err| {
        std.debug.print("Error decoding request: {}\n", .{err});
        const error_msg = std.fmt.allocPrint(allocator, "Failed to decode request: {}", .{err}) catch "Failed to decode request";
        try writeErrorResponse(error_msg, &arena);
        return;
    };

    std.debug.print("Successfully decoded request\n", .{});

    // Parse descriptor into FileInfo structures
    const parsed = descriptor_parser.parseRequest(request_msg, allocator) catch |err| {
        // Build error response
        const error_msg = std.fmt.allocPrint(allocator, "Failed to parse request: {}", .{err}) catch "Failed to parse request";
        try writeErrorResponse(error_msg, &arena);
        return;
    };

    // Compute layout for all messages (across all files, including dependencies)
    for (parsed.all_files) |*file| {
        for (file.messages) |*msg| {
            layout.computeLayoutRecursive(msg, allocator) catch |err| {
                const error_msg = std.fmt.allocPrint(allocator, "Failed to compute layout for {s}: {}", .{ file.name, err }) catch "Failed to compute layout";
                try writeErrorResponse(error_msg, &arena);
                return;
            };
        }
    }

    // Link submessages using global symbol table (across all files)
    linker.linkFiles(parsed.all_files, allocator) catch |err| {
        const error_msg = std.fmt.allocPrint(allocator, "Failed to link: {}", .{err}) catch "Failed to link";
        try writeErrorResponse(error_msg, &arena);
        return;
    };

    // Generate code only for files_to_generate
    var generated_files: std.ArrayList(generator.GeneratedFile) = .empty;
    errdefer generated_files.deinit(allocator);

    for (parsed.files_to_generate) |*file| {
        // Generate code
        const gen_file = generator.generateFile(file.*, allocator) catch |err| {
            const error_msg = std.fmt.allocPrint(allocator, "Failed to generate {s}: {}", .{ file.name, err }) catch "Failed to generate";
            try writeErrorResponse(error_msg, &arena);
            return;
        };

        try generated_files.append(allocator, gen_file);
    }

    // Build and encode response
    try writeSuccessResponse(try generated_files.toOwnedSlice(allocator), &arena);
}

/// Write a successful CodeGeneratorResponse to stdout.
fn writeSuccessResponse(generated_files: []const generator.GeneratedFile, arena: *Arena) !void {
    // Create response message
    const response_msg = Message.new(arena, &bootstrap.code_generator_response_table) orelse return error.OutOfMemory;

    // Populate file field (field 15) with generated files
    if (generated_files.len > 0) {
        const files_field = response_msg.table.field_by_number(15) orelse return error.InvalidTable;

        // Get the repeated field from the message
        const repeated = response_msg.get_repeated(files_field);

        // Allocate data for all file messages
        const data_size: u32 = @intCast(generated_files.len * @sizeOf(*Message));
        const data = arena.alloc(u8, data_size) orelse return error.OutOfMemory;

        repeated.* = RepeatedField{
            .data = data.ptr,
            .count = @intCast(generated_files.len),
            .capacity = @intCast(generated_files.len),
            .element_size = @sizeOf(*Message),
        };

        // Create each file message and store pointer in repeated field
        for (generated_files, 0..) |gen_file, i| {
            const file_msg = Message.new(arena, &bootstrap.code_generator_response_file_table) orelse return error.OutOfMemory;

            // Set name field (field 1)
            const name_field = file_msg.table.field_by_number(1) orelse return error.InvalidTable;
            file_msg.set_scalar(name_field, .{ .string_val = StringView.from_slice(gen_file.name) });

            // Set content field (field 15)
            const content_field = file_msg.table.field_by_number(15) orelse return error.InvalidTable;
            file_msg.set_scalar(content_field, .{ .string_val = StringView.from_slice(gen_file.content) });

            // Store pointer in repeated field data
            const offset = i * @sizeOf(*Message);
            const ptr_slot = @as(*?*Message, @ptrCast(@alignCast(data[offset .. offset + @sizeOf(*Message)].ptr)));
            ptr_slot.* = file_msg;
        }
    }

    // Encode and write to stdout
    const encoded = try encode(response_msg, arena, .{});

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(encoded);
}

/// Write an error CodeGeneratorResponse to stdout.
fn writeErrorResponse(error_message: []const u8, arena: *Arena) !void {
    // Create response message
    const response_msg = Message.new(arena, &bootstrap.code_generator_response_table) orelse return error.OutOfMemory;

    // Set error field (field 1)
    const error_field = response_msg.table.field_by_number(1) orelse return error.InvalidTable;
    response_msg.set_scalar(error_field, .{ .string_val = StringView.from_slice(error_message) });

    // Encode and write to stdout
    const encoded = try encode(response_msg, arena, .{});

    const stdout = std.fs.File.stdout();
    try stdout.writeAll(encoded);
}

test {
    _ = @import("descriptor_parser.zig");
    _ = @import("generator.zig");
    _ = @import("layout.zig");
    _ = @import("linker.zig");
    _ = @import("names.zig");
}
