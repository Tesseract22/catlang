const std = @import("std");
const assert = std.debug.assert;
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Cir = @import("cir.zig");
const TypeCheck = @import("typecheck.zig");
const Token = Lexer.Token;

const MAX_FILE_SIZE = 2 << 20;

const NASM_FLAG = .{ "-f", "elf64", "-g", "-F dwarf" };
const LD_FLAG = .{ "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc" };




const Mode = enum(u8) {
    help = 0,
    lex = 1,
    type = 2,
    parse = 3,
    compile = 4,
    pub fn fromString(s: []const u8) CliError!Mode {

        const options = .{
        //.{ "-e", Mode.eval },
        .{ "-c", Mode.compile },
        .{ "-h", Mode.help },
        .{ "-p", Mode.parse },
        .{ "-l", Mode.lex },
        .{ "-t", Mode.type},
        // .{"print", TokenData.print},
    };
    return inline for (options) |k| {
        if (std.mem.eql(u8, k[0], s)) break k[1];
        } else CliError.InvalidOption;
    }
    pub fn usage() void {
        log.err("Expect option `-c`, `-e`, `-l`, `-t` or `-h`", .{});
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

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    defer bw.flush() catch unreachable;
    const stdout = bw.writer();

    var args = std.process.args();
    const proc_name = args.next().?;
    _ = proc_name;
    errdefer Mode.usage();

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
    const src = try src_f.readToEndAlloc(alloc, MAX_FILE_SIZE);
    defer alloc.free(src);


    var lexer = Lexer.init(src, src_path);
    var ast: ?Ast = null;
    defer if (ast) |*a| a.deinit(alloc);

    const stage = Mode.lex;
    stage: switch (stage) {
        .help => {
            Mode.usage();
        },
        .lex => {
            if (@intFromEnum(mode) > @intFromEnum(Mode.lex)) {
                continue :stage .parse;
            }
            var i: usize = 0;
            while (true): (i += 1) {
                const tk = lexer.next() catch break;
                try stdout.print("{}: {s}\n", .{i, @tagName(tk.data)});
                if (tk.data == .eof) break;
            }
            
        },
        .parse => {
            ast = try Ast.parse(&lexer, alloc, arena.allocator());
            if (@intFromEnum(mode) > @intFromEnum(Mode.parse)) {
                continue :stage .type;
            }
            try stdout.print("definations: {}\nexpressios: {}\nstatements: {}\n", .{ast.?.defs.len, ast.?.exprs.len, ast.?.stats.len});
        },
        .type => {
            try TypeCheck.typeCheck(&ast.?, alloc, arena.allocator());
            if (@intFromEnum(mode) > @intFromEnum(Mode.type)) {
                continue :stage .compile;
            }
        },
        .compile => {
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
            var asm_file = try std.fs.cwd().createFile(try std.fmt.allocPrint(path_alloc, "cache/{s}.s", .{name}), .{});
            defer asm_file.close();
            const asm_writer = asm_file.writer();

            var cir = Cir.generate(ast.?, alloc, arena.allocator());
            defer cir.deinit(alloc);
            try cir.compile(asm_writer, alloc);

            var nasm = std.process.Child.init(&(.{"as"} ++
                .{
                try std.fmt.allocPrint(path_alloc, "cache/{s}.s", .{name}),
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
    }
}
