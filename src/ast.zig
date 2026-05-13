const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const Type = @import("type.zig");
const Symbol = Lexer.Symbol;
const LexerError = Lexer.Error;
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;
const Cir = @import("cir.zig");

pub const Lit = union(enum) {
    string: Symbol,
    int: isize,
    double: f64,
    float: f32,
    bool: bool,
    pub fn format(value: Lit, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .string => |s| _ = try writer.write(Lexer.string_pool.lookup(s)),
            inline .int, .bool, .double, .float => |x| try writer.print("{}", .{x}),
        }
    }
};
pub const TypeExprIdx = makeID(TypeExpr);
pub const TypeExprData = union(enum) {
    ident: Symbol,
    ptr: struct { el: TypeExprIdx },
    array: struct { size: u64, el: TypeExprIdx },
    tuple: []TypeExprIdx,
    named: []VarBind,
    function: struct { args: []TypeExprIdx, ret: TypeExprIdx },
    subset: Subset,
    
    pub const Subset = struct {
        sub_t: TypeExprIdx,
        fields: []Field,

        pub const Field = struct {
            name: Symbol,
            expr: ExprIdx,
            tk: Token,
        };
    };
};

pub const VarBind = struct {
    type: TypeExprIdx,
    name: Symbol,
    tk: Token,
};

pub const NamedInit = struct {
    expr: ExprIdx,
    name: Symbol,
    tk: Token,
};

pub fn makeID(comptime T: type) type {
    return struct {
        idx: usize,
        comptime {
            _ = T;
        }
    };
}

pub const ExprIdx = makeID(Expr);
pub const StatIdx = makeID(Stat);
pub const DefIdx = makeID(TopDef);
fn nodeFromData(comptime T: type) type {
    return struct {
        data: T,
        tk: Token,
    };
}
pub const Op = enum {
    assign,

    eq,
    lt,
    gt,

    plus,
    minus,

    times,
    div,
    mod,

    as,

    lparen,
    field,

    lbrack,

    not,
    pub fn infixBP(self: Op) ?[2]u8 {
        return switch (self) {
            .assign => .{ 1, 1 },
            .eq, .lt, .gt => .{ 3, 3 },
            .plus, .minus => .{ 5, 6 },
            .times, .div, .mod => .{ 7, 8 },
            .as => .{ 9, 10 },
            else => null,
        };
    }
    pub fn postfixBP(self: Op) ?u8 {
        return switch (self) {
            .field, .lbrack => 19,
            .lparen => 21,
            else => null,
        };
    }
    pub fn prefixBP(self: Op) ?u8 {
        return switch (self) {
            .not => 10,
            else => null,
        };
    }
    pub fn nonAssoc(self: Op) bool {
        return switch (self) {
            .assign, .eq, .lt, .gt => true,
            else => false,
        };
    }
};
pub const ExprData = union(enum) {
    iden: Symbol,
    string: Symbol,
    int: isize,
    bool: bool,
    float: f64,
    paren: ExprIdx,
    addr: ExprIdx,

    bin_op: BinOp,
    as: As,
    not: ExprIdx,
    addr_of: ExprIdx,
    deref: ExprIdx,
    fn_app: FnApp,
    array: []ExprIdx,
    tuple: []ExprIdx,
    named_tuple: []NamedInit,
    array_access: ArrayAccess,
    field: FieldAccess,
    pub const FieldAccess = struct {
        lhs: ExprIdx,
        rhs: Symbol,
    };
    pub const ArrayAccess = struct {
        lhs: ExprIdx,
        rhs: ExprIdx,
    };
    pub const FnApp = struct {
        func: ExprIdx,
        args: []const ExprIdx,
    };
    pub const BinOp = struct {
        lhs: ExprIdx,
        rhs: ExprIdx,
        op: Op,
    };
    pub const As = struct {
        lhs: ExprIdx,
        rhs: TypeExprIdx,
    };
};
pub const StatData = union(enum) {
    anon: ExprIdx,
    var_decl: VarDecl,
    @"if": If,
    loop: Loop,
    ret: ExprIdx,
    assign: Assign,

    pub const Loop = struct {
        cond: ExprIdx,
        body: []StatIdx,
    };

    pub const If = struct {
        cond: ExprIdx,
        body: []StatIdx,
        else_body: Else,
    };
    pub const Else = union(enum) {
        stats: []StatIdx,
        else_if: StatIdx,
        none,
    };
    pub const VarDecl = struct {
        name: Symbol,
        te: ?TypeExprIdx,
        expr: ?ExprIdx,
        t: Type.Type,
        i: Cir.Index,
    };
    pub const Assign = struct {
        left_value: ExprIdx, // has to be left value, ensures during not here but during typecheck
        expr: ExprIdx,
    };
};
pub const TopDefData = union(enum) {
    import: Import,
    proc: ProcDef,
    type: VarBind,
    foreign: Foreign,

    pub const Foreign = struct {
        name: Symbol,
        t: TypeExprIdx,
    };
    pub const ProcDef = struct {
        name: Symbol,
        args: []VarBind,
        args_def_insts: []Cir.Index,
        body: []StatIdx,
        ret: TypeExprIdx,
    };

    pub const Import = struct {
        id: Id,
    };

};
pub const TypeExpr = nodeFromData(TypeExprData);
pub const Expr = nodeFromData(ExprData);
pub const Stat = nodeFromData(StatData);
pub const TopDef = nodeFromData(TopDefData);
pub const Error = error{ UnexpectedToken, EndOfStream, InvalidType } || LexerError || Io.File.OpenError || Io.Dir.AccessError;

