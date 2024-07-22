const std = @import("std");
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const LexerError = Lexer.LexerError;
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;
const LangType = @import("type.zig");
const Type = LangType.Type;
const TypeExpr = LangType.TypeExpr;
const VarBind = LangType.VarBind;

pub const Lit = union(enum) {
    string: []const u8,
    int: isize,
    float: f64,
    bool: bool,
    pub fn format(value: Lit, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .string => |s| _ = try writer.write(s),
            inline .int, .bool, .float => |x| try writer.print("{}", .{x}),
        }
    }
};


pub const NamedInit = struct {
    expr: ExprIdx,
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
pub const DefIdx = makeID(TopDef);
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

    type: TypeExpr,
    addr: ExprIdx,

};
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
    pub fn infixBP(self: Op) ?[2]u8 {
        return switch (self) {
            .assign => .{1, 1},
            .eq, .lt, .gt => .{3, 3},
            .plus, .minus => .{5, 6},
            .times, .div, .mod => .{7, 8},
            .as => .{9, 10},
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
    pub fn nonAssoc(self: Op) bool {
        return switch (self) {
            .assign, .eq, .lt, .gt => true,
            else => false,
        };

    }
};
pub const ExprData = union(enum) {
    atomic: Atomic,
    bin_op: BinOp,
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
        rhs: []const u8,
    };
    pub const ArrayAccess = struct {
        lhs: ExprIdx,
        rhs: ExprIdx,
    };
    pub const FnApp = struct {
        func: []const u8,
        args: []const ExprIdx,
    };
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
        t: ?TypeExpr,
        expr: ExprIdx,
    };
    pub const Assign = struct {
        left_value: ExprIdx, // has to be left value, ensures during not here but during typecheck
        expr: ExprIdx,
    };
};
pub const TopDefData = union(enum) {
    proc: ProcDef,
    type: VarBind,
};
pub const ProcDef = struct {
    name: []const u8,
    args: []VarBind,
    body: []StatIdx,
    ret: TypeExpr,
};
pub const Atomic = nodeFromData(AtomicData);
pub const Expr = nodeFromData(ExprData);
pub const Stat = nodeFromData(StatData);
pub const TopDef = nodeFromData(TopDefData);
pub const ParseError = error{ UnexpectedToken, EndOfStream, InvalidType } || LexerError;
exprs: []Expr,
stats: []Stat,

defs: []TopDef,
// top: []ProcDef,
const Exprs = std.ArrayList(Expr);
const Defs = std.ArrayList(TopDef);
const Stats = std.ArrayList(Stat);
const Arena = struct {
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    exprs: Exprs,
    defs: Defs,
    stats: Stats,
};
const Ast = @This();
pub fn new(array: anytype, e: anytype) makeID(@TypeOf(e)) {
    array.append(e) catch @panic("out of memory");
    return makeID(@TypeOf(e)){ .idx = array.items.len - 1 };
}




