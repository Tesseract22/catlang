const std = @import("std");
const NASM_FLAG = .{"-f", "elf64", "-g", "-F dwarf"};
const LD_FLAG = .{"-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc"};
// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
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
    
    var lang_dir = std.fs.cwd().openDir("lang", .{.iterate = true}) catch |e| {
        std.log.err("Cannot open `lang` folder: {}", .{e});
        unreachable;
    };
    var it = lang_dir.iterate();
    while (it.next() catch unreachable) |entry| {
        const compile_cmd = b.addRunArtifact(exe);
        compile_cmd.step.dependOn(b.getInstallStep());
        compile_cmd.addArg("-c");
        compile_cmd.addArg(std.fmt.allocPrint(b.allocator, "lang/{s}", .{entry.name}) catch unreachable);
        compile_cmd.addArg("-o");
        compile_cmd.addArg(std.fmt.allocPrint(b.allocator, "cache/{s}.asm", .{entry.name}) catch unreachable); // purposefully leaked
        compile_step.dependOn(&compile_cmd.step);
    }

    const test_step = b.step("test", "build test.asm");
    const test_nasm_cmd = b.addSystemCommand(&.{"nasm"});   
    test_nasm_cmd.addArgs(&NASM_FLAG);
    test_nasm_cmd.addArg("cache/test.asm");
    test_nasm_cmd.addArg("-o");
    test_nasm_cmd.addArg("cache/test.o");
    test_step.dependOn(&test_nasm_cmd.step);

    const test_ld_cmd = b.addSystemCommand(&.{"ld"});
    test_ld_cmd.addArgs(&LD_FLAG);
    test_ld_cmd.addArg("-lc");
    test_ld_cmd.addArg("cache/test.o");
    test_ld_cmd.addArg("-o");
    test_ld_cmd.addArg("out/test");
    test_step.dependOn(&test_ld_cmd.step);

    // compile_step.dependOn(other: *Step)
}
