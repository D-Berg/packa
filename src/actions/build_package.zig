const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const util = @import("../util.zig");
const lua_helpers = @import("../lua_helpers.zig");
const zlua = @import("zlua");
const assert = std.debug.assert;
const log = std.log.scoped(.build);
const Package = @import("../Package.zig");

const bufPrint = std.fmt.bufPrint;
const bufPrintZ = std.fmt.bufPrintZ;

const BuildArgs = cli.BuildArgs;

const Allocator = std.mem.Allocator;
const Io = std.Io;

// TODO: add copy License fn for pkg.build
pub fn build(io: Io, gpa: Allocator, arena: Allocator, env: *std.process.Environ.Map, args: BuildArgs) !void {
    _ = env;

    try util.checkSetup(io);
    var timer: std.time.Timer = try .start();

    // use for temporary strings
    var print_buf: [4096]u8 = undefined;

    const packa_dir = try Io.Dir.cwd().openDir(io, "/opt/packa", .{});
    defer packa_dir.close(io);

    const cache_dir = try packa_dir.openDir(io, "cache", .{});
    defer cache_dir.close(io);

    const tmp_dir = try packa_dir.openDir(io, "tmp", .{});
    defer tmp_dir.close(io);

    assert(args.package_name.len > 0);

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();

    lua_helpers.setupState(&lua);

    var state: Package.State = .empty;
    const pkg_id = try Package.collect(io, arena, &state, packa_dir, args.package_name, &lua, true);
    // TODO: fetch and install deps

    const pkg_idx = state.package_table.get(pkg_id) orelse return error.FailedToCollectPackage;
    const pkg = state.packages.get(@intFromEnum(pkg_idx));

    const pkg_key = pkg_id.slice(&state.string_state);
    const pkg_name = pkg.name.slice(&state.string_state);

    const build_dir = try tmp_dir.createDirPathOpen(io, try bufPrint(&print_buf, "build-{s}-{f}", .{
        pkg_name, pkg.version,
    }), .{});
    defer build_dir.close(io);

    const tar_root_dir_path = try util.unpackSource(
        io,
        arena,
        cache_dir,
        pkg.source_url.slice(&state.string_state),
        pkg.source_hash.slice(&state.string_state),
        build_dir,
    );

    const tar_root_dir = try build_dir.openDir(io, tar_root_dir_path, .{});
    defer tar_root_dir.close(io);

    assert(lua.getField(pkg.lua_idx, "build") == .function);

    // create b = Build{}
    lua.createTable(0, 5);
    const b = lua.getTop();

    // b.os = builtin.os.tag
    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.os.tag}));
    lua.setField(b, "os");

    // b.arch = builtin.cpu.arch
    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.cpu.arch}));
    lua.setField(b, "arch");

    const prefix_path = blk: { // push prefix to lua state
        if (Io.Dir.path.isAbsolute(args.prefix_path)) {
            if (std.mem.eql(u8, args.prefix_path, "/opt/packa/tmp")) {
                const prefix_path = try bufPrint(&print_buf, "{s}/{s}-{f}-{s}", .{
                    args.prefix_path, pkg_name, pkg.version, pkg_key[0..32],
                });
                break :blk lua.pushlString(prefix_path);
            }
            break :blk lua.pushlString(args.prefix_path);
        } else {
            var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_path = try std.process.getCwd(&cwd_buf);
            const prefix_path = try bufPrint(&print_buf, "{s}/{s}/{s}-{f}-{s}", .{
                cwd_path, args.prefix_path, pkg_name, pkg.version, pkg_key[0..32],
            });
            break :blk lua.pushlString(prefix_path);
        }
    };

    lua.setField(b, "prefix");

    var build_env: std.process.Environ.Map = .init(arena);
    const run_ctx: RunContext = .{
        .io = io,
        .gpa = gpa,
        .cwd_dir = tar_root_dir,
        .env = &build_env,
        .verbose = args.verbose,
    };
    { // b.run = luaRun
        lua.pushLightUserdata(@ptrCast(@alignCast(@constCast(&run_ctx))));
        lua.pushCClosure(luaRun, 1);
        lua.setField(b, "run");
    }

    { // b.env = env;
        lua.createTable(0, 3);
        const env_table = lua.getTop();

        lua.pushLightUserdata(@ptrCast(@alignCast(&build_env)));
        lua.pushCClosure(luaEnvSet, 1);
        lua.setField(env_table, "set");

        lua.pushLightUserdata(@ptrCast(@alignCast(&build_env)));
        lua.pushCClosure(luaEnvGet, 1);
        lua.setField(env_table, "get");

        lua.pushLightUserdata(@ptrCast(@alignCast(&build_env)));
        lua.pushCClosure(luaEnvAppend, 1);
        lua.setField(env_table, "append");

        lua.setField(b, "env");
    }

    // call pkg.build(b)
    lua.pcall(1, 0, 0) catch |err| {
        log.err("{s}", .{lua.toLString(-1)});
        return err;
    };

    if (args.archive) {
        var root_dir_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const root_dir_path = try std.fmt.bufPrint(&root_dir_path_buf, "{s}-{f}-{s}", .{
            pkg_name, pkg.version, pkg_key[0..32],
        });

        const root_dir = try tmp_dir.openDir(io, root_dir_path, .{ .iterate = true });
        defer root_dir.close(io);

        var output_file_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const output_file_path = try std.fmt.bufPrint(&output_file_path_buf, "{s}.tar", .{root_dir_path});

        const output_file = try tmp_dir.createFile(io, output_file_path, .{});
        defer output_file.close(io);

        var output_writer_buf: [4096]u8 = undefined;
        var output_writer = output_file.writer(io, &output_writer_buf);

        var tar_w: std.tar.Writer = .{ .underlying_writer = &output_writer.interface };
        try tar_w.setRoot(root_dir_path);

        var walker = try root_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    const file = try root_dir.openFile(io, entry.path, .{});
                    defer file.close(io);

                    var file_reader_buf: [4096]u8 = undefined;
                    var file_reader = file.reader(io, &file_reader_buf);
                    const reader = &file_reader.interface;

                    const stat = try file.stat(io);
                    // TODO: make a reader interface that hashes content of file
                    // to pass to tar archiver
                    try tar_w.writeFileStream(entry.path, stat.size, reader, .{
                        .mode = @intFromEnum(stat.permissions),
                    });
                },
                else => {},
            }
        }

        try output_writer.flush();

        if (args.compress) {
            const term = try std.process.run(arena, io, .{
                .argv = &.{ "zstd", "-T0", "--ultra", "-20", output_file_path },
                .cwd_dir = tmp_dir,
            });
            _ = term;

            if (args.sign) {
                // TODO:
            }
        }
    }

    log.info(
        "Successfully built {s}-{f} located at {s}, built in {D}",
        .{ pkg_name, pkg.version, prefix_path, timer.lap() },
    );
}

