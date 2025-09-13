const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const c = @import("c");
const lua = @import("lua.zig");

package_names: []const []const u8,

const Install = @This();
pub fn execute(self: *const Install, gpa: Allocator, env: std.process.EnvMap) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    const packa_path = try std.fmt.allocPrint(arena, "{s}/.local/share/packa", .{home_dir_path});

    var dir = blk: {
        if (std.fs.openDirAbsolute(packa_path, .{})) |dir| {
            break :blk dir;
        } else |err| {
            switch (err) {
                error.FileNotFound => {
                    try std.fs.makeDirAbsolute(packa_path);
                    break :blk try std.fs.openDirAbsolute(packa_path, .{});
                },
                else => return err,
            }
        }
    };
    defer dir.close();

    for (self.package_names) |name| {
        try installPackage(gpa, dir, name);
    }
}

fn installPackage(gpa: Allocator, packa_dir: std.fs.Dir, name: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    log.debug("installing package: {s}", .{name});

    const script = blk: {
        const script_path = try std.fmt.allocPrint(gpa, "formulas/{s}/{s}.lua", .{
            name[0..1], name,
        });
        defer gpa.free(script_path);
        const script_file = try packa_dir.openFile(script_path, .{});
        defer script_file.close();

        var read_buffer: [1024]u8 = undefined;
        var file_reader = script_file.reader(&read_buffer);

        var alloc_writer = std.Io.Writer.Allocating.init(arena);

        _ = try file_reader.interface.streamRemaining(&alloc_writer.writer);

        break :blk try alloc_writer.toOwnedSliceSentinel(0);
    };

    log.debug("{s}", .{script});

    const state = try lua.newStateAlloc(gpa);
    defer lua.close(state);

    lua.openLibs(state);

    try lua.loadString(state, script);
    try lua.pcallk(state);

    const lua_type = lua.getField(state, -1, "homepage");
    std.debug.print("type = {t}\n", .{lua_type});
    std.debug.print("{s}\n", .{lua.toLString(state, -1)});

    lua.remove(state, -1);
}
