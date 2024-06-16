const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const Loc  = @import("lexer.zig").Loc;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
const Type = Ast.Type;
const TypeExpr = Ast.TypeExpr;
const Stat = Ast.Stat;
const ProcDef = Ast.ProcDef;
const Op = Ast.Op;
const SemaError = Ast.ParseError || error {NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn, RightValue, Unresolvable, MissingField};
const Allocator = std.mem.Allocator;


const ScopeItem = struct {
    t: TypeExpr,
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
    arena: Allocator,
    ast: *const Ast,
    stack: ScopeStack,
    ret_type: Ast.TypeExpr,
};

pub fn validType(te: TypeExpr) bool {
    return switch (te) {
        .singular => |t| blk: {
            if (t == Type.ptr) {
                log.err("Singualr type can not be `ptr`", .{});
                break :blk false;
            } else {
                break :blk true;
            }
        },
        .plural => |ts| ts.len >= 2 and for (ts, 0..) |t, i| {
            if (t != Type.ptr and t != Type.array and i != ts.len - 1) {
                log.err("Terminal type `{}` must only be at the end", .{t});
                break false;
            }
        } else true,
    };
}
pub fn reportValidType(te: TypeExpr, loc: Loc) SemaError!void {
    errdefer log.err("{} `{}` is not valid type", .{loc, te});
    if (!validType(te)) return SemaError.InvalidType;
}


pub fn typeCheck(ast: *const Ast, a: Allocator, arena: Allocator) SemaError!void {
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
    if (!main_proc.data.ret.isType(Type.void)) {
        log.err("{} `main` must have return type `void`, found {}", .{main_proc.tk.loc, main_proc.data.ret});
    }
    var gen = TypeGen {
        .a = a,
        .arena = arena,
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
    defer gen.stack.popDiscard(); // TODO do something with it
    for (proc.data.args) |arg| {
        try reportValidType(arg.type, proc.tk.loc);
        if (gen.stack.putTop(arg.name, .{.i = undefined, .t = arg.type, .loc = arg.tk.loc})) |old_var| {
            log.err("{} argument of `{s}` `{s}` shadows outer variable ", .{arg.tk.loc, proc.data.name, arg.name});
            log.note("{} variable previously defined here", .{old_var.loc});
            return SemaError.Redefined;
         } // i is not set until cir
    }
    try reportValidType(proc.data.ret, proc.tk.loc);
    gen.ret_type = proc.data.ret;
    for (proc.data.body, 0..) |stat, i| {
        if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |_| {
            if (i != proc.data.body.len - 1) {
                log.err("{} early ret invalids later statement", .{gen.ast.stats[stat.idx].tk.loc});
                return SemaError.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (!proc.data.ret.isType(.void)) {
            log.err("{} `{s}` implicitly return", .{proc.tk.loc, proc.data.name});
            return SemaError.TypeMismatched;
        }
    }
    

}
pub fn typeCheckBlock(block: []Ast.StatIdx, gen: *TypeGen) SemaError!?TypeExpr {
    gen.stack.push();
    defer gen.stack.popDiscard();

    return for (block, 0..) |stat, i| {
        if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |ret| {
            if (i != block.len - 1) {
                log.err("{} early ret invalidates later statement", .{gen.ast.stats[stat.idx].tk.loc});
                return SemaError.EarlyReturn;
            } else {
                break ret;
            }

        }
    } else null;
}
// assume variable in this expression exists in the current scope
pub fn isLeftValue(expr: Expr, gen: *TypeGen) bool {
    return switch (expr.data) {
        .atomic => |atomic| {
             switch (atomic.data) {
                .iden => true,
                else => false,
             }
        },
        .deref => |deref| isLeftValue(gen.ast.exprs[deref.idx], gen),
    };
}
pub fn typeCheckStat(stat: *Stat, gen: *TypeGen) SemaError!?TypeExpr {
    switch (stat.data) {
        .@"if" => |if_stat| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[if_stat.cond.idx], gen);
            if (!expr_t.isType(.bool)) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk.loc, expr_t});
                return SemaError.TypeMismatched;
            }
            const body_t = try typeCheckBlock(if_stat.body, gen);
            const else_t: ?TypeExpr = switch (if_stat.else_body) {
                .stats => |stats| try typeCheckBlock(stats, gen),
                .else_if => |else_if| try typeCheckStat(&gen.ast.stats[else_if.idx], gen),
                .none => null,
            };
            return if (body_t != null and else_t != null and body_t.?.eq(else_t.?)) body_t else null; 
        },
        .anon => |expr| {
            _ = try typeCheckExpr(gen.ast.exprs[expr.idx], gen);
            return null;
        },
        .assign => |assign| {
            const right_t = try typeCheckExpr(gen.ast.exprs[assign.expr.idx], gen);
            const left_t = try typeCheckExpr(gen.ast.exprs[assign.left_value.idx], gen);
            if (!right_t.eq(left_t)) {
                log.err("{} Assigning to lhs of type `{}`, but rhs has type `{}`", .{stat.tk.loc, left_t, right_t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[loop.cond.idx], gen);
            if (!expr_t.isType(.bool)) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk, expr_t});
                return SemaError.TypeMismatched;
            }
            for (loop.body) |si| {
                _ = try typeCheckStat(&gen.ast.stats[si.idx], gen);
            }
            return null;
        },
        .ret => |ret| {
            const ret_t = try typeCheckExpr(gen.ast.exprs[ret.idx], gen);
            if (!ret_t.eq(gen.ret_type)) {
                log.err("{} function has return type `{}`, but this return statement has `{}`", .{stat.tk.loc, gen.ret_type, ret_t});
                return SemaError.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            const t = try typeCheckExpr(gen.ast.exprs[var_decl.expr.idx], gen);
            if (var_decl.t) |strong_t| {
                try reportValidType(strong_t, stat.tk.loc);
                if (!strong_t.eq(t)) {
                    log.err("{} mismatched type in variable decleration and expression", .{stat.tk.loc});
                    return SemaError.TypeMismatched;
                }
            } else {
                var_decl.t = t;
            }
            if (gen.stack.putTop(var_decl.name, .{.i = undefined, .t = t, .loc = stat.tk.loc})) |old_var| {
                log.err("{} `{s}` is already defined", .{stat.tk.loc, var_decl.name});
                log.note("{} previously defined here", .{old_var.loc});
                return SemaError.Redefined;
            }
            return null;
        }
    }

}

