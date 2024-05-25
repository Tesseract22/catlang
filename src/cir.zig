const std = @import("std");
const Ast = @import("ast.zig");
const log = @import("log.zig");
const CompileError = Ast.EvalError;
const Register = enum {
    rax,
    rbx,
    rcx,
    rdx,
    rbp,
    rsp,
    rsi,
    rdi,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,
    xmm0,
    xmm1,
    xmm2,
    xmm3,
    xmm4,
    xmm5,
    xmm6,
    xmm7,

    pub const DivendReg = Register.rax;
    pub const DivQuotient = Register.rax;
    pub const DivRemainder = Register.rdx;


    pub fn format(value: Register, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.writeAll(@tagName(value));
    }
    
};
const RegisterManager = struct {

    unused: Regs,
    insts: [count]usize,
    const count = @typeInfo(Register).Enum.fields.len;
    pub const Regs = std.bit_set.ArrayBitSet(u8, count);
    pub fn init() RegisterManager {
        return RegisterManager {.unused = Regs.initFull(), .insts = undefined };
    }
    pub fn markUnusedAll(self: *RegisterManager) void {
        self.unused = Regs.initFull();
    }
    pub fn getInst(self: *RegisterManager, reg: Register) usize {
        return self.insts[@intFromEnum(reg)];
    }
    pub fn getUnusedTemp(self: *RegisterManager) ?Register {
        // TODO: get different kind of register@
        const idx = self.unused.findFirstSet() orelse return null;
        return @enumFromInt(idx);
    }
    pub fn getUnusedTempExclude(self: *RegisterManager, exclude: []const Register) ?Register {
        var exclude_mask = Regs.initFull();
        for (exclude) |reg| {
            exclude_mask.unset(@intFromEnum(reg));
        }
        const and_res = self.unused.intersectWith(exclude_mask);
        return @enumFromInt(and_res.findFirstSet() orelse return null);
    }
    pub fn getUnused(self: *RegisterManager, inst: ?usize) ?Register {
        // TODO: get different kind of register
        const reg = self.getUnusedTemp() orelse return null;
        self.markUsed(reg, inst);
        return reg;
    }
    pub fn getUnusedExclude(self: *RegisterManager, inst: ?usize, exclude: []const Register) ?Register {
        const reg = self.getUnusedTempExclude(exclude) orelse return null;
        self.markUsed(reg, inst);
        return reg;
    }
    pub fn markUsed(self: *RegisterManager, reg: Register, inst: ?usize) void {
        if (inst) |i| self.insts[@intFromEnum(reg)] = i;
        self.unused.unset(@intFromEnum(reg));

    }
    pub fn markUnused(self: *RegisterManager, reg: Register) void {
        self.unused.set(@intFromEnum(reg));

    }
    pub fn isUsed(self: *RegisterManager, reg: Register) bool {
        return !self.unused.isSet(@intFromEnum(reg));
    }
    pub fn getFloatArgLoc(self: *RegisterManager, t_pos: u8) Register {
        _ = self; // autofix
        if (t_pos > 8) @panic("Too much float argument");
        return @enumFromInt(@intFromEnum(Register.xmm0) + t_pos);
    }
    pub fn getArgLoc(self: *RegisterManager, arg_decl: Inst.Arg) Register {
        const reg: Register =  switch (arg_decl.t) {
            .float => self.getFloatArgLoc(arg_decl.t_pos),
            .int,
            .string => 
                switch (arg_decl.t_pos) {
                    0 => .rdi,
                    1 => .rsi,
                    2 => .rdx,
                    3 => .rcx,
                    4 => .r8,
                    5 => .r9,
                    else => @panic("Too much int argument"),
                }
            ,
            .void => unreachable,
        };
        if (self.isUsed(reg)) {
            log.err("{} already in used", .{reg});
            @panic("TODO: register already inused, save it somewhere");
        }
        return reg;
    }
};
const ResultLocation = union(enum) {
    reg: Register,
    stack_top: usize,
    stack_base: usize,
    int_lit: isize,
    data: usize,


    pub fn moveToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer) !void  {
        try writer.print("\tmov {}, ", .{reg});
        try self.print(writer);
        try writer.writeByte('\n');
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackTop(self: ResultLocation, off: usize, writer: std.fs.File.Writer) !void {
        try writer.print("\tmov QWORD [rbp - {}], ", .{off});
        try self.print(writer); 
        try writer.writeByte('\n');
    }

    pub fn print(self: ResultLocation, writer: std.fs.File.Writer) !void {
        switch (self) {
            .reg => |reg| try writer.print("{}", .{reg}),
            .stack_base => |off| try writer.print("[rbp - {}]", .{off}),
            .int_lit => |i| try writer.print("{}", .{i}),
            .data => |s| try writer.print("s{}", .{s}),
            .stack_top => |_| @panic("TODO"),
        }
    }
};
const Inst = union(enum) {
    // add,
    function: Fn,
    ret: usize, // index
    call: []const u8,
    arg: Arg,
    arg_decl: Arg,
    lit: Ast.Val,
    var_access: usize, // the instruction where it is defined
    var_decl: Ast.Type,
    print: Ast.Type,
    bin_op: BinOp, // TODO float

    pub const BinOp = struct {
        lhs: usize,
        op: Ast.Op,
        rhs: usize,
    };
    pub const Arg = struct {
        f: usize,
        t: Ast.Type,
        pos: u8,
        t_pos: u8,
    };
    pub const Fn = struct {
        name: []const u8,
        scope: Scope,
        frame_size: usize,
    };
    pub fn format(value: Inst, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.print("{s} ", .{@tagName(value)});
        switch (value) {
            .function => |f| try writer.print("{s}", .{f.name}),
            .call => |s| try writer.print("{s}", .{s}),
            .bin_op => |bin_op| try writer.print("{} {} {}", .{bin_op.lhs, bin_op.op, bin_op.rhs}),
        
            inline
            .var_decl,
            .ret,
            .arg_decl,
            .var_access,
            .print,
            .arg,
            .lit => |x| try writer.print("{}", .{x}),
        }
    }
};
const ScopeItem = struct {
    t: Ast.Type,
    i: usize,
};
const Scope = std.StringArrayHashMap(ScopeItem);
    
