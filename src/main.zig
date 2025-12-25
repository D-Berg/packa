const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const util = @import("util.zig");
const cli = @import("cli.zig");

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

    var threaded_io: Io.Threaded = .init(gpa, .{});
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

    const command = try cli.parse(arena, args, null);
    switch (command) {
        .install => |install_args| {
            try actions.install(io, gpa, &env, install_args);
        },
        .help => |help| {
            var stdout_buf: [64]u8 = undefined;
            var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
            const stdout: *std.Io.Writer = &stdout_w.interface;

            try stdout.print("{s}\n", .{help});
            try stdout.flush();
        },
    }
}
