const std = @import("std");
const util = @import("../util.zig");
const Io = std.Io;

pub fn gc(io: Io) !void {
    try util.checkSetup(io);

    // TODO: delete only the ones that aren't reachable from
    // /opt/packa/active

    const store = try Io.Dir.cwd().openDir(io, "/opt/packa/store", .{ .iterate = true });
    defer store.close(io);
    var store_it = store.iterate();
    while (try store_it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                try store.deleteTree(io, entry.name);
            },
            else => {},
        }
    }
}
