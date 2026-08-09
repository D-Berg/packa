const std = @import("std");
const zlua = @import("zlua");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Config = struct {
    packages: []const []const u8 = &.{},
    shell_packages: []const []const u8 = &.{},
    environment: []const Entry = &.{},
    build_from_source: bool = false,
};

pub fn load(
    io: Io,
    gpa: Allocator,
    path: []const u8,
    shell_name: ?[]const u8,
) !Config {
    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();

    setup(&lua, shell_name);
    try lua.loadFile(io, path);
    lua.pcall(0, 1, 0) catch |err| {
        if (!builtin.is_test) std.log.err("invalid configuration '{s}': {s}", .{ path, lua.toLString(-1) });
        return err;
    };
    if (lua.typeOf(-1) != .table) return error.ConfigMustReturnTable;
    lua.setGlobal("__packa_config");

    try lua.loadBuffer(normalize_source, "@packa:config-normalize");
    lua.pcall(0, 1, 0) catch |err| {
        if (!builtin.is_test) std.log.err("invalid configuration '{s}': {s}", .{ path, lua.toLString(-1) });
        return err;
    };

    const root = lua.getTop();
    var config: Config = .{};
    config.packages = try readStrings(&lua, gpa, root, "packages");
    config.shell_packages = try readStrings(&lua, gpa, root, "shell_packages");
    config.environment = try readEnvironment(&lua, gpa, root);

    if (lua.getField(root, "build_from_source") == .boolean) {
        config.build_from_source = lua.toBoolean(-1);
    }
    lua.pop(1);
    return config;
}

fn setup(lua: *const zlua.State, shell_name: ?[]const u8) void {
    lua.requiref("_G", zlua.Open.base, true);
    lua.requiref("table", zlua.Open.table, true);
    lua.requiref("string", zlua.Open.string, true);

    inline for (&.{ "dofile", "load", "loadfile", "require" }) |name| {
        lua.pushNil();
        lua.setGlobal(name);
    }

    if (shell_name) |name| {
        _ = lua.pushLString(name);
    } else lua.pushNil();
    lua.setGlobal("__packa_shell_name");
}

fn readStrings(lua: *const zlua.State, gpa: Allocator, table: i32, field: [:0]const u8) ![]const []const u8 {
    switch (lua.getField(table, field)) {
        .nil => {
            lua.pop(1);
            return &.{};
        },
        .table => {},
        else => return error.ConfigExpectedStringList,
    }
    defer lua.pop(1);

    const list = lua.getTop();
    const len = lua.rawLen(list);
    const result = try gpa.alloc([]const u8, len);
    for (result, 1..) |*item, index| {
        if (lua.rawGetI(list, @intCast(index)) != .string) return error.ConfigExpectedStringList;
        item.* = try gpa.dupe(u8, lua.toLString(-1));
        lua.pop(1);
    }
    return result;
}

fn readEnvironment(lua: *const zlua.State, gpa: Allocator, table: i32) ![]const Entry {
    switch (lua.getField(table, "environment")) {
        .nil => {
            lua.pop(1);
            return &.{};
        },
        .table => {},
        else => return error.ConfigExpectedEnvironmentList,
    }
    defer lua.pop(1);

    const list = lua.getTop();
    const len = lua.rawLen(list);
    const result = try gpa.alloc(Entry, len);
    for (result, 1..) |*entry, index| {
        if (lua.rawGetI(list, @intCast(index)) != .table) return error.ConfigExpectedEnvironmentList;
        const pair = lua.getTop();
        if (lua.rawGetI(pair, 1) != .string) return error.ConfigExpectedEnvironmentList;
        entry.key = try gpa.dupe(u8, lua.toLString(-1));
        lua.pop(1);
        if (lua.rawGetI(pair, 2) != .string) return error.ConfigExpectedEnvironmentList;
        entry.value = try gpa.dupe(u8, lua.toLString(-1));
        lua.pop(2);
    }
    return result;
}

const normalize_source = @embedFile("config_normalize.lua");

test "loads packages and a default development shell" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "packa.lua",
        .data =
        \\return {
        \\  version = 1,
        \\  packages = { "git", "ripgrep" },
        \\  install = { build_from_source = true },
        \\  dev_shell = {
        \\    packages = { "zig", "zls" },
        \\    environment = { MODE = "development" },
        \\  },
        \\}
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "packa.lua", testing.allocator);
    defer testing.allocator.free(path);

    const config = try load(testing.io, testing.allocator, path, null);
    defer {
        for (config.packages) |item| testing.allocator.free(item);
        testing.allocator.free(config.packages);
        for (config.shell_packages) |item| testing.allocator.free(item);
        testing.allocator.free(config.shell_packages);
        for (config.environment) |entry| {
            testing.allocator.free(entry.key);
            testing.allocator.free(entry.value);
        }
        testing.allocator.free(config.environment);
    }
    try testing.expectEqualStrings("git", config.packages[0]);
    try testing.expectEqualStrings("zig", config.shell_packages[0]);
    try testing.expectEqualStrings("MODE", config.environment[0].key);
    try testing.expectEqualStrings("development", config.environment[0].value);
    try testing.expect(config.build_from_source);
}

test "selects a named development shell" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "packa.lua",
        .data =
        \\return {
        \\  version = 1,
        \\  dev_shells = {
        \\    default = { packages = { "zig" } },
        \\    release = { packages = { "zig", "minisign" } },
        \\  },
        \\}
        ,
    });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "packa.lua", testing.allocator);
    defer testing.allocator.free(path);
    const config = try load(testing.io, testing.allocator, path, "release");
    defer {
        for (config.shell_packages) |item| testing.allocator.free(item);
        testing.allocator.free(config.shell_packages);
    }
    try testing.expectEqual(@as(usize, 2), config.shell_packages.len);
    try testing.expectEqualStrings("minisign", config.shell_packages[1]);
}

test "rejects unknown fields" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "packa.lua",
        .data = "return { version = 1, pakcages = {} }",
    });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "packa.lua", testing.allocator);
    defer testing.allocator.free(path);
    try testing.expectError(error.Run, load(testing.io, testing.allocator, path, null));
}
