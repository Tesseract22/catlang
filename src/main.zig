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
pub fn main() !void {
    log.init();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    defer bw.flush() catch unreachable;
    const stdout = bw.writer();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
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
    const target_os = builtin.os.tag;
    const curr_os = builtin.os.tag;
    const tmp_dir_path = switch (curr_os) {
        .linux => "/tmp",
        .windows => "%Temp%",
        else => unreachable,
    };
    var tmp_dir = std.fs.openDirAbsoluteZ(tmp_dir_path, .{}) catch unreachable;
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
                try stdout.print("{}: {}\n", .{i, tk.tag});
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
            const asm_writer = asm_file.writer();

            const cirs = Cir.generate(ast.?, &sema.?, alloc, arena.allocator());
            defer {
                for (cirs) |cir|
                    cir.deinit(alloc);
                alloc.free(cirs);
            }
            const arch = Arch.resolve(builtin.target);
            try arch.compileAll(cirs, asm_writer, alloc, target_os);

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
            const ld_flag = (.{"ld"} ++
                .{ try std.fmt.allocPrint(path_alloc, "{s}/{s}.o", .{tmp_dir_path, name}), "-o", try std.fmt.allocPrint(path_alloc, "{s}", .{out_path}) }) ++
                LD_FLAG ++ .{libc};
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
