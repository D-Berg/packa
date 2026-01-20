const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Package = @import("../Package.zig");
const string = @import("../string.zig");
const String = string.State;

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

    const repo_sig = try packa_dir.readFileAllocOptions(
        io,
        "repos/core/minisign.pub.minisig",
        gpa,
        .limited(1024),
        .@"8",
        null,
    );
    defer gpa.free(repo_sig);

    const repo_pub_key = try packa_dir.readFileAllocOptions(
        io,
        "repos/core/minisign.pub",
        gpa,
        .limited(1024),
        .@"8",
        null,
    );
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

    var state: Package.State = .empty;
    defer state.deinit(gpa);

    var package_ids: std.ArrayList(Package.Id) = try .initCapacity(gpa, args.package_names.len);
    defer package_ids.deinit(gpa);

    for (args.package_names) |name| {
        package_ids.appendAssumeCapacity(try Package.collect(io, gpa, &state, packa_dir, name, &lua, true));
    }

    const store_dir = try packa_dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    // TODO: check store if package already is installed

    const cache_dir = try packa_dir.openDir(io, "cache", .{});
    defer cache_dir.close(io);

    try fetchPackages(io, gpa, cache_dir, &state, &pub_key, progress);

    for (package_ids.items) |id| {
        const idx = state.package_table.get(id) orelse return error.MissingPackageIdx;
        const pkg = state.packages.get(@intFromEnum(idx));
        // TODO: install runtime deps first recursively
        // for (pkg.runtime_deps.items) |dep_id| {}
        //

        try installPackage(io, gpa, &pkg, id, &state.string_state, store_dir, cache_dir);
    }

    log.debug("finished installing\n", .{});
}

