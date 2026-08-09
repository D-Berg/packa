const std = @import("std");
const Config = @import("../Config.zig");
const cli = @import("../cli.zig");
const installer = @import("install.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn apply(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    progress: std.Progress.Node,
    environ: *const std.process.Environ.Map,
    args: cli.ApplyArgs,
) !void {
    const path = if (args.config_path) |path|
        path
    else blk: {
        const home = environ.get("HOME") orelse return error.HomeNotSet;
        break :blk try std.fs.path.join(arena, &.{ home, ".config", "packa", "init.lua" });
    };

    const config = try Config.load(io, arena, path, null);
    try installer.install(io, gpa, arena, progress, .{
        .package_names = config.packages,
        .approved = args.approved,
        .build_from_source = config.build_from_source,
        .link_global = true,
    });
}
