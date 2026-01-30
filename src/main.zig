const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    var thread_safe_arena: std.heap.ThreadSafeAllocator = .{
        .child_allocator = init.arena.allocator(),
    };
    const arena = thread_safe_arena.allocator();

    const progress = std.Progress.start(init.io, .{});
    defer progress.end();

    const args = try init.minimal.args.toSlice(arena);
    const command = try cli.parse(arena, args, null);
    switch (command) {
        .install => |install_args| actions.install(init.io, init.gpa, arena, progress, install_args) catch |err| {
            fastExit(1);
            return err;
        },
        .build => |build_args| actions.build(init.io, init.gpa, arena, init.environ_map, build_args) catch |err| {
            fastExit(1);
            return err;
        },
        .help, .version => |str| {
            var stdout_buf: [1024]u8 = undefined;
            var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);

            const stdout: *std.Io.Writer = &stdout_w.interface;
            try stdout.print("{s}\n", .{str});
            try stdout.flush();
        },
        .setup => actions.setup(init.io, arena, progress) catch |err| {
            fastExit(1);
            return err;
        },
        .info => |package_name| actions.info(init.io, arena, package_name) catch |err| {
            fastExit(1);
            return err;
        },
        .gc => actions.gc(init.io) catch |err| {
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

test {
    _ = @import("string.zig");
}
