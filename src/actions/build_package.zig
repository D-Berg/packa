const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const util = @import("../util.zig");
const zlua = @import("zlua");
const assert = std.debug.assert;

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

    const manifest = try util.getLuaScript(io, gpa, packa_dir, args.package_name);
    defer gpa.free(manifest);

    std.debug.print("manifest: \n\n{s}\n\n", .{manifest});

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new();
    defer lua.close();

    lua.requiref("_G", zlua.Lib.base, true);

    lua.setGlobal("load");
    lua.pushNil();
    lua.setGlobal("loadfile");
    lua.pushNil();
    lua.setGlobal("dofile");

    var lua_script_name_buf: [128]u8 = undefined;
    const lua_script_name = try std.fmt.bufPrintZ(&lua_script_name_buf, "@{s}.lua", .{args.package_name});

    try lua.loadBuffer(manifest, lua_script_name);
    try lua.pcall(0, 1, 0);

    const manifest_idx = lua.getTop();
    std.debug.print("manifest_idx = {d}\n", .{manifest_idx});

    const name = switch (lua.getField(manifest_idx, "name")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };

    std.debug.print("name = {s}\n", .{name});

    const src_url = switch (lua.getField(manifest_idx, "url")) {
        .string => lua.toLString(-1),
        else => return error.WrongLuaType,
    };
    std.debug.print("src_url: {s}\n", .{src_url});

    if (lua.getField(manifest_idx, "build") != .function) {
        std.debug.print("lua: build is not a function\n", .{});
        return error.WrongLuaType;
    }

    // local ctx = {}
    lua.newTable();
    const ctx = lua.getTop();
    std.debug.print("ctx = {d}\n", .{ctx});

    var print_buf: [4096]u8 = undefined;

    // ctx["os"] = builtin.os.tag
    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.os.tag}));
    lua.setField(ctx, "os");

    _ = lua.pushlString(try std.fmt.bufPrint(&print_buf, "{t}", .{builtin.cpu.arch}));
    lua.setField(ctx, "arch");

    // TODO: actually provide a prefix;
    _ = lua.pushlString("prefix_tmp");
    lua.setField(ctx, "prefix");

    // ctx.run = luaRun
    lua.pushCFunction(luaRun);
    lua.setField(ctx, "run");

    lua.pushLightUserdata(@ptrCast(@alignCast(@constCast(&io))));
    lua.setField(ctx, "io");

    lua.pushLightUserdata(@ptrCast(@alignCast(@constCast(&gpa))));
    lua.setField(ctx, "gpa");

    lua.newTable();
    const env_table = lua.getTop();
    lua.pushCFunction(luaEnvSet);
    lua.setField(env_table, "set");

    lua.pushLightUserdata(@ptrCast(@alignCast(env)));
    lua.setField(env_table, "ud");

    lua.setField(ctx, "env");

    // build(ctx)
    lua.pcall(1, 0, 0) catch |err| {
        // TODO: run cleanup
        return err;
    };
}

// TODO: type check args and check number of args supplied by lua
fn luaEnvSet(state: ?*zlua.LuaState) callconv(.c) c_int {
    std.debug.print("lua called: lua_env_set\n", .{});
    const lua: zlua.State = .{ .inner = state.? };

    assert(lua.getField(1, "ud") == .light_userdata);
    const ud = lua.toUserdata(-1) orelse {
        lua.pop(1);
        lua.pushBoolean(false);
        _ = lua.pushlString("null userdata");
        return 2;
    };
    lua.pop(1); // restore stack
    const env_map: *std.process.EnvMap = @ptrCast(@alignCast(ud));

    const key = lua.toLString(2);
    const value = lua.toLString(3);

    env_map.put(key, value) catch |err| {
        std.debug.panic("{t}", .{err});
    };

    lua.pushBoolean(true);
    return 1;
}

fn luaRun(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };

    var print_buf: [128]u8 = undefined;

    const n_args = lua.getTop();
    std.debug.print("run got called with {d} args\n", .{n_args});

    assert(lua.getField(1, "io") == .light_userdata);
    const io_ud = lua.toUserdata(-1) orelse {
        lua.pop(1);
        lua.pushBoolean(false);
        _ = lua.pushlString("io userdata was null");
        return 2;
    };
    lua.pop(1); // restore stack
    const io_ptr: *const Io = @ptrCast(@alignCast(io_ud));
    const io = io_ptr.*;

    assert(lua.getField(1, "gpa") == .light_userdata);
    const gpa_ud = lua.toUserdata(-1) orelse {
        lua.pop(1);
        lua.pushBoolean(false);
        _ = lua.pushlString("gpa userdata was null");
        return 2;
    };
    lua.pop(1); // restore stack
    const gpa_ptr: *const Allocator = @ptrCast(@alignCast(gpa_ud));
    const gpa = gpa_ptr.*;

    const argv = gpa.alloc([]const u8, lua.rawLen(2)) catch |err| {
        std.debug.panic("{t}", .{err});
    };
    defer gpa.free(argv);

    for (0..argv.len) |i| {
        switch (lua.rawGeti(2, i + 1)) { // pushes
            .string => argv[i] = lua.toLString(-1),
            inline else => |t| {
                lua.pop(1); // rawGeti
                const err_msg = std.fmt.bufPrint(
                    &print_buf,
                    "Expected arg[{d}] be of type string, got {t}",
                    .{ i + 1, t },
                ) catch "Unexpected type";
                lua.pushBoolean(false);
                _ = lua.pushlString(err_msg);

                return 2;
            },
        }
        // safe since table hold reference to the strings
        lua.pop(1); // rawGetI;
    }

    var child = std.process.Child.init(argv, gpa);
    child.spawn(io) catch {
        lua.pushBoolean(false);
        _ = lua.pushlString("SpawnError");
        return 2;
    };

    const term = child.wait(io) catch {
        lua.pushBoolean(false);
        _ = lua.pushlString("WaitError");
        return 2;
    };

    std.debug.print("child exited with term: {t}({d})\n", .{ term, term.Exited });

    lua.pushBoolean(true);
    return 1;
}
