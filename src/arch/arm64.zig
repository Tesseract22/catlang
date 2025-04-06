const std = @import("std");
const TypePool = @import("../type.zig");
const Cir = @import("../cir.zig");
const log = @import("../log.zig");
const InternPool = @import("../intern_pool.zig");
const Symbol = InternPool.Symbol;
const Lexer = @import("../lexer.zig");
const TypeCheck = @import("../typecheck.zig");
const Arch = @import("../arch.zig");
const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;

const PTR_SIZE = 8;
const STACK_ALIGNMENT = 16;


const Register = enum {
    x0, x1, x2, x3, x4, x5, x6, x7,
    x8, x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, x19, x20, x21, x22, x23,
    x24, x25, x26, x27, x28, x29, x30, xzr,

    // 128-bit floating-point registers
    q0, q1, q2, q3, q4, q5, q6, q7,
    q8, q9, q10, q11, q12, q13, q14, q15,
    q16, q17, q18, q19, q20, q21, q22, q23,
    q24, q25, q26, q27, q28, q29, q30, q31,

    sp,

    pub const Lower32 = enum {
        w0, w1, w2, w3, w4, w5, w6, w7,
        w8, w9, w10, w11, w12, w13, w14, w15,
        w16, w17, w18, w19, w20, w21, w22, w23,
        w24, w25, w26, w27, w28, w29, w30, wzr,


        pub fn format(value: Lower32, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            _ = try writer.writeAll(@tagName(value));
        }
    };

    pub fn isFloat(self: Register) bool {
        return switch (@intFromEnum(self)) {
            @intFromEnum(Register.q0)...@intFromEnum(Register.q31) => true,
            else => false,
        };
    }
    pub fn lower32(self: Register) Lower32 {
        return @enumFromInt(@intFromEnum(self));
    }
    pub fn adapatSize(self: Register, word: Word) []const u8 {
        return switch (word) {
            .byte,
            .word,
            .dword => @tagName(self.lower32()),
            .qword => @tagName(self),
        };
    }


    //pub const DivendReg = Register.rax;
    //pub const DivQuotient = Register.rax;
    //pub const DivRemainder = Register.rdx;

    pub fn format(value: Register, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        _ = try writer.writeAll(@tagName(value));
    }
};

