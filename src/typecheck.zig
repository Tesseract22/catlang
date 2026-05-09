const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const TypePool = @import("type.zig");
const Type = TypePool.Type;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
const TypeExpr = Ast.TypeExpr;
const Stat = Ast.Stat;
const TopDef = Ast.TopDef;
const ProcDef = Ast.TopDefData.ProcDef;
const VarBind = Ast.VarBind;
const Op = Ast.Op;
pub const Error = Ast.Error || error{ NumOfArgs, Undefined, Redefined, TypeMismatched, EarlyReturn, RightValue, Unresolvable, MissingField };

const Allocator = std.mem.Allocator;
const Symbol = Lexer.Symbol;

const lookup = Lexer.lookup;
const intern = Lexer.intern;

// TODO checks for duplicate function

pub const ScopeItem = struct {
    t: Type,
    off: u32,
};
pub const Scope = std.array_hash_map.Auto(Symbol, ScopeItem);
pub const ScopeStack = struct {
    gpa: Allocator,
    stack: std.ArrayList(Scope),
    pub fn init(gpa: std.mem.Allocator) ScopeStack {
        return ScopeStack{ .gpa = gpa, .stack = .empty };
    }
    pub fn deinit(self: *ScopeStack) void {
        //std.debug.assert(self.stack.items.len == 0);
        for (self.stack.items) |*scope| {
            scope.deinit(self.gpa);
        }
        self.stack.deinit(self.gpa);
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
        self.stack.items[self.stack.items.len - 1].putNoClobber(self.gpa, name, item) catch unreachable;
        return null;
    }
    pub fn exist(self: *ScopeStack, name: Symbol) bool {
        for (self.stack.items) |scope| {
            if (scope.get(name)) |_| return true;
        }
        return false;
    }
    pub fn push(self: *ScopeStack) void {
        self.stack.append(self.gpa, Scope.empty) catch unreachable;
    }
    pub fn pop(self: *ScopeStack) Scope {
        return self.stack.pop().?;
    }
    pub fn popDiscard(self: *ScopeStack) void {
        var scope = self.pop();
        scope.deinit(self.gpa);
    }
};
pub const UseDefs = std.AutoHashMap(Ast.ExprIdx, VarDef);
pub const TypeDefs = std.AutoHashMap(Symbol, Type);
const TypeGen = struct {
    a: Allocator,
    arena: Allocator,
    types: []Type,
    expr_types: []Type,
    typedefs: TypeDefs,
    use_defs: UseDefs,
    sources: *Ast.Sources,
};

const ModuleGen = struct {
    ret_type: Type,
    stack: ScopeStack,
    ast: *const Ast,
    gen: *TypeGen,

    pub fn get_type_expr(module: ModuleGen, idx: Ast.TypeExprIdx) Ast.TypeExpr {
        return module.gen.sources.types[idx.idx];
    }

    pub fn get_type(module: ModuleGen, idx: Ast.TypeExprIdx) Type {
        return module.gen.types[idx.idx];
    }
};

pub fn evalTypeExpr(module: *ModuleGen, type_expr: Ast.TypeExpr) !Type {
    switch (type_expr.data) {
        .ident => |i| {
            return module.gen.typedefs.get(i) orelse {
                log.err("Unknown type `{s}`", .{lookup(i)});
                return Error.Undefined;
            };
        },
        .ptr => |ptr| {
            const el = try reportValidType(module, ptr.el);
            return TypePool.intern(.{ .ptr = .{ .el = el } });
        },
        .array => |array| {
            const el = try reportValidType(module, array.el);
            return TypePool.intern(.{ .array = .{ .el = el, .size = @intCast(array.size) } });
        },
        .tuple => |tuple| {
            const els = module.gen.arena.alloc(Type, tuple.len) catch unreachable;
            for (els, tuple) |*t1, t2| {
                t1.* = try reportValidType(module, t2);
            }
            return TypePool.intern(.{ .tuple = .{ .els = els } });
        },
        .named => |named| {
            const els = module.gen.arena.alloc(Type, named.len) catch unreachable;
            const syms = module.gen.arena.alloc(Type, named.len) catch unreachable;
            for (els, syms, named) |*t, *sym, vs| {
                t.* = try reportValidType(module, vs.type);
                sym.* = vs.name;
            }
            return TypePool.intern(.{ .named = .{ .els = els, .syms = syms } });
        },
        .function => |function| {
            const args = module.gen.arena.alloc(Type, function.args.len) catch unreachable;
            for (args, function.args) |*arg_t, arg_expr| {
                arg_t.* = try reportValidType(module, arg_expr);
            }
            const ret = try reportValidType(module, function.ret);
            return TypePool.intern(.{ .function = .{ .args = args, .ret = ret } });
        },
    }
}

