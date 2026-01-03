const zlua = @import("zlua");

/// function Package.new()
///     return table.create(0, 6)
/// end
pub fn luaPackageNew(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: zlua.State = .{ .inner = state.? };
    lua.createTable(0, 6);
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
        lua.createTable(0, 1);
        const package_idx = lua.getTop();
        lua.pushCFunction(luaPackageNew);
        lua.setField(package_idx, "new");
        lua.setGlobal("Package");
    }
}
