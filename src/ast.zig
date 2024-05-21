const std = @import("std");
const Lexer = @import("lexer.zig");
const LexerError = Lexer.LexerError;
const TokenType = Lexer.TokenType;
const Token = Lexer.Token;
const Type = enum {
    string,
    int,
    void,
    pub fn fromString(s: []const u8) ?Type {
        const info = @typeInfo(Type).Enum;
        inline for (info.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, s)) return @enumFromInt(i);
        }
        return null;
    }
};
const Val = union(Type) {
    string: []const u8,
    int: isize,
    void,
    pub fn format(value: Val, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (value) {
            .string => |s| _ = try writer.write(s),
            .int => |i| try writer.print("{}", .{i}),
            .void => _ = try writer.write("void"),
        }
    }
};
const VarBind = struct {
    type: Type,
    name: []const u8,
};

pub fn makeID(comptime T: type) type {
    return struct {
        idx: usize,
        comptime {
            _ = T;
        }
    };
}

const ExprIdx = makeID(Expr);
const StatIdx = makeID(Stat);
const DefIdx = makeID(ProcDef);

const Atomic = union(enum) {
    iden: []const u8,
    string: []const u8,
    int: isize,
    paren: ExprIdx,
};
const Expr = union(enum) {
    atomic: Atomic,
    fn_app: FnApp,
    const FnApp = struct {
        func: []const u8,
        args: []const ExprIdx,
    };
};
const Stat = union(enum) {
    anon: ExprIdx,
    var_decl: VarDecl,
    const VarDecl = struct {
        name: []const u8,
        expr: ExprIdx,
    };
};
const ProcDef = struct {
    name: []const u8,
    args: []VarBind,
    body: []StatIdx,
};
const ParseError = error{ UnexpectedToken, EndOfStream, InvalidType } || LexerError;
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
            alloc.free(def.body);
            alloc.free(def.args);
        }
        for (arena.exprs.items) |expr| {
            switch (expr) {
                .fn_app => |fn_app| alloc.free(fn_app.args),
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
        alloc.free(def.body);
        alloc.free(def.args);
    }
    for (ast.exprs) |expr| {
        switch (expr) {
            .fn_app => |fn_app| alloc.free(fn_app.args),
            else => {},
        }
    }
    alloc.free(ast.exprs);
    alloc.free(ast.defs);
    alloc.free(ast.stats);
}
pub fn expectTokenCrit(lexer: *Lexer, kind: TokenType, before: Token) !Token {
    const tok = try lexer.next() orelse {
        std.log.err("{} Expect {} after `{s}`, found eof", .{ before.loc, kind, @tagName(before.data) });
        return ParseError.EndOfStream;
    };
    if (@intFromEnum(tok.data) != @intFromEnum(kind)) {
        std.log.err("{} Expect {} after `{s}`, found {s}", .{ tok.loc, kind, @tagName(before.data), @tagName(tok.data) });
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
        std.log.err("Unknow type: `{s}`", .{type_tk.data.iden});
        return ParseError.InvalidType;
    };
    return VarBind{ .name = iden_tk.data.iden, .type = t };
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
                    std.log.err("{} Expect argument after comma", .{tk.loc});
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
    const proc_tok = try expectTokenRewind(lexer, .proc) orelse return null;
    const iden_tok = try expectTokenCrit(lexer, .fn_app, proc_tok);

    const args_slice = try parseList(VarBind, parseVarBind, lexer, arena);
    errdefer arena.alloc.free(args_slice);

    _ = try expectTokenCrit(lexer, .rparen, iden_tok);
    _ = try expectTokenCrit(lexer, .lcurly, iden_tok);

    var stats = std.ArrayList(StatIdx).init(arena.alloc);
    defer stats.deinit();

    while (try parseStat(lexer, arena)) |stat| {
        stats.append(stat) catch unreachable;
    }
    _ = try expectTokenCrit(lexer, .rcurly, iden_tok);
    const stats_slice = stats.toOwnedSlice() catch unreachable;
    return new(&arena.defs, ProcDef{ .body = stats_slice, .name = iden_tok.data.fn_app, .args = args_slice });
}
pub fn parseStat(lexer: *Lexer, arena: *Arena) ParseError!?StatIdx {
    const head = try lexer.peek() orelse return null;
    switch (head.data) {
        .let => {
            lexer.consume();
            const name_tk = try expectTokenCrit(lexer, .iden, head);
            const colon_tk = try expectTokenCrit(lexer, .colon, name_tk);
            // TODO parse type token
            const eq_tk = try expectTokenCrit(lexer, .eq, colon_tk);
            const expr = try parseExpr(lexer, arena) orelse {
                std.log.err("{} Expect expression after `=`", .{eq_tk.loc});
                return ParseError.UnexpectedToken;
            };
            _ = try expectTokenCrit(lexer, .semi, eq_tk);
            return new(&arena.stats, Stat{ .var_decl = .{ .expr = expr, .name = name_tk.data.iden } });
        },
        else => {
            const expr = try parseExpr(lexer, arena) orelse return null;
            _ = try expectTokenCrit(lexer, .semi, Token{ .data = .semi, .loc = lexer.loc });
            return new(&arena.stats, Stat{ .anon = expr });
        },
    }
    unreachable;
}
pub fn parseFnApp(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {
    const iden_tok = try expectTokenRewind(lexer, .fn_app) orelse return null;
    const args = try parseList(ExprIdx, parseExpr, lexer, arena);
    errdefer arena.alloc.free(args);

    _ = try expectTokenCrit(lexer, .rparen, iden_tok);
    return new(&arena.exprs, Expr{ .fn_app = .{ .args = args, .func = iden_tok.data.fn_app } });
}
pub fn parseExpr(lexer: *Lexer, arena: *Arena) ParseError!?ExprIdx {
    if (try parseFnApp(lexer, arena)) |expr| return expr;
    if (try parseAtomic(lexer, arena)) |atomic| return new(&arena.exprs, Expr{ .atomic = atomic });

    return null;
}
pub fn parseAtomic(lexer: *Lexer, arena: *Arena) ParseError!?Atomic {
    const tok = try lexer.peek() orelse return null;
    switch (tok.data) {
        .string => |s| {
            lexer.consume();
            return Atomic{ .string = s };
        },
        .iden => |s| {
            lexer.consume();
            return Atomic{ .iden = s };
        },
        .int => |i| {
            lexer.consume();
            return Atomic{ .int = i };
        },
        .lparen => {
            const lparen = lexer.next() catch unreachable orelse unreachable;
            const expr = try parseExpr(lexer, arena) orelse {
                std.log.err("{} Expect expr after `(`", .{lparen.loc});
                return null;
            };
            // TODO use last tok in exprression
            _ = try expectTokenCrit(lexer, .rparen, tok);
            return Atomic{ .paren = expr };
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
pub fn eval(ast: Ast, alloc: std.mem.Allocator) void {
    const main_idx = for (ast.defs, 0..) |def, i| {
        if (std.mem.eql(u8, def.name, "main")) {
            break i;
        }
    } else {
        @panic("undefined reference to `main`");
    };
    const main_fn = ast.defs[main_idx];
    var state = State.init(alloc);
    defer state.deinit();
    for (main_fn.body) |stat| {
        evalStat(ast, &state, ast.stats[stat.idx]);
    }
}
pub fn evalStat(ast: Ast, state: *State, stat: Stat) void {
    switch (stat) {
        .anon => |expr_idx| {
            const expr = ast.exprs[expr_idx.idx];
            _ = evalExpr(ast, state, expr);
        },
        .var_decl => |var_decls| {
            const val = evalExpr(ast, state, ast.exprs[var_decls.expr.idx]);
            const entry = state.mem.fetchPut(var_decls.name, val) catch unreachable;
            if (entry) |_| {
                std.log.err("identifier redefined: `{s}`", .{var_decls.name});
                @panic("Invalid Program");
            }
        },
    }
}
pub fn evalExpr(ast: Ast, state: *State, expr: Expr) Val {
    return switch (expr) {
        .fn_app => |fn_app| blk: {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) @panic("`print` must have exactly one argument");
                const arg_expr = ast.exprs[fn_app.args[0].idx];
                const val = evalExpr(ast, state, arg_expr);
                std.debug.print("{}\n", .{val});
                break :blk Val.void;
            }
            const fn_def = for (ast.defs) |def| {
                if (std.mem.eql(u8, def.name, fn_app.func)) break def;
            } else {
                std.log.err("Undefined function `{s}`", .{fn_app.func});
                @panic("Invalid Program");
            };
            if (fn_def.args.len != fn_app.args.len) {
                std.log.err("`{s}` expected {} arguments, got {}", .{ fn_app.func, fn_def.args.len, fn_app.args.len });
            }
            var fn_eval_state = State.init(state.mem.allocator); // TODO account for global variable
            defer fn_eval_state.deinit();

            for (fn_def.args, fn_app.args, 0..) |fd, fa, i| {
                const e = ast.exprs[fa.idx];
                const val = evalExpr(ast, state, e);
                if (@intFromEnum(val) != @intFromEnum(fd.type)) {
                    std.log.err("{} argument of `{s}` expected type `{}`, got type `{s}`", .{ i, fn_app.func, fd.type, @tagName(val) });
                    @panic("Invalid Program");
                }
                const entry = fn_eval_state.mem.fetchPut(fd.name, val) catch unreachable; // TODO account for global variable
                if (entry) |_| {
                    std.log.err("{} argument of `{s}` shadows outer variable `{s}`", .{ i, fn_app.func, fd.name });
                    @panic("Invalid Program");
                }
            }

            // TODO eval the function and reset the memory
            for (fn_def.body) |di| {
                const stat = ast.stats[di.idx];
                evalStat(ast, &fn_eval_state, stat);
            }

            break :blk Val.void;
        },
        .atomic => |atomic| evalAtomic(ast, state, atomic),
    };
}
pub fn evalAtomic(ast: Ast, state: *State, atomic: Atomic) Val {
    return switch (atomic) {
        .iden => |s| state.mem.get(s) orelse {
            std.log.err("Undefined identifier: {s}", .{s});
            @panic("Invalid Program");
        },
        .string => |s| Val{ .string = s },
        .int => |i| Val{ .int = i },
        .paren => |ei| evalExpr(ast, state, ast.exprs[ei.idx]),
    };
}
