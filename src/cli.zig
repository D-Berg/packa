const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const build_options = @import("build_options");

pub const Command = union(enum) {
    install: InstallArgs,
    help: []const u8,
    build: BuildArgs,
    version: []const u8,

    pub fn deinit(self: *Command, gpa: Allocator) void {
        _ = gpa;
        switch (self.*) {
            .install => |install| {
                _ = install;
            },
            .help => {},
            .build => {},
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

    fn remaining(self: *ArgIterator) ?[]const []const u8 {
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
    } else if (std.mem.eql(u8, arg, "build")) {
        return try parseBuildArgs(&arg_it);
    } else if (std.mem.eql(u8, arg, "version")) {
        return .{ .version = build_options.version };
    }

    return error.UnknownCommand;
}

pub const InstallArgs = struct {
    package_names: []const []const u8,
    approved: bool,
    build_from_source: bool,
};
fn parseInstallArgs(args: *ArgIterator, gpa: Allocator) !Command {
    _ = gpa;

    var approved: bool = false;
    var build_from_source: bool = false;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h")) {
                return .{ .help = "packa install <formula1> <formula2> ..." };
            } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
                approved = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
                build_from_source = true;
            } else {
                return error.UnknowInstallFlag;
            }
        } else break;
    }

    const remaining = args.remaining() orelse
        return error.MissingInstallPackages;

    return .{ .install = .{
        .package_names = remaining,
        .build_from_source = true,
        .approved = approved,
    } };
}

pub const BuildArgs = struct {
    package_name: []const u8,
    prefix_path: []const u8,
};
fn parseBuildArgs(args: *ArgIterator) !Command {
    const package_name = args.next() orelse return error.BuildMissingPackageName;
    assert(args.skip());
    const prefix_path = args.next() orelse return error.BuildMissingPrefix;
    return .{ .build = .{
        .package_name = package_name,
        .prefix_path = prefix_path,
    } };
}

pub const usage =
    \\Usage of packa
    \\
;
