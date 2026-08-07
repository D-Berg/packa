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
    /// Maps each unique `Package.ID` to its entry in `packages`.
    package_table: std.AutoArrayHashMapUnmanaged(Id, Package.Idx) = .empty,
    /// Owns the interned strings referenced by packages and dependencies.
    string_state: string.State = .empty,
    /// Append-only package storage; duplicate packages may share an ID.
    packages: std.MultiArrayList(Package) = .empty,
    /// Contiguous storage addressed by each package's dependency ranges.
    dependencies: std.ArrayList(Dependency) = .empty,

    pub const empty = State{};

    pub const DependencyKind = enum { compile, runtime };

    pub const Entry = struct {
        package: Package,
    };

    pub const Iterator = struct {
        packages_slice: std.MultiArrayList(Package).Slice,
        table_iterator: std.AutoArrayHashMapUnmanaged(Id, Package.Idx).Iterator,

        pub fn next(self: *Iterator) ?Package {
            const entry = self.table_iterator.next() orelse return null;
            assert(entry.key_ptr.* != .none);
            const index = @intFromEnum(entry.value_ptr.*);
            assert(index < self.packages_slice.len);
            const package = self.packages_slice.get(index);
            assert(package.id == entry.key_ptr.*);
            return package;
        }
    };

    pub fn get(self: *const State, id: Id) ?Package {
        assert(id != .none);
        const index = self.package_table.get(id) orelse return null;

        const package_index = @intFromEnum(index);
        assert(package_index < self.packages.len);

        const package = self.packages.get(package_index);
        assert(package.id == id);
        return package;
    }

    pub fn getDependencies(self: *const State, package: Package, kind: DependencyKind) []const Dependency {
        const deps = switch (kind) {
            .compile => package.compile_deps,
            .runtime => package.runtime_deps,
        };
        const start: usize = deps.start;
        const dependency_count: usize = deps.count;
        assert(package.id != .none);
        assert(start <= self.dependencies.items.len);
        assert(dependency_count <= self.dependencies.items.len - start);
        return self.dependencies.items[start..][0..dependency_count];
    }

    pub fn count(self: *const State) usize {
        assert(self.package_table.count() <= self.packages.len);
        return self.package_table.count();
    }

    /// Iterate over Packages.
    /// It is not safe to mofify state while iterating
    pub fn iterator(self: *const State) Iterator {
        assert(self.package_table.count() <= self.packages.len);
        return .{
            .packages_slice = self.packages.slice(),
            .table_iterator = self.package_table.iterator(),
        };
    }

    pub fn deinit(self: *State, gpa: Allocator, lua: *const zlua.State) void {
        for (self.packages.items(.build_func_ref)) |build_ref| {
            lua.unref(zlua.REGISTRYINDEX, build_ref);
        }
        self.package_table.deinit(gpa);
        self.string_state.deinit(gpa);
        self.packages.deinit(gpa);
        self.dependencies.deinit(gpa);
    }
};

pub const Dependency = struct {
    name: String,
    pkg_id: Id = .none,
};
/// Unique hash(Id) of a Package by hashing OS, cpu Arch, manifests and dependecies manifests.
pub const Id = String;
/// Index into State.packages
pub const Idx = enum(u32) { _ };

/// Unique package id generated from hashing build input
id: Id = .none,
/// name of Package
name: String,
version: std.SemanticVersion,
/// Lua registry reference to the package's build function
build_func_ref: zlua.Idx,
desc: String,
homepage: String,
license: String,
source_url: String,
source_hash: String,
install: bool = false,
compile_deps: Deps,
runtime_deps: Deps,

pub const Deps = struct {
    start: u32,
    count: u32,
};

