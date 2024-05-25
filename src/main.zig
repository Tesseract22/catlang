const std = @import("std");
const assert = std.debug.assert;
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Cir = @import("cir.zig");
const Token = Lexer.Token;
const NASM_FLAG = .{"-f", "elf64", "-g", "-F dwarf"};
const LD_FLAG = .{"-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc"};
fn usage(proc_name: []const u8) void {
    std.debug.print("usage: {s} <src_path>\n", .{proc_name});
}
const Mode = enum {
    eval,
    compile,
    help,
    pub fn fromString(s: []const u8) CliError!Mode {
        return 
            if (std.mem.eql(u8, "-e", s)) Mode.eval 
            else if (std.mem.eql(u8, "-c", s)) Mode.compile
            else if (std.mem.eql(u8, "-h", s)) Mode.help
            else CliError.InvalidOption;
    }
    pub fn usage() void {
        log.err("Expect option `-c`, `-s`, or `-h`", .{});
    }
};
const CliError = error {
    InvalidOption,
    TooFewArgument,
};
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = std.process.args();
    const proc_name = args.next().?;
    errdefer usage(proc_name);

    const mode = Mode.fromString(args.next() orelse {
        Mode.usage();
        return CliError.TooFewArgument;
    }) catch |e| {
        Mode.usage();
        return e;
    };
    const src_path = args.next() orelse return CliError.TooFewArgument;
    const cwd = std.fs.cwd();
    const src_f = try cwd.openFile(src_path, .{});
    const src = try src_f.readToEndAlloc(alloc, 1000);
    defer alloc.free(src);

    var lexer = Lexer.init(src, src_path);

    // while (try lexer.next()) |tk| {
    //     log.debug("token: {}", .{tk});
    // }
    // lexer = Lexer.init(src, src_path);
    var ast = try Ast.parse(&lexer, alloc);
    defer ast.deinit(alloc);
    switch (mode) {
        .eval => try ast.eval(alloc),
        .compile => {
            const out_opt = args.next() orelse return CliError.TooFewArgument;
            if (!std.mem.eql(u8, "-o", out_opt)) {
                return CliError.InvalidOption;
            }
            const out_path = args.next() orelse return CliError.TooFewArgument;
            log.debug("compiling `{s}` to `{s}`", .{src_path, out_path});
            var asm_file = try std.fs.cwd().createFile("cache/main.asm", .{});
            defer asm_file.close();
            const asm_writer = asm_file.writer();
            var cir = try Cir.generate(ast, alloc);
            defer cir.deinit(alloc);
            for (cir.insts, 0..) |inst, i| {
                log.debug("{} {}", .{i,inst});
            }
            try cir.compile(asm_writer, alloc);

            var nasm = std.process.Child.init(&(.{"nasm"} ++ NASM_FLAG ++ .{"cache/main.asm", "-o", "cache/main.o"}), alloc);
            try nasm.spawn();
            _ = try nasm.wait();
            var ld = std.process.Child.init(&(.{"ld"} ++ LD_FLAG ++ .{"cache/main.o", "-o", "out/main"}), alloc);
            try ld.spawn();
            _ = try ld.wait();
        
        },
        .help => @panic("TODO"),
    }
}