lexer: Lexer,
defs: []DefIdx,
//
const Exprs = std.ArrayList(Expr);
const Defs = std.ArrayList(TopDef);
const Stats = std.ArrayList(Stat);
const TypeExprs = std.ArrayList(TypeExpr);
pub const Id = enum(u32) {
    builtin = 0,
    entry = 1,
    invalid = std.math.maxInt(u32),
    _
};
pub const Sources = struct {
    exprs: []Expr,
    defs: []TopDef,
    stats: []Stat,
    types: []TypeExpr,
    asts: Map,
    pub const Map = std.array_hash_map.Auto(Id, *Ast);

    pub fn deinit(self: *Sources, gpa: std.mem.Allocator) void {
        var it = self.asts.iterator();
        while (it.next()) |entry| {
            const ast = entry.value_ptr.*;
            ast.deinit(gpa);
            // gpa.free(ast.lexer.src);
        }
        self.asts.deinit(gpa);
        for (self.defs) |def| {
            switch (def.data) {
                .proc => |proc| {
                    gpa.free(proc.body);
                    gpa.free(proc.args);
                },
                else => {},
            }
        }
        for (self.exprs) |expr| {
            switch (expr.data) {
                .fn_app => |fn_app| gpa.free(fn_app.args),
                .array => |array| gpa.free(array),
                .tuple => |tuple| gpa.free(tuple),
                .named_tuple => |tuple| gpa.free(tuple),

                else => {},
            }
        }
        for (self.stats) |stat| {
            switch (stat.data) {
                .@"if" => |if_stat| {
                    gpa.free(if_stat.body);
                switch (if_stat.else_body) {
                    .stats => |stats| gpa.free(stats),
                    else => {},
                }
            },
            .loop => |loop| {
                gpa.free(loop.body);
            },
            else => {},
        }
    }
        gpa.free(self.exprs);
        gpa.free(self.defs);
        gpa.free(self.stats);
        gpa.free(self.types);

    }
};

const AstGen = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    exprs: Exprs,
    defs: Defs,
    stats: Stats,
    types: TypeExprs,
    asts: Sources.Map,
    module_cache: std.array_hash_map.String(Ast.Id),
    srcs_to_parsed: std.ArrayList(ModulePath),
    io: Io,

    const ModulePath = struct {
        by: ?struct {
            off: u32,
            path: []const u8,
            src: []const u8,
        },
        path: ?[]const u8,
        id: Id,
    };

    pub fn new(self: *AstGen, array: anytype, e: anytype) makeID(@TypeOf(e)) {
        array.append(self.gpa, e) catch @panic("out of memory");
        return makeID(@TypeOf(e)){ .idx = array.items.len - 1 };
    }

    pub var mono_inc_id: Id = @enumFromInt(0);

    pub fn get_id() Id {
        mono_inc_id = @enumFromInt(@intFromEnum(mono_inc_id) + 1);
        return @enumFromInt(@intFromEnum(mono_inc_id) - 1);
    }

};
const Ast = @This();

pub var std_path: []const u8 = "";

