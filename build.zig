const std = @import("std");
const Io = std.Io;
const NASM_FLAG = .{ "-f", "elf64", "-g", "-F dwarf" };
const LD_FLAG = .{ "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc" };

pub fn compile(b: *std.Build, exe: *std.Build.Step.Compile, name: []const u8) *std.Build.Step.Run {
    const compile_cmd = b.addRunArtifact(exe);
    compile_cmd.step.dependOn(b.getInstallStep());
    compile_cmd.addArg("-c");
    compile_cmd.addFileArg(b.path(b.fmt("lang/{s}.cat", .{name})));
    compile_cmd.addArg("-o");
    compile_cmd.addArg(b.fmt("out/{s}", .{name}));
    return compile_cmd;
}
pub fn build(b: *std.Build) void {
    // const io = b.graph.io;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const catc = b.addExecutable(.{
        .name = "catc",
        .root_module = b.addModule("main", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .link_libc = true,
        }),
    });
    b.installArtifact(catc);
    const install_std = b.addInstallDirectory(.{
        .source_dir = b.path("src/lang/std"),
        .install_dir = .lib,
        .install_subdir = "std",
    });
    b.default_step.dependOn(&install_std.step);

    const test_step = b.step("test", "invoke the integrated test system");
    const install_test_step = b.step("install-test", "intall the test-system");

    const single_thread = b.option(bool, "single-thread", "");
    const test_module = b.addModule("test", .{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = single_thread,
    });
    const test_system = b.addExecutable(.{
        .name = "test",
        .root_module = test_module,
    });
    // const record_opt = b.option(bool, "record", "tell the test system to record the output") orelse false;

    const detail = b.option(bool, "detail", "") orelse false;
    const run_test = b.addRunArtifact(test_system);

    run_test.addArtifactArg(catc);
    run_test.addDirectoryArg(b.path("tests"));
    run_test.addArg("--std"); run_test.addFileArg(b.path("src/lang/std/std.cat"));
    if (detail) run_test.addArg("--detail");
    const test_output = run_test.addOutputDirectoryArg("output");

    const install_test_output = b.addInstallDirectory(.{
        .source_dir = test_output,
        .install_dir = .bin,
        .install_subdir = "tests",
    });
    run_test.has_side_effects = true;
    // if (record_opt) run_test.addArg("--record");

    run_test.step.dependOn(&catc.step);
    install_test_output.step.dependOn(&run_test.step);
    test_step.dependOn(&install_test_output.step);
    test_step.dependOn(&run_test.step);

    const install_test = b.addInstallArtifact(test_system, .{});
    install_test_step.dependOn(&install_test.step);
}