pub fn reportValidType(moudle: *ModuleGen, idx: Ast.TypeExprIdx) Error!Type {
    const te = moudle.get_type_expr(idx);
    const t = evalTypeExpr(moudle, te) catch {
        // TODO: print type expression
        log.err("{f}: `{}` is not valid type", .{ moudle.ast.to_loc(te.tk), te });
        return Error.InvalidType;
    };
    moudle.gen.types[idx.idx] = t;
    return t;
}
// This struct is returned by typeCheck, and used by the code generation
const VarDef = union(enum) {
    stat: Ast.StatIdx,
    arg: u32, // the position of the arguments of the current function
    top: Ast.DefIdx,
};
pub const Sema = struct {
    types: []Type, // each item (a concrete, fully evaluated type) in this slice correspond to each type expression in ast.types
    expr_types: []Type,
    use_defs: UseDefs, // a map from the usage of the variable to the definition of said variable
    top_scope: Scope,
    sources: *Ast.Sources,
};


pub fn typeCheck(sources: *Ast.Sources, a: Allocator, arena: Allocator) Error!Sema {
    var gen = TypeGen {
        .a = a,
        .arena = arena,
        .types = a.alloc(Type, sources.types.len) catch unreachable,
        .expr_types = a.alloc(Type, sources.exprs.len) catch unreachable,
        .typedefs = TypeDefs.init(a),
        .use_defs = UseDefs.init(a),
        .sources = sources,
    };
    // init builtin types
    {
        gen.typedefs.put(Lexer.int, TypePool.int) catch unreachable;
        gen.typedefs.put(Lexer.float, TypePool.float) catch unreachable;
        gen.typedefs.put(Lexer.double, TypePool.double) catch unreachable;
        gen.typedefs.put(Lexer.void, TypePool.void) catch unreachable;
        gen.typedefs.put(Lexer.bool, TypePool.bool) catch unreachable;
        gen.typedefs.put(Lexer.char, TypePool.char) catch unreachable;
    }
    errdefer {
        a.free(gen.types);
        a.free(gen.expr_types);
    }
    defer {
        gen.typedefs.deinit();
    }
    
    const top_scope = try typeCheckModule(Ast.Id.entry, sources, &gen);
    return Sema { .types = gen.types, .expr_types = gen.expr_types, .use_defs = gen.use_defs, .top_scope = top_scope, .sources = sources };
}

