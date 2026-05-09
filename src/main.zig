const std = @import("std");
const Io = std.Io;
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
const LD_FLAG = .{ "-L", "zig-out/lib", "-lm" };
const UNIX_LIBC = "-lc";
const WINDOWS_LIBC = "-lmsvcrt";

const Mode = enum(u8) {
    lex,
    parse,
    type,
    codegen,
    compile,
};

const LinkerError = error{
    DynamicLinker,
};

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

fn exitOnErr(e: anyerror) noreturn {
    std.process.exit(@intFromEnum(ErrorReturnCode.fromError(e)));
}

fn exit(code: ErrorReturnCode) noreturn {
    std.process.exit(@intFromEnum(code));
}

fn errOut(e: anyerror, comptime fmt: []const u8, args: anytype) noreturn {
    std.process.fatal(fmt ++ ": {}", args ++ .{e});
}

fn unexpected(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    exit(.unexpected);
}

fn childSucceed(term: std.process.Child.WaitError!std.process.Child.Term) bool {
    switch (term catch return false) {
        .exited => |code| return code == 0,
        else => return false,
    }
}

pub fn findDynamicLinker(io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "/lib/ld64.so.1",
        "/lib64/ld-linux-x86-64.so.2",
        "/lib/ld-linux-aarch64.so.1",
    };
    var res: ?[]const u8 = null;
    for (candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        res = candidate;
    }
    return res;
}

const Opt = struct {
    pub var input_path: []const u8 = undefined;
    pub var output_path: []const u8 = undefined;
    pub var tmp_dir_path: ?[]const u8 = undefined;
    pub var mode: Mode = undefined;
    pub var arch_os_abi: []const u8 = undefined;
};

const Target = std.Target;

