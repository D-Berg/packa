const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const zlua = @import("zlua");
const util = @import("../util.zig");
const cli = @import("../cli.zig");
const log = std.log;

pub fn install(
    io: Io,
    gpa: Allocator,
    env: *std.process.EnvMap,
    args: cli.InstallArgs,
) !void {
    // var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    // defer arena_impl.deinit();
    //
    // const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    var home_dir = try Io.Dir.cwd().openDir(io, home_dir_path, .{});
    defer home_dir.close(io);

    try home_dir.createDirPath(io, ".local/share/packa");

    var dir = try home_dir.openDir(io, ".local/share/packa", .{});
    defer dir.close(io);

    for (args.package_names) |name| {
        try installPackage(io, gpa, dir, name, args.approved);
    }
}

fn installPackage(
    io: Io,
    gpa: Allocator,
    packa_dir: Io.Dir,
    name: []const u8,
    approved: bool,
) !void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    log.debug("installing package: {s}", .{name});

    var stdout_buf: [64]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *Io.Writer = &stdout_w.interface;

    const script = util.getLuaScript(io, arena, name, packa_dir) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("package {s} is missing formula", .{name});
            return err;
        },
        else => {
            log.err("Failed to get script: {t}", .{err});
            return err;
        },
    };

    if (!approved) {
        // review and approve package script
        try stdout.print("The following script will be run:\n", .{});
        try stdout.print("{s}", .{script});
        if (!try util.confirm(io, "Do you want to run it?", 3)) return;
    }

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new();
    defer lua.close();

    lua.openLibs();

    try lua.loadString(script);
    try lua.pcallk(0, 1, 0, 0, null);

    switch (lua.getField(-1, "homepage")) {
        .string => {
            std.debug.print("{s}\n", .{lua.toLString(-1)});
        },
        else => return error.UnexecpectedLuaType,
    }

    lua.pop(1);

    const full_name = switch (lua.getField(-1, "name")) {
        .string => lua.toLString(-1),
        else => return error.LuaError,
    };

    const version = switch (lua.getField(-2, "version")) {
        .string => lua.toLString(-1),
        else => return error.LuaError,
    };

    // TODO: check cache
    var cache_dir = try packa_dir.openDir(io, "cache", .{});
    defer cache_dir.close(io);

    var file_name_buffer: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(
        &file_name_buffer,
        "{s}-{s}.tar.xz",
        .{ full_name, version },
    );

    try packa_dir.createDirPath(io, "cache"); // make sure cache dir exists
    if (cache_dir.openFile(io, file_name, .{})) |cached_file| {
        defer cached_file.close(io);
        log.debug("found existing cached archive", .{});
        var file_path_buf: [1024]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "packages/{s}/{s}", .{ name[0..1], name });
        try packa_dir.createDirPath(io, file_path);
    } else |_| switch (lua.getField(-3, "fetch")) {
        .function => {
            std.debug.print("fetch is a function\n", .{});
            try lua.pcallk(0, zlua.MultiRet, 0, 0, null);
        },
        .table => {
            var arch_os_buf: [64]u8 = undefined;
            const arch_os = try std.fmt.bufPrintZ(&arch_os_buf, "{t}_{t}", .{ builtin.cpu.arch, builtin.os.tag });

            log.info("checking if prebuilt binary exists for {s}", .{arch_os});

            switch (lua.getField(-1, arch_os)) {
                .table => {
                    switch (lua.getField(-1, "url")) {
                        .string => {
                            const url = lua.toLString(-1);
                            log.info("fetching {s}...", .{url});

                            const correct_hash = switch (lua.getField(-2, "hash")) {
                                .string => lua.toLString(-1),
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

                            const fetched = try util.fetch(io, arena, url);

                            sha256.hash(fetched, &computed_hash, .{});

                            var buf: [sha256.digest_length * 2]u8 = undefined;
                            const readable_hash = try std.fmt.bufPrint(&buf, "{x}", .{computed_hash[0..]});

                            if (!std.mem.eql(u8, readable_hash, correct_hash)) {
                                log.err("wrong hash: expected {s}, got {s}", .{ correct_hash, readable_hash });
                                return;
                            }

                            try util.saveSliceToFile(io, cache_dir, file_name, fetched);

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
