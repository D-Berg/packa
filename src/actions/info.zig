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

    try printInfo(terminal, pkg_id, &state);
    try terminal.writer.flush();
}

fn printInfo(
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
}

// TODO print dependency tree
fn printDeps(t: Io.Terminal) !void {
    _ = t;
}
