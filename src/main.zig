const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const util = @import("util.zig");

const Io = std.Io;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const log = std.log;

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

    var threaded_io: Io.Threaded = .init(gpa);
    defer threaded_io.deinit();

    const io = threaded_io.io();

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

    var stdout_buf: [64]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    const stdout: *std.Io.Writer = &stdout_w.interface;

    var stderr_buf: [64]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    const stderr: *Io.Writer = &stderr_w.interface;

    const parsed_args = try util.parseArgs(arena, args[1..]);
    switch (parsed_args) {
        .usage => |usage| {
            try stdout.print("{s}", .{usage});
            try stdout.flush();
        },
        .install => |install_args| {
            try actions.install(io, gpa, install_args, &env);
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