pub fn parse(entry_file_path: []const u8, provided_std_path: ?[]const u8, io: Io, gpa: std.mem.Allocator, a: std.mem.Allocator) Error!Sources {
    if (provided_std_path) |path| std_path = path;
    const builtin_id = AstGen.get_id(); assert(builtin_id == .builtin);
    const entry_id = AstGen.get_id(); assert(entry_id == .entry);
    var gen = AstGen {
        .gpa = gpa,
        .exprs = Exprs.empty,
        .defs = Defs.empty,
        .stats = Stats.empty,
        .types = TypeExprs.empty,
        .arena = a,
        .asts = .empty,
        .module_cache = .empty,
        .srcs_to_parsed = std.ArrayList(AstGen.ModulePath).initCapacity(gpa, 3) catch @panic("OOM"),
        .io = io,
    };
    gen.srcs_to_parsed.appendAssumeCapacity(.{ .path = null, .id = builtin_id, .by = null });
    gen.srcs_to_parsed.appendAssumeCapacity(.{ .path = entry_file_path, .id = entry_id, .by = null });
    // TODO: better allocation strat so we can forget about this
    errdefer {
        for (gen.defs.items) |def| {
            switch (def.data) {
                .proc => |proc| {
                    gpa.free(proc.body);
                    gpa.free(proc.args);
                },
                else => {},
            }
        }
        for (gen.exprs.items) |expr| {
            switch (expr.data) {
                .fn_app => |fn_app| gpa.free(fn_app.args),
                else => {},
            }
        }
        gen.exprs.deinit(gpa);
        gen.defs.deinit(gpa);
        gen.stats.deinit(gpa);
        gen.asts.deinit(gpa);
    }
    defer gen.module_cache.deinit(gpa);
    defer gen.srcs_to_parsed.deinit(gpa);

    // TODO: memory leak when error

    while (gen.srcs_to_parsed.pop()) |module_path| {
        log.debug("parsing file: {s}", .{ module_path.path orelse "<builtin>"});
        var lexer = if (module_path.path) |path| lexer: {
            var f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
                log.err("cannot open import file: `{s}`: {}", .{ path, e });
                if (module_path.by) |by| {
                    log.note("{f}: file imported here",
                        .{ Lexer.to_loc_src(by.src, by.path, by.off) });
                    Lexer.print_src_line_off(by.src, by.off);
                }
                return e;
            };
            defer f.close(io);

            var buf: [256]u8 = undefined;
            var reader = f.reader(io, &buf);
            const src = reader.interface.allocRemaining(gen.arena, .unlimited) catch @panic("OOM");
            break :lexer Lexer.init(src, path);
        } else Lexer.init(@embedFile("lang/builtin.cat"), "<builtin>");


        var defs = std.ArrayList(DefIdx).initCapacity(gpa, 3) catch @panic("OOM");
        errdefer defs.deinit(gpa);
        while (try parseTopDef(&lexer, &gen)) |idx| {
            defs.append(gpa, idx) catch @panic("OOM");
        }
        const ast = gen.arena.create(Ast) catch @panic("OOM");
        ast.* = Ast {
            .defs = defs.toOwnedSlice(gpa) catch @panic("OOM"),
            .lexer = lexer,
        };
        gen.asts.putNoClobber(gen.gpa, module_path.id, ast) catch @panic("OOM");
    }
    return Sources {
        .exprs = gen.exprs.toOwnedSlice(gpa) catch @panic("OOM"),
        .defs = gen.defs.toOwnedSlice(gpa) catch @panic("OOM"),
        .stats = gen.stats.toOwnedSlice(gpa) catch @panic("OOM"),
        .types = gen.types.toOwnedSlice(gpa) catch @panic("OOM"),
        .asts = gen.asts,
    };
}
pub fn deinit(ast: *Ast, alloc: std.mem.Allocator) void {
    alloc.free(ast.defs);
}
pub fn expectTokenCrit(lexer: *Lexer, kind: TokenType, before: Token) !Token {
    const tok = lexer.next() catch |e| {
        lexer.report_err(before.off, "Expect {f} after {f}, but encounter {}", .{ kind, before.fmt(lexer), e });
        return Error.EndOfStream;
    };
    if (tok.tag != kind) {
        lexer.report_err(before.off, "Expect {f} after {f}, found {f}", .{ kind, before.fmt(lexer), tok.fmt(lexer) });
        return Error.UnexpectedToken;
    }
    return tok;
}
pub fn expectTokenRewind(lexer: *Lexer, kind: TokenType) !?Token {
    const tok = try lexer.peek();
    if (tok.tag != kind) {
        return null;
    }
    _ = lexer.next() catch unreachable;
    return tok;
}
pub fn parseVarBind(lexer: *Lexer, gen: *AstGen) Error!?VarBind {
    const iden_tk = try expectTokenRewind(lexer, .iden) orelse return null;
    const colon_tk = try expectTokenCrit(lexer, .colon, iden_tk);
    const t = try parseTypeExpr(lexer, gen) orelse {
        lexer.report_err(colon_tk.off, "Expect type expression after `:`", .{});
        return Error.UnexpectedToken;
    };
    return VarBind{ .name = lexer.reIdentifier(iden_tk.off), .type = t, .tk = iden_tk };
}
pub fn parseList(comptime T: type, f: fn (*Lexer, *AstGen) Error!?T, lexer: *Lexer, gen: *AstGen, alloc: std.mem.Allocator) Error![]T {
    var list = std.ArrayList(T).empty;
    defer list.deinit(alloc);
    const first = try f(lexer, gen) orelse return (list.toOwnedSlice(alloc) catch unreachable);
    list.append(alloc, first) catch unreachable;
    while (true) {
        const tk = try lexer.peek();
        switch (tk.tag) {
            .comma => {
                lexer.consume();
                const item = try f(lexer, gen) orelse if (list.items.len == 0) {
                    lexer.report_err(tk.off, "Expect item after {f}", .{tk.fmt(lexer)});
                    return Error.UnexpectedToken;
                } else {
                    break;
                };
                list.append(alloc, item) catch unreachable;
            },
            else => break,
        }
    }
    return list.toOwnedSlice(alloc) catch unreachable;
}

