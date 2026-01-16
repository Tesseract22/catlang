const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert; 

const cli = @import("cli.zig");
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const Cir = @import("cir.zig");
const TypeCheck = @import("typecheck.zig");
const InternPool = @import("intern_pool.zig");
const TypePool = @import("type.zig");
const Arch = @import("arch.zig");
const Token = Lexer.Token;

const MAX_FILE_SIZE = 2 << 20;

const NASM_FLAG = .{ "-f", "elf64", "-g", "-F dwarf" };
const LD_FLAG = .{  "-L", "zig-out/lib", "-lm" };
const UNIX_LIBC = "-lc";
const WINDOWS_LIBC = "-lmsvcrt";
//const LD_FLAG = .{ "-dynamic-linker", "/lib64/ld-linux-x86-64.so.2", "-lc", "-lm", "-z", "noexecstack" };

const Mode = enum(u8) {
    lex,
    parse,
    type,
    compile,
    
    pub fn usage() void {
        log.err("Expect option `-c`, `-e`, `-l`, `-t` or `-h`", .{});
    }
};

const LinkerError = error {
    DynamicLinker,
};

pub fn exit_or_dump_trace(e: anyerror) noreturn {
    if (!log.enable_debug) std.process.exit(@intFromEnum(ErrorReturnCode.fromError(e)));
    std.log.err("{}", .{e});
    unreachable;
}

pub const ErrorReturnCode = enum(u8) {
    success = 0,
    cli,
    lex,
    parse,
    sema,
    eval,
    mem_leak,
    unexpected,

    pub fn fromError(e: anyerror) ErrorReturnCode {
        if (isErrorFromSet(cli.Error, e)) return .cli;
        if (isErrorFromSet(Lexer.Error, e)) return .lex;
        if (isErrorFromSet(Ast.Error, e)) return .parse;
        if (isErrorFromSet(TypeCheck.Error, e)) return .sema;
        return .unexpected;
    }

    pub fn isErrorFromSet(comptime T: type, e: anyerror) bool {
        const err_info = @typeInfo(T).error_set.?;
        return inline for (err_info) |err| {
            if (@field(T, err.name) == e) break true;
        } else false;
    }
};

pub fn findDynamicLinker() ?[]const u8 {
    const candidates = [_][]const u8 {
        "/lib/ld64.so.1",
        "/lib64/ld-linux-x86-64.so.2",
        "/lib/ld-linux-aarch64.so.1",
    };
    var res: ?[]const u8 = null;
    for (candidates) |candidate| {
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        res = candidate;
    }
    return res;
}

const Opt = struct {
    pub var input_path: []const u8 = undefined;
    pub var output_path: []const u8 = undefined;
    pub var tmp_dir_path: ?[]const u8 = undefined;
    pub var mode: Mode = undefined;
};

