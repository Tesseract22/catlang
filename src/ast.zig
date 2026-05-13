const std = @import("std");
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
    entry = 0,
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
            gpa.free(ast.lexer.src);
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

const Arena = struct {
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    exprs: Exprs,
    defs: Defs,
    stats: Stats,
    types: TypeExprs,
    asts: Sources.Map,
    srcs_to_parsed: std.ArrayList(ModulePath),
    io: Io,

    const ModulePath = struct {
        by_off: u32,
        by_path: []const u8,
        by_src: []const u8,

        path: []const u8,
        id: Id,
    };

    pub fn new(self: *Arena, array: anytype, e: anytype) makeID(@TypeOf(e)) {
        array.append(self.alloc, e) catch @panic("out of memory");
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
    const entry_id = Arena.get_id();
    var arena = Arena {
        .alloc = gpa,
        .exprs = Exprs.empty,
        .defs = Defs.empty,
        .stats = Stats.empty,
        .types = TypeExprs.empty,
        .arena = a,
        .asts = .empty,
        .srcs_to_parsed = std.ArrayList(Arena.ModulePath).initCapacity(gpa, 3) catch @panic("OOM"),
        .io = io,
    };
    arena.srcs_to_parsed.appendAssumeCapacity(.{ .path = entry_file_path, .id = entry_id, .by_off = 0, .by_src = "", .by_path = entry_file_path });
    // TODO: better allocation strat so we can forget about this
    errdefer {
        for (arena.defs.items) |def| {
            switch (def.data) {
                .proc => |proc| {
                    gpa.free(proc.body);
                    gpa.free(proc.args);
                },
                else => {},
            }
        }
        for (arena.exprs.items) |expr| {
            switch (expr.data) {
                .fn_app => |fn_app| gpa.free(fn_app.args),
                else => {},
            }
        }
        arena.exprs.deinit(gpa);
        arena.defs.deinit(gpa);
        arena.stats.deinit(gpa);
        arena.asts.deinit(gpa);
    }
    defer arena.srcs_to_parsed.deinit(gpa);

    // TODO: memory leak when error
    while (arena.srcs_to_parsed.pop()) |module_path| {
        log.debug("parsing file: {s}", .{ module_path.path });
        const path = module_path.path;
        var f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
            log.err("cannot open import file: `{s}`: {}", .{ path, e });
            log.note("{f}: file imported here", .{ Lexer.to_loc_src(module_path.by_src, module_path.by_path, module_path.by_off) });
            Lexer.print_src_line_off(module_path.by_src, module_path.by_off);
            return e;
        };
        defer f.close(io);

        var buf: [256]u8 = undefined;
        var reader = f.reader(io, &buf);
        const src = reader.interface.allocRemaining(gpa, .unlimited) catch @panic("OOM");
        errdefer gpa.free(src);

        var lexer = Lexer.init(src, path);

        var defs = std.ArrayList(DefIdx).initCapacity(gpa, 3) catch @panic("OOM");
        errdefer defs.deinit(gpa);
        while (try parseTopDef(&lexer, &arena)) |idx| {
            defs.append(gpa, idx) catch @panic("OOM");
        }
        const ast = arena.arena.create(Ast) catch @panic("OOM");
        ast.* = Ast {
            .defs = defs.toOwnedSlice(gpa) catch @panic("OOM"),
            .lexer = lexer,
        };
        arena.asts.putNoClobber(arena.alloc, module_path.id, ast) catch @panic("OOM");
    }
    return Sources {
        .exprs = arena.exprs.toOwnedSlice(gpa) catch @panic("OOM"),
        .defs = arena.defs.toOwnedSlice(gpa) catch @panic("OOM"),
        .stats = arena.stats.toOwnedSlice(gpa) catch @panic("OOM"),
        .types = arena.types.toOwnedSlice(gpa) catch @panic("OOM"),
        .asts = arena.asts,
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
pub fn parseVarBind(lexer: *Lexer, arena: *Arena) Error!?VarBind {
    const iden_tk = try expectTokenRewind(lexer, .iden) orelse return null;
    const colon_tk = try expectTokenCrit(lexer, .colon, iden_tk);
    const t = try parseTypeExpr(lexer, arena) orelse {
        lexer.report_err(colon_tk.off, "Expect type expression after `:`", .{});
        return Error.UnexpectedToken;
    };
    return VarBind{ .name = lexer.reIdentifier(iden_tk.off), .type = t, .tk = iden_tk };
}
pub fn parseList(comptime T: type, f: fn (*Lexer, *Arena) Error!?T, lexer: *Lexer, arena: *Arena, alloc: std.mem.Allocator) Error![]T {
    var list = std.ArrayList(T).empty;
    defer list.deinit(alloc);
    const first = try f(lexer, arena) orelse return (list.toOwnedSlice(alloc) catch unreachable);
    list.append(alloc, first) catch unreachable;
    while (true) {
        const tk = try lexer.peek();
        switch (tk.tag) {
            .comma => {
                lexer.consume();
                const item = try f(lexer, arena) orelse {
                    lexer.report_err(tk.off, "Expect argument after comma", .{});
                    return Error.UnexpectedToken;
                };
                list.append(alloc, item) catch unreachable;
            },
            else => break,
        }
    }
    return list.toOwnedSlice(alloc) catch unreachable;
}

pub fn parseTypeExpr(lexer: *Lexer, arena: *Arena) Error!?TypeExprIdx {
    const head = try lexer.peek();
    switch (head.tag) {
        .times => {
            lexer.consume();
            const el_t = try parseTypeExpr(lexer, arena) orelse {
                lexer.report_err(head.off, "Expect element type after '*'", .{});
                return Error.UnexpectedToken;
            };
            return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .ptr = .{ .el = el_t } } });
        },
        .lbrack => {
            lexer.consume();
            const size_tk = try expectTokenCrit(lexer, .int, head);
            const rbrack = try expectTokenCrit(lexer, .rbrack, size_tk);
            const size = lexer.reInt(size_tk.off);
            const el_t = try parseTypeExpr(lexer, arena) orelse {
                lexer.report_err(rbrack.off, "Expect element type after ']'", .{});
                return Error.UnexpectedToken;
            };
            if (size < 0) {
                lexer.report_err(size_tk.off, "Array length must be non-negative, got {}", .{ size });
                return Error.InvalidNum;
            }
            return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .array = .{ .el = el_t, .size = @intCast(size) } } });
        },
        .lcurly => {
            lexer.consume();
            if ((try lexer.peek()).tag == .dot) {
                const tuple = try parseList(VarBind, parseVarBindField, lexer, arena, arena.arena);
                _ = try expectTokenCrit(lexer, .rcurly, head);
                return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .named = tuple } });
            } else {
                const tuple = try parseList(TypeExprIdx, parseTypeExpr, lexer, arena, arena.arena);
                _ = try expectTokenCrit(lexer, .rcurly, head);
                return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .tuple = tuple } });
            }
        },
        .lparen => {
            lexer.consume();
            const args = try parseList(TypeExprIdx, parseTypeExpr, lexer, arena, arena.arena);
            const rparen = try expectTokenCrit(lexer, .rparen, head);
            const arrow = try expectTokenCrit(lexer, .arrow, rparen);
            const ret = try parseTypeExpr(lexer, arena) orelse {
                lexer.report_err(arrow.off, "Expect return type after '->'", .{});
                return Error.UnexpectedToken;
            };
            return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .function = .{ .args = args, .ret = ret } } });
        },
        .iden => {
            lexer.consume();
            return arena.new(&arena.types, TypeExpr{ .tk = head, .data = .{ .ident = lexer.reIdentifier(head.off) } });
        },
        else => return null,
    }
}
pub fn parseVarBindField(lexer: *Lexer, arena: *Arena) Error!?VarBind {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const bind = try parseVarBind(lexer, arena) orelse {
        lexer.report_err(dot.off, "Expect field decleration after dot", .{});
        return Error.UnexpectedToken;
    };
    return bind;
}

