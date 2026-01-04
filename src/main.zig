const std = @import("std");
const builtin = @import("builtin");
const actions = @import("actions.zig");
const util = @import("util.zig");
const cli = @import("cli.zig");
const minizign = @import("minizign");

const Io = std.Io;
const log = std.log;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
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

    const progress = std.Progress.start(io, .{});
    defer progress.end();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var env = std.process.getEnvMap(arena) catch |err| {
        log.err("Could not get env map: {t}", .{err});
        return err;
    };

    const args = try std.process.argsAlloc(arena);

    var stdout_buf: [64]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_w.interface;

    const command = try cli.parse(arena, args, null);
    switch (command) {
        .install => |install_args| {
            checkSetup(io);
            actions.install(io, gpa, progress, install_args) catch |err| {
                fastExit(1);
                return err;
            };
        },
        .build => |build_args| {
            checkSetup(io);
            actions.build(io, gpa, &env, build_args) catch |err| {
                fastExit(1);
                return err;
            };
        },
        .help, .version => |str| {
            try stdout.print("{s}\n", .{str});
            try stdout.flush();
        },
        .setup => actions.setup(io, arena, progress) catch |err| {
            fastExit(1);
            return err;
        },
        // TODO: info
    }
}

/// Fast check and exit if packa is not setup
fn checkSetup(io: Io) void {
    Io.Dir.cwd().access(io, "/opt/packa", .{
        .read = true,
        .write = true,
        .follow_symlinks = false,
    }) catch |err| {
        // TODO: switch on error for better reporting
        switch (err) {
            else => {},
        }
        std.log.err("packa need access to '/opt/packa', try running 'packa setup'", .{});
        std.process.exit(1);
    };
}

/// To not print error stack trace and just fast exit depending on build mode
fn fastExit(status: u8) void {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => std.process.exit(status),
    }
}
