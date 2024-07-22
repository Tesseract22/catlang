const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const LangTye = @import("type.zig");
const Loc  = @import("lexer.zig").Loc;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
const Stat = Ast.Stat;
const TopDef = Ast.TopDef;
const Op = Ast.Op;
const SemaError = Ast.ParseError || error {NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn, RightValue, Unresolvable, MissingField};

const Type = LangTye.Type;
const TypeExpr = LangTye.TypeExpr;
const TypeEnv = LangTye.TypeEnv;

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
    ret_type: TypeExpr,
    types: std.ArrayList(TypeExpr),
    type_env: TypeEnv,
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

pub const TypeCheckRes = struct {
    types: []TypeExpr,
    // type_env: []
};

pub fn typeCheck(ast: *const Ast, a: Allocator, arena: Allocator) SemaError![]TypeExpr {

    var gen = TypeGen {
        .a = a,
        .arena = arena,
        .ast = ast,
        .stack = ScopeStack.init(a),
        .ret_type = undefined,
        .types = std.ArrayList(TypeExpr).init(a),
        .type_env = TypeEnv.init(a),
    };
    gen.types.resize(ast.exprs.len) catch unreachable;
    defer gen.stack.deinit();
    defer gen.type_env.deinit();


    const main_idx = for (ast.defs, 0..) |def, i| {
        if (def.data == .proc and std.mem.eql(u8, def.data.proc.name, "main")) {
            break i;
        }
    } else {
        log.err("Undefined reference to `main`", .{});
        return SemaError.Undefined;
    };
    const main_def = ast.defs[main_idx];
    const main_proc = main_def.data.proc;
    if (main_proc.args.len != 0) {
        log.err("{} `main` must have exactly 0 argument", .{main_def.tk.loc});
        return SemaError.NumOfArgs;
    }
    if (!main_proc.ret.isType(Type.void, gen.type_env)) {
        log.err("{} `main` must have return type `void`, found {}", .{main_def.tk.loc, main_proc.ret});
    }

    for (0..ast.defs.len) |i| {
        try typeCheckTopDef(Ast.DefIdx {.idx = i}, &gen);
    }
    return gen.types.toOwnedSlice() catch unreachable;
    
}

pub fn resolveTypeDef(t: TypeExpr, env: TypeEnv, loc: Loc) SemaError!TypeExpr {
    const resolve_t = t.fromEnv(env) orelse {
        log.err("{} Undefined type `{s}`", .{loc, t.first().iden});
        return SemaError.Undefined;
    };
    return resolve_t;
}

