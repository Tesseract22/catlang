const std = @import("std");
const Ast = @import("ast.zig");
const LangType = @import("type.zig");
const Expr = Ast.Expr;
const TypeExpr = Ast.TypeExpr;
const Stat = Ast.Stat;
const Op = Ast.Op;
const log = @import("log.zig");
const CompileError = Ast.EvalError;

const InternPool = @import("intern_pool.zig");
const Symbol = InternPool.Symbol;
const Lexer = @import("lexer.zig");

const lookup = Lexer.lookup;
const intern = Lexer.intern;

// We are currently only working on 64 bits machine
const TypePool = @import("type.zig");
const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;
const TypeCheck = @import("typecheck.zig");

insts: []Inst,
name: Symbol,
arg_types: []Type,
ret_type: Type,

pub const ResInst = union(enum) {
    none,
    ptr: usize,
    loc: usize,
};

pub const Inst = union(enum) {
    // add,
    block_start: usize, 
    arg_decl: Var,
    ret_decl: Type,
    block_end: usize,
    ret: Ret, // index
    call: Call,
    lit: Ast.Lit,
    var_access: usize, // the instruction where it is defined
    var_decl: Var,
    var_assign: Assign,

    type_size: Type,
    array_len: Type,

    addr_of,
    deref,
    getelementptr: GetElementPtr,

    field: Field,
    not: usize,


    array_init: ArrayInit,
    array_init_loc: ArrayInitEl,
    array_init_assign: ArrayInitEl,
    array_init_end: usize,
    uninit,

    if_start: IfStart, // index of condition epxrssion
    else_start: usize, // refer to if start
    if_end: usize,

    while_start,
    while_jmp: usize, // refer to while start,

    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,
    mod: BinOp,

    addf: BinOp,
    subf: BinOp,
    mulf: BinOp,
    divf: BinOp,

    addd: BinOp,
    subd: BinOp,
    muld: BinOp,
    divd: BinOp,


    eq: BinOp,
    lt: BinOp,
    gt: BinOp,
    eqf: BinOp,
    ltf: BinOp,
    gtf: BinOp,
    eqd: BinOp,
    ltd: BinOp,
    gtd: BinOp,



    i2f,
    i2d,
    f2i,
    f2d,
    d2i,
    d2f,
    pub const GetElementPtr = struct { 
        base: usize, 
        mul_imm: usize, 
        mul_reg: usize
    };
    pub const Field = struct {
        t: Type,
        off: usize,
    };
    pub const Var = struct {
        t: Type,
    };
    pub const ArrayInitEl = struct {
        off: usize,
        array_init: usize, // refers to inst
    };

    pub const ArrayInit = struct {
        t: Type,
        res_inst: ResInst,
    };

    pub const Array = struct {
        el: []usize,
        sub_t: Type,
    };
    pub const Assign = struct {
        lhs: usize,
        rhs: usize,
        t: Type,
    };

    pub const IfStart = struct {
        expr: usize,
        first_if: usize,
    };

    pub const Call = struct {
        name: Symbol,
        t: Type,
        args: []ScopeItem, // the inst of the applied argument
    };
    pub const Ret = struct {
        t: Type,
    };
    pub const BinOp = struct {
        lhs: usize,
        rhs: usize,
    };
    pub const ArgExpr = struct {
        t: Type,
        pos: u8,
        t_pos: u8,
        expr_inst: usize,
    };

    pub const Fn = struct {
        name: Symbol,
        scope: Scope,
        frame_size: usize,
    };
    pub fn format(value: Inst, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.print("{s} ", .{@tagName(value)});
        switch (value) {
            .add => |bin_op| try writer.print("{} + {}", .{ bin_op.lhs, bin_op.rhs }),
            .sub => |bin_op| try writer.print("{} - {}", .{ bin_op.lhs, bin_op.rhs }),
            .mul => |bin_op| try writer.print("{} * {}", .{ bin_op.lhs, bin_op.rhs }),
            .div => |bin_op| try writer.print("{} / {}", .{ bin_op.lhs, bin_op.rhs }),
            .mod => |bin_op| try writer.print("{} % {}", .{ bin_op.lhs, bin_op.rhs }),
            .addf => |bin_op| try writer.print("{} +.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .subf => |bin_op| try writer.print("{} -.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .mulf => |bin_op| try writer.print("{} *.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .divf => |bin_op| try writer.print("{} /.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .addd => |bin_op| try writer.print("{} +.d {}", .{ bin_op.lhs, bin_op.rhs }),
            .subd => |bin_op| try writer.print("{} -.d {}", .{ bin_op.lhs, bin_op.rhs }),
            .muld => |bin_op| try writer.print("{} *.d {}", .{ bin_op.lhs, bin_op.rhs }),
            .divd => |bin_op| try writer.print("{} /.d {}", .{ bin_op.lhs, bin_op.rhs }),

            .eq => |bin_op| try writer.print("{} == {}", .{ bin_op.lhs, bin_op.rhs }),
            .lt => |bin_op| try writer.print("{} < {}", .{ bin_op.lhs, bin_op.rhs }),
            .gt => |bin_op| try writer.print("{} > {}", .{ bin_op.lhs, bin_op.rhs }),
            .eqf => |bin_op| try writer.print("{} ==.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .ltf => |bin_op| try writer.print("{} <.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .gtf => |bin_op| try writer.print("{} >.f {}", .{ bin_op.lhs, bin_op.rhs }),
            .eqd => |bin_op| try writer.print("{} ==.d {}", .{ bin_op.lhs, bin_op.rhs }),
            .ltd => |bin_op| try writer.print("{} <.d {}", .{ bin_op.lhs, bin_op.rhs }),
            .gtd => |bin_op| try writer.print("{} >.d {}", .{ bin_op.lhs, bin_op.rhs }),


            .not => |not| try writer.print("!{}", .{ not }),

            .call => |s| try writer.print("{s}: {any} {}", .{ lookup(s.name), s.args, TypePool.lookup(s.t) }),
            .if_start => |if_start| try writer.print("first_if: {}, expr: {}", .{ if_start.first_if, if_start.expr }),
            .else_start => |start| try writer.print("{}", .{start}),
            .if_end => |start| try writer.print("{}", .{start}),
            .block_start => try writer.print("{{", .{}),
            .block_end => |start| try writer.print("}} {}", .{start}),
            .getelementptr => |getelementptr| try writer.print("[{} + {} * {}]", .{getelementptr.base, getelementptr.mul_imm, getelementptr.mul_reg}),

            inline .i2f, .i2d, .f2i, .f2d, .d2f, .d2i, .arg_decl, .ret_decl, .var_decl, .ret, .var_access, .lit, .var_assign, .while_start, .while_jmp, .type_size, .array_len,.array_init, .array_init_assign, .array_init_loc , .array_init_end, .field => |x| try writer.print("{}", .{x}),
            .addr_of, .deref, .uninit => {},
        }
    }
};
pub const ScopeItem = struct {
    t: Type,
    i: usize,
};
const Scope = std.AutoArrayHashMap(Symbol, ScopeItem);
const ScopeStack = struct {
    stack: std.ArrayList(Scope),
    pub fn init(alloc: std.mem.Allocator) ScopeStack {
        return ScopeStack{ .stack = std.ArrayList(Scope).init(alloc) };
    }
    pub fn get(self: ScopeStack, name: Symbol) ?ScopeItem {
        return for (self.stack.items) |scope| {
            if (scope.get(name)) |v| break v;
        } else null;
    }
    pub fn putTop(self: *ScopeStack, name: Symbol, item: ScopeItem) bool {
        for (self.stack.items) |scope| {
            if (scope.contains(name)) return false;
        }
        self.stack.items[self.stack.items.len - 1].putNoClobber(name, item) catch unreachable;
        return true;
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
const CirGen = struct {
    insts: std.ArrayList(Inst),
    ast: *const Ast,
    scopes: ScopeStack,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ret_decl: usize,
    types: []Type,
    expr_types: []Type,
    use_defs: TypeCheck.UseDefs,
    top_scope: TypeCheck.Scope,
    //type_env: TypeEnv,
    // rel: R

    // pub const Rel = enum {
    //     lt,
    //     gt,
    //     eq,
    // };
    pub fn getLast(self: CirGen) u32 {
        return @intCast(self.insts.items.len - 1);
    }
    pub fn append(self: *CirGen, inst: Inst) void {
        self.insts.append(inst) catch unreachable;
    }
    pub fn get_type(gen: CirGen, idx: Ast.TypeExprIdx) Type {
        return gen.types[idx.idx];
    }
    pub fn get_type_expr(gen: CirGen, idx: Ast.TypeExprIdx) Ast.TypeExpr {
        return gen.ast.types[idx.idx];
    }
    pub fn get_expr_type(gen: CirGen, idx: Ast.ExprIdx) Type {
        return gen.expr_types[idx.idx];
    }
};
const Cir = @This();

pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            // .if_start => |*scope| scope.deinit(),
            .call => |call| alloc.free(call.args),
            else => {},
        }
    }
    alloc.free(self.insts);
}
pub fn generate(ast: Ast, sema: *TypeCheck.Sema, alloc: std.mem.Allocator, arena: std.mem.Allocator) []Cir {
    //errdefer cir_gen.insts.deinit();
    var cirs = std.ArrayList(Cir).init(alloc);
    //var scopes = ScopeStack.init(alloc);
    //defer scopes.deinit();

    //scopes.push();
    //for (ast.defs) |def| {
    //    switch (def.data) {
    //        .type => {},
    //        .proc => |proc| {
    //            scopes.putTop(proc.name, undefined);
    //        },
    //        .foreign => |foreign| {
    //            _ = foreign;
    //        }
    //    }
    //}
    //scopes.popDiscard();
    for (ast.defs) |def| {
        switch (def.data) {
            .type, .foreign => {},
            .proc => |proc| {
                cirs.append(generateProc(proc, ast, sema, alloc, arena)) catch unreachable;
            },
        }
    }
    // errdefer cir_gen.insts.deinit();

    return cirs.toOwnedSlice() catch unreachable;
}
pub fn generateProc(def: Ast.ProcDef, ast: Ast, sema: *TypeCheck.Sema, alloc: std.mem.Allocator, arena: std.mem.Allocator) Cir  {
    var cir_gen = CirGen {
        .ast = &ast,
        .insts = std.ArrayList(Inst).init(alloc),
        .scopes = ScopeStack.init(alloc),
        .gpa = alloc,
        .arena = arena,
        .ret_decl = undefined,
        .types = sema.types,
        .expr_types = sema.expr_types,
        .use_defs = sema.use_defs,
        .top_scope = sema.top_scope,
    };
    defer cir_gen.scopes.stack.deinit();

    cir_gen.scopes.push();
    cir_gen.append(Inst{ .block_start = 0 });
    const block_start = cir_gen.getLast();
    // TODO struct pos
    cir_gen.append(Inst {.ret_decl = cir_gen.get_type(def.ret)});
    //cir_gen.ret_decl = cir_gen.getLast();
    const arg_types = arena.alloc(Type, def.args.len) catch unreachable;
    for (def.args, arg_types) |arg, *arg_t | {
        cir_gen.append(Inst{ .arg_decl = .{.t = cir_gen.get_type(arg.type) } });
        _ = cir_gen.scopes.putTop(arg.name, ScopeItem{ .i = cir_gen.getLast(), .t = cir_gen.get_type(arg.type) }); // TODO handle parameter with same name
        arg_t.* = cir_gen.get_type(arg.type);
    }
    for (def.body) |stat_id| {
        generateStat(cir_gen.ast.stats[stat_id.idx], &cir_gen);
    }
    var scope = cir_gen.scopes.pop();
    scope.deinit();

    const last_inst = cir_gen.getLast();
    if (cir_gen.insts.items[last_inst] != Inst.ret and cir_gen.get_type(def.ret) == TypePool.void) {
        cir_gen.append(Inst{ .ret = .{ .t = cir_gen.get_type(def.ret) } });
    }
    cir_gen.append(Inst{ .block_end = block_start });


    return Cir {.insts = cir_gen.insts.toOwnedSlice() catch unreachable, .arg_types = arg_types, .ret_type = cir_gen.get_type(def.ret), .name = def.name};

}
pub fn generateIf(if_stat: Ast.StatData.If, tk: @import("lexer.zig").Token, cir_gen: *CirGen, first_if_or: ?usize) void {
    _ = tk;
    _ = generateExpr(if_stat.cond, cir_gen, .none);
    const expr_idx = cir_gen.getLast();
    cir_gen.scopes.push();
    cir_gen.append(Inst{ .if_start = .{ .expr = expr_idx, .first_if = undefined } });
    const if_start = cir_gen.getLast();
    const first_if = if (first_if_or) |f| f else if_start;
    cir_gen.insts.items[if_start].if_start.first_if = first_if;

    cir_gen.append(Inst{ .block_start = 0 });

    for (if_stat.body) |body_stat| {
        generateStat(cir_gen.ast.stats[body_stat.idx], cir_gen);
    }
    cir_gen.append(Inst{ .block_end = if_start + 1 });
    cir_gen.append(Inst{ .else_start = if_start });
    cir_gen.scopes.popDiscard();
    switch (if_stat.else_body) {
        .none => {},
        .stats => |else_stats| {
            for (else_stats) |body_stat| {
                generateStat(cir_gen.ast.stats[body_stat.idx], cir_gen);
            }
        },
        .else_if => |idx| {
            const next_if = cir_gen.ast.stats[idx.idx];
            generateIf(next_if.data.@"if", next_if.tk, cir_gen, first_if);
        },
    }
    if (first_if_or == null) cir_gen.append(Inst{ .if_end = first_if });
}
pub fn generateStat(stat: Stat, cir_gen: *CirGen) void {
    switch (stat.data) {
        .anon => |expr| _ = generateExpr(expr, cir_gen, .none),
        .var_decl => |var_decl| {
            // var_decl.
            const t = var_decl.t;
            cir_gen.append(.{ .var_decl = .{.t = t } });
            const var_i = cir_gen.getLast();
            _ = cir_gen.scopes.putTop(var_decl.name, .{ .t = t, .i = var_i });
            _ = generateExpr(var_decl.expr, cir_gen, .{ .loc = cir_gen.getLast() });
            cir_gen.append(.{ .var_assign = .{.lhs = var_i, .rhs = cir_gen.getLast(), .t = t} });
        },
        .ret => |expr| {
            generateExpr(expr, cir_gen, .{ .ptr = 1 }); // TODO array
            cir_gen.append(.{ .ret = .{ .t = cir_gen.get_expr_type(expr) } });
        },
        .@"if" => |if_stat| {
            generateIf(if_stat, stat.tk, cir_gen, null);
        },
        .loop => |loop| {
            cir_gen.scopes.push();
            cir_gen.append(Inst.while_start);
            const while_start = cir_gen.getLast();

            _ = generateExpr(loop.cond, cir_gen, .none);
            const expr_idx = cir_gen.getLast();


            cir_gen.append(Inst{ .if_start = .{ .first_if = cir_gen.getLast() + 1, .expr = expr_idx } });
            const if_start = cir_gen.getLast();
            cir_gen.append(Inst{ .block_start = 0 });
            const block_start = cir_gen.getLast();
            for (loop.body) |body_stat| {
                generateStat(cir_gen.ast.stats[body_stat.idx], cir_gen);
            }
            cir_gen.append(Inst{ .block_end = block_start });
            cir_gen.append(Inst{ .while_jmp = while_start });
            cir_gen.append(Inst{ .else_start = if_start });
            cir_gen.append(Inst{ .if_end = if_start });

            cir_gen.scopes.popDiscard();
        },
        .assign => |assign| {
            generateExpr(assign.expr, cir_gen, .none);
            const rhs = cir_gen.getLast();
            _ = generateExpr(assign.left_value, cir_gen, .none);
            const lhs = cir_gen.getLast();
            cir_gen.append(.{ .var_assign = .{ .lhs = lhs, .rhs = rhs, .t = cir_gen.get_expr_type(assign.expr)} });
        },
    }
}

pub fn generateAs(lhs_idx: Ast.ExprIdx, rhs_t: Type, cir_gen: *CirGen, res_inst: ResInst) void {
    generateExpr(lhs_idx, cir_gen, res_inst);
    const lhs_t = cir_gen.get_expr_type(lhs_idx);
    const lhs_t_full = TypePool.lookup(lhs_t);

    switch (lhs_t_full) { // TODO first
                          //.float => {
                          //    // can only be casted to int
                          //    if (rhs_t != TypePool.int) unreachable;
                          //    cir_gen.append(Inst.f2i);
                          //},
        .number_lit => @panic("TODO"),
        .double => {
            if (rhs_t == TypePool.int) {
                cir_gen.append(Inst.d2i);
            }
            else if (rhs_t == TypePool.float) {

                cir_gen.append(Inst.d2f);
            }
        },
        .float => {
            if (rhs_t == TypePool.int) {
                cir_gen.append(Inst.f2i);
            }
            else if (rhs_t == TypePool.double) {
                cir_gen.append(Inst.f2d);
            }
        },
        .int => {
            const rhs_t_full = TypePool.lookup(rhs_t);
            switch (rhs_t_full) {
                .ptr, .char => {},
                .float => cir_gen.append(Inst.i2f),
                .double => cir_gen.append(Inst.i2d),
                else => unreachable,
            }
        },
        .char, .bool => {
            if (rhs_t != TypePool.int) unreachable;
        },
        .ptr, .function => {},
        .void => unreachable,
        .array, .tuple, .named => unreachable,
    }
}
pub fn generateRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, op: Op, cir_gen: *CirGen) void {
    _ = generateExpr(lhs, cir_gen, .none);
    const lhs_idx = cir_gen.getLast();
    _ = generateExpr(rhs, cir_gen, .none);
    const rhs_idx = cir_gen.getLast();

    const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
    const t = cir_gen.get_expr_type(lhs);
    if (t == TypePool.int) switch (op) {
        .eq => cir_gen.append(Inst{ .eq = bin }),
        .lt => cir_gen.append(Inst{ .lt = bin }),
        .gt => cir_gen.append(Inst{ .gt = bin }),
        else => unreachable,
        } else if (t == TypePool.float) switch (op) {
            .eq => cir_gen.append(Inst{ .eqf = bin }),
            .lt => cir_gen.append(Inst{ .ltf = bin }),
            .gt => cir_gen.append(Inst{ .gtf = bin }),
            else => unreachable,
            } else if (t == TypePool.double) switch (op) {
                .eq => cir_gen.append(Inst{ .eqd = bin }),
                .lt => cir_gen.append(Inst{ .ltd = bin }),
                .gt => cir_gen.append(Inst{ .gtd = bin }),
                else => unreachable,
            };
}
pub fn generateExpr(expr_idx: Ast.ExprIdx, cir_gen: *CirGen, res_inst: ResInst) void {
    const expr = &cir_gen.ast.exprs[expr_idx.idx];
    const t = cir_gen.get_expr_type(expr_idx);
    switch (expr.data) {
        .atomic => |atomic| {
            switch (atomic.data) {
                .float => |f| {
                    if (t == TypePool.double) 
                        cir_gen.append(Inst{ .lit = .{ .double = f } })
                    else if (t == TypePool.float)
                        cir_gen.append(Inst  {.lit = .{.float = @floatCast(f)}})
                    else
                        unreachable;
                    },
                    .int => |i| {
                        cir_gen.append(Inst{ .lit = .{ .int = i } });
                    },
                    .string => |s| {
                        cir_gen.append(Inst{ .lit = .{ .string = s } });
                    },
                    .bool => |b| {
                        cir_gen.append(Inst{ .lit = .{ .int = @intFromBool(b) } });
                    },
                    .paren => |e| {
                        return generateExpr(e, cir_gen, res_inst);
                    },
                    .iden => |i| {
                        cir_gen.append(Inst{ .var_access = cir_gen.scopes.get(i).?.i });
                    },

                    .addr => @panic("TODO ADDR"),
            }
        },
        .as => |as| return generateAs(as.lhs, cir_gen.get_type(as.rhs), cir_gen, res_inst),
        .bin_op => |bin_op| {
            switch (bin_op.op) {
                .eq, .gt, .lt => return generateRel(bin_op.lhs, bin_op.rhs, bin_op.op, cir_gen),
                else => {},
            }
            generateExpr(bin_op.lhs, cir_gen, res_inst);
            const lhs_t = cir_gen.get_expr_type(bin_op.lhs);
            //const lhs_t_full = TypePool.lookup(lhs_t);

            const lhs_idx = cir_gen.getLast();

            _ = generateExpr(bin_op.rhs, cir_gen, .none);


            const rhs_idx = cir_gen.getLast();
            const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
            const inst =
                if (TypeCheck.isIntLike(lhs_t)) switch (bin_op.op) {
                    .plus => Inst{ .add = bin },
                    .minus => Inst{ .sub = bin },
                    .times => Inst{ .mul = bin },
                    .div => Inst{ .div = bin },
                    .mod => Inst{ .mod = bin },
                    else => unreachable
                } else if (lhs_t == TypePool.float) switch (bin_op.op) {
                    .plus => Inst{ .addf = bin },
                    .minus => Inst{ .subf = bin },
                    .times => Inst{ .mulf = bin },
                    .div => Inst{ .divf = bin },
                    .mod => @panic("TODO: Float mod not yet supported"),
                    else => unreachable,
                    } else if (lhs_t == TypePool.double) switch (bin_op.op) {
                        .plus => Inst{ .addd = bin },
                        .minus => Inst{ .subd = bin },
                        .times => Inst{ .muld = bin },
                        .div => Inst{ .divd = bin },
                        .mod => @panic("TODO: Float mod not yet supported"),
                        else => unreachable,
                    } else unreachable;
            cir_gen.append(inst);
        },
        .fn_app => |fn_app| {
            var args = std.ArrayList(ScopeItem).init(cir_gen.gpa);
            defer args.deinit();
            if (fn_app.func ==  Lexer.string_pool.intern("print")) {
                generateExpr(fn_app.args[0], cir_gen, res_inst);
                const arg_t = cir_gen.get_expr_type(fn_app.args[0]);
                const t_full = TypePool.lookup(arg_t);
                if (t_full == .float) cir_gen.append(Inst.f2d);
                const arg_idx = cir_gen.getLast();
                const format = switch (t_full) {
                    .number_lit => @panic("TODO"),
                    .void => unreachable,
                    .bool, .int => "%i\n",
                    .char => "%c\n",
                    .double, .float => "%f\n",
                    .ptr => |ptr| if (ptr.el == TypePool.char) "%s\n" else "%p\n",
                    .array, => "%s\n",
                    .tuple, .named, .function => @panic("TODO"),
                };
                cir_gen.append(Inst{ .lit = .{ .string = Lexer.string_pool.intern(format) } });
                args.append(.{.i = cir_gen.getLast(), .t = TypePool.string}) catch unreachable; // TODO
                args.append(.{.i = arg_idx, .t = arg_t}) catch unreachable;
                cir_gen.append(Inst{ .call = .{ .name = Lexer.string_pool.intern("printf"), .t = TypePool.void ,.args = args.toOwnedSlice() catch unreachable } });
                return;
            }
            const fn_def = cir_gen.top_scope.get(fn_app.func) orelse unreachable;
            const fn_type = TypePool.lookup(fn_def.t);
            var expr_insts = std.ArrayList(usize).init(cir_gen.arena);
            defer expr_insts.deinit();
            for (fn_app.args) |fa| {
                generateExpr(fa, cir_gen, .none);
                args.append(.{ .i = cir_gen.getLast(), .t = cir_gen.get_expr_type(fa) }) catch unreachable;

            }
            cir_gen.append(.{ .call = .{ .name = fn_app.func, .t = fn_type.function.ret, .args = args.toOwnedSlice() catch unreachable } });

        },
        .addr_of => |addr_of| {
            generateExpr(addr_of, cir_gen, .none);
            cir_gen.append(.addr_of);
        },
        .deref => |deref| {
            generateExpr(deref, cir_gen, .none);
            cir_gen.append(.deref);
        },
        .array => |array| {

            cir_gen.append(.{.array_init = .{.res_inst = res_inst, .t = cir_gen.get_expr_type(expr_idx)}});

            const array_init = cir_gen.getLast();
            for (array, 0..) |e, i| {
                cir_gen.append(.{.array_init_loc = .{.array_init = array_init, .off = i}});
                generateExpr(e, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{.array_init_assign = .{.array_init = array_init, .off = i}});

            }
            cir_gen.append(Inst {.array_init_end = array_init });
        },
        .tuple => |tuple| {
            const tuple_t = cir_gen.get_expr_type(expr_idx);
            cir_gen.append(.{.array_init = .{.res_inst = res_inst, .t = tuple_t}});
            const array_init = cir_gen.getLast();
            for (tuple, 0..) |e, i| {
                cir_gen.append(.{.array_init_loc = .{.array_init = array_init, .off = i}});
                generateExpr(e, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{.array_init_assign = .{.array_init = array_init, .off = i}});

            }
            cir_gen.append(Inst {.array_init_end = array_init });
        },
        .named_tuple => |tuple| {
            const tuple_t = cir_gen.get_expr_type(expr_idx);
            cir_gen.append(.{.array_init = .{.res_inst = res_inst, .t = tuple_t}});
            const array_init = cir_gen.getLast();
            for (tuple, 0..) |vb, i| {
                cir_gen.append(.{.array_init_loc = .{.array_init = array_init, .off = i}});
                generateExpr(vb.expr, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{.array_init_assign = .{.array_init = array_init, .off = i}});

            }
            cir_gen.append(Inst {.array_init_end = array_init });
        },
        .array_access => |aa| {
            generateExpr(aa.lhs, cir_gen, .none);
            cir_gen.append(Inst.addr_of);
            const lhs_addr = cir_gen.getLast();
            _ = generateExpr(aa.rhs, cir_gen, .none);
            const rhs_inst = cir_gen.getLast();
            const lhs_t = cir_gen.get_expr_type(aa.lhs);
            const lhs_t_full = TypePool.lookup(lhs_t);
            switch (lhs_t_full) {
                .array => |array| {
                    cir_gen.append(Inst {.type_size = array.el});
                    cir_gen.append(Inst {.getelementptr = .{.base = lhs_addr, .mul_imm = cir_gen.getLast(), .mul_reg = rhs_inst}});
                },
                .tuple => |_| {
                    const i = cir_gen.ast.exprs[aa.rhs.idx].data.atomic.data.int;
                    cir_gen.append(.{ .field = .{ .off = @intCast(i), .t = lhs_t } });
                    cir_gen.append(Inst {.add = .{ .lhs = lhs_addr, .rhs = cir_gen.getLast() }});
                    cir_gen.append(.deref);
                },
                else => unreachable,
            }


        },
        .field => |fa| {
            generateExpr(fa.lhs, cir_gen, .none);

            const lhs_t = cir_gen.get_expr_type(fa.lhs);
            const lhs_t_full = TypePool.lookup(lhs_t);
            switch (lhs_t_full) {
                .named => |tuple| {
                    const i = for (tuple.syms, 0..) |sym, i| {
                        if (sym == fa.rhs) break i;
                    } else unreachable;
                    cir_gen.append(Inst.addr_of);
                    const lhs_addr = cir_gen.getLast();
                    cir_gen.append(.{ .field = .{ .off = @intCast(i), .t = lhs_t } });
                    cir_gen.append(Inst {.add = .{ .lhs = lhs_addr, .rhs = cir_gen.getLast() }});
                    cir_gen.append(.deref);
                },
                .array => |_| {
                    cir_gen.append(Inst {.array_len = lhs_t});
                },
                else => unreachable,
            }
        },
        .not => |not| {
            generateExpr(not, cir_gen, .none);
            cir_gen.append(Inst {.not = cir_gen.getLast()});
        },
    }
}



