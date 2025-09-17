const std = @import("std");
const Allocator = std.mem.Allocator;
const Install = @import("Install.zig");

var stdout_buf: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
pub const stdout = &stdout_writer.interface;

var stderr_buf: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
pub const stderr = &stderr_writer.interface;

var stdin_buf: [64]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
pub const stdin = &stdin_reader.interface;

pub const Argument = union(enum) {
    install: InstallArgs,
    usage: []const u8,
    err_msg: []const u8,
    help: []const u8,
};

pub fn parseArgs(arena: Allocator, args: []const []const u8) !Argument {
    if (args.len == 0) return .{ .usage = usage };
    const first_arg = args[0];

    if (std.mem.eql(u8, first_arg, "install")) {
        return try parseInstallArgs(arena, args[1..]);
    }

    return .{ .err_msg = "Failed to parse arguments" };
}

fn parseInstallArgs(arena: Allocator, args: []const []const u8) !Argument {
    _ = arena;
    if (args.len == 0) {
        return .{ .err_msg = "no arguments passed to install cmd" };
    }

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            return .{ .help = "packa install <formula1> <formula2> ..." };
        }
    }

    return .{ .install = .{ .package_names = args } };
}

pub const InstallArgs = struct {
    package_names: []const []const u8,
};

pub const usage =
    \\Usage of packa
    \\
;
