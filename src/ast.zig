const std = @import("std");
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const LexerError = Lexer.LexerError;
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;
pub const Type = enum {
    string,
    int,
    float,
    bool,
    void,
    pub fn fromString(s: []const u8) ?Type {
        const info = @typeInfo(Type).Enum;
        inline for (info.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, s)) return @enumFromInt(i);
        }
        return null;
    }
    pub fn format(value: Type, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.write(@tagName(value));
    }
};
pub const Val = union(Type) {
    string: []const u8,
    int: isize,
    float: f64,
    bool: bool,
    void,
    pub fn format(value: Val, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .string => |s| _ = try writer.write(s),
            inline .int, .bool, .float => |x| try writer.print("{}", .{x}),
            .void => _ = try writer.write("void"),
        }
    }
};
pub const VarBind = struct {
    type: Type,
    name: []const u8,
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
pub const DefIdx = makeID(ProcDef);
fn nodeFromData(comptime T: type) type {
    return struct {
        data: T,
        tk: Token,
    };
}
pub const AtomicData = union(enum) {
    iden: []const u8,
    string: []const u8,
    int: isize,
    bool: bool,
    float: f64,
    paren: ExprIdx,
    fn_app: FnApp,
    pub const FnApp = struct {
        func: []const u8,
        args: []const ExprIdx,
    };
};
pub const Op = enum {
    eq,
    lt,
    gt,

    plus,
    minus,

    times,
    div,
    mod,

    as,
    pub fn prec(self: Op) u8 {
        return switch (self) {
            .eq, .lt, .gt => 0,
            .plus, .minus => 1,
            .times, .div, .mod => 2,
            .as => 3,
        };
    }
};
pub const ExprData = union(enum) {
    atomic: Atomic,
    bin_op: BinOp,
    const BinOp = struct {
        lhs: ExprIdx,
        rhs: ExprIdx,
        op: Op,
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
        name: []const u8,
        t: ?Type,
        expr: ExprIdx,
    };
    pub const Assign = struct {
        name: []const u8,
        expr: ExprIdx,
    };
};
pub const ProcDefData = struct {
    name: []const u8,
    args: []VarBind,
    body: []StatIdx,
    ret: Type,
};
pub const Atomic = nodeFromData(AtomicData);
pub const Expr = nodeFromData(ExprData);
pub const Stat = nodeFromData(StatData);
pub const ProcDef = nodeFromData(ProcDefData);
pub const ParseError = error{ UnexpectedToken, EndOfStream, InvalidType } || LexerError;
exprs: []Expr,
stats: []Stat,

defs: []ProcDef,
// top: []ProcDef,
const Exprs = std.ArrayList(Expr);
const Defs = std.ArrayList(ProcDef);
const Stats = std.ArrayList(Stat);
const Arena = struct {
    alloc: std.mem.Allocator,
    exprs: Exprs,
    defs: Defs,
    stats: Stats,
};
const Ast = @This();
pub fn new(array: anytype, e: anytype) makeID(@TypeOf(e)) {
    array.append(e) catch @panic("out of memory");
    return makeID(@TypeOf(e)){ .idx = array.items.len - 1 };
}




pub fn parse(lexer: *Lexer, alloc: std.mem.Allocator) ParseError!Ast {
    var arena = Arena{
        .alloc = alloc,
        .exprs = Exprs.init(alloc),
        .defs = Defs.init(alloc),
        .stats = Stats.init(alloc),
    };
    errdefer {
        for (arena.defs.items) |def| {
            alloc.free(def.data.body);
            alloc.free(def.data.args);
        }
        for (arena.exprs.items) |expr| {
            switch (expr.data) {
                .atomic => |atomic| switch (atomic.data) {
                    .fn_app => |fn_app| alloc.free(fn_app.args),
                    else => {},
                },
                else => {},
            }
        }
        arena.exprs.deinit();
        arena.defs.deinit();
        arena.stats.deinit();
    }
    while (try parseProc(lexer, &arena)) |_| {}
    return Ast{
        .exprs = arena.exprs.toOwnedSlice() catch unreachable,
        .stats = arena.stats.toOwnedSlice() catch unreachable,
        .defs = arena.defs.toOwnedSlice() catch unreachable,
    };
}
pub fn deinit(ast: *Ast, alloc: std.mem.Allocator) void {
    for (ast.defs) |def| {
        alloc.free(def.data.body);
        alloc.free(def.data.args);
    }
    for (ast.exprs) |expr| {
        switch (expr.data) {
            .atomic => |atomic| switch (atomic.data) {
                .fn_app => |fn_app| alloc.free(fn_app.args),
                else => {},
            },
            else => {},
        }
    }
    for (ast.stats) |stat| {
        switch (stat.data) {
            .@"if" => |if_stat| {
                alloc.free(if_stat.body);
                switch (if_stat.else_body) {
                    .stats => |stats| alloc.free(stats),
                    else => {},
                }
            },
            .loop => |loop| {
                alloc.free(loop.body);
            },
            else => {},
        }
    }
    alloc.free(ast.exprs);
    alloc.free(ast.defs);
    alloc.free(ast.stats);
}
pub fn expectTokenCrit(lexer: *Lexer, kind: TokenType, before: Token) !Token {
    const tok = try lexer.next() orelse {
        log.err("{} Expect {} after `{s}`, found eof", .{ before.loc, kind, @tagName(before.data) });
        return ParseError.EndOfStream;
    };
    if (@intFromEnum(tok.data) != @intFromEnum(kind)) {
        log.err("{} Expect {} after `{s}`, found {s}", .{ tok.loc, kind, @tagName(before.data), @tagName(tok.data) });
        return ParseError.UnexpectedToken;
    }
    return tok;
}
pub fn expectTokenRewind(lexer: *Lexer, kind: TokenType) !?Token {
    const tok = try lexer.peek() orelse return null;
    if (@intFromEnum(tok.data) != @intFromEnum(kind)) {
        return null;
    }
    _ = lexer.next() catch unreachable;
    return tok;
}
pub fn parseVarBind(lexer: *Lexer, _: *Arena) ParseError!?VarBind {
    const iden_tk = try expectTokenRewind(lexer, .iden) orelse return null;
    const colon_tk = try expectTokenCrit(lexer, .colon, iden_tk);
    const type_tk = try expectTokenCrit(lexer, .iden, colon_tk);
    const t = Type.fromString(type_tk.data.iden) orelse {
        log.err("Unknow type: `{s}`", .{type_tk.data.iden});
        return ParseError.InvalidType;
    };
    return VarBind{ .name = iden_tk.data.iden, .type = t, .tk = iden_tk };
}
pub fn parseList(comptime T: type, f: fn (*Lexer, *Arena) ParseError!?T, lexer: *Lexer, arena: *Arena) ParseError![]T {
    var list = std.ArrayList(T).init(arena.alloc);
    defer list.deinit();
    const first = try f(lexer, arena) orelse return (list.toOwnedSlice() catch unreachable);

    list.append(first) catch unreachable;
    while (try lexer.peek()) |tk| {
        switch (tk.data) {
            .comma => {
                lexer.consume();
                const item = try f(lexer, arena) orelse {
                    log.err("{} Expect argument after comma", .{tk.loc});
                    return ParseError.UnexpectedToken;
                };
                list.append(item) catch unreachable;
            },
            else => break,
        }
    }
    return list.toOwnedSlice() catch unreachable;
}
pub fn parseProc(lexer: *Lexer, arena: *Arena) ParseError!?DefIdx {
    const proc_tok: Token = (try expectTokenRewind(lexer, .proc)) orelse (try expectTokenRewind(lexer, .func)) orelse return null;
    const iden_tok = try expectTokenCrit(lexer, .fn_app, proc_tok);

    const args_slice = try parseList(VarBind, parseVarBind, lexer, arena);
    errdefer arena.alloc.free(args_slice);

    const rparen = try expectTokenCrit(lexer, .rparen, iden_tok);
    const ret_type: Type = if (proc_tok.data == TokenType.func) blk: {
        const colon = try expectTokenCrit(lexer, .colon, rparen);
        const ret_tk = try expectTokenCrit(lexer, .iden, colon);
        break :blk Type.fromString(ret_tk.data.iden) orelse {
            log.err("{} `{s}` is not a type", .{ ret_tk.loc, ret_tk.data.iden });
            return ParseError.InvalidType;
        };
    } else Type.void;
    const stats = try parseBlock(lexer, arena, rparen);
    errdefer arena.alloc.free(stats);
    return new(
        &arena.defs,
        ProcDef{
            .data = .{ .body = stats, .name = iden_tok.data.fn_app, .args = args_slice, .ret = ret_type },
            .tk = rparen,
        },
    );
}
pub fn parseBlock(lexer: *Lexer, arena: *Arena, before: Token) ParseError![]StatIdx {
    const lcurly = try expectTokenCrit(lexer, .lcurly, before);
    var stats = std.ArrayList(StatIdx).init(arena.alloc);
    defer stats.deinit();

    while (try parseStat(lexer, arena)) |stat| {
        stats.append(stat) catch unreachable;
    }
    _ = try expectTokenCrit(lexer, .rcurly, if (stats.items.len > 1) arena.stats.items[stats.getLast().idx].tk else lcurly);
    return stats.toOwnedSlice() catch unreachable;
}
pub fn parseBinOp(tk: Token) ?Op {
    return switch (tk.data) {
        .plus => .plus,
        .minus => .minus,
        .times => .times,
        .div => .div,
        .mod => .mod,
        .as => .as,
        .eq => .eq,
        .lt => .lt,
        .gt => .gt,
        else => null,
    };
}
pub fn parseIf(lexer: *Lexer, arena: *Arena) ParseError!?StatIdx {
    const if_tk = try expectTokenRewind(lexer, .@"if") orelse return null;
    const cond_expr = try parseExpr(lexer, arena) orelse {
        log.err("{} Expect expression after `if`", .{if_tk.loc});
        return ParseError.UnexpectedToken;
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
    return new(
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
pub fn parseStat(lexer: *Lexer, arena: *Arena) ParseError!?StatIdx {
    const head = try lexer.peek() orelse return null;
    switch (head.data) {
        .let => {
            lexer.consume();
            const name_tk = try expectTokenCrit(lexer, .iden, head);
            const colon_tk = try expectTokenCrit(lexer, .colon, name_tk);
            const type_tk = try expectTokenRewind(lexer, .iden);
            const eq_tk = try expectTokenCrit(lexer, .assign, if (type_tk) |tk| tk else colon_tk);
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expression after `=`", .{eq_tk.loc});
                return ParseError.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, eq_tk);
            const t: ?Type =
                if (type_tk) |tk| Type.fromString(tk.data.iden) orelse {
                log.err("Unknow type `{s}` ", .{tk.data.iden});
                return ParseError.UnexpectedToken;
            } else null;
            return new(
                &arena.stats,
                Stat{
                    .data = .{ .var_decl = .{ .expr = expr, .name = name_tk.data.iden, .t = t } },
                    .tk = semi_tk,
                },
            );
        },
        .ret => {
            lexer.consume();
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expression after `ret`", .{head.loc});
                return ParseError.UnexpectedToken;
            };
            const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
            return new(
                &arena.stats,
                Stat{
                    .data = .{ .ret = expr },
                    .tk = semi_tk,
                },
            );
        },
        .@"if" => return parseIf(lexer, arena),
        .loop => {
            const loop = lexer.next() catch unreachable orelse unreachable;
            const expr = try parseExpr(lexer, arena) orelse new(
                &arena.exprs,
                Expr{ .data = .{ .atomic = .{ .data = .{ .bool = true }, .tk = loop } }, .tk = loop },
            );
            const stats = try parseBlock(lexer, arena, arena.exprs.items[expr.idx].tk);
            errdefer arena.alloc.free(stats);
            return new(&arena.stats, Stat{ .data = .{ .loop = .{ .cond = expr, .body = stats } }, .tk = loop });
        },
        .iden => |iden| {
            const iden_tok = lexer.next() catch unreachable orelse unreachable;
            const assign = try expectTokenCrit(lexer, .assign, iden_tok);
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expr after `assign`", .{assign.loc});
                return ParseError.UnexpectedToken;
            };
            _ = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
            return new(&arena.stats, Stat{ .data = .{ .assign = .{ .name = iden, .expr = expr } }, .tk = assign });
        },
        else => {
            const expr = try parseExpr(lexer, arena) orelse return null;
            const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
            return new(
                &arena.stats,
                Stat{
                    .data = .{ .anon = expr },
                    .tk = semi_tk,
                },
            );
        },
    }
    unreachable;
}
pub fn parseExpr(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {
    const lhs = try parseAtomicExpr(lexer, arena) orelse return null;

    return parseExprClimb(
        lexer,
        arena,
        lhs,
        0,
    );
}
pub fn parseExprClimb(lexer: *Lexer, arena: *Arena, lhs_arg: ExprIdx, min_prec: u8) ParseError!?ExprIdx {
    var lhs = lhs_arg;
    var peek = try lexer.peek() orelse return lhs;
    while (parseBinOp(peek)) |op| {
        const prec = op.prec();
        if (prec < min_prec) break;
        lexer.consume();
        errdefer log.err("{} Expect expression after `{}`", .{ peek.loc, op });
        var rhs = try parseAtomicExpr(lexer, arena) orelse return ParseError.UnexpectedToken;
        defer {
            const bin_op_expr = Expr{ .data = ExprData{ .bin_op = .{ .lhs = lhs, .rhs = rhs, .op = op } }, .tk = arena.exprs.items[rhs.idx].tk };
            lhs = new(&arena.exprs, bin_op_expr);
        }
        peek = try lexer.peek() orelse break;
        while (parseBinOp(peek)) |op2| {
            if (op2.prec() <= prec) break;
            errdefer log.err("{} Expect expression after `{}`", .{ peek.loc, op2 });
            rhs = try parseExprClimb(lexer, arena, rhs, prec + 1) orelse return ParseError.UnexpectedToken;
            peek = try lexer.peek() orelse break;
        }

        // if (peek.data.)
    }
    return lhs;
}
pub fn parseAtomicExpr(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {
    const atomic = try parseAtomic(lexer, arena) orelse return null;
    return new(&arena.exprs, Expr{ .data = .{ .atomic = atomic }, .tk = atomic.tk });
}
pub fn parseAtomic(lexer: *Lexer, arena: *Arena) ParseError!?Atomic {
    const tok = try lexer.peek() orelse return null;
    switch (tok.data) {
        .string => |i| {
            lexer.consume();
            return Atomic{ .data = .{ .string = i }, .tk = tok };
        },
        .iden => |i| {
            lexer.consume();
            return Atomic{ .data = .{ .iden = i }, .tk = tok };
        },
        .int => |i| {
            lexer.consume();
            return Atomic{ .data = .{ .int = i }, .tk = tok };
        },
        .float => |f| {
            lexer.consume();
            return Atomic{ .data = .{ .float = f }, .tk = tok };
        },
        .lparen => {
            const lparen = lexer.next() catch unreachable orelse unreachable;
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expr after `(`", .{lparen.loc});
                return null;
            };
            const rparen = try expectTokenCrit(lexer, .rparen, arena.exprs.items[expr.idx].tk);
            return Atomic{ .data = .{ .paren = expr }, .tk = rparen };
        },
        .fn_app => {
            const fn_app_tok = lexer.next() catch unreachable orelse unreachable;
            const args = try parseList(ExprIdx, parseExpr, lexer, arena);
            errdefer arena.alloc.free(args);

            const rparen_tk = try expectTokenCrit(lexer, .rparen, fn_app_tok);

            return Atomic{
                .data = .{ .fn_app = .{ .args = args, .func = fn_app_tok.data.fn_app } },
                .tk = rparen_tk,
            };
        },
        else => return null,
    }
}
const State = struct {
    mem: Mem,
    pub const Mem = std.StringHashMap(Val);

    pub fn init(alloc: std.mem.Allocator) State {
        return State{ .mem = Mem.init(alloc) };
    }
    pub fn deinit(self: *State) void {
        self.mem.deinit();
    }
    pub fn clone(self: State) State {
        return State{ .mem = self.mem.clone() catch unreachable };
    }
};
pub const EvalError = error{
    Undefined,
    Redefined,
    IO,
    TypeMismatched,
};
pub fn eval(ast: Ast, alloc: std.mem.Allocator) EvalError!void {
    const main_idx = for (ast.defs, 0..) |def, i| {
        if (std.mem.eql(u8, def.data.name, "main")) {
            break i;
        }
    } else {
        log.err("Undefined reference to `main`", .{});
        return EvalError.Undefined;
    };
    const main_fn = ast.defs[main_idx];
    var state = State.init(alloc);
    defer state.deinit();
    for (main_fn.data.body) |stat| {
        try evalStat(ast, &state, ast.stats[stat.idx]);
    }
}
pub fn evalStat(ast: Ast, state: *State, stat: Stat) EvalError!void {
    switch (stat.data) {
        .anon => |expr_idx| {
            const expr = ast.exprs[expr_idx.idx];
            _ = try evalExpr(ast, state, expr);
        },
        .var_decl => |var_decls| {
            const val = try evalExpr(ast, state, ast.exprs[var_decls.expr.idx]);
            const entry = state.mem.fetchPut(var_decls.name, val) catch unreachable;
            if (entry) |_| {
                log.err("{} Identifier redefined: `{s}`", .{ stat.tk.loc, var_decls.name });
                // TODO provide location of previously defined variable
                return EvalError.Undefined;
            }
        },
        inline .@"if",
        .ret,
        .assign,
        .loop,
        => |_| @panic("TODO"),
    }
}
// pub fn typeCheckFn(ast: Ast, fn_app_expr: Expr, fn_def_stat: ProcDef) !void {
//     const fn_app = fn_app_expr.data.fn_app;
//     const fn_def = fn_def_stat;

//     if (fn_def.data.args.len != fn_app.args.len) {
//         log.err("{} `{s}` expected {} arguments, got {}", .{fn_app_expr.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
//         log.note("{} function argument defined here", .{fn_def.tk.loc});
//         return EvalError.TypeMismatched;
//     }
//     for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
//         const e = ast.exprs[fa.idx];
//         const val = try evalExpr(ast, state, e);
//         if (@intFromEnum(val) != @intFromEnum(fd.type)) {
//             log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{e.tk.loc, i, fn_app.func, fd.type, @tagName(val) });
//             log.note("{} function argument defined here", .{fd.tk.loc});
//             return EvalError.TypeMismatched;
//         }
//         const entry = fn_eval_state.mem.fetchPut(fd.name, val) catch unreachable; // TODO account for global variable
//         if (entry) |_| {
//             log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{expr.tk, i, fn_app.func, fd.name });
//             // TODO provide location of previously defined variable
//             return EvalError.Redefined;
//         }
//     }
// }
pub fn evalExpr(ast: Ast, state: *State, expr: Expr) EvalError!Val {
    return switch (expr.data) {
        .atomic => |atomic| evalAtomic(ast, state, atomic),
        .bin_op => @panic("TODO"),
    };
}
pub fn evalAtomic(ast: Ast, state: *State, atomic: Atomic) EvalError!Val {
    return switch (atomic.data) {
        .iden => |s| state.mem.get(s) orelse {
            log.err("{} Undefined identifier: {s}", .{ atomic.tk.loc, s });
            return EvalError.Undefined;
        },
        .string => |s| Val{ .string = s },
        .int => |i| Val{ .int = i },
        .float => |f| Val{ .float = f },
        .bool => |b| Val{ .bool = b },
        .paren => |ei| evalExpr(ast, state, ast.exprs[ei.idx]),
        .fn_app => |fn_app| blk: {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{atomic.tk});
                    return EvalError.TypeMismatched;
                }
                const arg_expr = ast.exprs[fn_app.args[0].idx];
                const val = try evalExpr(ast, state, arg_expr);
                const stdout_file = std.io.getStdOut();
                var stdout = stdout_file.writer();
                stdout.print("{}\n", .{val}) catch return EvalError.IO;
                break :blk Val.void;
            }
            const fn_def = for (ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ atomic.tk, fn_app.func });
                return EvalError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ atomic.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return EvalError.TypeMismatched;
            }
            var fn_eval_state = State.init(state.mem.allocator); // TODO account for global variable
            defer fn_eval_state.deinit();

            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = ast.exprs[fa.idx];
                const val = try evalExpr(ast, state, e);
                if (@intFromEnum(val) != @intFromEnum(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ e.tk.loc, i, fn_app.func, fd.type, @tagName(val) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return EvalError.TypeMismatched;
                }
                const entry = fn_eval_state.mem.fetchPut(fd.name, val) catch unreachable; // TODO account for global variable
                if (entry) |_| {
                    log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{ atomic.tk, i, fn_app.func, fd.name });
                    // TODO provide location of previously defined variable
                    return EvalError.Redefined;
                }
            }

            // TODO eval the function and reset the memory
            for (fn_def.data.body) |di| {
                const stat = ast.stats[di.idx];
                try evalStat(ast, &fn_eval_state, stat);
            }

            break :blk Val.void;
        },
    };
}
