const std = @import("std");
const Allocator = std.mem.Allocator;
const Install = @import("Install.zig");

pub const Argument = union(enum) {
    install: Install,
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
            return .{ .help = "packa install formula1 formula2 ..." };
        }
    }

    return .{ .install = .{ .package_names = args } };
}

pub const usage =
    \\Usage of packa
    \\
;
