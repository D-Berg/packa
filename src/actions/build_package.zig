const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const util = @import("../util.zig");
const zlua = @import("zlua");

const BuildArgs = cli.BuildArgs;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn build(io: Io, gpa: Allocator, env: *std.process.EnvMap, args: BuildArgs) !void {
    const home_dir_path = env.get("HOME") orelse {
        return error.MissingHomeEnv;
    };

    var home_dir = try Io.Dir.cwd().openDir(io, home_dir_path, .{});
    defer home_dir.close(io);

    const packa_dir = try home_dir.openDir(io, ".local/share/packa", .{});
    defer packa_dir.close(io);

    const manifest = try util.getLuaScript(io, gpa, packa_dir, args.package_name);
    defer gpa.free(manifest);

    std.debug.print("manifest: \n\n{s}\n\n", .{manifest});

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new();
    defer lua.close();

    lua.requiref("_G", zlua.Lib.base, true);

    try lua.loadString(manifest);
    try lua.pcallk(0, 1, 0, 0, null);

    const manifest_idx = lua.getTop();
    std.debug.print("manifest_idx = {d}\n", .{manifest_idx});

    const name = switch (lua.getField(manifest_idx, "name")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };

    std.debug.print("name = {s}\n", .{name});

    const src_url = switch (lua.getField(manifest_idx, "url")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };
    std.debug.print("src_url: {s}\n", .{src_url});

    if (lua.getField(manifest_idx, "build") != .function) {
        std.debug.print("lua: build is not a function\n", .{});
        return error.WrongLuaType;
    }

    // local ctx = {}
    lua.newTable();
    const ctx = lua.getTop();
    std.debug.print("ctx = {d}\n", .{ctx});

    var print_buf: [4096]u8 = undefined;

    // ctx["os"] = builtin.os.tag
    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.os.tag}));
    lua.setField(ctx, "os");

    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.cpu.arch}));
    lua.setField(ctx, "arch");

    // build(ctx)
    try lua.pcallk(1, 0, 0, 0, null);
}