pub fn parseTargetQuery(options: std.Target.Query.ParseOptions) error{ParseFailed}!std.Target.Query {
    assert(options.diagnostics == null);
    var diags: Target.Query.ParseOptions.Diagnostics = .{};
    var opts_copy = options;
    opts_copy.diagnostics = &diags;
    return std.Target.Query.parse(opts_copy) catch |err| switch (err) {
        error.UnknownCpuModel => {
            log.err("unknown CPU: '{s}'", .{diags.cpu_name.?});
            log.note("available CPUs for architecture '{s}':", .{@tagName(diags.arch.?)});
            for (diags.arch.?.allCpuModels()) |cpu| {
                log.note(" {s}", .{cpu.name});
            }
            return error.ParseFailed;
        },
        error.UnknownCpuFeature => {
            log.err("unknown CPU feature: '{s}'", .{
                diags.unknown_feature_name.?,
            });
            log.note("available CPU features for architecture '{s}':", .{@tagName(diags.arch.?)});
            for (diags.arch.?.allFeaturesList()) |feature| {
                log.note(" {s}: {s}", .{ feature.name, feature.description });
            }
            return error.ParseFailed;
        },
        error.UnknownOperatingSystem => {
            log.err("unknown OS: '{s}'", .{diags.os_name.?});
            log.note("available operating systems:", .{});
            inline for (std.meta.fields(Target.Os.Tag)) |field| {
                log.note(" {s}", .{field.name});
            }
            return error.ParseFailed;
        },
        else => |e| {
            log.err("unable to parse target '{s}': {s}", .{
                options.arch_os_abi, @errorName(e),
            });
            return error.ParseFailed;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    log.init(io);
    errdefer |e| {
        if (log.enable_debug) {
            const err_trace = @errorReturnTrace();
            if (err_trace) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
        }
        exitOnErr(e);
    }
    var debug_gpa = std.heap.DebugAllocator(.{.stack_trace_frames = 15}).init;
    // defer _ = debug_gpa.deinit();
    var gpa = debug_gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const stdout_file = Io.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    const stdout_writer = stdout_file.writer(io, &stdout_buf);
    var stdout = stdout_writer.interface;
    // defer stdout.flush() catch unreachable;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    var args_parser = cli.ArgParser{};
    args_parser.init(gpa, args.next().?, "\nCatlang Compiler");
    defer args_parser.deinit();
    _ = args_parser
        .add_opt(bool, &log.enable_debug, .{ .just = &false }, .{ .prefix = "--verbose" }, "", "enable verbose logging")
        .add_opt(?[]const u8, &Opt.tmp_dir_path, .{ .just = &null }, .{ .prefix = "--tmp-dir" }, "<tmp-dir>", "directory to save temporary file")
        .add_opt(Mode, &Opt.mode, .{ .just = &.compile }, .{ .prefix = "--mode" }, "<mode>", "")
        .add_opt([]const u8, &Opt.input_path, .none, .positional, "<input>", "input .cat file")
        .add_opt([]const u8, &Opt.arch_os_abi, .{ .just = &"native" }, .{ .prefix = "--target" }, "<target>", "target triple")
        .add_opt([]const u8, &Opt.output_path, .none, .{ .prefix = "-o" }, "<output>", "output exectuable");

    try args_parser.parse(&args);
    const target_query = try parseTargetQuery(.{
        .arch_os_abi = Opt.arch_os_abi,
    });
    const target = std.zig.system.resolveTargetQuery(io, target_query) catch |e| {
        log.err("cannot resolve target: {}", .{e});
        exitOnErr(e);
    };

    // const lex_comd = args_parser.sub_command("lex", "lex")
    //     .add_opt([]const u8, &Opt.input_path, .none, .positional, "<input>", "input .cat file");

    const cwd = Io.Dir.cwd();
    const src_f = cwd.openFile(io, Opt.input_path, .{}) catch |e| {
        log.err("cannot open input file `{s}`: {}", .{ Opt.input_path, e });
        exitOnErr(e);
    };
    var src_buf: [256]u8 = undefined;
    var src_reader = src_f.reader(io, &src_buf);
    const src = try src_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(src);

    const is_native = builtin.target.os.tag == target.os.tag and builtin.target.cpu.arch == target.cpu.arch and builtin.target.abi == target.abi;

    // const target_os = target.os.tag;
    const curr_os = builtin.os.tag;

    // var tmp_dir_path_buf: [512]u8 = undefined;
    const tmp_dir_path = Opt.tmp_dir_path orelse switch (curr_os) {
        .linux => "/tmp",
        .windows => {
            @panic("TODO");
            // const windows_h = @cImport({
            //     @cInclude("windows.h");
            // });
            // const path_len = windows_h.GetTempPath2A(tmp_dir_path_buf.len, &tmp_dir_path_buf);
            // log.debug("path: {s}", .{ tmp_dir_path_buf[0..path_len] });
            // break :blk tmp_dir_path_buf[0..path_len];
        },
        else => unreachable,
    };
    log.debug("tmp dir: {s}", .{tmp_dir_path});
    var tmp_dir = cwd.openDir(io, tmp_dir_path, .{}) catch unreachable;
    defer tmp_dir.close(io);

    Lexer.string_pool = InternPool.StringInternPool.init(gpa);
    TypePool.type_pool = TypePool.TypeIntern.init(gpa);

    defer Lexer.string_pool.deinit();
    defer TypePool.type_pool.deinit();

    const name = std.fs.path.basename(Opt.output_path);
    var sources: ?Ast.Sources = null;
    var sema: ?TypeCheck.Sema = null;
    defer {
        if (sources) |*a| {
            a.deinit(gpa);
        }
        if (sema) |*s| {
            gpa.free(s.types);
            gpa.free(s.expr_types);
            s.use_defs.deinit();
            s.top_scope.deinit(gpa);
        }
    }

    var cmd_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer cmd_arena_state.deinit();
    const cmd_arena = cmd_arena_state.allocator();

    const stage = Mode.lex;
    log.debug("mode: {}", .{Opt.mode});
    stage: switch (stage) {
        .lex => {
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.lex)) {
                continue :stage .parse;
            }
            @panic("TODO");
            // var i: usize = 0;
            // while (true) : (i += 1) {
            //     const tk = try lexer.next();
            //     try stdout.print("{}: {f}\n", .{ i, tk.tag });
            //     if (tk.tag == .eof) break;
            // }
        },
        .parse => {
            log.debug("parsing", .{});
            sources = try Ast.parse(Opt.input_path, io, gpa, arena.allocator());
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.parse)) {
                continue :stage .type;
            }
            try stdout.print("number of asts: {}\n", .{ sources.?.asts.count() });
            try stdout.print("definations: {}\nexpressios: {}\nstatements: {}\n", .{ sources.?.defs.len, sources.?.exprs.len, sources.?.stats.len });
        },
        .type => {
            log.debug("typechecking", .{});
            sema = try TypeCheck.typeCheck(&sources.?, gpa, arena.allocator());
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.type)) {
                continue :stage .codegen;
            }
        },
        .codegen => {
            var asm_file = try tmp_dir.createFile(io, try std.fmt.allocPrint(arena.allocator(), "{s}.s", .{name}), .{});
            defer asm_file.close(io);
            var asm_buf: [512]u8 = undefined;
            var asm_writer = asm_file.writer(io, &asm_buf);

            const cirs = Cir.generate(&sema.?, gpa, arena.allocator());
            defer {
                for (cirs) |cir|
                    cir.deinit(gpa);
                gpa.free(cirs);
            }
            log.debug("codegne for {}", .{target});
            const arch = try Arch.resolve(target);
            try arch.compileAll(cirs, &asm_writer.interface, gpa, target.os.tag);
            if (@intFromEnum(Opt.mode) > @intFromEnum(Mode.type)) {
                continue :stage .compile;
            }
        },
        .compile => {
            // assembly =(nasm)>  reloctable object =(ld)> executable
            log.debug("compiling `{s}` to `{s}`", .{ Opt.input_path, Opt.output_path });
            log.debug("name: {s}", .{name});

            var cmd = std.ArrayList([]const u8).initCapacity(cmd_arena, 10) catch @panic("OOM");
            const asm_file = fmtAlloc(arena.allocator(), "{s}/{s}.s", .{ tmp_dir_path, name });
            const obj_file = fmtAlloc(arena.allocator(), "{s}/{s}.o", .{ tmp_dir_path, name });

            if (!is_native) {
                try cmd.appendSlice(gpa, &.{ "zig", "build-obj", "-target", Opt.arch_os_abi });
                try cmd.append(gpa, asm_file);
                try cmd.append(gpa, fmtAlloc(cmd_arena, "-femit-bin={s}", .{  obj_file }));
            } else {
                try cmd.append(gpa, "as");
                try cmd.append(gpa, "-g");
                try cmd.append(gpa, asm_file);
                try cmd.append(gpa, "-o");
                try cmd.append(gpa, obj_file);
            }

            var assemebler = std.process.spawn(io, .{ .argv = cmd.items }) catch |e|
                errOut(e, "cannot invoke assembler `as`: {}", .{e});

            if (!childSucceed(assemebler.wait(io)))
                unexpected("an error occur during assembling {s}/{s}.s", .{ tmp_dir_path, name });
            log.debug("assembled", .{});
            cmd.clearRetainingCapacity();
            _ = cmd_arena_state.reset(.retain_capacity);

            // const libc = switch (target_os) {
            //     .linux => UNIX_LIBC,
            //     .windows => WINDOWS_LIBC,
            //     else => @panic("target os not supported"),
            // };

            if (target.cpu.arch == .aarch64 and !is_native) {
                try cmd.appendSlice(gpa, &.{ "aarch64-linux-gnu-gcc", obj_file, "-nostdlib", "-o", Opt.output_path });
            } else {
                const dynamic_linker = findDynamicLinker(io) orelse
                    errOut(error.DynamicLinker, "cannot find any dynamic linker", .{});
                const ld_flag = (.{"ld"} ++
                    .{ try std.fmt.allocPrint(arena.allocator(), "{s}/{s}.o", .{ tmp_dir_path, name }), "-o", try std.fmt.allocPrint(arena.allocator(), "{s}", .{Opt.output_path}) }) ++ LD_FLAG ++ .{ "--dynamic-linker", dynamic_linker };
                try cmd.appendSlice(gpa, &ld_flag);
            }

            // try cmd.appendSlice(gpa, &.{ "zig", "build-exe", obj_file, "-o", Opt.output_path});

                        // const ld_flag = (.{"ld"} ++
            //     .{ try std.fmt.allocPrint(arena.allocator(), "{s}/{s}.o", .{ tmp_dir_path, name }), "-o", try std.fmt.allocPrint(arena.allocator(), "{s}", .{Opt.output_path}) }) ++ LD_FLAG ++ .{libc} ++ .{ "--dynamic-linker", dynamic_linker };
            // inline for (ld_flag) |flag| {
            //     try stdout.print("{s} ", .{flag});
            // }
            // try stdout.print("\n", .{});
            var ld = std.process.spawn(io, .{ .argv = cmd.items }) catch |e|
                errOut(e, "cannot invoke linker `{s}`", .{ cmd.items[0] });
            if (!childSucceed(ld.wait(io))) {
                unexpected("an error occured during linking {s}/{s}.o", .{ tmp_dir_path, name });
            }
            log.debug("linked", .{});
        },
    }
}

fn resolvePath(gpa: std.mem.Allocator, paths: []const []const u8) []const u8 {
    return std.fs.path.resolve(gpa, paths) catch @panic("OOM");
}

fn fmtAlloc(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch @panic("OOM");
}