const RegisterManager = struct {
    unused: Regs, // record of register currently holding some data
    dirty: Regs, // record of volatile registers being used in a function, and thus needs to be restored right before return
    insts: [count]usize, // points to the instruction which allocate the corresponding register in `unused`
    cconv: CallingConvention, // TODO: This prevent us to have different calling convention
    body_writer: OutputBuffer.Writer,

    // stack management
    frame_usage: usize, // record the current stack usage inside the current function, which is then used to properly allocate space in prologue
    max_usage: usize,
    scope_stack: ScopeStack, // record the stack usage at each level of the scope
    temp_usage: usize,
    temp_stack: ScopeStack,
    dirty_spilled: std.AutoHashMap(Register, isize),
    alloc: std.mem.Allocator,

    const ScopeStack = std.ArrayListUnmanaged(usize);
    const count = @typeInfo(Register).@"enum".fields.len;
    pub const Regs = std.bit_set.ArrayBitSet(u8, count);
    pub const GpRegs = [_]Register{
        .x0, .x1, .x2, .x3, .x4, .x5, .x6, .x7,
        .x8, .x9, .x10, .x11, .x12, .x13, .x14, .x15,
        .x16, .x17, .x18, .x19, .x20, .x21, .x22, .x23,
        .x24, .x25, .x26, .x27, .x28, .x29, .x30, .xzr,
    };
    // This actually depends on the calling convention
    pub const FlaotRegs = [_]Register{
        .q0, .q1, .q2, .q3, .q4, .q5, .q6, .q7,
        .q8, .q9, .q10, .q11, .q12, .q13, .q14, .q15,
        .q16, .q17, .q18, .q19, .q20, .q21, .q22, .q23,
        .q24, .q25, .q26, .q27, .q28, .q29, .q30, .q31,
    };
    pub const GpMask = cherryPick(&GpRegs);
    pub const FloatMask = cherryPick(&FlaotRegs);
    // stack manipulation functions -----------------------------------------------------------------
    pub fn enterScope(self: *RegisterManager) void {
        self.scope_stack.append(self.alloc, 0) catch unreachable;
    }
    pub fn exitScope(self: *RegisterManager) void {
        const size = self.scope_stack.pop().?;
        self.frame_usage -= size;
    }
    // This function does not immediately do `sub rsp, ...`, instead it does it `lazily`
    // There is also no ways to revert the effect
    pub fn allocateStack(self: *RegisterManager, size: usize, alignment: usize) isize {
        const new_size = alignAlloc2(self.frame_usage, size, alignment);
        self.scope_stack.items[self.scope_stack.items.len - 1] += new_size - self.frame_usage;
        self.frame_usage = new_size;
        self.max_usage = @max(self.frame_usage, self.max_usage);
        return -@as(isize, @intCast(self.frame_usage));
    }
    pub fn allocateStackTyped(self: *RegisterManager, t: Type) isize {
        return self.allocateStack(typeSize(t), alignOf(t));
    }
    // A wrapper around isize. We use this to signify that this offset SHOULD NOT be used directly
    pub const StackTop = struct { off: usize };
    // allocate a temporary memory on the top of the stack, which can be freed by `freeStackTemp`
    // The alignment automatically at least STACK_ALIGNMENT
    // This function returns the offset from stack top (rsp). However, 
    // The ACTUAL position could change as new temp comes on top
    // One must use `getStackTop` to get the ACTUAL stack offset
    pub fn allocateStackTemp(self: *RegisterManager, size: usize, alignment: usize) StackTop {
        const new_size = alignAlloc2(self.temp_usage, size, alignment);
        self.temp_stack.append(self.alloc, new_size - self.temp_usage) catch unreachable;
        self.print("\tsub rsp, {}\n", .{new_size - self.temp_usage});
        self.temp_usage = new_size;
        return .{.off = self.temp_usage };
    }
    pub fn allocateStackTempTyped(self: *RegisterManager, t: Type) StackTop {
        return self.allocateStackTemp(typeSize(t), alignOf(t));
    }
    pub fn freeStackTemp(self: *RegisterManager) void {
        const size = self.temp_stack.pop().?;
        self.temp_usage -= size;
        self.print("\tadd rsp, {}\n", .{size});
    }
    pub fn getStackTop(self: RegisterManager, stack_top: StackTop) usize {
        if (stack_top.off > self.temp_usage) @panic("The stack top item has already been freed!");
        return self.temp_usage - stack_top.off;
    }
    // --------------------------------------------------------------------------------------------
    pub fn debug(self: RegisterManager) void {
        var it = self.unused.iterator(.{ .kind = .unset });
        while (it.next()) |i| {
            log.debug("{} inused", .{@as(Register, @enumFromInt(i))});
        }
    }
    pub fn init(cconv: CallingConvention, body_writer: OutputBuffer.Writer, alloc: std.mem.Allocator) RegisterManager {
        var dirty = cconv.callee_saved;
        dirty.toggleAll();
        return RegisterManager{ 
            .alloc = alloc,
            .unused = Regs.initFull(), 
            .insts = undefined, 
            .dirty = dirty, 
            .cconv = cconv, 
            .body_writer = body_writer,
            .frame_usage = 0,
            .max_usage = 0,
            .scope_stack = ScopeStack.initCapacity(alloc, 0) catch unreachable,
            .temp_usage = 0,
            .temp_stack = ScopeStack.initCapacity(alloc, 0) catch unreachable,
            .dirty_spilled = std.AutoHashMap(Register, isize).init(alloc),
        };
    }
    pub fn deinit(self: *RegisterManager) void {
        self.scope_stack.deinit(self.alloc);
        self.temp_stack.deinit(self.alloc);
        self.dirty_spilled.deinit();
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
        var dirty = self.cconv.callee_saved;
        dirty.toggleAll();
        self.dirty = dirty;
    }
    pub fn getInst(self: *RegisterManager, reg: Register) usize {
        return self.insts[@intFromEnum(reg)];
    }
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
        self.protectDirty(reg);
        return reg;
    }
    pub fn saveDirty(self: *RegisterManager, reg: Register) void {
        const off = self.allocateStack(PTR_SIZE, PTR_SIZE);
        self.dirty_spilled.putNoClobber(reg, off) catch unreachable;
        self.print("\tmov [x29 + {}], {}\n", .{ off, reg });
    }
    pub fn restoreDirty(self: *RegisterManager, reg: Register) void {
        const off = self.dirty_spilled.get(reg) orelse @panic("restoring a register that is not dirty");
        self.print("\tmov {}, [x29 + {}]\n", .{ reg, off });
    }
    pub fn protectDirty(self: *RegisterManager, reg: Register) void {
        if (!self.isDirty(reg)) {
            self.markDirty(reg);
            self.saveDirty(reg);
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
    pub fn print(self: RegisterManager, comptime format: []const u8, args: anytype) void {
        self.body_writer.print(format, args) catch unreachable;
    }
    // Given the position and class of the argument, return the register for this argument,
    // or null if it should be passe on the stack

};
pub const AddrReg = struct {
    reg: Register,
    mul: ?struct {Register, Word} = null,
    disp: isize,

    pub fn print(reg: AddrReg, writer: OutputBuffer.Writer, word: Word) !void {
        if (reg.mul) |mul| 
            try writer.print("{s} PTR [{} + {} * {} + {}]", .{@tagName(word), reg.reg, mul[0], @intFromEnum(mul[1]), reg.disp})
        else
            try writer.print("{s} PTR [{} + {}]", .{@tagName(word), reg.reg, reg.disp});

    }
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

pub fn tupleOffset(tuple: []const Type, off: usize) usize {
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
    //stack_top: RegisterManager.StackTop,
    int_lit: isize,
    foreign: Symbol,
    string_data: usize,
    float_data: usize,
    double_data: usize,
    local_lable: usize,
    array: []usize,
    uninit,

    pub fn stackBase(off: isize) ResultLocation {
        return .{.addr_reg = .{.reg = .x29, .disp = off, }};
    }
    pub const StackTop = struct {
        off: isize,
        size: usize,
    };
    pub fn isMem(self: ResultLocation) bool {
        return switch (self) {
            .addr_reg => true,
            else => false
        };
    }
    pub fn offsetBy(self: ResultLocation, pos: usize, t: Type) ResultLocation {
        const t_full = TypePool.lookup(t);
        const total_off: isize = 
            switch (t_full) {
                .tuple => |tuple| @intCast(tupleOffset(tuple.els, pos)),
                .named => |named| @intCast(tupleOffset(named.els, pos)),
                .array => |array| blk: {
                    const sub_t = array.el;
                    break :blk @intCast(typeSize(sub_t) * pos);
                },
                else => unreachable,
            };
        return switch (self) {
            .addr_reg => |addr_reg| .{.addr_reg = AddrReg {.disp = total_off + addr_reg.disp, .reg = addr_reg.reg}},
            else => unreachable
        };
    }
    pub fn offsetByByte(self: ResultLocation, off: isize) ResultLocation {
        if (self != .addr_reg)
            return self;
        var clone = self.addr_reg;
        clone.disp += off;
        return .{.addr_reg = clone };
    }

    pub fn moveAddrToReg(self: ResultLocation, reg: Register, reg_manager: *RegisterManager) void {
        reg_manager.print("\tlea {}, ", .{reg});
        self.print(reg_manager.body_writer, .qword) catch unreachable;
        reg_manager.print("\n", .{});
    }
    pub fn moveToGpReg(self: ResultLocation, size: usize, inst: ?usize, reg_manager: *RegisterManager) Register {
        switch (self) {
            .reg => |reg| {
                if (inst != null and RegisterManager.GpMask.isSet(@intFromEnum(reg))) {
                    reg_manager.markUsed(reg, inst.?);
                    return reg;
                }
            },
            else => {},
        }
        const gp_reg = reg_manager.getUnused(inst, RegisterManager.GpMask) orelse unreachable;
        self.moveToReg(gp_reg, size, reg_manager);
        return gp_reg;
    }
    pub fn moveToReg(self: ResultLocation, reg: Register, size: usize, reg_manager: *RegisterManager) void {
        if (self == .uninit) return;
        var mov: []const u8 = "mov";
        const word = Word.fromSize(size).?;
        switch (self) {
            .reg => |self_reg| {
                if (self_reg == reg) return;
                if (self_reg.isFloat()) {
                    //    if (word == .qword) mov = "movsd";
                    //    if (word == .dword) mov = "movss";
                    mov = switch (word) {
                        .qword => "movq",
                        .dword => "movd",
                        .word, .byte => "mov",
                    };
                }
            },
            //inline .stack_base, .stack_top, .addr_reg => |_| {if (size != 8) mov = "movzx";},
            .string_data => |_| mov = "lea",
            .array => @panic("TODO"),
            else => {},
        }
        // TODO
        if (reg.isFloat()) {
            if (word == .qword) mov = "movsd";
            if (word == .dword) mov = "movss";
        }         
        reg_manager.print("\t{s} {s}, ", .{ mov, reg.adapatSize(word) });
        self.print(reg_manager.body_writer, word) catch unreachable;
        reg_manager.print("\n", .{});
    }
    // the offset is NOT multiple by platform size
    pub fn moveToStackBase(self: ResultLocation, off: isize, size: usize, reg_man: *RegisterManager, results: []ResultLocation) void {
        return self.moveToAddrReg(AddrReg {.reg = .x29, .disp = off}, size, reg_man, results);

    }
    pub fn moveToStackTop(self: ResultLocation, size: usize, reg_man: *RegisterManager, results: []ResultLocation) void {
        return self.moveToAddrReg(AddrReg {.reg = .sp, .disp = 0 }, size, reg_man, results);
    }

    pub fn moveToAddrReg(self: ResultLocation, reg: AddrReg, size: usize, reg_man: *RegisterManager, results: []ResultLocation) void {
        if (self == .uninit) return;
        if (Word.fromSize(size)) |word| {
            return self.moveToAddrRegWord(reg, word, reg_man, results);
        }
        var self_clone = self;
        switch (self_clone) {
            .array => |array| {
                const sub_size = @divExact(size, array.len);
                for (array, 0..array.len) |el_inst, i| {
                    const loc = consumeResult(results, el_inst, reg_man);
                    loc.moveToAddrReg(AddrReg {.reg = reg.reg, .disp = reg.disp + @as(isize, @intCast(sub_size * i))}, sub_size, reg_man, results);
                }
                return;
            },
            .addr_reg => |_| {
                const off = &self_clone.addr_reg.disp;
                //reg_man.markUsed(self_clone.addr_reg.reg, null);
                reg_man.unused.unset(@intFromEnum(self_clone.addr_reg.reg));
                const reg_size = PTR_SIZE;
                var size_left = size;
                while (size_left > reg_size): (size_left -= reg_size) {
                    self_clone.moveToAddrRegWord(AddrReg {.reg = reg.reg, .disp = reg.disp + @as(isize, @intCast(size - size_left)), .mul = reg.mul}, .qword, reg_man, results);
                    off.* += reg_size;
                }
                self_clone.moveToAddrRegWord(AddrReg {.reg = reg.reg, .disp= reg.disp + @as(isize, @intCast(size - size_left)), .mul = reg.mul}, Word.fromSize(size_left).?, reg_man, results);
                reg_man.unused.set(@intFromEnum(self_clone.addr_reg.reg));
                //reg_man.markUnused(self_clone.addr_reg.reg);
            },
            else => unreachable
        }
    }
    pub fn moveToAddrRegWord(self: ResultLocation, reg: AddrReg, word: Word, reg_man: *RegisterManager, _: []ResultLocation) void {
        const mov = if (self == ResultLocation.reg and self.reg.isFloat()) blk: {
            if (word == .qword) break :blk "movsd";
            if (word == .dword) break :blk "movss";
            unreachable;
        } else "mov";
        const temp_loc = switch (self) {
            inline .string_data, .float_data, .double_data, .addr_reg  => |_| blk: {
                const temp_reg = reg_man.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                self.moveToReg(temp_reg, @intFromEnum(word), reg_man);
                break :blk ResultLocation{ .reg = temp_reg };
            },
            .array => unreachable,
            else => self,
        };
        //log.err("mov {s}, temp_loc {}", .{mov, temp_loc});
        //temp_loc.print(std.io.getStdOut().writer(), word) catch unreachable;
        reg_man.print("\t{s} ", .{ mov});
        reg.print(reg_man.body_writer, word) catch unreachable;
        reg_man.print(", ", .{});
        temp_loc.print(reg_man.body_writer, word) catch unreachable;
        reg_man.print("\n", .{});
    }

    pub fn print(self: ResultLocation, writer: OutputBuffer.Writer, word: Word) std.ArrayList(u8).Writer.Error!void {

        switch (self) {
            .reg => |reg| try writer.print("{s}", .{reg.adapatSize(word)}),
            .addr_reg => |reg| 
                try reg.print(writer, word),
            //.stack_base => |off| try writer.print("{s} PTR [x29 + {}]", .{@tagName(word), off}),
            //.stack_top => |stack_top| try writer.print("{s} PTR [rsp + {}]", .{@tagName(word), stack_top.off}),
            .int_lit => |i| try writer.print("#{}", .{i}),
            .string_data => |s| try writer.print(".s{}[rip]", .{s}),
            .float_data => |f| try writer.print(".f{}[rip]", .{f}),
            .double_data => |f| try writer.print(".d{}[rip]", .{f}),
            .foreign => |foreign| try writer.print("{s}[rip]", .{Lexer.lookup(foreign)}),
            inline .local_lable,  .array => |_| @panic("TODO"),
            .uninit => unreachable,
        }
    }
};



pub fn typeSize(t: Type) usize {
    if (t == TypePool.double) return 8;
    if (t == TypePool.float) return 4;
    if (t == TypePool.int) return PTR_SIZE;
    if (t == TypePool.bool) return 1;
    if (t == TypePool.char) return 1;
    if (t == TypePool.void) return 0;
    const t_full = TypePool.lookup(t);
    return switch (t_full) {
        .array => |array| array.size * typeSize(array.el),
        .tuple => |tuple| tupleOffset(tuple.els, tuple.els.len),
        .named => |tuple| tupleOffset(tuple.els, tuple.els.len),
        .function => |_| PTR_SIZE,
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
pub fn roundUpMultipleOf(size: usize, alignment: usize) usize {
    return alignAlloc2(size, 0, alignment);
}
pub fn alignStack(curr_size: usize) usize {
    return alignAlloc2(curr_size, 0, STACK_ALIGNMENT);
}
pub fn consumeResult(results: []ResultLocation, idx: usize, reg_mangager: *RegisterManager) ResultLocation {
    const loc = results[idx];
    switch (loc) {
        .reg => |reg| reg_mangager.markUnused(reg),
        .addr_reg, => |addr_reg| {
            reg_mangager.markUnused(addr_reg.reg);
            if (addr_reg.mul) |mul|
                reg_mangager.markUnused(mul[0]);
            },

            inline .float_data, .double_data, .string_data, .int_lit, .foreign, .local_lable, .array, .uninit => |_| {},
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
pub const CallingConvention = struct {
    pub const VTable = struct {
        call: *const fn (
                  i: usize,
                  call: Cir.Inst.Call, 
                  reg_manager: *RegisterManager, 
                  results: []ResultLocation) void,  

                  prolog: *const fn (
                      self: Cir, 
                      reg_manager: *RegisterManager, 
                      results: []ResultLocation) void,
                      epilog: *const fn (
                          reg_manager: *RegisterManager, 
                          results: []ResultLocation, 
                          ret_t: Type,
                          i: usize) void,  
                      };
    vtable: VTable,
    callee_saved: RegisterManager.Regs,
    pub fn makeCall(
        cconv: CallingConvention,
        i: usize,
        call: Cir.Inst.Call, 
        reg_manager: *RegisterManager, 
        results: []ResultLocation) void {
        cconv.vtable.call(i, call, reg_manager, results);
    }
    pub fn prolog(cconv: CallingConvention, self: Cir, reg_manager: *RegisterManager, results: []ResultLocation) void {
        cconv.vtable.prolog(self, reg_manager, results);
    }
    pub fn epilog(            
        cconv: CallingConvention,
        reg_manager: *RegisterManager, 
        results: []ResultLocation, 
        ret_t: Type,
        i: usize) void {
        cconv.vtable.epilog(reg_manager, results, ret_t, i);
    }

    const Class = union(enum) {
        int,
        float,
        composite,
        nfa: struct { base: Type, count: u32 },
        pub fn isComposite(self: Class) bool {
            return self == .composite or self == .nfa;
        }
    };
    pub const CDecl = struct {
        pub const CallerSaveRegs = [_]Register{ 
            .x9, .x10, .x11, .x12, .x13, .x14, .x15,
            .q0, .q1, .q2, .q3, .q4, .q5, .q6, .q7,
            .q16, .q17, .q18, .q19, .q20, .q21, .q22, .q23, .q24, .q25, .q26, .q27, .q28, .q29, .q30, .q31

        };
        pub const CalleeSaveRegs = [_]Register{ 
            .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x27, .x28, 
            .q8, .q9, .q10, .q11, .q12, .q13, .q14, .q15  };
        pub const CallerSaveMask = RegisterManager.cherryPick(&CallerSaveRegs);
        pub const CalleeSaveMask = RegisterManager.cherryPick(&CalleeSaveRegs);



        pub fn interface() CallingConvention {
            return .{.vtable = .{.call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog }, .callee_saved = CalleeSaveMask};
        }
        fn getFloatLoc(t_pos: u8) Register {
            return @enumFromInt(t_pos + @intFromEnum(Register.q0));
        }
        fn getIntLoc(t_pos: u8) Register {
            return @enumFromInt(t_pos + @intFromEnum(Register.x0));
        }
        fn classifyType(t: Type) Class {
            const t_full = TypePool.lookup(t);
            switch (t_full) {
                .number_lit, .void, .function => unreachable,
                .float, .double => return .float,
                .ptr, .int, .bool, .char => return .int,
                .array => |array| {
                    const base_class = classifyType(array.el);
                    switch (base_class) {
                        .nfa => |nfa| {
                            if (nfa.count * array.size <= 4) return Class {.nfa = .{.base = nfa.base, .count = nfa.count * array.size }};
                        },
                        .float => {
                            if (array.size <= 4) return Class {.nfa = .{.base = array.el, .count = array.size }};
                        },
                        else => return .composite,
                    }
                    return .composite;
                },
                inline .tuple, .named => |tuple| {
                    if (tuple.els.len > 4) return .composite;
                    var nfa_count: u32 = 0;
                    var nfa_base: ?Type = null;
                    for (tuple.els) |base| {
                        const base_class = classifyType(base);
                        switch (base_class) {
                            .nfa => |nfa| {
                                if (nfa_base) |curr_base| {
                                    if (nfa.base != curr_base) return .composite;
                                } else {
                                    nfa_base = nfa.base;
                                }
                                nfa_count += nfa.count;
                            },
                            .float => {
                                if (nfa_base) |curr_base| {
                                    if (base != curr_base) return .composite;
                                } else {
                                    nfa_base = base;
                                }
                                nfa_count += 1;
                            },
                            else => return .composite,
                        }
                        if (nfa_count > 4) return .composite; 
                    }
                    return .{ .nfa = .{ .base = nfa_base.?, .count = nfa_count }};
                }
            }
        }
         
        pub fn prolog(
            self: Cir, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation
        ) void {
            reg_manager.markCleanAll();
            reg_manager.markUnusedAll();

            // allocate return
            // Index 1 of insts is always the ret_decl
            
            if (self.ret_type != TypePool.@"void") {
                const ret_loc = findCallArgsLoc(&.{self.ret_type}, reg_manager.alloc);
                defer ret_loc.deinit(reg_manager.alloc);
                if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                    results[1] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = 0 }};
                    reg_manager.markUsed(.x29, 1);
                }
            }
            const args_loc = findCallArgsLoc(self.arg_types, reg_manager.alloc);
            defer args_loc.deinit(reg_manager.alloc);
            for (0..args_loc.locs.len) |arg_i| {
                const stack_pos = reg_manager.allocateStack(args_loc.sizes[arg_i], args_loc.aligns[arg_i]);
                if (args_loc.turn_into_addr[arg_i]) |_| self.insts[2 + arg_i].arg_decl.auto_deref = true;
                switch (args_loc.locs[arg_i]) {
                    .gp_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                            const reg = getIntLoc(@intCast(r));
                            const loc = ResultLocation { .reg = reg };
                            loc.moveToStackBase(stack_pos + PTR_SIZE*@as(isize, @intCast(r)), PTR_SIZE, reg_manager, results);
                        }
                        results[2 + arg_i] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = stack_pos }};
                    },
                    .vf_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                            const reg = getFloatLoc(@intCast(r));
                            const loc = ResultLocation { .reg = reg };
                            loc.moveToStackBase(stack_pos + PTR_SIZE*@as(isize, @intCast(r)), PTR_SIZE, reg_manager, results);
                        }
                        results[2 + arg_i] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = stack_pos }};
                    },
                    .stack => |off| {
                        results[2 + arg_i] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = off + 2 * PTR_SIZE }};
                    },
                }
            }
        }
        pub fn epilog(
            reg_manager: *RegisterManager, 
            results: []ResultLocation, 
            ret_t: Type,
            i: usize) void {
            

            if (ret_t != TypePool.@"void") {
                const ret_loc = findCallArgsLoc(&.{ret_t}, reg_manager.alloc);
                defer ret_loc.deinit(reg_manager.alloc);

                const loc = consumeResult(results, i - 1, reg_manager);
                if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                    loc.moveToAddrReg(AddrReg {.reg = .x29, .disp = 0}, typeSize(ret_t), reg_manager, results);
                } else {
                    switch (ret_loc.locs[0]) {
                        .gp_regs => |reg_loc| {
                            for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                                loc.moveToReg(getIntLoc(@intCast(r)), PTR_SIZE, reg_manager);
                            }
                        },
                        .vf_regs => |reg_loc| {
                            for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                                loc.moveToReg(getFloatLoc(@intCast(r)), PTR_SIZE, reg_manager);
                            }
                        },
                        .stack => unreachable,
                    }
                }
            }

            var it = reg_manager.dirty.intersectWith(CalleeSaveMask).iterator(.{});
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);
                reg_manager.restoreDirty(reg);
            }
            reg_manager.print("\tmov sp, x29\n", .{});
            reg_manager.print("\tldp x29, x30, [sp]\n", .{});
            reg_manager.print("\tret\n", .{});

        } 
        fn saveVolatile(reg_manager: *RegisterManager, results: []ResultLocation) void {
            const caller_used = CallerSaveMask.differenceWith(reg_manager.unused);
            var it = caller_used.iterator(.{ .kind = .set });
            while (it.next()) |regi| {
                const callee_unused = CalleeSaveMask.intersectWith(reg_manager.unused);
                const reg: Register = @enumFromInt(regi);
                const inst = reg_manager.getInst(reg);
                const dest_reg: Register = @enumFromInt(callee_unused.findFirstSet() orelse @panic("TODO"));

                reg_manager.markUnused(reg);
                reg_manager.markUsed(dest_reg, inst);
                reg_manager.protectDirty(dest_reg);

                ResultLocation.moveToReg(ResultLocation{ .reg = reg }, dest_reg, 8, reg_manager);
                results[inst] = switch (results[inst]) {
                    .reg => |_| ResultLocation {.reg = dest_reg},
                    .addr_reg => |old_addr| blk: {
                        break :blk if (old_addr.reg == reg)
                            ResultLocation {.addr_reg = AddrReg {.mul = old_addr.mul, .reg = dest_reg, .disp = old_addr.disp}}
                        else
                            ResultLocation {.addr_reg = AddrReg {.mul = .{dest_reg, old_addr.mul.?[1]}, .reg = old_addr.reg, .disp = old_addr.disp}};

                        },
                    else => unreachable
                };

            }

        }
        const CallArgsLoc = struct {
            const RegLoc = struct {
                start: u8,
                count: u8,
            };
            const ArgLoc = union(enum) {
                gp_regs: RegLoc,
                vf_regs: RegLoc,
                stack: isize,
            };
            sizes: []usize, 
            aligns: []usize,
            locs: []ArgLoc,
            turn_into_addr: []?usize,
            NSAA: usize,
            pub fn init(alloc: std.mem.Allocator, arg_count: usize) CallArgsLoc {
                return .{
                    .sizes = alloc.alloc(usize, arg_count) catch unreachable,
                    .aligns = alloc.alloc(usize, arg_count) catch unreachable,
                    .locs = alloc.alloc(ArgLoc, arg_count) catch unreachable,
                    .turn_into_addr = alloc.alloc(?usize, arg_count) catch unreachable,
                    .NSAA = 0,
                };
            }
            pub fn deinit(self: CallArgsLoc, alloc: std.mem.Allocator) void {
                alloc.free(self.sizes);
                alloc.free(self.aligns);
                alloc.free(self.locs);
                alloc.free(self.turn_into_addr);
            }
        };
        pub fn findCallArgsLoc(arg_types: []const Type, alloc: std.mem.Allocator) CallArgsLoc {
            var NGRN: usize = 0; // next general purpose register number
            var NSRN: usize = 0; // next SIMD and floting-point register number
            var NSAA: usize = 0; // next stacked argument address
                                 // Stage A ends
            var args = CallArgsLoc.init(alloc, arg_types.len);
            for (arg_types, 0..) |t, arg_i| {

                args.sizes[arg_i] = typeSize(t);
                args.aligns[arg_i] = alignOf(t);
                const size = &args.sizes[arg_i];
                const alignment = &args.aligns[arg_i];
                const class = classifyType(t);

                // Stage B - Pre-padding and extension of arguments
                // B.1 - ignored, scalable vector type is not supported
                // B.2 - ignored, all types size can be determined at compile-time
                // B.3 - ignored, 
                switch (class) {
                    .composite => {
                        // B.4 - copy composite type large than 16 bytes to mem
                        if (size.* > 2 * PTR_SIZE) {
                            //const stack_top = reg_manager.allocateStackTempTyped(arg.t);
                            //const arg_loc = consumeResult(results, arg.i, reg_manager);
                            //arg_loc.moveToStackTop(size, reg_manager, results);
                            //arg.i = ResultLocation {.stack_top = stack_top };
                            size.* = PTR_SIZE;
                            alignment.* = PTR_SIZE;
                            args.turn_into_addr[arg_i] = 0;
                        } else {
                            // B.5 - round composite size to the nearest 8 byte
                            size.* = roundUpMultipleOf(size.*, PTR_SIZE);
                            args.turn_into_addr[arg_i] = null;
                        }
                    },
                    else => {},
                }
                // B.6 - ignored
                if (alignment.* <= PTR_SIZE) alignment.* = PTR_SIZE;
                if (alignment.* >= PTR_SIZE * 2) alignment.* = 2 * PTR_SIZE;
                // Stage B ends
                // Stage C - Assignment of arguments to registers and stack
                //const arg_loc = consumeResult(results, arg.i, reg_manager);
                // C.1 - Assign float to v[NSRN] if NSRN < 8
                if (class == .float and NSRN < 8) {
                    args.locs[arg_i] = .{ .vf_regs = .{.start = @intCast(NSRN), .count = 1 } };
                    NSRN += 1;
                    continue;
                } 
                if (class == .nfa and NSRN + class.nfa.count <= 8) { // C.2 - Assign NFA,NVA to v[NSRN]
                    args.locs[arg_i] = .{ .vf_regs = .{.start = @intCast(NSRN), .count = @intCast(class.nfa.count) } };
                    NSRN += class.nfa.count;
                    continue;
                }
                if (class == .nfa) { // C.3 - round up to nearest multiple of 8 bytes
                    size.* = roundUpMultipleOf(size.*, PTR_SIZE);
                    NSRN = 8;
                }
                if (class == .nfa) { // C.4 - round NSAA
                    if (alignment.* <= PTR_SIZE) NSAA = roundUpMultipleOf(NSAA, PTR_SIZE);
                    if (alignment.* >= PTR_SIZE * 2) NSAA = roundUpMultipleOf(NSAA, 2 * PTR_SIZE);
                }
                if (class == .float) { // C.5 - float and double should occpy 8 bytes
                    size.* = PTR_SIZE;
                }
                if (class == .float or class == .nfa) { // C.6 - move float to NSAA if NSAA >= 8
                    args.locs[arg_i] = .{ .stack = @intCast(NSAA) };
                    NSAA += size.*;
                }
                // C.7 - ignored
                // C.8 - ignored
                // C.9 - move integral to v[NGRN] if NGRN < 8
                if (class == .int and NGRN < 8) {
                    args.locs[arg_i] = .{ .vf_regs = .{.start = @intCast(NSRN), .count = 1 } };
                    NGRN += 1;
                    continue;
                }
                if (alignment.* == 2 * PTR_SIZE) { // C.10
                    NGRN = roundUpMultipleOf(NGRN, 2);
                }
                // C.11 - ignored, all integer sizes <= PTR_SIZE in our language
                if (class.isComposite() and size.*/PTR_SIZE <= 8 - NGRN) { // C.12 - Composite type
                    args.locs[arg_i] = .{ .gp_regs = .{.start = @intCast(NGRN), .count = @intCast(size.*/PTR_SIZE) } };
                    NGRN += size.*/PTR_SIZE;
                    continue;
                }
                // C.13
                NGRN = 8;
                // C.14
                NSAA = roundUpMultipleOf(NSAA, @max(alignment.*, PTR_SIZE));
                if (class.isComposite()) { // C.15
                    args.locs[arg_i] = .{ .stack = @intCast(NSAA) };
                    NSAA += size.*;
                    continue;
                }
                if (size.* < PTR_SIZE) size.* = PTR_SIZE;
                args.locs[arg_i] = .{ .stack = @intCast(NSAA) };
                NSAA += size.*;
                // Stack C ends
            }
            for (arg_types, 0..) |t, arg_i| {
                if (args.turn_into_addr[arg_i]) |*addr| {
                    addr.* = NSAA;
                    NSAA = alignAlloc2(NSAA, typeSize(t), @max(PTR_SIZE, alignOf(t)));
                }
            }
            args.NSAA = NSAA;
            return args;
        }
        // aarch64 procedure call standard
        // https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
        pub fn makeCall(
            i: usize,
            call: Cir.Inst.Call, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void {
            saveVolatile(reg_manager, results);

            if (call.t != TypePool.@"void") {
                const ret_loc = findCallArgsLoc(&.{call.t}, reg_manager.alloc);
                defer ret_loc.deinit(reg_manager.alloc);
                if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                    const stack_off = reg_manager.allocateStackTyped(call.t);
                    reg_manager.print("\tadd x8, x29, {}\n", .{stack_off});
                }
            }
            const args_loc = findCallArgsLoc(call.ts, reg_manager.alloc);
            defer args_loc.deinit(reg_manager.alloc);
            _ = reg_manager.allocateStackTemp(args_loc.NSAA, STACK_ALIGNMENT);
            defer reg_manager.freeStackTemp();
            for (call.locs, call.ts, 0..) |loc_i, t, arg_i| {
                var loc = consumeResult(results, loc_i, reg_manager);
                const raw_size = typeSize(t);
                if (args_loc.turn_into_addr[arg_i]) |addr| {
                    loc.moveToAddrReg(AddrReg {.reg = .sp, .disp = @intCast(addr) }, raw_size, reg_manager, results);
                    const addr_reg = reg_manager.getUnused(null, RegisterManager.GpMask).?;
                    reg_manager.print("\tadd {}, {}, {}\n", .{ addr_reg, .sp, addr });
                    loc = ResultLocation { .reg = addr_reg };
                }
                switch (args_loc.locs[arg_i]) {
                    .gp_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                            const reg = getIntLoc(@intCast(r));
                            loc.offsetByByte(PTR_SIZE*@as(isize, @intCast(r))).moveToReg(reg, PTR_SIZE, reg_manager);
                        }
                    },
                    .vf_regs => |reg_loc| {
                        for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                            const reg = getFloatLoc(@intCast(r));
                            loc.offsetByByte(PTR_SIZE*@as(isize, @intCast(r))).moveToReg(reg, PTR_SIZE, reg_manager);
                        }
                    },
                    .stack => |off| {
                        loc.moveToAddrReg(AddrReg {.reg = .sp, .disp = off }, raw_size, reg_manager, results);
                    },
                }
            }
            if (call.t != TypePool.@"void") {
                const ret_loc = findCallArgsLoc(&.{call.t}, reg_manager.alloc);
                defer ret_loc.deinit(reg_manager.alloc);
                if (ret_loc.turn_into_addr[0] != null or ret_loc.locs[0] == .stack) {
                    results[i] = ResultLocation {.addr_reg = .{.reg = .x8, .disp = 0 }};
                } else {
                    switch (ret_loc.locs[0]) {
                        .gp_regs => |reg_loc| {

                            const stack_off = reg_manager.allocateStackTyped(call.t);
                            if (reg_loc.count > 1) {
                                for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                                    const reg = ResultLocation {.reg = getIntLoc(@intCast(r)) };
                                    reg.moveToAddrReg(AddrReg {.reg = .x29, .disp = stack_off + @as(isize, @intCast(r))*PTR_SIZE}, PTR_SIZE, reg_manager, results);
                                }
                                results[i] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = stack_off}};
                            } else {
                                results[i] = ResultLocation {.reg = getIntLoc(0) };
                            }

                        },
                        .vf_regs => |reg_loc| {
                            const stack_off = reg_manager.allocateStackTyped(call.t);
                            if (reg_loc.count > 1) {
                                for (reg_loc.start..reg_loc.start+reg_loc.count) |r| {
                                    const reg = ResultLocation {.reg = getFloatLoc(@intCast(r)) };
                                    reg.moveToAddrReg(AddrReg {.reg = .x29, .disp = stack_off + @as(isize, @intCast(r))*PTR_SIZE}, PTR_SIZE, reg_manager, results);
                                }
                                results[i] = ResultLocation {.addr_reg = .{.reg = .x29, .disp = stack_off}};
                            } else {
                                results[i] = ResultLocation {.reg = getFloatLoc(0) };
                            }
                        },
                        else => unreachable,
                    }
                }
            }
        }
    };
};
pub const OutputBuffer = std.ArrayList(u8);
pub fn compileAll(cirs: []Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) Arch.CompileError!void {
    try file.print("{s}", .{switch (os) {
        .linux => builtinTextStart,
        .windows => builtinTextWinMain,
        else => unreachable,
        }});

    // Static Data needed by the program
    var string_data = std.AutoArrayHashMap(Symbol, usize).init(alloc);
    var double_data = std.AutoArrayHashMap(u64, usize).init(alloc);
    var float_data = std.AutoArrayHashMap(u32, usize).init(alloc);
    defer {
        string_data.deinit();
        double_data.deinit();
    }    


    var label_ct: usize = 0;

    const cconv = switch (os) {
        .linux => CallingConvention.CDecl.interface(),
        //.windows => CallingConvention.FastCall.interface(),
        else => @panic("Unsupported OS, only linux and windows is supported"),
    };
    // This creates the entry point of the program
    {
        var entry_insts = [_]Cir.Inst {
            Cir.Inst {.block_start = 0},
            Cir.Inst {.ret_decl = TypePool.void},
            Cir.Inst {.foreign = .{.sym = Lexer.main, .t = TypePool.void_ptr }},
            Cir.Inst {.call = .{.func = 2, .t = TypePool.void, .locs = &.{}, .ts = &.{}, .varadic = false}},
            Cir.Inst {.lit = .{.int = 0}},
            Cir.Inst {.foreign = .{.sym = Lexer.intern("exit"), .t = TypePool.void_ptr }},
            Cir.Inst {.call = .{.func = 5, .t = TypePool.void, .ts = &.{TypePool.int}, .locs = &.{4}, .varadic = false}},
            Cir.Inst {.block_end = 0},
        };
        const entry = switch (os) {
            .linux => "_start",
            .windows => "WinMain",
            else => unreachable,
        };
        const pgm_entry = Cir {.arg_types = &.{}, .insts = &entry_insts, .name = Lexer.intern(entry), .ret_type = TypePool.void };
        // On windows, the start function requires an additional 8 byte of the stack
        // On linux, it doesn't
        const prologue = switch (os) {
            .linux => false,
            .windows => true,
            else => unreachable,
        };
        try compile(pgm_entry, file, &string_data, &double_data, &float_data, &label_ct, cconv, alloc, prologue);

    }
    for (cirs) |cir| {
        try compile(cir, file, &string_data, &double_data, &float_data, &label_ct, cconv, alloc, true);
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
    var double_data_it = double_data.iterator();
    while (double_data_it.next()) |entry| {
        try file.print("\t.d{}:\n\t.double\t{}\n", .{ entry.value_ptr.*, @as(f64, @bitCast(entry.key_ptr.*)) });
    }
    try file.print(".align 4\n", .{});
    var float_data_it = float_data.iterator();
    while (float_data_it.next()) |entry| {
        try file.print("\t.f{}:\n\t.float\t{}\n", .{ entry.value_ptr.*, @as(f32, @bitCast(entry.key_ptr.*)) });
    }
}
pub fn compile(
    self: Cir, 
    file: std.fs.File.Writer, 
    string_data: *std.AutoArrayHashMap(Symbol, usize), 
    double_data: *std.AutoArrayHashMap(u64, usize), 
    float_data: *std.AutoArrayHashMap(u32, usize),
    label_ct: *usize,
    cconv: CallingConvention,
    alloc: std.mem.Allocator,
    prologue: bool) Arch.CompileError!void {
    var function_body_buffer = OutputBuffer.init(alloc);

    const body_writer = function_body_buffer.writer();

    const results = alloc.alloc(ResultLocation, self.insts.len) catch unreachable;
    defer alloc.free(results);


    var reg_manager = RegisterManager.init(cconv, body_writer, alloc);
    defer {
        if (reg_manager.temp_stack.items.len != 0) {
            @panic("not all tempory stack is free");
        }

        file.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)}) catch unreachable;
        if (prologue) {
            file.print("\tstp x29, x30, [sp, -{}]\n", .{alignStack(reg_manager.max_usage + 2*PTR_SIZE)}) catch unreachable;
            file.print("\tmov x29, sp\n", .{}) catch unreachable;
        }
        //log.note("frame usage {}", .{reg_manager.frame_usage});


        file.writeAll(function_body_buffer.items) catch unreachable;
        function_body_buffer.deinit();
        reg_manager.deinit();
    }
    // The stack (and some registers) upon a function call
    //
    // sub rsp, [amount of stack memory need for arguments]
    // mov [rsp+...], arguments
    // jmp foo
    // push x29
    // mov x29, rsp <- rbp for the calle
    // sub rsp, [amount of stack memory]
    //
    // (+ => downwards, - => upwards)
    // -------- <- rsp of the callee
    // callee stack ...
    // -------- <- x29 of the callee
    // x29 of the caller saved (PTR_SIZE)
    // -------- rsp of the caller immediately before and after the call instruction
    // leftmost argument on stack
    // ...
    // rightmost argument on stack
    // -------- rsp of the caller before the call and after the cleanup of the call


    // ctx
    // TODO
    // The current way of this doing this forces us to remember to reset this on entering function body
    // A more resoable way will be to make CIR a per-function thing, instead of per-program or per-file
    // The first instruction of the cir is always block_start
    // the second is always ret_def
    // And the following n instructions are arg_def's, depending on the number of argument to the function



    for (self.insts, 0..) |_, i| {
        reg_manager.debug();
        log.debug("[{}] {}", .{ i, self.insts[i] });
        reg_manager.print("# [{}] {}\n", .{i, self.insts[i]});
        switch (self.insts[i]) {
            .ret => |ret| {
                cconv.epilog(&reg_manager, results, ret.t, i);
            },
            .lit => |lit| {
                switch (lit) {
                    .int => |int| results[i] = ResultLocation{ .int_lit = int },
                    .string => |s| {
                        const kv = string_data.getOrPutValue(s, string_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else string_data.count() - 1;
                        results[i] = ResultLocation{ .string_data = idx };
                    },
                    .double => |f| {
                        const kv = double_data.getOrPutValue(@bitCast(f), double_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else double_data.count() - 1;
                        results[i] = ResultLocation{ .double_data = idx };
                    },
                    .float => |f| {
                        const kv = float_data.getOrPutValue(@bitCast(f), float_data.count()) catch unreachable;
                        const idx = if (kv.found_existing) kv.value_ptr.* else float_data.count() - 1;
                        results[i] = ResultLocation{ .float_data = idx };
                    },
                    .bool => unreachable,
                }
            },
            .var_decl => |var_decl| {
                // TODO explicit operand position
                // const size = typeSize(var_decl);

                // var loc = consumeResult(results, i - 1, &reg_manager);
                // try loc.moveToStackBase(scope_size, size, &reg_manager, results);
                results[i] = ResultLocation.stackBase(reg_manager.allocateStackTyped(var_decl.t));
                // reg_manager.print("mov", args: anytype)
            },
            .var_access => |var_access| {
                const v = switch (self.insts[var_access]) {
                    .arg_decl, .var_decl => |v| v,
                    else => unreachable,
                };
                const loc = results[var_access];
                if (v.auto_deref) {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                    loc.moveToReg(reg, PTR_SIZE, &reg_manager);
                    results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
                } else {
                    results[i] = loc;

                }
            },
            .var_assign => |var_assign| {
                const var_loc = results[var_assign.lhs];
                var expr_loc = results[var_assign.rhs];
                //log.note("expr_loc {}", .{expr_loc});
                switch (var_loc) {
                    .addr_reg => |reg| expr_loc.moveToAddrReg(reg, typeSize(var_assign.t), &reg_manager, results),
                    else => unreachable,
                }
                _ = consumeResult(results, var_assign.lhs, &reg_manager);
                _ = consumeResult(results, var_assign.rhs, &reg_manager);

            },
            .ret_decl => |t| {
                cconv.prolog(self, &reg_manager, results);
                _ = t;
            },
            .arg_decl => |*v| {
                _ = v;
            },
            .foreign => |foreign| {
                results[i] = ResultLocation {.foreign = foreign.sym };

            },
            .call => |call| {
                cconv.makeCall(i, call, &reg_manager, results);
            },
            .add,
            .sub,
            .mul,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                lhs_loc.moveToReg(reg, 8, &reg_manager);

                const op = switch (self.insts[i]) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "imul",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {}, ", .{ op, reg });
                try rhs_loc.print(reg_manager.body_writer, .qword);
                reg_manager.print("\n", .{});

                results[i] = ResultLocation{ .reg = reg };
            },
            .mod => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = reg_manager.getUnusedExclude(null, &.{}, RegisterManager.GpMask).?;

                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{}, RegisterManager.GpMask).?;
                lhs_loc.moveToReg(lhs_reg, PTR_SIZE, &reg_manager);
                rhs_loc.moveToReg(rhs_reg, PTR_SIZE, &reg_manager);
                const quotient_reg = reg_manager.getUnused(null, RegisterManager.GpMask).?;
                reg_manager.print("\tsdiv {}, {}, {}\n", .{quotient_reg, lhs_reg, rhs_reg});
                const res_reg = reg_manager.getUnused(null, RegisterManager.GpMask).?;
                reg_manager.print("\tmsub {}, {}, {}, {}\n", .{res_reg, quotient_reg, rhs_reg, lhs_reg});
                results[i] = ResultLocation{ .reg = res_reg };

            },
            .div => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = reg_manager.getUnusedExclude(null, &.{}, RegisterManager.GpMask).?;

                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &.{}, RegisterManager.GpMask).?;
                lhs_loc.moveToReg(lhs_reg, PTR_SIZE, &reg_manager);
                rhs_loc.moveToReg(rhs_reg, PTR_SIZE, &reg_manager);
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;
                reg_manager.print("\tsdiv {}, {}, {}\n", .{res_reg, lhs_reg, rhs_reg});
                results[i] = ResultLocation{ .reg = res_reg };
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

                lhs_loc.moveToReg(result_reg, 4, &reg_manager);
                rhs_loc.moveToReg(temp_reg, 4, &reg_manager);
                const op = switch (self.insts[i]) {
                    .addf => "addss",
                    .subf => "subss",
                    .mulf => "mulss",
                    .divf => "divss",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {}, {}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .addd,
            .subd,
            .muld,
            .divd,
            => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const result_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const temp_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");

                lhs_loc.moveToReg(result_reg, 8, &reg_manager);
                rhs_loc.moveToReg(temp_reg, 8, &reg_manager);
                const op = switch (self.insts[i]) {
                    .addd => "addsd",
                    .subd => "subsd",
                    .muld => "mulsd",
                    .divd => "divsd",
                    else => unreachable,
                };
                reg_manager.print("\t{s} {}, {}\n", .{ op, result_reg, temp_reg });
                results[i] = ResultLocation{ .reg = result_reg };
            },
            .eq, .lt, .gt => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = lhs_loc.moveToGpReg(PTR_SIZE, i, &reg_manager);
                const rhs_reg = rhs_loc.moveToGpReg(PTR_SIZE, null, &reg_manager);
                reg_manager.print("\tcmp {}, {}\n", .{lhs_reg, rhs_reg});
                reg_manager.print("\tcset {}, {s}\n", .{lhs_reg, @tagName(self.insts[i])});
                results[i] = ResultLocation{ .reg = lhs_reg };
            },
            .eqf, .ltf, .gtf => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = lhs_loc.moveToGpReg(PTR_SIZE, i, &reg_manager);
                const rhs_reg = rhs_loc.moveToGpReg(PTR_SIZE, null, &reg_manager);
                reg_manager.print("\tfcmp {}, {}\n", .{lhs_reg.lower32(), rhs_reg.lower32()});
                reg_manager.print("\tcset {}, {s}\n", .{lhs_reg, @tagName(self.insts[i])});
                results[i] = ResultLocation{ .reg = lhs_reg };
            },
            .eqd, .ltd, .gtd => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const lhs_reg = lhs_loc.moveToGpReg(PTR_SIZE, i, &reg_manager);
                const rhs_reg = rhs_loc.moveToGpReg(PTR_SIZE, null, &reg_manager);
                reg_manager.print("\tfcmp {}, {}\n", .{lhs_reg, rhs_reg});
                reg_manager.print("\tcset {}, {s}\n", .{lhs_reg, @tagName(self.insts[i])});
                results[i] = ResultLocation{ .reg = lhs_reg };
            },
            .not => |rhs| {
                const rhs_loc = consumeResult(results, rhs, &reg_manager);
                const reg = rhs_loc.moveToGpReg(typeSize(TypePool.@"bool"), i, &reg_manager);
                reg_manager.print("\teor {}, #1\n", .{reg});
                results[i] = ResultLocation {.reg = reg};
            },
            .i2d => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                loc.moveToReg(temp_int_reg, typeSize(TypePool.double), &reg_manager);
                reg_manager.print("\tcvtsi2sd {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, typeSize(TypePool.int), &reg_manager);
                reg_manager.print("\tcvtsd2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .i2f => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_int_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                loc.moveToReg(temp_int_reg, typeSize(TypePool.float), &reg_manager);
                reg_manager.print("\tcvtsi2ss {}, {}\n", .{ res_reg, temp_int_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2i => {

                // CVTPD2PI

                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, typeSize(TypePool.int), &reg_manager);
                reg_manager.print("\tcvtss2si {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .f2d => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, typeSize(TypePool.float), &reg_manager);
                reg_manager.print("\tcvtss2sd {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .d2f => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const temp_float_reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const res_reg = reg_manager.getUnused(i, RegisterManager.FloatMask) orelse @panic("TODO");
                loc.moveToReg(temp_float_reg, typeSize(TypePool.double), &reg_manager);
                reg_manager.print("\tcvtsd2ss {}, {}\n", .{ res_reg, temp_float_reg });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .if_start => |if_start| {
                defer label_ct.* += 1;
                const loc = consumeResult(results, if_start.expr, &reg_manager);
                results[i] = ResultLocation{ .local_lable = label_ct.* };

                const jump = switch (self.insts[if_start.expr]) {
                    .eq, .eqf, .eqd => "jne",
                    .lt, .ltf, .ltd => "jae",
                    .gt, .gtf, .gtd => "jbe",
                    else => blk: {
                        const temp_reg = reg_manager.getUnused(null, RegisterManager.GpMask) orelse @panic("TODO");
                        loc.moveToReg(temp_reg, typeSize(TypePool.bool), &reg_manager);
                        reg_manager.print("\tcmp {}, 0\n", .{temp_reg});
                        break :blk "je";
                    },
                };
                reg_manager.print("\t{s} .L{}\n", .{ jump, label_ct.* });
            },
            .else_start => |if_start| {
                reg_manager.print("\tjmp .LE{}\n", .{results[self.insts[if_start].if_start.first_if].local_lable});
                reg_manager.print(".L{}:\n", .{results[if_start].local_lable});
            },
            .if_end => |start| {
                const label = results[start].local_lable;
                reg_manager.print(".LE{}:\n", .{label});
            },
            .while_start => {
                defer label_ct.* += 1;
                results[i] = ResultLocation{ .local_lable = label_ct.* };

                reg_manager.print(".W{}:\n", .{label_ct.*});
            },
            .while_jmp => |while_start| {
                const label = results[while_start].local_lable;
                reg_manager.print("\tjmp .W{}\n", .{label});
            },
            .block_start => |_| {
                reg_manager.enterScope();
            },
            .block_end => |start| {
                _ = start;
                reg_manager.exitScope();
            },
            .addr_of => {
                // FIXME: the whole `consumeResults` mechanic is rigged...
                const loc = consumeResult(results, i - 1, &reg_manager);
                if (loc == .addr_reg and loc.addr_reg.disp == 0 and loc.addr_reg.mul == null) {
                    results[i] = ResultLocation {.reg = loc.addr_reg.reg };
                } else {
                    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                    loc.moveAddrToReg(reg, &reg_manager);
                    results[i] = ResultLocation {.reg = reg};

                }
            },
            .deref => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                loc.moveToReg(reg, PTR_SIZE, &reg_manager);

                results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
            },
            .field => |field| {
                switch (TypePool.lookup(field.t)) {
                    inline .tuple, .named => |tuple| results[i] = ResultLocation {.int_lit = @intCast(tupleOffset(tuple.els, field.off))},
                    else => unreachable
                }
            },
            .getelementptr => |getelementptr| {
                const base = consumeResult(results, getelementptr.base, &reg_manager).moveToGpReg(PTR_SIZE, i, &reg_manager);
                // both the instruction responsible for `mul_imm` and `disp` should produce a int_lit
                const disp = if (getelementptr.disp) |disp| consumeResult(results, disp, &reg_manager).int_lit else 0;
                if (getelementptr.mul) |mul| {
                    const mul_imm = consumeResult(results, mul.imm, &reg_manager).int_lit;
                    const mul_reg = consumeResult(results, mul.reg, &reg_manager).moveToGpReg(PTR_SIZE, i, &reg_manager);
                    if (Word.fromSize(@intCast(mul_imm))) |word| {
                        results[i] = ResultLocation {.addr_reg = 
                            .{
                                .reg = base, 
                                .disp = disp, 
                                .mul = .{mul_reg, word}, 
                            }
                        };
                    } else {
                        reg_manager.print("\timul {}, {}, {}\n", .{mul_reg, mul_reg, mul_imm});
                        results[i] = ResultLocation {.addr_reg = 
                            .{
                                .reg = base, 
                                .mul = .{mul_reg, Word.byte},
                                .disp = disp,
                            }
                        };
                    }
                } else {
                    results[i] = ResultLocation {.addr_reg = 
                        .{
                            .reg = base, 
                            .mul =  null,
                            .disp = disp,
                        }
                    };
                }
            },
            .type_size => |t| {
                results[i] = ResultLocation {.int_lit = @intCast(typeSize(t))};
            },
            .array_len => |t| {
                _ = consumeResult(results, i - 1, &reg_manager);
                results[i] = ResultLocation {.int_lit = @intCast(TypePool.lookup(t).array.size)};
            },
            .array_init => |array_init| {
                blk: switch (array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
                        const reg = reg_manager.getUnused(i, RegisterManager.GpMask).?;
                        results[ptr].moveToReg(reg, PTR_SIZE, &reg_manager);
                        results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
                    },
                    .loc => |loc| results[i] = results[loc],
                    .none => {
                        const stack_pos = reg_manager.allocateStackTyped(array_init.t);
                        results[i] = ResultLocation.stackBase(stack_pos);

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
                const loc = consumeResult(results, i - 1, &reg_manager);
                switch (res_loc) {
                    .addr_reg => |addr_reg| loc.moveToAddrReg(addr_reg, sub_size, &reg_manager, results),
                    else => unreachable
                }
            },
            .array_init_end => |array_init| {
                blk: switch (self.insts[array_init].array_init.res_inst) {
                    .ptr => |ptr| {
                        if (results[ptr] == .uninit) {
                            continue :blk .none;
                        }
                        _ = consumeResult(results, array_init, &reg_manager);
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

}


const builtinData =
    \\aligned:
    \\  .byte 0
    \\
        ;
const winPrintf = 
        \\printf:
        \\push x29
 \\.seh_pushreg x29
 \\push rbx
 \\.seh_pushreg rbx
 \\sub rsp, 56
 \\.seh_stackalloc 56
 \\lea x29, 48[rsp]
 \\.seh_setframe x29, 48
 \\.seh_endprologue
 \\mov QWORD PTR 32[x29], rcx
 \\mov QWORD PTR 40[x29], rdx
 \\mov QWORD PTR 48[x29], r8
 \\mov QWORD PTR 56[x29], r9
 \\lea rax, 40[x29]
 \\mov QWORD PTR -16[x29], rax
 \\mov rbx, QWORD PTR -16[x29]
 \\mov ecx, 1
 \\mov rax, QWORD PTR __imp___acrt_iob_func[rip]
 \\call rax
 \\mov rcx, rax
 \\mov rax, QWORD PTR 32[x29]
 \\mov r8, rbx
 \\mov rdx, rax
 \\call __mingw_vfprintf
 \\mov DWORD PTR -4[x29], eax
 \\mov eax, DWORD PTR -4[x29]
 \\add rsp, 56
 \\pop rbx
 \\pop x29
 \\ret
 \\.seh_endproc
 \\.section .rdata,"dr

 ;

 const builtinTextStart =
    \\.text
    \\.globl         _start
    \\
        ;
const builtinTextWinMain =
    \\.intel_syntax noprefix
    \\.text
    \\.globl         WinMain
    \\
        ;

const fnStart = "\tpush x29\n\tmov x29, rsp\n";