const CirGen = struct {
    insts: std.ArrayList(Inst),
    ast: *const Ast,
    scope: Scope,
    gpa: std.mem.Allocator,
    pub fn getLast(self: CirGen) usize {
        return self.insts.items.len - 1;
    }

};
const Cir = @This();
insts: []Inst,

pub fn typeSize(t: Ast.Type) usize {
    return switch (t) {
        .float => 8,
        .int => 8,
        .string => 8,
        .void => 0,
    };
}
pub fn consumeResult(results: []ResultLocation, idx: usize, reg_mangager: *RegisterManager) ResultLocation {
    const loc = results[idx];
    switch (loc) {
        .reg => |reg| reg_mangager.markUnused(reg),
        .stack_top => |top_off| {
            _ = top_off; // autofix
            @panic("TODO");
        },
        inline
        .data,
        .int_lit,
        .stack_base => |_| {},
    }
    return loc;
}
pub fn compile(self: Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator) !void {
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init();
    try file.print(builtinText ++ builtinShow ++ builtinStart, .{});
    var scope_size: usize = 0;
    var scope: *Scope = undefined;
    var data = std.ArrayList([]const u8).init(alloc);
    defer data.deinit();
    for (self.insts, 0..) |_, i| {
        log.debug("{}", .{i});
        switch (self.insts[i]) {
            .function => |*f| {
                
                try file.print("{s}:\n", .{f.name});
                try file.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
                var it = f.scope.iterator();
                while (it.next()) |entry| {
                    f.frame_size += typeSize(entry.value_ptr.t);
                }
                try file.print("\tsub rsp, {}\n", .{f.frame_size});
                scope = &f.scope;
                scope_size = 0;

            },
            .ret => |f| {
                const frame_size: usize = self.insts[f].function.frame_size;

                try file.print("\tadd rsp, {}\n", .{frame_size});
                try file.print("\tpop rbp\n", .{});
                try file.print("\tret\n", .{});
                // TODO deal with register
            },
            .lit => |lit| {
                switch (lit) {
                    .int => |int| results[i] = ResultLocation {.int_lit = int},
                    .string => |s| {
                        results[i] = ResultLocation {.data = data.items.len};
                        data.append(s) catch unreachable;

                    },
                    else => @panic("TODO"),
                }
            },
            .var_decl => |var_decl| {
                const size = typeSize(var_decl);
                scope_size += size;
                // TODO explicit operand position
                const loc = consumeResult(results, i - 1, &reg_manager);
                try loc.moveToStackTop(scope_size, file);
                results[i] = ResultLocation {.stack_base = scope_size};

                // try file.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const loc = results[var_access];
                results[i] = loc;
            },
            .arg_decl => |arg_decl| {
                // TODO handle differnt type
                // TODO handle different number of argument
                
                const reg = reg_manager.getArgLoc(arg_decl);
                const off = (arg_decl.pos + 1) * 8;
                try file.print("\tmov [rbp - {}], {}\n", .{off, reg});
                results[i] = ResultLocation {.stack_base = off};
                
            },
            .call => |f| {
                reg_manager.markUnusedAll();
                try file.print("\tcall {s}\n", .{f}); // TODO handle return
            },
            .arg => |arg| {
                const loc = results[i - 1];
                // const 
                const arg_reg = reg_manager.getArgLoc(arg);
                reg_manager.markUsed(arg_reg, i);
                switch (arg.t) {
                    .string,
                    .int => {
                        try loc.moveToReg(arg_reg, file);
                    },
                    else => @panic("TDOO"),
                }

            },
            .print => |t| {
                const loc = results[i - 1];
                try loc.moveToReg(.rsi, file);

                const format = switch (t) {
                    .int => "format",
                    .string => "formats",
                    .float => "formatf",
                    else => @panic("TODO"),
                    
                };
                try file.print("\tmov rdi, {s}\n" ++  "\tmov rax, 0\n" ++ "\tcall align_printf\n", .{format});

            },
            .bin_op => |bin_op| {
                if (bin_op.op == Ast.Op.div) {
                    // TODO
                    const exclude = [_]Register {Register.DivendReg, Register.DivQuotient, Register.DivRemainder};
                    if (reg_manager.isUsed(Register.DivendReg)) {
                        const other_inst = reg_manager.getInst(Register.DivendReg);
                        const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude) orelse @panic("TODO");
                        try results[other_inst].moveToReg(new_reg, file);
                        results[other_inst] = ResultLocation {.reg = new_reg};

                    }
                    if (reg_manager.isUsed(Register.DivRemainder)) {
                        const other_inst = reg_manager.getInst(Register.DivRemainder);
                        const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude) orelse @panic("TODO");
                        try results[other_inst].moveToReg(new_reg, file);
                        results[other_inst] = ResultLocation {.reg = new_reg};
                    }
                    const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);

                    const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                    const rhs_reg = reg_manager.getUnusedExclude(i, &.{Register.DivendReg}) orelse @panic("TODO");
                    try lhs_loc.moveToReg(Register.DivendReg, file);
                    try file.print("\tmov edx, 0\n", .{});
                    try rhs_loc.moveToReg(rhs_reg, file);
                    try file.print("\tidiv {}\n", .{rhs_reg});
                    reg_manager.markUsed(Register.DivQuotient, i);

                    results[i] = ResultLocation {.reg = Register.DivQuotient};
                    continue;
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                try lhs_loc.moveToReg(reg, file);
                
                const op = switch (bin_op.op) {
                    .plus => "add",
                    .minus => "sub",
                    .times => "imul",
                    .div => unreachable,
                };
                try file.print("\t{s} {}, ", .{op, reg});
                try rhs_loc.print(file);
                try file.writeByte('\n');

                results[i] = ResultLocation {.reg =  reg};
            }
        }
    }
    try file.print(builtinData, .{});
    for (data.items, 0..) |d, i| {
        try file.print("\ts{} db  \"{s}\", 0x0\n", .{i, d});
    }
}
pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            .function => |*f| {
                f.scope.deinit();
            },
            else => {},
        }
    }
    alloc.free(self.insts);

}
pub fn generate(ast: Ast, alloc: std.mem.Allocator) CompileError!Cir {
    var zir_gen = CirGen {.ast = &ast, .insts = std.ArrayList(Inst).init(alloc), .scope = Scope.init(alloc), .gpa = alloc };
    defer zir_gen.scope.deinit();
    for (ast.defs) |def| {
        try generateProc(def, &zir_gen);
    }
    // errdefer zir_gen.insts.deinit();

    return Cir {.insts = zir_gen.insts.toOwnedSlice() catch unreachable};
    
}
pub fn generateProc(def: Ast.ProcDef, zir_gen: *CirGen) CompileError!void {
    zir_gen.insts.append(Inst {.function = Inst.Fn {.name = def.data.name, .scope = undefined, .frame_size = 0}}) catch unreachable;
    const idx = zir_gen.getLast();
    var int_pos: u8 = 0;
    var float_pos: u8 = 0;
    // TODO struct pos
    for (def.data.args, 0..) |arg, pos| {
        const t_pos = switch (arg.type) {
            .float => blk: {
                float_pos += 1;
                break :blk float_pos - 1;
            },
            .int,
            .string => blk: {
                int_pos += 1;
                break :blk int_pos - 1;
            },
            .void => return CompileError.TypeMismatched,
        };
        zir_gen.insts.append(Inst {.arg_decl = .{.t = arg.type, .pos = @intCast(pos), .t_pos = t_pos, .f = idx}}) catch unreachable;
        zir_gen.scope.put(arg.name, ScopeItem {.i = zir_gen.getLast(), .t = arg.type}) catch unreachable;


    }
    for (def.data.body) |stat_id| {
        try generateStat(zir_gen.ast.stats[stat_id.idx], zir_gen);
    }
    zir_gen.insts.items[idx].function.scope = zir_gen.scope;
    zir_gen.scope = Scope.init(zir_gen.gpa);


    zir_gen.insts.append(Inst {.ret = idx}) catch unreachable;


}
pub fn generateStat(stat: Ast.Stat, zir_gen: *CirGen) CompileError!void {
    switch (stat.data) {
        .anon => |expr| _ = try generateExpr(zir_gen.ast.exprs[expr.idx], zir_gen),
        .var_decl => |var_decl| {
            // var_decl.
            const expr_type = try generateExpr(zir_gen.ast.exprs[var_decl.expr.idx], zir_gen);
            if (zir_gen.scope.fetchPut(var_decl.name, .{.t = expr_type, .i = zir_gen.getLast() + 1}) catch unreachable) |_| {
                log.err("{} Identifier redefined: `{s}`", .{stat.tk.loc, var_decl.name});
                // TODO provide location of previously defined variable
                return CompileError.Undefined;
            }
            zir_gen.insts.append(.{.var_decl = expr_type}) catch unreachable;
        }
    }

}
pub fn generateExpr(expr: Ast.Expr, zir_gen: *CirGen) CompileError!Ast.Type {
    switch (expr.data) {
        .atomic => |atomic| return try generateAtomic(atomic, zir_gen),
        .bin_op => |bin_op| {
            const lhs = zir_gen.ast.exprs[bin_op.lhs.idx];
            const lhs_t = try generateExpr(lhs, zir_gen);
            if (lhs_t != Ast.Type.int) {
                log.err("{} Invalid type of operand for `{}`, expect `int`, got {}", .{lhs.tk, bin_op.op, lhs_t});
                return CompileError.TypeMismatched;
            }
            const lhs_idx = zir_gen.getLast();
            const rhs = zir_gen.ast.exprs[bin_op.rhs.idx];
            const rhs_t = try generateExpr(rhs, zir_gen);
            if (rhs_t != Ast.Type.int) {
                log.err("{} Invalid type of operand for `{}`, expect `int`, got {}", .{rhs.tk, bin_op.op, rhs_t});
                return CompileError.TypeMismatched;
            }
            const rhs_idx = zir_gen.getLast();
            zir_gen.insts.append(Inst {.bin_op = .{.lhs = lhs_idx, .rhs = rhs_idx, .op = bin_op.op}}) catch unreachable;
            return Ast.Type.int;
        },
    }

}
pub fn generateAtomic(atomic: Ast.Atomic, zir_gen: *CirGen) CompileError!Ast.Type {
    switch (atomic.data) {
        .float => |f| {
            zir_gen.insts.append(Inst {.lit = .{ .float =  f}}) catch unreachable;
            return Ast.Type.float;
        },
        .int => |i| {
            zir_gen.insts.append(Inst {.lit = .{ .int =  i}}) catch unreachable;
            return Ast.Type.int;
        },
        .string => |s| {
            zir_gen.insts.append(Inst {.lit = .{ .string =s}}) catch unreachable;
            return Ast.Type.string;
        },
        .paren => |e| {
            return try generateExpr(zir_gen.ast.exprs[e.idx], zir_gen);
        },
        .iden => |i| {
            const t = zir_gen.scope.get(i) orelse {
                log.err("{} Undefined identifier: {s}", .{atomic.tk.loc, i});
                return CompileError.Undefined;
            };
            zir_gen.insts.append(Inst {.var_access = t.i}) catch unreachable;
            return t.t;

        },
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                if (fn_app.args.len != 1) {
                    std.log.err("{} builtin function `print` expects exactly one argument", .{atomic.tk});
                    return CompileError.TypeMismatched;
                }

                const t = try generateExpr(zir_gen.ast.exprs[fn_app.args[0].idx], zir_gen);
                zir_gen.insts.append(Inst {.print = t}) catch unreachable;
                return Ast.Type.void;
            }
            const fn_def = for (zir_gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{atomic.tk, fn_app.func});
                return CompileError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{atomic.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return CompileError.TypeMismatched;
            }
            var fn_eval_scope = std.StringHashMap(Ast.VarBind).init(zir_gen.scope.allocator); // TODO account for global variable
            defer fn_eval_scope.deinit();


            var int_pos: u8 = 0;
            var float_pos: u8 = 0;
            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = zir_gen.ast.exprs[fa.idx];
                const e_type = try generateExpr(e, zir_gen);
                if (@intFromEnum(e_type) != @intFromEnum(fd.type)) {
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{e.tk.loc, i, fn_app.func, fd.type, @tagName(e_type) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return CompileError.TypeMismatched;
                }
                const entry = fn_eval_scope.fetchPut(fd.name, Ast.VarBind {.name = fd.name, .tk = fd.tk, .type = e_type}) catch unreachable; // TODO account for global variable
                if (entry) |_| {
                    log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{atomic.tk, i, fn_app.func, fd.name });
                    // TODO provide location of previously defined variable
                    return CompileError.Redefined;
                }
                const t_pos = switch (e_type) {
                    .float => blk: {
                        float_pos += 1;
                        break :blk float_pos - 1;
                    },
                    .int,
                    .string => blk: {
                        int_pos += 1;
                        break :blk int_pos - 1;
                    },
                    .void => return CompileError.TypeMismatched,
                };

                zir_gen.insts.append(Inst {.arg = Inst.Arg {.t = e_type, .pos = @intCast(i), .t_pos = t_pos, .f = 0}}) catch unreachable;
            }
            zir_gen.insts.append(.{.call = fn_app.func}) catch unreachable;

            // for (fn_def.data.body) |di| {
            //     const stat = zir_gen.ast.stats[di.idx];
            //     try generateStat(stat, zir_gen);
            // }

            return Ast.Type.void;
        }
    }

}


const builtinData = 
    \\section        .data  
    \\    format        db "%i", 0xa, 0x0
    \\    formatf       db "%f", 0xa, 0x0
    \\    formats       db "%s", 0xa, 0x0
    \\
    \\    aligned       db 0
    \\
    ;

const builtinText = 
\\section        .text
\\extern printf
\\extern exit
\\global         _start
\\
;
const builtinShow = 
\\align_printf:
\\    mov rbx, rsp
\\    and rbx, 0x000000000000000f
\\    cmp rbx, 0
\\    je .align_end
\\    .align:
\\       push rbx
\\        mov byte [aligned], 1
\\    .align_end:
\\    call printf
\\    cmp byte [aligned], 1
\\    jne .unalign_end
\\    .unalign:
\\        pop rbx
\\        mov byte [aligned], 0
\\    .unalign_end:
\\    ret
\\
;


const builtinStart = "_start:\n\tcall main\n\tmov rdi, 0\n\tcall exit\n";
const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";