const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip binary");

    const lua_dep = b.dependency("lua", .{});
    const lua_lib = b.addLibrary(.{
        .name = "lua",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    lua_lib.root_module.addCSourceFiles(.{
        .root = lua_dep.path("src"),
        .files = lua_src_files,
    });
    lua_lib.root_module.addIncludePath(lua_dep.path("src"));

    const translate_lua = b.addTranslateC(.{
        .root_source_file = b.path("include.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_lua.addIncludePath(lua_dep.path("src"));

    const exe = b.addExecutable(.{
        .name = "packa",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
            .strip = strip,
        }),
    });

    exe.root_module.linkLibrary(lua_lib);
    exe.root_module.addImport("c", translate_lua.createModule());

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

const lua_src_files = &.{
    "lapi.c",
    "lcode.c",
    "lctype.c",
    "ldebug.c",
    "ldo.c",
    "ldump.c",
    "lfunc.c",
    "lgc.c",
    "llex.c",
    "lmem.c",
    "lobject.c",
    "lopcodes.c",
    "lparser.c",
    "lstate.c",
    "lstring.c",
    "ltable.c",
    "ltm.c",
    "lundump.c",
    "lvm.c",
    "lzio.c",
    "lauxlib.c",
    "lbaselib.c",
    "lcorolib.c",
    "ldblib.c",
    "liolib.c",
    "lmathlib.c",
    "loadlib.c",
    "loslib.c",
    "lstrlib.c",
    "ltablib.c",
    "lutf8lib.c",
    "linit.c",
};
