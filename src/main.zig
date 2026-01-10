const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const util = @import("util.zig");
const cli = @import("cli.zig");
const minizign = @import("minizign");

const Io = std.Io;
const log = std.log;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub fn main(init: std.process.Init.Minimal) !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var threaded_io: Io.Threaded = .init(gpa, .{ .environ = init.environ });
    defer threaded_io.deinit();

    const io = threaded_io.io();

    const progress = std.Progress.start(io, .{});
    defer progress.end();

    var arena_impl: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var env = init.environ.createMap(arena) catch |err| { // TODO: arena?
        log.err("Could not get env map: {t}", .{err});
        return err;
    };

    var stdout_buf: [64]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_w.interface;

    const args = try init.args.toSlice(arena);
    const command = try cli.parse(arena, args, null);
    switch (command) {
        .install => |install_args| actions.install(io, gpa, progress, install_args) catch |err| {
            fastExit(1);
            return err;
        },
        .build => |build_args| actions.build(io, gpa, &env, build_args) catch |err| {
            fastExit(1);
            return err;
        },
        .help, .version => |str| {
            try stdout.print("{s}\n", .{str});
            try stdout.flush();
        },
        .setup => actions.setup(io, arena, progress) catch |err| {
            fastExit(1);
            return err;
        },
        .info => |package_name| actions.info(io, gpa, package_name) catch |err| {
            fastExit(1);
            return err;
        },
    }
    fastExit(0);
}

/// To not print error stack trace and just fast exit depending on build mode
fn fastExit(status: u8) void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => std.process.exit(status),
    }
}
