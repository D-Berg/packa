const std = @import("std");
const build_options = @import("build_options");
const zlua = @import("zlua");
const util = @import("../util.zig");
const cli = @import("../cli.zig");
const lua_helpers = @import("../lua_helpers.zig");
const minizign = @import("minizign");
const Package = @import("../Package.zig");
const string = @import("../string.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const assert = std.debug.assert;
const log = std.log.scoped(.info);

pub fn info(io: Io, gpa: Allocator, package_name: []const u8) !void {
    try util.checkSetup(io);

    const packa_dir = try Io.Dir.cwd().openDir(io, "/opt/packa", .{});
    defer packa_dir.close(io);

    // TODO: read maintainer key from config
    const maintainer_pub_key = try minizign.PublicKey.decodeFromBase64(build_options.pub_key);

    const repo_pub_key = try packa_dir.readFileAllocOptions(io, "repos/core/minisign.pub", gpa, .limited(1024), .@"8", null);
    defer gpa.free(repo_pub_key);

    const repo_sign = try packa_dir.readFileAllocOptions(io, "repos/core/minisign.pub.minisig", gpa, .limited(1024), .@"8", null);
    defer gpa.free(repo_sign);

    var sig = try minizign.Signature.decode(gpa, repo_sign);
    defer sig.deinit();

    var verifier = try maintainer_pub_key.verifier(&sig);
    verifier.update(repo_pub_key);
    try verifier.verify(gpa);

    assert(package_name.len > 0);
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&path_buf, "repos/core/manifests/{c}/{s}.lua", .{
        package_name[0],
        package_name,
    });
    const man_stat = try packa_dir.statFile(io, manifest_path, .{});
    const manifest = try packa_dir.readFileAllocOptions(io, manifest_path, gpa, .limited64(man_stat.size + 1), .@"8", 0);
    defer gpa.free(manifest);

    var lua: zlua.State = .{ .gpa = gpa };
    try lua.new(0);
    defer lua.close();

    lua_helpers.setupState(&lua);

    var state: Package.State = .empty;
    defer state.deinit(gpa);

    const pkg_id = try Package.collect(io, gpa, &state, packa_dir, package_name, &lua, false);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *Io.Writer = &stdout_writer.interface;

    const terminal: Io.Terminal = .{
        .writer = stdout,
        .mode = .escape_codes,
    };

    // TODO: check if binarie exist
    // TODO: insert fake build fn args and print build steps

    try printInfo(io, terminal, pkg_id, &state);
    try terminal.writer.flush();
}

fn printInfo(
    io: Io,
    t: Io.Terminal,
    pkg_id: Package.Id,
    state: *const Package.State,
) !void {
    const pkg = state.packages.get(@intFromEnum(state.package_table.get(pkg_id).?));

    try t.setColor(.bold);
    try t.writer.print("{s}-{f}\n", .{ pkg.name.slice(&state.string_state), pkg.version });
    try t.setColor(.reset);

    try t.writer.print("{s}\n\n", .{pkg.desc.slice(&state.string_state)});

    try t.writer.print("{s:<10}", .{"Homepage:"});
    try t.writer.print("\x1b[4m", .{}); // underline
    try t.writer.print("{s}\n", .{pkg.homepage.slice(&state.string_state)});
    try t.setColor(.reset);

    try t.writer.print("{s:<10}", .{"License:"});
    try t.writer.print("{s}\n", .{pkg.license.slice(&state.string_state)});

    try t.writer.print("{s:<10}", .{"Url: "});
    try t.writer.print("\x1b[4m", .{}); // underline
    try t.writer.print("{s}\n", .{pkg.source_url.slice(&state.string_state)});
    try t.setColor(.reset);

    try t.writer.print("{s:<10}", .{"Blake3:"});
    try t.writer.print("{s}\n", .{pkg.source_hash.slice(&state.string_state)});

    try t.writer.print("{s:<10}{s}\n", .{ "Deps:", "compile(◇), runtime(○)" });

    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;

    try printDeps(io, t, pkg_id, state, true, 0, 0, &path_buf);
}

fn printDeps(
    io: Io,
    t: Io.Terminal,
    pkg_id: Package.Id,
    state: *const Package.State,
    is_root: bool,
    level: u6,
    pipes: u64,
    path_buf: []u8,
) !void {
    const pkg = state.packages.get(@intFromEnum(state.package_table.get(pkg_id).?));
    const comp_deps = state.dependencies.items[pkg.compile_deps.start..][0..pkg.compile_deps.count];
    const run_deps = state.dependencies.items[pkg.runtime_deps.start..][0..pkg.runtime_deps.count];
    const total = comp_deps.len + run_deps.len;

    for (0..total) |i| {
        const is_comp = i < comp_deps.len;
        const dep = if (is_comp) comp_deps[i] else run_deps[i - comp_deps.len];
        const is_last = (i == total - 1);

        const dep_pkg = state.packages.get(@intFromEnum(state.package_table.get(dep.pkg_id).?));

        for (0..level) |l| {
            const pipe = if ((pipes >> @intCast(l)) & 1 == 1) "│  " else "   ";
            try t.writer.print("{s}", .{pipe});
        }

        try t.writer.print("{s}", .{if (is_root and i == 0) "╭──" else if (is_last) "╰──" else "├──"});
        try t.writer.print("{s}", .{if (is_comp) "◇ " else "○ "});

        const path = try std.fmt.bufPrint(path_buf, "{s}-{f}-{s}", .{
            dep.name.slice(&state.string_state), dep_pkg.version, dep.pkg_id.slice(&state.string_state)[0..32],
        });

        if (Io.Dir.cwd().access(io, path, .{})) {
            try t.setColor(.green);
        } else |_| {
            try t.setColor(.red);
        }
        try t.writer.print("{s}-{f}\n", .{ dep.name.slice(&state.string_state), dep_pkg.version });
        try t.setColor(.reset);

        const next_pipes = if (is_last) pipes & ~(@as(u64, 1) << level) else pipes | (@as(u64, 1) << level);
        try printDeps(io, t, dep.pkg_id, state, false, level + 1, next_pipes, path_buf);
    }
}
