const std = @import("std");
const log = std.log.scoped(.zig_build);

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "strip binary");

    const version = getVersion(b) catch |err| {
        std.debug.panic("Failed to get version: error: {t}", .{err});
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
    });

    const minizign_dep = b.dependency("minizign", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = @tagName(manifest.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .strip = strip,
        }),
    });
    exe.root_module.addImport("zlua", zlua_dep.module("zlua"));
    exe.root_module.addImport("minizign", minizign_dep.module("minizign"));
    exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());

    const run_cmd = b.step("run", "run executable");
    run_cmd.dependOn(&run_exe.step);

    const test_exe = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_unit_test = b.addRunArtifact(test_exe);

    if (b.args) |args| {
        run_exe.addArgs(args);
        run_unit_test.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_test.step);
}

fn getVersion(b: *std.Build) ![]const u8 {
    const version = manifest.version;
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git", "-C", b.build_root.path orelse ".",
        "--git-dir", ".git", // affected by the -C argument
        "describe", "--match",    "*.*.*", //
        "--tags",   "--abbrev=8",
    }, &code, .Ignore) catch {
        return version;
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");
    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            if (!std.mem.eql(u8, git_describe, version)) {
                std.debug.panic(
                    "packa version '{s}' does not match Git tag '{s}'\n",
                    .{ version, git_describe },
                );
            }
            return version;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            var sem_ver = try std.SemanticVersion.parse(version);
            if (sem_ver.order(ancestor_ver) == .lt) {
                std.debug.panic(
                    "version '{f}' must be greater or equal to tagged ancestor '{f}'\n",
                    .{ sem_ver, ancestor_ver },
                );
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
                return version;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version, commit_height, commit_id[1..] });
        },
        else => {
            log.err("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version;
        },
    }
}
