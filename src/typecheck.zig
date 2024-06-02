const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const Loc  = @import("lexer.zig").Loc;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
const Type = Ast.Type;
const Stat = Ast.Stat;
const ProcDef = Ast.ProcDef;
const Op = Ast.Op;
const SemaError = Ast.ParseError || error {NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn};
const Allocator = std.mem.Allocator;


const ScopeItem = struct {
    t: Type,
    i: usize,
    loc: Loc,
};
const Scope = std.StringArrayHashMap(ScopeItem);
const ScopeStack = struct {
    stack: std.ArrayList(Scope),
    pub fn init(alloc: std.mem.Allocator) ScopeStack {
        return ScopeStack{ .stack = std.ArrayList(Scope).init(alloc) };
    }
    pub fn deinit(self: *ScopeStack) void {
        std.debug.assert(self.stack.items.len == 0);
        self.stack.deinit();
    }
    pub fn get(self: ScopeStack, name: []const u8) ?ScopeItem {
        return for (self.stack.items) |scope| {
            if (scope.get(name)) |v| break v;
        } else null;
    }
    // return the old value, if any
    pub fn putTop(self: *ScopeStack, name: []const u8, item: ScopeItem) ?ScopeItem {
        for (self.stack.items) |scope| {
            if (scope.get(name)) |old| return old;
        }
        self.stack.items[self.stack.items.len - 1].putNoClobber(name, item) catch unreachable;
        return null;
    }
    pub fn push(self: *ScopeStack) void {
        self.stack.append(Scope.init(self.stack.allocator)) catch unreachable;
    }
    pub fn pop(self: *ScopeStack) Scope {
        return self.stack.pop();
    }
    pub fn popDiscard(self: *ScopeStack) void {
        var scope = self.pop();
        scope.deinit();
    }
};

const TypeGen = struct {
    a: Allocator,
    ast: *const Ast,
    stack: ScopeStack,
    ret_type: Ast.Type,
};


pub fn typeCheck(ast: *const Ast, a: Allocator) SemaError!void {
    const main_idx = for (ast.defs, 0..) |def, i| {
        if (std.mem.eql(u8, def.data.name, "main")) {
            break i;
        }
    } else {
        log.err("Undefined reference to `main`", .{});
        return SemaError.Undefined;
    };
    const main_proc = ast.defs[main_idx];
    if (main_proc.data.args.len != 0) {
        log.err("{} `main` must have exactly 0 argument", .{main_proc.tk.loc});
        return SemaError.NumOfArgs;
    }
    if (main_proc.data.ret != Type.void) {
        log.err("{} `main` must have return type `void`", .{main_proc.tk.loc});
    }
    var gen = TypeGen {
        .a = a,
        .ast = ast,
        .stack = ScopeStack.init(a),
        .ret_type = undefined,
    };
    defer gen.stack.deinit();
    for (ast.defs) |def| {
        try typeCheckProc(def, &gen);
    }
    
}