pub fn typeCheckTopDef(idx: Ast.DefIdx, gen: *TypeGen) SemaError!void {
    const top = gen.ast.defs[idx.idx];
    switch (gen.ast.defs[idx.idx].data) {
        .proc => |*proc| {
            gen.stack.push();
            defer gen.stack.popDiscard(); // TODO do something with it
            proc.ret = try resolveTypeDef(proc.ret, gen.type_env, top.tk.loc);
            for (proc.args) |*arg| {
                try reportValidType(arg.type, top.tk.loc);
                arg.type =  try resolveTypeDef(arg.type, gen.type_env, arg.tk.loc);
                if (gen.stack.putTop(arg.name, .{.i = undefined, .t = arg.type, .loc = arg.tk.loc})) |old_var| {
                    log.err("{} argument of `{s}` `{s}` shadows outer variable ", .{arg.tk.loc, proc.name, arg.name});
                    log.note("{} variable previously defined here", .{old_var.loc});
                    return SemaError.Redefined;
                } // i is not set until cir
            }
            try reportValidType(proc.ret, top.tk.loc);
            gen.ret_type = proc.ret;
            for (proc.body, 0..) |stat, i| {
                if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |_| {
                    if (i != proc.body.len - 1) {
                        log.err("{} early ret invalids later statement", .{gen.ast.stats[stat.idx].tk.loc});
                        return SemaError.EarlyReturn;
                    } else {
                        break;
                    }
                }
            } else {
                if (!proc.ret.isType(.void, gen.type_env)) {
                    log.err("{} `{s}` implicitly return", .{top.tk.loc, proc.name});
                    return SemaError.TypeMismatched;
                }
            }
        },
        .type => |typedef| {
            if (gen.type_env.contains(typedef.name)) {
                log.err("{} type `{s}` already defined", .{typedef.tk.loc, typedef.name});
                return SemaError.Redefined;
            }
            gen.type_env.put(typedef.name, try resolveTypeDef(typedef.type, gen.type_env, top.tk.loc)) catch unreachable;
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
            const expr_t = try typeCheckExpr(if_stat.cond, gen);
            if (!expr_t.isType(.bool, gen.type_env)) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk.loc, expr_t});
                return SemaError.TypeMismatched;
            }
            const body_t = try typeCheckBlock(if_stat.body, gen);
            const else_t: ?TypeExpr = switch (if_stat.else_body) {
                .stats => |stats| try typeCheckBlock(stats, gen),
                .else_if => |else_if| try typeCheckStat(&gen.ast.stats[else_if.idx], gen),
                .none => null,
            };
            return if (body_t != null and else_t != null and body_t.?.eq(else_t.?, gen.type_env)) body_t else null; 
        },
        .anon => |expr| {
            _ = try typeCheckExpr(expr, gen);
            return null;
        },
        .assign => |assign| {
            const right_t = try typeCheckExpr(assign.expr, gen);
            const left_t = try typeCheckExpr(assign.left_value, gen);
            if (!right_t.eq(left_t, gen.type_env)) {
                log.err("{} Assigning to lhs of type `{}`, but rhs has type `{}`", .{stat.tk.loc, left_t, right_t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(loop.cond, gen);
            if (!expr_t.isType(.bool, gen.type_env)) {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{stat.tk, expr_t});
                return SemaError.TypeMismatched;
            }
            for (loop.body) |si| {
                _ = try typeCheckStat(&gen.ast.stats[si.idx], gen);
            }
            return null;
        },
        .ret => |ret| {
            const ret_t = try typeCheckExpr(ret, gen);
            if (!ret_t.eq(gen.ret_type, gen.type_env)) {
                log.err("{} function has return type `{}`, but this return statement has `{}`", .{stat.tk.loc, gen.ret_type, ret_t});
                return SemaError.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            const t = try typeCheckExpr(var_decl.expr, gen);
            if (var_decl.t) |strong_t| {
                try reportValidType(strong_t, stat.tk.loc);
                if (!strong_t.eq(t, gen.type_env)) {
                    log.err("{} mismatched type in variable decleration and expression", .{stat.tk.loc});
                    return SemaError.TypeMismatched;
                }
                var_decl.t = try resolveTypeDef(strong_t, gen.type_env, stat.tk.loc);
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

pub fn castable(s: TypeExpr, d: TypeExpr, env: TypeEnv) bool {
    const src = if (s.first() == .iden) env.get(s.singular.iden).? else s;
    const dest = if (d.first() == .iden) env.get(d.singular.iden).? else d;
    return switch (src) {
        .singular => |t| switch (t) {
            .float => dest.first().eq(.int, env),
            .int => !dest.first().eq(.void, env),
            .char => dest.first().eq(.int, env),
            .bool => dest.first().eq(.int, env),
            .void => false,
            .ptr, .array, .tuple, .named, .iden => unreachable,
        },
        .plural => |ts| switch (ts[0]) {
            .ptr => dest.first().eq(.int, env) or dest.first().eq(.ptr, env),
            .array, .tuple, .named, .iden => false,
            else => false,
        }

    };
}


pub fn typeCheckAs(lhs_idx: Ast.ExprIdx, rhs_idx: Ast.ExprIdx, gen: *TypeGen) SemaError!TypeExpr {
    const lhs_t = try typeCheckExpr(lhs_idx, gen);

    const rhs = gen.ast.exprs[rhs_idx.idx];
    const rhs_t =
        if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData.type)
        rhs.data.atomic.data.type
    else {
        log.err("{} Expect type expression in rhs of `as`", .{rhs.tk.loc});
        return SemaError.TypeMismatched;
    };
    if (!castable(lhs_t, rhs_t, gen.type_env)) {
        log.err("{} `{}` can not be casted into `{}`", .{ rhs.tk, lhs_t, rhs_t });
        return SemaError.TypeMismatched;
    }
    try reportValidType(rhs_t, rhs.tk.loc);
    return rhs_t;
}
pub fn typeCheckRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, gen: *TypeGen) SemaError!TypeExpr {
    const lhs_t = try typeCheckExpr(lhs, gen);
    const rhs_t = try typeCheckExpr(rhs, gen);
    if (!lhs_t.eq(rhs_t, gen.type_env) or !lhs_t.isType(Type.int, gen.type_env)) return SemaError.TypeMismatched;

    return .{.singular = .bool};
}
pub fn typeCheckOp(op: Ast.Op, lhs_t: TypeExpr, rhs_t: TypeExpr, loc: Loc, env: TypeEnv) bool {
    if (op == Ast.Op.as) unreachable;
    if (!lhs_t.isType(Type.int, env) and !lhs_t.isType(Type.float, env)) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, lhs_t });
        return false;
    }
    if (!rhs_t.isType(Type.int, env) and !rhs_t.isType(Type.float, env)) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, rhs_t });
        return false;
    }

    if (!lhs_t.eq(rhs_t, env)) {
        log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{ loc, op, lhs_t, rhs_t });
        return false;
    }
    return true;
}
pub fn typeCheckExpr(expr_idx: Ast.ExprIdx, gen: *TypeGen) SemaError!TypeExpr {
    const t = try typeCheckExpr2(expr_idx, gen);
    const resolve_t = try resolveTypeDef(t, gen.type_env, gen.ast.exprs[expr_idx.idx].tk.loc);
    gen.types.items[expr_idx.idx] = resolve_t;
    return resolve_t;
}
pub fn typeCheckExpr2(expr_idx: Ast.ExprIdx, gen: *TypeGen) SemaError!TypeExpr {
    const expr = gen.ast.exprs[expr_idx.idx];
    switch (expr.data) {
        .atomic => |atomic| return typeCheckAtomic(atomic, gen),
        .bin_op => |bin_op| {

            switch (bin_op.op) {
                .as => return typeCheckAs(bin_op.lhs, bin_op.rhs, gen),
                .lt, .gt, .eq => return typeCheckRel(bin_op.lhs, bin_op.rhs, gen),
                else => {},
            }
            const lhs_t = try typeCheckExpr(bin_op.lhs, gen);


            const rhs_t = try typeCheckExpr(bin_op.rhs, gen);

            if (!typeCheckOp(bin_op.op, lhs_t, rhs_t, expr.tk.loc, gen.type_env)) return SemaError.TypeMismatched;
            return lhs_t;
            
        },
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
                const arg_t = try typeCheckExpr(fn_app.args[0], gen);
                if (arg_t.first() == .array and arg_t.plural[1] != .char) {
                    log.err("{} Value of type `array` can not be printed", .{expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
                return .{.singular = .void};
            }
            const fn_def = for (gen.ast.defs) |def| {
                if (def.data == .proc and std.mem.eql(u8, def.data.proc.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ expr.tk, fn_app.func });
                return SemaError.Undefined;
            };
            if (fn_def.data.proc.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ expr.tk.loc, fn_app.func, fn_def.data.proc.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return SemaError.TypeMismatched;
            }

            for (fn_def.data.proc.args, fn_app.args, 0..) |fd, fa, i| {
                const e_type = try typeCheckExpr(fa, gen);
                if (!e_type.eq(fd.type, gen.type_env)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{}`", .{ gen.ast.exprs[fa.idx].tk.loc, i, fn_app.func, fd.type, e_type });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    log.debug("{}", .{e_type.first().fromEnv(gen.type_env).?});
                    return SemaError.TypeMismatched;
                }

            }

            return fn_def.data.proc.ret;
        },
        .addr_of => |addr_of| {
            const expr_addr = gen.ast.exprs[addr_of.idx];
            if (expr_addr.data != .atomic and expr_addr.data.atomic.data != .iden) {
                log.err("{} Cannot take the address of right value", .{expr_addr.tk.loc});
                return SemaError.RightValue;
            }
            const t = try typeCheckExpr(addr_of, gen);
            return TypeExpr.ptr(gen.arena, t);
            
        },
        .deref => |deref| {
            const expr_deref = gen.ast.exprs[deref.idx];
            const t = try typeCheckExpr(deref, gen);
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
            const t = try typeCheckExpr(array[0], gen);
            for (array[1..], 2..) |e, i| {
                const el_expr = gen.ast.exprs[e.idx];
                const el_t = try typeCheckExpr(e, gen);
                if (!t.eq(el_t, gen.type_env)) {
                    log.err("{} Array element has different type than its 1st element", .{el_expr.tk.loc});
                    log.note("1st element has type `{}`, but {}th element has type `{}`", .{t, i, el_t});
                    log.note("{} 1st expression defined here", .{first_expr.tk.loc});
                    return SemaError.TypeMismatched;
                }
            }
            return TypeExpr.prefixWith(gen.arena, t, .{ .array = array.len });
        
        },
        .tuple => |tuple| {
            var tuple_t = std.ArrayList(TypeExpr).initCapacity(gen.arena, tuple.len) catch unreachable;
            errdefer tuple_t.deinit();
            for (tuple) |ti| {
                const t = try typeCheckExpr(ti, gen);
                tuple_t.append(t) catch unreachable;
            }
            return TypeExpr {.singular = .{ .tuple = tuple_t.toOwnedSlice() catch unreachable }};
        },
        .named_tuple => |tuple| {
            var tuple_t = std.ArrayList(LangTye.VarBind).initCapacity(gen.arena, tuple.len) catch unreachable;
            var set = std.StringHashMap(void).init(gen.a);
            defer set.deinit();
            for (tuple) |named_init| {
                const t = try typeCheckExpr(named_init.expr, gen);
                const tk = gen.ast.exprs[named_init.expr.idx].tk;
                if (set.contains(named_init.name)) {
                    log.err("{} Duplicate field `{s}` in named tuple initialization", .{tk.loc, named_init.name});
                    return SemaError.Redefined;
                }
                set.put(named_init.name, {}) catch unreachable;
                tuple_t.append(.{.name = named_init.name, .type = t, .tk = tk}) catch unreachable;
            }
            return TypeExpr {.singular = .{.named = tuple_t.toOwnedSlice() catch unreachable}};
        },
        .array_access => |aa| {
            const lhs_t = try typeCheckExpr(aa.lhs, gen);
            const rhs = gen.ast.exprs[aa.rhs.idx];
            switch (lhs_t.first()) {
                .array => {
                    const rhs_t = try typeCheckExpr(aa.rhs, gen);
                    if (!rhs_t.isType(.int, gen.type_env)) {
                        log.err("{} Index must have type `int`, found `{}`", .{expr.tk.loc, rhs_t});
                        return SemaError.TypeMismatched;
                    }
                    return TypeExpr.deref(lhs_t);
                },
                .tuple => |tuple| {
                    if (rhs.data != .atomic or rhs.data.atomic.data != .int) {
                        log.err("{} Tuple can only be directly indexed by int literal", .{expr.tk.loc});
                        return SemaError.TypeMismatched;
                    }
                    const i = rhs.data.atomic.data.int;
                    if (i >= tuple.len or i < 0) {
                        log.err("{} Tuple has length {}, but index is {}", .{expr.tk.loc, tuple.len, i});
                        return SemaError.TypeMismatched;
                    }
                    return tuple[@intCast(i)];
                },
                else => {
                    log.err("{} Type `{}` can not be indexed", .{expr.tk.loc, lhs_t});
                    log.note("Only type `array` or `tuple` can be indexed", .{});
                    return SemaError.TypeMismatched;
                }
            }


        },
        .field => |fa| {
            const lhs_t = try typeCheckExpr(fa.lhs, gen);
            const first = lhs_t.first();


            switch (first) {
                .array => {
                    if (std.mem.eql(u8, fa.rhs, "len")) {
                        return TypeExpr {.singular = .int};
                    }
                    log.err("{} Unrecoginized field `{s}` for type `{}`", .{expr.tk.loc, fa.rhs, lhs_t});
                    return SemaError.MissingField;
                },
                .named => |tuple| {
                    for (tuple) |vb| {
                        if (std.mem.eql(u8, fa.rhs, vb.name)) return vb.type;
                    }
                    log.err("{} Unrecoginized field `{s}` for type `{}`", .{expr.tk.loc, fa.rhs, lhs_t});
                    return SemaError.MissingField;
                },
                else => {
                    log.err("{} Only type `array` or `struct` can be field accessed, got type `{}`", .{expr.tk.loc, lhs_t});
                    return SemaError.TypeMismatched;
                }
            }

            
        },
    }


}


pub fn typeCheckAtomic(atomic: Atomic, gen: *TypeGen) SemaError!TypeExpr {
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
        .paren => |expr| return typeCheckExpr(expr, gen), 

        .addr => @panic("TODO ADDR"),
        .type => @panic("Should never be called"),
    }

}


