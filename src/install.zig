const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const c = @import("c");
const lua = @import("lua.zig");
const util = @import("util.zig");
const InstallArgs = util.InstallArgs;
const log = std.log;

const stdout = util.stdout;
const stdin = util.stdin;

pub fn install(gpa: Allocator, args: InstallArgs, env: *std.process.EnvMap) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    const packa_path = try std.fmt.allocPrint(arena, "{s}/.local/share/packa", .{home_dir_path});

    var dir = try util.makeOrOpenAbsoluteDir(packa_path);
    defer dir.close();

    for (args.package_names) |name| {
        try installPackage(gpa, dir, name, args.approved);
    }
}

fn installPackage(
    gpa: Allocator,
    packa_dir: std.fs.Dir,
    name: []const u8,
    approved: bool,
) !void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    log.debug("installing package: {s}", .{name});

    const script = util.getLuaScript(arena, name, packa_dir) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("package {s} is missing formula", .{name});
            return;
        },
        else => {
            log.err("Failed to get script: {t}", .{err});
            return;
        },
    };

    if (!approved) {
        // review and approve package script
        try stdout.print("The following script will be run:\n", .{});
        try stdout.print("{s}", .{script});
        if (!try util.confirm("Do you want to run it?", 3)) return;
    }

    const state = try lua.newStateAlloc(gpa);
    defer lua.close(state);

    lua.openLibs(state);

    try lua.loadString(state, script);
    try lua.pcallk(state);

    switch (lua.getField(state, -1, "homepage")) {
        .string => {
            std.debug.print("{s}\n", .{lua.toLString(state, -1)});
        },
        else => return error.UnexecpectedLuaType,
    }

    lua.pop(state, 1);

    const full_name = switch (lua.getField(state, -1, "name")) {
        .string => lua.toLString(state, -1),
        else => return error.LuaError,
    };

    const version = switch (lua.getField(state, -2, "version")) {
        .string => lua.toLString(state, -1),
        else => return error.LuaError,
    };

    // TODO: check cache

    switch (lua.getField(state, -3, "fetch")) {
        .function => {
            std.debug.print("fetch is a function\n", .{});
            try lua.pcallk(state);
        },
        .table => {
            var arch_os_buf: [64]u8 = undefined;
            const arch_os = try std.fmt.bufPrintZ(&arch_os_buf, "{t}_{t}", .{ builtin.cpu.arch, builtin.os.tag });

            log.info("checking if prebuilt binary exists for {s}", .{arch_os});

            switch (lua.getField(state, -1, arch_os)) {
                .table => {
                    switch (lua.getField(state, -1, "url")) {
                        .string => {
                            const url = lua.toLString(state, -1);
                            log.info("fetching {s}...", .{url});

                            const correct_hash = switch (lua.getField(state, -2, "hash")) {
                                .string => lua.toLString(state, -1),
                                else => |kind| {
                                    log.err("expected lua string got {t}", .{kind});
                                    return error.LuaError;
                                },
                            };

                            const sha256 = std.crypto.hash.sha2.Sha256;
                            var computed_hash: [sha256.digest_length]u8 = undefined;

                            if (correct_hash.len != sha256.digest_length * 2) {
                                log.err("hash is wrong len", .{});
                                return;
                            }

                            const fetched = try util.fetch(arena, url);

                            sha256.hash(fetched, &computed_hash, .{});

                            var buf: [sha256.digest_length * 2]u8 = undefined;
                            const readable_hash = try std.fmt.bufPrint(&buf, "{x}", .{computed_hash[0..]});

                            if (!std.mem.eql(u8, readable_hash, correct_hash)) {
                                log.err("wrong hash: expected {s}, got {s}", .{ correct_hash, readable_hash });
                                return;
                            }

                            // assume tar.xz
                            var file_name_buffer: [256]u8 = undefined;
                            const file_name = try std.fmt.bufPrint(
                                &file_name_buffer,
                                "{s}-{s}.tar.xz",
                                .{ full_name, version },
                            );

                            try packa_dir.makePath("cache"); // make sure cache dir exists
                            var cache_dir = try packa_dir.openDir("cache", .{});
                            defer cache_dir.close();

                            try util.saveSliceToFile(cache_dir, file_name, fetched);

                            log.info("installed file", .{});
                        },
                        else => {
                            log.err("url field needs to be either a string", .{});
                            return error.LuaError;
                        },
                    }
                },
                .none, .nil => {
                    log.err("sorry no prebuilt binary exist for {s}", .{arch_os});
                    return;
                },
                else => |lua_type| {
                    log.err("fetch is of lua type {t}", .{lua_type});
                    return error.LuaError;
                },
            }
        },
        else => return error.WrongLuaType,
    }
}
