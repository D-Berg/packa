const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.util);
const assert = std.debug.assert;

const minizign = @import("minizign");

/// Fast check and exit if packa is not setup
pub fn checkSetup(io: Io) !void {
    Io.Dir.cwd().access(io, "/opt/packa", .{
        .read = true,
        .write = true,
        .follow_symlinks = false,
    }) catch |err| {
        // TODO: switch on error for better reporting
        switch (err) {
            else => {},
        }
        std.log.err("packa need access to '/opt/packa', try running 'packa setup'", .{});
        return error.PackaIsNotSetup;
    };
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

pub fn fetch(io: Io, gpa: Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    var req = try client.request(.GET, try .parse(url), .{
        .keep_alive = true,
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var res = try req.receiveHead(&redirect_buffer);

    const decompress_buffer: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = res.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var offset: usize = 0;
    while (true) {
        offset += reader.stream(&aw.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return res.bodyErr().?,
            else => |e| return e,
        };
        // TODO: progressbar
    }

    return try aw.toOwnedSlice();
}

pub fn calcHash(
    io: Io,
    gpa: Allocator,
    in: []const u8,
) ![64]u8 {
    _ = io;
    _ = gpa;
    var digest: [32]u8 = undefined;

    // BUG: use parallel when https://codeberg.org/ziglang/zig/issues/30855 gets solved
    // try std.crypto.hash.Blake3.hashParallel(in, &digest, .{}, gpa, io);
    {
        var blake3: std.crypto.hash.Blake3 = .init(.{});
        blake3.update(in);
        blake3.final(&digest);
    }
    var hash_buf: [2 * digest.len]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_buf, "{x}", .{digest[0..]}) catch unreachable;
    return hash_buf;
}

pub fn unpackSource(
    io: Io,
    gpa: Allocator,
    cache_dir: Io.Dir,
    url: []const u8,
    pkg_hash: []const u8,
    out_dir: Io.Dir,
) ![]const u8 {
    const tar_file_name = url[1 + std.mem.findScalarLast(u8, url, '/').? ..];

    const compression: Compression = try .from(url);
    log.debug("compression = {t}", .{compression});

    const bytes = blk: {
        if (cache_dir.access(io, tar_file_name, .{})) {
            log.debug("cache contains {s}", .{tar_file_name});

            const tar_file = try cache_dir.openFile(io, tar_file_name, .{});
            defer tar_file.close(io);

            const tar_size = try tar_file.length(io);

            var tar_file_reader = tar_file.reader(io, &.{});
            const tar_reader: *Io.Reader = &tar_file_reader.interface;

            var blake3: std.crypto.hash.Blake3 = .init(.{});
            var digest: [32]u8 = undefined;

            var hash_reader_buf: [4096]u8 = undefined;
            var hash_reader = Io.Reader.hashed(tar_reader, &blake3, &hash_reader_buf);

            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();

            try hash_reader.reader.streamExact64(&aw.writer, tar_size);
            blake3.final(&digest);

            var hash_buf: [2 * digest.len]u8 = undefined;
            const hash = try std.fmt.bufPrint(&hash_buf, "{x}", .{digest[0..]});
            assert(hash.len == hash_buf.len);

            if (std.mem.eql(u8, pkg_hash, hash)) {
                log.debug("hashes matches", .{});
            } else {
                log.err(
                    \\hashes DONT match for {s}:
                    \\expected: {s},
                    \\recieved: {s}
                , .{ tar_file_name, pkg_hash, hash });
                return error.MalformedHash;
            }

            break :blk try aw.toOwnedSlice();
        } else |_| {
            const bytes = try fetch(io, gpa, url);
            errdefer gpa.free(bytes);

            log.debug("recieved {B}", .{bytes.len});

            const hash = try calcHash(io, gpa, bytes);
            if (!std.mem.eql(u8, pkg_hash, hash[0..])) {
                log.err("hashes DONT match, expected {s}, got {s}", .{ pkg_hash, hash });
                return error.MalformedHash;
            }
            log.debug("Hashes match, saving {s} to cache", .{tar_file_name});

            const file = try cache_dir.createFile(io, tar_file_name, .{});
            defer file.close(io);

            var file_writer_buf: [4096]u8 = undefined;
            var file_writer = file.writer(io, &file_writer_buf);

            var reader: Io.Reader = .fixed(bytes);
            assert(try reader.streamRemaining(&file_writer.interface) == bytes.len);
            try file_writer.interface.flush();

            break :blk bytes;
        }
    };
    defer gpa.free(bytes);

    var in: Io.Reader = .fixed(bytes);
    return extractArchive(io, gpa, &in, out_dir, compression);
}

const Compression = enum {
    none,
    xz,
    gz,
    zst,

    fn from(file_path: []const u8) !Compression {
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar")) return .none;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tgz")) return .gz;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.gz")) return .gz;
        if (std.ascii.endsWithIgnoreCase(file_path, ".txz")) return .xz;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.xz")) return .xz;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tzst")) return .zst;
        if (std.ascii.endsWithIgnoreCase(file_path, ".tar.zst")) return .zst;

        return error.InvalidCompression;
    }
};

pub fn extractArchive(
    io: Io,
    gpa: Allocator,
    in: *Io.Reader,
    out_dir: Io.Dir,
    compression: Compression,
) ![]const u8 {
    switch (compression) {
        .none => return try tarToDir(io, gpa, in, out_dir),
        .gz => {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor: std.compress.flate.Decompress = .init(in, .gzip, &decompress_buf);
            return try tarToDir(io, gpa, &decompressor.reader, out_dir);
        },
        .xz => {
            var decompressor: std.compress.xz.Decompress = try .init(in, gpa, &.{});
            defer decompressor.deinit();

            return try tarToDir(io, gpa, &decompressor.reader, out_dir);
        },
        .zst => {
            // TODO: reconsider window_len for decompressing zstd --ultra -20, is default enough?
            const window_len = 16 * std.compress.zstd.default_window_len;
            const window_buffer = try gpa.alloc(u8, window_len + std.compress.zstd.block_size_max);
            defer gpa.free(window_buffer);

            var decompressor: std.compress.zstd.Decompress = .init(in, window_buffer, .{
                .window_len = window_len,
            });
            { // FIX: remove this when zig asserts stops crashing
                // pipeToFileSystem uses discard
                // https://github.com/ziglang/zig/issues/25764
                var aw = Io.Writer.Allocating.init(gpa);
                defer aw.deinit();

                std.debug.print("{B}\n", .{try decompressor.reader.streamRemaining(&aw.writer)});
                var r: Io.Reader = .fixed(aw.written());
                return try tarToDir(io, gpa, &r, out_dir);
            }
            // BROKEN
            // return try tarToDir(io, gpa, &decompressor.reader, out_dir);
        },
    }
}

fn tarToDir(io: Io, gpa: Allocator, in: *Io.Reader, out_dir: Io.Dir) ![]const u8 {
    var diagnostics: std.tar.Diagnostics = .{ .allocator = gpa };
    defer diagnostics.deinit();

    try std.tar.pipeToFileSystem(io, out_dir, in, .{
        // .exclude_empty_directories = true,
        .diagnostics = &diagnostics,
    });
    if (diagnostics.errors.items.len > 0) {
        // TODO: handle errors
        log.warn("untar had errors", .{});
    }

    return try gpa.dupe(u8, diagnostics.root_dir);
}
