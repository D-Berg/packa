const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const lua = @import("lua.zig");
const util = @import("util.zig");
const InstallArgs = util.InstallArgs;
const log = std.log;
const stdout = util.stdout;
const stdin = util.stdin;

pub fn install(gpa: Allocator, args: InstallArgs, env: std.process.EnvMap) !void {
    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const home_dir_path = env.get("HOME") orelse return;

    const packa_path = try std.fmt.allocPrint(arena, "{s}/.local/share/packa", .{home_dir_path});

    var dir = blk: {
        if (std.fs.openDirAbsolute(packa_path, .{})) |dir| {
            break :blk dir;
        } else |err| {
            switch (err) {
                error.FileNotFound => {
                    try std.fs.makeDirAbsolute(packa_path);
                    break :blk try std.fs.openDirAbsolute(packa_path, .{});
                },
                else => return err,
            }
        }
    };
    defer dir.close();

    for (args.package_names) |name| {
        try installPackage(gpa, dir, name);
    }
}

fn installPackage(gpa: Allocator, packa_dir: std.fs.Dir, name: []const u8) !void {
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

    // review and approve package script
    try stdout.print("The following script will be run:\n", .{});
    try stdout.print("{s}", .{script});
    try stdout.print("Do you want to run it, Y/N?: ", .{});
    try stdout.flush();

    var questioned: usize = 0;
    while (questioned < 3) : (questioned += 1) {
        const answer = try stdin.takeDelimiterExclusive('\n');
        if (std.mem.eql(u8, answer, "N")) return;
        if (std.mem.eql(u8, answer, "Y")) break;

        try stdout.print("Do you want to run it, Y/N?: ", .{});
        try stdout.flush();
    } else {
        return;
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

    switch (lua.getField(state, -1, "fetch")) {
        .function => {
            std.debug.print("fetch is a function\n", .{});
            try lua.pcallk(state);
        },
        .table => {
            switch (lua.getField(state, -1, "url")) {
                .string => {
                    const url = lua.toLString(state, -1);
                    log.info("fetching {s}", .{url});
                },
                else => {
                    log.err("url field needs to be either a string", .{});
                    return error.LuaError;
                },
            }
        },
        else => return error.WrongLuaType,
    }
    // _ = lua.getField(state, -1, "url");
    //
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
