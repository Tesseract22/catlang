const std = @import("std");
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
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lang",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    const compile_step = b.step("compile", "compile the example program with the built compiler");
    const compile_opt = b.option([]const u8, "cat", "specifically choose which file in `lang` to compile");
    var lang_dir = std.fs.cwd().openDir("lang", .{ .iterate = true }) catch |e| {
        std.log.err("Cannot open `lang` folder: {}", .{e});
        unreachable;
    };
    var it = lang_dir.iterate();
    if (compile_opt) |name| {
        const compile_cmd = compile(b, exe, name);
        compile_step.dependOn(&compile_cmd.step);
    } else {
        while (it.next() catch unreachable) |entry| {
            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8, ext, ".cat")) continue;
            const name = entry.name[0 .. entry.name.len - 4];
            const compile_cmd = compile(b, exe, name);
            compile_step.dependOn(&compile_cmd.step);
        }
    }

    const test_step = b.step("test", "build test.s");
    const test_nasm_cmd = b.addSystemCommand(&.{"as"});
    test_nasm_cmd.addFileArg(b.path("cache/test.s"));
    test_nasm_cmd.addArg("-g");
    test_nasm_cmd.addArg("-o");
    const test_obj = test_nasm_cmd.addOutputFileArg("test.o");

    var test_ld_cmd = b.addSystemCommand(&.{"ld"});
    test_ld_cmd.addFileArg(test_obj);
    test_ld_cmd.addArg("-o");
    _ = test_ld_cmd.addArg(b.fmt("out/test", .{}));
    test_ld_cmd.step.dependOn(&test_nasm_cmd.step);

    test_ld_cmd.addArgs(&LD_FLAG);
    test_ld_cmd.addArg("-lc");
    test_ld_cmd.addArg("-lm");
    test_ld_cmd.addArg("-lraylib");

    const test_run_cmd = b.addSystemCommand(&.{b.fmt("out/test", .{})});
    test_run_cmd.step.dependOn(&test_ld_cmd.step);

    test_step.dependOn(&test_run_cmd.step);

    // compile_step.dependOn(other: *Step)
}