pub fn main() !void {
    log.init();
    errdefer |e| {
        if (log.enable_debug)
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            };
        std.log.err("{}", .{e});
        std.process.exit(@intFromEnum(ErrorReturnCode.fromError(e)));
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    const stdout_writer = stdout_file.writer(&stdout_buf);
    var stdout = stdout_writer.interface;
    // defer stdout.flush() catch unreachable;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    var args_parser = cli.ArgParser {};
    args_parser.init(alloc, args.next().?, "\nCatlang Compiler");
    _ = args_parser
        .add_opt(bool, &log.enable_debug, .{ .just = &false }, .{ .prefix = "--verbose" }, "", "enable verbose logging")
        .add_opt(?[]const u8, &Opt.tmp_dir_path, .{ .just = &null }, .{ .prefix = "--tmp-dir" }, "<tmp-dir>", "directory to save temporary file")
        .add_opt(Mode, &Opt.mode, .{ .just = &.compile }, .{ .prefix = "--mode"}, "<mode>", "")
        .add_opt([]const u8, &Opt.input_path, .none, .positional, "<input>", "input .cat file")
        .add_opt([]const u8, &Opt.output_path, .none, .{ .prefix = "-o" }, "<output>", "output exectuable");

    try args_parser.parse(&args);
    // const lex_comd = args_parser.sub_command("lex", "lex")
    //     .add_opt([]const u8, &Opt.input_path, .none, .positional, "<input>", "input .cat file");

    const src_f = try std.fs.cwd().openFile(Opt.input_path, .{});
    const src = try src_f.readToEndAlloc(alloc, MAX_FILE_SIZE);
    defer alloc.free(src);

    const target_os = builtin.os.tag;
    const curr_os = builtin.os.tag;

    var tmp_dir_path_buf: [512]u8 = undefined;
    const tmp_dir_path = Opt.tmp_dir_path orelse switch (curr_os) {
        .linux => "/tmp",
        .windows => blk: {
            const windows_h = @cImport({
                @cInclude("windows.h");
            });
            const path_len = windows_h.GetTempPath2A(tmp_dir_path_buf.len, &tmp_dir_path_buf);
            log.debug("path: {s}", .{ tmp_dir_path_buf[0..path_len] });
            break :blk tmp_dir_path_buf[0..path_len];
        },
        else => unreachable,
    };
    log.debug("tmp dir: {s}", .{ tmp_dir_path });
    var tmp_dir = std.fs.cwd().openDir(tmp_dir_path, .{}) catch unreachable;
    defer tmp_dir.close();

    Lexer.string_pool = InternPool.StringInternPool.init(alloc);
    TypePool.type_pool = TypePool.TypeIntern.init(alloc);
    defer Lexer.string_pool.deinit();
    defer TypePool.type_pool.deinit();
    var lexer = Lexer.init(src, Opt.input_path);
    var ast: ?Ast = null;
    var sema: ?TypeCheck.Sema = null;
    defer {
        if (ast) |*a| a.deinit(alloc);
        if (sema) |*s| {
            alloc.free(s.types);
            alloc.free(s.expr_types);
            s.use_defs.deinit();
            s.top_scope.deinit();
        }
    }

    const stage = Mode.lex;
    log.debug("mode: {}", .{ Opt.mode });
    stage: switch (stage) {
        .lex => {
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.lex)) {
                continue :stage .parse;
            }
            var i: usize = 0;
            while (true): (i += 1) {
                const tk = try lexer.next();
                try stdout.print("{}: {f}\n", .{i, tk.tag});
                if (tk.tag == .eof) break;
            }
            
        },
        .parse => {
            log.debug("parsing", .{});
            ast = try Ast.parse(&lexer, alloc, arena.allocator());
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.parse)) {
                continue :stage .type;
            }
            try stdout.print("definations: {}\nexpressios: {}\nstatements: {}\n", .{ast.?.defs.len, ast.?.exprs.len, ast.?.stats.len});
        },
        .type => {
            log.debug("typechecking", .{});
            sema = try TypeCheck.typeCheck(&ast.?, alloc, arena.allocator());
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.type)) {
                continue :stage .compile;
            }
        },
        .compile => {
            const name = std.fs.path.basename(Opt.output_path);
            log.debug("compiling `{s}` to `{s}`", .{ Opt.input_path, Opt.output_path });
            log.debug("name: {s}", .{name});

            var asm_file = try tmp_dir.createFile(try std.fmt.allocPrint(arena.allocator(), "{s}.s", .{name}), .{});
            defer asm_file.close();
            var asm_buf: [512]u8 = undefined;
            var asm_writer = asm_file.writer(&asm_buf);

            const cirs = Cir.generate(ast.?, &sema.?, alloc, arena.allocator());
            defer {
                for (cirs) |cir|
                    cir.deinit(alloc);
                alloc.free(cirs);
            }
            const arch = Arch.resolve(builtin.target);
            try arch.compileAll(cirs, &asm_writer.interface, alloc, target_os);

            var nasm = std.process.Child.init(&(.{"as"} ++
                .{
                try std.fmt.allocPrint(arena.allocator(), "{s}/{s}.s", .{tmp_dir_path, name}),
                "-o",
                try std.fmt.allocPrint(arena.allocator(), "{s}/{s}.o", .{tmp_dir_path, name}),
            }), alloc);
            try nasm.spawn();
            _ = try nasm.wait();
            const libc = switch (target_os) {
                .linux => UNIX_LIBC,
                .windows => WINDOWS_LIBC,
                else => @panic("target os not supported"),
            };

            const dynamic_linker = findDynamicLinker() orelse {
                log.err("cannot find any dynamic linker", .{});
                return error.DynamicLinker;
            };
            const ld_flag = (.{"ld"} ++
                .{ 
                    try std.fmt.allocPrint(arena.allocator(), "{s}/{s}.o", .{tmp_dir_path, name}), 
                    "-o", try std.fmt.allocPrint(arena.allocator(), "{s}", .{Opt.output_path})
                })
                ++ LD_FLAG
                ++ .{libc}
                ++ .{"--dynamic-linker", dynamic_linker };
            inline for (ld_flag) |flag| {
                try stdout.print("{s} ", .{flag});
            }
            try stdout.print("\n", .{});
            var ld = std.process.Child.init(&ld_flag , alloc);
            try ld.spawn();
            _ = try ld.wait();
        },
    }
}
