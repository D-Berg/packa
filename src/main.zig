const std = @import("std");
const builtin = @import("builtin");

const util = @import("util.zig");
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const log = std.log;

var stdout_buf: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
const stdout = &stdout_writer.interface;

var stderr_buf: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
const stderr = &stderr_writer.interface;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var env = std.process.getEnvMap(arena) catch |err| {
        log.err("Could not get env map: {t}", .{err});
        return err;
    };

    if (env.get("EDITOR")) |editor| {
        std.debug.print("editor = {s}\n", .{editor});
    } else {
        log.err("couldnt find editor env var\n", .{});
    }

    const args = try std.process.argsAlloc(arena);

    const parsed_args = try util.parseArgs(arena, args[1..]);
    switch (parsed_args) {
        .usage => |usage| {
            try stdout.print("{s}", .{usage});
            try stdout.flush();
        },
        .install => |install| {
            try install.execute(gpa, env);
        },
        .err_msg => |err_msg| {
            try stderr.print("error: {s}\n", .{err_msg});
            try stderr.flush();
        },
        .help => |help| {
            try stdout.print("{s}\n", .{help});
            try stdout.flush();
        },
    }
}
