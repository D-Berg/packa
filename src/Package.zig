const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const minizign = @import("minizign");
const util = @import("util.zig");
const lua_helpers = @import("lua_helpers.zig");
const log = std.log;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Package = @This();

name: []const u8,
/// filled in by lua
version: std.SemanticVersion,
// TODO: homepage, ... and other fields
lua_idx: i32,
desc: []const u8,
homepage: []const u8,
license: []const u8,
source_url: []const u8,
source_hash: []const u8,
compile_deps: std.ArrayList([]const u8) = .empty,
runtime_deps: std.ArrayList([]const u8) = .empty,
install: bool = false,

pub fn init(
    io: Io,
    gpa: Allocator,
    packa_dir: Io.Dir,
    repo: []const u8,
    name: []const u8,
    lua: *const zlua.State,
    hash: ?*std.crypto.hash.Blake3,
) !Package {
    assert(name.len > 0);
    assert(repo.len > 0);
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrintZ(&path_buf, "@/opt/packa/repos/{s}/manifests/{c}/{s}.lua", .{
        repo, name[0], name,
    });
    const manifest_stat = try packa_dir.statFile(io, manifest_path[1..], .{ .follow_symlinks = true });
    const manifest = try packa_dir.readFileAllocOptions(io, manifest_path[1..], gpa, .limited64(manifest_stat.size + 1), .of(u8), 0);
    defer gpa.free(manifest);

    var os_buf: [64]u8 = undefined;
    var arch_buf: [64]u8 = undefined;

    const os = try std.fmt.bufPrint(&os_buf, "{t}", .{builtin.target.os.tag});
    const arch = try std.fmt.bufPrint(&arch_buf, "{t}", .{builtin.target.cpu.arch});

    if (hash) |h| {
        h.update(manifest);
        h.update(os);
        h.update(arch);
    }

    try lua.loadBuffer(manifest, manifest_path);
    lua.pcall(0, 1, 0) catch |err| {
        log.err("{s}", .{lua.toLString(-1)});
        return err;
    };
    const pkg = lua.getTop();
    // TODO: log errors
    assert(std.mem.eql(u8, name, switch (lua.getField(pkg, "name")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    }));
    lua.pop(1);

    const version: std.SemanticVersion = try .parse(switch (lua.getField(pkg, "version")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    const desc = try gpa.dupe(u8, switch (lua.getField(pkg, "desc")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    errdefer gpa.free(desc);

    const homepage = try gpa.dupe(u8, switch (lua.getField(pkg, "homepage")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    errdefer gpa.free(homepage);

    const license = try gpa.dupe(u8, switch (lua.getField(pkg, "license")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    errdefer gpa.free(license);

    const source_url = try gpa.dupe(u8, switch (lua.getField(pkg, "url")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    errdefer gpa.free(source_url);
    lua.pop(1);

    const source_hash = try gpa.dupe(u8, switch (lua.getField(pkg, "hash")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    errdefer gpa.free(source_hash);
    lua.pop(1);

    if (lua.getField(pkg, "build") != .function) return error.WrongLuaType;
    lua.pop(1);

    var compile_deps: std.ArrayList([]const u8) = .empty;
    var runtime_deps: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (compile_deps.items) |dep| gpa.free(dep);
        for (runtime_deps.items) |dep| gpa.free(dep);
    }

    var pop_count: i32 = 0;
    switch (lua.getField(pkg, "deps")) {
        .nil => {},
        .table => {
            const deps = lua.getTop();
            switch (lua.getField(deps, "compile")) {
                .nil => {},
                .table => {
                    const compile = lua.getTop();
                    const len = lua.rawLen(compile);
                    try compile_deps.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(compile, i)) {
                            .string => compile_deps.appendAssumeCapacity(try gpa.dupe(u8, lua.toLString(-1))),
                            else => return error.WrongLuaType,
                        }
                        pop_count += 1;
                    }
                },
                else => return error.WrongLuaType,
            }
            pop_count += 1;

            switch (lua.getField(deps, "runtime")) {
                .nil => {},
                .table => {
                    const runtime = lua.getTop();
                    const len = lua.rawLen(runtime);
                    try runtime_deps.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(runtime, i)) {
                            .string => runtime_deps.appendAssumeCapacity(try gpa.dupe(u8, lua.toLString(-1))),
                            else => return error.WrongLuaType,
                        }
                        pop_count += 1;
                    }
                },
                else => return error.WrongLuaType,
            }
            pop_count += 1;
        },
        else => return error.WrongLuaType,
    }
    pop_count += 1;
    lua.pop(pop_count);

    return .{
        .name = name,
        .version = version,
        .source_url = source_url,
        .source_hash = source_hash,
        .desc = desc,
        .homepage = homepage,
        .license = license,
        .lua_idx = pkg,
        .compile_deps = compile_deps,
        .runtime_deps = runtime_deps,
    };
}

pub fn deinit(self: *Package, gpa: Allocator) void {
    for (self.compile_deps.items) |dep| {
        gpa.free(dep);
    }
    self.compile_deps.deinit(gpa);
    for (self.runtime_deps.items) |dep| {
        gpa.free(dep);
    }
    self.runtime_deps.deinit(gpa);
    gpa.free(self.source_url);
    gpa.free(self.source_hash);
    gpa.free(self.license);
    gpa.free(self.homepage);
    gpa.free(self.desc);
}

pub fn collect(
    io: Io,
    gpa: Allocator,
    packa_dir: Io.Dir,
    names: []const []const u8,
    resolved: *std.StringArrayHashMapUnmanaged(Package),
    lua: *const zlua.State,
    parent_hash: ?*std.crypto.hash.Blake3,
    install: bool,
) !void {
    var digest: [32]u8 = undefined;
    var blake3: std.crypto.hash.Blake3 = .init(.{ .key = null });
    for (names) |name| {
        defer blake3.reset();

        var pkg: Package = try .init(io, gpa, packa_dir, "core", name, lua, &blake3);
        errdefer pkg.deinit(gpa);
        pkg.install = install;

        try collect(io, gpa, packa_dir, pkg.compile_deps.items, resolved, lua, &blake3, false);
        try collect(io, gpa, packa_dir, pkg.runtime_deps.items, resolved, lua, &blake3, true);

        blake3.final(&digest);
        if (parent_hash) |ph| ph.update(&digest);

        try resolved.ensureUnusedCapacity(gpa, 1);
        const key = try std.fmt.allocPrint(gpa, "{x}", .{&digest});
        errdefer comptime unreachable;

        const gop = resolved.getOrPutAssumeCapacity(key);
        if (gop.found_existing) {
            gpa.free(key);
            if (pkg.install) gop.value_ptr.install = true;
            pkg.deinit(gpa);
            continue;
        }
        gop.value_ptr.* = pkg;
    }
}

/// Fetch a binary package and save it in cache if it is signed
pub fn fetch(
    self: *const Package,
    io: Io,
    gpa: Allocator,
    pub_key: *const minizign.PublicKey,
    progress: std.Progress.Node,
) !void {
    assert(self.name.len > 0);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    var timer: std.time.Timer = try .start();

    // TODO: HAAAASHHHHHHHH
    const name = self.name;
    const version = self.version;

    var fetch_progress_name_buf: [256]u8 = undefined;
    const fetch_progress = progress.start(
        try std.fmt.bufPrint(&fetch_progress_name_buf, "{s}-{f}", .{ name, version }),
        1,
    );
    defer fetch_progress.end();

    // TODO: use hash
    const archive_name = try std.fmt.allocPrint(arena, "{s}-{f}-{t}-{t}.tar.zst", .{
        name, version, builtin.target.cpu.arch, builtin.os.tag,
    });
    const sig_name = try std.fmt.allocPrint(arena, "{s}-{f}-{t}-{t}.tar.zst.minisig", .{
        name, version, builtin.target.cpu.arch, builtin.os.tag,
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
    const packa_sig = try package_sig_fut.await(io); // sig of archive

    std.debug.print("fetched {s} in {D}\n", .{ name, timer.lap() });

    var sig = try minizign.Signature.decode(gpa, packa_sig);
    defer sig.deinit();

    var verifier = try pub_key.verifier(&sig);
    verifier.update(archive);
    try verifier.verify(gpa);

    const cache_dir = try Io.Dir.cwd().openDir(io, "/opt/packa/cache", .{});
    defer cache_dir.close(io);

    try cache_dir.writeFile(io, .{ .data = archive, .sub_path = archive_name });
    try cache_dir.writeFile(io, .{ .data = archive, .sub_path = sig_name });

    std.debug.print("verified {s} in {D}\n", .{ name, timer.lap() });

    log.debug("package signature matches\n", .{});
}
