const std = @import("std");
const Ast = @import("ast.zig");
const Expr = Ast.Expr;
const Type = Ast.Type;
const Stat = Ast.Stat;
const Op = Ast.Op;
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
    pub const Lower8 = enum {
        al,
        bl,
        cl,
        dl,
        sil,
        dil,
        bpl,
        spl,
        r8b,
        r9b,
        r10b,
        r11b,
        r12b,
        r13b,
        r14b,
        r15b,
        pub fn format(value: Lower8, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = try writer.writeAll(@tagName(value));
        }
    };

    pub fn isFloat(self: Register) bool {
        return switch (@intFromEnum(self)) {
            @intFromEnum(Register.xmm0)...@intFromEnum(Register.xmm7) => true,
            else => false,
        };
    }
    pub fn lower8(self: Register) Lower8 {
        return @enumFromInt(@intFromEnum(self));
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
    pub const GpRegs = [_]Register{
        .rax, .rcx, .rdx, .rbx, .rsi, .rdi, .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15,
    };
    pub const CallerSaveRegs = [_]Register{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 };
    pub const CalleeSaveRegs = [_]Register{ .rbx, .r12, .r13, .r14, .r15 };
    pub const FlaotRegs = [_]Register{
        .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7,
    };
    pub const GpMask = cherryPick(&GpRegs);
    pub const CallerSaveMask = cherryPick(&CallerSaveRegs);
    pub const CalleeSaveMask = cherryPick(&CalleeSaveRegs);
    pub const FloatMask = cherryPick(&FlaotRegs);

    pub fn debug(self: RegisterManager) void {
        var it = self.unused.iterator(.{ .kind = .unset });
        while (it.next()) |i| {
            log.debug("{} inused", .{@as(Register, @enumFromInt(i))});
        }
    }
    pub fn init() RegisterManager {
        return RegisterManager{ .unused = Regs.initFull(), .insts = undefined };
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
        const reg: Register = @enumFromInt(res_mask.findFirstSet() orelse return null);
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
    pub fn getArgLoc(self: *RegisterManager, t_pos: u8, t: Type) Register {
        const reg: Register = switch (t) {
            .float => self.getFloatArgLoc(t_pos),
            .int, .string, .bool => switch (t_pos) {
                0 => .rdi,
                1 => .rsi,
                2 => .rdx,
                3 => .rcx,
                4 => .r8,
                5 => .r9,
                else => @panic("Too much int argument"),
            },
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
    local_lable: usize,

    pub fn moveToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer) !void {
        var mov: []const u8 = "mov";
        switch (self) {
            .reg => |self_reg| {
                if (self_reg == reg) return;
                if (self_reg.isFloat()) mov = "movsd";
            },
            else => {},
        }
        if (reg.isFloat()) mov = "movsd";
        try writer.print("\t{s} {}, ", .{ mov, reg });
        try self.print(writer);
        try writer.writeByte('\n');
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, off: usize, writer: std.fs.File.Writer) !void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) "movsd" else "mov";
        try writer.print("\t{s} QWORD [rbp - {}], ", .{ mov, off });
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
            .local_lable, .stack_top => |_| @panic("TODO"),
        }
    }
};
const Inst = union(enum) {
    // add,
    function: Fn,
    block_start: usize, // lazily populated
    block_end: usize,
    ret: Ret, // index
    call: Call,
    arg: ArgExpr,
    arg_decl: ArgDecl,
    lit: Ast.Val,
    var_access: usize, // the instruction where it is defined
    var_decl: Type,

    if_start: Scope, // count
    if_end: usize, // refer to if start

    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,
    mod: BinOp,

    addf: BinOp,
    subf: BinOp,
    mulf: BinOp,
    divf: BinOp,
    eq: BinOp,
    i2f,
    f2i,

    pub const Call = struct {
        name: []const u8,
        t: Type,
    };
    pub const Ret = struct {
        f: usize,
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
    pub const ArgDecl = struct {
        t: Type,
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
            .add => |bin_op| try writer.print("{} + {}", .{ bin_op.lhs, bin_op.rhs }),
            .sub => |bin_op| try writer.print("{} - {}", .{ bin_op.lhs, bin_op.rhs }),
            .mul => |bin_op| try writer.print("{} * {}", .{ bin_op.lhs, bin_op.rhs }),
            .div => |bin_op| try writer.print("{} / {}", .{ bin_op.lhs, bin_op.rhs }),
            .mod => |bin_op| try writer.print("{} % {}", .{ bin_op.lhs, bin_op.rhs }),
            .addf => |bin_op| try writer.print("{} +. {}", .{ bin_op.lhs, bin_op.rhs }),
            .subf => |bin_op| try writer.print("{} -. {}", .{ bin_op.lhs, bin_op.rhs }),
            .mulf => |bin_op| try writer.print("{} *. {}", .{ bin_op.lhs, bin_op.rhs }),
            .divf => |bin_op| try writer.print("{} /. {}", .{ bin_op.lhs, bin_op.rhs }),
            .eq => |bin_op| try writer.print("{} == {}", .{ bin_op.lhs, bin_op.rhs }),
            .call => |s| try writer.print("{s}: {}", .{ s.name, s.t }),
            .if_start => try writer.print("if start", .{}),
            .if_end => |start| try writer.print("if end {}", .{start}),
            .block_start => try writer.print("{{", .{}),
            .block_end => |start| try writer.print("}} {}", .{start}),

            inline .i2f, .f2i, .var_decl, .ret, .arg_decl, .var_access, .arg, .lit => |x| try writer.print("{}", .{x}),
        }
    }
};
const ScopeItem = struct {
    t: Type,
    i: usize,
};
const Scope = std.StringArrayHashMap(ScopeItem);
const ScopeStack = struct {
    stack: std.ArrayList(Scope),
    pub fn init(alloc: std.mem.Allocator) ScopeStack {
        return ScopeStack{ .stack = std.ArrayList(Scope).init(alloc) };
    }
    pub fn get(self: ScopeStack, name: []const u8) ?ScopeItem {
        return for (self.stack.items) |scope| {
            if (scope.get(name)) |v| break v;
        } else null;
    }
    pub fn putTop(self: *ScopeStack, name: []const u8, item: ScopeItem) bool {
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
};
const CirGen = struct {
    insts: std.ArrayList(Inst),
    ast: *const Ast,
    scopes: ScopeStack,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    fn_ctx: ?usize,
    pub fn getLast(self: CirGen) usize {
        return self.insts.items.len - 1;
    }
    pub fn append(self: *CirGen, inst: Inst) void {
        self.insts.append(inst) catch unreachable;
    }
};
const Cir = @This();
insts: []Inst,

pub fn typeSize(t: Type) usize {
    return switch (t) {
        .float => 8,
        .int => 8,
        .bool => 8,
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
        inline .float_data, .string_data, .int_lit, .stack_base, .local_lable => |_| {},
    }
    return loc;
}
fn getFrameSize(self: Cir, block_start: usize, curr_idx: *usize) usize {
    var size: usize = 0;
    while (true) : (curr_idx.* += 1) {
        const inst = self.insts[curr_idx.*];
        switch (inst) {
            .block_start => {
                curr_idx.* += 1;
                const block_frame_size = getFrameSize(self, curr_idx.* - 1, curr_idx);
                curr_idx.* += 1;
                const rest_size = getFrameSize(self, block_start, curr_idx);
                return size + @max(block_frame_size, rest_size);
            },
            .block_end => |start| if (block_start == start) return size,
            .var_decl => |t| size += typeSize(t),
            .arg_decl => |arg_decl| size += typeSize(arg_decl.t),
            else => {},
        }
    }
    unreachable;
}
pub fn compile(self: Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator) !void {
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init();
    try file.print(builtinText ++ builtinShow ++ builtinStart, .{});
    var scope_size: usize = 0;
    var curr_block: usize = 0;
    var local_lable_ct: usize = 0;

    var string_data = std.StringArrayHashMap(usize).init(alloc);
    defer string_data.deinit();
    var float_data = std.AutoArrayHashMap(usize, usize).init(alloc);
    defer float_data.deinit();
    for (self.insts, 0..) |_, i| {
        reg_manager.debug();
        log.debug("[{}] {}", .{ i, self.insts[i] });
        switch (self.insts[i]) {
            .function => |*f| {
                try file.print("{s}:\n", .{f.name});
                try file.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
                var curr_idx = i + 2;
                f.frame_size = self.getFrameSize(i + 1, &curr_idx);
                try file.print("\tsub rsp, {}\n", .{f.frame_size});
                scope_size = 0;
                local_lable_ct = 0;

                // save callee-saved register
                // TODO alloc stack but lazily push
                var it = RegisterManager.CalleeSaveMask.iterator(.{});
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);
                    try file.print("\tpush {}\n", .{reg});
                }
            },
            .ret => |ret| {
                const frame_size: usize = self.insts[ret.f].function.frame_size;

                switch (ret.t) {
                    .void => {},
                    .int, .string, .bool => {
                        const loc = consumeResult(results, i - 1, &reg_manager);
                        if (reg_manager.isUsed(.rax)) @panic("unreachable");
                        try loc.moveToReg(.rax, file);
                    },
                    .float => @panic("TODO"),
                }
                var it = RegisterManager.CalleeSaveMask.iterator(.{ .direction = .reverse });
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);
                    try file.print("\tpop {}\n", .{reg});
                }
                try file.print("\tadd rsp, {}\n", .{frame_size});
                try file.print("\tpop rbp\n", .{});
                try file.print("\tret\n", .{});
                // TODO deal with register
            },
            .lit => |lit| {
                switch (lit) {
                    .int => |int| results[i] = ResultLocation{ .int_lit = int },
                    .string => |s| {
                        const kv = string_data.getOrPutValue(s, string_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else string_data.count() - 1;
                        results[i] = ResultLocation{ .string_data = idx };
                    },
                    .float => |f| {
                        const kv = float_data.getOrPutValue(@bitCast(f), float_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else float_data.count() - 1;
                        results[i] = ResultLocation{ .float_data = idx };
                    },
                    else => unreachable,
                }
            },
            .var_decl => |var_decl| {
                const size = typeSize(var_decl);
                self.insts[curr_block].block_start += size;
                scope_size += size;
                // TODO explicit operand position
                var loc = consumeResult(results, i - 1, &reg_manager);
                if (loc == ResultLocation.float_data) {
                    const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                    try loc.moveToReg(temp_reg, file);
                    loc = ResultLocation{ .reg = temp_reg };
                }
                try loc.moveToStackBase(scope_size, file);
                results[i] = ResultLocation{ .stack_base = scope_size };

                // try file.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const loc = results[var_access];
                results[i] = loc;
            },
            .arg_decl => |arg_decl| {
                // TODO handle differnt type
                // TODO handle different number of argument

                const reg = reg_manager.getArgLoc(arg_decl.t_pos, arg_decl.t);
                const size = typeSize(arg_decl.t);
                self.insts[curr_block].block_start += size;
                scope_size += size;
                const off = scope_size;
                try file.print("\tmov [rbp - {}], {}\n", .{ off, reg });
                results[i] = ResultLocation{ .stack_base = off };
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
                    log.debug("saving {} to {}", .{ reg, dest_reg });

                    try ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, file);
                    results[inst] = ResultLocation{ .reg = dest_reg };

                    reg_manager.markUnused(reg);
                    reg_manager.markUsed(dest_reg, inst);
                }
                try file.print("\tcall {s}\n", .{call.name}); // TODO handle return
                switch (call.t) {
                    .void => {},
                    .int, .string, .bool => {
                        if (reg_manager.isUsed(.rax)) @panic("TODO");
                        reg_manager.markUsed(.rax, i);
                        results[i] = ResultLocation{ .reg = .rax };
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

                if (arg.t == Type.float and self.insts[i + 1] == Inst.call) {
                    try file.print("\tmov rax, {}\n", .{arg.t_pos + 1});
                }
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
                try file.print("\t{s} {}, ", .{ op, reg });
                try rhs_loc.print(file);
                try file.writeByte('\n');

                results[i] = ResultLocation{ .reg = reg };
            },
            .mod, .div => |bin_op| {
                const exclude = [_]Register{ Register.DivendReg, Register.DivQuotient, Register.DivRemainder };
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{Register.DivendReg}, RegisterManager.GpMask) orelse @panic("TODO");
                try lhs_loc.moveToReg(Register.DivendReg, file);
                try file.print("\tmov edx, 0\n", .{});
                try rhs_loc.moveToReg(rhs_reg, file);
                try file.print("\tidiv {}\n", .{rhs_reg});

                const result_reg = switch (self.insts[i]) {
                    .div => Register.DivQuotient,
                    .mod => Register.DivRemainder,
                    else => unreachable,
                };
                results[i] = ResultLocation{ .reg = result_reg };
                reg_manager.markUsed(result_reg, i);
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
                try file.print("\t{s} {}, {}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .eq => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                try lhs_loc.moveToReg(reg, file);
                try file.print("\tcmp {}, ", .{reg});
                try rhs_loc.print(file);
                try file.writeByte('\n');
                try file.print("\tsete {}\n", .{reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .i2f => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                try loc.moveToReg(temp_int_reg, file);
                try file.print("\tcvtsi2sd {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                try loc.moveToReg(temp_float_reg, file);
                try file.print("\tcvtsd2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => {
                defer local_lable_ct += 1;
                _ = consumeResult(results, i - 1, &reg_manager);
                results[i] = ResultLocation{ .local_lable = local_lable_ct };
                try file.print("\tjne .L{}\n", .{local_lable_ct});
            },
            .if_end => |start| {
                const label = results[start].local_lable;
                try file.print(".L{}:\n", .{label});
            },
            .block_start => |_| {
                curr_block = i;
            },
            .block_end => |start| {
                scope_size -= self.insts[start].block_start;
            },
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
        try file.print("\tf{} dq\t0x{x}\n", .{ entry.value_ptr.*, entry.key_ptr.* });
    }
}
pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            .if_start => |*scope| scope.deinit(),
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
    var zir_gen = CirGen{
        .ast = &ast,
        .insts = std.ArrayList(Inst).init(alloc),
        .scopes = ScopeStack.init(alloc),
        .gpa = alloc,
        .arena = arena.allocator(),
        .fn_ctx = null,
    };
    defer zir_gen.scopes.stack.deinit();
    errdefer zir_gen.insts.deinit();
    for (ast.defs) |def| {
        try generateProc(def, &zir_gen);
    }
    // errdefer zir_gen.insts.deinit();

    return Cir{ .insts = zir_gen.insts.toOwnedSlice() catch unreachable };
}
pub fn generateProc(def: Ast.ProcDef, zir_gen: *CirGen) CompileError!void {
    zir_gen.scopes.push();
    zir_gen.append(Inst{ .function = Inst.Fn{ .name = def.data.name, .scope = undefined, .frame_size = 0 } });
    const fn_idx = zir_gen.getLast();
    zir_gen.fn_ctx = fn_idx;
    zir_gen.append(Inst{ .block_start = 0 });
    var int_pos: u8 = 0;
    var float_pos: u8 = 0;
    // TODO struct pos
    for (def.data.args, 0..) |arg, pos| {
        const t_pos = switch (arg.type) {
            .float => blk: {
                float_pos += 1;
                break :blk float_pos - 1;
            },
            .int, .string, .bool => blk: {
                int_pos += 1;
                break :blk int_pos - 1;
            },
            .void => return CompileError.TypeMismatched,
        };
        zir_gen.append(Inst{ .arg_decl = .{ .t = arg.type, .pos = @intCast(pos), .t_pos = t_pos } });
        _ = zir_gen.scopes.putTop(arg.name, ScopeItem{ .i = zir_gen.getLast(), .t = arg.type }); // TODO handle parameter with same name
    }
    for (def.data.body) |stat_id| {
        try generateStat(zir_gen.ast.stats[stat_id.idx], zir_gen);
        const stat_inst: *Inst = &zir_gen.insts.items[zir_gen.getLast()];
        switch (stat_inst.*) {
            .ret => |ret| {
                if (ret.t != def.data.ret) {
                    log.err("{} function expects `{}`, got `{}` in ret statement", .{ zir_gen.ast.stats[stat_id.idx].tk.loc, def.data.ret, ret.t });
                    return CompileError.TypeMismatched;
                }
            },
            else => {},
        }
    }
    zir_gen.insts.items[fn_idx].function.scope = zir_gen.scopes.pop();

    const last_inst = zir_gen.getLast();
    if (zir_gen.insts.items[last_inst] != Inst.ret) {
        if (def.data.ret == Type.void) {
            zir_gen.append(Inst{ .ret = .{ .f = fn_idx, .t = def.data.ret } });
        } else {
            log.err("{} function implicitly returns", .{def.tk});
            return CompileError.TypeMismatched;
        }
    }
    zir_gen.append(Inst{ .block_end = fn_idx + 1 });
}
pub fn generateStat(stat: Stat, zir_gen: *CirGen) CompileError!void {
    switch (stat.data) {
        .anon => |expr| _ = try generateExpr(zir_gen.ast.exprs[expr.idx], zir_gen),
        .var_decl => |var_decl| {
            // var_decl.
            const expr_type = try generateExpr(zir_gen.ast.exprs[var_decl.expr.idx], zir_gen);
            if (!zir_gen.scopes.putTop(var_decl.name, .{ .t = expr_type, .i = zir_gen.getLast() + 1 })) {
                log.err("{} Identifier redefined: `{s}`", .{ stat.tk.loc, var_decl.name });
                // TODO provide location of previously defined variable
                return CompileError.Redefined;
            }
            zir_gen.append(.{ .var_decl = expr_type });
        },
        .ret => |expr| {
            const expr_type = try generateExpr(zir_gen.ast.exprs[expr.idx], zir_gen);
            zir_gen.append(.{ .ret = .{ .f = zir_gen.fn_ctx.?, .t = expr_type } });
        },
        .@"if" => |if_stat| {
            const expr_t = try generateExpr(zir_gen.ast.exprs[if_stat.cond.idx], zir_gen);
            zir_gen.scopes.push();
            zir_gen.append(Inst{ .if_start = undefined });
            const if_start = zir_gen.getLast();
            zir_gen.append(Inst{ .block_start = 0 });
            if (expr_t != Type.bool) {
                log.err("{} Expect `bool` in condition expression, found `{}`", .{ stat.tk.loc, expr_t });
                return CompileError.TypeMismatched;
            }
            for (if_stat.body) |body_stat| {
                try generateStat(zir_gen.ast.stats[body_stat.idx], zir_gen);
            }
            zir_gen.append(Inst{ .if_end = if_start });
            zir_gen.insts.items[if_start].if_start = zir_gen.scopes.pop();
            zir_gen.append(Inst{ .block_end = if_start + 1 });
        },
    }
}
pub fn castable(src: Type, dest: Type) bool {
    switch (src) {
        .float => return dest == Type.int,
        .int => return dest != Type.void,
        .string => return dest == Type.int,
        .bool => return dest == Type.int,
        .void => unreachable,
    }
}
pub fn typeCheckOp(op: Ast.Op, lhs_t: Type, rhs_t: Type, loc: @import("lexer.zig").Loc) bool {
    if (op == Ast.Op.as) unreachable;
    if (lhs_t != Type.int and lhs_t != Type.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, lhs_t });
        return false;
    }
    if (rhs_t != Type.int and rhs_t != Type.float) {
        log.err("{} Invalid type of operand for `{}`, expect `int` or `float`, got {}", .{ loc, op, rhs_t });
        return false;
    }

    if (lhs_t != rhs_t) {
        log.err("{} Invalid type of operand for `{}, lhs has `{}`, but rhs has `{}`", .{ loc, op, lhs_t, rhs_t });
        return false;
    }
    return true;
}
pub fn generateAs(lhs: Expr, rhs: Expr, zir_gen: *CirGen) CompileError!Type {
    const lhs_t = try generateExpr(lhs, zir_gen);

    const rhs_t =
        if (rhs.data == Ast.ExprData.atomic and rhs.data.atomic.data == Ast.AtomicData.iden)
        Type.fromString(rhs.data.atomic.data.iden) orelse {
            log.err("{} Expect type identifier in rhs of `as`", .{rhs.tk.loc});
            return CompileError.TypeMismatched;
        }
    else {
        log.err("{} Expect type identifier in rhs of `as`", .{rhs.tk.loc});
        return CompileError.TypeMismatched;
    };
    if (!castable(lhs_t, rhs_t)) {
        log.err("{} `{}` can not be casted into `{}`", .{ rhs.tk, lhs_t, rhs_t });
        return CompileError.TypeMismatched;
    }
    switch (lhs_t) {
        .float => {
            // can only be casted to int
            if (rhs_t != Type.int) unreachable;
            zir_gen.append(Inst.f2i);
        },
        .int, .bool => {
            switch (rhs_t) {
                .string => {},
                .float => zir_gen.append(Inst.i2f),
                else => unreachable,
            }
        },
        .string => {
            if (rhs_t != Type.int) unreachable;
        },
        .void => unreachable,
    }
    return rhs_t;
}
pub fn generateRel(lhs: Expr, rhs: Expr, zir_gen: *CirGen) CompileError!Type {
    const lhs_t = try generateExpr(lhs, zir_gen);
    const lhs_idx = zir_gen.getLast();
    const rhs_t = try generateExpr(rhs, zir_gen);
    const rhs_idx = zir_gen.getLast();
    if (lhs_t != rhs_t or lhs_t != Type.int) return CompileError.TypeMismatched;

    zir_gen.append(Inst{ .eq = .{ .lhs = lhs_idx, .rhs = rhs_idx } });
    return Type.bool;
}
pub fn generateExpr(expr: Expr, zir_gen: *CirGen) CompileError!Type {
    switch (expr.data) {
        .atomic => |atomic| return try generateAtomic(atomic, zir_gen),
        .bin_op => |bin_op| {
            if (bin_op.op == Ast.Op.as) return generateAs(zir_gen.ast.exprs[bin_op.lhs.idx], zir_gen.ast.exprs[bin_op.rhs.idx], zir_gen);
            if (bin_op.op == Ast.Op.eq) return generateRel(zir_gen.ast.exprs[bin_op.lhs.idx], zir_gen.ast.exprs[bin_op.rhs.idx], zir_gen);
            const lhs = zir_gen.ast.exprs[bin_op.lhs.idx];
            const lhs_t = try generateExpr(lhs, zir_gen);

            const lhs_idx = zir_gen.getLast();

            const rhs = zir_gen.ast.exprs[bin_op.rhs.idx];
            const rhs_t = try generateExpr(rhs, zir_gen);

            if (!typeCheckOp(bin_op.op, lhs_t, rhs_t, expr.tk.loc)) return CompileError.TypeMismatched;

            const rhs_idx = zir_gen.getLast();
            const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
            const inst =
                if (lhs_t == Type.int) switch (bin_op.op) {
                .plus => Inst{ .add = bin },
                .minus => Inst{ .sub = bin },
                .times => Inst{ .mul = bin },
                .div => Inst{ .div = bin },
                .mod => Inst{ .mod = bin },
                .eq, .as => unreachable,
            } else switch (bin_op.op) {
                .plus => Inst{ .addf = bin },
                .minus => Inst{ .subf = bin },
                .times => Inst{ .mulf = bin },
                .div => Inst{ .divf = bin },
                .mod => @panic("TODO: Float mod not yet supported"),
                .eq, .as => unreachable,
            };
            zir_gen.append(inst);
            return lhs_t;
        },
    }
}
pub fn generateAtomic(atomic: Ast.Atomic, zir_gen: *CirGen) CompileError!Type {
    switch (atomic.data) {
        .float => |f| {
            zir_gen.append(Inst{ .lit = .{ .float = f } });
            return Type.float;
        },
        .int => |i| {
            zir_gen.append(Inst{ .lit = .{ .int = i } });
            return Type.int;
        },
        .string => |s| {
            zir_gen.append(Inst{ .lit = .{ .string = s } });
            return Type.string;
        },
        .paren => |e| {
            return try generateExpr(zir_gen.ast.exprs[e.idx], zir_gen);
        },
        .iden => |i| {
            const t = zir_gen.scopes.get(i) orelse {
                log.err("{} Undefined identifier: {s}", .{ atomic.tk.loc, i });
                return CompileError.Undefined;
            };
            zir_gen.append(Inst{ .var_access = t.i });
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
                    .bool, .int => "%i\n",
                    .string => "%s\n",
                    .float => "%f\n",
                };
                zir_gen.append(Inst{ .lit = .{ .string = format } });
                zir_gen.append(Inst{ .arg = .{ .expr_inst = zir_gen.getLast(), .pos = 0, .t_pos = 0, .t = .string } });
                zir_gen.append(Inst{ .arg = .{ .expr_inst = expr_idx, .pos = 1, .t_pos = if (t == Type.float) 0 else 1, .t = t } });
                zir_gen.append(Inst{ .call = .{ .name = "align_printf", .t = .void } });
                return Type.void;
            }
            const fn_def = for (zir_gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else {
                log.err("{} Undefined function `{s}`", .{ atomic.tk, fn_app.func });
                return CompileError.Undefined;
            };
            if (fn_def.data.args.len != fn_app.args.len) {
                log.err("{} `{s}` expected {} arguments, got {}", .{ atomic.tk.loc, fn_app.func, fn_def.data.args.len, fn_app.args.len });
                log.note("{} function argument defined here", .{fn_def.tk.loc});
                return CompileError.TypeMismatched;
            }
            // var fn_eval_scope = std.StringHashMap(Ast.VarBind).init(zir_gen.scope.allocator); // TODO account for global variable
            // defer fn_eval_scope.deinit();

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
                    log.err("{} {} argument of `{s}` expected type `{}`, got type `{s}`", .{ e.tk.loc, i, fn_app.func, fd.type, @tagName(e_type) });
                    log.note("{} function argument defined here", .{fd.tk.loc});
                    return CompileError.TypeMismatched;
                }
                // const entry = fn_eval_scope.fetchPut(fd.name, Ast.VarBind{ .name = fd.name, .tk = fd.tk, .type = e_type }) catch unreachable; // TODO account for global variable
                // if (entry) |_| {
                //     log.err("{} {} argument of `{s}` shadows outer variable `{s}`", .{ atomic.tk, i, fn_app.func, fd.name });
                //     // TODO provide location of previously defined variable
                //     return CompileError.Redefined;
                // }
            }
            for (fn_def.data.args, expr_insts.items, 0..) |fd, expr_inst, i| {
                const t_pos = switch (fd.type) {
                    .float => blk: {
                        float_pos += 1;
                        break :blk float_pos - 1;
                    },
                    .int, .string, .bool => blk: {
                        int_pos += 1;
                        break :blk int_pos - 1;
                    },
                    .void => return CompileError.TypeMismatched,
                };

                zir_gen.append(Inst{ .arg = Inst.ArgExpr{ .t = fd.type, .pos = @intCast(i), .t_pos = t_pos, .expr_inst = expr_inst } });
            }
            zir_gen.append(.{ .call = .{ .name = fn_def.data.name, .t = fn_def.data.ret } });

            // for (fn_def.data.body) |di| {
            //     const stat = zir_gen.ast.stats[di.idx];
            //     try generateStat(stat, zir_gen);
            // }

            return fn_def.data.ret;
        },
    }
}

const builtinData =
    \\section        .data  
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
