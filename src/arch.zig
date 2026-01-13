const std = @import("std");
const Cir = @import("cir.zig");
const x86_64 = @import("arch/x86-64.zig");
const arm64 = @import("arch/arm64.zig");
const log = @import("log.zig");
const Self = @This();
pub const CompileError = std.ArrayList(u8).Writer.Error || std.Io.Writer.Error;
compileAll: *const fn (cirs: []Cir, file: *std.Io.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) CompileError!void,
pub fn resolve(target: std.Target) Self {
    return .{.compileAll = switch (target.cpu.arch) {
        .x86_64 => x86_64.compileAll,
        .aarch64 => arm64.compileAll,
        else => {
            log.err("CPU Arch `{}` is not supported", .{target.cpu.arch});
            @panic("Unsupported CPU");
        },
    }};
}