pub fn typeCheckProc(proc: ProcDef, gen: *TypeGen) SemaError!void {
    gen.stack.push();
    for (proc.data.args) |arg| {
        if (gen.stack.putTop(arg.name, .{.i = undefined, .t = arg.type, .loc = arg.tk.loc})) |old_var| {
            log.err("{} argument of `{s}` `{s}` shadows outer variable ", .{arg.tk.loc, proc.data.name, arg.name});
            log.note("{} variable previously defined here", .{old_var.loc});
            return SemaError.Redefined;
         } // i is not set until cir
    }
    gen.ret_type = proc.data.ret;
    for (proc.data.body, 0..) |stat, i| {
        if (try typeCheckStat(gen.ast.stats[stat.idx], gen)) |_| {
            if (i != proc.data.body.len - 1) {
                log.err("{} early ret invalids later statement", .{gen.ast.stats[stat.idx].tk.loc});
                return SemaError.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (proc.data.ret != Type.void) {
            log.err("{} `{s}` implicitly return", .{proc.tk.loc, proc.data.name});
            return SemaError.TypeMismatched;
        }
    }
    gen.stack.popDiscard(); // TODO do something with it
    

}
pub fn typeCheckBlock(block: []Ast.StatIdx, gen: *TypeGen) SemaError!?Type {
    gen.stack.push();
    defer gen.stack.popDiscard();

    return for (block, 0..) |stat, i| {
        if (try typeCheckStat(gen.ast.stats[stat.idx], gen)) |ret| {
            if (i != block.len - 1) {
                log.err("{} early ret invalidates later statement", .{gen.ast.stats[stat.idx].tk.loc});
                return SemaError.EarlyReturn;
            } else {
                break ret;
            }

        }
    } else null;
}
pub fn typeCheckStat(stat: Stat, gen: *TypeGen) SemaError!?Type {
    switch (stat.data) {
        .@"if" => |if_stat| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[if_stat.cond.idx], gen);
            if (expr_t != Type.bool) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk.loc, expr_t});
                return SemaError.TypeMismatched;
            }
            const body_t = try typeCheckBlock(if_stat.body, gen);
            const else_t: ?Type = switch (if_stat.else_body) {
                .stats => |stats| try typeCheckBlock(stats, gen),
                .else_if => |else_if| try typeCheckStat(gen.ast.stats[else_if.idx], gen),
                .none => null,
            };
            return if (body_t != null and body_t == else_t) body_t else null; 
        },
        .anon => |expr| {
            _ = try typeCheckExpr(gen.ast.exprs[expr.idx], gen);
            return null;
        },
        .assign => |assign| {
            const t = try typeCheckExpr(gen.ast.exprs[assign.expr.idx], gen);
            const item = gen.stack.get(assign.name) orelse {
                log.err("{} assigning to variable `{s}`, but it is not defined", .{stat.tk.loc, assign.name});
                return SemaError.Undefined;
            };
            if (t != item.t) {
                log.err("{} Assigning to variable `{s}` of type `{}`, but expression has type `{}` ", .{stat.tk.loc, assign.name, t, item.t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[loop.cond.idx], gen);
            if (expr_t != Type.bool) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk, expr_t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .ret => |ret| {
            const ret_t = try typeCheckExpr(gen.ast.exprs[ret.idx], gen);
            if (ret_t != gen.ret_type) {
                log.err("{} function has return type `{}`, but this return statement has `{}`", .{stat.tk.loc, gen.ret_type, ret_t});
                return SemaError.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |var_decl| {
            const t = try typeCheckExpr(gen.ast.exprs[var_decl.expr.idx], gen);
            if (gen.stack.putTop(var_decl.name, .{.i = undefined, .t = t, .loc = stat.tk.loc})) |old_var| {
                log.err("{} `{s}` is already defined", .{stat.tk.loc, var_decl.name});
                log.note("{} previously defined here", .{old_var.loc});
                return SemaError.Redefined;
            }
            return null;
        }
    }

}

pub fn castable(src: Type, dest: Type) bool {
    switch (src) {
        .float => return dest == Type.int,
        .int => return dest != Type.void,
        .string => return dest == Type.int,
        .bool => return dest == Type.int,
        .void => unreachable,
    }
}


pub fn typeCheckAs(lhs: Expr, rhs: Expr, gen: *TypeGen) SemaError!Type {
    const lhs_t = try typeCheckExpr(lhs, gen);

    const rhs_t =
        if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData.iden)
        Type.fromString(rhs.data.atomic.data.iden) orelse {
            log.err("{} Expect type identifier in rhs of `as`", .{rhs.tk.loc});
            return SemaError.TypeMismatched;
        }
    else {
        log.err("{} Expect type identifier in rhs of `as`", .{rhs.tk.loc});
        return SemaError.TypeMismatched;
    };
    if (!castable(lhs_t, rhs_t)) {
        log.err("{} `{}` can not be casted into `{}`", .{ rhs.tk, lhs_t, rhs_t });
        return SemaError.TypeMismatched;
    }
    return rhs_t;
}
pub fn typeCheckRel(lhs: Expr, rhs: Expr, gen: *TypeGen) SemaError!Type {
    const lhs_t = try typeCheckExpr(lhs, gen);
    const rhs_t = try typeCheckExpr(rhs, gen);
    if (lhs_t != rhs_t or lhs_t != Type.int) return SemaError.TypeMismatched;

    return Type.bool;
}
pub fn typeCheckOp(op: Ast.Op, lhs_t: Type, rhs_t: Type, loc: Loc) bool {
    if (op == Ast.Op.as) unreachable;
    if (lhs_t != Type.int and lhs_t != Type.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, lhs_t });
        return false;
    }
    if (rhs_t != Type.int and rhs_t != Type.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, rhs_t });
        return false;
    }

    if (lhs_t != rhs_t) {
        log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{ loc, op, lhs_t, rhs_t });
        return false;
    }
    return true;
}

pub fn typeCheckExpr(expr: Expr, gen: *TypeGen) SemaError!Ast.Type {
    switch (expr.data) {
        .atomic => |atomic| return typeCheckAtomic(atomic, gen),
        .bin_op => |bin_op| {
            const lhs = gen.ast.exprs[bin_op.lhs.idx];
            const rhs = gen.ast.exprs[bin_op.rhs.idx];

            switch (bin_op.op) {
                .as => return typeCheckAs(lhs, rhs, gen),
                .lt, .gt, .eq => return typeCheckRel(lhs, rhs, gen),
                else => {},
            }
            const lhs_t = try typeCheckExpr(lhs, gen);


            const rhs_t = try typeCheckExpr(rhs, gen);

            if (!typeCheckOp(bin_op.op, lhs_t, rhs_t, expr.tk.loc)) return SemaError.TypeMismatched;
            return lhs_t;
            
        },
    }


}

pub fn typeCheckAtomic(atomic: Atomic, gen: *TypeGen) SemaError!Ast.Type {
    switch (atomic.data) {
        .bool => return .bool,
        .float => return .float,
        .int => return .int,
        .string => return .string,
        .iden => |i| {
            if (gen.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{} use of unbound variable `{s}`", .{atomic.tk.loc, i});
                return SemaError.Undefined;
            }
        },
        .paren => |expr| return typeCheckExpr(gen.ast.exprs[expr.idx], gen), 
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{atomic.tk.loc});
                    return SemaError.TypeMismatched;
                }
                _ = try typeCheckExpr(gen.ast.exprs[fn_app.args[0].idx], gen);
                return Type.void;
            }
            const fn_def = for (gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ atomic.tk, fn_app.func });
                return SemaError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ atomic.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return SemaError.TypeMismatched;
            }

            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = gen.ast.exprs[fa.idx];
                const e_type = try typeCheckExpr(e, gen);
                if (e_type != fd.type) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ e.tk.loc, i, fn_app.func, fd.type, @tagName(e_type) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return SemaError.TypeMismatched;
                }

            }

            return fn_def.data.ret;
        }
    }

}


