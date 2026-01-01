const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const minizign = @import("minizign");
const pub_key = @embedFile("minisign.pub");

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
pub fn confirm(io: Io, prompt: []const u8, retries: usize) !bool {
    var stdout_buf: [64]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *Io.Writer = &stdout_w.interface;

    var stdin_buf: [64]u8 = undefined;
    var stdin_r = Io.File.stdin().reader(io, &stdin_buf);
    const stdin: *Io.Reader = &stdin_r.interface;

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

// TODO: rename to fetch_alloc
pub fn fetch(io: Io, gpa: Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(gpa);
    errdefer alloc_writer.deinit();

    const res = try client.fetch(.{
        .response_writer = &alloc_writer.writer,
        .location = .{ .url = url },
    });

    switch (res.status) {
        .ok => return try alloc_writer.toOwnedSlice(),
        else => |status| {
            std.log.err("Failed to fetch from {s}, got status {t}({d})", .{
                url,
                status,
                @intFromEnum(status),
            });

            return error.FailedFetch;
        },
    }
}

pub fn saveSliceToFile(io: Io, dir: Io.Dir, file_name: []const u8, data: []const u8) !void {
    var save_file = try dir.createFile(io, file_name, .{});
    defer save_file.close(io);

    var file_write_buf: [1024]u8 = undefined;
    var file_writer = save_file.writer(io, &file_write_buf);

    try file_writer.interface.writeAll(data);
    try file_writer.interface.flush();
}

/// Retreives Lua script `dir/formulas/<name[0]/{name}.lua`
pub fn getLuaScript(io: Io, gpa: Allocator, dir: Io.Dir, name: []const u8) ![:0]const u8 {
    const script_path = try std.fmt.allocPrint(gpa, "formulas/{s}/{s}.lua", .{
        name[0..1], name,
    });
    defer gpa.free(script_path);

    const script_file = try dir.openFile(io, script_path, .{});
    defer script_file.close(io);

    var read_buffer: [1024]u8 = undefined;
    var file_reader = script_file.reader(io, &read_buffer);

    var alloc_writer = std.Io.Writer.Allocating.init(gpa);
    errdefer alloc_writer.deinit();

    _ = try file_reader.interface.streamRemaining(&alloc_writer.writer);

    return try alloc_writer.toOwnedSliceSentinel(0);
}

/// Verify minisign Signature
pub fn checkSignature(gpa: Allocator, bytes: []const u8, minisig: []const u8) !bool {
    var pks_buf: [64]minizign.PublicKey = undefined;
    const pks = try minizign.PublicKey.decode(&pks_buf, pub_key);

    var sig = try minizign.Signature.decode(gpa, minisig);
    defer sig.deinit();

    var verifier = try pks[0].verifier(&sig);
    verifier.update(bytes);
    verifier.verify(gpa) catch return false;

    return true;
}

pub fn calcHash(in: []const u8) [64]u8 {
    var blake3 = std.crypto.hash.Blake3.init(.{});
    blake3.update(in);

    var hash: [32]u8 = undefined;
    blake3.final(&hash);

    var hash_buf: [2 * hash.len]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_buf, "{x}", .{hash[0..]}) catch unreachable;
    return hash_buf;
}
