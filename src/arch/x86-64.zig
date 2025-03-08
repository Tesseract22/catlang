const std = @import("std");
const TypePool = @import("../type.zig");
const Cir = @import("../cir.zig");
const log = @import("../log.zig");
const InternPool = @import("../intern_pool.zig");
const Symbol = InternPool.Symbol;
const Lexer = @import("../lexer.zig");
const TypeCheck = @import("../typecheck.zig");

const Type = TypePool.Type;
const TypeFull = TypePool.TypeFull;

const PTR_SIZE = 8;
const STACK_ALIGNMENT = 16;


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
    pub const Lower32 = enum {
        eax,
        ebx,
        ecx,
        edx,
        ebp,
        esp,
        esi,
        edi,
        r8d,
        r9d,
        r10d,
        r11d,
        r12d,
        r13d,
        r14d,
        r15d,
        xmm0,
        xmm1,
        xmm2,
        xmm3,
        xmm4,
        xmm5,
        xmm6,
        xmm7,
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
    pub fn lower32(self: Register) Lower32 {
        return @enumFromInt(@intFromEnum(self));
    }
    pub fn adapatSize(self: Register, word: Word) []const u8 {
        return switch (word) {
            .byte => @tagName(self.lower8()),
            .dword => @tagName(self.lower32()),
            .qword => @tagName(self),
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
    const ScopeStack = std.ArrayList(usize);
    const count = @typeInfo(Register).@"enum".fields.len;
    pub const Regs = std.bit_set.ArrayBitSet(u8, count);
    pub const GpRegs = [_]Register{
        .rax, .rcx, .rdx, .rbx, .rsi, .rdi, .r8, .r9, .r10, .r11, .r12, .r13, .r14, .r15,
    };
    // This actually depends on the calling convention
    pub const FlaotRegs = [_]Register{
        .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7,
    };
    pub const GpMask = cherryPick(&GpRegs);
    pub const FloatMask = cherryPick(&FlaotRegs);
    // stack manipulation functions -----------------------------------------------------------------
    pub fn enterScope(self: *RegisterManager) void {
        self.scope_stack.append(0) catch unreachable;
    }
    pub fn exitScope(self: *RegisterManager) void {
        const size = self.scope_stack.pop();
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
    // One must use `` to get the ACTUAL stack offset
    pub fn allocateStackTemp(self: *RegisterManager, size: usize, alignment: usize) StackTop {
        const new_size = alignAlloc2(self.temp_usage, size, @max(alignment, STACK_ALIGNMENT));
        self.temp_stack.append(new_size - self.temp_usage) catch unreachable;
        self.print("\tsub rsp, {}\n", .{new_size - self.temp_usage});
        self.temp_usage = new_size;
        return .{.off = self.temp_usage };
    }
    pub fn allocateStackTempTyped(self: *RegisterManager, t: Type) StackTop {
        return self.allocateStackTemp(typeSize(t), alignOf(t));
    }
    pub fn freeStackTemp(self: *RegisterManager) void {
        const size = self.temp_stack.pop();
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
            .unused = Regs.initFull(), 
            .insts = undefined, 
            .dirty = dirty, 
            .cconv = cconv, 
            .body_writer = body_writer,
            .frame_usage = 0,
            .max_usage = 0,
            .scope_stack = ScopeStack.init(alloc),
            .temp_usage = 0,
            .temp_stack = ScopeStack.init(alloc),
            .dirty_spilled = std.AutoHashMap(Register, isize).init(alloc),
        };
    }
    pub fn deinit(self: *RegisterManager) void {
        self.scope_stack.deinit();
        self.temp_stack.deinit();
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
        self.print("\tmov [rbp + {}], {}\n", .{ off, reg });
    }
    pub fn restoreDirty(self: *RegisterManager, reg: Register) void {
        const off = self.dirty_spilled.get(reg) orelse @panic("restoring a register that is not dirty");
        self.print("\tmov {}, [rbp + {}]\n", .{ reg, off });
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
    pub fn getFloatArgLoc(self: *RegisterManager, t_pos: u8) Register {
        _ = self;
        if (t_pos > 8) @panic("Too much float argument");
        return @enumFromInt(@intFromEnum(Register.xmm0) + t_pos);
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
    int_lit: isize,
    string_data: usize,
    float_data: usize,
    double_data: usize,
    local_lable: usize,
    array: []usize,
    uninit,

    pub fn stackBase(off: isize) ResultLocation {
        return .{.addr_reg = .{.reg = .rbp, .disp = off, }};
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
        var clone = self.addr_reg;
        clone.disp += off;
        return .{.addr_reg = clone };
    }

    pub fn moveAddrToReg(self: ResultLocation, reg: Register, reg_manager: *RegisterManager) void {
        reg_manager.print("\tlea {}, ", .{reg});
        self.print(reg_manager.body_writer, .qword) catch unreachable;
        reg_manager.print("\n", .{});
    }
    pub fn moveToGpReg(self: ResultLocation, size: usize, inst: usize, reg_manager: *RegisterManager) Register {
        switch (self) {
            .reg => |reg| {
                if (RegisterManager.GpMask.isSet(@intFromEnum(reg))) {
                    reg_manager.markUsed(reg, inst);
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
                    mov = "movq";
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
        return self.moveToAddrReg(AddrReg {.reg = .rbp, .disp = off}, size, reg_man, results);

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

    pub fn print(self: ResultLocation, writer: OutputBuffer.Writer, word: Word) !void {

        switch (self) {
            .reg => |reg| try writer.print("{s}", .{reg.adapatSize(word)}),
            .addr_reg => |reg| 
                try reg.print(writer, word),
            //.stack_base => |off| try writer.print("{s} PTR [rbp + {}]", .{@tagName(word), off}),
            //.stack_top => |stack_top| try writer.print("{s} PTR [rsp + {}]", .{@tagName(word), stack_top.off}),
            .int_lit => |i| try writer.print("{}", .{i}),
            .string_data => |s| try writer.print(".s{}[rip]", .{s}),
            .float_data => |f| try writer.print(".f{}[rip]", .{f}),
            .double_data => |f| try writer.print(".d{}[rip]", .{f}),
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

        inline .float_data, .double_data, .string_data, .int_lit, .local_lable, .array, .uninit => |_| {},
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
                          calleeSavedPos: *const fn (reg: Register) u8,
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

    const Class = enum { // A simplified version of the x86-64 System V ABI classification algorithms
        int, // int
        sse, // float
             //sse_up, This is used when passing vector argument (_m256,_float128,etc.), but there is no such thing in our language
        none, // intialized with this
        mem, // passed via allocating memory on stack
    };
    pub const CDecl = struct {
        pub const CallerSaveRegs = [_]Register{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 };
        pub const CalleeSaveRegs = [_]Register{ .rbx, .r12, .r13, .r14, .r15 };
        pub const CallerSaveMask = RegisterManager.cherryPick(&CallerSaveRegs);
        pub const CalleeSaveMask = RegisterManager.cherryPick(&CalleeSaveRegs);

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

        // The Classification Algorithm
        // Each eightbyte (or 64 bits, becaus 64 bits fit exactly into a normal register) is classified individually, then merge
        const MAX_CLASS = PTR_SIZE * 8; // Anything more tan 
        const ClassResult = std.BoundedArray(Class, MAX_CLASS);

        pub fn interface() CallingConvention {
            return .{.vtable = .{.call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog, .calleeSavedPos = @This().calleeSavePos}, .callee_saved = CalleeSaveMask};
        }
        pub fn getArgLoc(self: *RegisterManager, t_pos: u8, class: Class) ?Register {
            const reg: Register = switch (class) {
                .sse => self.getFloatArgLoc(t_pos),
                .int, => switch (t_pos) {
                    0 => .rdi,
                    1 => .rsi,
                    2 => .rdx,
                    3 => .rcx,
                    4 => .r8,
                    5 => .r9,
                    else => @panic("Too much int argument"),
                },
                .none => @panic("unexpected class \"none\""),
                .mem => return null,
            };
            if (self.isUsed(reg)) {
                log.err("{} already in used", .{reg});
                @panic("TODO: register already inused, save it somewhere");
            }
            return reg;
        }
        pub fn getRetLocInt(self: *RegisterManager, t_pos: u8) Register {
            _ = self;
            return switch (t_pos) {
                0 => .rax,
                1 => .rdx,
                else => unreachable,
            };
        }
        pub fn getRetLocSse(self: *RegisterManager, t_pos: u8) Register {
            _ = self;
            return switch (t_pos) {
                0 => .xmm0,
                1 => .xmm1,
                else => unreachable,
            };
        }
        fn mergeClass(a: Class, b: Class) Class {
            if (a == .none) return b;
            if (b == .none) return a;
            if (a == b) return a;
            if (a == .mem or b == .mem) return .mem;
            if (a == .int or b == .int) return .int;
            return .sse;
        }
        fn classifyType(t: Type) ClassResult {
            const size = typeSize(t);
            var res = ClassResult.init(0) catch unreachable;
            // If the the size exceed 2 eightbytes, and the any of then IS NOT sse or sseup, it should be passed via memory.
            // However, we dont have sseup at all
            // So if the size >= 2, we can conclude immediately that it is .mem
            // We leave the "size > 8" so you know what is going on
            if (size > 2 * PTR_SIZE or size > MAX_CLASS) { 
                res.append(.mem) catch unreachable;
                return res;
            }
            classifyTypeRecur(t, &res, 0);
            const slice = res.constSlice();
            for (0..res.len) |i| {
                switch (slice[i]) {
                    .none => break,
                    .mem => {
                        res.resize(1) catch unreachable;
                        res.set(0, .mem);
                        break;
                    },
                    .sse, .int => {},
                }
            }
            return res;

        }
        // Classify each eightbyte of this data structure. result should be initialized to be filled with .no_class, which will then be populated by this function
        // The size of the data structure is assumend to be <= eight eightbytes
        fn classifyTypeRecur(t: Type, result: *ClassResult, byte_off: u8) void {
            //const size = typeSize(t);
            const class_idx = byte_off / 8;
            if (result.len <= class_idx) result.append(.none) catch unreachable;
            if (t == TypePool.int or t == TypePool.@"bool" or t == TypePool.char) {
                result.set(class_idx, mergeClass(.int, result.get(class_idx)));
                return;
            }
            if (t == TypePool.double or t == TypePool.float) {
                result.set(class_idx, mergeClass(.sse, result.get(class_idx)));
                return;
            }
            const t_full = TypePool.lookup(t);
            switch (t_full) {
                .ptr, .function => {
                    result.set(class_idx, mergeClass(.int, result.get(class_idx)));
                },
                .array => |array| {
                    var field_off: u8 = 0;
                    const sub_size = typeSize(array.el);
                    for (0..array.size) |_| {
                        classifyTypeRecur(array.el, result, byte_off + field_off);
                        field_off += @intCast(sub_size);
                    }
                },
                inline .tuple, .named => |tuple| {
                    var field_off: u8 = 0;
                    for (tuple.els) |sub_t| {
                        const sub_align = alignOf(sub_t);
                        field_off = @intCast((field_off + sub_align - 1) / sub_align * sub_align);
                        classifyTypeRecur(sub_t, result, byte_off + field_off);
                        const sub_size = typeSize(sub_t);
                        field_off += @intCast(sub_size);
                    } 
                },
                else => {
                    log.err("Unreachable Type {}", .{t_full});
                    unreachable;
                },
            }
        } 
        pub fn prolog(
            self: Cir, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation
        ) void {
            var int_ct: u8 = 0;
            var float_ct: u8 = 0;
            // basic setup
            //reg_manager.print("{s}:\n", .{Lexer.string_pool.lookup(self.name)});
            //reg_manager.print("\tpush rbp\n\tmov rbp, rsp\n", .{});
            //reg_manager.print("\tsub rsp, {}\n", .{frame_size.*});
            reg_manager.markCleanAll();
            reg_manager.markUnusedAll();

            // allocate return
            // Index 1 of insts is always the ret_decl
            if (self.ret_type != TypePool.@"void") {
                const ret_classes = CDecl.classifyType(self.ret_type);
                if (ret_classes.len > 2) @panic("Type larger than 2 eightbytes should be passed via stack");
                if (ret_classes.get(0) == .mem) {
                    const reg = CDecl.getArgLoc(reg_manager, 0, .int).?;
                    const stack_pos = reg_manager.allocateStack(PTR_SIZE, PTR_SIZE);
                    reg_manager.print("\tmov [rbp + {}], {}\n", .{ stack_pos, reg });
                    results[1] = ResultLocation.stackBase(stack_pos);   
                    int_ct += 1;
                } else {
                    results[1] = ResultLocation.uninit;
                }
            }

            for (self.arg_types, 0..) |t, arg_pos| {
                // generate instruction for all the arguments
                const arg_classes = CDecl.classifyType(t);
                // For argumennt already passed via stack, there is no need to allocate another space on stack for it
                const off = if (arg_classes.get(0) != .mem) blk: {
                    break :blk reg_manager.allocateStackTyped(t);
                } else blk: {
                    break :blk undefined;
                };
                // The offset from the stack base to next argument on the stack (ONLY sensible to the argument that ARE passed via the stack)
                // Starts with PTR_SIZE because "push rbp"
                var arg_stackbase_off: usize = PTR_SIZE * 2;
                const arg_size = typeSize(t);
                // TODO: this should be done in reverse order
                for (arg_classes.slice(), 0..) |class, eightbyte| {
                    const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
                    switch (class) {
                        .int => {
                            const reg = getArgLoc(reg_manager, int_ct, class).?;
                            int_ct += 1;
                            const loc = ResultLocation {.reg = reg };
                            loc.moveToStackBase(class_off, @min(arg_size, PTR_SIZE), reg_manager, results);
                            results[2 + arg_pos] = ResultLocation.stackBase(off);
                        },
                        .sse => {
                            const reg = getArgLoc(reg_manager, float_ct, class).?;
                            float_ct += 1;
                            const loc = ResultLocation {.reg = reg };
                            loc.moveToStackBase(class_off, @min(arg_size, PTR_SIZE), reg_manager, results);
                            results[2 + arg_pos] = ResultLocation.stackBase(off);
                        },
                        .mem => {
                            const sub_size = typeSize(t);
                            const sub_align = alignOf(t);
                            arg_stackbase_off = (arg_stackbase_off + sub_align - 1) / sub_align * sub_align;
                            results[2 + arg_pos] = ResultLocation.stackBase(@intCast(arg_stackbase_off));
                            arg_stackbase_off += sub_size;

                        },
                .none => unreachable,
                    }
                }
            }
        }
        pub fn epilog(
            reg_manager: *RegisterManager, 
            results: []ResultLocation, 
            ret_t: Type,
            i: usize) void {
            const ret_size = typeSize(ret_t);
            if (ret_t != TypePool.@"void") {
                const loc = consumeResult(results, i - 1, reg_manager);
                const ret_classes = classifyType(ret_t);
                for (ret_classes.constSlice(), 0..) |class, class_pos| {
                    switch (class) {
                        .int => {
                            const reg = getRetLocInt(reg_manager, @intCast(class_pos));
                            if (reg_manager.isUsed(reg)) unreachable;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, PTR_SIZE, reg_manager);
                            } else {
                                loc.moveToReg(reg, PTR_SIZE, reg_manager);
                            }
                        },
                        .sse => {
                            const reg = getRetLocSse(reg_manager, @intCast(class_pos));
                            if (reg_manager.isUsed(reg)) unreachable;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, PTR_SIZE, reg_manager);
                            } else {
                                loc.moveToReg(reg, PTR_SIZE, reg_manager);
                            }
                        },
                        .mem => {
                            const reg = getRetLocInt(reg_manager, 0);
                            // Assume that ret_loc is always the first location on the stack
                            const ret_loc = results[1];
                            ret_loc.moveToReg(reg, PTR_SIZE, reg_manager);
                            loc.moveToAddrReg(AddrReg {.reg = reg, .disp = 0}, ret_size, reg_manager, results);

                        },
                            .none => unreachable,
                    }
                }
            }

            var it = reg_manager.dirty.intersectWith(CalleeSaveMask).iterator(.{});
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);
                reg_manager.restoreDirty(reg);
            }
            reg_manager.print("\tleave\n", .{});
            reg_manager.print("\tret\n", .{});

        }
        pub fn makeCall(
            i: usize,
            call: Cir.Inst.Call, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void {
            // Save the caller saved (volatile) registers. We save everything before we handle any of the arguments. 
            // TODO: This works, but is not optimal
            const caller_used = CallerSaveMask.differenceWith(reg_manager.unused);
            const callee_unused = CalleeSaveMask.intersectWith(reg_manager.unused);
            var it = caller_used.iterator(.{ .kind = .set });
            while (it.next()) |regi| {
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
            // keep track of the number of integer parameter. This is used to determine the which integer register should the next integer parameter uses 
            var call_int_ct: u8 = 0;
            // keep track of the number of float parameter. In addition to the purpose of call_int_ct, this is also needed because the number of float needs to be passed in rax
            var call_float_ct: u8 = 0;

            if (call.t != TypePool.@"void") {
                const ret_classes = classifyType(call.t).constSlice();
                // If the class of the return type is mem, a pointer to the stack is passed to %rdi as if it is the first argument
                // On return, %rax will contain the address that has been passed in by the calledr in %rdi
                if (ret_classes[0] == .mem) {
                    // Here, we allocate it inside the stack frame, instead of allocating on the stack top
                    // TODO: stack top
                    call_int_ct += 1;
                    const stack_pos = reg_manager.allocateStackTyped(call.t);
                    const reg = getArgLoc(reg_manager, 0, .int).?;
                    reg_manager.print("\tlea {}, [rbp + {}]\n", .{reg, stack_pos});

                }
            }

            // Move each argument operand into the right register
            var arg_stack_allocation: usize = 0;
            // TODO: this should be done in reverse order
            //
            //
            for (call.args) |arg| {
                const loc = consumeResult(results, arg.i, reg_manager);
                const arg_classes = classifyType(arg.t);
                //const arg_t_full = TypePool.lookup(arg.t);
                //log.debug("arg {}", .{arg_t_full});
                //for (arg_classes.constSlice()) |class| {
                //    log.debug("class {}", .{class});
                //}
                // Needs to pass this thing by pushing it onto the stack
                // Notice in the fastcall calling convention, we needs to pass it as a reference
                if (arg_classes.get(0) == .mem) {
                    _ = reg_manager.allocateStackTempTyped(arg.t);
                    //const reg = reg_manager.getUnused(i, RegisterManager.GpRegs);
                    //reg_manager.markUnused(reg);
                    loc.moveToAddrReg(.{.reg = .rsp, .disp = 0}, typeSize(arg.t), reg_manager, results);
                    arg_stack_allocation += 1;

                }
                for (arg_classes.slice(), 0..) |class, class_pos| {
                    switch (class) {
                        .int => {
                            log.note("arg {}", .{loc});
                            const reg = getArgLoc(reg_manager, call_int_ct, .int).?;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, PTR_SIZE, reg_manager);
                            } else {
                                loc.moveToReg(reg, PTR_SIZE, reg_manager);
                            }
                            call_int_ct += 1;
                        },
                        .sse => {
                            const reg = getArgLoc(reg_manager, call_float_ct, .sse).?;
                            if (loc.isMem()) {
                                loc.offsetByByte(@intCast(class_pos * PTR_SIZE)).moveToReg(reg, PTR_SIZE, reg_manager);
                            } else {
                                loc.moveToReg(reg, PTR_SIZE, reg_manager);
                            }
                            call_float_ct += 1;
                        },
                        .mem => {},
                        .none => unreachable,
                    }
                }
            }




            reg_manager.print("\tmov rax, {}\n", .{call_float_ct});
            reg_manager.print("\tcall {s}\n", .{Lexer.lookup(call.name)});
            for (0..arg_stack_allocation) |_| reg_manager.freeStackTemp();
            // ResultLocation
            if (call.t != TypePool.@"void") {
                const ret_classes = classifyType(call.t).constSlice();
                // This is temporary solution:
                // In CDecl calling convention, some aggregate types can be return througg MULTIPLE registers
                // There is currently no way for us to represent this in `ResultLocation`
                // Therefore, we allocate a location on stack for it
                if (ret_classes.len > 1) {
                    //const realloc = alignStack(typeSize(call.t));
                    //self.insts[curr_block].block_start += realloc;
                    //frame_size.* += realloc;
                    //reg_manager.print("\tsub rsp, {}\n", .{realloc});
                    const ret_stack = reg_manager.allocateStackTyped(call.t);
                    for (ret_classes, 0..) |class, pos| {
                        switch (class) {
                            .int => {
                                reg_manager.print("\tmov qword PTR [rbp + {}], {}\n", .{ret_stack + @as(isize, @intCast(pos * PTR_SIZE)), getRetLocInt(reg_manager, @intCast(pos))});
                            },
                            .sse => {
                                reg_manager.print("\tmovsd qword PTR [rbp + {}], {}\n", .{ret_stack + @as(isize, @intCast(pos * PTR_SIZE)), getRetLocSse(reg_manager, @intCast(pos))});
                            },
                            .mem, .none => unreachable,
                        }
                    }
                    results[i] = ResultLocation.stackBase(ret_stack);
                } else {
                    switch (ret_classes[0]) {
                        .int => {
                            reg_manager.markUsed(.rax, i);
                            results[i] = ResultLocation{ .reg = .rax };
                        },
                        .sse => {
                            reg_manager.markUsed(.xmm0, i);
                            results[i] = ResultLocation{ .reg = .xmm0 };
                        },
                        // In our current implementation, we allocate this memory on a compile time known position on the stack
                        // However, this is NOT part of the spec other implemtation could allocate it anywhere
                        // So, we CANNNOT assume it is on thbe stack
                        .mem => {
                            reg_manager.markUsed(.rax, i);
                            results[i] = ResultLocation {.addr_reg = .{.reg = .rax, .disp = 0}};
                        },
                        .none => unreachable,
                    }
                }
            }


        }
    };
    // https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170
    pub const FastCall = struct {
        pub const CallerSaveRegs = [_]Register{ .rax, .rcx, .rdx, .r8, .r9, .r10, .r11 }; // TODO: save xmm reg?
        pub const CalleeSaveRegs = [_]Register{ .rdi, .rsi, .rbx, .r12, .r13, .r14, .r15  };
        pub const CallerSaveMask = RegisterManager.cherryPick(&CallerSaveRegs);
        pub const CalleeSaveMask = RegisterManager.cherryPick(&CalleeSaveRegs);
        pub fn calleeSavePos(self: Register) u8 {
            return switch (self) {
                .rdi => 0,
                .rsi => 1,
                .rbx => 2,
                .r12 => 3,
                .r13 => 4,
                .r14 => 5,
                .r15 => 6,
                else => unreachable,
            };
        }
        pub fn interface() CallingConvention {
            return .{.vtable = .{.call = @This().makeCall, .prolog = @This().prolog, .epilog = @This().epilog, .calleeSavedPos = @This().calleeSavePos }, .callee_saved = CalleeSaveMask};
        }
        // Unlike the cdecl calling convention, anything that exceeds 8 byte is always passed through mem. Therefore one arg can only have one class.
        pub fn classifyType(t: Type) Class {
            if (t == TypePool.int or t == TypePool.@"bool" or t == TypePool.char) {
                return .int;
            }
            if (t == TypePool.double or t == TypePool.float) {
                return .sse;
            }
            const t_size = typeSize(t);
            if (t_size > 8) return .mem;
            const t_full = TypePool.lookup(t);
            switch (t_full) {
                .ptr, .function => {
                    return .int;
                },
                .array => |array| {
                    _ = array;
                    if (t_size == 1 or t_size == 2 or t_size == 4 or t_size == 8) return .int;
                    return .mem;
                },
                inline .tuple, .named => |tuple| {
                    _ = tuple;
                    if (t_size == 1 or t_size == 2 or t_size == 4 or t_size == 8) return .int;
                    return .mem;
                },
                else => {
                    log.err("Unreachable Type {}", .{t_full});
                    unreachable;
                },

            }
        }
        pub fn getArgLoc(self: *RegisterManager, t_pos: u8, class: Class) ?Register {
            const reg: Register = switch (class) {
                .sse => self.getFloatArgLoc(t_pos),
                .int, => switch (t_pos) {
                    0 => .rcx,
                    1 => .rdx,
                    2 => .r8,
                    3 => .r9,
                    else => @panic("Too much int argument"),
                },
                .none => @panic("unexpected class \"none\""),
                .mem => return null,
            };
            if (self.isUsed(reg)) {
                log.err("{} already in used", .{reg});
                @panic("Unreachable: register already inused, save it somewhere");
            }
            return reg;
        }
        pub fn getRetLocInt(self: *RegisterManager) Register {
            _ = self;
            return .rax;
        }
        pub fn getRetLocSse(self: *RegisterManager) Register {
            _ = self;
            return .xmm0;
        }
        pub fn prolog(
            self: Cir, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation
        ) void {
            var int_ct: u8 = 0;
            var float_ct: u8 = 0;

            reg_manager.markCleanAll();
            reg_manager.markUnusedAll();

            // allocate return
            // Index 1 of insts is always the ret_decl
            if (self.ret_type != TypePool.@"void") {
                const ret_class = classifyType(self.ret_type);
                if (ret_class == .mem) {
                    const reg = CDecl.getArgLoc(reg_manager, 0, .int).?;
                    const stack_pos = reg_manager.allocateStack(PTR_SIZE, PTR_SIZE);
                    reg_manager.print("\tmov [rbp + {}], {}\n", .{ stack_pos, reg });
                    results[1] = ResultLocation.stackBase(stack_pos);   
                    int_ct += 1;
                } else {
                    results[1] = ResultLocation.uninit;
                }
            }

            for (self.arg_types, 0..) |t, arg_pos| {
                // generate instruction for all the arguments
                const arg_class = classifyType(t);
                if (int_ct + float_ct >= 4) @panic("TODO");
                // For argumennt already passed via stack, there is no need to allocate another space on stack for it
                // The offset from the stack base to next argument on the stack (ONLY sensible to the argument that ARE passed via the stack)
                // Starts with PTR_SIZE because "push rbp"
                //var arg_stackbase_off: usize = PTR_SIZE * 2;
                // TODO: this should be done in reverse order
                //const class_off = off + @as(isize, @intCast(eightbyte * PTR_SIZE));
                switch (arg_class) {
                    .int => {
                        const off = reg_manager.allocateStackTyped(t);
                        const reg = getArgLoc(reg_manager, int_ct, arg_class).?;
                        int_ct += 1;
                        const loc = ResultLocation {.reg = reg};
                        loc.moveToStackBase(off, typeSize(t), reg_manager, results);
                        results[2 + arg_pos] = ResultLocation.stackBase(off);
                    },
                    .sse => {
                        const off = reg_manager.allocateStackTyped(t);
                        const reg = getArgLoc(reg_manager, float_ct, arg_class).?;
                        float_ct += 1;
                        const loc = ResultLocation {.reg = reg};
                        loc.moveToStackBase(off, typeSize(t), reg_manager, results);

                        results[2 + arg_pos] = ResultLocation.stackBase(off);
                    },
                    .mem => {
                        @panic("TODO");
                        //const reg = getArgLoc(reg_manager, int_ct, .int).?;
                        //reg_manager.markUsed(reg, 2 + arg_pos);
                        //results[2 + arg_pos] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0 }};

                    },

                .none => unreachable,
                }
            }
        }
        pub fn epilog(
            reg_manager: *RegisterManager, 
            results: []ResultLocation, 
            ret_t: Type,
            i: usize) void {
            const ret_size = typeSize(ret_t);
            if (ret_t != TypePool.@"void") {
                const loc = consumeResult(results, i - 1, reg_manager);
                const ret_class = classifyType(ret_t);
                switch (ret_class) {
                    .int => {
                        const reg = getRetLocInt(reg_manager);
                        if (reg_manager.isUsed(reg)) unreachable;
                        reg_manager.markUsed(reg, i);
                        //log.debug("loc {}", .{loc});
                        loc.moveToReg(reg, ret_size, reg_manager);
                        reg_manager.markUnused(reg);
                    },
                    .sse => {
                        const reg = getRetLocSse(reg_manager);
                        if (reg_manager.isUsed(reg)) unreachable;
                        reg_manager.markUsed(reg, i);
                        loc.moveToReg(reg, ret_size, reg_manager);
                        reg_manager.markUnused(reg);
                    },
                    .mem => {
                        const reg = getRetLocInt(reg_manager);
                        if (reg_manager.isUsed(reg)) unreachable;
                        reg_manager.markUsed(reg, i);
                        // Assume that ret_loc is always the first location on the stack
                        const ret_loc = results[1];
                        ret_loc.moveToReg(reg, ret_size, reg_manager);
                        loc.moveToAddrReg(AddrReg {.reg = reg, .disp = 0}, ret_size, reg_manager, results);

                        reg_manager.markUnused(reg);
                    },
                    .none => unreachable,
                }
            }

            var it = reg_manager.dirty.intersectWith(CalleeSaveMask).iterator(.{});
            while (it.next()) |regi| {
                const reg: Register = @enumFromInt(regi);
                reg_manager.restoreDirty(reg);
            }
            reg_manager.print("\tleave\n", .{});
            reg_manager.print("\tret\n", .{});

        }
        pub fn makeCall(
            i: usize,
            call: Cir.Inst.Call, 
            reg_manager: *RegisterManager, 
            results: []ResultLocation) void {
            // TODO: factor this out
            const caller_used = CallerSaveMask.differenceWith(reg_manager.unused);
            const callee_unused = CalleeSaveMask.intersectWith(reg_manager.unused);
            var it = caller_used.iterator(.{ .kind = .set });
            while (it.next()) |regi| {
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
            // keep track of the number of integer parameter. This is used to determine the which integer register should the next integer parameter uses 
            var call_int_ct: u8 = 0;
            // keep track of the number of float parameter. In addition to the purpose of call_int_ct, this is also needed because the number of float needs to be passed in rax
            var call_float_ct: u8 = 0;
            if (call.t != TypePool.@"void") {
                const ret_class = classifyType(call.t);
                // If the class of the return type is mem, a pointer to the stack is passed to %rdi as if it is the first argument
                if (ret_class == .mem) {
                    call_int_ct += 1;
                }
            }

            // Move each argument operand into the right register
            // According to Microsoft, the caller is supposd to allocate 32 bytes of `shadow space`, below the stack args
            var arg_stack_allocation: usize = 0;
            // TODO: this should be done in reverse order
            for (call.args) |arg| {
                var loc = results[arg.i];
                const arg_class = classifyType(arg.t);
                const arg_size = typeSize(arg.t);
                if (call_int_ct + call_float_ct >= 4) @panic("More than 4 arguments, the rest should go onto the stack, but it is not yet implemented");
                blk: switch (arg_class) {
                    .int => {
                        const reg = getArgLoc(reg_manager, call_int_ct, .int).?;
                        loc.moveToReg(reg, arg_size, reg_manager);
                        call_int_ct += 1;
                    },
                    // https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention?view=msvc-170#varargs
                    // for varargs, floating-point values must also be duplicate into the integer register
                    .sse => {
                        const reg = getArgLoc(reg_manager, call_float_ct, .sse).?;
                        loc.moveToReg(reg, arg_size, reg_manager);
                        call_float_ct += 1;
                        if (call.name == Lexer.printf) continue :blk .int;
                    },
                    // for 
                    .mem => {
                        _ = reg_manager.allocateStackTempTyped(arg.t);
                        //const reg = reg_manager.getUnused(i, RegisterManager.GpRegs);
                        //reg_manager.markUnused(reg);
                        loc.moveToAddrReg(.{.reg = .rsp, .disp = 0}, typeSize(arg.t), reg_manager, results);
                        arg_stack_allocation += 1;
                        call_int_ct += 1;
                    },
                    .none => unreachable,
                }
            }
            var ret_mem: isize = undefined;
            if (call.t != TypePool.@"void") {
                const ret_class = classifyType(call.t);
                // If the class of the return type is mem, a pointer to the stack is passed to %rdi as if it is the first argument
                // On return, %rax will contain the address that has been passed in by the calledr in %rdi
                if (ret_class == .mem) {
                    // TODO: use temporary stack memory
                    ret_mem = reg_manager.allocateStackTyped(call.t);
                    const reg = getArgLoc(reg_manager, 0, .int).?;
                    reg_manager.print("\tlea {}, [rbp + {}]\n", .{reg, ret_mem});

                }
            }
            //const arg_stack_allocation_aligned = alignStack(arg_stack_allocation);
            //reg_manager.print("\tsub rsp, {}\n", .{arg_stack_allocation_aligned - arg_stack_allocation});
            const SHADOW_SPACE = 32;
            reg_manager.print("\t# shadow space\n", .{});
            _ = reg_manager.allocateStackTemp(SHADOW_SPACE, SHADOW_SPACE);
            reg_manager.print("\tcall {s}\n", .{Lexer.lookup(call.name)}); // TODO handle return 
            for (0..arg_stack_allocation+1) |_| reg_manager.freeStackTemp();
            // ResultLocation
            if (call.t != TypePool.@"void") {
                const ret_class = classifyType(call.t);
                switch (ret_class) {
                    .int => {
                        reg_manager.markUsed(.rax, i);
                        results[i] = ResultLocation{ .reg = .rax };
                    },
                    .sse => {
                        reg_manager.markUsed(.xmm0, i);
                        results[i] = ResultLocation{ .reg = .xmm0 };
                    },
                    .mem => {
                        results[i] = ResultLocation.stackBase(ret_mem);
                    },
                    .none => unreachable,
                }
            }
        }
    };


};
pub const OutputBuffer = std.ArrayList(u8);
pub fn compileAll(cirs: []Cir, file: std.fs.File.Writer, alloc: std.mem.Allocator, os: std.Target.Os.Tag) !void {
    try file.print(builtinText, .{});

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
        .windows => CallingConvention.FastCall.interface(),
        else => @panic("Unsupported OS, only linux and windows is supported"),
    };
    // This creates the entry point of the program
    {
        var exit_args = [_]Cir.ScopeItem{ .{.t = TypePool.int, .i = 3 } };
        var entry_insts = [_]Cir.Inst {
            Cir.Inst {.block_start = 0},
            Cir.Inst {.ret_decl = TypePool.void},
            Cir.Inst {.call = .{.name = Lexer.main, .t = TypePool.void, .args = &.{}}},
            Cir.Inst {.lit = .{.int = 0}},
            Cir.Inst {.call = .{.name = Lexer.intern("exit"), .t = TypePool.void, .args = &exit_args }},
            Cir.Inst {.block_end = 0},
        };
        const pgm_entry = Cir {.arg_types = &.{}, .insts = &entry_insts, .name = Lexer.intern("_start"), .ret_type = TypePool.void };
        // On windows, the start function requires an additional 8 byte of the stack
        // On linux, it doesn't
        const prologue = switch (os) {
            .linux => false,
            .windows => true,
            else => @panic("Unsupported OS, only linux and windows is supported"),
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
    prologue: bool) !void {
    log.debug("cir: {s}", .{Lexer.lookup(self.name)});
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
            file.print("\tpush rbp\n\tmov rbp, rsp\n", .{}) catch unreachable;
            file.print("\tsub rsp, {}\n", .{alignStack(reg_manager.max_usage)}) catch unreachable;
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
    // push rbp
    // mov rbp, rsp <- rbp for the calle
    // sub rsp, [amount of stack memory]
    //
    // (+ => downwards, - => upwards)
    // -------- <- rsp of the callee
    // callee stack ...
    // -------- <- rbp of the callee
    // rbp of the caller saved (PTR_SIZE)
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
                //const v = switch (self.insts[var_access]) {
                //    .var_decl => |v| v,
                //    .arg_decl => |v| v,
                //    else => unreachable,
                //};
                const loc = results[var_access];
                //if (v.auto_deref) {
                //    const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                //    loc.moveToReg(reg, PTR_SIZE);
                //    results[i] = ResultLocation {.addr_reg = .{.reg = reg, .off = 0}};
                //} else {
                //    results[i] = loc;

                //}
                results[i] = loc;
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
            .mod, .div => |bin_op| {
                const exclude = [_]Register{ Register.DivendReg, Register.DivQuotient, Register.DivRemainder };
                if (reg_manager.isUsed(Register.DivendReg)) {
                    const other_inst = reg_manager.getInst(Register.DivendReg);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, 8, &reg_manager);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                if (reg_manager.isUsed(Register.DivRemainder)) {
                    const other_inst = reg_manager.getInst(Register.DivRemainder);
                    const new_reg = reg_manager.getUnusedExclude(other_inst, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                    results[other_inst].moveToReg(new_reg, 8, &reg_manager);
                    results[other_inst] = ResultLocation{ .reg = new_reg };
                }
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                const rhs_reg = reg_manager.getUnusedExclude(null, &exclude, RegisterManager.GpMask) orelse @panic("TODO");
                lhs_loc.moveToReg(Register.DivendReg, 8, &reg_manager);
                reg_manager.print("\tmov edx, 0\n", .{});
                rhs_loc.moveToReg(rhs_reg, 8, &reg_manager);
                reg_manager.print("\tidiv {}\n", .{rhs_reg});

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
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                lhs_loc.moveToReg(reg, PTR_SIZE, &reg_manager);
                reg_manager.print("\tcmp {}, ", .{reg});
                try rhs_loc.print(reg_manager.body_writer, .byte);
                reg_manager.print("\n", .{});
                reg_manager.print("\tsete {}\n", .{reg.lower8()});
                reg_manager.print("\tmovzx {}, {}\n", .{ reg, reg.lower8() });
                results[i] = ResultLocation{ .reg = reg };
            },
            .eqf, .ltf, .gtf => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                lhs_loc.moveToReg(reg, 4, &reg_manager);
                reg_manager.print("\tcomiss {}, ", .{reg});
                try rhs_loc.print(body_writer, .dword);
                reg_manager.print("\n", .{});

                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                reg_manager.print("\tsete {}\n", .{res_reg.lower8()});
                reg_manager.print("\tmovzx {}, {}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .eqd, .ltd, .gtd => |bin_op| {
                const lhs_loc = consumeResult(results, bin_op.lhs, &reg_manager);
                const reg = reg_manager.getUnused(null, RegisterManager.FloatMask) orelse @panic("TODO");
                const rhs_loc = consumeResult(results, bin_op.rhs, &reg_manager);
                lhs_loc.moveToReg(reg, 8, &reg_manager);
                reg_manager.print("\tcomisd {}, ", .{reg});
                try rhs_loc.print(body_writer, .qword);
                reg_manager.print("\n", .{});

                const res_reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                reg_manager.print("\tsete {}\n", .{res_reg.lower8()});
                reg_manager.print("\tmovzx {}, {}\n", .{ res_reg, res_reg.lower8() });
                results[i] = ResultLocation{ .reg = res_reg };
            },
            .not => |rhs| {
                const rhs_loc = consumeResult(results, rhs, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse @panic("TODO");
                rhs_loc.moveToReg(reg, typeSize(TypePool.@"bool"), &reg_manager);
                reg_manager.print("\ttest {}, {}\n", .{reg, reg});
                reg_manager.print("\tsetz {}\n", .{reg.lower8()});
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
                const loc = consumeResult(results, i - 1, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                loc.moveAddrToReg(reg, &reg_manager);
                results[i] = ResultLocation {.reg = reg};
            },
            .deref => {
                const loc = consumeResult(results, i - 1, &reg_manager);
                const reg = reg_manager.getUnused(i, RegisterManager.GpMask) orelse unreachable;
                loc.moveToReg(reg, PTR_SIZE, &reg_manager);

                results[i] = ResultLocation {.addr_reg = .{.reg = reg, .disp = 0}};
            },
            .field => |field| {
                switch (TypePool.lookup(field.t)) {
                    .named => |tuple| results[i] = ResultLocation {.int_lit = @intCast(tupleOffset(tuple.els, field.off))},
                    .tuple => |tuple| results[i] = ResultLocation {.int_lit = @intCast(tupleOffset(tuple.els, field.off))},
                    else => unreachable
                }
            },
            .getelementptr => |getelementptr| {
                const base = consumeResult(results, getelementptr.base, &reg_manager).moveToGpReg(PTR_SIZE, i, &reg_manager);
                const mul_imm = consumeResult(results, getelementptr.mul_imm, &reg_manager).int_lit;
                const mul_reg = consumeResult(results, getelementptr.mul_reg, &reg_manager).moveToGpReg(PTR_SIZE, i, &reg_manager);

                if (Word.fromSize(@intCast(mul_imm))) |word| {
                    results[i] = ResultLocation {.addr_reg = 
                        .{
                            .reg = base, 
                            .disp = 0, 
                            .mul = .{mul_reg, word}, 
                        }
                    };
                } else {
                    reg_manager.print("\timul {}, {}, {}\n", .{mul_reg, mul_reg, mul_imm});
                    results[i] = ResultLocation {.addr_reg = 
                        .{
                            .reg = base, 
                            .mul = .{mul_reg, Word.byte},
                            .disp = 0,
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
        \\push rbp
 \\.seh_pushreg rbp
 \\push rbx
 \\.seh_pushreg rbx
 \\sub rsp, 56
 \\.seh_stackalloc 56
 \\lea rbp, 48[rsp]
 \\.seh_setframe rbp, 48
 \\.seh_endprologue
 \\mov QWORD PTR 32[rbp], rcx
 \\mov QWORD PTR 40[rbp], rdx
 \\mov QWORD PTR 48[rbp], r8
 \\mov QWORD PTR 56[rbp], r9
 \\lea rax, 40[rbp]
 \\mov QWORD PTR -16[rbp], rax
 \\mov rbx, QWORD PTR -16[rbp]
 \\mov ecx, 1
 \\mov rax, QWORD PTR __imp___acrt_iob_func[rip]
 \\call rax
 \\mov rcx, rax
 \\mov rax, QWORD PTR 32[rbp]
 \\mov r8, rbx
 \\mov rdx, rax
 \\call __mingw_vfprintf
 \\mov DWORD PTR -4[rbp], eax
 \\mov eax, DWORD PTR -4[rbp]
 \\add rsp, 56
 \\pop rbx
 \\pop rbp
 \\ret
 \\.seh_endproc
 \\.section .rdata,"dr

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

//const builtinStart = "_start:\n\tcall main\n\tmov rdi, 0\n\tcall exit\n";
const builtinStart = "_start:\n\tcall main\n\tmov rcx, 0\n\tcall exit\n";
const fnStart = "\tpush rbp\n\tmov rbp, rsp\n";
