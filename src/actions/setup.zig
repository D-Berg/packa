const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.setup);
const assert = std.debug.assert;

pub fn setup(io: Io, arena: Allocator, progress: std.Progress.Node) !void {
    if (!std.meta.isError(Io.Dir.cwd().access(io, "/opt/packa", .{}))) {
        log.err("packa seems to be already setup", .{});
        return error.AlreadySetup;
    }

    const uid = std.posix.getuid();
    const gid = std.posix.getgid();

    if (uid != 0) {
        log.info("Need root privelages", .{});
        try run(io, arena, &.{ "sudo", "-v" }, .none, null);
    }

    const setup_progress = progress.start("setup", 4);
    defer setup_progress.end();

    try run(io, arena, &.{ "sudo", "mkdir", "-p", "/opt/packa" }, setup_progress, null);

    var id_str_buf: [32]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_str_buf, "{d}:{d}", .{ uid, gid });
    try run(io, arena, &.{ "sudo", "chown", id_str, "/opt/packa" }, setup_progress, null);

    const packa_dir = try Io.Dir.cwd().openDir(io, "/opt/packa", .{
        .follow_symlinks = false,
    });
    defer packa_dir.close(io);
    try packa_dir.createDirPath(io, "bin");
    try packa_dir.createDirPath(io, "lib");
    try packa_dir.createDirPath(io, "share");
    try packa_dir.createDirPath(io, "cache");
    try packa_dir.createDirPath(io, "tmp");
    try packa_dir.createDirPath(io, "repos");
    try packa_dir.createDirPath(io, "store");

    const repo_dir = try packa_dir.openDir(io, "repos", .{});
    defer repo_dir.close(io);
    try run(
        io,
        arena,
        &.{ "git", "clone", "https://github.com/d-berg/packa-core", "core" },
        setup_progress,
        repo_dir,
    );

    log.info("Success", .{});
}

fn run(
    io: Io,
    arena: Allocator,
    argv: []const []const u8,
    progress: std.Progress.Node,
    cwd_dir: ?Io.Dir,
) !void {
    assert(argv.len > 0);
    const argv_str = try std.mem.join(arena, " ", argv);

    const run_progress = progress.start(argv_str, 1);
    defer run_progress.end();

    const run_result = try std.process.Child.run(arena, io, .{
        .argv = argv,
        .progress_node = run_progress,
        .cwd_dir = cwd_dir,
    });
    switch (run_result.term) {
        .Exited => |code| if (code != 0) {
            log.err("{s} failed with exit code {d}", .{ argv_str, code });
            log.err("{s}", .{run_result.stderr});
            return error.BadExit;
        },
        inline else => |code| {
            log.err(
                "Failed to create dir '/opt/packa' due to {t}({d})\n {s}",
                .{ run_result.term, code, run_result.stderr },
            );
            return error.RunFailed;
        },
    }
}
