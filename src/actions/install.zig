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

    // _ = progress;
    // _ = pub_key;
    try fetchPackages(io, gpa, fetch_list.values(), &pub_key, progress);

    log.debug("fetching {d} packages", .{fetch_list.count()});

    log.info("finished installing\n", .{});

    // for (args.package_names) |name| {
    //     try installPackage(io, gpa, progress, dir, name, args.approved);
    // }
}

fn fetchPackages(
    io: Io,
    gpa: Allocator,
    packages: []const Package,
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) !void {
    var fetch_progress = progress.start("fetching", packages.len);
    defer fetch_progress.end();

    const queue_buf = try gpa.alloc(anyerror!void, packages.len);
    defer gpa.free(queue_buf);
    var queue: Io.Queue(anyerror!void) = .init(queue_buf);

    var group: Io.Group = .init;
    defer group.cancel(io);

    for (packages) |*pkg| {
        group.async(io, fetchPackage, .{ io, gpa, pkg, &queue, pub_key, fetch_progress });
    }

    var n_fetched: usize = 0;
    while (queue.getOne(io)) |res| {
        if (res) {
            n_fetched += 1;
            if (n_fetched == packages.len) break;
            continue;
        } else |err| return err;
        std.debug.print("quing...\n", .{});
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => {
            unreachable;
        },
    }
    std.debug.print("finished fetching\n", .{});
}

fn fetchPackage(
    io: Io,
    gpa: Allocator,
    pkg: *const Package,
    queue: *Io.Queue(anyerror!void),
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) Io.Cancelable!void {
    defer std.debug.print("finished downloading .{s}\n", .{pkg.name});
    const result = pkg.fetch(io, gpa, pub_key, progress) catch |err| switch (err) {
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
