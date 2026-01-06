const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const build_options = @import("build_options");

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const Command = union(enum) {
    install: InstallArgs,
    help: []const u8,
    build: BuildArgs,
    version: []const u8,
    setup,
    info: []const u8,

    pub fn deinit(self: *Command, gpa: Allocator) void {
        switch (self.*) {
            .install => |install| {
                gpa.free(install.package_names);
            },
            .help, .build, .version, .setup, .info => {},
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
    if (eql(arg, "install")) {
        return try parseInstallArgs(&arg_it, gpa);
    } else if (eql(arg, "build")) {
        return try parseBuildArgs(&arg_it);
    } else if (eql(arg, "version")) {
        return .{ .version = build_options.version };
    } else if (eql(arg, "setup")) {
        return .setup;
    } else if (eql(arg, "info")) {
        return try parseInfoArgs(&arg_it);
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
        if (std.mem.startsWith(u8, arg, "-")) {
            if (eql(arg, "-h")) {
                return .{ .help = "packa install <formula1> <formula2> ..." };
            } else if (eql(arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
                approved = true;
            } else if (eql(arg, "-s") or std.mem.eql(u8, arg, "--source")) {
                build_from_source = true;
            } else {
                return error.UnknowInstallFlag;
            }
        } else try package_names.append(gpa, arg);
    }

    return .{ .install = .{
        .package_names = try package_names.toOwnedSlice(gpa),
        .build_from_source = true,
        .approved = approved,
    } };
}

pub const BuildArgs = struct {
    package_name: []const u8,
    prefix_path: []const u8,
    verbose: bool = false,
};
fn parseBuildArgs(args: *ArgIterator) !Command {
    var build_args: BuildArgs = .{
        .package_name = undefined,
        .prefix_path = "/opt/packa/tmp",
    };
    build_args.package_name = args.next() orelse return error.BuildMissingPackageName;

    while (args.next()) |arg| {
        if (eql(arg, "-p") or eql(arg, "--prefix")) {
            const next = args.next() orelse return error.BuildMissingPrefixPath;
            build_args.prefix_path = next;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            build_args.verbose = true;
        }
    }

    return .{ .build = build_args };
}

fn parseInfoArgs(args: *ArgIterator) !Command {
    const package_name = args.next() orelse return error.InfoMissingPackageName;
    return .{ .info = package_name };
}

pub const usage =
    \\Usage of packa
    \\
;

// TODO: test cli parsing
