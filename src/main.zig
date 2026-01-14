const std = @import("std"); 
const builtin = @import("builtin");
const assert = std.debug.assert; 
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
    help = 0,
    lex = 1,
    parse = 2,
    type = 3,
    compile = 4,
    pub fn fromString(s: []const u8) CliError!Mode {

        const options = .{
        //.{ "-e", Mode.eval },
        .{ "-h", Mode.help },
        .{ "-l", Mode.lex },
        .{ "-p", Mode.parse },
        .{ "-t", Mode.type },
        .{ "-c", Mode.compile },
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

const LinkerError = error {
    DynamicLinker,
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

pub fn main() !void {
    log.init();
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
    const proc_name = args.next().?;
    _ = proc_name;
    errdefer Mode.usage();

    const mode = Mode.fromString(args.next() orelse {
        return CliError.TooFewArgument;
    }) catch |e| {
        return e;
    };
    const src_path = args.next() orelse return CliError.TooFewArgument;
    const cwd = std.fs.cwd();
    const src_f = try cwd.openFile(src_path, .{});
    const src = try src_f.readToEndAlloc(alloc, MAX_FILE_SIZE);
    defer alloc.free(src);

    const target_os = builtin.os.tag;
    const curr_os = builtin.os.tag;

    var tmp_dir_path_buf: [512]u8 = undefined;
    const tmp_dir_path = switch (curr_os) {
        .linux => "/tmp",
        .windows => blk: {
            const windows_h = @cImport({
                @cInclude("windows.h");
            });
            const path_len = windows_h.GetTempPath2A(tmp_dir_path_buf.len, &tmp_dir_path_buf);
            std.log.debug("path: {s}", .{ tmp_dir_path_buf[0..path_len] });
            break :blk tmp_dir_path_buf[0..path_len];
        },
        else => unreachable,
    };
    var tmp_dir = std.fs.cwd().openDir(tmp_dir_path, .{}) catch unreachable;
    defer tmp_dir.close();


    Lexer.string_pool = InternPool.StringInternPool.init(alloc);
    TypePool.type_pool = TypePool.TypeIntern.init(alloc);
    defer Lexer.string_pool.deinit();
    defer TypePool.type_pool.deinit();
    var lexer = Lexer.init(src, src_path);
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
    std.log.debug("mode: {}", .{mode});
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
                try stdout.print("{}: {f}\n", .{i, tk.tag});
                if (tk.tag == .eof) break;
            }
            
        },
        .parse => {
            std.log.debug("parsing", .{});
            ast = try Ast.parse(&lexer, alloc, arena.allocator());
            if (@intFromEnum(mode) > @intFromEnum(Mode.parse)) {
                continue :stage .type;
            }
            try stdout.print("definations: {}\nexpressios: {}\nstatements: {}\n", .{ast.?.defs.len, ast.?.exprs.len, ast.?.stats.len});
        },
        .type => {
            std.log.debug("typechecking", .{});
            sema = try TypeCheck.typeCheck(&ast.?, alloc, arena.allocator());
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
            var asm_file = try tmp_dir.createFile(try std.fmt.allocPrint(path_alloc, "{s}.s", .{name}), .{});
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
                try std.fmt.allocPrint(path_alloc, "{s}/{s}.s", .{tmp_dir_path, name}),
                "-o",
                try std.fmt.allocPrint(path_alloc, "{s}/{s}.o", .{tmp_dir_path, name}),
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
                return LinkerError.DynamicLinker;
            };
            const ld_flag = (.{"ld"} ++
                .{ 
                    try std.fmt.allocPrint(path_alloc, "{s}/{s}.o", .{tmp_dir_path, name}), 
                    "-o", try std.fmt.allocPrint(path_alloc, "{s}", .{out_path})
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
