const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;

package_names: []const []const u8,

const Install = @This();
pub fn execute(self: *const Install, gpa: Allocator, env: std.process.EnvMap) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    const packa_path = try std.fmt.allocPrint(arena, "{s}/.local/packa", .{home_dir_path});

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
    _ = gpa;
    _ = packa_dir;

    log.debug("installing package: {s}", .{name});
}
