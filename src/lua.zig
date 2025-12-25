//! Here we list all functions and types from the C API in alphabetical order. Each function has an indicator like this: [-o, +p, x]
//! The first field, o, is how many elements the function pops from the stack.
//! The second field, p, is how many elements the function pushes onto the stack.
//! (Any function always pushes its results after popping its arguments.)
//! A field in the form x|y means the function can push (or pop) x or y elements,
//! depending on the situation; an interrogation mark '?' means that we cannot know
//! how many elements the function pops/pushes by looking only at its arguments.
//! (For instance, they may depend on what is in the stack.)
//! The third field, x, tells whether the function may raise errors: '-' means the function never raises any error;
//! 'm' means the function may raise only out-of-memory errors;
//! 'v' means the function may raise the errors explained in the text;
//! 'e' means the function can run arbitrary Lua code, either directly or through metamethods, and therefore may raise any errors.

const std = @import("std");
const c = @import("c");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const LuaState = c.lua_State;

pub const MultiRet = c.LUA_MULTRET;

pub const Error = error{
    NewStateError,
    UnknownError,
};

pub const State = struct {
    inner: *LuaState = undefined,
    gpa: Allocator,

    /// Requires a stable pointer for gpa
    pub fn new(self: *State) !void {
        if (c.lua_newstate(alloc, &self.gpa)) |state| {
            self.inner = state;
            return;
        }
        return error.LuaError;
    }

    pub fn close(self: *const State) void {
        c.lua_close(self.inner);
    }
    /// Performs an arithmetic or bitwise operation over the two values (or one, in the case of negations)
    /// at the top of the stack, with the value on the top being the second operand,
    /// pops these values, and pushes the result of the operation.
    /// The function follows the semantics of the corresponding Lua operator (that is, it may call metamethods).
    pub fn arith(self: *const State, op: Op) void {
        c.lua_arith(self.inner, op);
    }

    /// Opens all standard Lua libraries into the given state.
    pub fn openLibs(self: *const State) void {
        c.luaL_openlibs(self.inner);
    }

    /// Loads a string as a Lua chunk. This function uses lua_load to load the chunk in the zero-terminated string s.
    /// This function returns the same results as lua_load.
    /// Also as lua_load, this function only loads the chunk; it does not run it.
    pub fn loadString(state: *State, string: [:0]const u8) Error!void {
        const rc = c.luaL_loadstring(state.inner, string);
        try checkError(state, rc);
    }

    fn printLuaError(state: ?*c.lua_State) void {
        var len: usize = 0;
        const msg = c.lua_tolstring(state, -1, &len);
        if (msg != null) std.debug.print("{s}\n", .{msg[0..len]});
    }

    /// Calls a function (or a callable object) in protected mode.
    /// Both nargs and nresults have the same meaning as in lua_call.
    /// If there are no errors during the call, lua_pcall behaves exactly like lua_call.
    /// However, if there is any error, lua_pcall catches it, pushes a single value on the stack (the error object),
    /// and returns an error code. Like lua_call, lua_pcall always removes the function and its arguments from the stack.
    ///
    /// If msgh is 0, then the error object returned on the stack is exactly the original error object.
    /// Otherwise, msgh is the stack index of a message handler.
    /// (This index cannot be a pseudo-index.) In case of runtime errors,
    /// this handler will be called with the error object and its return value will be the object returned on the stack by lua_pcall.
    ///
    /// Typically, the message handler is used to add more debug information to the error object,
    /// such as a stack traceback. Such information cannot be gathered after the return of lua_pcall,
    /// since by then the stack has unwound.
    ///
    /// The lua_pcall function returns one of the following status codes: LUA_OK, LUA_ERRRUN, LUA_ERRMEM, or LUA_ERRERR.
    /// FIX: doesnt wooooork
    pub fn pcall(state: *State, nargs: isize, nresults: isize, msgh: isize) !void {
        const rc = c.lua_pcall(
            state.inner,
            @as(c_int, @intCast(nargs)),
            @as(c_int, @intCast(nresults)),
            @as(c_int, @intCast(msgh)),
        );
        try checkError(state, rc);
    }

    /// This function behaves exactly like lua_pcall, except that it allows the called function to yield (see §4.5).
    pub fn pcallk(state: *State, nargs: isize, nresults: isize, msgh: isize, ctx: isize, k: KFunction) !void {
        const rc = c.lua_pcallk(
            state.inner,
            @as(c_int, @intCast(nargs)),
            @as(c_int, @intCast(nresults)),
            @as(c_int, @intCast(msgh)),
            ctx,
            @ptrCast(k),
        );
        try checkError(state, rc);
    }

    fn checkError(state: *const State, rc: c_int) Error!void {
        if (rc != c.LUA_OK) {
            printLuaError(state.inner);
            return Error.UnknownError;
        }
    }

    ///Pushes onto the stack the value `t[k]`, where t is the value at the given index.
    ///As in Lua, this function may trigger a metamethod for the "index" event (see §2.4).
    //Returns the type of the pushed value.
    pub fn getField(state: *State, idx: isize, field: [:0]const u8) Type {
        return @enumFromInt(c.lua_getfield(state.inner, @intCast(idx), field));
    }

    pub fn toLString(state: *State, idx: isize) []const u8 {
        var len: usize = 0;
        const ptr = c.lua_tolstring(state.inner, @intCast(idx), &len);
        var slice: []const u8 = undefined;
        slice.ptr = ptr;
        slice.len = len;
        return slice;
    }

    ///Pops n elements from the stack.
    pub fn pop(self: *const State, n: isize) void {
        c.lua_pop(self.inner, @as(c_int, @intCast(n)));
    }

    /// Removes the element at the given valid index,
    /// shifting down the elements above this index to fill the gap.
    /// This function cannot be called with a pseudo-index, because a pseudo-index is not an actual stack position.
    pub fn remove(self: *const State, index: isize) void {
        c.lua_remove(self.inner, index);
    }
};

fn alloc(
    maybe_ud: ?*anyopaque,
    maybe_ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const gpa: *Allocator = @ptrCast(@alignCast(maybe_ud));

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

        const new_slice = gpa.realloc(slice, nsize) catch return null;
        return @ptrCast(new_slice.ptr);
    } else {
        const slice = gpa.alloc(u8, nsize) catch return null;
        @memset(slice, 0);
        return @ptrCast(slice.ptr);
    }

    return null;
}

pub const Type = enum(c_int) {
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

pub const Op = enum(c_int) {
    /// performs addition (+)
    add = c.LUA_OPADD,
    sub = c.LUA_OPSUB,
    mul = c.LUA_OPMUL,
    div = c.LUA_OPDIV,
    idiv = c.LUA_OPIDIV,
    mod = c.LUA_OPMOD,
    pow = c.LUA_OPPOW,
    /// performs mathematical negation (unary -)
    unm = c.LUA_OPUNM,
};

pub const KFunction = ?*const fn (state: ?*LuaState, status: isize, ctx: isize) callconv(.c) isize;
