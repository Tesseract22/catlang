const std = @import("std");
const Ast = @import("ast.zig");
const Expr = Ast.Expr;
const Type = Ast.Type;
const TypeExpr = Ast.TypeExpr;
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
    pub fn adapatSize(self: Register, size: usize) []const u8 {
        return switch (size) {
            1 => @tagName(self.lower8()),
            8 => @tagName(self),
            else => unreachable,
        };
    }
    pub fn calleeSavePos(self: Register) u8 {
        return switch (self) {
            .rbx => 0,
            .r12 => 1,
            .r13 => 2,
            .r14 => 3,
            .r15 => 4,
            else => unreachable,
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
    dirty: Regs,
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
        var dirty = CalleeSaveMask;
        dirty.toggleAll();
        return RegisterManager{ .unused = Regs.initFull(), .insts = undefined, .dirty = dirty };
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
    pub fn markCleanAll(self: *RegisterManager) void {
        var dirty = CalleeSaveMask;
        dirty.toggleAll();
        self.dirty = dirty;
    }
    pub fn getInst(self: *RegisterManager, reg: Register) usize {
        return self.insts[@intFromEnum(reg)];
    }
    pub fn getUnused(self: *RegisterManager, inst: ?usize, cherry: Regs, file: std.fs.File.Writer) ?Register {
        return self.getUnusedExclude(inst, &.{}, cherry, file);
    }
    pub fn getUnusedExclude(self: *RegisterManager, inst: ?usize, exclude: []const Register, cherry: Regs, file: std.fs.File.Writer) ?Register {
        var exclude_mask = Regs.initFull();
        for (exclude) |reg| {
            exclude_mask.unset(@intFromEnum(reg));
        }
        const res_mask = self.unused.intersectWith(exclude_mask).intersectWith(cherry);
        const reg: Register = @enumFromInt(res_mask.findFirstSet() orelse return null);
        self.markUsed(reg, inst);
        if (!self.isDirty(reg)) {
            self.markDirty(reg);
            file.print("\tmov [rbp - {}], {}\n", .{ (reg.calleeSavePos() + 1) * 8, reg }) catch unreachable;
        }
        return reg;
    }
    pub fn isDirty(self: RegisterManager, reg: Register) bool {
        return self.dirty.isSet(@intFromEnum(reg));
    }
    pub fn markDirty(self: *RegisterManager, reg: Register) void {
        self.dirty.set(@intFromEnum(reg));
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
            .int, .bool, .ptr, .char => switch (t_pos) {
                0 => .rdi,
                1 => .rsi,
                2 => .rdx,
                3 => .rcx,
                4 => .r8,
                5 => .r9,
                else => @panic("Too much int argument"),
            },
            .array => @panic("TODO"),
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
    add_reg: Register,
    stack_top: usize,
    stack_base: usize,
    int_lit: isize,
    string_data: usize,
    float_data: usize,
    local_lable: usize,
    array: []usize,

    pub fn moveToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer, size: usize) !void {
        var mov: []const u8 = "mov";
        switch (self) {
            .reg => |self_reg| {
                if (self_reg == reg) return;
                if (self_reg.isFloat()) mov = "movsd";
                if (size != 8) mov = "movzx";
            },
            // .string_data => |_| mov = "lea",
            .stack_base => |_| {if (size != 8) mov = "movzx";},
            .array => @panic("TODO"),
            else => {},
        }
        // TODO
        if (reg.isFloat()) mov = "movsd";
        try writer.print("\t{s} {}, ", .{ mov, reg });
        try self.print(writer, size);
        try writer.writeByte('\n');
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, off: usize, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager, results: []ResultLocation) !void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) "movsd" else "mov";
        const temp_loc = switch (self) {
            inline .stack_base, .float_data, .add_reg => |_| blk: {
                const temp_reg = reg_man.getUnused(null, RegisterManager.GpMask, writer) orelse @panic("TODO");
                try self.moveToReg(temp_reg, writer, size);
                break :blk ResultLocation{ .reg = temp_reg };
            },
            .array => |array| {
                const sub_size = @divExact(size, array.len);
                for (array, 0..array.len) |el_inst, i| {
                    const loc = consumeResult(results, el_inst, reg_man);
                    log.debug("off: {} {}", .{off, off - sub_size * i});
                    try loc.moveToStackBase(off - sub_size * i, sub_size, writer, reg_man, results);
                }
                return;
            },
            else => self,
        };
        const word_size = switch (size) {
            1 => "BYTE",
            8 => "QWORD",
            else => unreachable,
        };
        try writer.print("\t{s} {s} PTR [rbp - {}], ", .{ mov, word_size, off });
        try temp_loc.print(writer, size);
        try writer.writeByte('\n');
    }
    pub fn moveToAddrReg(self: ResultLocation, reg: Register, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager) !void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) "movsd" else "mov";
        const temp_loc = switch (self) {
            .stack_base, .float_data => |_| blk: {
                const temp_reg = reg_man.getUnused(null, RegisterManager.GpMask, writer) orelse @panic("TODO");
                try self.moveToReg(temp_reg, writer, size);
                break :blk ResultLocation{ .reg = temp_reg };
            },
            else => self,
        };
        const word_size = switch (size) {
            1 => "BYTE",
            8 => "QWORD",
            else => unreachable,
        };
        try writer.print("\t{s} {s} PTR [{}], ", .{ mov, word_size, reg });
        try temp_loc.print(writer, size);
        try writer.writeByte('\n');
    }

    pub fn print(self: ResultLocation, writer: std.fs.File.Writer, size: usize) !void {
        const word_size = switch (size) {
            1 => "BYTE",
            8 => "QWORD",
            else => unreachable,
        };
        switch (self) {
            .reg => |reg| try writer.print("{s}", .{reg.adapatSize(size)}),
            .add_reg => |reg| try writer.print("[{}]", .{reg}),
            .stack_base => |off| try writer.print("{s} PTR [rbp - {}]", .{word_size, off}),
            .int_lit => |i| try writer.print("{}", .{i}),
            .string_data => |s| try writer.print("OFFSET FLAT:.s{}", .{s}),
            .float_data => |f| try writer.print(".f{}[rip]", .{f}),
            inline .local_lable, .stack_top, .array => |_| @panic("TODO"),
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
    lit: Ast.Lit,
    var_access: usize, // the instruction where it is defined
    var_decl: TypeExpr,
    var_assign: Assign,
    type_size: TypeExpr,

    addr_of,
    deref,

    array: []usize,

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
    eq: BinOp,
    lt: BinOp,
    gt: BinOp,
    i2f,
    f2i,

    pub const Array = struct {
        el: []usize,
        sub_t: TypeExpr,
    };
    pub const Assign = struct {
        lhs: usize,
        rhs: usize,
        t: TypeExpr,
    };

    pub const IfStart = struct {
        expr: usize,
        first_if: usize,
    };

    pub const Call = struct {
        name: []const u8,
        t: TypeExpr,
    };
    pub const Ret = struct {
        f: usize,
        t: TypeExpr,
    };
    pub const BinOp = struct {
        lhs: usize,
        rhs: usize,
    };
    pub const ArgExpr = struct {
        t: TypeExpr,
        pos: u8,
        t_pos: u8,
        expr_inst: usize,
    };
    pub const ArgDecl = struct {
        t: TypeExpr,
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
            .lt => |bin_op| try writer.print("{} < {}", .{ bin_op.lhs, bin_op.rhs }),
            .gt => |bin_op| try writer.print("{} > {}", .{ bin_op.lhs, bin_op.rhs }),
            .call => |s| try writer.print("{s}: {}", .{ s.name, s.t }),
            .if_start => |if_start| try writer.print("first_if: {}, expr: {}", .{ if_start.first_if, if_start.expr }),
            .else_start => |start| try writer.print("{}", .{start}),
            .if_end => |start| try writer.print("{}", .{start}),
            .block_start => try writer.print("{{", .{}),
            .block_end => |start| try writer.print("}} {}", .{start}),
            .array => |array| for (array) |el| {try writer.print("{}", .{el});},

            inline .i2f, .f2i, .var_decl, .ret, .arg_decl, .var_access, .arg, .lit, .var_assign, .while_start, .while_jmp, .addr_of, .deref, .type_size => |x| try writer.print("{}", .{x}),
        }
    }
};
const ScopeItem = struct {
    t: TypeExpr,
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
    fn_ctx: ?usize,
    // rel: R

    // pub const Rel = enum {
    //     lt,
    //     gt,
    //     eq,
    // };
    pub fn getLast(self: CirGen) usize {
        return self.insts.items.len - 1;
    }
    pub fn append(self: *CirGen, inst: Inst) void {
        self.insts.append(inst) catch unreachable;
    }
};
const Cir = @This();
insts: []Inst,

