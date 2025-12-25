const std = @import("std");

const manifest = @import("build.zig.zon");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip binary");

    const zlua_dep = b.dependency("zlua", .{
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
