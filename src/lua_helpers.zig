const std = @import("std");
const zlua = @import("zlua");
const builtin = @import("builtin");

pub fn lua_pkg(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    lua.checkType(1, .table);
    return 1;
}

pub fn setupState(lua: *const zlua.State) !void {
    lua.requiref("_G", zlua.Open.base, true);

    try lua.loadBuffer(@embedFile("error_wrapper.lua"), "@packa_lua_error_wrapper");
    try lua.pcall(0, 1, 0);
    lua.setField(zlua.REGISTRYINDEX, "packa.checked");

    lua.setGlobal("load");
    lua.pushNil();
    lua.setGlobal("loadfile");
    lua.pushNil();
    lua.setGlobal("dofile");

    lua.pushCFunction(lua_pkg);
    lua.setGlobal("pkg");

    _ = lua.pushLString(std.fmt.comptimePrint("{t}-{t}", .{
        builtin.cpu.arch, builtin.os.tag,
    }));
    lua.setGlobal("platform");
}

/// Wraps a native function with error_wrapper.lua
pub fn pushChecked(
    lua: *const zlua.State,
    native: zlua.CFunction,
    context: ?*anyopaque,
) !void {
    std.debug.assert(lua.getField(zlua.REGISTRYINDEX, "packa.checked") == .function);

    var upvalues: usize = 0;
    if (context) |ctx| {
        lua.pushLightUserdata(ctx);
        upvalues += 1;
    }
    lua.pushCClosure(native, upvalues);
    try lua.pcall(1, 1, 0);
}

const TestContext = struct {
    cleaned: bool = false,
};

fn testFailure(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    const context: *TestContext = @ptrCast(@alignCast(lua.toUserdata(lua.upvalueIndex(1))));
    defer context.cleaned = true;

    lua.pushNil();
    _ = lua.pushLString("native failure");
    return 2;
}

test pushChecked {
    var lua: zlua.State = .{ .gpa = std.testing.allocator };
    try lua.new(0);
    defer lua.close();

    try setupState(&lua);

    var context: TestContext = .{};
    try pushChecked(&lua, testFailure, &context);
    try std.testing.expectError(zlua.Error.Run, lua.pcall(0, 0, 0));
    try std.testing.expect(context.cleaned);
    try std.testing.expectEqualStrings("native failure", lua.toLString(-1));
}