pub fn typeSize(t: TypeExpr) usize {
    return switch (t.first()) {
        .float => 8,
        .int => 8,
        .bool => 1,
        .char => 1,
        .ptr => 8,
        .void => 0,
        .array => |len| len * typeSize(TypeExpr.deref(t)),
    };
}
pub fn alignOf(t: TypeExpr) usize {
    if (t.first() == .array) {
        return typeSize(t.deref());
    }
    return typeSize(t);
}
pub fn alignAlloc(curr_size: usize, t: TypeExpr) usize {
    const new_size = typeSize(t);
    const alignment = alignOf(t);
    return (curr_size + new_size + (alignment - 1)) / alignment * alignment;
}
pub fn consumeResult(results: []ResultLocation, idx: usize, reg_mangager: *RegisterManager) ResultLocation {
    const loc = results[idx];
    switch (loc) {
        .reg, .add_reg, => |reg| reg_mangager.markUnused(reg),
        .stack_top => |top_off| {
            _ = top_off; // autofix
            @panic("TODO");
        },
        inline .float_data, .string_data, .int_lit, .stack_base, .local_lable, .array => |_| {},
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
            .var_decl => |t| size = alignAlloc(size, t),
            .arg_decl => |arg_decl| size = alignAlloc(size, arg_decl.t),
            else => {},
        }
    }
    unreachable;
}
pub fn compile(self: Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator) !void {
    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;

    defer alloc.free(results);
    var reg_manager = RegisterManager.init();
    try file.print(builtinText ++ builtinStart, .{});
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
                f.frame_size = self.getFrameSize(i + 1, &curr_idx) + RegisterManager.CalleeSaveRegs.len * 8;
                log.debug("frame size: {}", .{f.frame_size});
                f.frame_size = (f.frame_size + 15) / 16 * 16; // align stack to 16 byte
                try file.print("\tsub rsp, {}\n", .{f.frame_size});
                // save callee-saved register
                // TODO finding which reg need to be saved would need additional passes
                // var it = RegisterManager.CalleeSaveMask.iterator(.{});
                // var off: usize = 0;
                // while (it.next()) |regi| {
                //     const reg: Register = @enumFromInt(regi);
                //     off += 8;
                //     try file.print("\tmov [rbp - {}], {}\n", .{off, reg});
                // }
                scope_size = RegisterManager.CalleeSaveRegs.len * 8;
                reg_manager.markCleanAll();
                reg_manager.markUnusedAll();


            },
            .ret => |ret| {


                switch (ret.t.first()) {
                    .void => {},
                    inline .int, .bool, .ptr, .char => {
                        const loc = consumeResult(results, i - 1, &reg_manager);
                        if (reg_manager.isUsed(.rax)) @panic("unreachable");
                        try loc.moveToReg(.rax, file, typeSize(ret.t));
                    },
                    .array => @panic("TODO"),
                    .float => @panic("TODO"),
                }
                var it = reg_manager.dirty.intersectWith(RegisterManager.CalleeSaveMask).iterator(.{});
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);
                    try file.print("\tmov {}, [rbp - {}]\n", .{ reg, (reg.calleeSavePos() + 1) * 8 });
                }
                // try file.print("\tadd rsp, {}\n", .{frame_size});
                // try file.print("\tpop rbp\n", .{});
                try file.print("\tleave\n", .{});
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
                self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, var_decl);
                scope_size = alignAlloc(scope_size, var_decl);
                // TODO explicit operand position
                const size = typeSize(var_decl);

                var loc = consumeResult(results, i - 1, &reg_manager);
                try loc.moveToStackBase(scope_size, size, file, &reg_manager, results);
                results[i] = ResultLocation{ .stack_base = scope_size };

                // try file.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const loc = results[var_access];
                results[i] = loc;
            },
            .var_assign => |var_assign| {
                const var_loc = consumeResult(results, var_assign.lhs, &reg_manager);
                var expr_loc = consumeResult(results, var_assign.rhs, &reg_manager);

                switch (var_loc) {
                    .stack_base => |off| try expr_loc.moveToStackBase(off, typeSize(var_assign.t), file, &reg_manager, results),
                    .add_reg => |reg| try expr_loc.moveToAddrReg(reg, typeSize(var_assign.t), file, &reg_manager),
                    else => unreachable,
                }
                
            },
            .arg_decl => |arg_decl| {
                // TODO handle differnt type
                // TODO handle different number of argument

                const reg = reg_manager.getArgLoc(arg_decl.t_pos, arg_decl.t.first());
                self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, arg_decl.t);
                scope_size = alignAlloc(scope_size, arg_decl.t);
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

                    try ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, file, 8);
                    results[inst] = ResultLocation{ .reg = dest_reg };

                    reg_manager.markUnused(reg);
                    reg_manager.markUsed(dest_reg, inst);
                }
                try file.print("\tcall {s}\n", .{call.name}); // TODO handle return
                switch (call.t.first()) {
                    .void => {},
                    inline .int, .bool, .ptr, .char, => {
                        if (reg_manager.isUsed(.rax)) @panic("TODO");
                        reg_manager.markUsed(.rax, i);
                        results[i] = ResultLocation{ .reg = .rax };
                    },
                    .array,
                    .float => @panic("TODO"),
                }
            },
            .arg => |arg| {
                const loc = consumeResult(results, arg.expr_inst, &reg_manager);
                // const
                const arg_reg = reg_manager.getArgLoc(arg.t_pos, arg.t.first());
                if (reg_manager.isUsed(arg_reg)) @panic("TODO");
                try loc.moveToReg(arg_reg, file, typeSize(arg.t));

                if (arg.t.isType(.float) and self.insts[i + 1] == Inst.call) {
                    try file.print("\tmov rax, {}\n", .{arg.t_pos + 1});
                }
            },
            .add,
            .sub,
            .mul,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                try lhs_loc.moveToReg(reg, file, 8);

                const op = switch (self.insts[i]) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "imul",
                    else => unreachable,
                };
                try file.print("\t{s} {}, ", .{ op, reg });
                try rhs_loc.print(file, 8);
                try file.writeByte('\n');

                results[i] = ResultLocation{ .reg = reg };
            },
            .mod, .div => |bin_op| {
                const exclude = [_]Register{ Register.DivendReg, Register.DivQuotient, Register.DivRemainder };
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    try results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{Register.DivendReg}, RegisterManager.GpMask, file) orelse @panic("TODO");
                try lhs_loc.moveToReg(Register.DivendReg, file, 8);
                try file.print("\tmov edx, 0\n", .{});
                try rhs_loc.moveToReg(rhs_reg, file, 8);
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
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask, file) orelse @panic("TODO");

                try lhs_loc.moveToReg(result_reg, file, 8);
                try rhs_loc.moveToReg(temp_reg, file, 8);
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
            .eq, .lt, .gt => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                try lhs_loc.moveToReg(reg, file, typeSize(TypeExpr {.singular = .bool}));
                try file.print("\tcmp {}, ", .{reg});
                try rhs_loc.print(file, typeSize(TypeExpr {.singular = .bool}));
                try file.writeByte('\n');
                try file.print("\tsete {}\n", .{reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .i2f => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                try loc.moveToReg(temp_int_reg, file, typeSize(TypeExpr {.singular = .float}));
                try file.print("\tcvtsi2sd {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                try loc.moveToReg(temp_float_reg, file, typeSize(TypeExpr {.singular = .int}));
                try file.print("\tcvtsd2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer local_lable_ct += 1;
                const loc = consumeResult(results, if_start.expr, &reg_manager);
                results[i] = ResultLocation{ .local_lable = local_lable_ct };

                const jump = switch (self.insts[if_start.expr]) {
                    .eq => "jne",
                    .lt => "jae",
                    .gt => "jbe",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask, file) orelse @panic("TODO");
                        try loc.moveToReg(temp_reg, file, typeSize(TypeExpr {.singular = .bool}));
                        try file.print("\tcmp {}, 0\n", .{temp_reg});
                        break :blk "je";
                    },
                };
                try file.print("\t{s} .L{}\n", .{ jump, local_lable_ct });
            },
            .else_start => |if_start| {
                try file.print("\tjmp .LE{}\n", .{results[self.insts[if_start].if_start.first_if].local_lable});
                try file.print(".L{}:\n", .{results[if_start].local_lable});
            },
            .if_end => |start| {
                const label = results[start].local_lable;
                try file.print(".LE{}:\n", .{label});
            },
            .while_start => {
                defer local_lable_ct += 1;
                results[i] = ResultLocation{ .local_lable = local_lable_ct };

                try file.print(".W{}:\n", .{local_lable_ct});
            },
            .while_jmp => |while_start| {
                const label = results[while_start].local_lable;
                try file.print("\tjmp .W{}\n", .{label});
            },
            .block_start => |_| {
                curr_block = i;
            },
            .block_end => |start| {
                scope_size -= self.insts[start].block_start;
            },
            .addr_of => {
                const stack_off = results[i - 1].stack_base;
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                try file.print("\tlea {}, [rbp - {}]\n", .{reg, stack_off});
                results[i] = ResultLocation {.reg = reg};
            },
            .deref => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                try loc.moveToReg(reg, file, typeSize(TypeExpr { .singular = .ptr}));
                results[i] = ResultLocation {.add_reg = reg};
            },
            .array => |array| {
                results[i] = ResultLocation {.array = array};
            },
            .type_size => |t| {
                results[i] = ResultLocation {.int_lit = @intCast(typeSize(t))};
            }
        }
    }
    try file.print(builtinData, .{});
    var string_data_it = string_data.iterator();
    while (string_data_it.next()) |entry| {
        try file.print(".s{}:\n\t.byte\t", .{entry.value_ptr.*});
        for (entry.key_ptr.*) |c| {
            try file.print("{}, ", .{c});
        }
        try file.print("0\n", .{});
    }
    try file.print(".align 8\n", .{});
    var float_data_it = float_data.iterator();
    while (float_data_it.next()) |entry| {
        try file.print("\t.f{}:\n\t.double\t{}\n", .{ entry.value_ptr.*, @as(f64, @bitCast(entry.key_ptr.*)) });
    }
}
pub fn deinit(self: Cir, alloc: std.mem.Allocator) void {
    for (self.insts) |*inst| {
        switch (inst.*) {
            // .if_start => |*scope| scope.deinit(),
            .function => |*f| {
                f.scope.deinit();
            },
            .array => |array| alloc.free(array),
            else => {},
        }
    }
    alloc.free(self.insts);
}
pub fn generate(ast: Ast, alloc: std.mem.Allocator, arena: std.mem.Allocator) Cir {
    var cir_gen = CirGen{
        .ast = &ast,
        .insts = std.ArrayList(Inst).init(alloc),
        .scopes = ScopeStack.init(alloc),
        .gpa = alloc,
        .arena = arena,
        .fn_ctx = null,
    };
    defer cir_gen.scopes.stack.deinit();
    errdefer cir_gen.insts.deinit();
    for (ast.defs) |def| {
        generateProc(def, &cir_gen);
    }
    // errdefer cir_gen.insts.deinit();

    return Cir{ .insts = cir_gen.insts.toOwnedSlice() catch unreachable };
}
pub fn generateProc(def: Ast.ProcDef, cir_gen: *CirGen) void {
    cir_gen.scopes.push();
    cir_gen.append(Inst{ .function = Inst.Fn{ .name = def.data.name, .scope = undefined, .frame_size = 0 } });
    const fn_idx = cir_gen.getLast();
    cir_gen.fn_ctx = fn_idx;
    cir_gen.append(Inst{ .block_start = 0 });
    var int_pos: u8 = 0;
    var float_pos: u8 = 0;
    // TODO struct pos
    for (def.data.args, 0..) |arg, pos| {
        const t_pos = switch (arg.type.first()) {
            .float => blk: {
                float_pos += 1;
                break :blk float_pos - 1;
            },
            .int, .bool, .ptr, .char => blk: {
                int_pos += 1;
                break :blk int_pos - 1;
            },
            .array => @panic("TODO"),
            .void => unreachable,
        };
        cir_gen.append(Inst{ .arg_decl = .{ .t = arg.type, .pos = @intCast(pos), .t_pos = t_pos } });
        _ = cir_gen.scopes.putTop(arg.name, ScopeItem{ .i = cir_gen.getLast(), .t = arg.type }); // TODO handle parameter with same name
    }
    for (def.data.body) |stat_id| {
        generateStat(cir_gen.ast.stats[stat_id.idx], cir_gen);
    }
    cir_gen.insts.items[fn_idx].function.scope = cir_gen.scopes.pop();

    const last_inst = cir_gen.getLast();
    if (cir_gen.insts.items[last_inst] != Inst.ret and def.data.ret.isType(.void)) {
        cir_gen.append(Inst{ .ret = .{ .f = fn_idx, .t = def.data.ret } });
    }
    cir_gen.append(Inst{ .block_end = fn_idx + 1 });
}
pub fn generateIf(if_stat: Ast.StatData.If, tk: @import("lexer.zig").Token, cir_gen: *CirGen, first_if_or: ?usize) void {
    _ = tk; // autofix
    _ = generateExpr(cir_gen.ast.exprs[if_stat.cond.idx], cir_gen);
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
        .anon => |expr| _ = generateExpr(cir_gen.ast.exprs[expr.idx], cir_gen),
        .var_decl => |var_decl| {
            // var_decl.
            const expr_type = generateExpr(cir_gen.ast.exprs[var_decl.expr.idx], cir_gen);
            _ = cir_gen.scopes.putTop(var_decl.name, .{ .t = expr_type, .i = cir_gen.getLast() + 1 });
            cir_gen.append(.{ .var_decl = expr_type });
        },
        .ret => |expr| {
            const expr_type = generateExpr(cir_gen.ast.exprs[expr.idx], cir_gen);
            cir_gen.append(.{ .ret = .{ .f = cir_gen.fn_ctx.?, .t = expr_type } });
        },
        .@"if" => |if_stat| {
            generateIf(if_stat, stat.tk, cir_gen, null);
        },
        .loop => |loop| {
            cir_gen.scopes.push();
            cir_gen.append(Inst.while_start);
            const while_start = cir_gen.getLast();

            _ = generateExpr(cir_gen.ast.exprs[loop.cond.idx], cir_gen);
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
            const t = generateExpr(cir_gen.ast.exprs[assign.expr.idx], cir_gen);
            const rhs = cir_gen.getLast();
            _ = generateExpr(cir_gen.ast.exprs[assign.left_value.idx], cir_gen);
            const lhs = cir_gen.getLast();
            cir_gen.append(.{ .var_assign = .{ .lhs = lhs, .rhs = rhs, .t = t} });
        },
    }
}