fn fetchPackages(
    io: Io,
    gpa: Allocator,
    cahce_dir: Io.Dir,
    resolved: *const Package.State,
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) !void {
    const package_count = resolved.package_table.count();

    var fetch_progress = progress.start("fetching", package_count);
    defer fetch_progress.end();

    const queue_buf = try gpa.alloc(anyerror!void, package_count);
    defer gpa.free(queue_buf);
    var queue: Io.Queue(anyerror!void) = .init(queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    var fetch_count: usize = 0;
    const pkg_slice = resolved.packages.slice();
    var it = resolved.package_table.iterator();
    while (it.next()) |entry| {
        const pkg_id = entry.key_ptr.*;
        const pkg_idx = entry.value_ptr.*;
        const name = pkg_slice.items(.name)[@intFromEnum(pkg_idx)];
        const version = pkg_slice.items(.version)[@intFromEnum(pkg_idx)];

        const path = try std.fmt.bufPrint(&path_buf, "{s}-{f}-{s}.tar.zst", .{
            name.slice(&resolved.string_state), version, pkg_id.slice(&resolved.string_state)[0..32],
        });
        cahce_dir.access(io, path, .{}) catch {
            // try fetchPackage(io, gpa, pkg_id, pkg_idx, pkg_slice, &resolved.string_state, &queue, pub_key, fetch_progress);
            group.async(io, fetchPackage, .{
                io, gpa, pkg_id, pkg_idx, pkg_slice, &resolved.string_state, &queue, pub_key, fetch_progress,
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
    pkg_id: Package.Id,
    pkg_idx: Package.Idx,
    packages_slice: std.MultiArrayList(Package).Slice,
    string_state: *const string.State,
    queue: *Io.Queue(anyerror!void),
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) Io.Cancelable!void {
    const name = packages_slice.items(.name)[@intFromEnum(pkg_idx)];
    const name_slice = name.slice(string_state);
    const version = packages_slice.items(.version)[@intFromEnum(pkg_idx)];
    const pkg_id_slice = pkg_id.slice(string_state);

    defer std.debug.print("finished downloading {s}\n", .{name_slice});
    const result = fetch(io, gpa, name_slice, version, pkg_id_slice, pub_key, progress) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => |e| e, // other errors go in the result queue
    };
    queue.putOne(io, result) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => unreachable, // `queue` must not be closed
    };
}

fn installPackage(
    io: Io,
    gpa: Allocator,
    pkg: *const Package,
    id: Package.Id,
    string_state: *const string.State,
    store_dir: Io.Dir,
    cache_dir: Io.Dir,
) !void {
    var archive_name_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    const pkg_name = pkg.name.slice(string_state);

    const archive_path = try std.fmt.bufPrint(&archive_name_buf, "{s}-{f}-{s}.tar.zst", .{
        pkg_name, pkg.version, id.slice(string_state)[0..32],
    });

    std.debug.print("{s}\n", .{archive_path});

    const archive = try cache_dir.openFile(io, archive_path, .{});
    defer archive.close(io);

    var archive_reader_buf: [16_392]u8 = undefined;
    var archive_reader = archive.reader(io, &archive_reader_buf);

    const root = try util.extractArchive(io, gpa, &archive_reader.interface, store_dir, .zst);
    defer gpa.free(root);

    try store_dir.access(io, root, .{});

    if (pkg.install) {
        // TODO: link if
        // - man
        // - libs
        // - check if package even have bin, man, lib and so on
        const pkg_dir = try store_dir.openDir(io, root, .{});
        defer pkg_dir.close(io);

        var sym_link_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const sym_link_path = try std.fmt.bufPrint(&sym_link_path_buf, "/opt/packa/bin/{s}", .{pkg_name});

        var target_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const target_path = try std.fmt.bufPrint(&target_path_buf, "/opt/packa/store/{s}/bin/{s}", .{ root, pkg_name });

        try pkg_dir.symLinkAtomic(io, target_path, sym_link_path, .{ .is_directory = false });
    }
}

/// Fetch a binary package and save it in cache if it is signed
pub fn fetch(
    io: Io,
    gpa: Allocator,
    name: []const u8,
    version: std.SemanticVersion,
    id: []const u8,
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) !void {
    assert(name.len > 0);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var timer: std.time.Timer = try .start();

    var fetch_progress_name_buf: [256]u8 = undefined;
    const fetch_progress = progress.start(
        try std.fmt.bufPrint(&fetch_progress_name_buf, "{s}-{f}", .{ name, version }),
        1,
    );
    defer fetch_progress.end();

    // TODO: use hash
    const archive_name = try std.fmt.allocPrint(arena, "{s}-{f}-{s}.tar.zst", .{
        name, version, id[0..32],
    });
    const sig_name = try std.fmt.allocPrint(arena, "{s}-{f}-{s}.tar.zst.minisig", .{
        name, version, id[0..32],
    });

    const base_url = "https://cdn.packa.dev"; // TODO get from fn since it can be from multible mirrors
    const binary_url = try std.fmt.allocPrint(arena, "{s}/{s}/{f}/{s}", .{
        base_url, name, version, archive_name,
    });
    const minisig_url = try std.fmt.allocPrint(arena, "{s}/{s}/{f}/{s}", .{
        base_url, name, version, sig_name,
    });

    var archive_fut = io.async(util.fetch, .{ io, gpa, binary_url });
    defer if (archive_fut.cancel(io)) |archive| gpa.free(archive) else |_| {};

    var package_sig_fut = io.async(util.fetch, .{ io, gpa, minisig_url });
    defer if (package_sig_fut.cancel(io)) |minisig| gpa.free(minisig) else |_| {};

    const archive = try archive_fut.await(io);
    const archive_sig = try package_sig_fut.await(io); // sig of archive

    std.debug.print("fetched {s} in {D}\n", .{ name, timer.lap() });

    var sig = try minizign.Signature.decode(gpa, archive_sig);
    defer sig.deinit();

    var verifier = try pub_key.verifier(&sig);
    verifier.update(archive);
    try verifier.verify(gpa);

    const cache_dir = try Io.Dir.cwd().openDir(io, "/opt/packa/cache", .{});
    defer cache_dir.close(io);

    try cache_dir.writeFile(io, .{ .data = archive, .sub_path = archive_name });
    try cache_dir.writeFile(io, .{ .data = archive_sig, .sub_path = sig_name });

    std.debug.print("verified {s} in {D}\n", .{ name, timer.lap() });

    log.debug("package signature matches\n", .{});
}
