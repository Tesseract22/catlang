const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
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
    none, // the result of the expression is not used, andand therefore should be discarded
    self, // most of the expression would have this, where the mark the result of the expression alive in its ResultLocation
    ptr: Index,
    loc: Index,
};
pub const Index = enum(usize) {
    start = 0,
    ret = 1,
    invalid = std.math.maxInt(usize),
    _,
    pub fn i(self: Index) usize { return @intFromEnum(self); }
    pub fn prev(self: Index) Index { return @enumFromInt(@intFromEnum(self) - 1); }
    pub fn next(self: Index) Index { return @enumFromInt(@intFromEnum(self) + 1); }
    pub fn format(value: Index, writer: *std.Io.Writer) !void {
        if (value == .invalid)
            try writer.print("<invalid>", .{})
        else
            try writer.print("<{}>", .{ @intFromEnum(value) });
    }
};

pub const Inst = union(enum) {
    // add,
    block_start,
    arg_decl: Var,
    ret_decl: Type,
    block_end: Index,
    ret: Ret,
    call: Call,
    lit: Ast.Lit,
    var_access: Index,
    var_decl: Var,
    var_assign: Assign,
    foreign: Foreign,

    type_size: Type,
    array_len: Type,

    addr_of,
    deref,
    getelementptr: GetElementPtr,

    field: Field,
    not: Index,

    array_init: ArrayInit,
    array_init_loc: ArrayInitEl,
    array_init_assign: ArrayInitEl,
    array_init_end: Index,
    uninit,

    if_start: IfStart, // index of condition epxrssion
    else_start: Index, // refer to if start
    if_end: Index,

    while_start,
    while_jmp: Index, // refer to while start,

    add: BinOp, // TODO: make this IntBinOp
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

    eq: IntBinOp,
    lt: IntBinOp,
    gt: IntBinOp,
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
    pub const Foreign = struct {
        sym: Symbol,
        // t: Type,
    };
    pub const GetElementPtr = struct {
        base: Index,
        mul: ?struct {
            imm: Index,
            reg: Index,
        },
        disp: ?Index,
    };
    pub const Field = struct {
        t: Type,
        off: usize,
    };
    pub const Var = struct {
        t: Type,
        auto_deref: bool,
    };
    pub const Access = struct {
        i: Index,
        auto_deref: bool,
    };
    pub const ArrayInitEl = struct {
        off: usize,
        array_init: Index,
    };

    pub const ArrayInit = struct {
        t: Type,
        res_inst: ResInst,
    };

    pub const Array = struct {
        el: []Index,
        sub_t: Type,
    };
    pub const Assign = struct {
        lhs: Index,
        rhs: Index,
        t: Type,
    };

    pub const IfStart = struct {
        expr: Index,
        first_if: Index,
    };

    pub const Call = struct {
        func: Index,
        t: Type,
        locs: []const Index,
        ts: []const Type,
        varadic: bool,
        discard: bool,
    };
    pub const Ret = struct {
        t: Type,
    };
    pub const BinOp = struct {
        lhs: Index,
        rhs: Index,
    };
    pub const IntBinOp = struct {
        lhs: Index,
        rhs: Index,
        t: Type,
    };
    pub const ArgExpr = struct {
        t: Type,
        pos: u8,
        t_pos: u8,
        expr_inst: Index,
    };

    //pub const Fn = struct {
    //    name: Symbol,
    //    scope: Scope,
    //    frame_size: usize,
    //};
    pub fn format(value: Inst, writer: *std.Io.Writer) !void {
        _ = try writer.print("{s} ", .{@tagName(value)});
        switch (value) {
            .add => |bin_op| try writer.print("{f} + {f}", .{ bin_op.lhs, bin_op.rhs }),
            .sub => |bin_op| try writer.print("{f} - {f}", .{ bin_op.lhs, bin_op.rhs }),
            .mul => |bin_op| try writer.print("{f} * {f}", .{ bin_op.lhs, bin_op.rhs }),
            .div => |bin_op| try writer.print("{f} / {f}", .{ bin_op.lhs, bin_op.rhs }),
            .mod => |bin_op| try writer.print("{f} % {f}", .{ bin_op.lhs, bin_op.rhs }),
            .addf => |bin_op| try writer.print("{f} +.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .subf => |bin_op| try writer.print("{f} -.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .mulf => |bin_op| try writer.print("{f} *.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .divf => |bin_op| try writer.print("{f} /.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .addd => |bin_op| try writer.print("{f} +.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .subd => |bin_op| try writer.print("{f} -.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .muld => |bin_op| try writer.print("{f} *.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .divd => |bin_op| try writer.print("{f} /.d {f}", .{ bin_op.lhs, bin_op.rhs }),

            .eq => |bin_op| try writer.print("{f} == {f}", .{ bin_op.lhs, bin_op.rhs }),
            .lt => |bin_op| try writer.print("{f} < {f}", .{ bin_op.lhs, bin_op.rhs }),
            .gt => |bin_op| try writer.print("{f} > {f}", .{ bin_op.lhs, bin_op.rhs }),
            .eqf => |bin_op| try writer.print("{f} ==.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .ltf => |bin_op| try writer.print("{f} <.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .gtf => |bin_op| try writer.print("{f} >.f {f}", .{ bin_op.lhs, bin_op.rhs }),
            .eqd => |bin_op| try writer.print("{f} ==.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .ltd => |bin_op| try writer.print("{f} <.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .gtd => |bin_op| try writer.print("{f} >.d {f}", .{ bin_op.lhs, bin_op.rhs }),
            .not => |not| try writer.print("!{f}", .{not}),
            .call => |s| try writer.print("{f}: types: {any} locs: {any} -> {f}", .{ s.func, s.ts, s.locs, TypePool.lookup(s.t) }),
            .if_start => |if_start| try writer.print("first_if: {f}, expr: {f}", .{ if_start.first_if, if_start.expr }),
            .else_start => |start| try writer.print("{f}", .{start}),
            .if_end => |start| try writer.print("{f}", .{start}),
            .block_start => try writer.print("{{", .{}),
            .block_end => |start| try writer.print("}} {f}", .{start}),
            .getelementptr => |getelementptr|
                if (getelementptr.mul) |mul|
                    try writer.print("[{f} + {f} * {f} + {f}]", .{
                        getelementptr.base, mul.imm, mul.reg, getelementptr.disp orelse .invalid })
                else try writer.print("[{f} + {f}]", .{ getelementptr.base, getelementptr.disp orelse .invalid }),
            .foreign => |foreign| try writer.print("{s}", .{lookup(foreign.sym)}),

            inline .i2f, .i2d, .f2i, .f2d, .d2f, .d2i, .arg_decl, .ret_decl, .var_decl, .ret, .var_access, .lit, .var_assign, .while_start, .while_jmp, .type_size, .array_len, .array_init, .array_init_assign, .array_init_loc, .array_init_end, .field => |x| try writer.print("{any}", .{x}),
            .addr_of, .deref, .uninit => {},
        }
    }
};
pub const ScopeItem = struct {
    t: Type,
    i: Index,
};
const Scope = std.array_hash_map.Auto(Symbol, ScopeItem);
const ScopeStack = struct {
    stack: std.ArrayList(Scope),
    gpa: Allocator,

    pub fn init(gpa: Allocator) ScopeStack {
        return .{ .stack = .empty, .gpa = gpa };
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
        self.stack.items[self.stack.items.len - 1].putNoClobber(self.gpa, name, item) catch unreachable;
        return true;
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
const CirGen = struct {
    insts: std.ArrayList(Inst),
    ast: *const Ast,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ret_decl: Index,
    vals: []TypeCheck.TypedValue,
    use_defs: TypeCheck.UseDefs,
    top_scope: TypeCheck.Scope,
    sources :*Ast.Sources,
    //type_env: TypeEnv,
    // rel: R

    // pub const Rel = enum {
    //     lt,
    //     gt,
    //     eq,
    // };
    pub fn getLast(self: CirGen) Index {
        return @enumFromInt(self.insts.items.len - 1);
    }
    pub fn append(self: *CirGen, inst: Inst) void {
        self.insts.append(self.gpa, inst) catch unreachable;
    }
    pub fn get_expr_val_as_type(gen: CirGen, idx: Ast.ExprIdx) Type {
        const tv = gen.vals[idx.idx];
        assert(tv.t == TypePool.type);
        return tv.v.asType();
    }
    pub fn get_expr_type(gen: CirGen, idx: Ast.ExprIdx) Type {
        const tv = gen.vals[idx.idx];
        // assert(tv.t != TypePool.type);
        return tv.t;
    }
};
const Cir = @This();

pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            // .if_start => |*scope| scope.deinit(),
            .call => |call| {
                alloc.free(call.ts);
                alloc.free(call.locs);
            },
            else => {},
        }
    }
    alloc.free(self.insts);
}

pub fn generate(sema: *TypeCheck.Sema, alloc: std.mem.Allocator, arena: std.mem.Allocator) []Cir {
    var cirs = std.ArrayList(Cir).empty;
    var it = sema.sources.asts.iterator();
    while (it.next()) |entry| {
        const ast = entry.value_ptr.*;
        generateModule(ast.*, sema, &cirs, alloc, arena);
    }
    return cirs.toOwnedSlice(alloc) catch @panic("OOM");
}

pub fn generateModule(ast: Ast, sema: *TypeCheck.Sema, cirs: *std.ArrayList(Cir), alloc: std.mem.Allocator, arena: std.mem.Allocator) void {
    for (ast.defs) |def| {
        switch (sema.sources.defs[def.idx].data) {
            .type, .foreign, .import => {},
            .proc => |proc| {
                cirs.append(alloc, generateProc(proc, ast, sema, alloc, arena)) catch unreachable;
            },
        }
    }
}
pub fn generateProc(def: Ast.TopDefData.ProcDef, ast: Ast, sema: *TypeCheck.Sema, gpa: std.mem.Allocator, arena: std.mem.Allocator) Cir {
    log.debug("generate Proc: {s}", .{ lookup(def.name) });
    var cir_gen = CirGen {
        .ast = &ast,
        .insts = .empty,
        .gpa = gpa,
        .arena = arena,
        .ret_decl = .invalid,
        .vals = sema.vals,
        .use_defs = sema.use_defs,
        .top_scope = sema.top_scope,
        .sources = sema.sources,
    };
    cir_gen.append(Inst{ .block_start = {} });
    const block_start = cir_gen.getLast();
    // TODO struct pos
    cir_gen.append(Inst{ .ret_decl = cir_gen.get_expr_val_as_type(def.ret) });
    //cir_gen.ret_decl = cir_gen.getLast();
    const arg_types = arena.alloc(Type, def.args.len) catch unreachable;
    for (def.args, arg_types, def.args_def_insts) |arg, *arg_t, *i| {
        log.debug("generate arg: {s}", .{ lookup(arg.name) });
        cir_gen.append(Inst{ .arg_decl = .{ .t = cir_gen.get_expr_val_as_type(arg.type), .auto_deref = false } });
        i.* = cir_gen.getLast();
        arg_t.* = cir_gen.get_expr_val_as_type(arg.type);
    }
    for (def.body) |stat_idx| {
        generateStat(stat_idx, &cir_gen);
    }

    const last_inst = cir_gen.getLast();
    if (cir_gen.insts.items[last_inst.i()] != Inst.ret and cir_gen.get_expr_val_as_type(def.ret) == TypePool.void) {
        cir_gen.append(Inst{ .ret = .{ .t = cir_gen.get_expr_val_as_type(def.ret) } });
    }
    cir_gen.append(Inst{ .block_end = block_start });

    return Cir{ .insts = cir_gen.insts.toOwnedSlice(cir_gen.gpa) catch unreachable, .arg_types = arg_types, .ret_type = cir_gen.get_expr_val_as_type(def.ret), .name = def.name };
}
pub fn generateIf(if_stat: Ast.StatData.If, tk: @import("lexer.zig").Token, cir_gen: *CirGen, first_if_or: ?Index) void {
    _ = tk;
    _ = generateExpr(if_stat.cond, cir_gen, .self);
    const expr_idx = cir_gen.getLast();
    cir_gen.append(Inst{ .if_start = .{ .expr = expr_idx, .first_if = .invalid } });
    const if_start = cir_gen.getLast();
    const first_if = if (first_if_or) |f| f else if_start;
    cir_gen.insts.items[if_start.i()].if_start.first_if = first_if;

    cir_gen.append(Inst{ .block_start = {} });

    for (if_stat.body) |body_stat| {
        generateStat(body_stat, cir_gen);
    }
    cir_gen.append(Inst{ .block_end = if_start.next() });
    cir_gen.append(Inst{ .else_start = if_start });
    switch (if_stat.else_body) {
        .none => {},
        .stats => |else_stats| {
            for (else_stats) |body_stat| {
                generateStat(body_stat, cir_gen);
            }
        },
        .else_if => |idx| {
            const next_if = cir_gen.sources.stats[idx.idx];
            generateIf(next_if.data.@"if", next_if.tk, cir_gen, first_if);
        },
    }
    if (first_if_or == null) cir_gen.append(Inst{ .if_end = first_if });
}
pub fn generateStat(stat_idx: Ast.StatIdx, cir_gen: *CirGen) void {
    const stat = &cir_gen.sources.stats[stat_idx.idx];
    switch (stat.data) {
        .anon => |expr| generateExpr(expr, cir_gen, .none), // discard the result of the
        .var_decl => |*var_decl| {
            const t = var_decl.t;
            cir_gen.append(.{ .var_decl = .{ .t = t, .auto_deref = false } });
            const var_i = cir_gen.getLast();
            var_decl.i = var_i;
            if (var_decl.expr) |expr| {
                generateExpr(expr, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{ .var_assign = .{ .lhs = var_i, .rhs = cir_gen.getLast(), .t = t } });

            }
        },
        .ret => |expr| {
            generateExpr(expr, cir_gen, .{ .ptr = .ret }); // TODO array
            cir_gen.append(.{ .ret = .{ .t = cir_gen.get_expr_type(expr) } });
        },
        .@"if" => |if_stat| {
            generateIf(if_stat, stat.tk, cir_gen, null);
        },
        .loop => |loop| {
            cir_gen.append(Inst.while_start);
            const while_start = cir_gen.getLast();

            _ = generateExpr(loop.cond, cir_gen, .self);
            const expr_idx = cir_gen.getLast();

            cir_gen.append(Inst{ .if_start = .{ .first_if = cir_gen.getLast().next(), .expr = expr_idx } });
            const if_start = cir_gen.getLast();
            cir_gen.append(Inst{ .block_start = {} });
            const block_start = cir_gen.getLast();
            for (loop.body) |body_stat| {
                generateStat(body_stat, cir_gen);
            }
            cir_gen.append(Inst{ .block_end = block_start });
            cir_gen.append(Inst{ .while_jmp = while_start });
            cir_gen.append(Inst{ .else_start = if_start });
            cir_gen.append(Inst{ .if_end = if_start });
        },
        .assign => |assign| {
            generateExpr(assign.expr, cir_gen, .self);
            const rhs = cir_gen.getLast();
            _ = generateExpr(assign.left_value, cir_gen, .self);
            const lhs = cir_gen.getLast();
            cir_gen.append(.{ .var_assign = .{ .lhs = lhs, .rhs = rhs, .t = cir_gen.get_expr_type(assign.expr) } });
        },
    }
}

pub fn generateAs(lhs_t: Type, rhs_t: Type, cir_gen: *CirGen, res_inst: ResInst) void {
    const lhs_t_full = TypePool.lookup(lhs_t);

    switch (lhs_t_full) { // TODO first
        //.float => {
        //    // can only be casted to int
        //    if (rhs_t != TypePool.int) unreachable;
        //    cir_gen.append(Inst.f2i);
        //},
        .number_lit => @panic("TODO"),
        .subset => |subset| {
            if (subset.sub_t == rhs_t) return;
            return generateAs(subset.sub_t, rhs_t, cir_gen, res_inst);
        },
        .double => {
            if (rhs_t == TypePool.int) {
                cir_gen.append(Inst.d2i);
            } else if (rhs_t == TypePool.float) {
                cir_gen.append(Inst.d2f);
            }
        },
        .float => {
            if (rhs_t == TypePool.int) {
                cir_gen.append(Inst.f2i);
            } else if (rhs_t == TypePool.double) {
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
        .array, .tuple, .named, .type => unreachable,
    }
}
pub fn generateRel(lhs: Ast.ExprIdx, rhs: Ast.ExprIdx, op: Op, cir_gen: *CirGen, res_inst: ResInst) void {
    _ = generateExpr(lhs, cir_gen, res_inst);
    const lhs_idx = cir_gen.getLast();
    _ = generateExpr(rhs, cir_gen, res_inst);
    const rhs_idx = cir_gen.getLast();

    const lhs_t = cir_gen.get_expr_type(lhs);
    const t = switch (TypePool.lookup(lhs_t)) {
        .int, .char,
        .float,
        .double => lhs_t,
        .subset => |subset| subset.sub_t,
        else => unreachable,
    };
    const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
    const int_bin = Inst.IntBinOp{ .lhs = lhs_idx, .rhs = rhs_idx, .t = t };
    if (t == TypePool.int or t == TypePool.char) switch (op) {
        .eq => cir_gen.append(Inst{ .eq = int_bin }),
        .lt => cir_gen.append(Inst{ .lt = int_bin }),
        .gt => cir_gen.append(Inst{ .gt = int_bin }),
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
    } else unreachable;
}
pub fn generateExpr(expr_idx: Ast.ExprIdx, cir_gen: *CirGen, res_inst: ResInst) void {
    const expr = &cir_gen.sources.exprs[expr_idx.idx];
    assert(res_inst != .none or expr.data == .fn_app);
    const t = cir_gen.get_expr_type(expr_idx);
    switch (expr.data) {
        .type_ptr,
        .type_array,
        .type_tuple,
        .type_named,
        .type_function,
        .type_subset => {},

        .float => |f| {
            if (t == TypePool.double) {
                cir_gen.append(Inst{ .lit = .{ .double = f } });
            } else if (t == TypePool.float) {
                cir_gen.append(Inst{ .lit = .{ .float = @floatCast(f) } });
            } else {
                unreachable;
            }
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
            log.debug("iden: {s}", .{ lookup(i) });
            if (cir_gen.use_defs.get(expr_idx)) |var_def| {
                if (cir_gen.get_expr_type(expr_idx) == TypePool.type) return;
                switch (var_def) {
                   .arg => |arg| {
                       // log.debug("from {s}[{}]: {*}", .{ lookup(arg.proc.name), arg.num, &arg.proc.args_def_insts[arg.num] });
                       assert(arg.proc.args_def_insts[arg.num] != .invalid);
                       cir_gen.append(.{ .var_access = arg.proc.args_def_insts[arg.num] });
                   },
                   .let => |let| {
                       log.debug("let: {*}", .{ let });
                       assert(let.i != .invalid);
                       cir_gen.append(.{ .var_access = let.i });
                   },
                   .proc => |proc| {
                       cir_gen.append(.{ .foreign = .{ .sym = proc.name } });
                   },
                   .foreign => |foreign| {
                       cir_gen.append(.{ .foreign = .{ .sym = foreign.name } });
                   },
                   .@"comptime" => |val| {
                       cir_gen.append(.{ .lit = .{ .int = @intFromEnum(val) }});
                   },
               }
            } else {
                unreachable;
            }
        },

        .addr => @panic("TODO ADDR"),
        .bin_op => |bin_op| {
            switch (bin_op.op) {
                .eq, .gt, .lt => return generateRel(bin_op.lhs, bin_op.rhs, bin_op.op, cir_gen, res_inst),
                .as => {
                    generateExpr(bin_op.lhs, cir_gen, res_inst);
                    generateAs(cir_gen.get_expr_type(bin_op.lhs), cir_gen.get_expr_val_as_type(bin_op.rhs), cir_gen, res_inst);
                    return;
                },
                else => {},
            }
            generateExpr(bin_op.lhs, cir_gen, res_inst );
            const lhs_t = cir_gen.get_expr_type(bin_op.lhs);
            //const lhs_t_full = TypePool.lookup(lhs_t);

            const lhs_idx = cir_gen.getLast();

            _ = generateExpr(bin_op.rhs, cir_gen, res_inst );

            const rhs_idx = cir_gen.getLast();
            const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
            const inst =
                if (TypeCheck.isIntLike(lhs_t)) switch (bin_op.op) {
                    .plus => Inst{ .add = bin },
                    .minus => Inst{ .sub = bin },
                    .times => Inst{ .mul = bin },
                    .div => Inst{ .div = bin },
                    .mod => Inst{ .mod = bin },
                    else => unreachable,
                } else if (lhs_t == TypePool.float) switch (bin_op.op) {
                    .plus => Inst{ .addf = bin },
                    .minus => Inst{ .subf = bin },
                    .times => Inst{ .mulf = bin },
                    .div => Inst{ .divf = bin },
                    .mod => @panic("TODO: float mod not yet supported"),
                    else => unreachable,
                } else if (lhs_t == TypePool.double) switch (bin_op.op) {
                    .plus => Inst{ .addd = bin },
                    .minus => Inst{ .subd = bin },
                    .times => Inst{ .muld = bin },
                    .div => Inst{ .divd = bin },
                    .mod => @panic("TODO: double mod not yet supported"),
                    else => unreachable,
                } else unreachable;
            cir_gen.append(inst);
        },
        .fn_app => |fn_app| {
            var locs = std.ArrayListUnmanaged(Index).initCapacity(cir_gen.gpa, 0) catch unreachable;
            var ts = std.ArrayListUnmanaged(Type).initCapacity(cir_gen.gpa, 0) catch unreachable;
            defer locs.deinit(cir_gen.gpa);
            defer ts.deinit(cir_gen.gpa);
            for (fn_app.args) |fa| {
                generateExpr(fa, cir_gen, .self); // TODO: hacky
                locs.append(cir_gen.gpa, cir_gen.getLast()) catch unreachable;
                ts.append(cir_gen.gpa, cir_gen.get_expr_type(fa)) catch unreachable;
            }
            generateExpr(fn_app.func, cir_gen, .self);
            log.debug("fn_app: {f}, {}", .{ cir_gen.insts.items[cir_gen.getLast().i()], res_inst });
            const fn_type = TypeCheck.getCallable(cir_gen.get_expr_type(fn_app.func)).?;
            cir_gen.append(.{ .call =
                .{
                    .func = cir_gen.getLast(),
                    .t = fn_type.ret,
                    .locs = locs.toOwnedSlice(cir_gen.gpa) catch unreachable,
                    .ts = ts.toOwnedSlice(cir_gen.gpa) catch unreachable,
                    .varadic = false, .discard = if (res_inst == .none) true else false,
                } });
        },
        .addr_of => |addr_of| {
            generateExpr(addr_of, cir_gen, .self);
            cir_gen.append(.addr_of);
        },
        .deref => |deref| {
            generateExpr(deref, cir_gen, .self);
            cir_gen.append(.{ .deref = {} });
        },
        .array => |array| {
            assert(res_inst != .none);
            cir_gen.append(.{ .array_init = .{ .res_inst = res_inst, .t = cir_gen.get_expr_type(expr_idx) } });

            const array_init = cir_gen.getLast();
            for (array, 0..) |e, i| {
                cir_gen.append(.{ .array_init_loc = .{ .array_init = array_init, .off = i } });
                generateExpr(e, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{ .array_init_assign = .{ .array_init = array_init, .off = i } });
            }
            cir_gen.append(Inst{ .array_init_end = array_init });
        },
        .tuple => |tuple| {
            assert(res_inst != .none);
            const tuple_t = cir_gen.get_expr_type(expr_idx);
            cir_gen.append(.{ .array_init = .{ .res_inst = res_inst, .t = tuple_t } });
            const array_init = cir_gen.getLast();
            for (tuple, 0..) |e, i| {
                cir_gen.append(.{ .array_init_loc = .{ .array_init = array_init, .off = i } });
                generateExpr(e, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{ .array_init_assign = .{ .array_init = array_init, .off = i } });
            }
            cir_gen.append(Inst{ .array_init_end = array_init });
        },
        .named_tuple => |tuple| {
            assert(res_inst != .none);
            const tuple_t = cir_gen.get_expr_type(expr_idx);
            cir_gen.append(.{ .array_init = .{ .res_inst = res_inst, .t = tuple_t } });
            const array_init = cir_gen.getLast();
            for (tuple, 0..) |vb, i| {
                cir_gen.append(.{ .array_init_loc = .{ .array_init = array_init, .off = i } });
                generateExpr(vb.expr, cir_gen, .{ .loc = cir_gen.getLast() });
                cir_gen.append(.{ .array_init_assign = .{ .array_init = array_init, .off = i } });
            }
            cir_gen.append(Inst{ .array_init_end = array_init });
        },
        .array_access => |aa| {
            generateExpr(aa.lhs, cir_gen, res_inst);
            cir_gen.append(Inst.addr_of);
            const lhs_addr = cir_gen.getLast();
            _ = generateExpr(aa.rhs, cir_gen, res_inst);
            const rhs_inst = cir_gen.getLast();
            const lhs_t = cir_gen.get_expr_type(aa.lhs);
            const lhs_t_full = TypePool.lookup(lhs_t);
            switch (lhs_t_full) {
                .array => |array| {
                    cir_gen.append(Inst{ .type_size = array.el });
                    cir_gen.append(Inst{ .getelementptr = .{ .base = lhs_addr, .mul = .{ .imm = cir_gen.getLast(), .reg = rhs_inst }, .disp = null } });
                },
                .tuple => {
                    const i = cir_gen.sources.exprs[aa.rhs.idx].data.int;
                    cir_gen.append(.{ .field = .{ .off = @intCast(i), .t = lhs_t } });
                    cir_gen.append(Inst{ .getelementptr = .{ .base = lhs_addr, .mul = null, .disp = cir_gen.getLast() } });
                },
                else => unreachable,
            }
        },
        .field => |fa| {
            generateExpr(fa.lhs, cir_gen, .self);

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
                    cir_gen.append(Inst{ .getelementptr = .{ .base = lhs_addr, .mul = null, .disp = cir_gen.getLast() } });
                },
                .array => {
                    // FIXME: why do we need this again?
                    cir_gen.append(Inst{ .array_len = lhs_t });
                },
                .type => {
                    const decl_t = cir_gen.get_expr_val_as_type(fa.lhs);
                    switch (TypePool.lookup(decl_t)) {
                        .subset => |subset| {
                            assert(subset.sub_t == TypePool.int);
                            for (subset.syms, subset.vals) |sym, v| {
                                if (sym == fa.rhs) {
                                    cir_gen.append(.{ .lit = .{ .int = @intFromEnum(v) }});
                                    return;
                                }
                            }
                        },
                        else => unreachable,
                    }
                },

                else => unreachable,
            }
        },
        .not => |not| {
            generateExpr(not, cir_gen, .self);
            cir_gen.append(Inst{ .not = cir_gen.getLast() });
        },
    }
}