pub fn parse(lexer: *Lexer, alloc: std.mem.Allocator, a: std.mem.Allocator) ParseError!Ast {
    var arena = Arena{
        .alloc = alloc,
        .exprs = Exprs.init(alloc),
        .defs = Defs.init(alloc),
        .stats = Stats.init(alloc),
        .arena = a,
    };
    errdefer {
        for (arena.defs.items) |def| {
            switch (def.data) {
                .proc => |proc| {
                    alloc.free(proc.body);
                    alloc.free(proc.args);
                },
                else => {},
            }

        }
        for (arena.exprs.items) |expr| {
            switch (expr.data) {
                .fn_app => |fn_app| alloc.free(fn_app.args),
                else => {},
            }
        }
        arena.exprs.deinit();
        arena.defs.deinit();
        arena.stats.deinit();
    }
    while (try parseTopDef(lexer, &arena)) |_| {}
    return Ast {
        .exprs = arena.exprs.toOwnedSlice() catch unreachable,
        .stats = arena.stats.toOwnedSlice() catch unreachable,
        .defs = arena.defs.toOwnedSlice() catch unreachable,
    };
}
pub fn deinit(ast: *Ast, alloc: std.mem.Allocator) void {
    for (ast.defs) |def| {
        switch (def.data) {
            .proc => |proc| {
                alloc.free(proc.body);
                alloc.free(proc.args);
            },
            else => {},
        }

    }
    for (ast.exprs) |expr| {
        switch (expr.data) {
            // .atomic => |atomic| switch (atomic.data) {
            //     .type => |te| if (te == TypeExpr.plural) alloc.free(te.plural),
            //     else => {},
            // },
            .fn_app => |fn_app| alloc.free(fn_app.args),
            .array => |array| alloc.free(array),
            .tuple => |tuple| alloc.free(tuple),
            .named_tuple => |tuple| alloc.free(tuple),

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
    const tok = lexer.next() catch |e| {
        log.err("{} Expect {} after `{s}`, but encounter {} in lexe ", .{ before.loc, kind, @tagName(before.data), e });
        return ParseError.EndOfStream;
    };
    if (tok.data != kind) {
        log.err("{} Expect {} after `{s}`, found {s}", .{ tok.loc, kind, @tagName(before.data), @tagName(tok.data) });
        return ParseError.UnexpectedToken;
    }
    return tok;
}
pub fn expectTokenRewind(lexer: *Lexer, kind: TokenType) !?Token {
    const tok = try lexer.peek();
    if (tok.data != kind) {
        return null;
    }
    _ = lexer.next() catch unreachable;
    return tok;
}
pub fn parseVarBind(lexer: *Lexer, arena: *Arena) ParseError!?VarBind {
    const iden_tk = try expectTokenRewind(lexer, .iden) orelse return null;
    const colon_tk = try expectTokenCrit(lexer, .colon, iden_tk);
    const t = try parseTypeExpr(lexer, arena) orelse {
        log.err("{} Expect type expression after `:`", .{colon_tk.loc});
        return ParseError.UnexpectedToken;
    };
    return VarBind{ .name = iden_tk.data.iden, .type = t, .tk = iden_tk };
}
pub fn parseList(comptime T: type, f: fn (*Lexer, *Arena) ParseError!?T, lexer: *Lexer, arena: *Arena, alloc: std.mem.Allocator) ParseError![]T {
    var list = std.ArrayList(T).init(alloc);
    defer list.deinit();
    const first = try f(lexer, arena) orelse return (list.toOwnedSlice() catch unreachable);
    list.append(first) catch unreachable;
    while (true) {
        const tk = try lexer.peek();
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
pub fn parseVarBindField(lexer: *Lexer, arena: *Arena) ParseError!?VarBind {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const bind = try parseVarBind(lexer, arena) orelse {
        log.err("{} Expect field decleration after dot", .{dot.loc});
        return ParseError.UnexpectedToken;
    };
    return bind;
}
pub fn parseType(lexer: *Lexer, arena: *Arena) ParseError!?Type {
    const tk = try lexer.peek();
    const rest_type = Type.fromToken(tk) orelse 
        switch (tk.data) {
            .lbrack => {
                lexer.consume();
                const size = try expectTokenCrit(lexer, .int, tk);
                _ = try expectTokenCrit(lexer, .rbrack, size);
               return Type {.array = @intCast(size.data.int)};
            },
            .lcurly => {
                lexer.consume();
                if ((try lexer.peek()).data == .dot) {
                    const tuple = try parseList(VarBind, parseVarBindField, lexer, arena, arena.arena);
                    _  = try expectTokenCrit(lexer, .rcurly, tk);
                    return Type {.named = tuple};
                } else {
                    const tuple = try parseList(TypeExpr, parseTypeExpr, lexer, arena, arena.arena);
                    _  = try expectTokenCrit(lexer, .rcurly, tk);
                    return Type {.tuple = tuple};
                }

            },
            else => return null
    };
    lexer.consume();
    return rest_type;
}
pub fn parseTypeExpr(lexer: *Lexer, arena: *Arena) ParseError!?TypeExpr {
    const first_type = try parseType(lexer, arena) orelse return null;
    var list = std.ArrayList(Type).init(arena.arena);
    defer list.deinit();
    if (!first_type.isTerm()) {
        while (try parseType(lexer, arena)) |t| {
            list.append(t) catch unreachable;
            if (t.isTerm()) break;
        }
    }
       
    if (list.items.len == 0) {
        return TypeExpr {.singular = first_type};
    } else {
        list.insert(0, first_type) catch unreachable;
        return TypeExpr {.plural = list.toOwnedSlice() catch unreachable};
    }
    
    
}


pub fn parseTopDef(lexer: *Lexer, arena: *Arena) ParseError!?DefIdx {
    const head = try lexer.peek();
    switch (head.data) {
        .proc, .func => {
            lexer.consume();
            const iden_tok = try expectTokenCrit(lexer, .iden, head);
            const lparen_tok = try expectTokenCrit(lexer, .lparen, iden_tok);

            const args_slice = try parseList(VarBind, parseVarBind, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(args_slice);

            const rparen = try expectTokenCrit(lexer, .rparen, lparen_tok);
            const ret_type: TypeExpr = if (head.data == TokenType.func) blk: {
                const colon = try expectTokenCrit(lexer, .colon, rparen);
                const ret_t = try parseTypeExpr(lexer, arena) orelse {
                    log.err("{} Expects type expression after colon", .{colon.loc});
                    return ParseError.UnexpectedToken;
                };
                break :blk ret_t;
            } else TypeExpr {.singular = .void};
            const stats = try parseBlock(lexer, arena, rparen);
            errdefer arena.alloc.free(stats);
            return new(
                &arena.defs,
                
                TopDef { 
                    .tk = rparen,
                    .data = .{.proc =  ProcDef {
                        .body = stats, .name = iden_tok.data.iden, .args = args_slice, .ret = ret_type }
                    }},
            );
        },
        .type => {
            lexer.consume();
            const name = try expectTokenCrit(lexer, .iden, head);
            const colon = try expectTokenCrit(lexer, .colon, name);
            const type_expr = try parseTypeExpr(lexer, arena) orelse {
                log.err("{} Expects type expression after colon", .{colon.loc});
                return ParseError.UnexpectedToken;
            };
            const semi = try expectTokenCrit(lexer, .semi, colon);
            return new(&arena.defs, 
                TopDef {
                    .tk = semi,
                    .data = .{.type = .{.tk = semi, .name = name.data.iden, .type = type_expr}},
                }
            );

        },
        else => return null,
    }

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
pub fn parseOp(tk: Token) ?Op {
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
        .lparen => .lparen,
        .dot => .field,
        .assign => .assign,
        .lbrack => .lbrack,
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
    if (try parseExpr(lexer, arena)) |expr| {

        const semi_tk = try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
        switch (arena.exprs.items[expr.idx].data) {
            .bin_op => |bin_op| {
                if (bin_op.op == .assign) {
                    return new(&arena.stats, Stat {
                        .data = .{.assign = .{ .expr = bin_op.rhs, .left_value = bin_op.lhs },}, .tk = arena.exprs.items[bin_op.lhs.idx].tk,
                    });
                }
            },
            else => {},
        }
        return new(
            &arena.stats,
            Stat{
                .data = .{ .anon = expr },
                .tk = semi_tk,
            },
        );
    }

    const head = try lexer.peek();
    switch (head.data) {
        .let => {
            lexer.consume();
            const name_tk = try expectTokenCrit(lexer, .iden, head);
            const colon_tk = try expectTokenCrit(lexer, .colon, name_tk);
            const t = try parseTypeExpr(lexer, arena);
            const eq_tk = try expectTokenCrit(lexer, .assign, colon_tk);
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expression after `=`", .{eq_tk.loc});
                return ParseError.UnexpectedToken;
            };
            const semi_tk =  try expectTokenCrit(lexer, .semi, arena.exprs.items[expr.idx].tk);
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
            const loop = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, arena) orelse new(
                &arena.exprs,
                Expr{ .data = .{ .atomic = .{ .data = .{ .bool = true }, .tk = loop } }, .tk = loop },
            );
            const stats = try parseBlock(lexer, arena, arena.exprs.items[expr.idx].tk);
            errdefer arena.alloc.free(stats);
            return new(&arena.stats, Stat{ .data = .{ .loop = .{ .cond = expr, .body = stats } }, .tk = loop });
        },
        else => return null,
    }
    unreachable;
}
pub fn parseNamedInit(lexer: *Lexer, arena: *Arena) ParseError!?NamedInit {
    const dot = try expectTokenRewind(lexer, .dot) orelse return null;
    const name = try expectTokenCrit(lexer, .iden, dot);
    const assign = try expectTokenCrit(lexer, .assign, name);
    const expr = try parseExpr(lexer, arena) orelse {
        log.err("{} Expect exprssion after `=`", .{assign.loc});
        return ParseError.UnexpectedToken;
    };
    return NamedInit {.expr = expr, .name = name.data.iden, .tk = arena.exprs.items[expr.idx].tk};
}
pub fn parseExpr(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {

    return parseExprClimb(
        lexer,
        arena,
        0,
    );
}
pub fn parseExprClimb(lexer: *Lexer, arena: *Arena, min_bp: u8) ParseError!?ExprIdx {
    var lhs = if (try expectTokenRewind(lexer, .lbrack)) |lbrack| blk: {
        const list = try parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc);
        errdefer arena.alloc.free(list);
        const rbrack = try expectTokenCrit(lexer, .rbrack, if (list.len > 1) arena.exprs.items[list[list.len - 1].idx].tk else lbrack);
        break :blk new(&arena.exprs, Expr {.data = .{ .array = list }, .tk = rbrack});
    } else if (try expectTokenRewind(lexer, .lcurly)) |lt| blk: {
        const head = try lexer.peek();
        if (head.data == .dot) {
            const list = try parseList(NamedInit, parseNamedInit, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(list);
            const rcurly = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) list[list.len - 1].tk else lt);
            break :blk new(&arena.exprs, Expr {.data = .{ .named_tuple = list }, .tk = rcurly});
        } else {
            const list = try parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc);
            errdefer arena.alloc.free(list);
            const gt = try expectTokenCrit(lexer, .rcurly, if (list.len > 1) arena.exprs.items[list[list.len - 1].idx].tk else lt);
            break :blk new(&arena.exprs, Expr {.data = .{ .tuple = list }, .tk = gt});
        }
        
    } else
    try parseAtomicExpr(lexer, arena) orelse return null;
    var peek = try lexer.peek();

    while (parseOp(peek)) |op| {
        const expr =  if (op.postfixBP()) |lbp| expr_blk: {
            if (lbp < min_bp) break;
            lexer.consume();
            break :expr_blk switch (op) {
                .lparen => {
                    const exprs = parseList(ExprIdx, parseExpr, lexer, arena, arena.alloc) catch |e| {
                        log.err("{} Expect list of expression after `{}`", .{peek.loc, op});
                        return e;
                    };
                    errdefer arena.alloc.free(exprs);
                    const exprs_tk  = if (exprs.len > 1) arena.exprs.items[exprs[exprs.len - 1].idx].tk else peek;
                    const rparen = expectTokenCrit(lexer, .rparen, peek) catch |e| {
                        log.err("{} Unclosed parenthesis", .{exprs_tk.loc});
                        log.note("{} Left paren starts here", .{peek.loc});
                        return e;
                    };
                    const lhs_exp = arena.exprs.items[lhs.idx];
                    if (lhs_exp.data != ExprData.atomic and lhs_exp.data.atomic.data != AtomicData.iden) {
                        log.err("{} Lhs of function application has to be identifier", .{lhs_exp.tk.loc});
                        return ParseError.UnexpectedToken;
                    }
                    break :expr_blk Expr {.data = .{.fn_app = .{ .func = lhs_exp.data.atomic.data.iden, .args = exprs }}, .tk = rparen};
                },
                .field => {
                    const field = try lexer.next();
                    break :expr_blk switch (field.data) {
                        .ampersand => Expr {.data = .{ .addr_of = lhs }, .tk = field},
                        .times => Expr {.data = .{ .deref = lhs }, .tk = field},
                        .iden => |i| Expr {.data = .{ .field = .{ .lhs = lhs, .rhs = i }, }, .tk = field},
                        else => {
                            log.err("{} Unexpected token `{}` after field access `.`", .{field.loc, field.data});
                            return ParseError.UnexpectedToken;
                        }
                    };
                },
                .lbrack => {
                    const index_expr = try parseExpr(lexer, arena) orelse {
                        log.err("{} Expect expression after `[`", .{peek.loc});
                        return ParseError.UnexpectedToken;
                    };
                    const rbrack = try expectTokenCrit(lexer, .rbrack, arena.exprs.items[index_expr.idx].tk);
                    break :expr_blk Expr {.data = .{.array_access = .{.lhs = lhs, .rhs = index_expr}}, .tk = rbrack};
                },
                else => unreachable,
            };
          
        } else if (op.infixBP()) |bp| expr_blk: {
            const lbp, const rbp = bp;
            if (lbp < min_bp or (op.nonAssoc() and lbp == min_bp)) break;
            lexer.consume();
            const rhs = try parseExprClimb(lexer, arena, rbp) orelse {
                log.err("{} Expect expression after `{}`", .{ peek.loc, op });
                return ParseError.UnexpectedToken;
            };
            break :expr_blk Expr{ .data = ExprData{ .bin_op = .{ .lhs = lhs, .rhs = rhs, .op = op } }, .tk = arena.exprs.items[rhs.idx].tk };
        } else {
            break;
        };
        lhs = new(&arena.exprs, expr);
        peek = try lexer.peek();
    }
    return lhs;
}
pub fn parseAtomicExpr(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {
    const atomic = try parseAtomic(lexer, arena) orelse return null;
    return new(&arena.exprs, Expr{ .data = .{ .atomic = atomic }, .tk = atomic.tk });
}
pub fn parseAtomic(lexer: *Lexer, arena: *Arena) ParseError!?Atomic {
    const tok = try lexer.peek();
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
            const lparen = lexer.next() catch unreachable;
            const expr = try parseExpr(lexer, arena) orelse {
                log.err("{} Expect expr after `(`", .{lparen.loc});
                return null;
            };
            const rparen = try expectTokenCrit(lexer, .rparen, arena.exprs.items[expr.idx].tk);
            return Atomic{ .data = .{ .paren = expr }, .tk = rparen };
        },
        else => return Atomic {.data = .{ .type = try parseTypeExpr(lexer, arena) orelse return null}, .tk = tok},
    }
}
// const State = struct {
//     mem: Mem,
//     pub const Mem = std.StringHashMap(Val);

//     pub fn init(alloc: std.mem.Allocator) State {
//         return State{ .mem = Mem.init(alloc) };
//     }
//     pub fn deinit(self: *State) void {
//         self.mem.deinit();
//     }
//     pub fn clone(self: State) State {
//         return State{ .mem = self.mem.clone() catch unreachable };
//     }
// };
// pub const EvalError = error{
//     Undefined,
//     Redefined,
//     IO,
//     TypeMismatched,
// };
// pub fn eval(ast: Ast, alloc: std.mem.Allocator) EvalError!void {
//     const main_idx = for (ast.defs, 0..) |def, i| {
//         if (std.mem.eql(u8, def.data.name, "main")) {
//             break i;
//         }
//     } else {
//         log.err("Undefined reference to `main`", .{});
//         return EvalError.Undefined;
//     };
//     const main_fn = ast.defs[main_idx];
//     var state = State.init(alloc);
//     defer state.deinit();
//     for (main_fn.data.body) |stat| {
//         try evalStat(ast, &state, ast.stats[stat.idx]);
//     }
// }
// pub fn evalStat(ast: Ast, state: *State, stat: Stat) EvalError!void {
//     switch (stat.data) {
//         .anon => |expr_idx| {
//             const expr = ast.exprs[expr_idx.idx];
//             _ = try evalExpr(ast, state, expr);
//         },
//         .var_decl => |var_decls| {
//             const val = try evalExpr(ast, state, ast.exprs[var_decls.expr.idx]);
//             const entry = state.mem.fetchPut(var_decls.name, val) catch unreachable;
//             if (entry) |_| {
//                 log.err("{} Identifier redefined: `{s}`", .{ stat.tk.loc, var_decls.name });
//                 // TODO provide location of previously defined variable
//                 return EvalError.Undefined;
//             }
//         },
//         inline .@"if",
//         .ret,
//         .assign,
//         .loop,
//         => |_| @panic("TODO"),
//     }
// }
// // pub fn typeCheckFn(ast: Ast, fn_app_expr: Expr, fn_def_stat: ProcDef) !void {
// //     const fn_app = fn_app_expr.data.fn_app;
// //     const fn_def = fn_def_stat;

// //     if (fn_def.data.args.len != fn_app.args.len) {
// //         log.err("{} `{s}` expected {} arguments, got {}", .{fn_app_expr.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
// //         log.note("{} function argument defined here", .{fn_def.tk.loc});
// //         return EvalError.TypeMismatched;
// //     }
// //     for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
// //         const e = ast.exprs[fa.idx];
// //         const val = try evalExpr(ast, state, e);
// //         if (@intFromEnum(val) != @intFromEnum(fd.type)) {
// //             log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{e.tk.loc, i, fn_app.func, fd.type, @tagName(val) });
// //             log.note("{} function argument defined here", .{fd.tk.loc});
// //             return EvalError.TypeMismatched;
// //         }
// //         const entry = fn_eval_state.mem.fetchPut(fd.name, val) catch unreachable; // TODO account for global variable
// //         if (entry) |_| {
// //             log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{expr.tk, i, fn_app.func, fd.name });
// //             // TODO provide location of previously defined variable
// //             return EvalError.Redefined;
// //         }
// //     }
// // }
// pub fn evalExpr(ast: Ast, state: *State, expr: Expr) EvalError!Val {
//     return switch (expr.data) {
//         .atomic => |atomic| evalAtomic(ast, state, atomic),
//         .bin_op => @panic("TODO"),
//     };
// }
// pub fn evalAtomic(ast: Ast, state: *State, atomic: Atomic) EvalError!Val {
//     return switch (atomic.data) {
//         .iden => |s| state.mem.get(s) orelse {
//             log.err("{} Undefined identifier: {s}", .{ atomic.tk.loc, s });
//             return EvalError.Undefined;
//         },
//         .string => |s| Val{ .string = s },
//         .int => |i| Val{ .int = i },
//         .float => |f| Val{ .float = f },
//         .bool => |b| Val{ .bool = b },
//         .paren => |ei| evalExpr(ast, state, ast.exprs[ei.idx]),
//         .fn_app => |fn_app| blk: {
//             if (std.mem.eql(u8, fn_app.func, "print")) {
//                 if (fn_app.args.len != 1) {
//                     std.log.err("{} builtin function `print` expects exactly one argument", .{atomic.tk});
//                     return EvalError.TypeMismatched;
//                 }
//                 const arg_expr = ast.exprs[fn_app.args[0].idx];
//                 const val = try evalExpr(ast, state, arg_expr);
//                 const stdout_file = std.io.getStdOut();
//                 var stdout = stdout_file.writer();
//                 stdout.print("{}\n", .{val}) catch return EvalError.IO;
//                 break :blk Val.void;
//             }
//             const fn_def = for (ast.defs) |def| {
//                 if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
//             } else {
//                 log.err("{} Undefined function `{s}`", .{ atomic.tk, fn_app.func });
//                 return EvalError.Undefined;
//             };
//             if (fn_def.data.args.len != fn_app.args.len) {
//                 log.err("{} `{s}` expected {} arguments, got {}", .{ atomic.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
//                 log.note("{} function argument defined here", .{fn_def.tk.loc});
//                 return EvalError.TypeMismatched;
//             }
//             var fn_eval_state = State.init(state.mem.allocator); // TODO account for global variable
//             defer fn_eval_state.deinit();

//             for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
//                 const e = ast.exprs[fa.idx];
//                 const val = try evalExpr(ast, state, e);
//                 if (@intFromEnum(val) != @intFromEnum(fd.type)) {
//                     log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ e.tk.loc, i, fn_app.func, fd.type, @tagName(val) });
//                     log.note("{} function argument defined here", .{fd.tk.loc});
//                     return EvalError.TypeMismatched;
//                 }
//                 const entry = fn_eval_state.mem.fetchPut(fd.name, val) catch unreachable; // TODO account for global variable
//                 if (entry) |_| {
//                     log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{ atomic.tk, i, fn_app.func, fd.name });
//                     // TODO provide location of previously defined variable
//                     return EvalError.Redefined;
//                 }
//             }

//             // TODO eval the function and reset the memory
//             for (fn_def.data.body) |di| {
//                 const stat = ast.stats[di.idx];
//                 try evalStat(ast, &fn_eval_state, stat);
//             }

//             break :blk Val.void;
//         },
//     };
// }
