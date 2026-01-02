const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const util = @import("../util.zig");
const zlua = @import("zlua");
const assert = std.debug.assert;
const log = std.log.scoped(.build);

const bufPrint = std.fmt.bufPrint;
const bufPrintZ = std.fmt.bufPrintZ;

const BuildArgs = cli.BuildArgs;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn build(io: Io, gpa: Allocator, env: *std.process.EnvMap, args: BuildArgs) !void {
    const home_dir_path = env.get("HOME") orelse {
        return error.MissingHomeEnv;
    };

    var home_dir = try Io.Dir.cwd().openDir(io, home_dir_path, .{});
    defer home_dir.close(io);

    const packa_dir = try home_dir.openDir(io, ".local/share/packa", .{});
    defer packa_dir.close(io);

    const cache_dir = home_dir.openDir(io, ".cache/packa", .{}) catch blk: {
        try home_dir.createDirPath(io, ".cache/packa");
        break :blk try home_dir.openDir(io, ".cache/packa", .{});
    };
    defer cache_dir.close(io);

    const manifest = try util.getLuaScript(io, gpa, packa_dir, args.package_name);
    defer gpa.free(manifest);

    log.debug("manifest: \n\n{s}\n\n", .{manifest});

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();

    lua.requiref("_G", zlua.Lib.base, true);

    lua.setGlobal("load");
    lua.pushNil();
    lua.setGlobal("loadfile");
    lua.pushNil();
    lua.setGlobal("dofile");

    { // create global Package with Package.new()
        lua.createTable(0, 1);
        const package_idx = lua.getTop();
        lua.pushCFunction(luaPackageNew);
        lua.setField(package_idx, "new");
        lua.setGlobal("Package");
    }

    var lua_script_name_buf: [128]u8 = undefined;
    const lua_script_name = try bufPrintZ(&lua_script_name_buf, "@{s}.lua", .{args.package_name});

    try lua.loadBuffer(manifest, lua_script_name);
    try lua.pcall(0, 1, 0);

    const pkg = lua.getTop();
    const name = switch (lua.getField(pkg, "name")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };

    log.debug("name = {s}", .{name});

    const src_url = switch (lua.getField(pkg, "url")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };
    log.debug("src_url: {s}", .{src_url});

    const pkg_hash = switch (lua.getField(pkg, "hash")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };
    log.debug("pkg_hash: {s}", .{pkg_hash});

    // use for temporary strings
    var print_buf: [4096]u8 = undefined;

    const tar_file_name = src_url[1 + std.mem.findScalarLast(u8, src_url, '/').? ..];
    const is_cached = if (cache_dir.access(io, tar_file_name, .{})) true else |_| false;
    if (!is_cached) {
        const file = try cache_dir.createFile(io, tar_file_name, .{});
        defer file.close(io);

        var file_writer_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &file_writer_buf);

        const bytes = try util.fetch(io, gpa, src_url);
        defer gpa.free(bytes);

        // TODO: verify hash

        var reader: Io.Reader = .fixed(bytes);

        assert(try reader.streamRemaining(&file_writer.interface) == bytes.len);
    }

    log.debug("cache contains {s}: {}", .{ tar_file_name, is_cached });

    if (lua.getField(pkg, "build") != .function) {
        log.err("build need to be a function", .{});
        return error.WrongLuaType;
    }

    { // create b = Build{}
        lua.createTable(0, 5);
        const b = lua.getTop();

        // b.os = builtin.os.tag
        _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.os.tag}));
        lua.setField(b, "os");

        // b.arch = builtin.cpu.arch
        _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.cpu.arch}));
        lua.setField(b, "arch");

        // TODO: actually provide a prefix;
        _ = lua.pushlString("prefix_tmp");
        lua.setField(b, "prefix");

        { // b.run = luaRun
            lua.pushLightUserdata(@ptrCast(@alignCast(@constCast(&io))));
            lua.pushLightUserdata(@ptrCast(@alignCast(@constCast(&gpa))));
            lua.pushCClosure(luaRun, 2);
            lua.setField(b, "run");
        }

        { // b.env = env;
            lua.createTable(0, 1);
            const env_table = lua.getTop();

            lua.pushLightUserdata(@ptrCast(@alignCast(env)));
            lua.pushCClosure(luaEnvSet, 1);
            lua.setField(env_table, "set");

            lua.setField(b, "env");
        }
    }

    // call pkg.build(b)
    lua.pcall(1, 0, 0) catch |err| {
        // TODO: run cleanup
        const err_msg = lua.toLString(-1);
        log.err("{s}", .{err_msg});
        return err;
    };
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
    const env_map: *std.process.EnvMap = @ptrCast(@alignCast(ud));

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

/// `luaRun(io: Io, gpa: Allocator, args: []const u8)`
fn luaRun(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };

    var print_buf: [128]u8 = undefined;

    const n_args: usize = @intCast(lua.getTop());
    if (n_args < 1) {
        lua.pushNil();
        _ = lua.pushlString("run requires atleast 1 arg");
        return 2;
    }

    const io_ud = lua.toUserdata(lua.upvalueIndex(1)) orelse {
        lua.pushNil();
        _ = lua.pushlString("io userdata was null");
        return 2;
    };
    const io_ptr: *const Io = @ptrCast(@alignCast(io_ud));
    const io = io_ptr.*;

    const gpa_ud = lua.toUserdata(lua.upvalueIndex(2)) orelse {
        lua.pushNil();
        _ = lua.pushlString("gpa userdata was null");
        return 2;
    };
    const gpa_ptr: *const Allocator = @ptrCast(@alignCast(gpa_ud));
    const gpa = gpa_ptr.*;

    const argv = gpa.alloc([]const u8, n_args) catch |err| {
        std.debug.panic("{t}", .{err});
    };
    defer gpa.free(argv);

    for (0..argv.len) |i| {
        const lua_idx: isize = @intCast(i + 1);
        switch (lua.typeOf(lua_idx)) {
            .string => argv[i] = lua.toLString(lua_idx),
            inline else => |t| {
                const err_msg = std.fmt.bufPrint(
                    &print_buf,
                    "Expected arg[{d}] be of type string, got {t}",
                    .{ i + 1, t },
                ) catch "Unexpected type";

                lua.pushNil();
                _ = lua.pushlString(err_msg);

                return 2;
            },
        }
    }

    log.debug("runing {s}", .{argv[0]});
    var child = std.process.Child.init(argv, gpa);
    child.spawn(io) catch {
        lua.pushNil();
        _ = lua.pushlString("SpawnError");
        return 2;
    };

    const term = child.wait(io) catch |err| {
        const err_msg = bufPrint(&print_buf, "{t}", .{err}) catch "WaitError";
        lua.pushNil();
        _ = lua.pushlString(err_msg);
        return 2;
    };

    log.debug("child exited with term: {t}({d})\n", .{ term, term.Exited });

    lua.pushBoolean(true);
    return 1;
}

/// function Package.new()
///     return table.create(0, 6)
/// end
fn luaPackageNew(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    lua.createTable(0, 6);
    return 1;
}
