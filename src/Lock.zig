const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Package = struct {
    name: []const u8,
    version: []const u8,
    id: []const u8,
};

pub const Shell = struct {
    config_hash: []const u8,
    name: []const u8,
    packages: []const Package,
};

pub const File = struct {
    version: u32 = 1,
    target: []const u8,
    shells: []const Shell,
};

pub fn configHash(io: Io, gpa: Allocator, config_path: []const u8, shell_name: []const u8) ![]const u8 {
    const source = try Io.Dir.cwd().readFileAllocOptions(
        io,
        config_path,
        gpa,
        .limited(1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(source);

    var digest: [32]u8 = undefined;
    var hash: std.crypto.hash.Blake3 = .init(.{});
    hash.update(source);
    hash.update(shell_name);
    hash.update(target);
    hash.final(&digest);
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}

pub fn read(io: Io, gpa: Allocator, path: []const u8) !?File {
    const contents = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(4 * 1024 * 1024),
        .of(u8),
        null,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(contents);

    const lock = try std.json.parseFromSliceLeaky(File, gpa, contents, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    if (lock.version != 1) return error.UnsupportedLockVersion;
    return lock;
}

pub fn write(io: Io, path: []const u8, lock: File) !void {
    const parent_path = std.fs.path.dirname(path) orelse ".";
    const file_name = std.fs.path.basename(path);
    const parent = try Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent.close(io);

    var atomic_file = try parent.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try std.json.Stringify.value(lock, .{ .whitespace = .indent_2 }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.flush();
    try atomic_file.replace(io);
}

pub fn shellEql(a: Shell, b: Shell) bool {
    if (!std.mem.eql(u8, a.config_hash, b.config_hash) or
        !std.mem.eql(u8, a.name, b.name) or
        a.packages.len != b.packages.len) return false;
    for (a.packages, b.packages) |a_pkg, b_pkg| {
        if (!std.mem.eql(u8, a_pkg.name, b_pkg.name) or
            !std.mem.eql(u8, a_pkg.version, b_pkg.version) or
            !std.mem.eql(u8, a_pkg.id, b_pkg.id)) return false;
    }
    return true;
}

pub fn findShell(lock: File, name: []const u8) ?Shell {
    for (lock.shells) |shell| {
        if (std.mem.eql(u8, shell.name, name)) return shell;
    }
    return null;
}

pub const target = std.fmt.comptimePrint("{t}-{t}", .{ builtin.cpu.arch, builtin.os.tag });

test "writes and reads a lock file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_impl: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var dir_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(testing.io, &dir_path_buf);
    const path = try std.fs.path.join(arena, &.{ dir_path_buf[0..dir_path_len], "packa.lock" });

    const expected: File = .{
        .target = "x86_64-linux",
        .shells = &.{.{
            .config_hash = "abc123",
            .name = "default",
            .packages = &.{.{
                .name = "zig",
                .version = "0.16.0",
                .id = "0123456789abcdef",
            }},
        }},
    };
    try write(testing.io, path, expected);

    const actual = (try read(testing.io, arena, path)).?;
    try testing.expectEqualStrings(expected.target, actual.target);
    try testing.expect(shellEql(expected.shells[0], actual.shells[0]));
}
