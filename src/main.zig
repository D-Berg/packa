const std = @import("std");
const builtin = @import("builtin");
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const log = std.log;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var env_map = std.process.getEnvMap(arena) catch |err| {
        log.err("Could not get env map: {t}", .{err});
        return err;
    };

    if (env_map.get("EDITOR")) |editor| {
        std.debug.print("editor = {s}\n", .{editor});
    } else {
        log.err("couldnt find editor env var\n", .{});
    }

    std.debug.print("hello world\n", .{});
}
