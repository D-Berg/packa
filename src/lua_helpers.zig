const zlua = @import("zlua");

pub fn lua_pkg(state: ?*zlua.LuaState) callconv(.c) c_int {
    _ = state;
    return 1;
}

pub fn setupState(lua: *const zlua.State) void {
    lua.requiref("_G", zlua.Lib.base, true);

    lua.setGlobal("load");
    lua.pushNil();
    lua.setGlobal("loadfile");
    lua.pushNil();
    lua.setGlobal("dofile");

    { // create global Package with Package.new()
        lua.pushCFunction(lua_pkg);
        lua.setGlobal("pkg");
    }
}

// TODO make helper fn to lua.pkg -> zig.Package
