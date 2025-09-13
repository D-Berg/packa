const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const State = c.lua_State;

pub fn newState() error{NewStateError}!*State {
    if (c.luaL_newstate()) |state| {
        return state;
    }

    return error.NewStateError;
}
var user_data: UserData = undefined;
const UserData = struct {
    allocator: Allocator,
};

fn alloc(
    maybe_ud: ?*anyopaque,
    maybe_ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    _ = maybe_ud;
    const gpa = user_data.allocator;

    if (nsize == 0) {
        if (maybe_ptr) |ptr| {
            var slice: []u8 = undefined;
            slice.ptr = @ptrCast(ptr);
            slice.len = osize;

            gpa.free(slice);
        }
    } else if (maybe_ptr) |ptr| {
        var slice: []u8 = undefined;
        slice.ptr = @ptrCast(ptr);
        slice.len = osize;

        if (gpa.realloc(slice, nsize)) |new_slice| {
            return @ptrCast(new_slice.ptr);
        } else |_| return null;
    } else {
        if (gpa.alloc(u8, nsize)) |slice| {
            @memset(slice, 0);
            return @ptrCast(slice.ptr);
        } else |_| return null;
    }

    return null;
}

pub fn newStateAlloc(gpa: Allocator) !*State {
    user_data = .{ .allocator = gpa };
    if (c.lua_newstate(alloc, null)) |state| {
        return state;
    }
    return error.NewStateError;
}

pub fn close(state: *State) void {
    c.lua_close(state);
}

pub const openLibs = c.luaL_openlibs;

fn printLuaError(state: ?*c.lua_State) void {
    var len: usize = 0;
    const msg = c.lua_tolstring(state, -1, &len);
    if (msg != null) std.debug.print("{s}\n", .{msg[0..len]});
}

pub fn loadString(state: *State, string: [:0]const u8) error{LuaError}!void {
    const rc = c.luaL_loadstring(state, string);
    try checkError(state, rc);
}

pub fn pcallk(state: *State) !void {
    const rc = c.lua_pcallk(state, 0, c.LUA_MULTRET, 0, 0, null);
    try checkError(state, rc);
}

fn checkError(state: *State, rc: c_int) !void {
    if (rc != c.LUA_OK) {
        printLuaError(state);
        return error.LuaError;
    }
}

///Pushes onto the stack the value t[k], where t is the value at the given index.
///As in Lua, this function may trigger a metamethod for the "index" event (see §2.4).
//Returns the type of the pushed value.
pub fn getField(state: *State, idx: isize, field: [:0]const u8) LuaType {
    return @enumFromInt(c.lua_getfield(state, @intCast(idx), field));
}

pub const LuaType = enum(c_int) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    light_userdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
};

pub fn toLString(state: *State, idx: isize) []const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, @intCast(idx), &len);
    var slice: []const u8 = undefined;
    slice.ptr = ptr;
    slice.len = len;
    return slice;
}

pub const remove = c.lua_remove;

///Pops n elements from the stack.
pub const pop = c.lua_pop;