pub fn castable(src: TypeExpr, dest: TypeExpr) bool {
    return switch (src) {
        .singular => |t| switch (t) {
            .float => dest.first().eq(.int),
            .int => dest.first() != .void,
            .char => dest.first().eq(.int),
            .bool => dest.first().eq(.int),
            .void => false,
            .ptr, .array => unreachable,
        },
        .plural => |ts| switch (ts[0]) {
            .ptr => dest.first().eq(.int) or dest.first().eq(.ptr),
            else => {
                log.err("{} {}", .{src, dest});
                unreachable;
            },
            .array => false,
        }

    };
}


pub fn typeCheckAs(lhs: Expr, rhs: Expr, gen: *TypeGen) SemaError!TypeExpr {
    const lhs_t = try typeCheckExpr(lhs, gen);

    const rhs_t =
        if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData.type)
        rhs.data.atomic.data.type
    else {
        log.err("{} Expect type expression in rhs of `as`", .{rhs.tk.loc});
        return SemaError.TypeMismatched;
    };
    if (!castable(lhs_t, rhs_t)) {
        log.err("{} `{}` can not be casted into `{}`", .{ rhs.tk, lhs_t, rhs_t });
        return SemaError.TypeMismatched;
    }
    try reportValidType(rhs_t, rhs.tk.loc);
    return rhs_t;
}
pub fn typeCheckRel(lhs: Expr, rhs: Expr, gen: *TypeGen) SemaError!TypeExpr {
    const lhs_t = try typeCheckExpr(lhs, gen);
    const rhs_t = try typeCheckExpr(rhs, gen);
    if (!lhs_t.eq(rhs_t) or !lhs_t.isType(Type.int)) return SemaError.TypeMismatched;

    return .{.singular = .bool};
}
pub fn typeCheckOp(op: Ast.Op, lhs_t: TypeExpr, rhs_t: TypeExpr, loc: Loc) bool {
    if (op == Ast.Op.as) unreachable;
    if (!lhs_t.isType(Type.int) and !lhs_t.isType(Type.float)) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, lhs_t });
        return false;
    }
    if (!rhs_t.isType(Type.int) and !rhs_t.isType(Type.float)) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, rhs_t });
        return false;
    }

    if (!lhs_t.eq(rhs_t)) {
        log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{ loc, op, lhs_t, rhs_t });
        return false;
    }
    return true;
}

