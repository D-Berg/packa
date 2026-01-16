const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const build_options = @import("build_options");

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

pub const usage =
    \\usage: packa [command] [options]
    \\
    \\Commands:
    \\
    \\  install          Install a pre-built package
    \\  build            Build a package from source
    \\  info             Print info of package and exit
    \\  setup            Setup packa in /opt/packa 
    \\  version          Print version number and exit
    \\
    \\General Options:
    \\
    \\  -h, --help       Print command-specific usage
;

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
    } else if (eql(arg, "-h") or eql(arg, "--help")) {
        return .{ .help = usage };
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
    archive: bool = false,
    compress: bool = false,
    sign: bool = false,
    verbose: bool = false,
};
fn parseBuildArgs(args: *ArgIterator) !Command {
    var build_args: BuildArgs = .{
        .package_name = "",
        .prefix_path = "/opt/packa/tmp",
    };
    while (args.next()) |arg| {
        if (startWith(arg, "--")) {
            if (eql(arg, "--prefix")) {
                const next = args.next() orelse return error.BuildMissingPrefixPath;
                build_args.prefix_path = next;
            } else if (eql(arg, "--verbose")) {
                build_args.verbose = true;
            } else if (eql(arg, "--archive")) {
                build_args.archive = true;
            } else if (eql(arg, "--compress")) {
                build_args.compress = true;
            } else if (eql(arg, "--sign")) {
                build_args.sign = true;
            }
        } else if (startWith(arg, "-")) {
            for (arg[1..], 1..) |c, i| switch (c) {
                'p' => {
                    if (i != arg.len) return error.WrongFlagPosition;
                    const next = args.next() orelse return error.BuildMissingPrefixPath;
                    build_args.prefix_path = next;
                },
                'v' => build_args.verbose = true,
                'a' => build_args.archive = true,
                'c' => build_args.compress = true,
                's' => build_args.sign = true,
                else => return error.UnknownFlag,
            };
        } else {
            if (build_args.package_name.len != 0) return error.PackageNameAlreadySet;
            assert(arg.len != 0);
            build_args.package_name = arg;
        }
    }

    return .{ .build = build_args };
}

fn parseInfoArgs(args: *ArgIterator) !Command {
    const package_name = args.next() orelse return error.InfoMissingPackageName;
    return .{ .info = package_name };
}

// TODO: make a fatal function with no return

// TODO: test cli parsing
