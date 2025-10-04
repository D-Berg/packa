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
        try installPackage(gpa, dir, name, args.approved, home_dir_path);
    }
}

fn installPackage(
    gpa: Allocator,
    packa_dir: std.fs.Dir,
    name: []const u8,
    approved: bool,
    home_dir_path: []const u8,
) !void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    log.debug("installing package: {s}", .{name});

    const script = blk: {
        const script_path = try std.fmt.allocPrint(gpa, "formulas/{s}/{s}.lua", .{
            name[0..1], name,
        });
        defer gpa.free(script_path);
        const script_file = try packa_dir.openFile(script_path, .{});
        defer script_file.close();

        var read_buffer: [1024]u8 = undefined;
        var file_reader = script_file.reader(&read_buffer);

        var alloc_writer = std.Io.Writer.Allocating.init(arena);

        _ = try file_reader.interface.streamRemaining(&alloc_writer.writer);

        break :blk try alloc_writer.toOwnedSliceSentinel(0);
    };

    if (!approved) {
        // review and approve package script
        try stdout.print("The following script will be run:\n", .{});
        try stdout.print("{s}", .{script});
        try stdout.print("Do you want to run it, Y/N?: ", .{});
        try stdout.flush();

        var questioned: usize = 0;
        while (questioned < 3) : (questioned += 1) {
            const answer = try stdin.takeDelimiterExclusive('\n');

            if (std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "n")) return;
            if (std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "y")) break;

            try stdout.print("Do you want to run it, Y/N?: ", .{});
            try stdout.flush();
        } else {
            return;
        }
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
                            log.info("fetching {s}", .{url});

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

                            var client = std.http.Client{ .allocator = arena };
                            defer client.deinit();

                            var alloc_writer = std.Io.Writer.Allocating.init(arena);

                            const res = try client.fetch(.{
                                .response_writer = &alloc_writer.writer,
                                .location = .{ .url = url },
                            });

                            if (res.status == .ok) {
                                sha256.hash(alloc_writer.written(), &computed_hash, .{});

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

                                var cache_path_buf: [256]u8 = undefined;
                                const cache_path = try std.fmt.bufPrint(&cache_path_buf, "{s}/.cache/packa/fetch", .{
                                    home_dir_path,
                                });

                                var cache_dir = try util.makeOrOpenAbsoluteDir(cache_path);
                                defer cache_dir.close();

                                var save_file = try cache_dir.createFile(file_name, .{});
                                defer save_file.close();

                                var file_write_buf: [1024]u8 = undefined;
                                var file_writer = save_file.writer(&file_write_buf);

                                try file_writer.interface.writeAll(alloc_writer.writer.buffered());
                                try file_writer.interface.flush();

                                log.info("installed file", .{});
                            } else {
                                log.err("got status {t}", .{res.status});
                            }
                        },
                        else => {
                            log.err("url field needs to be either a string", .{});
                            return error.LuaError;
                        },
                    }
                },
                .none => {
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
    // _ = lua.getField(state, -1, "url");

    // const url = lua.toLString(state, -1);
    //
    // var client = std.http.Client{ .allocator = arena };
    // defer client.deinit();
    //
    // var alloc_writer = std.Io.Writer.Allocating.init(arena);
    //
    // const res = try client.fetch(.{
    //     .response_writer = &alloc_writer.writer,
    //     .location = .{ .url = url },
    // });
    //
    // if (res.status == .ok) {
    //     var save_file = try std.fs.cwd().createFile("zig.tar.xz", .{});
    //     defer save_file.close();
    //
    //     var file_write_buf: [1024]u8 = undefined;
    //     var file_writer = save_file.writer(&file_write_buf);
    //
    //     try file_writer.interface.writeAll(alloc_writer.writer.buffered());
    //     try file_writer.interface.flush();
    // }
    //
    // lua.pop(state, 2);
}
