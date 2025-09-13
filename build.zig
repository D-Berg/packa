const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "packa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

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
