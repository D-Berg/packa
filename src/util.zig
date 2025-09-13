const std = @import("std");

pub const Argument = union(enum) {
    install: Install,
    usage: []const u8,
    err_msg: []const u8,
};

pub fn parseArgs(args: []const []const u8) !Argument {
    if (args.len == 0) return .{ .usage = usage };
    const first_arg = args[0];

    if (std.mem.eql(u8, first_arg, "install")) return try parseInstallArgs(args[1..]);

    return .{ .err_msg = "Failed to parse arguments" };
}

pub const Install = struct {};
fn parseInstallArgs(args: []const []const u8) !Argument {
    _ = args;

    @panic("TODO");
}

pub const usage =
    \\Usage of packa
    \\
;