// TODO: type check args and check number of args supplied by lua
fn luaEnvSet(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    if (lua.getTop() != 2) {
        lua.pushNil();
        _ = lua.pushlString("Package.env requires 2 args, key and value");
        return 2;
    }

    const ud = lua.toUserdata(lua.upvalueIndex(1)) orelse {
        lua.pushBoolean(false);
        _ = lua.pushlString("null userdata");
        return 2;
    };
    const env_map: *std.process.Environ.Map = @ptrCast(@alignCast(ud));

    const key = lua.toLString(1);
    const value = lua.toLString(2);

    env_map.put(key, value) catch {
        lua.pushNil();
        _ = lua.pushlString("OOM");
        return 2;
    };

    log.debug("env {s} = {s}", .{ key, value });

    lua.pushBoolean(true);
    return 1;
}

fn luaEnvGet(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    if (lua.getTop() != 1) {
        lua.pushNil();
        _ = lua.pushlString("Package.get requires a key");
        return 2;
    }

    const ud = lua.toUserdata(lua.upvalueIndex(1)) orelse {
        lua.pushBoolean(false);
        _ = lua.pushlString("null userdata");
        return 2;
    };
    const env_map: *std.process.Environ.Map = @ptrCast(@alignCast(ud));

    const key = lua.toLString(1);
    if (env_map.get(key)) |val| {
        _ = lua.pushlString(val);
        return 1;
    }

    lua.pushNil();
    return 1;
}

fn luaEnvAppend(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    if (lua.getTop() != 2) {
        lua.pushNil();
        _ = lua.pushlString("Package.get requires a key and value");
        return 2;
    }

    const ud = lua.toUserdata(lua.upvalueIndex(1)) orelse {
        lua.pushBoolean(false);
        _ = lua.pushlString("null userdata");
        return 2;
    };
    const env: *std.process.Environ.Map = @ptrCast(@alignCast(ud));

    const key = lua.toLString(1);
    const val = lua.toLString(2);

    if (env.getPtr(key)) |old_val| {
        const new_val = std.fmt.allocPrint(env.allocator, "{s} {s}", .{ old_val.*, val }) catch @panic("OOM");
        env.allocator.free(old_val.*);
        old_val.* = new_val;
    } else {
        env.put(key, val) catch @panic("OOM");
    }

    lua.pushBoolean(true);
    return 1;
}

