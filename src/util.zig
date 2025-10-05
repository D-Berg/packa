const std = @import("std");
const Allocator = std.mem.Allocator;
const Install = @import("Install.zig");

var stdout_buf: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
pub const stdout = &stdout_writer.interface;

var stderr_buf: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
pub const stderr = &stderr_writer.interface;

var stdin_buf: [64]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
pub const stdin = &stdin_reader.interface;

pub const Argument = union(enum) {
    install: InstallArgs,
    usage: []const u8,
    err_msg: []const u8,
    help: []const u8,
};

pub fn parseArgs(arena: Allocator, args: []const []const u8) !Argument {
    if (args.len == 0) return .{ .usage = usage };
    const first_arg = args[0];

    if (std.mem.eql(u8, first_arg, "install")) {
        return try parseInstallArgs(arena, args[1..]);
    }

    return .{ .err_msg = "Failed to parse arguments" };
}

fn parseInstallArgs(arena: Allocator, args: []const []const u8) !Argument {
    _ = arena;

    var approved = false;
    if (args.len == 0) {
        return .{ .err_msg = "no arguments passed to install cmd" };
    }

    // FIX: arg parsing flags
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            return .{ .help = "packa install <formula1> <formula2> ..." };
        }

        if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            approved = true;
        }
    }

    return .{ .install = .{ .package_names = args, .approved = approved } };
}

pub const InstallArgs = struct {
    package_names: []const []const u8,
    approved: bool = false,
};

pub const usage =
    \\Usage of packa
    \\
;

pub fn makeOrOpenAbsoluteDir(path: []const u8) !std.fs.Dir {
    if (std.fs.openDirAbsolute(path, .{})) |dir| {
        return dir;
    } else |err| {
        switch (err) {
            error.FileNotFound => {
                try std.fs.makeDirAbsolute(path);
                return try std.fs.openDirAbsolute(path, .{});
            },
            else => return err,
        }
    }
}

/// Prompt user with a yes or no prompt, returning either true or false
pub fn confirm(prompt: []const u8, retries: usize) !bool {
    try stdout.print("{s} Y/N: ", .{prompt});
    try stdout.flush();

    var questioned: usize = 0;
    while (questioned < retries) : (questioned += 1) {
        const answer = try stdin.takeDelimiterExclusive('\n');

        if (std.mem.eql(u8, answer, "N") or std.mem.eql(u8, answer, "n")) return false;
        if (std.mem.eql(u8, answer, "Y") or std.mem.eql(u8, answer, "y")) return true;

        try stdout.print("{s}", .{prompt});
        try stdout.flush();
    }

    return false;
}

pub fn fetch(gpa: Allocator, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(gpa);

    const res = try client.fetch(.{
        .response_writer = &alloc_writer.writer,
        .location = .{ .url = url },
    });

    if (res.status == .ok) {
        return try alloc_writer.toOwnedSlice();
    }

    return error.FailedFetch;
}

pub fn saveSliceToFile(dir: std.fs.Dir, file_name: []const u8, data: []const u8) !void {
    var save_file = try dir.createFile(file_name, .{});
    defer save_file.close();

    var file_write_buf: [1024]u8 = undefined;
    var file_writer = save_file.writer(&file_write_buf);

    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
}

pub fn getLuaScript(gpa: Allocator, name: []const u8, dir: std.fs.Dir) ![:0]const u8 {
    const script_path = try std.fmt.allocPrint(gpa, "formulas/{s}/{s}.lua", .{
        name[0..1], name,
    });
    defer gpa.free(script_path);

    const script_file = try dir.openFile(script_path, .{});
    defer script_file.close();

    var read_buffer: [1024]u8 = undefined;
    var file_reader = script_file.reader(&read_buffer);

    var alloc_writer = std.Io.Writer.Allocating.init(gpa);
    errdefer alloc_writer.deinit();

    _ = try file_reader.interface.streamRemaining(&alloc_writer.writer);

    return try alloc_writer.toOwnedSliceSentinel(0);
}
