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
const PTR_SIZE = 8;
const TypePool = @import("type.zig");
const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;

const TypeCheck = @import("typecheck.zig");
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
    pub fn adapatSize(self: Register, word: Word) []const u8 {
        return switch (word) {
            .byte => @tagName(self.lower8()),
            .qword => @tagName(self),
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
pub fn saveDirty(reg: Register, file: std.fs.File.Writer) void {
    file.print("\tmov [rbp + {}], {}\n", .{ -@as(isize, @intCast((reg.calleeSavePos() + 1) * 8)), reg }) catch unreachable;
}
pub fn restoreDirty(reg: Register, file: std.fs.File.Writer) void {
    file.print("\tmov {}, [rbp + {}]\n", .{ reg, -@as(isize, @intCast((reg.calleeSavePos() + 1) * 8)) }) catch unreachable;
}
const RegisterManager = struct {
    unused: Regs,
    dirty: Regs,
    insts: [count]usize,
    const count = @typeInfo(Register).@"enum".fields.len;
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
        self.protectDirty(reg, file);
        return reg;
    }
    pub fn protectDirty(self: *RegisterManager, reg: Register, file: std.fs.File.Writer) void {
        if (!self.isDirty(reg)) {
            self.markDirty(reg);
            saveDirty(reg, file);
        }
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
        _ = self;
        if (t_pos > 8) @panic("Too much float argument");
        return @enumFromInt(@intFromEnum(Register.xmm0) + t_pos);
    }
    pub fn getArgLoc(self: *RegisterManager, t_pos: u8, t: Type) Register {
        const t_full = TypePool.lookup(t);
        const reg: Register = switch (t_full) {
            .float => self.getFloatArgLoc(t_pos),
            .int, .bool, .ptr, .char, .array, .tuple, .named => switch (t_pos) {
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
pub const AddrReg = struct {
    reg: Register,
    off: isize,
};
const Word = enum(u8) {
    byte = 1,
    word = 2,
    dword = 4,
    qword = 8,
    pub fn fromSize(size: usize) ?Word {
        return switch (size) {
            1 => .byte,
            2 => .word,
            3...4 => .dword,
            5...8 => .qword,
            else => null,
        };
    }
};
pub const ResInst = union(enum) {
    none,
    ptr: usize,
    loc: usize,
};
pub fn tupleOffset(tuple: []Type, off: usize) usize {
    var size: usize = 0;
    for (tuple, 0..) |sub_t, i| {
        const sub_size = typeSize(sub_t);
        const sub_align = alignOf(sub_t);
        size = (size + sub_align - 1) / sub_align * sub_align;
        if (i == off) break;
        size += sub_size;
    }
    return size;
}
//pub fn structOffset(tuple: [], off: usize) usize {
//    var size: usize = 0;
//    for (tuple, 0..) |vb, i| {
//        const sub_t = vb.type;
//        const sub_size = typeSize(sub_t);
//        const sub_align = alignOf(sub_t);
//        size = (size + sub_align - 1) / sub_align * sub_align;
//        if (i == off) break;
//        size += sub_size;
//    }
//    return size;
//}
const ResultLocation = union(enum) {
    reg: Register,
    addr_reg: AddrReg,
    stack_top: StackTop,
    stack_base: isize,
    int_lit: isize,
    string_data: usize,
    float_data: usize,
    local_lable: usize,
    array: []usize,
    uninit,

    pub const StackTop = struct {
        off: isize,
        size: usize,
    };
    pub fn offsetBy(self: ResultLocation, off: usize, t: Type) ResultLocation {
        const t_full = TypePool.lookup(t);
        const total_off: isize = 
        switch (t_full) {
            .tuple => |tuple| @intCast(tupleOffset(tuple.els, off)),
            .named => |named| @intCast(tupleOffset(named.els, off)),
            .array => |array| blk: {
                const sub_t = array.el;
                break :blk @intCast(typeSize(sub_t) * off);
            },
            else => unreachable,
        };
        return switch (self) {
            .addr_reg => |addr_reg| .{.addr_reg = AddrReg {.off = total_off + addr_reg.off, .reg = addr_reg.reg}},
            .stack_top => |stack_top| .{.stack_top = .{.off = total_off + stack_top.off, .size = stack_top.size}},
            .stack_base => |stack_base| .{.stack_base = stack_base + total_off},
            else => unreachable
        };
    }

    pub fn moveAddrToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer) void {
        writer.print("\tlea {}, ", .{reg}) catch unreachable;
        self.print(writer, .qword) catch unreachable;
        writer.writeByte('\n') catch unreachable;
    }
    pub fn moveToReg(self: ResultLocation, reg: Register, writer: std.fs.File.Writer, size: usize) void {
        if (self == .uninit) return;
        var mov: []const u8 = "mov";
        switch (self) {
            .reg => |self_reg| {
                if (self_reg == reg) return;
                if (self_reg.isFloat()) mov = "movsd";
                if (size != 8) mov = "movzx";
            },
            inline .stack_base, .stack_top, .addr_reg => |_| {if (size != 8) mov = "movzx";},
            .array => @panic("TODO"),
            else => {},
        }
        // TODO
        if (reg.isFloat()) mov = "movsd";
        writer.print("\t{s} {}, ", .{ mov, reg }) catch unreachable;
        self.print(writer, Word.fromSize(size).?) catch unreachable;
        writer.writeByte('\n') catch unreachable;
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, off: isize, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager, results: []ResultLocation) void {
        return self.moveToAddrReg(AddrReg {.reg = .rbp, .off = off}, size, writer, reg_man, results);

    }

    pub fn moveToAddrReg(self: ResultLocation, reg: AddrReg, size: usize, writer: std.fs.File.Writer, reg_man: *RegisterManager, results: []ResultLocation) void {
        if (self == .uninit) return;
        if (Word.fromSize(size)) |word| {
            return self.moveToAddrRegWord(reg, word, writer, reg_man, results);
        }
        var self_clone = self;
        switch (self_clone) {
            .array => |array| {
                const sub_size = @divExact(size, array.len);
                for (array, 0..array.len) |el_inst, i| {
                    const loc = consumeResult(results, el_inst, reg_man, writer);
                    loc.moveToAddrReg(AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(sub_size * i))}, sub_size, writer, reg_man, results);
                }
                return;
            },
            inline 
            .addr_reg,
            .stack_top,
            .stack_base => |_| {
                const off = switch (self_clone) {
                    .addr_reg => |*addr_reg| &addr_reg.off,
                    .stack_top => |*stack_top| &stack_top.off,
                    .stack_base => |*off| off,
                    else => unreachable

                };
                const reg_size = 8;
                var size_left = size;
                while (size_left > reg_size): (size_left -= reg_size) {
                    self_clone.moveToAddrRegWord(AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(size - size_left))}, .qword, writer, reg_man, results);
                    off.* += reg_size;
                }
                self_clone.moveToAddrRegWord(AddrReg {.reg = reg.reg, .off = reg.off + @as(isize, @intCast(size - size_left))}, Word.fromSize(size_left).?, writer, reg_man, results);
            },
            else => unreachable
        }
    }
    pub fn moveToAddrRegWord(self: ResultLocation, reg: AddrReg, word: Word, writer: std.fs.File.Writer, reg_man: *RegisterManager, _: []ResultLocation) void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) "movsd" else "mov";
        const temp_loc = switch (self) {
            inline .stack_base, .float_data, .stack_top, .addr_reg  => |_| blk: {
                const temp_reg = reg_man.getUnused(null, RegisterManager.GpMask, writer) orelse @panic("TODO");
                self.moveToReg(temp_reg, writer, @intFromEnum(word));
                break :blk ResultLocation{ .reg = temp_reg };
            },
            .array => unreachable,
            else => self,
        };
        writer.print("\t{s} {s} PTR [{} + {}], ", .{ mov, @tagName(word), reg.reg, reg.off}) catch unreachable;
        temp_loc.print(writer, word) catch unreachable;
        writer.writeByte('\n') catch unreachable;
    }

    pub fn print(self: ResultLocation, writer: std.fs.File.Writer, word: Word) !void {

        switch (self) {
            .reg => |reg| try writer.print("{s}", .{reg.adapatSize(word)}),
            .addr_reg => |reg| try writer.print("{s} PTR [{} + {}]", .{@tagName(word), reg.reg, reg.off}),
            .stack_base => |off| try writer.print("{s} PTR [rbp + {}]", .{@tagName(word), off}),
            .stack_top => |stack_top| try writer.print("{s} PTR [rsp + {}]", .{@tagName(word), stack_top.off}),
            .int_lit => |i| try writer.print("{}", .{i}),
            .string_data => |s| try writer.print("OFFSET FLAT:.s{}", .{s}),
            .float_data => |f| try writer.print(".f{}[rip]", .{f}),
            inline .local_lable,  .array => |_| @panic("TODO"),
            .uninit => unreachable,
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
    ret_decl: Type,
    arg_decl: Var,
    lit: Ast.Lit,
    var_access: usize, // the instruction where it is defined
    var_decl: Var,
    var_assign: Assign,

    type_size: Type,
    array_len: Type,

    addr_of,
    deref,

    field: Field,
    

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
    eq: BinOp,
    lt: BinOp,
    gt: BinOp,
    i2f,
    f2i,

    pub const Field = struct {
        t: Type,
        off: usize,
    };
    pub const Var = struct {
        t: Type,
        auto_deref: bool,
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
        ret_decl: usize,
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
            .function => |f| try writer.print("{s}", .{lookup(f.name)}),
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
            .call => |s| try writer.print("{s}: {}", .{ lookup(s.name), s.t }),
            .if_start => |if_start| try writer.print("first_if: {}, expr: {}", .{ if_start.first_if, if_start.expr }),
            .else_start => |start| try writer.print("{}", .{start}),
            .if_end => |start| try writer.print("{}", .{start}),
            .block_start => try writer.print("{{", .{}),
            .block_end => |start| try writer.print("}} {}", .{start}),

            inline .i2f, .f2i, .var_decl, .ret, .arg_decl, .var_access, .ret_decl, .lit, .var_assign, .while_start, .while_jmp, .type_size, .array_len,.array_init, .array_init_assign, .array_init_loc , .array_init_end, .field => |x| try writer.print("{}", .{x}),
            .addr_of, .deref, .uninit => {},
        }
    }
};
const ScopeItem = struct {
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
insts: []Inst,

pub fn typeSize(t: Type) usize {
    if (t == TypePool.float) return PTR_SIZE;
    if (t == TypePool.int) return PTR_SIZE;
    if (t == TypePool.bool) return 1;
    if (t == TypePool.char) return 1;
    if (t == TypePool.void) return 0;
    const t_full = TypePool.lookup(t);
    return switch (t_full) {
        .array => |array| array.size * typeSize(array.el),
        .tuple => |tuple| tupleOffset(tuple.els, tuple.els.len),
        .named => |tuple| tupleOffset(tuple.els, tuple.els.len),
        .ptr => PTR_SIZE,
        else => unreachable
    };
}
pub fn alignOf(t: Type) usize {
    const t_full = TypePool.lookup(t);
    switch (t_full) {
        .array => |array| return alignOf(array.el),
        inline .tuple, .named => |tuple| {
            var max: usize = 0;
            for (tuple.els) |el_t| {
                max = @max(max, alignOf(el_t));
            }
            return max;
        },
        else => return typeSize(t),
    }
}
pub fn alignAlloc(curr_size: usize, t: Type) usize {
    const size = typeSize(t);
    const alignment = alignOf(t);
    return alignAlloc2(curr_size, size, alignment);
}
pub fn alignAlloc2(curr_size: usize, size: usize, alignment: usize) usize {
    return (curr_size + size + (alignment - 1)) / alignment * alignment;
}
pub fn consumeResult(results: []ResultLocation, idx: usize, reg_mangager: *RegisterManager, writer: std.fs.File.Writer) ResultLocation {
    var loc = results[idx];
    switch (loc) {
        .reg => |reg| reg_mangager.markUnused(reg),
        .addr_reg, => |addr_reg| reg_mangager.markUnused(addr_reg.reg),
        .stack_top => |top_off| {
            writer.print("\tadd rsp, {}\n", .{top_off.size}) catch unreachable;
            loc.stack_top.off -= @as(isize, @intCast(top_off.size));
        },
        inline .float_data, .string_data, .int_lit, .stack_base, .local_lable, .array, .uninit => |_| {},
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
            .var_decl => |v| size = alignAlloc(size, v.t),
            .arg_decl => |v| size = alignAlloc(size, v.t),
            .ret_decl => |t| {
                const t_full = TypePool.lookup(t);
                switch (t_full) {
                    .array, .tuple => size = alignAlloc2(size, PTR_SIZE, PTR_SIZE),
                    else => {},
                }
            },
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

    // ctx
    // TODO
    // The current way of this doing this forces us to remember to reset this on entering function body
    // A more resoable way will be to make CIR a per-function thing, instead of per-program or per-file
    var scope_size: usize = 0;
    var int_ct: u8 = 0;
    var float_ct: u8 = 0; // why is there a global state?
    var curr_block: usize = 0;
    var local_lable_ct: usize = 0;

    var string_data = std.AutoArrayHashMap(Symbol, usize).init(alloc);
    defer string_data.deinit();
    var float_data = std.AutoArrayHashMap(usize, usize).init(alloc);
    defer float_data.deinit();
    for (self.insts, 0..) |_, i| {
        reg_manager.debug();
        log.debug("[{}] {}", .{ i, self.insts[i] });
        try file.print("# [{}] {}\n", .{i, self.insts[i]});
        switch (self.insts[i]) {
            .function => |*f| {
                try file.print("{s}:\n", .{Lexer.string_pool.lookup(f.name)});
                try file.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
                var curr_idx = i + 2;
                f.frame_size = self.getFrameSize(i + 1, &curr_idx) + RegisterManager.CalleeSaveRegs.len * 8;
                f.frame_size = (f.frame_size + 15) / 16 * 16; // align stack to 16 byte
                try file.print("\tsub rsp, {}\n", .{f.frame_size});
                scope_size = RegisterManager.CalleeSaveRegs.len * 8;
                reg_manager.markCleanAll();
                reg_manager.markUnusedAll();

                int_ct = 0;
                float_ct = 0;



            },
            .ret => |ret| {

                const ret_t_full = TypePool.lookup(ret.t);
                switch (ret_t_full) {
                    .void => {},
                    inline .int, .bool, .ptr, .char => {
                        const loc = consumeResult(results, i - 1, &reg_manager, file);
                        if (reg_manager.isUsed(.rax)) @panic("unreachable");
                        loc.moveToReg(.rax, file, typeSize(ret.t));
                    },
                    .array, .tuple, .named => {
                        const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file).?;
                        defer reg_manager.markUnused(reg);
                        const ret_loc = results[ret.ret_decl];
                        ret_loc.moveToReg(reg, file, PTR_SIZE);

                        const loc = consumeResult(results, i - 1, &reg_manager, file);
                        loc.moveToAddrReg(AddrReg {.reg = reg, .off = 0}, typeSize(ret.t), file, &reg_manager, results);
                    },
                    .float => @panic("TODO"),
                }
                var it = reg_manager.dirty.intersectWith(RegisterManager.CalleeSaveMask).iterator(.{});
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);
                    restoreDirty(reg, file);
                }
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
                self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, var_decl.t);
                scope_size = alignAlloc(scope_size, var_decl.t);
                // TODO explicit operand position
                // const size = typeSize(var_decl);

                // var loc = consumeResult(results, i - 1, &reg_manager, file);
                // try loc.moveToStackBase(scope_size, size, file, &reg_manager, results);
                results[i] = ResultLocation{ .stack_base = -@as(isize, @intCast(scope_size)) };
                // try file.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const v = switch (self.insts[var_access]) {
                    .var_decl => |v| v,
                    .arg_decl => |v| v,
                    else => unreachable,
                };
                const loc = results[var_access];
                if (v.auto_deref) {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                    loc.moveToReg(reg, file, PTR_SIZE);
                    results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
                } else {
                    results[i] = loc;

                }
            },
            .var_assign => |var_assign| {
                const var_loc = consumeResult(results, var_assign.lhs, &reg_manager, file);
                var expr_loc = consumeResult(results, var_assign.rhs, &reg_manager, file);

                switch (var_loc) {
                    .stack_base => |off| expr_loc.moveToStackBase(off, typeSize(var_assign.t), file, &reg_manager, results),
                    .addr_reg => |reg| expr_loc.moveToAddrReg(reg, typeSize(var_assign.t), file, &reg_manager, results),
                    else => unreachable,
                }

            },
            .ret_decl => |t| {
                const t_full = TypePool.lookup(t);
                switch (t_full) {
                    .array, .tuple, .named => {
                        const reg = reg_manager.getArgLoc(0, TypePool.void_ptr);
                        self.insts[curr_block].block_start = alignAlloc2(self.insts[curr_block].block_start, PTR_SIZE, PTR_SIZE);
                        scope_size = alignAlloc2(scope_size, PTR_SIZE, PTR_SIZE);
                        const off = -@as(isize, @intCast(scope_size));
                        try file.print("\tmov [rbp + {}], {}\n", .{ off, reg });
                        results[i] = ResultLocation{ .stack_base = @as(isize, @intCast(off)) };   
                        int_ct += 1;
                    },
                    else => {},
                }

            },
            .arg_decl => |*v| {
                // TODO handle differnt type
                // TODO handle different number of argument
                var t = v.t;
                const t_full = TypePool.lookup(v.t);
                const reg: Register = switch (t_full) {
                    .int, .ptr, .char, .bool, => blk: {
                        defer int_ct += 1;
                        break :blk reg_manager.getArgLoc(int_ct, t);
                    },
                    .array, .tuple, .named => blk: {
                        v.auto_deref = true;
                        t = TypePool.void_ptr;
                        defer int_ct += 1;
                        break :blk reg_manager.getArgLoc(int_ct, t);
                    },
                    .float => blk: {
                        defer float_ct += 1;
                        break :blk  reg_manager.getArgLoc(float_ct, t);
                    },
                    .void => unreachable,
                };
                self.insts[curr_block].block_start = alignAlloc(self.insts[curr_block].block_start, t);
                scope_size = alignAlloc(scope_size, t);
                const off = -@as(isize, @intCast(scope_size));
                try file.print("\tmov [rbp + {}], {}\n", .{off , reg });
                results[i] = ResultLocation{ .stack_base = off };
            },
            .call => |call| {
                // reg_manager.markUnusedAll(); // TODO caller saved register
                const caller_used = RegisterManager.CallerSaveMask.differenceWith(reg_manager.unused);
                var it = caller_used.iterator(.{ .kind = .set });
                while (it.next()) |regi| {
                    const reg: Register = @enumFromInt(regi);

                    const inst = reg_manager.getInst(reg);
                    const callee_unused = RegisterManager.CalleeSaveMask.intersectWith(reg_manager.unused);
                    const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));

                    reg_manager.markUnused(reg);
                    reg_manager.markUsed(dest_reg, inst);
                    reg_manager.protectDirty(dest_reg, file);

                    ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, file, 8);
                    results[inst] = switch (results[inst]) {
                        .reg => |_| ResultLocation {.reg = dest_reg},
                        .addr_reg => |old_addr| ResultLocation {.addr_reg = AddrReg {.off = old_addr.off, .reg = dest_reg}},
                        else => unreachable
                    };


                }


                var call_int_ct: u8 = 0;
                var call_float_ct: u8 = 0;
                const call_t_full = TypePool.lookup(call.t);
                switch (call_t_full) {
                    .array, .tuple, .named => call_int_ct += 1,
                    else => {},
                }
                for (call.args) |arg| {
                    const loc = results[arg.i];

                    if (loc != .stack_top) _ = consumeResult(results, arg.i, &reg_manager, file);
                    const arg_t_full = TypePool.lookup(arg.t);
                    switch (arg_t_full) {
                        .int, .ptr, .char, .bool => {
                            const reg = reg_manager.getArgLoc(call_int_ct, arg.t);
                            loc.moveToReg(reg, file, typeSize(arg.t));
                            call_int_ct += 1;
                        },
                        .float => {
                            const reg = reg_manager.getArgLoc(call_float_ct, arg.t);
                            loc.moveToReg(reg, file, typeSize(arg.t));
                            call_float_ct += 1;
                        },
                        .void => unreachable,
                        inline .array, .tuple, .named => |_| {
                            const reg = reg_manager.getArgLoc(call_int_ct, arg.t);
                            loc.moveAddrToReg(reg, file);
                            call_int_ct += 1;
                        },
                    }
                }
                switch (call_t_full) {
                    .array, .tuple, .named => {
                        const tsize = typeSize(call.t);
                        const align_size = (tsize + 15) / 16 * 16;
                        try file.print("\tsub rsp, {}\n", .{align_size});
                        const reg = reg_manager.getArgLoc(0, TypePool.void_ptr);
                        try file.print("\tmov {}, rsp\n", .{reg});
                    },
                    else => {},
                }



                try file.print("\tmov rax, {}\n", .{call_float_ct});
                try file.print("\tcall {s}\n", .{Lexer.lookup(call.name)}); // TODO handle return 
                for (call.args) |arg| {
                    if (results[i] == .stack_top) _ = consumeResult(results, arg.i, &reg_manager, file);
                }
                switch (call_t_full) {
                    .void => {},
                    inline .int, .bool, .ptr, .char, => {
                        if (reg_manager.isUsed(.rax)) @panic("TODO");
                        reg_manager.markUsed(.rax, i);
                        results[i] = ResultLocation{ .reg = .rax };
                    },
                    .array, .tuple, .named => {
                        results[i] = ResultLocation {.stack_top = .{ .off = 0, .size = (typeSize(call.t) + 15) / 16 * 16 }};
                    },
                    .float => @panic("TODO"),
                }
            },
            .add,
            .sub,
            .mul,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                lhs_loc.moveToReg(reg, file, 8);

                const op = switch (self.insts[i]) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "imul",
                    else => unreachable,
                };
                try file.print("\t{s} {}, ", .{ op, reg });
                try rhs_loc.print(file, .qword);
                try file.writeByte('\n');

                results[i] = ResultLocation{ .reg = reg };
            },
            .mod, .div => |bin_op| {
                const exclude = [_]Register{ Register.DivendReg, Register.DivQuotient, Register.DivRemainder };
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask, file) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, file, 8);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{Register.DivendReg}, RegisterManager.GpMask, file) orelse @panic("TODO");
                lhs_loc.moveToReg(Register.DivendReg, file, 8);
                try file.print("\tmov edx, 0\n", .{});
                rhs_loc.moveToReg(rhs_reg, file, 8);
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
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask, file) orelse @panic("TODO");

                lhs_loc.moveToReg(result_reg, file, 8);
                rhs_loc.moveToReg(temp_reg, file, 8);
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
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager, file);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager, file);
                lhs_loc.moveToReg(reg, file, typeSize(TypePool.bool));
                try file.print("\tcmp {}, ", .{reg});
                try rhs_loc.print(file, .byte);
                try file.writeByte('\n');
                try file.print("\tsete {}\n", .{reg.lower8()});
                try file.print("\tmovzx {}, {}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .i2f => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_int_reg, file, typeSize(TypePool.float));
                try file.print("\tcvtsi2sd {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask, file) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, file, typeSize(TypePool.int));
                try file.print("\tcvtsd2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer local_lable_ct += 1;
                const loc = consumeResult(results, if_start.expr, &reg_manager, file);
                results[i] = ResultLocation{ .local_lable = local_lable_ct };

                const jump = switch (self.insts[if_start.expr]) {
                    .eq => "jne",
                    .lt => "jae",
                    .gt => "jbe",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask, file) orelse @panic("TODO");
                        loc.moveToReg(temp_reg, file, typeSize(TypePool.bool));
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
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                loc.moveAddrToReg(reg, file);
                results[i] = ResultLocation {.reg = reg};
            },
            .deref => {
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file) orelse unreachable;
                loc.moveToReg(reg, file, PTR_SIZE);
                results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
            },
            .field => |field| {
                switch (TypePool.lookup(field.t)) {
                    .named => |tuple| results[i] = ResultLocation {.int_lit = @intCast(tupleOffset(tuple.els, field.off))},
                    .tuple => |tuple| results[i] = ResultLocation {.int_lit = @intCast(tupleOffset(tuple.els, field.off))},
                    else => unreachable
                }

            },
            .type_size => |t| {
                results[i] = ResultLocation {.int_lit = @intCast(typeSize(t))};
            },
            .array_len => |t| {
                _ = consumeResult(results, i - 1, &reg_manager, file);
                results[i] = ResultLocation {.int_lit = @intCast(TypePool.lookup(t).array.size)};
            },
            .array_init => |array_init| {
                switch (array_init.res_inst) {
                    .ptr => |ptr| {
                        const reg = reg_manager.getUnused(i, RegisterManager.GpMask, file).?;
                        results[ptr].moveToReg(reg, file, PTR_SIZE);
                        results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
                    },
                    .loc => |loc| results[i] = results[loc],
                    .none => {
                        const align_size = (typeSize(array_init.t) + 15) / 16 * 16;
                        file.print("\tsub rsp, {}\n", .{align_size}) catch unreachable;
                        results[i] = ResultLocation {.stack_top = .{.off = 0, .size = align_size}};
                    },
                }

            },
            .array_init_loc => |array_init_loc| {
                const array_init = self.insts[array_init_loc.array_init].array_init;
                results[i] = results[array_init_loc.array_init].offsetBy(array_init_loc.off, array_init.t);
            },
            .array_init_assign => |array_init_assign| {
                const array_init = self.insts[array_init_assign.array_init].array_init;
                const t = array_init.t;
                const sub_t = switch (TypePool.lookup(t)) {
                    inline .tuple, .named => |tuple| tuple.els[array_init_assign.off],
                    .array => |array| array.el,
                    else => unreachable,
                };
                const sub_size = typeSize(sub_t);
                const res_loc = results[array_init_assign.array_init].offsetBy(array_init_assign.off, t);
                const loc = consumeResult(results, i - 1, &reg_manager, file);
                switch (res_loc) {
                    .stack_base => |stack_base| loc.moveToStackBase(stack_base, sub_size, file, &reg_manager, results),
                    .stack_top => |stack_top| loc.moveToAddrReg(.{ .off = stack_top.off, .reg = .rsp }, sub_size, file, &reg_manager, results),
                    .addr_reg => |addr_reg| loc.moveToAddrReg(addr_reg, sub_size, file, &reg_manager, results),
                    else => unreachable
                }
            },
            .array_init_end => |array_init| {
                switch (self.insts[array_init].array_init.res_inst) {
                    .ptr => {
                        _ = consumeResult(results, array_init, &reg_manager, file);
                        results[i] = .uninit;
                    },
                    .loc => {
                        results[i] = .uninit;
                    },
                    .none => {
                        results[i] = results[array_init];
                    },
                }
            },
            .uninit => results[i] = .uninit,
        }
    }
    try file.print(builtinData, .{});
    var string_data_it = string_data.iterator();
    while (string_data_it.next()) |entry| {
        try file.print(".s{}:\n\t.byte\t", .{entry.value_ptr.*});
        const string = Lexer.string_pool.lookup(entry.key_ptr.*);
        for (string) |c| {
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
            .call => |call| alloc.free(call.args),
            else => {},
        }
    }
    alloc.free(self.insts);
}
pub fn generate(ast: Ast, sema: *TypeCheck.Sema, alloc: std.mem.Allocator, arena: std.mem.Allocator) Cir {
    var cir_gen = CirGen {
        .ast = &ast,
        .insts = std.ArrayList(Inst).init(alloc),
        .scopes = ScopeStack.init(alloc),
        .gpa = alloc,
        .arena = arena,
        .ret_decl = undefined,
        .types = sema.types,
        .expr_types = sema.expr_types,
        .use_defs = sema.use_defs
    };
    defer cir_gen.scopes.stack.deinit();
    errdefer cir_gen.insts.deinit();
    for (ast.defs) |def| {
        generateTopDef(def, &cir_gen);
    }
    // errdefer cir_gen.insts.deinit();

    return Cir{ .insts = cir_gen.insts.toOwnedSlice() catch unreachable };
}
pub fn generateTopDef(top: Ast.TopDef, cir_gen: *CirGen) void {
    switch (top.data) {
        .proc => |def| {
            cir_gen.scopes.push();
            cir_gen.append(Inst{ .function = Inst.Fn{ .name = def.name, .scope = undefined, .frame_size = 0 } });
            const fn_idx = cir_gen.getLast();
            cir_gen.append(Inst{ .block_start = 0 });
            // TODO struct pos
            cir_gen.append(Inst {.ret_decl = cir_gen.get_type(def.ret)});
            cir_gen.ret_decl = cir_gen.getLast();
            for (def.args) |arg| {
                cir_gen.append(Inst{ .arg_decl = .{.t = cir_gen.get_type(arg.type), .auto_deref = false} });
                _ = cir_gen.scopes.putTop(arg.name, ScopeItem{ .i = cir_gen.getLast(), .t = cir_gen.get_type(arg.type) }); // TODO handle parameter with same name
            }
            for (def.body) |stat_id| {
                generateStat(cir_gen.ast.stats[stat_id.idx], cir_gen);
            }
            cir_gen.insts.items[fn_idx].function.scope = cir_gen.scopes.pop();

            const last_inst = cir_gen.getLast();
            if (cir_gen.insts.items[last_inst] != Inst.ret and cir_gen.get_type(def.ret) == TypePool.void) {
                cir_gen.append(Inst{ .ret = .{ .ret_decl = cir_gen.ret_decl, .t = cir_gen.get_type(def.ret) } });
            }
            cir_gen.append(Inst{ .block_end = fn_idx + 1 });
        },
        .type => {},
    }

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
            cir_gen.append(.{ .var_decl = .{.t = t, .auto_deref = false} });
            const var_i = cir_gen.getLast();
            _ = cir_gen.scopes.putTop(var_decl.name, .{ .t = t, .i = var_i });
            _ = generateExpr(var_decl.expr, cir_gen, .{ .loc = cir_gen.getLast() });
            cir_gen.append(.{ .var_assign = .{.lhs = var_i, .rhs = cir_gen.getLast(), .t = t} });
        },
        .ret => |expr| {
            generateExpr(expr, cir_gen, .{ .ptr = cir_gen.ret_decl }); // TODO array
            cir_gen.append(.{ .ret = .{ .ret_decl = cir_gen.ret_decl, .t = cir_gen.get_expr_type(expr) } });
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
        .float => {
            // can only be casted to int
            if (rhs_t != TypePool.int) unreachable;
            cir_gen.append(Inst.f2i);
        },
        .int => {
            const rhs_t_full = TypePool.lookup(rhs_t);
            switch (rhs_t_full) {
                .ptr, .char => {},
                .float => cir_gen.append(Inst.i2f),
                else => unreachable,
            }
        },
        .char, .bool => {
            if (rhs_t != TypePool.int) unreachable;
        },
        .ptr => {},
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

    switch (op) {
        .eq => cir_gen.append(Inst{ .eq = bin }),
        .lt => cir_gen.append(Inst{ .lt = bin }),
        .gt => cir_gen.append(Inst{ .gt = bin }),
        else => unreachable,
    }
}
pub fn generateExpr(expr_idx: Ast.ExprIdx, cir_gen: *CirGen, res_inst: ResInst) void {
    const expr = &cir_gen.ast.exprs[expr_idx.idx];
    switch (expr.data) {
        .atomic => |atomic| return generateAtomic(atomic, cir_gen, res_inst),
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
                if (lhs_t == TypePool.int) switch (bin_op.op) {
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
        },
        .fn_app => |fn_app| {
            var args = std.ArrayList(ScopeItem).init(cir_gen.gpa);
            defer args.deinit();
            if (fn_app.func ==  Lexer.string_pool.intern("print")) {
                generateExpr(fn_app.args[0], cir_gen, res_inst);
                const arg_idx = cir_gen.getLast();
                const t = cir_gen.get_expr_type(fn_app.args[0]);
                const t_full = TypePool.lookup(t);
                const format = switch (t_full) {
                    .void => unreachable,
                    .bool, .int => "%i\n",
                    .char => "%c\n",
                    .float => "%f\n",
                    .ptr => |ptr| if (ptr.el == TypePool.char) "%s\n" else "%p\n",
                    .array, => "%s\n",
                    .tuple, .named => @panic("TODO"),
                };
                cir_gen.append(Inst{ .lit = .{ .string = Lexer.string_pool.intern(format) } });
                args.append(.{.i = cir_gen.getLast(), .t = TypePool.string}) catch unreachable; // TODO
                args.append(.{.i = arg_idx, .t = t}) catch unreachable;
                cir_gen.append(Inst{ .call = .{ .name = Lexer.string_pool.intern("printf"), .t = TypePool.void ,.args = args.toOwnedSlice() catch unreachable } });
                return;
            }
            const fn_def = for (cir_gen.ast.defs) |def| {
                if (def.data == .proc and def.data.proc.name == fn_app.func) break def.data.proc;
            } else unreachable;



            var expr_insts = std.ArrayList(usize).init(cir_gen.arena);
            defer expr_insts.deinit();
            for (fn_app.args) |fa| {
                generateExpr(fa, cir_gen, .none);
                args.append(.{ .i = cir_gen.getLast(), .t = cir_gen.get_expr_type(fa) }) catch unreachable;

            }
            cir_gen.append(.{ .call = .{ .name = fn_def.name, .t = cir_gen.get_type(fn_def.ret), .args = args.toOwnedSlice() catch unreachable } });

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
                    cir_gen.append(Inst {.mul = .{ .lhs = cir_gen.getLast(), .rhs = rhs_inst }});
                    cir_gen.append(Inst {.add = .{.lhs = lhs_addr, .rhs = cir_gen.getLast()}});

                    cir_gen.append(.deref);
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
    }
}
pub fn generateAtomic(atomic: Ast.Atomic, cir_gen: *CirGen, res_inst: ResInst) void {
    switch (atomic.data) {
        .float => |f| {
            cir_gen.append(Inst{ .lit = .{ .float = f } });
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
            const t = cir_gen.scopes.get(i).?;
            cir_gen.append(Inst{ .var_access = t.i });
        },

        .addr => @panic("TODO ADDR"),
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