pub fn parseTypeExpr(lexer: *Lexer, gen: *AstGen) Error!?TypeExprIdx {
    const head = try lexer.peek();
    switch (head.tag) {
        .times => {
            lexer.consume();
            const el_t = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(head.off, "Expect element type after '*'", .{});
                return Error.UnexpectedToken;
            };
            return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .ptr = .{ .el = el_t } } });
        },
        .lbrack => {
            lexer.consume();
            const size_tk = try expectTokenCrit(lexer, .int, head);
            const rbrack = try expectTokenCrit(lexer, .rbrack, size_tk);
            const size = lexer.reInt(size_tk.off);
            const el_t = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(rbrack.off, "Expect element type after ']'", .{});
                return Error.UnexpectedToken;
            };
            if (size < 0) {
                lexer.report_err(size_tk.off, "Array length must be non-negative, got {}", .{ size });
                return Error.InvalidNum;
            }
            return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .array = .{ .el = el_t, .size = @intCast(size) } } });
        },
        .lcurly => {
            lexer.consume();
            if ((try lexer.peek()).tag == .dot) {
                const tuple = try parseList(VarBind, parseVarBindField, lexer, gen, gen.arena);
                _ = try expectTokenCrit(lexer, .rcurly, head);
                return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .named = tuple } });
            } else {
                const tuple = try parseList(TypeExprIdx, parseTypeExpr, lexer, gen, gen.arena);
                _ = try expectTokenCrit(lexer, .rcurly, head);
                return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .tuple = tuple } });
            }
        },
        .lparen => {
            lexer.consume();
            const args = try parseList(TypeExprIdx, parseTypeExpr, lexer, gen, gen.arena);
            const rparen = try expectTokenCrit(lexer, .rparen, head);
            const arrow = try expectTokenCrit(lexer, .arrow, rparen);
            const ret = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(arrow.off, "Expect return type after '->'", .{});
                return Error.UnexpectedToken;
            };
            return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .function = .{ .args = args, .ret = ret } } });
        },
        .subset => {
            lexer.consume();
            const sub_t = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(head.off, "Expect type expression after {f}", .{ head.fmt(lexer) });
                return Error.UnexpectedToken;
            };
            const sub_t_tk = gen.types.items[sub_t.idx].tk;
            const lcurly = try expectTokenCrit(lexer, .lcurly, sub_t_tk);
            const fields = try parseList(TypeExprData.Subset.Field, parseSubsetField, lexer, gen, gen.gpa);
            errdefer gen.gpa.free(fields);
            const tk = if (fields.len == 0) lcurly else fields[0].tk;
            _ = try expectTokenCrit(lexer, .rcurly, tk);
            return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .subset = .{ .sub_t = sub_t, .fields = fields } }});
        },
        .iden => {
            lexer.consume();
            return gen.new(&gen.types, TypeExpr{ .tk = head, .data = .{ .ident = lexer.reIdentifier(head.off) } });
        },
        else => return null,
    }
}

pub fn parseSubsetField(lexer: *Lexer, gen: *AstGen) Error!?TypeExprData.Subset.Field {
    const iden = try expectTokenRewind(lexer, .iden) orelse return null;
    const assign = try expectTokenCrit(lexer, .assign, iden);
    const expr = try parseExpr(lexer, gen) orelse {
        lexer.report_err(assign.off, "Expect expression after {f}", .{ assign.fmt(lexer) });
        return Error.UnexpectedToken;
    };
    return .{ .name = lexer.reIdentifier(iden.off), .expr = expr, .tk = iden };
}

pub fn parseVarBindField(lexer: *Lexer, arena: *AstGen) Error!?VarBind {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const bind = try parseVarBind(lexer, arena) orelse {
        lexer.report_err(dot.off, "Expect field decleration after dot", .{});
        return Error.UnexpectedToken;
    };
    return bind;
}

