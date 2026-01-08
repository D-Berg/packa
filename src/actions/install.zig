const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const zlua = @import("zlua");
const minizign = @import("minizign");

const util = @import("../util.zig");
const cli = @import("../cli.zig");
const lua_helpers = @import("../lua_helpers.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.install);

pub fn install(
    io: Io,
    gpa: Allocator,
    progress: std.Progress.Node,
    args: cli.InstallArgs,
) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    // var fetch_group: Io.Group = .init;
    // defer fetch_group.cancel(io);
    //

    const packa_dir = try Io.Dir.cwd().openDir(io, "/opt/packa", .{});
    defer packa_dir.close(io);

    const repo_sig = try packa_dir.readFileAllocOptions(io, "repos/core/minisign.pub.minisig", gpa, .limited(1024), .@"8", null);
    defer gpa.free(repo_sig);

    const repo_pub_key = try packa_dir.readFileAllocOptions(io, "repos/core/minisign.pub", gpa, .limited(1024), .@"8", null);
    defer gpa.free(repo_pub_key);

    var sig = try minizign.Signature.decode(gpa, repo_sig);
    defer sig.deinit();

    // verify repo
    // TODO: load from config to support several repos
    const maintainer_pub_key = try minizign.PublicKey.decodeFromBase64(build_options.pub_key);
    var verifier = try maintainer_pub_key.verifier(&sig);
    verifier.update(repo_pub_key);
    try verifier.verify(gpa);

    var pub_keys_buf: [1]minizign.PublicKey = undefined;
    const pub_keys = try minizign.PublicKey.decode(&pub_keys_buf, repo_pub_key);

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

        try packages[i].tryFetch(io, gpa, &pub_keys[0]);
    }

    // try fetch_group.await(io);
    log.info("finished installing\n", .{});

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

    /// Fetch a binary package and save it in cache if it is signed
    fn tryFetch(self: *Package, io: Io, gpa: Allocator, pub_key: *const minizign.PublicKey) !void {
        const lua = self.lua;

        const packa_dir = try Io.Dir.cwd().openDir(io, "/opt/packa", .{});
        defer packa_dir.close(io);

        assert(self.name.len > 0);
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const manifest_path = try std.fmt.bufPrint(&path_buf, "repos/core/manifests/{c}/{s}.lua", .{
            self.name[0],
            self.name,
        });
        const man_stat = try packa_dir.statFile(io, manifest_path, .{});
        const manifest = try packa_dir.readFileAllocOptions(io, manifest_path, gpa, .limited64(man_stat.size + 1), .@"8", 0);
        defer gpa.free(manifest);

        lua_helpers.setupState(&lua);

        try lua.loadString(manifest);
        lua.pcall(0, 1, 0) catch {
            log.err("{s}", .{lua.toLString(-1)});
            return error.ManifestCrash;
        };

        const pkg = lua.getTop();
        const lua_name = switch (lua.getField(pkg, "name")) {
            .string => lua.toLString(-1),
            else => return error.WrongLuaType,
        };

        const version = switch (lua.getField(pkg, "version")) {
            .string => lua.toLString(-1),
            else => return error.WrongLuaType,
        };

        std.debug.print("lua_name = {s}\n", .{lua_name});
        std.debug.print("version = {s}\n", .{version});

        self.version = try .parse(version);

        const name = self.name;

        var fetch_progress_name_buf: [256]u8 = undefined;
        const fetch_progrss = self.progress.start(
            try std.fmt.bufPrint(&fetch_progress_name_buf, "fetching: {s}", .{name}),
            1,
        );
        defer fetch_progrss.end();

        const base_url = "http://localhost:8000"; // TODO get from fn since it can be from multible mirrors
        const binary_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}-{s}-{t}-{t}.tar.zst", .{
            base_url, name, version, name, version, builtin.target.cpu.arch, builtin.os.tag,
        });
        defer gpa.free(binary_url);

        const minisig_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}-{s}-{t}-{t}.tar.zst.minisig", .{
            base_url, name, version, name, version, builtin.target.cpu.arch, builtin.os.tag,
        });
        defer gpa.free(minisig_url);

        var archive_fut = io.async(util.fetch, .{ io, gpa, binary_url });
        defer if (archive_fut.cancel(io)) |archive| gpa.free(archive) else |_| {};

        var package_sig_fut = io.async(util.fetch, .{ io, gpa, minisig_url });
        defer if (package_sig_fut.cancel(io)) |minisig| gpa.free(minisig) else |_| {};

        const archive = try archive_fut.await(io);
        const packa_sig = try package_sig_fut.await(io); // sig of archive

        var sig = try minizign.Signature.decode(gpa, packa_sig);
        defer sig.deinit();

        var verifier = try pub_key.verifier(&sig);
        verifier.update(archive);
        try verifier.verify(gpa);

        log.debug("package signature matches\n", .{});
    }
};