pub fn init(
    io: Io,
    gpa: Allocator,
    state: *Package.State,
    packa_dir: Io.Dir,
    repo: []const u8,
    pkg_name: []const u8,
    lua: *const zlua.State,
    hash: ?*std.crypto.hash.Blake3,
) !Package {
    assert(pkg_name.len > 0);
    assert(repo.len > 0);

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const manifest_path = try std.fmt.allocPrintSentinel(arena, "@/opt/packa/repos/{s}/manifests/{c}/{s}.lua", .{
        repo,
        pkg_name[0],
        pkg_name,
    }, 0);
    const manifest_stat = try packa_dir.statFile(io, manifest_path[1..], .{ .follow_symlinks = true });

    const manifest = try packa_dir.readFileAllocOptions(
        io,
        manifest_path[1..],
        arena,
        .limited64(manifest_stat.size + 1), // zero sentinel
        .of(u8),
        0,
    );

    if (hash) |h| {
        h.update(manifest);
        h.update(std.fmt.comptimePrint("{t}", .{builtin.target.cpu.arch}));
        h.update(std.fmt.comptimePrint("{t}", .{builtin.target.os.tag}));
    }

    try lua.loadBuffer(manifest, manifest_path);
    lua.pcall(0, 1, 0) catch |err| {
        log.err("{s}", .{lua.toLString(-1)});
        return err;
    };
    const pkg = lua.getTop();
    // TODO: log errors
    const name = try state.string_state.internString(gpa, switch (lua.getField(pkg, "name")) {
        .string => lua.toLString(-1),
        else => |kind| {
            log.err("Package expected name to be function, got {t}", .{kind});
            return error.WrongLuaType;
        },
    });
    lua.pop(1);

    if (!std.mem.eql(u8, pkg_name, name.slice(&state.string_state))) {
        log.err("Package name differs from expected name '{s}', got {s}", .{ pkg_name, name.slice(&state.string_state) });
        return error.WrongPackageName;
    }

    const version: std.SemanticVersion = try .parse(switch (lua.getField(pkg, "version")) {
        .string => lua.toLString(-1),
        else => |kind| {
            log.err("Package expected type of version to be string, got {t}", .{kind});
            return error.WrongLuaType;
        },
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

    const build_func_ref = switch (lua.getField(pkg, "build")) {
        .function => lua.ref(zlua.REGISTRYINDEX), // pops build
        else => |kind| {
            log.err("Package expected build to be a function, got {t}", .{kind});
            return error.WrongLuaType;
        },
    };
    errdefer lua.unref(zlua.REGISTRYINDEX, build_func_ref);

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
                    compile_deps.start = @intCast(state.dependencies.items.len);

                    const compile = lua.getTop();
                    const len = lua.rawLen(compile);
                    try state.dependencies.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(compile, i)) {
                            .string => state.dependencies.appendAssumeCapacity(.{
                                .name = try state.string_state.internString(gpa, lua.toLString(-1)),
                            }),
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
                    runtime_deps.start = @intCast(state.dependencies.items.len);
                    const runtime = lua.getTop();
                    const len = lua.rawLen(runtime);
                    try state.dependencies.ensureUnusedCapacity(gpa, len);
                    var i: isize = 1;
                    while (i < len + 1) : (i += 1) {
                        switch (lua.rawGetI(runtime, i)) {
                            .string => state.dependencies.appendAssumeCapacity(.{
                                .name = try state.string_state.internString(gpa, lua.toLString(-1)),
                            }),
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
    lua.pop(1); // package

    return .{
        .name = name,
        .version = version,
        .source_url = source_url,
        .source_hash = source_hash,
        .desc = desc,
        .homepage = homepage,
        .license = license,
        .build_func_ref = build_func_ref,
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
    const package = try Package.init(io, gpa, state, packa_dir, "core", name, lua, &blake3);
    const pkg_idx = state.packages.addOneAssumeCapacity();
    state.packages.set(pkg_idx, package);
    state.packages.items(.install)[pkg_idx] = install;

    const runtime_deps: Deps = state.packages.items(.runtime_deps)[pkg_idx];
    const compile_deps: Deps = state.packages.items(.compile_deps)[pkg_idx];

    // Buffer to hold temp name since holding slice of string is not stable when modifying state
    var name_buf: [128]u8 = undefined;
    for (0..runtime_deps.count) |i| {
        const run_dep = state.dependencies.items[runtime_deps.start..][i];
        const dep_name = try std.fmt.bufPrint(&name_buf, "{s}", .{run_dep.name.slice(&state.string_state)});
        const id = try collect(io, gpa, state, packa_dir, dep_name, lua, true);
        state.dependencies.items[runtime_deps.start + i].pkg_id = id;
        blake3.update(id.slice(&state.string_state));
    }

    for (0..compile_deps.count) |i| {
        const comp_dep = state.dependencies.items[compile_deps.start..][i];
        const dep_name = try std.fmt.bufPrint(&name_buf, "{s}", .{comp_dep.name.slice(&state.string_state)});
        const id = try collect(io, gpa, state, packa_dir, dep_name, lua, false);
        state.dependencies.items[compile_deps.start + i].pkg_id = id;
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
    state.packages.items(.id)[pkg_idx] = key_string;
    return key_string;
}