pub fn typeCheckExpr(expr: Expr, gen: *TypeGen) SemaError!Ast.TypeExpr {
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
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
                const arg_t = try typeCheckExpr(gen.ast.exprs[fn_app.args[0].idx], gen);
                if (arg_t.first() == .array and arg_t.plural[1] != .char) {
                    log.err("{} Value of type `array` can not be printed", .{expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
                return .{.singular = .void};
            }
            const fn_def = for (gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ expr.tk, fn_app.func });
                return SemaError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ expr.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return SemaError.TypeMismatched;
            }

            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = gen.ast.exprs[fa.idx];
                const e_type = try typeCheckExpr(e, gen);
                if (!e_type.eq(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ e.tk.loc, i, fn_app.func, fd.type, @tagName(e_type) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return SemaError.TypeMismatched;
                }

            }

            return fn_def.data.ret;
        },
        .addr_of => |addr_of| {
            const expr_addr = gen.ast.exprs[addr_of.idx];
            if (expr_addr.data != .atomic and expr_addr.data.atomic.data != .iden) {
                log.err("{} Cannot take the address of right value", .{expr_addr.tk.loc});
                return SemaError.RightValue;
            }
            const t = try typeCheckExpr(expr_addr, gen);
            return TypeExpr.ptr(gen.arena, t);
            
        },
        .deref => |deref| {
            const expr_deref = gen.ast.exprs[deref.idx];
            const t = try typeCheckExpr(expr_deref, gen);
            if (t.first() != .ptr) {
                log.err("{} Cannot dereference non-ptr type `{}`", .{expr_deref.tk.loc, t});
                return SemaError.TypeMismatched;
            }
            return TypeExpr.deref(t);
        },
        .array => |array| {
            if (array.len < 1) {
                log.err("{} Array must have at least one element to resolve its type", .{expr.tk.loc});
                return SemaError.Unresolvable;
            }
            const first_expr = gen.ast.exprs[array[0].idx];
            const t = try typeCheckExpr(first_expr, gen);
            for (array[1..], 2..) |e, i| {
                const el_expr = gen.ast.exprs[e.idx];
                const el_t = try typeCheckExpr(el_expr, gen);
                if (!t.eq(el_t)) {
                    log.err("{} Array element has different type than its 1st element", .{el_expr.tk.loc});
                    log.note("1st element has type `{}`, but {}th element has type `{}`", .{t, i, el_t});
                    log.note("{} 1st expression defined here", .{first_expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
            }
            return TypeExpr.prefixWith(gen.arena, t, .{ .array = array.len });
        
        },
        .array_access => |aa| {
            const lhs_t = try typeCheckExpr(gen.ast.exprs[aa.lhs.idx], gen);
            if (lhs_t.first() != .array) {
                log.err("{} Type `{}` can not be indexed", .{expr.tk.loc, lhs_t});
                log.note("Only type `array` can be indexed", .{});
                return SemaError.TypeMismatched;
            }
            const rhs_t = try typeCheckExpr(gen.ast.exprs[aa.rhs.idx], gen);
            if (!rhs_t.isType(.int)) {
                log.err("{} Index must have type `int`, found `{}`", .{expr.tk.loc, rhs_t});
                return SemaError.TypeMismatched;
            }
            return TypeExpr.deref(lhs_t);
        },
        .field => |fa| {
            const lhs_t = try typeCheckExpr(gen.ast.exprs[fa.lhs.idx], gen);
            if (lhs_t.first() != .array) {
                log.err("{} Only type `array` can be field accessed, got type `{}`", .{expr.tk.loc, lhs_t});
                return SemaError.TypeMismatched;
            }
            if (std.mem.eql(u8, fa.rhs, "len")) {
                return TypeExpr {.singular = .int};
            }
            log.err("{} Unrecoginized field `{s}` for type `{}`", .{expr.tk.loc, fa.rhs, lhs_t});
            return SemaError.MissingField;
            
        },
    }


}


pub fn typeCheckAtomic(atomic: Atomic, gen: *TypeGen) SemaError!Ast.TypeExpr {
    switch (atomic.data) {
        .bool => return .{.singular = .bool},
        .float => return .{.singular = .float},
        .int => return .{.singular = .int},
        .string => return TypeExpr.string(gen.arena),
        .iden => |i| {
            if (gen.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{} use of unbound variable `{s}`", .{atomic.tk.loc, i});
                return SemaError.Undefined;
            }
        },
        .paren => |expr| return typeCheckExpr(gen.ast.exprs[expr.idx], gen), 

        .addr => @panic("TODO ADDR"),
        .type => @panic("Should never be called"),
    }

}