pub fn parseTopDef(lexer: *Lexer, gen: *AstGen) Error!?DefIdx {
    const head = try lexer.peek();
    switch (head.tag) {
        .proc, .@"fn" => {
            lexer.consume();
            const iden_tok = try expectTokenCrit(lexer, .iden, head);
            const lparen_tok = try expectTokenCrit(lexer, .lparen, iden_tok);

            const args_slice = try parseList(VarBind, parseVarBind, lexer, gen, gen.gpa);
            errdefer gen.gpa.free(args_slice);

            const rparen = try expectTokenCrit(lexer, .rparen, lparen_tok);
            const ret_type: TypeExprIdx = if (head.tag == TokenType.@"fn") blk: {
                const colon = try expectTokenCrit(lexer, .colon, rparen);
                const ret_t = try parseTypeExpr(lexer, gen) orelse {
                    lexer.report_err(colon.off, "Expects type expression after colon", .{});
                    return Error.UnexpectedToken;
                };
                break :blk ret_t;
            } else gen.new(&gen.types, TypeExpr { .data = .{ .ident = Lexer.string_pool.intern("void") }, .tk = rparen });
            const stats = try parseBlock(lexer, gen, rparen);
            const args_def_insts = gen.arena.alloc(Cir.Index, args_slice.len) catch @panic("OOM");
            errdefer gen.gpa.free(stats);
            return gen.new(
                &gen.defs,
                TopDef{ .tk = rparen, .data =
                    .{ .proc = TopDefData.ProcDef { .body = stats, .name = lexer.reIdentifier(iden_tok.off), .args = args_slice, .args_def_insts = args_def_insts, .ret = ret_type } } },
            );
        },
        .foreign => {
            lexer.consume();
            const string_tok = try expectTokenCrit(lexer, .string, head);
            const colon = try expectTokenCrit(lexer, .colon, string_tok);
            const t = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(colon.off, "Expect type expression after ':'", .{});
                return Error.UnexpectedToken;
            };
            const semi = try expectTokenCrit(lexer, .semi, colon);
            return gen.new(
                &gen.defs,
                TopDef{ .tk = semi, .data = .{ .foreign = TopDefData.Foreign { .name = lexer.reIdentifier(string_tok.off + 1), .t = t } } },
            );
        },
        .type => {
            lexer.consume();
            const name = try expectTokenCrit(lexer, .iden, head);
            const colon = try expectTokenCrit(lexer, .colon, name);
            const type_expr = try parseTypeExpr(lexer, gen) orelse {
                lexer.report_err(colon.off, "Expects type expression after colon", .{});
                return Error.UnexpectedToken;
            };
            const semi = try expectTokenCrit(lexer, .semi, colon);
            return gen.new(&gen.defs, TopDef {
                .tk = semi,
                .data = .{ .type = .{ .tk = semi, .name = lexer.reIdentifier(name.off), .type = type_expr } },
            });
        },
        .import => {
            lexer.consume();
            const string_tok = try expectTokenCrit(lexer, .string, head);
            _ = try expectTokenCrit(lexer, .semi, string_tok);

            const import_str = lexer.reStringLitStr(string_tok.off);
            const final_path = if (std.mem.eql(u8, "std", import_str)) blk: {
                if (std_path.len == 0) std_path = try findStandardLibrary(gen.io, gen.gpa);
                break :blk std_path;
            } else blk: {
                // resolve the path to the imported file. The path is always assumed to be relative to the current file
                // TODO: have some sort of module system like rust, where each imported file has a unique user-defined module name
                const dir_path = std.fs.path.dirname(lexer.path) orelse ".";
                const rela_path = std.fs.path.resolve(gen.arena, &.{ dir_path, import_str }) catch @panic("OOM");
                break :blk rela_path;
                // break :blk Io.Dir.realPathFile(dir: Dir, io: Io, sub_path: []const u8, out_buffer: []u8)
            };

            const gop = gen.module_cache.getOrPut(gen.gpa, final_path) catch @panic("OOM");
            const id = if (gop.found_existing) gop.value_ptr.* else blk: {
                const id = AstGen.get_id();
                gop.value_ptr.* = id;
                gen.srcs_to_parsed.append(gen.gpa, .{
                    .path = final_path,
                    .id = id,
                    .by = .{
                        .off = head.off,
                        .src = lexer.src,
                        .path = final_path,
                    }
                }) catch @panic("OOM");
                break :blk id;
            };

            // TODO: dependency loop detection
            return gen.new(&gen.defs, TopDef {
                .tk = head,
                .data = .{ .import = .{ .id = id, } }
            });
        },
        .eof => return null,
        else => {
            lexer.report_err(head.off, "Unexpected token `{s}`", .{ @tagName(head.tag) });
            log.note("Expect typedef, foreign declaration, or function declaration", .{});
            return Error.UnexpectedToken;
        },
    }
}
pub fn parseBlock(lexer: *Lexer, gen: *AstGen, before: Token) Error![]StatIdx {
    const lcurly = try expectTokenCrit(lexer, .lcurly, before);
    var stats = std.ArrayList(StatIdx).empty;
    defer stats.deinit(gen.gpa);

    while (try parseStat(lexer, gen)) |stat| {
        stats.append(gen.gpa, stat) catch unreachable;
    }
    _ = try expectTokenCrit(lexer, .rcurly, if (stats.items.len > 1) gen.stats.items[stats.getLast().idx].tk else lcurly);
    return stats.toOwnedSlice(gen.gpa) catch unreachable;
}
pub fn parseOp(tk: Token) ?Op {
    return switch (tk.tag) {
        .plus => .plus,
        .minus => .minus,
        .times => .times,
        .div => .div,
        .mod => .mod,
        .as => .as,
        .eq => .eq,
        .lt => .lt,
        .gt => .gt,
        .lparen => .lparen,
        .dot => .field,
        .assign => .assign,
        .lbrack => .lbrack,
        .not => .not,
        else => null,
    };
}
pub fn parseIf(lexer: *Lexer, gen: *AstGen) Error!?StatIdx {
    const if_tk = try expectTokenRewind(lexer, .@"if") orelse return null;
    const cond_expr = try parseExpr(lexer, gen) orelse {
        lexer.report_err(if_tk.off, "Expect expression after `if`", .{});
        return Error.UnexpectedToken;
    };
    const stats = try parseBlock(lexer, gen, gen.exprs.items[cond_expr.idx].tk);
    errdefer gen.gpa.free(stats);
    const else_stats: StatData.Else = blk: {
        const else_tk = try expectTokenRewind(lexer, .@"else") orelse break :blk .none;
        if (try parseIf(lexer, gen)) |next_if| {
            break :blk .{ .else_if = next_if };
        } else {
            break :blk .{ .stats = try parseBlock(lexer, gen, else_tk) };
        }
    };
    return gen.new(
        &gen.stats,
        Stat{
            .data = .{ .@"if" = .{
                .cond = cond_expr,
                .body = stats,
                .else_body = else_stats,
            } },
            .tk = if_tk,
        },
    );
}
pub fn parseStat(lexer: *Lexer, gen: *AstGen) Error!?StatIdx {
    if (try parseExpr(lexer, gen)) |expr| {
        const semi_tk = try expectTokenCrit(lexer, .semi, gen.exprs.items[expr.idx].tk);
        switch (gen.exprs.items[expr.idx].data) {
            .bin_op => |bin_op| {
                if (bin_op.op == .assign) {
                    return gen.new(&gen.stats, Stat{
                        .data = .{
                            .assign = .{ .expr = bin_op.rhs, .left_value = bin_op.lhs },
                        },
                        .tk = gen.exprs.items[bin_op.lhs.idx].tk,
                    });
                }
            },
            else => {},
        }
        return gen.new(
            &gen.stats,
            Stat{ .data = .{ .anon = expr }, .tk = semi_tk },
        );
    }

    const head = try lexer.peek();
    switch (head.tag) {
        .let => {
            lexer.consume();
            const name_tk = try expectTokenCrit(lexer, .iden, head);
            const colon_tk = try expectTokenCrit(lexer, .colon, name_tk);
            const te = try parseTypeExpr(lexer, gen);
            const eq_tk = try expectTokenRewind(lexer, .assign) orelse {
                const prev_tk = if (te) |te_inner| gen.types.items[te_inner.idx].tk else colon_tk;
                const semi_tk = try expectTokenCrit(lexer, .semi, prev_tk);
                if (te == null) {
                    lexer.report_err(head.off, "At least one of the type or the rhs expression should be specified", .{});
                    return Error.UnexpectedToken;
                }
                return gen.new(
                    &gen.stats,
                    Stat{ .data = .{ .var_decl =.{
                        .expr = null, .name = lexer.reIdentifier(name_tk.off), .te = te,
                        .t = .invalid, .i = .invalid } }, .tk = semi_tk },
                );
            };
            const expr = try parseExpr(lexer, gen) orelse {
                lexer.report_err(eq_tk.off, "Expect expression after `=`", .{});
                return Error.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, gen.exprs.items[expr.idx].tk);
            return gen.new(
                &gen.stats,
                Stat{ .data = .{ .var_decl = .{
                    .expr = expr, .name = lexer.reIdentifier(name_tk.off), .te = te,
                    .t = .invalid, .i = .invalid } }, .tk = semi_tk },
            );
        },
        .ret => {
            lexer.consume();
            const expr = try parseExpr(lexer, gen) orelse {
                lexer.report_err(head.off, "Expect expression after `ret`", .{});
                return Error.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, gen.exprs.items[expr.idx].tk);
            return gen.new(
                &gen.stats,
                Stat{ .data = .{ .ret = expr }, .tk = semi_tk },
            );
        },
        .@"if" => return parseIf(lexer, gen),
        .loop => {
            const loop = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, gen) orelse gen.new(
                &gen.exprs,
                Expr{ .data = .{ .bool = true }, .tk = loop },
            );
            const stats = try parseBlock(lexer, gen, gen.exprs.items[expr.idx].tk);
            errdefer gen.gpa.free(stats);
            return gen.new(&gen.stats, Stat{ .data = .{ .loop = .{ .cond = expr, .body = stats } }, .tk = loop });
        },
        else => return null,
    }
    unreachable;
}
pub fn parseNamedInit(lexer: *Lexer, gen: *AstGen) Error!?NamedInit {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const name = try expectTokenCrit(lexer, .iden, dot);
    const assign = try expectTokenCrit(lexer, .assign, name);
    const expr = try parseExpr(lexer, gen) orelse {
        lexer.report_err(assign.off, "Expect exprssion after `=`", .{});
        return Error.UnexpectedToken;
    };
    return NamedInit{ .expr = expr, .name = lexer.reIdentifier(name.off), .tk = gen.exprs.items[expr.idx].tk };
}
pub fn parseExpr(lexer: *Lexer, gen: *AstGen) Error!?ExprIdx {
    return parseExprClimb(
        lexer,
        gen,
        0,
    );
}
pub fn parseExprClimb(lexer: *Lexer, gen: *AstGen, min_bp: u8) Error!?ExprIdx {
    var lhs = if (try expectTokenRewind(lexer, .lbrack)) |lbrack| blk: {
        const list = try parseList(ExprIdx, parseExpr, lexer, gen, gen.gpa);
        errdefer gen.gpa.free(list);
        const rbrack = try expectTokenCrit(lexer, .rbrack, if (list.len > 1) gen.exprs.items[list[list.len - 1].idx].tk else lbrack);
        break :blk gen.new(&gen.exprs, Expr{ .data = .{ .array = list }, .tk = rbrack });
    } else if (try expectTokenRewind(lexer, .lcurly)) |lt| blk: {
        const head = try lexer.peek();
        if (head.tag == .dot) {
            const list = try parseList(NamedInit, parseNamedInit, lexer, gen, gen.gpa);
            errdefer gen.gpa.free(list);
            const rcurly = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) list[list.len - 1].tk else lt);
            break :blk gen.new(&gen.exprs, Expr{ .data = .{ .named_tuple = list }, .tk = rcurly });
        } else {
            const list = try parseList(ExprIdx, parseExpr, lexer, gen, gen.gpa);
            errdefer gen.gpa.free(list);
            const gt = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) gen.exprs.items[list[list.len - 1].idx].tk else lt);
            break :blk gen.new(&gen.exprs, Expr{ .data = .{ .tuple = list }, .tk = gt });
        }
    } else if (try expectTokenRewind(lexer, .not)) |not| blk: {
        const lbp = parseOp(not).?.prefixBP().?;
        const rhs = try parseExprClimb(lexer, gen, lbp) orelse {
            lexer.report_err(not.off, "Expect rhs after `!`", .{});
            return Error.UnexpectedToken;
        };
        break :blk gen.new(&gen.exprs, Expr{ .data = .{ .not = rhs }, .tk = not });
    } else try parseAtomicExpr(lexer, gen) orelse return null;
    var peek = try lexer.peek();

    while (parseOp(peek)) |op| {
        const expr = if (op.postfixBP()) |lbp| expr_blk: {
            if (lbp < min_bp) break;
            lexer.consume();
            break :expr_blk switch (op) {
                .lparen => {
                    const exprs = parseList(ExprIdx, parseExpr, lexer, gen, gen.gpa) catch |e| {
                        lexer.report_err(peek.off, "Expect list of expression after `{}`", .{ op });
                        return e;
                    };
                    errdefer gen.gpa.free(exprs);
                    const exprs_tk = if (exprs.len > 1) gen.exprs.items[exprs[exprs.len - 1].idx].tk else peek;
                    const rparen = expectTokenCrit(lexer, .rparen, peek) catch |e| {
                        lexer.report_err(exprs_tk.off, "Unclosed parenthesis", .{});
                        lexer.report(peek.off, .note, "Left paren starts here", .{});
                        return e;
                    };
                    break :expr_blk Expr{ .data = .{ .fn_app = .{ .func = lhs, .args = exprs } }, .tk = rparen };
                },
                .field => {
                    const field = try lexer.next();
                    break :expr_blk switch (field.tag) {
                        .ampersand => Expr{ .data = .{ .addr_of = lhs }, .tk = field },
                        .times => Expr{ .data = .{ .deref = lhs }, .tk = field },
                        .iden => Expr{ .data = .{
                            .field = .{ .lhs = lhs, .rhs = lexer.reIdentifier(field.off) },
                        }, .tk = field },
                        else => {
                            lexer.report_err(field.off, "Unexpected token `{f}` after field access `.`", .{ field.tag });
                            return Error.UnexpectedToken;
                        },
                    };
                },
                .lbrack => {
                    const index_expr = try parseExpr(lexer, gen) orelse {
                        lexer.report_err(peek.off, "Expect expression after `[`", .{});
                        return Error.UnexpectedToken;
                    };
                    const rbrack = try expectTokenCrit(lexer, .rbrack, gen.exprs.items[index_expr.idx].tk);
                    break :expr_blk Expr{ .data = .{ .array_access = .{ .lhs = lhs, .rhs = index_expr } }, .tk = rbrack };
                },
                else => unreachable,
            };
        } else if (op.infixBP()) |bp| expr_blk: {
            const lbp, const rbp = bp;
            if (lbp < min_bp or (op.nonAssoc() and lbp == min_bp)) break;
            lexer.consume();
            if (op == .as) {
                const rhs = try parseTypeExpr(lexer, gen) orelse {
                    lexer.report_err(peek.off, "Expected type expression after `as`", .{});
                    return Error.UnexpectedToken;
                };
                break :expr_blk Expr{ .data = ExprData{ .as = .{ .lhs = lhs, .rhs = rhs } }, .tk = gen.types.items[rhs.idx].tk };
            } else {
                const rhs = try parseExprClimb(lexer, gen, rbp) orelse {
                    lexer.report_err(peek.off, "Expect expression after `{}`", .{ op });
                    return Error.UnexpectedToken;
                };
                break :expr_blk Expr{ .data = ExprData{ .bin_op = .{ .lhs = lhs, .rhs = rhs, .op = op } }, .tk = gen.exprs.items[rhs.idx].tk };
            }
        } else {
            break;
        };
        lhs = gen.new(&gen.exprs, expr);
        peek = try lexer.peek();
    }
    return lhs;
}
pub fn parseAtomicExpr(lexer: *Lexer, gen: *AstGen) Error!?ExprIdx {
    const tok = try lexer.peek();
    switch (tok.tag) {
        .string => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .string = lexer.reStringLit(tok.off) }, .tk = tok });
        },
        .iden => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .iden = lexer.reIdentifier(tok.off) }, .tk = tok });
        },
        .int => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .int = lexer.reInt(tok.off) }, .tk = tok });
        },
        .float => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .float = lexer.reFloat(tok.off) }, .tk = tok });
        },
        .lparen => {
            const lparen = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, gen) orelse {
                lexer.report_err(lparen.off, "Expect expr after `(`", .{});
                return null;
            };
            const rparen = try expectTokenCrit(lexer, .rparen, gen.exprs.items[expr.idx].tk);
            return gen.new(&gen.exprs, Expr{ .data = .{ .paren = expr }, .tk = rparen });
        },
        .true => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .bool = true }, .tk = tok });
        },
        .false => {
            lexer.consume();
            return gen.new(&gen.exprs, Expr{ .data = .{ .bool = false }, .tk = tok });
        },
        else => return null,
    }
}

pub fn to_loc(ast: *const Ast, tk: Token) Lexer.Loc {
    return ast.lexer.to_loc(tk.off);
}

pub fn to_loc2(ast: *const Ast, off: u32) Lexer.Loc {
    return ast.lexer.to_loc(off);
}

fn findStandardLibrary(io: Io, gpa: std.mem.Allocator) ![]const u8 {
    const exe_dir_path = std.process.executableDirPathAlloc(io, gpa) catch @panic("OOM");
    defer gpa.free(exe_dir_path);
    const std_cat_path = std.fs.path.resolve(gpa, &.{ exe_dir_path, "..", "lib", "std", "std.cat"}) catch @panic("OOM");
    log.debug("std path: {s}", .{ std_cat_path });
    try Io.Dir.accessAbsolute(io, std_cat_path, .{ .read = true });
    return std_cat_path;
}


