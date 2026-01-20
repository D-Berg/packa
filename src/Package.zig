const std = @import("std");
const builtin = @import("builtin");
const zlua = @import("zlua");
const minizign = @import("minizign");
const util = @import("util.zig");
const lua_helpers = @import("lua_helpers.zig");
const log = std.log;
const string = @import("string.zig");
const String = string.State.String;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Package = @This();

/// Holds all data for Package(s)
/// Since packages are longlived, they are created and only destroyed at program end.
/// Efficiently store metadata of package by
///     - interning strings,
///     - SoA(MultiArrayList) for holding packages and package_table and dependencies
/// Downside is potential footguns of holding references to a pointer or slice
/// to long, but quite fun to program with, future self may disagree.
/// Also need to come up with better name than calling everything State.
/// Based on [Programming without pointers](https://www.hytradboi.com/2025/05c72e39-c07e-41bc-ac40-85e8308f2917-programming-without-pointers).
/// Rules:
///     - no element in array or hashmap are allowed to hold pointers (ArrayList and HashMaps are also pointers).
pub const State = struct {
    package_table: std.AutoArrayHashMapUnmanaged(Id, Package.Idx) = .empty,
    string_state: string.State = .empty,
    packages: std.MultiArrayList(Package) = .empty,
    runtime_deps: DependencyMap = .empty,
    compile_deps: DependencyMap = .empty,

    pub const empty = State{};

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.package_table.deinit(gpa);
        self.string_state.deinit(gpa);
        self.packages.deinit(gpa);
        self.runtime_deps.deinit(gpa);
        self.compile_deps.deinit(gpa);
    }
};

pub const DependencyMap = std.AutoArrayHashMapUnmanaged(String, Id);
/// Unique hash(Id) of a Package by hashing OS, cpu Arch, manifests and dependecies manifests.
pub const Id = String;
/// idx into State.packages
pub const Idx = enum(u32) { _ };

name: String,
version: std.SemanticVersion,
lua_idx: i32,
desc: String,
homepage: String,
license: String,
source_url: String,
source_hash: String,
install: bool = false,
compile_deps: Deps,
runtime_deps: Deps,

const Deps = struct {
    start: u32,
    count: u32,
};

pub fn init(
    io: Io,
    gpa: Allocator,
    state: *Package.State,
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
    const manifest = try packa_dir.readFileAllocOptions(
        io,
        manifest_path[1..],
        gpa,
        .limited64(manifest_stat.size + 1),
        .of(u8),
        0,
    );
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

    const desc = try state.string_state.internString(gpa, switch (lua.getField(pkg, "desc")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    const homepage = try state.string_state.internString(gpa, switch (lua.getField(pkg, "homepage")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    const license = try state.string_state.internString(gpa, switch (lua.getField(pkg, "license")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    const source_url = try state.string_state.internString(gpa, switch (lua.getField(pkg, "url")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    const source_hash = try state.string_state.internString(gpa, switch (lua.getField(pkg, "hash")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    });
    lua.pop(1);

    if (lua.getField(pkg, "build") != .function) return error.WrongLuaType;
    lua.pop(1);

    var runtime_deps: Deps = .{ .start = 0, .count = 0 };
    var compile_deps: Deps = .{ .start = 0, .count = 0 };

    var pop_count: i32 = 0;
    switch (lua.getField(pkg, "deps")) {
        .nil => {},
        .table => {
            const lua_deps = lua.getTop();
            switch (lua.getField(lua_deps, "compile")) {
                .nil => {},
                .table => {
                    compile_deps.start = @intCast(state.compile_deps.count());

                    const compile = lua.getTop();
                    const len = lua.rawLen(compile);
                    try state.compile_deps.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(compile, i)) {
                            .string => state.compile_deps.putAssumeCapacity(
                                try state.string_state.internString(gpa, lua.toLString(-1)),
                                .none, // package id is unresolved
                            ),
                            else => return error.WrongLuaType,
                        }
                        pop_count += 1;
                    }
                    compile_deps.count = @intCast(len);
                },
                else => return error.WrongLuaType,
            }
            pop_count += 1; // compile

            switch (lua.getField(lua_deps, "runtime")) {
                .nil => {},
                .table => {
                    runtime_deps.start = @intCast(state.runtime_deps.count());
                    const runtime = lua.getTop();
                    const len = lua.rawLen(runtime);
                    try state.runtime_deps.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(runtime, i)) {
                            .string => state.runtime_deps.putAssumeCapacity(
                                try state.string_state.internString(gpa, lua.toLString(-1)),
                                .none,
                            ),
                            else => return error.WrongLuaType,
                        }
                        pop_count += 1;
                    }

                    runtime_deps.count = @intCast(len);
                },
                else => return error.WrongLuaType,
            }
            pop_count += 1; // runtime
        },
        else => return error.WrongLuaType,
    }
    pop_count += 1; // deps
    lua.pop(pop_count);

    return .{
        .name = try state.string_state.internString(gpa, name),
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

/// Initialises a package based on its name and collects its dependencies
pub fn collect(
    io: Io,
    gpa: Allocator,
    state: *Package.State,
    packa_dir: Io.Dir,
    name: []const u8,
    lua: *const zlua.State,
    install: bool,
) !Id {
    var digest: [32]u8 = undefined;
    var key_buf: [2 * digest.len]u8 = undefined;
    var blake3: std.crypto.hash.Blake3 = .init(.{ .key = null });

    try state.packages.ensureUnusedCapacity(gpa, 1);
    const pkg_idx = state.packages.addOneAssumeCapacity();
    state.packages.set(
        pkg_idx,
        try .init(io, gpa, state, packa_dir, "core", name, lua, &blake3),
    );
    state.packages.items(.install)[pkg_idx] = install;

    var name_buf: [128]u8 = undefined;
    const runtime_deps = state.packages.items(.runtime_deps)[pkg_idx];
    for (state.runtime_deps.keys()[runtime_deps.start..][0..runtime_deps.count]) |run_dep| {
        const dep_name = try std.fmt.bufPrint(&name_buf, "{s}", .{run_dep.slice(&state.string_state)});
        const id = try collect(io, gpa, state, packa_dir, dep_name, lua, true);
        state.runtime_deps.getPtr(run_dep).?.* = id;
        blake3.update(id.slice(&state.string_state));
    }

    const compile_deps = state.packages.items(.compile_deps)[pkg_idx];
    for (state.compile_deps.keys()[compile_deps.start..][0..compile_deps.count]) |comp_dep| {
        const dep_name = try std.fmt.bufPrint(&name_buf, "{s}", .{comp_dep.slice(&state.string_state)});
        const id = try collect(io, gpa, state, packa_dir, dep_name, lua, false);
        state.compile_deps.getPtr(comp_dep).?.* = id;
        blake3.update(id.slice(&state.string_state));
    }

    blake3.final(&digest);
    const key = std.fmt.bufPrint(&key_buf, "{x}", .{&digest}) catch unreachable;
    assert(key.len == key_buf.len);

    const key_string = try state.string_state.internString(gpa, key);
    const gop = try state.package_table.getOrPut(gpa, key_string);
    if (gop.found_existing and builtin.mode == .Debug) {
        const names = state.packages.items(.name);
        assert(names[@intFromEnum(gop.value_ptr.*)] == names[pkg_idx]);
    }
    gop.value_ptr.* = @enumFromInt(pkg_idx);
    return key_string;
}