pub fn parseTopDef(lexer: *Lexer, arena: *Arena) Error!?DefIdx {
    const head = try lexer.peek();
    switch (head.tag) {
        .proc, .@"fn" => {
            lexer.consume();
            const iden_tok = try expectTokenCrit(lexer, .iden, head);
            const lparen_tok = try expectTokenCrit(lexer, .lparen, iden_tok);

            const args_slice = try parseList(VarBind, parseVarBind, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(args_slice);

            const rparen = try expectTokenCrit(lexer, .rparen, lparen_tok);
            const ret_type: TypeExprIdx = if (head.tag == TokenType.@"fn") blk: {
                const colon = try expectTokenCrit(lexer, .colon, rparen);
                const ret_t = try parseTypeExpr(lexer, arena) orelse {
                    lexer.report_err(colon.off, "Expects type expression after colon", .{});
                    return Error.UnexpectedToken;
                };
                break :blk ret_t;
            } else arena.new(&arena.types, TypeExpr { .data = .{ .ident = Lexer.string_pool.intern("void") }, .tk = rparen });
            const stats = try parseBlock(lexer, arena, rparen);
            const args_def_insts = arena.arena.alloc(Cir.Index, args_slice.len) catch @panic("OOM");
            errdefer arena.alloc.free(stats);
            return arena.new(
                &arena.defs,
                TopDef{ .tk = rparen, .data =
                    .{ .proc = TopDefData.ProcDef { .body = stats, .name = lexer.reIdentifier(iden_tok.off), .args = args_slice, .args_def_insts = args_def_insts, .ret = ret_type } } },
            );
        },
        .foreign => {
            lexer.consume();
            const string_tok = try expectTokenCrit(lexer, .string, head);
            const colon = try expectTokenCrit(lexer, .colon, string_tok);
            const t = try parseTypeExpr(lexer, arena) orelse {
                lexer.report_err(colon.off, "Expect type expression after ':'", .{});
                return Error.UnexpectedToken;
            };
            const semi = try expectTokenCrit(lexer, .semi, colon);
            return arena.new(
                &arena.defs,
                TopDef{ .tk = semi, .data = .{ .foreign = TopDefData.Foreign { .name = lexer.reIdentifier(string_tok.off + 1), .t = t } } },
            );
        },
        .type => {
            lexer.consume();
            const name = try expectTokenCrit(lexer, .iden, head);
            const colon = try expectTokenCrit(lexer, .colon, name);
            const type_expr = try parseTypeExpr(lexer, arena) orelse {
                lexer.report_err(colon.off, "Expects type expression after colon", .{});
                return Error.UnexpectedToken;
            };
            const semi = try expectTokenCrit(lexer, .semi, colon);
            return arena.new(&arena.defs, TopDef {
                .tk = semi,
                .data = .{ .type = .{ .tk = semi, .name = lexer.reIdentifier(name.off), .type = type_expr } },
            });
        },
        .import => {
            lexer.consume();
            const string_tok = try expectTokenCrit(lexer, .string, head);
            _ = try expectTokenCrit(lexer, .semi, string_tok);

            const id = Arena.get_id(); // TODO: resuse previously parsed module
            const import_str = lexer.reStringLitStr(string_tok.off);
            const final_path = if (std.mem.eql(u8, "std", import_str)) blk: {
                if (std_path.len == 0) std_path = try findStandardLibrary(arena.io, arena.alloc);
                break :blk std_path;
            } else blk: {
                const dir_path = std.fs.path.dirname(lexer.path) orelse ".";
                break :blk std.fs.path.resolve(arena.arena, &.{ dir_path, import_str }) catch @panic("OOM");
            };

            // TODO: dependency loop detection

            arena.srcs_to_parsed.append(arena.alloc, .{
                .path = final_path,
                .id = id,
                .by_off = head.off,
                .by_src = lexer.src,
                .by_path = final_path,
            }) catch @panic("OOM");
            return arena.new(&arena.defs, TopDef {
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
pub fn parseBlock(lexer: *Lexer, arena: *Arena, before: Token) Error![]StatIdx {
    const lcurly = try expectTokenCrit(lexer, .lcurly, before);
    var stats = std.ArrayList(StatIdx).empty;
    defer stats.deinit(arena.alloc);

    while (try parseStat(lexer, arena)) |stat| {
        stats.append(arena.alloc, stat) catch unreachable;
    }
    _ = try expectTokenCrit(lexer, .rcurly, if (stats.items.len > 1) arena.stats.items[stats.getLast().idx].tk else lcurly);
    return stats.toOwnedSlice(arena.alloc) catch unreachable;
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
pub fn parseIf(lexer: *Lexer, arena: *Arena) Error!?StatIdx {
    const if_tk = try expectTokenRewind(lexer, .@"if") orelse return null;
    const cond_expr = try parseExpr(lexer, arena) orelse {
        lexer.report_err(if_tk.off, "Expect expression after `if`", .{});
        return Error.UnexpectedToken;
    };
    const stats = try parseBlock(lexer, arena, arena.exprs.items[cond_expr.idx].tk);
    errdefer arena.alloc.free(stats);
    const else_stats: StatData.Else = blk: {
        const else_tk = try expectTokenRewind(lexer, .@"else") orelse break :blk .none;
        if (try parseIf(lexer, arena)) |next_if| {
            break :blk .{ .else_if = next_if };
        } else {
            break :blk .{ .stats = try parseBlock(lexer, arena, else_tk) };
        }
    };
    return arena.new(
        &arena.stats,
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
pub fn parseStat(lexer: *Lexer, arena: *Arena) Error!?StatIdx {
    if (try parseExpr(lexer, arena)) |expr| {
        const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
        switch (arena.exprs.items[expr.idx].data) {
            .bin_op => |bin_op| {
                if (bin_op.op == .assign) {
                    return arena.new(&arena.stats, Stat{
                        .data = .{
                            .assign = .{ .expr = bin_op.rhs, .left_value = bin_op.lhs },
                        },
                        .tk = arena.exprs.items[bin_op.lhs.idx].tk,
                    });
                }
            },
            else => {},
        }
        return arena.new(
            &arena.stats,
            Stat{ .data = .{ .anon = expr }, .tk = semi_tk },
        );
    }

    const head = try lexer.peek();
    switch (head.tag) {
        .let => {
            lexer.consume();
            const name_tk = try expectTokenCrit(lexer, .iden, head);
            const colon_tk = try expectTokenCrit(lexer, .colon, name_tk);
            const te = try parseTypeExpr(lexer, arena);
            const eq_tk = try expectTokenRewind(lexer, .assign) orelse {
                const prev_tk = if (te) |te_inner| arena.types.items[te_inner.idx].tk else colon_tk;
                const semi_tk = try expectTokenCrit(lexer, .semi, prev_tk);
                if (te == null) {
                    lexer.report_err(head.off, "At least one of the type or the rhs expression should be specified", .{});
                    return Error.UnexpectedToken;
                }
                return arena.new(
                    &arena.stats,
                    Stat{ .data = .{ .var_decl =.{
                        .expr = null, .name = lexer.reIdentifier(name_tk.off), .te = te,
                        .t = .invalid, .i = .invalid } }, .tk = semi_tk },
                );
            };
            const expr = try parseExpr(lexer, arena) orelse {
                lexer.report_err(eq_tk.off, "Expect expression after `=`", .{});
                return Error.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
            return arena.new(
                &arena.stats,
                Stat{ .data = .{ .var_decl = .{
                    .expr = expr, .name = lexer.reIdentifier(name_tk.off), .te = te,
                    .t = .invalid, .i = .invalid } }, .tk = semi_tk },
            );
        },
        .ret => {
            lexer.consume();
            const expr = try parseExpr(lexer, arena) orelse {
                lexer.report_err(head.off, "Expect expression after `ret`", .{});
                return Error.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
            return arena.new(
                &arena.stats,
                Stat{ .data = .{ .ret = expr }, .tk = semi_tk },
            );
        },
        .@"if" => return parseIf(lexer, arena),
        .loop => {
            const loop = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, arena) orelse arena.new(
                &arena.exprs,
                Expr{ .data = .{ .bool = true }, .tk = loop },
            );
            const stats = try parseBlock(lexer, arena, arena.exprs.items[expr.idx].tk);
            errdefer arena.alloc.free(stats);
            return arena.new(&arena.stats, Stat{ .data = .{ .loop = .{ .cond = expr, .body = stats } }, .tk = loop });
        },
        else => return null,
    }
    unreachable;
}
pub fn parseNamedInit(lexer: *Lexer, arena: *Arena) Error!?NamedInit {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const name = try expectTokenCrit(lexer, .iden, dot);
    const assign = try expectTokenCrit(lexer, .assign, name);
    const expr = try parseExpr(lexer, arena) orelse {
        lexer.report_err(assign.off, "Expect exprssion after `=`", .{});
        return Error.UnexpectedToken;
    };
    return NamedInit{ .expr = expr, .name = lexer.reIdentifier(name.off), .tk = arena.exprs.items[expr.idx].tk };
}
pub fn parseExpr(lexer: *Lexer, arena: *Arena) Error!?ExprIdx {
    return parseExprClimb(
        lexer,
        arena,
        0,
    );
}
pub fn parseExprClimb(lexer: *Lexer, arena: *Arena, min_bp: u8) Error!?ExprIdx {
    var lhs = if (try expectTokenRewind(lexer, .lbrack)) |lbrack| blk: {
        const list = try parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc);
        errdefer arena.alloc.free(list);
        const rbrack = try expectTokenCrit(lexer, .rbrack, if (list.len > 1) arena.exprs.items[list[list.len - 1].idx].tk else lbrack);
        break :blk arena.new(&arena.exprs, Expr{ .data = .{ .array = list }, .tk = rbrack });
    } else if (try expectTokenRewind(lexer, .lcurly)) |lt| blk: {
        const head = try lexer.peek();
        if (head.tag == .dot) {
            const list = try parseList(NamedInit, parseNamedInit, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(list);
            const rcurly = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) list[list.len - 1].tk else lt);
            break :blk arena.new(&arena.exprs, Expr{ .data = .{ .named_tuple = list }, .tk = rcurly });
        } else {
            const list = try parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(list);
            const gt = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) arena.exprs.items[list[list.len - 1].idx].tk else lt);
            break :blk arena.new(&arena.exprs, Expr{ .data = .{ .tuple = list }, .tk = gt });
        }
    } else if (try expectTokenRewind(lexer, .not)) |not| blk: {
        const lbp = parseOp(not).?.prefixBP().?;
        const rhs = try parseExprClimb(lexer, arena, lbp) orelse {
            lexer.report_err(not.off, "Expect rhs after `!`", .{});
            return Error.UnexpectedToken;
        };
        break :blk arena.new(&arena.exprs, Expr{ .data = .{ .not = rhs }, .tk = not });
    } else try parseAtomicExpr(lexer, arena) orelse return null;
    var peek = try lexer.peek();

    while (parseOp(peek)) |op| {
        const expr = if (op.postfixBP()) |lbp| expr_blk: {
            if (lbp < min_bp) break;
            lexer.consume();
            break :expr_blk switch (op) {
                .lparen => {
                    const exprs = parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc) catch |e| {
                        lexer.report_err(peek.off, "Expect list of expression after `{}`", .{ op });
                        return e;
                    };
                    errdefer arena.alloc.free(exprs);
                    const exprs_tk = if (exprs.len > 1) arena.exprs.items[exprs[exprs.len - 1].idx].tk else peek;
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
                    const index_expr = try parseExpr(lexer, arena) orelse {
                        lexer.report_err(peek.off, "Expect expression after `[`", .{});
                        return Error.UnexpectedToken;
                    };
                    const rbrack = try expectTokenCrit(lexer, .rbrack, arena.exprs.items[index_expr.idx].tk);
                    break :expr_blk Expr{ .data = .{ .array_access = .{ .lhs = lhs, .rhs = index_expr } }, .tk = rbrack };
                },
                else => unreachable,
            };
        } else if (op.infixBP()) |bp| expr_blk: {
            const lbp, const rbp = bp;
            if (lbp < min_bp or (op.nonAssoc() and lbp == min_bp)) break;
            lexer.consume();
            if (op == .as) {
                const rhs = try parseTypeExpr(lexer, arena) orelse {
                    lexer.report_err(peek.off, "Expected type expression after `as`", .{});
                    return Error.UnexpectedToken;
                };
                break :expr_blk Expr{ .data = ExprData{ .as = .{ .lhs = lhs, .rhs = rhs } }, .tk = arena.types.items[rhs.idx].tk };
            } else {
                const rhs = try parseExprClimb(lexer, arena, rbp) orelse {
                    lexer.report_err(peek.off, "Expect expression after `{}`", .{ op });
                    return Error.UnexpectedToken;
                };
                break :expr_blk Expr{ .data = ExprData{ .bin_op = .{ .lhs = lhs, .rhs = rhs, .op = op } }, .tk = arena.exprs.items[rhs.idx].tk };
            }
        } else {
            break;
        };
        lhs = arena.new(&arena.exprs, expr);
        peek = try lexer.peek();
    }
    return lhs;
}
pub fn parseAtomicExpr(lexer: *Lexer, arena: *Arena) Error!?ExprIdx {
    const tok = try lexer.peek();
    switch (tok.tag) {
        .string => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .string = lexer.reStringLit(tok.off) }, .tk = tok });
        },
        .iden => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .iden = lexer.reIdentifier(tok.off) }, .tk = tok });
        },
        .int => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .int = lexer.reInt(tok.off) }, .tk = tok });
        },
        .float => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .float = lexer.reFloat(tok.off) }, .tk = tok });
        },
        .lparen => {
            const lparen = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, arena) orelse {
                lexer.report_err(lparen.off, "Expect expr after `(`", .{});
                return null;
            };
            const rparen = try expectTokenCrit(lexer, .rparen, arena.exprs.items[expr.idx].tk);
            return arena.new(&arena.exprs, Expr{ .data = .{ .paren = expr }, .tk = rparen });
        },
        .true => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .bool = true }, .tk = tok });
        },
        .false => {
            lexer.consume();
            return arena.new(&arena.exprs, Expr{ .data = .{ .bool = false }, .tk = tok });
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


