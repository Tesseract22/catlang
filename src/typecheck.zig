const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("ast.zig");
const log = @import("log.zig");
const Lexer = @import("lexer.zig");
const TypePool = @import("type.zig");
const Type = TypePool.Type;
const Atomic = Ast.Atomic;
const Expr = Ast.Expr;
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

const Value = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub fn fromType(t: Type) Value {
        return @enumFromInt(@intFromEnum(t));
    }

    pub fn asType(v: Value) Type {
        return @enumFromInt(@intFromEnum(v));
    }
};

pub const ScopeItem = struct {
    t: Type,
    comptime_v: Value,
    from: ?struct {
        module: Ast.Id, // points to the original defination of the item, no matter how much import there is.
        off: u32, // the offset of that declaration within that module.
    },
    import_off: ?u32, // the immediate import that introduce this item. If the item is defined in the same file, this is null.
    define: VarDef, // A reference to the ast node that defines this item.

    pub fn builtin_type(t: Type) ScopeItem {
        return .{
            .t = TypePool.type,
            .comptime_v = .fromType(t),
            .from = null,
            .import_off = null,
            .define =  undefined,
        };
    }
};
pub const Scope = std.array_hash_map.Auto(Symbol, ScopeItem);
pub const ScopeStack = struct {
    gpa: Allocator,
    builtin_scope: *Scope,
    stack: std.ArrayList(Scope),
    pub fn init(gpa: std.mem.Allocator, builtin: *Scope) ScopeStack {
        return ScopeStack{ .gpa = gpa, .builtin_scope = builtin, .stack = .empty };
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
        } else self.builtin_scope.get(name);
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
pub const TypedValue = struct {
    t: Type,
    v: Value,
};
pub const UseDefs = std.AutoHashMap(Ast.ExprIdx, VarDef);
const TypeGen = struct {
    gpa: Allocator,
    arena: Allocator,
    expr_vals: []TypedValue,
    use_defs: UseDefs,
    builtin_scope: Scope,
    module_cache: std.array_hash_map.Auto(Ast.Id, Scope),
    sources: *Ast.Sources,

    pub fn report(self: TypeGen, off: u32, id: Ast.Id, level: log.Level, comptime fmt: []const u8, args: anytype) void {
        self.sources.asts.get(id).?.lexer.report(off, level, fmt, args);
    }

    pub fn report_err(self: TypeGen, id: Ast.Id, off: u32, comptime fmt: []const u8, args: anytype) void {
        self.sources.asts.get(id).?.lexer.report_err(off, fmt, args);
    }
};

const ModuleGen = struct {
    id: Ast.Id,
    ret_type: Type,
    stack: ScopeStack,
    ast: *const Ast,
    gen: *TypeGen,

    pub fn get_type(module: ModuleGen, idx: Ast.ExprIdx) Type {
        const tv = module.gen.expr_vals[idx.idx];
        assert(tv.t == TypePool.type);
        return tv.v.asType();
    }

    pub fn report(self: ModuleGen, off: u32, level: log.Level, comptime fmt: []const u8, args: anytype) void {
        self.ast.lexer.report(off, level, fmt, args);
    }

    pub fn report_err(self: ModuleGen, off: u32, comptime fmt: []const u8, args: anytype) void {
        self.ast.lexer.report_err(off, fmt, args);
    }

    pub fn report_redefined(self: ModuleGen, prev: ScopeItem) void {
        if (prev.import_off) |off| self.report(off, .note, "Previous defination imported here", .{});
        if (prev.from) |from|
            self.gen.report(from.off, from.module, .note, "defined here", .{})
        else
            log.note("this is a builtin variable/type name", .{});
    }
};

// TODO: use a scratch buffer?
pub fn evalExpr(module: *ModuleGen, type_expr_idx: Ast.ExprIdx) !Type {
    const type_expr = module.gen.sources.exprs[type_expr_idx.idx];
    //const Static = struct {
    //    pub var arena: ?std.heap.ArenaAllocator = null;
    //};
    //if (Static.arena == null) Static.arena = .init(module.gen.arena);
    //_ = Static.arena.?.reset(.retain_capacity);
    //const arena = Static.arena.?.allocator();
    const arena = module.gen.arena;
    const off =  type_expr.tk.off;
    switch (type_expr.data) {
        .iden => |i| {
            const item = module.stack.get(i) orelse {
                module.report_err(off, "Unknown type `{s}`", .{lookup(i)});
                return Error.Undefined;
            };
            if (item.t != TypePool.type) {
                module.report_err(off, "{s} does not refer to a type, but a {f} instead", .{ lookup(i), item.t });
                return Error.InvalidType;
            }
            return item.comptime_v.asType();
        },
        .type_ptr => |ptr| {
            const el = try reportValidType(module, ptr.el);
            return TypePool.intern(.{ .ptr = .{ .el = el } });
        },
        .type_array => |array| {
            const el = try reportValidType(module, array.el);
            return TypePool.intern(.{ .array = .{ .el = el, .size = @intCast(array.size) } });
        },
        .type_tuple => |tuple| {
            const els = arena.alloc(Type, tuple.len) catch unreachable;
            for (els, tuple) |*t1, t2| {
                t1.* = try reportValidType(module, t2);
            }
            return TypePool.intern(.{ .tuple = .{ .els = els } });
        },
        .type_named => |named| {
            const els = arena.alloc(Type, named.len) catch unreachable;
            const syms = arena.alloc(Symbol, named.len) catch unreachable;
            for (els, syms, named) |*t, *sym, vs| {
                t.* = try reportValidType(module, vs.type);
                sym.* = vs.name;
            }
            return TypePool.intern(.{ .named = .{ .els = els, .syms = syms } });
        },
        .type_function => |function| {
            const args = arena.alloc(Type, function.args.len) catch unreachable;
            for (args, function.args) |*arg_t, arg_expr| {
                arg_t.* = try reportValidType(module, arg_expr);
            }
            const ret = try reportValidType(module, function.ret);
            return TypePool.intern(.{ .function = .{ .args = args, .ret = ret } });
        },
        .type_subset => |subset| {
            var set =  std.hash_map.AutoHashMap(Symbol, u32).init(arena);
            const sub_t = try reportValidType(module, subset.sub_t);
            const syms = arena.alloc(Symbol, subset.fields.len) catch unreachable;
            const vals = arena.alloc(u32, subset.fields.len) catch unreachable;
            for (subset.fields, syms, vals) |field, *sym, *val| {
                if (set.fetchPut(field.name, field.tk.off) catch @panic("OOM")) |prev| {
                    module.report_err(field.tk.off, "Duplicate field `{s}` in subset", .{ lookup(field.name) });
                    module.report(prev.value, .note, "field previously defined here", .{});
                    return Error.Redefined;
                }
                sym.* = field.name;
                const val_expr = module.gen.sources.exprs[field.expr.idx];
                if (val_expr.data != .int) {
                    module.report_err(val_expr.tk.off, "Only int literal is allowed as the value of a subset field for now", .{});
                    return Error.InvalidType;
                }
                val.* = @intCast(val_expr.data.int);
            }
            return TypePool.intern(.{ .subset = .{ .sub_t = sub_t, .syms = syms, .vals = vals }});
        },
        else => {
            // module.report_err(type_expr.tk.off, "Expect type expression, found {s}", .{ @tagName(type_expr.data) });
            return Error.InvalidType;
        },
    }
}

pub fn reportValidType(module: *ModuleGen, expr_idx: Ast.ExprIdx) Error!Type {
    const te = module.gen.sources.exprs[expr_idx.idx];
    const t = evalExpr(module, expr_idx) catch |e| {
        // TODO: print type expression
        module.report_err(te.tk.off, "`{s}` is not a valid type", .{@tagName(te.data)});
        return e;
    };
    module.gen.expr_vals[expr_idx.idx] = .{ .t = TypePool.type, .v = .fromType(t) };
    return t;
}
// This struct is returned by typeCheck, and used by the code generation
pub const VarDef = union(enum) {
    arg: struct { proc: *const Ast.TopDefData.ProcDef, num: u32 },
    let: *const Ast.StatData.VarDecl,
    proc: *const Ast.TopDefData.ProcDef,
    foreign: *const Ast.TopDefData.Foreign,

    const Self = @This();
};

pub const Sema = struct {
    vals: []TypedValue, // each item (a concrete, fully evaluated type) in this slice correspond to each type expression in ast.types
    use_defs: UseDefs, // a map from the usage of the variable to the definition of said variable
    top_scope: Scope,
    sources: *Ast.Sources,
};


pub fn typeCheck(sources: *Ast.Sources, gpa: Allocator, arena: Allocator) Error!Sema {
    var gen = TypeGen {
        .gpa = gpa,
        .arena = arena,
        .expr_vals = gpa.alloc(TypedValue, sources.exprs.len) catch unreachable,
        .use_defs = UseDefs.init(gpa),
        .builtin_scope = .empty,
        .module_cache = .empty,
        .sources = sources,
    };
    // init builtin types
    {
        gen.builtin_scope.put(gpa, Lexer.int, .builtin_type(TypePool.int)) catch unreachable;
        gen.builtin_scope.put(gpa, Lexer.float, .builtin_type(TypePool.float)) catch unreachable;
        gen.builtin_scope.put(gpa, Lexer.double, .builtin_type(TypePool.double)) catch unreachable;
        gen.builtin_scope.put(gpa, Lexer.void, .builtin_type(TypePool.void)) catch unreachable;
        gen.builtin_scope.put(gpa, Lexer.bool, .builtin_type(TypePool.bool)) catch unreachable;
        gen.builtin_scope.put(gpa, Lexer.char, .builtin_type(TypePool.char)) catch unreachable;
    }
    errdefer {
        gpa.free(gen.expr_vals);
    }
    defer {
        gen.builtin_scope.deinit(gpa);
        gen.module_cache.deinit(gpa);
    }

    // TODO: cached the result of already checked module
    // const builtin_scope = try typeCheckModule(Ast.Id.builtin, sources, gen);
    // _ = builtin_scope;
    // const arch_type = gen.typedefs.get(intern("Arch"));
    // const os_type = gen.typedefs.get(intern("Os"));
    const top_scope = try typeCheckModule(Ast.Id.entry, sources, &gen);
    return Sema { .vals = gen.expr_vals, .use_defs = gen.use_defs, .top_scope = top_scope, .sources = sources };
}

pub fn typeCheckModule(id: Ast.Id, sources: *Ast.Sources, gen: *TypeGen) Error!Scope {
    const ast = sources.asts.get(id).?;

    var module = ModuleGen {
        .id = id,
        .ast = ast,
        .stack = .init(gen.gpa, &gen.builtin_scope),
        .ret_type = .invalid,
        .gen = gen,
    };
    defer {
        module.stack.deinit();
    }


    module.stack.push();
    for (ast.defs) |def_idx| {
        const def = &sources.defs[def_idx.idx];
        const off = def.tk.off;
        switch (def.data) {
            .proc => |*proc| try typeCheckProcSignature(proc, off, &module),
            .type => |typedef| {
                const t = try evalExpr(&module, typedef.type);
                if (module.stack.putTop(typedef.name, .{
                    .t = TypePool.type,
                    .comptime_v = .fromType(t),
                    .from = .{ .off = off, .module = id  },
                    .import_off = null,
                    .define = undefined,
                })) |prev| {
                    module.report_err(off, "duplicate type defs {s}", .{ Lexer.lookup(typedef.name) });
                    module.report_redefined(prev);
                    return Error.Redefined;
                }
            },
            .foreign => |*foreign| {
                const t = try reportValidType(&module, foreign.t);
                if (module.stack.putTop(foreign.name,
                        .{ .t = t, .comptime_v = .invalid, .from = .{ .off = off, .module = id, }, .import_off = null, .define = .{ .foreign = foreign } })) |prev| {
                    module.report_err(off, "function `{s}` shadows defination", .{lookup(foreign.name)});
                    module.report_redefined(prev);
                    return Error.Redefined;
                }
            },
            .import => |import|  {
                const gop = gen.module_cache.getOrPut(gen.gpa, import.id) catch @panic("OOM");
                var scope =
                    if (gop.found_existing)
                        gop.value_ptr.*
                    else blk: {
                        const scope = try typeCheckModule(import.id, sources, gen);
                        gop.value_ptr.* = scope;
                        break :blk scope;
                    };
                var it = scope.iterator();
                while (it.next()) |entry| {
                    const name = entry.key_ptr.*;
                    const scope_item = entry.value_ptr;
                    scope_item.import_off = off;
                    if (module.stack.putTop(name, scope_item.*)) |prev| {
                        if (prev.from != null and prev.from.?.module == scope_item.from.?.module) continue;
                        const module_name = sources.asts.get(import.id).?.lexer.path;
                        module.report_err(scope_item.import_off.?, "imported `{s}` from `{s}` shadows defination", .{ lookup(name), module_name });
                        const from = scope_item.from.?;
                        gen.report(from.off, from.module, .note, "new defination is originally defined here", .{});
                        module.report_redefined(prev);
                        return Error.Redefined;
                    }
                }
            }
        }
    }
    for (ast.defs) |def_idx| {
        const def = &sources.defs[def_idx.idx];
        switch (def.data) {
            .proc => |*proc| try typeCheckProcBody(proc, def.tk, &module),
            .type, .foreign, .import => {},
        }
    }
    // TODO: rework finding main
    for (ast.defs) |def_idx| {
        const def = sources.defs[def_idx.idx];
        if (def.data == .proc and def.data.proc.name == Lexer.main) {
            if (def.data.proc.args.len != 0) {
                module.report_err(def.tk.off, "`main` must have exactly 0 argument", .{});
                return Error.NumOfArgs;
            }
            if (module.get_type(def.data.proc.ret) != TypePool.void) {
                module.report_err(def.tk.off, "`main` must have return type `void`, found {}", .{def.data.proc.ret});
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
pub fn typeCheckProcSignature(proc: *const ProcDef, off: u32, module: *ModuleGen) Error!void {
    const arg_ts = module.gen.arena.alloc(Type, proc.args.len) catch unreachable;
    module.stack.push();
    for (proc.args, arg_ts) |arg, *arg_t| {
        arg_t.* = try reportValidType(module, arg.type);
        if (module.stack.get(arg.name)) |prev| {
            module.report_err(arg.tk.off, "argument of `{s}` `{s}` shadows variable ", .{ lookup(proc.name), lookup(arg.name) });
            module.report_redefined(prev);
            return Error.Redefined;
        }
    }
    module.stack.popDiscard(); // TODO do something with it
    const signature = TypePool.TypeFull{ .function = .{ .ret = try reportValidType(module, proc.ret), .args = arg_ts } };
    if (module.stack.putTop(proc.name, .{ .t = TypePool.intern(signature), .comptime_v = .invalid,
        .from = .{ .off =  off, .module = module.id, }, .import_off = null, .define = .{ .proc = proc } })) |prev| {
        module.report_err(off, "function `{s}` shadows variable", .{lookup(proc.name)});
        module.report_redefined(prev);
        return Error.Redefined;
    }
}
// This functions should be called AFTER typeCheckProcSignature
pub fn typeCheckProcBody(proc: *const ProcDef, tk: Lexer.Token, module: *ModuleGen) Error!void {
    module.stack.push();
    defer module.stack.popDiscard(); // TODO do something with it
    for (proc.args, 0..) |arg, i| {
        const arg_t = module.get_type(arg.type);
        if (module.stack.putTop(arg.name, .{ .t = arg_t, .comptime_v = .invalid,
            .from = .{ .off =  tk.off, .module = module.id, }, .import_off = null, .define = .{ .arg = .{ .proc = proc, .num = @intCast(i) } }})) |prev| {
            module.report_err(arg.tk.off, "duplicate arguments of `{s}` `{s}` ", .{ lookup(proc.name), lookup(arg.name) });
            module.report_redefined(prev);
            return Error.Redefined;
        }
    }
    const ret_t = module.get_type(proc.ret);
    module.ret_type = ret_t;
    for (proc.body, 0..) |stat_idx, i| {
        const stat = &module.gen.sources.stats[stat_idx.idx];
        if (try typeCheckStat(stat_idx, module)) |_| {
            if (i != proc.body.len - 1) {
                module.report_err(stat.tk.off, "early ret invalids later statement", .{});
                return Error.EarlyReturn;
            } else {
                break;
            }
        }
    } else {
        if (ret_t != TypePool.void) {
            module.report_err(tk.off, "`{s}` implicitly return", .{ lookup(proc.name) });
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
                module.report_err(stat.tk.off, "early ret invalidates later statement", .{});
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
                module.report_err(stat.tk.off, "Expect type `bool` in if statment condition, found `{f}`", .{ expr_t });
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
                module.report_err(stat.tk.off, "Assigning to lhs of type `{f}`, but rhs has type `{f}`", .{ left_t, right_t });
                return Error.TypeMismatched;
            }
            if (TypePool.lookup(right_t) == .function) {
                module.report_err(stat.tk.off, "cannot assign function to variale, try taking the address instead", .{});
                return Error.TypeMismatched;
            }
            return null;
        },
        .loop => |loop| {
            const expr_t = try typeCheckExpr(loop.cond, module, TypePool.bool);
            if (expr_t != TypePool.bool) {
                module.report_err(stat.tk.off, "Expect type `bool` in if statment condition, found `{f}`", .{expr_t});
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
                module.report_err(stat.tk.off, "function has return type `{f}`, but this return statement has `{f}`", .{ module.ret_type, ret_t });
                return Error.TypeMismatched;
            }
            return ret_t;
        },
        .var_decl => |*var_decl| {
            const t = if (var_decl.te) |strong_te| blk: {
                const strong_t = try reportValidType(module, strong_te);
                const expr = var_decl.expr orelse break :blk strong_t;
                const t = try typeCheckExpr(expr, module, strong_t);
                if (strong_t != t) { // TODO coersion betwee different types should be used here (together with as)?
                    module.report_err(stat.tk.off, "mismatched type in variable decleration {f} and expression {f}", .{ strong_t, t });
                    return Error.TypeMismatched;
                }

                break :blk t;
            } else try typeCheckExpr(var_decl.expr.?, module, null);

            if (TypePool.lookup(t) == .function) {
                module.report_err(stat.tk.off, "cannot assign function to variale, try taking the address instead", .{});
                return Error.TypeMismatched;
            }
            var_decl.t = t;
            // TODO remove this completely, because the type of the varible declaration is already in gen.types
            //else {
            //    var_decl.t = gen.ast.exprs[var_decl.expr.idx];
            //}
            if (module.stack.putTop(var_decl.name, .{ .t = t, .comptime_v = .invalid,
                .from = .{ .off = stat.tk.off, .module = module.id, }, .import_off = null, .define = .{ .let = var_decl } })) |prev| {
                module.report_err(stat.tk.off, "`{s}` is already defined", .{ lookup(var_decl.name) });
                module.report_redefined(prev);
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
        .subset => |subset| return subset.sub_t ==  dest or castable(subset.sub_t, dest),
        .tuple, .array => return false,
        else => return false,
    }
}

pub fn typeCheckAs(lhs_idx: Ast.ExprIdx, rhs_t: Type, module: *ModuleGen) Error!Type {
    const lhs_t = try typeCheckExpr(lhs_idx, module, null);
    const lhs = module.gen.sources.exprs[lhs_idx.idx];
    if (!castable(lhs_t, rhs_t)) {
        module.report_err(lhs.tk.off, "`{f}` can not be casted into `{f}`", .{ lhs_t, rhs_t });

        return Error.TypeMismatched;
    }
    return rhs_t;
}
pub fn typeCheckRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, module: *ModuleGen, infer: ?Type) Error!Type {
    _ = infer;
    var lhs_t = try typeCheckExpr(lhs, module, null);
    const rhs_t = try typeCheckExpr(rhs, module, lhs_t);
    lhs_t = try typeCheckExpr(lhs, module, rhs_t);
    if (lhs_t != rhs_t or (!isNumberLike(lhs_t))) {
        module.report_err(module.gen.sources.exprs[lhs.idx].tk.off, "expression of different type cannot be compared", .{});
        module.report(module.gen.sources.exprs[lhs.idx].tk.off, .note, "lhs is `{f}`", .{lhs_t});
        module.report(module.gen.sources.exprs[rhs.idx].tk.off, .note, "rhs is `{f}`", .{rhs_t});
        return Error.TypeMismatched;
    }

    return TypePool.bool;
}
pub fn isNumberLike(t: Type) bool {
    if (t == TypePool.int or t == TypePool.float or t == TypePool.double or t == TypePool.char) return true;
    return switch (TypePool.lookup(t)) {
        .subset => |subset| isNumberLike(subset.sub_t),
        else => false
    };
}
pub fn typeCheckOp(module: *const ModuleGen, op: Ast.Op, lhs_t: Type, rhs_t: Type, off: u32) bool {
    if (op == Ast.Op.as) unreachable;
    if (!isNumberLike(lhs_t)) {
        module.report_err(off, "Invalid type of operand for `{}`, expect `int`, `double`, or `float`, got {f}", .{ op, lhs_t });
        return false;
    }
    if (!isNumberLike(rhs_t)) {
        module.report_err(off, "Invalid type of operand for `{}`, expect `int`, `double`, or `float`, got {f}", .{ op, rhs_t });
        return false;
    }
    // If the one of them is number lit, then the rhs and lhs do not have to match
    //if (lhs_t == TypePool.number_lit or rhs_t == TypePool.number_lit) return true;
    // otherwise, they will have to match
    if (lhs_t != rhs_t) {
        module.report_err(off, "Invalid type of operand for `{}, lhs has `{f}`, but rhs has `{f}`", .{ op, lhs_t, rhs_t });
        return false;
    }
    return true;
}

pub fn typeCheckExpr(expr_idx: Ast.ExprIdx, module: *ModuleGen, infer: ?Type) Error!Type {
    // if (expr_idx.idx == 0) asm volatile ("int3");
    const t = try typeCheckExpr2(expr_idx, module, infer);
    module.gen.expr_vals[expr_idx.idx] = .{ .t = t, .v = .invalid };
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
                module.report_err(expr.tk.off, "The rhs of `!` has to be boolean", .{});
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
                module.gen.use_defs.put(expr_idx, item.define) catch @panic("OOM");
                return item.t;
            } else {
                module.report_err(expr.tk.off, "use of unbound variable `{s}`", .{ lookup(i) });
                return Error.Undefined;
            }
        },
        .paren => |inner| return typeCheckExpr(inner, module, infer),

        .addr => @panic("TODO ADDR"),
        .bin_op => |bin_op| {
            switch (bin_op.op) {
                .lt, .gt, .eq => return typeCheckRel(bin_op.lhs, bin_op.rhs, module, infer),
                .as => {
                    const rhs_t = try reportValidType(module, bin_op.rhs);
                    return typeCheckAs(bin_op.lhs, rhs_t, module);
                },
                else => {},
            }
            var lhs_t = try typeCheckExpr(bin_op.lhs, module, null);
            const rhs_t = try typeCheckExpr(bin_op.rhs, module, lhs_t);

            lhs_t = try typeCheckExpr(bin_op.lhs, module, rhs_t);

            if (!typeCheckOp(module, bin_op.op, lhs_t, rhs_t, expr.tk.off)) return Error.TypeMismatched;

            return lhs_t;
        },
        .fn_app => |fn_app| {
            const lhs_type = try typeCheckExpr(fn_app.func, module, null);
            const fn_type = getCallable(lhs_type) orelse {
                module.report_err(expr.tk.off, "type `{f}` is not callable", .{ lhs_type });
                return Error.TypeMismatched;
            };

            if (fn_type.args.len != fn_app.args.len) {
                module.report_err(expr.tk.off, "expected {} arguments, got {}", .{ fn_type.args.len, fn_app.args.len });
                //log.note("{} function argument defined here", .{ gen.ast.to_loc2(fn_item.off)});
                return Error.TypeMismatched;
            }

            for (fn_type.args, fn_app.args, 0..) |fd, fa, i| {
                const e_type = try typeCheckExpr(fa, module, fd);
                if (e_type != fd) {
                    module.report_err(sources.exprs[fa.idx].tk.off, "expected type `{f}` for {}th argument, got type `{f}`", .{ fd, i, e_type });
                    return Error.TypeMismatched;
                }
            }

            return fn_type.ret;
        },
        .addr_of => |addr_of| {
            const expr_addr = sources.exprs[addr_of.idx];
            if (expr_addr.data != .iden) {
                module.report_err(expr_addr.tk.off, "Cannot take the address of right value", .{});
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
                module.report_err(expr_deref.tk.off, "Cannot dereference non-ptr type `{}`", .{ t });
                return Error.TypeMismatched;
            }
            return t_full.ptr.el;
        },
        .array => |array| {
            if (array.len < 1) {
                module.report_err(expr.tk.off, "Array must have at least one element to resolve its type", .{});
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
                    module.report_err(el_expr.tk.off, "Array element has different type than its 1st element", .{});
                    log.note("1st element has type `{f}`, but {}th element has type `{f}`", .{ t, i, el_t });
                    module.report(first_expr.tk.off, .note, "1st expression defined here", .{});
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
            var syms = module.gen.arena.alloc(Symbol, tuple.len) catch unreachable;
            var set = std.AutoHashMap(Symbol, void).init(module.gen.arena);
            defer set.deinit();
            for (tuple, 0..) |named_init, i| {
                const t = try typeCheckExpr(named_init.expr, module, infer);
                const tk = sources.exprs[named_init.expr.idx].tk;
                if (set.contains(named_init.name)) {
                    module.report_err(tk.off, "Duplicate field `{s}` in named tuple initialization", .{ lookup(named_init.name) });
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
                        module.report_err(expr.tk.off, "Index must have type `int`, found `{f}`", .{ rhs_t });
                        return Error.TypeMismatched;
                    }
                    return array.el;
                },
                .tuple => |tuple| {
                    if (rhs.data != .int) {
                        module.report_err(expr.tk.off, "Tuple can only be directly indexed by int literal", .{});
                        return Error.TypeMismatched;
                    }
                    const i = rhs.data.int;
                    if (i >= tuple.els.len or i < 0) {
                        module.report_err(expr.tk.off, "Tuple has length {}, but index is {}", .{ tuple.els.len, i });
                        return Error.TypeMismatched;
                    }
                    return tuple.els[@intCast(i)];
                },
                else => {
                    module.report_err(expr.tk.off, "Type `{f}` can not be indexed", .{ lhs_t });
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
                    module.report_err(expr.tk.off, "Unrecoginized field `{s}` for type `{f}`", .{ lookup(fa.rhs), lhs_t });
                    return Error.MissingField;
                },
                .named => |tuple| {
                    for (tuple.syms, tuple.els) |sym, t| {
                        if (fa.rhs == sym) return t;
                    }
                    module.report_err(expr.tk.off, "Unrecoginized field `{s}` for type `{f}`", .{ lookup(fa.rhs), lhs_t });
                    return Error.MissingField;
                },
                .type => {
                    const t = try reportValidType(module, fa.lhs);
                    const full = TypePool.lookup(t);
                    switch (full) {
                        .subset => |subset| {
                            for (subset.syms) |sym| {
                                if (sym == fa.rhs)
                                    return subset.sub_t;
                            }
                            module.report_err(expr.tk.off, "Unrecoginized field `{s}` for type `{f}`", .{ lookup(fa.rhs), t });
                            return Error.MissingField;
                        },
                        else => {
                            module.report_err(expr.tk.off, "Unrecoginized field `{s}` for type `{f}`", .{ lookup(fa.rhs), t });
                            return Error.MissingField;
                        }
                    }
                },
                else => {
                    module.report_err(expr.tk.off, "`{f}` cannot be field accessed", .{ lhs_t });
                    return Error.TypeMismatched;
                },
            }
        },
        .type_ptr,
        .type_array,
        .type_tuple,
        .type_named,
        .type_function,
        .type_subset => {
            module.report_err(expr.tk.off, "Expect normal expression, got type expression `{s}`", .{ @tagName(expr.data) });
            switch (expr.data) {
                .type_array => log.note("array literal starts with `.[`", .{}),
                .type_tuple => log.note("struct literal starts with `.{{`", .{}),
                else => {},
            }
            return Error.InvalidType;
        },
    }
}

pub fn isFloatLike(t: Type) bool {
    return t == TypePool.float or t == TypePool.double;
}
pub fn isIntLike(t: Type) bool {
    return t == TypePool.int or t == TypePool.char;
}
