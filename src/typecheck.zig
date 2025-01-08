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
const TopDef = Ast.TopDef;
const ProcDef = Ast.ProcDef;
const VarBind = Ast.VarBind;
const Op = Ast.Op;
const SemaError = Ast.ParseError || error {NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn, RightValue, Unresolvable, MissingField};


const Allocator = std.mem.Allocator;
const Symbol = Lexer.Symbol;


const lookup = Lexer.lookup;
const intern = Lexer.intern;

// TODO checks for duplicate function

const ScopeItem = struct {
    t: Type,
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
pub const UseDefs = std.AutoHashMap(Ast.ExprIdx, Ast.StatIdx);
pub const TypeDefs = std.AutoHashMap(Symbol, Type);
const TypeGen = struct {
    a: Allocator,
    arena: Allocator,
    ast: *const Ast,
    stack: ScopeStack,
    ret_type: Type,
    types: []Type,
    expr_types: []Type,
    typedefs: TypeDefs,
    use_defs: UseDefs,
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
            return gen.typedefs.get(i) orelse {
                log.err("Unknown type `{s}`", .{lookup(i)});
                return SemaError.Undefined;
            };
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
        },
        .named => |named| {
            const els = gen.arena.alloc(Type, named.len) catch unreachable;
            const syms = gen.arena.alloc(Type, named.len) catch unreachable;
            for (els, syms, named) |*t, *sym, vs| {
                t.* = try reportValidType(gen, vs.type);
                sym.* = vs.name;
            }
            return TypePool.intern(.{.named = .{.els = els, .syms = syms}});
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
// This struct is returned by typeCheck, and used by the code generation
pub const Sema = struct {
    types: []Type, // each item (a concrete, fully evaluated type) in this slice correspond to each type expression in ast.types
    expr_types: []Type,
    use_defs: std.AutoHashMap(Ast.ExprIdx, Ast.StatIdx), // a map from the usage of the variable to the definition of said variable
};

pub fn typeCheck(ast: *const Ast, a: Allocator, arena: Allocator) SemaError!Sema {
    const main_idx = for (ast.defs, 0..) |def, i| {
        if (def.data == .proc and def.data.proc.name == Lexer.main) {
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
        .expr_types = a.alloc(Type, ast.exprs.len) catch unreachable,
        .typedefs = TypeDefs.init(a),
        .use_defs = UseDefs.init(a),
    };
    defer {
        gen.stack.deinit();
        gen.typedefs.deinit();
    }
    // init builtin types
    {
        gen.typedefs.put(Lexer.int, TypePool.int) catch unreachable;
        gen.typedefs.put(Lexer.float, TypePool.float) catch unreachable;
        gen.typedefs.put(Lexer.void, TypePool.void) catch unreachable;
        gen.typedefs.put(Lexer.bool, TypePool.bool) catch unreachable;
        gen.typedefs.put(Lexer.char, TypePool.char) catch unreachable;

    }
    for (ast.defs) |def| {
        switch (def.data) {
            .proc => |proc| try typeCheckProcSignature(proc, &gen),
            .type => |typedef| {
                gen.typedefs.put(typedef.name, try evalTypeExpr(&gen, gen.get_type_expr(typedef.type))) catch unreachable;
            },
        }
    }
    for (ast.defs) |def| {
        switch (def.data) {
            .proc => |proc| try typeCheckProcBody(proc, def.tk, &gen),
            .type => {},
        }
    }
    const main_proc = ast.defs[main_idx];
    if (main_proc.data.proc.args.len != 0) {
        log.err("{} `main` must have exactly 0 argument", .{main_proc.tk});
        return SemaError.NumOfArgs;
    }
    if (gen.get_type(main_proc.data.proc.ret) != TypePool.@"void") {
        log.err("{} `main` must have return type `void`, found {}", .{ast.to_loc(main_proc.tk), main_proc.data.proc.ret});
    }
    return Sema {.types = gen.types, .expr_types = gen.expr_types, .use_defs = gen.use_defs };

}
// When typechecking the root of a file:
// We first ONLY tyoecheck the signature of the all the function defination, so that they can be referenced by other function bodies later
// This allow the defination and usage of function to be NOT neccessarily in order
pub fn typeCheckProcSignature(proc: ProcDef, gen: *TypeGen) SemaError!void {
    gen.stack.push();
    defer gen.stack.popDiscard(); // TODO do something with it
    for (proc.args) |arg| {
        const arg_t = try reportValidType(gen, arg.type);
        if (gen.stack.putTop(arg.name, .{.t = arg_t, .off = arg.tk.off})) |old_var| {
            log.err("{} argument of `{s}` `{s}` shadows outer variable ", .{
                gen.ast.to_loc(arg.tk), 
                lookup(proc.name), 
                lookup(arg.name)
            });
            log.note("{} variable previously defined here", .{gen.ast.to_loc2(old_var.off)});
            return SemaError.Redefined;
        }

    }
    _ = try reportValidType(gen, proc.ret);
}
// This functions should be called AFTER typeCheckProcSignature
pub fn typeCheckProcBody(proc: ProcDef, tk: Lexer.Token, gen: *TypeGen) SemaError!void {
    gen.stack.push();
    defer gen.stack.popDiscard(); // TODO do something with it
    for (proc.args) |arg| {
        const arg_t = gen.get_type(arg.type);
        if (gen.stack.putTop(arg.name, .{.t = arg_t, .off = arg.tk.off})) |_| 
            @panic("The previous called to typeCheckProcSignature should already checks for this. Something is messed up!");
    }
    const ret_t = gen.get_type(proc.ret);
    gen.ret_type = ret_t;
    for (proc.body, 0..) |stat, i| {
        if (try typeCheckStat(&gen.ast.stats[stat.idx], gen)) |_| {
            if (i != proc.body.len - 1) {
                log.err("{} early ret invalids later statement", .{gen.ast.to_loc(gen.ast.stats[stat.idx].tk)});
                return SemaError.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (ret_t != TypePool.void) {
            log.err("{} `{s}` implicitly return", .{gen.ast.to_loc(tk), lookup(proc.name)});
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
            const expr_t = try typeCheckExpr(if_stat.cond, gen);
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
            _ = try typeCheckExpr(expr, gen);
            return null;
        },
        .assign => |assign| {
            const right_t = try typeCheckExpr(assign.expr, gen);
            const left_t = try typeCheckExpr(assign.left_value, gen);
            if (right_t != left_t) {
                log.err("{} Assigning to lhs of type `{}`, but rhs has type `{}`", .{gen.ast.to_loc(stat.tk), left_t, right_t});
                return SemaError.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(loop.cond, gen);
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
            const ret_t = try typeCheckExpr(ret, gen);
            if (ret_t != gen.ret_type) {
                log.err("{} function has return type `{}`, but this return statement has `{}`", .{gen.ast.to_loc(stat.tk), gen.ret_type, ret_t});
                return SemaError.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            log.debug("typecheck var decl {s}", .{lookup(var_decl.name)});
            const t = try typeCheckExpr(var_decl.expr, gen);
            if (var_decl.te) |strong_te| {

                std.log.debug("type expression {}", .{gen.get_type_expr(strong_te)});
                const strong_t = try reportValidType(gen, strong_te);
                if (strong_t != t) { // TODO coersion betwee different types should be used here (together with as)?
                    log.err("{} mismatched type in variable decleration and expression", .{gen.ast.to_loc(stat.tk)});
                    return SemaError.TypeMismatched;
                }
            }

            var_decl.t = t;
            // TODO remove this completely, because the type of the varible declaration is already in gen.types
            //else {
            //    var_decl.t = gen.ast.exprs[var_decl.expr.idx];
            //}
            if (gen.stack.putTop(var_decl.name, .{ .t = t, .off = stat.tk.off })) |old_var| {
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


pub fn typeCheckAs(lhs_idx: Ast.ExprIdx, rhs_t: Type, gen: *TypeGen) SemaError!Type {
    const lhs_t = try typeCheckExpr(lhs_idx, gen);
    const lhs = gen.ast.exprs[lhs_idx.idx];
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
pub fn typeCheckRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, gen: *TypeGen) SemaError!Type {
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

pub fn typeCheckExpr(expr_idx: Ast.ExprIdx, gen: *TypeGen) SemaError!Type {
    const t = try typeCheckExpr2(expr_idx, gen);
    gen.expr_types[expr_idx.idx] = t;
    return t;
} 
pub fn typeCheckExpr2(expr_idx: Ast.ExprIdx, gen: *TypeGen) SemaError!Type {
    const expr = gen.ast.exprs[expr_idx.idx];
    switch (expr.data) {
        .atomic => |atomic| return typeCheckAtomic(atomic, gen),
        .as => |as| {
            const rhs_t = try reportValidType(gen, as.rhs);
            return typeCheckAs(as.lhs, rhs_t, gen);
        },
        .bin_op => |bin_op| {

            switch (bin_op.op) {
                .lt, .gt, .eq => return typeCheckRel(bin_op.lhs, bin_op.rhs, gen),
                else => {},
            }
            const lhs_t = try typeCheckExpr(bin_op.lhs, gen);


            const rhs_t = try typeCheckExpr(bin_op.rhs, gen);

            if (!typeCheckOp(gen, bin_op.op, lhs_t, rhs_t, expr.tk.off)) return SemaError.TypeMismatched;
            return lhs_t;

        },
        .fn_app => |fn_app| {
            if (fn_app.func == intern("print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{gen.ast.to_loc(expr.tk)});
                    return SemaError.TypeMismatched;
                }
                const arg_t = try typeCheckExpr(fn_app.args[0], gen);
                const arg_full_t = TypePool.lookup(arg_t);
                switch (arg_full_t) {
                    .array => |array| {
                        if (array.el != TypePool.char) {
                            log.err("{} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
                            return SemaError.TypeMismatched;
                        }
                    },
                    .tuple, .named => {
                        log.err("{} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
                        return SemaError.TypeMismatched;
                    },
                    else => {},

                }
                return TypePool.@"void";
            }
            // TODO use a map instead, also checks for duplicate
            const fn_def = for (gen.ast.defs) |def| {
                if (def.data == .proc and def.data.proc.name == fn_app.func) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ expr.tk, lookup(fn_app.func) });
                return SemaError.Undefined;
            };
            if (fn_def.data.proc.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ gen.ast.to_loc(expr.tk), lookup(fn_app.func), fn_def.data.proc.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{ gen.ast.to_loc(fn_def.tk)});
                return SemaError.TypeMismatched;
            }

            for (fn_def.data.proc.args, fn_app.args, 0..) |fd, fa, i| {
                const e_type = try typeCheckExpr(fa, gen);
                if (e_type != gen.get_type(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ 
                        gen.ast.to_loc(gen.ast.exprs[fa.idx].tk), i, 
                        lookup(fn_app.func), 
                        TypePool.lookup(gen.get_type(fd.type)), 
                        @tagName(TypePool.lookup(e_type)) });
                    log.note("{} function argument defined here", .{gen.ast.to_loc(fd.tk)});
                    return SemaError.TypeMismatched;
                }

            }

            return gen.get_type(fn_def.data.proc.ret);
        },
        .addr_of => |addr_of| {
            const expr_addr = gen.ast.exprs[addr_of.idx];
            if (expr_addr.data != .atomic and expr_addr.data.atomic.data != .iden) {
                log.err("{} Cannot take the address of right value", .{gen.ast.to_loc(expr_addr.tk)});
                return SemaError.RightValue;
            }
            const t = try typeCheckExpr(addr_of, gen);
            return TypePool.type_pool.address_of(t);

        },
        .deref => |deref| {
            const t = try typeCheckExpr(deref, gen);
            const t_full = TypePool.lookup(t);
            if (t_full != .ptr) {
                const expr_deref = gen.ast.exprs[deref.idx];
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
            const t = try typeCheckExpr(array[0], gen);
            for (array[1..], 2..) |e, i| {
                const el_t = try typeCheckExpr(e, gen);
                if (t != el_t) {
                    const el_expr = gen.ast.exprs[e.idx];
                    log.err("{} Array element has different type than its 1st element", .{gen.ast.to_loc(el_expr.tk)});
                    log.note("1st element has type `{}`, but {}th element has type `{}`", .{TypePool.lookup(t), i, TypePool.lookup(el_t)});
                    log.note("{} 1st expression defined here", .{gen.ast.to_loc(first_expr.tk)});
                    return SemaError.TypeMismatched;
                }
            }
            const array_full = TypePool.TypeFull {.array = .{.el = t, .size = @intCast(array.len) }};
            return TypePool.intern(array_full);

        },
        .tuple => |tuple| {
            var els = gen.arena.alloc(Type, tuple.len) catch unreachable;
            for (tuple, 0..) |ti, i| {
                const t = try typeCheckExpr(ti, gen);
                els[i] = t;
            }
            return TypePool.intern(.{.tuple = .{.els = els}});
        },
        .named_tuple => |tuple| {
            var els = gen.arena.alloc(Type, tuple.len) catch unreachable;
            var syms = gen.arena.alloc(Type, tuple.len) catch unreachable;
            var set = std.AutoHashMap(Symbol, void).init(gen.arena);
            defer set.deinit();
            for (tuple, 0..) |named_init, i| {
                const t = try typeCheckExpr(named_init.expr, gen);
                const tk = gen.ast.exprs[named_init.expr.idx].tk;
                if (set.contains(named_init.name)) {
                    log.err("{} Duplicate field `{s}` in named tuple initialization", .{gen.ast.to_loc(tk), lookup(named_init.name)});
                    return SemaError.Redefined;
                }
                set.put(named_init.name, {}) catch unreachable;
                els[i] = t;
                syms[i] = named_init.name;
            }
            return TypePool.intern(.{.named = .{.syms = syms, .els = els }});
        },
        .array_access => |aa| {

            const lhs_t = try typeCheckExpr(aa.lhs, gen);
            const rhs = gen.ast.exprs[aa.rhs.idx];
            const lhs_t_full = TypePool.lookup(lhs_t);
            switch (lhs_t_full) {
                .array => |array| {
                    const rhs_t = try typeCheckExpr(aa.rhs, gen);
                    if (rhs_t != TypePool.int) {
                        log.err("{} Index must have type `int`, found `{}`", .{gen.ast.to_loc(expr.tk), rhs_t});
                        return SemaError.TypeMismatched;
                    }
                    return array.el;
                },
                .tuple => |tuple| {
                    if (rhs.data != .atomic or rhs.data.atomic.data != .int) {
                        log.err("{} Tuple can only be directly indexed by int literal", .{gen.ast.to_loc(expr.tk)});
                        return SemaError.TypeMismatched;
                    }
                    const i = rhs.data.atomic.data.int;
                    if (i >= tuple.els.len or i < 0) {
                        log.err("{} Tuple has length {}, but index is {}", .{gen.ast.to_loc(expr.tk), tuple.els.len, i});
                        return SemaError.TypeMismatched;
                    }
                    return tuple.els[@intCast(i)];
                },
                else => {
                    log.err("{} Type `{}` can not be indexed", .{gen.ast.to_loc(expr.tk), lhs_t});
                    log.note("Only type `array` or `tuple` can be indexed", .{});
                    return SemaError.TypeMismatched;
                }
            }


        },
        .field => |fa| {
            const lhs_t = try typeCheckExpr(fa.lhs, gen);
            const lhs_t_full = TypePool.lookup(lhs_t);


            switch (lhs_t_full) {
                .array => {
                    if (fa.rhs == Lexer.len) {
                        return TypePool.int;
                    }
                    log.err("{} Unrecoginized field `{s}` for type `{}`", .{gen.ast.to_loc(expr.tk), lookup(fa.rhs), lhs_t});
                    return SemaError.MissingField;
                },
                .named => |tuple| {
                    for (tuple.syms, tuple.els) |sym, t| {
                        if (fa.rhs ==  sym) return t;
                    }
                    log.err("{} Unrecoginized field `{s}` for type `{}`", .{gen.ast.to_loc(expr.tk), lookup(fa.rhs), lhs_t});
                    return SemaError.MissingField;
                },
                else => {
                    log.err("{} Only type `array` or `struct` can be field accessed, got type `{}`", .{gen.ast.to_loc(expr.tk), lhs_t});
                    return SemaError.TypeMismatched;
                }
            }


        },
    }


}


pub fn typeCheckAtomic(atomic: Atomic, gen: *TypeGen) SemaError!Type {
    switch (atomic.data) {
        .bool => return TypePool.@"bool",
        .float => return TypePool.float,
        .int => return TypePool.int,
        .string => |_| {
            //const len = Lexer.string_pool.lookup(sym).len;
            //return TypePool.intern(TypePool.TypeFull {.array = .{.el = TypePool.char, .size = @intCast(len)}});
            return TypePool.string;
        },
        .iden => |i| {
            if (gen.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{} use of unbound variable `{s}`", .{gen.ast.to_loc(atomic.tk), lookup(i)});
                return SemaError.Undefined;
            }
        },
        .paren => |expr| return typeCheckExpr(expr, gen), 

        .addr => @panic("TODO ADDR"),
    }

}


