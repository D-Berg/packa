const std = @import("std");
const zlua = @import("zlua");
const assert = std.debug.assert;
const max_load_percentage = std.hash_map.default_max_load_percentage;

pub const State = struct {
    string_bytes: std.ArrayList(u8) = .empty,
    string_table: String.Table = .empty,

    pub const empty = State{};

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        state.string_bytes.deinit(gpa);
        state.string_table.deinit(gpa);
    }

    pub const String = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub const Table = std.HashMapUnmanaged(String, void, TableContext, max_load_percentage);

        pub const TableContext = struct {
            bytes: []const u8,
            pub fn eql(_: @This(), a: String, b: String) bool {
                return a == b;
            }

            pub fn hash(ctx: @This(), key: String) u64 {
                return std.hash_map.hashString(std.mem.sliceTo(ctx.bytes[@intFromEnum(key)..], 0));
            }
        };

        pub const TableIndexAdapter = struct {
            bytes: []const u8,

            pub fn eql(ctx: @This(), a: []const u8, b: String) bool {
                return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes[@intFromEnum(b)..], 0));
            }

            pub fn hash(_: @This(), adapted_key: []const u8) u64 {
                assert(std.mem.indexOfScalar(u8, adapted_key, 0) == null);
                return std.hash_map.hashString(adapted_key);
            }
        };

        pub fn slice(index: String, state: *const State) [:0]const u8 {
            if (index == .none) return "";
            const start_slice = state.string_bytes.items[@intFromEnum(index)..];
            return start_slice[0..std.mem.indexOfScalar(u8, start_slice, 0).? :0];
        }
    };

    pub fn internString(state: *State, gpa: std.mem.Allocator, bytes: []const u8) !String {
        const gop = try state.string_table.getOrPutContextAdapted(
            gpa,
            @as([]const u8, bytes),
            @as(String.TableIndexAdapter, .{ .bytes = state.string_bytes.items }),
            @as(String.TableContext, .{ .bytes = state.string_bytes.items }),
        );
        if (gop.found_existing) return gop.key_ptr.*;

        try state.string_bytes.ensureUnusedCapacity(gpa, bytes.len + 1);
        const new_offset: String = @enumFromInt(state.string_bytes.items.len);

        state.string_bytes.appendSliceAssumeCapacity(bytes);
        state.string_bytes.appendAssumeCapacity(0);

        gop.key_ptr.* = new_offset;

        return new_offset;
    }
};

test {
    const gpa = std.testing.allocator;

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();

    _ = lua.pushLString("Hello World");

    var state: State = .empty;
    defer state.deinit(gpa);

    _ = try state.internString(gpa, lua.toLString(-1));
    _ = try state.internString(gpa, lua.toLString(-1));
}