const RunContext = struct {
    io: Io,
    gpa: Allocator,
    cwd_dir: Io.Dir,
    env: *const std.process.Environ.Map,
    verbose: bool,
};
/// `luaRun(ctx: RunContext, args: []const u8)`
fn luaRun(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };

    const n_args: usize = @intCast(lua.getTop());
    if (n_args < 1) {
        lua.pushNil();
        _ = lua.pushlString("run requires atleast 1 arg");
        return 2;
    }

    const ctx: *const RunContext = @ptrCast(@alignCast(lua.toUserdata(lua.upvalueIndex(1))));

    var scratch_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer scratch_arena.deinit();
    const arena = scratch_arena.allocator();

    const argv = arena.alloc([]const u8, n_args) catch @panic("OOM");
    for (0..argv.len) |i| {
        const lua_idx: i32 = @intCast(i + 1);
        switch (lua.typeOf(lua_idx)) {
            .string => argv[i] = lua.toLString(lua_idx),
            inline else => |t| {
                const err_msg = std.fmt.allocPrint(
                    arena,
                    "Expected arg[{d}] be of type string, got {t}",
                    .{ i + 1, t },
                ) catch @panic("OOM");

                lua.pushNil();
                _ = lua.pushlString(err_msg);

                return 2;
            },
        }
    }

    const command = std.mem.join(arena, " ", argv) catch @panic("OOM");
    log.info("{s}", .{command});
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = ctx.env,
        .cwd_dir = ctx.cwd_dir,
        .stdout = if (ctx.verbose) .inherit else .ignore,
        .stderr = if (ctx.verbose) .inherit else .pipe,
    }) catch |err| {
        lua.pushNil();
        _ = lua.pushlString(std.fmt.allocPrint(arena, "Failed to run {s}, err: {t}", .{
            command, err,
        }) catch @panic("OOM"));
        return 2;
    };
    defer child.kill(ctx.io);

    var stderr: std.ArrayList(u8) = .empty;
    if (!ctx.verbose) {
        const KiB = 1024;
        const MiB = 1024 * KiB;
        const max_output_bytes = 2 * MiB;

        var poller = std.Io.poll(arena, enum { stderr }, .{
            .stderr = child.stderr.?,
        });
        defer poller.deinit();

        const stderr_r = poller.reader(.stderr);
        stderr_r.buffer = stderr.allocatedSlice();
        stderr_r.seek = 0;
        stderr_r.end = stderr.items.len;
        defer {
            stderr = .{
                .items = stderr_r.buffer[0..stderr_r.end],
                .capacity = stderr_r.buffer.len,
            };
            stderr_r.buffer = &.{};
        }
        while (true) {
            const continue_poll = poller.poll() catch |err| {
                const err_msg = std.fmt.allocPrint(arena, "{s}: {t}", .{ command, err }) catch @panic("oom");
                lua.pushNil();
                _ = lua.pushlString(err_msg);
                return 2;
            };
            if (!continue_poll or stderr_r.bufferedLen() > max_output_bytes) break;
        }
    }

    const term = child.wait(ctx.io) catch |err| {
        const err_msg = std.fmt.allocPrint(arena, "{s}: {t}", .{ command, err }) catch @panic("oom");
        lua.pushNil();
        _ = lua.pushlString(err_msg);
        return 2;
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                lua.pushBoolean(true);
                return 1;
            }
            const err_msg = if (ctx.verbose) std.fmt.allocPrint(arena, "{s} exited({d})", .{
                command, code,
            }) catch @panic("OOM") else std.fmt.allocPrint(
                arena,
                "{s} exited({d})\n{s}",
                .{ command, code, stderr.items },
            ) catch @panic("OOM");
            lua.pushNil();
            _ = lua.pushlString(err_msg);
            return 2;
        },
        inline else => |code| {
            const err_msg = if (ctx.verbose) std.fmt.allocPrint(arena, "{s} terminated: {t}({d})", .{
                command, term, code,
            }) catch @panic("OOM") else std.fmt.allocPrint(arena, "{s} terminated: {t}({d})\n{s}", .{
                command, term, code, stderr.items,
            }) catch @panic("OOM");

            lua.pushNil();
            _ = lua.pushlString(err_msg);
            return 2;
        },
    }
}
