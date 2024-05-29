const std = @import("std");
const assert = std.debug.assert;
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Cir = @import("cir.zig");
const Token = Lexer.Token;
const NASM_FLAG = .{ "-f", "elf64", "-g", "-F dwarf" };
const LD_FLAG = .{ "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc" };
fn usage(proc_name: []const u8) void {
    std.debug.print("usage: {s} <src_path>\n", .{proc_name});
}
const Mode = enum {
    eval,
    compile,
    help,
    lex,
    pub fn fromString(s: []const u8) CliError!Mode {
        return if (std.mem.eql(u8, "-e", s)) Mode.eval else if (std.mem.eql(u8, "-c", s)) Mode.compile else if (std.mem.eql(u8, "-h", s)) Mode.help else if (std.mem.eql(u8, "-l", s)) Mode.lex else CliError.InvalidOption;
    }
    pub fn usage() void {
        log.err("Expect option `-c`, `-e`, or `-h`", .{});
    }
};
const CliError = error{
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
    switch (mode) {
        .eval => {
            var ast = try Ast.parse(&lexer, alloc);
            defer ast.deinit(alloc);

            try ast.eval(alloc);
        },
        .lex => {
            while (try lexer.next()) |tk| {
                log.debug("{}", .{tk});
            }
        },
        .compile => {
            var ast = try Ast.parse(&lexer, alloc);
            defer ast.deinit(alloc);
            const out_opt = args.next() orelse return CliError.TooFewArgument;
            if (!std.mem.eql(u8, "-o", out_opt)) {
                return CliError.InvalidOption;
            }
            const out_path = args.next() orelse return CliError.TooFewArgument;
            const name = std.fs.path.basename(out_path);
            log.debug("compiling `{s}` to `{s}`", .{ src_path, out_path });
            log.debug("name: {s}", .{name});

            var path_buf: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&path_buf);
            const path_alloc = fba.allocator();
            var asm_file = try std.fs.cwd().createFile(try std.fmt.allocPrint(path_alloc, "cache/{s}.asm", .{name}), .{});
            defer asm_file.close();
            const asm_writer = asm_file.writer();

            var cir = try Cir.generate(ast, alloc);
            defer cir.deinit(alloc);
            try cir.compile(asm_writer, alloc);

            var nasm = std.process.Child.init(&(.{"as"} ++
                .{
                try std.fmt.allocPrint(path_alloc, "cache/{s}.asm", .{name}),
                "-o",
                try std.fmt.allocPrint(path_alloc, "cache/{s}.o", .{name}),
            }), alloc);
            try nasm.spawn();
            _ = try nasm.wait();
            var ld = std.process.Child.init(&(.{"ld"} ++
                LD_FLAG ++
                .{ try std.fmt.allocPrint(path_alloc, "cache/{s}.o", .{name}), "-o", try std.fmt.allocPrint(path_alloc, "out/{s}", .{name}) }), alloc);
            try ld.spawn();
            _ = try ld.wait();
        },
        .help => @panic("TODO"),
    }
}
