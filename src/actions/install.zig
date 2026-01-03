const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const zlua = @import("zlua");
const util = @import("../util.zig");
const cli = @import("../cli.zig");
const log = std.log;

pub fn install(
    io: Io,
    gpa: Allocator,
    progress: std.Progress.Node,
    env: *std.process.EnvMap,
    args: cli.InstallArgs,
) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    var home_dir = try Io.Dir.cwd().openDir(io, home_dir_path, .{});
    defer home_dir.close(io);

    try home_dir.createDirPath(io, ".local/share/packa");

    var fetch_group: Io.Group = .init;
    defer fetch_group.cancel(io);

    var initialized_packages: usize = 0;
    var packages = try arena.alloc(Package, args.package_names.len);
    defer for (0..initialized_packages) |i| packages[i].deinit();

    for (args.package_names, 0..) |name, i| {
        packages[i] = Package{
            .name = name,
            .version = undefined,
            .lua = .{ .gpa = gpa },
            .progress = progress,
        };
        try packages[i].lua.new(0);
        initialized_packages += 1;

        try packages[i].tryFetch(io, gpa, home_dir);
    }

    try fetch_group.await(io);
    std.debug.print("finished installing\n", .{});

    // for (args.package_names) |name| {
    //     try installPackage(io, gpa, progress, dir, name, args.approved);
    // }
}

fn installPackage(
    io: Io,
    gpa: Allocator,
    progress: std.Progress.Node,
    packa_dir: Io.Dir,
) !void {
    _ = io;
    _ = packa_dir;
    _ = progress;

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();
    _ = arena;
}

const Package = struct {
    name: []const u8,
    /// filled in by lua
    version: std.SemanticVersion,
    lua: zlua.State,
    progress: std.Progress.Node,

    fn deinit(self: *Package) void {
        self.lua.close();
    }

    /// Fetch a package and save it in cache if it is signed
    fn tryFetch(self: *Package, io: Io, gpa: Allocator, home_dir: Io.Dir) !void {
        const lua = self.lua;

        const packa_dir = try home_dir.openDir(io, ".local/share/packa", .{});
        defer packa_dir.close(io);

        const manifest = try util.getLuaScript(io, gpa, packa_dir, self.name);
        defer gpa.free(manifest);

        try lua.loadString(manifest);
        try lua.pcallk(0, 1, 0, 0, null);

        const lua_name = switch (lua.getField(-1, "name")) {
            .string => lua.toLString(-1),
            else => return error.WrongLuaType,
        };

        const version = switch (lua.getField(-2, "version")) {
            .string => lua.toLString(-1),
            else => return error.WrongLuaType,
        };

        std.debug.print("lua_name = {s}\n", .{lua_name});
        std.debug.print("version = {s}\n", .{version});

        self.version = try .parse(version);

        const name = self.name;

        var fetch_progress_name_buf: [256]u8 = undefined;
        const fetch_progrss = self.progress.start(try std.fmt.bufPrint(
            &fetch_progress_name_buf,
            "fetching: {s}",
            .{name},
        ), 1);
        defer fetch_progrss.end();

        const base_url = "http://localhost:8000";
        const binary_url = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}/{s}/{s}-{t}-{t}.tar.gz",
            .{ base_url, name, version, name, builtin.target.cpu.arch, builtin.os.tag },
        );
        defer gpa.free(binary_url);

        const minisig_url = try std.fmt.allocPrint(
            gpa,
            "{s}/{s}/{s}/{s}-{t}-{t}.tar.gz.minisig",
            .{ base_url, name, version, name, builtin.target.cpu.arch, builtin.os.tag },
        );
        defer gpa.free(minisig_url);

        const archive = try util.fetch(io, gpa, binary_url);
        defer gpa.free(archive);

        const minisig = try util.fetch(io, gpa, minisig_url);
        defer gpa.free(minisig);

        if (!try util.checkSignature(gpa, archive, minisig)) {
            return error.InvalidSignature;
        }

        std.debug.print("package signature matches\n", .{});
    }
};
