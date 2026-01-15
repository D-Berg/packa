const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Package = @import("../Package.zig");

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
    arena: Allocator,
    progress: std.Progress.Node,
    args: cli.InstallArgs,
) !void {
    try util.checkSetup(io);
    _ = arena;

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
    const pub_key = pub_keys[0];

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();
    lua_helpers.setupState(&lua);

    var fetch_list: Package.Map = .empty;
    defer {
        var it = fetch_list.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        fetch_list.deinit(gpa);
    }

    try Package.collect(io, gpa, packa_dir, args.package_names, &fetch_list, &lua, null, true);

    const store = try packa_dir.openDir(io, "store", .{});
    defer store.close(io);
    // TODO: check store if package already is installed

    const cache_dir = try packa_dir.openDir(io, "cache", .{});
    defer cache_dir.close(io);

    try fetchPackages(io, gpa, cache_dir, &fetch_list, &pub_key, progress);

    var archive_name_buf: [Io.Dir.max_name_bytes]u8 = undefined;
    var it = fetch_list.iterator();
    while (it.next()) |entry| {
        const hash = entry.key_ptr.*;
        const pkg = entry.value_ptr;
        const archive_path = try std.fmt.bufPrint(&archive_name_buf, "{s}-{f}-{s}.tar.zst", .{
            pkg.name, pkg.version, hash[0..32],
        });

        std.debug.print("{s}\n", .{archive_path});

        const archive = try cache_dir.openFile(io, archive_path, .{});
        defer archive.close(io);

        var archive_reader_buf: [16_392]u8 = undefined;
        var archive_reader = archive.reader(io, &archive_reader_buf);

        const root = try util.extractArchive(io, gpa, &archive_reader.interface, store, .zst);
        defer gpa.free(root);

        try store.access(io, root, .{});

        if (pkg.install) {
            // TODO: link if
            // - man
            // - libs
            // - check if package even have bin, man, lib and so on
            const pkg_dir = try store.openDir(io, root, .{});
            defer pkg_dir.close(io);

            var sym_link_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const sym_link_path = try std.fmt.bufPrint(&sym_link_path_buf, "/opt/packa/bin/{s}", .{pkg.name});

            var target_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const target_path = try std.fmt.bufPrint(&target_path_buf, "/opt/packa/store/{s}/bin/{s}", .{ root, pkg.name });

            try pkg_dir.symLinkAtomic(io, target_path, sym_link_path, .{ .is_directory = false });
        }
    }

    log.debug("finished installing\n", .{});
}

fn fetchPackages(
    io: Io,
    gpa: Allocator,
    cahce_dir: Io.Dir,
    packages: *Package.Map,
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) !void {
    var fetch_progress = progress.start("fetching", packages.count());
    defer fetch_progress.end();

    const queue_buf = try gpa.alloc(anyerror!void, packages.count());
    defer gpa.free(queue_buf);
    var queue: Io.Queue(anyerror!void) = .init(queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    var fetch_count: usize = 0;
    var it = packages.iterator();
    while (it.next()) |entry| {
        const path = try std.fmt.bufPrint(&path_buf, "{s}-{f}-{s}.tar.zst", .{
            entry.value_ptr.name, entry.value_ptr.version, entry.key_ptr.*[0..32],
        });
        cahce_dir.access(io, path, .{}) catch {
            group.async(io, fetchPackage, .{
                io, gpa, entry.key_ptr.*, entry.value_ptr, &queue, pub_key, fetch_progress,
            });
            fetch_count += 1;
            continue;
        };
    }

    if (fetch_count == 0) return;

    var n_fetched: usize = 0;
    while (queue.getOne(io)) |res| {
        if (res) {
            n_fetched += 1;
            if (n_fetched >= fetch_count) break;
            continue;
        } else |err| return err;
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => unreachable,
    }
}

fn fetchPackage(
    io: Io,
    gpa: Allocator,
    pkg_hash: []const u8,
    pkg: *const Package,
    queue: *Io.Queue(anyerror!void),
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) Io.Cancelable!void {
    defer std.debug.print("finished downloading {s}\n", .{pkg.name});
    const result = pkg.fetch(io, gpa, pkg_hash, pub_key, progress) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| e, // other errors go in the result queue
    };
    queue.putOne(io, result) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => unreachable, // `queue` must not be closed
    };
}
