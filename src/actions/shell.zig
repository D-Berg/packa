const std = @import("std");
const Config = @import("../Config.zig");
const Lock = @import("../Lock.zig");
const cli = @import("../cli.zig");
const installer = @import("install.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn shell(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    progress: std.Progress.Node,
    environ: *const std.process.Environ.Map,
    args: cli.ShellArgs,
) !void {
    const config_path = try findProjectConfig(io, arena);
    const config = try Config.load(io, arena, config_path, args.name);
    if (config.shell_packages.len == 0) return error.EmptyDevelopmentShell;

    const shell_name = args.name orelse "default";
    const lock_path = try std.fs.path.join(arena, &.{
        std.fs.path.dirname(config_path) orelse ".",
        "packa.lock",
    });
    const config_hash = try Lock.configHash(io, arena, config_path, shell_name);
    const previous_lock = try Lock.read(io, arena, lock_path);

    const installed = try installer.installForShell(io, gpa, arena, progress, .{
        .package_names = config.shell_packages,
        .approved = true,
        .build_from_source = config.build_from_source,
        .link_global = false,
    });

    const locked_packages = try arena.alloc(Lock.Package, installed.packages.len);
    for (locked_packages, installed.packages) |*locked, resolved| {
        locked.* = .{
            .name = resolved.name,
            .version = resolved.version,
            .id = resolved.id,
        };
    }
    const current_shell: Lock.Shell = .{
        .config_hash = config_hash,
        .name = shell_name,
        .packages = locked_packages,
    };

    var write_lock = true;
    if (previous_lock) |previous| {
        if (std.mem.eql(u8, previous.target, Lock.target)) {
            if (Lock.findShell(previous, shell_name)) |previous_shell| {
                const same_config = std.mem.eql(u8, previous_shell.config_hash, config_hash);
                if (same_config and !Lock.shellEql(previous_shell, current_shell) and !args.update_lock) {
                    std.log.err("package resolution differs from packa.lock; run 'packa shell --update' to accept it", .{});
                    return error.LockOutOfDate;
                }
                if (Lock.shellEql(previous_shell, current_shell)) write_lock = false;
            }
        }
    }
    if (write_lock) {
        const old_shells = if (previous_lock) |previous|
            if (std.mem.eql(u8, previous.target, Lock.target)) previous.shells else &.{}
        else
            &.{};
        var shells = try arena.alloc(Lock.Shell, old_shells.len + 1);
        var count: usize = 0;
        for (old_shells) |old_shell| {
            if (std.mem.eql(u8, old_shell.name, shell_name)) continue;
            shells[count] = old_shell;
            count += 1;
        }
        shells[count] = current_shell;
        count += 1;
        shells = shells[0..count];
        std.mem.sort(Lock.Shell, shells, {}, struct {
            fn lessThan(_: void, a: Lock.Shell, b: Lock.Shell) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
        try Lock.write(io, lock_path, .{
            .target = Lock.target,
            .shells = shells,
        });
    }

    var child_env = try environ.clone(gpa);
    defer child_env.deinit();
    for (config.environment) |entry| try child_env.put(entry.key, entry.value);

    const old_path = environ.get("PATH") orelse "";
    const prefix = try std.mem.join(arena, ":", installed.bin_paths);
    const path = if (prefix.len == 0)
        old_path
    else
        try std.fmt.allocPrint(arena, "{s}:{s}", .{ prefix, old_path });
    try child_env.put("PATH", path);
    try child_env.put("PACKA_SHELL", shell_name);

    const shell_path = environ.get("SHELL") orelse "/bin/sh";
    var child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &child_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.DevelopmentShellFailed,
        else => return error.DevelopmentShellFailed,
    }
}

fn findProjectConfig(io: Io, arena: Allocator) ![]const u8 {
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPath(io, &cwd_buf);
    var current: []const u8 = cwd_buf[0..cwd_len];

    while (true) {
        const candidate = try std.fs.path.join(arena, &.{ current, "packa.lua" });
        if (Io.Dir.cwd().access(io, candidate, .{})) {
            return candidate;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }
    return error.PackaConfigNotFound;
}
