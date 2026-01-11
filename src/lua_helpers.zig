const zlua = @import("zlua");

pub fn lua_pkg(state: ?*zlua.LuaState) callconv(.c) c_int {
    _ = state;
    // TODO: assert nargs
    return 1;
}

pub fn setupState(lua: *const zlua.State) void {
    lua.requiref("_G", zlua.Lib.base, true);

    lua.setGlobal("load");
    lua.pushNil();
    lua.setGlobal("loadfile");
    lua.pushNil();
    lua.setGlobal("dofile");

    lua.pushCFunction(lua_pkg);
    lua.setGlobal("pkg");
}
