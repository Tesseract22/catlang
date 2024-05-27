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

    pub fn isFloat(self: Register) bool {
        return switch (@intFromEnum(self)) {
            @intFromEnum(Register.xmm0) ... @intFromEnum(Register.xmm7) => true,
            else => false
        };
    }

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
    pub const GpRegs = [_]Register {
        .rax, .rcx, .rdx, .rbx, .rsi, .rdi, .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15,
    };
    pub const CallerSaveRegs = [_]Register {
        .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11
    };
    pub const CalleeSaveRegs = [_]Register {
        .rbx, .r12, .r13, .r14, .r15
    };
    pub const FlaotRegs = [_]Register {
        .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7,
    };
    pub const GpMask = cherryPick(&GpRegs);
    pub const CallerSaveMask = cherryPick(&CallerSaveRegs);
    pub const CalleeSaveMask = cherryPick(&CalleeSaveRegs);
    pub const FloatMask = cherryPick(&FlaotRegs);

    pub fn debug(self: RegisterManager) void {
        var it = self.unused.iterator(.{.kind = .unset});
        while (it.next()) |i| {
            log.debug("{} inused", .{@as(Register, @enumFromInt(i))});
        }
    }
    pub fn init() RegisterManager {
        return RegisterManager {.unused = Regs.initFull(), .insts = undefined };
    }
    pub fn cherryPick(regs: []const Register) Regs {
        var mask = Regs.initEmpty();
        for (regs) |r| {
            mask.set(@intFromEnum(r));
        }
        return mask;
    }
    pub fn markUnusedAll(self: *RegisterManager) void {
        self.unused = Regs.initFull();
    }
    pub fn getInst(self: *RegisterManager, reg: Register) usize {
        return self.insts[@intFromEnum(reg)];
    }
    // pub fn getUnusedTemp(self: *RegisterManager) ?Register {
    //     // TODO: get different kind of register@
    //     const idx = self.unused.findFirstSet() orelse return null;
    //     return @enumFromInt(idx);
    // }
    // pub fn getUnusedTempExclude(self: *RegisterManager, exclude: []const Register) ?Register {
    //     var exclude_mask = Regs.initFull();
    //     for (exclude) |reg| {
    //         exclude_mask.unset(@intFromEnum(reg));
    //     }
    //     const and_res = self.unused.intersectWith(exclude_mask);
    //     return @enumFromInt(and_res.findFirstSet() orelse return null);
    // }
    pub fn getUnused(self: *RegisterManager, inst: ?usize, cherry: Regs) ?Register {
        return self.getUnusedExclude(inst, &.{}, cherry);
    }
    pub fn getUnusedExclude(self: *RegisterManager, inst: ?usize, exclude: []const Register, cherry: Regs) ?Register {
        var exclude_mask = Regs.initFull();
        for (exclude) |reg| {
            exclude_mask.unset(@intFromEnum(reg));
        }
        const res_mask = self.unused.intersectWith(exclude_mask).intersectWith(cherry);
        const reg: Register =  @enumFromInt(res_mask.findFirstSet() orelse return null);
        self.markUsed(reg, inst);
        return reg;
    }
    pub fn markUsed(self: *RegisterManager, reg: Register, inst: ?usize) void {
        if (inst) |i| {
            self.insts[@intFromEnum(reg)] = i;
            self.unused.unset(@intFromEnum(reg));
        }

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
    pub fn getArgLoc(self: *RegisterManager, t_pos: u8, t: Ast.Type) Register {
        const reg: Register =  switch (t) {
            .float => self.getFloatArgLoc(t_pos),
            .int,
            .string => 
                switch (t_pos) {
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
    string_data: usize,
    float_data: usize,


    pub fn moveToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer) !void  { 
        var mov: []const u8 = "mov";
        switch (self) {
            .reg => |self_reg| {
                if (self_reg == reg) return;
                if (self_reg.isFloat()) mov = "movsd";
            },
            else => {},
        }
        if (reg.isFloat()) mov = "movsd";
        try writer.print("\t{s} {}, ", .{mov, reg});
        try self.print(writer);
        try writer.writeByte('\n');
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, off: usize, writer: std.fs.File.Writer) !void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) "movsd" else "mov";
        try writer.print("\t{s} QWORD [rbp - {}], ", .{mov, off});
        try self.print(writer); 
        try writer.writeByte('\n');
    }

    pub fn print(self: ResultLocation, writer: std.fs.File.Writer) !void {
        switch (self) {
            .reg => |reg| try writer.print("{}", .{reg}),
            .stack_base => |off| try writer.print("[rbp - {}]", .{off}),
            .int_lit => |i| try writer.print("{}", .{i}),
            .string_data => |s| try writer.print("s{}", .{s}),
            .float_data => |f| try writer.print("[f{}]", .{f}),
            .stack_top => |_| @panic("TODO"),
        }
    }
};
const Inst = union(enum) {
    // add,
    function: Fn,
    ret: Ret, // index
    call: Call,
    arg: ArgExpr,
    arg_decl: ArgDecl,
    lit: Ast.Val,
    var_access: usize, // the instruction where it is defined
    var_decl: Ast.Type,
    print: Ast.Type,
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,
    addf: BinOp,
    subf: BinOp,
    mulf: BinOp,
    divf: BinOp,

    pub const Call = struct {
        name: []const u8,
        t: Ast.Type,
    };
    pub const Ret = struct {
        f: usize,
        t: Ast.Type,
    };
    pub const BinOp = struct {
        lhs: usize,
        rhs: usize,
    };
    pub const ArgExpr = struct {
        t: Ast.Type,
        pos: u8,
        t_pos: u8,
        expr_inst: usize,
    };
    pub const ArgDecl = struct {
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
            .add => |bin_op| try writer.print("{} + {}", .{bin_op.lhs, bin_op.rhs}),
            .sub => |bin_op| try writer.print("{} - {}", .{bin_op.lhs, bin_op.rhs}),
            .mul => |bin_op| try writer.print("{} * {}", .{bin_op.lhs, bin_op.rhs}),
            .div => |bin_op| try writer.print("{} / {}", .{bin_op.lhs, bin_op.rhs}),
            .addf => |bin_op| try writer.print("{} +. {}", .{bin_op.lhs, bin_op.rhs}),
            .subf => |bin_op| try writer.print("{} -. {}", .{bin_op.lhs, bin_op.rhs}),
            .mulf => |bin_op| try writer.print("{} *. {}", .{bin_op.lhs, bin_op.rhs}),
            .divf => |bin_op| try writer.print("{} /. {}", .{bin_op.lhs, bin_op.rhs}),              
            .call => |s| try writer.print("{s}: {}", .{s.name, s.t}),
        
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
    arena: std.mem.Allocator,
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
        .float_data,
        .string_data,
        .int_lit,
        .stack_base => |_| {},
    }
    return loc;
}
pub fn compile(self: Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator) !void {
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init();
    try file.print(builtinText ++ builtinStart, .{});
    var scope_size: usize = 0;
    var scope: *Scope = undefined;

    var string_data = std.StringArrayHashMap(usize).init(alloc);
    defer string_data.deinit();
    var float_data = std.AutoArrayHashMap(usize, usize).init(alloc);
    defer float_data.deinit();
    for (self.insts, 0..) |_, i| {
        reg_manager.debug(); 
        log.debug("[{}] {}", .{i, self.insts[i]});
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
            .ret => |ret| {
                const frame_size: usize = self.insts[ret.f].function.frame_size;

                switch (ret.t) {
                    .void => {},
                    .int,
                    .string => {
                        const loc = consumeResult(results, i - 1, &reg_manager);
                        if (reg_manager.isUsed(.rax)) @panic("unreachable");
                        try loc.moveToReg(.rax, file);

                    },
                    .float => @panic("TODO"),
                    
                }
                try file.print("\tadd rsp, {}\n", .{frame_size});
                try file.print("\tpop rbp\n", .{});
                try file.print("\tret\n", .{});
                // TODO deal with register
            },
            .lit => |lit| {
                switch (lit) {
                    .int => |int| results[i] = ResultLocation {.int_lit = int},
                    .string => |s| {
                        const kv  = string_data.getOrPutValue(s, string_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else string_data.count() - 1;
                        results[i] = ResultLocation {.string_data = idx};


                    },
                    .float => |f| {
                        const kv = float_data.getOrPutValue(@bitCast(f), float_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else float_data.count() - 1;
                        results[i] = ResultLocation {.float_data = idx};

                    },
                    else => unreachable,
                }
            },
            .var_decl => |var_decl| {
                const size = typeSize(var_decl);
                scope_size += size;
                // TODO explicit operand position
                var loc = consumeResult(results, i - 1, &reg_manager);
                if (loc == ResultLocation.float_data) {
                    const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                    try loc.moveToReg(temp_reg, file);
                    loc = ResultLocation {.reg= temp_reg};
                }
                try loc.moveToStackBase(scope_size, file);
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
                
                const reg = reg_manager.getArgLoc(arg_decl.t_pos ,arg_decl.t);
                const off = (arg_decl.pos + 1) * 8;
                try file.print("\tmov [rbp - {}], {}\n", .{off, reg});
                results[i] = ResultLocation {.stack_base = off};
                
            },
            .call => |call| {
                // reg_manager.markUnusedAll(); // TODO caller saved register
                const caller_used = RegisterManager.CallerSaveMask.differenceWith(reg_manager.unused);
                var it = caller_used.iterator(.{ .kind = .set });
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);
                    const inst = reg_manager.getInst(reg);
                    if (self.insts[inst] == Inst.arg) continue;
                    const callee_unused = RegisterManager.CalleeSaveMask.intersectWith(reg_manager.unused);
                    const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));
                    try ResultLocation.moveToReg(ResultLocation {.reg = reg}, dest_reg, file);
                    results[inst] = ResultLocation {.reg = dest_reg};

                    reg_manager.markUnused(reg);
                    reg_manager.markUsed(dest_reg, inst);
                    
                }
                try file.print("\tcall {s}\n", .{call.name}); // TODO handle return
                switch (call.t) {
                    .void => {},
                    .int,
                    .string => {
                        if (reg_manager.isUsed(.rax)) @panic("TODO");
                        reg_manager.markUsed(.rax, i);
                        results[i] = ResultLocation {.reg = .rax};
                    },
                    .float => @panic("TODO"),
                }
            },
            .arg => |arg| {
                const loc = consumeResult(results, arg.expr_inst, &reg_manager);
                // const 
                const arg_reg = reg_manager.getArgLoc(arg.t_pos, arg.t);
                if (reg_manager.isUsed(arg_reg)) @panic("TODO");
                try loc.moveToReg(arg_reg, file);

                if (arg.t == Ast.Type.float and self.insts[i + 1] == Inst.call) {
                    try file.print("\tmov rax, {}\n", .{arg.t_pos + 1});
                }

            },
            .print => |t| {
                const loc = consumeResult(results, i - 1, &reg_manager);
                try loc.moveToReg(.rsi, file);

                const format = switch (t) {
                    .int => "format",
                    .string => "formats",
                    .float => "formatf",
                    .void => @panic("void cannot be print")
                    
                };
                try file.print("\tmov rdi, {s}\n" ++  "\tmov rax, 0\n" ++ "\tcall align_printf\n", .{format});

            },
            .add,
            .sub,
            .mul, 
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                try lhs_loc.moveToReg(reg, file);
                
                const op = switch (self.insts[i]) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "imul",
                    else => unreachable,
                };
                try file.print("\t{s} {}, ", .{op, reg});
                try rhs_loc.print(file);
                try file.writeByte('\n');

                results[i] = ResultLocation {.reg =  reg};
            },
            .div => |bin_op| {
                const exclude = [_]Register {Register.DivendReg, Register.DivQuotient, Register.DivRemainder};
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file);
                    results[other_inst] = ResultLocation {.reg = new_reg};

                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file);
                    results[other_inst] = ResultLocation {.reg = new_reg};
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{Register.DivendReg}, RegisterManager.GpMask) orelse @panic("TODO");
                try lhs_loc.moveToReg(Register.DivendReg, file);
                try file.print("\tmov edx, 0\n", .{});
                try rhs_loc.moveToReg(rhs_reg, file);
                try file.print("\tidiv {}\n", .{rhs_reg});
                reg_manager.markUsed(Register.DivQuotient, i);

                results[i] = ResultLocation {.reg = Register.DivQuotient};
                continue;
            },
            .addf,
            .subf,
            .mulf,
            .divf,
             => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");

                try lhs_loc.moveToReg(result_reg, file);
                try rhs_loc.moveToReg(temp_reg, file);
                const op = switch (self.insts[i]) {
                    .addf => "addsd",
                    .subf => "subsd",
                    .mulf => "mulsd",
                    .divf => "divsd",
                    else => unreachable,
                };
                try file.print("\t{s} {}, {}\n", .{op, result_reg, temp_reg});
                results[i] = ResultLocation {.reg = result_reg};
            }
            
        }
    }
    try file.print(builtinData, .{});
    var string_data_it = string_data.iterator();
    while (string_data_it.next()) |entry| {
        try file.print("\ts{} db\t", .{entry.value_ptr.*});
        for (entry.key_ptr.*) |c| {
            try file.print("{}, ", .{c});
        }
        try file.print("0\n", .{});
    }
    var float_data_it = float_data.iterator();
    while (float_data_it.next()) |entry| {
        try file.print("\tf{} dq\t0x{x}\n", .{entry.value_ptr.*, entry.key_ptr.*});
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
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var zir_gen = CirGen {.ast = &ast, .insts = std.ArrayList(Inst).init(alloc), .scope = Scope.init(alloc), .gpa = alloc, .arena = arena.allocator() };
    defer zir_gen.scope.deinit();
    errdefer zir_gen.insts.deinit();
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
        zir_gen.insts.append(Inst {.arg_decl = .{.t = arg.type, .pos = @intCast(pos), .t_pos = t_pos}}) catch unreachable;
        zir_gen.scope.put(arg.name, ScopeItem {.i = zir_gen.getLast(), .t = arg.type}) catch unreachable;


    }
    for (def.data.body) |stat_id| {
        try generateStat(zir_gen.ast.stats[stat_id.idx], zir_gen);
        const stat_inst: *Inst = &zir_gen.insts.items[zir_gen.getLast()];
        switch (stat_inst.*) {
            .ret => |ret| {
                if (ret.t != def.data.ret) {
                    log.err("{} function expects `{}`, got `{}` in ret statement", .{zir_gen.ast.stats[stat_id.idx].tk.loc, def.data.ret, ret.t});
                    return CompileError.TypeMismatched;
                }
                stat_inst.ret.f = idx;
            },
            else => {},
        }
    }
    zir_gen.insts.items[idx].function.scope = zir_gen.scope;
    zir_gen.scope = Scope.init(zir_gen.gpa);

    const last_inst = zir_gen.getLast();
    if (zir_gen.insts.items[last_inst] != Inst.ret) {
        if (def.data.ret == Ast.Type.void) {
            zir_gen.insts.append(Inst {.ret = .{.f = idx, .t = def.data.ret}}) catch unreachable;
        } else {
            log.err("{} function implicitly returns", .{def.tk});
            return CompileError.TypeMismatched;
        }
    }


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
        },
        .ret => |expr| {
            const expr_type = try generateExpr(zir_gen.ast.exprs[expr.idx], zir_gen);
            zir_gen.insts.append(.{.ret = .{.f = undefined, .t = expr_type}}) catch unreachable;

        }
    }

}
pub fn generateExpr(expr: Ast.Expr, zir_gen: *CirGen) CompileError!Ast.Type {
    switch (expr.data) {
        .atomic => |atomic| return try generateAtomic(atomic, zir_gen),
        .bin_op => |bin_op| {
            const lhs = zir_gen.ast.exprs[bin_op.lhs.idx];
            const lhs_t = try generateExpr(lhs, zir_gen);
            if (lhs_t != Ast.Type.int and lhs_t != Ast.Type.float) {
                log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{lhs.tk.loc, bin_op.op, lhs_t});
                return CompileError.TypeMismatched;
            }
            const lhs_idx = zir_gen.getLast();

            const rhs = zir_gen.ast.exprs[bin_op.rhs.idx];
            const rhs_t = try generateExpr(rhs, zir_gen);
            if (rhs_t != Ast.Type.int and rhs_t != Ast.Type.float) {
                log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{rhs.tk.loc, bin_op.op, rhs_t});
                return CompileError.TypeMismatched;
            }
            if (lhs_t != rhs_t) {
                log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{lhs.tk.loc, bin_op.op, lhs_t, rhs_t});
                return CompileError.TypeMismatched;
            }
            const rhs_idx = zir_gen.getLast();
            const bin = Inst.BinOp {.lhs = lhs_idx, .rhs = rhs_idx};
            const inst = 
            if (lhs_t == Ast.Type.int) switch (bin_op.op) {
                .plus => Inst {.add = bin},
                .minus => Inst {.sub = bin},
                .times => Inst {.mul = bin},
                .div => Inst {.div = bin},
            }
            else switch (bin_op.op) {
                .plus => Inst {.addf = bin},
                .minus => Inst {.subf = bin},
                .times => Inst {.mulf = bin},
                .div => Inst {.divf = bin},
            };
            zir_gen.insts.append(inst) catch unreachable;
            return lhs_t;
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
                const expr_idx = zir_gen.getLast();
                const format = switch (t) {
                    .void => unreachable,
                    .int => "%i\n",
                    .string => "%s\n",
                    .float => "%f\n",
                };
                zir_gen.insts.append(Inst {.lit = .{.string = format}}) catch unreachable;
                zir_gen.insts.append(Inst {.arg = .{.expr_inst = zir_gen.getLast(), .pos = 0, .t_pos = 0, .t = .string}}) catch unreachable;
                zir_gen.insts.append(Inst {.arg = .{.expr_inst = expr_idx, .pos = 1, .t_pos = if (t == Ast.Type.float) 0 else 1, .t = t}}) catch unreachable;
                zir_gen.insts.append(Inst {.call = .{.name = "printf", .t = .void}}) catch unreachable;
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
            // generate all args expresssion
            // and then all args int
            var expr_insts = std.ArrayList(usize).init(zir_gen.arena);
            defer expr_insts.deinit();
            for (fn_def.data.args, fn_app.args, 0..) |fd, fa, i| {
                const e = zir_gen.ast.exprs[fa.idx];
                const e_type = try generateExpr(e, zir_gen);
                expr_insts.append(zir_gen.getLast()) catch unreachable;
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

            }
            for (fn_def.data.args, expr_insts.items, 0..) |fd, expr_inst, i| {
                const t_pos = switch (fd.type) {
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

                zir_gen.insts.append(Inst {.arg = Inst.ArgExpr {.t = fd.type, .pos = @intCast(i), .t_pos = t_pos, .expr_inst = expr_inst }}) catch unreachable;
            }
            zir_gen.insts.append(.{.call = .{.name = fn_def.data.name, .t = fn_def.data.ret}}) catch unreachable;

            // for (fn_def.data.body) |di| {
            //     const stat = zir_gen.ast.stats[di.idx];
            //     try generateStat(stat, zir_gen);
            // }

            return fn_def.data.ret;
        }
    }

}


const builtinData = 
    \\section        .data  
    \\
    ;

const builtinText = 
\\section        .text
\\extern printf
\\extern exit
\\global         _start
\\
;



const builtinStart = "_start:\n\tcall main\n\tmov rdi, 0\n\tcall exit\n";
const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";