pub fn typeCheckModule(id: Ast.Id, sources: *Ast.Sources, gen: *TypeGen) Error!Scope {
    const ast = sources.asts.get(id).?;

    var module = ModuleGen {
        .ast = ast,
        .stack = .init(gen.a),
        .ret_type = undefined,
        .gen = gen,
    };
    defer {
        module.stack.deinit();
    }


    module.stack.push();
    for (ast.defs) |def_idx| {
        const def = sources.defs[def_idx.idx];
        switch (def.data) {
            .proc => |proc| try typeCheckProcSignature(proc, def.tk.off, &module),
            .type => |typedef| {
                if (gen.typedefs.fetchPut(typedef.name, try evalTypeExpr(&module, module.get_type_expr(typedef.type))) catch unreachable) |_| {
                    log.err("{f} duplicate type defs {s}", .{ module.ast.to_loc(def.tk), Lexer.lookup(typedef.name) });
                    return Error.Redefined;
                }
            },
            .foreign => |foreign| {
                const t = try reportValidType(&module, foreign.t);
                if (module.stack.putTop(foreign.name, .{ .t = t, .off = def.tk.off })) |old_fn| {
                    log.err("{f} function `{s}` shadows defination", .{
                        module.ast.to_loc2(def.tk.off),
                        lookup(foreign.name),
                    });
                    log.note("{f} variable previously defined here", .{module.ast.to_loc2(old_fn.off)});
                    return Error.Redefined;
                }
            },
            .import => |import|  {
                var scope = try typeCheckModule(import.id, sources, gen);
                defer scope.deinit(module.stack.gpa);
                var it = scope.iterator();
                while (it.next()) |entry| {
                    const name = entry.key_ptr.*;
                    if (module.stack.putTop(name, entry.value_ptr.*)) |prev| {
                        const module_name = sources.asts.get(import.id).?.lexer.path;
                        log.err("{f} defination `{s}` from `{s}` shadows defination", .{
                            module.ast.to_loc2(def.tk.off),
                            module_name,
                            lookup(name),
                        });
                        log.note("{f} variable previously defined here", .{module.ast.to_loc2(prev.off)});
                        return Error.Redefined;
                    }
                }
            }
        }
    }
    for (ast.defs) |def_idx| {
        const def = sources.defs[def_idx.idx];
        switch (def.data) {
            .proc => |proc| try typeCheckProcBody(proc, def.tk, &module),
            .type, .foreign, .import => {},
        }
    }
    // TODO: rework finding main
    for (ast.defs) |def_idx| {
        const def = sources.defs[def_idx.idx];
        if (def.data == .proc and def.data.proc.name == Lexer.main) {
            if (def.data.proc.args.len != 0) {
                log.err("{f} `main` must have exactly 0 argument", .{ast.to_loc(def.tk)});
                return Error.NumOfArgs;
            }
            if (module.get_type(def.data.proc.ret) != TypePool.void) {
                log.err("{f} `main` must have return type `void`, found {}", .{ ast.to_loc(def.tk), def.data.proc.ret });
            }
            break;
        }
    } else if (id == .entry) {
        log.err("Undefined reference to `main`", .{});
        return Error.Undefined;
    }
    
    return module.stack.pop();
}
// When typechecking the root of a file:
// We first ONLY tyoecheck the signature of the all the function defination, so that they can be referenced by other function bodies later
// This allow the defination and usage of function to be NOT neccessarily in order
pub fn typeCheckProcSignature(proc: ProcDef, off: u32, module: *ModuleGen) Error!void {
    const arg_ts = module.gen.arena.alloc(Type, proc.args.len) catch unreachable;
    module.stack.push();
    for (proc.args, arg_ts) |arg, *arg_t| {
        arg_t.* = try reportValidType(module, arg.type);
        if (module.stack.get(arg.name)) |old_var| {
            log.err("{f} argument of `{s}` `{s}` shadows variable ", .{ module.ast.to_loc(arg.tk), lookup(proc.name), lookup(arg.name) });
            log.note("{f} variable previously defined here", .{module.ast.to_loc2(old_var.off)});
            return Error.Redefined;
        }
    }
    module.stack.popDiscard(); // TODO do something with it
    const signature = TypePool.TypeFull{ .function = .{ .ret = try reportValidType(module, proc.ret), .args = arg_ts } };
    if (module.stack.putTop(proc.name, .{ .t = TypePool.intern(signature), .off = off })) |old_fn| {
        log.err("{f} function `{s}` shadows variable", .{
            module.ast.to_loc2(off),
            lookup(proc.name),
        });
        log.note("{f} variable previously defined here", .{module.ast.to_loc2(old_fn.off)});
        return Error.Redefined;
    }
}
// This functions should be called AFTER typeCheckProcSignature
pub fn typeCheckProcBody(proc: ProcDef, tk: Lexer.Token, module: *ModuleGen) Error!void {
    module.stack.push();
    defer module.stack.popDiscard(); // TODO do something with it
    for (proc.args) |arg| {
        const arg_t = module.get_type(arg.type);
        if (module.stack.putTop(arg.name, .{ .t = arg_t, .off = arg.tk.off })) |old_var| {
            log.err("{f} duplicate arguments of `{s}` `{s}` ", .{ module.ast.to_loc(arg.tk), lookup(proc.name), lookup(arg.name) });
            log.note("{f} argument previously defined here", .{module.ast.to_loc2(old_var.off)});
            return Error.Redefined;
        }
    }
    const ret_t = module.get_type(proc.ret);
    module.ret_type = ret_t;
    for (proc.body, 0..) |stat_idx, i| {
        const stat = &module.gen.sources.stats[stat_idx.idx];
        if (try typeCheckStat(stat_idx, module)) |_| {
            if (i != proc.body.len - 1) {
                log.err("{f} early ret invalids later statement", .{module.ast.to_loc(stat.tk)});
                return Error.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (ret_t != TypePool.void) {
            log.err("{f} `{s}` implicitly return", .{ module.ast.to_loc(tk), lookup(proc.name) });
            return Error.TypeMismatched;
        }
    }
}
pub fn typeCheckBlock(block: []Ast.StatIdx, module: *ModuleGen) Error!?Type {
    module.stack.push();
    defer module.stack.popDiscard();

    return for (block, 0..) |stat_idx, i| {
        const stat = &module.gen.sources.stats[stat_idx.idx];
        if (try typeCheckStat(stat_idx, module)) |ret| {
            if (i != block.len - 1) {
                log.err("{f} early ret invalidates later statement", .{module.ast.to_loc(stat.tk)});
                return Error.EarlyReturn;
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
pub fn typeCheckStat(stat_idx: Ast.StatIdx, module: *ModuleGen) Error!?Type {
    const stat = &module.gen.sources.stats[stat_idx.idx];
    switch (stat.data) {
        .@"if" => |if_stat| {
            const expr_t = try typeCheckExpr(if_stat.cond, module, TypePool.bool);
            if (expr_t != TypePool.bool) {
                log.err("{f} Expect type `bool` in if statment condition, found `{f}`", .{ module.ast.to_loc(stat.tk), TypePool.lookup(expr_t) });
                return Error.TypeMismatched;
            }
            const body_t = try typeCheckBlock(if_stat.body, module);
            const else_t: ?Type = switch (if_stat.else_body) {
                .stats => |stats| try typeCheckBlock(stats, module),
                .else_if => |else_if| try typeCheckStat(else_if, module),
                .none => null,
            };
            return if (body_t != null and else_t != null and body_t.? == else_t.?) body_t else null;
        },
        .anon => |expr| {
            _ = try typeCheckExpr(expr, module, null);
            return null;
        },
        .assign => |assign| {
            const left_t = try typeCheckExpr(assign.left_value, module, null);
            const right_t = try typeCheckExpr(assign.expr, module, left_t);
            if (right_t != left_t) {
                log.err("{f} Assigning to lhs of type `{f}`, but rhs has type `{f}`", .{ module.ast.to_loc(stat.tk), TypePool.lookup(left_t), TypePool.lookup(right_t) });
                return Error.TypeMismatched;
            }
            if (TypePool.lookup(right_t) == .function) {
                log.err("{f} cannot assign function to variale, try taking the address instead", .{module.ast.to_loc(stat.tk)});
                return Error.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(loop.cond, module, TypePool.bool);
            if (expr_t != TypePool.bool) {
                log.err("{} Expect type `bool` in if statment condition, found `{f}`", .{ stat.tk, TypePool.lookup(expr_t) });
                return Error.TypeMismatched;
            }
            for (loop.body) |si| {
                _ = try typeCheckStat(si, module);
            }
            return null;
        },
        .ret => |ret| {
            const ret_t = try typeCheckExpr(ret, module, module.ret_type);
            if (ret_t != module.ret_type) {
                log.err("{f} function has return type `{f}`, but this return statement has `{f}`", .{ module.ast.to_loc(stat.tk), TypePool.lookup(module.ret_type), TypePool.lookup(ret_t) });
                return Error.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            const t = if (var_decl.te) |strong_te| blk: {
                log.debug("type expression {}", .{module.get_type_expr(strong_te)});
                const strong_t = try reportValidType(module, strong_te);
                const expr = var_decl.expr orelse break :blk strong_t;
                const t = try typeCheckExpr(expr, module, strong_t);
                if (strong_t != t) { // TODO coersion betwee different types should be used here (together with as)?
                    log.err("{f} mismatched type in variable decleration {f} and expression {f}", .{ module.ast.to_loc(stat.tk), TypePool.lookup(strong_t), TypePool.lookup(t) });
                    return Error.TypeMismatched;
                }

                break :blk t;
            } else try typeCheckExpr(var_decl.expr.?, module, null);

            if (TypePool.lookup(t) == .function) {
                log.err("{f} cannot assign function to variale, try taking the address instead", .{module.ast.to_loc(stat.tk)});
                return Error.TypeMismatched;
            }
            var_decl.t = t;
            // TODO remove this completely, because the type of the varible declaration is already in gen.types
            //else {
            //    var_decl.t = gen.ast.exprs[var_decl.expr.idx];
            //}
            if (module.stack.putTop(var_decl.name, .{ .t = t, .off = stat.tk.off })) |old_var| {
                log.err("{f} `{s}` is already defined", .{ module.ast.to_loc(stat.tk), lookup(var_decl.name) });
                log.note("{f} previously defined here", .{module.ast.to_loc2(old_var.off)});
                return Error.Redefined;
            }
            return null;
        },
    }
}
pub fn castable(src: Type, dest: Type) bool {
    if (dest == TypePool.number_lit) return false; // TODO: provide specific error message
    if (src == dest) return true;
    if (src == TypePool.float) return dest == TypePool.int or dest == TypePool.double;
    if (src == TypePool.double) return dest == TypePool.int or dest == TypePool.float;
    if (src == TypePool.int) return dest != TypePool.void;
    if (src == TypePool.char) return dest == TypePool.int;
    if (src == TypePool.bool) return dest == TypePool.int;
    if (src == TypePool.void) return false;
    if (src == TypePool.number_lit) return isNumberLike(dest);

    const src_full = TypePool.lookup(src);
    const dest_full = TypePool.lookup(dest);
    switch (src_full) {
        .ptr => return dest_full == .ptr or dest_full == .int,
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

pub fn typeCheckAs(lhs_idx: Ast.ExprIdx, rhs_t: Type, module: *ModuleGen) Error!Type {
    const lhs_t = try typeCheckExpr(lhs_idx, module, null);
    const lhs = module.gen.sources.exprs[lhs_idx.idx];
    //const rhs_t =
    //    if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData)
    //        rhs.data.atomic.data.type
    //    else {
    //        log.err("{} Expect type expression in rhs of `as`", .{gen.ast.to_loc(rhs.tk)});
    //        return SemaError.TypeMismatched;
    //    };
    if (!castable(lhs_t, rhs_t)) {
        log.err("{f} `{f}` can not be casted into `{f}`", .{ module.ast.to_loc(lhs.tk), TypePool.lookup(lhs_t), TypePool.lookup(rhs_t) });

        return Error.TypeMismatched;
    }
    return rhs_t;
}
pub fn typeCheckRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, module: *ModuleGen, infer: ?Type) Error!Type {
    _ = infer;
    var lhs_t = try typeCheckExpr(lhs, module, null);
    const rhs_t = try typeCheckExpr(rhs, module, lhs_t);
    lhs_t = try typeCheckExpr(lhs, module, rhs_t);
    if (lhs_t != rhs_t or (!isNumberLike(lhs_t))) return Error.TypeMismatched;

    return TypePool.bool;
}
pub fn isNumberLike(t: Type) bool {
    return t == TypePool.int or t == TypePool.float or t == TypePool.double or t == TypePool.char;
}
pub fn typeCheckOp(module: *const ModuleGen, op: Ast.Op, lhs_t: Type, rhs_t: Type, off: u32) bool {
    if (op == Ast.Op.as) unreachable;
    if (!isNumberLike(lhs_t)) {
        log.err("{f} Invalid type of operand for `{}`, expect `int`, `double`, or `float`, got {f}", .{ module.ast.to_loc2(off), op, TypePool.lookup(lhs_t) });
        return false;
    }
    if (!isNumberLike(rhs_t)) {
        log.err("{f} Invalid type of operand for `{}`, expect `int`, `double`, or `float`, got {f}", .{ module.ast.to_loc2(off), op, TypePool.lookup(rhs_t) });
        return false;
    }
    // If the one of them is number lit, then the rhs and lhs do not have to match
    //if (lhs_t == TypePool.number_lit or rhs_t == TypePool.number_lit) return true;
    // otherwise, they will have to match
    if (lhs_t != rhs_t) {
        log.err("{f} Invalid type of operand for `{}, lhs has `{f}`, but rhs has `{f}`", .{ module.ast.to_loc2(off), op, TypePool.lookup(lhs_t), TypePool.lookup(rhs_t) });
        return false;
    }
    return true;
}

pub fn typeCheckExpr(expr_idx: Ast.ExprIdx, module: *ModuleGen, infer: ?Type) Error!Type {
    // if (expr_idx.idx == 0) asm volatile ("int3");
    const t = try typeCheckExpr2(expr_idx, module, infer);
    module.gen.expr_types[expr_idx.idx] = t;
    return t;
}

pub fn getCallable(t: Type) ?TypePool.TypeFull.Function {
    switch (TypePool.lookup(t)) {
        .function => |function| return function,
        .ptr => |ptr| {
            const sub_full = TypePool.lookup(ptr.el);
            if (sub_full == .function) return sub_full.function;
            return null;
        },
        else => return null,
    }
}

pub fn typeCheckExpr2(expr_idx: Ast.ExprIdx, module: *ModuleGen, infer: ?Type) Error!Type {
    const sources = module.gen.sources;
    const expr = sources.exprs[expr_idx.idx];
    switch (expr.data) {
        .not => |not| {
            const rhs_t = try typeCheckExpr(not, module, infer);
            if (rhs_t != TypePool.bool) {
                log.err("{f} The rhs of `!` has to be boolean", .{module.ast.to_loc(expr.tk)});
                return Error.TypeMismatched;
            }
            return rhs_t;
        },
        .bool => return TypePool.bool,
        .float => {
            if (infer) |in| {
                if (isFloatLike(in)) return in;
            }
            return TypePool.double;
        },
        .int => {
            if (infer) |in| {
                if (isIntLike(in)) return in;
            }
            return TypePool.int;
        },
        .string => {
            //const len = Lexer.string_pool.lookup(sym).len;
            //return TypePool.intern(TypePool.TypeFull {.array = .{.el = TypePool.char, .size = @intCast(len)}});
            return TypePool.string;
        },
        .iden => |i| {
            if (module.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{f} use of unbound variable `{s}`", .{ module.ast.to_loc(expr.tk), lookup(i) });
                return Error.Undefined;
            }
        },
        .paren => |inner| return typeCheckExpr(inner, module, infer),

        .addr => @panic("TODO ADDR"),

        .as => |as| {
            const rhs_t = try reportValidType(module, as.rhs);
            return typeCheckAs(as.lhs, rhs_t, module);
        },
        .bin_op => |bin_op| {
            switch (bin_op.op) {
                .lt, .gt, .eq => return typeCheckRel(bin_op.lhs, bin_op.rhs, module, infer),
                else => {},
            }
            var lhs_t = try typeCheckExpr(bin_op.lhs, module, null);
            const rhs_t = try typeCheckExpr(bin_op.rhs, module, lhs_t);

            lhs_t = try typeCheckExpr(bin_op.lhs, module, rhs_t);

            if (!typeCheckOp(module, bin_op.op, lhs_t, rhs_t, expr.tk.off)) return Error.TypeMismatched;

            log.debug("bin_op lhs: {}, lhs: {f}({})", .{ bin_op.lhs.idx, TypePool.lookup(lhs_t), lhs_t });
            return lhs_t;
        },
        .fn_app => |fn_app| {
            // const func_expr = gen.ast.exprs[fn_app.func.idx];
            // if (func_expr.data == .iden and func_expr.data.iden == intern("print")) {
            //     if (fn_app.args.len != 1) {
            //         std.log.err("{f} builtin function `print` expects exactly one argument", .{gen.ast.to_loc(expr.tk)});
            //         return Error.TypeMismatched;
            //     }
            //     const arg_t = try typeCheckExpr(fn_app.args[0], gen, infer);
            //     const arg_full_t = TypePool.lookup(arg_t);
            //     switch (arg_full_t) {
            //         .array => |array| {
            //             _ = array;
            //             //if (array.el != TypePool.char) {
            //             //    log.err("{} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
            //             //    return SemaError.TypeMismatched;
            //             //}

            //             log.err("{f} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
            //             return Error.TypeMismatched;
            //         },
            //         .tuple, .named, .void => {
            //             log.err("{f} Value of type `array` can not be printed", .{gen.ast.to_loc(expr.tk)});
            //             return Error.TypeMismatched;
            //         },
            //         else => {},
            //     }
            //     return TypePool.void;
            // }
            // TODO use a map instead, also checks for duplicate
            const lhs_type = try typeCheckExpr(fn_app.func, module, null);
            const fn_type = getCallable(lhs_type) orelse {
                log.err("{f} type `{f}` is not callable", .{ module.ast.to_loc(expr.tk), TypePool.lookup(lhs_type) });
                return Error.TypeMismatched;
            };

            if (fn_type.args.len != fn_app.args.len) {
                log.err("{f} expected {} arguments, got {}", .{ module.ast.to_loc(expr.tk), fn_type.args.len, fn_app.args.len });
                //log.note("{} function argument defined here", .{ gen.ast.to_loc2(fn_item.off)});
                return Error.TypeMismatched;
            }

            for (fn_type.args, fn_app.args, 0..) |fd, fa, i| {
                const e_type = try typeCheckExpr(fa, module, fd);
                if (e_type != fd) {
                    log.err("{f} {} argument expected type `{f}`, got type `{f}`",
                        .{ module.ast.to_loc(sources.exprs[fa.idx].tk), i, TypePool.lookup(fd), TypePool.lookup(e_type) });
                    return Error.TypeMismatched;
                }
            }

            return fn_type.ret;
        },
        .addr_of => |addr_of| {
            const expr_addr = sources.exprs[addr_of.idx];
            if (expr_addr.data != .iden) {
                log.err("{f} Cannot take the address of right value", .{module.ast.to_loc(expr_addr.tk)});
                return Error.RightValue;
            }
            const t = try typeCheckExpr(addr_of, module, infer);
            return TypePool.type_pool.address_of(t);
        },
        .deref => |deref| {
            const t = try typeCheckExpr(deref, module, infer);
            const t_full = TypePool.lookup(t);
            if (t_full != .ptr) {
                const expr_deref = sources.exprs[deref.idx];
                log.err("{f} Cannot dereference non-ptr type `{}`", .{ module.ast.to_loc(expr_deref.tk), t });
                return Error.TypeMismatched;
            }
            return t_full.ptr.el;
        },
        .array => |array| {
            if (array.len < 1) {
                log.err("{f} Array must have at least one element to resolve its type", .{module.ast.to_loc(expr.tk)});
                return Error.Unresolvable;
            }
            const first_expr = sources.exprs[array[0].idx];
            const el_infer: ?Type = if (infer) |in| blk: {
                const in_full = TypePool.lookup(in);
                switch (in_full) {
                    .array => |array_t| break :blk array_t.el,
                    else => break :blk null,
                }
            } else null;
            const t = try typeCheckExpr(array[0], module, el_infer);
            for (array[1..], 2..) |e, i| {
                const el_t = try typeCheckExpr(e, module, el_infer);
                if (t != el_t) {
                    const el_expr = sources.exprs[e.idx];
                    log.err("{f} Array element has different type than its 1st element", .{module.ast.to_loc(el_expr.tk)});
                    log.note("1st element has type `{f}`, but {}th element has type `{f}`", .{ TypePool.lookup(t), i, TypePool.lookup(el_t) });
                    log.note("{f} 1st expression defined here", .{module.ast.to_loc(first_expr.tk)});
                    return Error.TypeMismatched;
                }
            }
            const array_full = TypePool.TypeFull{ .array = .{ .el = t, .size = @intCast(array.len) } };
            return TypePool.intern(array_full);
        },
        .tuple => |tuple| {
            var els = module.gen.arena.alloc(Type, tuple.len) catch unreachable;
            if (infer) |infer_type| {
                switch (TypePool.lookup(infer_type)) {
                    .tuple => |infer_tuple| {
                        for (tuple, infer_tuple.els, 0..) |ti, infer_el_type, i| {
                            const t = try typeCheckExpr(ti, module, infer_el_type);
                            els[i] = t;
                        }
                        return TypePool.intern(.{ .tuple = .{ .els = els } });
                    },
                    else => {},
                }
            }
            for (tuple, 0..) |ti, i| {
                const t = try typeCheckExpr(ti, module, null);
                els[i] = t;
            }
            return TypePool.intern(.{ .tuple = .{ .els = els } });
        },
        .named_tuple => |tuple| {
            var els = module.gen.arena.alloc(Type, tuple.len) catch unreachable;
            var syms = module.gen.arena.alloc(Type, tuple.len) catch unreachable;
            var set = std.AutoHashMap(Symbol, void).init(module.gen.arena);
            defer set.deinit();
            for (tuple, 0..) |named_init, i| {
                const t = try typeCheckExpr(named_init.expr, module, infer);
                const tk = sources.exprs[named_init.expr.idx].tk;
                if (set.contains(named_init.name)) {
                    log.err("{f} Duplicate field `{s}` in named tuple initialization", .{ module.ast.to_loc(tk), lookup(named_init.name) });
                    return Error.Redefined;
                }
                set.put(named_init.name, {}) catch unreachable;
                els[i] = t;
                syms[i] = named_init.name;
            }
            return TypePool.intern(.{ .named = .{ .syms = syms, .els = els } });
        },
        .array_access => |aa| {
            const lhs_t = try typeCheckExpr(aa.lhs, module, infer);
            const rhs = sources.exprs[aa.rhs.idx];
            const lhs_t_full = TypePool.lookup(lhs_t);
            switch (lhs_t_full) {
                .array => |array| {
                    const rhs_t = try typeCheckExpr(aa.rhs, module, TypePool.int);
                    if (rhs_t != TypePool.int) {
                        log.err("{f} Index must have type `int`, found `{f}`", .{ module.ast.to_loc(expr.tk), TypePool.lookup(rhs_t) });
                        return Error.TypeMismatched;
                    }
                    return array.el;
                },
                .tuple => |tuple| {
                    if (rhs.data != .int) {
                        log.err("{f} Tuple can only be directly indexed by int literal", .{module.ast.to_loc(expr.tk)});
                        return Error.TypeMismatched;
                    }
                    const i = rhs.data.int;
                    if (i >= tuple.els.len or i < 0) {
                        log.err("{f} Tuple has length {}, but index is {}", .{ module.ast.to_loc(expr.tk), tuple.els.len, i });
                        return Error.TypeMismatched;
                    }
                    return tuple.els[@intCast(i)];
                },
                else => {
                    log.err("{f} Type `{f}` can not be indexed", .{ module.ast.to_loc(expr.tk), TypePool.lookup(lhs_t) });
                    log.note("Only type `array` or `tuple` can be indexed", .{});
                    return Error.TypeMismatched;
                },
            }
        },
        .field => |fa| {
            const lhs_t = try typeCheckExpr(fa.lhs, module, infer);
            const lhs_t_full = TypePool.lookup(lhs_t);

            switch (lhs_t_full) {
                .array => {
                    if (fa.rhs == Lexer.len) {
                        return TypePool.int;
                    }
                    log.err("{f} Unrecoginized field `{s}` for type `{f}`", .{ module.ast.to_loc(expr.tk), lookup(fa.rhs), TypePool.lookup(lhs_t) });
                    return Error.MissingField;
                },
                .named => |tuple| {
                    for (tuple.syms, tuple.els) |sym, t| {
                        if (fa.rhs == sym) return t;
                    }
                    log.err("{f} Unrecoginized field `{s}` for type `{f}`", .{ module.ast.to_loc(expr.tk), lookup(fa.rhs), TypePool.lookup(lhs_t) });
                    return Error.MissingField;
                },
                else => {
                    log.err("{f} Only type `array` or `struct` can be field accessed, got type `{f}`", .{ module.ast.to_loc(expr.tk), TypePool.lookup(lhs_t) });
                    return Error.TypeMismatched;
                },
            }
        },
    }
}

pub fn isFloatLike(t: Type) bool {
    return t == TypePool.float or t == TypePool.double;
}
pub fn isIntLike(t: Type) bool {
    return t == TypePool.int or t == TypePool.char;
}

pub fn typeCheckAtomic(atomic: Ast.Atomic, gen: *TypeGen, infer: ?Type) Error!Type {
    switch (atomic.data) {
        .bool => return TypePool.bool,
        .float => {
            if (infer) |in| {
                if (isFloatLike(in)) return in;
            }
            return TypePool.double;
        },
        .int => {
            if (infer) |in| {
                if (isIntLike(in)) return in;
            }
            return TypePool.int;
        },
        .string => {
            //const len = Lexer.string_pool.lookup(sym).len;
            //return TypePool.intern(TypePool.TypeFull {.array = .{.el = TypePool.char, .size = @intCast(len)}});
            return TypePool.string;
        },
        .iden => |i| {
            if (gen.stack.get(i)) |item| {
                return item.t;
            } else {
                log.err("{} use of unbound variable `{s}`", .{ gen.ast.to_loc(atomic.tk), lookup(i) });
                return Error.Undefined;
            }
        },
        .paren => |expr| return typeCheckExpr(expr, gen, infer),

        .addr => @panic("TODO ADDR"),
    }
}