pub fn generateAs(lhs: Expr, rhs: Expr, cir_gen: *CirGen) TypeExpr {
    const lhs_t = generateExpr(lhs, cir_gen);

    const rhs_t: TypeExpr = rhs.data.atomic.data.type;

    switch (lhs_t.first()) { // TODO first
        .float => {
            // can only be casted to int
            if (!rhs_t.isType(.int)) unreachable;
            cir_gen.append(Inst.f2i);
        },
        .int => {
            switch (rhs_t.first()) {
                .ptr => {},
                .float => cir_gen.append(Inst.i2f),
                else => unreachable,
            }
        },
        .char, .bool => {
            if (!rhs_t.isType(.int)) unreachable;
        },
        .ptr => {},
        .void => unreachable,
        .array => unreachable,
    }
    return rhs_t;
}
pub fn generateRel(lhs: Expr, rhs: Expr, op: Op, cir_gen: *CirGen) TypeExpr {
    _ = generateExpr(lhs, cir_gen);
    const lhs_idx = cir_gen.getLast();
    _ = generateExpr(rhs, cir_gen);
    const rhs_idx = cir_gen.getLast();

    const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };

    switch (op) {
        .eq => cir_gen.append(Inst{ .eq = bin }),
        .lt => cir_gen.append(Inst{ .lt = bin }),
        .gt => cir_gen.append(Inst{ .gt = bin }),
        else => unreachable,
    }
    return .{.singular = .bool };
}
pub fn generateExpr(expr: Expr, cir_gen: *CirGen) TypeExpr {
    switch (expr.data) {
        .atomic => |atomic| return generateAtomic(atomic, cir_gen),
        .bin_op => |bin_op| {
            switch (bin_op.op) {
                .as => return generateAs(cir_gen.ast.exprs[bin_op.lhs.idx], cir_gen.ast.exprs[bin_op.rhs.idx], cir_gen),
                .eq, .gt, .lt => return generateRel(cir_gen.ast.exprs[bin_op.lhs.idx], cir_gen.ast.exprs[bin_op.rhs.idx], bin_op.op, cir_gen),
                else => {},
            }
            const lhs = cir_gen.ast.exprs[bin_op.lhs.idx];
            const lhs_t = generateExpr(lhs, cir_gen);

            const lhs_idx = cir_gen.getLast();

            const rhs = cir_gen.ast.exprs[bin_op.rhs.idx];
            _ = generateExpr(rhs, cir_gen);


            const rhs_idx = cir_gen.getLast();
            const bin = Inst.BinOp{ .lhs = lhs_idx, .rhs = rhs_idx };
            const inst =
                if (lhs_t.isType(.int)) switch (bin_op.op) {
                .plus => Inst{ .add = bin },
                .minus => Inst{ .sub = bin },
                .times => Inst{ .mul = bin },
                .div => Inst{ .div = bin },
                .mod => Inst{ .mod = bin },
                else => unreachable,
            } else switch (bin_op.op) {
                .plus => Inst{ .addf = bin },
                .minus => Inst{ .subf = bin },
                .times => Inst{ .mulf = bin },
                .div => Inst{ .divf = bin },
                .mod => @panic("TODO: Float mod not yet supported"),
                else => unreachable,
            };
            cir_gen.append(inst);
            return lhs_t;
        },
        .fn_app => |fn_app| {
            if (std.mem.eql(u8, fn_app.func, "print")) {
                const t = generateExpr(cir_gen.ast.exprs[fn_app.args[0].idx], cir_gen);
                const expr_idx = cir_gen.getLast();
                const format = switch (t.first()) {
                    .void => unreachable,
                    .bool, .int => "%i\n",
                    .char => "%c\n",
                    .float => "%f\n",
                    .ptr => switch (t.plural[1]) {
                        .char => "%s\n",
                        else => "%p\n",
                    },
                    .array => @panic("TODO"),
                };
                cir_gen.append(Inst{ .lit = .{ .string = format } });
                cir_gen.append(Inst{ .arg = .{ .expr_inst = cir_gen.getLast(), .pos = 0, .t_pos = 0, .t = TypeExpr.string(cir_gen.arena) } });
                cir_gen.append(Inst{ .arg = .{ .expr_inst = expr_idx, .pos = 1, .t_pos = if (t.isType(.float)) 0 else 1, .t = t } });
                cir_gen.append(Inst{ .call = .{ .name = "printf", .t = .{.singular = .void} } });
                return .{.singular = .void};
            }
            const fn_def = for (cir_gen.ast.defs) |def| {
                if (std.mem.eql(u8, def.data.name, fn_app.func)) break def;
            } else unreachable;


            var int_pos: u8 = 0;
            var float_pos: u8 = 0;

            var expr_insts = std.ArrayList(usize).init(cir_gen.arena);
            defer expr_insts.deinit();
            for (fn_app.args) |fa| {
                const e = cir_gen.ast.exprs[fa.idx];
                _ = generateExpr(e, cir_gen);
                expr_insts.append(cir_gen.getLast()) catch unreachable;

            }
            for (fn_def.data.args, expr_insts.items, 0..) |fd, expr_inst, i| {
                const t_pos = switch (fd.type.first()) {
                    .float => blk: {
                        float_pos += 1;
                        break :blk float_pos - 1;
                    },
                    .int, .char, .bool, .ptr => blk: {
                        int_pos += 1;
                        break :blk int_pos - 1;
                    },
                    .void => unreachable,
                    .array => @panic("TODO"),
                };

                cir_gen.append(Inst{ .arg = Inst.ArgExpr{ .t = fd.type, .pos = @intCast(i), .t_pos = t_pos, .expr_inst = expr_inst } });
            }
            cir_gen.append(.{ .call = .{ .name = fn_def.data.name, .t = fn_def.data.ret } });


            return fn_def.data.ret;
        },
        .addr_of => |addr_of| {
            const expr_addr = cir_gen.ast.exprs[addr_of.idx];
            const t = generateExpr(expr_addr, cir_gen);
            cir_gen.append(.addr_of);
            return TypeExpr.ptr(cir_gen.arena, t);
        },
        .deref => |deref| {
            const expr_deref = cir_gen.ast.exprs[deref.idx];
            const t = generateExpr(expr_deref, cir_gen);
            cir_gen.append(.deref);
            return TypeExpr.deref(t);
        },
        .array => |array| {
            var list = std.ArrayList(usize).initCapacity(cir_gen.gpa, array.len) catch unreachable;
            var t: TypeExpr = undefined;
            for (array) |e| {
                t = generateExpr(cir_gen.ast.exprs[e.idx], cir_gen);
                list.append(cir_gen.getLast()) catch unreachable;
            }
            cir_gen.append(Inst {.array = list.toOwnedSlice() catch unreachable });
            return TypeExpr.prefixWith(cir_gen.arena, t, .{ .array = array.len });
            
        },
        .array_access => |aa| {
            const lhs_t = generateExpr(cir_gen.ast.exprs[aa.lhs.idx], cir_gen);
            cir_gen.append(Inst.addr_of);
            const lhs_addr = cir_gen.getLast();
            _ = generateExpr(cir_gen.ast.exprs[aa.rhs.idx], cir_gen);
            const rhs_inst = cir_gen.getLast();

            cir_gen.append(Inst {.type_size = TypeExpr.deref(lhs_t)});
            cir_gen.append(Inst {.mul = .{ .lhs = cir_gen.getLast(), .rhs = rhs_inst }});
            cir_gen.append(Inst {.add = .{.lhs = lhs_addr, .rhs = cir_gen.getLast()}});
             
            cir_gen.append(.deref);
            return lhs_t.deref();
        },
        .field => |fa| {
            const lhs_t = generateExpr(cir_gen.ast.exprs[fa.lhs.idx], cir_gen);
            cir_gen.append(Inst {.lit = .{ .int = @intCast(lhs_t.first().array) }});
            return TypeExpr {.singular = .int};
        },
    }
}
pub fn generateAtomic(atomic: Ast.Atomic, cir_gen: *CirGen) TypeExpr {
    switch (atomic.data) {
        .float => |f| {
            cir_gen.append(Inst{ .lit = .{ .float = f } });
            return .{.singular =  Type.float};
        },
        .int => |i| {
            cir_gen.append(Inst{ .lit = .{ .int = i } });
            return .{.singular =  Type.int};
        },
        .string => |s| {
            cir_gen.append(Inst{ .lit = .{ .string = s } });
            return TypeExpr.string(cir_gen.arena);
        },
        .bool => |b| {
            cir_gen.append(Inst{ .lit = .{ .int = @intFromBool(b) } });
            return .{.singular =  Type.bool};
        },
        .paren => |e| {
            return generateExpr(cir_gen.ast.exprs[e.idx], cir_gen);
        },
        .iden => |i| {
            const t = cir_gen.scopes.get(i).?;
            cir_gen.append(Inst{ .var_access = t.i });
            return t.t;
        },

        .addr => @panic("TODO ADDR"),
        .type => unreachable,
    }
}

const builtinData =
    \\aligned:
    \\  .byte 0
    \\
;

const builtinText =
    \\.intel_syntax noprefix
    \\.text
    \\.globl         _start
    \\
;
// const builtinShow =
//     \\align_printf:
//     \\    mov rbx, rsp
//     \\    and rbx, 0x000000000000000f
//     \\    cmp rbx, 0
//     \\    je .align_end
//     \\    .align:
//     \\       push rbx
//     \\        mov BYTE PTR [aligned], 1
//     \\    .align_end:
//     \\    call printf
//     \\    cmp BYTE PTR [aligned], 1
//     \\    jne .unalign_end
//     \\    .unalign:
//     \\        pop rbx
//     \\        mov BYTE PTR [aligned], 0
//     \\    .unalign_end:
//     \\    ret
//     \\
// ;

const builtinStart = "_start:\n\tcall main\n\tmov rdi, 0\n\tcall exit\n";
const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";
