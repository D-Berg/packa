const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Command = union(enum) {
    install: InstallArgs,
    help: []const u8,

    pub fn deinit(self: *Command, gpa: Allocator) void {
        switch (self.*) {
            .install => |install| {
                gpa.free(install.package_names);
            },
            .help => {},
        }
    }
};

const ArgIterator = struct {
    args: []const []const u8,
    idx: usize = 0,

    fn init(args: []const []const u8) ArgIterator {
        return .{ .args = args };
    }

    fn next(self: *ArgIterator) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        const arg = self.args[self.idx];
        self.idx += 1;
        return arg;
    }

    fn skip(self: *ArgIterator) bool {
        if (self.idx >= self.args.len) return false;
        self.idx += 1;
        return true;
    }

    fn remaining(self: *ArgIterator) ?[]const u8 {
        if (self.idx >= self.args.len) return null;
        return self.args[self.idx..];
    }
};

// TODO: add Diagnostic to cli parsing
pub const Diagnostic = struct {};

pub fn parse(gpa: Allocator, args: []const []const u8, diag: ?*Diagnostic) !Command {
    _ = diag;
    var arg_it: ArgIterator = .init(args);
    assert(arg_it.skip());

    const arg = arg_it.next() orelse return .{ .help = usage };
    if (std.mem.eql(u8, arg, "install")) {
        return try parseInstallArgs(&arg_it, gpa);
    }

    return error.UnknownCommand;
}

pub const InstallArgs = struct {
    package_names: []const []const u8,
    approved: bool,
    build_from_source: bool,
};
fn parseInstallArgs(args: *ArgIterator, gpa: Allocator) !Command {
    var approved: bool = false;
    var build_from_source: bool = false;

    var package_names: std.ArrayList([]const u8) = .empty;
    errdefer package_names.deinit(gpa);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            return .{ .help = "packa install <formula1> <formula2> ..." };
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            approved = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
            build_from_source = true;
        } else {
            try package_names.append(gpa, arg);
        }
    }

    return .{ .install = .{
        .package_names = try package_names.toOwnedSlice(gpa),
        .build_from_source = true,
        .approved = approved,
    } };
}

pub const usage =
    \\Usage of packa
    \\
;
