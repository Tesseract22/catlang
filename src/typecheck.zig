const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const Lexer  = @import("lexer.zig");
const TypePool = @import("type.zig");
const Type = TypePool.Type;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
const TypeExpr = Ast.TypeExpr;
const Stat = Ast.Stat;
const ProcDef = Ast.ProcDef;
const Op = Ast.Op;
const SemaError = Ast.ParseError || error {NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn, RightValue, Unresolvable, MissingField};
const Allocator = std.mem.Allocator;
const Symbol = Lexer.Symbol;


const lookup = Lexer.lookup;
const intern = Lexer.intern;

// TODO checks for duplicate function

const ScopeItem = struct {
    t: Type,
    i: usize,
    off: u32,
};
const Scope = std.AutoArrayHashMap(Symbol, ScopeItem);
const ScopeStack = struct {
    stack: std.ArrayList(Scope),
    pub fn init(alloc: std.mem.Allocator) ScopeStack {
        return ScopeStack{ .stack = std.ArrayList(Scope).init(alloc) };
    }
    pub fn deinit(self: *ScopeStack) void {
        std.debug.assert(self.stack.items.len == 0);
        self.stack.deinit();
    }
    pub fn get(self: ScopeStack, name: Symbol) ?ScopeItem {
        return for (self.stack.items) |scope| {
            if (scope.get(name)) |v| break v;
        } else null;
    }
    // return the old value, if any
    pub fn putTop(self: *ScopeStack, name: Symbol, item: ScopeItem) ?ScopeItem {
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
    ret_type: Type,
    types: []Type,
    pub fn get_type(gen: TypeGen, idx: Ast.TypeExprIdx) Type {
        return gen.types[idx.idx];
    }
    pub fn get_type_expr(gen: TypeGen, idx: Ast.TypeExprIdx) Ast.TypeExpr {
        return gen.ast.types[idx.idx];
    }
};
pub fn evalTypeExpr(gen: *TypeGen, type_expr: Ast.TypeExpr) !Type {
    switch (type_expr.data) {
        .ident => |i| {
            if (i == Lexer.int) return TypePool.int;
            if (i == Lexer.float) return TypePool.float;
            if (i == Lexer.void) return TypePool.void;
            if (i == Lexer.bool) return TypePool.bool;
            @panic("unimplemented");
        },
        .ptr => |ptr| {
            const el = try reportValidType(gen, ptr.el);
            return TypePool.intern(.{.ptr = .{.el = el}});
        },
        .array => |array| {
            const el = try reportValidType(gen, array.el);
            return TypePool.intern(.{.array = .{.el = el, .size = @intCast(array.size) }});
        },
        .tuple => |tuple| {
            const els = gen.arena.alloc(Type, tuple.len) catch unreachable;
            for (els, tuple) |*t1, t2| {
                t1.* = try reportValidType(gen, t2);
            }
            return TypePool.intern(.{.tuple = .{.els = els }});
        }
    }
}

pub fn reportValidType(gen: *TypeGen, idx: Ast.TypeExprIdx) SemaError!Type {
    const te = gen.get_type_expr(idx);
    const t =  evalTypeExpr(gen, te) catch |e| {
        log.err("{}: {} `{}` is not valid type", .{gen.ast.to_loc(te.tk), e, te});
        return SemaError.InvalidType;
    };
    gen.types[idx.idx] = t;
    return t;
}


pub fn typeCheck(ast: *const Ast, a: Allocator, arena: Allocator) SemaError!void {
    const main_idx = for (ast.defs, 0..) |def, i| {
        if (def.data.name == intern("main")) {
            break i;
        }
    } else {
        log.err("Undefined reference to `main`", .{});
        return SemaError.Undefined;
    };

    var gen = TypeGen {
        .a = a,
        .arena = arena,
        .ast = ast,
        .stack = ScopeStack.init(a),
        .ret_type = undefined,
        .types = a.alloc(Type, ast.types.len) catch unreachable,
    };
    defer gen.stack.deinit();
    for (ast.defs) |def| {
        try typeCheckProc(def, &gen);
    }
    const main_proc = ast.defs[main_idx];
    if (main_proc.data.args.len != 0) {
        log.err("{} `main` must have exactly 0 argument", .{main_proc.tk});
        return SemaError.NumOfArgs;
    }
    if (gen.get_type(main_proc.data.ret) != TypePool.@"void") {
        log.err("{} `main` must have return type `void`, found {}", .{ast.to_loc(main_proc.tk), main_proc.data.ret});
    }

}

pub fn typeCheckProc(proc: ProcDef, gen: *TypeGen) SemaError!void {
    gen.stack.push();
    defer gen.stack.popDiscard(); // TODO do something with it
    for (proc.data.args) |arg| {
        const arg_t = try reportValidType(gen, arg.type);
        if (gen.stack.putTop(arg.name, .{.i = undefined, .t = arg_t, .off = arg.tk.off})) |old_var| {
            log.err("{} argument of `{s}` `{s}` shadows outer variable ", .{
                gen.ast.to_loc(arg.tk), 
                lookup(proc.data.name), 
                lookup(arg.name)
            });
            log.note("{} variable previously defined here", .{gen.ast.to_loc2(old_var.off)});
            return SemaError.Redefined;
        } // i is not set until cir
    }
    const ret_t = try reportValidType(gen, proc.data.ret);
    gen.ret_type = ret_t;
    for (proc.data.body, 0..) |stat, i| {
        if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |_| {
            if (i != proc.data.body.len - 1) {
                log.err("{} early ret invalids later statement", .{gen.ast.to_loc(gen.ast.stats[stat.idx].tk)});
                return SemaError.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (ret_t != TypePool.void) {
            log.err("{} `{s}` implicitly return", .{gen.ast.to_loc(proc.tk), lookup(proc.data.name)});
            return SemaError.TypeMismatched;
        }
    }


}
pub fn typeCheckBlock(block: []Ast.StatIdx, gen: *TypeGen) SemaError!?Type {
    gen.stack.push();
    defer gen.stack.popDiscard();

    return for (block, 0..) |stat, i| {
        if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |ret| {
            if (i != block.len - 1) {
                log.err("{} early ret invalidates later statement", .{gen.ast.to_loc(gen.ast.stats[stat.idx].tk)});
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
pub fn typeCheckStat(stat: *Stat, gen: *TypeGen) SemaError!?Type {
    switch (stat.data) {
        .@"if" => |if_stat| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[if_stat.cond.idx], gen);
            if (expr_t != TypePool.@"bool") {
                log.err("{} Expect type `bool` in if statment condition, found `{}`", .{gen.ast.to_loc(stat.tk), expr_t});
                return SemaError.TypeMismatched;
            }
            const body_t = try typeCheckBlock(if_stat.body, gen);
            const else_t: ?Type = switch (if_stat.else_body) {
                .stats => |stats| try typeCheckBlock(stats, gen),
                .else_if => |else_if| try typeCheckStat(&gen.ast.stats[else_if.idx], gen),
                .none => null,
            };
            return if (body_t != null and else_t != null and body_t.? == else_t.?) body_t else null; 
        },
        .anon => |expr| {
            _ = try typeCheckExpr(gen.ast.exprs[expr.idx], gen);
            return null;
        },
        .assign => |assign| {
            const right_t = try typeCheckExpr(gen.ast.exprs[assign.expr.idx], gen);
            const left_t = try typeCheckExpr(gen.ast.exprs[assign.left_value.idx], gen);
            if (right_t != left_t) {
                log.err("{} Assigning to lhs of type `{}`, but rhs has type `{}`", .{gen.ast.to_loc(stat.tk), left_t, right_t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(gen.ast.exprs[loop.cond.idx], gen);
            if (expr_t != TypePool.bool) {
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
            if (ret_t != gen.ret_type) {
                log.err("{} function has return type `{}`, but this return statement has `{}`", .{gen.ast.to_loc(stat.tk), gen.ret_type, ret_t});
                return SemaError.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            log.debug("typecheck {s}", .{lookup(var_decl.name)});
            const t = try typeCheckExpr(gen.ast.exprs[var_decl.expr.idx], gen);
            if (var_decl.t) |strong_te| {
                const strong_t = try reportValidType(gen, strong_te);
                if (strong_t != t) { // TODO coersion betwee different types should be used here (together with as)?
                    log.err("{} mismatched type in variable decleration and expression", .{gen.ast.to_loc(stat.tk)});
                    return SemaError.TypeMismatched;
                }
            } 
            // TODO remove this completely, because the type of the varible declaration is already in gen.types
            //else {
            //    var_decl.t = gen.ast.exprs[var_decl.expr.idx];
            //}
            if (gen.stack.putTop(var_decl.name, .{.i = undefined, .t = t, .off = stat.tk.off })) |old_var| {
                log.err("{} `{s}` is already defined", .{gen.ast.to_loc(stat.tk), lookup(var_decl.name)});
                log.note("{} previously defined here", .{gen.ast.to_loc2(old_var.off)});
                return SemaError.Redefined;
            }
            return null;
        }
    }

}
pub fn castable(src: Type, dest: Type) bool {
    if (src == dest) return true;
    if (src == TypePool.float) return dest == TypePool.int;
    if (src == TypePool.int) return dest != TypePool.void;
    if (src == TypePool.char) return dest == TypePool.int;
    if (src == TypePool.bool) return dest == TypePool.int;
    if (src == TypePool.void) return false;

    const src_full = TypePool.lookup(src);
    const dest_full = TypePool.lookup(dest);
    switch (src_full) {
        .ptr => |_| return dest_full == .ptr or dest_full == .int,
        .tuple, .array => return false,
        else => return false,
    }
}


//pub fn castable(src: Type, dest: Type) bool {
//    return switch (src) {
//        .singular => |t| switch (t) {
//            .float => dest.first().eq(.int),
//            .int => dest.first() != .void,
//            .char => dest.first().eq(.int),
//            .bool => dest.first().eq(.int),
//            .void => false,
//            .ptr, .array => unreachable,
//        },
//        .plural => |ts| switch (ts[0]) {
//            .ptr => dest.first().eq(.int) or dest.first().eq(.ptr),
//            else => {
//                log.err("{} {}", .{src, dest});
//                unreachable;
//            },
//            .array => false,
//        }
//
//    };
//}


pub fn typeCheckAs(lhs: Expr, rhs_t: Type, gen: *TypeGen) SemaError!Type {
    const lhs_t = try typeCheckExpr(lhs, gen);

    //const rhs_t =
    //    if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData)
    //        rhs.data.atomic.data.type
    //    else {
    //        log.err("{} Expect type expression in rhs of `as`", .{gen.ast.to_loc(rhs.tk)});
    //        return SemaError.TypeMismatched;
    //    };
    if (!castable(lhs_t, rhs_t)) {
        log.err("{} `{}` can not be casted into `{}`", .{ gen.ast.to_loc(lhs.tk), lhs_t, rhs_t });
        return SemaError.TypeMismatched;
    }
    return rhs_t;
}
pub fn typeCheckRel(lhs: Expr, rhs: Expr, gen: *TypeGen) SemaError!Type {
    const lhs_t = try typeCheckExpr(lhs, gen);
    const rhs_t = try typeCheckExpr(rhs, gen);
    if (lhs_t != rhs_t or lhs_t != TypePool.int) return SemaError.TypeMismatched;

    return TypePool.@"bool";
}
pub fn typeCheckOp(gen: *const TypeGen, op: Ast.Op, lhs_t: Type, rhs_t: Type, off: u32) bool {
    if (op == Ast.Op.as) unreachable;
    if (lhs_t != TypePool.int and lhs_t != TypePool.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ gen.ast.to_loc2(off) , op, lhs_t });
        return false;
    }
    if (rhs_t != TypePool.int and rhs_t != TypePool.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ gen.ast.to_loc2(off), op, rhs_t });
        return false;
    }

    if (lhs_t != rhs_t) {
        log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{ gen.ast.to_loc2(off), op, lhs_t, rhs_t });
        return false;
    }
    return true;
}

pub fn typeCheckExpr(expr: Expr, gen: *TypeGen) SemaError!Type {
    switch (expr.data) {
        .atomic => |atomic| return typeCheckAtomic(atomic, gen),
        .as => |as| {
            const lhs = gen.ast.exprs[as.lhs.idx];
            const rhs_t = try reportValidType(gen, as.rhs);
            return typeCheckAs(lhs, rhs_t, gen);
        },
        .bin_op => |bin_op| {
            const lhs = gen.ast.exprs[bin_op.lhs.idx];
            const rhs = gen.ast.exprs[bin_op.rhs.idx];

            switch (bin_op.op) {
                .lt, .gt, .eq => return typeCheckRel(lhs, rhs, gen),
                else => {},
            }
            const lhs_t = try typeCheckExpr(lhs, gen);


            const rhs_t = try typeCheckExpr(rhs, gen);

            if (!typeCheckOp(gen, bin_op.op, lhs_t, rhs_t, expr.tk.off)) return SemaError.TypeMismatched;
            return lhs_t;

        },
        .fn_app => |fn_app| {
            if (fn_app.func == intern("print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{gen.ast.to_loc(expr.tk)});
                    return SemaError.TypeMismatched;
                }
                const arg_t = try typeCheckExpr(gen.ast.exprs[fn_app.args[0].idx], gen);
                const arg_full_t = TypePool.lookup(arg_t);
                if (arg_full_t == .array) {
                    log.err("{} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
                    return SemaError.TypeMismatched;
                }
                return TypePool.@"void";
            }
            // TODO use a map instead, also checks for duplicate
            const fn_def = for (gen.ast.defs) |def| {
                if (def.data.name == fn_app.func) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ expr.tk, lookup(fn_app.func) });
                return SemaError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ gen.ast.to_loc(expr.tk), lookup(fn_app.func), fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{ gen.ast.to_loc(fn_def.tk)});
                return SemaError.TypeMismatched;
            }

            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = gen.ast.exprs[fa.idx];
                const e_type = try typeCheckExpr(e, gen);
                if (e_type != gen.get_type(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ 
                        gen.ast.to_loc(e.tk), i, 
                        lookup(fn_app.func), 
                        fd.type, 
                        @tagName(TypePool.lookup(e_type)) });
                    log.note("{} function argument defined here", .{gen.ast.to_loc(fd.tk)});
                    return SemaError.TypeMismatched;
                }

            }

            return gen.get_type(fn_def.data.ret);
        },
        .addr_of => |addr_of| {
            const expr_addr = gen.ast.exprs[addr_of.idx];
            if (expr_addr.data != .atomic and expr_addr.data.atomic.data != .iden) {
                log.err("{} Cannot take the address of right value", .{gen.ast.to_loc(expr_addr.tk)});
                return SemaError.RightValue;
            }
            const t = try typeCheckExpr(expr_addr, gen);
            return TypePool.type_pool.address_of(t);

        },
        .deref => |deref| {
            const expr_deref = gen.ast.exprs[deref.idx];
            const t = try typeCheckExpr(expr_deref, gen);
            const t_full = TypePool.lookup(t);
            if (t_full != .ptr) {
                log.err("{} Cannot dereference non-ptr type `{}`", .{ gen.ast.to_loc(expr_deref.tk), t});
                return SemaError.TypeMismatched;
            }
            return t_full.ptr.el;
        },
        .array => |array| {
            if (array.len < 1) {
                log.err("{} Array must have at least one element to resolve its type", .{gen.ast.to_loc(expr.tk)});
                return SemaError.Unresolvable;
            }
            const first_expr = gen.ast.exprs[array[0].idx];
            const t = try typeCheckExpr(first_expr, gen);
            for (array[1..], 2..) |e, i| {
                const el_expr = gen.ast.exprs[e.idx];
                const el_t = try typeCheckExpr(el_expr, gen);
                if (t == el_t) {
                    log.err("{} Array element has different type than its 1st element", .{gen.ast.to_loc(el_expr.tk)});
                    log.note("1st element has type `{}`, but {}th element has type `{}`", .{t, i, el_t});
                    log.note("{} 1st expression defined here", .{gen.ast.to_loc(first_expr.tk)});
                    return SemaError.TypeMismatched;
                }
            }
            const array_full = TypePool.TypeFull {.array = .{.el = t, .size = @intCast(array.len) }};
            return TypePool.intern(array_full);

        },
        .array_access => |aa| {
            const lhs_t = try typeCheckExpr(gen.ast.exprs[aa.lhs.idx], gen);
            const lhs_t_full = TypePool.lookup(lhs_t);
            if (lhs_t_full != .array) {
                log.err("{} Type `{}` can not be indexed", .{gen.ast.to_loc(expr.tk), lhs_t});
                log.note("Only type `array` can be indexed", .{});
                return SemaError.TypeMismatched;
            }
            const rhs_t = try typeCheckExpr(gen.ast.exprs[aa.rhs.idx], gen);
            const rhs_t_full = TypePool.lookup(rhs_t);
            if (rhs_t_full != .int) {
                log.err("{} Index must have type `int`, found `{}`", .{gen.ast.to_loc(expr.tk), rhs_t});
                return SemaError.TypeMismatched;
            }
            return lhs_t_full.array.el;
        },
        .field => |fa| {
            const lhs_t = try typeCheckExpr(gen.ast.exprs[fa.lhs.idx], gen);
            const lhs_t_full = TypePool.lookup(lhs_t);
            if (lhs_t_full != .array) {
                log.err("{} Only type `array` can be field accessed, got type `{}`", .{gen.ast.to_loc(expr.tk), lhs_t});
                return SemaError.TypeMismatched;
            }
            if (fa.rhs == intern("len")) {
                return TypePool.int;
            }
            log.err("{} Unrecoginized field `{s}` for type `{}`", .{gen.ast.to_loc(expr.tk), lookup(fa.rhs), lhs_t});
            return SemaError.MissingField;

        },
    }


}


pub fn typeCheckAtomic(atomic: Atomic, gen: *TypeGen) SemaError!Type {
    switch (atomic.data) {
        .bool => return TypePool.@"bool",
        .float => return TypePool.float,
        .int => return TypePool.int,
        .string => |sym| {
            const len = Lexer.string_pool.lookup(sym).len;
            return TypePool.intern(TypePool.TypeFull {.array = .{.el = TypePool.char, .size = @intCast(len)}});
        },
        .iden => |i| {
            if (gen.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{} use of unbound variable `{s}`", .{gen.ast.to_loc(atomic.tk), lookup(i)});
                return SemaError.Undefined;
            }
        },
        .paren => |expr| return typeCheckExpr(gen.ast.exprs[expr.idx], gen), 

        .addr => @panic("TODO ADDR"),
    }

}


